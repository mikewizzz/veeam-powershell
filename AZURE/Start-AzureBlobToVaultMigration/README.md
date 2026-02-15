# Azure Blob to Veeam Vault Migration Tool

Pre-flight assessment and guided migration tool for moving backup data from Azure Blob Storage to Veeam Vault.

## Why Migrate to Veeam Vault?

| Feature | Azure Blob (DIY) | Veeam Vault |
|---------|-------------------|-------------|
| **Pricing** | Storage + egress + API ops (variable) | $14/TB/month all-inclusive |
| **Egress Fees** | ~$0.087/GB | Zero |
| **API Operations** | Per-transaction charges | Included |
| **Immutability** | Extra API cost for validation | Built-in, no extra cost |
| **Commitment** | 1-3 year reservations for discounts | Month-to-month |
| **Management** | Self-managed storage account | Fully managed by Veeam |

## Quick Start

### Assessment Only (Read-Only)

```powershell
# Run from the VBR server - no changes made
.\Start-AzureBlobToVaultMigration.ps1 -AssessOnly
```

This generates a comprehensive report showing:
- VBR version and license validation
- All Azure Blob SOBR extents and their data volumes
- Network connectivity checks
- Migration time estimates
- Step-by-step migration guide

### Full Migration

```powershell
# Step 1: Assess environment
.\Start-AzureBlobToVaultMigration.ps1 -AssessOnly

# Step 2: Deploy gateway and plan migration
.\Start-AzureBlobToVaultMigration.ps1 `
  -TargetVaultName "VeeamVault-01" `
  -GatewayRegion "eastus" `
  -GatewayResourceGroup "rg-veeam-migration" `
  -GatewayVNetName "vnet-backup"

# Step 3: Execute evacuation (after gateway is registered in VBR)
.\Start-AzureBlobToVaultMigration.ps1 `
  -TargetVaultName "VeeamVault-01" `
  -SkipGatewayDeploy `
  -ExecuteEvacuate
```

## Prerequisites

| Requirement | Minimum | Notes |
|-------------|---------|-------|
| **VBR Version** | 12.3+ | Required for Veeam Vault support |
| **PowerShell** | 5.1+ | PowerShell 7.x recommended |
| **VBR PowerShell** | VeeamPSSnapIn or Veeam.Backup.PowerShell | Installed with VBR Console |
| **Azure Modules** | Az.Accounts, Az.Compute, Az.Network, Az.Storage | For gateway deployment |
| **Network** | HTTPS (443) outbound | To Azure APIs and vault.veeam.com |

Install Azure modules if needed:

```powershell
Install-Module Az.Accounts, Az.Compute, Az.Network, Az.Storage -Scope CurrentUser
```

## Parameters

### Connection

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `VBRServer` | No | localhost | VBR server hostname or IP |
| `VBRPort` | No | 9392 | VBR console port |
| `VBRCredential` | No | Current user | PSCredential for VBR authentication |

### Mode

| Parameter | Description |
|-----------|-------------|
| `AssessOnly` | Read-only assessment. No changes made to the environment |
| `ExecuteEvacuate` | Execute the data evacuation after all checks pass |

### Migration Target

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TargetVaultName` | Yes (migrate mode) | Name of the Veeam Vault repository in VBR |

### Gateway Configuration

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `GatewayVmSize` | No | Standard_D4s_v5 | Azure VM size for the gateway |
| `GatewayRegion` | Migrate mode | - | Azure region (match your Blob storage region) |
| `GatewayResourceGroup` | Migrate mode | - | Azure resource group for the gateway VM |
| `GatewayVNetName` | Migrate mode | - | Existing VNet with connectivity to Blob and VBR |
| `GatewaySubnetName` | No | default | Subnet within the VNet |
| `SkipGatewayDeploy` | No | false | Skip gateway deployment (use existing) |

