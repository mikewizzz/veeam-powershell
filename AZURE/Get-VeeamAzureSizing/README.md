# Veeam Backup for Azure - Sizing & Discovery Tool

Community-maintained PowerShell script that inventories Azure infrastructure and delivers production-ready Veeam sizing recommendations with executive-grade HTML reports.

## Overview

- **Full Azure inventory** — VMs, SQL Databases, Managed Instances, Storage Accounts, Recovery Services Vaults
- **Veeam capacity planning** — Snapshot storage and repository sizing based on provisioned capacity and configurable parameters
- **Existing backup analysis** — Discovers Azure Backup vaults, policies, and protected item counts
- **Professional HTML report** — Microsoft Fluent Design System with KPI cards, executive summary, and methodology notes
- **Multi-format exports** — 8 CSV files + HTML report + execution log, bundled into a ZIP archive
- **Modern authentication** — Managed Identity, certificate-based SP, client secret, device code, interactive browser
- **Flexible scoping** — Filter by subscription, region, or VM tags

## Architecture

```
Get-VeeamAzureSizing/
├── Get-VeeamAzureSizing.ps1    # Orchestration (~240 lines)
└── lib/
    ├── Constants.ps1            # Unit conversions, Format-Storage, Escape-Html, tag helpers
    ├── Logging.ps1              # Write-Log (console + list), Write-ProgressStep
    ├── Auth.ps1                 # Module checks, Azure auth hierarchy, subscription resolution
    ├── DataCollection.ps1       # VM, SQL, Storage, Azure Backup inventory functions
    ├── Sizing.ps1               # Veeam snapshot + repository capacity calculations
    ├── Exports.ps1              # CSV exports, log export, ZIP archive
    └── HtmlReport.ps1           # Fluent Design HTML report generation
```

The main script is pure orchestration — all logic lives in the 7 library files, dot-sourced in dependency order.

## Quick Start

```powershell
.\Get-VeeamAzureSizing.ps1
```

The script will:
1. Verify required Azure PowerShell modules are installed
2. Open browser for Azure authentication (or reuse existing session)
3. Inventory all accessible subscriptions
4. Calculate Veeam sizing recommendations
5. Generate HTML report, CSV exports, and ZIP archive

## Prerequisites

**PowerShell modules:**
```powershell
Install-Module Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices -Scope CurrentUser
```

**Azure permissions:**

| Role | Scope | Purpose |
|------|-------|---------|
| `Reader` | Subscription(s) | VM, SQL, Storage inventory |
| `Backup Reader` | Subscription(s) | Recovery Services Vault analysis (optional) |
| `Storage Blob Data Reader` | Storage account(s) | Blob size enumeration (optional, with `-CalculateBlobSizes`) |

**PowerShell version:**
- PowerShell 7.x recommended
- PowerShell 5.1 supported

## Authentication

### Interactive Browser (Default)
```powershell
.\Get-VeeamAzureSizing.ps1
```

### Managed Identity (Azure VMs/Containers)
```powershell
.\Get-VeeamAzureSizing.ps1 -UseManagedIdentity
```

### Service Principal with Certificate (Recommended for Automation)
```powershell
.\Get-VeeamAzureSizing.ps1 -ServicePrincipalId "app-id" -CertificateThumbprint "thumbprint" -TenantId "tenant-id"
```

### Service Principal with Client Secret
```powershell
.\Get-VeeamAzureSizing.ps1 -ServicePrincipalId "app-id" -ServicePrincipalSecret $secret -TenantId "tenant-id"
```

### Device Code Flow (Headless/Remote)
```powershell
.\Get-VeeamAzureSizing.ps1 -UseDeviceCode
```

The script checks for an existing valid session before authenticating — no repeated logins within the token lifetime.

## Parameters

### Scope & Filtering

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Subscriptions` | string[] | All accessible | Target specific subscription IDs or names |
| `-TenantId` | string | Current tenant | Azure AD tenant ID |
| `-Region` | string | All regions | Filter resources by Azure region (e.g., `eastus`) |
| `-TagFilter` | hashtable | None | Filter VMs by tags: `@{"Environment"="Prod"}` |

### Authentication

| Parameter | Type | Description |
|-----------|------|-------------|
| `-UseManagedIdentity` | switch | Azure Managed Identity (VMs/containers) |
| `-ServicePrincipalId` | string | Application (client) ID |
| `-ServicePrincipalSecret` | securestring | Client secret (legacy — prefer certificate) |
| `-CertificateThumbprint` | string | Certificate thumbprint (recommended) |
| `-UseDeviceCode` | switch | Device code flow for headless scenarios |

### Sizing Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SnapshotRetentionDays` | int | 14 | Snapshot retention period (1-365) |
| `-RepositoryOverhead` | double | 1.2 | Repository overhead multiplier (1.0-3.0) |

### Discovery Options

| Parameter | Type | Description |
|-----------|------|-------------|
| `-CalculateBlobSizes` | switch | Enumerate all blobs to calculate container sizes (can be slow) |

