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
    [AllowEmptyCollection()]
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogName
  )
  $log = Join-Path $evidence $LogName
  $previousCl = $env:CL
  try {
    if ($IsWindows) {
      $env:CL = ("/EHsc $previousCl").Trim()
    }
    $output = & $Program @Arguments 2>&1
    $status = $LASTEXITCODE
  } finally {
    $env:CL = $previousCl
  }
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
  $clipboardFixture = Join-Path $evidence "clipboard-fixture.exe"
  $clipboardFixtureObject = Join-Path $evidence "clipboard_fixture.obj"
  Invoke-CheckedCommand -Program "cl" -Arguments @(
    "/nologo", "/std:c11", "/utf-8", "/W4",
    "tests/windows/clipboard_fixture.c", "/Fo$clipboardFixtureObject",
    "/Fe$clipboardFixture", "user32.lib"
  ) -LogName "clipboard-fixture-build.log"
  $ownerIdTest = Join-Path $evidence "accessibility-owner-id-test.exe"
  Invoke-CheckedCommand -Program "cl" -Arguments @(
    "/nologo", "/std:c11", "/utf-8", "/W4",
    "tests/native/accessibility_owner_id_allocator_test.c",
    "/Fe$ownerIdTest"
  ) -LogName "accessibility-owner-id-build.log"
  Invoke-CheckedCommand -Program $ownerIdTest -Arguments @() -LogName "accessibility-owner-id-test.log"
}

Invoke-CheckedCommand -Program "moon" -Arguments @("fmt", "--check", "windows", "platform/windows_text", "examples/windows", "examples/windows_text_field") -LogName "format.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "windows", "--target", "native", "--deny-warn") -LogName "check-windows.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "platform/windows_text", "--target", "native", "--deny-warn") -LogName "check-text-adapter.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "examples/windows", "--target", "native", "--deny-warn") -LogName "check-example.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("check", "--package-path", "examples/windows_text_field", "--target", "native", "--deny-warn") -LogName "check-text-field.log"

Remove-Item Env:GPUI_WINDOWS_E2E -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/windows", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "portable-tests.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/accessibility", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "accessibility-tests.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/platform/windows_text", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "text-adapter-tests.log"
Invoke-CheckedCommand -Program "moon" -Arguments @("test", "--package", "f4ah6o/gpui/examples/windows_text_field", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "text-field-tests.log"

if ($PortableOnly) {
  exit 0
}
if (-not $IsWindows) {
  throw "The native Windows tests require Windows; use -PortableOnly for headless coverage."
}

$env:GPUI_WINDOWS_E2E = "1"
$env:GPUI_WINDOWS_READBACK = "1"
$env:GPUI_WINDOWS_CLIPBOARD_FIXTURE = (Resolve-Path $clipboardFixture).Path
Invoke-CheckedCommand -Program "moon" -Arguments @(
  "test", "--package", "f4ah6o/gpui/windows", "--target", "native",
  "--deny-warn", "--no-parallelize", "--filter",
  "Windows clipboard fixture line reader drains buffered exit response"
) -LogName "clipboard-line-reader-regression.log"
Invoke-CheckedCommand -Program "moon" -Arguments @(
  "test", "--package", "f4ah6o/gpui/windows", "--target", "native",
  "--deny-warn", "--no-parallelize", "--filter",
  "Windows D3D11 HWND renders and reads back first frame"
) -LogName "windows-e2e.log"
Invoke-CheckedCommand -Program "moon" -Arguments @(
  "test", "--package", "f4ah6o/gpui/windows", "--target", "native",
  "--deny-warn", "--no-parallelize", "--filter",
  "shared backend lifecycle conformance on Windows"
) -LogName "windows-conformance.log"

Remove-Item Env:GPUI_WINDOWS_E2E -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue
Remove-Item Env:GPUI_WINDOWS_CLIPBOARD_FIXTURE -ErrorAction SilentlyContinue
$env:GPUI_WINDOWS_SMOKE = "1"
Invoke-CheckedCommand -Program "moon" -Arguments @("run", "examples/windows", "--target", "native") -LogName "app-smoke.log"

Invoke-CheckedCommand -Program "pwsh" -Arguments @("-NoProfile", "-File", "scripts/run_windows_text_field.ps1", "-Mode", "Smoke") -LogName "text-field-smoke.log"
Invoke-CheckedCommand -Program "pwsh" -Arguments @("-NoProfile", "-File", "scripts/run_windows_text_field.ps1", "-Mode", "Smoke", "-ExperimentalIme") -LogName "text-field-imm-smoke.log"
