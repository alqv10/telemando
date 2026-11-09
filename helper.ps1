# Motor de telemando: lee ordenes de stdin, una por linea, y las ejecuta
# sobre el escritorio. Un solo proceso vivo: arrancar powershell por cada
# click costaba ~300 ms.
#
# Protocolo: "<id> <verbo> <arg>". Si el verbo devuelve algo, responde por
# stdout "res <id> <base64>" — base64 para que nada se corte con un salto
# de linea ni se arruine por encoding.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;

public class Native {
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, int extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, int extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

  // Pixeles de verdad en todas las pantallas. "Por monitor" y no "sistema":
  // con la notebook al 150% y un monitor al 100%, un proceso de modo sistema
  // conoce una sola escala y Windows le sigue mintiendo las medidas de la
  // otra pantalla, que sale recortada. PER_MONITOR_AWARE_V2 es el contexto -4.
  // Si el proceso ya tiene modo fijado, se intenta por hilo; en un Windows
  // viejo sin esas funciones, al menos el modo sistema.
  public static string DpiPorMonitor() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "por monitor"; } catch (EntryPointNotFoundException) { }
    try { if (SetThreadDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return "por monitor (hilo)"; } catch (EntryPointNotFoundException) { }
    return SetProcessDPIAware() ? "sistema" : "sin cambiar";
  }

  // Tecla con su scan code: muchos juegos leen el teclado crudo y no se
  // enteran de un keybd_event que solo trae el codigo virtual. Las flechas y
  // compania son "extendidas": sin esa marca llegan como el teclado numerico.
  public static void Key(int vk, bool up) {
    uint flags = up ? 2u : 0u;
    if ((vk >= 0x21 && vk <= 0x2E) || vk == 0xA3 || vk == 0xA5) flags |= 1u;
    keybd_event((byte)vk, (byte)MapVirtualKey((uint)vk, 0), flags, 0);
  }
}

// El cursor no sale en CopyFromScreen: hay que pedirlo y dibujarlo a mano.
public class Cursor2 {
  [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize; public int flags; public IntPtr hCursor; public POINT pt; }
  [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
  [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
  [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
  [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);

  // Devuelve donde quedo la punta, relativa al origen capturado, o null si
  // el cursor esta escondido (un juego o un video a pantalla completa).
  public static int[] Draw(IntPtr hdc, int originX, int originY) {
    CURSORINFO ci = new CURSORINFO();
    ci.cbSize = Marshal.SizeOf(typeof(CURSORINFO));
    if (!GetCursorInfo(ref ci) || (ci.flags & 1) == 0) return null;
    int hx = 0, hy = 0;
    ICONINFO ii;
    if (GetIconInfo(ci.hCursor, out ii)) {
      hx = ii.xHotspot; hy = ii.yHotspot;
      if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask);
      if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor);
    }
    int x = ci.pt.X - originX, y = ci.pt.Y - originY;
    DrawIconEx(hdc, x - hx, y - hy, ci.hCursor, 0, 0, 0, IntPtr.Zero, 3);
    return new int[] { x, y };
  }
}

// Brillo de monitores externos por DDC/CI: lo que usa un escritorio, donde
// WmiMonitorBrightness no existe porque eso es solo para paneles de notebook.
public class Ddc {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int l, t, r, b; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct MONITORINFOEX { public int cbSize; public RECT mon; public RECT work; public int flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string device; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string str;
    public int state;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string id;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string key;
  }
  delegate bool MonEnum(IntPtr hMon, IntPtr hdc, IntPtr rect, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr data);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, out uint n);
  [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint n, [Out] PHYSICAL_MONITOR[] arr);
  [DllImport("dxva2.dll")] static extern bool GetMonitorBrightness(IntPtr h, out uint min, out uint cur, out uint max);
  [DllImport("dxva2.dll")] static extern bool SetMonitorBrightness(IntPtr h, uint v);
  [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYSICAL_MONITOR[] arr);

