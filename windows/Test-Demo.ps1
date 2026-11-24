#Requires -RunAsAdministrator
param([ValidateRange(20,90)][int]$HoldDownSeconds = 45)
$ErrorActionPreference = 'Stop'
$state = Join-Path $env:LOCALAPPDATA 'NetXMS-SNMP-Demo'
$config = Get-Content "$state\monitor.json" -Raw | ConvertFrom-Json
$demo = Get-NetAdapter -InterfaceIndex $config.demoIfIndex
$main = Get-NetAdapter -InterfaceIndex $config.mainIfIndex
if ($demo.ifIndex -eq $main.ifIndex -or [guid]$demo.InterfaceGuid -ne [guid]$config.adapterGuid -or
    [guid]$main.InterfaceGuid -ne [guid]$config.mainAdapterGuid -or $demo.Status -ne 'Up' -or $main.Status -ne 'Up') {
    throw 'Adapter identities or link states changed. Rerun Configure-Demo.ps1 with the current adapters.'
}
if (Get-NetRoute -InterfaceIndex $demo.ifIndex | Where-Object DestinationPrefix -in '0.0.0.0/0','::/0') {
    throw 'Refusing to disable an adapter with a default route.'
}
if (Get-Process -Name VirtualBoxVM,VBoxHeadless -ErrorAction SilentlyContinue) {
    throw 'Stop any VirtualBox guests before running the demo.'
}
$addresses = @(Get-NetIPAddress -InterfaceIndex $demo.ifIndex -ErrorAction SilentlyContinue | Select-Object -ExpandProperty IPAddress)
if (Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object LocalAddress -in $addresses) {
    throw 'Refusing to disable an adapter with active TCP connections.'
}
$rollbackName = 'NetXMS-SNMP-Demo-Restore'
if (Get-ScheduledTask -TaskName $rollbackName -ErrorAction SilentlyContinue) {
    throw 'A previous demo still has a recovery task. Check the adapter and task before rerunning.'
}

$base = 'http://127.0.0.1:8000/v1'
$admin = Import-Clixml "$state\netxms-credential.xml"
$login = Invoke-RestMethod "$base/login" -Method Post -ContentType 'application/json' -Body (@{username=$admin.UserName;password=$admin.GetNetworkCredential().Password} | ConvertTo-Json) -TimeoutSec 10
$headers = @{Authorization="Bearer $($login.token)"}
$results = [ordered]@{ started=[DateTimeOffset]::UtcNow.ToString('o'); passed=$false; adapter=$demo.Name; mainAdapter=$main.Name; phases=@() }
$registered = $false
$disabled = $false
$modeChanged = $false
$originalMode = [uint32]0

