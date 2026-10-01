Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-HVContext {
    param([string]$Root)
    $script:Root = $Root
    $script:C = Get-Content -LiteralPath (Join-Path $Root 'config.json') -Raw | ConvertFrom-Json
    $script:ConfigHash = (Get-Content -LiteralPath (Join-Path $Root 'config-hash.txt') -Raw).Trim()
    $script:Data = "L:\HyperVLab\$($script:C.LabId)"
    $script:Switch = "HVLab-$($script:C.Prefix)"
    $script:Subnet = "$($script:C.NetworkPrefix).0/24"
    $script:Gateway = "$($script:C.NetworkPrefix).1"
    $script:StatePath = Join-Path $Root 'state.json'
    if (Test-Path -LiteralPath $script:StatePath) {
        $script:State = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        if ($script:State.ConfigHash -ne $script:ConfigHash) { throw 'Host checkpoint configuration mismatch.' }
    } else {
        $script:State = [pscustomobject]@{
            ConfigHash=$script:ConfigHash; Status='NotStarted'; Step='None'; Completed=@()
            UpdatedUtc=[DateTime]::UtcNow.ToString('o'); ErrorType=$null; ErrorCode=$null; DiskUniqueId=$null; RebootBootTime=$null
        }
    }
}

function Save-HVState {
    $script:State.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    $next = "$($script:StatePath).next"
    $script:State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $next -Encoding UTF8
    Move-Item -LiteralPath $next -Destination $script:StatePath -Force
}

function Write-HVEvent {
    param([string]$Step,[string]$Result)
    @{ Utc=[DateTime]::UtcNow.ToString('o'); Step=$Step; Result=$Result } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $script:Root 'events.jsonl') -Encoding UTF8
}

function Invoke-HVStep {
    param([string]$Name,[scriptblock]$Body)
    if ($script:State.Completed -contains $Name) { return }
    $script:State.Status='Running'; $script:State.Step=$Name; $script:State.ErrorType=$null; $script:State.ErrorCode=$null
    Save-HVState; Write-HVEvent $Name 'Started'
    try {
        & $Body | Out-Null
        $script:State.Completed=@($script:State.Completed) + $Name
        Save-HVState; Write-HVEvent $Name 'Succeeded'
    } catch {
        $script:State.Status=if ($_.Exception.Data['SafeCode'] -eq 'AwaitingMedia') { 'AwaitingMedia' } else { 'Failed' }
        $script:State.ErrorType=$_.Exception.GetType().Name
        $script:State.ErrorCode=$_.Exception.Data['SafeCode']
        Save-HVState; Write-HVEvent $Name 'Failed'
        throw
    }
}

function Invoke-HVNative {
    param([string]$File,[string[]]$Arguments)
    $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
    try { & $File @Arguments 2>&1 | Out-Null; $code=$LASTEXITCODE }
    finally { $ErrorActionPreference=$old }
    if ($code -ne 0) {
        $error=New-Object InvalidOperationException("Native command failed with exit $code.")
        $error.Data['SafeCode']="NativeExit:$code"
        throw $error
    }
}