  // Recorre cada monitor fisico en orden; el indice es el id que usa "bright".
  // f recibe (indice, handle, codigo del fabricante, es principal) y devuelve
  // false para cortar.
  static void Each(Func<int, IntPtr, string, bool, bool> f) {
    int i = 0; bool seguir = true;
    EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, d, r, x) => {
      MONITORINFOEX mi = new MONITORINFOEX();
      mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
      GetMonitorInfo(m, ref mi);
      // "MONITOR\SAM7489\{...}" -> SAM7489, el mismo codigo que trae WmiMonitorID
      DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
      dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
      string code = "";
      if (EnumDisplayDevices(mi.device, 0, ref dd, 0) && dd.id != null) {
        string[] p = dd.id.Split('\\');
        if (p.Length > 1) code = p[1];
      }
      uint n;
      if (!GetNumberOfPhysicalMonitorsFromHMONITOR(m, out n) || n == 0) return true;
      PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
      if (GetPhysicalMonitorsFromHMONITOR(m, n, arr)) {
        foreach (PHYSICAL_MONITOR pm in arr) {
          if (seguir) seguir = f(i, pm.h, code, (mi.flags & 1) != 0);
          i++;
        }
        DestroyPhysicalMonitors(n, arr);
      }
      return seguir;
    }, IntPtr.Zero);
  }

  static bool Leer(IntPtr h, out uint min, out uint cur, out uint max) {
    // Hay monitores que contestan la segunda vez: el bus DDC es lento y miedoso.
    if (GetMonitorBrightness(h, out min, out cur, out max)) return true;
    System.Threading.Thread.Sleep(40);
    return GetMonitorBrightness(h, out min, out cur, out max);
  }

  // "indice<TAB>codigo<TAB>principal<TAB>porcentaje", solo los que contestan.
  public static string[] List() {
    var res = new System.Collections.Generic.List<string>();
    Each((i, h, code, primary) => {
      uint min, cur, max;
      if (Leer(h, out min, out cur, out max) && max > min) {
        int pct = (int)Math.Round((cur - min) * 100.0 / (max - min));
        res.Add(i + "\t" + code + "\t" + (primary ? "1" : "0") + "\t" + pct);
      }
      return true;
    });
    return res.ToArray();
  }

  // pct 0..100, convertido a la escala propia del monitor (el Odyssey G5,
  // por ejemplo, va de 0 a 50).
  // "\\.\DISPLAY2" -> "SAM7489", para ponerle nombre a cada pantalla.
  public static string CodeFor(string device) {
    DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
    dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
    if (!EnumDisplayDevices(device, 0, ref dd, 0) || dd.id == null) return "";
    string[] p = dd.id.Split('\\');
    return p.Length > 1 ? p[1] : "";
  }

  public static bool Set(int index, int pct) {
    bool ok = false;
    Each((i, h, code, primary) => {
      if (i != index) return true;
      uint min, cur, max;
      if (Leer(h, out min, out cur, out max) && max > min) {
        uint v = (uint)(min + Math.Round(Math.Max(0, Math.Min(100, pct)) * (max - min) / 100.0));
        ok = SetMonitorBrightness(h, v);
      }
      return false;
    });
    return ok;
  }
}

// CoreAudio. Los metodos que no uso quedan como huecos numerados: en una
// vtable COM lo unico que importa es el orden de las ranuras.
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolume {
  int _1(); int _2(); int _3(); int _4();
  int SetMasterVolumeLevelScalar(float level, Guid ctx);
  int _6();
  int GetMasterVolumeLevelScalar(out float level);
  int _8(); int _9(); int _10(); int _11();
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, Guid ctx);
  int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
  int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int _2();
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
  int _4();
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
  int _1();
  int GetDefaultAudioEndpoint(int flow, int role, out IMMDevice dev);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
