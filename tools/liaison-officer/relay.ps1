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
$script:CurrentStage = 'preflight'
$script:SelectedIssue = $null

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
  $normalizedOrigin = $origin -replace '\\','/' -replace '\.git$','' -replace '^git@github\.com:','https://github.com/'
  if ($normalizedOrigin -ne "https://github.com/$($Config.repository)") { throw "origin does not exactly match configured repository: $origin" }
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
  New-Item -ItemType Directory -Force -Path $Config.StatePath | Out-Null
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
function Get-ProcessTreeIds([int]$RootProcessId) {
  # CIM is preferred on current Windows; WMI keeps the runtime usable on Windows PowerShell 5.1 hosts.
  $ids = New-Object System.Collections.Generic.List[int]
  $pending = New-Object System.Collections.Queue
  $ids.Add($RootProcessId); $pending.Enqueue($RootProcessId)
  try {
    while ($pending.Count -gt 0) {
      $parentId = [int]$pending.Dequeue()
      try { $children = Get-CimInstance -ClassName Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction Stop } catch { $children = Get-WmiObject -Class Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction Stop }
      foreach ($child in @($children)) { $childId = [int]$child.ProcessId; if (-not $ids.Contains($childId)) { $ids.Add($childId); $pending.Enqueue($childId) } }
    }
  } catch { Write-Result "Process-tree child discovery was unavailable: $($_.Exception.Message)" }
  return @($ids | Sort-Object -Unique)
}
function Get-RemainingProcessIds([int[]]$ProcessIds) {
  return @($ProcessIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
}
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
  Start-Sleep -Milliseconds 50
  $treeIds = @(Get-ProcessTreeIds $process.Id)
  $timedOut = -not $process.WaitForExit([int]$Config.timeoutMinutes * 60000)
  $killPath = Join-Path $RunDirectory 'taskkill.log'
  $killExitCode = $null
  if ($timedOut) {
    $script:CurrentStage='codex-timeout'
    # cmd.exe keeps taskkill's diagnostic as captured output under PowerShell's Stop preference.
    $treeIds = @($treeIds + @(Get-ProcessTreeIds $process.Id) | Sort-Object -Unique)
    $kill = & cmd.exe /d /c "taskkill.exe /PID $($process.Id) /T /F" 2>&1; $killExitCode = $LASTEXITCODE
    [IO.File]::WriteAllText($killPath, ($kill -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [void]$process.WaitForExit(5000)
  }
  $remaining = @(); if($timedOut){$remaining=@(Get-RemainingProcessIds $treeIds)}
  if($timedOut -and ($killExitCode -ne 0 -or -not $process.HasExited -or $remaining.Count -gt 0)){
    [IO.File]::WriteAllText($stdoutPath,'[stdout unavailable: timed-out process did not close its stream]',[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($stderrPath,'[stderr unavailable: timed-out process did not close its stream]',[Text.UTF8Encoding]::new($false))
    throw "Codex timeout; taskkill exit=$killExitCode and parent process did not exit within the bounded wait. Logs were saved."
  }
  $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult(); [IO.File]::WriteAllText($stdoutPath,$stdout,[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($stderrPath,$stderr,[Text.UTF8Encoding]::new($false))
  if($timedOut){
    if($killExitCode -ne 0){throw "Codex timeout; taskkill failed (exit $killExitCode). stdout, stderr, and taskkill logs were saved."}
    if(-not $process.HasExited -or $remaining.Count -gt 0){throw "Codex timeout; remaining process IDs: $($remaining -join ', '). stdout, stderr, and taskkill logs were saved."}
    throw "Codex timed out after $($Config.timeoutMinutes) minutes; process tree IDs $($treeIds -join ', ') terminated and logs were saved."
  }
  return [pscustomobject]@{ ExitCode = $process.ExitCode; StdoutPath = $stdoutPath; StderrPath = $stderrPath; Stdout = $stdout; ProcessIds = $treeIds }
}
function Get-ChangedPaths($Config) {
  $paths = @()
  foreach ($arguments in @(@('diff','--name-only'), @('diff','--cached','--name-only'), @('ls-files','--others','--exclude-standard'))) {
    $result = Invoke-Tool $Config.GitPath $arguments $Config.RepoPath
    if ($result.ExitCode -ne 0) { throw "git $($arguments -join ' ') failed while listing changes." }
    $paths += @($result.Output | Where-Object { $_ } | ForEach-Object { Normalize-PathValue $_ })
  }
  return @($paths | Sort-Object -Unique)
}
function Test-WorkerResult($Config, [string]$StartBranch, [string]$StartHead, $Worker) {
  if ($Worker.ExitCode -ne 0) { $script:CurrentStage='codex-exit'; throw "Codex exit code: $($Worker.ExitCode)" }
  if ((Get-GitValue $Config @('branch','--show-current')) -ne $StartBranch) { throw 'Codex changed branch.' }
  if ((Get-GitValue $Config @('rev-parse','HEAD')) -ne $StartHead) { throw 'Codex changed HEAD or committed.' }
  $paths = @(Get-ChangedPaths $Config); if ($paths.Count -eq 0) { throw 'Codex produced no changes.' }
  $check = Invoke-Tool $Config.GitPath @('diff','--check') $Config.RepoPath; if ($check.ExitCode -ne 0) { throw 'git diff --check failed.' }
  foreach ($path in $paths) { foreach ($pattern in $Config.protectedPaths) { $prefix = $pattern.TrimEnd('*'); if ($path -like $pattern -or ($prefix -and $path.StartsWith($prefix))) { throw "Protected path changed: $path" } } }
  $match = [regex]::Match($Worker.Stdout,'LIAISON_REPORT_BEGIN\s*(\{[\s\S]*?\})\s*LIAISON_REPORT_END')
  if (-not $match.Success) { $script:CurrentStage='report-parse'; throw 'Codex final report sentinel is missing.' }
  try { $report = $match.Groups[1].Value | ConvertFrom-Json } catch { $script:CurrentStage='report-parse'; throw 'Codex final report JSON is invalid.' }
  foreach ($key in @('status','summary','changedFiles','tests','unresolved','humanReview')) { if ($null -eq $report.PSObject.Properties[$key] -or $null -eq $report.PSObject.Properties[$key].Value) { throw "Codex report key is missing: $key" } }
  if ($report.status -ne 'success') { throw "Codex report status is not success: $($report.status)" }
  $reported = @($report.changedFiles | ForEach-Object { Normalize-PathValue $_ } | Sort-Object); $actual = @($paths | Sort-Object)
  if (@(Compare-Object $reported $actual).Count -ne 0) { throw 'Codex report changedFiles does not match actual changes.' }
  return $report
}
function Set-IssueLabels($Config, [int]$IssueNumber, [string[]]$Add, [string[]]$Remove) {
  foreach ($label in $Add) { $r = Invoke-Tool $Config.GhPath @('issue','edit',[string]$IssueNumber,'--repo',$Config.repository,'--add-label',$label) $Config.RepoPath; if ($r.ExitCode -ne 0) { throw "Could not add label $label" } }
  foreach ($label in $Remove) { $r = Invoke-Tool $Config.GhPath @('issue','edit',[string]$IssueNumber,'--repo',$Config.repository,'--remove-label',$label) $Config.RepoPath; if ($r.ExitCode -ne 0) { throw "Could not remove label $label" } }
  $verify = Invoke-Tool $Config.GhPath @('issue','view',[string]$IssueNumber,'--repo',$Config.repository,'--json','labels') $Config.RepoPath
  if($verify.ExitCode -ne 0){throw 'Issue labels could not be re-read after update.'}
  $names=@((($verify.Output -join "`n")|ConvertFrom-Json).labels|ForEach-Object{$_.name})
  foreach($label in $Add){if($label -notin $names){throw "Added label was not confirmed: $label"}}
  foreach($label in $Remove){if($label -in $names){throw "Removed label was not confirmed: $label"}}
}
function Complete-Failure($Config, [string]$Message) {
  if(-not $script:SelectedIssue){return}
  try { Set-IssueLabels $Config $script:SelectedIssue.number @('codex-failed') @('codex-running','ready-for-codex','awaiting-gm-review') } catch { Write-Error "[$RunId] failure label cleanup also failed: $($_.Exception.Message)" }
  try { $safe = ($Message -replace 'C:\\Users\\[^\\\s]+','[local-path]' -replace '(gho|github_pat)_[A-Za-z0-9_\-]+','[redacted]'); $comment = Invoke-Tool $Config.GhPath @('issue','comment',[string]$script:SelectedIssue.number,'--repo',$Config.repository,'--body',"Liaison run $RunId failed at $script:CurrentStage. $safe Human review is required.") $Config.RepoPath; if($comment.ExitCode -ne 0){throw 'Issue failure comment was rejected.'} } catch { Write-Error "[$RunId] failure comment also failed: $($_.Exception.Message)" }
}
function Test-SelfTest($Config) {
  $pre = Test-RepositoryPreflight $Config $false
  $auth = Invoke-Tool $Config.GhPath @('auth','status','--hostname','github.com') $Config.RepoPath
  if ($auth.ExitCode -ne 0) { throw 'GitHub CLI authentication is not active.' }
  $identity = Invoke-Tool $Config.GhPath @('api','user') $Config.RepoPath
  if ($identity.ExitCode -ne 0) { throw 'GitHub CLI login could not be read.' }
  try { $login = ((($identity.Output -join "`n") | ConvertFrom-Json).login) } catch { throw 'GitHub CLI user response is invalid.' }
  $owner = ($Config.repository -split '/')[0]
  if ($login -ne $owner) { throw "GitHub CLI login $login does not match repository owner $owner." }
  $repo = Invoke-Tool $Config.GhPath @('repo','view',$Config.repository,'--json','nameWithOwner') $Config.RepoPath
  if ($repo.ExitCode -ne 0) { throw 'Configured repository is not accessible.' }
  foreach ($args in @(@('--version'),@('--help'),@($Config.codexSubcommand,'--help'))) { $check = Invoke-Tool $Config.CodexPath $args $Config.RepoPath; if ($check.ExitCode -ne 0) { throw "Codex CLI check failed: $($args -join ' ')" } }
  $missing = Test-RequiredLabels $Config
  foreach ($path in @($Config.LogPath,$Config.StatePath,$Config.TempPath)) { $parent = Split-Path -Parent $path; if (-not (Test-Path $parent)) { $parent = Split-Path -Parent $parent }; if (-not (Test-Path $parent)) { throw "Runtime parent directory is not available: $path" } }
  $stateExisted=Test-Path $Config.StatePath; $runtimeRoot=Split-Path -Parent $Config.StatePath; $runtimeExisted=Test-Path $runtimeRoot; $probe = Join-Path $Config.StatePath ".probe-$PID.lock"
  try { New-Item -ItemType Directory -Force -Path $Config.StatePath | Out-Null; $stream = New-Object IO.FileStream($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None); $stream.Dispose(); foreach($path in @($Config.LogPath,$Config.TempPath)){New-Item -ItemType Directory -Force -Path $path | Out-Null; $file=Join-Path $path ".probe-$PID"; [IO.File]::WriteAllText($file,'probe'); Remove-Item $file -Force} } finally { if(Test-Path $probe){Remove-Item $probe -Force}; if(-not $stateExisted -and (Test-Path $Config.StatePath) -and -not (Get-ChildItem -Force $Config.StatePath | Select-Object -First 1)){Remove-Item $Config.StatePath -Force}; if(-not $runtimeExisted -and (Test-Path $runtimeRoot) -and -not (Get-ChildItem -Force $runtimeRoot | Select-Object -First 1)){Remove-Item $runtimeRoot -Force} }
  Write-Result "PowerShell=$($PSVersionTable.PSVersion); GitHub login=$login; authenticated repository=$($Config.repository); branch=$($pre.Branch); head=$($pre.Head)"
  Write-Result "Runtime paths: logs=$($Config.LogPath); state=$($Config.StatePath); temp=$($Config.TempPath); missingLabels=$($missing -join ', ')"
}
function Invoke-CodexSmokeTest($Config) {
  $temp = Join-Path $env:TEMP "liaison-smoke-$PID"; New-Item -ItemType Directory -Path $temp -Force | Out-Null
  try { $result = Invoke-Tool $Config.CodexPath @($Config.codexSubcommand,'-s','read-only','--ephemeral','-C',$temp,'Reply with LIAISON_SMOKE_OK only.') $temp; if($result.ExitCode -ne 0 -or ($result.Output -join "`n") -notmatch 'LIAISON_SMOKE_OK'){throw 'Codex smoke test failed.'}; Write-Result 'Codex smoke test passed in an external temporary directory.' } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Invoke-Once($Config) {
  $script:CurrentStage = 'preflight'
  $preflight = Test-RepositoryPreflight $Config; $missing = @(Test-RequiredLabels $Config); if ($missing.Count) { throw "Required labels are missing: $($missing -join ', ')" }
  $issues = @(Get-EligibleIssues $Config); if ($issues.Count -eq 0) { Write-Result 'No eligible Issue. No action taken.'; exit $ExitCode.NoEligibleIssue }
  $script:CurrentStage = 'selection'; $issue = $issues[0]; $script:SelectedIssue = $issue; $script:RunId = 'LO-{0}-Issue{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $issue.number; $branch = Get-BranchName $issue.number $issue.title
  $script:CurrentStage = 'lock'
  Acquire-LocalLock $Config $issue.number
  try {
    $script:CurrentStage = 'branch'; $openResult=Invoke-Tool $Config.GhPath @('pr','list','--repo',$Config.repository,'--state','open','--json','number,headRefName,headRefOid,body,createdAt') $Config.RepoPath; if($openResult.ExitCode -ne 0){throw 'Open PR lookup failed.'}; $open=@((($openResult.Output -join "`n")|ConvertFrom-Json)); $issuePattern='(?<![0-9])#'+[regex]::Escape([string]$issue.number)+'(?![0-9])'; $issuePr=@($open|Where-Object{$_.body -match $issuePattern}); $headPr=@($open|Where-Object{$_.headRefName -eq $branch}); $localRef=Invoke-Tool $Config.GitPath @('show-ref','--verify','--quiet',"refs/heads/$branch") $Config.RepoPath; $remoteRef=Invoke-Tool $Config.GitPath @('show-ref','--verify','--quiet',"refs/remotes/origin/$branch") $Config.RepoPath
    $isRework=$false; $reworkApproval=$null; if($issuePr.Count -eq 1 -and $headPr.Count -eq 1 -and $issuePr[0].number -eq $headPr[0].number -and $issuePr[0].body -match 'Liaison run ID:' -and $localRef.ExitCode -eq 0 -and $remoteRef.ExitCode -eq 0){$localTip=Get-GitValue $Config @('rev-parse',$branch); $remoteTip=Get-GitValue $Config @('rev-parse',"origin/$branch"); if($localTip -ne $remoteTip -or $localTip -ne $issuePr[0].headRefOid){throw 'Rework branch, remote branch, and PR head SHA do not match.'}; $issueDetail=Invoke-Tool $Config.GhPath @('issue','view',[string]$issue.number,'--repo',$Config.repository,'--json','comments,labels') $Config.RepoPath; if($issueDetail.ExitCode -ne 0){throw 'Rework approval comments could not be read.'}; $issueState=(($issueDetail.Output -join "`n")|ConvertFrom-Json); $labelNames=@($issueState.labels|ForEach-Object{$_.name}); $approvalPattern='LIAISON_REWORK_APPROVED'; $reworkApproval=@($issueState.comments|Where-Object{$_.body -match $approvalPattern -and $_.body -match [regex]::Escape($issuePr[0].headRefOid) -and ([DateTime]$_.createdAt) -gt ([DateTime]$issuePr[0].createdAt)}|Sort-Object createdAt|Select-Object -Last 1); $prHistory=Invoke-Tool $Config.GhPath @('pr','view',[string]$issuePr[0].number,'--repo',$Config.repository,'--json','comments') $Config.RepoPath; if($prHistory.ExitCode -ne 0){throw 'Rework history could not be read.'}; $usedApprovalIds=@(((($prHistory.Output -join "`n")|ConvertFrom-Json).comments|ForEach-Object{if($_.body -match 'Approval comment:\s*(\S+)'){$Matches[1]}})); if('gm-approved' -notin $labelNames -or 'ready-for-codex' -notin $labelNames -or -not $reworkApproval -or $reworkApproval[0].id -in $usedApprovalIds){throw 'Rework requires fresh labels and an unused later LIAISON_REWORK_APPROVED comment naming the current existing head SHA.'}; $isRework=$true}
    if(-not $isRework -and ($localRef.ExitCode -eq 0 -or $remoteRef.ExitCode -eq 0 -or $headPr.Count -gt 0 -or $issuePr.Count -gt 0)){throw 'Initial execution is blocked by an existing local branch, remote branch, matching-head PR, or Issue-referencing Open PR.'}
    $script:CurrentStage = 'github-state'; Set-IssueLabels $Config $issue.number @('codex-running') @(); $confirmed = Invoke-Tool $Config.GhPath @('issue','view',[string]$issue.number,'--repo',$Config.repository,'--json','labels') $Config.RepoPath
    if ($confirmed.ExitCode -ne 0 -or 'codex-running' -notin @((($confirmed.Output -join "`n") | ConvertFrom-Json).labels | ForEach-Object { $_.name })) { throw 'codex-running label was not confirmed.' }
    Set-IssueLabels $Config $issue.number @() @('ready-for-codex')
    $script:CurrentStage = 'issue-snapshot'; $runDirectory = Join-Path $Config.LogPath $RunId; New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    $snapshot = Save-IssueSnapshot $Config $issue $runDirectory
    $script:CurrentStage = 'branch'; $createArgs=if($isRework){@('checkout',$branch)}else{@('checkout','-b',$branch,"origin/$($Config.baseBranch)")}; $create = Invoke-Tool $Config.GitPath $createArgs $Config.RepoPath; if ($create.ExitCode -ne 0) { throw "Branch preparation failed: $($create.Output -join ' ')" }
    $workerStartBranch=Get-GitValue $Config @('branch','--show-current'); $workerStartHead=Get-GitValue $Config @('rev-parse','HEAD')
    $script:CurrentStage = 'codex-start'; $worker = Invoke-CodexWorker $Config $issue $branch $snapshot $runDirectory; $script:CurrentStage = 'validation'; $report = Test-WorkerResult $Config $workerStartBranch $workerStartHead $worker
    $verifiedPaths=@(Get-ChangedPaths $Config); $script:CurrentStage = 'commit'; $commit = Invoke-Tool $Config.GitPath (@('add','--') + $verifiedPaths) $Config.RepoPath; if ($commit.ExitCode -ne 0) { throw 'git add failed.' }; $staged=@(Get-GitValue $Config @('diff','--cached','--name-only') -split "`n"|Where-Object{$_}|ForEach-Object{Normalize-PathValue $_}); if(@(Compare-Object ($verifiedPaths|Sort-Object) ($staged|Sort-Object)).Count -ne 0){throw 'Staged paths differ from verified paths.'}; $cachedCheck=Invoke-Tool $Config.GitPath @('diff','--cached','--check') $Config.RepoPath; if($cachedCheck.ExitCode -ne 0){throw 'git diff --cached --check failed.'}; $commit = Invoke-Tool $Config.GitPath @('commit','-m',"issue #$($issue.number): liaison officer change") $Config.RepoPath; if ($commit.ExitCode -ne 0) { throw 'git commit failed.' }
    $script:CurrentStage = 'push'; $head = Get-GitValue $Config @('rev-parse','HEAD'); $push = Invoke-Tool $Config.GitPath @('push','-u','origin',$branch) $Config.RepoPath; if ($push.ExitCode -ne 0) { throw 'git push failed.' }
    $body = "Closes #$($issue.number)`n`nLiaison run ID: $RunId`nInitial execution: yes`nBase SHA: $($preflight.Head)`nHead SHA: $head`n`nCodex report: $($report.summary)`n`nAutomated checks: passed`nUnperformed: human review and public verification`nLocal log ID: $RunId"
    $script:CurrentStage = 'pull-request'; $bodyPath = Join-Path $runDirectory 'pr-body.md'; [IO.File]::WriteAllText($bodyPath,$body,[Text.UTF8Encoding]::new($false)); if($isRework){$pr=[pscustomobject]@{Output=@($issuePr[0].number)}; $reworkBody="Liaison rework record`nRun ID: $RunId`nIssue: #$($issue.number)`nMode: rework`nPrevious head SHA: $workerStartHead`nNew head SHA: $head`nApproval comment: $($reworkApproval[0].id)`nCodex report: $($report.summary)`nAutomated checks: $($report.tests -join '; ')`nLocal log ID: $RunId`nUnperformed: human review and public verification"; $update=Invoke-Tool $Config.GhPath @('pr','comment',[string]$issuePr[0].number,'--repo',$Config.repository,'--body',$reworkBody) $Config.RepoPath; if($update.ExitCode -ne 0){throw 'Existing PR update comment failed.'}}else{$pr = Invoke-Tool $Config.GhPath @('pr','create','--repo',$Config.repository,'--base',$Config.baseBranch,'--head',$branch,'--title',"issue #$($issue.number): liaison officer change",'--body-file',$bodyPath) $Config.RepoPath; if ($pr.ExitCode -ne 0) { throw 'PR creation failed.' }}
    $script:CurrentStage = 'cleanup'; $returnMain = Invoke-Tool $Config.GitPath @('checkout',$Config.baseBranch) $Config.RepoPath; if ($returnMain.ExitCode -ne 0) { throw 'Could not return local repository to the base branch.' }
    if ((Get-GitValue $Config @('status','--porcelain'))) { throw 'Worktree is not clean after successful execution.' }
    $script:CurrentStage = 'github-state'; Set-IssueLabels $Config $issue.number @('awaiting-gm-review') @('codex-running','ready-for-codex','codex-failed'); $successComment=Invoke-Tool $Config.GhPath @('issue','comment',[string]$issue.number,'--repo',$Config.repository,'--body',"Liaison run $RunId completed. PR: $($pr.Output -join '')") $Config.RepoPath; if($successComment.ExitCode -ne 0){throw 'Success comment failed.'}; Write-Result "Completed Issue #$($issue.number)."
  } finally { Release-LocalLock $Config }
}

if ($env:LIAISON_OFFICER_IMPORT -eq '1') { return }

try {
  $config = Get-Config
  $config | Add-Member -NotePropertyName GitPath -NotePropertyValue (Resolve-Executable $config.gitExecutable 'Git')
  $config | Add-Member -NotePropertyName GhPath -NotePropertyValue (Resolve-Executable $config.ghExecutable 'GitHub CLI')
  $config | Add-Member -NotePropertyName CodexPath -NotePropertyValue (Resolve-Executable $config.codexExecutable 'Codex CLI')
  $config | Add-Member -NotePropertyName LogPath -NotePropertyValue (Join-Path $config.repoPath $config.logDirectory)
  $config | Add-Member -NotePropertyName StatePath -NotePropertyValue (Join-Path $config.repoPath $config.stateDirectory)
  $config | Add-Member -NotePropertyName TempPath -NotePropertyValue (Join-Path $config.repoPath $config.temporaryDirectory)
  if ($Mode -eq 'SelfTest') { Test-SelfTest $config; if($RunCodexSmokeTest){Invoke-CodexSmokeTest $config}; Write-Result 'SelfTest completed without external state changes.'; exit $ExitCode.Success }
  if ($Mode -eq 'DryRun') { Test-RepositoryPreflight $config | Out-Null; $issues = @(Get-EligibleIssues $config); if ($issues.Count -eq 0) { Write-Result 'No eligible Issue. DryRun made no changes.'; exit $ExitCode.NoEligibleIssue }; $chosen=$issues[0]; Write-Result "Candidates=$($issues.Count); selected=#$($chosen.number) '$($chosen.title)'; branch=$(Get-BranchName $chosen.number $chosen.title); labels=ready-for-codex -> codex-running -> awaiting-gm-review"; exit $ExitCode.Success }
  Invoke-Once $config; exit $ExitCode.Success
} catch { if ($LockHandle) { try { Release-LocalLock $config } catch {} }; try { Complete-Failure $config $_.Exception.Message } catch {}; $stageCodes=@{preflight=30;selection=10;lock=40;'github-state'=70;branch=30;'issue-snapshot'=70;'codex-start'=50;'codex-timeout'=50;'codex-exit'=50;'report-parse'=60;validation=60;commit=70;push=70;'pull-request'=70;cleanup=30}; $code=if($stageCodes.ContainsKey($script:CurrentStage)){$stageCodes[$script:CurrentStage]}else{30}; Stop-WithCode $code $_.Exception.Message }
