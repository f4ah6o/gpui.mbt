[CmdletBinding()]
param(
  [ValidateSet("Validate", "Preflight", "Run")][string]$Mode = "Run",
  [switch]$NoBuild,
  [string]$OutputDirectory,
  [ValidateRange(5, 180)][int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$repo = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repo
$interop = Join-Path $PSScriptRoot "windows_command_palette_e2e_native.cs"
$buildRoot = Join-Path $repo "_build/windows-command-palette"
$binary = Join-Path $buildRoot "bin/windows-command-palette.exe"
$buildManifestPath = Join-Path $buildRoot "manifest.json"
$runId = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
$evidenceRoot = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
  Join-Path $buildRoot "e2e"
} else {
  [IO.Path]::GetFullPath($OutputDirectory)
}
$runDir = Join-Path $evidenceRoot $runId
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
Add-Type -Path $interop -ErrorAction Stop
if ([IntPtr]::Size -ne 8 -or [PaletteE2E.Win32]::InputStructureSize() -ne 40) {
  throw "This driver requires x64 PowerShell and sizeof(INPUT)==40; process=$([IntPtr]::Size), INPUT=$([PaletteE2E.Win32]::InputStructureSize())."
}

$script:result = [ordered]@{
  schema_version = 1
  run_id = $runId
  mode = $Mode
  status = "IN_PROGRESS"
  evidence_directory = $runDir
  started_at_utc = [DateTime]::UtcNow.ToString("o")
  source_head = $null
  source_clean = $null
  executable = $binary
  executable_sha256 = $null
  build_manifest = $buildManifestPath
  host = [ordered]@{
    os = [Environment]::OSVersion.VersionString
    architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
    powershell = $PSVersionTable.PSVersion.ToString()
    process_bits = [IntPtr]::Size * 8
    input_structure_size = [PaletteE2E.Win32]::InputStructureSize()
  }
  input_desktop = $null
  input_desktop_checks = @()
  dpi_context = $null
  fixtures = @()
  focus_changes = @()
  input_events = @()
  input_event_total_basis = $null
  input_event_totals_error = $null
  window_discovery = @()
  captures = @()
  capture_settlements = @()
  stages = @()
  ime = [ordered]@{ original_layout = $null; original_state = $null; japanese_layout = $null; restoration = $null }
  cleanup = @()
  failure = $null
  limitations = @(
    "GPU READBACK records are three point samples; BMP files are separate full visible-client captures.",
    "ImmGetCandidateWindow records requested CANDIDATEFORM adapter geometry; it does not prove visible popup placement.",
    "BMP captures require a human pixel audit before they qualify search, caret, active/disabled rows, scrolling, or clipping.",
    "Candidate contents/highlight and UI Automation transport remain UNRUN/UNSUPPORTED."
  )
}
$script:owners = [System.Collections.Generic.List[object]]::new()
$script:primary = $null
$script:aux = $null
$script:imeOriginal = $null
$script:japaneseLayout = [IntPtr]::Zero
$script:loadedJapaneseByDriver = $false
$script:loadedJapaneseHandle = [IntPtr]::Zero
$script:dpiPrevious = [IntPtr]::Zero
$script:activeStage = $null
$script:unrun = $false
$script:expectedGpuiWindowClass = "gpui_mbt_windows_host_v1"

function Save-Result {
  $script:result.updated_at_utc = [DateTime]::UtcNow.ToString("o")
  $script:result | ConvertTo-Json -Depth 24 | Set-Content -LiteralPath (Join-Path $runDir "result.json") -Encoding utf8
}

function Add-Stage {
  param([string]$Name, [string]$Status, [object]$Details = $null)
  $script:result.stages += [ordered]@{
    name = $Name
    status = $Status
    details = $Details
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  Save-Result
}

function Start-Stage { param([string]$Name) $script:activeStage = $Name }

function Assert-Condition {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Add-InputEvidence {
  param([string]$Action, [ushort[]]$VirtualKeys, [object]$NativeResult)
  $script:result.input_events += [ordered]@{
    action = $Action
    virtual_keys = @($VirtualKeys)
    requested = [uint32]$NativeResult.Requested
    inserted = [uint32]$NativeResult.Inserted
    input_size = [int]$NativeResult.InputSize
    win32_error = [int]$NativeResult.LastError
    at_utc = [DateTime]::UtcNow.ToString("o")
  }
  Save-Result
}

function Get-InputEventTotals {
  param([AllowNull()][object]$Events)
  if ($null -eq $Events -or $Events -isnot [System.Collections.IList]) {
    throw "Input-event evidence must be an explicit list, including when empty."
  }
  [long]$requestedTotal = 0
  [long]$insertedTotal = 0
  foreach ($event in $Events) {
    if ($event -isnot [System.Collections.IDictionary] -or
        -not $event.Contains("action") -or $event.action -isnot [string] -or
        -not $event.Contains("virtual_keys") -or $event.virtual_keys -isnot [System.Collections.IList] -or
        -not $event.Contains("requested") -or -not $event.Contains("inserted")) {
      throw "Input-event evidence is missing its action, virtual key list, requested count, or inserted count."
    }
    if (-not (Test-ExactInteger $event.requested 1 2147483647) -or
        -not (Test-ExactInteger $event.inserted 0 2147483647) -or
        [long]$event.inserted -gt [long]$event.requested -or
        $event.virtual_keys.Count -ne [long]$event.requested) {
      throw "Input-event evidence has an invalid count or virtual-key payload for '$($event.action)'."
    }
    foreach ($virtualKey in $event.virtual_keys) {
      if (-not (Test-ExactInteger $virtualKey 0 65535)) { throw "Input-event evidence has an invalid virtual-key value for '$($event.action)'." }
    }
    if ($requestedTotal -gt ([long]::MaxValue - [long]$event.requested) -or
        $insertedTotal -gt ([long]::MaxValue - [long]$event.inserted)) {
      throw "Input-event evidence total exceeds Int64 range."
    }
    $requestedTotal += [long]$event.requested
    $insertedTotal += [long]$event.inserted
  }
  return [pscustomobject]@{
    batch_count = [int]$Events.Count
    requested_keyboard_events_total = $requestedTotal
    inserted_keyboard_events_total = $insertedTotal
    basis = "sum of requested/inserted counts for input_events primary SendInput batches; targeted partial-release attempts remain separately recorded under failure.targeted_release."
  }
}

function Get-RecordPayload {
  param([string]$Line, [string]$Prefix)
  if (-not $Line.StartsWith($Prefix, [StringComparison]::Ordinal)) { return $null }
  try {
    $value = ConvertFrom-Json -InputObject $Line.Substring($Prefix.Length) -AsHashtable -ErrorAction Stop
    if ($value -is [System.Collections.IDictionary]) { return $value }
  } catch {}
  return $null
}

function Test-ExactInteger {
  param([object]$Value, [long]$Minimum, [long]$Maximum)
  if ($null -eq $Value -or $Value -isnot [ValueType] -or $Value -is [bool]) { return $false }
  try { $number = [double]$Value } catch { return $false }
  return [double]::IsFinite($number) -and $number -eq [Math]::Truncate($number) -and $number -ge $Minimum -and $number -le $Maximum
}

function Test-PositiveFinite {
  param([object]$Value)
  if ($null -eq $Value -or $Value -isnot [ValueType] -or $Value -is [bool]) { return $false }
  try { $number = [double]$Value } catch { return $false }
  return [double]::IsFinite($number) -and $number -gt 0
}

function Test-FrameTuple {
  param([System.Collections.IDictionary]$Accepted, [System.Collections.IDictionary]$State, [System.Collections.IDictionary]$Complete, [System.Collections.IDictionary]$Readback)
  foreach ($record in @($Accepted, $State, $Complete, $Readback)) {
    if (-not (Test-ExactInteger $record.presentation 1 2147483647)) { return $false }
  }
  if (-not (Test-ExactInteger $Accepted.open_epoch 0 2147483647) -or
      -not (Test-ExactInteger $State.open_epoch 0 2147483647) -or
      -not (Test-ExactInteger $Complete.open_epoch 0 2147483647) -or
      $Accepted.open -isnot [bool] -or $State.open -isnot [bool] -or
      $Accepted.query -isnot [string] -or
      -not (Test-ExactInteger $Accepted.matches 0 2147483647) -or
      -not (Test-ExactInteger $State.matches 0 2147483647) -or
      -not (Test-ExactInteger $Accepted.visible_count 0 8) -or
      -not (Test-ExactInteger $State.visible_count 0 8) -or
      -not (Test-ExactInteger $Complete.visible_count 0 8) -or
      -not (Test-ExactInteger $Complete.event_sequence 1 9223372036854775807) -or
      -not (Test-ExactInteger $Readback.frame_event_sequence 1 9223372036854775807)) { return $false }
  if ([long]$Accepted.presentation -ne [long]$State.presentation -or
      [long]$State.presentation -ne [long]$Complete.presentation -or
      [long]$Complete.presentation -ne [long]$Readback.presentation -or
      [long]$Accepted.open_epoch -ne [long]$State.open_epoch -or
      [long]$State.open_epoch -ne [long]$Complete.open_epoch -or
      [bool]$Accepted.open -ne [bool]$State.open -or
      [string]$Accepted.query -cne [string]$State.query -or
      [string]$State.query -cne [string]$Complete.query -or
      [long]$Accepted.matches -ne [long]$State.matches -or
      [long]$Accepted.visible_count -ne [long]$State.visible_count -or
      [long]$State.visible_count -ne [long]$Complete.visible_count -or
      [long]$Complete.event_sequence -ne [long]$Readback.frame_event_sequence) { return $false }
  if ($State.query -isnot [string] -or $Complete.query -isnot [string] -or
      [string]$State.query -cne [string]$Complete.query -or
      -not (Test-ExactInteger $State.visible_count 0 8) -or
      -not (Test-ExactInteger $State.matches 0 2147483647) -or
      -not $State.Contains("active_index") -or
      -not $State.Contains("active_id") -or
      -not $Complete.Contains("active_id")) { return $false }
  $activeIndex = $State["active_index"]
  if ($null -ne $activeIndex -and
      ($activeIndex -isnot [System.Collections.IList] -or $activeIndex.Count -ne 1 -or
       -not (Test-ExactInteger $activeIndex[0] 0 2147483647))) { return $false }
  if ([bool]$State.open) {
    if ($null -eq $State.active_id) {
      if ($null -ne $Complete.active_id -or [long]$State.visible_count -ne 0 -or $null -ne $activeIndex) { return $false }
    } else {
      if ([string]$State.active_id -cne [string]$Complete.active_id -or $null -eq $activeIndex -or
          $State.semantic -isnot [System.Collections.IDictionary] -or $State.semantic.options -isnot [System.Collections.IList]) { return $false }
      $matchingOptions = @($State.semantic.options | Where-Object {
        (Test-ExactInteger $_.index 0 2147483647) -and [long]$_.index -eq [long]$activeIndex[0] -and [string]$_.id -ceq [string]$State.active_id
      })
      if ($matchingOptions.Count -ne 1) { return $false }
    }
  } elseif ($null -ne $Complete.active_id -and [string]$Complete.active_id -notmatch '^palette\.command\.[0-9]+$') { return $false }
  $stateViewport = $State.viewport; $viewport = $Readback.viewport
  if ($stateViewport -isnot [System.Collections.IDictionary] -or $viewport -isnot [System.Collections.IDictionary] -or
      -not (Test-PositiveFinite $stateViewport.logical_width) -or
      -not (Test-PositiveFinite $stateViewport.logical_height) -or
      -not (Test-PositiveFinite $stateViewport.scale) -or
      -not (Test-PositiveFinite $viewport.logical_width) -or
      -not (Test-PositiveFinite $viewport.logical_height) -or
      -not (Test-PositiveFinite $viewport.scale) -or
      [double]$stateViewport.logical_width -ne [double]$viewport.logical_width -or
      [double]$stateViewport.logical_height -ne [double]$viewport.logical_height -or
      [double]$stateViewport.scale -ne [double]$viewport.scale) { return $false }
  $pixelWidth = [int][Math]::Truncate([double]$viewport.logical_width * [double]$viewport.scale)
  $pixelHeight = [int][Math]::Truncate([double]$viewport.logical_height * [double]$viewport.scale)
  if ($pixelWidth -lt 4 -or $pixelHeight -lt 4) { return $false }
  $points = @("1,1", "$([int][Math]::Truncate($pixelWidth / 4)),$([int][Math]::Truncate($pixelHeight / 3))", "$($pixelWidth - 2),$($pixelHeight - 2)")
  if ($Readback.samples -isnot [System.Collections.IList] -or $Readback.samples.Count -ne 3) { return $false }
  for ($i = 0; $i -lt 3; $i++) {
    $sample = $Readback.samples[$i]
    if ($sample -isnot [System.Collections.IDictionary] -or $sample.point -isnot [System.Collections.IList] -or
        $sample.point.Count -ne 2 -or $sample.rgba -isnot [System.Collections.IList] -or $sample.rgba.Count -ne 4) { return $false }
    if ("$($sample.point[0]),$($sample.point[1])" -ne $points[$i]) { return $false }
    foreach ($channel in $sample.rgba) { if (-not (Test-ExactInteger $channel 0 255)) { return $false } }
  }
  return $true
}

function Get-LatestFrame {
  param([string]$LogPath)
  if (-not (Test-Path -LiteralPath $LogPath)) { return $null }
  $lines = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
  if (@($lines | Where-Object { $_.StartsWith("GPUI_WINDOWS_COMMAND_PALETTE_READBACK_UNAVAILABLE ", [StringComparison]::Ordinal) }).Count -gt 0) {
    throw "Fixture emitted READBACK_UNAVAILABLE; see $LogPath."
  }
  $accepted = @{}; $states = @{}; $completed = @{}; $readbacks = @{}
  foreach ($line in $lines) {
    foreach ($kind in @("ACCEPTED", "STATE", "COMPLETE", "READBACK")) {
      $prefix = "GPUI_WINDOWS_COMMAND_PALETTE_$kind "
      if (-not $line.StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
      $record = Get-RecordPayload $line $prefix
      if ($null -eq $record -or -not (Test-ExactInteger $record.presentation 1 2147483647)) { throw "Malformed $kind observer record in $LogPath." }
      switch ($kind) {
        "ACCEPTED" { $accepted[[string]$record.presentation] = $record }
        "STATE" { $states[[string]$record.presentation] = $record }
        "COMPLETE" { $completed[[string]$record.presentation] = $record }
        "READBACK" { $readbacks[[string]$record.presentation] = $record }
      }
      break
    }
  }
  if ($accepted.Count -eq 0 -and $states.Count -eq 0) { return $null }
  $published = @($accepted.Keys + $states.Keys | ForEach-Object { [long]$_ } | Sort-Object -Unique)
  $latest = [string]($published[-1])
  if (-not $accepted.ContainsKey($latest) -or -not $states.ContainsKey($latest) -or
      -not $completed.ContainsKey($latest) -or -not $readbacks.ContainsKey($latest)) { return $null }
  $a = $accepted[$latest]; $s = $states[$latest]; $c = $completed[$latest]; $r = $readbacks[$latest]
  if (-not (Test-FrameTuple $a $s $c $r)) { return $null }
  return [pscustomobject]@{ Accepted = $a; State = $s; Complete = $c; Readback = $r }
}

function Get-LogTail {
  param([AllowNull()][object]$Text, [bool]$Exists, [int]$MaximumLength = 1800)
  if (-not $Exists) { return "<missing log>" }
  if ($null -eq $Text -or [string]::IsNullOrEmpty([string]$Text)) { return "<empty log>" }
  $value = [string]$Text
  return $value.Substring([Math]::Max(0, $value.Length - $MaximumLength))
}

function Format-ExitedChildDiagnostic {
  param(
    [string]$ProcessCheckError,
    [AllowNull()][object]$Stdout,
    [bool]$StdoutExists,
    [AllowNull()][object]$Stderr,
    [bool]$StderrExists
  )
  $stdoutTail = Get-LogTail $Stdout $StdoutExists
  $stderrTail = Get-LogTail $Stderr $StderrExists
  return "Owned fixture exited before predicate. process check=$ProcessCheckError; stdout tail=$stdoutTail; stderr tail=$stderrTail."
}

function Get-FrameIdentity {
  param([object]$Frame)
  if ($null -eq $Frame) { return $null }
  return [ordered]@{
    presentation = [long]$Frame.State.presentation
    event_sequence = [long]$Frame.Complete.event_sequence
    state = $Frame.State
    accepted = $Frame.Accepted
    completed = $Frame.Complete
    readback = $Frame.Readback
  } | ConvertTo-Json -Depth 20 -Compress
}

function Get-CaptureSemanticIdentity {
  param([System.Collections.IDictionary]$State)
  $ownerIdentity = $null
  if ($null -ne $State.native_owner) {
    $ownerIdentity = [ordered]@{
      owner_generation = $State.native_owner.owner_generation
      palette_open_epoch = $State.native_owner.palette_open_epoch
      native_epoch = $State.native_owner.native_epoch
      sequence = $State.native_owner.sequence
      composing = $State.native_owner.composing
    }
  }
  $nativeCountersIdentity = $null
  if ($null -ne $State.native_counters) {
    # update is a presentation-side count and can advance while an otherwise
    # unchanged accepted frame is settling. All record/fence counters remain
    # part of the state so key leaks or rejected native records cannot be
    # adopted as equivalent pixels.
    $nativeCountersIdentity = [ordered]@{
      begin = $State.native_counters.begin
      cancel = $State.native_counters.cancel
      end = $State.native_counters.end
      records = $State.native_counters.records
      stale_records = $State.native_counters.stale_records
      rejected_records = $State.native_counters.rejected_records
    }
  }
  $selection = if ($null -ne $State.selection) { [ordered]@{ anchor = $State.selection.anchor; head = $State.selection.head } } else { $null }
  $caret = if ($null -ne $State.caret) { [ordered]@{ x = $State.caret.x; y = $State.caret.y; width = $State.caret.width; height = $State.caret.height } } else { $null }
  $viewport = if ($null -ne $State.viewport) { [ordered]@{ logical_width = $State.viewport.logical_width; logical_height = $State.viewport.logical_height; scale = $State.viewport.scale; font_family = $State.viewport.font_family; font_size = $State.viewport.font_size } } else { $null }
  $activeIndexIdentity = if ($null -eq $State.active_index) { $null } else { @($State.active_index) }
  $options = if ($null -ne $State.semantic -and $null -ne $State.semantic.options) { @($State.semantic.options) } else { @() }
  return [ordered]@{
    open = $State.open
    open_epoch = $State.open_epoch
    query = $State.query
    field_text = $State.field_text
    committed_text = $State.committed_text
    composing = $State.composing
    selection = $selection
    matches = $State.matches
    active_id = $State.active_id
    active_index = $activeIndexIdentity
    visible_start = $State.visible_start
    visible_count = $State.visible_count
    actions = $State.actions
    last_action = $State.last_action
    background_presses = $State.background_presses
    background_releases = $State.background_releases
    guarded_presses = $State.guarded_presses
    guarded_releases = $State.guarded_releases
    focus_owner = $State.focus_owner
    field_focused = $State.field_focused
    experimental_imm32 = $State.experimental_imm32
    caret = $caret
    viewport = $viewport
    semantic_options = $options
    native_owner_identity = $ownerIdentity
    native_counters_identity = $nativeCountersIdentity
  } | ConvertTo-Json -Depth 20 -Compress
}

function Test-CaptureSemanticState {
  param([System.Collections.IDictionary]$Actual, [System.Collections.IDictionary]$Expected)
  return (Get-CaptureSemanticIdentity $Actual) -ceq (Get-CaptureSemanticIdentity $Expected)
}

function Test-CandidateGeometryMatchesFrame {
  param([object]$Extra, [object]$Frame)
  if ($null -eq $Extra -or -not $Extra.source_semantic_identity) { return $true }
  return [string]::Equals([string]$Extra.source_semantic_identity, (Get-CaptureSemanticIdentity $Frame.State), [StringComparison]::Ordinal)
}

function Get-CaptureBracketDecision {
  param([object]$Before, [object]$After, [System.Collections.IDictionary]$ExpectedState)
  if ($null -eq $Before) { return "RETRY_BEFORE_FRAME_PENDING" }
  if (-not (Test-CaptureSemanticState $Before.State $ExpectedState)) { return "SEMANTIC_STATE_CHANGED_BEFORE_CAPTURE" }
  if ($null -eq $After) { return "RETRY_AFTER_FRAME_PENDING" }
  if (-not (Test-CaptureSemanticState $After.State $ExpectedState)) { return "SEMANTIC_STATE_CHANGED_DURING_CAPTURE" }
  if ((Get-FrameIdentity $Before) -ceq (Get-FrameIdentity $After)) { return "STABLE" }
  return "RETRY_NEWER_EQUIVALENT_FRAME"
}

function Invoke-CaptureStableRetry {
  param(
    [object]$Owner,
    [string]$Name,
    [object]$ExpectedFrame,
    [object]$Extra,
    [scriptblock]$FrameReader,
    [scriptblock]$CaptureAttempt,
    [int]$TimeoutMilliseconds = 3000,
    [int]$MaximumPolls = 20,
    [int]$PollIntervalMilliseconds = 50
  )
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $attempts = [System.Collections.Generic.List[object]]::new()
  $captureCount = 0
  for ($poll = 1; $poll -le $MaximumPolls -and $watch.ElapsedMilliseconds -lt $TimeoutMilliseconds; $poll++) {
    $frame = & $FrameReader $Owner
    if ($null -eq $frame) {
      [void]$attempts.Add([ordered]@{ poll = $poll; status = "WAITING_FOR_COMPLETE_FRAME" })
    } elseif (-not (Test-CaptureSemanticState $frame.State $ExpectedFrame.State)) {
      [void]$attempts.Add([ordered]@{ poll = $poll; status = "SEMANTIC_STATE_CHANGED"; presentation = [long]$frame.State.presentation; frame_identity = Get-FrameIdentity $frame })
      return [pscustomobject]@{ status = "SEMANTIC_STATE_CHANGED"; frame = $frame; capture = $null; attempts = @($attempts.ToArray()); reason = "Latest complete frame no longer matches the requested semantic state." }
    } else {
      $captureCount++
      try {
        $capture = & $CaptureAttempt $Owner $Name $frame $ExpectedFrame $Extra $captureCount
      } catch {
        $failure = [ordered]@{
          poll = $poll
          status = "CAPTURE_EXCEPTION"
          capture_attempt = $captureCount
          presentation = [long]$frame.State.presentation
          frame_identity = Get-FrameIdentity $frame
          error = $_.Exception.Message
        }
        $attemptBitmapName = if ($captureCount -eq 1) { "$Name.bmp" } else { "$Name.attempt-$captureCount.bmp" }
        $attemptBitmapPath = Join-Path $runDir $attemptBitmapName
        if (Test-Path -LiteralPath $attemptBitmapPath) {
          $failure.bitmap = $attemptBitmapPath
          try { $failure.bitmap_sha256 = (Get-FileHash -LiteralPath $attemptBitmapPath -Algorithm SHA256).Hash.ToLowerInvariant() }
          catch { $failure.bitmap_hash_error = $_.Exception.Message }
        }
        $attemptManifest = Join-Path $runDir "$Name.capture-$captureCount.failure.json"
        $failure.attempt_manifest = $attemptManifest
        try { $failure | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $attemptManifest -Encoding utf8 }
        catch { $failure.attempt_manifest_error = $_.Exception.Message }
        [void]$attempts.Add($failure)
        return [pscustomobject]@{ status = "FAIL"; frame = $frame; capture = $null; attempts = @($attempts.ToArray()); reason = "Capture attempt failed terminally: $($_.Exception.Message)" }
      }
      $attempts.Add([ordered]@{ poll = $poll; status = [string]$capture.status; presentation = [long]$frame.State.presentation; frame_identity = Get-FrameIdentity $frame; reason = $capture.reason })
      if ($capture.status -eq "STABLE") {
        return [pscustomobject]@{ status = "PASS"; frame = $frame; capture = $capture; attempts = @($attempts.ToArray()); reason = $null }
      }
      if ($capture.status -in @("SEMANTIC_STATE_CHANGED_BEFORE_CAPTURE", "SEMANTIC_STATE_CHANGED_DURING_CAPTURE")) {
        return [pscustomobject]@{ status = "SEMANTIC_STATE_CHANGED"; frame = $frame; capture = $capture; attempts = @($attempts.ToArray()); reason = [string]$capture.reason }
      }
      if ($capture.status -notin @("RETRY_BEFORE_FRAME_PENDING", "RETRY_AFTER_FRAME_PENDING", "RETRY_NEWER_EQUIVALENT_FRAME")) {
        return [pscustomobject]@{ status = "FAIL"; frame = $frame; capture = $capture; attempts = @($attempts.ToArray()); reason = "Capture attempt returned unexpected status '$($capture.status)'." }
      }
    }
    if ($PollIntervalMilliseconds -gt 0) { Start-Sleep -Milliseconds $PollIntervalMilliseconds }
  }
  return [pscustomobject]@{ status = "TIMEOUT"; frame = $null; capture = $null; attempts = @($attempts.ToArray()); reason = "No stable equivalent completed frame within ${TimeoutMilliseconds}ms and $MaximumPolls polls." }
}

function Assert-OwnedProcessIdentity {
  param([object]$Owner)
  if ($null -eq $Owner) { throw "Owned process record is missing." }
  $process = Get-Process -Id $Owner.pid -ErrorAction Stop
  if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$Owner.start_ticks) { throw "Owned PID $($Owner.pid) was reused." }
  $image = [PaletteE2E.Win32]::QueryProcessImagePath([uint32]$Owner.pid)
  if (-not $image.Success -or [string]::IsNullOrWhiteSpace($image.Path) -or
      -not [string]::Equals([IO.Path]::GetFullPath($image.Path), [IO.Path]::GetFullPath($Owner.executable), [StringComparison]::OrdinalIgnoreCase)) {
    $errorCode = if ($image.Success) { 0 } else { [int]$image.LastError }
    throw "Owned PID $($Owner.pid) executable path changed or could not be queried; Win32=$errorCode."
  }
  if ($Owner.executable_sha256) {
    $actualHash = (Get-FileHash -LiteralPath $image.Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if (-not [string]::Equals($actualHash, [string]$Owner.executable_sha256, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Owned PID $($Owner.pid) executable hash changed."
    }
  }
  return $process
}

function Assert-OwnedProcess {
  param([object]$Owner)
  $null = Assert-OwnedProcessIdentity $Owner
  $hwnd = [IntPtr]::new([long]$Owner.hwnd)
  if ($hwnd -eq [IntPtr]::Zero -or -not [PaletteE2E.Win32]::IsWindow($hwnd) -or -not [PaletteE2E.Win32]::IsWindowVisible($hwnd)) {
    throw "Owned HWND is no longer a visible window."
  }
  $actualPid = [uint32]0
  [void][PaletteE2E.Win32]::GetWindowThreadProcessId($hwnd, [ref]$actualPid)
  if ([long]$actualPid -ne [long]$Owner.pid) { throw "Owned HWND PID mismatch." }
  $className = [PaletteE2E.Win32]::GetWindowClassName($hwnd)
  if (-not [string]::Equals($className, $script:expectedGpuiWindowClass, [StringComparison]::Ordinal)) {
    throw "Owned HWND class mismatch: expected '$($script:expectedGpuiWindowClass)', got '$className'."
  }
  return $hwnd
}

function Get-OwnedGpuiWindowCandidates {
  param([object[]]$Windows, [long]$OwnerPid)
  return @($Windows | Where-Object {
    $_.Visible -and [long]$_.ProcessId -eq $OwnerPid -and [long]$_.Handle -ne 0 -and
      [string]::Equals([string]$_.ClassName, $script:expectedGpuiWindowClass, [StringComparison]::Ordinal)
  })
}

function Get-OwnedWindowDiagnostics {
  param([object[]]$Windows, [long]$OwnerPid)
  return @($Windows | Where-Object { [long]$_.ProcessId -eq $OwnerPid } | ForEach-Object {
    [ordered]@{
      hwnd = [long]$_.Handle
      thread_id = [uint32]$_.ThreadId
      visible = [bool]$_.Visible
      class_name = [string]$_.ClassName
      title = [string]$_.Title
      bounds = [ordered]@{ left = [int]$_.Bounds.Left; top = [int]$_.Bounds.Top; right = [int]$_.Bounds.Right; bottom = [int]$_.Bounds.Bottom }
    }
  })
}

function Select-OwnedGpuiWindow {
  param([object[]]$Windows, [long]$OwnerPid)
  $candidates = @(Get-OwnedGpuiWindowCandidates $Windows $OwnerPid)
  if ($candidates.Count -gt 1) {
    $handles = @($candidates | ForEach-Object { '0x{0:X}' -f [long]$_.Handle }) -join ', '
    throw "Ambiguous owned GPUI HWNDs for PID $($OwnerPid): $handles."
  }
  if ($candidates.Count -eq 0) { return $null }
  return $candidates[0]
}

function Discover-OwnedGpuiWindow {
  param([object]$Owner, [switch]$RecordDiagnostics)
  $null = Assert-OwnedProcessIdentity $Owner
  $windows = [PaletteE2E.Win32]::VisibleWindows()
  $diagnostics = @(Get-OwnedWindowDiagnostics $windows ([long]$Owner.pid))
  if ($RecordDiagnostics) {
    $Owner.window_candidates = $diagnostics
    $script:result.window_discovery += [ordered]@{ role = $Owner.role; pid = $Owner.pid; candidates = $diagnostics; at_utc = [DateTime]::UtcNow.ToString("o") }
    Save-Result
  }
  $candidate = Select-OwnedGpuiWindow $windows ([long]$Owner.pid)
  if ($null -eq $candidate) { return $null }
  $Owner.hwnd = [long]$candidate.Handle
  $Owner.thread_id = [uint32]$candidate.ThreadId
  $Owner.title = [string]$candidate.Title
  $Owner.window_class = [string]$candidate.ClassName
  $null = Assert-OwnedProcess $Owner
  Save-Result
  return $candidate
}

function Assert-OwnedWindowDiscoveryRegressionTests {
  $ownerPid = 4488L
  $rect = [PaletteE2E.RECT]::new()
  $windows = @(
    [pscustomobject]@{ Handle = 3213606L; ProcessId = [uint32]$ownerPid; ThreadId = 91; Visible = $true; Title = ""; ClassName = "gpui_mbt_windows_host_v1"; Bounds = $rect },
    [pscustomobject]@{ Handle = 3475810L; ProcessId = [uint32]$ownerPid; ThreadId = 92; Visible = $true; Title = "C:\fixture\windows-command-palette.exe"; ClassName = "ConsoleWindowClass"; Bounds = $rect },
    [pscustomobject]@{ Handle = 410L; ProcessId = 7777; ThreadId = 93; Visible = $true; Title = "decoy"; ClassName = "gpui_mbt_windows_host_v1"; Bounds = $rect },
    [pscustomobject]@{ Handle = 411L; ProcessId = [uint32]$ownerPid; ThreadId = 94; Visible = $false; Title = "hidden"; ClassName = "gpui_mbt_windows_host_v1"; Bounds = $rect }
  )
  $selected = Select-OwnedGpuiWindow $windows $ownerPid
  if ($null -eq $selected -or [long]$selected.Handle -ne 3213606L -or $selected.Title -ne "") {
    throw "Window-discovery regression failed: blank-caption GPUI window was not selected over same-PID console/other-PID/invisible decoys."
  }
  $diagnostics = @(Get-OwnedWindowDiagnostics $windows $ownerPid)
  if ($diagnostics.Count -ne 3 -or @($diagnostics | Where-Object { [long]$_.hwnd -eq 410L }).Count -ne 0 -or
      @($diagnostics | Where-Object { [long]$_.hwnd -eq 3475810L }).Count -ne 1) {
    throw "Window-discovery diagnostics must retain same-PID host/console candidates without recording other-PID decoys."
  }
  $ambiguous = @($windows) + @([pscustomobject]@{ Handle = 412L; ProcessId = [uint32]$ownerPid; ThreadId = 95; Visible = $true; Title = "second"; ClassName = "gpui_mbt_windows_host_v1"; Bounds = $rect })
  $rejectedAmbiguous = $false
  try { $null = Select-OwnedGpuiWindow $ambiguous $ownerPid } catch { $rejectedAmbiguous = $_.Exception.Message -match "Ambiguous owned GPUI HWNDs" }
  if (-not $rejectedAmbiguous) { throw "Window-discovery regression did not reject multiple visible same-PID GPUI HWNDs." }
  $absent = @($windows | Where-Object { $_.ClassName -ne $script:expectedGpuiWindowClass -or [long]$_.ProcessId -ne $ownerPid })
  if ($null -ne (Select-OwnedGpuiWindow $absent $ownerPid)) { throw "Window-discovery regression accepted an absent owned GPUI HWND." }
  $invisible = @($windows | Where-Object { [long]$_.Handle -eq 411L })
  if ($null -ne (Select-OwnedGpuiWindow $invisible $ownerPid)) { throw "Window-discovery regression accepted an invisible owned GPUI HWND." }
}

function Assert-DefaultInputDesktop {
  param([string]$Context)
  $desktop = [PaletteE2E.Win32]::CheckInputDesktop()
  $check = [ordered]@{ context = $Context; opened = [bool]$desktop.Success; name = $desktop.Name; win32_error = [int]$desktop.LastError; at_utc = [DateTime]::UtcNow.ToString("o") }
  $script:result.input_desktop_checks += $check
  $script:result.input_desktop = $check
  if (-not $desktop.Success -or $desktop.Name -ne "Default") {
    Save-Result
    throw "Interactive input desktop check failed before '$Context' (opened=$($desktop.Success), name='$($desktop.Name)', Win32=$($desktop.LastError)); no input was sent."
  }
  Save-Result
  return $desktop
}

function Assert-OwnedForeground {
  param([object]$Owner, [switch]$PassThru)
  $hwnd = Assert-OwnedProcess $Owner
  $foreground = [PaletteE2E.Win32]::GetForegroundWindow()
  if ($foreground -ne $hwnd) {
    $foregroundPid = [uint32]0
    [void][PaletteE2E.Win32]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
    throw "Owned HWND is not foreground: expected=0x$('{0:X}' -f $hwnd.ToInt64()) PID $($Owner.pid), actual=0x$('{0:X}' -f $foreground.ToInt64()) PID $foregroundPid."
  }
  if ($PassThru) { return $hwnd }
}

function Set-OwnedForeground {
  param([object]$Owner, [int]$WaitMilliseconds = 1500)
  Assert-DefaultInputDesktop "foreground request $($Owner.role)" | Out-Null
  $hwnd = Assert-OwnedProcess $Owner
  $callReturned = [PaletteE2E.Win32]::SetForegroundWindow($hwnd)
  $callError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt $WaitMilliseconds) {
    Assert-DefaultInputDesktop "foreground verification $($Owner.role)" | Out-Null
    if ([PaletteE2E.Win32]::GetForegroundWindow() -eq $hwnd) {
      $script:result.focus_changes += [ordered]@{ role = $Owner.role; hwnd = "0x$('{0:X}' -f $hwnd.ToInt64())"; set_foreground_returned = $callReturned; call_last_error = $callError; verified = $true; at_utc = [DateTime]::UtcNow.ToString("o") }
      Save-Result
      return $true
    }
    Start-Sleep -Milliseconds 25
  }
  $foreground = [PaletteE2E.Win32]::GetForegroundWindow()
  $foregroundPid = [uint32]0
  [void][PaletteE2E.Win32]::GetWindowThreadProcessId($foreground, [ref]$foregroundPid)
  $script:result.focus_changes += [ordered]@{ role = $Owner.role; hwnd = "0x$('{0:X}' -f $hwnd.ToInt64())"; set_foreground_returned = $callReturned; call_last_error = $callError; verified = $false; actual_hwnd = "0x$('{0:X}' -f $foreground.ToInt64())"; actual_pid = $foregroundPid; at_utc = [DateTime]::UtcNow.ToString("o") }
  Save-Result
  throw "SetForegroundWindow was not granted: returned=$callReturned, last_error=$callError, expected=0x$('{0:X}' -f $hwnd.ToInt64()), actual=0x$('{0:X}' -f $foreground.ToInt64()) PID $foregroundPid; no focus-policy bypass used."
}

function Assert-NoHeldModifiers {
  $groups = [ordered]@{ Shift = @(0x10, 0xA0, 0xA1); Control = @(0x11, 0xA2, 0xA3); Alt = @(0x12, 0xA4, 0xA5); Windows = @(0x5B, 0x5C) }
  $held = [System.Collections.Generic.List[string]]::new()
  foreach ($group in $groups.Keys) {
    foreach ($vk in $groups[$group]) {
      if (([PaletteE2E.Win32]::GetAsyncKeyState([int]$vk) -band 0x8000) -ne 0) { $held.Add("$group/0x$('{0:X2}' -f $vk)") }
    }
  }
  if ($held.Count -gt 0) { throw "Pre-existing held modifier key(s) $($held -join ', '); refusing to reset or inject user key state." }
}

function Invoke-OwnedInput {
  param([object]$Owner, [string]$Action, [ushort[]]$Keys, [bool[]]$Ups)
  # Reject stale/reused/malformed ownership before querying desktop state or
  # reaching the only SendInput call. This also keeps Validate safe to run.
  Assert-OwnedProcess $Owner | Out-Null
  Assert-DefaultInputDesktop "pre-input $Action" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
  Assert-NoHeldModifiers
  Assert-DefaultInputDesktop "immediate pre-input $Action" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
  $native = [PaletteE2E.Win32]::SendEvents($Keys, $Ups)
  Add-InputEvidence $Action $Keys $native
  if ($native.Inserted -ne $native.Requested) {
    $held = [System.Collections.Generic.List[ushort]]::new()
    for ($i = 0; $i -lt [Math]::Min([int]$native.Inserted, $Keys.Length); $i++) {
      if ($Ups[$i]) { [void]$held.Remove([ushort]$Keys[$i]) } else { $held.Add([ushort]$Keys[$i]) }
    }
    $release = [ordered]@{ attempted = $false; requested = 0; inserted = 0; error = $null }
    if ($held.Count -gt 0) {
      try {
        Assert-DefaultInputDesktop "targeted partial-input release $Action" | Out-Null
        Assert-OwnedForeground $Owner | Out-Null
        $releaseKeys = [System.Collections.Generic.List[ushort]]::new()
        for ($i = $held.Count - 1; $i -ge 0; $i--) { $releaseKeys.Add($held[$i]) }
        $releaseUps = [bool[]]::new($releaseKeys.Count)
        for ($i = 0; $i -lt $releaseUps.Length; $i++) { $releaseUps[$i] = $true }
        $r = [PaletteE2E.Win32]::SendEvents($releaseKeys.ToArray(), $releaseUps)
        $release = [ordered]@{ attempted = $true; requested = $r.Requested; inserted = $r.Inserted; error = $r.LastError }
      } catch { $release.error = $_.Exception.Message }
    }
    $script:result.failure = [ordered]@{ kind = "partial_sendinput"; action = $Action; requested = $native.Requested; inserted = $native.Inserted; win32_error = $native.LastError; targeted_release = $release }
    Save-Result
    throw "SendInput inserted $($native.Inserted) of $($native.Requested) events for '$Action'; stopping with evidence retained."
  }
  Assert-DefaultInputDesktop "post-input $Action" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
}

function Send-KeyTap {
  param([object]$Owner, [string]$Action, [ushort]$Key)
  [ushort[]]$keys = @($Key, $Key); [bool[]]$ups = @($false, $true)
  Invoke-OwnedInput $Owner $Action $keys $ups
}

function Send-KeyChord {
  param([object]$Owner, [string]$Action, [ushort]$Modifier, [ushort]$Key)
  [ushort[]]$keys = @($Modifier, $Key, $Key, $Modifier); [bool[]]$ups = @($false, $false, $true, $true)
  Invoke-OwnedInput $Owner $Action $keys $ups
}

function Wait-ForFrame {
  param([object]$Owner, [long]$AfterPresentation = 0, [scriptblock]$Predicate = { param($state) $true }, [int]$Seconds = $TimeoutSeconds)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
    try {
      $process = Get-Process -Id $Owner.pid -ErrorAction Stop
      if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$Owner.start_ticks) { throw "PID reused." }
    } catch {
      $processCheckError = $_.Exception.Message
      $outExists = Test-Path -LiteralPath $Owner.stdout
      $errExists = Test-Path -LiteralPath $Owner.stderr
      $out = if ($outExists) { Get-Content -Raw -LiteralPath $Owner.stdout -ErrorAction SilentlyContinue } else { $null }
      $err = if ($errExists) { Get-Content -Raw -LiteralPath $Owner.stderr -ErrorAction SilentlyContinue } else { $null }
      throw (Format-ExitedChildDiagnostic $processCheckError $out $outExists $err $errExists)
    }
    $frame = Get-LatestFrame $Owner.stdout
    if ($null -ne $frame -and [long]$frame.State.presentation -gt $AfterPresentation -and (& $Predicate $frame.State)) { return $frame }
    Start-Sleep -Milliseconds 50
  }
  throw "Timed out waiting for a completed frame and observer predicate; log=$($Owner.stdout)."
}

function Get-CurrentFrame {
  param([object]$Owner)
  $frame = Get-LatestFrame $Owner.stdout
  if ($null -eq $frame) { throw "No correlated ACCEPTED/STATE/COMPLETE/READBACK frame in $($Owner.stdout)." }
  return $frame
}

function Wait-OwnedWindow {
  param([object]$Owner)
  $null = Assert-OwnedProcessIdentity $Owner
  $watch = [Diagnostics.Stopwatch]::StartNew()
  $lastWindows = @()
  $lastDiagnostics = @()
  $ambiguity = $null
  while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    try {
      $process = Get-Process -Id $Owner.pid -ErrorAction Stop
      if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$Owner.start_ticks) { throw "Owned PID $($Owner.pid) was reused while waiting for its window." }
    } catch { throw "Owned fixture PID $($Owner.pid) exited before its window was discovered: $($_.Exception.Message)" }
    $lastWindows = [PaletteE2E.Win32]::VisibleWindows()
    $lastDiagnostics = @(Get-OwnedWindowDiagnostics $lastWindows ([long]$Owner.pid))
    try { $candidate = Select-OwnedGpuiWindow $lastWindows ([long]$Owner.pid) } catch { $ambiguity = $_.Exception.Message; break }
    if ($null -ne $candidate) {
      $Owner.hwnd = [long]$candidate.Handle
      $Owner.thread_id = [uint32]$candidate.ThreadId
      $Owner.title = [string]$candidate.Title
      $Owner.window_class = [string]$candidate.ClassName
      $Owner.window_candidates = $lastDiagnostics
      $null = Assert-OwnedProcess $Owner
      $script:result.window_discovery += [ordered]@{ role = $Owner.role; pid = $Owner.pid; status = "PASS"; selected_hwnd = $Owner.hwnd; class_name = $Owner.window_class; title = $Owner.title; candidates = $lastDiagnostics; at_utc = [DateTime]::UtcNow.ToString("o") }
      Save-Result
      return
    }
    Start-Sleep -Milliseconds 50
  }
  $Owner.window_candidates = $lastDiagnostics
  $script:result.window_discovery += [ordered]@{ role = $Owner.role; pid = $Owner.pid; status = "FAIL"; ambiguity = $ambiguity; candidates = $lastDiagnostics; at_utc = [DateTime]::UtcNow.ToString("o") }
  Save-Result
  $details = $lastDiagnostics | ConvertTo-Json -Depth 8 -Compress
  if ($ambiguity) { throw "$ambiguity; final same-PID candidates=$details" }
  throw "Expected exactly one visible top-level '$($script:expectedGpuiWindowClass)' for owned PID $($Owner.pid); title is diagnostic only. Final same-PID candidates=$details"
}

