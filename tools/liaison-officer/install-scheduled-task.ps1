[CmdletBinding()]
param(
  [string]$ConfigPath = '',
  [string]$TaskName = 'IkimonoLab-LiaisonOfficer'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot 'config.local.json'
}
$relayPath = Join-Path $PSScriptRoot 'relay-windows.ps1'
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config.local.json is required: $ConfigPath" }
if (-not (Test-Path -LiteralPath $relayPath)) { throw "relay-windows.ps1 is missing: $relayPath" }

& $relayPath -Mode SelfTest -ConfigPath $ConfigPath
if ($LASTEXITCODE -ne 0) { throw 'SelfTest failed. The scheduled task was not registered.' }

$config = Get-Content -Raw -Encoding UTF8 -LiteralPath $ConfigPath | ConvertFrom-Json
$interval = [int]$config.taskIntervalMinutes
if ($interval -lt 1) { throw 'taskIntervalMinutes must be at least 1.' }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$relayPath`" -Mode Scheduled -ConfigPath `"$ConfigPath`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $interval) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable:$false -WakeToRun:$false
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Ikimono Lab Liaison Officer MVP' -Force | Out-Null
Write-Output "Registered scheduled task: $TaskName"
