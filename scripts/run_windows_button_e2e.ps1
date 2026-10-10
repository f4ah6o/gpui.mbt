[CmdletBinding()]
param(
  [string]$OutputDirectory,
  [ValidateRange(5, 120)][int]$TimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repo
$moonHome = Join-Path $repo "_build/tools/moonbit"
if (-not (Test-Path -LiteralPath (Join-Path $moonHome "bin/moon.exe")) -and
    -not [string]::IsNullOrWhiteSpace($env:MOON_HOME) -and
    (Test-Path -LiteralPath (Join-Path $env:MOON_HOME "bin/moon.exe"))) {
  $moonHome = $env:MOON_HOME
}
$moon = Join-Path $moonHome "bin/moon.exe"
$evidenceRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  Join-Path $repo "_build/windows-button/e2e"
} else {
  [IO.Path]::GetFullPath($OutputDirectory)
}
$runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
$runDir = Join-Path $evidenceRoot $runId
$interop = Join-Path $PSScriptRoot "windows_button_e2e_native.cs"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Add-Type -Path $interop -ErrorAction Stop
if ([IntPtr]::Size -ne 8 -or [WindowsButtonE2E.Win32]::InputStructureSize() -ne 40) {
  throw "Button E2E requires x64 PowerShell and sizeof(INPUT)==40; process=$([IntPtr]::Size), INPUT=$([WindowsButtonE2E.Win32]::InputStructureSize())."
}

$script:result = [ordered]@{
  schema_version = 1
  run_id = $runId
  status = "IN_PROGRESS"
  started_at_utc = [DateTime]::UtcNow.ToString("o")
  source_head = (& git rev-parse HEAD).Trim()
  source_dirty = (@(& git status --porcelain).Count -gt 0)
  evidence_directory = $runDir
  executable = $null
  executable_sha256 = $null
  host = [ordered]@{
    os = [Environment]::OSVersion.VersionString
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    powershell = $PSVersionTable.PSVersion.ToString()
    process_bits = [IntPtr]::Size * 8
    input_structure_size = [WindowsButtonE2E.Win32]::InputStructureSize()
  }
  processes = @()
  inputs = @()
  checkpoints = @()
  limitation = "UI Automation transport is unsupported; evidence covers the shared headless semantic snapshot, SendInput delivery, D3D11 completed-frame readback and same-process lifecycle only."
  failure = $null
}
$osProfile = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue
$displayAdapters = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object {
  [ordered]@{
    name = $_.Name
    driver_version = $_.DriverVersion
    current_horizontal_resolution = $_.CurrentHorizontalResolution
    current_vertical_resolution = $_.CurrentVerticalResolution
  }
})
$fontPath = Join-Path $env:WINDIR "Fonts/segoeui.ttf"
$fontEvidence = $null
if (Test-Path -LiteralPath $fontPath) {
  $fontEvidence = [ordered]@{
    path = $fontPath
    sha256 = (Get-FileHash -LiteralPath $fontPath -Algorithm SHA256).Hash.ToLowerInvariant()
    file_version = (Get-Item -LiteralPath $fontPath).VersionInfo.FileVersion
  }
}
$script:result.host.os_caption = if ($osProfile) { $osProfile.Caption } else { [Environment]::OSVersion.VersionString }
$script:result.host.os_version = if ($osProfile) { $osProfile.Version } else { [Environment]::OSVersion.Version.ToString() }
$script:result.host.os_build = if ($osProfile) { $osProfile.BuildNumber } else { $null }
$script:result.host.display_adapters = $displayAdapters
$script:result.host.font = $fontEvidence
$script:owners = [System.Collections.Generic.List[object]]::new()
$script:activeOwner = $null

function Save-Result {
  $script:result.updated_at_utc = [DateTime]::UtcNow.ToString("o")
  $script:result | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $runDir "result.json") -Encoding utf8
}