public class MMDeviceEnumeratorObject { }

[Guid("f8679f50-850a-41cf-9c72-430f290290c8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPolicyConfig {
  int _1(); int _2(); int _3(); int _4(); int _5();
  int _6(); int _7(); int _8(); int _9(); int _10();
  int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
}

[ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
public class PolicyConfigClient { }

public class Audio {
  static IAudioEndpointVolume Endpoint() {
    IMMDevice dev;
    ((IMMDeviceEnumerator)new MMDeviceEnumeratorObject()).GetDefaultAudioEndpoint(0, 0, out dev);
    Guid iid = typeof(IAudioEndpointVolume).GUID;
    object o;
    dev.Activate(ref iid, 0, IntPtr.Zero, out o);
    return (IAudioEndpointVolume)o;
  }
  public static int Get() { float v; Endpoint().GetMasterVolumeLevelScalar(out v); return (int)Math.Round(v * 100); }
  public static void Set(int pct) { Endpoint().SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, pct / 100f)), Guid.Empty); }
  public static bool Muted() { bool m; Endpoint().GetMute(out m); return m; }
  public static void Mute(bool m) { Endpoint().SetMute(m, Guid.Empty); }
  public static string DefaultId() {
    IMMDevice d;
    ((IMMDeviceEnumerator)new MMDeviceEnumeratorObject()).GetDefaultAudioEndpoint(0, 0, out d);
    string id; d.GetId(out id); return id;
  }
  public static void SetDefault(string id) {
    IPolicyConfig pc = (IPolicyConfig)new PolicyConfigClient();
    pc.SetDefaultEndpoint(id, 0);
    pc.SetDefaultEndpoint(id, 1);
    pc.SetDefaultEndpoint(id, 2);
  }
}
"@

# Pixeles de verdad, antes de preguntarle nada a Screen (que guarda la
# primera respuesta). Sin esto, en una notebook al 150% Windows le miente a
# este proceso y la captura sale recortada. Queda en el estado para poder
# ver desde el telefono en que modo quedo.
$script:dpi = [Native]::DpiPorMonitor()
[Console]::Error.WriteLine("telemando: DPI $($script:dpi)")

# ---------------------------------------------------------------- capturas

# Las pantallas, de izquierda a derecha como estan puestas en el escritorio:
# el indice que ve el telefono ("0", "1") es este orden. "all" es el
# escritorio entero, todas juntas; "p" o nada, la principal.
function Displays {
  @([System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.X }, { $_.Bounds.Y })
}

function Region([string]$which) {
  if ($which -eq 'all') { return [System.Windows.Forms.SystemInformation]::VirtualScreen }
  $i = -1
  if ([int]::TryParse($which, [ref]$i)) {
    $d = Displays
    if ($i -ge 0 -and $i -lt $d.Count) { return $d[$i].Bounds }
  }
  [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
}

$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$quality = New-Object Drawing.Imaging.EncoderParameters 1
$quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, 55)

# El aro que marca el cursor: en el telefono la captura se ve a un sexto de
# su tamaño y la flechita sola se pierde. Ambar con borde oscuro, para que
# se lea igual sobre una ventana blanca que sobre un fondo negro.
$ringDark  = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(190, 0, 0, 0)), 1
$ringAmber = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(235, 240, 163, 44)), 1

