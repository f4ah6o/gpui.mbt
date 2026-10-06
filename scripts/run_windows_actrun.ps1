[CmdletBinding()]
param(
  [string]$PythonPath = $env:GPUI_WINDOWS_PYTHON
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $repo

$build = Join-Path $repo '_build/windows-actrun'
$logs = Join-Path $build 'logs'
New-Item -ItemType Directory -Force (Join-Path $build 'records'), $logs | Out-Null

$lockPath = Join-Path $repo 'infra/linux-desktop/actrun-runner.lock.json'
$lock = Get-Content -Raw $lockPath | ConvertFrom-Json
$toolRoot = Join-Path $repo '_build/tools/actrun-windows'
$cli = Join-Path $toolRoot 'node_modules/@mizchi/actrun/dist/actrun.js'
$packageJson = Join-Path $toolRoot 'node_modules/@mizchi/actrun/package.json'
$packageLock = Join-Path $toolRoot 'package-lock.json'
$cache = Join-Path $repo '_build/tools/actrun-npm-cache'

if (-not (Test-Path $cli)) {
  $installLog = Join-Path $logs 'npm-install.log'
  & npm install --prefix $toolRoot --cache $cache --ignore-scripts --no-audit --no-fund --save-exact "$($lock.name)@$($lock.version)" 2>&1 |
    Tee-Object -FilePath $installLog
  if ($LASTEXITCODE -ne 0) { throw "Pinned actrun installation failed; see $installLog" }
}

if (-not (Test-Path $packageJson) -or -not (Test-Path $packageLock)) {
  throw 'Pinned actrun package metadata is missing after installation.'
}
$package = Get-Content -Raw $packageJson | ConvertFrom-Json
if ($package.name -ne $lock.name -or $package.version -ne $lock.version) {
  throw 'Installed actrun package name/version does not match the repository lock.'
}
$npmLock = Get-Content -Raw $packageLock | ConvertFrom-Json -AsHashtable
$packageEntry = $npmLock.packages['node_modules/@mizchi/actrun']
if (-not $packageEntry -or $packageEntry.integrity -ne $lock.registry_integrity) {
  throw 'Installed actrun npm integrity does not match the repository lock.'
}
$cliHash = (Get-FileHash $cli -Algorithm SHA256).Hash.ToLowerInvariant()
if ($cliHash -ne $lock.cli_sha256.ToLowerInvariant()) {
  throw 'Installed actrun CLI SHA-256 does not match the repository lock.'
}

$nodeVersion = (& node --version).Trim()
$nodeMajor = [int]($nodeVersion.TrimStart('v').Split('.')[0])
if ($nodeMajor -lt $lock.node_minimum_major) {
  throw "Node.js $nodeVersion is below the pinned actrun minimum."
}

$moonHome = Join-Path $repo '_build/tools/moonbit'
$moonBin = Join-Path $moonHome 'bin'
if (-not (Test-Path (Join-Path $moonBin 'moon.exe'))) {
  throw "Pinned MoonBit toolchain is missing at $moonBin."
}
$env:MOON_HOME = $moonHome
$env:PATH = "$moonBin;$env:PATH"

if (-not $PythonPath) {
  $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($pythonCommand) { $PythonPath = $pythonCommand.Source }
}
if (-not $PythonPath -or -not (Test-Path $PythonPath)) {
  throw 'Set GPUI_WINDOWS_PYTHON to a Python 3 interpreter before running the local portable profile.'
}
$env:GPUI_WINDOWS_PYTHON = (Resolve-Path $PythonPath).Path
$env:PYTHONUTF8 = '1'
$pythonVersion = (& $env:GPUI_WINDOWS_PYTHON --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw "Python could not be started: $pythonVersion" }

$cl = Get-Command cl.exe -ErrorAction SilentlyContinue
if (-not $cl) {
  $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio/Installer/vswhere.exe'
  if (-not (Test-Path $vswhere)) { throw 'MSVC is not on PATH and vswhere.exe was not found.' }
  $vsInstall = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath).Trim()
  if (-not $vsInstall) { throw 'No Visual Studio installation with x64 C++ tools was found.' }
  $vsDevCmd = Join-Path $vsInstall 'Common7/Tools/VsDevCmd.bat'
  $cmd = "call `"$vsDevCmd`" -arch=x64 -host_arch=x64 >nul && set"
  $environmentLines = & $env:ComSpec /d /c $cmd
  if ($LASTEXITCODE -ne 0) { throw 'VsDevCmd.bat failed to prepare the MSVC environment.' }
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
  foreach ($name in @('PATH', 'INCLUDE', 'LIB')) {
    if ($toolEnvironment.ContainsKey($name)) {
      $entry = $toolEnvironment[$name]
      [Environment]::SetEnvironmentVariable($entry.Name, $entry.Value, 'Process')
    }
  }
}

$gitCommand = Get-Command git.exe -ErrorAction Stop
$gitRoot = Split-Path (Split-Path $gitCommand.Source -Parent) -Parent
$gnuBin = Join-Path $gitRoot 'usr/bin'
if (-not (Test-Path (Join-Path $gnuBin 'env.exe'))) {
  throw "Git's GNU utilities, including env.exe, were not found under $gnuBin."
}
$env:PATH = "$gnuBin;$moonBin;$env:PATH"
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
  throw 'MSVC environment initialization did not make cl.exe available.'
}

$preload = Join-Path $repo 'infra/windows-native/actrun-preload.cjs'
$head = (& git rev-parse HEAD).Trim()
$dirty = @(& git status --porcelain)
$moonVersionLog = Join-Path $logs 'moon-version.txt'
& moon version --all 2>&1 | Tee-Object -FilePath $moonVersionLog
if ($LASTEXITCODE -ne 0) { throw 'Could not read the pinned MoonBit toolchain version.' }

$manifest = [ordered]@{
  schema_version = 1
  started_at_utc = [DateTime]::UtcNow.ToString('o')
  state = 'running'
  source_head = $head
  worktree_dirty = ($dirty.Count -gt 0)
  dirty_paths = @($dirty | ForEach-Object { $_.Substring(3).Trim() })
  source_snapshot_sha256 = $sourceSnapshot
  actrun = [ordered]@{
    package = $package.name
    version = $package.version
    cli_sha256 = $cliHash
    node_version = $nodeVersion
  }
  host = [ordered]@{
    os = [Environment]::OSVersion.VersionString
    powershell = $PSVersionTable.PSVersion.ToString()
    python = $pythonVersion
    moon_home = $moonHome
    gnu_utilities = $gnuBin
    msvc = (Get-Command cl.exe).Source
    msys_path_conversion_disabled_for_actrun = $true
  }
  setup_actions_skipped = @(
    'actions/checkout: local workspace already selected',
    'ilammy/msvc-dev-cmd: loaded in this process',
    'hustcer/setup-moonbit: pinned local toolchain loaded',
    'actions/upload-artifact: evidence stays in _build/windows-actrun'
  )
  runs = @()
  source_unchanged = $null
  final_head = $null
  final_source_snapshot_sha256 = $null
  finished_at_utc = $null
  error = $null
}
$manifestPath = Join-Path $build 'manifest.json'

function Get-SourceSnapshotHash {
  $paths = @(& git -C $repo ls-files --cached --others --exclude-standard)
  if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate tracked and non-ignored source files.' }
  $entries = foreach ($relativePath in ($paths | Sort-Object -CaseSensitive)) {
    if ([string]::IsNullOrEmpty($relativePath)) { continue }
    $fullPath = Join-Path $repo $relativePath
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
      $hash = (Get-FileHash -LiteralPath $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
      "$relativePath`t$hash"
    } else {
      "$relativePath`t<missing>"
    }
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($entries -join "`n"))
  $sha = [Security.Cryptography.SHA256]::Create()
  try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
  finally { $sha.Dispose() }
}

