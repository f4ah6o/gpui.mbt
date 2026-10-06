param(
  [ValidateSet("Run", "Smoke", "Build", "Portable")]
  [string]$Mode = "Run",
  [switch]$ExperimentalIme
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$evidence = Join-Path (Get-Location) "_build/windows-text-field"
New-Item -ItemType Directory -Force $evidence | Out-Null
Get-Command "moon" -ErrorAction Stop | Out-Null
$env:MOONBIT_NEW_NATIVE = "0"

function Invoke-CheckedCommand {
  param(
    [Parameter(Mandatory = $true)][string]$Program,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogName
  )
  $log = Join-Path $evidence $LogName
  $previousCl = $env:CL
  if ($IsWindows -and $Program -eq "moon") {
    $env:CL = if ([string]::IsNullOrWhiteSpace($previousCl)) {
      "/EHsc"
    } else {
      "$previousCl /EHsc"
    }
  }
  try {
    $output = & $Program @Arguments 2>&1
  } finally {
    if ($IsWindows -and $Program -eq "moon") {
      $env:CL = $previousCl
    }
  }
  $status = $LASTEXITCODE
  $output | Tee-Object -FilePath $log
  if ($status -ne 0) {
    throw "$Program $($Arguments -join ' ') failed with exit code $status; see $log"
  }
}

Invoke-CheckedCommand -Program "git" -Arguments @("rev-parse", "HEAD") -LogName "revision.txt"
Invoke-CheckedCommand -Program "moon" -Arguments @("version", "--all") -LogName "moon-version.txt"
if (-not (Select-String -Path (Join-Path $evidence "moon-version.txt") -Pattern "moonc v0\.10\.14\+7d59c7ec9" -Quiet)) {
  throw "Use the repository-pinned MoonBit compiler 0.10.14+7d59c7ec9 from PATH; see docs/windows-native.md."
}
if ($IsWindows -and $Mode -ne "Portable") {
  $compiler = Get-Command "cl.exe" -ErrorAction Stop
  $compiler.Source | Set-Content -Path (Join-Path $evidence "compiler-path.txt")
  $compilerInfo = Get-Item -LiteralPath $compiler.Source
  @(
    "Path: $($compiler.Source)",
    "FileVersion: $($compilerInfo.VersionInfo.FileVersion)",
    "ProductVersion: $($compilerInfo.VersionInfo.ProductVersion)"
  ) | Set-Content -Path (Join-Path $evidence "msvc-version.txt")
  $backendObject = Join-Path $evidence "windows-backend.obj"
  Invoke-CheckedCommand -Program "cl.exe" -Arguments @(
    "/nologo", "/Bv", "/std:c11", "/utf-8", "/W4", "/c",
    "windows/backend.c", "/Fo$backendObject"
  ) -LogName "msvc-c-compile.log"
}

Invoke-CheckedCommand -Program "moon" -Arguments @("fmt", "--check", "windows", "platform/windows_text", "examples/windows_text_field") -LogName "format.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "windows", "--target", "native", "--deny-warn") -LogName "check-windows.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "platform/windows_text", "--target", "native", "--deny-warn") -LogName "check-text-adapter.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "examples/windows_text_field", "--target", "native", "--deny-warn") -LogName "check-example.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/platform/windows_text", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "text-adapter-tests.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/windows", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "windows-tests.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/examples/windows_text_field", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "controller-tests.log"

if ($Mode -eq "Portable") {
  exit 0
}
if (-not $IsWindows) {
  throw "Build, smoke, and interactive modes require Windows; use -Mode Portable elsewhere."
}

if ($Mode -eq "Build") {
  Invoke-CheckedCommand -Program "moon" -Arguments @("build", "--target", "native", "--deny-warn", "examples/windows_text_field") -LogName "build.log"
  exit 0
}

Remove-Item Env:GPUI_WINDOWS_FIELD_SMOKE -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_FIELD_IME -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_FIELD_STATE -ErrorAction SilentlyContinue
if ($Mode -eq "Smoke") {
  $env:GPUI_WINDOWS_FIELD_SMOKE = "1"
  $env:GPUI_WINDOWS_FIELD_STATE = "1"
}
if ($ExperimentalIme) {
  $env:GPUI_WINDOWS_FIELD_IME = "1"
  $env:GPUI_WINDOWS_FIELD_STATE = "1"
}
Invoke-CheckedCommand -Program "moon" -Arguments @("run", "examples/windows_text_field", "--target", "native") -LogName "app.log"
