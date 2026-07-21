[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$CliArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_GH_ARGV_JSON)) {
  try {
    $decodedArguments = $env:FAKE_GH_ARGV_JSON | ConvertFrom-Json
    $CliArguments = @($decodedArguments | ForEach-Object { [string]$_ })
  } catch {
    [Console]::Error.WriteLine("FAKE_GH_ARGV_JSON is invalid: $($_.Exception.Message)")
    exit 78
  }
}

$collectionNames = @(
  'issues',
  'prs',
  'comments',
  'labels',
  'reviews',
  'ghCalls',
  'codexCalls',
  'commits',
  'branches',
  'failures'
)

function Write-Stderr([string]$Message) {
  [Console]::Error.WriteLine($Message)
}

function Stop-BeforeState([int]$ExitCode, [string]$Message) {
  Write-Stderr $Message
  exit $ExitCode
}

function Convert-ToArray($Value) {
  if ($null -eq $Value) { return @() }
  return @($Value)
}

function Get-PropertyValue($Object, [string]$Name, $Default = $null) {
  if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
    return $Object.$Name
  }
  return $Default
}

function Set-PropertyValue($Object, [string]$Name, $Value) {
  if ($Object.PSObject.Properties.Name -contains $Name) {
    $Object.$Name = $Value
  } else {
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
  }
}

function Convert-ToLabel($Value) {
  if ($Value -is [string]) {
    return [pscustomobject][ordered]@{ name = [string]$Value }
  }
  $name = [string](Get-PropertyValue $Value 'name' '')
  if ([string]::IsNullOrWhiteSpace($name)) { throw 'A label entry is missing name.' }
  return [pscustomobject][ordered]@{ name = $name }
}

function Normalize-State($State) {
  foreach ($name in $collectionNames) {
    if ($State.PSObject.Properties.Name -notcontains $name) {
      $State | Add-Member -NotePropertyName $name -NotePropertyValue @()
    }
    $State.$name = @(Convert-ToArray $State.$name)
  }

  $normalizedLabels = @()
  foreach ($label in @($State.labels)) { $normalizedLabels += @(Convert-ToLabel $label) }
  $State.labels = @($normalizedLabels)

  foreach ($issue in @($State.issues)) {
    if ($issue.PSObject.Properties.Name -notcontains 'labels') { $issue | Add-Member -NotePropertyName labels -NotePropertyValue @() }
    $issueLabels = @()
    foreach ($label in @(Convert-ToArray $issue.labels)) { $issueLabels += @(Convert-ToLabel $label) }
    $issue.labels = @($issueLabels)
    if ($issue.PSObject.Properties.Name -notcontains 'comments') { $issue | Add-Member -NotePropertyName comments -NotePropertyValue @() }
    $issue.comments = @(Convert-ToArray $issue.comments)
  }

  foreach ($pr in @($State.prs)) {
    if ($pr.PSObject.Properties.Name -notcontains 'comments') { $pr | Add-Member -NotePropertyName comments -NotePropertyValue @() }
    $pr.comments = @(Convert-ToArray $pr.comments)
  }

  if ($State.PSObject.Properties.Name -notcontains 'authenticatedUser') {
    $State | Add-Member -NotePropertyName authenticatedUser -NotePropertyValue ([pscustomobject]@{ login = 'owner' })
  }
  if ($State.PSObject.Properties.Name -notcontains 'currentRepo') {
    $State | Add-Member -NotePropertyName currentRepo -NotePropertyValue 'owner/repo'
  }
  if ($State.PSObject.Properties.Name -notcontains 'repository') {
    $State | Add-Member -NotePropertyName repository -NotePropertyValue ([pscustomobject]@{ nameWithOwner = [string]$State.currentRepo })
  }
  return $State
}

function Read-StateFile([string]$Path) {
  try {
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    $parsed = $raw | ConvertFrom-Json
  } catch {
    throw "Fake gh state JSON could not be read: $($_.Exception.Message)"
  }
  return (Normalize-State $parsed)
}

