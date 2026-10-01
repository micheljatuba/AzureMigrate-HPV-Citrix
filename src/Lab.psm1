Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SecretValues = @()

function Protect-LabText {
    param([string]$Text)
    foreach ($value in $script:SecretValues) {
        if ($value) { $Text = $Text.Replace($value, '[REDACTED]') }
    }
    $Text = $Text -replace '(?i)(password|token|secret|sig)\s*[:=]\s*[^;\s]+', '$1=[REDACTED]'
    return $Text
}

function Assert-LabKeys {
    param([hashtable]$Value, [string[]]$Keys, [string]$Label)
    foreach ($key in $Value.Keys) {
        if ($key -notin $Keys) { throw "Unknown field in $Label. Only documented non-secret configuration fields are accepted." }
    }
    foreach ($key in $Keys) {
        if (-not $Value.ContainsKey($key)) { throw "Missing $Label.$key." }
    }
}

function Test-LabOfficialUri {
    param([string]$Value)
    $uri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return ($uri.Scheme -eq 'https' -and $uri.Port -eq 443 -and -not $uri.UserInfo -and
        -not $uri.Fragment -and $uri.DnsSafeHost -in @('go.microsoft.com','download.microsoft.com','software-download.microsoft.com','software-static.download.prss.microsoft.com') -and
        $uri.Query -notmatch '(?i)(sig|token|password|secret)=')
}

function Read-LabConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Configuration not found. Copy config.example.psd1 to config.local.psd1 and configure it.' }
    $c = Import-PowerShellDataFile -LiteralPath $Path
    Assert-LabConfig $c
    return $c
}

function Assert-LabConfig {
    param([hashtable]$c)
    Assert-LabKeys $c @('SchemaVersion','LabId','SubscriptionId','ResourceGroup','Prefix','Location','HostVmSize','AdminUsername','AllowedSourceIp','DataDiskSizeGB','ShutdownTime','ShutdownTimeZone','DomainName','DomainNetbios','GuestPrefix','NetworkPrefix','Iso','Sql','Appliance') 'Config'
    if ($c.SchemaVersion -ne 1) { throw 'Unsupported SchemaVersion.' }
    foreach ($name in @('LabId','SubscriptionId')) {
        $id = [guid]::Empty
        if (-not [guid]::TryParse($c[$name], [ref]$id) -or $id -eq [guid]::Empty) { throw "$name must be a nonzero GUID." }
    }
    if ($c.Prefix -cnotmatch '^[a-z][a-z0-9]{2,7}$') { throw 'Prefix must be 3-8 lowercase alphanumeric characters, starting with a letter.' }
    if ($c.ResourceGroup -notmatch '^rg-[a-z0-9-]{3,55}$') { throw 'ResourceGroup must start rg- and contain lowercase letters, digits and hyphens only.' }
    if ($c.Location -notmatch '^[a-z][a-z0-9]{2,30}$') { throw 'Location must be an Azure region name.' }
    if ($c.HostVmSize -notin @('Standard_E16ds_v5','Standard_E16ds_v6','Standard_D16s_v5')) { throw 'HostVmSize is not in the supported nested-virtualization allowlist.' }
    if ($c.AdminUsername -notmatch '^[a-z][a-z0-9]{3,18}$' -or $c.AdminUsername -in @('administrator','admin','guest','root','test','user','user1')) { throw 'Choose a nonreserved 4-19 character AdminUsername.' }
    $ip = $null
    if ($c.AllowedSourceIp -notmatch '^(\d{1,3}\.){3}\d{1,3}/32$' -or
        -not [net.ipaddress]::TryParse(($c.AllowedSourceIp -split '/')[0],[ref]$ip)) { throw 'AllowedSourceIp must be one explicit IPv4 /32, never a broad CIDR.' }
    $bytes = $ip.GetAddressBytes()
    if ($bytes[0] -in @(0,10,127) -or $bytes[0] -ge 224 -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
        ($bytes[0] -eq 169 -and $bytes[1] -eq 254)) { throw 'AllowedSourceIp must be the operator public IPv4 address.' }
    if ($c.NetworkPrefix -notmatch '^192\.168\.(\d{1,3})$' -or [int]$Matches[1] -gt 254) { throw 'NetworkPrefix must be 192.168.N, N between 0 and 254.' }
    if ($c.DomainName -notmatch '^[a-z][a-z0-9-]{1,30}\.test$') { throw 'Use an isolated lab domain ending .test.' }
    foreach ($name in @('DomainNetbios','GuestPrefix')) {
        if ($c[$name] -cnotmatch '^[A-Z][A-Z0-9]{2,7}$') { throw "$name must be 3-8 uppercase alphanumeric characters." }
    }
    if ($c.GuestPrefix.Length -gt 6) { throw 'GuestPrefix must be at most 6 characters so every Windows computer name fits the 15-character limit.' }
    if ($c.DataDiskSizeGB -isnot [int] -or $c.DataDiskSizeGB -lt 256 -or $c.DataDiskSizeGB -gt 4096) { throw 'DataDiskSizeGB must be an integer from 256 to 4096.' }
    if ($c.ShutdownTime -notmatch '^([01][0-9]|2[0-3])[0-5][0-9]$') { throw 'ShutdownTime must be HHmm, 0000-2359.' }
    try { [TimeZoneInfo]::FindSystemTimeZoneById($c.ShutdownTimeZone) | Out-Null } catch { throw 'Unknown ShutdownTimeZone.' }
    Assert-LabKeys $c.Iso @('Mode','Uri','HostPath','Sha256','ImageIndex','ImageName') 'Iso'
    if ($c.Iso.Mode -notin @('OfficialDownload','HostFile')) { throw 'Iso.Mode must be OfficialDownload or HostFile.' }
    if ($c.Iso.Mode -eq 'OfficialDownload' -and -not (Test-LabOfficialUri $c.Iso.Uri)) { throw 'ISO requires an approved official Microsoft HTTPS URL without credentials.' }
    if ($c.Iso.Mode -eq 'HostFile' -and $c.Iso.Uri) { throw 'Set Iso.Uri to empty for HostFile mode.' }
    if ($c.Iso.HostPath -notmatch '^[CL]:\\LabMedia\\[a-zA-Z0-9_.-]+\.iso$') { throw 'Iso.HostPath must be a simple ISO filename under C:\LabMedia or L:\LabMedia.' }
    if ($c.Iso.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $c.Iso.Sha256 -match '^0{64}$') { throw 'Iso.Sha256 must be an independently obtained 64-hex SHA256.' }
    if ($c.Iso.ImageIndex -isnot [int] -or $c.Iso.ImageIndex -lt 1 -or $c.Iso.ImageIndex -gt 20) { throw 'Iso.ImageIndex must be 1-20.' }
    if ($c.Iso.ImageName -notmatch '^Windows Server 2022 [A-Za-z0-9 ()-]{3,80}$') { throw 'Iso.ImageName must exactly identify your Windows Server 2022 Desktop Experience WIM edition.' }
    foreach ($name in @('Appliance','Sql')) {
        $component=$c[$name]
        Assert-LabKeys $component @('Enabled','InstallerUri','InstallerSha256') $name
        if ($component.Enabled -isnot [bool]) { throw "$name.Enabled must be a boolean." }
        if (($component.Enabled -or $component.InstallerUri) -and -not (Test-LabOfficialUri $component.InstallerUri)) { throw "$name requires an approved official installer URL without credentials." }
        if (($component.Enabled -or $component.InstallerSha256) -and ($component.InstallerSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $component.InstallerSha256 -match '^0{64}$')) { throw "$name requires an independently obtained SHA256." }
    }
}

