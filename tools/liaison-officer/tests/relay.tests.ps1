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
$relayText=Get-Content -Raw -Encoding UTF8 -LiteralPath $relay
foreach($property in @('StandardInputEncoding','StandardOutputEncoding','StandardErrorEncoding')){if($relayText-notmatch($property+'\s*=\s*\$utf8')){throw "Codex worker does not set $property to UTF-8."}}

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
  Invoke-Case 'native stdout stderr stay separate as UTF-8 arrays and stderr is logged' {
    $fixture=Join-Path $sandbox 'stream-fixture.ps1'
    $fixtureText=@'
param([ValidateSet('zero','one','multiple')][string]$Mode)
$utf8=New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding=$utf8
$warning=-join @([char]0x65E5,[char]0x672C,[char]0x8A9E,[char]0x8B66,[char]0x544A)
if($Mode-eq'one'){[Console]::Out.WriteLine('one.txt')}
if($Mode-eq'multiple'){[Console]::Out.WriteLine('one.txt');[Console]::Out.WriteLine('two.txt')}
[Console]::Error.WriteLine($warning)
'@
    [IO.File]::WriteAllText($fixture,$fixtureText,[Text.Encoding]::ASCII)
    $streamLog=Join-Path $sandbox 'stream-log';New-Item -ItemType Directory -Force -Path $streamLog|Out-Null;$script:ActiveRunDirectory=$streamLog
    try {
      $powershell=(Get-Command powershell.exe -ErrorAction Stop).Source
      $zero=Invoke-Tool $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Mode','zero') $sandbox
      $one=Invoke-Tool $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Mode','one') $sandbox
      $multiple=Invoke-Tool $powershell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$fixture,'-Mode','multiple') $sandbox
      if(@($zero.Stdout).Count-ne0-or@($zero.Stderr).Count-ne1){throw 'zero-line stream shape was not preserved'}
      if(@($one.Stdout).Count-ne1-or@($one.Stderr).Count-ne1-or@($one.Output).Count-ne1){throw 'one-line stream shape was not preserved'}
      if(@($multiple.Stdout).Count-ne2-or@($multiple.Stderr).Count-ne1-or@($multiple.Output).Count-ne2){throw 'multiple-line stream shape was not preserved'}
      if($multiple.Output-contains$multiple.Stderr[0]){throw 'stderr leaked into the stdout compatibility alias'}
      $stderrLog=[IO.File]::ReadAllText((Join-Path $streamLog 'native.stderr.log'),[Text.Encoding]::UTF8)
      $expected=-join @([char]0x65E5,[char]0x672C,[char]0x8A9E,[char]0x8B66,[char]0x544A)
      if($stderrLog-notmatch[regex]::Escape($expected)){throw 'UTF-8 stderr was not preserved in the native stderr log'}
    } finally { $script:ActiveRunDirectory=$null }
  }

  Invoke-Case 'CRLF warning on stderr is logged but never becomes a changed path' {
    $warningGit=Join-Path $sandbox 'warning-git.cmd'
    $warningGitText=@'
@echo off
"%LIAISON_TEST_REAL_GIT%" %*
set code=%ERRORLEVEL%
if %code%==0 if /I "%~1"=="diff" if /I "%~2"=="--name-only" echo warning: LF will be replaced by CRLF 1>&2
exit /b %code%
'@ -replace "`n","`r`n"
    [IO.File]::WriteAllText($warningGit,$warningGitText,[Text.Encoding]::ASCII)
    $env:LIAISON_TEST_REAL_GIT=$git
    $warningLog=Join-Path $sandbox 'warning-log';New-Item -ItemType Directory -Force -Path $warningLog|Out-Null;$script:ActiveRunDirectory=$warningLog
    try {
      'ok'|Set-Content -NoNewline (Join-Path $repo 'allowed.txt')
      $warningConfig=[pscustomobject]@{RepoPath=$repo;GitPath=$warningGit;GhPath='fake';CodexPath='fake';baseBranch='main';protectedPaths=$config.protectedPaths;timeoutMinutes=1;LogPath=$config.LogPath;StatePath=$config.StatePath;TempPath=$config.TempPath}
      $report='LIAISON_REPORT_BEGIN'+"`n"+'{"status":"success","summary":"ok","changedFiles":["allowed.txt"],"tests":["fake"],"unresolved":[],"humanReview":true}'+"`nLIAISON_REPORT_END"
      [void](Test-WorkerResult $warningConfig 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$report}))
      $paths=@(Get-ChangedPaths $warningConfig)
      if($paths.Count-ne1-or$paths[0]-ne'allowed.txt'){throw "CRLF stderr changed the path set: $($paths-join ', ')"}
      $stderrLog=[IO.File]::ReadAllText((Join-Path $warningLog 'native.stderr.log'),[Text.Encoding]::UTF8)
      if($stderrLog-notmatch'LF will be replaced by CRLF'){throw 'CRLF warning was not retained in stderr log'}
    } finally {
      Remove-Item Env:\LIAISON_TEST_REAL_GIT -ErrorAction SilentlyContinue
      Remove-Item (Join-Path $repo 'allowed.txt') -ErrorAction SilentlyContinue
      $script:ActiveRunDirectory=$null
    }
  }

  Invoke-Case 'SelfTest executes against fake GitHub and Codex CLIs without removing existing state' {
    & $git -C $repo update-ref refs/remotes/origin/main HEAD
    $fakeGh=Join-Path $sandbox 'fake-gh.cmd'; $fakeCodex=Join-Path $sandbox 'fake-codex.cmd'
@'
@echo off
echo %1 %2>> "%FAKE_GH_CALL_LOG%"
if "%1"=="auth" ( echo authenticated & exit /b 0 )
if "%1"=="api" ( echo {"login":"owner"} & exit /b 0 )
if "%1"=="repo" ( echo {"nameWithOwner":"owner/repo"} & exit /b 0 )
if "%1"=="label" ( echo [{"name":"gm-approved"},{"name":"ready-for-codex"},{"name":"codex-running"},{"name":"awaiting-gm-review"},{"name":"codex-failed"}] & exit /b 0 )
exit /b 1
'@ | Set-Content -Encoding ASCII $fakeGh
    "@echo off`r`necho fake codex`r`nexit /b 0" | Set-Content -Encoding ASCII $fakeCodex
    $callLog=Join-Path $sandbox 'fake-gh.calls.log'; New-Item -ItemType File -Force -Path $callLog|Out-Null; $env:FAKE_GH_CALL_LOG=$callLog
    $stateFile=Join-Path $config.StatePath 'keep.txt'; New-Item -ItemType Directory -Force -Path $config.StatePath|Out-Null; 'keep'|Set-Content $stateFile
    $self=[pscustomobject]@{RepoPath=$repo;GitPath=$git;GhPath=$fakeGh;CodexPath=$fakeCodex;repository='owner/repo';baseBranch='main';codexSubcommand='exec';LogPath=$config.LogPath;StatePath=$config.StatePath;TempPath=$config.TempPath;requiredLabels=@('gm-approved','ready-for-codex','codex-running','awaiting-gm-review','codex-failed')}
    Test-SelfTest $self; if(-not(Test-Path $stateFile)){throw 'SelfTest removed existing state.'}; $calls=@(Get-Content $callLog); foreach($expected in @('auth status','api user','repo view','label list')){if($calls -notcontains $expected){throw "SelfTest did not call fake gh: $expected"}}
  }

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
      @{name='missing-sentinel'; worker=[pscustomobject]@{ExitCode=0;Stdout='no report'}; expect='sentinel is missing'},
      @{name='bad-json'; worker=[pscustomobject]@{ExitCode=0;Stdout='LIAISON_REPORT_BEGIN {bad} LIAISON_REPORT_END'}; expect='JSON is invalid'}
    )
    foreach($case in $cases){ 'x'|Set-Content -NoNewline (Join-Path $repo 'allowed.txt'); Assert-Throws { Test-WorkerResult $config 'main' $base $case.worker } $case.expect; Remove-Item (Join-Path $repo 'allowed.txt') }
    'x'|Set-Content -NoNewline (Join-Path $repo 'allowed.txt')
    Assert-Throws { Test-WorkerResult $config 'other' $base ([pscustomobject]@{ExitCode=0;Stdout='x'}) } 'Codex changed branch'
    $bad='LIAISON_REPORT_BEGIN {"status":"failed","summary":"x","changedFiles":["allowed.txt"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$bad}) } 'not success'
    $missing='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["allowed.txt"],"tests":[],"unresolved":[]} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$missing}) } 'key is missing'
    $mismatch='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["other.txt"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$mismatch}) } 'does not match'
    Remove-Item (Join-Path $repo 'allowed.txt')
  }
  Invoke-Case 'protected path writes are rejected' {
    foreach($path in @('index.html','README.md','.github\workflows\x.yml','archive\codex-sites-deployment\x.txt')) { $dir=Split-Path -Parent (Join-Path $repo $path); if($dir){New-Item -ItemType Directory -Force -Path $dir|Out-Null}; 'x'|Set-Content -NoNewline (Join-Path $repo $path); $report='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["'+($path -replace '\\','/')+'"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'; Assert-Throws {Test-WorkerResult $config 'main' $base ([pscustomobject]@{ExitCode=0;Stdout=$report})} 'Protected path changed'; & $git -C $repo clean -fdq }
  }
  Invoke-Case 'git rename and copy into protected paths are rejected' {
    'source'|Set-Content -NoNewline (Join-Path $repo 'source.txt'); & $git -C $repo add source.txt; & $git -C $repo commit -qm source
    $head=Get-GitValue $config @('rev-parse','HEAD'); & $git -C $repo mv source.txt index.html
    $renameReport='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["index.html"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $head ([pscustomobject]@{ExitCode=0;Stdout=$renameReport}) } 'Protected path changed'
    & $git -C $repo reset --hard -q $head; Copy-Item (Join-Path $repo 'source.txt') (Join-Path $repo 'README.md')
    $copyReport='LIAISON_REPORT_BEGIN {"status":"success","summary":"x","changedFiles":["README.md"],"tests":[],"unresolved":[],"humanReview":true} LIAISON_REPORT_END'
    Assert-Throws { Test-WorkerResult $config 'main' $head ([pscustomobject]@{ExitCode=0;Stdout=$copyReport}) } 'Protected path changed'
    & $git -C $repo reset --hard -q $head
  }
  Invoke-Case 'runtime and config artifacts never become changed paths or staged paths' {
    & $git -C $repo reset --hard -q; & $git -C $repo clean -fdq; New-Item -ItemType Directory -Force -Path $config.LogPath,$config.StatePath,$config.TempPath|Out-Null; 'log'|Set-Content (Join-Path $config.LogPath 'x.log'); '{}'|Set-Content (Join-Path $repo 'config.local.json'); if(@(Get-ChangedPaths $config).Count){throw 'Ignored runtime artifact appeared in changed paths.'}; & $git -C $repo add -- .; if((& $git -C $repo diff --cached --name-only)){throw 'Ignored runtime artifact was staged.'}; & $git -C $repo reset -q
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
  Invoke-Case 'existing state fixture remains available for SelfTest coverage' {
    $oldState=Join-Path $config.StatePath 'kept.txt'; New-Item -ItemType Directory -Force -Path $config.StatePath|Out-Null; 'keep'|Set-Content $oldState; if(-not(Test-Path $oldState)){throw 'Existing state fixture missing.'}
  }
  $reportPath=Join-Path $sandbox 'relay-test-results.json'; $results | ConvertTo-Json -Depth 3 | Set-Content -Encoding UTF8 $reportPath
  Write-Output "relay integration tests passed: $($results.Count) cases; environment=temp Git repo + fake Codex child; results=$reportPath"
} finally { if(Test-Path $sandbox){Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue} }