function Capture([int]$divisor, [int]$q = 55, [string]$which = 'p') {
  if ($divisor -lt 1) { $divisor = 2 }
  $q = [math]::Max(30, [math]::Min(90, $q))
  $quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, [long]$q)
  $b = Region $which
  $full = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($b.X, $b.Y, 0, 0, $full.Size)
  $hdc = $g.GetHdc()
  $tip = $null
  try { $tip = [Cursor2]::Draw($hdc, $b.X, $b.Y) } finally { $g.ReleaseHdc($hdc) }

  $small = New-Object Drawing.Bitmap $full, ([int]($b.Width / $divisor)), ([int]($b.Height / $divisor))
  if ($tip) {
    # El aro se dibuja despues de achicar, asi su grosor no depende de la
    # nitidez elegida: siempre es una fraccion del ancho de la imagen.
    $sg = [Drawing.Graphics]::FromImage($small)
    $sg.SmoothingMode = 'AntiAlias'
    $r = [math]::Max(9, $small.Width / 42)
    $x = $tip[0] / $divisor; $y = $tip[1] / $divisor
    $ringDark.Width = $r / 2.2; $ringAmber.Width = $r / 4
    $sg.DrawEllipse($ringDark, [float]($x - $r), [float]($y - $r), [float](2 * $r), [float](2 * $r))
    $sg.DrawEllipse($ringAmber, [float]($x - $r), [float]($y - $r), [float](2 * $r), [float](2 * $r))
    $sg.Dispose()
  }
  $ms = New-Object IO.MemoryStream
  $small.Save($ms, $jpeg, $quality)
  $out = [Convert]::ToBase64String($ms.ToArray())
  $g.Dispose(); $full.Dispose(); $small.Dispose(); $ms.Dispose()
  $out
}

# ------------------------------------------------------------------- estado

# Enumerar los endpoints tarda ~800 ms y la lista de parlantes no cambia
# mientras no enchufes nada, asi que se guarda medio minuto. Cambiar de salida
# la tira a la basura para que el punto se mueva en el acto.
$script:outputsCache = $null
$script:outputsAt = [datetime]::MinValue

function AudioOutputs {
  if ($script:outputsCache -and ((Get-Date) - $script:outputsAt).TotalSeconds -lt 30) {
    return $script:outputsCache
  }
  $script:outputsCache = @(AudioOutputsFresh)
  $script:outputsAt = Get-Date
  $script:outputsCache
}