function Get-LabHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function ConvertTo-LabCanonical {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object)) { $result[$key] = ConvertTo-LabCanonical $Value[$key] }
        return $result
    }
    return $Value
}

function Get-LabConfigHash { param([hashtable]$Config) Get-LabHash ((ConvertTo-LabCanonical $Config) | ConvertTo-Json -Depth 12 -Compress) }

function Get-LabPlan {
    param([hashtable]$Config)
    Assert-LabConfig $Config
    [pscustomobject]@{
        Action = 'Plan'; CloudAccess = 'None; no authentication, CLI install, downloads or resource changes'
        ResourceGroup = $Config.ResourceGroup; Host = "$($Config.Prefix)-hv01"
        Size = $Config.HostVmSize; Location = $Config.Location
        SecurityType = 'Standard'; DiskController = $(if ($Config.HostVmSize -match '_v6$') { 'NVMe' } else { 'SCSI' })
        DataDisk = "Premium_LRS $($Config.DataDiskSizeGB) GiB, LUN 0; never local temporary storage"
        Inbound = "RDP only from $($Config.AllowedSourceIp); appliance UI not published"
        Guests = @('DC01','FS01','APP01','CLIENT01') + $(if ($Config.Appliance.Enabled) { @('MIG01') } else { @() })
        Media = $Config.Iso.Mode
        MediaStaging = $(if ($Config.Iso.Mode -eq 'HostFile') { 'Operator stages the licensed ISO at HostPath; a new Azure host incurs cost while waiting' } else { 'Verified official download on host; no ISO bundled/uploaded from repository' })
        Sql = $(if ($Config.Sql.Enabled) { 'Real SQL Express on APP01; authenticated TDS connections' } else { 'Not installed; no fake SQL listener or SQL discovery claims' })
        Resume = 'SYSTEM startup task; successful step checkpoints; same config required'
        CloudPreflight = 'Not run: SKU, generation/controller, regional/family quota, ownership, agent and ARM what-if at Install'
        Cost = 'Billable host, disks, IP, network and optional Migrate services. Shutdown does not remove storage/IP charges.'
        Manual = 'Media license/hash; initial Azure sign-in; appliance Hyper-V selection/license/registration when enabled'
    }
}

