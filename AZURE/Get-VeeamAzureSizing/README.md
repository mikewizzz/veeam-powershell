# Veeam Backup for Azure - Sizing & Discovery Tool

Professional Azure assessment tool that analyzes your environment and delivers production-ready sizing recommendations with Microsoft-style deliverables.

## Features

- **Azure inventory** - VMs, SQL, Storage, and existing backup configurations
- **Veeam sizing** - Snapshot storage and repository capacity calculations
- **Professional reports** - HTML with Microsoft Fluent Design System
- **Modern authentication** - Managed Identity, certificates, interactive browser, device code
- **Session management** - Automatic token reuse, no repeated logins
- **Progress tracking** - Real-time status for long-running operations

## Quick Start

**Download and run:**
```powershell
.\Get-VeeamAzureSizing.ps1
```

The script will:
1. Check for required Azure PowerShell modules
2. Open browser for Azure authentication
3. Analyze all accessible subscriptions
4. Generate HTML report and CSV exports
5. Create ZIP archive with all deliverables

## Prerequisites

**PowerShell modules:**
```powershell
Install-Module Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices -Scope CurrentUser
```

**Azure permissions:**
- `Reader` role on target subscription(s)
- `Backup Reader` for Azure Backup analysis (optional)

**PowerShell version:**
- PowerShell 7.x (recommended)
- PowerShell 5.1 supported

## Authentication

### Interactive Browser (Default)
```powershell
.\Get-VeeamAzureSizing.ps1
```

### Managed Identity (Azure VMs)
```powershell
.\Get-VeeamAzureSizing.ps1 -UseManagedIdentity
```

### Service Principal with Certificate
```powershell
.\Get-VeeamAzureSizing.ps1 -ServicePrincipalId "app-id" -CertificateThumbprint "thumbprint" -TenantId "tenant-id"
```

### Device Code Flow (Headless)
```powershell
.\Get-VeeamAzureSizing.ps1 -UseDeviceCode
```

## Parameters

### Filtering
- `-Subscriptions <string[]>` - Target specific subscriptions
- `-Region <string>` - Filter by Azure region
- `-TagFilter <hashtable>` - Filter VMs by tags: `@{"Environment"="Prod"}`

### Sizing Configuration
- `-SnapshotRetentionDays <int>` - Snapshot retention (default: 14)
- `-RepositoryOverhead <double>` - Repository multiplier (default: 1.2)

### Discovery Options
- `-CalculateBlobSizes` - Enumerate all blobs (slower)
- `-IncludeAzureBackupPricing` - Query Azure Retail Prices API

### Output
- `-OutputPath <string>` - Custom output folder
- `-GenerateHTML` - Create HTML report (default: true)
- `-ZipOutput` - Create ZIP archive (default: true)

## Examples

**Specific subscription and region:**
```powershell
.\Get-VeeamAzureSizing.ps1 -Subscriptions "Production" -Region "eastus"
```

**Filter by tags:**
```powershell
.\Get-VeeamAzureSizing.ps1 -TagFilter @{"Environment"="Production"; "Backup"="Required"}
```

**Custom Veeam sizing:**
```powershell
.\Get-VeeamAzureSizing.ps1 -SnapshotRetentionDays 30 -RepositoryOverhead 1.5
```

**Managed Identity automation:**
```powershell
.\Get-VeeamAzureSizing.ps1 -UseManagedIdentity -Subscriptions "sub-id"
```

## Output Files

**Primary deliverable:**
- `assessment_report.html` - Executive summary and detailed findings

**Detailed data:**
- `azure_vms.csv` - VM inventory with Veeam sizing
- `azure_sql_databases.csv` - SQL Database details
- `azure_sql_managed_instances.csv` - Managed Instance details
- `azure_files.csv` - Azure Files inventory
- `azure_blob.csv` - Blob container inventory
- `azure_backup_vaults.csv` - Existing backup vaults
- `veeam_sizing_summary.csv` - Aggregate recommendations
- `execution_log.csv` - Complete operation log

**Archive:**
- `VeeamAzureSizing_[timestamp].zip` - All files bundled

## Sizing Methodology

**Snapshot Storage:**
```
Capacity (GB) × (Retention Days / 30) × 10% daily change rate
```

**Repository Capacity:**
```
Source Data (GB) × Overhead Multiplier
```

**Example:**
- 500 GB VM, 14-day retention → 23.3 GB snapshot storage
- 1000 GB source data, 1.2 overhead → 1200 GB repository

## Troubleshooting

**Missing modules:**
```powershell
Install-Module Az -Scope CurrentUser
```

**Access denied:**
- Verify `Reader` role on subscription
- Check conditional access policies
- Try `-UseDeviceCode` for restricted environments

**No subscriptions found:**
- Verify authentication succeeded
- Check subscription access
- Specify `-TenantId` explicitly

**Slow execution:**
- Omit `-CalculateBlobSizes` for faster runs
- Use `-Region` or `-TagFilter` to reduce scope

## Best Practices

**For Sales Engineers:**
- Use default parameters for quick assessments
- Add `-CalculateBlobSizes` for detailed storage analysis
- Adjust retention and overhead based on customer requirements

**For Production:**
- Use Managed Identity or certificate-based authentication
- Schedule regular runs for capacity planning
- Archive historical reports for trend analysis
- Use tag filtering for targeted assessments

**For Performance:**
- Skip blob size calculation unless needed
- Use regional or tag scoping for large environments
- Run during off-peak hours for production assessments

## Support

- **Sales Engineers** - Contact your Veeam Solutions Architect
- **Customers** - Contact your Veeam Account Team
- **Partners** - Access Veeam Partner Portal

---

**© 2026 Veeam Software**