function AudioOutputsFresh {
  # El id que quiere IPolicyConfig es la cola del InstanceId del endpoint,
  # despues de "MMDEVAPI\". 0.0.0 son salidas; 0.0.1, entradas.
  try {
    Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction Stop |
      Where-Object { $_.InstanceId -like '*MMDEVAPI\{0.0.0.00000000}*' } |
      ForEach-Object {
        [pscustomobject]@{
          id   = $_.InstanceId.Substring($_.InstanceId.IndexOf('MMDEVAPI\') + 9)
          name = $_.FriendlyName
        }
      }
  } catch { @() }
}

# Win32_Processor.LoadPercentage tarda un segundo entero. El contador de
# rendimiento, abierto una sola vez, contesta en milisegundos: la primera
# lectura siempre da 0, asi que se quema aca.
$cpuCounter = $null
try {
  $cpuCounter = New-Object Diagnostics.PerformanceCounter 'Processor', '% Processor Time', '_Total'
  $cpuCounter.NextValue() | Out-Null
} catch { }

function Cpu {
  if ($cpuCounter) { try { return [int]$cpuCounter.NextValue() } catch { } }
  [int]((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average)
}

# Una entrada por pantalla con brillo regulable: el panel de la notebook por
# WMI ("wmi") y cada monitor externo por DDC/CI ("ddc0", "ddc1"...). El panel
# interno no contesta DDC, asi que nunca aparece dos veces. Preguntarle al bus
# DDC tarda decenas de ms por monitor: se guarda un rato y al cambiar un
# brillo se corrige el valor guardado en vez de volver a preguntar.
$script:screensCache = $null
$script:screensAt = [datetime]::MinValue

function Screens {
  if ($script:screensCache -and ((Get-Date) - $script:screensAt).TotalSeconds -lt 20) {
    return $script:screensCache
  }
  $script:screensCache = @(ScreensFresh)
  $script:screensAt = Get-Date
  $script:screensCache
}

# Nombre de verdad ("Odyssey G5") en vez de "Generic PnP Monitor", por el
# codigo del fabricante. No cambia mientras no enchufes otro monitor.
$script:namesCache = $null
$script:namesAt = [datetime]::MinValue

function MonitorNames {
  if ($script:namesCache -and ((Get-Date) - $script:namesAt).TotalSeconds -lt 60) { return $script:namesCache }
  $names = @{}
  try {
    Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorID -ErrorAction Stop | ForEach-Object {
      $code = ($_.InstanceName -split '\\')[1]
      $n = -join ($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ })
      if ($code -and $n -and -not $names.ContainsKey($code)) { $names[$code] = $n }
    }
  } catch { }
  $script:namesCache = $names
  $script:namesAt = Get-Date
  $names
}

# Las pantallas que se pueden mirar desde la vista Pantalla.
function DisplayList {
  $names = MonitorNames
  $i = 0
  foreach ($s in Displays) {
    $code = [Ddc]::CodeFor($s.DeviceName)
    $n = if ($code -and $names[$code]) { $names[$code] } else { "Pantalla $($i + 1)" }
    [pscustomobject]@{ i = $i; name = $n; w = $s.Bounds.Width; h = $s.Bounds.Height; primary = $s.Primary }
    $i++
  }
}

function ScreensFresh {
  $names = MonitorNames

  $list = @()
  try {
    $w = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
    if ($w) {
      $code = ($w.InstanceName -split '\\')[1]
      $n = if ($names[$code]) { $names[$code] } else { 'Pantalla integrada' }
      $list += [pscustomobject]@{ id = 'wmi'; name = $n; value = [int]$w.CurrentBrightness; primary = $false }
    }
  } catch { }

  try {
    foreach ($row in [Ddc]::List()) {
      $p = $row.Split("`t")
      $n = if ($names[$p[1]]) { $names[$p[1]] } else { "Monitor $([int]$p[0] + 1)" }
      $list += [pscustomobject]@{ id = "ddc$($p[0])"; name = $n; value = [int]$p[3]; primary = $p[2] -eq '1' }
    }
  } catch { }

  # Dos monitores iguales se llamarian igual: se numeran.
  $vistos = @{}
  foreach ($s in $list) {
    if ($vistos.ContainsKey($s.name)) { $vistos[$s.name]++; $s.name = "$($s.name) $($vistos[$s.name])" }
    else { $vistos[$s.name] = 1 }
  }
  $list
}

function SetBrightness([string]$which, [int]$pct) {
  $pct = [math]::Max(0, [math]::Min(100, $pct))
  if ($which -eq 'wmi') {
    # Un CimInstance no trae los metodos de la clase: ".WmiSetBrightness()"
    # tiraba "no contiene ningun metodo" y el catch se lo comia, asi que en
    # las notebooks el brillo nunca se movio. Va por Invoke-CimMethod, con
    # los tipos exactos que pide WMI (Brightness es uint8).
    foreach ($m in @(Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop)) {
      Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]1; Brightness = [byte]$pct } -ErrorAction Stop | Out-Null
    }
  } elseif ($which -match '^ddc(\d+)$') {
    [Ddc]::Set([int]$Matches[1], $pct) | Out-Null
  } else { return }
  if ($script:screensCache) {
    foreach ($s in $script:screensCache) { if ($s.id -eq $which) { $s.value = $pct } }
  }
}

# Las apps del menu inicio: la misma lista que ve Windows, tiendas incluidas
# (Apple Music, WhatsApp...). Abrir una cuyo id no este aca no se puede: la
# lista sigue siendo cerrada, solo que la cierra Windows y no este archivo.
$script:startCache = $null
$script:startAt = [datetime]::MinValue

function StartApps {
  if ($script:startCache -and ((Get-Date) - $script:startAt).TotalSeconds -lt 60) {
    return $script:startCache
  }
  $script:startCache = @(Get-StartApps | Sort-Object Name | ForEach-Object {
    [pscustomobject]@{ name = $_.Name; id = $_.AppID }
  })
  $script:startAt = Get-Date
  $script:startCache
}

