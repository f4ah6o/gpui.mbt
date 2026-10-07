[CmdletBinding()]
param(
  [ValidateSet("Build", "Smoke", "Run", "Stop")]
  [string]$Mode = "Build",
  [switch]$ExperimentalIme,
  [switch]$NoChecks,
  [int]$ProcessId,
  [ValidateRange(5, 180)][int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repo
$evidence = Join-Path $repo "_build/windows-command-palette"
$logs = Join-Path $evidence "logs"
$buildDir = Join-Path $evidence "build"
$binary = Join-Path $evidence "bin/windows-command-palette.exe"
New-Item -ItemType Directory -Force $logs, (Split-Path $binary -Parent), $buildDir | Out-Null
$env:MOONBIT_NEW_NATIVE = "0"

$moonHome = Join-Path $repo "_build/tools/moonbit"
$pinnedMoon = Join-Path $moonHome "bin/moon.exe"
if (Test-Path -LiteralPath $pinnedMoon) {
  $env:MOON_HOME = $moonHome
  $env:PATH = "$(Join-Path $moonHome 'bin');$env:PATH"
  $moon = $pinnedMoon
} else {
  $moonCommand = Get-Command moon.exe -ErrorAction Stop
  $moon = $moonCommand.Source
}

function Initialize-Msvc {
  if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }
  $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
  $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio/Installer/vswhere.exe"
  if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "MSVC is not on PATH and vswhere.exe was not found."
  }
  $vsInstall = (& $vswhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
  if (-not $vsInstall) { throw "No Visual Studio installation with x64 C++ tools was found." }
  $vsDevCmd = Join-Path $vsInstall "Common7/Tools/VsDevCmd.bat"
  $cmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
  $environmentLines = & $env:ComSpec /d /c $cmd
  if ($LASTEXITCODE -ne 0) { throw "VsDevCmd.bat failed to prepare MSVC." }
  $toolEnvironment = @{}
  foreach ($line in $environmentLines) {
    if ($line -match '^(PATH|INCLUDE|LIB)=(.*)$') {
      $variableName = [string]$matches[1]
      $variableValue = [string]$matches[2]
      $normalizedName = $variableName.ToUpperInvariant()
      $isCanonicalName = $variableName -ceq $normalizedName
      if (-not $toolEnvironment.ContainsKey($normalizedName) -or $isCanonicalName) {
        $toolEnvironment[$normalizedName] = [pscustomobject]@{
          Name = $variableName
          Value = $variableValue
        }
      }
    }
  }
  foreach ($name in @("PATH", "INCLUDE", "LIB")) {
    if ($toolEnvironment.ContainsKey($name)) {
      $entry = $toolEnvironment[$name]
      [Environment]::SetEnvironmentVariable($entry.Name, $entry.Value, "Process")
    }
  }
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "MSVC environment initialization did not make cl.exe available."
  }
}