function Start-OwnedFixture {
  param([string]$Role, [bool]$Readback, [bool]$Ime)
  $logDir = Join-Path $runDir $Role; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
  $stdout = Join-Path $logDir "app.stdout.log"; $stderr = Join-Path $logDir "app.stderr.log"
  [uint32]$bridgeNonce = 0
  if ($Ime) {
    $nonceBytes = [byte[]]::new(4)
    [Security.Cryptography.RandomNumberGenerator]::Fill($nonceBytes)
    $bridgeNonce = [BitConverter]::ToUInt32($nonceBytes, 0)
    if ($bridgeNonce -eq 0) { $bridgeNonce = 1 }
  }
  $saved = @{ r = $env:GPUI_WINDOWS_READBACK; i = $env:GPUI_WINDOWS_COMMAND_PALETTE_IME; n = $env:GPUI_WINDOWS_COMMAND_PALETTE_IME_NONCE; s = $env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE }
  try {
    $env:GPUI_WINDOWS_READBACK = if ($Readback) { "1" } else { "0" }
    $env:GPUI_WINDOWS_COMMAND_PALETTE_IME = if ($Ime) { "1" } else { "0" }
    $env:GPUI_WINDOWS_COMMAND_PALETTE_IME_NONCE = $bridgeNonce.ToString("x8", [Globalization.CultureInfo]::InvariantCulture)
    Remove-Item Env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE -ErrorAction SilentlyContinue
    $process = Start-Process -FilePath $binary -WorkingDirectory $repo -WindowStyle Normal -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  } finally {
    if ($null -eq $saved.r) { Remove-Item Env:GPUI_WINDOWS_READBACK -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_READBACK = $saved.r }
    if ($null -eq $saved.i) { Remove-Item Env:GPUI_WINDOWS_COMMAND_PALETTE_IME -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_COMMAND_PALETTE_IME = $saved.i }
    if ($null -eq $saved.n) { Remove-Item Env:GPUI_WINDOWS_COMMAND_PALETTE_IME_NONCE -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_COMMAND_PALETTE_IME_NONCE = $saved.n }
    if ($null -eq $saved.s) { Remove-Item Env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE -ErrorAction SilentlyContinue } else { $env:GPUI_WINDOWS_COMMAND_PALETTE_SMOKE = $saved.s }
  }
  $process.Refresh()
  $owner = [pscustomobject]@{
    role = $Role; pid = [int]$process.Id; start_ticks = [long]$process.StartTime.ToUniversalTime().Ticks
    started_at_utc = $process.StartTime.ToUniversalTime().ToString("o")
    executable = [IO.Path]::GetFullPath($binary); executable_sha256 = (Get-FileHash $binary -Algorithm SHA256).Hash.ToLowerInvariant()
    hwnd = 0L; thread_id = 0; title = $null; window_class = $null; window_candidates = @(); stdout = $stdout; stderr = $stderr
    readback = $Readback; experimental_imm32 = $Ime; bridge_nonce = $bridgeNonce; process = $process
  }
  $script:owners.Add($owner)
  $script:result.fixtures += [ordered]@{ role = $Role; pid = $owner.pid; start_time_utc = $owner.started_at_utc; executable = $owner.executable; executable_sha256 = $owner.executable_sha256; stdout = $stdout; stderr = $stderr; readback = $Readback; experimental_imm32 = $Ime }
  Save-Result
  Wait-OwnedWindow $owner
  return $owner
}