function Invoke-LabNative {
    param([string]$File, [string[]]$Arguments)
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $File @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($code -ne 0) { throw "Native operation failed (exit $code). Output suppressed to protect credentials. Check authentication, permissions and the documented prerequisites." }
    return ($output | Out-String).Trim()
}

function Invoke-LabAz {
    param([string[]]$Arguments, [switch]$Raw)
    $text = Invoke-LabNative 'az' ($Arguments + @('--only-show-errors','--output','json'))
    if ($Raw) { return $text }
    if ($text) { return $text | ConvertFrom-Json }
}

function Protect-LabDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value,'S-1-5-18','S-1-5-32-544') | Select-Object -Unique) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            ([Security.Principal.SecurityIdentifier]$sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    # Persist only the modified DACL; Set-Acl may attempt SACL changes on
    # repeated calls and require SeSecurityPrivilege in a non-elevated shell.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path),$acl)
    } else { ([IO.DirectoryInfo]$Path).SetAccessControl($acl) }
}

function Initialize-LabDependencies {
    param([string]$Root,[switch]$AllowInstall)
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'Installation requires 64-bit Windows PowerShell 5.1 or PowerShell 7 on Windows.' }
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        if (-not $AllowInstall) { throw 'Azure CLI missing. Pass -AllowDependencyInstall to consent to the Microsoft-signed MSI installation.' }
        $work = Join-Path $Root '.runtime'
        Protect-LabDirectory $work
        $msi = Join-Path $work 'AzureCLI.msi'
        try {
            Invoke-WebRequest 'https://aka.ms/installazurecliwindowsx64' -OutFile $msi -UseBasicParsing
            $sig = Get-AuthenticodeSignature -LiteralPath $msi
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Azure CLI MSI signature verification failed.' }
            $p = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru -Verb RunAs
            if ($p.ExitCode -notin @(0,3010)) { throw 'Azure CLI MSI installation failed.' }
            $env:PATH = [Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [Environment]::GetEnvironmentVariable('PATH','User')
        } finally { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue }
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI installation completed but az is not available. Open a new terminal and rerun.' }
    }
    try { Invoke-LabNative az @('bicep','version','--only-show-errors') | Out-Null }
    catch {
        if (-not $AllowInstall) { throw 'Bicep CLI missing. Pass -AllowDependencyInstall to authorize the Azure CLI-managed official Bicep installation.' }
        Invoke-LabNative az @('bicep','install','--only-show-errors') | Out-Null
        $azConfig = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path $HOME '.azure' }
        $bicep = Join-Path $azConfig 'bin\bicep.exe'
        if (-not (Test-Path $bicep)) { throw 'Azure CLI did not install Bicep at its documented location.' }
        $sig=Get-AuthenticodeSignature -LiteralPath $bicep
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'Downloaded Bicep executable signature verification failed.' }
        Invoke-LabNative az @('bicep','version','--only-show-errors') | Out-Null
    }
}

function Assert-LabOwner {
    param($Resource,[hashtable]$Config,[switch]$CheckHash)
    if (-not $Resource -or -not $Resource.PSObject.Properties['tags'] -or
        -not $Resource.tags -or -not $Resource.tags.PSObject.Properties['labId'] -or
        $Resource.tags.labId -ne $Config.LabId -or
        -not $Resource.tags.PSObject.Properties['managedBy'] -or
        $Resource.tags.managedBy -ne 'hyperv-discovery-lab') { throw 'Ownership mismatch. Refusing to adopt or modify an unrelated resource.' }
    if ($CheckHash -and (-not $Resource.tags.PSObject.Properties['configHash'] -or
        $Resource.tags.configHash -ne (Get-LabConfigHash $Config))) { throw 'Configuration changed since provisioning. Restore the original private config; automatic migration/destructive reconciliation is not supported.' }
}

