@{
    SchemaVersion = 1
    # Generate once with [guid]::NewGuid(); retain it for every resume.
    LabId = 'REPLACE-WITH-NEW-GUID'
    SubscriptionId = 'REPLACE-WITH-SUBSCRIPTION-GUID'
    ResourceGroup = 'rg-hvlab-demo'
    Prefix = 'hvdemo'
    Location = 'eastus2'
    HostVmSize = 'Standard_E16ds_v5'
    AdminUsername = 'laboperator'
    AllowedSourceIp = '203.0.113.10/32' # Replace with your public IPv4 address.
    DataDiskSizeGB = 512
    ShutdownTime = '2200'
    ShutdownTimeZone = 'UTC'
    DomainName = 'demo.test'
    DomainNetbios = 'DEMO'
    GuestPrefix = 'DEMO'
    # Dedicated internal network; not connected to any existing network.
    NetworkPrefix = '192.168.100'
    # Never inferred from a moving download link. Obtain the SHA256 independently.
    Iso = @{
        Mode = 'OfficialDownload' # Or HostFile (operator stages media on owned host).
        Uri = 'https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US'
        HostPath = 'C:\LabMedia\WindowsServer2022.iso'
        Sha256 = 'REPLACE-WITH-64-HEX-SHA256'
        ImageIndex = 4
        # Prevent accidentally selecting Core or a different OS/index.
        ImageName = 'Windows Server 2022 SERVERDATACENTER EVAL'
    }
    # Optional REAL SQL Server Express 2022 on APP01, Windows authentication.
    # Supply an official full SQLEXPR_x64_ENU.exe URL, NOT the web bootstrapper.
    Sql = @{
        Enabled = $false
        InstallerUri = ''
        InstallerSha256 = ''
    }
    # Optional dedicated 8-vCPU, 16-GiB, 100-GiB workgroup appliance VM.
    # Only stages the verified MICROSOFT MULTI-SCENARIO installer; setup/registration
    # require you to select Hyper-V interactively. It is never executed silently.
    Appliance = @{
        Enabled = $false
        InstallerUri = 'https://go.microsoft.com/fwlink/?linkid=2191847'
        InstallerSha256 = ''
    }
}