$sourceSnapshot = Get-SourceSnapshotHash
$manifest.source_snapshot_sha256 = $sourceSnapshot

$priorMsysEnvironment = @{
  MSYS2_ARG_CONV_EXCL = $env:MSYS2_ARG_CONV_EXCL
  MSYS2_ENV_CONV_EXCL = $env:MSYS2_ENV_CONV_EXCL
  MSYS_NO_PATHCONV = $env:MSYS_NO_PATHCONV
}
$env:MSYS2_ARG_CONV_EXCL = '*'
$env:MSYS2_ENV_CONV_EXCL = '*'
$env:MSYS_NO_PATHCONV = '1'

function Invoke-ActrunWorkflow {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Workflow,
    [Parameter(Mandatory = $true)][string]$Trigger,
    [Parameter(Mandatory = $true)][string[]]$RequiredTaskIds
  )
  $runRootRelative = "_build/windows-actrun/records/$Name"
  $runRoot = Join-Path $repo $runRootRelative
  $log = Join-Path $logs "$Name-actrun.log"
  $arguments = @(
    '--require', $preload,
    $cli, 'workflow', 'run', $Workflow,
    '--workspace-mode', 'local',
    '--run-root', $runRootRelative,
    '--no-nix', '--trigger', $Trigger,
    '--skip-action', 'actions/checkout',
    '--skip-action', 'ilammy/msvc-dev-cmd',
    '--skip-action', 'hustcer/setup-moonbit',
    '--skip-action', 'actions/upload-artifact'
  )
  $output = & node @arguments 2>&1
  $exitCode = $LASTEXITCODE
  $output | Tee-Object -FilePath $log | Out-Host
  $text = Get-Content -Raw $log
  $runMatch = [Regex]::Match($text, '(?m)^run_id=([^\r\n]+)\r?$')
  if (-not $runMatch.Success) {
    return [ordered]@{ name = $Name; workflow = $Workflow; exit_code = $exitCode; log = $log; ok = $false; error = 'actrun did not report a run id' }
  }
  $runId = $runMatch.Groups[1].Value.Trim()
  $recordPath = Join-Path (Join-Path $runRoot $runId) 'run.json'
  if (-not (Test-Path $recordPath)) {
    return [ordered]@{ name = $Name; workflow = $Workflow; run_id = $runId; exit_code = $exitCode; log = $log; ok = $false; error = "actrun did not persist $recordPath" }
  }
  $record = Get-Content -Raw $recordPath | ConvertFrom-Json
  $taskMap = @{}
  foreach ($task in @($record.tasks)) { $taskMap[[string]$task.id] = $task }
  $missingTasks = @($RequiredTaskIds | Where-Object { -not $taskMap.ContainsKey($_) })
  $failedTasks = @($record.tasks | Where-Object { $_.status -ne 'success' -or $null -eq $_.code -or $_.code -ne 0 })
  $recordHead = [string]$record.headSha
  $ok = ($exitCode -eq 0) -and ($record.ok -eq $true) -and ($record.state -eq 'completed') -and ($failedTasks.Count -eq 0) -and ($missingTasks.Count -eq 0) -and ($record.workspace_root -eq '.') -and ($recordHead -eq $head)
  return [ordered]@{
    name = $Name
    workflow = $Workflow
    run_id = $runId
    exit_code = $exitCode
    run_record = $recordPath
    workspace_root = $record.workspace_root
    head_sha = $recordHead
    state = $record.state
    ok = $ok
    missing_tasks = $missingTasks
    failed_tasks = @($failedTasks | ForEach-Object { @{ id = $_.id; status = $_.status; code = $_.code; message = $_.message } })
    log = $log
  }
}