function Get-LabOwnedHost {
    param([hashtable]$Config)
    $common = @('--subscription',$Config.SubscriptionId)
    $exists = Invoke-LabAz (@('group','exists','--name',$Config.ResourceGroup) + $common)
    if (-not $exists) { return $null }
    $rg = Invoke-LabAz (@('group','show','--name',$Config.ResourceGroup) + $common)
    Assert-LabOwner $rg $Config -CheckHash
    $resources = @(Invoke-LabAz (@('resource','list','--resource-group',$Config.ResourceGroup) + $common))
    $expected = @("$($Config.Prefix)-nsg","$($Config.Prefix)-vnet","$($Config.Prefix)-pip","$($Config.Prefix)-nic",
        "$($Config.Prefix)-hv01","$($Config.Prefix)-hv01-data","$($Config.Prefix)-hv01-os","shutdown-computevm-$($Config.Prefix)-hv01")
    foreach ($resource in $resources) {
        # OS disks inherit no tags from VM creation, so verify their managedBy VM ID.
        if ($resource.name -eq "$($Config.Prefix)-hv01-os" -and $resource.type -eq 'Microsoft.Compute/disks') {
            $d = Invoke-LabAz (@('disk','show','--ids',$resource.id) + $common)
            $vmId = "/subscriptions/$($Config.SubscriptionId)/resourceGroups/$($Config.ResourceGroup)/providers/Microsoft.Compute/virtualMachines/$($Config.Prefix)-hv01"
            if ($d.managedBy -ne $vmId) { throw 'OS disk ownership mismatch.' }
        } else { Assert-LabOwner $resource $Config -CheckHash }
        if ($resource.name -notin $expected) { throw 'Unexpected resource in the lab group. Refusing deployment.' }
    }
    if (-not ($resources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' -and $_.name -eq "$($Config.Prefix)-hv01" })) { return $null }
    $vm = Invoke-LabAz (@('vm','show','-g',$Config.ResourceGroup,'-n',"$($Config.Prefix)-hv01") + $common)
    Assert-LabOwner $vm $Config -CheckHash
    if ($vm.hardwareProfile.vmSize -ne $Config.HostVmSize -or $vm.storageProfile.dataDisks.Count -ne 1 -or
        $vm.storageProfile.dataDisks[0].lun -ne 0 -or $vm.storageProfile.dataDisks[0].managedDisk.id -notlike "*/$($Config.Prefix)-hv01-data") { throw 'Host hardware/disk layout drift detected.' }
    $controller = if ($Config.HostVmSize -match '_v6$') { 'NVMe' } else { 'SCSI' }
    if ($vm.storageProfile.diskControllerType -ne $controller) { throw 'Host disk controller drift detected.' }
    if ($vm.PSObject.Properties['securityProfile'] -and $vm.securityProfile -and
        $vm.securityProfile.PSObject.Properties['securityType'] -and $vm.securityProfile.securityType -and
        $vm.securityProfile.securityType -ne 'Standard') { throw 'Host no longer uses Standard security required by this nested lab.' }
    return $vm
}

function Assert-LabHostReady {
    param([hashtable]$Config,[int]$TimeoutSeconds = 0)
    $until = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $view = Invoke-LabAz @('vm','get-instance-view','--subscription',$Config.SubscriptionId,'-g',$Config.ResourceGroup,'-n',"$($Config.Prefix)-hv01")
        $power = @($view.statuses | Where-Object { $_.code -like 'PowerState/*' } | ForEach-Object { $_.code })
        $agentReady = $view.PSObject.Properties['vmAgent'] -and $view.vmAgent -and
            @($view.vmAgent.statuses | Where-Object { $_.code -eq 'ProvisioningState/succeeded' }).Count -gt 0
        if ($power -contains 'PowerState/running' -and $agentReady) { return }
        if ((Get-Date) -ge $until) { throw 'Owned host is not running with a ready VM agent. No automatic start/deallocate is performed; check this host in Azure and rerun.' }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Assert-LabCloudPreflight {
    param([hashtable]$Config,[switch]$ExistingHost)
    $account = Invoke-LabAz @('account','show','--subscription',$Config.SubscriptionId)
    if ($account.id -ne $Config.SubscriptionId -or $account.state -ne 'Enabled') { throw 'The configured subscription is not enabled/accessible.' }
    if ($account.environmentName -ne 'AzureCloud') { throw 'This package supports Azure public cloud only.' }
    $sku = @(Invoke-LabAz @('vm','list-skus','--subscription',$Config.SubscriptionId,'--location',$Config.Location,'--size',$Config.HostVmSize,'--all') | Where-Object { $_.name -eq $Config.HostVmSize -and $_.resourceType -eq 'virtualMachines' })
    if ($sku.Count -ne 1 -or @($sku[0].restrictions | Where-Object { $_.type -eq 'Location' }).Count) { throw 'VM SKU unavailable/restricted in the selected region/subscription.' }
    $caps = @{}
    foreach ($cap in $sku[0].capabilities) { $caps[$cap.name] = $cap.value }
    if ($caps['HyperVGenerations'] -notmatch 'V2' -or $caps['PremiumIO'] -ne 'True' -or [int]$caps['vCPUs'] -lt 16 -or [double]$caps['MemoryGB'] -lt 64) { throw 'SKU capabilities do not meet generation, storage, CPU or RAM requirements.' }
    if ($caps.ContainsKey('NestedVirtualization') -and $caps['NestedVirtualization'] -eq 'False') { throw 'Azure reports no nested virtualization support.' }
    $controller = if ($Config.HostVmSize -match '_v6$') { 'NVMe' } else { 'SCSI' }
    if ($caps.ContainsKey('DiskControllerTypes') -and $caps['DiskControllerTypes'] -notmatch $controller) { throw 'SKU disk controller mismatch.' }
    $image = Invoke-LabAz @('vm','image','show','--subscription',$Config.SubscriptionId,'--location',$Config.Location,'--urn','MicrosoftWindowsServer:WindowsServer:2022-datacenter-g2:latest')
    if ($image.hyperVGeneration -ne 'V2') { throw 'Marketplace image is not generation 2.' }
    if ($controller -eq 'NVMe' -and -not @($image.features | Where-Object { $_.name -eq 'DiskControllerTypes' -and $_.value -match 'NVMe' }).Count) { throw 'Marketplace image does not advertise NVMe support.' }
    $usage = @(Invoke-LabAz @('vm','list-usage','--subscription',$Config.SubscriptionId,'--location',$Config.Location))
    foreach ($name in @('cores',$sku[0].family)) {
        $q = @($usage | Where-Object { $_.name.value -eq $name })
        if ($q.Count -ne 1) { throw 'Could not resolve regional/family quota. Check quota in Azure before spending.' }
        $needed = if ($ExistingHost) { 0 } else { [int]$caps['vCPUs'] }
        Write-Host ("Quota {0}: {1}/{2}; additional required {3}" -f $name,$q[0].currentValue,$q[0].limit,$needed)
        if ($q[0].limit - $q[0].currentValue -lt $needed) { throw 'Insufficient regional/family vCPU quota.' }
    }
}

function Invoke-LabHostCommand {
    param([hashtable]$Config,[string]$Root,[string]$Script)
    Assert-LabHostReady $Config
    $path = Join-Path $Root '.runtime\command.ps1'
    $wrapped = "`$ErrorActionPreference='Stop'`ntry {`n$Script`nWrite-Output 'HVLAB_COMMAND_OK'`n} catch { Write-Output 'HVLAB_COMMAND_FAILED'; exit 1 }"
    [IO.File]::WriteAllText($path,$wrapped,[Text.Encoding]::UTF8)
    try {
        $r = Invoke-LabAz @('vm','run-command','invoke','--subscription',$Config.SubscriptionId,'-g',$Config.ResourceGroup,'-n',"$($Config.Prefix)-hv01",'--command-id','RunPowerShellScript','--scripts',"@$path")
        $stdout = (@($r.value | Where-Object { $_.code -match 'StdOut' } | ForEach-Object { $_.message }) -join "`n")
        if ($stdout -notmatch 'HVLAB_COMMAND_OK' -or $stdout -match 'HVLAB_COMMAND_FAILED') { throw 'Host command failed or returned no success sentinel; step not checkpointed.' }
        return ($stdout -replace 'HVLAB_COMMAND_OK','').Trim()
    } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

function Get-LabPayload {
    param([string]$Root,[hashtable]$Config)
    # Fixed allowlist: private config, state, credentials and repository history cannot enter.
    $files = [ordered]@{}
    foreach ($relative in @('host\Runner.ps1','host\Engine.psm1','host\Guest.ps1','workloads\DependencyDemo.cs')) {
        $files[$relative] = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $Root $relative)))
    }
    Assert-LabConfig $Config
    [ordered]@{ Files = $files; Config = (ConvertTo-LabCanonical $Config); ConfigHash = (Get-LabConfigHash $Config) } | ConvertTo-Json -Depth 12 -Compress
}

function Send-LabPayload {
    param([hashtable]$Config,[string]$Root)
    $payload = Get-LabPayload $Root $Config
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms,[IO.Compression.CompressionMode]::Compress,$true)
    $gz.Write($bytes,0,$bytes.Length); $gz.Dispose()
    $data = [Convert]::ToBase64String($ms.ToArray()); $ms.Dispose()
    $remote = "C:\ProgramData\HyperVLab\$($Config.LabId)"
    $hash = Get-LabHash $payload
    $init = @"
`$root='$remote'
if(Test-Path "`$root\host\Runner.ps1") {
  `$task=Get-ScheduledTask -TaskName 'HyperVLab-$($Config.LabId)' -ErrorAction SilentlyContinue
  if(`$task -and `$task.State -eq 'Running') { throw 'Installer already running' }
}
New-Item -ItemType Directory -Path `$root -Force | Out-Null
`$acl=Get-Acl -LiteralPath `$root
`$acl.SetAccessRuleProtection(`$true,`$false)
foreach(`$rule in @(`$acl.Access)) { `$acl.RemoveAccessRuleSpecific(`$rule) }
foreach(`$sid in @('S-1-5-18','S-1-5-32-544')) {
 `$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(([Security.Principal.SecurityIdentifier]`$sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
}
([IO.DirectoryInfo]`$root).SetAccessControl(`$acl)
[IO.File]::WriteAllText("`$root\transfer.txt",'')
"@
    Invoke-LabHostCommand $Config $Root $init | Out-Null
    for ($i = 0; $i -lt $data.Length; $i += 20000) {
        $chunk = $data.Substring($i,[Math]::Min(20000,$data.Length-$i))
        Invoke-LabHostCommand $Config $Root "[IO.File]::AppendAllText('$remote\transfer.txt','$chunk')" | Out-Null
    }
    $extract = @"
`$root='$remote'
`$ms=New-Object IO.MemoryStream(,[Convert]::FromBase64String([IO.File]::ReadAllText("`$root\transfer.txt")))
`$gz=New-Object IO.Compression.GZipStream(`$ms,[IO.Compression.CompressionMode]::Decompress)
`$reader=New-Object IO.StreamReader(`$gz)
`$text=`$reader.ReadToEnd(); `$reader.Dispose(); `$ms.Dispose()
`$sha=[Security.Cryptography.SHA256]::Create()
`$got=([BitConverter]::ToString(`$sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(`$text)))).Replace('-','').ToLowerInvariant()
`$sha.Dispose()
if(`$got -ne '$hash') { throw 'Transfer hash mismatch' }
`$package=`$text | ConvertFrom-Json
if(Test-Path "`$root\config.json") {
 if((Get-Content "`$root\config-hash.txt" -Raw).Trim() -ne `$package.ConfigHash) { throw 'Configuration drift' }
}
foreach(`$file in `$package.Files.PSObject.Properties) {
 if(`$file.Name -notin @('host\Runner.ps1','host\Engine.psm1','host\Guest.ps1','workloads\DependencyDemo.cs')) { throw 'Invalid package member' }
 `$dest=Join-Path `$root `$file.Name
 New-Item -ItemType Directory -Path (Split-Path `$dest) -Force | Out-Null
 [IO.File]::WriteAllBytes(`$dest,[Convert]::FromBase64String(`$file.Value))
}
`$package.Config | ConvertTo-Json -Depth 12 | Set-Content "`$root\config.json" -Encoding UTF8
Set-Content "`$root\config-hash.txt" `$package.ConfigHash
Remove-Item "`$root\transfer.txt" -Force
`$cert=Get-ChildItem Cert:\LocalMachine\My | Where-Object Subject -eq 'CN=HyperVLab-$($Config.LabId)' | Select-Object -First 1
if(-not `$cert) { `$cert=New-SelfSignedCertificate -Subject 'CN=HyperVLab-$($Config.LabId)' -CertStoreLocation Cert:\LocalMachine\My -KeyLength 3072 -KeyExportPolicy NonExportable -KeySpec KeyExchange -HashAlgorithm SHA256 }
`$rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey(`$cert)
`$p=`$rsa.ExportParameters(`$false)
@{Modulus=[Convert]::ToBase64String(`$p.Modulus);Exponent=[Convert]::ToBase64String(`$p.Exponent);Thumbprint=`$cert.Thumbprint} | ConvertTo-Json -Compress
`$rsa.Dispose()
"@
    return (Invoke-LabHostCommand $Config $Root $extract | ConvertFrom-Json)
}

function ConvertFrom-LabSecure {
    param([securestring]$Secret)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try { $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr); $script:SecretValues += $value; return $value }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Assert-LabPassword {
    param([string]$Value,[string]$Username)
    if ($Value.Length -lt 14 -or $Value.Length -gt 100 -or $Value -notmatch '[A-Z]' -or $Value -notmatch '[a-z]' -or
        $Value -notmatch '[0-9]' -or $Value -notmatch '[^a-zA-Z0-9]' -or $Value -match '[\x00-\x1f]' -or
        $Value.IndexOf($Username,[StringComparison]::OrdinalIgnoreCase) -ge 0) { throw 'Password must be 14-100 characters with upper/lowercase, digit and symbol, no control characters or username.' }
}

function Invoke-LabInstall {
    param([hashtable]$Config,[string]$Root,[switch]$AllowDependencyInstall,[switch]$Login,[securestring]$HostPassword,[securestring]$GuestPassword)
    Initialize-LabDependencies $Root -AllowInstall:$AllowDependencyInstall
    Protect-LabDirectory (Join-Path $Root '.runtime')
    $lock = $null
    $parameterPath = Join-Path $Root '.runtime\parameters.json'
    try {
        $lock = [IO.File]::Open((Join-Path $Root '.runtime\install.lock'),'OpenOrCreate','ReadWrite','None')
        # Static build precedes authentication and any spend.
        $template = Join-Path $Root '.runtime\main.bicep.json'
        Invoke-LabNative az @('bicep','build','--file',(Join-Path $Root 'infra\main.bicep'),'--outfile',$template,'--only-show-errors') | Out-Null
        if ($Login) { Invoke-LabNative az @('login','--output','none','--only-show-errors') | Out-Null }
        $existing = Get-LabOwnedHost $Config
        Assert-LabCloudPreflight $Config -ExistingHost:([bool]$existing)
        if ($existing) { Assert-LabHostReady $Config }
        if ($Config.Iso.Mode -eq 'HostFile') { Write-Host 'HostFile mode: stage the verified ISO at the configured path on this owned host. A new host incurs cost while awaiting media.' }
        if ($Config.Iso.Mode -eq 'OfficialDownload') {
            # Read-only availability probe; host verifies full content hash before use.
            try { Invoke-WebRequest $Config.Iso.Uri -Method Head -UseBasicParsing -TimeoutSec 60 | Out-Null }
            catch { throw 'Official ISO URL is unavailable. Resolve URL/hash before provisioning.' }
        }
        foreach ($component in @($Config.Sql,$Config.Appliance)) {
            if ($component.Enabled) {
                try { Invoke-WebRequest $component.InstallerUri -Method Head -UseBasicParsing -TimeoutSec 60 | Out-Null }
                catch { throw 'Optional component installer URL is unavailable. Resolve URL/hash before provisioning.' }
            }
        }
        if (-not $GuestPassword) { $GuestPassword = Read-Host 'Nested guests/domain administrator password (store securely for recovery)' -AsSecureString }
        $guestPlain = ConvertFrom-LabSecure $GuestPassword
        Assert-LabPassword $guestPlain 'Administrator'
        if (-not $existing) {
            if (-not $HostPassword) { $HostPassword = Read-Host 'Azure host administrator password (different from guest password)' -AsSecureString }
            $hostPlain = ConvertFrom-LabSecure $HostPassword
            Assert-LabPassword $hostPlain $Config.AdminUsername
            if ($hostPlain -eq $guestPlain) { throw 'Host and guest passwords must differ.' }
            $values = @{
                resourceGroupName=$Config.ResourceGroup;location=$Config.Location;labId=$Config.LabId;configHash=(Get-LabConfigHash $Config)
                prefix=$Config.Prefix;hostVmSize=$Config.HostVmSize;adminUsername=$Config.AdminUsername;adminPassword=$hostPlain
                allowedSourceIp=$Config.AllowedSourceIp;dataDiskSizeGB=$Config.DataDiskSizeGB;shutdownTime=$Config.ShutdownTime;shutdownTimeZone=$Config.ShutdownTimeZone
            }
            $parameters = @{}
            foreach ($key in $values.Keys) { $parameters[$key] = @{ value=$values[$key] } }
            @{ '$schema'='https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#';contentVersion='1.0.0.0';parameters=$parameters } |
                ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $parameterPath -Encoding UTF8
            $args = @('--subscription',$Config.SubscriptionId,'--location',$Config.Location,'--name',"hvlab-$($Config.LabId)",'--template-file',$template,'--parameters',"@$parameterPath")
            Invoke-LabAz (@('deployment','sub','validate') + $args) | Out-Null
            $preview = Invoke-LabAz (@('deployment','sub','what-if','--no-pretty-print') + $args)
            foreach ($change in @($preview.changes)) {
                if ($change.changeType -notin @('Create','NoChange','Ignore')) { throw 'What-if proposes modifying/deleting existing resources. Refusing installation.' }
                Write-Host ("What-if: {0} {1}" -f $change.changeType,$change.resourceId)
            }
            # Recheck ownership immediately before creation.
            Get-LabOwnedHost $Config | Out-Null
            Invoke-LabAz (@('deployment','sub','create') + $args) | Out-Null
            $existing = Get-LabOwnedHost $Config
            if (-not $existing) { throw 'Deployment returned but the owned host is missing.' }
        }
        Remove-Item -LiteralPath $parameterPath -Force -ErrorAction SilentlyContinue
        Assert-LabHostReady $Config -TimeoutSeconds 900
        $public = Send-LabPayload $Config $Root
        # RSACryptoServiceProvider on Windows PowerShell cannot use OAEP-SHA256.
        $rsa = New-Object Security.Cryptography.RSACng
        try {
            $p = New-Object Security.Cryptography.RSAParameters
            $p.Modulus=[Convert]::FromBase64String($public.Modulus); $p.Exponent=[Convert]::FromBase64String($public.Exponent)
            $rsa.ImportParameters($p)
            $encrypted = [Convert]::ToBase64String($rsa.Encrypt([Text.Encoding]::UTF8.GetBytes($guestPlain),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
        } finally { $rsa.Dispose() }
        $remote = "C:\ProgramData\HyperVLab\$($Config.LabId)"
        $launch = @"
`$root='$remote'
`$cert=Get-Item 'Cert:\LocalMachine\My\$($public.Thumbprint)'
`$rsa=[Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(`$cert)
`$plain=[Text.Encoding]::UTF8.GetString(`$rsa.Decrypt([Convert]::FromBase64String('$encrypted'),[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256))
`$rsa.Dispose()
if(Test-Path "`$root\credential.clixml") {
 `$saved=Import-Clixml "`$root\credential.clixml"
 if(`$saved.GetNetworkCredential().Password -cne `$plain) { throw 'Guest credential differs from original installation' }
} else {
 (New-Object Management.Automation.PSCredential('Administrator',(ConvertTo-SecureString `$plain -AsPlainText -Force))) | Export-Clixml "`$root\credential.clixml"
}
`$plain=`$null
`$name='HyperVLab-$($Config.LabId)'
`$task=Get-ScheduledTask -TaskName `$name -ErrorAction SilentlyContinue
if(`$task -and `$task.State -eq 'Running') { throw 'Already running' }
# Format on the host so quotes survive the outer expandable here-string.
`$taskArguments='-NoProfile -ExecutionPolicy Bypass -File "{0}\host\Runner.ps1" -Action Install' -f `$root
`$action=New-ScheduledTaskAction -Execute "`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument `$taskArguments -WorkingDirectory `$root
`$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
`$settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 8) -StartWhenAvailable
Register-ScheduledTask -TaskName `$name -Action `$action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Principal `$principal -Settings `$settings -Force | Out-Null
Start-ScheduledTask -TaskName `$name
Write-Output 'Host installation scheduled; run Status -GuestChecks -Approve for durable step state.'
"@
        Invoke-LabHostCommand $Config $Root $launch
    } finally {
        Remove-Item -LiteralPath $parameterPath -Force -ErrorAction SilentlyContinue
        if ($lock) { $lock.Dispose() }
        $script:SecretValues = @()
        $guestPlain=$null; $hostPlain=$null
    }
}

function Get-LabStatus {
    param([hashtable]$Config,[string]$Root,[switch]$GuestChecks,[switch]$RequireHealthy)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI required for cloud Status. Use Validate without -Online for offline tests.' }
    $vm = Get-LabOwnedHost $Config
    if (-not $vm) { throw 'No owned Azure host found.' }
    $view = Invoke-LabAz @('vm','get-instance-view','--subscription',$Config.SubscriptionId,'-g',$Config.ResourceGroup,'-n',"$($Config.Prefix)-hv01")
    $power = @($view.statuses | Where-Object { $_.code -like 'PowerState/*' } | ForEach-Object { $_.code })
    [pscustomobject]@{ Host=$vm.name; Power=$power -join ','; GuestHealth='Unknown unless -GuestChecks is requested'; CloudMutation='None in default Status' }
    if (-not $GuestChecks) {
        if ($RequireHealthy) { throw 'Guest health unverified. Add -GuestChecks -Approve for the read-only guest probe via Run Command.' }
        return
    }
    Protect-LabDirectory (Join-Path $Root '.runtime')
    $remote = "C:\ProgramData\HyperVLab\$($Config.LabId)"
    $json = Invoke-LabHostCommand $Config $Root @"
if(-not (Test-Path '$remote\host\Runner.ps1')) { throw 'Host package is not installed' }
& '$remote\host\Runner.ps1' -Action Status
if(-not `$?) { throw 'Probe failed' }
"@
    $status = $json | ConvertFrom-Json
    $status | ConvertTo-Json -Depth 12
    if ($RequireHealthy -and $status.Health -ne 'Healthy') { throw 'Guest validation is incomplete or unhealthy; inspect the returned checks.' }
}

Export-ModuleMember -Function *
