param(
    [Parameter(Mandatory)][string]$MainAdapter,
    [Parameter(Mandatory)][string]$DemoAdapter
)
$ErrorActionPreference = 'Stop'
$state = Join-Path $env:LOCALAPPDATA 'NetXMS-SNMP-Demo'
$adapters = Get-NetAdapter
$main = $adapters | Where-Object Name -eq $MainAdapter
$demo = $adapters | Where-Object Name -eq $DemoAdapter
if (-not $main -or -not $demo -or $main.ifIndex -eq $demo.ifIndex -or $main.Status -ne 'Up' -or $demo.Status -ne 'Up') {
    throw 'Select two distinct, currently up adapters. Use Get-NetAdapter to list names.'
}

$snmp = Import-Clixml "$state\snmp-credential.xml"
foreach ($adapter in $main,$demo) {
    $oid = "1.3.6.1.2.1.2.2.1.8.$($adapter.ifIndex)"
    $sample = & 'C:\NetXMS\bin\nxsnmpget.exe' -M -v 2c -c $snmp.GetNetworkCredential().Password -n -R -w 2 127.0.0.1 $oid
    if ($LASTEXITCODE -ne 0 -or $sample -notcontains "$oid [INTEGER]: 1") {
        throw "Windows SNMP did not report '$($adapter.Name)' (ifIndex $($adapter.ifIndex)) up. Check the agent and interface index."
    }
}

$admin = Import-Clixml "$state\netxms-credential.xml"
$base = 'http://127.0.0.1:8000/v1'
$login = Invoke-RestMethod "$base/login" -Method Post -ContentType 'application/json' -Body (@{username=$admin.UserName;password=$admin.GetNetworkCredential().Password} | ConvertTo-Json) -TimeoutSec 10
$headers = @{Authorization="Bearer $($login.token)"}
function Invoke-NetXms([string]$Method, [string]$Path, [hashtable]$Body) {
    $request = @{Uri="$base$Path"; Method=$Method; Headers=$headers; TimeoutSec=15}
    if ($null -ne $Body) {
        $request.ContentType = 'application/json'
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
    }
    $response = Invoke-RestMethod @request
    $response
}