function Set-HVPrivateDirectory {
    param([string]$Path)
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl=Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            ([Security.Principal.SecurityIdentifier]$sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    ([IO.DirectoryInfo]$Path).SetAccessControl($acl)
}

function Select-HVDataDisk {
    param([object[]]$Disks,[object[]]$Drives,[int]$SizeGB,[string]$Controller)
    $lun = if ($Controller -eq 'NVMe') { 1 } else { 0 }
    $candidates = @(
        foreach ($drive in $Drives) {
            if ($drive.SCSILogicalUnit -ne $lun) { continue }
            if ($Controller -eq 'NVMe' -and $drive.Model -notmatch '^Virtual_Disk NVMe Premium') { continue }
            if ($Controller -eq 'SCSI' -and $drive.Model -notmatch '(Virtual Disk|Virtual_Disk)') { continue }
            $Disks | Where-Object {
                $_.Number -eq $drive.Index -and -not $_.IsBoot -and -not $_.IsSystem -and
                [math]::Abs([double]$_.Size - ($SizeGB * 1GB)) -lt 1MB
            }
        }
    )
    if ($candidates.Count -ne 1) { throw 'Data disk identification is ambiguous. No disk will be initialized. Verify managed LUN 0, model/controller and exact configured size.' }
    return $candidates[0]
}

function Initialize-HVDisk {
    $metadata = Invoke-RestMethod -Headers @{ Metadata='true' } -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' -TimeoutSec 15
    if ($metadata.compute.name -ne "$($script:C.Prefix)-hv01" -or $metadata.compute.subscriptionId -ne $script:C.SubscriptionId -or
        $metadata.compute.resourceGroupName -ne $script:C.ResourceGroup -or
        -not @($metadata.compute.tagsList | Where-Object { $_.name -eq 'labId' -and $_.value -eq $script:C.LabId }).Count) { throw 'Host identity/ownership mismatch.' }
    $attached = @($metadata.compute.storageProfile.dataDisks)
    if ($attached.Count -ne 1 -or [int]$attached[0].lun -ne 0 -or [int]$attached[0].diskSizeGB -ne $script:C.DataDiskSizeGB) { throw 'Unexpected managed data disk layout.' }
    $controller = if ($script:C.HostVmSize -match '_v6$') { 'NVMe' } else { 'SCSI' }
    $disk = Select-HVDataDisk @(Get-Disk) @(Get-CimInstance Win32_DiskDrive) $script:C.DataDiskSizeGB $controller
    if ($script:State.DiskUniqueId -and $script:State.DiskUniqueId -ne $disk.UniqueId) { throw 'Data disk identity changed since checkpoint.' }
    $existingL = Get-Partition -DriveLetter L -ErrorAction SilentlyContinue
    $label = 'HVLAB-' + $script:C.LabId.Substring(0,8)
    if ($existingL) {
        if ($existingL.DiskNumber -ne $disk.Number) { throw 'L: is not the owned lab data disk.' }
        $volume=Get-Volume -DriveLetter L
        if ($script:State.DiskUniqueId -eq $disk.UniqueId -and ($volume.FileSystemType -in @('Unknown','RAW') -or -not $volume.FileSystem)) {
            Format-Volume -DriveLetter L -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel $label -Confirm:$false | Out-Null
        } elseif ($volume.FileSystemLabel -ne $label) { throw 'L: is not the owned lab data volume.' }
    } else {
        if (-not $script:State.DiskUniqueId -and $disk.PartitionStyle -ne 'RAW') { throw 'Refusing an already initialized, unowned data disk.' }
        $script:State.DiskUniqueId=$disk.UniqueId; Save-HVState
        if ($disk.IsOffline) { Set-Disk -Number $disk.Number -IsOffline $false }
        if ($disk.IsReadOnly) { throw 'Owned data disk is read-only; inspect before proceeding.' }
        if ($disk.PartitionStyle -eq 'RAW') { Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null }
        $parts=@(Get-Partition -DiskNumber $disk.Number | Where-Object { $_.Type -eq 'Basic' })
        if ($parts.Count -gt 1) { throw 'Unexpected partitions on the owned data disk.' }
        if ($parts.Count -eq 0) { $part=New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter L }
        else {
            $part=$parts[0]
            if ($part.DriveLetter -and $part.DriveLetter -ne 'L') { throw 'Owned partition has an unexpected drive letter.' }
            $part | Set-Partition -NewDriveLetter L
        }
        $volume=Get-Volume -DriveLetter L
        if ($volume.FileSystemType -in @('Unknown','RAW') -or -not $volume.FileSystem) {
            Format-Volume -DriveLetter L -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel $label -Confirm:$false | Out-Null
        } elseif ($volume.FileSystemLabel -ne $label) { throw 'Refusing to format a data volume containing an unexpected filesystem.' }
    }
    $script:State.DiskUniqueId=$disk.UniqueId
    Set-HVPrivateDirectory $script:Data
    foreach ($folder in @('Media','Base','VMs','Build','Mount')) {
        New-Item -ItemType Directory -Path (Join-Path $script:Data $folder) -Force | Out-Null
    }
}

function Initialize-HVNetwork {
    $switch = Get-VMSwitch -Name $script:Switch -ErrorAction SilentlyContinue
    if ($switch -and $switch.SwitchType -ne 'Internal') { throw 'Existing switch is not an internal lab switch.' }
    if (-not $switch) { New-VMSwitch -Name $script:Switch -SwitchType Internal | Out-Null }
    $adapter=Get-NetAdapter -Name "vEthernet ($($script:Switch))"
    $ips=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 | Where-Object { $_.PrefixOrigin -ne 'WellKnown' -and $_.IPAddress -notlike '169.254.*' })
    if ($ips.Count -and -not @($ips | Where-Object { $_.IPAddress -eq $script:Gateway -and $_.PrefixLength -eq 24 }).Count) { throw 'Unexpected switch gateway; refusing to remove addresses.' }
    if (-not @($ips | Where-Object { $_.IPAddress -eq $script:Gateway }).Count) {
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $script:Gateway -PrefixLength 24 | Out-Null
    }
    $nats=@(Get-NetNat)
    $nat=$nats | Where-Object { $_.Name -eq $script:Switch }
    if ($nat -and $nat.InternalIPInterfaceAddressPrefix -ne $script:Subnet) { throw 'Owned NAT has unexpected prefix.' }
    if (-not $nat) {
        if ($nats.Count) { throw 'Another NAT exists. WinNAT sharing is not automatically reconciled.' }
        New-NetNat -Name $script:Switch -InternalIPInterfaceAddressPrefix $script:Subnet | Out-Null
    }
    # Host RDP is restricted in Windows Firewall AND Azure NSG.
    Get-NetFirewallRule -Name 'RemoteDesktop*' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
    if (-not (Get-NetFirewallRule -Name 'HVLab-OperatorRdp' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'HVLab-OperatorRdp' -DisplayName 'HVLab operator RDP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress $script:C.AllowedSourceIp | Out-Null
    }
    # Remoting remains confined to the nested subnet, with no public NSG opening.
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue |
        Set-NetFirewallRule -RemoteAddress $script:Subnet
    if ($script:C.Appliance.Enabled) {
        foreach ($sid in @('S-1-5-32-578','S-1-5-32-580','S-1-5-32-558')) {
            $group = Get-LocalGroup -SID $sid
            if (-not @(Get-LocalGroupMember -Group $group | Where-Object { $_.Name -eq "$env:COMPUTERNAME\$($script:C.AdminUsername)" }).Count) {
                Add-LocalGroupMember -Group $group -Member $script:C.AdminUsername
            }
        }
    }
}

function Receive-HVOfficialFile {
    param([string]$Uri,[string]$Path,[string]$Sha256)
    if (Test-Path -LiteralPath $Path) {
        if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256) { return }
        throw 'Existing media has a different hash; move it aside explicitly before retrying.'
    }
    $part="$Path.partial"
    # Validate every redirect, not only the first URL.
    $current=[uri]$Uri
    for ($redirect=0; $redirect -lt 10; $redirect++) {
        if ($current.Scheme -ne 'https' -or $current.Port -ne 443 -or $current.UserInfo -or
            $current.DnsSafeHost -notin @('go.microsoft.com','download.microsoft.com','software-download.microsoft.com','software-static.download.prss.microsoft.com')) { throw 'Download redirected outside the approved Microsoft media hosts.' }
        $request=[Net.HttpWebRequest]::Create($current)
        $request.AllowAutoRedirect=$false; $request.Timeout=120000
        $response=$request.GetResponse()
        if ([int]$response.StatusCode -in @(301,302,303,307,308)) {
            $next=$response.Headers['Location']; $response.Dispose(); $current=New-Object uri($current,$next); continue
        }
        try {
            $inputStream=$response.GetResponseStream()
            $file=[IO.File]::Open($part,'Create','Write','None')
            try { $inputStream.CopyTo($file) } finally { $file.Dispose(); $inputStream.Dispose() }
        } finally { $response.Dispose() }
        if ((Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash -ne $Sha256) {
            Remove-Item -LiteralPath $part -Force
            throw 'Downloaded media SHA256 mismatch; nothing executed.'
        }
        Move-Item -LiteralPath $part -Destination $Path
        return
    }
    throw 'Too many media redirects.'
}

function Initialize-HVMedia {
    $script:IsoPath = if ($script:C.Iso.Mode -eq 'HostFile') { $script:C.Iso.HostPath } else { Join-Path $script:Data 'Media\WindowsServer2022.iso' }
    if ($script:C.Iso.Mode -eq 'OfficialDownload') {
        Receive-HVOfficialFile $script:C.Iso.Uri $script:IsoPath $script:C.Iso.Sha256
    } elseif (-not (Test-Path -LiteralPath $script:IsoPath)) {
        $error=New-Object InvalidOperationException('Operator ISO not staged at configured HostPath. Copy it to this owned host, then rerun Install with the same config.')
        $error.Data['SafeCode']='AwaitingMedia'
        throw $error
    }
    if ((Get-FileHash -LiteralPath $script:IsoPath -Algorithm SHA256).Hash -ne $script:C.Iso.Sha256) { throw 'ISO SHA256 mismatch.' }
    $image=Mount-DiskImage -ImagePath $script:IsoPath -PassThru
    try {
        $letter=($image | Get-Volume).DriveLetter
        $wim="${letter}:\sources\install.wim"
        if (-not (Test-Path -LiteralPath $wim)) { throw 'ISO must contain sources\install.wim (ESD not supported).' }
        $edition=Get-WindowsImage -ImagePath $wim -Index $script:C.Iso.ImageIndex
        if ($edition.ImageName -ne $script:C.Iso.ImageName -or $edition.Architecture -ne 9 -or
            $edition.InstallationType -ne 'Server' -or $edition.Version -notlike '10.0.20348*') { throw 'ISO index/name/architecture/build mismatch. Windows Server 2022 Desktop Experience x64 is required.' }
    } finally { Dismount-DiskImage -ImagePath $script:IsoPath | Out-Null }
    if ($script:C.Appliance.Enabled) {
        Receive-HVOfficialFile $script:C.Appliance.InstallerUri (Join-Path $script:Data 'Media\AzureMigrateInstaller.zip') $script:C.Appliance.InstallerSha256
    }
    if ($script:C.Sql.Enabled) {
        $sql=Join-Path $script:Data 'Media\SqlExpress.exe'
        Receive-HVOfficialFile $script:C.Sql.InstallerUri $sql $script:C.Sql.InstallerSha256
        $sig=Get-AuthenticodeSignature -LiteralPath $sql
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') { throw 'SQL media signature verification failed.' }
    }
}

function New-HVBase {
    $path=Join-Path $script:Data 'Base\WindowsServer2022.vhdx'
    $stamp=Join-Path $script:Data 'Base\complete.json'
    if (Test-Path $path) {
        if (-not (Test-Path $stamp)) { throw 'Base disk exists without a completed build marker. Refusing to use/rebuild an unknown parent.' }
        $built=Get-Content $stamp -Raw | ConvertFrom-Json
        if ($built.ConfigHash -ne $script:ConfigHash -or (Get-FileHash $path -Algorithm SHA256).Hash -ne $built.Sha256) { throw 'Base disk integrity/configuration mismatch.' }
        return
    }
    $building=Join-Path $script:Data 'Base\building.vhdx'
    if (Test-Path $building) {
        if ((Get-VHD -Path $building).Attached) { throw 'Incomplete build disk is still mounted; inspect it before retrying.' }
        Remove-Item -LiteralPath $building -Force
    }
    if ((Get-Volume -DriveLetter L).SizeRemaining -lt 80GB) { throw 'Less than 80 GiB available for the base build.' }
    $isoPath=if ($script:C.Iso.Mode -eq 'HostFile') { $script:C.Iso.HostPath } else { Join-Path $script:Data 'Media\WindowsServer2022.iso' }
    if ((Get-FileHash $isoPath -Algorithm SHA256).Hash -ne $script:C.Iso.Sha256) { throw 'ISO changed before base build.' }
    $iso=Mount-DiskImage -ImagePath $isoPath -PassThru
    $mounted=$false
    try {
        $wim=('{0}:\sources\install.wim' -f ($iso | Get-Volume).DriveLetter)
        New-VHD -Path $building -SizeBytes 100GB -Dynamic | Out-Null
        $disk=Mount-VHD -Path $building -PassThru | Get-Disk; $mounted=$true
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT | Out-Null
        # Remove only auto-created partitions on this newly created VHD.
        Get-Partition -DiskNumber $disk.Number | Remove-Partition -Confirm:$false
        $esp=New-Partition -DiskNumber $disk.Number -Size 300MB -AssignDriveLetter
        $esp | Format-Volume -FileSystem FAT32 -NewFileSystemLabel System -Confirm:$false | Out-Null
        New-Partition -DiskNumber $disk.Number -Size 16MB -GptType '{e3c9e316-0b5c-4db8-817d-f92df00215ae}' | Out-Null
        $win=New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        $win | Format-Volume -FileSystem NTFS -NewFileSystemLabel Windows -Confirm:$false | Out-Null
        $w="$($win.DriveLetter):"; $e="$($esp.DriveLetter):"
        Expand-WindowsImage -ImagePath $wim -Index $script:C.Iso.ImageIndex -ApplyPath "$w\" | Out-Null
        foreach ($folder in @("$e\EFI\Microsoft\Boot","$e\EFI\Microsoft\Recovery","$e\EFI\Boot")) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        Invoke-HVNative "$env:SystemRoot\System32\bcdboot.exe" @("$w\Windows",'/s',$e,'/f','UEFI')
        if (-not (Test-Path "$e\EFI\Microsoft\Boot\BCD")) { throw 'bcdboot did not create BCD.' }
        if (-not (Test-Path "$e\EFI\Microsoft\Boot\bootmgfw.efi")) {
            Copy-Item "$w\Windows\Boot\EFI\*" "$e\EFI\Microsoft\Boot" -Recurse -Force
            foreach ($extra in @('Fonts','Resources')) {
                if (Test-Path "$w\Windows\Boot\$extra") { Copy-Item "$w\Windows\Boot\$extra" "$e\EFI\Microsoft\Boot" -Recurse -Force }
            }
        }
        Copy-Item "$e\EFI\Microsoft\Boot\bootmgfw.efi" "$e\EFI\Boot\bootx64.efi" -Force
        Set-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber -GptType '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
        if ((Get-Partition -DiskNumber $disk.Number -PartitionNumber $esp.PartitionNumber).GptType -ne '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}') { throw 'EFI partition type verification failed.' }
    } finally {
        if ($mounted) { Dismount-VHD -Path $building }
        Dismount-DiskImage -ImagePath $isoPath | Out-Null
    }
    $hash=(Get-FileHash $building -Algorithm SHA256).Hash
    # Stamp before move: neither half-complete parent nor unverified disk is consumed.
    @{ConfigHash=$script:ConfigHash;Sha256=$hash} | ConvertTo-Json | Set-Content $stamp -Encoding UTF8
    Move-Item -LiteralPath $building -Destination $path
    Set-ItemProperty -LiteralPath $path -Name IsReadOnly -Value $true
}

function Get-HVTopology {
    param($Config)
    $roles=@(
        @{Suffix='DC01';Role='DC';Octet=10;MemoryGB=4;Cpu=2;Join=$true}
        @{Suffix='FS01';Role='File';Octet=11;MemoryGB=2;Cpu=2;Join=$true}
        @{Suffix='APP01';Role='App';Octet=12;MemoryGB=4;Cpu=2;Join=$true}
        @{Suffix='CLIENT01';Role='Client';Octet=13;MemoryGB=2;Cpu=2;Join=$true}
    )
    if ($Config.Appliance.Enabled) { $roles+=@{Suffix='MIG01';Role='Appliance';Octet=30;MemoryGB=16;Cpu=8;Join=$false} }
    foreach ($role in $roles) {
        [pscustomobject]@{ Name="$($Config.GuestPrefix)-$($role.Suffix)";Role=$role.Role;Ip="$($Config.NetworkPrefix).$($role.Octet)";MemoryGB=$role.MemoryGB;Cpu=$role.Cpu;Join=$role.Join }
    }
}

function New-HVUnattend {
    param([string]$Name,[string]$Password)
    $nameXml=[Security.SecurityElement]::Escape($Name)
    $passwordXml=[Security.SecurityElement]::Escape($Password)
    # EULA is hidden only after the entrypoint's explicit -AcceptMediaLicense gate.
    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
 <settings pass="specialize">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <ComputerName>$nameXml</ComputerName><TimeZone>UTC</TimeZone>
  </component>
 </settings>
 <settings pass="oobeSystem">
  <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
   <UserAccounts><AdministratorPassword><Value>$passwordXml</Value><PlainText>true</PlainText></AdministratorPassword></UserAccounts>
   <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC></OOBE>
  </component>
 </settings>
</unattend>
"@
}

function New-HVGuests {
    $base=Join-Path $script:Data 'Base\WindowsServer2022.vhdx'
    foreach ($spec in @(Get-HVTopology $script:C)) {
        Invoke-HVStep "VM-$($spec.Name)" {
            $vmDir=Join-Path $script:Data "VMs\$($spec.Name)"
            New-Item -ItemType Directory -Path $vmDir -Force | Out-Null
            $child=Join-Path $vmDir 'OS.vhdx'
            $existing=Get-VM -Name $spec.Name -ErrorAction SilentlyContinue
            if ($existing) {
                if ($existing.Notes -ne "HyperVLab:$($script:C.LabId)") { throw 'VM name is already in use by an unowned VM.' }
                if (@(Get-VMHardDiskDrive -VMName $spec.Name | Where-Object { $_.Path -eq $child }).Count -ne 1) { throw 'Guest disk attachment drift.' }
            } else {
                if (-not (Test-Path $child)) { New-VHD -Path $child -ParentPath $base -Differencing | Out-Null }
                if ((Get-VHD $child).ParentPath -ne $base) { throw 'Guest disk has unexpected parent.' }
                $mount=Join-Path $script:Data "Mount\$($spec.Name)"
                New-Item -ItemType Directory -Path $mount -Force | Out-Null
                $disk=Mount-VHD -Path $child -NoDriveLetter -PassThru | Get-Disk
                $accessAdded=$false
                try {
                    $win=Get-Partition -DiskNumber $disk.Number | Sort-Object Size -Descending | Select-Object -First 1
                    if ($win.AccessPaths -notcontains "$mount\") {
                        Add-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber -AccessPath "$mount\"
                    }
                    $accessAdded=$true
                    $panther=Join-Path $mount 'Windows\Panther'
                    New-Item -ItemType Directory -Path $panther -Force | Out-Null
                    $xml=New-HVUnattend $spec.Name $script:Credential.GetNetworkCredential().Password
                    [xml]$xml | Out-Null
                    [IO.File]::WriteAllText((Join-Path $panther 'unattend.xml'),$xml,[Text.Encoding]::UTF8)
                    $xml=$null
                    # First-boot cleanup is independent of the orchestration connection.
                    $setup=Join-Path $mount 'Windows\Setup\Scripts'
                    New-Item -ItemType Directory -Path $setup -Force | Out-Null
                    @'
@echo off
del /f /q C:\Windows\Panther\unattend.xml 2>nul
del /f /q C:\Windows\Panther\Unattend\unattend.xml 2>nul
del /f /q C:\Windows\System32\Sysprep\unattend.xml 2>nul
'@ | Set-Content (Join-Path $setup 'SetupComplete.cmd') -Encoding ASCII
                } finally {
                    try {
                        if ($accessAdded) { Remove-PartitionAccessPath -DiskNumber $disk.Number -PartitionNumber $win.PartitionNumber -AccessPath "$mount\" }
                    } finally { Dismount-VHD -Path $child }
                }
                New-VM -Name $spec.Name -Generation 2 -MemoryStartupBytes ($spec.MemoryGB*1GB) -VHDPath $child -SwitchName $script:Switch -Path $vmDir | Out-Null
                Set-VM -Name $spec.Name -Notes "HyperVLab:$($script:C.LabId)" -ProcessorCount $spec.Cpu -AutomaticCheckpointsEnabled $false -AutomaticStartAction Start -AutomaticStartDelay $(if ($spec.Role -eq 'DC') { 0 } else { 90 }) -AutomaticStopAction ShutDown | Out-Null
                Set-VMMemory -VMName $spec.Name -DynamicMemoryEnabled $false
                Set-VMFirmware -VMName $spec.Name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows
                Enable-VMIntegrationService -VMName $spec.Name -Name 'Guest Service Interface'
            }
            # The protected data tree must still let this VM's worker read the
            # immutable parent and write its own child, never another guest disk.
            $vmIdentity=New-Object Security.Principal.NTAccount('NT VIRTUAL MACHINE',(Get-VM -Name $spec.Name).Id.ToString())
            $parentAcl=Get-Acl -LiteralPath $base
            $parentAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($vmIdentity,'Read','Allow')))
            ([IO.FileInfo]$base).SetAccessControl($parentAcl)
            $childAcl=Get-Acl -LiteralPath $child
            $childAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($vmIdentity,'FullControl','Allow')))
            ([IO.FileInfo]$child).SetAccessControl($childAcl)
            if ((Get-VM -Name $spec.Name).State -eq 'Off') { Start-VM -Name $spec.Name | Out-Null }
            $session=New-HVSession $spec
            try { Invoke-HVGuest $session 'Network' $spec | Out-Null }
            finally { Remove-PSSession $session }
        }
    }
}

