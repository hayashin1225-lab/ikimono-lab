[CmdletBinding()]
param(
  [ValidateSet('SelfTest', 'DryRun', 'Once', 'Scheduled')]
  [string]$Mode = 'SelfTest',
  [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.local.json'),
  [switch]$RunCodexSmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExitCode = @{ Success = 0; NoEligibleIssue = 10; Configuration = 20; Preflight = 30; Lock = 40; Codex = 50; Validation = 60; GitHub = 70 }
$RunId = 'LO-{0}-Issue{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), 'pending'
$LockHandle = $null

function Write-Result([string]$Message) { Write-Output "[$RunId] $Message" }
function Stop-WithCode([int]$Code, [string]$Message) { Write-Error "[$RunId] $Message"; exit $Code }
function Normalize-PathValue([string]$Path) { return $Path.Replace('\', '/') }
function Get-Config {
  if (-not (Test-Path -LiteralPath $ConfigPath)) { Stop-WithCode $ExitCode.Configuration "Config file is missing: $ConfigPath" }
  try { $config = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json } catch { Stop-WithCode $ExitCode.Configuration "Config JSON is invalid: $($_.Exception.Message)" }
  foreach ($name in @('repository','repoPath','baseBranch','timeoutMinutes','logDirectory','stateDirectory','temporaryDirectory','requiredLabels','stateLabels','protectedPaths','gitExecutable','ghExecutable','codexExecutable','codexSubcommand','codexArguments')) {
    if ($null -eq $config.$name -or [string]::IsNullOrWhiteSpace([string]$config.$name)) { Stop-WithCode $ExitCode.Configuration "Config value is required: $name" }
  }
  return $config
}
function Resolve-Executable([string]$Value, [string]$Name) {
  if (Test-Path -LiteralPath $Value) { return (Resolve-Path -LiteralPath $Value).Path }
  $command = Get-Command $Value -ErrorAction SilentlyContinue
  if (-not $command) { throw "$Name executable was not found: $Value" }
  return $command.Source
}
function Invoke-Tool([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory) {
  $old = Get-Location
  try { Set-Location -LiteralPath $WorkingDirectory; $output = & $FileName @Arguments 2>&1; $code = $LASTEXITCODE } finally { Set-Location -LiteralPath $old }
  return [pscustomobject]@{ ExitCode = $code; Output = @($output | ForEach-Object { $_.ToString() }) }
}
function Get-GitValue($Config, [string[]]$Arguments) {
  $result = Invoke-Tool $Config.GitPath $Arguments $Config.RepoPath
  if ($result.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $($result.Output -join [Environment]::NewLine)" }
  return ($result.Output -join "`n").Trim()
}
function Test-RepositoryPreflight($Config, [bool]$FetchOrigin = $true) {
  if (-not (Test-Path -LiteralPath $Config.RepoPath)) { throw "repoPath is missing: $($Config.RepoPath)" }
  $branch = Get-GitValue $Config @('branch','--show-current')
  if ($branch -ne $Config.baseBranch) { throw "Current branch must be $($Config.baseBranch), but is $branch." }
  $status = Get-GitValue $Config @('status','--porcelain')
  if ($status) { throw 'Worktree is not clean.' }
  $origin = Get-GitValue $Config @('remote','get-url','origin')
  if ($origin -notmatch [regex]::Escape($Config.repository)) { throw "origin does not match configured repository: $origin" }
  if ($FetchOrigin) {
    $fetch = Invoke-Tool $Config.GitPath @('fetch','origin',$Config.baseBranch) $Config.RepoPath
    if ($fetch.ExitCode -ne 0) { throw "origin/$($Config.baseBranch) could not be fetched." }
  }
  $local = Get-GitValue $Config @('rev-parse',$Config.baseBranch)
  $remote = Get-GitValue $Config @('rev-parse',"origin/$($Config.baseBranch)")
  if ($local -ne $remote) { throw "Local $($Config.baseBranch) does not match origin/$($Config.baseBranch)." }
  if ($branch -match '^archive/') { throw 'A protected archive branch must not be used.' }
  return [pscustomobject]@{ Branch = $branch; Head = $local; Origin = $origin }
}
function Test-RequiredLabels($Config) {
  $labels = Invoke-Tool $Config.GhPath @('label','list','--repo',$Config.repository,'--limit','100','--json','name') $Config.RepoPath
  if ($labels.ExitCode -ne 0) { throw "GitHub labels could not be read: $($labels.Output -join ' ')" }
  $names = @((($labels.Output -join "`n") | ConvertFrom-Json) | ForEach-Object { $_.name })
  return @($Config.requiredLabels | Where-Object { $_ -notin $names })
}
function Get-EligibleIssues($Config) {
  $result = Invoke-Tool $Config.GhPath @('issue','list','--repo',$Config.repository,'--state','open','--limit','100','--json','number,title,createdAt,labels,url') $Config.RepoPath
  if ($result.ExitCode -ne 0) { throw "GitHub issues could not be read: $($result.Output -join ' ')" }
  $issues = (($result.Output -join "`n") | ConvertFrom-Json)
  return @($issues | Where-Object {
    $names = @($_.labels | ForEach-Object { $_.name })
    $_.number -ne 13 -and 'gm-approved' -in $names -and 'ready-for-codex' -in $names -and 'codex-running' -notin $names -and 'awaiting-gm-review' -notin $names -and 'codex-failed' -notin $names
  } | Sort-Object @{Expression = { [DateTime]$_.createdAt }}, @{Expression = { [int]$_.number }})
}
function Get-BranchName([int]$IssueNumber, [string]$Title) {
  $slug = $Title.ToLowerInvariant() -replace '[^a-z0-9]+','-' -replace '^-|-$',''
  if (-not $slug) { $slug = 'task' }; if ($slug.Length -gt 40) { $slug = $slug.Substring(0,40).TrimEnd('-') }
  return "codex/issue-$IssueNumber-$slug"
}
function Acquire-LocalLock($Config, [int]$IssueNumber) {
  $lockPath = Join-Path $Config.StatePath 'liaison.lock'
  if (Test-Path -LiteralPath $lockPath) { throw "Existing lock requires human review: $lockPath" }
  try {
    $script:LockHandle = New-Object System.IO.FileStream($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $data = [Text.Encoding]::UTF8.GetBytes("runId=$RunId`nissue=$IssueNumber`nstartedAt=$([DateTime]::UtcNow.ToString('o'))`npid=$PID`n")
    $script:LockHandle.Write($data,0,$data.Length); $script:LockHandle.Flush()
  } catch { throw "Local lock could not be acquired: $($_.Exception.Message)" }
}
function Release-LocalLock($Config) {
  if ($script:LockHandle) { $script:LockHandle.Dispose(); $script:LockHandle = $null }
  $lockPath = Join-Path $Config.StatePath 'liaison.lock'
  if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
}
function Save-IssueSnapshot($Config, $Issue, [string]$RunDirectory) {
  $detail = Invoke-Tool $Config.GhPath @('issue','view',[string]$Issue.number,'--repo',$Config.repository,'--json','number,title,body,url,labels,createdAt,updatedAt,comments') $Config.RepoPath
  if ($detail.ExitCode -ne 0) { throw "Issue snapshot failed: $($detail.Output -join ' ')" }
  $item = (($detail.Output -join "`n") | ConvertFrom-Json)
  $lines = @("# Issue #$($item.number): $($item.title)", '', "URL: $($item.url)", "Created: $($item.createdAt)", "Updated: $($item.updatedAt)", "Labels: $((@($item.labels | ForEach-Object { $_.name }) -join ', '))", '', '## Body', $item.body, '', '## Comments')
  foreach ($comment in @($item.comments | Sort-Object createdAt)) { $lines += @('', "### $($comment.author.login) — $($comment.createdAt)", $comment.body) }
  $path = Join-Path $RunDirectory 'issue-snapshot.md'; [IO.File]::WriteAllText($path, ($lines -join "`r`n"), [Text.UTF8Encoding]::new($false)); return $path
}
function Quote-ProcessArgument([string]$Value) { if ($Value -notmatch '[\s"]') { return $Value }; return '"' + ($Value -replace '(\\*)"','$1$1\"' -replace '(\\*)$','$1$1') + '"' }
function Invoke-CodexWorker($Config, $Issue, [string]$Branch, [string]$SnapshotPath, [string]$RunDirectory) {
  $template = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $PSScriptRoot 'prompt-template.txt')
  $prompt = $template.Replace('{{ISSUE_SNAPSHOT_PATH}}',$SnapshotPath).Replace('{{BRANCH}}',$Branch).Replace('{{REPOSITORY}}',$Config.repository)
  $promptPath = Join-Path $RunDirectory 'prompt.txt'; [IO.File]::WriteAllText($promptPath,$prompt,[Text.UTF8Encoding]::new($false))
  $stdoutPath = Join-Path $RunDirectory 'codex.stdout.log'; $stderrPath = Join-Path $RunDirectory 'codex.stderr.log'
  $args = @($Config.codexSubcommand) + @($Config.codexArguments) + @('-C',$Config.RepoPath,'-')
  $info = New-Object System.Diagnostics.ProcessStartInfo; $info.FileName = $Config.CodexPath; $info.Arguments = (($args | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' '); $info.WorkingDirectory = $Config.RepoPath; $info.UseShellExecute = $false; $info.RedirectStandardInput = $true; $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
  $process = New-Object System.Diagnostics.Process; $process.StartInfo = $info
  if (-not $process.Start()) { throw 'Codex process did not start.' }
  $process.StandardInput.Write($prompt); $process.StandardInput.Close(); $outTask = $process.StandardOutput.ReadToEndAsync(); $errTask = $process.StandardError.ReadToEndAsync()
  if (-not $process.WaitForExit([int]$Config.timeoutMinutes * 60000)) { & taskkill.exe /PID $process.Id /T /F | Out-Null; throw "Codex timed out after $($Config.timeoutMinutes) minutes." }
  $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult(); [IO.File]::WriteAllText($stdoutPath,$stdout,[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($stderrPath,$stderr,[Text.UTF8Encoding]::new($false))
  return [pscustomobject]@{ ExitCode = $process.ExitCode; StdoutPath = $stdoutPath; StderrPath = $stderrPath; Stdout = $stdout }
}
function Get-ChangedPaths($Config) { return @((Get-GitValue $Config @('status','--porcelain','--untracked-files=all') -split "`n" | Where-Object { $_ } | ForEach-Object { (($_.Substring(3)).Trim() -replace ' -> .*$', '') -replace '\\','/' })) }
function Test-WorkerResult($Config, [string]$StartBranch, [string]$StartHead, $Worker) {
  if ($Worker.ExitCode -ne 0) { throw "Codex exit code: $($Worker.ExitCode)" }
  if ((Get-GitValue $Config @('branch','--show-current')) -ne $StartBranch) { throw 'Codex changed branch.' }
  if ((Get-GitValue $Config @('rev-parse','HEAD')) -ne $StartHead) { throw 'Codex changed HEAD or committed.' }
  $paths = Get-ChangedPaths $Config; if ($paths.Count -eq 0) { throw 'Codex produced no changes.' }
  $check = Invoke-Tool $Config.GitPath @('diff','--check'); if ($check.ExitCode -ne 0) { throw 'git diff --check failed.' }
  foreach ($path in $paths) { foreach ($pattern in $Config.protectedPaths) { $prefix = $pattern.TrimEnd('*'); if ($path -like $pattern -or ($prefix -and $path.StartsWith($prefix))) { throw "Protected path changed: $path" } } }
  $match = [regex]::Match($Worker.Stdout,'LIAISON_REPORT_BEGIN\s*(\{[\s\S]*?\})\s*LIAISON_REPORT_END')
  if (-not $match.Success) { throw 'Codex final report sentinel is missing.' }
  try { $report = $match.Groups[1].Value | ConvertFrom-Json } catch { throw 'Codex final report JSON is invalid.' }
  foreach ($key in @('status','summary','changedFiles','tests','unresolved','humanReview')) { if ($null -eq $report.$key) { throw "Codex report key is missing: $key" } }
  if ($report.status -ne 'success') { throw "Codex report status is not success: $($report.status)" }
  $reported = @($report.changedFiles | ForEach-Object { Normalize-PathValue $_ } | Sort-Object); $actual = @($paths | Sort-Object)
  if ((Compare-Object $reported $actual).Count -ne 0) { throw 'Codex report changedFiles does not match actual changes.' }
  return $report
}
function Set-IssueLabels($Config, [int]$IssueNumber, [string[]]$Add, [string[]]$Remove) {
  foreach ($label in $Add) { $r = Invoke-Tool $Config.GhPath @('issue','edit',[string]$IssueNumber,'--repo',$Config.repository,'--add-label',$label) $Config.RepoPath; if ($r.ExitCode -ne 0) { throw "Could not add label $label" } }
  foreach ($label in $Remove) { $r = Invoke-Tool $Config.GhPath @('issue','edit',[string]$IssueNumber,'--repo',$Config.repository,'--remove-label',$label) $Config.RepoPath; if ($r.ExitCode -ne 0) { throw "Could not remove label $label" } }
}
function Invoke-Once($Config) {
  $preflight = Test-RepositoryPreflight $Config; $missing = Test-RequiredLabels $Config; if ($missing.Count) { throw "Required labels are missing: $($missing -join ', ')" }
  $issues = Get-EligibleIssues $Config; if ($issues.Count -eq 0) { Write-Result 'No eligible Issue. No action taken.'; exit $ExitCode.NoEligibleIssue }
  $issue = $issues[0]; $script:RunId = 'LO-{0}-Issue{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $issue.number; $branch = Get-BranchName $issue.number $issue.title
  Acquire-LocalLock $Config $issue.number
  try {
    $exists = Invoke-Tool $Config.GhPath @('pr','list','--repo',$Config.repository,'--state','open','--head',$branch,'--json','number') $Config.RepoPath
    if ($exists.ExitCode -ne 0 -or ((($exists.Output -join "`n") | ConvertFrom-Json).Count -gt 0)) { throw "Initial execution is blocked by an existing Open PR or lookup failure for $branch." }
    Set-IssueLabels $Config $issue.number @('codex-running') @(); $confirmed = Invoke-Tool $Config.GhPath @('issue','view',[string]$issue.number,'--repo',$Config.repository,'--json','labels') $Config.RepoPath
    if ($confirmed.ExitCode -ne 0 -or 'codex-running' -notin @((($confirmed.Output -join "`n") | ConvertFrom-Json).labels | ForEach-Object { $_.name })) { throw 'codex-running label was not confirmed.' }
    Set-IssueLabels $Config $issue.number @() @('ready-for-codex')
    $runDirectory = Join-Path $Config.LogPath $RunId; New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $snapshot = Save-IssueSnapshot $Config $issue $runDirectory
    $create = Invoke-Tool $Config.GitPath @('checkout','-b',$branch,"origin/$($Config.baseBranch)") $Config.RepoPath; if ($create.ExitCode -ne 0) { throw "Branch creation failed: $($create.Output -join ' ')" }
    $worker = Invoke-CodexWorker $Config $issue $branch $snapshot $runDirectory; $report = Test-WorkerResult $Config $branch $preflight.Head $worker
    $commit = Invoke-Tool $Config.GitPath @('add','--all') $Config.RepoPath; if ($commit.ExitCode -ne 0) { throw 'git add failed.' }; $commit = Invoke-Tool $Config.GitPath @('commit','-m',"issue #$($issue.number): liaison officer change") $Config.RepoPath; if ($commit.ExitCode -ne 0) { throw 'git commit failed.' }
    $head = Get-GitValue $Config @('rev-parse','HEAD'); $push = Invoke-Tool $Config.GitPath @('push','-u','origin',$branch) $Config.RepoPath; if ($push.ExitCode -ne 0) { throw 'git push failed.' }
    $body = "Closes #$($issue.number)`n`nLiaison run ID: $RunId`nInitial execution: yes`nBase SHA: $($preflight.Head)`nHead SHA: $head`n`nCodex report: $($report.summary)`n`nAutomated checks: passed`nUnperformed: human review and public verification`nLocal log ID: $RunId"
    $bodyPath = Join-Path $runDirectory 'pr-body.md'; [IO.File]::WriteAllText($bodyPath,$body,[Text.UTF8Encoding]::new($false)); $pr = Invoke-Tool $Config.GhPath @('pr','create','--repo',$Config.repository,'--base',$Config.baseBranch,'--head',$branch,'--title',"issue #$($issue.number): liaison officer change",'--body-file',$bodyPath) $Config.RepoPath; if ($pr.ExitCode -ne 0) { throw 'PR creation failed.' }
    Set-IssueLabels $Config $issue.number @('awaiting-gm-review') @('codex-running','ready-for-codex','codex-failed'); Invoke-Tool $Config.GhPath @('issue','comment',[string]$issue.number,'--repo',$Config.repository,'--body',"Liaison run $RunId completed. PR: $($pr.Output -join '')") $Config.RepoPath | Out-Null
    $returnMain = Invoke-Tool $Config.GitPath @('checkout',$Config.baseBranch) $Config.RepoPath; if ($returnMain.ExitCode -ne 0) { throw 'Could not return local repository to the base branch.' }
    if ((Get-GitValue $Config @('status','--porcelain'))) { throw 'Worktree is not clean after successful execution.' }
    Write-Result "Completed Issue #$($issue.number)."
  } finally { Release-LocalLock $Config }
}

try {
  $config = Get-Config
  $config | Add-Member -NotePropertyName GitPath -NotePropertyValue (Resolve-Executable $config.gitExecutable 'Git')
  $config | Add-Member -NotePropertyName GhPath -NotePropertyValue (Resolve-Executable $config.ghExecutable 'GitHub CLI')
  $config | Add-Member -NotePropertyName CodexPath -NotePropertyValue (Resolve-Executable $config.codexExecutable 'Codex CLI')
  $config | Add-Member -NotePropertyName LogPath -NotePropertyValue (Join-Path $config.repoPath $config.logDirectory)
  $config | Add-Member -NotePropertyName StatePath -NotePropertyValue (Join-Path $config.repoPath $config.stateDirectory)
  $config | Add-Member -NotePropertyName TempPath -NotePropertyValue (Join-Path $config.repoPath $config.temporaryDirectory)
  if ($Mode -eq 'SelfTest') { $pre = Test-RepositoryPreflight $config $false; $missing = Test-RequiredLabels $config; Write-Result "PowerShell=$($PSVersionTable.PSVersion); branch=$($pre.Branch); head=$($pre.Head)"; Write-Result "Logs=$($config.LogPath); state=$($config.StatePath); temp=$($config.TempPath)"; Write-Result "Missing labels: $($missing -join ', ')"; $testLock = Join-Path $env:TEMP "liaison-officer-$PID.lock"; $stream = New-Object IO.FileStream($testLock,[IO.FileMode]::Create,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $stream.Dispose(); Remove-Item $testLock -Force; Write-Result 'SelfTest completed without external state changes.'; exit $ExitCode.Success }
  if ($Mode -eq 'DryRun') { Test-RepositoryPreflight $config | Out-Null; $issues = Get-EligibleIssues $config; if ($issues.Count -eq 0) { Write-Result 'No eligible Issue. DryRun made no changes.'; exit $ExitCode.NoEligibleIssue }; $chosen=$issues[0]; Write-Result "Candidates=$($issues.Count); selected=#$($chosen.number) '$($chosen.title)'; branch=$(Get-BranchName $chosen.number $chosen.title); labels=ready-for-codex -> codex-running -> awaiting-gm-review"; exit $ExitCode.Success }
  Invoke-Once $config; exit $ExitCode.Success
} catch { if ($LockHandle) { try { Release-LocalLock $config } catch {} }; Stop-WithCode $ExitCode.Preflight $_.Exception.Message }
