[CmdletBinding()]
param([string]$Root)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
}

$source = Join-Path $Root 'tools\liaison-officer\relay-windows.ps1'
$installer = Join-Path $Root 'tools\liaison-officer\install-scheduled-task.ps1'
$readme = Join-Path $Root 'tools\liaison-officer\README.md'
$powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source

foreach ($path in @($source, $installer)) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
  if ($errors.Count) {
    throw "$path parse failed: $($errors | ForEach-Object Message -join '; ')"
  }
}

$installerText = Get-Content -Raw -Encoding UTF8 -LiteralPath $installer
if ($installerText -notmatch 'relay-windows\.ps1') {
  throw 'Scheduled Task installer does not route through relay-windows.ps1.'
}
if ($installerText -match '\[string\]\$ConfigPath\s*=\s*\(Join-Path') {
  throw 'Scheduled Task installer still evaluates PSScriptRoot in the parameter default.'
}
$readmeText = Get-Content -Raw -Encoding UTF8 -LiteralPath $readme
if ($readmeText -notmatch '\.\\relay-windows\.ps1 -Mode Once') {
  throw 'README does not document relay-windows.ps1 as the Once entrypoint.'
}
if ($readmeText -match '(?m)^\s*\.\\relay\.ps1\s+-Mode') {
  throw 'README still contains a direct relay.ps1 launch command.'
}

$temp = Join-Path $env:TEMP ('liaison-windows-entry-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$previousFakeGh = $env:FAKE_GH
$previousFakeCodex = $env:FAKE_CODEX

try {
  Copy-Item -LiteralPath $source -Destination (Join-Path $temp 'relay-windows.ps1')
  '{}' | Set-Content -Encoding UTF8 (Join-Path $temp 'config.local.json')

  $fakeGhScript = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$json = '[{"number":20,"title":"日本語の試運転","createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"gm-approved"},{"name":"ready-for-codex"}],"url":"https://github.test/owner/repo/issues/20"}]'
[Console]::Out.Write($json)
'@
  [IO.File]::WriteAllText((Join-Path $temp 'fake-gh.ps1'), $fakeGhScript, [Text.UTF8Encoding]::new($false))
  $fakeGhCmd = "@echo off`r`n`"$powerShell`" -NoProfile -ExecutionPolicy Bypass -File `"%~dp0fake-gh.ps1`"`r`nexit /b %ERRORLEVEL%"
  [IO.File]::WriteAllText((Join-Path $temp 'fake-gh.cmd'), $fakeGhCmd, [Text.Encoding]::ASCII)

  $fakeCodexCmd = @'
@echo off
echo %* | findstr /C:"--skip-git-repo-check" >nul
if errorlevel 1 (
  echo missing --skip-git-repo-check 1>&2
  exit /b 64
)
echo OpenAI Codex vTEST 1>&2
echo LIAISON_SMOKE_OK
exit /b 0
'@ -replace "`n", "`r`n"
  [IO.File]::WriteAllText((Join-Path $temp 'fake-codex.cmd'), $fakeCodexCmd, [Text.Encoding]::ASCII)

  $env:FAKE_GH = Join-Path $temp 'fake-gh.cmd'
  $env:FAKE_CODEX = Join-Path $temp 'fake-codex.cmd'

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
    ghExecutable = $env:FAKE_GH
    codexExecutable = $env:FAKE_CODEX
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
function Resolve-Executable([string]$Value, [string]$Name) { return (Resolve-Path -LiteralPath $Value).Path }
function Invoke-Tool([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory) {
  $old = Get-Location
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    Set-Location -LiteralPath $WorkingDirectory
    $ErrorActionPreference = 'Continue'
    $output = & $FileName @Arguments 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
    Set-Location -LiteralPath $old
  }
  return [pscustomobject]@{ ExitCode = $code; Output = @($output | ForEach-Object { $_.ToString() }) }
}
function Test-SelfTest($Config) {
  if ([Console]::OutputEncoding.WebName -ne 'utf-8') { throw 'console output encoding was not UTF-8' }
  if ($OutputEncoding.WebName -ne 'utf-8') { throw 'pipeline output encoding was not UTF-8' }
  Write-Result 'fake SelfTest passed'
}
function Test-RepositoryPreflight($Config) { return [pscustomobject]@{ Branch = 'main' } }
function Get-EligibleIssues($Config) {
  $result = Invoke-Tool $Config.GhPath @('issue','list') $Config.RepoPath
  if ($result.ExitCode -ne 0) { throw "fake gh failed: $($result.Output -join ' ')" }
  $issues = (($result.Output -join "`n") | ConvertFrom-Json)
  return @($issues | Where-Object {
    $names = @($_.labels | ForEach-Object { $_.name })
    'gm-approved' -in $names -and 'ready-for-codex' -in $names
  })
}
function Get-BranchName([int]$IssueNumber, [string]$Title) { return "codex/issue-$IssueNumber-task" }
function Invoke-Once($Config) { Write-Result 'fake Once passed' }
function Release-LocalLock($Config) {}
function Complete-Failure($Config, [string]$Message) {}
'@
  [IO.File]::WriteAllText((Join-Path $temp 'relay.ps1'), $fakeRelay, [Text.UTF8Encoding]::new($false))

  function Invoke-TestProcess([string[]]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $powerShell
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
  if ($self.Stdout -notmatch 'Codex smoke test passed') { throw "smoke success marker was absent: $($self.Stdout)" }
  if ($self.Stdout -notmatch 'SelfTest completed') { throw 'SelfTest completion marker was absent' }

  $dry = Invoke-TestProcess @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $temp 'relay-windows.ps1'), '-Mode', 'DryRun')
  if ($dry.ExitCode -ne 0) { throw "DryRun wrapper failed: $($dry.Stdout) $($dry.Stderr)" }
  if ($dry.Stdout -notmatch '日本語の試運転') { throw "UTF-8 Japanese gh JSON was not preserved: $($dry.Stdout)" }

  Write-Output 'Windows PowerShell 5.1 entrypoint regression passed: default config path, native UTF-8 gh JSON, native Codex stderr tolerance, non-Git smoke flag, README, and Scheduled Task routing.'
} finally {
  if ($null -eq $previousFakeGh) { Remove-Item Env:\FAKE_GH -ErrorAction SilentlyContinue } else { $env:FAKE_GH = $previousFakeGh }
  if ($null -eq $previousFakeCodex) { Remove-Item Env:\FAKE_CODEX -ErrorAction SilentlyContinue } else { $env:FAKE_CODEX = $previousFakeCodex }
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
