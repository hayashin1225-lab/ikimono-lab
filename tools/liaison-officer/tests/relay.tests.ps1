[CmdletBinding()]
param([string]$Root)

if([string]::IsNullOrWhiteSpace($Root)) { $Root = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..\..')).Path }

$ErrorActionPreference = 'Stop'
$relay = Join-Path $Root 'tools\liaison-officer\relay.ps1'
$config = Join-Path $Root 'tools\liaison-officer\config.example.json'
$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($relay,[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | ForEach-Object Message -join '; ')}
Get-Content -Raw -Encoding UTF8 $config | ConvertFrom-Json | Out-Null
$source = Get-Content -Raw -Encoding UTF8 $relay
foreach($required in @('FileShare]::None','taskkill.exe','LIAISON_REPORT_BEGIN','git diff --check','Get-ChangedPaths','codex-running','codex-failed','awaiting-gm-review','Invoke-CodexSmokeTest')) { if($source -notmatch [regex]::Escape($required)){throw "Missing runtime safeguard: $required"} }
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
if(-not $git){$git='C:\Users\User\AppData\Local\GitHubDesktop\app-3.6.2\resources\app\git\mingw64\bin\git.exe'}
$ignored = & $git -C $Root check-ignore --no-index tools/liaison-officer/config.local.json tools/liaison-officer/.runtime/logs/test.log tools/liaison-officer/.runtime/state/test.lock tools/liaison-officer/.runtime/temp/prompt.txt
if($LASTEXITCODE -ne 0){throw 'Runtime outputs are not ignored.'}
$changed = & $git -C $Root diff --name-only; if($changed -contains 'index.html' -or $changed -contains 'README.md' -or ($changed | Where-Object {$_ -like '.github/workflows/*'})){throw 'Protected application path changed.'}
Write-Output 'relay tests passed: syntax, JSON, runtime ignore, protected-path safeguards, report validation markers.'
