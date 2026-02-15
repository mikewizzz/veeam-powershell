# New-VeeamSureBackupSetup

**Simplified SureBackup Setup Wizard for Veeam Backup & Replication**

SureBackup is one of the most powerful features in Veeam B&R -- automated backup verification that actually boots your VMs and confirms they work. But setting it up (Virtual Labs, network isolation, proxy appliances, Application Groups) is the #1 pain point for on-prem customers.

This tool eliminates that complexity. Answer a few questions (or provide parameters) and it creates everything for you.

## What This Tool Creates

| Component | What It Is | Why It's Hard |
|---|---|---|
| **Virtual Lab** | Isolated network environment where VMs boot from backups | Proxy appliance IP config, isolated subnets, masquerading rules, datastore selection |
| **Application Group** | Ordered list of VMs to verify with boot tests | Figuring out startup order, delays between VMs, which tests to run |
| **SureBackup Job** | Orchestrates the entire verification process | Tying it all together correctly |

## Quick Start

```powershell
# Interactive wizard - discovers everything and walks you through it
.\New-VeeamSureBackupSetup.ps1

# Specify the backup job, wizard handles the rest
.\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -Prefix "Prod"

# Fully automated - zero prompts
.\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -HostName "esxi01" -Auto

# Preview mode - see what would be created without making changes
.\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -WhatIf
```

## Prerequisites

- **Veeam Backup & Replication 12+** with PowerShell snap-in installed
- **PowerShell 5.1+** (7.x recommended)
- **Run as Administrator** on the VBR server (or machine with VBR console)
- **At least one backup job** with restore points
- **Managed infrastructure** (VMware vCenter/ESXi or Hyper-V hosts) added to VBR

## Supported Platforms

| Platform | Virtual Lab Type | Auto-Detection |
|---|---|---|
| VMware vSphere | vSphere Virtual Lab with proxy appliance | ESXi hosts, vCenter, datastores, port groups |
| Microsoft Hyper-V | Hyper-V Virtual Lab with network isolation | Hyper-V hosts, clusters, virtual switches |

The tool auto-detects your platform from VBR's managed infrastructure. If both are present, you choose which to use.

## Parameters

### Core Selection

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-BackupJobName` | string | *(interactive)* | Backup job to verify. Wizard shows available jobs if omitted. |
| `-HostName` | string | *(interactive)* | ESXi host or Hyper-V server for the Virtual Lab. |
| `-DatastoreName` | string | *(most free space)* | Datastore/volume for Virtual Lab storage. |

### Naming

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Prefix` | string | `SB` | Naming prefix. Produces: `SB-VirtualLab`, `SB-AppGroup`, `SB-SureBackupJob`. |

### Network Configuration

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-IsolatedNetworkPrefix` | string | `10.99` | First two octets for isolated subnets. Each production network gets its own /24. |
| `-ProxyApplianceIp` | string | `10.99.0.1` | IP address for the Virtual Lab proxy appliance. |
| `-ProxyApplianceNetmask` | string | `255.255.255.0` | Subnet mask for the proxy appliance. |

### Application Group

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-MaxVmsToVerify` | int | `10` | Max VMs to include. DCs are prioritized, then smallest VMs first. |
| `-VerificationTests` | string[] | `Heartbeat` | Tests per VM: `Heartbeat`, `Ping`, or `Script`. |
| `-StartupTimeout` | int | `300` | Seconds to wait for each VM to boot before failing. |

### Behavior

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-Auto` | switch | `false` | Skip all prompts. Uses defaults or provided values. |
| `-WhatIf` (common) | switch | `false` | PowerShell common parameter. Preview mode: shows what would be created without making changes. |

> **Note:** `-WhatIf` is provided by PowerShell as a common parameter via `CmdletBinding(SupportsShouldProcess = $true)`. It is not declared in the script's `param()` block, but can still be used as shown in the examples.

### Output

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-OutputPath` | string | `$PSScriptRoot\SureBackupSetup_[timestamp]` | Folder for the HTML report. |
| `-GenerateHTML` | switch | `true` | Generate a professional HTML summary report. |

