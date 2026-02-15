# Pure Storage FlashArray Snapshot Recovery to VMware

Recovery tool that restores Veeam-protected VMs from Pure Storage FlashArray snapshots to VMware vSphere infrastructure, designed for integration with Veeam Recovery Orchestrator (VRO).

## Overview

When Veeam VMs reside on Pure Storage FlashArray datastores, this script provides a complete recovery workflow:

```
Pure Storage Snapshot -> Clone Volume -> Present to ESXi -> Mount VMFS -> Register VMs -> Verify
```

### Key Capabilities

- **Snapshot Discovery** - Browse Protection Groups and select point-in-time snapshots
- **Volume Cloning** - Create FlashArray clones from selected snapshots (instant, space-efficient)
- **Auto Host Mapping** - Automatically detects FC/iSCSI host group mappings between Pure and ESXi
- **VMFS Resignature** - Handles VMFS snapshot resignaturing for safe parallel mount
- **VM Registration** - Registers VMs with name prefix to avoid conflicts with source VMs
- **Network Remapping** - Optionally reconfigure VM NICs to a target port group
- **UUID Conflict Handling** - Automatically answers "I Copied It" for VM UUID questions
- **HTML Reporting** - Professional recovery report with action log and VM inventory
- **WhatIf Support** - Preview mode to validate recovery plan without making changes
- **Cleanup on Failure** - Automatic rollback of cloned volumes and datastores if recovery fails

## Prerequisites

### Required PowerShell Modules

```powershell
# Pure Storage PowerShell SDK 2
Install-Module -Name PureStoragePowerShellSDK2 -Scope CurrentUser -Force

# VMware PowerCLI
Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force
```

### Requirements

| Component | Requirement |
|-----------|-------------|
| PowerShell | 7.x (recommended) or 5.1 |
| Pure Storage | FlashArray with Protection Groups configured |
| VMware | vCenter Server 7.0+ with connected ESXi hosts |
| Network | Management access to FlashArray and vCenter APIs |
| Storage | FC or iSCSI connectivity between FlashArray and ESXi hosts |
| Pure Host Config | ESXi hosts registered as hosts/host groups on FlashArray |

### Pure Storage Setup

Before running this script, ensure:

1. **Protection Groups** are configured with the VM datastore volumes as members
2. **Snapshots** exist (scheduled or manual) for the protection group
3. **Host/Host Group** entries exist on the FlashArray matching the ESXi hosts (by WWN or IQN)

## Quick Start

```powershell
# Interactive mode - prompts for everything
.\Restore-VRO-PureStorage-VMware.ps1 `
  -FlashArrayEndpoint "pure01.corp.local" `
  -VCenterServer "vcsa.corp.local"
```

## Usage Examples

### Basic Recovery with API Token

```powershell
.\Restore-VRO-PureStorage-VMware.ps1 `
  -FlashArrayEndpoint "pure01.corp.local" `
  -PureApiToken "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -VCenterServer "vcsa.corp.local" `
  -VCenterCredential (Get-Credential) `
  -ProtectionGroupName "PG-VeeamVMs" `
  -TargetHostName "esxi01.corp.local"
```

### Recover Specific VMs with Network Remapping

```powershell
.\Restore-VRO-PureStorage-VMware.ps1 `
  -FlashArrayEndpoint "pure01.corp.local" `
  -PureApiToken $token `
  -VCenterServer "vcsa.corp.local" `
  -VCenterCredential $vcCred `
  -ProtectionGroupName "PG-VeeamVMs" `
  -VMNames @("SQL-Prod-01", "APP-Prod-01") `
  -TargetPortGroup "VLAN100-Recovery" `
  -VMNamePrefix "DR-" `
  -PowerOnVMs
```

### DR Test with Preview Mode

```powershell
# See what would happen without making changes
.\Restore-VRO-PureStorage-VMware.ps1 `
  -FlashArrayEndpoint "pure01.corp.local" `
  -PureApiToken $token `
  -VCenterServer "vcsa.corp.local" `
  -ProtectionGroupName "PG-VeeamVMs" `
  -WhatIf
```

### Fully Automated (VRO Integration)

```powershell
# No interactive prompts - all parameters specified
$pureToken = Get-Content "C:\secure\pure-token.txt"
$vcCred = Import-Clixml "C:\secure\vcenter-cred.xml"

.\Restore-VRO-PureStorage-VMware.ps1 `
  -FlashArrayEndpoint "pure01.corp.local" `
  -PureApiToken $pureToken `
  -VCenterServer "vcsa.corp.local" `
  -VCenterCredential $vcCred `
  -ProtectionGroupName "PG-VeeamVMs" `
  -SnapshotName "PG-VeeamVMs.2026-02-15T02:00:00Z" `
  -TargetHostName "esxi-dr-01.corp.local" `
  -HostGroupName "ESXi-DR-Cluster" `
  -TargetPortGroup "VLAN200-DR" `
  -TargetFolder "DR-Recovery" `
  -VMNamePrefix "DR-" `
  -PowerOnVMs `
  -OutputPath "C:\Recovery\Output"
```

## Parameters

