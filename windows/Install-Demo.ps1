#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$InstallerDirectory)
$ErrorActionPreference = 'Stop'
$state = Join-Path $env:LOCALAPPDATA 'NetXMS-SNMP-Demo'
$snmpRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters'
if ((Get-Service NetXMSCore,nxWebUI,NetXMSAgentdW32 -ErrorAction SilentlyContinue) -or
    (Test-Path 'C:\NetXMS') -or (Test-Path 'C:\NetXMS-WebUI') -or (Test-Path $state)) {
    throw 'Install on a clean demo machine. Existing NetXMS or demo state will not be overwritten.'
}
$communities = Get-Item "$snmpRoot\ValidCommunities" -ErrorAction SilentlyContinue
if ($communities -and $communities.GetValueNames().Count) {
    throw 'Windows SNMP already has configured communities; refusing to replace them.'
}

$serverInstaller = Join-Path $InstallerDirectory 'netxms-server-7.0.4-x64.exe'
$webInstaller = Join-Path $InstallerDirectory 'netxms-webui-7.0.4-x64.exe'
foreach ($file in $serverInstaller,$webInstaller) {
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Raden Solutions') {
        throw "Invalid NetXMS vendor signature: $file"
    }
}

function New-DemoCredential([string]$Name) {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $secret = 'Nx-' + [BitConverter]::ToString($bytes).Replace('-', '') + '!7a'
    [pscredential]::new($Name, (ConvertTo-SecureString $secret -AsPlainText -Force))
}

$cap = Get-WindowsCapability -Online -Name 'SNMP.Client*'
if ($cap.State -ne 'Installed') {
    $result = Add-WindowsCapability -Online -Name $cap.Name
    if ($result.RestartNeeded) { throw 'Restart Windows before running this installer again.' }
}
New-Item -ItemType Directory -Path $state | Out-Null
& icacls.exe $state /inheritance:r /grant:r "$([Security.Principal.WindowsIdentity]::GetCurrent().Name):(OI)(CI)(F)" 'SYSTEM:(OI)(CI)(F)' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the local demo state directory.' }

# Explicit blocks protect the listeners even while the installers are applying defaults.
foreach ($rule in @(
    @{Name='NetXMS-Demo-TCP-External-Block'; Protocol='TCP'; LocalPort=4700,4701,4703,4733,4788,8000},
    @{Name='NetXMS-Demo-SNMP-External-Block'; Protocol='UDP'; LocalPort=161}
)) {
    New-NetFirewallRule @rule -DisplayName $rule.Name -Direction Inbound -Action Block -InterfaceType Wired,Wireless,RemoteAccess -Profile Any | Out-Null
}
Stop-Service SNMP
$snmp = New-DemoCredential 'snmp-read-only'
$snmp | Export-Clixml "$state\snmp-credential.xml"
New-Item "$snmpRoot\ValidCommunities" -Force | Out-Null
New-Item "$snmpRoot\PermittedManagers" -Force | Out-Null
New-ItemProperty "$snmpRoot\ValidCommunities" -Name $snmp.GetNetworkCredential().Password -PropertyType DWord -Value 4 | Out-Null
New-ItemProperty "$snmpRoot\PermittedManagers" -Name '1' -PropertyType String -Value '127.0.0.1' | Out-Null
Set-Service SNMP -StartupType Automatic
Start-Service SNMP

$p = Start-Process -FilePath $serverInstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\NetXMS /COMPONENTS=base,server,tools /TASKS=fspermissions' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "NetXMS server installer failed: $($p.ExitCode)" }
$serverConfig = 'C:\NetXMS\etc\netxmsd.conf'
if (Test-Path $serverConfig) { throw 'Unexpected existing NetXMS server configuration.' }
@'
DBDriver = sqlite.ddr
DBName = C:\NetXMS\var\netxmsd.db
LogFile = C:\NetXMS\log\netxmsd.log
DataDirectory = C:\NetXMS\var
ListenAddress = 127.0.0.1
ManagementAgentAddress = 127.0.0.1
Module = webapi

[WEBAPI]
Enable = yes
Address = loopback
Port = 8000
'@ | Set-Content $serverConfig -Encoding ASCII
$admin = New-DemoCredential 'admin'
$admin | Export-Clixml "$state\netxms-credential.xml"
$password = $admin.GetNetworkCredential().Password
$output = & 'C:\NetXMS\bin\nxdbmgr.exe' -c $serverConfig init -F sqlite -p $password 2>&1
if ($LASTEXITCODE -ne 0) { throw (($output -join "`n").Replace($password, '[REDACTED]')) }
Set-Service NetXMSCore -StartupType Automatic
Start-Service NetXMSCore

$p = Start-Process -FilePath $webInstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR=C:\NetXMS-WebUI' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "NetXMS web console installer failed: $($p.ExitCode)" }
@'
# Use the Logback jars bundled with 7.0.4 and allow time for annotation scanning.
logback.version=1.5.21
jetty.http.host=127.0.0.1
jetty.ssl.host=127.0.0.1
-Dorg.eclipse.jetty.annotations.maxWait=180
'@ | Set-Content 'C:\NetXMS-WebUI\jetty-base\start.d\snmp-demo.ini' -Encoding ASCII
Restart-Service nxWebUI
Write-Host 'Installed. After the services start, run Configure-Demo.ps1 from this Windows account.'
