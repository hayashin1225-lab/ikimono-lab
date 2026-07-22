[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

$source = Join-Path $Root 'tools\liaison-officer\relay-windows.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
  throw ($errors | ForEach-Object Message -join '; ')
}

$temp = Join-Path $env:TEMP ('liaison-windows-entry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null

try {
  Copy-Item -LiteralPath $source -Destination (Join-Path $temp 'relay-windows.ps1')
  '{}' | Set-Content -Encoding UTF8 (Join-Path $temp 'config.local.json')

  $fakeRelay = @'
[CmdletBinding()]
param(
  [string]$Mode = 'SelfTest',
  [string]$ConfigPath = ''
)

if ($env:LIAISON_OFFICER_IMPORT -ne '1') { throw 'import guard was not set' }
if ($ConfigPath -ne (Join-Path $PSScriptRoot 'config.local.json')) { throw "default config path was not resolved: $ConfigPath" }

$ExitCode = @{ Success = 0; NoEligibleIssue = 10 }
$LockHandle = $null
$script:CurrentStage = 'preflight'
$script:SelectedIssue = $null
$RunId = 'TEST'

function Write-Result([string]$Message) { Write-Output "[$RunId] $Message" }
function Stop-WithCode([int]$Code, [string]$Message) { Write-Error $Message -ErrorAction Continue; exit $Code }
function Get-Config {
  return [pscustomobject]@{
    gitExecutable = $env:ComSpec
    ghExecutable = $env:ComSpec
    codexExecutable = $env:ComSpec
    codexSubcommand = 'exec'
    repoPath = $PSScriptRoot
    logDirectory = 'runtime/logs'
    stateDirectory = 'runtime/state'
    temporaryDirectory = 'runtime/temp'
    repository = 'owner/repo'
    baseBranch = 'main'
    requiredLabels = @()
  }
}
function Resolve-Executable([string]$Value, [string]$Name) { return $Value }
function Test-SelfTest($Config) {
  if ([Console]::OutputEncoding.WebName -ne 'utf-8') { throw 'console output encoding was not UTF-8' }
  Write-Result 'fake SelfTest passed'
}
function Invoke-Tool([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory) {
  if ('--skip-git-repo-check' -notin $Arguments) {
    return [pscustomobject]@{ ExitCode = 64; Output = @('missing skip flag') }
  }
  return [pscustomobject]@{ ExitCode = 0; Output = @('LIAISON_SMOKE_OK') }
}
function Test-RepositoryPreflight($Config) { return [pscustomobject]@{ Branch = 'main' } }
function Get-EligibleIssues($Config) {
  return @([pscustomobject]@{ number = 20; title = '日本語の試運転' })
}
function Get-BranchName([int]$IssueNumber, [string]$Title) { return "codex/issue-$IssueNumber-task" }
function Invoke-Once($Config) { Write-Result 'fake Once passed' }
function Release-LocalLock($Config) {}
function Complete-Failure($Config, [string]$Message) {}
'@
  [IO.File]::WriteAllText((Join-Path $temp 'relay.ps1'), $fakeRelay, [Text.UTF8Encoding]::new($false))

  function Invoke-TestProcess([string[]]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $info.Arguments = ($Arguments | ForEach-Object {
      if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
    }) -join ' '
    $info.WorkingDirectory = $temp
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    if (-not $process.Start()) { throw 'test process did not start' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = $stdoutTask.GetAwaiter().GetResult()
      Stderr = $stderrTask.GetAwaiter().GetResult()
    }
  }

  $self = Invoke-TestProcess @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $temp 'relay-windows.ps1'), '-Mode', 'SelfTest', '-RunCodexSmokeTest')
  if ($self.ExitCode -ne 0) { throw "SelfTest wrapper failed: $($self.Stdout) $($self.Stderr)" }
  if ($self.Stdout -notmatch 'Codex smoke test passed') { throw 'smoke success marker was absent' }
  if ($self.Stdout -notmatch 'SelfTest completed') { throw 'SelfTest completion marker was absent' }

  $dry = Invoke-TestProcess @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $temp 'relay-windows.ps1'), '-Mode', 'DryRun')
  if ($dry.ExitCode -ne 0) { throw "DryRun wrapper failed: $($dry.Stdout) $($dry.Stderr)" }
  if ($dry.Stdout -notmatch '日本語の試運転') { throw "UTF-8 Japanese title was not preserved: $($dry.Stdout)" }

  Write-Output 'Windows PowerShell 5.1 entrypoint regression passed: default config path, UTF-8 output, and non-Git Codex smoke flag.'
} finally {
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