### Connection Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `FlashArrayEndpoint` | String | Yes | FQDN or IP of the FlashArray management interface |
| `PureApiToken` | String | No | API token for Pure Storage authentication (recommended) |
| `PureCredential` | PSCredential | No | Credential object for Pure Storage (alternative to token) |
| `VCenterServer` | String | Yes | FQDN or IP of the vCenter Server |
| `VCenterCredential` | PSCredential | No | Credential object for vCenter (prompts if omitted) |

### Snapshot Selection

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ProtectionGroupName` | String | (interactive) | Pure Storage Protection Group name |
| `SnapshotName` | String | (interactive) | Specific snapshot name to restore from |

### Target Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `TargetHostName` | String | (interactive) | ESXi host for VM registration |
| `TargetDatastoreName` | String | auto-generated | Name for the recovered datastore |
| `TargetPortGroup` | String | (keep original) | VMware port group for recovered VM NICs |
| `TargetFolder` | String | `Recovered-VMs` | vCenter VM folder for recovered VMs |
| `TargetResourcePool` | String | host default | Resource pool for recovered VMs |
| `VMNamePrefix` | String | `REC-` | Prefix added to recovered VM names |
| `VMNames` | String[] | (all VMs) | Filter to specific VM names |
| `PowerOnVMs` | Switch | false | Power on VMs after registration |

### Storage Options

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `HostGroupName` | String | auto-detect | Pure Storage Host Group for volume presentation |
| `Protocol` | String | `Auto` | Storage protocol: `FC`, `iSCSI`, or `Auto` |

### Behavior

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `CleanupOnFailure` | Bool | true | Remove cloned volumes/datastores if recovery fails |
| `SkipDatastoreRescan` | Switch | false | Skip ESXi storage rescan |
| `WhatIf` | Switch | false | Preview mode - no changes made |

### Output

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `OutputPath` | String | `./PureRecovery_<timestamp>` | Output directory for reports |
| `GenerateHTML` | Bool | true | Generate HTML recovery report |
| `ZipOutput` | Bool | true | Create ZIP archive of outputs |

## Output Files

| File | Description |
|------|-------------|
| `RecoveryReport.html` | Professional HTML report with status, VM details, and action log |
| `RecoveryLog.csv` | Timestamped log of all recovery operations |
| `RecoveryActions.csv` | Structured action log with status tracking |
| `RecoveredVMs.csv` | Inventory of all recovered VMs with configuration details |

## Recovery Workflow Detail

```
1. PREREQUISITES       Check PureStoragePowerShellSDK2 and VMware.PowerCLI modules
                       |
2. CONNECT PURE        Authenticate to FlashArray (API token or credential)
                       |
3. CONNECT VCENTER     Authenticate to vCenter (credential or existing session)
                       |
4. SELECT SNAPSHOT     List Protection Groups -> List Snapshots -> Select one
                       |
5. DISCOVER VOLUMES    Enumerate volume snapshots within the PG snapshot
                       |
6. SELECT HOST         Choose target ESXi host for recovery
                       |
7. CLONE VOLUMES       Create new FlashArray volumes from snapshot (instant clone)
                       |
8. PRESENT TO HOST     Connect cloned volumes to ESXi host group (FC/iSCSI)
                       |
9. MOUNT DATASTORE     Rescan storage -> Resignature VMFS -> Mount datastore
                       |
10. REGISTER VMs       Find VMX files -> Register VMs -> Remap network -> Power on
                       |
11. REPORT             Generate HTML report, export CSVs, create ZIP archive
```

## Veeam Recovery Orchestrator Integration

This script is designed to be called as a **Plan Step** within Veeam Recovery Orchestrator:

1. In VRO, create a new **Recovery Plan**
2. Add a **Run Script** step
3. Point to this script with the required parameters
4. Use VRO variables to pass connection details and snapshot selection
5. The script's exit code and HTML report integrate with VRO's reporting

### VRO Plan Step Example

```
Script Path: \\share\scripts\Restore-VRO-PureStorage-VMware.ps1
Arguments: -FlashArrayEndpoint "%PureArrayIP%" -PureApiToken "%PureToken%" -VCenterServer "%VCenterIP%" -ProtectionGroupName "%PGName%" -TargetHostName "%DRHost%" -PowerOnVMs
```

## Troubleshooting

### Common Issues

| Issue | Solution |
|-------|----------|
| "Module missing: Pure Storage PowerShell SDK 2" | Run `Install-Module PureStoragePowerShellSDK2 -Scope CurrentUser` |
| "Module missing: VMware PowerCLI" | Run `Install-Module VMware.PowerCLI -Scope CurrentUser` |
| "Could not auto-detect Host Group mapping" | Ensure ESXi host WWNs/IQNs are registered on the FlashArray |
| "No unresolved VMFS volumes found" | The datastore may have auto-mounted; check vCenter for new datastores |
| "Failed to locate recovered datastore" | Try running with `-SkipDatastoreRescan:$false` and manually rescan storage |
| VM UUID conflict question | The script handles this automatically with `AnswerSourceVM` (default: true) |

### Generating a Pure Storage API Token

```powershell
# Via Pure Storage GUI: Settings -> Users -> API Tokens -> Create
# Or via CLI:
ssh pureuser@pure01.corp.local
pureadmin create --api-token myuser
```

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-02-15 | Initial release - full recovery workflow with HTML reporting |
