# Dibuja icon-192.png e icon-512.png con los mismos trazos que icon.svg.
# Chrome quiere PNG declarado con su tamaño real para ofrecer instalar la app.
Add-Type -AssemblyName System.Drawing

function Redondeado([int]$x, [int]$y, [int]$w, [int]$h, [int]$r) {
  $p = New-Object Drawing.Drawing2D.GraphicsPath
  $d = $r * 2
  $p.AddArc($x, $y, $d, $d, 180, 90)
  $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
  $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
  $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  $p
}

$case  = [Drawing.Color]::FromArgb(0x21, 0x1e, 0x1b)
$glass = [Drawing.Color]::FromArgb(0x12, 0x10, 0x10)
$amber = [Drawing.Color]::FromArgb(0xf0, 0xa3, 0x2c)
$dim   = [Drawing.Color]::FromArgb(0xa1, 0x70, 0x2a)
$key   = [Drawing.Color]::FromArgb(0x3a, 0x35, 0x30)

# x, y, ancho, alto, radio, color — en la grilla de 512 del svg
$piezas = @(
  @(0, 0, 512, 512, 104, $case),
  @(96, 76, 320, 130, 18, $glass),
  @(128, 120, 180, 42, 6, $amber),
  @(330, 120, 54, 42, 6, $dim),
  @(96, 246, 88, 76, 20, $key),
  @(212, 246, 88, 76, 20, $key),
  @(328, 246, 88, 76, 20, $key),
  @(96, 352, 88, 76, 20, $key),
  @(212, 352, 88, 76, 20, $amber),
  @(328, 352, 88, 76, 20, $key)
)

foreach ($size in 192, 512) {
  $bmp = New-Object Drawing.Bitmap $size, $size
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $k = $size / 512
  foreach ($p in $piezas) {
    $path = Redondeado ([int]($p[0] * $k)) ([int]($p[1] * $k)) ([int]($p[2] * $k)) ([int]($p[3] * $k)) ([Math]::Max(2, [int]($p[4] * $k)))
    $brush = New-Object Drawing.SolidBrush $p[5]
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
  }
  $out = Join-Path $PSScriptRoot "icon-$size.png"
  $bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  "listo: $out"
}
