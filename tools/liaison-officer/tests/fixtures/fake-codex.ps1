[CmdletBinding()]
param(
  [Alias('C')]
  [string]$RepositoryArgument,
  [switch]$StdinMarker,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$collectionNames = @(
  'issues',
  'prs',
  'comments',
  'labels',
  'reviews',
  'ghCalls',
  'codexCalls',
  'commits',
  'branches',
  'failures'
)
$invocationArguments = @()
if (-not [string]::IsNullOrWhiteSpace($RepositoryArgument)) { $invocationArguments += @('-C', $RepositoryArgument) }
if ($null -ne $CliArguments) { $invocationArguments += @($CliArguments) }
if ($StdinMarker) { $invocationArguments += @('-') }

function Write-Stderr([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Write-Trace([string]$Message) {
  if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_TRACE)) {
    $line = ([DateTime]::UtcNow.ToString('o') + ' pid=' + $PID + ' ' + $Message + [Environment]::NewLine)
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($env:FAKE_CODEX_TRACE), $line, [Text.UTF8Encoding]::new($false))
  }
}

function Convert-ToArray($Value) {
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) { return $Object.$Name }
  return $Default
}

function Normalize-State($State) {
  foreach ($name in $collectionNames) {
    if ($State.PSObject.Properties.Name -notcontains $name) {
      $State | Add-Member -NotePropertyName $name -NotePropertyValue @()
    }
    $State.$name = @(Convert-ToArray $State.$name)
  }
  return $State
}

function Read-StateFile([string]$Path) {
  $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
  return (Normalize-State ($raw | ConvertFrom-Json))
}

function Save-StateFile([string]$Path, $State) {
  [void](Normalize-State $State)
  $directory = Split-Path -Parent $Path
  $temporaryPath = Join-Path $directory ('.fake-codex-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    $json = ConvertTo-Json -InputObject $State -Depth 50
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    [void](Read-StateFile $Path)
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
  }
}

function Stop-Fixture([int]$Code, [string]$Message) {
  Write-Stderr $Message
  exit $Code
}

if ([string]::IsNullOrWhiteSpace($env:FAKE_CODEX_STATE)) {
  Stop-Fixture 78 'FAKE_CODEX_STATE is required.'
}

$statePath = [IO.Path]::GetFullPath($env:FAKE_CODEX_STATE)
Write-Trace ('start argv=' + ($invocationArguments -join '|') + ' state=' + $statePath)
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  Stop-Fixture 78 "FAKE_CODEX_STATE file does not exist: $statePath"
}

$state = Read-StateFile $statePath
Write-Trace 'state-read'
if ($state.PSObject.Properties.Name -notcontains 'codexBehavior') {
  Stop-Fixture 78 'codexBehavior is required in fake Codex state.'
}

$repoPath = if ([string]::IsNullOrWhiteSpace($RepositoryArgument)) { $env:FAKE_CODEX_REPO } else { $RepositoryArgument }
if ([string]::IsNullOrWhiteSpace($repoPath) -or -not (Test-Path -LiteralPath $repoPath -PathType Container)) {
  Stop-Fixture 78 "Fake Codex repository is unavailable: $repoPath"
}
$repoPath = [IO.Path]::GetFullPath($repoPath)
Write-Trace ('stdin-read-start repo=' + $repoPath)
$prompt = [Console]::In.ReadToEnd()
Write-Trace ('stdin-read-end length=' + $prompt.Length)
$behavior = $state.codexBehavior
$mode = [string](Get-PropertyValue $behavior 'mode' '')
if ([string]::IsNullOrWhiteSpace($mode)) { Stop-Fixture 78 'codexBehavior.mode is required.' }
$implementationPath = (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Path).Path
$callNumber = @($state.codexCalls).Count + 1
$call = [pscustomobject][ordered]@{
  implementationPath = $implementationPath
  argv = @($invocationArguments)
  statePath = $statePath
  repositoryPath = $repoPath
  processId = $PID
  mode = $mode
  promptLength = $prompt.Length
  calledAt = [DateTime]::UtcNow.ToString('o')
}
$state.codexCalls = @($state.codexCalls) + @($call)
Write-Trace 'state-write-start'
Save-StateFile $statePath $state
Write-Trace 'state-write-end'

if ($mode -eq 'nonzero') {
  $exitCode = [int](Get-PropertyValue $behavior 'exitCode' 9)
  Write-Stderr ([string](Get-PropertyValue $behavior 'stderr' 'Injected fake Codex nonzero exit.'))
  exit $exitCode
}

if ($mode -eq 'timeout') {
  Write-Trace 'timeout-sleep-start'
  $sleepSeconds = [int](Get-PropertyValue $behavior 'sleepSeconds' 30)
  Start-Sleep -Seconds $sleepSeconds
  exit 0
}

$relativePath = [string](Get-PropertyValue $behavior 'file' 'allowed.txt')
$normalizedPath = $relativePath.Replace('\', '/')
if ([IO.Path]::IsPathRooted($relativePath) -or $normalizedPath -match '(^|/)\.\.(/|$)') {
  Stop-Fixture 78 "Unsafe fake Codex output path: $relativePath"
}
$outputPath = Join-Path $repoPath $relativePath
$outputParent = Split-Path -Parent $outputPath
if (-not [string]::IsNullOrWhiteSpace($outputParent)) { New-Item -ItemType Directory -Force -Path $outputParent | Out-Null }

if ($mode -eq 'validation-failure') {
  [IO.File]::WriteAllText($outputPath, "invalid trailing space   `r`n", [Text.UTF8Encoding]::new($false))
} elseif ($mode -eq 'success' -or $mode -eq 'report-mismatch' -or $mode -eq 'bad-report') {
  $prefix = [string](Get-PropertyValue $behavior 'contentPrefix' 'fake change ')
  [IO.File]::WriteAllText($outputPath, ($prefix + $callNumber), [Text.UTF8Encoding]::new($false))
} elseif ($mode -eq 'no-change') {
  # Intentionally leave the repository unchanged so relay validation rejects it.
} else {
  Stop-Fixture 78 "Unsupported fake Codex mode: $mode"
}
Write-Trace ('artifact-written mode=' + $mode)

if ($mode -eq 'bad-report') {
  [Console]::Out.WriteLine('LIAISON_REPORT_BEGIN')
  [Console]::Out.WriteLine('{invalid-json')
  [Console]::Out.WriteLine('LIAISON_REPORT_END')
  exit 0
}

$reportedPath = if ($mode -eq 'report-mismatch') { 'other.txt' } else { $normalizedPath }
$reportedFiles = [object[]]@()
if ($mode -ne 'no-change') { $reportedFiles = [object[]]@($reportedPath) }
$report = [ordered]@{
  status = 'success'
  summary = "fake Codex $mode"
  changedFiles = $reportedFiles
  tests = @('fake Codex fixture')
  unresolved = @()
  humanReview = $true
}
[Console]::Out.WriteLine('LIAISON_REPORT_BEGIN')
[Console]::Out.WriteLine(($report | ConvertTo-Json -Compress -Depth 10))
[Console]::Out.WriteLine('LIAISON_REPORT_END')
Write-Trace 'report-written'
exit 0