## How It Works

### Step-by-Step Flow

```
1. Connect           Connect to local VBR server, load PowerShell snap-in
2. Detect Platform   Auto-detect VMware vs Hyper-V from managed infrastructure
3. Select Job        Choose which backup job to verify (or auto-select)
4. Select Host       Choose ESXi/Hyper-V host for Virtual Lab (or auto-select)
5. Configure Storage Pick datastore/volume (auto-selects most free space)
6. Build Networks    Auto-generate isolated network mappings with DHCP + masquerading
7. Validate          Pre-flight checks (naming conflicts, disk space, restore points)
8. Create            Build Virtual Lab + Application Group + SureBackup Job
```

### Network Isolation (The Hard Part, Simplified)

The #1 confusion with SureBackup is network isolation. Here's what this tool does automatically:

```
Production Network          Isolated Network (auto-generated)
==================          =================================
VM Network (10.0.1.0/24)    -->  10.99.1.0/24  (Gateway: 10.99.1.1)
Server VLAN (10.0.2.0/24)   -->  10.99.2.0/24  (Gateway: 10.99.2.1)
DB Network (10.0.3.0/24)    -->  10.99.3.0/24  (Gateway: 10.99.3.1)

Proxy Appliance: 10.99.0.1
  - Routes between isolated and production networks
  - Masquerading (NAT) lets isolated VMs reach DNS/AD
  - DHCP: .10 - .200 in each isolated subnet
```

Each production network gets its own isolated /24 subnet. The proxy appliance handles masquerading so verified VMs can reach essential services (DNS, Active Directory) without touching production.

### VM Priority Logic

The tool automatically orders VMs for the Application Group:

1. **Domain Controllers first** -- detected by name pattern (dc, domain, ad, pdc, bdc)
2. **Smallest VMs next** -- boot faster, verify quicker
3. **Startup delays** -- DCs get no delay, others get 30s spacing

This ensures dependent services (AD/DNS) are running before application servers try to authenticate.

## Examples

### Example 1: First-Time Interactive Setup

```powershell
.\New-VeeamSureBackupSetup.ps1
```

The wizard will:
- Connect to VBR and detect your platform
- Show your backup jobs and let you pick one
- Show available hosts and datastores
- Auto-generate network mappings
- Show a full configuration summary
- Ask for confirmation before creating anything

### Example 2: Production Verification with Custom Networks

```powershell
.\New-VeeamSureBackupSetup.ps1 `
  -BackupJobName "Prod-Daily" `
  -Prefix "Prod" `
  -IsolatedNetworkPrefix "172.30" `
  -ProxyApplianceIp "172.30.0.1" `
  -MaxVmsToVerify 5
```

Uses a custom isolated network range (172.30.x.x) instead of the default 10.99.x.x.

### Example 3: Fully Automated for Scripting

```powershell
.\New-VeeamSureBackupSetup.ps1 `
  -BackupJobName "DC-Backup" `
  -HostName "esxi-prod-01" `
  -DatastoreName "SSD-Datastore" `
  -Prefix "DC" `
  -VerificationTests "Heartbeat","Ping" `
  -Auto
```

Zero prompts. Creates everything with the specified parameters and defaults.

### Example 4: Dry Run / Planning

```powershell
.\New-VeeamSureBackupSetup.ps1 -BackupJobName "Weekly Full" -WhatIf
```

Shows exactly what would be created (names, networks, VM order) without making any changes. Generates the HTML report for review.

### Example 5: Hyper-V Environment

```powershell
.\New-VeeamSureBackupSetup.ps1 `
  -BackupJobName "HV-Backup" `
  -HostName "hyperv-node01" `
  -Prefix "HV" `
  -Auto