### Other

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MaxConcurrentTasks` | 4 | Concurrent data transfer tasks (1-16) |
| `OutputPath` | Auto-generated | Custom output folder for reports |

## Migration Workflow

```
┌─────────────────────────────────────────────────────────────────────┐
│                    MIGRATION WORKFLOW                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. Pre-Flight Assessment    ← You are here (run -AssessOnly)       │
│     • Validate VBR version, license, connectivity                   │
│     • Discover Azure Blob SOBR extents                              │
│     • Estimate data volume and transfer time                        │
│                                                                     │
│  2. Add Veeam Vault Repository                                      │
│     • VBR Console > Backup Infrastructure > Add Repository          │
│     • Select Veeam Vault, provision capacity                        │
│                                                                     │
│  3. Deploy Gateway Server                                           │
│     • Linux VM in Azure (same region as Blob)                       │
│     • Automated via this script or manual in Azure Portal           │
│                                                                     │
│  4. Register Gateway in VBR                                         │
│     • Add as Managed Server > Linux in VBR Console                  │
│                                                                     │
│  5. Update SOBR Configuration                                       │
│     • Replace Azure Blob capacity tier with Veeam Vault             │
│     • Assign gateway as data transfer proxy                         │
│                                                                     │
│  6. Evacuate (Data Move)                                            │
│     • Start-VBRRepositoryEvacuate moves data to Vault               │
│     • Runs in background, backups continue normally                 │
│                                                                     │
│  7. Validate & Clean Up                                             │
│     • Verify backup chains are intact                               │
│     • Decommission Azure Blob storage and gateway VM                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Output Files

| File | Description |
|------|-------------|
| `migration_assessment_report.html` | Professional HTML report with all findings and step-by-step guide |
| `preflight_checks.csv` | All pre-flight check results with remediation steps |
| `azure_blob_extents.csv` | Discovered Azure Blob extents with data volumes |
| `migration_log.csv` | Timestamped execution log |

## Examples

### Assess a Remote VBR Server

```powershell
$cred = Get-Credential -Message "VBR admin credentials"
.\Start-AzureBlobToVaultMigration.ps1 -AssessOnly -VBRServer "vbr01.contoso.com" -VBRCredential $cred
```

### Deploy Gateway with Custom VM Size

```powershell
.\Start-AzureBlobToVaultMigration.ps1 `
  -TargetVaultName "VeeamVault-01" `
  -GatewayVmSize "Standard_D8s_v5" `
  -GatewayRegion "westeurope" `
  -GatewayResourceGroup "rg-veeam-gw" `
  -GatewayVNetName "vnet-prod" `
  -GatewaySubnetName "snet-backup"
```

### Execute Migration with Higher Parallelism

```powershell
.\Start-AzureBlobToVaultMigration.ps1 `
  -TargetVaultName "VeeamVault-01" `
  -SkipGatewayDeploy `
  -ExecuteEvacuate `
  -MaxConcurrentTasks 8
```

## Troubleshooting

### VBR PowerShell Snap-in Not Found

```
[FAIL] PowerShell Snap-in - Cannot load Veeam PowerShell components
```

**Fix:** Run the script from the VBR server, or install the VBR Console on your workstation. The Veeam PowerShell module is included with the VBR Console installation.

### VBR Version Too Old

```
[FAIL] VBR Version - Version 12.1.0 is below minimum 12.3.0
```

**Fix:** Upgrade VBR to version 12.3 or later. Veeam Vault integration requires v12.3+.

### No Azure Blob Extents Found

```
[WARN] Azure Blob Extents - No Azure Blob storage extents found in any SOBR
```

**Fix:** Verify that Azure Blob is configured as a capacity tier in your Scale-Out Backup Repository. Check VBR Console > Backup Infrastructure > Scale-Out Repositories.

### Cannot Reach Azure or Veeam Vault Endpoints

```
[WARN] Azure Management API - Cannot reach Azure Management API
[WARN] Veeam Vault Endpoint - Cannot reach Veeam Vault endpoint
```

**Fix:** Check outbound HTTPS (443) firewall rules. Both `management.azure.com` and `vault.veeam.com` must be reachable.

## Best Practices

1. **Always run assessment first** - Use `-AssessOnly` before any migration
2. **Match gateway region** - Deploy the gateway in the same Azure region as your Blob storage
3. **Schedule during low-activity windows** - Evacuation uses bandwidth; run during off-hours
4. **Monitor in VBR Console** - Track evacuation progress under Backup Infrastructure > SOBR
5. **Keep backups running** - Evacuation runs alongside normal backup operations
6. **Validate before cleanup** - Verify all data is accessible from Vault before deleting Blob storage

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-02-15 | Initial release - assessment, gateway deployment, guided migration |