### Output

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-OutputPath` | string | `./VeeamAzureSizing_[timestamp]` | Custom output folder |
| `-GenerateHTML` | switch | true | Generate HTML report |
| `-ZipOutput` | switch | true | Create ZIP archive |

## Output Files

| File | Description |
|------|-------------|
| `Veeam-Azure-Sizing-Report.html` | Executive HTML report with KPI cards, sizing tables, methodology |
| `azure_vms.csv` | VM inventory with disk details and Veeam sizing per VM |
| `azure_sql_databases.csv` | SQL Database details (edition, service objective, max size) |
| `azure_sql_managed_instances.csv` | Managed Instance details (vCores, storage, license type) |
| `azure_files.csv` | Azure File Shares (quota, usage) |
| `azure_blob.csv` | Blob containers (with size if `-CalculateBlobSizes`) |
| `azure_backup_vaults.csv` | Recovery Services Vaults (soft delete, immutability, protected items) |
| `azure_backup_policies.csv` | Backup policies (workload type, management type) |
| `veeam_sizing_summary.csv` | Aggregate sizing recommendations |
| `execution_log.csv` | Timestamped operation log |
| `VeeamAzureSizing_[timestamp].zip` | All files bundled |

## Examples

**Specific subscription and region:**
```powershell
.\Get-VeeamAzureSizing.ps1 -Subscriptions "Production" -Region "eastus"
```

**Filter by tags:**
```powershell
.\Get-VeeamAzureSizing.ps1 -TagFilter @{"Environment"="Production"; "Backup"="Required"}
```

**Custom sizing parameters:**
```powershell
.\Get-VeeamAzureSizing.ps1 -SnapshotRetentionDays 30 -RepositoryOverhead 1.5
```

**Managed Identity with specific subscriptions:**
```powershell
.\Get-VeeamAzureSizing.ps1 -UseManagedIdentity -Subscriptions "sub-id-1", "sub-id-2"
```

**Full storage analysis with blob enumeration:**
```powershell
.\Get-VeeamAzureSizing.ps1 -CalculateBlobSizes -Region "westeurope"
```

**Certificate-based automation:**
```powershell
.\Get-VeeamAzureSizing.ps1 `
  -ServicePrincipalId "00000000-0000-0000-0000-000000000000" `
  -CertificateThumbprint "A1B2C3D4E5F6..." `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -Subscriptions "Prod-Sub-1", "Prod-Sub-2" `
  -SnapshotRetentionDays 30
```

## Sizing Methodology

**Snapshot Storage:**
```
Provisioned Capacity (GB) x (Retention Days / 30) x 10% daily change rate
```

**Repository Capacity:**
```
Source Data (GB) x Overhead Multiplier
```

**SQL Repository:**
```
Max DB Size (GB) x 1.3 (30% overhead for compression/retention)
```

**Example calculations:**

| Workload | Source | Retention | Result |
|----------|--------|-----------|--------|
| 500 GB VM | 500 GB | 14 days | 24 GB snapshot + 600 GB repository |
| 100 GB SQL DB | 100 GB | N/A | 130 GB repository |
| 10 VMs x 200 GB | 2,000 GB | 30 days | 200 GB snapshot + 2,400 GB repository |

These are sizing estimates for capacity planning. Actual consumption varies based on backup configuration, data change rates, and compression ratios.

## Troubleshooting

**Missing modules:**
```powershell
Install-Module Az -Scope CurrentUser
```
The script checks for all 7 required modules at startup and provides the exact install command if any are missing.

**Access denied on Recovery Services:**
- Add `Backup Reader` role to the service principal or user account
- The script continues without backup data if permissions are insufficient

**No subscriptions found:**
- Verify authentication succeeded (`Get-AzContext`)
- Check subscription access permissions
- Specify `-TenantId` explicitly for multi-tenant scenarios

**Slow execution:**
- Omit `-CalculateBlobSizes` — blob enumeration is extremely slow on large storage accounts
- Use `-Region` to limit geographic scope
- Use `-TagFilter` to target specific workloads
- Use `-Subscriptions` to narrow to relevant subscriptions

**Lib file not found:**
- Ensure the `lib/` directory is alongside `Get-VeeamAzureSizing.ps1`
- All 7 library files must be present: Constants, Logging, Auth, DataCollection, Sizing, Exports, HtmlReport

## Known Limitations

1. **Blob size calculation is slow** — `-CalculateBlobSizes` enumerates every blob in every container. For large storage accounts with millions of blobs, this can take hours.
2. **Snapshot sizing assumes 10% daily change** — This is a conservative default. Actual change rates vary by workload.
3. **SQL sizing uses max provisioned size** — Not actual used space. Actual backup sizes will typically be smaller.
4. **Azure Backup item counts require vault context** — Each vault is queried individually, which adds time in environments with many vaults.
5. **Tag filtering applies to VMs only** — SQL, Storage, and Backup resources are not filtered by tags.

## License

MIT — see [LICENSE](../../M365/LICENSE)

## Contributing

1. Follow existing patterns in `lib/` files
2. Use approved PowerShell verbs (`Get-`, `Test-`, `Export-`, `Build-`)
3. Maintain PS 5.1 compatibility (no `??`, `?.`, ternary, `::new()`)
4. Wrap user-controlled values in `Escape-Html` before embedding in HTML
5. Add `Write-Log` calls for operation visibility
6. Test with `Invoke-ScriptAnalyzer` before submitting
