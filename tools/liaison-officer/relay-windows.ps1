[CmdletBinding()]
param(
  [ValidateSet('SelfTest', 'DryRun', 'Once', 'Scheduled')]
  [string]$Mode = 'SelfTest',
  [string]$ConfigPath = '',
  [switch]$RunCodexSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$relayPath = Join-Path $PSScriptRoot 'relay.ps1'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}
if (-not (Test-Path -LiteralPath $relayPath)) {
  throw "relay.ps1 is missing: $relayPath"
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$previousInputEncoding = [Console]::InputEncoding
$previousOutputEncoding = [Console]::OutputEncoding
$previousPipelineEncoding = $OutputEncoding
$previousImport = $env:LIAISON_OFFICER_IMPORT
$config = $null
$LockHandle = $null
$script:CurrentStage = 'preflight'

try {
  [Console]::InputEncoding = $utf8
  [Console]::OutputEncoding = $utf8
  $OutputEncoding = $utf8

  $env:LIAISON_OFFICER_IMPORT = '1'
  . $relayPath -Mode $Mode -ConfigPath $ConfigPath

  $config = Get-Config
  $config | Add-Member -NotePropertyName GitPath -NotePropertyValue (Resolve-Executable $config.gitExecutable 'Git')
  $config | Add-Member -NotePropertyName GhPath -NotePropertyValue (Resolve-Executable $config.ghExecutable 'GitHub CLI')
  $config | Add-Member -NotePropertyName CodexPath -NotePropertyValue (Resolve-Executable $config.codexExecutable 'Codex CLI')
  $config | Add-Member -NotePropertyName LogPath -NotePropertyValue (Join-Path $config.repoPath $config.logDirectory)
  $config | Add-Member -NotePropertyName StatePath -NotePropertyValue (Join-Path $config.repoPath $config.stateDirectory)
  $config | Add-Member -NotePropertyName TempPath -NotePropertyValue (Join-Path $config.repoPath $config.temporaryDirectory)

  if ($Mode -eq 'SelfTest') {
    Test-SelfTest $config
    if ($RunCodexSmokeTest) {
      $temp = Join-Path $env:TEMP ("liaison-smoke-{0}" -f $PID)
      New-Item -ItemType Directory -Path $temp -Force | Out-Null
      try {
        $arguments = @(
          $config.codexSubcommand,
          '-s', 'read-only',
          '--ephemeral',
          '--skip-git-repo-check',
          '-C', $temp,
          'Reply with LIAISON_SMOKE_OK only.'
        )
        $result = Invoke-Tool $config.CodexPath $arguments $temp
        $text = $result.Output -join "`n"
        if ($result.ExitCode -ne 0 -or $text -notmatch 'LIAISON_SMOKE_OK') {
          throw "Codex smoke test failed. exit=$($result.ExitCode); output=$text"
        }
        Write-Result 'Codex smoke test passed in an external temporary directory.'
      } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    Write-Result 'SelfTest completed without external state changes.'
    exit $ExitCode.Success
  }

  if ($Mode -eq 'DryRun') {
    Test-RepositoryPreflight $config | Out-Null
    $issues = @(Get-EligibleIssues $config)
    if ($issues.Count -eq 0) {
      Write-Result 'No eligible Issue. DryRun made no changes.'
      exit $ExitCode.NoEligibleIssue
    }
    $chosen = $issues[0]
    Write-Result "Candidates=$($issues.Count); selected=#$($chosen.number) '$($chosen.title)'; branch=$(Get-BranchName $chosen.number $chosen.title); labels=ready-for-codex -> codex-running -> awaiting-gm-review"
    exit $ExitCode.Success
  }

  Invoke-Once $config
  exit $ExitCode.Success
} catch {
  if ($LockHandle -and $null -ne $config) {
    try { Release-LocalLock $config } catch {}
  }
  if ($null -ne $config) {
    try { Complete-Failure $config $_.Exception.Message } catch {}
  }
  $stageCodes = @{
    preflight = 30
    selection = 10
    lock = 40
    'github-state' = 70
    branch = 30
    'issue-snapshot' = 70
    'codex-start' = 50
    'codex-timeout' = 50
    'codex-exit' = 50
    'report-parse' = 60
    validation = 60
    commit = 70
    push = 70
    'pull-request' = 70
    cleanup = 30
  }
  $code = if ($stageCodes.ContainsKey($script:CurrentStage)) { $stageCodes[$script:CurrentStage] } else { 30 }
  Stop-WithCode $code $_.Exception.Message
} finally {
  if ($null -eq $previousImport) {
    Remove-Item Env:\LIAISON_OFFICER_IMPORT -ErrorAction SilentlyContinue
  } else {
    $env:LIAISON_OFFICER_IMPORT = $previousImport
  }
  [Console]::InputEncoding = $previousInputEncoding
  [Console]::OutputEncoding = $previousOutputEncoding
  $OutputEncoding = $previousPipelineEncoding
}
