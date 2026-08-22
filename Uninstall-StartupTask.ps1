[CmdletBinding()]
param([string]$TaskName = 'FileBot Media Automation')
$ErrorActionPreference = 'Stop'
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Write-Host "Removed startup task: $TaskName"