# Teclas que quedan apretadas en el modo juego. Si el telefono se corta con
# una flecha abajo, el personaje camina solo para siempre: "kall" las suelta.
$script:held = @{}

function State {
  $os = Get-CimInstance Win32_OperatingSystem
  $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
  $windows = Get-Process | Where-Object { $_.MainWindowTitle } |
    Sort-Object { $_.MainWindowTitle } |
    ForEach-Object { [pscustomobject]@{ pid = $_.Id; title = $_.MainWindowTitle } }

  $clip = ''
  try { $clip = (Get-Clipboard -Raw -ErrorAction Stop) } catch { }
  if ($null -eq $clip) { $clip = '' }
  if ($clip.Length -gt 4000) { $clip = $clip.Substring(0, 4000) }

  [pscustomobject]@{
    host       = $env:COMPUTERNAME
    volume     = [Audio]::Get()
    muted      = [Audio]::Muted()
    screens    = @(Screens)
    displays   = @(DisplayList)
    dpi        = $script:dpi
    outputs    = @(AudioOutputs)
    defaultOut = [Audio]::DefaultId()
    windows    = @($windows)
    clipboard  = $clip
    ramUsed    = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1mb, 1)
    ramTotal   = [math]::Round($os.TotalVisibleMemorySize / 1mb, 1)
    cpu        = Cpu
    battery    = if ($bat) { [int]$bat.EstimatedChargeRemaining } else { $null }
    charging   = if ($bat) { $bat.BatteryStatus -ne 1 } else { $true }
    uptimeMin  = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
  }
}

# Lista cerrada: nada de texto que llego por la red termina en un ejecutable.
$apps = @{
  explorer = { Start-Process explorer.exe }
  calc     = { Start-Process calc.exe }
  notepad  = { Start-Process notepad.exe }
  taskmgr  = { Start-Process taskmgr.exe }
  settings = { Start-Process 'ms-settings:' }
  spotify  = { Start-Process 'spotify:' }
  terminal = { Start-Process powershell.exe }
}

# ------------------------------------------------------------------- bucle

function Reply($id, $text) {
  if ($id -eq '-') { return }
  [Console]::Out.WriteLine("res $id " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$text)))
}

