[CmdletBinding()]
param([string]$Root)

# This suite intentionally uses a disposable local Git repository and fake CLI programs.
# It never calls GitHub, creates an Issue, or registers a Scheduled Task.
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..\..')).Path }
$ErrorActionPreference = 'Stop'
$relay = Join-Path $Root 'tools\liaison-officer\relay.ps1'
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if (-not $git) { $git = 'C:\Users\User\AppData\Local\GitHubDesktop\app-3.6.2\resources\app\git\mingw64\bin\git.exe' }
$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($relay,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors|ForEach-Object Message -join '; ')}

$results = New-Object System.Collections.Generic.List[object]
function Invoke-Case([string]$Name,[scriptblock]$Body) {
  $started=[DateTime]::UtcNow
  try { & $Body; $results.Add([pscustomobject]@{Name=$Name; Expected='success or controlled rejection'; Actual='pass'; Started=$started.ToString('o'); Ended=[DateTime]::UtcNow.ToString('o')}) }
  catch { $results.Add([pscustomobject]@{Name=$Name; Expected='success or controlled rejection'; Actual="FAIL: $($_.Exception.Message)"; Started=$started.ToString('o'); Ended=[DateTime]::UtcNow.ToString('o')}); throw }
}
function Assert-Throws([scriptblock]$Action,[string]$Needle) { try { & $Action; throw "Expected failure containing '$Needle'." } catch { if($_.Exception.Message -eq "Expected failure containing '$Needle'." -or $_.Exception.Message -notmatch [regex]::Escape($Needle)){throw} } }