function New-HVSession {
    param($Spec,[int]$TimeoutSeconds=1200)
    $until=(Get-Date).AddSeconds($TimeoutSeconds)
    $secure=$script:Credential.Password
    $names=@("$($Spec.Name)\Administrator")
    if ($Spec.Role -eq 'DC') { $names=@("$($script:C.DomainNetbios)\Administrator","$($Spec.Name)\Administrator") }
    do {
        foreach ($name in $names) {
            $cred=New-Object Management.Automation.PSCredential($name,$secure)
            try { return New-PSSession -VMName $Spec.Name -Credential $cred -ErrorAction Stop }
            catch { }
        }
        if ((Get-Date) -ge $until) { throw 'PowerShell Direct unavailable or credentials rejected.' }
        Start-Sleep -Seconds 15
    } while ($true)
}

function Invoke-HVGuest {
    param($Session,[string]$Action,$Spec)
    $result=Invoke-Command -Session $Session -FilePath (Join-Path $script:Root 'host\Guest.ps1') -ArgumentList $Action,$script:C,$Spec,$script:Credential -ErrorAction Stop
    $envelope=@($result | Where-Object { $_ -and $_.PSObject.Properties['Marker'] -and $_.Marker -eq 'HVLAB_GUEST_RESULT' })
    if ($envelope.Count -ne 1 -or -not $envelope[0].Success) {
        $error=New-Object InvalidOperationException("Guest operation $Action failed or returned no result.")
        $error.Data['SafeCode']="GuestFailure:$Action"
        throw $error
    }
    return $envelope[0].Data
}