function Add-Checkpoint {
  param([string]$Name, [string]$Status, [object]$Details = $null)
  $script:result.checkpoints += [ordered]@{
    name = $Name
    status = $Status
    details = $Details
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  Save-Result
}

function Get-Records {
  param([object]$Owner, [string]$Prefix)
  if (-not (Test-Path -LiteralPath $Owner.stdout)) { return @() }
  $lines = @(Get-Content -LiteralPath $Owner.stdout -ErrorAction SilentlyContinue)
  $records = @()
  foreach ($line in $lines) {
    if ($line.StartsWith($Prefix, [StringComparison]::Ordinal)) {
      try { $records += ,(ConvertFrom-Json -InputObject $line.Substring($Prefix.Length) -AsHashtable -ErrorAction Stop) } catch {}
    }
  }
  return $records
}

function Wait-Record {
  param([object]$Owner, [string]$Prefix, [scriptblock]$Predicate, [string]$Description)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $records = @(Get-Records -Owner $Owner -Prefix $Prefix)
    if ($records.Count -gt 0) {
      $candidate = $records[$records.Count - 1]
      if (& $Predicate $candidate) { return $candidate }
    }
    $Owner.process.Refresh()
    if ($Owner.process.HasExited) {
      $stderr = if (Test-Path -LiteralPath $Owner.stderr) { Get-Content -Raw -LiteralPath $Owner.stderr } else { "" }
      throw "Owned Button process exited before $Description (exit=$($Owner.process.ExitCode)): $stderr"
    }
    Start-Sleep -Milliseconds 100
  }
  throw "Timed out waiting for $Description."
}

function Wait-Window {
  param([object]$Owner)
  $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  while ([DateTime]::UtcNow -lt $deadline) {
    $handle = [WindowsButtonE2E.Win32]::FindWindow($Owner.pid)
    if ($handle -ne 0) {
      $Owner.hwnd = [long]$handle
      if (-not [WindowsButtonE2E.Win32]::SetForegroundWindow([IntPtr]$Owner.hwnd)) {
        Start-Sleep -Milliseconds 100
      }
      if ([WindowsButtonE2E.Win32]::GetForegroundWindow().ToInt64() -eq $Owner.hwnd) { return }
    }
    $Owner.process.Refresh()
    if ($Owner.process.HasExited) { throw "Button process exited before its visible GPUI HWND appeared." }
    Start-Sleep -Milliseconds 100
  }
  throw "Timed out finding the owned visible GPUI window in the foreground."
}

function Start-ButtonProcess {
  param([string]$Name)
  $stdout = Join-Path $runDir "$Name.stdout.log"
  $stderr = Join-Path $runDir "$Name.stderr.log"
  $saved = @{
    o = $env:GPUI_WINDOWS_BUTTON_OBSERVE
    n = $env:GPUI_NATIVE_E2E
    r = $env:GPUI_WINDOWS_READBACK
  }
  try {
    $env:GPUI_WINDOWS_BUTTON_OBSERVE = "1"
    $env:GPUI_NATIVE_E2E = "1"
    $env:GPUI_WINDOWS_READBACK = "1"
    $process = Start-Process -FilePath $script:result.executable -WorkingDirectory $repo -WindowStyle Normal -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  } finally {
    if ($null -eq $saved.o) { Remove-Item Env:GPUI_WINDOWS_BUTTON_OBSERVE -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_BUTTON_OBSERVE = $saved.o }
    if ($null -eq $saved.n) { Remove-Item Env:GPUI_NATIVE_E2E -ErrorAction SilentlyContinue } else { $env:GPUI_NATIVE_E2E = $saved.n }
    if ($null -eq $saved.r) { Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_READBACK = $saved.r }
  }
  $process.Refresh()
  $owner = [pscustomobject]@{
    name = $Name
    pid = [int]$process.Id
    start_ticks = [long]$process.StartTime.ToUniversalTime().Ticks
    hwnd = 0L
    stdout = $stdout
    stderr = $stderr
    process = $process
  }
  $script:owners.Add($owner)
  $script:result.processes += [ordered]@{
    name = $Name
    pid = $owner.pid
    start_time_utc = $process.StartTime.ToUniversalTime().ToString("o")
    hwnd = $null
    window_class = "gpui_mbt_windows_host_v1"
    dpi = $null
    stdout = $stdout
    stderr = $stderr
  }
  Save-Result
  Wait-Window $owner
  $processRecord = $script:result.processes[-1]
  $processRecord.hwnd = $owner.hwnd
  $processRecord.dpi = [WindowsButtonE2E.Win32]::GetDpiForWindow([IntPtr]$owner.hwnd)
  $script:activeOwner = $owner
  Save-Result
  return $owner
}