while ($null -ne ($line = [Console]::In.ReadLine())) {
  $parts = $line.Split(' ', 3)
  $id = $parts[0]
  $verb = if ($parts.Length -gt 1) { $parts[1] } else { '' }
  $arg = if ($parts.Length -gt 2) { $parts[2] } else { '' }
  try {
    switch ($verb) {
      'move' {
        $d = $arg.Split(',')
        $p = [System.Windows.Forms.Cursor]::Position
        [Native]::SetCursorPos($p.X + [int]$d[0], $p.Y + [int]$d[1]) | Out-Null
      }
      'moveto' {
        # "fx,fy [pantalla]": fracciones 0..1 de la pantalla que se esta
        # mirando, asi el telefono no necesita saber ninguna resolucion
        $m = $arg.Split(' ')
        $f = $m[0].Split(',')
        $b = Region $(if ($m.Length -gt 1) { $m[1] } else { 'p' })
        [Native]::SetCursorPos($b.X + [int]([double]$f[0] * $b.Width), $b.Y + [int]([double]$f[1] * $b.Height)) | Out-Null
      }
      'click'   { [Native]::mouse_event(0x02, 0, 0, 0, 0); [Native]::mouse_event(0x04, 0, 0, 0, 0) }
      'dblclick'{ 1..2 | ForEach-Object { [Native]::mouse_event(0x02, 0, 0, 0, 0); [Native]::mouse_event(0x04, 0, 0, 0, 0) } }
      'rclick'  { [Native]::mouse_event(0x08, 0, 0, 0, 0); [Native]::mouse_event(0x10, 0, 0, 0, 0) }
      'mclick'  { [Native]::mouse_event(0x20, 0, 0, 0, 0); [Native]::mouse_event(0x40, 0, 0, 0, 0) }
      'down'    { [Native]::mouse_event(0x02, 0, 0, 0, 0) }
      'up'      { [Native]::mouse_event(0x04, 0, 0, 0, 0) }
      'scroll'  { [Native]::mouse_event(0x0800, 0, 0, [int]$arg, 0) }
      'hscroll' { [Native]::mouse_event(0x01000, 0, 0, [int]$arg, 0) }
      'vk'      { $k = [byte][int]$arg; [Native]::keybd_event($k, 0, 0, 0); [Native]::keybd_event($k, 0, 2, 0) }
      'keys'    { [System.Windows.Forms.SendKeys]::SendWait($arg) }
      'shot'    {
        # "shot <divisor> [calidad] [pantalla]"
        $s = $arg.Split(' ')
        $q = if ($s.Length -gt 1) { [int]$s[1] } else { 55 }
        $w = if ($s.Length -gt 2) { $s[2] } else { 'p' }
        if ($id -ne '-') { [Console]::Out.WriteLine("res $id " + (Capture ([int]$s[0]) $q $w)) }
      }
      'state'   { Reply $id (State | ConvertTo-Json -Compress -Depth 4) }
      'vol'     { [Audio]::Set([int]$arg) }
      'mute'    { [Audio]::Mute($arg -eq '1') }
      'output'  { [Audio]::SetDefault($arg); $script:outputsCache = $null }
      'bright'  {
        # "bright ddc0 70" o "bright wmi 40"
        $b = $arg.Split(' ')
        if ($b.Length -eq 2) { SetBrightness $b[0] ([int]$b[1]) }
      }
      'app'     { if ($apps.ContainsKey($arg)) { & $apps[$arg] } }
      'startapps' { Reply $id (ConvertTo-Json -InputObject @(StartApps) -Compress) }
      'launch'  {
        $appId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))
        if (@(StartApps | Where-Object { $_.id -eq $appId }).Count) {
          # El mismo camino que usa el menu inicio: sirve para apps de la
          # tienda y para .exe sueltos, sin armar ninguna linea de comandos.
          Start-Process explorer.exe -ArgumentList ('"shell:AppsFolder\' + $appId + '"')
        }
      }
      'kd'      { $k = [int]$arg; if (-not $script:held[$k]) { [Native]::Key($k, $false); $script:held[$k] = $true } }
      'ku'      { $k = [int]$arg; [Native]::Key($k, $true); $script:held.Remove($k) }
      'kall'    { foreach ($k in @($script:held.Keys)) { [Native]::Key($k, $true) }; $script:held.Clear() }
      'open'    { Start-Process $arg }
      'focus'   {
        $p = Get-Process -Id ([int]$arg) -ErrorAction Stop
        if ([Native]::IsIconic($p.MainWindowHandle)) { [Native]::ShowWindow($p.MainWindowHandle, 9) | Out-Null }
        [Native]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
      }
      'closewin' { (Get-Process -Id ([int]$arg) -ErrorAction Stop).CloseMainWindow() | Out-Null }
      'clip'     { Set-Clipboard -Value ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($arg))) }
      'sys'      {
        # lista cerrada, otra vez: esto apaga una computadora
        switch ($arg) {
          'lock'     { rundll32.exe user32.dll,LockWorkStation }
          'sleep'    { rundll32.exe powrprof.dll,SetSuspendState 0,1,0 }
          'shutdown' { shutdown.exe /s /t 0 }
          'reboot'   { shutdown.exe /r /t 0 }
          'logoff'   { shutdown.exe /l }
        }
      }
      default    { Reply $id '' }
    }
  } catch {
    [Console]::Error.WriteLine("telemando: $verb -> $_")
    Reply $id ''
  }
}
