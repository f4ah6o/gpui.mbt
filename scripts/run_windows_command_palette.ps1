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

function Get-PaletteJsonRecord {
  param(
    [Parameter(Mandatory = $true)][string[]]$Lines,
    [Parameter(Mandatory = $true)][string]$Prefix,
    [Parameter(Mandatory = $true)][string]$Name
  )
  $records = @($Lines | Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) })
  if ($records.Count -ne 1) {
    throw "Expected exactly one $Name record beginning '$Prefix'; found $($records.Count)."
  }
  $payload = $records[0].Substring($Prefix.Length)
  try {
    $value = ConvertFrom-Json -InputObject $payload -AsHashtable -ErrorAction Stop
  } catch {
    throw "$Name record contains malformed JSON: $($_.Exception.Message)"
  }
  if ($value -isnot [System.Collections.IDictionary]) {
    throw "$Name record JSON must be an object."
  }
  return $value
}

function Test-PaletteExactInteger {
  param([object]$Value, [long]$Minimum, [long]$Maximum)
  if ($null -eq $Value -or $Value -isnot [ValueType] -or $Value -is [bool]) { return $false }
  try { $number = [double]$Value } catch { return $false }
  return [double]::IsFinite($number) -and
    $number -eq [Math]::Truncate($number) -and
    $number -ge $Minimum -and $number -le $Maximum
}

function Test-PaletteFinitePositiveNumber {
  param([object]$Value)
  if ($null -eq $Value -or $Value -isnot [ValueType] -or $Value -is [bool]) { return $false }
  try { $number = [double]$Value } catch { return $false }
  return [double]::IsFinite($number) -and $number -gt 0
}

function Get-PaletteSmokeEvidence {
  param([Parameter(Mandatory = $true)][string]$Text)
  $lines = @($Text -split "`r?`n" | Where-Object { -not [string]::IsNullOrEmpty($_) })
  if (@($lines | Where-Object { $_.StartsWith("GPUI_WINDOWS_COMMAND_PALETTE_READBACK_UNAVAILABLE ", [StringComparison]::Ordinal) }).Count -gt 0) {
    throw "Smoke log contains READBACK_UNAVAILABLE."
  }
  $accepted = Get-PaletteJsonRecord $lines "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED " "accepted"
  $complete = Get-PaletteJsonRecord $lines "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE " "completion"
  $readback = Get-PaletteJsonRecord $lines "GPUI_WINDOWS_COMMAND_PALETTE_READBACK " "readback"

  if (-not (Test-PaletteExactInteger $accepted.presentation 1 2147483647)) { throw "Accepted record has an invalid presentation identity." }
  if (-not (Test-PaletteExactInteger $complete.presentation 1 2147483647)) { throw "Completion record has an invalid presentation identity." }
  if (-not (Test-PaletteExactInteger $readback.presentation 1 2147483647)) { throw "Readback record has an invalid presentation identity." }
  if ([long]$accepted.presentation -ne [long]$complete.presentation -or
      [long]$accepted.presentation -ne [long]$readback.presentation) {
    throw "Accepted, completed, and readback presentation identities do not match."
  }
  if (-not (Test-PaletteExactInteger $complete.event_sequence 1 9223372036854775807) -or
      -not (Test-PaletteExactInteger $readback.frame_event_sequence 1 9223372036854775807) -or
      [long]$complete.event_sequence -ne [long]$readback.frame_event_sequence) {
    throw "Completion and readback event sequences do not match."
  }

  $viewport = $readback.viewport
  if ($viewport -isnot [System.Collections.IDictionary]) { throw "Readback record has no viewport object." }
  foreach ($name in @("logical_width", "logical_height", "scale")) {
    if (-not (Test-PaletteFinitePositiveNumber $viewport[$name])) { throw "Readback viewport $name is invalid." }
  }
  $scaledWidth = [double]$viewport.logical_width * [double]$viewport.scale
  $scaledHeight = [double]$viewport.logical_height * [double]$viewport.scale
  if (-not [double]::IsFinite($scaledWidth) -or -not [double]::IsFinite($scaledHeight) -or
      $scaledWidth -gt 2147483647 -or $scaledHeight -gt 2147483647) {
    throw "Readback viewport exceeds supported pixel dimensions."
  }
  $pixelWidth = [int][Math]::Truncate($scaledWidth)
  $pixelHeight = [int][Math]::Truncate($scaledHeight)
  if ($pixelWidth -lt 4 -or $pixelHeight -lt 4) { throw "Readback viewport is too small for the three required samples." }
  $expectedPoints = @(
    "1,1",
    "$([int][Math]::Truncate($pixelWidth / 4)),$([int][Math]::Truncate($pixelHeight / 3))",
    "$($pixelWidth - 2),$($pixelHeight - 2)"
  )
  $samples = $readback.samples
  if ($samples -isnot [System.Collections.IList] -or $samples.Count -ne 3) {
    throw "Readback must contain exactly three RGBA samples."
  }
  for ($index = 0; $index -lt 3; $index++) {
    $sample = $samples[$index]
    if ($sample -isnot [System.Collections.IDictionary] -or
        $sample.point -isnot [System.Collections.IList] -or $sample.point.Count -ne 2 -or
        $sample.rgba -isnot [System.Collections.IList] -or $sample.rgba.Count -ne 4) {
      throw "Readback sample $index has an invalid point/RGBA shape."
    }
    for ($axis = 0; $axis -lt 2; $axis++) {
      if (-not (Test-PaletteExactInteger $sample.point[$axis] 0 2147483647)) {
        throw "Readback sample $index has an unexpected pixel coordinate."
      }
    }
    $actualPoint = "$([int]$sample.point[0]),$([int]$sample.point[1])"
    if ($actualPoint -ne $expectedPoints[$index]) { throw "Readback sample $index has an unexpected pixel coordinate." }
    foreach ($channel in $sample.rgba) {
      if (-not (Test-PaletteExactInteger $channel 0 255)) {
        throw "Readback sample $index contains an invalid RGBA channel."
      }
    }
  }
  return [ordered]@{
    presentation = [long]$readback.presentation
    frame_event_sequence = [long]$readback.frame_event_sequence
    viewport = $viewport
    samples = $samples
  }
}

