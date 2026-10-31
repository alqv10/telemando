# Pone (o saca, con -Off) un acceso directo en shell:startup para que
# telemando arranque solo con Windows, minimizado.
param([switch]$Off, [switch]$Https)

$link = Join-Path ([Environment]::GetFolderPath('Startup')) 'Telemando.lnk'

if ($Off) {
  Remove-Item $link -ErrorAction SilentlyContinue
  "listo: no arranca mas solo"
  return
}

$node = (Get-Command node).Source
$s = (New-Object -ComObject WScript.Shell).CreateShortcut($link)
$s.TargetPath = $node
$s.Arguments = if ($Https) { 'server.js --https' } else { 'server.js' }
$s.WorkingDirectory = $PSScriptRoot
$s.WindowStyle = 7          # minimizado
$s.Description = 'Telemando'
$s.Save()
"listo: arranca con Windows ($link)"