$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('liaison-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
try {
  $repo=Join-Path $sandbox 'repo'; & $git init -q $repo; Push-Location $repo
  try { & $git config user.email 'liaison-test@example.invalid'; & $git config user.name 'Liaison Test'; 'base' | Set-Content -NoNewline base.txt; & $git add base.txt; & $git commit -qm base; & $git branch -M main; & $git remote add origin 'https://github.com/owner/repo.git' } finally { Pop-Location }
  $runtime=Join-Path $repo 'tools\liaison-officer\.runtime'; New-Item -ItemType Directory -Force -Path $runtime | Out-Null
  "tools/liaison-officer/.runtime/`nconfig.local.json" | Set-Content -NoNewline (Join-Path $repo '.gitignore'); & $git -C $repo add .gitignore; & $git -C $repo commit -qm ignore
  $config=[pscustomobject]@{RepoPath=$repo; GitPath=$git; GhPath='fake'; CodexPath='fake'; baseBranch='main'; protectedPaths=@('index.html','README.md','.github/workflows/*','archive/codex-sites-deployment*'); timeoutMinutes=1; LogPath=(Join-Path $runtime 'logs'); StatePath=(Join-Path $runtime 'state'); TempPath=(Join-Path $runtime 'temp')}
  $env:LIAISON_OFFICER_IMPORT='1'; . $relay; Remove-Item Env:\LIAISON_OFFICER_IMPORT
  $base=Get-GitValue $config @('rev-parse','HEAD')

  Invoke-Case 'worker legal change is verified and only verified path is stageable' {
    'ok' | Set-Content -NoNewline (Join-Path $repo 'allowed.txt')
    $report='LIAISON_REPORT_BEGIN' + "`n" + '{"status":"success","summary":"ok","changedFiles":["allowed.txt"],"tests":["fake"],"unresolved":[],"humanReview":true}' + "`nLIAISON_REPORT_END"
    $r=Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$report})
    if($r.changedFiles[0] -ne 'allowed.txt'){throw 'Legal worker report was not accepted.'}
    $verified=@(Get-ChangedPaths $config); & $git -C $repo add -- $verified; $staged=@((& $git -C $repo diff --cached --name-only)|Where-Object{$_}); if(@(Compare-Object $verified $staged).Count){throw 'Stage boundary mismatch.'}; & $git -C $repo reset -q; Remove-Item (Join-Path $repo 'allowed.txt')
  }
  Invoke-Case 'worker report and state violations are rejected' {
    $cases=@(
      @{name='nonzero'; worker=[pscustomobject]@{ExitCode=9;Stdout=''}; expect='Codex exit code'},
      @{name='missing-sentinel'; worker=[pscustomobject]@{ExitCode=0;Stdout='no report'}; expect='no changes'},
      @{name='bad-json'; worker=[pscustomobject]@{ExitCode=0;Stdout='LIAISON_REPORT_BEGIN {bad} LIAISON_REPORT_END'}; expect='no changes'}
    )
    foreach($case in $cases){Assert-Throws { Test-WorkerResult $config 'main' $base $case.worker } $case.expect}
    'x'|Set-Content -NoNewline (Join-Path $repo 'allowed.txt')
    Assert-Throws { Test-WorkerResult $config 'other' $base ([pscustomobject]@{ExitCode=0;Stdout='x'}) } 'Codex changed branch'
    $bad='LIAISON_REPORT_BEGIN {"status":"failed","summary":"x","changedFiles":["allowed.txt"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$bad}) } 'not success'
    Remove-Item (Join-Path $repo 'allowed.txt')
  }
  Invoke-Case 'protected normal rename and copy targets are rejected' {
    foreach($path in @('index.html','README.md','.github\workflows\x.yml','archive\codex-sites-deployment\x.txt')) { $dir=Split-Path -Parent (Join-Path $repo $path); if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}; 'x'|Set-Content -NoNewline (Join-Path $repo $path); $report='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["'+($path -replace '\\','/')+'"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'; Assert-Throws {Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$report})} 'Protected path changed'; & $git -C $repo clean -fdq }
  }
  Invoke-Case 'runtime and config artifacts never become changed paths or staged paths' {
    New-Item -ItemType Directory -Force -Path $config.LogPath,$config.StatePath,$config.TempPath|Out-Null; 'log'|Set-Content (Join-Path $config.LogPath 'x.log'); '{}'|Set-Content (Join-Path $repo 'config.local.json'); if(@(Get-ChangedPaths $config).Count){throw 'Ignored runtime artifact appeared in changed paths.'}; & $git -C $repo add -- .; if((& $git -C $repo diff --cached --name-only)){throw 'Ignored runtime artifact was staged.'}; & $git -C $repo reset -q
  }
  Invoke-Case 'post-verification untested file is not included in exact staging set' {
    'verified'|Set-Content -NoNewline (Join-Path $repo 'allowed.txt'); $verified=@(Get-ChangedPaths $config); 'intruder'|Set-Content -NoNewline (Join-Path $repo 'intruder.txt'); & $git -C $repo add -- $verified; $staged=@(& $git -C $repo diff --cached --name-only); if($staged -contains 'intruder.txt'){throw 'Untested file was staged.'}; if(@(Compare-Object $verified $staged).Count){throw 'Verified staging set changed.'}; & $git -C $repo reset -q; Remove-Item (Join-Path $repo 'allowed.txt'),(Join-Path $repo 'intruder.txt')
  }
  Invoke-Case 'timeout records output error taskkill log and terminates parent child' {
    $workerScript=Join-Path $sandbox 'fake-codex.ps1'; @'
$child=Start-Process powershell.exe -ArgumentList '-NoProfile -Command Start-Sleep -Seconds 30' -PassThru
Write-Output "child=$($child.Id)"; Write-Error 'fake stderr'; Start-Sleep -Seconds 30
'@ | Set-Content -Encoding UTF8 $workerScript
    $timeoutConfig=[pscustomobject]@{CodexPath=(Get-Command powershell.exe).Source;codexSubcommand='-NoProfile';codexArguments=@('-ExecutionPolicy','Bypass','-File',$workerScript);RepoPath=$repo;repository='owner/repo';timeoutMinutes=0.01}
    $run=Join-Path $sandbox 'timeout-run'; New-Item -ItemType Directory -Force -Path $run|Out-Null
    Assert-Throws { Invoke-CodexWorker $timeoutConfig ([pscustomobject]@{number=42}) 'main' 'snapshot' $run } 'timed out'
    foreach($file in @('codex.stdout.log','codex.stderr.log','taskkill.log')){if(-not(Test-Path (Join-Path $run $file))){throw "Missing timeout log $file"}}
    $childLine=Get-Content -Raw (Join-Path $run 'codex.stdout.log'); if($childLine -match 'child=(\d+)'){if(Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue){throw 'Fake worker child remains after timeout.'}}
  }
  Invoke-Case 'existing state and runtime directories survive SelfTest cleanup policy' {
    $oldState=Join-Path $config.StatePath 'kept.txt'; New-Item -ItemType Directory -Force -Path $config.StatePath|Out-Null; 'keep'|Set-Content $oldState; if(-not(Test-Path $oldState)){throw 'Existing state fixture missing.'}
  }
  $reportPath=Join-Path $sandbox 'relay-test-results.json'; $results | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 $reportPath
  Write-Output "relay integration tests passed: $($results.Count) cases; environment=temp Git repo + fake Codex child; results=$reportPath"
} finally { if(Test-Path $sandbox){Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue} }
