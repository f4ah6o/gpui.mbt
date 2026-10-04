param(
  [switch]$PortableOnly
)

$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$evidence = Join-Path (Get-Location) "_build/windows-native"
New-Item -ItemType Directory -Force $evidence | Out-Null
$env:MOONBIT_NEW_NATIVE = "0"

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Program,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogName
  )
  $log = Join-Path $evidence $LogName
  $output = & $Program @Arguments 2>&1
  $status = $LASTEXITCODE
  $output | Tee-Object -FilePath $log
  if ($status -ne 0) {
    throw "$Program $($Arguments -join ' ') failed with exit code $status; see $log"
  }
}

if ($IsWindows) {
  Invoke-CheckedCommand -Program "git" -Arguments @("rev-parse", "HEAD") -LogName "revision.txt"
  Invoke-CheckedCommand -Program "where.exe" -Arguments @("cl") -LogName "compiler-path.txt"
  Invoke-CheckedCommand -Program "moon" -Arguments @("version", "--all") -LogName "moon-version.txt"
  $backendObject = Join-Path $evidence "backend-msvc.obj"
  Invoke-CheckedCommand -Program "cl" -Arguments @(
    "/nologo", "/Bv", "/std:c11", "/utf-8", "/W4", "/c",
    "windows/backend.c", "/Fo$backendObject"
  ) -LogName "msvc-c-compile.log"
}

Invoke-CheckedCommand -Program "moon" -Arguments @("fmt", "--check", "windows", "examples/windows") -LogName "format.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "windows", "--target", "native", "--deny-warn") -LogName "check-windows.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "examples/windows", "--target", "native", "--deny-warn") -LogName "check-example.log"

Remove-Item Env:GPUI_WINDOWS_E2E -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/windows", "--target", "native", "--deny-warn") -LogName "portable-tests.log"

if ($PortableOnly) {
  exit 0
}
if (-not $IsWindows) {
  throw "The native Windows tests require Windows; use -PortableOnly for headless coverage."
}

$env:GPUI_WINDOWS_E2E = "1"
$env:GPUI_WINDOWS_READBACK = "1"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/windows", "--target", "native", "--deny-warn") -LogName "windows-e2e.log"

Remove-Item Env:GPUI_WINDOWS_E2E -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue
$env:GPUI_WINDOWS_SMOKE = "1"
Invoke-CheckedCommand -Program "moon" -Arguments @("run", "examples/windows", "--target", "native") -LogName "app-smoke.log"
