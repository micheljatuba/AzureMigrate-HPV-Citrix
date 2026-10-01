GENERIC AZURE-HOSTED HYPER-V DISCOVERY LAB
=======================================

This repository's URL retains "Citrix" for historical naming only. Its executable
path has no Citrix roles, agents, license server, SDK, catalogs or simulated
Citrix processes. It creates a standalone, generic Windows Hyper-V lab nested
inside ONE newly owned Azure Windows Server 2022 VM.

LAB ONLY - VALIDATE IN AN ISOLATED SANDBOX FIRST
-----------------------------------------------
This is demonstration and experimentation code, not a production-ready solution.
Before any implementation, adaptation, update or new revision, review the exact
code/configuration and validate it end-to-end in an isolated, disposable sandbox
with synthetic data. Revalidate every revision; previous results are not approval.
Review permissions, network access, security, licensing, costs, operational impact
and cleanup/rollback before running. Never run directly against production.
Any later use in a customer test or production environment requires independent
technical/security assessment and explicit approval through its change process.
Local tests do not certify an Azure deployment, guest workloads or Azure Migrate.
Keep real credentials, keys and collected data out of Git and synchronized folders;
.gitignore is not encryption and does not prevent OneDrive synchronization.

QUICK START (Windows, 64-bit PowerShell 5.1 or PowerShell 7)
--------------------------------------------------------
  git clone https://github.com/micheljatuba/AzureMigrate-HPV-Citrix.git
  Set-Location .\AzureMigrate-HPV-Citrix
  Copy-Item .\config.example.psd1 .\config.local.psd1
  notepad .\config.local.psd1

Fill LabId with a new GUID ([guid]::NewGuid()), SubscriptionId, your public IPv4
/32, naming, region, and an independently obtained ISO SHA256. Verify the WIM
image index AND exact image name match your Windows Server 2022 x64 Desktop
Experience media. The example is intentionally not deployment-ready.

Never put passwords, subscription tokens, appliance keys or signed private URLs
in the configuration. The strict schema rejects unknown fields. The local
configuration and .runtime directory are gitignored. A public example is not a
credential store.

  .\Install.ps1 -Action Plan
  .\tests\Test-Local.ps1

Plan performs no network calls, login, downloads, dependency installations or
file creation. It is not an Azure what-if and cannot verify quota or capacity.
Tests are self-contained, non-deploying assertions using in-box tooling.

After reviewing costs, obtaining media rights and deciding to create the lab:

  .\Install.ps1 -Action Install -Approve -AcceptMediaLicense -AllowDependencyInstall -Login

This is the single installation entrypoint. Deploy is an alias for Install.
Passwords are securely prompted, never printed. Use DIFFERENT host and guest
passwords; preserve them in your own password manager. Each needs 14-100
characters, upper/lowercase, a digit and symbol, and must exclude the username.
The nested local administrator becomes the domain administrator on the DC.
The same guest password is also used for DSRM in this isolated lab.

Flags are separate consents:
  -Approve                 Creates billable resources, configures this owned host
                           and guests, and allows required installation reboots.
  -AcceptMediaLicense       Your explicit authorization for unattended Windows
                           setup and SQL terms if Sql.Enabled is true. Read the
                           relevant terms first; the flag grants no license.
  -AllowDependencyInstall   Allows missing Microsoft Azure CLI MSI (UAC prompt)
                           and official Bicep installation after signature checks.
  -Login                   Runs interactive az login. Omit if already signed in.
                           Every Azure operation uses the configured subscription;
                           the user's default subscription is not changed.

No Az PowerShell modules, Pester, .NET SDK, community image scripts or media
binaries need to be installed separately. Hyper-V, DISM, AD DS, DNS, IIS, file
server and in-box .NET compilation are handled on the new host/guests.
Initial sign-in, subscription/RBAC/quota, media licensing/hash selection and
optional appliance registration remain operator responsibilities.