function Invoke-Logged {
  param(
    [Parameter(Mandatory = $true)][string]$Program,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogName
  )
  $log = Join-Path $logs $LogName
  $previousCl = $env:CL
  try {
    if ($IsWindows) {
      $env:CL = if ([string]::IsNullOrWhiteSpace($previousCl)) { "/EHsc" } else { "$previousCl /EHsc" }
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

function Get-ToolIdentity {
  $moonVersion = (& $moon version --all 2>&1 | Out-String).Trim()
  $compilerPath = Join-Path (Split-Path $moon -Parent) "moonc.exe"
  $moonIdentity = [ordered]@{
    executable = $moon
    sha256 = (Get-FileHash -LiteralPath $moon -Algorithm SHA256).Hash.ToLowerInvariant()
    version = $moonVersion
  }
  if (Test-Path -LiteralPath $compilerPath) {
    $moonIdentity.compiler = [ordered]@{
      executable = $compilerPath
      sha256 = (Get-FileHash -LiteralPath $compilerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
  }
  return $moonIdentity
}

function Get-HostIdentity {
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $videos = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
      name = $_.Name
      driver_version = $_.DriverVersion
      pnp_device_id = $_.PNPDeviceID
      current_horizontal_resolution = $_.CurrentHorizontalResolution
      current_vertical_resolution = $_.CurrentVerticalResolution
    }
  })
  $fontPath = Join-Path $env:WINDIR "Fonts/segoeui.ttf"
  $font = $null
  if (Test-Path -LiteralPath $fontPath) {
    $fontItem = Get-Item -LiteralPath $fontPath
    $font = [ordered]@{
      path = $fontPath
      sha256 = (Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash.ToLowerInvariant()
      file_version = $fontItem.VersionInfo.FileVersion
    }
  }
  return [ordered]@{
    os_caption = if ($os) { $os.Caption } else { [Environment]::OSVersion.VersionString }
    os_version = if ($os) { $os.Version } else { [Environment]::OSVersion.Version.ToString() }
    os_build = if ($os) { $os.BuildNumber } else { $null }
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    powershell = $PSVersionTable.PSVersion.ToString()
    display_adapters = $videos
    font = $font
  }
}

function Write-BuildManifest {
  $sourceHead = (& git rev-parse HEAD).Trim()
  $dirty = @(& git status --porcelain)
  $manifest = [ordered]@{
    schema_version = 1
    created_at_utc = [DateTime]::UtcNow.ToString("o")
    source_head = $sourceHead
    worktree_dirty = ($dirty.Count -gt 0)
    dirty_paths = @($dirty | ForEach-Object { $_.Substring(3).Trim() })
    executable = $binary
    executable_sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    toolchain = Get-ToolIdentity
    host = Get-HostIdentity
    logs = [ordered]@{
      stdout = Join-Path $logs "app.stdout.log"
      stderr = Join-Path $logs "app.stderr.log"
    }
    runtime_profile = [ordered]@{
      logical_size = @(640, 480)
      font_family = "Segoe UI"
      font_size = 18
      command_count = 16
      visible_rows = 8
      experimental_imm32_default = $false
      candidate_rect_source = "TextField.caret_rect, floored origin / ceiled right and bottom"
    }
  }
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $evidence "manifest.json") -Encoding utf8
}

function Build-Fixture {
  Initialize-Msvc
  if (-not $NoChecks) {
    Invoke-Logged -Program $moon -Arguments @("fmt", "--check", "examples/windows_command_palette") -LogName "format.log"
    Invoke-Logged -Program $moon -Arguments @("check", "--package-path", "examples/windows_command_palette", "--target", "native", "--deny-warn") -LogName "check.log"
    Invoke-Logged -Program $moon -Arguments @("test", "--package", "f4ah6o/gpui/examples/windows_command_palette", "--target", "native", "--deny-warn", "--no-parallelize") -LogName "tests.log"
  }
  $output = Join-Path $logs "build.log"
  Invoke-Logged -Program $moon -Arguments @("build", "--target", "native", "--deny-warn", "--target-dir", $buildDir, "examples/windows_command_palette") -LogName "build.log"
  $built = Get-ChildItem -LiteralPath $buildDir -Filter "windows_command_palette.exe" -File -Recurse |
    Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
  if (-not $built) { throw "MoonBit completed without producing windows_command_palette.exe; see $output" }
  Copy-Item -LiteralPath $built.FullName -Destination $binary -Force
  Write-BuildManifest
}

if ($Mode -eq "Stop") {
  if ($ProcessId -le 0) { throw "Pass -ProcessId from a Run launch to stop the owned fixture." }
  $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction SilentlyContinue
  if (-not $processInfo) { Write-Output "Fixture process $ProcessId is already stopped."; exit 0 }
  $expected = [IO.Path]::GetFullPath($binary)
  $actual = if ($processInfo.ExecutablePath) { [IO.Path]::GetFullPath($processInfo.ExecutablePath) } else { "" }
  if (-not [string]::Equals($expected, $actual, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Process $ProcessId does not match this fixture executable; refusing to stop it."
  }
  Stop-Process -Id $ProcessId -Force
  Write-Output "Stopped command-palette fixture PID $ProcessId."
  exit 0
}

if (-not $IsWindows) { throw "The Windows command-palette fixture requires Windows." }
Build-Fixture

if ($Mode -eq "Build") {
  Write-Output "Built Windows command-palette fixture: $binary"
  Write-Output "Build manifest: $(Join-Path $evidence 'manifest.json')"
  exit 0
}

$env:GPUI_WINDOWS_READBACK = "1"
$env:GPUI_WINDOWS_COMMAND_PALETTE_IME = if ($ExperimentalIme) { "1" } else { "0" }
Remove-Item Env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE -ErrorAction SilentlyContinue

if ($Mode -eq "Smoke") {
  $env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE = "1"
  $stdout = Join-Path $logs "smoke.stdout.log"
  $stderr = Join-Path $logs "smoke.stderr.log"
  Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue
  $process = Start-Process -FilePath $binary -WorkingDirectory $repo -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "Smoke fixture exceeded $TimeoutSeconds seconds; see $stdout and $stderr"
  }
  if ($process.ExitCode -ne 0) { throw "Smoke fixture exited $($process.ExitCode); see $stdout and $stderr" }
  $smokeText = if (Test-Path $stdout) { Get-Content -Raw $stdout } else { "" }
  foreach ($required in @("GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED", "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE", "GPUI_WINDOWS_COMMAND_PALETTE_READBACK")) {
    if (-not $smokeText.Contains($required)) { throw "Smoke log is missing $required; see $stdout" }
  }
  Copy-Item -LiteralPath $stdout -Destination (Join-Path $logs "app.stdout.log") -Force
  Copy-Item -LiteralPath $stderr -Destination (Join-Path $logs "app.stderr.log") -Force
  $manifestPath = Join-Path $evidence "manifest.json"
  $manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -AsHashtable
  $manifest.smoke = [ordered]@{
    exit_code = $process.ExitCode
    timeout_seconds = $TimeoutSeconds
    accepted_frame = $true
    completed_frame = $true
    readback_samples = $true
    stdout = $stdout
    stderr = $stderr
  }
  $manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
  Write-Output "Windows command-palette frame/readback smoke passed. Executable: $binary; evidence: $evidence"
  exit 0
}

$stdout = Join-Path $logs "app.stdout.log"
$stderr = Join-Path $logs "app.stderr.log"
$process = Start-Process -FilePath $binary -WorkingDirectory $repo -WindowStyle Normal -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$manifestPath = Join-Path $evidence "manifest.json"
$manifest = Get-Content -Raw $manifestPath | ConvertFrom-Json -AsHashtable
$manifest.launch = [ordered]@{
  pid = $process.Id
  started_at_utc = [DateTime]::UtcNow.ToString("o")
  experimental_imm32 = [bool]$ExperimentalIme
  stdout = $stdout
  stderr = $stderr
  cleanup = "pwsh -NoProfile -File scripts/run_windows_command_palette.ps1 -Mode Stop -ProcessId $($process.Id)"
}
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
Write-Output "Started visible Windows command-palette fixture PID $($process.Id)."
Write-Output "Executable: $binary"
Write-Output "Live flushed output: $stdout"
Write-Output "Diagnostics: $stderr"
Write-Output "Cleanup: pwsh -NoProfile -File scripts/run_windows_command_palette.ps1 -Mode Stop -ProcessId $($process.Id)"