function Capture-OwnedClientCore {
  param([object]$Owner, [string]$Name, [object]$CandidateFrame, [object]$ExpectedFrame, [object]$Extra = $null, [int]$CaptureNumber = 1)
  Assert-OwnedForeground $Owner
  if ($null -eq $CandidateFrame -or -not (Test-CaptureSemanticState $CandidateFrame.State $ExpectedFrame.State)) {
    return [pscustomobject]@{ status = "SEMANTIC_STATE_CHANGED_BEFORE_CAPTURE"; record = $null; reason = "The selected candidate frame does not match the requested semantic state." }
  }
  $before = Get-LatestFrame $Owner.stdout
  if ($null -eq $before) {
    return [pscustomobject]@{ status = "RETRY_BEFORE_FRAME_PENDING"; record = $null; reason = "The newest accepted state has no complete readback tuple yet." }
  }
  if (-not (Test-CaptureSemanticState $before.State $ExpectedFrame.State)) {
    return [pscustomobject]@{ status = "SEMANTIC_STATE_CHANGED_BEFORE_CAPTURE"; record = $null; reason = "The newest complete frame no longer matches the requested semantic state." }
  }
  $identity = Get-FrameIdentity $before
  $semanticIdentity = Get-CaptureSemanticIdentity $ExpectedFrame.State
  if (-not (Test-CandidateGeometryMatchesFrame $Extra $before)) {
    return [pscustomobject]@{ status = "SEMANTIC_STATE_CHANGED_BEFORE_CAPTURE"; record = $null; reason = "Candidate geometry evidence belongs to a different semantic state than the adopted frame." }
  }
  $hwnd = Assert-OwnedProcess $Owner
  $client = [PaletteE2E.RECT]::new()
  if (-not [PaletteE2E.Win32]::GetClientRect($hwnd, [ref]$client)) { throw "GetClientRect failed; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $origin = [PaletteE2E.POINT]::new(); $origin.X = $client.Left; $origin.Y = $client.Top
  if (-not [PaletteE2E.Win32]::ClientToScreen($hwnd, [ref]$origin)) { throw "ClientToScreen failed; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $width = $client.Right - $client.Left; $height = $client.Bottom - $client.Top
  $scale = [double]$before.State.viewport.scale
  $expectedWidth = [int][Math]::Floor(([double]$before.State.viewport.logical_width * $scale) + 0.5)
  $expectedHeight = [int][Math]::Floor(([double]$before.State.viewport.logical_height * $scale) + 0.5)
  if ([Math]::Abs($width - $expectedWidth) -gt 3 -or [Math]::Abs($height - $expectedHeight) -gt 3) { throw "Physical client pixel geometry $width x $height differs from scene viewport $expectedWidth x $expectedHeight." }
  $vx = [PaletteE2E.Win32]::GetSystemMetrics(76); $vy = [PaletteE2E.Win32]::GetSystemMetrics(77)
  $vw = [PaletteE2E.Win32]::GetSystemMetrics(78); $vh = [PaletteE2E.Win32]::GetSystemMetrics(79)
  if ($origin.X -lt $vx -or $origin.Y -lt $vy -or ($origin.X + $width) -gt ($vx + $vw) -or ($origin.Y + $height) -gt ($vy + $vh)) { throw "Client capture rectangle is outside the physical virtual screen." }
  $bitmapName = if ($CaptureNumber -eq 1) { "$Name.bmp" } else { "$Name.attempt-$CaptureNumber.bmp" }
  $path = Join-Path $runDir $bitmapName
  $dwmBefore = [PaletteE2E.Win32]::DwmFlush()
  if ($dwmBefore -lt 0) { throw "DwmFlush before capture failed; HRESULT=0x$('{0:X8}' -f [uint32]$dwmBefore)." }
  $capture = [PaletteE2E.CaptureResult]::new()
  $ok = [PaletteE2E.Win32]::CaptureScreenRect($path, $origin.X, $origin.Y, $width, $height, [ref]$capture)
  $dwmAfter = [PaletteE2E.Win32]::DwmFlush()
  if ($dwmAfter -lt 0) { throw "DwmFlush after capture failed; HRESULT=0x$('{0:X8}' -f [uint32]$dwmAfter)." }
  if (-not $ok -or -not $capture.Success) { throw "BitBlt client capture failed; Win32=$($capture.LastError); error=$($capture.ErrorText)." }
  $bytes = [IO.File]::ReadAllBytes($path)
  $bmpWidth = [BitConverter]::ToInt32($bytes, 18); $bmpHeight = [BitConverter]::ToInt32($bytes, 22)
  if ($bytes.Length -ne (54 + ($width * $height * 4)) -or $bmpWidth -ne $width -or $bmpHeight -ne (-$height) -or $bytes[0] -ne 0x42 -or $bytes[1] -ne 0x4d) { throw "BMP header/byte geometry validation failed for $Name." }
  Assert-OwnedForeground $Owner
  $after = Get-LatestFrame $Owner.stdout
  $decision = Get-CaptureBracketDecision $before $after $ExpectedFrame.State
  $afterIdentity = if ($null -ne $after) { Get-FrameIdentity $after } else { $null }
  $afterSemanticIdentity = if ($null -ne $after) { Get-CaptureSemanticIdentity $after.State } else { $null }
  $stable = $decision -eq "STABLE"
  $record = [ordered]@{
    name = $Name
    capture_attempt = $CaptureNumber
    capture_kind = "visible compositor client via screen-DC BitBlt/CAPTUREBLT"
    bitmap_format = "top-down 32-bpp BI_RGB BMP (BGRX, alpha ignored)"
    presentation = [long]$before.State.presentation
    frame_event_sequence = [long]$before.Complete.event_sequence
    retry_candidate_identity = Get-FrameIdentity $CandidateFrame
    state_identity = $identity
    expected_semantic_identity = $semanticIdentity
    extra_source_frame_identity = if ($Extra -and $Extra.source_frame_identity) { $Extra.source_frame_identity } else { $null }
    extra_source_semantic_identity = if ($Extra -and $Extra.source_semantic_identity) { $Extra.source_semantic_identity } else { $null }
    before_semantic_identity = Get-CaptureSemanticIdentity $before.State
    after_semantic_identity = $afterSemanticIdentity
    before_identity = (Get-FrameIdentity $before)
    after_identity = $afterIdentity
    capture_bracket_decision = $decision
    stable_frame_bracketing = $stable
    frame_state = $before.State
    screen_client_rect = [ordered]@{ x = $origin.X; y = $origin.Y; width = $width; height = $height }
    logical_viewport = $before.State.viewport
    target_dpi = [PaletteE2E.Win32]::GetDpiForWindow($hwnd)
    pixel_geometry_check = [ordered]@{ status = "PASS"; bitmap_width = $bmpWidth; bitmap_height = -$bmpHeight; expected_width = $expectedWidth; expected_height = $expectedHeight; bmp_bytes = $bytes.Length }
    gpu_readback_samples = $before.Readback.samples
    bitmap = $path
    bitmap_sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
    bitmap_bytes = $capture.Bytes
    dwm_flush_before_hresult = $dwmBefore
    dwm_flush_after_hresult = $dwmAfter
    human_pixel_audit = "UNRUN"
    extra = $Extra
  }
  $record | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDir "$Name.capture-$CaptureNumber.json") -Encoding utf8
  $script:result.captures += $record
  Save-Result
  return [pscustomobject]@{ status = $decision; record = $record; reason = if ($decision -eq "STABLE") { $null } else { "The capture did not retain the exact frame identity before and after BitBlt; decision=$decision." } }
}

function Capture-OwnedClient {
  param([object]$Owner, [string]$Name, [object]$ExpectedFrame, [object]$Extra = $null)
  $stage = "pixel_capture_$Name"
  Start-Stage $stage
  try {
    $frameReader = { param($captureOwner) Get-LatestFrame $captureOwner.stdout }
    $captureAttempt = { param($captureOwner, $captureName, $candidateFrame, $expectedFrame, $extraData, $captureNumber) Capture-OwnedClientCore $captureOwner $captureName $candidateFrame $expectedFrame $extraData $captureNumber }
    $settlement = Invoke-CaptureStableRetry $Owner $Name $ExpectedFrame $Extra $frameReader $captureAttempt 3000 20 50
    $settlementEvidence = [ordered]@{
      name = $Name
      status = $settlement.status
      expected_semantic_identity = Get-CaptureSemanticIdentity $ExpectedFrame.State
      selected_presentation = if ($settlement.capture -and $settlement.capture.record) { [long]$settlement.capture.record.presentation } elseif ($settlement.frame) { [long]$settlement.frame.State.presentation } else { $null }
      attempts = $settlement.attempts
      reason = $settlement.reason
    }
    $script:result.capture_settlements += $settlementEvidence
    Save-Result
    if ($settlement.status -eq "PASS") {
      $record = $settlement.capture.record
      Add-Stage $stage "PASS" ([ordered]@{ bitmap = $record.bitmap; sha256 = $record.bitmap_sha256; presentation = $record.presentation; event_sequence = $record.frame_event_sequence; stable_frame_bracketing = $record.stable_frame_bracketing; capture_attempts = $settlement.attempts })
      return $record
    }
    Add-Stage $stage "FAIL" $settlementEvidence
    throw "Capture $Name did not settle on a stable frame matching its requested semantic state: $($settlement.status): $($settlement.reason)"
  } catch {
    if (-not (@($script:result.stages | Where-Object { $_.name -eq $stage }).Count)) {
      Add-Stage $stage "FAIL" ([ordered]@{ error = $_.Exception.Message })
    }
    throw
  }
}

function Open-Palette {
  param([object]$Owner, [object]$Before)
  $epoch = [long]$Before.State.open_epoch
  Send-KeyChord $Owner "Ctrl+K open" 0x11 0x4B
  return Wait-ForFrame $Owner ([long]$Before.State.presentation) { param($s) [bool]$s.open -and [long]$s.open_epoch -gt $epoch }
}

function Send-RomanText {
  param([object]$Owner, [string]$Text)
  foreach ($char in $Text.ToCharArray()) {
    $upper = [char]::IsUpper($char)
    $value = [char]::ToUpperInvariant($char)
    $vk = [ushort][byte]$value
    if ($upper) { Send-KeyChord $Owner "physical-style Shift+$value" 0x10 $vk }
    else { Send-KeyTap $Owner "physical-style VK $value" $vk }
  }
}

function Get-ImeSnapshot {
  param([object]$Owner)
  Assert-DefaultInputDesktop "owner-thread IMM32 snapshot" | Out-Null
  $hwnd = Assert-OwnedForeground $Owner -PassThru
  $ime = [PaletteE2E.Win32]::QueryIme($hwnd, [uint32]$Owner.pid, [uint32]$Owner.thread_id, [long]$Owner.start_ticks, [string]$Owner.executable, [string]$Owner.executable_sha256, [uint32]$Owner.bridge_nonce, 1500)
  Assert-OwnedForeground $Owner | Out-Null
  if ([int]$ime.Status -notin @(0, 1)) { throw "Owner-thread IMM32 snapshot failed: bridge_status=$($ime.Status), win32_error=$($ime.LastError), target_pid=$($ime.TargetProcessId), target_thread=$($ime.TargetThreadId), request_id=$($ime.BridgeRequestId)." }
  return [ordered]@{
    query_transport = "bounded scalar WM_APP request handled by the owned HWND thread"
    bridge_status = [int]$ime.Status
    bridge_last_error = [int]$ime.LastError
    bridge_request_id = [long]$ime.BridgeRequestId
    target_process_id = [uint32]$ime.TargetProcessId
    target_thread_id = [uint32]$ime.TargetThreadId
    owner_process_id = [uint32]$ime.OwnerProcessId
    owner_thread_id = [uint32]$ime.OwnerThreadId
    has_context = $ime.HasContext
    open = $ime.Open
    conversion_valid = $ime.ConversionValid
    conversion_mode = $ime.ConversionMode
    sentence_mode = $ime.SentenceMode
    native_mode = (($ime.ConversionMode -band 1) -ne 0)
    full_shape_mode = (($ime.ConversionMode -band 8) -ne 0)
  }
}

function Wait-Ime {
  param([object]$Owner, [scriptblock]$Predicate, [int]$Milliseconds = 3000)
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.ElapsedMilliseconds -lt $Milliseconds) {
    $state = Get-ImeSnapshot $Owner
    if (& $Predicate $state) { return $state }
    Start-Sleep -Milliseconds 50
  }
  return Get-ImeSnapshot $Owner
}

function Snapshot-OriginalIme {
  param([object]$Owner)
  if ($null -ne $script:imeOriginal) { return $script:imeOriginal }
  Assert-DefaultInputDesktop "initial IME/layout snapshot" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
  $original = [PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id)
  $script:imeOriginal = [ordered]@{
    hkl = $original.ToInt64()
    hkl_hex = "0x$('{0:X}' -f $original.ToInt64())"
    language_id = [int]($original.ToInt64() -band 0xFFFF)
    state = Get-ImeSnapshot $Owner
  }
  $script:result.ime.original_layout = $script:imeOriginal.hkl_hex
  $script:result.ime.original_state = $script:imeOriginal.state
  Save-Result
  return $script:imeOriginal
}

function Ensure-DirectInputMode {
  param([object]$Owner)
  $null = Snapshot-OriginalIme $Owner
  Assert-DefaultInputDesktop "direct-input mode setup" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
  $ime = Get-ImeSnapshot $Owner
  if ($ime.has_context -and $ime.open) {
    Send-KeyTap $Owner "physical IME_OFF for committed ASCII input" 0x1A
    $ime = Wait-Ime $Owner { param($v) -not $v.open }
    if ($ime.open) { throw "IME did not close after physical IME_OFF; direct ASCII input is not qualified." }
  }
  return [ordered]@{ status = "PASS"; ime_context = $ime.has_context; open = $ime.open; target_thread_hkl = "0x$('{0:X}' -f ([PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id).ToInt64()))"; verified = $true }
}

function Ensure-JapaneseLayout {
  param([object]$Owner)
  Assert-DefaultInputDesktop "Japanese layout setup" | Out-Null
  Assert-OwnedForeground $Owner | Out-Null
  $null = Snapshot-OriginalIme $Owner
  $thread = [uint32]$Owner.thread_id
  $original = [PaletteE2E.Win32]::GetKeyboardLayout($thread)
  if (($original.ToInt64() -band 0xFFFF) -eq 0x0411 -and [PaletteE2E.Win32]::ImmIsIME($original)) {
    $script:japaneseLayout = $original
    $script:result.ime.japanese_layout = "pre-existing target-thread HKL $($script:imeOriginal.hkl_hex)"
    Save-Result
    return
  }
  $loaded = [IntPtr]::Zero
  foreach ($candidate in [PaletteE2E.Win32]::LoadedKeyboardLayouts()) {
    if (($candidate.ToInt64() -band 0xFFFF) -eq 0x0411 -and [PaletteE2E.Win32]::ImmIsIME($candidate)) { $loaded = $candidate; break }
  }
  if ($loaded -eq [IntPtr]::Zero) {
    $loaded = [PaletteE2E.Win32]::LoadKeyboardLayoutW("00000411", 0x00000080)
    if ($loaded -ne [IntPtr]::Zero) {
      # Record ownership immediately so a later IME/layout request failure can
      # still unload exactly this driver-added HKL during normal cleanup.
      $script:loadedJapaneseByDriver = $true
      $script:loadedJapaneseHandle = $loaded
    }
    if ($loaded -eq [IntPtr]::Zero -or -not [PaletteE2E.Win32]::ImmIsIME($loaded)) {
      $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
      $script:result.ime.japanese_layout = [ordered]@{ status = "UNRUN"; win32_error = $err; reason = "No loaded/installed Japanese 0411 IME HKL." }
      $script:unrun = $true
      return
    }
  }
  $requestError = 0
  Assert-DefaultInputDesktop "Japanese layout change request" | Out-Null
  $hwnd = Assert-OwnedForeground $Owner -PassThru
  if (-not [PaletteE2E.Win32]::RequestInputLanguage($hwnd, $loaded, [ref]$requestError)) {
    $script:result.ime.japanese_layout = [ordered]@{ status = "UNRUN"; win32_error = $requestError; reason = "WM_INPUTLANGCHANGEREQUEST rejected." }
    $script:unrun = $true
    return
  }
  $watch = [Diagnostics.Stopwatch]::StartNew()
  while ($watch.Elapsed.TotalSeconds -lt 5) {
    $current = [PaletteE2E.Win32]::GetKeyboardLayout($thread)
    if (($current.ToInt64() -band 0xFFFF) -eq 0x0411 -and [PaletteE2E.Win32]::ImmIsIME($current)) {
      $script:japaneseLayout = $current
      $script:result.ime.japanese_layout = [ordered]@{ status = "PASS"; target_thread_hkl = "0x$('{0:X}' -f $current.ToInt64())"; loaded_by_driver = $script:loadedJapaneseByDriver }
      Save-Result
      return
    }
    Start-Sleep -Milliseconds 50
  }
  $script:result.ime.japanese_layout = [ordered]@{ status = "UNRUN"; reason = "Target thread did not activate Japanese 0411 layout."; loaded_by_driver = $script:loadedJapaneseByDriver }
  $script:unrun = $true
}

function Ensure-ImeNativeMode {
  param([object]$Owner)
  $ime = Get-ImeSnapshot $Owner
  if (-not $ime.has_context -or -not $ime.conversion_valid) { throw "The owned HWND owner-thread bridge reported no usable IMM32 context/conversion state: bridge_status=$($ime.bridge_status), win32_error=$($ime.bridge_last_error), request_id=$($ime.bridge_request_id), target_pid=$($ime.target_process_id), target_thread=$($ime.target_thread_id)." }
  if (-not $ime.open) { Send-KeyTap $Owner "physical IME_ON VK" 0x16; $ime = Wait-Ime $Owner { param($v) $v.open } }
  if ($ime.open -and -not $ime.native_mode) { Send-KeyChord $Owner "physical IME mode Alt+OEM3" 0x12 0xC0; $ime = Wait-Ime $Owner { param($v) $v.open -and $v.native_mode } }
  if (-not $ime.open -or -not $ime.native_mode) { throw "Japanese IME did not enter open native mode; observed=$(ConvertTo-Json $ime -Compress)." }
  return $ime
}