function Assert-PaletteParserRejects {
  param([string]$Text, [string]$Case)
  try {
    $null = Get-PaletteSmokeEvidence $Text
  } catch {
    return
  }
  throw "Smoke parser accepted invalid test case '$Case'."
}

function Test-PaletteSmokeParser {
  $accepted = [ordered]@{ presentation = 4 }
  $complete = [ordered]@{ presentation = 4; event_sequence = 91 }
  $readback = [ordered]@{
    presentation = 4
    frame_event_sequence = 91
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 }
    samples = @(
      [ordered]@{ point = @(1, 1); rgba = @(0, 1, 2, 255) },
      [ordered]@{ point = @(160, 160); rgba = @(3, 4, 5, 255) },
      [ordered]@{ point = @(638, 478); rgba = @(6, 7, 8, 255) }
    )
  }
  $valid = @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 6)"
  ) -join "`n"
  $validEvidence = Get-PaletteSmokeEvidence $valid
  if ($validEvidence.presentation -ne 4 -or $validEvidence.samples.Count -ne 3) {
    throw "Smoke parser failed its valid record-chain test."
  }
  Assert-PaletteParserRejects "GPUI_WINDOWS_COMMAND_PALETTE_READBACK_UNAVAILABLE {}`n$valid" "unavailable readback"
  $mismatchedPresentation = ([regex]::new('"presentation":4')).Replace($valid, '"presentation":5', 1)
  Assert-PaletteParserRejects $mismatchedPresentation "presentation mismatch"
  Assert-PaletteParserRejects ($valid -replace '"frame_event_sequence":91', '"frame_event_sequence":92') "event mismatch"
  Assert-PaletteParserRejects ($valid -replace '"point":\[160,160\]', '"point":[159,160]') "sample coordinate mismatch"
  Assert-PaletteParserRejects ($valid -replace '"rgba":\[0,1,2,255\]', '"rgba":[0,1,2,256]') "out-of-range channel"
  Assert-PaletteParserRejects ($valid -replace '"rgba":\[0,1,2,255\]', '"rgba":[0,1,2,"255"]') "string channel"
  Assert-PaletteParserRejects ($valid -replace '"logical_width":640', '"logical_width":"640"') "string viewport dimension"
  Assert-PaletteParserRejects ($valid -replace 'GPUI_WINDOWS_COMMAND_PALETTE_READBACK \{', 'GPUI_WINDOWS_COMMAND_PALETTE_READBACK {bad') "malformed JSON"
  Assert-PaletteParserRejects "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)" "missing completion/readback"
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
Test-PaletteSmokeParser
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
  $smokeEvidence = Get-PaletteSmokeEvidence $smokeText
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
    presentation = $smokeEvidence.presentation
    frame_event_sequence = $smokeEvidence.frame_event_sequence
    viewport = $smokeEvidence.viewport
    samples = $smokeEvidence.samples
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
