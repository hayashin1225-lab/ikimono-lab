[CmdletBinding()]
param([string]$TaskName = 'IkimonoLab-LiaisonOfficer')

$ErrorActionPreference = 'Stop'
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) { Write-Output "Scheduled task is not registered: $TaskName"; exit 0 }
if ($task.Description -ne 'Ikimono Lab Liaison Officer MVP') { throw "Refusing to remove a task not created by this MVP: $TaskName" }
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Output "Removed scheduled task: $TaskName"
