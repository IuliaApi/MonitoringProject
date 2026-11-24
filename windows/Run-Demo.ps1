$ErrorActionPreference = 'Stop'
$state = Join-Path $env:LOCALAPPDATA 'NetXMS-SNMP-Demo'
if (-not (Test-Path "$state\monitor.json")) { throw 'Run Configure-Demo.ps1 before launching the demo.' }
$credential = Import-Clixml "$state\netxms-credential.xml"
Write-Host "Username: $($credential.UserName)"
Write-Host "Password: $($credential.GetNetworkCredential().Password)"
Write-Host 'Keep these login details private.'
Start-Process 'http://127.0.0.1:4788/nxmc/'
Write-Host 'Sign in and open Dashboards > Windows SNMP Interface Demo.'
Read-Host 'Press Enter when the dashboard is visible, then approve the Windows elevation prompt' | Out-Null
Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -NoExit -ExecutionPolicy Bypass -File `"$PSScriptRoot\Test-Demo.ps1`""