function Save-StateFile([string]$Path, $State) {
  [void](Normalize-State $State)
  $directory = Split-Path -Parent $Path
  $temporaryPath = Join-Path $directory ('.fake-gh-state-' + [Guid]::NewGuid().ToString('N') + '.tmp')
  try {
    $json = ConvertTo-Json -InputObject $State -Depth 50
    [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    $verified = Read-StateFile $Path
    foreach ($name in $collectionNames) { [void]@(Convert-ToArray $verified.$name) }
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
  }
}

function Copy-StateValue($Value) {
  if ($null -eq $Value) { return $null }
  return ((ConvertTo-Json -InputObject $Value -Depth 40) | ConvertFrom-Json)
}

function Get-StateSnapshot($State) {
  return [pscustomobject][ordered]@{
    labels = @(Copy-StateValue @($State.labels))
    issues = @(Copy-StateValue @($State.issues))
    prs = @(Copy-StateValue @($State.prs))
    comments = @(Copy-StateValue @($State.comments))
    reviews = @(Copy-StateValue @($State.reviews))
    commits = @(Copy-StateValue @($State.commits))
    branches = @(Copy-StateValue @($State.branches))
    failures = @(Copy-StateValue @($State.failures))
    ghCallCount = @($State.ghCalls).Count
    codexCallCount = @($State.codexCalls).Count
  }
}

function Get-Option([string]$Name, [bool]$Required = $false) {
  for ($index = 0; $index -lt $CliArguments.Count; $index++) {
    if ($CliArguments[$index] -eq $Name) {
      if ($index + 1 -ge $CliArguments.Count) { throw "Option $Name requires a value." }
      return [string]$CliArguments[$index + 1]
    }
  }
  if ($Required) { throw "Required option is missing: $Name" }
  return $null
}

function Get-JsonFields {
  $value = Get-Option '--json' $true
  return @($value -split ',' | Where-Object { $_ })
}

function Get-CommandName {
  if ($CliArguments.Count -eq 0) { return '' }
  if ($CliArguments.Count -eq 1) { return [string]$CliArguments[0] }
  return ([string]$CliArguments[0] + ' ' + [string]$CliArguments[1])
}

function Test-RepositoryOption {
  $repo = Get-Option '--repo' $true
  if ($repo -ne [string]$state.currentRepo) { throw "Unexpected repository: $repo" }
}

function Get-Issue([int]$Number) {
  $matches = @($state.issues | Where-Object { [int]$_.number -eq $Number })
  if ($matches.Count -ne 1) { throw "Issue #$Number was not found uniquely." }
  return $matches[0]
}

function Get-Pr([int]$Number) {
  $matches = @($state.prs | Where-Object { [int]$_.number -eq $Number })
  if ($matches.Count -ne 1) { throw "PR #$Number was not found uniquely." }
  return $matches[0]
}

function Get-TargetComments([string]$TargetType, [int]$Number, $Embedded) {
  $result = @()
  foreach ($comment in @(Convert-ToArray $Embedded)) { $result += @($comment) }
  foreach ($comment in @($state.comments)) {
    if ([string](Get-PropertyValue $comment 'targetType' '') -eq $TargetType -and [int](Get-PropertyValue $comment 'number' -1) -eq $Number) {
      $id = [string](Get-PropertyValue $comment 'id' '')
      if (-not @($result | Where-Object { [string](Get-PropertyValue $_ 'id' '') -eq $id })) { $result += @($comment) }
    }
  }
  return @($result | Sort-Object @{ Expression = { [DateTime](Get-PropertyValue $_ 'createdAt' '1970-01-01T00:00:00Z') } })
}

function Select-IssueFields($Issue, [string[]]$Fields) {
  $selected = [ordered]@{}
  foreach ($field in $Fields) {
    switch ($field) {
      'labels' { $selected[$field] = @($Issue.labels) }
      'comments' { $selected[$field] = @(Get-TargetComments 'issue' ([int]$Issue.number) $Issue.comments) }
      default { $selected[$field] = Get-PropertyValue $Issue $field $null }
    }
  }
  return [pscustomobject]$selected
}

function Select-PrFields($Pr, [string[]]$Fields) {
  $selected = [ordered]@{}
  foreach ($field in $Fields) {
    switch ($field) {
      'comments' { $selected[$field] = @(Get-TargetComments 'pr' ([int]$Pr.number) $Pr.comments) }
      default { $selected[$field] = Get-PropertyValue $Pr $field $null }
    }
  }
  return [pscustomobject]$selected
}

function Upsert-BranchAndCommit([string]$Name, [string]$Sha) {
  if ([string]::IsNullOrWhiteSpace($Sha)) { return }
  $branch = @($state.branches | Where-Object { [string](Get-PropertyValue $_ 'name' '') -eq $Name } | Select-Object -First 1)
  if ($branch.Count -eq 0) {
    $state.branches = @($state.branches) + @([pscustomobject][ordered]@{ name = $Name; sha = $Sha })
  } else {
    Set-PropertyValue $branch[0] 'sha' $Sha
  }
  if (-not @($state.commits | Where-Object { [string](Get-PropertyValue $_ 'sha' '') -eq $Sha })) {
    $state.commits = @($state.commits) + @([pscustomobject][ordered]@{ sha = $Sha; branch = $Name })
  }
}

function Resolve-HeadOid([string]$HeadName) {
  if (-not [string]::IsNullOrWhiteSpace($env:FAKE_GH_REAL_GIT) -and
      -not [string]::IsNullOrWhiteSpace($env:FAKE_GH_REPO) -and
      (Test-Path -LiteralPath $env:FAKE_GH_REAL_GIT) -and
      (Test-Path -LiteralPath $env:FAKE_GH_REPO)) {
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = & $env:FAKE_GH_REAL_GIT -C $env:FAKE_GH_REPO rev-parse $HeadName 2>$null
      $code = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($code -eq 0) { return (($output -join '').Trim()) }
  }
  $known = @($state.branches | Where-Object { [string](Get-PropertyValue $_ 'name' '') -eq $HeadName } | Select-Object -First 1)
  if ($known.Count -eq 1) { return [string](Get-PropertyValue $known[0] 'sha' '') }
  return ''
}

function Sync-PrHeads {
  foreach ($pr in @($state.prs)) {
    $headName = [string](Get-PropertyValue $pr 'headRefName' '')
    if ([string]::IsNullOrWhiteSpace($headName)) { continue }
    $sha = Resolve-HeadOid $headName
    if (-not [string]::IsNullOrWhiteSpace($sha)) {
      Set-PropertyValue $pr 'headRefOid' $sha
      Upsert-BranchAndCommit $headName $sha
    }
  }
}

function New-Comment([string]$TargetType, [int]$Number, [string]$Body) {
  $prefix = if ($TargetType -eq 'pr') { 'PC' } else { 'IC' }
  $id = '{0}_{1}' -f $prefix, (@($state.comments).Count + 1)
  $login = [string](Get-PropertyValue $state.authenticatedUser 'login' 'owner')
  return [pscustomobject][ordered]@{
    id = $id
    targetType = $TargetType
    number = $Number
    body = $Body
    author = [pscustomobject][ordered]@{ login = $login }
    createdAt = [DateTime]::UtcNow.ToString('o')
    url = "https://github.test/$($state.currentRepo)/$TargetType/$Number#comment-$id"
  }
}

function Find-Failure([string]$CommandName) {
  $joined = $CliArguments -join ' '
  foreach ($failure in @($state.failures)) {
    $remaining = [int](Get-PropertyValue $failure 'remaining' 1)
    $failureCommand = [string](Get-PropertyValue $failure 'command' '')
    $contains = [string](Get-PropertyValue $failure 'argvContains' '')
    if ($remaining -gt 0 -and $failureCommand -eq $CommandName -and ([string]::IsNullOrWhiteSpace($contains) -or $joined.Contains($contains))) {
      Set-PropertyValue $failure 'remaining' ($remaining - 1)
      return $failure
    }
  }
  return $null
}

function Complete-Invocation([int]$ExitCode, [string]$OutputType = 'none', $OutputValue = $null, [string]$Stderr = '') {
  $after = Get-StateSnapshot $state
  $record = [pscustomobject][ordered]@{
    executablePath = $fakeExecutablePath
    implementationPath = $implementationPath
    argv = @($CliArguments)
    command = $commandName
    statePath = $statePath
    processId = $PID
    workingDirectory = (Get-Location).Path
    startedAt = $startedAt
    completedAt = [DateTime]::UtcNow.ToString('o')
    exitCode = $ExitCode
    stderr = $Stderr
    before = $before
    after = $after
  }
  $state.ghCalls = @($state.ghCalls) + @($record)
  Save-StateFile $statePath $state
  if (-not [string]::IsNullOrWhiteSpace($env:FAKE_GH_LOG)) {
    $logPath = [IO.Path]::GetFullPath($env:FAKE_GH_LOG)
    $logLine = (ConvertTo-Json -InputObject $record -Compress -Depth 12) + [Environment]::NewLine
    [IO.File]::AppendAllText($logPath, $logLine, [Text.UTF8Encoding]::new($false))
  }
  if (-not [string]::IsNullOrWhiteSpace($Stderr)) { Write-Stderr $Stderr }
  switch ($OutputType) {
    'json-array' { [Console]::Out.WriteLine((ConvertTo-Json -InputObject @($OutputValue) -Compress -Depth 30)) }
    'json-object' { [Console]::Out.WriteLine((ConvertTo-Json -InputObject $OutputValue -Compress -Depth 30)) }
    'text' { [Console]::Out.WriteLine([string]$OutputValue) }
  }
  exit $ExitCode
}

if ([string]::IsNullOrWhiteSpace($env:FAKE_GH_STATE)) {
  Stop-BeforeState 78 'FAKE_GH_STATE is required.'
}

$statePath = [IO.Path]::GetFullPath($env:FAKE_GH_STATE)
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
  Stop-BeforeState 78 "FAKE_GH_STATE file does not exist: $statePath"
}

