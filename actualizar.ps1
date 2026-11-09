# Trae la version nueva de telemando y lo vuelve a arrancar como estaba.
#
#   clic derecho -> Ejecutar con PowerShell
#   o:  powershell -ExecutionPolicy Bypass -File actualizar.ps1
#
# token.txt y botones.json no estan en git: el pull no los toca, el telefono
# sigue vinculado y las teclas que editaste siguen ahi.
param(
  [int]$Puerto = $(if ($env:PORT) { [int]$env:PORT } else { 7070 }),
  [switch]$SinPausa
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
# git habla en UTF-8; sin esto los títulos de los commits salen con "Ã³".
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Salir([int]$codigo) {
  if (-not $SinPausa) { Write-Host ''; Read-Host 'Enter para cerrar' | Out-Null }
  exit $codigo
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host 'No encuentro git. Instalalo con:  winget install Git.Git' -ForegroundColor Red
  Salir 1
}
if (-not (Test-Path (Join-Path $PSScriptRoot '.git'))) {
  Write-Host 'Esta carpeta no es un clon de git (¿lo bajaste como ZIP?).' -ForegroundColor Red
  Write-Host 'Bajá el ZIP nuevo y reemplazá los archivos, pero sin borrar token.txt ni botones.json.'
  Salir 1
}

# ------------------------------------------------ el servidor que esta andando
# Se busca por el puerto y no por el nombre: "node server.js" puede ser
# cualquier otro proyecto, el que escucha en el puerto de telemando no.
$corriendo = $null
try {
  $pid7070 = (Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction Stop | Select-Object -First 1).OwningProcess
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $pid7070"
  if ($proc -and $proc.Name -eq 'node.exe' -and $proc.CommandLine -match 'server\.js') { $corriendo = $proc }
} catch { }

# ------------------------------------------------------------------- el pull
$antes = (git rev-parse HEAD).Trim()
Write-Host 'Buscando la versión nueva…'
git pull --ff-only
$pullOk = $LASTEXITCODE -eq 0
$despues = (git rev-parse HEAD).Trim()

if (-not $pullOk) {
  Write-Host ''
  Write-Host 'No pude actualizar. Lo más común: tocaste algún archivo de telemando a mano.' -ForegroundColor Red
  Write-Host 'Mirá cuáles con "git status". Lo que estaba andando lo dejo como estaba.'
  Salir 1
}

if ($antes -eq $despues) {
  Write-Host 'Ya tenías la última versión.' -ForegroundColor Green
  Salir 0
}

Write-Host ''
Write-Host 'Novedades:' -ForegroundColor Green
git log --format='  · %s' "$antes..$despues"

# --------------------------------------------------------- volver a arrancar
if ($corriendo) {
  $https = $corriendo.CommandLine -match '--https'
  Write-Host ''
  Write-Host 'Reiniciando el servidor…'
  # Al morir node se cierra el stdin del helper y el PowerShell se va solo.
  Stop-Process -Id $corriendo.ProcessId -Force
  Start-Sleep -Milliseconds 800
  $argumentos = if ($https) { @('server.js', '--https') } else { @('server.js') }
  Start-Process node -ArgumentList $argumentos -WorkingDirectory $PSScriptRoot -WindowStyle Minimized
  Write-Host 'Listo: telemando ya corre la versión nueva (minimizado en la barra de tareas).' -ForegroundColor Green
} else {
  Write-Host ''
  Write-Host 'Listo. El servidor no estaba andando: arrancalo con  node server.js' -ForegroundColor Green
}
Write-Host 'En el teléfono: recargá la página, o cerrá la app del todo y abrila de nuevo.'
Salir 0
