#Requires -Version 5.1
param(
    [ValidateSet('Network','Forest','Directory','Join','VerifyDomain','Workload','Validate')][string]$Action,
    $Config,
    $Spec,
    [pscredential]$Credential
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root='C:\HyperVLab'
$subnet="$($Config.NetworkPrefix).0/24"
$domainAdmin=New-Object Management.Automation.PSCredential("$($Config.DomainNetbios)\Administrator",$Credential.Password)
$data=$null
$reboot=$false

function Assert-GuestNative {
    param([string]$File,[string[]]$Arguments)
    $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { & $File @Arguments 2>&1 | Out-Null; $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    if ($code -ne 0) { throw "Native guest operation failed (exit $code)." }
}

function Set-GuestPort {
    param([int[]]$Ports,[string]$Name)
    $rule=Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name $Name -DisplayName $Name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Ports -RemoteAddress $subnet -Profile Any | Out-Null
    } else { $rule | Set-NetFirewallRule -RemoteAddress $subnet -Enabled True }
}

function Set-GuestTask {
    param([string]$Name,[string]$Arguments)
    $task=Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    if ($task) {
        if ($task.Actions[0].Execute -ne "$root\DependencyDemo.exe" -or $task.Actions[0].Arguments -ne $Arguments) { throw 'Existing workload task definition differs.' }
    } else {
        $action=New-ScheduledTaskAction -Execute "$root\DependencyDemo.exe" -Argument $Arguments
        $principal=New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::Zero) -RestartCount 100 -RestartInterval (New-TimeSpan -Minutes 1)
        Register-ScheduledTask -TaskName $Name -Action $action -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings | Out-Null
    }
    if (-not $task -or $task.State -ne 'Running') { Start-ScheduledTask -TaskName $Name }
}

function Get-GuestHealth {
    $checks=[ordered]@{}
    $checks.Hostname=$env:COMPUTERNAME -eq $Spec.Name
    $checks.Address=@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $Spec.Ip).Count -eq 1
    $checks.WinRM=(Get-Service WinRM).Status -eq 'Running'
    $cs=Get-CimInstance Win32_ComputerSystem
    $checks.Domain=if ($Spec.Join) { $cs.PartOfDomain -and $cs.Domain -eq $Config.DomainName } else { -not $cs.PartOfDomain }
    $checks.UnattendRemoved=-not (Test-Path 'C:\Windows\Panther\unattend.xml')
    switch ($Spec.Role) {
        DC {
            try {
                $checks.AD=(Get-ADDomain).DNSRoot -eq $Config.DomainName
                $checks.Users=@(Get-ADUser -Filter "SamAccountName -like 'demo.user*'").Count -eq 3
                $checks.DNS=[bool](Resolve-DnsName $Config.DomainName -Type SOA -Server "$($Config.NetworkPrefix).10" -ErrorAction Stop)
            } catch { $checks.DirectoryAvailable=$false }
        }
        File {
            $share=Get-SmbShare -Name 'DemoData' -ErrorAction SilentlyContinue
            $checks.SMB=[bool]$share -and $share.Path -eq "$root\Data"
            $checks.Sample=Test-Path "$root\Data\sample.txt"
        }
        App {
            $service=Get-Service W3SVC -ErrorAction SilentlyContinue
            $checks.IIS=[bool]$service -and $service.Status -eq 'Running'
            try { $checks.HTTP=(Invoke-WebRequest 'http://localhost/' -UseBasicParsing -TimeoutSec 15).StatusCode -eq 200 } catch { $checks.HTTP=$false }
            $checks.TCP=@(Get-NetTCPConnection -State Listen -LocalPort 9500 -ErrorAction SilentlyContinue).Count -gt 0
            if ($Config.Sql.Enabled) {
                $sqlService=Get-Service 'MSSQL$HVLAB' -ErrorAction SilentlyContinue
                $checks.SQL=[bool]$sqlService -and $sqlService.Status -eq 'Running' -and
                    @(Get-NetTCPConnection -LocalPort 1433 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
            }
        }
        Client {
            foreach ($taskName in @('HVLab-Traffic')) {
                $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                $checks.TrafficTask=[bool]$task -and $task.State -eq 'Running'
            }
            # The connector itself writes health after actual TCP, HTTP and SMB I/O
            # under SYSTEM (domain computer identity), not this administrator probe.
            if (Test-Path "$root\traffic-health.txt") {
                $lines=Get-Content "$root\traffic-health.txt"
                $when=[datetime]::MinValue
                $fresh=$lines.Count -ge 2 -and [datetime]::TryParse($lines[0],[ref]$when) -and ([datetime]::UtcNow-$when.ToUniversalTime()).TotalSeconds -lt 180
                $expected=if ($Config.Sql.Enabled) { 'TCP=OK;HTTP=OK;SMB=OK;SQL=OK' } else { 'TCP=OK;HTTP=OK;SMB=OK' }
                $checks.Traffic=$fresh -and $lines[1] -eq $expected
            } else { $checks.Traffic=$false }
        }
        Appliance {
            $checks.Memory=$cs.TotalPhysicalMemory -ge 15GB
            $checks.Cpu=$cs.NumberOfLogicalProcessors -ge 8
            $checks.Disk=(Get-Volume -DriveLetter C).Size -ge 95GB
            $checks.InstallerStaged=(Test-Path "$root\installer-path.txt") -and (Test-Path ((Get-Content "$root\installer-path.txt" -Raw).Trim()))
            # This checks infrastructure readiness, NOT appliance registration.
        }
    }
    [pscustomobject]@{ Health=$(if (@($checks.Values | Where-Object { $_ -ne $true }).Count -eq 0) { 'Healthy' } else { 'Unhealthy' });Checks=[pscustomobject]$checks }
}

