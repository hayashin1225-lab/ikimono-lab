[CmdletBinding()]
param([string]$Root)

# Entry-point E2E support.  Every JSON collection is normalized at every read
# boundary so ConvertFrom-Json's one-item object shape cannot change behavior.
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path }
$Root = (Resolve-Path -LiteralPath $Root).Path
$ErrorActionPreference='Stop'
$relay = Join-Path $Root 'tools\liaison-officer\relay.ps1'
$fakeGhImplementation = Join-Path $Root 'tools\liaison-officer\tests\fixtures\fake-gh.ps1'
$fakeGhLauncher = Join-Path $Root 'tools\liaison-officer\tests\fixtures\fake-gh-launcher.ps1'
$fakeCodexImplementation = Join-Path $Root 'tools\liaison-officer\tests\fixtures\fake-codex.ps1'
$powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
$collectionNames = @('issues','prs','comments','labels','reviews','ghCalls','codexCalls','commits','branches','failures')

function Convert-ToArray($Value) { if($null -eq $Value){return @()}; return @($Value) }
function Get-StateArray($State,[string]$Name) { return @(Convert-ToArray $State.$Name) }
function Save-State($Path,$State) {
  foreach($name in $collectionNames) {
    if($State.PSObject.Properties.Name -notcontains $name){$State|Add-Member -NotePropertyName $name -NotePropertyValue @()}
    $State.$name=@(Convert-ToArray $State.$name)
  }
  $json=$State|ConvertTo-Json -Depth 50
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$json,[Text.UTF8Encoding]::new($false))
}
function Read-State($Path) {
  $state=[IO.File]::ReadAllText([IO.Path]::GetFullPath($Path),[Text.Encoding]::UTF8)|ConvertFrom-Json
  foreach($name in $collectionNames) {
    if($state.PSObject.Properties.Name -notcontains $name){$state|Add-Member -NotePropertyName $name -NotePropertyValue @()}
    $state.$name=@(Convert-ToArray $state.$name)
  }
  return $state
}
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Assert-Equal($Actual,$Expected,[string]$Message){if($Actual -ne $Expected){throw "$Message Expected=[$Expected] Actual=[$Actual]"}}
function Assert-Match([string]$Actual,[string]$Pattern,[string]$Message){if($Actual -notmatch $Pattern){throw "$Message Actual=[$Actual]"}}
function Get-LabelNames($Issue){return @($Issue.labels|ForEach-Object{if($_ -is [string]){$_}else{[string]$_.name}})}

