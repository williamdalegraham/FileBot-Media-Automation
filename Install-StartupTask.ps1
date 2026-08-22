[CmdletBinding()]
param([string]$TaskName = 'FileBot Media Automation')
$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot 'MediaWatcher.ps1'
$pwsh = (Get-Command powershell.exe).Source
$action = New-ScheduledTaskAction -Execute $pwsh -Argument ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $watcher)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Description 'Watches the pending-media folder and organizes media with FileBot.' -Force | Out-Null
Write-Host "Installed startup task: $TaskName"