function Restart-HVGuest {
    param($Spec)
    $session=New-HVSession $Spec
    try {
        Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference='Stop'
            $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
            & "$env:SystemRoot\System32\shutdown.exe" /r /t 10 /f | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'Guest reboot request failed.' }
            $boot
        } -OutVariable previous | Out-Null
    } finally { Remove-PSSession $session }
    Start-Sleep -Seconds 20
    $until=(Get-Date).AddMinutes(20)
    do {
        try { $s=New-HVSession $Spec -TimeoutSeconds 60 }
        catch {
            if ((Get-Date) -ge $until) { throw 'Guest did not return after reboot.' }
            continue
        }
        try { $now=Invoke-Command -Session $s -ScriptBlock { (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o') } }
        finally { Remove-PSSession $s }
        if ($now -ne $previous[0]) { return }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $until)
    throw 'Guest reboot did not complete.'
}

function Initialize-HVDomain {
    $topology=@(Get-HVTopology $script:C)
    $dc=$topology | Where-Object Role -eq 'DC'
    Invoke-HVStep 'DomainForest' {
        $session=New-HVSession $dc
        try { $r=Invoke-HVGuest $session 'Forest' $dc } finally { Remove-PSSession $session }
        if ($r.Reboot) { Restart-HVGuest $dc }
        $session=New-HVSession $dc
        try { Invoke-HVGuest $session 'Directory' $dc | Out-Null } finally { Remove-PSSession $session }
    }
    foreach ($spec in @($topology | Where-Object { $_.Join -and $_.Role -ne 'DC' })) {
        Invoke-HVStep "Join-$($spec.Name)" {
            $s=New-HVSession $spec
            try { $r=Invoke-HVGuest $s 'Join' $spec } finally { Remove-PSSession $s }
            if ($r.Reboot) { Restart-HVGuest $spec }
            $s=New-HVSession $spec
            try { Invoke-HVGuest $s 'VerifyDomain' $spec | Out-Null } finally { Remove-PSSession $s }
        }
    }
}

function Initialize-HVWorkloads {
    $exe=Join-Path $script:Data 'Build\DependencyDemo.exe'
    Invoke-HVStep 'CompileWorkload' {
        $csc="$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
        if (-not (Test-Path $csc)) {
            $result=Install-WindowsFeature NET-Framework-45-Core
            if (-not $result.Success -or -not (Test-Path $csc)) { throw 'In-box .NET compiler unavailable.' }
        }
        Invoke-HVNative $csc @('/nologo','/target:exe','/optimize+',"/out:$exe",'/reference:System.Data.dll',(Join-Path $script:Root 'workloads\DependencyDemo.cs'))
        if (-not (Test-Path $exe)) { throw 'Workload compiler did not produce output.' }
    }
    foreach ($spec in @(Get-HVTopology $script:C | Where-Object { $_.Role -ne 'DC' })) {
        Invoke-HVStep "Workload-$($spec.Name)" {
            $session=New-HVSession $spec
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    $ErrorActionPreference='Stop'
                    New-Item -ItemType Directory -Path 'C:\HyperVLab' -Force | Out-Null
                } | Out-Null
                if ($spec.Role -in @('App','Client')) {
                    $remoteHash=Invoke-Command -Session $session -ScriptBlock {
                        if (Test-Path 'C:\HyperVLab\DependencyDemo.exe') { (Get-FileHash 'C:\HyperVLab\DependencyDemo.exe' -Algorithm SHA256).Hash }
                    }
                    if ($remoteHash -ne (Get-FileHash $exe -Algorithm SHA256).Hash) {
                        $running=Invoke-Command -Session $session -ScriptBlock { @(Get-Process | Where-Object { $_.Path -eq 'C:\HyperVLab\DependencyDemo.exe' }).Count }
                        if ($running) { throw 'Workload binary differs while running; do not overwrite live executables.' }
                        Copy-Item -LiteralPath $exe -Destination 'C:\HyperVLab\DependencyDemo.exe' -ToSession $session
                    }
                }
                if ($spec.Role -eq 'Appliance') {
                    Copy-Item -LiteralPath (Join-Path $script:Data 'Media\AzureMigrateInstaller.zip') -Destination 'C:\HyperVLab\AzureMigrateInstaller.zip' -ToSession $session -Force
                }
                if ($spec.Role -eq 'App' -and $script:C.Sql.Enabled) {
                    Copy-Item -LiteralPath (Join-Path $script:Data 'Media\SqlExpress.exe') -Destination 'C:\HyperVLab\SqlExpress.exe' -ToSession $session -Force
                }
                $workload=Invoke-HVGuest $session 'Workload' $spec
            } finally { Remove-PSSession $session }
            if ($workload.Reboot) {
                Restart-HVGuest $spec
                $session=New-HVSession $spec
                try { Invoke-HVGuest $session 'Workload' $spec | Out-Null } finally { Remove-PSSession $session }
            }
        }
    }
}