CHECK STATUS / RESUME
---------------------
  .\Install.ps1 -Action Status
  .\Install.ps1 -Action Status -GuestChecks -Approve
  .\Install.ps1 -Action Validate
  .\Install.ps1 -Action Validate -Online -GuestChecks -Approve

Default Status reads only Azure resource and power-state information. It does
NOT claim guests are healthy. -GuestChecks explicitly authorizes Azure Run
Command to run read-only probes inside the owned host/guests; the control-plane
request and local command file are writes, but the probe does not repair,
start/restart VMs or install software. Online Validate returns a failure if
any expected guest check is missing, unavailable or unhealthy.

Install returns once the host's SYSTEM startup task is launched; this is NOT a
claim installation finished. The task handles Hyper-V's reboot and continues
from successful durable checkpoints. It also runs on later host starts.

If a step fails, correct the identified prerequisite and rerun the SAME command
with the SAME config and guest password. Already successful steps are skipped;
credentials are compared, not silently reset. Changing the configuration after
provisioning is rejected rather than destructively reconciling resources.
The installer never starts a deallocated Azure VM: start only your owned lab
host explicitly in Azure when required, then rerun or allow the startup task.

ARCHITECTURE
------------
  Dedicated tagged resource group (no adoption of arbitrary existing resources)
    Standard-security, generation-2 Windows Server 2022 Azure host
    Default: Standard_E16ds_v5, 16 vCPU / 128 GiB
    Alternatives: Standard_E16ds_v6 (NVMe), Standard_D16s_v5 (64 GiB)
    OS disk + Premium_LRS data disk, LUN 0 -> L:
    Standard public IPv4; NSG and host firewall permit RDP from your /32 only
    Internal Hyper-V switch + NAT: 192.168.100.0/24 by default
      DEMO-DC01     .10   AD DS + DNS; three disabled sample users
      DEMO-FS01     .11   Real SMB DemoData share with sample content
      DEMO-APP01    .12   Real IIS HTTP + compiled TCP backend on port 9500
                          Optional REAL SQL Express 2022, TCP 1433
      DEMO-CLIENT01 .13   Compiled .NET TCP/HTTP/SMB dependency generator
                          Optional authenticated SqlClient/TDS workload
      DEMO-MIG01    .30   Optional workgroup appliance staging VM
                          8 vCPU, 16 GiB fixed RAM, 100 GiB virtual OS disk

Guest names, AD names, IPs and task names are deterministic from configuration.
Windows is applied to a read-only base VHDX; each guest has its own differencing
disk. VHDX files are on a persistent managed data disk, never Azure's ephemeral
NVMe local disks. Disk selection requires matching remote-disk model, LUN,
exact size and persisted identity; ambiguity fails without initialization.

Default workloads use REAL IIS and SMB plus a clearly generic TCP listener.
No process impersonates SQL Server. Set Sql.Enabled only after supplying the
official full SQL Express 2022 offline package URL and independent SHA256.
The installer verifies its Microsoft signature, installs an isolated HVLAB
instance with Windows authentication, and grants the CLIENT01 computer a login
for SELECT 1 traffic. No SQL password/product key is required or bundled.

Long-lived TCP/SMB (and optional TDS) connections aid dependency observation.
HTTP is exercised periodically. SMB sockets may be attributed to System rather
than the app. This lab does not promise that a particular collection interval,
service account, dependency graph or application assessment will find everything.

MEDIA MODES
-----------
OfficialDownload:
  Windows ISO is downloaded on the Azure host from explicitly approved Microsoft
  HTTPS hosts; each redirect is validated, then full SHA256 is checked before
  mounting. Supply an independently trusted hash; computing a hash from an
  untrusted download alone does not establish provenance. Microsoft links/hashes
  can change; old hashes fail closed. No media is silently substituted.