function Query-CandidateGeometry {
  param([object]$Owner, [object]$Frame)
  Assert-DefaultInputDesktop "candidate geometry query" | Out-Null
  $hwnd = Assert-OwnedForeground $Owner -PassThru
  $before = $null
  try { $before = Get-CurrentFrame $Owner } catch { return [ordered]@{ status = "FAIL"; reason = "No stable frame was available before owner-thread candidate query"; error = $_.Exception.Message; expected_frame_identity = Get-FrameIdentity $Frame } }
  if ((Get-FrameIdentity $before) -cne (Get-FrameIdentity $Frame)) {
    return [ordered]@{ status = "FAIL"; reason = "Candidate query frame advanced before the request"; expected_frame_identity = Get-FrameIdentity $Frame; before_frame_identity = Get-FrameIdentity $before }
  }
  if (-not [bool]$Frame.State.experimental_imm32 -or $null -eq $Frame.State.native_owner -or -not [bool]$Frame.State.native_owner.composing) {
    return [ordered]@{ status = "FAIL"; reason = "Candidate geometry requires the matching composing native-owner frame"; source_frame_identity = Get-FrameIdentity $Frame }
  }
  $candidate = [PaletteE2E.Win32]::QueryCandidate($hwnd, [uint32]$Owner.pid, [uint32]$Owner.thread_id, [long]$Owner.start_ticks, [string]$Owner.executable, [string]$Owner.executable_sha256, [uint32]$Owner.bridge_nonce, 0, 1500)
  Assert-OwnedForeground $Owner | Out-Null
  $after = $null
  try { $after = Get-CurrentFrame $Owner } catch { return [ordered]@{ status = "FAIL"; reason = "No stable frame was available after owner-thread candidate query"; error = $_.Exception.Message; before_frame_identity = Get-FrameIdentity $before } }
  if ((Get-FrameIdentity $before) -cne (Get-FrameIdentity $after)) {
    return [ordered]@{ status = "FAIL"; reason = "Observer frame changed across owner-thread candidate query"; before_frame_identity = Get-FrameIdentity $before; after_frame_identity = Get-FrameIdentity $after }
  }
  if (-not $candidate.HasContext -or -not $candidate.QuerySucceeded) { return [ordered]@{ status = "FAIL"; reason = "Owner-thread ImmGetCandidateWindow query failed"; bridge_status = $candidate.Status; win32_error = $candidate.LastError; bridge_request_id = $candidate.BridgeRequestId; target_process_id = $candidate.TargetProcessId; target_thread_id = $candidate.TargetThreadId; source_frame_identity = Get-FrameIdentity $Frame } }
  $caret = $Frame.State.caret; $scale = [double]$Frame.State.viewport.scale
  $expectedX = [int][Math]::Floor(([double]$caret.x * $scale) + 0.5)
  $expectedY = [int][Math]::Floor((([double]$caret.y + [double]$caret.height) * $scale) + 0.5)
  $dx = [Math]::Abs([int]$candidate.X - $expectedX); $dy = [Math]::Abs([int]$candidate.Y - $expectedY)
  $result = [ordered]@{
    status = "PASS"
    evidence_kind = "ImmGetCandidateWindow CANDIDATEFORM adapter geometry"
    source_presentation = [long]$Frame.State.presentation
    source_frame_event_sequence = [long]$Frame.Complete.event_sequence
    source_frame_identity = Get-FrameIdentity $Frame
    source_semantic_identity = Get-CaptureSemanticIdentity $Frame.State
    bridge_request_id = [long]$candidate.BridgeRequestId
    target_process_id = [uint32]$candidate.TargetProcessId
    target_thread_id = [uint32]$candidate.TargetThreadId
    owner_process_id = [uint32]$candidate.OwnerProcessId
    owner_thread_id = [uint32]$candidate.OwnerThreadId
    query_transport = "bounded scalar WM_APP snapshot handled by the owned HWND thread"
    style = [uint32]$candidate.Style
    candidate_index = [uint32]$candidate.Index
    position_client_physical = @([int]$candidate.X, [int]$candidate.Y)
    expected_from_caret = @($expectedX, $expectedY)
    tolerance_pixels = 2
    delta_pixels = @($dx, $dy)
    caret_logical = $caret
    viewport_scale = $scale
    candidate_area = $candidate.Area
    popup_visual_claim = "not established by CANDIDATEFORM"
  }
  if (($candidate.Style -band 0x40) -eq 0 -or $dx -gt 2 -or $dy -gt 2) { $result.status = "FAIL" }
  $client = [PaletteE2E.RECT]::new()
  if (-not [PaletteE2E.Win32]::GetClientRect($hwnd, [ref]$client)) { throw "GetClientRect for candidate geometry failed; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $origin = [PaletteE2E.POINT]::new(); $origin.X = $client.Left; $origin.Y = $client.Top
  if (-not [PaletteE2E.Win32]::ClientToScreen($hwnd, [ref]$origin)) { throw "ClientToScreen for candidate geometry failed; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $sx = $origin.X + [int]$candidate.X; $sy = $origin.Y + [int]$candidate.Y
  $windows = @([PaletteE2E.Win32]::VisibleWindows() | Where-Object {
    $_.Visible -and $_.ClassName -match "ime|candidate|msctf|textinput" -and
    $_.Bounds.Right -gt ($sx - 400) -and $_.Bounds.Left -lt ($sx + 700) -and
    $_.Bounds.Bottom -gt ($sy - 300) -and $_.Bounds.Top -lt ($sy + 600)
  })
  $result.popup_window_metadata = @($windows | ForEach-Object {
    [ordered]@{ hwnd = "0x$('{0:X}' -f $_.Handle)"; pid = $_.ProcessId; class_name = $_.ClassName; screen_rect = $_.Bounds }
  })
  $result.popup_visual_status = if ($windows.Count -gt 0) { "candidate-like-window-metadata_only" } else { "UNRUN_not_identified" }
  $result.expected_candidate_screen_point = @($sx, $sy)
  return $result
}

function Restore-OwnedIme {
  param([object]$Owner)
  if ($null -eq $script:imeOriginal) { return [ordered]@{ status = "UNRUN"; attempted = $false; reason = "no original HKL snapshot" } }
  try {
    Set-OwnedForeground $Owner | Out-Null
    Assert-DefaultInputDesktop "IME/layout restoration" | Out-Null
    $hwnd = Assert-OwnedForeground $Owner -PassThru
    $originalHkl = [IntPtr]::new([long]$script:imeOriginal.hkl)
    $currentHkl = [PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id)
    $requested = $true; $errorCode = 0
    if ($currentHkl -ne $originalHkl) {
      $requested = [PaletteE2E.Win32]::RequestInputLanguage($hwnd, $originalHkl, [ref]$errorCode)
      $watch = [Diagnostics.Stopwatch]::StartNew()
      while ($watch.Elapsed.TotalSeconds -lt 5 -and [PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id) -ne $originalHkl) {
        Assert-DefaultInputDesktop "IME/layout restoration wait" | Out-Null
        Start-Sleep -Milliseconds 50
      }
    }
    $layoutRestored = ([PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id) -eq $originalHkl)
    $stateRestored = "NOT_APPLICABLE_no_initial_HIMC"
    $stateError = 0
    if ($layoutRestored -and [bool]$script:imeOriginal.state.has_context) {
      Assert-DefaultInputDesktop "IMM32 state restoration" | Out-Null
      Assert-OwnedForeground $Owner | Out-Null
      $hwnd = Assert-OwnedForeground $Owner -PassThru
      $called = [PaletteE2E.Win32]::RestoreIme($hwnd, [uint32]$Owner.pid, [uint32]$Owner.thread_id, [long]$Owner.start_ticks, [string]$Owner.executable, [string]$Owner.executable_sha256, [uint32]$Owner.bridge_nonce, [bool]$script:imeOriginal.state.open, [bool]$script:imeOriginal.state.conversion_valid, [uint32]$script:imeOriginal.state.conversion_mode, [uint32]$script:imeOriginal.state.sentence_mode, 1500, [ref]$stateError)
      $after = Get-ImeSnapshot $Owner
      $matches = $called -and $after.open -eq [bool]$script:imeOriginal.state.open -and
        $after.conversion_valid -eq [bool]$script:imeOriginal.state.conversion_valid -and
        (-not [bool]$script:imeOriginal.state.conversion_valid -or
          ($after.conversion_mode -eq [uint32]$script:imeOriginal.state.conversion_mode -and $after.sentence_mode -eq [uint32]$script:imeOriginal.state.sentence_mode))
      $stateRestored = if ($matches) { "PASS" } else { "FAIL" }
    }
    $unloaded = $null; $unloadError = 0; $layoutAfterUnload = $layoutRestored
    if ($script:loadedJapaneseByDriver -and $script:loadedJapaneseHandle -ne [IntPtr]::Zero -and $layoutRestored) {
      if ($script:loadedJapaneseHandle -ne $originalHkl) {
        $unloaded = [PaletteE2E.Win32]::UnloadKeyboardLayout($script:loadedJapaneseHandle)
        if (-not $unloaded) { $unloadError = [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
      } else { $unloaded = $true }
      $layoutAfterUnload = ([PaletteE2E.Win32]::GetKeyboardLayout([uint32]$Owner.thread_id) -eq $originalHkl)
    }
    $ok = $requested -and $layoutRestored -and $stateRestored -in @("PASS", "NOT_APPLICABLE_no_initial_HIMC") -and
      (-not $script:loadedJapaneseByDriver -or ([bool]$unloaded -and $layoutAfterUnload))
    $result = [ordered]@{
      status = if ($ok) { "PASS" } else { "FAIL" }
      attempted = $true
      original_hkl = $script:imeOriginal.hkl_hex
      layout_request_accepted = $requested
      layout_request_error = $errorCode
      layout_restored = $layoutRestored
      original_ime_state = $script:imeOriginal.state
      ime_state_restored = $stateRestored
      ime_state_restore_error = $stateError
      extra_layout_loaded_by_driver = $script:loadedJapaneseByDriver
      loaded_japanese_hkl = if ($script:loadedJapaneseHandle -ne [IntPtr]::Zero) { "0x$('{0:X}' -f $script:loadedJapaneseHandle.ToInt64())" } else { $null }
      unload_attempted = $script:loadedJapaneseByDriver
      unload_succeeded = $unloaded
      unload_error = $unloadError
      layout_after_unload_still_original = $layoutAfterUnload
    }
    $script:result.ime.restoration = $result
    return $result
  } catch {
    $result = [ordered]@{ status = "FAIL"; attempted = $true; restored = $false; error = $_.Exception.Message }
    $script:result.ime.restoration = $result
    return $result
  }
}

function Close-OwnedFixture {
  param([object]$Owner)
  $entry = [ordered]@{ role = $Owner.role; pid = $Owner.pid; start_time_utc = $Owner.started_at_utc; normal_close_sent = $false; exited = $false; exit_code = $null; error = $null }
  $errors = [System.Collections.Generic.List[string]]::new()
  try {
    $process = Get-Process -Id $Owner.pid -ErrorAction SilentlyContinue
    if (-not $process) {
      $entry.exited = $true
      [void]$errors.Add("process exited before bounded WM_CLOSE")
    } else {
      if ($Owner.role -eq "primary") {
        $frame = $null
        try { $frame = Get-CurrentFrame $Owner } catch { [void]$errors.Add("could not verify latest end frame: $($_.Exception.Message)") }
        $endFenced = $null -ne $frame -and -not [bool]$frame.State.open -and $null -eq $frame.State.native_owner
        $entry.end_fenced_closed_state = [bool]$endFenced
        if (-not $endFenced) { [void]$errors.Add("palette/session was not observed closed and end-fenced before WM_CLOSE") }
      } else {
        $entry.end_fenced_closed_state = "NOT_REQUIRED_auxiliary_received_no_input"
      }
      if ([long]$Owner.hwnd -eq 0) {
        try {
          $candidate = Discover-OwnedGpuiWindow $Owner -RecordDiagnostics
          if ($null -eq $candidate) { throw "No unique visible owned GPUI HWND was available for bounded cleanup." }
          $entry.rediscovered_hwnd = [long]$Owner.hwnd
          $entry.rediscovered_class = [string]$Owner.window_class
          $entry.rediscovered_title = [string]$Owner.title
          $entry.rediscovery_status = "PASS"
        } catch {
          $entry.rediscovery_status = "FAIL"
          [void]$errors.Add("owned HWND rediscovery failed: $($_.Exception.Message)")
        }
      } else { $entry.rediscovery_status = "NOT_NEEDED" }
      if ($Owner.role -eq "primary" -and $entry.end_fenced_closed_state -and $null -ne $script:imeOriginal -and [long]$Owner.hwnd -ne 0) {
        $entry.ime_restoration = Restore-OwnedIme $Owner
        if ($entry.ime_restoration.status -notin @("PASS", "NOT_APPLICABLE")) {
          [void]$errors.Add("IME/layout restoration did not pass: $($entry.ime_restoration | ConvertTo-Json -Compress -Depth 8)")
        }
      }
      try {
        if ([long]$Owner.hwnd -eq 0) { throw "No exact owned GPUI HWND was discovered; WM_CLOSE was not sent." }
        $hwnd = Assert-OwnedProcess $Owner
        $closeError = 0
        $entry.normal_close_sent = [PaletteE2E.Win32]::SendClose($hwnd, 2000, [ref]$closeError)
        $entry.win32_error = $closeError
        if (-not $entry.normal_close_sent) { [void]$errors.Add("bounded WM_CLOSE to exact owned HWND failed; Win32=$closeError") }
      } catch { [void]$errors.Add($_.Exception.Message) }
      if ($entry.normal_close_sent) {
        $exited = $Owner.process.WaitForExit(8000)
        $Owner.process.Refresh()
        $entry.exited = [bool]$exited
        if ($exited) { $entry.exit_code = $Owner.process.ExitCode }
        if (-not $exited) { [void]$errors.Add("owned fixture did not exit after WM_CLOSE; no forced termination was attempted") }
        elseif ($Owner.process.ExitCode -ne 0) { [void]$errors.Add("owned fixture exited with code $($Owner.process.ExitCode)") }
      }
    }
  } catch { [void]$errors.Add($_.Exception.Message) }
  if ($errors.Count -gt 0) { $entry.error = $errors -join " | " }
  $script:result.cleanup += $entry
  Save-Result
}

function Add-UnreachedStages {
  $expected = @(
    "startup_closed_frame", "initial_ime_snapshot_and_direct_input", "open_default_eight_rows", "disabled_row_navigation", "navigation_scroll",
    "ordinary_committed_search", "empty_result", "ordinary_activation_once", "background_key_recovery",
    "japanese_ime_layout", "japanese_ime_native_mode", "japanese_preedit_real_ime",
    "candidate_form_caret_geometry", "candidate_popup_visual_placement",
    "japanese_result_commit_without_activation", "japanese_fresh_enter_activation", "actual_japanese_ime_flow",
    "escape_cancels_composition", "fresh_escape_dismisses_palette", "post_escape_background_recovery",
    "owned_auxiliary_focus_loss", "rapid_focus_reopen_fresh_epochs", "normal_fenced_cleanup", "human_pixel_audit"
  )
  foreach ($name in $expected) {
    if (-not (@($script:result.stages | Where-Object { $_.name -eq $name }).Count)) {
      Add-Stage $name "UNRUN" ([ordered]@{ reason = "stage not reached"; run_status = $script:result.status })
    }
  }
}

function New-MockLog {
  param([int]$Presentation = 4, [long]$Sequence = 91, [switch]$Mismatch, [switch]$StateMismatch)
  $accepted = [ordered]@{ presentation = $Presentation; open_epoch = 2; open = $true; query = ""; matches = 16; visible_count = 8 }
  $state = [ordered]@{
    version = 1; presentation = $Presentation; open_epoch = 2; open = $true; query = ""; field_text = ""; committed_text = ""; composing = $false
    selection = [ordered]@{ anchor = 0; head = 0 }; matches = 16; active_id = "palette.command.0"; active_index = @(0); visible_start = 0; visible_count = 8
    actions = 0; last_action = ""; background_presses = 0; background_releases = 0; guarded_presses = 0; guarded_releases = 0; native_owner = $null
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1; font_family = "Segoe UI"; font_size = 18 }
    semantic = [ordered]@{ options = @(
      [ordered]@{ id = "palette.command.0"; name = "Selected command"; index = 0; selected = $true; disabled = $false },
      [ordered]@{ id = "palette.command.1"; name = "Second command"; index = 1; selected = $false; disabled = $false },
      [ordered]@{ id = "palette.command.2"; name = "Disabled command"; index = 2; selected = $false; disabled = $true }
    ) }
  }
  if ($StateMismatch) { $state.query = "wrong" }
  $complete = [ordered]@{ presentation = $Presentation; event_sequence = $Sequence; open_epoch = 2; query = ""; visible_count = 8; active_id = "palette.command.0" }
  $readSequence = if ($Mismatch) { $Sequence + 1 } else { $Sequence }
  $readback = [ordered]@{
    presentation = $Presentation; frame_event_sequence = $readSequence
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 }
    samples = @(
      [ordered]@{ point = @(1, 1); rgba = @(0, 1, 2, 255) },
      [ordered]@{ point = @(160, 160); rgba = @(3, 4, 5, 255) },
      [ordered]@{ point = @(638, 478); rgba = @(6, 7, 8, 255) }
    )
  }
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 8)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 8)"
  )
}

function New-FilteredWireLog {
  param([string]$Query, [int]$CommandIndex, [int]$Presentation = 7)
  $id = "palette.command.$CommandIndex"
  $accepted = [ordered]@{ presentation = $Presentation; open_epoch = 2; open = $true; query = $Query; matches = 1; visible_count = 1 }
  $state = [ordered]@{
    version = 1; presentation = $Presentation; open_epoch = 2; open = $true; query = $Query; field_text = $Query; committed_text = $Query; composing = $false
    selection = [ordered]@{ anchor = $Query.Length; head = $Query.Length }; matches = 1; active_id = $id; active_index = @(0); visible_start = 0; visible_count = 1
    actions = 0; last_action = ""; background_presses = 0; background_releases = 0; guarded_presses = 0; guarded_releases = 0; native_owner = $null
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1; font_family = "Segoe UI"; font_size = 18 }
    semantic = [ordered]@{ options = @([ordered]@{ id = $id; name = "Filtered command"; selected = $true; disabled = $false; index = 0 }) }
  }
  $complete = [ordered]@{ presentation = $Presentation; event_sequence = 93; open_epoch = 2; query = $Query; visible_count = 1; active_id = $id }
  $readback = [ordered]@{
    presentation = $Presentation; frame_event_sequence = 93
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 }
    samples = @(
      [ordered]@{ point = @(1, 1); rgba = @(0, 1, 2, 255) },
      [ordered]@{ point = @(160, 160); rgba = @(3, 4, 5, 255) },
      [ordered]@{ point = @(638, 478); rgba = @(6, 7, 8, 255) }
    )
  }
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 8)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 8)"
  )
}

function New-CaptureScrollWireLog {
  param(
    [int]$Presentation,
    [int]$ActiveIndex = 15,
    [int]$VisibleStart = 8,
    [long]$Sequence = 61,
    [int]$NativeUpdate = 26,
    [int]$BackgroundPresses = 0,
    [int]$BackgroundReleases = 0,
    [int]$GuardedPresses = 0,
    [int]$GuardedReleases = 0,
    [int]$NativeBegin = 1,
    [int]$NativeCancel = 0,
    [int]$NativeEnd = 0,
    [int]$NativeRecords = 0,
    [int]$NativeStaleRecords = 0,
    [int]$NativeRejectedRecords = 0,
    [string]$NativeOwnerSequence = "0",
    [bool]$NativeOwnerComposing = $false,
    [bool]$ExperimentalImm32 = $true
  )
  $source = [string[]](New-MockLog -Presentation $Presentation -Sequence $Sequence)
  $accepted = Get-RecordPayload $source[0] "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED "
  $state = Get-RecordPayload $source[1] "GPUI_WINDOWS_COMMAND_PALETTE_STATE "
  $complete = Get-RecordPayload $source[2] "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE "
  $readback = Get-RecordPayload $source[3] "GPUI_WINDOWS_COMMAND_PALETTE_READBACK "
  $id = "palette.command.$ActiveIndex"
  $accepted.open_epoch = 1; $accepted.open = $true; $accepted.query = ""; $accepted.matches = 16; $accepted.visible_count = 8
  $state.open = $true; $state.open_epoch = 1; $state.query = ""; $state.field_text = ""; $state.committed_text = ""; $state.composing = $false
  $state.selection = [ordered]@{ anchor = 0; head = 0 }; $state.matches = 16; $state.active_id = $id; $state.active_index = @($ActiveIndex)
  $state.visible_start = $VisibleStart; $state.visible_count = 8; $state.actions = 0; $state.last_action = ""
  $state.background_presses = $BackgroundPresses; $state.background_releases = $BackgroundReleases
  $state.guarded_presses = $GuardedPresses; $state.guarded_releases = $GuardedReleases
  $state.focus_owner = 2; $state.field_focused = $true; $state.caret = [ordered]@{ x = 28; y = 32; width = 1; height = 24 }; $state.experimental_imm32 = $ExperimentalImm32
  $state.native_owner = [ordered]@{ owner_generation = 2; palette_open_epoch = 1; native_epoch = 1; sequence = $NativeOwnerSequence; composing = $NativeOwnerComposing }
  $state.native_counters = [ordered]@{ begin = $NativeBegin; update = $NativeUpdate; cancel = $NativeCancel; end = $NativeEnd; records = $NativeRecords; stale_records = $NativeStaleRecords; rejected_records = $NativeRejectedRecords }
  $options = [System.Collections.Generic.List[object]]::new()
  for ($index = $VisibleStart; $index -lt [Math]::Min(16, $VisibleStart + 8); $index++) {
    $options.Add([ordered]@{ id = "palette.command.$index"; name = "Command $index"; index = $index; selected = ($index -eq $ActiveIndex); disabled = $false })
  }
  $state.semantic = [ordered]@{ role = "dialog"; name = "Command palette"; search_role = "textbox"; search_name = "Search commands"; search_value = ""; search_focused = $true; collection_role = "listbox"; options = $options.ToArray() }
  $complete.open_epoch = 1; $complete.query = ""; $complete.visible_count = 8; $complete.active_id = $id
  $readback.frame_event_sequence = $Sequence
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 12)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 8)"
  )
}