function Get-HVStatus {
    param([string]$Root)
    Read-HVContext $Root
    $checks=@()
    $hasCredential=Test-Path (Join-Path $Root 'credential.clixml')
    if ($hasCredential) {
        try { $script:Credential=Import-Clixml (Join-Path $Root 'credential.clixml') }
        catch { $hasCredential=$false }
    }
    $hyperV=Get-Command Get-VM -ErrorAction SilentlyContinue
    foreach ($spec in @(Get-HVTopology $script:C)) {
        $vm=if ($hyperV) { Get-VM -Name $spec.Name -ErrorAction SilentlyContinue } else { $null }
        $entry=[ordered]@{ Name=$spec.Name;Role=$spec.Role;Power='Missing';GuestHealth='Unknown';Details=$null }
        if ($vm) {
            $entry.Power=$vm.State.ToString()
            if ($vm.Notes -ne "HyperVLab:$($script:C.LabId)") { $entry.GuestHealth='OwnershipMismatch' }
            elseif ($vm.State -eq 'Running' -and $hasCredential) {
                try {
                    $session=New-HVSession $spec -TimeoutSeconds 0
                    try { $entry.Details=Invoke-HVGuest $session 'Validate' $spec; $entry.GuestHealth=$entry.Details.Health }
                    finally { Remove-PSSession $session }
                } catch { $entry.GuestHealth='Unavailable' }
            }
        }
        $checks += [pscustomobject]$entry
    }
    $healthy=@($checks | Where-Object { $_.GuestHealth -ne 'Healthy' }).Count -eq 0
    $task=Get-ScheduledTask -TaskName "HyperVLab-$($script:C.LabId)" -ErrorAction SilentlyContinue
    $taskState=if ($task) { $task.State.ToString() } else { 'Missing' }
    [pscustomobject]@{
        Health=$(if ($healthy) { 'Healthy' } else { 'IncompleteOrUnhealthy' })
        Installation=$script:State; Task=$taskState; Checks=$checks
        ApplianceRegistration=$(if ($script:C.Appliance.Enabled) { 'Manual and unverified; Hyper-V scenario required' } else { 'Not requested' })
        Scope='Read-only probes only. No VM start/restart, media download, setup or repair.'
    }
}

