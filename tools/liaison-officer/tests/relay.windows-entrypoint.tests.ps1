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

$sourceText = Get-Content -Raw -Encoding UTF8 -LiteralPath $source
if ($sourceText -notmatch 'StandardOutputEncoding\s*=\s*\$utf8') {
  throw 'Windows entrypoint does not explicitly decode native stdout as UTF-8.'
}
if ($sourceText -notmatch 'StandardErrorEncoding\s*=\s*\$utf8') {
  throw 'Windows entrypoint does not explicitly decode native stderr as UTF-8.'
}
if ($sourceText -notmatch 'Stdout\s*=\s*@\(\$stdout\)' -or
    $sourceText -notmatch 'Stderr\s*=\s*@\(\$stderr\)' -or
    $sourceText -notmatch 'Output\s*=\s*@\(\$stdout\)') {
  throw 'Windows entrypoint does not return separate stdout/stderr arrays with a stdout-only compatibility alias.'
}
if ($sourceText -match '\$output\s*\+=\s*\$stderr') {
  throw 'Windows entrypoint still merges stderr into the path-consumed output stream.'
}
if ($sourceText -notmatch '\$requestedCodexSmokeTest\s*=\s*\[bool\]\$RunCodexSmokeTest') {
  throw 'Windows entrypoint does not preserve the requested Codex smoke switch before importing relay.ps1.'
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

  # Keep the fixture source ASCII-only because Windows PowerShell 5.1 treats
  # UTF-8 .ps1 files without a BOM as the active ANSI code page. Build the
  # Japanese title from Unicode code points, then emit its JSON as UTF-8.
  $fakeGhScript = @'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$title = -join @(
  [char]0x65E5,
  [char]0x672C,
  [char]0x8A9E,
  [char]0x306E,
  [char]0x8A66,
  [char]0x904B,
  [char]0x8EE2
)
$json = '[{"number":20,"title":"' + $title + '","createdAt":"2026-01-01T00:00:00Z","labels":[{"name":"gm-approved"},{"name":"ready-for-codex"}],"url":"https://github.test/owner/repo/issues/20"}]'
[Console]::Error.WriteLine('warning: LF will be replaced by CRLF')
[Console]::Out.Write($json)
'@
  [IO.File]::WriteAllText((Join-Path $temp 'fake-gh.ps1'), $fakeGhScript, [Text.Encoding]::ASCII)
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
echo LIAISON_SMOKE_OK 1>&2
exit /b 0
'@ -replace "`n", "`r`n"
  [IO.File]::WriteAllText((Join-Path $temp 'fake-codex.cmd'), $fakeCodexCmd, [Text.Encoding]::ASCII)

  $env:FAKE_GH = Join-Path $temp 'fake-gh.cmd'
  $env:FAKE_CODEX = Join-Path $temp 'fake-codex.cmd'

  $fakeRelay = @'
[CmdletBinding()]
param(
  [string]$Mode = 'SelfTest',
  [string]$ConfigPath = '',
  [switch]$RunCodexSmokeTest
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
function Quote-ProcessArgument([string]$Value) {
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\*)$','$1$1') + '"'
}
function Convert-ProcessTextToLines([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return @() }
  $trimmed = $Text.TrimEnd([char[]]"`r`n")
  if ([string]::IsNullOrEmpty($trimmed)) { return @() }
  return @($trimmed -split "`r?`n")
}
function Get-ToolCombinedLines($Result) { return @(@($Result.Stdout) + @($Result.Stderr)) }
function Write-NativeStderrLog([string]$FileName,[string[]]$Arguments,[string[]]$Stderr) {}
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
  throw 'relay-windows.ps1 did not replace the legacy native invocation path.'
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
  [IO.File]::WriteAllText((Join-Path $temp 'relay.ps1'), $fakeRelay, [Text.Encoding]::ASCII)

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
  if ($self.Stdout -notmatch 'Codex smoke test passed') { throw "requested smoke switch was lost across relay import or stderr sentinel was not captured: $($self.Stdout)" }
  if ($self.Stdout -notmatch 'SelfTest completed') { throw 'SelfTest completion marker was absent' }

  $dry = Invoke-TestProcess @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $temp 'relay-windows.ps1'), '-Mode', 'DryRun')
  if ($dry.ExitCode -ne 0) { throw "DryRun wrapper failed: $($dry.Stdout) $($dry.Stderr)" }
  $expectedTitle = -join @(
    [char]0x65E5,
    [char]0x672C,
    [char]0x8A9E,
    [char]0x306E,
    [char]0x8A66,
    [char]0x904B,
    [char]0x8EE2
  )
  if ($dry.Stdout -notmatch [regex]::Escape($expectedTitle)) {
    throw "UTF-8 Japanese gh JSON was not preserved: $($dry.Stdout)"
  }

  Write-Output 'Windows PowerShell 5.1 entrypoint regression passed: smoke switch preserved across relay import, ASCII-safe UTF-8 fixture, CRLF-like stderr isolated from native gh JSON, explicit native stdout/stderr decoding, default config path, non-Git smoke flag, README, and Scheduled Task routing.'
} finally {
  if ($null -eq $previousFakeGh) { Remove-Item Env:\FAKE_GH -ErrorAction SilentlyContinue } else { $env:FAKE_GH = $previousFakeGh }
  if ($null -eq $previousFakeCodex) { Remove-Item Env:\FAKE_CODEX -ErrorAction SilentlyContinue } else { $env:FAKE_CODEX = $previousFakeCodex }
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