function New-RetainedClosedWireLog {
  # Exact protocol shape from the retained Windows fixture startup records:
  # STATE.active_id is null while COMPLETE.active_id retains picker.command.0.
  $accepted = [ordered]@{ presentation = 1; open_epoch = 0; open = $false; query = ""; matches = 16; visible_count = 0 }
  $state = [ordered]@{
    version = 1; presentation = 1; open = $false; open_epoch = 0; query = ""; field_text = ""; committed_text = ""; composing = $false
    selection = [ordered]@{ anchor = 0; head = 0 }; matches = 16; active_id = $null; active_index = @(0); visible_start = 0; visible_count = 0
    actions = 0; last_action = ""; background_presses = 0; background_releases = 0; guarded_presses = 0; guarded_releases = 0
    focus_owner = 9; field_focused = $false; caret = [ordered]@{ x = 28; y = 32; width = 1; height = 24 }; experimental_imm32 = $false
    native_owner = $null; native_counters = [ordered]@{ begin = 0; update = 0; cancel = 0; end = 0; records = 0; stale_records = 0; rejected_records = 0 }
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1; font_family = "Segoe UI"; font_size = 18 }
    semantic = [ordered]@{ options = @() }
  }
  $complete = [ordered]@{ presentation = 1; event_sequence = 4; open_epoch = 0; query = ""; visible_count = 0; active_id = "palette.command.0" }
  $readback = [ordered]@{
    presentation = 1; frame_event_sequence = 4; viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 }
    samples = @(
      [ordered]@{ point = @(1, 1); rgba = @(24, 28, 36, 255) },
      [ordered]@{ point = @(160, 160); rgba = @(24, 28, 36, 255) },
      [ordered]@{ point = @(638, 478); rgba = @(24, 28, 36, 255) }
    )
  }
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 8)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 8)"
  )
}

function New-RetainedNoActiveWireFrame {
  param([ValidateSet(43, 44)][int]$Presentation)
  # Exact relevant producer values copied from the retained manual run at
  # _build/windows-command-palette/e2e/20261007T142455481Z/primary/app.stdout.log
  # (P43 empty query result, P44 subsequent closed frame). Moon Option None is
  # explicit JSON null; Some(index) remains the one-element array used above.
  $isClosed = $Presentation -eq 44
  $eventSequence = if ($isClosed) { 90 } else { 88 }
  $focusOwner = if ($isClosed) { 9 } else { 2 }
  $nativeOwner = if ($isClosed) { $null } else { [ordered]@{ owner_generation = 2; palette_open_epoch = 2; native_epoch = 5; sequence = "87"; composing = $false } }
  $nativeUpdate = if ($isClosed) { 39 } else { 38 }
  $nativeEnd = if ($isClosed) { 2 } else { 1 }
  $query = "zzzz"
  $accepted = [ordered]@{ presentation = $Presentation; open_epoch = 2; open = (-not $isClosed); query = $query; matches = 0; visible_count = 0 }
  $state = [ordered]@{
    version = 1; presentation = $Presentation; open = (-not $isClosed); open_epoch = 2; query = $query; field_text = $query; committed_text = $query; composing = $false
    selection = [ordered]@{ anchor = 4; head = 4 }; matches = 0; active_id = $null; active_index = $null; visible_start = 0; visible_count = 0
    actions = 0; last_action = ""; background_presses = 0; background_releases = 0; guarded_presses = 0; guarded_releases = 1
    focus_owner = $focusOwner; field_focused = (-not $isClosed)
    caret = [ordered]@{ x = 60; y = 32; width = 2; height = 24 }; experimental_imm32 = $true
    native_owner = $nativeOwner
    native_counters = [ordered]@{ begin = 2; update = $nativeUpdate; cancel = 0; end = $nativeEnd; records = 6; stale_records = 0; rejected_records = 0 }
    viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1; font_family = "Segoe UI"; font_size = 18 }
    semantic = [ordered]@{ role = "dialog"; name = "Command palette"; search_role = "textbox"; search_name = "Search commands"; search_value = $query; search_focused = (-not $isClosed); collection_role = "listbox"; options = @() }
  }
  $complete = [ordered]@{ presentation = $Presentation; event_sequence = $eventSequence; open_epoch = 2; query = $query; visible_count = 0; active_id = $null }
  $edgeRgba = @(24, 28, 36, 255)
  $centerRgba = if ($isClosed) { @(24, 28, 36, 255) } else { @(34, 39, 49, 255) }
  $readback = [ordered]@{
    presentation = $Presentation; frame_event_sequence = $eventSequence; viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 }
    samples = @(
      [ordered]@{ point = @(1, 1); rgba = $edgeRgba },
      [ordered]@{ point = @(160, 160); rgba = $centerRgba },
      [ordered]@{ point = @(638, 478); rgba = $edgeRgba }
    )
  }
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 8)",
    "GPUI_WINDOWS_COMMAND_PALETTE_COMPLETE $($complete | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_READBACK $($readback | ConvertTo-Json -Compress -Depth 8)"
  )
}

function Add-MockPendingFrame {
  param([int]$Presentation)
  $accepted = [ordered]@{ presentation = $Presentation; open_epoch = 3; open = $true; query = "pending"; matches = 1; visible_count = 1 }
  $state = [ordered]@{ version = 1; presentation = $Presentation; open_epoch = 3; open = $true; query = "pending"; field_text = "pending"; committed_text = "pending"; composing = $false; active_index = @(0); visible_start = 0; visible_count = 1; matches = 1; active_id = "palette.command.1"; actions = 0; viewport = [ordered]@{ logical_width = 640; logical_height = 480; scale = 1 } }
  return @(
    "GPUI_WINDOWS_COMMAND_PALETTE_ACCEPTED $($accepted | ConvertTo-Json -Compress)",
    "GPUI_WINDOWS_COMMAND_PALETTE_STATE $($state | ConvertTo-Json -Compress -Depth 8)"
  )
}