try {
    # nxdbmgr marks the randomly generated setup password for a change on first login.
    if ($login.changePassword) {
        Invoke-NetXms Put "/users/$($login.userId)" @{flags=@{changePassword=$false}} | Out-Null
    }
    $roots = Invoke-NetXms Get '/objects'
    $infrastructure = $roots | Where-Object class -eq 'ServiceRoot'
    $dashboards = $roots | Where-Object class -eq 'DashboardRoot'
    $nodes = Invoke-NetXms Get "/objects?parent=$($infrastructure.id)" | Where-Object class -eq 'Node'
    $node = foreach ($candidate in $nodes) {
        $detail = Invoke-NetXms Get "/objects/$($candidate.id)"
        if ($detail.capabilities.isLocalMgmt -and $detail.ipAddress.address -eq '127.0.0.1') { $detail }
    }
    if (-not $node) { throw 'The loopback NetXMS management node is not ready. Check NetXMSCore and try again.' }
    $nodePath = "/objects/$($node.id)"
    Invoke-NetXms Patch "$nodePath/snmp" @{version='2c'; port=161; authName=$snmp.GetNetworkCredential().Password; settingsLocked=$true} | Out-Null
    $dciPath = "$nodePath/data-collection/configuration"
    $existing = Invoke-NetXms Get $dciPath
    function Set-Metric([string]$Tag, [string]$Oid, [string]$Description, [string]$Type, [string]$Function, [string]$Condition) {
        # Explicit port bypasses capability discovery, which excludes loopback in 7.0.4.
        $definition = @{
            type='item'; name=$Oid; description=$Description; origin='snmp'; status='active'; dataType=$Type
            snmpPort=161; pollingScheduleType='custom'; pollingInterval='10'; retentionType='custom'; retentionTime='7'
            systemTag="snmp-demo.$Tag"
            thresholds=@(@{function=$Function; condition=$Condition; value='1'; sampleCount=1; activationEvent='SYS_THRESHOLD_REACHED'; deactivationEvent='SYS_THRESHOLD_REARMED'})
        }
        $current = $existing | Where-Object systemTag -eq $definition.systemTag
        if ($current) {
            if ($current.thresholds.Count -eq 1) { $definition.thresholds[0].id = $current.thresholds[0].id }
            Invoke-NetXms Patch "$dciPath/$($current.id)" $definition | Out-Null
            return $current.id
        }
        (Invoke-NetXms Post $dciPath $definition).id
    }

    $demoDescription = "Demo $($demo.Name) operational status (1=up, 2=down)"
    $uptimeId = Set-Metric uptime '1.3.6.1.2.1.1.3.0' 'Windows SNMP agent uptime (hundredths of a second)' uint32 error greaterOrEqual
    $demoId = Set-Metric secondary "1.3.6.1.2.1.2.2.1.8.$($demo.ifIndex)" $demoDescription int32 last notEqual
    $mainId = Set-Metric main "1.3.6.1.2.1.2.2.1.8.$($main.ifIndex)" "Main $($main.Name) operational status (1=up, 2=down)" int32 last notEqual

    $dashboardName = 'Windows SNMP Interface Demo'
    $dashboard = Invoke-NetXms Get "/objects?parent=$($dashboards.id)" | Where-Object { $_.class -eq 'Dashboard' -and $_.name -eq $dashboardName }
    if (-not $dashboard) {
        $dashboard = Invoke-NetXms Post '/objects' @{class='Dashboard'; name=$dashboardName; parentId=$dashboards.id}
    }
    $id = $node.id
    $layout = @{horizontalSpan=2; heightHint=250; grabVerticalSpace=$true}
    $content = @{numColumns=2; scrollable=$false; elements=@(
        @{type=6; layout=@{horizontalSpan=2; heightHint=90; grabVerticalSpace=$false}; data=@{
            title='Live status: green = available/up; red = unavailable/not up'; numColumns=3; labelType=1; shape=2; fullColorRange=$false
            elements=@(
                @{type=1; objectId=$id; dciId=$uptimeId; label='Laptop SNMP availability'},
                @{type=1; objectId=$id; dciId=$mainId; label="$($main.Name) - main connection"},
                @{type=1; objectId=$id; dciId=$demoId; label="$($demo.Name) - demo interface"}
            )
        }},
        @{type=1; layout=@{horizontalSpan=2; heightHint=230; grabVerticalSpace=$true}; data=@{
            title='ifOperStatus: 1 = UP, 2 = DOWN | polling every 10 seconds'; refreshRate=10; timeUnits=0; timeRange=5
            showLegend=$true; extendedLegend=$true; autoScale=$false; minYScaleValue=0; maxYScaleValue=3; modifyYBase=$true; showGrid=$true; lineWidth=2; yAxisLabel='ifOperStatus'
            dciList=@(
                @{nodeId=$id; dciId=$mainId; type=1; name="$($main.Name) (main)"},
                @{nodeId=$id; dciId=$demoId; type=1; name="$($demo.Name) (demo)"}
            )
        }},
        @{type=11; layout=$layout; data=@{title='Interface alarms'; objectId=$id; severityFilter=30; stateFilter=255}},
        @{type=24; layout=$layout; data=@{title='Recent changes (polling events, not traps)'; objectId=$id; maxEvents=100; timeRangeMinutes=60; eventCodes='17,18'}}
    )}
    Invoke-NetXms Put "/objects/$($dashboard.id)/dashboard" $content | Out-Null

    @{
        nodeId=$id; uptimeDciId=$uptimeId; demoDciId=$demoId; mainDciId=$mainId; demoDescription=$demoDescription
        adapterName=$demo.Name; adapterGuid=[string]$demo.InterfaceGuid; demoIfIndex=$demo.ifIndex
        mainAdapterName=$main.Name; mainAdapterGuid=[string]$main.InterfaceGuid; mainIfIndex=$main.ifIndex
    } | ConvertTo-Json | Set-Content "$state\monitor.json" -Encoding UTF8
    Write-Host "Configured $dashboardName. Run Run-Demo.cmd once the dashboard is ready."
} finally {
    Invoke-NetXms Post '/logout' @{} | Out-Null
}