function Install-GuestSql {
    if (Test-Path "$root\sql-reboot.txt") {
        $sameBoot=(Get-Content "$root\sql-reboot.txt" -Raw).Trim() -eq (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if ($sameBoot) { return $true }
    }
    $service=Get-Service 'MSSQL$HVLAB' -ErrorAction SilentlyContinue
    if (-not $service) {
        if ((Get-FileHash "$root\SqlExpress.exe" -Algorithm SHA256).Hash -ne $Config.Sql.InstallerSha256) { throw 'SQL media SHA256 mismatch.' }
        $sig=Get-AuthenticodeSignature "$root\SqlExpress.exe"
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'SQL media signature mismatch.' }
        # The full Express package extracts locally. A web bootstrapper will not
        # produce this setup.exe and therefore fails rather than accepting defaults.
        Assert-GuestNative "$root\SqlExpress.exe" @('/q',"/x:$root\SqlMedia")
        $setup="$root\SqlMedia\setup.exe"
        if (-not (Test-Path $setup)) { throw 'Supply the full SQL Server Express 2022 offline package, not a web bootstrapper.' }
        $sig=Get-AuthenticodeSignature $setup
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Extracted SQL setup signature mismatch.' }
        $process=Start-Process -FilePath $setup -Wait -PassThru -ArgumentList @(
            '/Q','/ACTION=Install','/IACCEPTSQLSERVERLICENSETERMS','/FEATURES=SQLENGINE',
            '/INSTANCENAME=HVLAB','/INSTANCEID=HVLAB','/TCPENABLED=1','/NPENABLED=0',
            '/SQLSVCSTARTUPTYPE=Automatic','/UPDATEENABLED=False','/SQLSYSADMINACCOUNTS="BUILTIN\Administrators"'
        )
        if ($process.ExitCode -notin @(0,3010)) { throw 'SQL setup returned a non-success exit code.' }
        if ($process.ExitCode -eq 3010) {
            Set-Content "$root\sql-reboot.txt" (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            return $true
        }
    }
    $instance=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL').HVLAB
    if ($instance -notlike 'MSSQL16.*') { throw 'Expected a SQL Server 2022 instance.' }
    $tcp="HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instance\MSSQLServer\SuperSocketNetLib\Tcp"
    $props=Get-ItemProperty "$tcp\IPAll"
    if ($props.TcpPort -ne '1433' -or $props.TcpDynamicPorts -ne '') {
        Set-ItemProperty $tcp -Name Enabled -Value 1
        Set-ItemProperty "$tcp\IPAll" -Name TcpDynamicPorts -Value ''
        Set-ItemProperty "$tcp\IPAll" -Name TcpPort -Value '1433'
        Restart-Service 'MSSQL$HVLAB'
    }
    Set-GuestPort @(1433) 'HVLab-SQL'
    $connection=New-Object Data.SqlClient.SqlConnection('Server=localhost\HVLAB;Integrated Security=SSPI;Connect Timeout=30')
    try {
        $connection.Open()
        $account="$($Config.DomainNetbios)\$($Config.GuestPrefix)-CLIENT01`$"
        $command=$connection.CreateCommand()
        $command.CommandText="IF SUSER_ID(N'$account') IS NULL CREATE LOGIN [$account] FROM WINDOWS;"
        $command.ExecuteNonQuery() | Out-Null
    } finally { $connection.Dispose() }
    return $false
}

try {
    if ($env:COMPUTERNAME -ne $Spec.Name) { throw 'Unexpected guest computer name.' }
    if ($Action -ne 'Network') {
        if (-not (Test-Path "$root\owner.txt") -or (Get-Content "$root\owner.txt" -Raw).Trim() -ne $Config.LabId) { throw 'Guest ownership marker missing or mismatched.' }
    }
    switch ($Action) {
        Network {
            New-Item -ItemType Directory -Path $root -Force | Out-Null
            if (Test-Path "$root\owner.txt") {
                if ((Get-Content "$root\owner.txt" -Raw).Trim() -ne $Config.LabId) { throw 'Guest ownership mismatch.' }
            } else { Set-Content "$root\owner.txt" $Config.LabId }
            $acl=Get-Acl $root
            $acl.SetAccessRuleProtection($true,$false)
            foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
                $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
                    ([Security.Principal.SecurityIdentifier]$sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
            }
            ([IO.DirectoryInfo]$root).SetAccessControl($acl)
            foreach ($path in @('C:\Windows\Panther\unattend.xml','C:\Windows\Panther\Unattend\unattend.xml','C:\Windows\System32\Sysprep\unattend.xml')) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
            $adapter=@(Get-NetAdapter | Where-Object Status -eq 'Up')
            if ($adapter.Count -ne 1) { throw 'Expected one guest network adapter.' }
            $idx=$adapter[0].ifIndex
            $static=@(Get-NetIPAddress -InterfaceIndex $idx -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -eq 'Manual' -and $_.IPAddress -notlike '169.254.*' })
            if ($static.Count -and -not @($static | Where-Object IPAddress -eq $Spec.Ip).Count) { throw 'Guest has unexpected static IP; refusing destructive reconfiguration.' }
            if (-not @($static | Where-Object IPAddress -eq $Spec.Ip).Count) {
                Set-NetIPInterface -InterfaceIndex $idx -AddressFamily IPv4 -Dhcp Disabled
                New-NetIPAddress -InterfaceIndex $idx -IPAddress $Spec.Ip -PrefixLength 24 -DefaultGateway "$($Config.NetworkPrefix).1" | Out-Null
            }
            Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses "$($Config.NetworkPrefix).10"
            Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
            Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress $subnet
            $data=@{ Network='Configured' }
        }
        Forest {
            $cs=Get-CimInstance Win32_ComputerSystem
            if ($cs.DomainRole -ge 4) {
                if ($cs.Domain -ne $Config.DomainName) { throw 'Guest already belongs to another forest.' }
                $sameBoot=(Test-Path "$root\forest-boot.txt") -and
                    (Get-Content "$root\forest-boot.txt" -Raw).Trim() -eq (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                $data=@{Reboot=($sameBoot -or (Get-Service NTDS).Status -ne 'Running')}
            } else {
                $result=Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
                if (-not $result.Success) { throw 'AD/DNS feature installation failed.' }
                Import-Module ADDSDeployment
                Set-Content "$root\forest-boot.txt" (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                Install-ADDSForest -DomainName $Config.DomainName -DomainNetbiosName $Config.DomainNetbios -SafeModeAdministratorPassword $Credential.Password -InstallDns -NoRebootOnCompletion:$true -Force -ErrorAction Stop | Out-Null
                $data=@{Reboot=$true}
            }
        }
        Directory {
            Import-Module ActiveDirectory
            $until=(Get-Date).AddMinutes(5)
            do {
                try { $domain=Get-ADDomain -ErrorAction Stop; break } catch { Start-Sleep -Seconds 10 }
            } while ((Get-Date) -lt $until)
            if (-not (Get-Variable domain -ErrorAction SilentlyContinue) -or $domain.DNSRoot -ne $Config.DomainName) { throw 'AD DS did not become ready.' }
            $forwarder='168.63.129.16'
            if (-not @((Get-DnsServerForwarder).IPAddress | Where-Object { $_.ToString() -eq $forwarder }).Count) { Add-DnsServerForwarder -IPAddress $forwarder | Out-Null }
            $ou="OU=Demo,$($domain.DistinguishedName)"
            if (-not (Get-ADOrganizationalUnit -Filter "Name -eq 'Demo'" -SearchBase $domain.DistinguishedName -SearchScope OneLevel)) {
                New-ADOrganizationalUnit -Name Demo -Path $domain.DistinguishedName -ProtectedFromAccidentalDeletion $true
            }
            if (-not (Get-ADGroup -Filter "SamAccountName -eq 'DemoUsers'")) { New-ADGroup -Name DemoUsers -GroupScope Global -Path $ou }
            foreach ($number in 1..3) {
                $name='demo.user{0:d2}' -f $number
                if (-not (Get-ADUser -Filter "SamAccountName -eq '$name'")) {
                    # Users are disabled sample inventory objects, not shared-password logins.
                    New-ADUser -Name $name -SamAccountName $name -UserPrincipalName "$name@$($Config.DomainName)" -Path $ou -Enabled $false
                }
                if (-not @(Get-ADGroupMember DemoUsers | Where-Object SamAccountName -eq $name).Count) { Add-ADGroupMember DemoUsers $name }
            }
            $data=@{Directory='Ready';DemoUsers='Three disabled sample accounts'}
        }
        Join {
            $cs=Get-CimInstance Win32_ComputerSystem
            if ($cs.PartOfDomain) {
                if ($cs.Domain -ne $Config.DomainName) { throw 'Guest is already joined to a different domain.' }
                # A pending join marker survives connection loss before the reboot.
                $pending=Test-Path "$root\join-boot.txt"
                $sameBoot=$pending -and (Get-Content "$root\join-boot.txt" -Raw).Trim() -eq (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                $data=@{Reboot=$sameBoot}
            } else {
                Set-Content "$root\join-boot.txt" (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
                Add-Computer -DomainName $Config.DomainName -Credential $domainAdmin -ErrorAction Stop
                $data=@{Reboot=$true}
            }
        }
        VerifyDomain {
            $cs=Get-CimInstance Win32_ComputerSystem
            if (-not $cs.PartOfDomain -or $cs.Domain -ne $Config.DomainName -or -not (Test-ComputerSecureChannel)) { throw 'Domain membership/secure channel verification failed.' }
            $data=@{Domain='Verified'}
        }
        Workload {
            switch ($Spec.Role) {
                File {
                    $result=Install-WindowsFeature FS-FileServer
                    if (-not $result.Success) { throw 'File server feature installation failed.' }
                    $path="$root\Data"
                    New-Item -ItemType Directory -Path $path -Force | Out-Null
                    if (-not (Test-Path "$path\sample.txt")) { Set-Content "$path\sample.txt" 'Generic dependency discovery sample. No customer data.' }
                    $group="$($Config.DomainNetbios)\Domain Computers"
                    $acl=Get-Acl $path
                    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($group,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
                    ([IO.DirectoryInfo]$path).SetAccessControl($acl)
                    # Grant traversal/read on the private parent solely to the domain computers.
                    $parentAcl=Get-Acl $root
                    $parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($group,'ReadAndExecute','None','None','Allow')))
                    ([IO.DirectoryInfo]$root).SetAccessControl($parentAcl)
                    $share=Get-SmbShare -Name DemoData -ErrorAction SilentlyContinue
                    if ($share -and $share.Path -ne $path) { throw 'Conflicting SMB share; refusing to remove it.' }
                    if (-not $share) { New-SmbShare -Name DemoData -Path $path -ReadAccess $group -FullAccess "$($Config.DomainNetbios)\Domain Admins" | Out-Null }
                    Set-GuestPort @(445) 'HVLab-SMB'
                }
                App {
                    $result=Install-WindowsFeature Web-Server -IncludeManagementTools
                    if (-not $result.Success) { throw 'IIS installation failed.' }
                    Set-Content 'C:\inetpub\wwwroot\index.html' '<html><body>Generic Hyper-V dependency lab API backend</body></html>' -Encoding UTF8
                    Get-NetFirewallRule -Name 'IIS-WebServerRole-HTTP-In-TCP' -ErrorAction SilentlyContinue | Set-NetFirewallRule -RemoteAddress $subnet
                    Set-GuestPort @(80,9500) 'HVLab-Backends'
                    Set-GuestTask 'HVLab-Listener' 'listen 9500'
                    $until=(Get-Date).AddSeconds(60)
                    do {
                        if (Get-NetTCPConnection -LocalPort 9500 -State Listen -ErrorAction SilentlyContinue) { break }
                        Start-Sleep -Seconds 3
                    } while ((Get-Date) -lt $until)
                    if (-not (Get-NetTCPConnection -LocalPort 9500 -State Listen -ErrorAction SilentlyContinue)) { throw 'TCP listener failed to bind.' }
                    if ($Config.Sql.Enabled) { $reboot=Install-GuestSql }
                }
                Client {
                    $app="$($Config.GuestPrefix)-APP01.$($Config.DomainName)"
                    $fs="$($Config.GuestPrefix)-FS01.$($Config.DomainName)"
                    $arguments="client $app $fs"
                    if ($Config.Sql.Enabled) { $arguments+=" $app" }
                    Set-GuestTask 'HVLab-Traffic' $arguments
                    $until=(Get-Date).AddSeconds(120)
                    do {
                        if ((Get-GuestHealth).Health -eq 'Healthy') { break }
                        Start-Sleep -Seconds 5
                    } while ((Get-Date) -lt $until)
                    if ((Get-GuestHealth).Health -ne 'Healthy') { throw 'TCP/HTTP/SMB traffic has not become healthy.' }
                }
                Appliance {
                    if ((Get-FileHash "$root\AzureMigrateInstaller.zip" -Algorithm SHA256).Hash -ne $Config.Appliance.InstallerSha256) { throw 'Appliance installer transfer hash mismatch.' }
                    if (-not (Test-Path "$root\AzureMigrateInstaller\AzureMigrateInstaller.ps1")) {
                        Expand-Archive -LiteralPath "$root\AzureMigrateInstaller.zip" -DestinationPath "$root\AzureMigrateInstaller" -Force
                        $scripts=@(Get-ChildItem "$root\AzureMigrateInstaller" -Filter AzureMigrateInstaller.ps1 -File -Recurse)
                        if ($scripts.Count -ne 1) { throw 'Official archive has an unexpected installer layout.' }
                        if ($scripts[0].FullName -ne "$root\AzureMigrateInstaller\AzureMigrateInstaller.ps1") {
                            # Keep original archive layout; record the exact operator path.
                            Set-Content "$root\installer-path.txt" $scripts[0].FullName
                        } else { Set-Content "$root\installer-path.txt" $scripts[0].FullName }
                    }
                    $installer=(Get-Content "$root\installer-path.txt" -Raw).Trim()
                    $sig=Get-AuthenticodeSignature -LiteralPath $installer
                    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Microsoft appliance script signature verification failed.' }
                    @'
MANUAL HYPER-V APPLIANCE SETUP
Read docs\APPLIANCE.txt in the repository before proceeding.
Open the path in C:\HyperVLab\installer-path.txt in elevated Windows PowerShell.
Choose HYPER-V, your cloud and connectivity. Read/accept terms yourself.
Never choose Physical as a substitute for Hyper-V.
Create your Azure Migrate project/key in the portal and register interactively.
This installer is only staged; its setup and Azure registration are not verified.
'@ | Set-Content "$root\NEXT-STEPS.txt" -Encoding UTF8
                }
            }
            $data=@{Workload='Configured';Reboot=$reboot}
        }
        Validate { $data=Get-GuestHealth }
    }
    [pscustomobject]@{Marker='HVLAB_GUEST_RESULT';Success=$true;Data=$data}
} catch {
    # Do not serialize a guest ErrorRecord or credential-bearing InvocationInfo.
    [pscustomobject]@{Marker='HVLAB_GUEST_RESULT';Success=$false;Data=@{Action=$Action;ErrorType=$_.Exception.GetType().Name}}
}
