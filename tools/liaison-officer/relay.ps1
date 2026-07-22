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
$script:ActiveRunDirectory = $null
$script:ActualChangedPaths = @()
$script:ReportedChangedPaths = @()
$script:LockAcquired = $false
$script:LockReleased = $false

function Write-Result([string]$Message) { Write-Output "[$RunId] $Message" }
function Stop-WithCode([int]$Code, [string]$Message) { Write-Error "[$RunId] $Message" -ErrorAction Continue; exit $Code }
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
function Convert-ProcessTextToLines([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return @() }
  $trimmed = $Text.TrimEnd([char[]]"`r`n")
  if ([string]::IsNullOrEmpty($trimmed)) { return @() }
  return @($trimmed -split "`r?`n")
}
function Get-ToolCombinedLines($Result) {
  return @(@($Result.Stdout) + @($Result.Stderr))
}
function Get-ToolFailureText($Result) {
  return ((Get-ToolCombinedLines $Result) -join [Environment]::NewLine).Trim()
}
function Write-NativeStderrLog([string]$FileName, [string[]]$Arguments, [string[]]$Stderr) {
  $lines = @($Stderr | Where-Object { -not [string]::IsNullOrEmpty([string]$_) })
  if ($lines.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$script:ActiveRunDirectory)) { return }
  try {
    New-Item -ItemType Directory -Force -Path $script:ActiveRunDirectory | Out-Null
    $commandName = [IO.Path]::GetFileName($FileName)
    $commandArguments = @($Arguments | Select-Object -First 3) -join ' '
    $header = '[{0}] {1} {2}' -f ([DateTime]::UtcNow.ToString('o')), $commandName, $commandArguments
    $content = (@($header) + $lines + @('')) -join [Environment]::NewLine
    [IO.File]::AppendAllText((Join-Path $script:ActiveRunDirectory 'native.stderr.log'), $content, [Text.UTF8Encoding]::new($false))
  } catch {
    Write-Warning "Native stderr could not be logged: $($_.Exception.Message)"
  }
}
function Invoke-Tool([string]$FileName, [string[]]$Arguments, [string]$WorkingDirectory) {
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $argumentList = @($Arguments)
  $extension = ([IO.Path]::GetExtension($FileName)).ToLowerInvariant()
  if ($extension -in @('.cmd', '.bat')) {
    $command = Quote-ProcessArgument ([string]$FileName)
    if ($argumentList.Count -gt 0) { $command += ' ' + (($argumentList | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ') }
    $info.FileName = $env:ComSpec
    $info.Arguments = '/d /s /c "' + $command + '"'
  } elseif ($extension -eq '.ps1') {
    $powerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $scriptArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FileName) + $argumentList
    $info.FileName = $powerShell
    $info.Arguments = (($scriptArguments | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
  } else {
    $info.FileName = $FileName
    $info.Arguments = (($argumentList | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
  }
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $info.WorkingDirectory = $WorkingDirectory
  $info.UseShellExecute = $false
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $info.StandardOutputEncoding = $utf8
  $info.StandardErrorEncoding = $utf8
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $info
  try {
    if (-not $process.Start()) { throw "Process did not start: $FileName" }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $stdout = @(Convert-ProcessTextToLines ($stdoutTask.GetAwaiter().GetResult()))
    $stderr = @(Convert-ProcessTextToLines ($stderrTask.GetAwaiter().GetResult()))
    Write-NativeStderrLog $FileName $argumentList $stderr
    return [pscustomobject]@{
      ExitCode = $process.ExitCode
      Stdout = @($stdout)
      Stderr = @($stderr)
      # Output remains a stdout-only compatibility alias.  Callers that need
      # diagnostics must opt into Stderr or Get-ToolCombinedLines explicitly.
      Output = @($stdout)
    }
  } finally {
    $process.Dispose()
  }
}
function Get-GitValue($Config, [string[]]$Arguments) {
  $result = Invoke-Tool $Config.GitPath $Arguments $Config.RepoPath
  if ($result.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $(Get-ToolFailureText $result)" }
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
  $expectedOrigin = "https://github.com/$($Config.repository)"
  if ($Config.PSObject.Properties.Name -contains 'expectedOrigin' -and $Config.expectedOrigin) {
    $expectedOrigin = ([string]$Config.expectedOrigin) -replace '\\','/' -replace '\.git$','' -replace '^git@github\.com:','https://github.com/'
  }
  if ($normalizedOrigin -ne $expectedOrigin) { throw "origin does not exactly match configured repository: $origin" }
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
    $script:LockAcquired = $true
    $script:LockReleased = $false
  } catch { throw "Local lock could not be acquired: $($_.Exception.Message)" }
}
function Release-LocalLock($Config) {
  if ($script:LockHandle) { $script:LockHandle.Dispose(); $script:LockHandle = $null }
  $lockPath = Join-Path $Config.StatePath 'liaison.lock'
  if (Test-Path -LiteralPath $lockPath) { Remove-Item -LiteralPath $lockPath -Force }
  if ($script:LockAcquired) { $script:LockReleased = $true }
}
function Save-IssueSnapshot($Config, $Issue, [string]$RunDirectory) {
  $detail = Invoke-Tool $Config.GhPath @('issue','view',[string]$Issue.number,'--repo',$Config.repository,'--json','number,title,body,url,labels,createdAt,updatedAt,comments') $Config.RepoPath
  if ($detail.ExitCode -ne 0) { throw "Issue snapshot failed: $($detail.Output -join ' ')" }
  $item = (($detail.Output -join "`n") | ConvertFrom-Json)
  $lines = @("# Issue #$($item.number): $($item.title)", '', "URL: $($item.url)", "Created: $($item.createdAt)", "Updated: $($item.updatedAt)", "Labels: $((@($item.labels | ForEach-Object { $_.name }) -join ', '))", '', '## Body', $item.body, '', '## Comments')
  foreach ($comment in @($item.comments | Sort-Object createdAt)) { $lines += @('', "### $($comment.author.login) - $($comment.createdAt)", $comment.body) }
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
  } catch {
    try {
      if (-not ('LiaisonOfficer.ProcessSnapshot' -as [type])) {
        [void](Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace LiaisonOfficer {
  public static class ProcessSnapshot {
    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct PROCESSENTRY32 {
      public uint dwSize;
      public uint cntUsage;
      public uint th32ProcessID;
      public IntPtr th32DefaultHeapID;
      public uint th32ModuleID;
      public uint cntThreads;
      public uint th32ParentProcessID;
      public int pcPriClassBase;
      public uint dwFlags;
      [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)] private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
    public static Dictionary<int,int> GetParentMap() {
      var result = new Dictionary<int,int>();
      IntPtr snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
      if (snapshot == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
      try {
        var entry = new PROCESSENTRY32();
        entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
        if (Process32First(snapshot, ref entry)) {
          do { result[(int)entry.th32ProcessID] = (int)entry.th32ParentProcessID; } while (Process32Next(snapshot, ref entry));
        }
      } finally { CloseHandle(snapshot); }
      return result;
    }
  }
}
'@)
      }
      $parentMap = [LiaisonOfficer.ProcessSnapshot]::GetParentMap()
      $ids.Clear(); $pending.Clear(); $ids.Add($RootProcessId); $pending.Enqueue($RootProcessId)
      while ($pending.Count -gt 0) {
        $parentId = [int]$pending.Dequeue()
        foreach ($entry in $parentMap.GetEnumerator()) {
          if ([int]$entry.Value -eq $parentId) { $childId = [int]$entry.Key; if (-not $ids.Contains($childId)) { $ids.Add($childId); $pending.Enqueue($childId) } }
        }
      }
    } catch { Write-Warning "Process-tree child discovery was unavailable: $($_.Exception.Message)" }
  }
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
  $utf8 = New-Object System.Text.UTF8Encoding($false)
  $info = New-Object System.Diagnostics.ProcessStartInfo
  $info.FileName = $Config.CodexPath
  $info.Arguments = (($args | ForEach-Object { Quote-ProcessArgument ([string]$_) }) -join ' ')
  $info.WorkingDirectory = $Config.RepoPath
  $info.UseShellExecute = $false
  $info.RedirectStandardInput = $true
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.CreateNoWindow = $true
  $info.StandardOutputEncoding = $utf8
  $info.StandardErrorEncoding = $utf8
  $process = New-Object System.Diagnostics.Process; $process.StartInfo = $info
  if (-not $process.Start()) { throw 'Codex process did not start.' }
  $inputBytes = $utf8.GetBytes($prompt)
  $process.StandardInput.BaseStream.Write($inputBytes, 0, $inputBytes.Length)
  $process.StandardInput.BaseStream.Flush()
  $process.StandardInput.Close()
  $outTask = $process.StandardOutput.ReadToEndAsync()
  $errTask = $process.StandardError.ReadToEndAsync()
  Start-Sleep -Milliseconds 50
  $treeIds = @(Get-ProcessTreeIds $process.Id)
  $timeoutMilliseconds = [int]([double]$Config.timeoutMinutes * 60000)
  $timedOut = -not $process.WaitForExit($timeoutMilliseconds)
  $killPath = Join-Path $RunDirectory 'taskkill.log'
  $killExitCode = $null
  $fallbackKill = @()
  if ($timedOut) {
    $script:CurrentStage='codex-timeout'
    $treeIds = @($treeIds + @(Get-ProcessTreeIds $process.Id) | Sort-Object -Unique)
    $previousErrorActionPreference = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $kill = & cmd.exe /d /c "taskkill.exe /PID $($process.Id) /T /F" 2>&1; $killExitCode = $LASTEXITCODE } finally { $ErrorActionPreference = $previousErrorActionPreference }
    if ($killExitCode -ne 0) {
      foreach ($processId in @($treeIds | Sort-Object -Descending)) {
        try { if (Get-Process -Id $processId -ErrorAction SilentlyContinue) { Stop-Process -Id $processId -Force -ErrorAction Stop; $fallbackKill += "Stop-Process terminated PID $processId" } } catch { $fallbackKill += "Stop-Process failed for PID $processId`: $($_.Exception.Message)" }
      }
    }
    $killLogLines = @($kill) + @($fallbackKill)
    [IO.File]::WriteAllText($killPath, ($killLogLines -join [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    [void]$process.WaitForExit(5000)
  }
  $remaining = @(); if($timedOut){$remaining=@(Get-RemainingProcessIds $treeIds)}
  if($timedOut -and (-not $process.HasExited -or $remaining.Count -gt 0)){
    [IO.File]::WriteAllText($stdoutPath,'[stdout unavailable: timed-out process did not close its stream]',[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($stderrPath,'[stderr unavailable: timed-out process did not close its stream]',[Text.UTF8Encoding]::new($false))
    throw "Codex timeout; taskkill exit=$killExitCode and process IDs $($remaining -join ', ') remained after the bounded fallback. Logs were saved."
  }
  $stdout = $outTask.GetAwaiter().GetResult(); $stderr = $errTask.GetAwaiter().GetResult(); [IO.File]::WriteAllText($stdoutPath,$stdout,[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText($stderrPath,$stderr,[Text.UTF8Encoding]::new($false))
  if($timedOut){
    if(-not $process.HasExited -or $remaining.Count -gt 0){throw "Codex timeout; remaining process IDs: $($remaining -join ', '). stdout, stderr, and taskkill logs were saved."}
    $fallbackNote=if($fallbackKill.Count){" taskkill exit=$killExitCode; PowerShell fallback was recorded."}else{''}
    throw "Codex timed out after $($Config.timeoutMinutes) minutes; process tree IDs $($treeIds -join ', ') terminated and logs were saved.$fallbackNote"
  }
  return [pscustomobject]@{ ExitCode = $process.ExitCode; StdoutPath = $stdoutPath; StderrPath = $stderrPath; Stdout = $stdout; ProcessIds = $treeIds }
}
function Get-ChangedPaths($Config) {
  $paths = @()
  foreach ($arguments in @(@('diff','--name-only'), @('diff','--cached','--name-only'), @('ls-files','--others','--exclude-standard'))) {
    $result = Invoke-Tool $Config.GitPath $arguments $Config.RepoPath
    if ($result.ExitCode -ne 0) { throw "git $($arguments -join ' ') failed while listing changes." }
    # Only stdout is path data.  Git warnings (including LF/CRLF conversion)
    # are retained in result.Stderr and native.stderr.log, never in this set.
    $paths += @($result.Stdout | Where-Object { $_ } | ForEach-Object { Normalize-PathValue $_ })
  }
  $script:ActualChangedPaths = @($paths | Sort-Object -Unique)
  return @($script:ActualChangedPaths)
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
  $script:ReportedChangedPaths = @($reported)
  $script:ActualChangedPaths = @($actual)
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
function Get-SafeFailureMessage([string]$Message) {
  return ($Message -replace 'C:\\Users\\[^\\\s]+','[local-path]' -replace '(gho|github_pat)_[A-Za-z0-9_\-]+','[redacted]')
}
function Ensure-FailureRunDirectory($Config) {
  if ([string]::IsNullOrWhiteSpace([string]$script:ActiveRunDirectory)) {
    $script:ActiveRunDirectory = Join-Path $Config.LogPath $RunId
  }
  New-Item -ItemType Directory -Force -Path $script:ActiveRunDirectory | Out-Null
  return $script:ActiveRunDirectory
}
function Get-FailureSnapshot($Config, [string]$Message) {
  [void](Ensure-FailureRunDirectory $Config)
  $branch = '[unavailable]'
  $head = '[unavailable]'
  $status = @()
  $actual = @($script:ActualChangedPaths)
  $diffCheck = 'unavailable'
  $diffCheckStderr = @()
  try { $branch = Get-GitValue $Config @('branch','--show-current') } catch {}
  try { $head = Get-GitValue $Config @('rev-parse','HEAD') } catch {}
  try {
    $statusResult = Invoke-Tool $Config.GitPath @('status','--porcelain=v1','--untracked-files=all') $Config.RepoPath
    if ($statusResult.ExitCode -eq 0) { $status = @($statusResult.Stdout) }
  } catch {}
  try { $actual = @(Get-ChangedPaths $Config) } catch {}
  try {
    $check = Invoke-Tool $Config.GitPath @('diff','--check') $Config.RepoPath
    $diffCheckStderr = @($check.Stderr)
    $diffCheck = if ($check.ExitCode -eq 0) { 'passed' } else { "failed (exit $($check.ExitCode))" }
  } catch { $diffCheck = "unavailable: $($_.Exception.Message)" }
  $lockPath = Join-Path $Config.StatePath 'liaison.lock'
  return [pscustomobject][ordered]@{
    runId = $RunId
    issue = [int]$script:SelectedIssue.number
    stage = $script:CurrentStage
    message = (Get-SafeFailureMessage $Message)
    branch = $branch
    head = $head
    gitStatus = @($status)
    actualChangedFiles = @($actual)
    reportedChangedFiles = @($script:ReportedChangedPaths)
    diffCheck = $diffCheck
    diffCheckStderr = @($diffCheckStderr)
    lock = [pscustomobject][ordered]@{
      present = [bool](Test-Path -LiteralPath $lockPath)
      acquired = [bool]$script:LockAcquired
      released = [bool]$script:LockReleased
    }
    cleanup = [pscustomobject][ordered]@{
      branchReturn = 'not-attempted'
      labels = 'not-attempted'
      labelErrors = @()
      comment = 'not-attempted'
    }
  }
}
function Write-FailureDiagnosis($Config, $Diagnosis) {
  $directory = Ensure-FailureRunDirectory $Config
  $json = $Diagnosis | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText((Join-Path $directory 'failure-diagnosis.json'), $json, [Text.UTF8Encoding]::new($false))
  $lines = @(
    'LIAISON_FAILURE_DIAGNOSIS_BEGIN',
    "runId: $($Diagnosis.runId)",
    "issue: $($Diagnosis.issue)",
    "stage: $($Diagnosis.stage)",
    "branch: $($Diagnosis.branch)",
    "head: $($Diagnosis.head)",
    "gitStatus: $(@($Diagnosis.gitStatus) -join ' | ')",
    "actualChangedFiles: $(@($Diagnosis.actualChangedFiles) -join ', ')",
    "reportedChangedFiles: $(@($Diagnosis.reportedChangedFiles) -join ', ')",
    "diffCheck: $($Diagnosis.diffCheck)",
    "lock: present=$($Diagnosis.lock.present); acquired=$($Diagnosis.lock.acquired); released=$($Diagnosis.lock.released)",
    "cleanup: branchReturn=$($Diagnosis.cleanup.branchReturn); labels=$($Diagnosis.cleanup.labels); comment=$($Diagnosis.cleanup.comment)",
    "diagnosisFile: $($Diagnosis.runId)/failure-diagnosis.json",
    'LIAISON_FAILURE_DIAGNOSIS_END'
  )
  $text = $lines -join [Environment]::NewLine
  [IO.File]::WriteAllText((Join-Path $directory 'failure-diagnosis.txt'), $text, [Text.UTF8Encoding]::new($false))
  Write-Output $text
}
function Invoke-FailureLabelCleanup($Config, [int]$IssueNumber) {
  $errors = @()
  foreach ($operation in @(
    [pscustomobject]@{ Action='--add-label'; Label='codex-failed' },
    [pscustomobject]@{ Action='--remove-label'; Label='codex-running' },
    [pscustomobject]@{ Action='--remove-label'; Label='ready-for-codex' },
    [pscustomobject]@{ Action='--remove-label'; Label='awaiting-gm-review' }
  )) {
    try {
      $result = Invoke-Tool $Config.GhPath @('issue','edit',[string]$IssueNumber,'--repo',$Config.repository,$operation.Action,$operation.Label) $Config.RepoPath
      if ($result.ExitCode -ne 0) { $errors += "$($operation.Action) $($operation.Label): $(Get-ToolFailureText $result)" }
    } catch { $errors += "$($operation.Action) $($operation.Label): $($_.Exception.Message)" }
  }
  try {
    $verify = Invoke-Tool $Config.GhPath @('issue','view',[string]$IssueNumber,'--repo',$Config.repository,'--json','labels') $Config.RepoPath
    if ($verify.ExitCode -ne 0) {
      $errors += "label verification: $(Get-ToolFailureText $verify)"
    } else {
      $names = @((($verify.Stdout -join "`n") | ConvertFrom-Json).labels | ForEach-Object { $_.name })
      if ('codex-failed' -notin $names) { $errors += 'codex-failed was not confirmed' }
      foreach ($label in @('codex-running','ready-for-codex','awaiting-gm-review')) {
        if ($label -in $names) { $errors += "$label remained after failure cleanup" }
      }
    }
  } catch { $errors += "label verification: $($_.Exception.Message)" }
  $status = if ($errors.Count -eq 0) { 'passed' } else { 'failed' }
  return [pscustomobject]@{ Status = $status; Errors = @($errors) }
}
function Complete-Failure($Config, [string]$Message) {
  if(-not $script:SelectedIssue){return}
  $diagnosis = Get-FailureSnapshot $Config $Message
  try {
    $currentBranch = $diagnosis.branch
    if ($currentBranch -and $currentBranch -ne $Config.baseBranch) {
      $returnBase = Invoke-Tool $Config.GitPath @('checkout',$Config.baseBranch) $Config.RepoPath
      if ($returnBase.ExitCode -ne 0) { throw "Could not return to $($Config.baseBranch): $(Get-ToolFailureText $returnBase)" }
      $diagnosis.cleanup.branchReturn = 'passed'
    } else {
      $diagnosis.cleanup.branchReturn = 'not-needed'
    }
  } catch {
    $diagnosis.cleanup.branchReturn = "failed; preserved worktree: $($_.Exception.Message)"
    Write-Error "[$RunId] failure branch cleanup also failed: $($_.Exception.Message)" -ErrorAction Continue
  }
  $labelResult = Invoke-FailureLabelCleanup $Config $script:SelectedIssue.number
  $diagnosis.cleanup.labels = $labelResult.Status
  $diagnosis.cleanup.labelErrors = @($labelResult.Errors)
  try {
    $diagnosis.cleanup.comment = 'attempting'
    $commentBody = @(
      "Liaison run $RunId failed at $script:CurrentStage.",
      (Get-SafeFailureMessage $Message),
      '',
      'Failure diagnosis was captured automatically; manual log relay is not required.',
      "Branch: $($diagnosis.branch)",
      "HEAD: $($diagnosis.head)",
      "Status: $(@($diagnosis.gitStatus) -join ' | ')",
      "Actual paths: $(@($diagnosis.actualChangedFiles) -join ', ')",
      "Reported paths: $(@($diagnosis.reportedChangedFiles) -join ', ')",
      "Diff check: $($diagnosis.diffCheck)",
      "Lock: present=$($diagnosis.lock.present); acquired=$($diagnosis.lock.acquired); released=$($diagnosis.lock.released)",
      "Cleanup: branchReturn=$($diagnosis.cleanup.branchReturn); labels=$($diagnosis.cleanup.labels)",
      "Local diagnosis: $RunId/failure-diagnosis.json",
      'Dirty changes were not reset, cleaned, stashed, or discarded. Human review is required.'
    ) -join "`n"
    $comment = Invoke-Tool $Config.GhPath @('issue','comment',[string]$script:SelectedIssue.number,'--repo',$Config.repository,'--body',$commentBody) $Config.RepoPath
    if($comment.ExitCode -ne 0){throw "Issue failure comment was rejected: $(Get-ToolFailureText $comment)"}
    $diagnosis.cleanup.comment = 'passed'
  } catch {
    $diagnosis.cleanup.comment = "failed: $($_.Exception.Message)"
    Write-Error "[$RunId] failure comment also failed: $($_.Exception.Message)" -ErrorAction Continue
  }
  try { Write-FailureDiagnosis $Config $diagnosis } catch { Write-Error "[$RunId] failure diagnosis could not be written: $($_.Exception.Message)" -ErrorAction Continue }
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
  try { $result = Invoke-Tool $Config.CodexPath @($Config.codexSubcommand,'-s','read-only','--ephemeral','-C',$temp,'Reply with LIAISON_SMOKE_OK only.') $temp; if($result.ExitCode -ne 0 -or ((Get-ToolCombinedLines $result) -join "`n") -notmatch 'LIAISON_SMOKE_OK'){throw 'Codex smoke test failed.'}; Write-Result 'Codex smoke test passed in an external temporary directory.' } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}
function Invoke-Once($Config) {
  $script:ActiveRunDirectory = $null; $script:ActualChangedPaths = @(); $script:ReportedChangedPaths = @(); $script:LockAcquired = $false; $script:LockReleased = $false
  $script:CurrentStage = 'preflight'
  $preflight = Test-RepositoryPreflight $Config; $missing = @(Test-RequiredLabels $Config); if ($missing.Count) { throw "Required labels are missing: $($missing -join ', ')" }
  $issues = @(Get-EligibleIssues $Config); if ($issues.Count -eq 0) { Write-Result 'No eligible Issue. No action taken.'; exit $ExitCode.NoEligibleIssue }
  $script:CurrentStage = 'selection'; $issue = $issues[0]; $script:SelectedIssue = $issue; $script:RunId = 'LO-{0}-Issue{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $issue.number; $branch = Get-BranchName $issue.number $issue.title
  $script:CurrentStage = 'lock'
  Acquire-LocalLock $Config $issue.number
  try {
    $script:ActiveRunDirectory = Join-Path $Config.LogPath $RunId; New-Item -ItemType Directory -Path $script:ActiveRunDirectory -Force | Out-Null
    $script:CurrentStage = 'branch'; $openResult=Invoke-Tool $Config.GhPath @('pr','list','--repo',$Config.repository,'--state','open','--json','number,headRefName,headRefOid,body,createdAt') $Config.RepoPath; if($openResult.ExitCode -ne 0){throw 'Open PR lookup failed.'}; $open=@((($openResult.Output -join "`n")|ConvertFrom-Json)); $issuePattern='(?<![0-9])#'+[regex]::Escape([string]$issue.number)+'(?![0-9])'; $issuePr=@($open|Where-Object{$_.body -match $issuePattern}); $headPr=@($open|Where-Object{$_.headRefName -eq $branch}); $localRef=Invoke-Tool $Config.GitPath @('show-ref','--verify','--quiet',"refs/heads/$branch") $Config.RepoPath; $remoteRef=Invoke-Tool $Config.GitPath @('show-ref','--verify','--quiet',"refs/remotes/origin/$branch") $Config.RepoPath
    $isRework=$false; $reworkApproval=$null; if($issuePr.Count -eq 1 -and $headPr.Count -eq 1 -and $issuePr[0].number -eq $headPr[0].number -and $issuePr[0].body -match 'Liaison run ID:' -and $localRef.ExitCode -eq 0 -and $remoteRef.ExitCode -eq 0){$localTip=Get-GitValue $Config @('rev-parse',$branch); $remoteTip=Get-GitValue $Config @('rev-parse',"origin/$branch"); if($localTip -ne $remoteTip -or $localTip -ne $issuePr[0].headRefOid){throw 'Rework branch, remote branch, and PR head SHA do not match.'}; $issueDetail=Invoke-Tool $Config.GhPath @('issue','view',[string]$issue.number,'--repo',$Config.repository,'--json','comments,labels') $Config.RepoPath; if($issueDetail.ExitCode -ne 0){throw 'Rework approval comments could not be read.'}; $issueState=(($issueDetail.Output -join "`n")|ConvertFrom-Json); $labelNames=@($issueState.labels|ForEach-Object{$_.name}); $approvalPattern='LIAISON_REWORK_APPROVED'; $reworkApproval=@($issueState.comments|Where-Object{$_.body -match $approvalPattern -and $_.body -match [regex]::Escape($issuePr[0].headRefOid) -and ([DateTime]$_.createdAt) -gt ([DateTime]$issuePr[0].createdAt)}|Sort-Object createdAt|Select-Object -Last 1); $prHistory=Invoke-Tool $Config.GhPath @('pr','view',[string]$issuePr[0].number,'--repo',$Config.repository,'--json','comments') $Config.RepoPath; if($prHistory.ExitCode -ne 0){throw 'Rework history could not be read.'}; $usedApprovalIds=@(((($prHistory.Output -join "`n")|ConvertFrom-Json).comments|ForEach-Object{if($_.body -match 'Approval comment:\s*(\S+)'){$Matches[1]}})); if('gm-approved' -notin $labelNames -or 'ready-for-codex' -notin $labelNames -or -not $reworkApproval -or $reworkApproval[0].id -in $usedApprovalIds){throw 'Rework requires fresh labels and an unused later LIAISON_REWORK_APPROVED comment naming the current existing head SHA.'}; $isRework=$true}
    if(-not $isRework -and ($localRef.ExitCode -eq 0 -or $remoteRef.ExitCode -eq 0 -or $headPr.Count -gt 0 -or $issuePr.Count -gt 0)){throw 'Initial execution is blocked by an existing local branch, remote branch, matching-head PR, or Issue-referencing Open PR.'}
    $script:CurrentStage = 'github-state'; Set-IssueLabels $Config $issue.number @('codex-running') @(); $confirmed = Invoke-Tool $Config.GhPath @('issue','view',[string]$issue.number,'--repo',$Config.repository,'--json','labels') $Config.RepoPath
    if ($confirmed.ExitCode -ne 0 -or 'codex-running' -notin @((($confirmed.Output -join "`n") | ConvertFrom-Json).labels | ForEach-Object { $_.name })) { throw 'codex-running label was not confirmed.' }
    Set-IssueLabels $Config $issue.number @() @('ready-for-codex')
    $script:CurrentStage = 'issue-snapshot'; $runDirectory = $script:ActiveRunDirectory
    $snapshot = Save-IssueSnapshot $Config $issue $runDirectory
    $script:CurrentStage = 'branch'; $createArgs=if($isRework){@('checkout',$branch)}else{@('checkout','-b',$branch,"origin/$($Config.baseBranch)")}; $create = Invoke-Tool $Config.GitPath $createArgs $Config.RepoPath; if ($create.ExitCode -ne 0) { throw "Branch preparation failed: $(Get-ToolFailureText $create)" }
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