function Send-Key {
  param([string]$Action, [ushort]$VirtualKey, [bool]$KeyUp)
  $owner = $script:activeOwner
  if (-not [WindowsButtonE2E.Win32]::IsOwnedWindow($owner.hwnd, $owner.pid) -or
      [WindowsButtonE2E.Win32]::GetForegroundWindow().ToInt64() -ne $owner.hwnd) {
    throw "Owned foreground HWND check failed before SendInput for $Action."
  }
  $native = [WindowsButtonE2E.Win32]::SendKey($VirtualKey, $KeyUp)
  $event = [ordered]@{
    action = $Action
    kind = if ($KeyUp) { "key_up" } else { "key_down" }
    virtual_key = [int]$VirtualKey
    requested = [uint32]$native.Requested
    inserted = [uint32]$native.Inserted
    input_size = [int]$native.InputSize
    win32_error = [int]$native.LastError
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  $script:result.inputs += $event
  Save-Result
  if ($native.Inserted -ne 1) { throw "SendInput inserted $($native.Inserted) of 1 events for $Action; Win32=$($native.LastError)." }
  Start-Sleep -Milliseconds 100
}

function Send-Mouse {
  param([string]$Action, [bool]$ButtonUp)
  $owner = $script:activeOwner
  if (-not [WindowsButtonE2E.Win32]::IsOwnedWindow($owner.hwnd, $owner.pid) -or
      [WindowsButtonE2E.Win32]::GetForegroundWindow().ToInt64() -ne $owner.hwnd) {
    throw "Owned foreground HWND check failed before SendInput for $Action."
  }
  $native = [WindowsButtonE2E.Win32]::SendMouse($ButtonUp)
  $event = [ordered]@{
    action = $Action
    kind = if ($ButtonUp) { "mouse_up" } else { "mouse_down" }
    requested = [uint32]$native.Requested
    inserted = [uint32]$native.Inserted
    input_size = [int]$native.InputSize
    win32_error = [int]$native.LastError
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  $script:result.inputs += $event
  Save-Result
  if ($native.Inserted -ne 1) { throw "SendInput inserted $($native.Inserted) of 1 events for $Action; Win32=$($native.LastError)." }
  Start-Sleep -Milliseconds 150
}

function Assert-FrameColor {
  param([object]$Frame, [int[]]$Expected, [string]$Name)
  if ($Frame.button.Count -ne 4) { throw "$Name frame has no GPU readback color." }
  for ($index = 0; $index -lt 4; $index++) {
    if ([Math]::Abs([int]$Frame.button[$index] - $Expected[$index]) -gt 3) {
      throw "$Name button pixel mismatch; expected=$($Expected -join ',') actual=$($Frame.button -join ',')."
    }
  }
}

function Wait-ButtonState {
  param([scriptblock]$Predicate, [string]$Description)
  Wait-Record -Owner $script:activeOwner -Prefix "GPUI_WINDOWS_BUTTON_STATE " -Predicate $Predicate -Description $Description
}

function Wait-ButtonFrame {
  param([scriptblock]$Predicate, [string]$Description)
  Wait-Record -Owner $script:activeOwner -Prefix "GPUI_WINDOWS_BUTTON_FRAME " -Predicate $Predicate -Description $Description
}

function Close-ButtonProcess {
  param([object]$Owner)
  if ($null -eq $Owner) { return }
  $Owner.process.Refresh()
  if (-not $Owner.process.HasExited) {
    if ([WindowsButtonE2E.Win32]::IsOwnedWindow($Owner.hwnd, $Owner.pid)) {
      [void][WindowsButtonE2E.Win32]::CloseOwnedWindow($Owner.hwnd, $Owner.pid)
    }
    [void]$Owner.process.WaitForExit(5000)
  }
  $Owner.process.Refresh()
  if (-not $Owner.process.HasExited) { throw "Owned Button process $($Owner.pid) did not exit during bounded cleanup." }
  $processEvidence = $script:result.processes | Where-Object { $_.pid -eq $Owner.pid } | Select-Object -First 1
  if ($null -ne $processEvidence) { $processEvidence.exit_code = $Owner.process.ExitCode }
  Save-Result
}

function Initialize-Msvc {
  if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return }
  $envScript = Join-Path $repo "_build/tools/msvc-env.cmd"
  if (Test-Path -LiteralPath $envScript) {
    $lines = & $env:ComSpec /d /s /c "call `"$envScript`" && set"
  } else {
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    $vswhere = Join-Path $programFilesX86 "Microsoft Visual Studio/Installer/vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswhere)) { throw "MSVC environment script and vswhere.exe are unavailable." }
    $vsInstall = (& $vswhere -latest -products "*" -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
    if (-not $vsInstall) { throw "No Visual Studio installation with x64 C++ tools was found." }
    $vsDevCmd = Join-Path $vsInstall "Common7/Tools/VsDevCmd.bat"
    $lines = & $env:ComSpec /d /s /c "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
  }
  foreach ($line in $lines) {
    if ($line -match '^(PATH|INCLUDE|LIB)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process") }
  }
  if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) { throw "MSVC environment initialization did not make cl.exe available." }
}

try {
  if (-not (Test-Path -LiteralPath $moon)) {
    $moonCommand = Get-Command moon.exe -ErrorAction SilentlyContinue
    if ($null -eq $moonCommand) { throw "Pinned MoonBit executable not found: $moon" }
    $moon = $moonCommand.Source
    $moonHome = Split-Path (Split-Path $moon -Parent) -Parent
  }
  Initialize-Msvc
  $env:MOON_HOME = $moonHome
  $env:PATH = "$(Join-Path $moonHome 'bin');$env:PATH"
  $env:CL = if ([string]::IsNullOrWhiteSpace($env:CL)) { "/EHsc" } else { "$env:CL /EHsc" }
  $env:MOONBIT_NEW_NATIVE = "0"
  $script:result.build_log = Join-Path $runDir "build.log"
  $buildOutput = & $moon build --target native --deny-warn examples/windows_button 2>&1
  $buildStatus = $LASTEXITCODE
  $buildOutput | Set-Content -LiteralPath $script:result.build_log -Encoding utf8
  $buildOutput | Write-Output
  if ($buildStatus -ne 0) { throw "Pinned Windows Button native build failed with exit code $buildStatus." }
  $binary = Join-Path $repo "_build/native/debug/build/examples/windows_button/windows_button.exe"
  if (-not (Test-Path -LiteralPath $binary)) { throw "Expected executable was not produced: $binary" }
  $script:result.executable = $binary
  $script:result.executable_sha256 = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
  $script:result.toolchain = [ordered]@{
    moon_executable = $moon
    moon_sha256 = (Get-FileHash -LiteralPath $moon -Algorithm SHA256).Hash.ToLowerInvariant()
    moon_version = ((& $moon version --all 2>&1 | Out-String).Trim())
    msvc = (Get-Command cl.exe -ErrorAction SilentlyContinue).Source
  }
  Save-Result

  $desktop = [WindowsButtonE2E.Win32]::CheckInputDesktop()
  $foreground = [WindowsButtonE2E.Win32]::GetForegroundWindow().ToInt64()
  if (-not $desktop.Success -or $desktop.Name -cne "Default" -or $foreground -eq 0) {
    $script:result.status = "BLOCKED"
    $script:result.limitation = "Visible SendInput interaction, foreground ownership and GUI close/reopen are UNRUN because the active Default input desktop/foreground could not be acquired. D3D11 completed-frame pixel readback is qualified separately by scripts/test_windows.ps1 Button smoke."
    Add-Checkpoint "input_desktop_foreground_preflight" "BLOCKED" ([ordered]@{
      input_desktop_success = [bool]$desktop.Success
      input_desktop_name = $desktop.Name
      win32_error = [int]$desktop.LastError
      foreground_hwnd = $foreground
      physical_input = "UNRUN"
      gui_lifecycle = "UNRUN"
    })
    return
  }

  $first = Start-ButtonProcess "interactive"
  $initial = Wait-ButtonState { param($r) $r.presentable -and $r.visible } "initial presented Button state"
  $initialFrame = Wait-ButtonFrame { param($r) -not $r.pressed -and $r.enabled -and -not $r.loading } "initial completed GPU frame"
  Assert-FrameColor $initialFrame @(42, 71, 101, 255) "initial"
  if ($initial.semantic_button.name -cne "Run action" -or -not $initial.semantic_button.enabled) { throw "Initial shared semantic Button projection is incorrect." }
  Add-Checkpoint "initial_frame_and_semantics" "PASS" ([ordered]@{ state = $initial; frame = $initialFrame })

  Send-Key "tab_focus" 0x09 $false; Send-Key "tab_focus" 0x09 $true
  $focused = Wait-ButtonState { param($r) $r.focused } "Tab focus"
  Add-Checkpoint "tab_focus" "PASS" $focused

  Send-Key "enter_first_down" 0x0d $false
  Send-Key "enter_repeat_down" 0x0d $false
  Send-Key "enter_up" 0x0d $true
  $entered = Wait-ButtonState { param($r) $r.activations -eq 1 -and $r.repeat_keydowns -ge 1 } "one Enter activation and observed repeated keydown"
  if ($entered.activations -ne 1) { throw "Repeated Enter caused $($entered.activations) activations instead of one." }
  Add-Checkpoint "enter_repeat_one_activation" "PASS" $entered

  Send-Key "space_down" 0x20 $false
  $spaceDown = Wait-ButtonState { param($r) $r.pressed } "Space pressed state"
  $spacePixel = Wait-ButtonFrame { param($r) $r.pressed } "Space pressed completed pixel frame"
  Assert-FrameColor $spacePixel @(35, 77, 119, 255) "Space pressed"
  Add-Checkpoint "space_pressed_pixel" "PASS" ([ordered]@{ state = $spaceDown; frame = $spacePixel })
  Send-Key "space_up" 0x20 $true
  $spaceDone = Wait-ButtonState { param($r) $r.activations -eq 2 -and -not $r.pressed } "single Space activation"
  Add-Checkpoint "space_one_activation" "PASS" $spaceDone

  if (-not [WindowsButtonE2E.Win32]::MovePointer($first.hwnd, 144.0, 44.0, [double]$focusedAgain.scale)) { throw "Could not move pointer to the Button client center." }
  Start-Sleep -Milliseconds 250
  Send-Mouse "pointer_down" $false
  $pointerDown = Wait-ButtonState { param($r) $r.pressed } "pointer pressed state"
  $pointerPixel = Wait-ButtonFrame { param($r) $r.pressed } "pointer pressed completed pixel frame"
  Assert-FrameColor $pointerPixel @(35, 77, 119, 255) "pointer pressed"
  Add-Checkpoint "pointer_pressed_pixel" "PASS" ([ordered]@{ state = $pointerDown; frame = $pointerPixel })
  Send-Mouse "pointer_up" $true
  $pointerDone = Wait-ButtonState { param($r) $r.activations -eq 3 -and -not $r.pressed } "single pointer activation"
  Send-Mouse "unmatched_pointer_up" $true
  $unmatched = Wait-ButtonState { param($r) $r.unmatched_pointer_releases -ge 1 } "unmatched pointer release accounting"
  Add-Checkpoint "pointer_release_and_unmatched_release" "PASS" ([ordered]@{ activation = $pointerDone; unmatched = $unmatched })

  Send-Key "disable_d" 0x44 $false; Send-Key "disable_d" 0x44 $true
  $disabled = Wait-ButtonState { param($r) -not $r.enabled } "disabled state"
  $disabledFrame = Wait-ButtonFrame { param($r) -not $r.enabled } "disabled pixel frame"
  Assert-FrameColor $disabledFrame @(47, 52, 60, 255) "disabled"
  if ($disabled.activations -ne 3 -or $disabled.semantic_button.enabled) { throw "Disabled Button accepted an action or semantic enabled state diverged." }
  Add-Checkpoint "disabled_state_and_pixel" "PASS" ([ordered]@{ state = $disabled; frame = $disabledFrame })

  Send-Key "enable_d" 0x44 $false; Send-Key "enable_d" 0x44 $true
  $enabled = Wait-ButtonState { param($r) $r.enabled } "enabled state"
  Send-Key "tab_refocus" 0x09 $false; Send-Key "tab_refocus" 0x09 $true
  $focusedAgain = Wait-ButtonState { param($r) $r.focused } "Button focus restored after reenable"
  Send-Key "loading_l" 0x4c $false; Send-Key "loading_l" 0x4c $true
  $loading = Wait-ButtonState { param($r) $r.loading } "loading state"
  $loadingFrame = Wait-ButtonFrame { param($r) $r.loading } "loading pixel frame"
  Assert-FrameColor $loadingFrame @(55, 70, 88, 255) "loading"
  Send-Key "loading_space_down" 0x20 $false; Send-Key "loading_space_up" 0x20 $true
  $loadingInert = Wait-ButtonState { param($r) $r.loading -and -not $r.pressed } "loading rejects keyboard activation"
  if ($loadingInert.activations -ne 3) { throw "Loading Button accepted an activation." }
  Add-Checkpoint "loading_state_and_pixel" "PASS" ([ordered]@{ enabled = $enabled; focused = $focusedAgain; state = $loadingInert; frame = $loadingFrame })

  Send-Key "reset_r" 0x52 $false; Send-Key "reset_r" 0x52 $true
  $reset = Wait-ButtonState { param($r) $r.activations -eq 0 -and -not $r.loading -and -not $r.focused } "reset session"
  Add-Checkpoint "reset_session" "PASS" $reset

  Send-Key "resize_tab" 0x09 $false; Send-Key "resize_tab" 0x09 $true
  $resizeFocused = Wait-ButtonState { param($r) $r.focused } "focus before resize cancellation"
  Send-Key "resize_space_down" 0x20 $false
  $resizePressed = Wait-ButtonState { param($r) $r.pressed } "armed press before undersized resize"
  $scale = [double]$resizePressed.scale
  $smallWidth = [int][Math]::Round(120 * $scale)
  $smallHeight = [int][Math]::Round(80 * $scale)
  if (-not [WindowsButtonE2E.Win32]::ResizeClient($first.hwnd, $smallWidth, $smallHeight)) { throw "SetWindowPos failed for undersized client resize; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $hidden = Wait-ButtonState { param($r) $r.visible -eq $false -and $r.width -lt 160 -and $r.height -ge 68 } "positive undersized resize hides Button target"
  Send-Key "stale_space_up_after_resize" 0x20 $true
  $staleRelease = Wait-ButtonState { param($r) $r.visible -eq $false -and -not $r.pressed } "stale release after resize"
  if ($staleRelease.activations -ne 0) { throw "Stale release after resize activated the hidden Button." }
  $restoreWidth = [int][Math]::Round(640 * $scale)
  $restoreHeight = [int][Math]::Round(240 * $scale)
  if (-not [WindowsButtonE2E.Win32]::ResizeClient($first.hwnd, $restoreWidth, $restoreHeight)) { throw "SetWindowPos failed while restoring Button viewport." }
  $restored = Wait-ButtonState { param($r) $r.visible -and $r.width -ge 640 -and -not $r.focused -and -not $r.pressed } "viewport restore without focus or replay"
  if ($restored.activations -ne 0) { throw "Resize restore replayed an earlier activation." }
  Add-Checkpoint "undersized_resize_cancel_restore" "PASS" ([ordered]@{ focused = $resizeFocused; pressed = $resizePressed; hidden = $hidden; stale_release = $staleRelease; restored = $restored })

  Send-Key "escape_close" 0x1b $false; Send-Key "escape_close" 0x1b $true
  Close-ButtonProcess $first
  Add-Checkpoint "escape_close_cleanup" "PASS" ([ordered]@{ process_id = $first.pid; exit_code = $first.process.ExitCode })

  $second = Start-ButtonProcess "reopened"
  $reopened = Wait-ButtonState { param($r) $r.presentable -and $r.visible -and $r.activations -eq 0 -and -not $r.focused } "fresh Button state after process reopen"
  $reopenedFrame = Wait-ButtonFrame { param($r) -not $r.pressed -and $r.enabled -and -not $r.loading } "reopened completed GPU frame"
  Assert-FrameColor $reopenedFrame @(42, 71, 101, 255) "reopened"
  Add-Checkpoint "fresh_process_reopen" "PASS" ([ordered]@{ state = $reopened; frame = $reopenedFrame })
  Send-Key "reopened_escape_close" 0x1b $false; Send-Key "reopened_escape_close" 0x1b $true
  Close-ButtonProcess $second
  Add-Checkpoint "reopened_cleanup" "PASS" ([ordered]@{ process_id = $second.pid; exit_code = $second.process.ExitCode })

  $script:result.status = "PASS"
} catch {
  $script:result.status = "FAIL"
  $script:result.failure = [ordered]@{
    stage = if ($script:result.checkpoints.Count -gt 0) { $script:result.checkpoints[-1].name } else { "startup" }
    message = $_.Exception.Message
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  throw
} finally {
  foreach ($owner in $script:owners) {
    try { Close-ButtonProcess $owner } catch {
      $script:result.cleanup_error = $_.Exception.Message
      if ($script:result.status -eq "PASS") { $script:result.status = "FAIL" }
    }
  }
  Save-Result
  Write-Output "Button E2E evidence: $runDir"
  Write-Output "Result status: $($script:result.status)"
}