$implementationPath = (Resolve-Path -LiteralPath $MyInvocation.MyCommand.Path).Path
$fakeExecutablePath = if ([string]::IsNullOrWhiteSpace($env:FAKE_GH_EXECUTABLE)) {
  $implementationPath
} else {
  [IO.Path]::GetFullPath($env:FAKE_GH_EXECUTABLE)
}
$startedAt = [DateTime]::UtcNow.ToString('o')
$state = Read-StateFile $statePath
$before = Get-StateSnapshot $state
Sync-PrHeads
$commandName = Get-CommandName
$failure = Find-Failure $commandName
$skipMutation = $false
if ($null -ne $failure) {
  $mode = [string](Get-PropertyValue $failure 'mode' 'fail')
  if ($mode -eq 'fail') {
    $exitCode = [int](Get-PropertyValue $failure 'exitCode' 1)
    $stderr = [string](Get-PropertyValue $failure 'stderr' "Injected failure for $commandName")
    Complete-Invocation $exitCode 'none' $null $stderr
  }
  if ($mode -eq 'invalid-json') { Complete-Invocation 0 'text' '{invalid-json' '' }
  if ($mode -eq 'no-op') { $skipMutation = $true }
}

try {
  switch ($commandName) {
    'label list' {
      Test-RepositoryOption
      [void](Get-Option '--limit' $true)
      $fields = Get-JsonFields
      $items = @()
      foreach ($label in @($state.labels)) {
        $selected = [ordered]@{}
        foreach ($field in $fields) { $selected[$field] = Get-PropertyValue $label $field $null }
        $items += @([pscustomobject]$selected)
      }
      Complete-Invocation 0 'json-array' @($items) ''
    }
    'issue list' {
      Test-RepositoryOption
      $requestedState = Get-Option '--state' $true
      $limit = [int](Get-Option '--limit' $true)
      $fields = Get-JsonFields
      $items = @($state.issues | Where-Object { [string](Get-PropertyValue $_ 'state' 'open') -ieq $requestedState } | Sort-Object number | Select-Object -First $limit)
      $projected = @()
      foreach ($issue in $items) { $projected += @(Select-IssueFields $issue $fields) }
      Complete-Invocation 0 'json-array' @($projected) ''
    }
    'issue view' {
      Test-RepositoryOption
      if ($CliArguments.Count -lt 3) { throw 'issue view requires a number.' }
      $issue = Get-Issue ([int]$CliArguments[2])
      $fields = Get-JsonFields
      Complete-Invocation 0 'json-object' (Select-IssueFields $issue $fields) ''
    }
    'issue edit' {
      Test-RepositoryOption
      if ($CliArguments.Count -lt 3) { throw 'issue edit requires a number.' }
      $issue = Get-Issue ([int]$CliArguments[2])
      $add = Get-Option '--add-label' $false
      $remove = Get-Option '--remove-label' $false
      if ([string]::IsNullOrWhiteSpace($add) -and [string]::IsNullOrWhiteSpace($remove)) { throw 'issue edit requires --add-label or --remove-label.' }
      if (-not $skipMutation) {
        if (-not [string]::IsNullOrWhiteSpace($add)) {
          if (-not @($state.labels | Where-Object { $_.name -eq $add })) { throw "Label does not exist: $add" }
          if (-not @($issue.labels | Where-Object { $_.name -eq $add })) { $issue.labels = @($issue.labels) + @([pscustomobject]@{ name = $add }) }
        }
        if (-not [string]::IsNullOrWhiteSpace($remove)) { $issue.labels = @($issue.labels | Where-Object { $_.name -ne $remove }) }
        Set-PropertyValue $issue 'updatedAt' ([DateTime]::UtcNow.ToString('o'))
      }
      Complete-Invocation 0 'none' $null ''
    }
    'issue comment' {
      Test-RepositoryOption
      if ($CliArguments.Count -lt 3) { throw 'issue comment requires a number.' }
      $number = [int]$CliArguments[2]
      [void](Get-Issue $number)
      $body = Get-Option '--body' $true
      $comment = New-Comment 'issue' $number $body
      if (-not $skipMutation) { $state.comments = @($state.comments) + @($comment) }
      Complete-Invocation 0 'text' $comment.url ''
    }
    'pr list' {
      Test-RepositoryOption
      $requestedState = Get-Option '--state' $true
      $fields = Get-JsonFields
      $items = @($state.prs | Where-Object { [string](Get-PropertyValue $_ 'state' 'open') -ieq $requestedState } | Sort-Object number)
      $projected = @()
      foreach ($pr in $items) { $projected += @(Select-PrFields $pr $fields) }
      Complete-Invocation 0 'json-array' @($projected) ''
    }
    'pr create' {
      Test-RepositoryOption
      $base = Get-Option '--base' $true
      $head = Get-Option '--head' $true
      $title = Get-Option '--title' $true
      $bodyFile = Get-Option '--body-file' $true
      if (-not [IO.Path]::IsPathRooted($bodyFile)) { $bodyFile = Join-Path (Get-Location).Path $bodyFile }
      if (-not (Test-Path -LiteralPath $bodyFile -PathType Leaf)) { throw "PR body file does not exist: $bodyFile" }
      $numbers = @($state.prs | ForEach-Object { [int]$_.number } | Sort-Object -Descending)
      $number = if ($numbers.Count -eq 0) { 1 } else { [int]$numbers[0] + 1 }
      $headOid = Resolve-HeadOid $head
      $createdAt = [DateTime]::UtcNow.ToString('o')
      $pr = [pscustomobject][ordered]@{
        number = $number
        state = 'open'
        title = $title
        body = [IO.File]::ReadAllText($bodyFile, [Text.Encoding]::UTF8)
        baseRefName = $base
        headRefName = $head
        headRefOid = $headOid
        createdAt = $createdAt
        url = "https://github.test/$($state.currentRepo)/pull/$number"
        comments = @()
      }
      if (-not $skipMutation) {
        $state.prs = @($state.prs) + @($pr)
        Upsert-BranchAndCommit $head $headOid
      }
      Complete-Invocation 0 'text' $pr.url ''
    }
    'pr view' {
      Test-RepositoryOption
      if ($CliArguments.Count -lt 3) { throw 'pr view requires a number.' }
      $pr = Get-Pr ([int]$CliArguments[2])
      $fields = Get-JsonFields
      Complete-Invocation 0 'json-object' (Select-PrFields $pr $fields) ''
    }
    'pr comment' {
      Test-RepositoryOption
      if ($CliArguments.Count -lt 3) { throw 'pr comment requires a number.' }
      $number = [int]$CliArguments[2]
      [void](Get-Pr $number)
      $body = Get-Option '--body' $true
      $comment = New-Comment 'pr' $number $body
      if (-not $skipMutation) { $state.comments = @($state.comments) + @($comment) }
      Complete-Invocation 0 'text' $comment.url ''
    }
    'auth status' {
      $hostname = Get-Option '--hostname' $true
      if ($hostname -ne 'github.com') { throw "Unexpected hostname: $hostname" }
      $login = [string](Get-PropertyValue $state.authenticatedUser 'login' '')
      Complete-Invocation 0 'text' "Logged in to github.com as $login" ''
    }
    'api user' {
      Complete-Invocation 0 'json-object' $state.authenticatedUser ''
    }
    'repo view' {
      if ($CliArguments.Count -lt 3) { throw 'repo view requires a repository.' }
      if ([string]$CliArguments[2] -ne [string]$state.currentRepo) { throw "Unexpected repository: $($CliArguments[2])" }
      $fields = Get-JsonFields
      $selected = [ordered]@{}
      foreach ($field in $fields) { $selected[$field] = Get-PropertyValue $state.repository $field $null }
      Complete-Invocation 0 'json-object' ([pscustomobject]$selected) ''
    }
    default {
      Complete-Invocation 64 'none' $null "Unsupported fake gh command: $($CliArguments -join ' ')"
    }
  }
} catch {
  $location = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) { " (line $($_.InvocationInfo.ScriptLineNumber))" } else { '' }
  Complete-Invocation 1 'none' $null ($_.Exception.Message + $location)
}