function New-FakeGh([string]$Directory) {
  if(-not(Test-Path -LiteralPath $fakeGhImplementation)){throw 'fake-gh.ps1 fixture is unavailable'}
  if(-not(Test-Path -LiteralPath $fakeGhLauncher)){throw 'fake-gh-launcher.ps1 fixture is unavailable'}
  return [pscustomobject]@{Launcher=(Resolve-Path -LiteralPath $fakeGhLauncher).Path;Implementation=(Resolve-Path -LiteralPath $fakeGhImplementation).Path}
}
function New-FakeCodex([string]$Directory) {
  if(-not(Test-Path -LiteralPath $fakeCodexImplementation)){throw 'fake-codex.ps1 fixture is unavailable'}
  $launcher=Join-Path $Directory 'fake-codex.cmd'
  $content="@echo off`r`nif /I not `"%~1`"==`"-C`" (echo Fake Codex expected -C 1>&2 & exit /b 64)`r`nif not `"%~3`"==`"-`" (echo Fake Codex expected stdin marker 1>&2 & exit /b 64)`r`n`"$powerShell`" -NoProfile -ExecutionPolicy Bypass -File `"$fakeCodexImplementation`" -RepositoryArgument `"%~2`" -StdinMarker`r`nexit /b %ERRORLEVEL%"
  [IO.File]::WriteAllText($launcher,$content,[Text.Encoding]::ASCII)
  return [pscustomobject]@{Executable=(Get-Command cmd.exe -ErrorAction Stop).Source;Implementation=(Resolve-Path -LiteralPath $fakeCodexImplementation).Path;Launcher=(Resolve-Path -LiteralPath $launcher).Path;Subcommand='/d';Arguments=@('/s','/c',(Resolve-Path -LiteralPath $launcher).Path)}
}
function Invoke-Native([string]$File,[string[]]$Arguments,[string]$Directory) {
  $old=Get-Location;$previous=$ErrorActionPreference
  try{Set-Location -LiteralPath $Directory;$ErrorActionPreference='Continue';$output=& $File @Arguments 2>&1;$code=$LASTEXITCODE}
  finally{$ErrorActionPreference=$previous;Set-Location -LiteralPath $old}
  return [pscustomobject]@{ExitCode=$code;Output=@($output|ForEach-Object{$_.ToString()})}
}
function Invoke-FakeGh($Gh,[string[]]$Arguments,[string]$Directory) {
  return Invoke-Native $Gh.Launcher $Arguments $Directory
}
function Convert-OutputJson($Result) {
  return (($Result.Output -join "`n")|ConvertFrom-Json)
}
function New-FailingGitWrapper([string]$Directory,[string]$RealGit,[string]$Command) {
  $wrapper=Join-Path $Directory 'fake-git.cmd';$log=Join-Path $Directory 'fake-git.log'
  $content=@'
@echo off
echo executable=%~f0 args=%*>> "%FAKE_GIT_LOG%"
if /I "%~1"=="%FAKE_GIT_FAIL_COMMAND%" (
  echo Injected fake Git failure for %~1 1>&2
  exit /b 86
)
"%FAKE_GIT_REAL%" %*
exit /b %ERRORLEVEL%
'@
  [IO.File]::WriteAllText($wrapper,$content,[Text.Encoding]::ASCII)
  $env:FAKE_GIT_REAL=(Resolve-Path -LiteralPath $RealGit).Path;$env:FAKE_GIT_FAIL_COMMAND=$Command;$env:FAKE_GIT_LOG=$log
  return [pscustomobject]@{Executable=(Resolve-Path -LiteralPath $wrapper).Path;Log=$log;FailedCommand=$Command}
}
function Invoke-RealGit([string]$Git,[string]$Directory,[string[]]$Arguments) {
  $previous=$ErrorActionPreference;$ErrorActionPreference='Continue'
  try{$output=& $Git -C $Directory @Arguments 2>&1;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$previous}
  if($code -ne 0){throw "git $($Arguments -join ' ') failed ($code): $($output -join "`n")"}
  return @($output)
}
function New-TemporaryBareRemote([string]$Git,[string]$Root) {
  $bare=Join-Path $Root 'remote.git';$seed=Join-Path $Root 'seed';$repo=Join-Path $Root 'repo'
  & $Git init --bare -q $bare;if($LASTEXITCODE){throw 'bare init failed'}
  & $Git init -q $seed;if($LASTEXITCODE){throw 'seed init failed'}
  [void](Invoke-RealGit $Git $seed @('config','user.email','entry@test.invalid'));[void](Invoke-RealGit $Git $seed @('config','user.name','Entry Test'))
  [IO.File]::WriteAllText((Join-Path $seed '.gitignore'),"tools/liaison-officer/.runtime/`n",[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $seed 'base.txt'),'base',[Text.UTF8Encoding]::new($false))
  [void](Invoke-RealGit $Git $seed @('add','.'));[void](Invoke-RealGit $Git $seed @('commit','-m','seed'));[void](Invoke-RealGit $Git $seed @('branch','-M','main'));[void](Invoke-RealGit $Git $seed @('remote','add','origin','../remote.git'));[void](Invoke-RealGit $Git $seed @('push','--receive-pack=/mingw64/bin/git-receive-pack.exe','-u','origin','main'))
  & $Git --git-dir=$bare symbolic-ref HEAD refs/heads/main;if($LASTEXITCODE){throw 'bare HEAD setup failed'}
  & $Git clone --upload-pack=/mingw64/bin/git-upload-pack.exe -q $bare $repo;if($LASTEXITCODE){throw 'clone failed'}
  [void](Invoke-RealGit $Git $repo @('config','user.email','entry@test.invalid'));[void](Invoke-RealGit $Git $repo @('config','user.name','Entry Test'))
  [void](Invoke-RealGit $Git $repo @('config','remote.origin.uploadpack','/mingw64/bin/git-upload-pack.exe'));[void](Invoke-RealGit $Git $repo @('config','remote.origin.receivepack','/mingw64/bin/git-receive-pack.exe'))
  [void](Invoke-RealGit $Git $repo @('remote','set-url','origin','../remote.git'));[void](Invoke-RealGit $Git $repo @('fetch','origin','main'));[void](Invoke-RealGit $Git $repo @('checkout','main'))
  $base=((Invoke-RealGit $Git $repo @('rev-parse','main'))-join '').Trim()
  return [pscustomobject]@{Bare=(Resolve-Path $bare).Path;Seed=(Resolve-Path $seed).Path;Repo=(Resolve-Path $repo).Path;ExpectedOrigin='../remote.git';BaseSha=$base}
}

# Static inventory of every gh contract reachable from relay.ps1.  The direct
# contract phase below exercises every row before any relay entry point runs.
$GhContracts=@(
  [pscustomobject][ordered]@{Id='label-list';Command='label list';Arguments='label list --repo <repo> --limit 100 --json name';Required=@('--repo','--limit','--json');Optional=@();Stdout='JSON array of {name}';ExitCode=0;Stderr='empty on success';JsonShape='array';StateMutation='ghCalls only';History='absolute executable/state paths, argv, before/after';RelayVerification='required label names are complete'},
  [pscustomobject][ordered]@{Id='issue-list';Command='issue list';Arguments='issue list --repo <repo> --state open --limit 100 --json number,title,createdAt,labels,url';Required=@('--repo','--state','--limit','--json');Optional=@();Stdout='JSON array of Issue objects';ExitCode=0;Stderr='empty on success';JsonShape='array';StateMutation='ghCalls only';History='full call record';RelayVerification='filter, #13 exclusion, createdAt/number ordering'},
  [pscustomobject][ordered]@{Id='issue-view-snapshot';Command='issue view';Arguments='issue view <number> --repo <repo> --json number,title,body,url,labels,createdAt,updatedAt,comments';Required=@('<number>','--repo','--json');Optional=@();Stdout='single Issue JSON object';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='ghCalls only';History='full call record';RelayVerification='snapshot fields and comment order'},
  [pscustomobject][ordered]@{Id='issue-view-labels';Command='issue view';Arguments='issue view <number> --repo <repo> --json labels';Required=@('<number>','--repo','--json');Optional=@();Stdout='single object with labels';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='ghCalls only';History='same absolute state as edit';RelayVerification='added/removed labels are re-read'},
  [pscustomobject][ordered]@{Id='issue-view-rework';Command='issue view';Arguments='issue view <number> --repo <repo> --json comments,labels';Required=@('<number>','--repo','--json');Optional=@();Stdout='single object with arrays';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='ghCalls only';History='full call record';RelayVerification='fresh approval and current labels'},
  [pscustomobject][ordered]@{Id='issue-edit-add';Command='issue edit';Arguments='issue edit <number> --repo <repo> --add-label <label>';Required=@('<number>','--repo','--add-label');Optional=@();Stdout='empty';ExitCode=0;Stderr='empty on success';JsonShape='none';StateMutation='Issue labels and updatedAt';History='before/after state';RelayVerification='subsequent issue view contains label'},
  [pscustomobject][ordered]@{Id='issue-edit-remove';Command='issue edit';Arguments='issue edit <number> --repo <repo> --remove-label <label>';Required=@('<number>','--repo','--remove-label');Optional=@();Stdout='empty';ExitCode=0;Stderr='empty on success';JsonShape='none';StateMutation='Issue labels and updatedAt';History='before/after state';RelayVerification='subsequent issue view omits label'},
  [pscustomobject][ordered]@{Id='issue-comment';Command='issue comment';Arguments='issue comment <number> --repo <repo> --body <text>';Required=@('<number>','--repo','--body');Optional=@();Stdout='comment URL text';ExitCode=0;Stderr='empty on success';JsonShape='text';StateMutation='comments';History='body argv and before/after';RelayVerification='nonzero is rejected'},
  [pscustomobject][ordered]@{Id='pr-list';Command='pr list';Arguments='pr list --repo <repo> --state open --json number,headRefName,headRefOid,body,createdAt';Required=@('--repo','--state','--json');Optional=@();Stdout='JSON array of PR objects';ExitCode=0;Stderr='empty on success';JsonShape='array';StateMutation='synchronized heads plus ghCalls';History='full call record';RelayVerification='initial/rework collision and SHA checks'},
  [pscustomobject][ordered]@{Id='pr-create';Command='pr create';Arguments='pr create --repo <repo> --base <base> --head <head> --title <title> --body-file <path>';Required=@('--repo','--base','--head','--title','--body-file');Optional=@();Stdout='created PR URL text';ExitCode=0;Stderr='empty on success';JsonShape='text';StateMutation='prs, branches, commits';History='body-file argv and before/after';RelayVerification='nonzero is rejected and returned URL is reported'},
  [pscustomobject][ordered]@{Id='pr-view';Command='pr view';Arguments='pr view <number> --repo <repo> --json comments';Required=@('<number>','--repo','--json');Optional=@();Stdout='single PR JSON object';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='synchronized head plus ghCalls';History='full call record';RelayVerification='approval comment IDs are not reused'},
  [pscustomobject][ordered]@{Id='pr-comment';Command='pr comment';Arguments='pr comment <number> --repo <repo> --body <text>';Required=@('<number>','--repo','--body');Optional=@();Stdout='comment URL text';ExitCode=0;Stderr='empty on success';JsonShape='text';StateMutation='comments and synchronized PR head';History='structured rework body and before/after';RelayVerification='nonzero is rejected'},
  [pscustomobject][ordered]@{Id='auth-status';Command='auth status';Arguments='auth status --hostname github.com';Required=@('--hostname');Optional=@();Stdout='authentication status text';ExitCode=0;Stderr='empty on success';JsonShape='text';StateMutation='ghCalls only';History='full call record';RelayVerification='exit code must be zero'},
  [pscustomobject][ordered]@{Id='api-user';Command='api user';Arguments='api user';Required=@('user');Optional=@();Stdout='single {login} JSON object';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='ghCalls only';History='full call record';RelayVerification='login equals repository owner'},
  [pscustomobject][ordered]@{Id='repo-view';Command='repo view';Arguments='repo view <repo> --json nameWithOwner';Required=@('<repo>','--json');Optional=@();Stdout='single repository JSON object';ExitCode=0;Stderr='empty on success';JsonShape='object';StateMutation='ghCalls only';History='full call record';RelayVerification='repository is accessible'}
)

function New-Issue([int]$Number,[string]$Title,[string]$CreatedAt,[string[]]$Labels,[string]$Body='body') {
  $values=@();$index=0
  foreach($label in $Labels){if(($index++ % 2)-eq 0){$values+=@($label)}else{$values+=@([pscustomobject]@{name=$label})}}
  return [pscustomobject][ordered]@{number=$Number;title=$Title;state='open';body=$Body;url="https://github.test/owner/repo/issues/$Number";createdAt=$CreatedAt;updatedAt=$CreatedAt;labels=@($values);comments=@()}
}
function New-TestState([object[]]$Issues=@(),[object[]]$Prs=@(),[string]$CodexMode='success',[object[]]$Failures=@()) {
  return [pscustomobject][ordered]@{
    labels=@('gm-approved',[pscustomobject]@{name='ready-for-codex'},'codex-running',[pscustomobject]@{name='awaiting-gm-review'},'codex-failed')
    issues=@($Issues);prs=@($Prs);comments=@();reviews=@();ghCalls=@();codexCalls=@();commits=@();branches=@();failures=@($Failures)
    authenticatedUser=[pscustomobject][ordered]@{login='owner'}
    currentRepo='owner/repo'
    repository=[pscustomobject][ordered]@{nameWithOwner='owner/repo'}
    codexBehavior=[pscustomobject][ordered]@{mode=$CodexMode;file='allowed.txt';contentPrefix='fake change '}
  }
}
function Get-StateIssue($State,[int]$Number){$match=@($State.issues|Where-Object{[int]$_.number-eq$Number});Assert ($match.Count-eq1) "Issue #$Number is not unique in state";return $match[0]}
function Get-StatePr($State,[int]$Number){$match=@($State.prs|Where-Object{[int]$_.number-eq$Number});Assert ($match.Count-eq1) "PR #$Number is not unique in state";return $match[0]}
function Set-FixtureEnvironment($Gh,[string]$StatePath,[string]$GhLog,[string]$Git,[string]$Repo) {
  $env:FAKE_GH_STATE=(Resolve-Path -LiteralPath $StatePath).Path
  $env:FAKE_GH_LOG=[IO.Path]::GetFullPath($GhLog)
  $env:FAKE_GH_EXECUTABLE=$Gh.Launcher
  $env:FAKE_GH_REAL_GIT=$Git
  $env:FAKE_GH_REPO=$Repo
  $env:FAKE_CODEX_STATE=$env:FAKE_GH_STATE
  $env:FAKE_CODEX_REPO=$Repo
}
function New-RelayConfig([string]$Path,$Remote,$Gh,$Codex,[string]$GitExecutable,[double]$TimeoutMinutes=1) {
  $config=[ordered]@{
    repository='owner/repo';repoPath=$Remote.Repo;baseBranch='main';expectedOrigin=$Remote.ExpectedOrigin;timeoutMinutes=$TimeoutMinutes
    logDirectory='tools/liaison-officer/.runtime/logs';stateDirectory='tools/liaison-officer/.runtime/state';temporaryDirectory='tools/liaison-officer/.runtime/temp'
    requiredLabels=@('gm-approved','ready-for-codex','codex-running','awaiting-gm-review','codex-failed');stateLabels=@('ready-for-codex','codex-running','awaiting-gm-review','codex-failed')
    protectedPaths=@('index.html','.github/workflows/**','archive/codex-sites-deployment/**','.git/**')
    gitExecutable=$GitExecutable;ghExecutable=$Gh.Launcher;codexExecutable=$Codex.Executable;codexSubcommand=$Codex.Subcommand;codexArguments=@($Codex.Arguments)
  }
  [IO.File]::WriteAllText($Path,($config|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  return $Path
}
function Invoke-Relay([string]$Mode,[string]$ConfigPath,[string]$Directory) {
  return Invoke-Native $powerShell @('-NoProfile','-ExecutionPolicy','Bypass','-File',$relay,'-Mode',$Mode,'-ConfigPath',$ConfigPath) $Directory
}
function Assert-JsonArrayResult($Result,[int]$Count,[string]$Message) {
  Assert-Equal $Result.ExitCode 0 "$Message exit code"
  $raw=($Result.Output-join "`n").Trim();Assert ($raw.StartsWith('[')) "$Message did not return a JSON array: $raw"
  $converted=$raw|ConvertFrom-Json;$parsed=@($converted);Assert-Equal $parsed.Count $Count "$Message count"
  return @($parsed)
}
function Assert-BaseState([string]$Git,$Remote,[bool]$Clean=$true) {
  $branch=((Invoke-RealGit $Git $Remote.Repo @('branch','--show-current'))-join '').Trim();Assert-Equal $branch 'main' 'repository did not return to main'
  $status=((Invoke-RealGit $Git $Remote.Repo @('status','--porcelain'))-join "`n").Trim()
  if($Clean){Assert ([string]::IsNullOrWhiteSpace($status)) "worktree is not clean: $status"}else{Assert (-not [string]::IsNullOrWhiteSpace($status)) 'expected preserved failure changes were absent'}
}
function Assert-NoGhWrites($State,[string]$Message) {
  $writes=@($State.ghCalls|Where-Object{$_.command-in@('issue edit','issue comment','pr create','pr comment')})
  Assert-Equal $writes.Count 0 "$Message performed a write-like gh command"
}

function Test-FakeGhContracts([string]$Directory,$Gh) {
  $statePath=Join-Path $Directory 'contract-state.json';$logPath=Join-Path $Directory 'contract-gh.jsonl'
  $state=New-TestState;Save-State $statePath $state
  Set-FixtureEnvironment $Gh $statePath $logPath '' $Directory

  $savedState=$env:FAKE_GH_STATE;Remove-Item Env:\FAKE_GH_STATE
  $missingEnv=Invoke-FakeGh $Gh @('label','list','--repo','owner/repo','--limit','100','--json','name') $Directory
  Assert ($missingEnv.ExitCode-ne0) 'fake gh accepted an empty FAKE_GH_STATE'
  $env:FAKE_GH_STATE=Join-Path $Directory 'missing-state.json'
  $missingFile=Invoke-FakeGh $Gh @('label','list','--repo','owner/repo','--limit','100','--json','name') $Directory
  Assert ($missingFile.ExitCode-ne0) 'fake gh accepted a missing state file'
  $env:FAKE_GH_STATE=$savedState

  $labels=Assert-JsonArrayResult (Invoke-FakeGh $Gh @('label','list','--repo','owner/repo','--limit','100','--json','name') $Directory) 5 'label list'
  Assert ('gm-approved'-in@($labels|ForEach-Object{$_.name})) 'label list omitted gm-approved'

  $state=Read-State $statePath;$state.issues=@();Save-State $statePath $state
  [void](Assert-JsonArrayResult (Invoke-FakeGh $Gh @('issue','list','--repo','owner/repo','--state','open','--limit','100','--json','number,title,createdAt,labels,url') $Directory) 0 'issue list zero')
  $state=Read-State $statePath;$state.issues=@(New-Issue 42 'one' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex'));Save-State $statePath $state
  $one=Assert-JsonArrayResult (Invoke-FakeGh $Gh @('issue','list','--repo','owner/repo','--state','open','--limit','100','--json','number,title,createdAt,labels,url') $Directory) 1 'issue list one';Assert-Equal $one[0].number 42 'issue list one number'
  $state=Read-State $statePath;$state.issues=@((New-Issue 42 'one' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),(New-Issue 43 'two' '2026-01-02T00:00:00Z' @('gm-approved','ready-for-codex')));Save-State $statePath $state
  [void](Assert-JsonArrayResult (Invoke-FakeGh $Gh @('issue','list','--repo','owner/repo','--state','open','--limit','100','--json','number,title,createdAt,labels,url') $Directory) 2 'issue list multiple')

  $view=Invoke-FakeGh $Gh @('issue','view','42','--repo','owner/repo','--json','number,title,body,url,labels,createdAt,updatedAt,comments') $Directory;Assert-Equal $view.ExitCode 0 'issue view exit';$viewJson=Convert-OutputJson $view;Assert-Equal $viewJson.number 42 'issue view number'
  $add=Invoke-FakeGh $Gh @('issue','edit','42','--repo','owner/repo','--add-label','codex-running') $Directory;Assert-Equal $add.ExitCode 0 'issue add-label exit'
  $afterAdd=Convert-OutputJson (Invoke-FakeGh $Gh @('issue','view','42','--repo','owner/repo','--json','labels') $Directory);Assert ('codex-running'-in@(Get-LabelNames $afterAdd)) 'issue view did not observe added label'
  $remove=Invoke-FakeGh $Gh @('issue','edit','42','--repo','owner/repo','--remove-label','ready-for-codex') $Directory;Assert-Equal $remove.ExitCode 0 'issue remove-label exit'
  $afterRemove=Convert-OutputJson (Invoke-FakeGh $Gh @('issue','view','42','--repo','owner/repo','--json','labels') $Directory);Assert ('ready-for-codex'-notin@(Get-LabelNames $afterRemove)) 'issue view did not observe removed label'
  $issueComment=Invoke-FakeGh $Gh @('issue','comment','42','--repo','owner/repo','--body','contract issue comment') $Directory;Assert-Equal $issueComment.ExitCode 0 'issue comment exit'
  $issueWithComments=Convert-OutputJson (Invoke-FakeGh $Gh @('issue','view','42','--repo','owner/repo','--json','comments,labels') $Directory);Assert-Equal @($issueWithComments.comments).Count 1 'issue comment view count'

  $state=Read-State $statePath;$state.prs=@();Save-State $statePath $state
  [void](Assert-JsonArrayResult (Invoke-FakeGh $Gh @('pr','list','--repo','owner/repo','--state','open','--json','number,headRefName,headRefOid,body,createdAt') $Directory) 0 'pr list zero')
  $pr1=[pscustomobject][ordered]@{number=7;state='open';headRefName='branch-seven';headRefOid=('7'*40);baseRefName='main';body='Closes #42';title='seven';createdAt='2026-01-01T00:00:00Z';comments=@()}
  $state=Read-State $statePath;$state.prs=@($pr1);$state.branches=@([pscustomobject]@{name='branch-seven';sha=('7'*40)});Save-State $statePath $state
  [void](Assert-JsonArrayResult (Invoke-FakeGh $Gh @('pr','list','--repo','owner/repo','--state','open','--json','number,headRefName,headRefOid,body,createdAt') $Directory) 1 'pr list one')
  $pr2=[pscustomobject][ordered]@{number=8;state='open';headRefName='branch-eight';headRefOid=('8'*40);baseRefName='main';body='Closes #43';title='eight';createdAt='2026-01-02T00:00:00Z';comments=@()}
  $state=Read-State $statePath;$state.prs=@($pr1,$pr2);$state.branches=@([pscustomobject]@{name='branch-seven';sha=('7'*40)},[pscustomobject]@{name='branch-eight';sha=('8'*40)});Save-State $statePath $state
  [void](Assert-JsonArrayResult (Invoke-FakeGh $Gh @('pr','list','--repo','owner/repo','--state','open','--json','number,headRefName,headRefOid,body,createdAt') $Directory) 2 'pr list multiple')

  $state=Read-State $statePath;$state.prs=@();$state.branches=@([pscustomobject]@{name='contract-head';sha=('a'*40)});Save-State $statePath $state
  $bodyPath=Join-Path $Directory 'contract-pr-body.md';[IO.File]::WriteAllText($bodyPath,"Closes #42`n`nLiaison run ID: contract",[Text.UTF8Encoding]::new($false))
  $create=Invoke-FakeGh $Gh @('pr','create','--repo','owner/repo','--base','main','--head','contract-head','--title','contract PR','--body-file',$bodyPath) $Directory;Assert-Equal $create.ExitCode 0 'pr create exit';Assert-Match ($create.Output-join '') '/pull/1' 'pr create URL'
  $created=Convert-OutputJson (Invoke-FakeGh $Gh @('pr','view','1','--repo','owner/repo','--json','number,baseRefName,headRefName,headRefOid,body,comments') $Directory);Assert-Equal $created.baseRefName 'main' 'created PR base';Assert-Equal $created.headRefName 'contract-head' 'created PR head';Assert-Equal $created.headRefOid ('a'*40) 'created PR head SHA'
  $contractPrComment="contract PR comment`nsecond line & symbols";$prComment=Invoke-FakeGh $Gh @('pr','comment','1','--repo','owner/repo','--body',$contractPrComment) $Directory;Assert-Equal $prComment.ExitCode 0 'pr comment exit'
  $prWithComments=Convert-OutputJson (Invoke-FakeGh $Gh @('pr','view','1','--repo','owner/repo','--json','comments') $Directory);Assert-Equal @($prWithComments.comments).Count 1 'pr comment view count'
  Assert-Equal $prWithComments.comments[0].body $contractPrComment 'pr comment multiline body'

  $auth=Invoke-FakeGh $Gh @('auth','status','--hostname','github.com') $Directory;Assert-Equal $auth.ExitCode 0 'auth status exit';Assert-Match ($auth.Output-join ' ') 'owner' 'auth status response'
  $user=Invoke-FakeGh $Gh @('api','user') $Directory;Assert-Equal $user.ExitCode 0 'api user exit';Assert-Equal (Convert-OutputJson $user).login 'owner' 'api user login'
  $repo=Invoke-FakeGh $Gh @('repo','view','owner/repo','--json','nameWithOwner') $Directory;Assert-Equal $repo.ExitCode 0 'repo view exit';Assert-Equal (Convert-OutputJson $repo).nameWithOwner 'owner/repo' 'repo view nameWithOwner'
  $unsupported=Invoke-FakeGh $Gh @('workflow','list') $Directory;Assert ($unsupported.ExitCode-ne0) 'unsupported fake gh command returned success'

  $state=Read-State $statePath
  foreach($command in @($GhContracts.Command|Sort-Object -Unique)){Assert (@($state.ghCalls|Where-Object{$_.command-eq$command}).Count-gt0) "contract command was not recorded: $command"}
  foreach($call in @($state.ghCalls)){Assert-Equal $call.executablePath $Gh.Launcher 'ghCalls executable path';Assert-Equal $call.implementationPath $Gh.Implementation 'ghCalls implementation path';Assert-Equal $call.statePath ([IO.Path]::GetFullPath($statePath)) 'ghCalls state path';Assert ($null-ne$call.before-and$null-ne$call.after) 'ghCalls omitted before/after state'}
  $editCall=@($state.ghCalls|Where-Object{$_.command-eq'issue edit'}|Select-Object -First 1)[0];$viewCall=@($state.ghCalls|Where-Object{$_.command-eq'issue view'-and$_.startedAt-gt$editCall.startedAt}|Select-Object -First 1)[0]
  Assert ($editCall.processId-ne$viewCall.processId) 'issue edit and view did not run in separate PowerShell processes';Assert-Equal $editCall.statePath $viewCall.statePath 'edit/view state path mismatch'
  Assert-Equal @($state.comments|Where-Object{$_.targetType-eq'issue'}).Count 1 'issue comment was not persisted';Assert-Equal @($state.comments|Where-Object{$_.targetType-eq'pr'}).Count 1 'PR comment was not persisted'
  Assert-Equal @(Get-ChildItem -LiteralPath $Directory -Filter '.fake-gh-state-*.tmp' -Force).Count 0 'atomic state temp files remain'
  Write-Host "fake gh direct contracts passed: $($GhContracts.Count) inventory rows; zero/one/multiple arrays, mutations, persistence, history, and explicit rejection verified."
  return [pscustomobject]@{StatePath=$statePath;Calls=@($state.ghCalls).Count;Contracts=$GhContracts.Count}
}

function Test-BareBranch([string]$Git,$Remote,[string]$Branch) {
  $result=Invoke-Native $Git @("--git-dir=$($Remote.Bare)",'show-ref','--verify','--quiet',"refs/heads/$Branch") $Remote.Repo
  return $result.ExitCode-eq0
}
function Get-BareBranchSha([string]$Git,$Remote,[string]$Branch) {
  $result=Invoke-Native $Git @("--git-dir=$($Remote.Bare)",'rev-parse',"refs/heads/$Branch") $Remote.Repo
  if($result.ExitCode-ne0){throw "bare branch is missing: $Branch"}
  return (($result.Output-join '').Trim())
}
function Assert-SuccessLabels($State,[int]$IssueNumber) {
  $names=@(Get-LabelNames (Get-StateIssue $State $IssueNumber))
  Assert ('gm-approved'-in$names) 'success removed gm-approved';Assert ('awaiting-gm-review'-in$names) 'success omitted awaiting-gm-review'
  foreach($name in @('ready-for-codex','codex-running','codex-failed')){Assert ($name-notin$names) "success retained label $name"}
}
function Assert-FailureState($State,[int]$IssueNumber) {
  $names=@(Get-LabelNames (Get-StateIssue $State $IssueNumber))
  Assert ('gm-approved'-in$names) 'failure removed gm-approved';Assert ('codex-failed'-in$names) 'failure omitted codex-failed'
  foreach($name in @('ready-for-codex','codex-running','awaiting-gm-review')){Assert ($name-notin$names) "failure retained label $name"}
  $failureComments=@($State.comments|Where-Object{$_.targetType-eq'issue'-and[int]$_.number-eq$IssueNumber-and$_.body-match'failed at'})
  Assert ($failureComments.Count-gt0) 'failure comment was not persisted';Assert-Match $failureComments[-1].body 'Human review is required' 'failure comment format'
  Assert-Match $failureComments[-1].body 'captured automatically; manual log relay is not required' 'automatic diagnosis notice'
  Assert-Match $failureComments[-1].body 'Actual paths:' 'failure comment actual paths'
  Assert-Match $failureComments[-1].body 'Cleanup: branchReturn=' 'failure comment cleanup result'
}
function Assert-FakeGhHistory($State,$Gh,[string]$StatePath) {
  foreach($call in @($State.ghCalls)){
    Assert-Equal $call.executablePath $Gh.Launcher 'E2E invoked unexpected fake gh executable'
    Assert-Equal $call.implementationPath $Gh.Implementation 'E2E invoked unexpected fake gh implementation'
    Assert-Equal $call.statePath ([IO.Path]::GetFullPath($StatePath)) 'E2E fake gh state path mismatch'
  }
}

function Test-DryRunMatrix([string]$Directory,[string]$Git,$Codex) {
  New-Item -ItemType Directory -Force -Path $Directory|Out-Null
  $remote=New-TemporaryBareRemote $Git $Directory;$gh=New-FakeGh $Directory
  $statePath=Join-Path $Directory 'dryrun-state.json';$logPath=Join-Path $Directory 'dryrun-gh.jsonl';$configPath=Join-Path $Directory 'dryrun-config.json'
  Save-State $statePath (New-TestState);Set-FixtureEnvironment $gh $statePath $logPath $Git $remote.Repo;[void](New-RelayConfig $configPath $remote $gh $Codex $Git 1)
  $base=$remote.BaseSha
  $fixtures=@(
    [pscustomobject]@{Name='zero';ExpectedExit=10;Selected=$null;Repeats=1;Issues=@(
      (New-Issue 13 'bootstrap' '2025-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 41 'missing-ready' '2026-01-01T00:00:00Z' @('gm-approved')),
      (New-Issue 42 'failed' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex','codex-failed'))
    )},
    [pscustomobject]@{Name='one';ExpectedExit=0;Selected=42;Repeats=1;Issues=@(
      (New-Issue 13 'bootstrap' '2025-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 42 'one' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 43 'running' '2025-12-01T00:00:00Z' @('gm-approved','ready-for-codex','codex-running')),
      (New-Issue 44 'unapproved' '2025-12-01T00:00:00Z' @('ready-for-codex'))
    )},
    [pscustomobject]@{Name='multiple';ExpectedExit=0;Selected=14;Repeats=2;Issues=@(
      (New-Issue 13 'bootstrap' '2025-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 30 'same-time-larger' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 14 'same-time-smaller' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 99 'later' '2026-01-02T00:00:00Z' @('gm-approved','ready-for-codex')),
      (New-Issue 10 'ineligible-running' '2025-01-01T00:00:00Z' @('gm-approved','ready-for-codex','codex-running'))
    )}
  )
  $results=@()
  foreach($fixture in $fixtures){
    $state=New-TestState -Issues $fixture.Issues;Save-State $statePath $state;Set-FixtureEnvironment $gh $statePath $logPath $Git $remote.Repo
    $selectedOutputs=@()
    for($repeat=0;$repeat-lt$fixture.Repeats;$repeat++){
      $run=Invoke-Relay 'DryRun' $configPath $remote.Repo;Assert-Equal $run.ExitCode $fixture.ExpectedExit "DryRun $($fixture.Name) exit"
      $output=$run.Output-join "`n";$selectedOutputs+=@($output-replace '^\[[^\]]+\]\s*','')
      if($null-eq$fixture.Selected){Assert-Match $output 'No eligible Issue' "DryRun $($fixture.Name) output"}else{Assert-Match $output ("selected=#"+$fixture.Selected+"\b") "DryRun $($fixture.Name) selection"}
    }
    if($fixture.Repeats-gt1){Assert-Equal $selectedOutputs[0] $selectedOutputs[1] 'DryRun multiple selection was not deterministic'}
    $state=Read-State $statePath;Assert-NoGhWrites $state "DryRun $($fixture.Name)";Assert-Equal @($state.codexCalls).Count 0 "DryRun $($fixture.Name) invoked Codex";Assert-Equal @($state.prs).Count 0 "DryRun $($fixture.Name) created a PR"
    Assert-FakeGhHistory $state $gh $statePath;Assert-BaseState $Git $remote $true
    $head=((Invoke-RealGit $Git $remote.Repo @('rev-parse','main'))-join '').Trim();Assert-Equal $head $base "DryRun $($fixture.Name) changed main"
    $branches=@(Invoke-RealGit $Git $remote.Repo @('for-each-ref','--format=%(refname:short)','refs/heads'));Assert-Equal $branches.Count 1 "DryRun $($fixture.Name) created a branch";Assert-Equal ($branches[0].Trim()) 'main' "DryRun $($fixture.Name) local branch"
    $results+=@([pscustomobject]@{Name=$fixture.Name;ExitCode=$run.ExitCode;Selected=$fixture.Selected;GhCalls=@($state.ghCalls).Count})
  }
  Write-Host 'DryRun entry-point E2E passed: zero, one, and deterministic multiple candidates; exclusions and no-write boundary verified.'
  return @($results)
}

function Test-InitialAndReworkSuccess([string]$Directory,[string]$Git,$Codex) {
  New-Item -ItemType Directory -Force -Path $Directory|Out-Null
  $remote=New-TemporaryBareRemote $Git $Directory;$gh=New-FakeGh $Directory;$statePath=Join-Path $Directory 'success-state.json';$logPath=Join-Path $Directory 'success-gh.jsonl';$configPath=Join-Path $Directory 'success-config.json'
  $issue=New-Issue 42 'one' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex');Save-State $statePath (New-TestState -Issues @($issue));Set-FixtureEnvironment $gh $statePath $logPath $Git $remote.Repo;[void](New-RelayConfig $configPath $remote $gh $Codex $Git 1)
  $branch='codex/issue-42-one';$initial=Invoke-Relay 'Once' $configPath $remote.Repo;Assert-Equal $initial.ExitCode 0 "initial Once failed: $($initial.Output-join ' | ')"
  $state=Read-State $statePath;Assert-SuccessLabels $state 42;Assert-Equal @($state.prs).Count 1 'initial success PR count';$pr=$state.prs[0]
  Assert-Equal $pr.baseRefName 'main' 'initial PR base';Assert-Equal $pr.headRefName $branch 'initial PR head';Assert-Match $pr.body 'Closes #42' 'initial PR issue reference';Assert-Match $pr.body 'Liaison run ID:' 'initial PR run ID'
  $localSha=((Invoke-RealGit $Git $remote.Repo @('rev-parse',$branch))-join '').Trim();$remoteSha=Get-BareBranchSha $Git $remote $branch;Assert-Equal $localSha $remoteSha 'initial pushed SHA mismatch';Assert-Equal $pr.headRefOid $remoteSha 'initial PR head SHA mismatch'
  $fileAtCommit=((Invoke-RealGit $Git $remote.Repo @('show',"$remoteSha`:allowed.txt"))-join '').Trim();Assert-Match $fileAtCommit '^fake change 1$' 'initial fake Codex artifact'
  $successComments=@($state.comments|Where-Object{$_.targetType-eq'issue'-and$_.body-match'completed'});Assert-Equal $successComments.Count 1 'initial success comment count'
  Assert (@($state.ghCalls|Where-Object{$_.command-eq'pr create'}).Count-eq1) 'initial success did not create exactly one PR';Assert-Equal @($state.codexCalls).Count 1 'initial fake Codex call count'
  Assert-Equal $state.codexCalls[0].implementationPath $Codex.Implementation 'initial fake Codex implementation path';Assert ($state.codexCalls[0].argv-contains'-C') 'initial fake Codex argv omitted -C'
  Assert-FakeGhHistory $state $gh $statePath;Assert-BaseState $Git $remote $true
  $initialPrNumber=[int]$pr.number;$initialPrCreated=[DateTime]$pr.createdAt;$initialCallCount=@($state.ghCalls).Count

  $issueState=Get-StateIssue $state 42;$issueState.labels=@('gm-approved',[pscustomobject]@{name='ready-for-codex'})
  $approval=[pscustomobject][ordered]@{id='approval-1';targetType='issue';number=42;body="LIAISON_REWORK_APPROVED $remoteSha";author=[pscustomobject]@{login='owner'};createdAt=$initialPrCreated.AddMinutes(5).ToUniversalTime().ToString('o');url='https://github.test/approval-1'}
  $state.comments=@($state.comments)+@($approval);$state.failures=@();$state.codexBehavior.mode='success';Save-State $statePath $state;Set-FixtureEnvironment $gh $statePath $logPath $Git $remote.Repo
  $rework=Invoke-Relay 'Once' $configPath $remote.Repo;Assert-Equal $rework.ExitCode 0 "rework Once failed: $($rework.Output-join ' | ')"
  $state=Read-State $statePath;Assert-SuccessLabels $state 42;Assert-Equal @($state.prs).Count 1 'rework created another PR';$pr=Get-StatePr $state $initialPrNumber
  $newRemoteSha=Get-BareBranchSha $Git $remote $branch;Assert ($newRemoteSha-ne$remoteSha) 'rework did not create a new commit';Assert-Equal $pr.headRefOid $newRemoteSha 'rework PR head did not follow pushed branch'
  $newCalls=@($state.ghCalls|Select-Object -Skip $initialCallCount);Assert-Equal @($newCalls|Where-Object{$_.command-eq'pr create'}).Count 0 'rework called pr create';Assert-Equal @($newCalls|Where-Object{$_.command-eq'pr comment'}).Count 1 'rework did not comment exactly once on existing PR'
  $reworkComments=@($state.comments|Where-Object{$_.targetType-eq'pr'-and[int]$_.number-eq$initialPrNumber-and$_.body-match'Liaison rework record'});Assert-Equal $reworkComments.Count 1 'rework PR record count';Assert-Match $reworkComments[0].body 'Approval comment: approval-1' 'rework approval ID record'
  Assert-Equal @($state.codexCalls).Count 2 'rework fake Codex call count';Assert-BaseState $Git $remote $true;Assert-FakeGhHistory $state $gh $statePath
  Write-Host 'Invoke-Once success E2E passed: initial branch/commit/push/PR and approved same-PR rework were verified against a real temporary Git remote.'
  return [pscustomobject]@{Directory=$Directory;Remote=$remote;Gh=$gh;Codex=$Codex;StatePath=$statePath;LogPath=$logPath;ConfigPath=$configPath;Branch=$branch;IssueNumber=42;PrNumber=$initialPrNumber;HeadSha=$newRemoteSha}
}

function Test-InitialFailure([string]$Directory,[string]$Git,$Codex,[string]$Name,[string]$CodexMode,[int]$ExpectedCode,[string]$GitFailureCommand='',$GhFailure=$null,[bool]$ExpectedClean=$true,[bool]$ExpectedRemoteBranch=$false,[int]$ExpectedCodexCalls=1) {
  New-Item -ItemType Directory -Force -Path $Directory|Out-Null
  $remote=New-TemporaryBareRemote $Git $Directory;$gh=New-FakeGh $Directory;$statePath=Join-Path $Directory 'failure-state.json';$logPath=Join-Path $Directory 'failure-gh.jsonl';$configPath=Join-Path $Directory 'failure-config.json';$branch='codex/issue-42-one'
  $failures=if($null-eq$GhFailure){@()}else{@($GhFailure)};$state=New-TestState -Issues @((New-Issue 42 'one' '2026-01-01T00:00:00Z' @('gm-approved','ready-for-codex'))) -CodexMode $CodexMode -Failures $failures
  if($CodexMode-eq'timeout'){$state.codexBehavior|Add-Member -NotePropertyName sleepSeconds -NotePropertyValue 30}
  if($CodexMode-eq'validation-failure'){$state.codexBehavior.file='base.txt'}
  Save-State $statePath $state;Set-FixtureEnvironment $gh $statePath $logPath $Git $remote.Repo
  $gitExecutable=$Git;$wrapper=$null
  if(-not[string]::IsNullOrWhiteSpace($GitFailureCommand)){$wrapper=New-FailingGitWrapper $Directory $Git $GitFailureCommand;$gitExecutable=$wrapper.Executable}else{Remove-Item Env:\FAKE_GIT_REAL,Env:\FAKE_GIT_FAIL_COMMAND,Env:\FAKE_GIT_LOG -ErrorAction SilentlyContinue}
  # Give the separately launched PowerShell fixture enough time to persist its
  # invocation before exercising relay's timeout/process-tree termination path.
  $timeout=if($CodexMode-eq'timeout'){0.05}else{1};[void](New-RelayConfig $configPath $remote $gh $Codex $gitExecutable $timeout)
  $run=Invoke-Relay 'Once' $configPath $remote.Repo;Assert-Equal $run.ExitCode $ExpectedCode "$Name exit: $($run.Output-join ' | ')"
  $state=Read-State $statePath;Assert-FailureState $state 42;Assert-Equal @($state.codexCalls).Count $ExpectedCodexCalls "$Name fake Codex call count";Assert-Equal @($state.prs).Count 0 "$Name unexpectedly persisted a PR"
  Assert-BaseState $Git $remote $ExpectedClean;Assert-Equal (Test-BareBranch $Git $remote $branch) $ExpectedRemoteBranch "$Name remote branch presence"
  Assert (-not(Test-Path -LiteralPath (Join-Path $remote.Repo 'tools\liaison-officer\.runtime\state\liaison.lock'))) "$Name retained local lock"
  $diagnosisFiles=@(Get-ChildItem -LiteralPath (Join-Path $remote.Repo 'tools\liaison-officer\.runtime\logs') -Filter 'failure-diagnosis.json' -File -Recurse)
  Assert-Equal $diagnosisFiles.Count 1 "$Name failure diagnosis count"
  $diagnosis=[IO.File]::ReadAllText($diagnosisFiles[0].FullName,[Text.Encoding]::UTF8)|ConvertFrom-Json
  Assert-Equal $diagnosis.issue 42 "$Name diagnosis issue"
  Assert (-not[string]::IsNullOrWhiteSpace([string]$diagnosis.runId)) "$Name diagnosis omitted run ID"
  Assert (-not[string]::IsNullOrWhiteSpace([string]$diagnosis.branch)) "$Name diagnosis omitted branch"
  Assert (-not[string]::IsNullOrWhiteSpace([string]$diagnosis.head)) "$Name diagnosis omitted HEAD"
  Assert ($null-ne$diagnosis.gitStatus-and$null-ne$diagnosis.actualChangedFiles-and$null-ne$diagnosis.reportedChangedFiles) "$Name diagnosis omitted path/status arrays"
  Assert ($null-ne$diagnosis.lock-and$null-ne$diagnosis.cleanup) "$Name diagnosis omitted lock/cleanup state"
  Assert-Match ($run.Output-join "`n") 'LIAISON_FAILURE_DIAGNOSIS_BEGIN' "$Name did not print diagnosis"
  Assert-FakeGhHistory $state $gh $statePath;Assert-Equal ((Invoke-RealGit $Git $remote.Repo @('remote','get-url','origin'))-join '').Trim() '../remote.git' "$Name used a non-temporary origin"
  if($null-ne$wrapper){$wrapperLog=[IO.File]::ReadAllText($wrapper.Log,[Text.Encoding]::UTF8);Assert-Match $wrapperLog ("args="+$GitFailureCommand+"\b") "$Name Git wrapper did not inject the intended command";Assert ($env:FAKE_GIT_REAL-ne$wrapper.Executable) "$Name Git wrapper delegates recursively"}
  Write-Host "Invoke-Once failure E2E passed: $Name (exit $ExpectedCode)."
  return [pscustomobject]@{Name=$Name;ExitCode=$run.ExitCode;Clean=$ExpectedClean;RemoteBranch=$ExpectedRemoteBranch;GhCalls=@($state.ghCalls).Count;CodexCalls=@($state.codexCalls).Count}
}

function Test-ReworkPrCommentFailure($Context,[string]$Git) {
  $state=Read-State $Context.StatePath;$pr=Get-StatePr $state $Context.PrNumber;$previousHead=$Context.HeadSha;$issue=Get-StateIssue $state $Context.IssueNumber
  $issue.labels=@('gm-approved',[pscustomobject]@{name='ready-for-codex'})
  $approval=[pscustomobject][ordered]@{id='approval-2';targetType='issue';number=$Context.IssueNumber;body="LIAISON_REWORK_APPROVED $previousHead";author=[pscustomobject]@{login='owner'};createdAt=([DateTime]$pr.createdAt).AddMinutes(10).ToUniversalTime().ToString('o');url='https://github.test/approval-2'}
  $state.comments=@($state.comments)+@($approval);$state.failures=@([pscustomobject][ordered]@{command='pr comment';mode='fail';remaining=1;exitCode=91;stderr='Injected PR comment failure'});$state.codexBehavior.mode='success';$beforePrCount=@($state.prs).Count;$beforeCalls=@($state.ghCalls).Count;Save-State $Context.StatePath $state
  Set-FixtureEnvironment $Context.Gh $Context.StatePath $Context.LogPath $Git $Context.Remote.Repo
  $run=Invoke-Relay 'Once' $Context.ConfigPath $Context.Remote.Repo;Assert-Equal $run.ExitCode 70 "rework PR comment failure exit: $($run.Output-join ' | ')"
  $state=Read-State $Context.StatePath;Assert-FailureState $state $Context.IssueNumber;Assert-Equal @($state.prs).Count $beforePrCount 'PR comment failure changed PR count'
  $newHead=Get-BareBranchSha $Git $Context.Remote $Context.Branch;Assert ($newHead-ne$previousHead) 'PR comment failure did not push rework commit';Assert-Equal (Get-StatePr $state $Context.PrNumber).headRefOid $newHead 'PR state did not synchronize pushed head on comment failure'
  $calls=@($state.ghCalls|Select-Object -Skip $beforeCalls);Assert-Equal @($calls|Where-Object{$_.command-eq'pr create'}).Count 0 'PR comment failure created a new PR';Assert-Equal @($calls|Where-Object{$_.command-eq'pr comment'-and[int]$_.exitCode-ne0}).Count 1 'PR comment failure was not injected once'
  Assert-BaseState $Git $Context.Remote $true;Assert-FakeGhHistory $state $Context.Gh $Context.StatePath
  Write-Host 'Invoke-Once failure E2E passed: existing PR comment failure after a pushed rework commit.'
  return [pscustomobject]@{Name='PR comment failure';ExitCode=$run.ExitCode;Clean=$true;RemoteBranch=$true;GhCalls=@($state.ghCalls).Count;CodexCalls=@($state.codexCalls).Count}
}

function Test-ReworkDirtyCheckoutFailure($Context,[string]$Git) {
  $state=Read-State $Context.StatePath;$pr=Get-StatePr $state $Context.PrNumber;$currentHead=Get-BareBranchSha $Git $Context.Remote $Context.Branch
  $issue=Get-StateIssue $state $Context.IssueNumber;$issue.labels=@('gm-approved',[pscustomobject]@{name='ready-for-codex'})
  $approval=[pscustomobject][ordered]@{id='approval-dirty';targetType='issue';number=$Context.IssueNumber;body="LIAISON_REWORK_APPROVED $currentHead";author=[pscustomobject]@{login='owner'};createdAt=([DateTime]$pr.createdAt).AddMinutes(20).ToUniversalTime().ToString('o');url='https://github.test/approval-dirty'}
  $state.comments=@($state.comments)+@($approval);$state.failures=@();$state.codexBehavior.mode='report-mismatch';$state.codexBehavior.file='allowed.txt';Save-State $Context.StatePath $state
  Set-FixtureEnvironment $Context.Gh $Context.StatePath $Context.LogPath $Git $Context.Remote.Repo
  $run=Invoke-Relay 'Once' $Context.ConfigPath $Context.Remote.Repo;Assert-Equal $run.ExitCode 60 "dirty rework failure exit: $($run.Output-join ' | ')"
  $state=Read-State $Context.StatePath;Assert-FailureState $state $Context.IssueNumber
  $branch=((Invoke-RealGit $Git $Context.Remote.Repo @('branch','--show-current'))-join '').Trim();Assert-Equal $branch $Context.Branch 'dirty rework branch was not preserved after checkout failure'
  $status=((Invoke-RealGit $Git $Context.Remote.Repo @('status','--porcelain=v1','--untracked-files=all'))-join "`n").Trim();Assert-Match $status 'allowed\.txt' 'dirty rework file was not preserved'
  $diagnosisFiles=@(Get-ChildItem -LiteralPath (Join-Path $Context.Remote.Repo 'tools\liaison-officer\.runtime\logs') -Filter 'failure-diagnosis.json' -File -Recurse|Sort-Object LastWriteTimeUtc)
  Assert ($diagnosisFiles.Count-gt0) 'dirty rework diagnosis file missing'
  $diagnosis=[IO.File]::ReadAllText($diagnosisFiles[-1].FullName,[Text.Encoding]::UTF8)|ConvertFrom-Json
  Assert-Match $diagnosis.cleanup.branchReturn '^failed; preserved worktree:' 'dirty rework checkout failure was not recorded'
  Assert ('allowed.txt'-in@($diagnosis.actualChangedFiles)) 'dirty rework actual path was not diagnosed'
  Assert ('other.txt'-in@($diagnosis.reportedChangedFiles)) 'dirty rework reported path was not diagnosed'
  Assert-Equal $diagnosis.diffCheck 'passed' 'dirty rework diff check diagnosis'
  Assert ($diagnosis.lock.acquired-and$diagnosis.lock.released) 'dirty rework lock lifecycle was not diagnosed'
  Assert (-not(Test-Path -LiteralPath (Join-Path $Context.Remote.Repo 'tools\liaison-officer\.runtime\state\liaison.lock'))) 'dirty rework retained local lock'
  Write-Host 'Invoke-Once failure E2E passed: dirty approved rework preserved its branch and diff while labels, comment, and automatic diagnosis continued.'
  return [pscustomobject]@{Name='dirty rework checkout failure';ExitCode=$run.ExitCode;Clean=$false;RemoteBranch=$true;GhCalls=@($state.ghCalls).Count;CodexCalls=@($state.codexCalls).Count}
}

$temp=Join-Path $env:TEMP ('liaison-entry-e2e-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp|Out-Null
$completed=$false
try {
  $path=Join-Path $temp 'normalization-state.json';$state=New-TestState;Save-State $path $state;$read=Read-State $path;Assert (@(Get-StateArray $read 'prs').Count-eq0) 'zero PR normalization failed'
  $read.prs=@([pscustomobject]@{number=1;state='open'});$read.comments=@([pscustomobject]@{id='c1'});Save-State $path $read;$read=Read-State $path;Assert (@(Get-StateArray $read 'prs').Count-eq1) 'single PR normalization failed';Assert (@(Get-StateArray $read 'comments').Count-eq1) 'single comment normalization failed'
  $read.prs=@([pscustomobject]@{number=1;state='open'},[pscustomobject]@{number=2;state='closed'});Save-State $path $read;$read=Read-State $path;$open=@((Get-StateArray $read 'prs')|Where-Object{$_.state-eq'open'});Assert ($open.Count-eq1) 'filtered PR normalization failed'

  $gitCommand=Get-Command git -ErrorAction SilentlyContinue;$git=if($gitCommand){$gitCommand.Source}else{'C:\Users\User\AppData\Local\GitHubDesktop\app-3.6.2\resources\app\git\mingw64\bin\git.exe'}
  if(-not(Test-Path -LiteralPath $git)){throw 'real git.exe is unavailable'};$git=(Resolve-Path -LiteralPath $git).Path
  $gitBin=Split-Path -Parent $git;$gitRoot=Split-Path -Parent $gitBin;$gitBase=Split-Path -Parent $gitRoot
  if(Test-Path -LiteralPath (Join-Path $gitBin 'git-receive-pack.exe')){$env:GIT_EXEC_PATH=$gitBin;$env:PATH=(Join-Path $gitBase 'cmd')+';'+$gitBin+';'+(Join-Path $gitBase 'usr\bin')+';'+$env:PATH}
  foreach($scriptPath in @($relay,$fakeGhLauncher,$fakeGhImplementation,$fakeCodexImplementation)){$tokens=$null;$errors=$null;[void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors);Assert-Equal @($errors).Count 0 "PowerShell 5.1 parser rejected $scriptPath"}
  $codex=New-FakeCodex $temp

  $contractDirectory=Join-Path $temp 'contracts';New-Item -ItemType Directory -Force -Path $contractDirectory|Out-Null;$contractGh=New-FakeGh $contractDirectory
  $contractResult=Test-FakeGhContracts $contractDirectory $contractGh

  $dryRunResults=Test-DryRunMatrix (Join-Path $temp 'dryrun') $git $codex
  $successContext=Test-InitialAndReworkSuccess (Join-Path $temp 'success') $git $codex

  $failureResults=@()
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-codex-exit') -Git $git -Codex $codex -Name 'Codex nonzero exit' -CodexMode 'nonzero' -ExpectedCode 50 -ExpectedClean $true -ExpectedRemoteBranch $false -ExpectedCodexCalls 1)
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-codex-timeout') -Git $git -Codex $codex -Name 'Codex timeout' -CodexMode 'timeout' -ExpectedCode 50 -ExpectedClean $true -ExpectedRemoteBranch $false -ExpectedCodexCalls 1)
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-validation') -Git $git -Codex $codex -Name 'validation failure' -CodexMode 'validation-failure' -ExpectedCode 60 -ExpectedClean $false -ExpectedRemoteBranch $false -ExpectedCodexCalls 1)
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-commit') -Git $git -Codex $codex -Name 'commit failure' -CodexMode 'success' -ExpectedCode 70 -GitFailureCommand 'commit' -ExpectedClean $false -ExpectedRemoteBranch $false -ExpectedCodexCalls 1)
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-push') -Git $git -Codex $codex -Name 'push failure' -CodexMode 'success' -ExpectedCode 70 -GitFailureCommand 'push' -ExpectedClean $true -ExpectedRemoteBranch $false -ExpectedCodexCalls 1)
  $prCreateFailure=[pscustomobject][ordered]@{command='pr create';mode='fail';remaining=1;exitCode=92;stderr='Injected PR creation failure'}
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-pr-create') -Git $git -Codex $codex -Name 'PR creation failure' -CodexMode 'success' -ExpectedCode 70 -GhFailure $prCreateFailure -ExpectedClean $true -ExpectedRemoteBranch $true -ExpectedCodexCalls 1)
  $labelFailure=[pscustomobject][ordered]@{command='issue edit';argvContains='--remove-label ready-for-codex';mode='no-op';remaining=1;exitCode=0;stderr=''}
  $failureResults+=@(Test-InitialFailure -Directory (Join-Path $temp 'failure-label-confirmation') -Git $git -Codex $codex -Name 'label transition confirmation failure' -CodexMode 'success' -ExpectedCode 70 -GhFailure $labelFailure -ExpectedClean $true -ExpectedRemoteBranch $false -ExpectedCodexCalls 0)
  $failureResults+=@(Test-ReworkPrCommentFailure $successContext $git)
  $failureResults+=@(Test-ReworkDirtyCheckoutFailure $successContext $git)

  $summary=[pscustomobject][ordered]@{
    contractInventoryRows=$contractResult.Contracts;directGhCalls=$contractResult.Calls;dryRunCases=@($dryRunResults).Count
    initialSuccess=$true;reworkSuccess=$true;failureCases=@($failureResults).Count
    failures=@($failureResults|ForEach-Object{"$($_.Name):$($_.ExitCode)"});powerShell51Parser='pass';realGit=$git;temporaryRemoteOnly=$true
  }
  Write-Output ('relay entry-point E2E passed: '+($summary|ConvertTo-Json -Compress -Depth 6))
  $completed=$true
} finally {
  Remove-Item Env:\FAKE_GH_STATE,Env:\FAKE_GH_LOG,Env:\FAKE_GH_EXECUTABLE,Env:\FAKE_GH_REAL_GIT,Env:\FAKE_GH_REPO,Env:\FAKE_CODEX_STATE,Env:\FAKE_CODEX_REPO,Env:\FAKE_GIT_REAL,Env:\FAKE_GIT_FAIL_COMMAND,Env:\FAKE_GIT_LOG -ErrorAction SilentlyContinue
  if($completed){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}else{Write-Output "ENTRYPOINT_E2E_ARTIFACTS_PRESERVED=$temp"}
}