HostFile:
  For operator-supplied licensed/evaluation ISO, set Uri='' and the absolute
  HostPath under C:\LabMedia or L:\LabMedia. Before invocation, obtain and
  verify that ISO, hash, WIM index and name. The installer may need to create
  the Azure host before it can access that path. It stops at Media if absent:
  use restricted RDP/your approved transfer procedure to stage the ISO on that
  owned host, then rerun Install. Provisioned resources keep costing money
  while waiting. Multi-gigabyte proprietary media is not sent in Run Command
  or copied into this repository. The host validates the staged ISO before use.

APPLIANCE BOUNDARY
------------------
Appliance.Enabled defaults false. When enabled, the installer creates the
correctly sized guest, prepares host/guest WinRM connectivity and stages the
hash/signature-verified Microsoft multi-scenario installer. It does NOT run
the appliance installer or register anything in Azure Migrate.
Read docs\APPLIANCE.txt. Explicitly select HYPER-V in Microsoft's installer and
portal; Physical is not an equivalent Hyper-V discovery appliance. The UI is
reachable from the host browser only; no 44368 public port forwarding is added.

COST, OWNERSHIP AND RESPONSIBILITIES
----------------------------------
Read-only runtime preflight checks subscription, SKU/image generation/controller,
regional and family vCPU quota, ownership, VM agent and power state. Bicep
compilation, ARM validation and what-if precede first resource creation.
Preflight is not a capacity reservation, price guarantee or permission to
modify unrelated resources. Standard security is deliberate for nested
virtualization; v6 requires NVMe-capable image/storage configuration.

Review current Azure pricing before invocation. Compute, Premium storage,
public IP, traffic and optional Migrate features can incur costs. The daily
shutdown schedule defaults to 22:00 UTC. Storage/IP charges remain while the
host is deallocated. Shutdown/update/reboot interrupts nested workloads;
there is no uptime or data-loss guarantee. Do not use this lab for production.
Windows Update remains enabled; schedule maintenance around your experiments.

There is no cleanup/destruction command. The installer does not delete resource
groups, resize unrelated hosts, stop/start a subscription or touch existing
customer VMs. You own RBAC, MFA, patching, license compliance, credentials,
backups, cost monitoring and eventual manual deletion of your dedicated group.

VERIFICATION BOUNDARY (IMPORTANT)
--------------------------------
The historical Hyper-V base underlying this work was executed successfully.
This NEW packaging/orchestration was NOT freshly deployed end-to-end in Azure.
Local checks cover PowerShell 5.1/7 parsing, pure configuration and disk-selection
logic, ownership rejection, credential redaction, native error propagation,
checkpoint behavior, payload allowlisting, generated transport-script parsing,
mocked install/resume and unsafe what-if rejection, offline Plan behavior, Bicep
compilation, and in-box C# compilation/self-test.

Azure deployment, Hyper-V guest boot, AD promotion, Windows/SQL setup, WinNAT,
reboot recovery on a real host and Azure Migrate registration still require an
authorized disposable-environment integration run. Do not mistake passing
offline tests or "scheduled" output for a validated deployment.

FILES
-----
Install.ps1                  Single user-facing entrypoint
config.example.psd1          Non-secret template; local copy ignored
src\Lab.psm1                 Config/preflight/ownership/transport/actions
infra\main.bicep             Subscription deployment + owned resource group
infra\host.bicep             Azure host, network, disks and shutdown schedule
host\Runner.ps1              Internal scheduled-task entrypoint
host\Engine.psm1             Checkpoints, media/image/VM/domain/workload pipeline
host\Guest.ps1               Internal PowerShell Direct actions and health probes
workloads\DependencyDemo.cs  Source-only compiled demo; no bundled executables
tests\Test-Local.ps1         Offline self-contained assertions
.github\workflows\validate.yml  Offline Windows CI; never deploys
docs\OPERATIONS.txt          Diagnostics, restart, testing and known boundaries
docs\SECURITY.txt            Secret lifecycle, firewall and trust model
docs\APPLIANCE.txt           Mandatory interactive Hyper-V discovery steps

The internal files are implementation details, not a checklist of scripts to
invoke manually. No original repository history, private configuration,
inventories, logs, appliance keys or proprietary binaries is packaged.