try {
  $manifest.runs += Invoke-ActrunWorkflow -Name 'windows-native' -Workflow '.github/workflows/windows-native.yml' -Trigger 'workflow_dispatch' -RequiredTaskIds @('win32-d3d11/step_1', 'win32-d3d11/__finish')
  if (-not $manifest.runs[-1].ok) { throw 'The actual Windows native workflow did not complete successfully under actrun.' }
  $portableWorkflowName = ".github/workflows/_local-actrun-feedback-windows-portable-$([Guid]::NewGuid().ToString('N')).yml"
  $portableWorkflowPath = Join-Path $repo $portableWorkflowName
  Copy-Item -LiteralPath (Join-Path $repo 'infra/windows-native/local-portable.yml') -Destination $portableWorkflowPath
  try {
    $manifest.runs += Invoke-ActrunWorkflow -Name 'portable' -Workflow $portableWorkflowName -Trigger 'push' -RequiredTaskIds @('windows-portable/step_1', 'windows-portable/step_2', 'windows-portable/step_3')
  } finally {
    Remove-Item -LiteralPath $portableWorkflowPath -Force -ErrorAction SilentlyContinue
  }
  if (-not $manifest.runs[-1].ok) { throw 'The Windows local portable acceptance profile did not complete successfully under actrun.' }
  $finalHead = (& git rev-parse HEAD).Trim()
  $finalSourceSnapshot = Get-SourceSnapshotHash
  $manifest.final_head = $finalHead
  $manifest.final_source_snapshot_sha256 = $finalSourceSnapshot
  $manifest.source_unchanged = ($finalHead -eq $head) -and ($finalSourceSnapshot -eq $sourceSnapshot)
  if (-not $manifest.source_unchanged) { throw 'Source HEAD or tracked/non-ignored file contents changed during actrun execution.' }
  $manifest.state = 'completed'
} catch {
  $manifest.state = 'failed'
  $manifest.error = $_.Exception.Message
  throw
} finally {
  if (-not $manifest.final_head) { $manifest.final_head = (& git rev-parse HEAD).Trim() }
  if ($null -eq $manifest.source_unchanged) {
    $manifest.final_source_snapshot_sha256 = Get-SourceSnapshotHash
    $manifest.source_unchanged = ($manifest.final_head -eq $head) -and ($manifest.final_source_snapshot_sha256 -eq $sourceSnapshot)
  }
  foreach ($name in $priorMsysEnvironment.Keys) {
    if ($null -eq $priorMsysEnvironment[$name]) {
      Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    } else {
      Set-Item "Env:$name" $priorMsysEnvironment[$name]
    }
  }
  $manifest.finished_at_utc = [DateTime]::UtcNow.ToString('o')
  $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8
}

Write-Output "Windows actrun acceptance passed. Evidence: $build"