```

Works the same way on Hyper-V. The tool auto-detects the platform and uses the appropriate Virtual Lab type.

## Output

### HTML Report

A professional HTML report is generated with:
- Configuration summary cards (lab name, app group, job name, source backup)
- Virtual Lab details (host, datastore, proxy appliance)
- Network isolation mapping table
- VM verification order with roles and sizes
- How-it-works explanation (useful for documentation)
- Full setup log with timestamps

### Console Output

Color-coded progress with step tracking:

```
  Step 1/8 (13%) : Connecting to Veeam Backup & Replication
  [2026-02-14 10:30:01] SUCCESS : Connected to VBR server
  Step 2/8 (25%) : Detecting Infrastructure Platform
  [2026-02-14 10:30:02] SUCCESS : Platform: VMware
  ...
  Step 8/8 (100%) : Creating SureBackup Objects
  [2026-02-14 10:30:15] SUCCESS : SureBackup setup completed successfully
```

## Troubleshooting

### "Veeam PowerShell snap-in/module not found"

- Install the Veeam Backup & Replication **console** (not just the server)
- Run PowerShell as Administrator
- On the VBR server, the snap-in is installed automatically

### "No backup jobs found"

- Create at least one backup job in the VBR console
- Run the backup job at least once to generate restore points
- SureBackup verifies from restore points, not from live VMs

### "No ESXi hosts / Hyper-V hosts found"

- Add your vCenter/ESXi hosts or Hyper-V servers to VBR's managed infrastructure
- VBR Console > Backup Infrastructure > Managed Servers

### "Virtual Lab name already exists"

- Use a different `-Prefix` parameter (e.g., `-Prefix "SB2"`)
- Or delete the existing Virtual Lab/App Group/Job from the VBR console

### "Datastore has less than 10 GB free"

- Virtual Lab needs space for the proxy appliance and redo logs
- Choose a datastore with at least 50 GB free for reliable operation
- VMs boot from backup files (not copied to the datastore), so space needs are modest

### Network Conflicts

- The default isolated prefix `10.99` avoids most production ranges
- If your production uses 10.99.x.x, change it: `-IsolatedNetworkPrefix "172.30"`
- The proxy IP should not conflict with any existing device

## Best Practices

1. **Start with WhatIf** -- preview the configuration before creating
2. **Use meaningful prefixes** -- `Prod-Exchange`, `DR-SQL` instead of `SB`
3. **Verify DCs first** -- the tool does this automatically, but confirm the order
4. **Keep MaxVmsToVerify reasonable** -- 3-5 VMs is usually enough for confidence
5. **Schedule weekly** -- after setup, schedule the SureBackup job for automated verification
6. **Check reports** -- SureBackup job results appear in VBR console under "Last 24 Hours"

## Architecture

```
New-VeeamSureBackupSetup.ps1
|
|-- Connect-VBRIfNeeded          Load snap-in, connect to VBR server
|-- Get-InfrastructurePlatform   Detect VMware vs Hyper-V
|-- Get-EligibleBackupJobs       Find jobs with restore points
|-- Get-JobVMs                   Extract and prioritize VMs
|-- Build-NetworkMapping         Auto-generate isolated subnets
|-- Test-Configuration           Pre-flight validation
|-- Show-ConfigurationSummary    Display plan for review
|-- New-SureBackupVirtualLab     Create Virtual Lab (VMware or Hyper-V)
|-- New-SureBackupAppGroup       Create Application Group with VM order
|-- New-SureBackupVerificationJob Create SureBackup Job
|-- Export-HTMLReport            Generate professional HTML report
```

## Known Limitations

- Script-based verification tests (`-VerificationTests "Script"`) require manual configuration of the test script path and credentials after setup
- DNS resolution test is not included in automated tests (use Ping + Heartbeat for most cases)
- The tool creates one Application Group per backup job. For multi-job SureBackup, run the tool multiple times with different prefixes
- Custom port-based application tests (e.g., verify SQL on port 1433) must be added manually after setup

## Version History

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-02-14 | Initial release. VMware + Hyper-V support, interactive wizard, auto mode, HTML reports. |
