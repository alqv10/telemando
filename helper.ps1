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

# ---------------------------------------------------------------- capturas

# ponytail: solo la pantalla principal. Con dos monitores habria que capturar
# VirtualScreen y pasarle el origen al cliente; no valia la vuelta.
$jpeg = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$quality = New-Object Drawing.Imaging.EncoderParameters 1
$quality.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality, 55)

function Capture([int]$divisor) {
  if ($divisor -lt 1) { $divisor = 2 }
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $full = New-Object Drawing.Bitmap $b.Width, $b.Height
  $g = [Drawing.Graphics]::FromImage($full)
  $g.CopyFromScreen($b.X, $b.Y, 0, 0, $full.Size)
  $small = New-Object Drawing.Bitmap $full, ([int]($b.Width / $divisor)), ([int]($b.Height / $divisor))
  $ms = New-Object IO.MemoryStream
  $small.Save($ms, $jpeg, $quality)
  $out = [Convert]::ToBase64String($ms.ToArray())
  $g.Dispose(); $full.Dispose(); $small.Dispose(); $ms.Dispose()
  $out
}

# ------------------------------------------------------------------- estado

function AudioOutputs {
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

function Brightness {
  try { (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop).CurrentBrightness }
  catch { $null }
}

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
    brightness = Brightness
    outputs    = @(AudioOutputs)
    defaultOut = [Audio]::DefaultId()
    windows    = @($windows)
    clipboard  = $clip
    ramUsed    = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1mb, 1)
    ramTotal   = [math]::Round($os.TotalVisibleMemorySize / 1mb, 1)
    cpu        = [int]((Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average)
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
        # fracciones 0..1, asi el telefono no necesita saber la resolucion
        $f = $arg.Split(',')
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
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
      'shot'    { if ($id -ne '-') { [Console]::Out.WriteLine("res $id " + (Capture ([int]$arg))) } }
      'state'   { Reply $id (State | ConvertTo-Json -Compress -Depth 4) }
      'vol'     { [Audio]::Set([int]$arg) }
      'mute'    { [Audio]::Mute($arg -eq '1') }
      'output'  { [Audio]::SetDefault($arg) }
      'bright'  {
        try { (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods).WmiSetBrightness(1, [int]$arg) | Out-Null } catch { }
      }
      'app'     { if ($apps.ContainsKey($arg)) { & $apps[$arg] } }
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
