#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
$failed=0
$passed=0
$priorAz=Get-Item function:az -ErrorAction SilentlyContinue
function Assert-True {
    param([bool]$Condition,[string]$Name)
    if (-not $Condition) { throw "Assertion failed: $Name" }
    $script:passed++
}
function Assert-Throws {
    param([scriptblock]$Body,[string]$Name)
    $thrown=$false
    try { & $Body | Out-Null } catch { $thrown=$true }
    Assert-True $thrown $Name
}
function New-TestConfig {
    $c=Import-PowerShellDataFile (Join-Path $root 'config.example.psd1')
    $c.LabId='11111111-1111-4111-8111-111111111111'
    $c.SubscriptionId='22222222-2222-4222-8222-222222222222'
    $c.Iso.Sha256='a'*64
    return $c
}
try {
    $files=@(Get-ChildItem -LiteralPath $root -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1','.psm1','.psd1') -and $_.FullName -notlike '*\.runtime\*' })
    foreach ($file in $files) {
        $tokens=$null;$errors=$null
        [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors) | Out-Null
        Assert-True ($errors.Count -eq 0) "Parser: $($file.Name)"
    }
    $workflow=Get-Content -LiteralPath (Join-Path $root '.github\workflows\validate.yml') -Raw
    Assert-True ($workflow -match '(?m)^\s*-\s*uses:\s*actions/checkout@[0-9a-f]{40}(?:\s|$)') 'checkout action uses a complete commit SHA'
    Import-Module (Join-Path $root 'src\Lab.psm1') -Force -DisableNameChecking
    Import-Module (Join-Path $root 'host\Engine.psm1') -Force -DisableNameChecking
    $c=New-TestConfig
    Assert-LabConfig $c
    Assert-True ((Get-LabConfigHash $c).Length -eq 64) 'config hash'
    $same=@{};foreach ($k in @($c.Keys | Sort-Object -Descending)) { $same[$k]=$c[$k] }
    Assert-True ((Get-LabConfigHash $c) -eq (Get-LabConfigHash $same)) 'order-independent config identity'
    $plan=Get-LabPlan $c
    Assert-True ($plan.Action -eq 'Plan' -and $plan.Guests.Count -eq 4) 'generic four-guest plan'
    $global:HVLabAzCalls=0
    function global:az { $global:HVLabAzCalls++; throw 'Tests prohibit Azure calls.' }
    $before=@(Get-ChildItem -LiteralPath $root -Force -Recurse -File).Count
    Get-LabPlan $c | Out-Null
    Assert-True ($global:HVLabAzCalls -eq 0) 'plan makes no Azure calls'
    Assert-True ($before -eq @(Get-ChildItem -LiteralPath $root -Force -Recurse -File).Count) 'plan creates no files'
    foreach ($bad in @('0.0.0.0/0','203.0.113.10/24','*','127.0.0.1/32','10.0.0.1/32','300.1.1.1/32','::1/128')) {
        $c=New-TestConfig;$c.AllowedSourceIp=$bad
        Assert-Throws { Assert-LabConfig $c } 'unsafe source IP rejected'
    }
    foreach ($bad in @("foo';exit;#",'../bad','UPPERCASE','x')) {
        $c=New-TestConfig;$c.Prefix=$bad
        Assert-Throws { Assert-LabConfig $c } 'unsafe naming rejected'
    }
    foreach ($bad in @('https://example.org/file.iso','http://download.microsoft.com/test.iso','https://download.microsoft.com.evil.test/file.iso','https://user:pw@download.microsoft.com/file.iso','https://download.microsoft.com/file.iso?sig=example')) {
        Assert-True (-not (Test-LabOfficialUri $bad)) 'unapproved media rejected'
    }
    Assert-True (Test-LabOfficialUri 'https://go.microsoft.com/fwlink/?linkid=2191847') 'official installer URL'
    $c=New-TestConfig;$c.Password='DO-NOT-PACKAGE'
    Assert-Throws { Get-LabPayload $root $c } 'unknown credential key cannot enter upload'
    $c=New-TestConfig;$c.Iso.Sha256='bad'
    Assert-Throws { Assert-LabConfig $c } 'missing integrity rejected'
    $c=New-TestConfig;$c.HostVmSize='Standard_D2s_v3'
    Assert-Throws { Assert-LabConfig $c } 'unsupported small SKU rejected'
    $c=New-TestConfig;$c.Appliance.Enabled=$true
    Assert-Throws { Assert-LabConfig $c } 'appliance hash required'
    $c=New-TestConfig;$c.DomainName='customer.example.com'
    Assert-Throws { Assert-LabConfig $c } 'non-lab domain rejected'
    $c=New-TestConfig;$c.GuestPrefix='ABCDEFGH'
    Assert-Throws { Assert-LabConfig $c } 'overlong Windows guest name rejected'
    $c=New-TestConfig
    $payload=Get-LabPayload $root $c | ConvertFrom-Json
    Assert-True (@($payload.Files.PSObject.Properties).Count -eq 4) 'fixed payload file allowlist'
    Assert-True (-not @($payload.Files.PSObject.Properties | Where-Object Name -match 'local|credential|log|git').Count) 'no private upload files'
    & (Get-Module Lab) {
        param($Root,$Config)
        $script:generatedCommands=0
        function Invoke-LabHostCommand {
            param($Config,$Root,$Script)
            $tokens=$null;$errors=$null
            [Management.Automation.Language.Parser]::ParseInput($Script,[ref]$tokens,[ref]$errors) | Out-Null
            if ($errors.Count) { throw 'Generated upload command does not parse.' }
            $script:generatedCommands++
            if ($Script -match 'RSACertificateExtensions.*GetRSAPublicKey') {
                return '{"Modulus":"AQ==","Exponent":"AQAB","Thumbprint":"TEST"}'
            }
            return ''
        }
        $public=Send-LabPayload $Config $Root
        if ($script:generatedCommands -lt 3 -or $public.Thumbprint -ne 'TEST') { throw 'Expected init/chunk/extract transport sequence.' }
    } $root $c
    $script:passed++
    $owner=[pscustomobject]@{tags=[pscustomobject]@{labId=$c.LabId;managedBy='hyperv-discovery-lab';configHash=(Get-LabConfigHash $c)}}
    Assert-LabOwner $owner $c -CheckHash
    $owner.tags.labId='different'
    Assert-Throws { Assert-LabOwner $owner $c } 'unrelated resource refused'
    $owner.tags.labId=$c.LabId;$owner.tags.configHash='changed'
    Assert-Throws { Assert-LabOwner $owner $c -CheckHash } 'configuration drift refused'
    $disk=[pscustomobject]@{Number=3;Size=512GB;IsBoot=$false;IsSystem=$false;UniqueId='test-managed';PartitionStyle='RAW'}
    $local=[pscustomobject]@{Number=2;Size=512GB;IsBoot=$false;IsSystem=$false;UniqueId='test-local';PartitionStyle='RAW'}
    $os=[pscustomobject]@{Number=0;Size=512GB;IsBoot=$true;IsSystem=$true;UniqueId='test-os';PartitionStyle='GPT'}
    $drive=[pscustomobject]@{Index=3;SCSILogicalUnit=1;Model='Virtual_Disk NVMe Premium'}
    $localDrive=[pscustomobject]@{Index=2;SCSILogicalUnit=1;Model='Microsoft NVMe Direct Disk'}
    $osDrive=[pscustomobject]@{Index=0;SCSILogicalUnit=1;Model='Virtual_Disk NVMe Premium'}
    Assert-True ((Select-HVDataDisk @($disk,$local,$os) @($drive,$localDrive,$osDrive) 512 NVMe).Number -eq 3) 'NVMe excludes same-sized local and OS disks'
    Assert-Throws { Select-HVDataDisk @($disk) @($drive) 1024 NVMe } 'no arbitrary RAW fallback'
    Assert-Throws { Select-HVDataDisk @($disk,$disk) @($drive) 512 NVMe } 'ambiguous disk refused'
    $drive.SCSILogicalUnit=0;$drive.Model='Msft Virtual Disk'
    Assert-True ((Select-HVDataDisk @($disk) @($drive) 512 SCSI).Number -eq 3) 'SCSI LUN zero'
    $xml=New-HVUnattend 'DEMO-DC01' 'Example&<>quote"not-a-real-password'
    [xml]$doc=$xml
    Assert-True ($doc.unattend.settings[1].component.UserAccounts.AdministratorPassword.Value -eq 'Example&<>quote"not-a-real-password') 'unattend XML safely escapes password'
    $secure=ConvertTo-SecureString 'TestOnly-NeverUsed-4a!&' -AsPlainText -Force
    $plain=ConvertFrom-LabSecure $secure
    Assert-True ((Protect-LabText "diagnostic $plain") -notlike "*$plain*") 'redaction of registered secret'
    Assert-Throws { Assert-LabPassword 'short' 'operator' } 'weak password rejected'
    Assert-LabPassword 'TestOnly-LongEnough-7A!' 'operator'
    $shell=(Get-Process -Id $PID).Path
    $output=Invoke-LabNative $shell @('-NoProfile','-NonInteractive','-Command','Write-Output "NATIVE_OK"; exit 0')
    Assert-True ($output -eq 'NATIVE_OK') 'native success captured'
    Assert-Throws { Invoke-LabNative $shell @('-NoProfile','-NonInteractive','-Command','Write-Output "secret-value"; exit 7') } 'nonzero native exit rejected'
    Assert-Throws { Invoke-HVNative $shell @('-NoProfile','-NonInteractive','-Command','exit 9') } 'host nonzero exit rejected'
    & (Get-Module Engine) {
        $script:State=[pscustomobject]@{Status='';Step='';ErrorType=$null;ErrorCode=$null;Completed=@()}
        function Save-HVState {}
        function Write-HVEvent {}
        Invoke-HVStep Good {}
        if ($script:State.Completed -notcontains 'Good') { throw 'Successful checkpoint missing.' }
        $script:executed=0
        Invoke-HVStep Good { $script:executed++ }
        if ($script:executed -ne 0) { throw 'Completed step reran.' }
        try { Invoke-HVStep Bad { throw 'intentional test failure' } } catch {}
        if ($script:State.Completed -contains 'Bad' -or $script:State.Status -ne 'Failed') { throw 'Failed step incorrectly checkpointed.' }
    }
    $script:passed+=3
    & (Get-Module Engine) {
        $script:Root='unused';$script:C=$null;$script:Credential=$null;$script:guestMode='success'
        function Invoke-Command {
            if ($script:guestMode -eq 'missing') { return 'ordinary output is not success' }
            [pscustomobject]@{Marker='HVLAB_GUEST_RESULT';Success=($script:guestMode -eq 'success');Data=[pscustomobject]@{Value=42}}
        }
        $r=Invoke-HVGuest $null 'Validate' $null
        if ($r.Value -ne 42) { throw 'Guest success envelope lost.' }
        foreach ($mode in @('missing','failed')) {
            $script:guestMode=$mode
            $blocked=$false
            try { Invoke-HVGuest $null 'Validate' $null | Out-Null } catch { $blocked=$true }
            if (-not $blocked) { throw 'Guest failure/missing envelope was treated as success.' }
        }
    }
    $script:passed+=3
    $rsa=New-Object Security.Cryptography.RSACng
    try {
        $sample=[Text.Encoding]::UTF8.GetBytes('TestOnly-Crypto-7A!')
        $cipher=$rsa.Encrypt($sample,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        $decoded=$rsa.Decrypt($cipher,[Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
        Assert-True ([Convert]::ToBase64String($decoded) -eq [Convert]::ToBase64String($sample)) 'OAEP-SHA256 works in this Windows PowerShell runtime'
    } finally { $rsa.Dispose() }
    $c=New-TestConfig;$c.Sql.Enabled=$true
    Assert-Throws { Assert-LabConfig $c } 'SQL missing verified media rejected'
    $c=New-TestConfig;$c.Appliance.InstallerUri='https://download.microsoft.com/a?token=private'
    Assert-Throws { Assert-LabConfig $c } 'disabled component cannot hide credential URL'
    $fixture=Join-Path $root ('.runtime\test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $fixture -Force | Out-Null
    try {
        $fixturePath=Join-Path $fixture 'config.psd1'
        $text=(Get-Content (Join-Path $root 'config.example.psd1') -Raw).
            Replace('REPLACE-WITH-NEW-GUID','11111111-1111-4111-8111-111111111111').
            Replace('REPLACE-WITH-SUBSCRIPTION-GUID','22222222-2222-4222-8222-222222222222').
            Replace('REPLACE-WITH-64-HEX-SHA256',('a'*64))
        Set-Content -LiteralPath $fixturePath -Value $text -Encoding UTF8
        $inventoryBefore=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { $_.FullName })
        $result=Invoke-LabNative $shell @('-NoProfile','-NonInteractive','-File',(Join-Path $root 'Install.ps1'),'-Action','Plan','-Config',$fixturePath) | ConvertFrom-Json
        Assert-True ($result.Action -eq 'Plan') 'actual entrypoint emits clean Plan JSON'
        $inventoryAfter=@(Get-ChildItem -LiteralPath $root -Recurse -File -Force | ForEach-Object { $_.FullName })
        Assert-True (@(Compare-Object $inventoryBefore $inventoryAfter).Count -eq 0) 'actual Plan creates no files'
        Assert-Throws { Invoke-LabNative $shell @('-NoProfile','-NonInteractive','-File',(Join-Path $root 'Install.ps1'),'-Action','Install','-Config',$fixturePath) } 'entrypoint refuses installation without approval'
        Assert-Throws { Invoke-LabNative $shell @('-NoProfile','-NonInteractive','-File',(Join-Path $root 'Install.ps1'),'-Action','Deploy','-Approve','-Config',$fixturePath) } 'entrypoint refuses setup without license authorization'
        & (Get-Module Lab) {
            param($Root,$Config,$Fixture)
            $Config.Iso.Mode='HostFile';$Config.Iso.Uri=''
            $script:created=$false;$script:deployCalls=0;$script:previewKind='Create';$script:launched=$false
            function Initialize-LabDependencies {}
            function Assert-LabCloudPreflight {}
            function Assert-LabHostReady {}
            function Get-LabOwnedHost { if ($script:created) { [pscustomobject]@{name='owned-fixture'} } }
            function Invoke-LabNative { return '' }
            function Invoke-LabAz {
                param($Arguments)
                switch ($Arguments[2]) {
                    'validate' { return [pscustomobject]@{} }
                    'what-if' { return [pscustomobject]@{changes=@([pscustomobject]@{changeType=$script:previewKind;resourceId='mock-only'})} }
                    'create' { $script:deployCalls++;$script:created=$true;return [pscustomobject]@{} }
                    default { throw 'Unexpected mocked Azure operation.' }
                }
            }
            $script:transportRsa=New-Object Security.Cryptography.RSACng
            $request=[Security.Cryptography.X509Certificates.CertificateRequest]::new(
                'CN=HVLab-Offline-Launcher-Test',$script:transportRsa,
                [Security.Cryptography.HashAlgorithmName]::SHA256,[Security.Cryptography.RSASignaturePadding]::Pkcs1)
            $script:transportCertificate=$request.CreateSelfSigned([datetimeoffset]::UtcNow.AddMinutes(-1),[datetimeoffset]::UtcNow.AddHours(1))
            $script:launcherCredential=$null
            $script:launcherBindingChecks=0
            function Send-LabPayload {
                $p=$script:transportRsa.ExportParameters($false)
                [pscustomobject]@{Modulus=[Convert]::ToBase64String($p.Modulus);Exponent=[Convert]::ToBase64String($p.Exponent);Thumbprint=$script:transportCertificate.Thumbprint}
            }
            function Test-GeneratedLauncherBinding {
                param([string]$CapturedScript,[string]$LabId)
                $probe=@{
                    Root="C:\ProgramData\HyperVLab\$LabId"
                    TaskName="HyperVLab-$LabId"
                    Certificate=$script:transportCertificate
                    Credential=$script:launcherCredential
                    HadCredential=($null -ne $script:launcherCredential)
                    Calls=(New-Object 'System.Collections.Generic.List[string]')
                    Action=$null
                    Registration=$null
                }
                # Every certificate/file/task command in the captured launcher is
                # intercepted; the certificate and credential exist only in memory.
                function Get-Item {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([Parameter(Position=0)][string[]]$Path)
                    if ($Path.Count -ne 1 -or $Path[0] -cne "Cert:\LocalMachine\My\$($probe.Certificate.Thumbprint)") { throw 'Unexpected launcher certificate path.' }
                    $probe.Calls.Add('Certificate')
                    return $probe.Certificate
                }
                function Test-Path {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([Parameter(Position=0)][string[]]$Path)
                    if ($Path.Count -ne 1 -or $Path[0] -cne "$($probe.Root)\credential.clixml") { throw 'Unexpected launcher credential probe path.' }
                    $probe.Calls.Add('CredentialExists')
                    return ($null -ne $probe.Credential)
                }
                function Export-Clixml {
                    [CmdletBinding(PositionalBinding=$false)]
                    param(
                        [Parameter(Position=0,Mandatory=$true)][string]$Path,
                        [Parameter(ValueFromPipeline=$true,Mandatory=$true)][object]$InputObject
                    )
                    process {
                        if ($Path -cne "$($probe.Root)\credential.clixml" -or $InputObject -isnot [pscredential]) { throw 'Unexpected launcher credential export binding.' }
                        $probe.Credential=$InputObject
                        $probe.Calls.Add('CredentialExport')
                    }
                }
                function Import-Clixml {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([Parameter(Position=0,Mandatory=$true)][string[]]$Path)
                    if ($Path.Count -ne 1 -or $Path[0] -cne "$($probe.Root)\credential.clixml") { throw 'Unexpected launcher credential import path.' }
                    $probe.Calls.Add('CredentialImport')
                    return $probe.Credential
                }
                function Get-ScheduledTask {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([Parameter(Position=0)][string[]]$TaskName)
                    if ($TaskName.Count -ne 1 -or $TaskName[0] -cne $probe.TaskName) { throw 'Unexpected scheduled-task lookup binding.' }
                    $probe.Calls.Add('TaskLookup')
                    if ($probe.HadCredential) { return [pscustomobject]@{State='Ready'} }
                }
                function New-ScheduledTaskAction {
                    [CmdletBinding(PositionalBinding=$false)]
                    param(
                        [Parameter(ParameterSetName='Exec')][string]$Id,
                        [Parameter(ParameterSetName='Exec',Mandatory=$true,Position=0)][ValidateNotNullOrEmpty()][string]$Execute,
                        [Parameter(ParameterSetName='Exec',Position=1)][ValidateNotNullOrEmpty()][string]$Argument,
                        [Parameter(ParameterSetName='Exec',Position=2)][ValidateNotNullOrEmpty()][string]$WorkingDirectory
                    )
                    $probe.Action=[pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory}
                    $probe.Calls.Add('Action')
                    return $probe.Action
                }
                function New-ScheduledTaskPrincipal {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([string]$UserId,[string]$LogonType,[string]$RunLevel)
                    return [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel}
                }
                function New-ScheduledTaskSettingsSet {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([string]$MultipleInstances,[timespan]$ExecutionTimeLimit,[switch]$StartWhenAvailable)
                    return [pscustomobject]@{MultipleInstances=$MultipleInstances;ExecutionTimeLimit=$ExecutionTimeLimit;StartWhenAvailable=$StartWhenAvailable.IsPresent}
                }
                function New-ScheduledTaskTrigger {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([switch]$AtStartup)
                    return [pscustomobject]@{AtStartup=$AtStartup.IsPresent}
                }
                function Register-ScheduledTask {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([string]$TaskName,[object[]]$Action,[object[]]$Trigger,[object]$Principal,[object]$Settings,[switch]$Force)
                    $probe.Registration=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Trigger=$Trigger;Principal=$Principal;Settings=$Settings;Force=$Force.IsPresent}
                    $probe.Calls.Add('Register')
                }
                function Start-ScheduledTask {
                    [CmdletBinding(PositionalBinding=$false)]
                    param([string[]]$TaskName)
                    if ($TaskName.Count -ne 1 -or $TaskName[0] -cne $probe.TaskName -or $probe.Calls[$probe.Calls.Count-1] -ne 'Register') { throw 'Launcher did not start the exact task after registration.' }
                    $probe.Calls.Add('Start')
                }
                # Read metadata only; do not invoke the real task cmdlet/CIM provider.
                $actual=(Get-Command ScheduledTasks\New-ScheduledTaskAction).ParameterSets | Where-Object Name -eq Exec
                $mock=(Get-Command New-ScheduledTaskAction).ParameterSets | Where-Object Name -eq Exec
                foreach ($name in @('Execute','Argument','WorkingDirectory')) {
                    $actualPosition=($actual.Parameters | Where-Object Name -eq $name).Position
                    $mockPosition=($mock.Parameters | Where-Object Name -eq $name).Position
                    if ($actualPosition -ne $mockPosition) { throw 'Task-action mock positional binding differs from installed cmdlet metadata.' }
                }
                & ([scriptblock]::Create($CapturedScript)) | Out-Null
                $expectedExecutable=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $expectedArguments='-NoProfile -ExecutionPolicy Bypass -File "' + $probe.Root + '\host\Runner.ps1" -Action Install'
                if ($probe.Action.Execute -cne $expectedExecutable) { throw 'Launcher executable binding differs from the expected PowerShell path.' }
                if ($probe.Action.Argument -cne $expectedArguments) { throw 'Launcher Argument binding is not the complete quoted Runner invocation.' }
                if ($probe.Action.WorkingDirectory -and $probe.Action.WorkingDirectory -cne $probe.Root) { throw 'Launcher WorkingDirectory contains arguments instead of the host directory.' }
                $registration=$probe.Registration
                if ($registration.TaskName -cne $probe.TaskName -or $registration.Action.Count -ne 1 -or
                    $registration.Action[0].Argument -cne $expectedArguments -or -not $registration.Force) { throw 'Task registration lost the exact action/name or resume replacement flag.' }
                if ($registration.Principal.UserId -cne 'SYSTEM' -or $registration.Principal.LogonType -cne 'ServiceAccount' -or
                    $registration.Principal.RunLevel -cne 'Highest') { throw 'Task principal binding changed.' }
                if ($registration.Trigger.Count -ne 1 -or -not $registration.Trigger[0].AtStartup -or
                    $registration.Settings.MultipleInstances -cne 'IgnoreNew' -or
                    $registration.Settings.ExecutionTimeLimit -ne [timespan]::FromHours(8) -or
                    -not $registration.Settings.StartWhenAvailable) { throw 'Task startup/resume settings binding changed.' }
                $credentialCall=if ($probe.HadCredential) { 'CredentialImport' } else { 'CredentialExport' }
                if (($probe.Calls -join ',') -cne "Certificate,CredentialExists,$credentialCall,TaskLookup,Action,Register,Start") { throw 'Launcher credential/task command ordering changed.' }
                if ($probe.Credential.GetNetworkCredential().Password -cne 'TestOnly-Guest-8A!') { throw 'Launcher did not recover the synthetic encrypted credential.' }
                $script:launcherCredential=$probe.Credential
                $script:launcherBindingChecks+=8
            }
            function Invoke-LabHostCommand {
                param($Config,$Root,$Script)
                $tokens=$null;$errors=$null
                [Management.Automation.Language.Parser]::ParseInput($Script,[ref]$tokens,[ref]$errors) | Out-Null
                if ($errors.Count) { throw 'Generated launcher does not parse.' }
                if ($Script -match 'TestOnly-Guest-8A!') { throw 'Plaintext guest credential entered transport.' }
                Test-GeneratedLauncherBinding -CapturedScript $Script -LabId $Config.LabId
                $script:launched=$true
                return 'MOCK_SCHEDULED'
            }
            try {
                $hostPassword=ConvertTo-SecureString 'TestOnly-Host-9B!' -AsPlainText -Force
                $guestPassword=ConvertTo-SecureString 'TestOnly-Guest-8A!' -AsPlainText -Force
                Invoke-LabInstall $Config $Fixture -HostPassword $hostPassword -GuestPassword $guestPassword | Out-Null
                if ($script:deployCalls -ne 1 -or -not $script:launched) { throw 'Mock install did not deploy once and launch.' }
                if (Test-Path (Join-Path $Fixture '.runtime\parameters.json')) { throw 'Parameter file was not cleaned after success.' }
                Invoke-LabInstall $Config $Fixture -GuestPassword $guestPassword | Out-Null
                if ($script:deployCalls -ne 1) { throw 'Resume redeployed infrastructure.' }
                if ($script:launcherBindingChecks -ne 16) { throw 'Both fresh and resumed launchers must pass actual binding checks.' }
                $script:created=$false;$script:previewKind='Modify'
                $blocked=$false
                try { Invoke-LabInstall $Config $Fixture -HostPassword $hostPassword -GuestPassword $guestPassword | Out-Null } catch { $blocked=$true }
                if (-not $blocked -or $script:deployCalls -ne 1) { throw 'Unsafe what-if was not rejected before create.' }
                if (Test-Path (Join-Path $Fixture '.runtime\parameters.json')) { throw 'Parameter file was not cleaned after failure.' }
            } finally {
                $script:launcherCredential=$null
                $script:transportCertificate.Dispose()
                $script:transportRsa.Dispose()
            }
        } $root (New-TestConfig) $fixture
        $script:passed+=21
    } finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
    $source=Get-Content (Join-Path $root 'Install.ps1') -Raw
    Assert-True ($source.IndexOf("if (-not `$Approve)") -lt $source.IndexOf('Invoke-LabInstall -Config')) 'approval gate before install'
    $hostSource=Get-Content (Join-Path $root 'host\Engine.psm1') -Raw
    Assert-True ($hostSource -notmatch 'Start-Transcript|TrustedHosts|Select-Object -First 1.*RAW') 'no transcripts/wildcard trust/raw fallback'
    Write-Host "PASS: $passed local assertions; no Azure access, VM operations, dependency installation or downloads."
} catch {
    $failed++
    Write-Host "FAIL: $($_.Exception.Message)" -ForegroundColor Red
    throw
} finally {
    Remove-Item function:az -Force -ErrorAction SilentlyContinue
    if ($priorAz) { Set-Item function:global:az -Value $priorAz.ScriptBlock }
    Remove-Variable HVLabAzCalls -Scope Global -ErrorAction SilentlyContinue
}