function Wait-Phase([string]$Name, [string]$Expected, [DateTimeOffset]$After) {
    $ids = $config.uptimeDciId,$config.demoDciId,$config.mainDciId
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(35)
    do {
        $values = @((Invoke-RestMethod "$base/objects/$($config.nodeId)/data-collection/current-values" -Headers $headers -TimeoutSec 10).values | Where-Object id -in $ids)
        $fresh = @($values | Where-Object { $_.timestamp -and $_.errorCount -eq 0 -and [DateTimeOffset]::Parse($_.timestamp) -ge $After })
        $secondary = $fresh | Where-Object id -eq $config.demoDciId
        $mainValue = $fresh | Where-Object id -eq $config.mainDciId
        $alarms = Invoke-RestMethod "$base/alarms?rootObject=$($config.nodeId)" -Headers $headers -TimeoutSec 10
        $outstanding = @($alarms | Where-Object { $_.state -in 0,1 -and $_.message.Contains($config.demoDescription) })
        $shouldAlarm = $Expected -eq '2'
        if ((Get-NetAdapter -InterfaceIndex $main.ifIndex).Status -ne 'Up') { throw 'The main connection is no longer up.' }
        if ($fresh.Count -eq 3 -and $secondary.value -eq $Expected -and $mainValue.value -eq '1' -and
            $secondary.hasActiveThreshold -eq $shouldAlarm -and ($outstanding.Count -gt 0) -eq $shouldAlarm) {
            $results.phases += @{ name=$Name; observedAt=[DateTimeOffset]::UtcNow.ToString('o'); values=$fresh; activeAlarms=$outstanding }
            Write-Host "$Name`: demo=$Expected, main=1, SNMP responding, demo alarm=$shouldAlarm."
            return
        }
        Start-Sleep -Seconds 1
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Timed out waiting for fresh telemetry and the expected alarm state: $Name."
}

try {
    # QuickEdit selection can suspend PowerShell output while the adapter is disabled.
    if (-not ('NetXmsDemo.ConsoleMode' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace NetXmsDemo {
    public static class ConsoleMode {
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int kind);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
    }
}
'@
    }
    $consoleInput = [NetXmsDemo.ConsoleMode]::GetStdHandle(-10)
    if ([NetXmsDemo.ConsoleMode]::GetConsoleMode($consoleInput, [ref]$originalMode)) {
        $mode = [uint32](($originalMode -bor 0x80) -band (-bnot 0x40))
        if (-not [NetXmsDemo.ConsoleMode]::SetConsoleMode($consoleInput, $mode)) { throw 'Cannot disable QuickEdit for this console.' }
        $modeChanged = $true
    }

    Wait-Phase baseline-up '1' ([DateTimeOffset]::UtcNow)
    # Independent recovery if this process exits or is interrupted while the adapter is down.
    $guid = [guid]$demo.InterfaceGuid
    $restore = "Get-NetAdapter -IncludeHidden | Where-Object { [guid]`$_.InterfaceGuid -eq [guid]'$guid' } | Enable-NetAdapter -Confirm:`$false"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restore))
    $action = New-ScheduledTaskAction -Execute "$env:windir\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -EncodedCommand $encoded"
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5)
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskName $rollbackName -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest | Out-Null
    $registered = $true

    $downAt = [DateTimeOffset]::UtcNow
    $results.disabledAt = $downAt.ToString('o')
    $disabled = $true
    Disable-NetAdapter -InputObject $demo -Confirm:$false
    Wait-Phase interface-down '2' $downAt
    Start-Sleep -Seconds $HoldDownSeconds
    $upAt = [DateTimeOffset]::UtcNow
    $results.enabledAt = $upAt.ToString('o')
    Get-NetAdapter -IncludeHidden | Where-Object { [guid]$_.InterfaceGuid -eq $guid } | Enable-NetAdapter -Confirm:$false
    $disabled = $false
    Wait-Phase interface-recovered '1' $upAt
    $results.passed = $true
    Write-Host 'PASS: secondary SNMP 1 -> 2 -> 1; alarm raised and cleared; main link stayed up.'
} catch {
    $results.error = $_.ToString()
    throw
} finally {
    if ($disabled) {
        Get-NetAdapter -IncludeHidden | Where-Object { [guid]$_.InterfaceGuid -eq $guid } | Enable-NetAdapter -Confirm:$false -ErrorAction Continue
    }
    if ($modeChanged) { [NetXmsDemo.ConsoleMode]::SetConsoleMode($consoleInput, $originalMode) | Out-Null }
    $results.adapterRestored = (Get-NetAdapter -IncludeHidden | Where-Object { [guid]$_.InterfaceGuid -eq [guid]$config.adapterGuid }).Status -eq 'Up'
    if ($registered -and $results.adapterRestored) { Unregister-ScheduledTask -TaskName $rollbackName -Confirm:$false }
    $results.finished = [DateTimeOffset]::UtcNow.ToString('o')
    $results | ConvertTo-Json -Depth 16 | Set-Content "$state\test-results.json" -Encoding UTF8
    Invoke-RestMethod "$base/logout" -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' -TimeoutSec 10 | Out-Null
}