function Invoke-HVInstall {
    param([string]$Root)
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Host administrator context required.' }
    $mutex=New-Object Threading.Mutex($false,'Global\HyperVLabInstaller')
    $locked=$false
    try {
        try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Another host installation is running.' }
        Read-HVContext $Root
        $script:Credential=Import-Clixml (Join-Path $Root 'credential.clixml')
        Invoke-HVStep 'DataDisk' { Initialize-HVDisk }
        # Never skip checking disk identity merely because a checkpoint exists.
        Initialize-HVDisk
        $boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
        if ($script:State.RebootBootTime -eq $boot) {
            $script:State.Status='RebootRequired'; Save-HVState
            Invoke-HVNative "$env:SystemRoot\System32\shutdown.exe" @('/r','/t','30','/f')
            return
        }
        if ((Get-WindowsFeature Hyper-V).InstallState -ne 'Installed') {
            $script:State.Step='HyperVRole'; $script:State.Status='Running'; Save-HVState
            $result=Install-WindowsFeature Hyper-V -IncludeManagementTools
            if (-not $result.Success) { throw 'Hyper-V role installation failed.' }
            $script:State.RebootBootTime=$boot; $script:State.Status='RebootRequired'; Save-HVState
            Write-HVEvent 'HyperVRole' 'InstalledRebootRequired'
            Invoke-HVNative "$env:SystemRoot\System32\shutdown.exe" @('/r','/t','30','/f')
            return
        }
        if ((Get-Service vmms).Status -ne 'Running') { throw 'Hyper-V service is not running after role installation/reboot.' }
        Invoke-HVStep 'Network' { Initialize-HVNetwork }
        Invoke-HVStep 'Media' { Initialize-HVMedia }
        Invoke-HVStep 'BaseImage' { New-HVBase }
        # Auto-start only owned guests on resume; never enumerate/start the subscription.
        foreach ($spec in @(Get-HVTopology $script:C)) {
            $vm=Get-VM -Name $spec.Name -ErrorAction SilentlyContinue
            if ($vm) {
                if ($vm.Notes -ne "HyperVLab:$($script:C.LabId)") { throw 'Guest ownership mismatch.' }
                if ($vm.State -eq 'Off') { Start-VM -Name $spec.Name | Out-Null }
            }
        }
        New-HVGuests
        Initialize-HVDomain
        Initialize-HVWorkloads
        $script:State.Step='Validation'; $script:State.Status='Running'; Save-HVState
        $status=Get-HVStatus -Root $Root
        if ($status.Health -ne 'Healthy') { throw 'Final guest validation incomplete or unhealthy.' }
        $script:State.Step='Complete'
        $script:State.Status=if ($script:C.Appliance.Enabled) { 'LabReady-ApplianceManualSetup' } else { 'LabReady' }
        $script:State.ErrorType=$null; $script:State.ErrorCode=$null; Save-HVState; Write-HVEvent 'Validation' 'Succeeded'
    } catch {
        if (Get-Variable State -Scope Script -ErrorAction SilentlyContinue) {
            $script:State.Status=if ($_.Exception.Data['SafeCode'] -eq 'AwaitingMedia') { 'AwaitingMedia' } else { 'Failed' }
            $script:State.ErrorType=$_.Exception.GetType().Name
            $script:State.ErrorCode=$_.Exception.Data['SafeCode']
            Save-HVState; Write-HVEvent $script:State.Step 'Failed'
        }
        throw
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

Export-ModuleMember -Function *