function Invoke-ParserTests {
  $path = Join-Path $runDir ("parser-" + [Guid]::NewGuid().ToString("N") + ".log")
  try {
    [IO.File]::WriteAllLines($path, [string[]](New-MockLog), $utf8NoBom)
    $frame = Get-LatestFrame $path
    if ($null -eq $frame -or [long]$frame.State.presentation -ne 4 -or [long]$frame.Complete.event_sequence -ne 91) { throw "Valid open frame tuple parser regression." }
    if (-not (Test-StateOptionDisabled $frame.State 2)) { throw "State-option helper failed its disabled-row validation." }
    if (-not (Test-StateActiveIndex $frame.State 0) -or (Test-StateActiveIndex $frame.State 7)) { throw "State active-index helper accepted an incorrect option index." }
    if (Test-StateActiveIndex ([ordered]@{ active_index = @() }) 0) { throw "State active-index helper accepted Option None as a selected row." }
    if (-not (Test-StateActiveIndex ([ordered]@{ active_index = @(3) }) 3)) { throw "State active-index helper rejected a single Option index." }
    if (Test-StateActiveIndex ([ordered]@{ active_index = @(3, 4) }) 3) { throw "State active-index helper accepted a malformed multi-value Option." }
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 30 -ActiveIndex 15 -VisibleStart 8 -Sequence 61 -NativeUpdate 26), $utf8NoBom)
    $scroll30 = Get-LatestFrame $path
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 31 -ActiveIndex 15 -VisibleStart 8 -Sequence 63 -NativeUpdate 27), $utf8NoBom)
    $scroll31 = Get-LatestFrame $path
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 32 -ActiveIndex 15 -VisibleStart 8 -Sequence 65 -NativeUpdate 28), $utf8NoBom)
    $scroll32 = Get-LatestFrame $path
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 33 -ActiveIndex 15 -VisibleStart 8 -Sequence 67 -NativeUpdate 29), $utf8NoBom)
    $scroll33 = Get-LatestFrame $path
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 34 -ActiveIndex 15 -VisibleStart 8 -Sequence 69 -NativeUpdate 30), $utf8NoBom)
    $scroll34 = Get-LatestFrame $path
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 35 -ActiveIndex 14 -VisibleStart 8 -Sequence 71 -NativeUpdate 31), $utf8NoBom)
    $scrollChanged = Get-LatestFrame $path
    if ($null -eq $scroll30 -or $null -eq $scroll31 -or $null -eq $scrollChanged -or
        (Get-FrameIdentity $scroll30) -ceq (Get-FrameIdentity $scroll31) -or
        -not (Test-CaptureSemanticState $scroll30.State $scroll31.State)) { throw "Capture semantic identity did not distinguish a newer presentation from the same visible scroll state." }
    if ((Get-CaptureBracketDecision $scroll30 $scroll31 $scroll30.State) -ne "RETRY_NEWER_EQUIVALENT_FRAME") { throw "Capture bracket did not request a retry for actual-order frames 30→31 with equivalent visible state." }
    if ((Get-CaptureBracketDecision $scroll30 $scrollChanged $scroll30.State) -ne "SEMANTIC_STATE_CHANGED_DURING_CAPTURE") { throw "Capture bracket accepted a changed active row for the requested scroll state." }
    $geometryEvidence = [ordered]@{ source_frame_identity = Get-FrameIdentity $scroll30; source_semantic_identity = Get-CaptureSemanticIdentity $scroll30.State }
    if (-not (Test-CandidateGeometryMatchesFrame $geometryEvidence $scroll31) -or (Test-CandidateGeometryMatchesFrame $geometryEvidence $scrollChanged)) {
      throw "Candidate-form geometry provenance did not follow equivalent caret state or reject changed semantic state."
    }
    $script:captureSettleTestFrame = $scroll31
    $script:captureSettleTestCalls = 0
    $testFrameReader = { param($ignoredOwner) $script:captureSettleTestFrame }
    $testStableCapture = { param($ignoredOwner, $captureName, $candidate, $expectedFrame, $extraData, $captureNumber) $script:captureSettleTestCalls++; [pscustomobject]@{ status = "STABLE"; record = [ordered]@{ presentation = [long]$candidate.State.presentation; capture_attempt = $captureNumber }; reason = $null } }
    $settled31 = Invoke-CaptureStableRetry $null "scroll-active-row" $scroll30 $null $testFrameReader $testStableCapture 1000 3 0
    if ($settled31.status -ne "PASS" -or [long]$settled31.frame.State.presentation -ne 31 -or [long]$settled31.capture.record.presentation -ne 31 -or $script:captureSettleTestCalls -ne 1) {
      throw "Capture settlement did not adopt latest equivalent complete frame 31 after expected frame 30."
    }
    $provenanceVariants = @(
      [pscustomobject]@{ name = "background press leak"; values = @{ BackgroundPresses = 1 } },
      [pscustomobject]@{ name = "background release leak"; values = @{ BackgroundReleases = 1 } },
      [pscustomobject]@{ name = "guarded press leak"; values = @{ GuardedPresses = 1 } },
      [pscustomobject]@{ name = "guarded release leak"; values = @{ GuardedReleases = 1 } },
      [pscustomobject]@{ name = "native begin counter"; values = @{ NativeBegin = 2 } },
      [pscustomobject]@{ name = "native cancel counter"; values = @{ NativeCancel = 1 } },
      [pscustomobject]@{ name = "native end counter"; values = @{ NativeEnd = 1 } },
      [pscustomobject]@{ name = "native records counter"; values = @{ NativeRecords = 1 } },
      [pscustomobject]@{ name = "native stale-record counter"; values = @{ NativeStaleRecords = 1 } },
      [pscustomobject]@{ name = "native rejected-record counter"; values = @{ NativeRejectedRecords = 1 } },
      [pscustomobject]@{ name = "native owner sequence"; values = @{ NativeOwnerSequence = "1" } },
      [pscustomobject]@{ name = "native owner composing"; values = @{ NativeOwnerComposing = $true } },
      [pscustomobject]@{ name = "IMM32 mode"; values = @{ ExperimentalImm32 = $false } }
    )
    $variantPresentation = 36
    foreach ($variant in $provenanceVariants) {
      $variantArgs = @{ Presentation = $variantPresentation; ActiveIndex = 15; VisibleStart = 8; Sequence = 73 + $variantPresentation; NativeUpdate = 31 }
      foreach ($key in $variant.values.Keys) { $variantArgs[$key] = $variant.values[$key] }
      [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog @variantArgs), $utf8NoBom)
      $variantFrame = Get-LatestFrame $path
      if ($null -eq $variantFrame -or (Test-CaptureSemanticState $scroll30.State $variantFrame.State) -or
          (Get-CaptureBracketDecision $scroll30 $variantFrame $scroll30.State) -ne "SEMANTIC_STATE_CHANGED_DURING_CAPTURE") {
        throw "Capture semantic identity accepted changed $($variant.name) provenance."
      }
      $script:captureSettleTestFrame = $variantFrame; $script:captureSettleTestCalls = 0
      $variantSettle = Invoke-CaptureStableRetry $null "scroll-active-row" $scroll30 $null $testFrameReader $testStableCapture 1000 3 0
      if ($variantSettle.status -ne "SEMANTIC_STATE_CHANGED" -or $script:captureSettleTestCalls -ne 0) {
        throw "Runtime capture settlement did not reject changed $($variant.name) before capture."
      }
      $variantPresentation++
    }
    $script:captureSettleTestFrame = $scroll31
    $throwingCapture = { param($ignoredOwner, $captureName, $candidate, $expectedFrame, $extraData, $captureNumber) throw "synthetic BitBlt failure" }
    $captureFailure = Invoke-CaptureStableRetry $null "capture-exception" $scroll30 $null $testFrameReader $throwingCapture 1000 3 0
    if ($captureFailure.status -ne "FAIL" -or $captureFailure.attempts.Count -ne 1 -or
        $captureFailure.attempts[0].status -ne "CAPTURE_EXCEPTION" -or
        $captureFailure.attempts[0].frame_identity -cne (Get-FrameIdentity $scroll31) -or
        $captureFailure.attempts[0].error -ne "synthetic BitBlt failure") {
      throw "Capture callback failure escaped or was not retained as a terminal failed attempt with frame identity."
    }
    $failureManifest = [string]$captureFailure.attempts[0].attempt_manifest
    if (-not (Test-Path -LiteralPath $failureManifest)) { throw "Capture callback failure did not write its per-attempt sidecar." }
    $failureManifestData = Get-Content -Raw -LiteralPath $failureManifest | ConvertFrom-Json -AsHashtable
    if ($failureManifestData.status -ne "CAPTURE_EXCEPTION" -or
        $failureManifestData.frame_identity -cne (Get-FrameIdentity $scroll31) -or
        $failureManifestData.error -ne "synthetic BitBlt failure") {
      throw "Per-attempt capture failure sidecar omitted its frame identity or error."
    }
    Remove-Item -LiteralPath $failureManifest
    $script:captureSettleTestFrame = $scrollChanged; $script:captureSettleTestCalls = 0
    $changedSettle = Invoke-CaptureStableRetry $null "scroll-active-row" $scroll30 $null $testFrameReader $testStableCapture 1000 3 0
    if ($changedSettle.status -ne "SEMANTIC_STATE_CHANGED" -or $script:captureSettleTestCalls -ne 0) { throw "Capture settlement captured after the requested active-row state changed." }
    [IO.File]::WriteAllLines($path, [string[]](New-CaptureScrollWireLog -Presentation 30 -ActiveIndex 15 -VisibleStart 8 -Sequence 61 -NativeUpdate 26) + [string[]](Add-MockPendingFrame 31), $utf8NoBom)
    if ($null -ne (Get-LatestFrame $path)) { throw "Capture parser accepted presentation 30 after newer presentation 31 remained incomplete." }
    $script:captureSettleTestLogPath = $path
    $pendingReader = { param($ignoredOwner) Get-LatestFrame $script:captureSettleTestLogPath }
    $pendingSettle = Invoke-CaptureStableRetry $null "pending-frame" $scroll30 $null $pendingReader $testStableCapture 1000 3 0
    if ($pendingSettle.status -ne "TIMEOUT" -or $pendingSettle.attempts.Count -ne 3 -or $script:captureSettleTestCalls -ne 0) { throw "Capture settlement did not fail boundedly while no complete readback tuple existed." }
    $script:captureSettleQueue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($queuedFrame in @($scroll30, $scroll31, $scroll32)) { $script:captureSettleQueue.Enqueue($queuedFrame) }
    $script:captureSettleFallback = $scroll32
    $script:captureSettleAfterFrames = @($scroll31, $scroll32, $scroll33, $scroll34)
    $script:captureSettleExpected = $scroll30
    $unstableReader = { param($ignoredOwner) if ($script:captureSettleQueue.Count -gt 0) { return $script:captureSettleQueue.Dequeue() }; return $script:captureSettleFallback }
    $unstableCapture = { param($ignoredOwner, $captureName, $candidate, $expectedFrame, $extraData, $captureNumber) $afterFrame = $script:captureSettleAfterFrames[$captureNumber - 1]; $decision = Get-CaptureBracketDecision $candidate $afterFrame $script:captureSettleExpected.State; [pscustomobject]@{ status = $decision; record = $null; reason = "simulated continuing frame advancement" } }
    $unstableSettle = Invoke-CaptureStableRetry $null "scroll-active-row" $scroll30 $null $unstableReader $unstableCapture 1000 3 0
    if ($unstableSettle.status -ne "TIMEOUT" -or $unstableSettle.attempts.Count -ne 3 -or
        @($unstableSettle.attempts | Where-Object { $_.status -ne "RETRY_NEWER_EQUIVALENT_FRAME" }).Count -ne 0) {
      throw "Capture settlement incorrectly passed while equivalent presentations advanced on every bounded attempt."
    }
    if (-not (Test-ImeGuardDelta ([ordered]@{ guarded_presses = 2; guarded_releases = 3 }) 2 3) -or
        -not (Test-ImeGuardDelta ([ordered]@{ guarded_presses = 3; guarded_releases = 4 }) 2 3) -or
        -not (Test-ImeGuardDelta ([ordered]@{ guarded_presses = 2; guarded_releases = 4 }) 2 3 -AllowSingleRelease) -or
        (Test-ImeGuardDelta ([ordered]@{ guarded_presses = 3; guarded_releases = 3 }) 2 3)) { throw "Native IME OS-consumed/app-guard event pair classification regression." }
    [IO.File]::WriteAllLines($path, [string[]](New-FilteredWireLog -Query "Go" -CommandIndex 1), $utf8NoBom)
    $filteredGo = Get-LatestFrame $path
    if ($null -eq $filteredGo -or $filteredGo.State.active_id -ne "palette.command.1" -or [long]$filteredGo.State.active_index[0] -ne 0) { throw "Parser rejected the committed Go filter's filtered active index 0 / command.1 identity." }
    [IO.File]::WriteAllLines($path, [string[]](New-FilteredWireLog -Query "日本語" -CommandIndex 3 -Presentation 8), $utf8NoBom)
    $filteredJapanese = Get-LatestFrame $path
    if ($null -eq $filteredJapanese -or $filteredJapanese.State.active_id -ne "palette.command.3" -or [long]$filteredJapanese.State.active_index[0] -ne 0) { throw "Parser rejected the Japanese result's filtered active index 0 / command.3 identity." }
    [IO.File]::WriteAllLines($path, [string[]](New-RetainedClosedWireLog), $utf8NoBom)
    $closed = Get-LatestFrame $path
    if ($null -eq $closed -or [bool]$closed.State.open -or $null -ne $closed.State.active_id -or $closed.Complete.active_id -ne "palette.command.0") { throw "Parser rejected the retained closed STATE/COMPLETE shape." }
    [IO.File]::WriteAllLines($path, [string[]](New-RetainedNoActiveWireFrame 43), $utf8NoBom)
    $emptyResult = Get-LatestFrame $path
    if ($null -eq $emptyResult -or [long]$emptyResult.State.presentation -ne 43 -or
        -not [bool]$emptyResult.State.open -or [string]$emptyResult.State.query -cne "zzzz" -or
        [int]$emptyResult.State.matches -ne 0 -or [int]$emptyResult.State.visible_count -ne 0 -or
        $null -ne $emptyResult.State.active_index -or $null -ne $emptyResult.State.active_id) {
      throw "Parser rejected the retained P43 open zero-match frame with explicit Option None/null."
    }
    $emptySemanticIdentity = Get-CaptureSemanticIdentity $emptyResult.State | ConvertFrom-Json -AsHashtable
    if ($null -ne $emptySemanticIdentity.active_index) { throw "Capture semantic identity rewrote the P43 None selection as an array." }
    $missingIndexState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { if ($key -ne "active_index") { $missingIndexState[$key] = $emptyResult.State[$key] } }
    if (Test-FrameTuple $emptyResult.Accepted $missingIndexState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser confused a missing active_index key with explicit null Option None." }
    $missingActiveIdState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { if ($key -ne "active_id") { $missingActiveIdState[$key] = $emptyResult.State[$key] } }
    if (Test-FrameTuple $emptyResult.Accepted $missingActiveIdState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser confused a missing active_id key with explicit null Option None." }
    $missingCompleteId = [ordered]@{}; foreach ($key in $emptyResult.Complete.Keys) { if ($key -ne "active_id") { $missingCompleteId[$key] = $emptyResult.Complete[$key] } }
    if (Test-FrameTuple $emptyResult.Accepted $emptyResult.State $missingCompleteId $emptyResult.Readback) { throw "Tuple parser confused a missing COMPLETE active_id key with explicit null Option None." }
    $emptyListState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { $emptyListState[$key] = $emptyResult.State[$key] }; $emptyListState.active_index = @()
    if (Test-FrameTuple $emptyResult.Accepted $emptyListState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser accepted an empty array as a wire Option None." }
    $stringIndexState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { $stringIndexState[$key] = $emptyResult.State[$key] }; $stringIndexState.active_index = @("0")
    if (Test-FrameTuple $emptyResult.Accepted $stringIndexState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser accepted a string payload as an integer Some index." }
    $multiIndexState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { $multiIndexState[$key] = $emptyResult.State[$key] }; $multiIndexState.active_index = @(0, 1)
    if (Test-FrameTuple $emptyResult.Accepted $multiIndexState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser accepted malformed multiple Some indices." }
    $someWithoutIndexState = [ordered]@{}; foreach ($key in $emptyResult.State.Keys) { $someWithoutIndexState[$key] = $emptyResult.State[$key] }; $someWithoutIndexState.active_id = "palette.command.0"
    if (Test-FrameTuple $emptyResult.Accepted $someWithoutIndexState $emptyResult.Complete $emptyResult.Readback) { throw "Tuple parser accepted active_id Some with active_index None." }
    $mismatchedNoneComplete = [ordered]@{}; foreach ($key in $emptyResult.Complete.Keys) { $mismatchedNoneComplete[$key] = $emptyResult.Complete[$key] }; $mismatchedNoneComplete.active_id = "palette.command.0"
    if (Test-FrameTuple $emptyResult.Accepted $emptyResult.State $mismatchedNoneComplete $emptyResult.Readback) { throw "Tuple parser accepted a Some completion ID for a None state selection." }
    $staleNoneReadback = [ordered]@{}; foreach ($key in $emptyResult.Readback.Keys) { $staleNoneReadback[$key] = $emptyResult.Readback[$key] }; $staleNoneReadback.frame_event_sequence = [long]$staleNoneReadback.frame_event_sequence + 1
    if (Test-FrameTuple $emptyResult.Accepted $emptyResult.State $emptyResult.Complete $staleNoneReadback) { throw "Tuple parser accepted stale readback for the retained P43 frame." }
    [IO.File]::AppendAllLines($path, [string[]](New-RetainedNoActiveWireFrame 44), $utf8NoBom)
    $closedEmptyResult = Get-LatestFrame $path
    if ($null -eq $closedEmptyResult -or [long]$closedEmptyResult.State.presentation -ne 44 -or
        [bool]$closedEmptyResult.State.open -or $null -ne $closedEmptyResult.State.active_index -or
        $null -ne $closedEmptyResult.State.active_id -or $null -ne $closedEmptyResult.Complete.active_id) {
      throw "Parser rejected the retained P44 closed frame with explicit Option None/null."
    }
    [IO.File]::WriteAllLines($path, [string[]](New-MockLog -Mismatch), $utf8NoBom)
    if ($null -ne (Get-LatestFrame $path)) { throw "Parser accepted mismatched completion/readback sequence." }
    [IO.File]::WriteAllLines($path, [string[]](New-MockLog -StateMismatch), $utf8NoBom)
    if ($null -ne (Get-LatestFrame $path)) { throw "Parser accepted a STATE query that disagreed with ACCEPTED/COMPLETE." }
    [IO.File]::WriteAllLines($path, @("GPUI_WINDOWS_COMMAND_PALETTE_READBACK_UNAVAILABLE {}") + [string[]](New-MockLog), $utf8NoBom)
    $rejected = $false
    try { $null = Get-LatestFrame $path } catch { $rejected = $_.Exception.Message -match "READBACK_UNAVAILABLE" }
    if (-not $rejected) { throw "Parser accepted READBACK_UNAVAILABLE." }
    [IO.File]::WriteAllLines($path, [string[]](New-MockLog) + [string[]](Add-MockPendingFrame 5), $utf8NoBom)
    if ($null -ne (Get-LatestFrame $path)) { throw "Parser returned completed frame 4 despite newer accepted/state frame 5 lacking completion/readback." }
    $smokePath = Join-Path $buildRoot "logs/smoke.stdout.log"
    if (Test-Path -LiteralPath $smokePath) {
      $smoke = Get-LatestFrame $smokePath
      if ($null -eq $smoke -or -not [bool]$smoke.State.open -or $smoke.State.active_id -ne $smoke.Complete.active_id) { throw "Parser did not accept the retained actual native smoke frame." }
    }
    $negativeCondition = $false
    try { Assert-Condition $false "expected condition guard failure" } catch { $negativeCondition = $_.Exception.Message -match "expected condition guard failure" }
    if (-not $negativeCondition) { throw "Assertion helper did not reject false." }
    $emptyStderrDiagnostic = Format-ExitedChildDiagnostic "process exited with code 0" "last stdout record" $true $null $true
    if ($emptyStderrDiagnostic -notmatch "process exited with code 0" -or
        $emptyStderrDiagnostic -notmatch "stderr tail=<empty log>" -or
        $emptyStderrDiagnostic -match "Substring") { throw "Child-exit formatter hid the process diagnostic when stderr exists but is empty." }
    $missingLogsDiagnostic = Format-ExitedChildDiagnostic "process handle disappeared" $null $false $null $false
    if ($missingLogsDiagnostic -notmatch "process handle disappeared" -or
        $missingLogsDiagnostic -notmatch "stdout tail=<missing log>" -or
        $missingLogsDiagnostic -notmatch "stderr tail=<missing log>") { throw "Child-exit formatter did not safely describe missing log files." }
    $exitStdoutPath = Join-Path $runDir "validate-child-exit.stdout.log"
    $exitStderrPath = Join-Path $runDir "validate-child-exit.stderr.log"
    try {
      [IO.File]::WriteAllText($exitStdoutPath, "", $utf8NoBom)
      [IO.File]::WriteAllText($exitStderrPath, "", $utf8NoBom)
      $missingOwner = [pscustomobject]@{ pid = [int]::MaxValue; start_ticks = 0L; stdout = $exitStdoutPath; stderr = $exitStderrPath }
      $waitExitDiagnostic = $null
      try { $null = Wait-ForFrame $missingOwner 0 { param($state) $false } 1 } catch { $waitExitDiagnostic = $_.Exception.Message }
      if ($waitExitDiagnostic -notmatch "Owned fixture exited before predicate" -or
          $waitExitDiagnostic -notmatch "stderr tail=<empty log>" -or
          $waitExitDiagnostic -match "Substring") { throw "Wait-ForFrame did not preserve the fake child's exit diagnostic with empty log files." }
    } finally {
      Remove-Item -LiteralPath $exitStdoutPath, $exitStderrPath -ErrorAction SilentlyContinue
    }
    # Exact input_events array retained from user run 20261007T142455481Z;
    # keep this deterministic fixture so Validate does not depend on _build.
    $inputBatchFixturePath = Join-Path $PSScriptRoot "testdata/windows-command-palette-input-events-25-batches.json"
    $actualInputBatches = @(Get-Content -Raw -LiteralPath $inputBatchFixturePath | ConvertFrom-Json -AsHashtable)
    $actualInputTotals = Get-InputEventTotals $actualInputBatches
    if ($actualInputTotals.batch_count -ne 25 -or
        $actualInputTotals.requested_keyboard_events_total -ne 58 -or
        $actualInputTotals.inserted_keyboard_events_total -ne 58) {
      throw "Retained actual 25-batch input_events wire fixture did not total 58 requested / 58 inserted."
    }
    $emptyInputBatches = [System.Collections.Generic.List[object]]::new()
    $emptyInputTotals = Get-InputEventTotals $emptyInputBatches
    if ($emptyInputTotals.batch_count -ne 0 -or $emptyInputTotals.requested_keyboard_events_total -ne 0 -or
        $emptyInputTotals.inserted_keyboard_events_total -ne 0) { throw "Zero-batch input evidence did not total 0 / 0." }
    $rejectedMissingInputList = $false
    try { $null = Get-InputEventTotals -Events $null } catch { $rejectedMissingInputList = $true }
    if (-not $rejectedMissingInputList) { throw "Input totals confused missing input_events with a valid zero-batch list." }
    $partialInputEvent = [ordered]@{ action = "partial regression"; virtual_keys = @(65, 65, 66, 66); requested = 4; inserted = 2 }
    $partialInputTotals = Get-InputEventTotals @($partialInputEvent)
    if ($partialInputTotals.batch_count -ne 1 -or $partialInputTotals.requested_keyboard_events_total -ne 4 -or
        $partialInputTotals.inserted_keyboard_events_total -ne 2) { throw "Partial insertion evidence was not reported accurately." }
    $malformedInputCases = @(
      [pscustomobject]@{ name = "missing requested"; event = [ordered]@{ action = "missing requested"; virtual_keys = @(65); inserted = 1 } },
      [pscustomobject]@{ name = "missing inserted"; event = [ordered]@{ action = "missing inserted"; virtual_keys = @(65); requested = 1 } },
      [pscustomobject]@{ name = "string count"; event = [ordered]@{ action = "string count"; virtual_keys = @(65); requested = "1"; inserted = 1 } },
      [pscustomobject]@{ name = "string inserted"; event = [ordered]@{ action = "string inserted"; virtual_keys = @(65); requested = 1; inserted = "1" } },
      [pscustomobject]@{ name = "fractional requested"; event = [ordered]@{ action = "fractional requested"; virtual_keys = @(65); requested = 1.5; inserted = 1 } },
      [pscustomobject]@{ name = "key count mismatch"; event = [ordered]@{ action = "key count mismatch"; virtual_keys = @(65); requested = 2; inserted = 1 } },
      [pscustomobject]@{ name = "inserted exceeds requested"; event = [ordered]@{ action = "inserted exceeds requested"; virtual_keys = @(65); requested = 1; inserted = 2 } },
      [pscustomobject]@{ name = "invalid virtual key"; event = [ordered]@{ action = "invalid virtual key"; virtual_keys = @("A"); requested = 1; inserted = 1 } }
    )
    foreach ($case in $malformedInputCases) {
      $rejectedInput = $false
      try { $null = Get-InputEventTotals @($case.event) } catch { $rejectedInput = $true }
      if (-not $rejectedInput) { throw "Input-event totals accepted malformed $($case.name) evidence." }
    }
    Invoke-OwnershipGuardTests
  } finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
  }
}

function Invoke-OwnershipGuardTests {
  $process = Get-Process -Id $PID -ErrorAction Stop
  $image = [PaletteE2E.Win32]::QueryProcessImagePath([uint32]$PID)
  if (-not $image.Success -or -not $image.Path) { throw "Validate could not resolve its own executable path for ownership guard tests; Win32=$($image.LastError)." }
  $base = [ordered]@{
    pid = [int]$PID
    start_ticks = [long]$process.StartTime.ToUniversalTime().Ticks
    executable = [IO.Path]::GetFullPath($image.Path)
    executable_sha256 = (Get-FileHash -LiteralPath $image.Path -Algorithm SHA256).Hash
    hwnd = 0L
    role = "validate-only"
  }
  $wrongStart = [ordered]@{}; foreach ($key in $base.Keys) { $wrongStart[$key] = $base[$key] }; $wrongStart.start_ticks = [long]$wrongStart.start_ticks + 1
  $wrongPath = [ordered]@{}; foreach ($key in $base.Keys) { $wrongPath[$key] = $base[$key] }; $wrongPath.executable = [IO.Path]::Combine([IO.Path]::GetDirectoryName($base.executable), "not-the-owned-process.exe")
  $wrongHash = [ordered]@{}; foreach ($key in $base.Keys) { $wrongHash[$key] = $base[$key] }; $wrongHash.executable_sha256 = "0" * 64
  $missingHwnd = [ordered]@{}; foreach ($key in $base.Keys) { if ($key -ne "hwnd") { $missingHwnd[$key] = $base[$key] } }
  $zeroHwnd = [ordered]@{}; foreach ($key in $base.Keys) { $zeroHwnd[$key] = $base[$key] }; $zeroHwnd.hwnd = 0L
  $cases = @(
    [pscustomobject]@{ name = "wrong_start_ticks"; owner = $wrongStart; expected = "reused" },
    [pscustomobject]@{ name = "mismatched_executable_path"; owner = $wrongPath; expected = "executable path changed" },
    [pscustomobject]@{ name = "mismatched_executable_hash"; owner = $wrongHash; expected = "executable hash changed" },
    [pscustomobject]@{ name = "missing_hwnd"; owner = $missingHwnd; expected = "visible window" },
    [pscustomobject]@{ name = "zero_hwnd"; owner = $zeroHwnd; expected = "visible window" }
  )
  $beforeEvents = $script:result.input_events.Count
  foreach ($case in $cases) {
    $message = $null
    try {
      Invoke-OwnedInput $case.owner "validate rejection $($case.name)" ([ushort[]]@(0x41, 0x41)) ([bool[]]@($false, $true))
    } catch { $message = $_.Exception.Message }
    if ($null -eq $message -or $message -notmatch [regex]::Escape($case.expected)) { throw "Ownership guard did not reject $($case.name) before SendInput: $message" }
  }
  if ($script:result.input_events.Count -ne $beforeEvents) { throw "Invalid-owner validation recorded an injected input event." }
  $missingImage = [PaletteE2E.Win32]::QueryProcessImagePath([uint32]::MaxValue)
  if ($missingImage.Success -or $missingImage.LastError -eq 0) { throw "Native process-image query accepted a nonexistent PID or omitted its Win32 error." }
  Assert-OwnedWindowDiscoveryRegressionTests

  $tokens = $null; $parseErrors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count -gt 0) { throw "PowerShell parser rejected the E2E script during ownership-order checks." }
  $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
  $inputBody = ($functions | Where-Object { $_.Name -eq "Invoke-OwnedInput" } | Select-Object -First 1).Body.Extent.Text
  $closeBody = ($functions | Where-Object { $_.Name -eq "Close-OwnedFixture" } | Select-Object -First 1).Body.Extent.Text
  $waitBody = ($functions | Where-Object { $_.Name -eq "Wait-OwnedWindow" } | Select-Object -First 1).Body.Extent.Text
  $frameWaitBody = ($functions | Where-Object { $_.Name -eq "Wait-ForFrame" } | Select-Object -First 1).Body.Extent.Text
  $captureBody = ($functions | Where-Object { $_.Name -eq "Capture-OwnedClient" } | Select-Object -First 1).Body.Extent.Text
  $captureCoreBody = ($functions | Where-Object { $_.Name -eq "Capture-OwnedClientCore" } | Select-Object -First 1).Body.Extent.Text
  $imeSnapshotBody = ($functions | Where-Object { $_.Name -eq "Get-ImeSnapshot" } | Select-Object -First 1).Body.Extent.Text
  $candidateBody = ($functions | Where-Object { $_.Name -eq "Query-CandidateGeometry" } | Select-Object -First 1).Body.Extent.Text
  $restoreImeBody = ($functions | Where-Object { $_.Name -eq "Restore-OwnedIme" } | Select-Object -First 1).Body.Extent.Text
  $startFixtureBody = ($functions | Where-Object { $_.Name -eq "Start-OwnedFixture" } | Select-Object -First 1).Body.Extent.Text
  if ([string]::IsNullOrEmpty($inputBody) -or $inputBody.IndexOf('Assert-OwnedProcess $Owner', [StringComparison]::Ordinal) -lt 0 -or
      $inputBody.IndexOf('Assert-OwnedProcess $Owner', [StringComparison]::Ordinal) -gt $inputBody.IndexOf("SendEvents(", [StringComparison]::Ordinal)) {
    throw "Input path no longer validates exact process ownership before SendInput."
  }
  if ($inputBody.IndexOf('$native.Inserted -ne $native.Requested', [StringComparison]::Ordinal) -lt 0) {
    throw "Per-batch SendInput inserted-count guard was removed or weakened."
  }
  if ([string]::IsNullOrEmpty($closeBody) -or $closeBody.IndexOf('Assert-OwnedProcess $Owner', [StringComparison]::Ordinal) -lt 0 -or
      $closeBody.IndexOf('Assert-OwnedProcess $Owner', [StringComparison]::Ordinal) -gt $closeBody.IndexOf("SendClose(", [StringComparison]::Ordinal)) {
    throw "Close path no longer validates exact process ownership before WM_CLOSE."
  }
  if ([string]::IsNullOrEmpty($waitBody) -or $waitBody -notmatch 'Select-OwnedGpuiWindow' -or $waitBody -match '\.Title\s+-match') {
    throw "Window discovery must select the exact native GPUI class and cannot require a caption."
  }
  if ([string]::IsNullOrEmpty($frameWaitBody) -or $frameWaitBody -notmatch 'Format-ExitedChildDiagnostic') { throw "Wait-ForFrame must use the tested safe child-exit log formatter." }
  $sourceText = [IO.File]::ReadAllText($PSCommandPath)
  if ($sourceText -notmatch 'Get-InputEventTotals\s+\$script:result\.input_events' -or
      $sourceText -match 'Measure-Object\s+-Property\s+(requested|inserted)\s+-Sum') {
    throw "Final evidence must compute keyboard totals through the validated explicit input-event helper."
  }
  if ([string]::IsNullOrEmpty($captureBody) -or $captureBody -notmatch 'Invoke-CaptureStableRetry' -or
      [string]::IsNullOrEmpty($captureCoreBody) -or $captureCoreBody -notmatch 'Get-CaptureBracketDecision' -or
      $captureCoreBody -notmatch 'Test-CandidateGeometryMatchesFrame') {
    throw "Runtime pixel capture must use bounded semantic settling, strict frame bracketing, and candidate-geometry provenance checks."
  }
  if (-not [PaletteE2E.Win32]::ValidateImeBridgeProtocol()) { throw "Scalar owner-thread IMM bridge request packing/status protocol failed its deterministic regression." }
  $interopSource = [IO.File]::ReadAllText($interop)
  if ($interopSource -match 'ImmGetContext|ImmReleaseContext|ImmGetOpenStatus|ImmSetOpenStatus|ImmGetConversionStatus|ImmSetConversionStatus|ImmGetCandidateWindow') {
    throw "E2E helper must not call IMM32 directly from the driver thread."
  }
  if ($interopSource -notmatch 'SendMessageTimeoutW' -or $interopSource -notmatch 'SMTO_ABORTIFHUNG' -or
      $interopSource -notmatch 'SMTO_ERRORONEXIT' -or $interopSource -notmatch 'VerifyImeBridgeTarget') {
    throw "E2E IMM transport lost its bounded scalar request or exact target checks."
  }
  if ([string]::IsNullOrEmpty($imeSnapshotBody) -or
      $imeSnapshotBody.IndexOf('Assert-DefaultInputDesktop', [StringComparison]::Ordinal) -gt $imeSnapshotBody.IndexOf('QueryIme(', [StringComparison]::Ordinal) -or
      $imeSnapshotBody.IndexOf('Assert-OwnedForeground', [StringComparison]::Ordinal) -gt $imeSnapshotBody.IndexOf('QueryIme(', [StringComparison]::Ordinal) -or
      $imeSnapshotBody.LastIndexOf('Assert-OwnedForeground', [StringComparison]::Ordinal) -lt $imeSnapshotBody.IndexOf('QueryIme(', [StringComparison]::Ordinal)) {
    throw "IME snapshot path must check Default desktop and exact foreground before and after the bridge query."
  }
  if ([string]::IsNullOrEmpty($candidateBody) -or
      $candidateBody.IndexOf('Get-CurrentFrame $Owner', [StringComparison]::Ordinal) -gt $candidateBody.IndexOf('QueryCandidate(', [StringComparison]::Ordinal) -or
      $candidateBody.LastIndexOf('Get-CurrentFrame $Owner', [StringComparison]::Ordinal) -lt $candidateBody.IndexOf('QueryCandidate(', [StringComparison]::Ordinal) -or
      $candidateBody -notmatch 'Assert-OwnedForeground' -or $candidateBody -notmatch 'Assert-DefaultInputDesktop') {
    throw "Candidate query must stay bracketed by the matching stable frame and exact owned foreground on Default desktop."
  }
  if ([string]::IsNullOrEmpty($restoreImeBody) -or
      $restoreImeBody.IndexOf('Assert-OwnedForeground $Owner', [StringComparison]::Ordinal) -gt $restoreImeBody.IndexOf('RestoreIme(', [StringComparison]::Ordinal) -or
      $restoreImeBody -notmatch 'Assert-DefaultInputDesktop') {
    throw "IME restoration must validate the exact owned foreground and desktop before its owner-thread setter."
  }
  $nativeBridgeSource = [IO.File]::ReadAllText((Join-Path $repo 'windows/text_input.inc'))
  if ($nativeBridgeSource -notmatch 'GetCurrentThreadId\(\)\s*!=\s*host->owner_thread' -or
      $nativeBridgeSource -notmatch 'gpui_ime_bridge_read_candidate_field' -or
      $nativeBridgeSource -notmatch 'GPUI_IME_BRIDGE_STATUS_STALE_SNAPSHOT' -or
      $nativeBridgeSource -notmatch 'request_nonce\s*!=\s*host->ime_bridge_nonce' -or
      $nativeBridgeSource.IndexOf('request_nonce != host->ime_bridge_nonce', [StringComparison]::Ordinal) -gt
        $nativeBridgeSource.IndexOf('switch ((int32_t)operation)', [StringComparison]::Ordinal)) {
    throw "Native bridge must authenticate the scalar nonce before dispatch, enforce owner-thread dispatch, and preserve snapshot-ID coherence."
  }
  if ([string]::IsNullOrEmpty($startFixtureBody) -or
      $startFixtureBody -notmatch 'RandomNumberGenerator\]::Fill' -or
      $startFixtureBody -notmatch 'GPUI_WINDOWS_COMMAND_PALETTE_IME_NONCE' -or
      $startFixtureBody -notmatch 'bridge_nonce\s*=\s*\$bridgeNonce' -or
      $startFixtureBody -notmatch 'finally') {
    throw "IME fixture startup must create a per-run nonzero bridge nonce, pass it only to the child environment, and restore the parent environment."
  }
}

function Get-GitIdentity {
  $head = (& git rev-parse HEAD).Trim()
  if ($LASTEXITCODE -ne 0) { throw "git rev-parse failed." }
  $dirty = @(& git status --porcelain)
  if ($LASTEXITCODE -ne 0) { throw "git status failed." }
  return [pscustomobject]@{ Head = $head; Dirty = $dirty; Clean = ($dirty.Count -eq 0) }
}

function Ensure-Build {
  $identity = Get-GitIdentity
  $script:result.source_head = $identity.Head
  $script:result.source_clean = $identity.Clean
  if (-not $identity.Clean) { throw "Run mode requires a clean committed source tree; dirty=$($identity.Dirty -join '; ')." }
  if (-not $NoBuild) {
    & (Join-Path $PSScriptRoot "run_windows_command_palette.ps1") -Mode Build
    if ($LASTEXITCODE -ne 0) { throw "Pinned Windows command-palette build returned $LASTEXITCODE." }
  }
  if (-not (Test-Path $binary) -or -not (Test-Path $buildManifestPath)) { throw "Expected executable/build manifest is missing." }
  $manifest = Get-Content -Raw $buildManifestPath | ConvertFrom-Json -AsHashtable
  $manifestSha = (Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
  $sha = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($manifest.source_head -ne $identity.Head -or [bool]$manifest.worktree_dirty -or
      -not [string]::Equals($manifest.executable_sha256, $sha, [StringComparison]::OrdinalIgnoreCase)) { throw "Build manifest does not match clean source and binary hash." }
  $manifestCopy = Join-Path $runDir "build-manifest.json"
  Copy-Item -LiteralPath $buildManifestPath -Destination $manifestCopy -Force
  $script:result.executable_sha256 = $sha
  $script:result.build_manifest_sha256 = $manifestSha
  $script:result.run_build_manifest = $manifestCopy
  $script:result.toolchain = $manifest.toolchain
  $script:result.build_host = $manifest.host
  $script:result.runtime_profile = $manifest.runtime_profile
  Save-Result
}

function Test-OpenEmpty {
  param([object]$State)
  return [bool]$State.open -and [string]::IsNullOrEmpty([string]$State.field_text) -and
    [string]::IsNullOrEmpty([string]$State.committed_text) -and [int]$State.visible_count -eq 8
}

function Test-StateOptionDisabled {
  param([object]$State, [int]$Index)
  $options = @($State.semantic.options | Where-Object { [int]$_.index -eq $Index })
  return $options.Count -eq 1 -and [bool]$options[0].disabled
}

function Test-StateActiveIndex {
  param([object]$State, [int]$Expected, [switch]$AtLeast)
  if ($State.active_index -isnot [System.Collections.IList] -or $State.active_index.Count -ne 1 -or
      -not (Test-ExactInteger $State.active_index[0] 0 2147483647)) { return $false }
  if ($AtLeast) { return [long]$State.active_index[0] -ge $Expected }
  return [long]$State.active_index[0] -eq $Expected
}

function Test-ImeGuardDelta {
  param([object]$State, [int]$PressBefore, [int]$ReleaseBefore, [switch]$AllowSingleRelease)
  $pressDelta = [int]$State.guarded_presses - $PressBefore
  $releaseDelta = [int]$State.guarded_releases - $ReleaseBefore
  if ($pressDelta -eq 0 -and $releaseDelta -eq 0) { return $true }
  if ($pressDelta -eq 1 -and $releaseDelta -eq 1) { return $true }
  return $AllowSingleRelease -and $pressDelta -eq 0 -and $releaseDelta -eq 1
}

if ($Mode -eq "Validate") {
  Invoke-ParserTests
  [ordered]@{ status = "PASS"; input_size = [PaletteE2E.Win32]::InputStructureSize(); process_bits = [IntPtr]::Size * 8; input_events = 0; fixtures_launched = 0; tests = @("valid open observer tuple and disabled option", "filtered Go command.1/index0 observer identity", "filtered Japanese command.3/index0 observer identity", "retained closed STATE/COMPLETE wire shape", "actual P43 open-empty and P44 closed-empty frames parse explicit active_index:null", "reject missing active-index/id keys, empty/string/multiple arrays, Some/None mismatches and stale P43 readback", "reject mismatched completion/readback identity", "reject accepted/state query mismatch", "reject READBACK_UNAVAILABLE", "reject newer incomplete accepted/state frame", "Option None/single-index/malformed multi-index cases", "IME guard deltas: OS-consumed 0/0, app-guarded 1/1, and app-delivered Escape release 0/1", "scroll capture adopts equivalent presentation 31 after expected presentation 30 with only native update count changed", "reject leaked background/guarded key counters and changed IMM32/native owner/native record provenance before capture", "capture callback failure is retained as a terminal frame-identified attempt", "scroll capture rejects active-row semantic change and preserves 30→31 strict identity retry", "pending and persistent frame advancement time out without a green capture", "candidate geometry remains tied to the matching semantic caret state", "runtime capture uses bounded semantic settling and exact before/after identity", "blank-caption GPUI discovery ignores same-PID console and other-PID/invisible decoys", "ambiguous multiple same-PID GPUI windows rejected", "wrong start ticks/executable/hash/missing HWND/zero HWND rejected before input", "native QueryFullProcessImageNameW PID path plus SHA-256 ownership guard, including nonexistent-PID failure", "source ordering proves owner validation before SendInput and WM_CLOSE", "empty/missing stderr child-exit diagnostics preserve the process cause", "validated input-event total helper covers retained 25/58/58 array, zero batches, partial insertion, malformed counts, and unchanged per-batch guard", "IMM32 state, candidate form, and restore use bounded scalar owner-thread bridge with per-run nonce, target PID/thread, desktop, foreground, frame, and snapshot IDs checked") } | ConvertTo-Json -Depth 6
  return
}

if ($Mode -eq "Preflight") {
  $previous = [PaletteE2E.Win32]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
  $desktop = [PaletteE2E.Win32]::CheckInputDesktop()
  $status = if ($desktop.Success -and $desktop.Name -eq "Default") { "PASS" } else { "FAIL" }
  $preflight = [ordered]@{
    status = $status
    input_desktop = [ordered]@{ opened = $desktop.Success; name = $desktop.Name; win32_error = $desktop.LastError; required = "Default" }
    input_structure_size = [PaletteE2E.Win32]::InputStructureSize()
    process_bits = [IntPtr]::Size * 8
    dpi_context_set = ($previous -ne [IntPtr]::Zero)
    foreground_hwnd = "0x$('{0:X}' -f [PaletteE2E.Win32]::GetForegroundWindow().ToInt64())"
    launched_process_count = 0
    input_event_count = 0
    security_or_foreground_bypass = $false
    dependent_stages = [ordered]@{ native_input = "UNRUN"; palette = "UNRUN"; japanese_ime = "UNRUN"; full_client_pixels = "UNRUN"; candidate_popup_visual = "UNRUN" }
    note = "Read-only preflight. Access failure does not establish that the desktop is locked."
  }
  $preflight | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $runDir "preflight.json") -Encoding utf8
  if ($null -ne $previous -and $previous -ne [IntPtr]::Zero) { [void][PaletteE2E.Win32]::SetThreadDpiAwarenessContext($previous) }
  $preflight | ConvertTo-Json -Depth 8
  if ($status -ne "PASS") { exit 2 }
  return
}

$failed = $false
try {
  if (-not $IsWindows) { throw "Run mode requires Windows." }
  Ensure-Build
  $script:dpiPrevious = [PaletteE2E.Win32]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
  $script:result.dpi_context = [ordered]@{ requested = "PER_MONITOR_AWARE_V2"; set = ($script:dpiPrevious -ne [IntPtr]::Zero); coordinate_basis = "physical screen pixels" }
  if ($script:dpiPrevious -eq [IntPtr]::Zero) { throw "SetThreadDpiAwarenessContext failed; Win32=$([Runtime.InteropServices.Marshal]::GetLastWin32Error())." }
  $desktop = [PaletteE2E.Win32]::CheckInputDesktop()
  $script:result.input_desktop = [ordered]@{ opened = $desktop.Success; name = $desktop.Name; win32_error = $desktop.LastError; required = "Default" }
  if (-not $desktop.Success -or $desktop.Name -ne "Default") {
    Add-Stage "interactive_default_input_desktop" "FAIL" $script:result.input_desktop
    throw "BLOCKED: OpenInputDesktop failed or did not name the active Default input desktop (name='$($desktop.Name)', Win32=$($desktop.LastError)); no fixtures or input were attempted."
  }
  Add-Stage "interactive_default_input_desktop" "PASS" $script:result.input_desktop

  Start-Stage "startup_closed_frame"
  $script:aux = Start-OwnedFixture "auxiliary" $false $false
  $script:primary = Start-OwnedFixture "primary" $true $true
  Set-OwnedForeground $script:primary | Out-Null
  $startup = Wait-ForFrame $script:primary 0 { param($s) -not [bool]$s.open }
  Add-Stage "startup_closed_frame" "PASS" ([ordered]@{ presentation = $startup.State.presentation; event_sequence = $startup.Complete.event_sequence })
  Capture-OwnedClient $script:primary "startup-closed" $startup | Out-Null

  Start-Stage "initial_ime_snapshot_and_direct_input"
  $null = Snapshot-OriginalIme $script:primary
  $directInput = Ensure-DirectInputMode $script:primary
  Add-Stage "initial_ime_snapshot_and_direct_input" "PASS" ([ordered]@{ original_layout = $script:imeOriginal.hkl_hex; original_state = $script:imeOriginal.state; direct_input_mode = $directInput })

  Start-Stage "open_default_eight_rows"
  $open = Open-Palette $script:primary $startup
  Assert-Condition (Test-OpenEmpty $open.State) "Ctrl+K did not open an empty palette with eight visible rows."
  Assert-Condition ([int]$open.State.matches -eq 16) "Expected 16 unfiltered commands."
  Assert-Condition (Test-StateOptionDisabled $open.State 2) "Disabled command row is not reported disabled."
  Add-Stage "open_default_eight_rows" "PASS" ([ordered]@{ presentation = $open.State.presentation; open_epoch = $open.State.open_epoch; matches = $open.State.matches; visible_count = $open.State.visible_count; native_owner_at_accept = $open.State.native_owner; note = "The STATE observer is emitted before a newly opened native session begins; assert armed ownership after accepted committed input." })
  Capture-OwnedClient $script:primary "open-default-disabled-row" $open | Out-Null

  Start-Stage "disabled_row_navigation"
  for ($i = 0; $i -lt 2; $i++) { Send-KeyTap $script:primary "Down skip disabled" 0x28 }
  $skip = Wait-ForFrame $script:primary ([long]$open.State.presentation) { param($s) [bool]$s.open -and (Test-StateActiveIndex $s 3) }
  Add-Stage "disabled_row_navigation" "PASS" ([ordered]@{ active_index = $skip.State.active_index; disabled_index = 2; presentation = $skip.State.presentation })
  Capture-OwnedClient $script:primary "disabled-row-skip" $skip | Out-Null

  Start-Stage "navigation_scroll"
  for ($i = 0; $i -lt 12; $i++) { Send-KeyTap $script:primary "Down scroll to last row" 0x28 }
  $scroll = Wait-ForFrame $script:primary ([long]$skip.State.presentation) { param($s) [bool]$s.open -and (Test-StateActiveIndex $s 15) -and [int]$s.visible_start -gt 0 }
  Assert-Condition ([int]$scroll.State.visible_count -eq 8) "Scrolling changed the eight-row viewport bound."
  Add-Stage "navigation_scroll" "PASS" ([ordered]@{ active_index = $scroll.State.active_index; visible_start = $scroll.State.visible_start; visible_count = $scroll.State.visible_count; matches = $scroll.State.matches; presentation = $scroll.State.presentation })
  Capture-OwnedClient $script:primary "scroll-active-row" $scroll | Out-Null
  $guardPressBeforeNavigationClose = [int]$scroll.State.guarded_presses
  $guardReleaseBeforeNavigationClose = [int]$scroll.State.guarded_releases
  Send-KeyTap $script:primary "Escape close navigation palette" 0x1B
  $closed = Wait-ForFrame $script:primary ([long]$scroll.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.guarded_releases -eq ($guardReleaseBeforeNavigationClose + 1) }
  Assert-Condition ([int]$closed.State.actions -eq 0) "Navigation close activated a command."
  Assert-Condition ([int]$closed.State.guarded_presses -eq $guardPressBeforeNavigationClose) "Navigation Escape press was unexpectedly counted as a native guarded press."

  Start-Stage "ordinary_committed_search"
  $open2 = Open-Palette $script:primary $closed
  Assert-Condition (Test-OpenEmpty $open2.State) "Ordinary-search reopen was not empty."
  Send-RomanText $script:primary "Go"
  $go = Wait-ForFrame $script:primary ([long]$open2.State.presentation) { param($s) [bool]$s.open -and $s.field_text -eq "Go" -and $s.committed_text -eq "Go" -and [int]$s.matches -eq 1 }
  Assert-Condition ([string]$go.State.active_id -eq "palette.command.1") "Committed substring filter did not find Go to file."
  Assert-Condition ($null -ne $go.State.native_owner -and [long]$go.State.native_owner.native_epoch -gt 0) "Committed input did not arm a fresh native owner epoch."
  Add-Stage "ordinary_committed_search" "PASS" ([ordered]@{ field_text = $go.State.field_text; query = $go.State.query; matches = $go.State.matches; presentation = $go.State.presentation; native_owner = $go.State.native_owner })
  Capture-OwnedClient $script:primary "search-go" $go | Out-Null

  Start-Stage "empty_result"
  Send-KeyChord $script:primary "Ctrl+A select search" 0x11 0x41
  Send-KeyTap $script:primary "Backspace clear search" 0x08
  $clear = Wait-ForFrame $script:primary ([long]$go.State.presentation) { param($s) [bool]$s.open -and $s.field_text -eq "" -and [int]$s.matches -eq 16 }
  Send-RomanText $script:primary "zzzz"
  $noMatch = Wait-ForFrame $script:primary ([long]$clear.State.presentation) { param($s) [bool]$s.open -and $s.field_text -eq "zzzz" -and [int]$s.matches -eq 0 -and [int]$s.visible_count -eq 0 }
  Add-Stage "empty_result" "PASS" ([ordered]@{ query = $noMatch.State.query; matches = $noMatch.State.matches; active_id = $noMatch.State.active_id; presentation = $noMatch.State.presentation })
  Capture-OwnedClient $script:primary "empty-result" $noMatch | Out-Null

  Start-Stage "ordinary_activation_once"
  Send-KeyChord $script:primary "Ctrl+A clear empty result" 0x11 0x41
  Send-KeyTap $script:primary "Backspace clear empty result" 0x08
  $clear2 = Wait-ForFrame $script:primary ([long]$noMatch.State.presentation) { param($s) [bool]$s.open -and $s.field_text -eq "" }
  Send-RomanText $script:primary "Go"
  $go2 = Wait-ForFrame $script:primary ([long]$clear2.State.presentation) { param($s) [bool]$s.open -and $s.committed_text -eq "Go" -and [int]$s.matches -eq 1 }
  $actionBeforeEnter = [int]$go2.State.actions
  $backgroundPressBeforeEnter = [int]$go2.State.background_presses
  $backgroundReleaseBeforeEnter = [int]$go2.State.background_releases
  $guardPressBeforeEnter = [int]$go2.State.guarded_presses
  $guardReleaseBeforeEnter = [int]$go2.State.guarded_releases
  Send-KeyTap $script:primary "Enter activate Go to file" 0x0D
  $activated = Wait-ForFrame $script:primary ([long]$go2.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.actions -eq ($actionBeforeEnter + 1) -and [int]$s.guarded_releases -eq ($guardReleaseBeforeEnter + 1) }
  Assert-Condition ([string]$activated.State.last_action -eq "palette.command.1") "Fresh Enter did not activate exactly Go to file."
  Assert-Condition ([int]$activated.State.guarded_presses -eq $guardPressBeforeEnter) "Activation Enter press used the native-IME guard path unexpectedly."
  Assert-Condition ([int]$activated.State.background_presses -eq $backgroundPressBeforeEnter -and [int]$activated.State.background_releases -eq $backgroundReleaseBeforeEnter) "Activation Enter press/release leaked into the background path."
  Add-Stage "ordinary_activation_once" "PASS" ([ordered]@{ actions = $activated.State.actions; last_action = $activated.State.last_action; background_presses_unchanged = $true; background_releases_unchanged = $true })

  Start-Stage "background_key_recovery"
  Send-KeyTap $script:primary "fresh background Enter after activation" 0x0D
  $background = Wait-ForFrame $script:primary ([long]$activated.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.background_presses -eq ([int]$activated.State.background_presses + 1) -and [int]$s.background_releases -eq ([int]$activated.State.background_releases + 1) }
  Assert-Condition ([int]$background.State.actions -eq [int]$activated.State.actions) "Fresh background Enter activated a command."
  Add-Stage "background_key_recovery" "PASS" ([ordered]@{ presses_before = $activated.State.background_presses; presses_after = $background.State.background_presses; releases_before = $activated.State.background_releases; releases_after = $background.State.background_releases; actions = $background.State.actions })

  Start-Stage "japanese_ime_layout"
  Set-OwnedForeground $script:primary | Out-Null
  Ensure-JapaneseLayout $script:primary
  if ($script:japaneseLayout -eq [IntPtr]::Zero) {
    $script:unrun = $true
    Add-Stage "japanese_ime_layout" "UNRUN" $script:result.ime.japanese_layout
    Add-Stage "actual_japanese_ime_flow" "UNRUN" ([ordered]@{ reason = "Japanese layout unavailable." })
  } else {
    Add-Stage "japanese_ime_layout" "PASS" $script:result.ime.japanese_layout
    $jpOpen = Open-Palette $script:primary $background
    Assert-Condition (Test-OpenEmpty $jpOpen.State) "Japanese IME palette did not reopen empty."
    Start-Stage "japanese_ime_native_mode"
    $imeMode = Ensure-ImeNativeMode $script:primary
    Add-Stage "japanese_ime_native_mode" "PASS" $imeMode

    Start-Stage "japanese_preedit_real_ime"
    Send-RomanText $script:primary "nihongo"
    $preedit = Wait-ForFrame $script:primary ([long]$jpOpen.State.presentation) { param($s) [bool]$s.open -and [bool]$s.composing -and [string]::IsNullOrEmpty([string]$s.committed_text) -and ([string]$s.field_text -match "[\u3040-\u309F]") }
    Assert-Condition ([int]$preedit.State.matches -eq 16) "Provisional Japanese preedit changed the command filter."
    Add-Stage "japanese_preedit_real_ime" "PASS" ([ordered]@{ field_text = $preedit.State.field_text; committed_text = $preedit.State.committed_text; query = $preedit.State.query; composing = $preedit.State.composing; ime = Get-ImeSnapshot $script:primary; native_owner = $preedit.State.native_owner })

    Start-Stage "candidate_form_caret_geometry"
    $preeditCandidate = Query-CandidateGeometry $script:primary $preedit
    if ($preeditCandidate.status -ne "PASS") { Add-Stage "candidate_form_caret_geometry" "FAIL" ([ordered]@{ preedit = $preeditCandidate; phase = "preedit" }); throw "Preedit CANDIDATEFORM does not follow the search caret." }
    Capture-OwnedClient $script:primary "japanese-preedit" $preedit $preeditCandidate | Out-Null
    Send-KeyTap $script:primary "IME conversion Space" 0x20
    $conversion = Wait-ForFrame $script:primary ([long]$preedit.State.presentation) { param($s) [bool]$s.open -and [bool]$s.composing -and ([string]$s.field_text -match "日本語") }
    $convertedCandidate = Query-CandidateGeometry $script:primary $conversion
    if ($convertedCandidate.status -ne "PASS") { Add-Stage "candidate_form_caret_geometry" "FAIL" ([ordered]@{ preedit = $preeditCandidate; converted = $convertedCandidate; phase = "conversion" }); throw "Converted CANDIDATEFORM does not follow the search caret." }
    $candidateCapture = Capture-OwnedClient $script:primary "japanese-conversion" $conversion $convertedCandidate
    $candidateMoved = ($preeditCandidate.position_client_physical[0] -ne $convertedCandidate.position_client_physical[0] -or $preeditCandidate.position_client_physical[1] -ne $convertedCandidate.position_client_physical[1])
    if (-not $candidateMoved) {
      Add-Stage "candidate_form_caret_geometry" "FAIL" ([ordered]@{ preedit = $preeditCandidate; converted = $convertedCandidate; preedit_caret = $preedit.State.caret; converted_caret = $conversion.State.caret; reason = "The candidate form did not move with the changed preedit/converted caret." })
      throw "Candidate form geometry did not change between Japanese preedit and conversion."
    }
    Add-Stage "candidate_form_caret_geometry" "PASS" ([ordered]@{
      preedit = $preeditCandidate
      converted = $convertedCandidate
      preedit_caret = $preedit.State.caret
      converted_caret = $conversion.State.caret
      changed_caret_and_form_position = $candidateMoved
    })
    Add-Stage "candidate_popup_visual_placement" "UNRUN" ([ordered]@{ reason = "Candidate form is adapter geometry; retained client BMP needs human audit for visible popup placement."; popup_status = $convertedCandidate.popup_visual_status; bitmap = $candidateCapture.bitmap })

    Start-Stage "japanese_result_commit_without_activation"
  $actionsBeforeCommit = [int]$conversion.State.actions
  $backgroundPressBeforeCommit = [int]$conversion.State.background_presses
  $backgroundReleaseBeforeCommit = [int]$conversion.State.background_releases
  $guardPressBeforeCommit = [int]$conversion.State.guarded_presses
  $guardReleaseBeforeCommit = [int]$conversion.State.guarded_releases
  Send-KeyTap $script:primary "Enter commit IME conversion" 0x0D
  $committed = Wait-ForFrame $script:primary ([long]$conversion.State.presentation) { param($s) [bool]$s.open -and -not [bool]$s.composing -and $s.committed_text -eq "日本語" -and $s.query -eq "日本語" -and [int]$s.actions -eq $actionsBeforeCommit -and (Test-ImeGuardDelta $s $guardPressBeforeCommit $guardReleaseBeforeCommit) }
  Assert-Condition (Test-ImeGuardDelta $committed.State $guardPressBeforeCommit $guardReleaseBeforeCommit) "IME result Enter produced an incomplete native key-guard pair."
    Assert-Condition ([int]$committed.State.background_presses -eq $backgroundPressBeforeCommit -and [int]$committed.State.background_releases -eq $backgroundReleaseBeforeCommit) "IME result Enter changed background press/release counters."
    Add-Stage "japanese_result_commit_without_activation" "PASS" ([ordered]@{ committed_text = $committed.State.committed_text; query = $committed.State.query; matches = $committed.State.matches; actions = $committed.State.actions; native_owner = $committed.State.native_owner; guarded_press_delta = ([int]$committed.State.guarded_presses - $guardPressBeforeCommit); guarded_release_delta = ([int]$committed.State.guarded_releases - $guardReleaseBeforeCommit); allowed_os_ime_consumed = $true; background_presses_unchanged = $true; background_releases_unchanged = $true })
    Capture-OwnedClient $script:primary "japanese-committed" $committed | Out-Null

    Start-Stage "japanese_fresh_enter_activation"
    $backgroundPressBeforeJapaneseEnter = [int]$committed.State.background_presses
    $backgroundReleaseBeforeJapaneseEnter = [int]$committed.State.background_releases
    $guardPressBeforeJapaneseEnter = [int]$committed.State.guarded_presses
    $guardReleaseBeforeJapaneseEnter = [int]$committed.State.guarded_releases
    Send-KeyTap $script:primary "fresh Enter activate Japanese command" 0x0D
    $jpActivated = Wait-ForFrame $script:primary ([long]$committed.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.actions -eq ($actionsBeforeCommit + 1) -and [int]$s.guarded_releases -eq ($guardReleaseBeforeJapaneseEnter + 1) }
    Assert-Condition ([string]$jpActivated.State.last_action -eq "palette.command.3") "Fresh Enter did not activate the 日本語設定 command."
    Assert-Condition ([int]$jpActivated.State.guarded_presses -eq $guardPressBeforeJapaneseEnter) "Fresh Japanese activation Enter press used the native-IME guard path unexpectedly."
    Assert-Condition ([int]$jpActivated.State.background_presses -eq $backgroundPressBeforeJapaneseEnter -and [int]$jpActivated.State.background_releases -eq $backgroundReleaseBeforeJapaneseEnter) "Fresh Enter after IME commit leaked into background."
    Add-Stage "japanese_fresh_enter_activation" "PASS" ([ordered]@{ actions = $jpActivated.State.actions; last_action = $jpActivated.State.last_action; background_presses_unchanged = $true; background_releases_unchanged = $true })

    Start-Stage "escape_cancels_composition"
    $escapeOpen = Open-Palette $script:primary $jpActivated
    $imeNow = Get-ImeSnapshot $script:primary
    if (-not $imeNow.open -or -not $imeNow.native_mode) { $null = Ensure-ImeNativeMode $script:primary }
    Send-RomanText $script:primary "nihongo"
    $escapePreedit = Wait-ForFrame $script:primary ([long]$escapeOpen.State.presentation) { param($s) [bool]$s.open -and [bool]$s.composing -and ([string]$s.field_text -match "[\u3040-\u309F]") }
    $guardBefore = [int]$escapePreedit.State.guarded_presses
    $guardReleaseBefore = [int]$escapePreedit.State.guarded_releases
    $actionBeforeEscape = [int]$escapePreedit.State.actions
    $backgroundPressBeforeEscape = [int]$escapePreedit.State.background_presses
    $backgroundReleaseBeforeEscape = [int]$escapePreedit.State.background_releases
    Send-KeyTap $script:primary "Escape cancel composition" 0x1B
    $cancelled = Wait-ForFrame $script:primary ([long]$escapePreedit.State.presentation) { param($s) [bool]$s.open -and -not [bool]$s.composing -and [string]::IsNullOrEmpty([string]$s.committed_text) -and (Test-ImeGuardDelta $s $guardBefore $guardReleaseBefore -AllowSingleRelease) }
    Assert-Condition (Test-ImeGuardDelta $cancelled.State $guardBefore $guardReleaseBefore -AllowSingleRelease) "Composition Escape produced an incomplete native key-guard delta."
    Assert-Condition ([int]$cancelled.State.actions -eq $actionBeforeEscape) "Escape composition cancel activated a command."
    Assert-Condition ([int]$cancelled.State.background_presses -eq $backgroundPressBeforeEscape -and [int]$cancelled.State.background_releases -eq $backgroundReleaseBeforeEscape) "Composition-cancel Escape press/release leaked into background."
    Add-Stage "escape_cancels_composition" "PASS" ([ordered]@{ open = $cancelled.State.open; composing = $cancelled.State.composing; guarded_press_delta = ([int]$cancelled.State.guarded_presses - $guardBefore); guarded_release_delta = ([int]$cancelled.State.guarded_releases - $guardReleaseBefore); allowed_os_ime_consumed = $true; actions = $cancelled.State.actions; background_presses_unchanged = $true; background_releases_unchanged = $true })
    Capture-OwnedClient $script:primary "escape-cancel-composition" $cancelled | Out-Null

    Start-Stage "fresh_escape_dismisses_palette"
    $backgroundPressBeforeDismiss = [int]$cancelled.State.background_presses
    $backgroundReleaseBeforeDismiss = [int]$cancelled.State.background_releases
    $guardPressBeforeDismiss = [int]$cancelled.State.guarded_presses
    $guardReleaseBeforeDismiss = [int]$cancelled.State.guarded_releases
    Send-KeyTap $script:primary "fresh Escape dismiss palette" 0x1B
    $escapeClosed = Wait-ForFrame $script:primary ([long]$cancelled.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.actions -eq $actionBeforeEscape -and [int]$s.guarded_releases -eq ($guardReleaseBeforeDismiss + 1) }
    Assert-Condition ([int]$escapeClosed.State.guarded_presses -eq $guardPressBeforeDismiss) "Fresh Escape dismissal press used the native-IME guard path unexpectedly."
    Assert-Condition ([int]$escapeClosed.State.background_presses -eq $backgroundPressBeforeDismiss -and [int]$escapeClosed.State.background_releases -eq $backgroundReleaseBeforeDismiss) "Fresh Escape dismissal press/release leaked into background."
    Add-Stage "fresh_escape_dismisses_palette" "PASS" ([ordered]@{ open = $escapeClosed.State.open; actions = $escapeClosed.State.actions; guarded_releases = $escapeClosed.State.guarded_releases; presentation = $escapeClosed.State.presentation; background_presses_unchanged = $true; background_releases_unchanged = $true })
    Capture-OwnedClient $script:primary "escape-dismissed" $escapeClosed | Out-Null

    Start-Stage "post_escape_background_recovery"
    Send-KeyTap $script:primary "fresh background Enter after Escape close" 0x0D
    $background2 = Wait-ForFrame $script:primary ([long]$escapeClosed.State.presentation) { param($s) -not [bool]$s.open -and [int]$s.background_presses -eq ([int]$escapeClosed.State.background_presses + 1) -and [int]$s.background_releases -eq ([int]$escapeClosed.State.background_releases + 1) }
    Assert-Condition ([int]$background2.State.actions -eq [int]$escapeClosed.State.actions) "Fresh background Enter after Escape activated a command."
    Add-Stage "post_escape_background_recovery" "PASS" ([ordered]@{ presses_before = $escapeClosed.State.background_presses; presses_after = $background2.State.background_presses; releases_before = $escapeClosed.State.background_releases; releases_after = $background2.State.background_releases; actions = $background2.State.actions })

    Start-Stage "owned_auxiliary_focus_loss"
    $rapidOpen = Open-Palette $script:primary $background2
    Assert-Condition (Test-OpenEmpty $rapidOpen.State) "Rapid-focus test did not open empty."
    Assert-Condition (Test-StateActiveIndex $rapidOpen.State 0) "Rapid-focus reopen did not restore the initial selected command."
    $null = Ensure-ImeNativeMode $script:primary
    Send-RomanText $script:primary "nihongo"
    $rapidPreedit = Wait-ForFrame $script:primary ([long]$rapidOpen.State.presentation) { param($s) [bool]$s.open -and [bool]$s.composing -and ([string]$s.field_text -match "[\u3040-\u309F]") }
    Assert-Condition ($null -ne $rapidPreedit.State.native_owner -and [long]$rapidPreedit.State.native_owner.native_epoch -gt 0) "Composition-time focus test did not have an armed native owner."
    $oldOpenEpoch = [long]$rapidPreedit.State.open_epoch
    $oldNativeEpoch = if ($rapidPreedit.State.native_owner) { [long]$rapidPreedit.State.native_owner.native_epoch } else { 0L }
    $preeditBeforeBlur = [string]$rapidPreedit.State.field_text
    $backgroundPressBeforeBlur = [int]$rapidPreedit.State.background_presses
    $backgroundReleaseBeforeBlur = [int]$rapidPreedit.State.background_releases
    $auxStart = [DateTime]::UtcNow.ToString("o")
    Set-OwnedForeground $script:aux 1200 | Out-Null
    $auxVerified = [DateTime]::UtcNow.ToString("o")
    Set-OwnedForeground $script:primary 1200 | Out-Null
    $primaryVerified = [DateTime]::UtcNow.ToString("o")
    $blur = Wait-ForFrame $script:primary ([long]$rapidPreedit.State.presentation) { param($s) -not [bool]$s.open }
    $logText = Get-Content -Raw $script:primary.stdout -ErrorAction SilentlyContinue
    Assert-Condition ($logText -notmatch "stale_handle|host_stopping|invalid_input") "Primary fixture logged a native focus/recovery error during composition blur."
    Assert-Condition ([int]$blur.State.actions -eq [int]$rapidPreedit.State.actions -and [int]$blur.State.background_presses -eq $backgroundPressBeforeBlur -and [int]$blur.State.background_releases -eq $backgroundReleaseBeforeBlur) "Composition blur changed action/background key counters."
    Add-Stage "owned_auxiliary_focus_loss" "PASS" ([ordered]@{ preedit = $preeditBeforeBlur; composing_before_blur = $rapidPreedit.State.composing; aux_foreground_verified_at_utc = $auxVerified; primary_return_verified_at_utc = $primaryVerified; observer_wait_between_switches = $false; closed_epoch = $blur.State.open_epoch; native_owner = $blur.State.native_owner })
    Start-Stage "rapid_focus_reopen_fresh_epochs"
    $reopened = Open-Palette $script:primary $blur
    Assert-Condition (Test-OpenEmpty $reopened.State) "Focus-loss recovery did not reopen empty."
    Assert-Condition ([long]$reopened.State.open_epoch -gt $oldOpenEpoch) "Palette open epoch did not advance after focus loss."
    Send-KeyTap $script:primary "Down create owner-bearing reopen frame" 0x28
    $reopenedDown = Wait-ForFrame $script:primary ([long]$reopened.State.presentation) { param($s) [bool]$s.open -and [string]::IsNullOrEmpty([string]$s.field_text) -and (Test-StateActiveIndex $s 1) }
    Send-KeyTap $script:primary "Up restore initial reopen selection" 0x26
    $reopenedOwnerFrame = Wait-ForFrame $script:primary ([long]$reopenedDown.State.presentation) { param($s) [bool]$s.open -and [string]::IsNullOrEmpty([string]$s.field_text) -and (Test-StateActiveIndex $s 0) -and $null -ne $s.native_owner -and [long]$s.native_owner.native_epoch -gt $oldNativeEpoch }
    $reopened = $reopenedOwnerFrame
    Assert-Condition ($null -ne $reopened.State.native_owner -and [long]$reopened.State.native_owner.native_epoch -gt $oldNativeEpoch) "Native epoch did not advance after focus loss."
    Assert-Condition (Test-StateActiveIndex $reopened.State 0) "Owner-bearing rapid reopen changed the original selected command."
    Assert-Condition ([int]$reopened.State.selection.anchor -eq [int]$rapidOpen.State.selection.anchor -and [int]$reopened.State.selection.head -eq [int]$rapidOpen.State.selection.head) "Owner-bearing rapid reopen changed the search selection."
    Add-Stage "rapid_focus_reopen_fresh_epochs" "PASS" ([ordered]@{ old_open_epoch = $oldOpenEpoch; new_open_epoch = $reopened.State.open_epoch; old_native_epoch = $oldNativeEpoch; new_native_epoch = $reopened.State.native_owner.native_epoch; query = $reopened.State.query; selected_index = $reopened.State.active_index; search_selection = $reopened.State.selection; note = "Fresh owner is required on a later accepted event because the first OPEN STATE is logged before native begin." })
    Capture-OwnedClient $script:primary "rapid-focus-reopened-empty" $reopened | Out-Null
    Add-Stage "actual_japanese_ime_flow" "PASS" ([ordered]@{ layout = $script:result.ime.japanese_layout; preedit_text = $preedit.State.field_text; conversion_text = $conversion.State.field_text; committed_text = $committed.State.committed_text; composition_cancel_guarded_release = $cancelled.State.guarded_releases })
  }
  Add-Stage "human_pixel_audit" "UNRUN" ([ordered]@{ reason = "Script retains stable full-client BMPs and geometry; a human must inspect them before visual acceptance." })
  $script:activeStage = $null
  if ($script:unrun) { $script:result.status = "INCOMPLETE" } else { $script:result.status = "PASS_SCRIPTED_ASSERTIONS" }

} catch {
  $failed = -not $_.Exception.Message.StartsWith("BLOCKED:", [StringComparison]::Ordinal)
  if ($_.Exception.Message.StartsWith("BLOCKED:", [StringComparison]::Ordinal)) {
    $script:result.status = "BLOCKED"
    $script:result.failure = [ordered]@{ kind = "interactive_input_desktop_unavailable"; message = $_.Exception.Message; input_count = $script:result.input_events.Count; launched_process_count = $script:owners.Count; fixture_count = $script:owners.Count; focus_policy_bypass = $false; at_utc = [DateTime]::UtcNow.ToString("o") }
  } else {
    $script:result.status = "FAIL"
    if ($null -eq $script:result.failure -or $script:result.failure.kind -ne "partial_sendinput") {
      $script:result.failure = [ordered]@{ kind = "scripted_e2e"; message = $_.Exception.Message; stack = $_.ScriptStackTrace; at_utc = [DateTime]::UtcNow.ToString("o") }
    }
    if ($script:activeStage -and -not (@($script:result.stages | Where-Object { $_.name -eq $script:activeStage }).Count)) {
      Add-Stage $script:activeStage "FAIL" ([ordered]@{ error = $_.Exception.Message })
    }
  }
} finally {
  if ($null -ne $script:primary) {
    try {
      $last = Get-CurrentFrame $script:primary
      if ([bool]$last.State.open) {
        try {
          Set-OwnedForeground $script:primary | Out-Null
          if ([bool]$last.State.composing) {
            Send-KeyTap $script:primary "cleanup cancel composition" 0x1B
            $last = Wait-ForFrame $script:primary ([long]$last.State.presentation) { param($s) -not [bool]$s.composing }
          }
          if ([bool]$last.State.open) {
            Send-KeyTap $script:primary "cleanup close palette" 0x1B
            $last = Wait-ForFrame $script:primary ([long]$last.State.presentation) { param($s) -not [bool]$s.open }
          }
        } catch { $script:result.cleanup_warning = $_.Exception.Message }
      }
    } catch { $script:result.cleanup_warning = $_.Exception.Message }
  }
  if ($script:owners.Count -gt 0) {
    Start-Stage "normal_fenced_cleanup"
    foreach ($owner in @($script:owners | Where-Object { $_.role -eq "auxiliary" })) { Close-OwnedFixture $owner }
    foreach ($owner in @($script:owners | Where-Object { $_.role -eq "primary" })) { Close-OwnedFixture $owner }
    $cleanupErrors = @($script:result.cleanup | Where-Object { -not [string]::IsNullOrEmpty([string]$_.error) })
    if ($script:result.cleanup_warning) { $cleanupErrors += [pscustomobject]@{ role = "primary"; error = $script:result.cleanup_warning } }
    if ($cleanupErrors.Count -eq 0) {
      Add-Stage "normal_fenced_cleanup" "PASS" ([ordered]@{ fixture_count = $script:owners.Count; cleanup = $script:result.cleanup })
    } else {
      Add-Stage "normal_fenced_cleanup" "FAIL" ([ordered]@{ errors = $cleanupErrors })
      if ($script:result.status -ne "BLOCKED") {
        $script:result.status = "FAIL"
        if ($null -eq $script:result.failure) { $script:result.failure = [ordered]@{ kind = "cleanup"; errors = $cleanupErrors; at_utc = [DateTime]::UtcNow.ToString("o") } }
      }
    }
  } else {
    Add-Stage "normal_fenced_cleanup" "UNRUN" ([ordered]@{ reason = "No fixture launched." })
  }
  if ($script:dpiPrevious -ne [IntPtr]::Zero) {
    $dpiRestored = [PaletteE2E.Win32]::SetThreadDpiAwarenessContext($script:dpiPrevious)
    if ($dpiRestored -eq [IntPtr]::Zero) {
      $script:result.dpi_context.restore_status = "FAIL"
      if ($script:result.status -ne "BLOCKED") {
        $script:result.status = "FAIL"
        $dpiFailure = [ordered]@{ kind = "dpi_context_restore"; at_utc = [DateTime]::UtcNow.ToString("o") }
        if ($null -eq $script:result.failure) { $script:result.failure = $dpiFailure } else { $script:result.cleanup_failure = $dpiFailure }
      }
    } else { $script:result.dpi_context.restore_status = "PASS" }
  }
  if ($script:result.status -eq "IN_PROGRESS") { $script:result.status = if ($script:unrun) { "INCOMPLETE" } else { "PASS_SCRIPTED_ASSERTIONS" } }
  Add-UnreachedStages
  $script:result.input_event_count = $script:result.input_events.Count
  $script:result.input_sendinput_batch_count = $script:result.input_events.Count
  $script:result.launched_process_count = $script:result.fixtures.Count
  try {
    $inputTotals = Get-InputEventTotals $script:result.input_events
    $script:result.input_event_count = $inputTotals.batch_count
    $script:result.input_sendinput_batch_count = $inputTotals.batch_count
    $script:result.requested_keyboard_events_total = $inputTotals.requested_keyboard_events_total
    $script:result.inserted_keyboard_events_total = $inputTotals.inserted_keyboard_events_total
    $script:result.input_event_total_basis = $inputTotals.basis
  } catch {
    $script:result.status = "FAIL"
    $script:result.requested_keyboard_events_total = $null
    $script:result.inserted_keyboard_events_total = $null
    $script:result.input_event_totals_error = $_.Exception.Message
    $inputTotalsFailure = [ordered]@{ kind = "input_event_totals"; message = $_.Exception.Message; at_utc = [DateTime]::UtcNow.ToString("o") }
    if ($null -eq $script:result.failure) { $script:result.failure = $inputTotalsFailure } else { $script:result.input_event_totals_failure = $inputTotalsFailure }
  }
  $script:result.fixture_process_count = $script:result.fixtures.Count
  $script:result.focus_policy_bypass = $false
  $script:result.input_injection_count = $script:result.input_events.Count
  try {
    $finalIdentity = Get-GitIdentity
    $script:result.final_source_head = $finalIdentity.Head
    $script:result.final_source_clean = $finalIdentity.Clean
    $script:result.final_executable_sha256 = if (Test-Path -LiteralPath $binary) { (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    $script:result.final_build_manifest_sha256 = if (Test-Path -LiteralPath $buildManifestPath) { (Get-FileHash -LiteralPath $buildManifestPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
    if ($null -ne $script:result.source_head -and
        ($finalIdentity.Head -ne $script:result.source_head -or -not $finalIdentity.Clean -or
          ($null -ne $script:result.executable_sha256 -and $script:result.final_executable_sha256 -ne $script:result.executable_sha256) -or
          ($null -ne $script:result.build_manifest_sha256 -and $script:result.final_build_manifest_sha256 -ne $script:result.build_manifest_sha256))) {
      $script:result.status = "FAIL"
      $provenance = [ordered]@{ kind = "final_provenance_mismatch"; source_head = $finalIdentity.Head; source_clean = $finalIdentity.Clean; executable_sha256 = $script:result.final_executable_sha256; build_manifest_sha256 = $script:result.final_build_manifest_sha256; at_utc = [DateTime]::UtcNow.ToString("o") }
      if ($null -eq $script:result.failure) { $script:result.failure = $provenance } else { $script:result.provenance_mismatch = $provenance }
    }
  } catch {
    $script:result.status = "FAIL"
    $provenanceError = [ordered]@{ kind = "final_provenance_check"; message = $_.Exception.Message; at_utc = [DateTime]::UtcNow.ToString("o") }
    if ($null -eq $script:result.failure) { $script:result.failure = $provenanceError } else { $script:result.provenance_check_error = $provenanceError }
  }
  $desktopStage = @($script:result.stages | Where-Object { $_.name -eq "interactive_default_input_desktop" } | Select-Object -Last 1)
  $desktopAcceptance = if ($desktopStage.Count -eq 0) { "UNRUN" } else { [string]$desktopStage[0].status }
  $pixelStages = @($script:result.stages | Where-Object { $_.name -like "pixel_capture_*" })
  $pixelStatus = if ($pixelStages.Count -eq 0) { "UNRUN" } elseif (@($pixelStages | Where-Object status -eq "FAIL").Count -gt 0) { "CAPTURE_FAILURE" } else { "CAPTURED_UNREVIEWED" }
  $script:result.acceptance = [ordered]@{
    overall = if ($script:result.status -eq "PASS_SCRIPTED_ASSERTIONS") { "INCOMPLETE_HUMAN_PIXEL_AUDIT" } else { $script:result.status }
    scripted_flow = if ($script:result.status -eq "PASS_SCRIPTED_ASSERTIONS") { "PASS" } else { "UNRUN_or_FAILED" }
    interactive_input_desktop = $desktopAcceptance
    palette_native_input = if (@($script:result.stages | Where-Object { $_.name -eq "background_key_recovery" -and $_.status -eq "PASS" }).Count -gt 0) { "PASS" } else { "UNRUN" }
    japanese_ime = if (@($script:result.stages | Where-Object { $_.name -eq "actual_japanese_ime_flow" -and $_.status -eq "PASS" }).Count -gt 0) { "PASS" } else { "UNRUN" }
    full_client_pixels = $pixelStatus
    human_pixel_audit = "UNRUN"
    candidate_form_geometry = if (@($script:result.stages | Where-Object { $_.name -eq "candidate_form_caret_geometry" -and $_.status -eq "PASS" }).Count -gt 0) { "PASS" } else { "UNRUN" }
    candidate_popup_placement = "UNRUN_until_visual_review"
    candidate_contents_highlight = "UNRUN"
  }
  $script:result.finished_at_utc = [DateTime]::UtcNow.ToString("o")
  Save-Result
}

Write-Output "Windows command-palette E2E: $($script:result.status)"
Write-Output "Evidence: $runDir"
if ($script:result.status -eq "FAIL") { exit 1 }
if ($script:result.status -eq "BLOCKED" -or $script:result.status -eq "INCOMPLETE") { exit 2 }
exit 0
