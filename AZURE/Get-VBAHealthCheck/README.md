# Veeam Backup for Azure - Health Check & Compliance Assessment

Professional health check tool for Veeam Backup for Azure (VBA) deployments. Analyzes protection coverage, backup job health, security posture, snapshot hygiene, repository configuration, and network readiness — then calculates a weighted health score with actionable recommendations.

## Features

- **Weighted Health Score (0-100)** across 7 categories with letter grades
- **Protection Coverage Analysis** — VMs, SQL Databases, Azure File Shares protected vs total
- **Backup Job Health** — Success rates, RPO compliance, failure detection
- **Security & Compliance Audit** — Soft delete, immutability, encryption, TLS, public access
- **Appliance Health** — VBA appliance VM status, sizing validation
- **Snapshot Health** — Age analysis, orphaned snapshot detection, storage consumption
- **Repository Health** — Storage account state, redundancy, access tier optimization
- **Network Assessment** — NSG rules, private endpoints, connectivity requirements
- **Professional HTML Report** — Microsoft Fluent Design System with executive summary
- **CSV Exports** — Structured data for every health check category
- **Unprotected Resources Report** — Identifies VMs, SQL, and file shares at risk
- **Modern Authentication** — Interactive, Managed Identity, Service Principal, Device Code

## Prerequisites

- **PowerShell** 7.x (recommended) or 5.1
- **Azure PowerShell Modules** (auto-installed if missing):
  - `Az.Accounts`
  - `Az.Resources`
  - `Az.Compute`
  - `Az.Network`
  - `Az.Sql`
  - `Az.Storage`
  - `Az.RecoveryServices`
- **Azure Permissions**: Reader role on target subscriptions (minimum)

## Quick Start

```powershell
# Basic health check — all accessible subscriptions
.\Get-VBAHealthCheck.ps1

# Scope to specific subscription and region
.\Get-VBAHealthCheck.ps1 -Subscriptions "Production-Sub" -Region "eastus"

# Full analysis with snapshot scanning
.\Get-VBAHealthCheck.ps1 -IncludeSnapshots

# Strict RPO threshold (12 hours instead of default 24)
.\Get-VBAHealthCheck.ps1 -RPOThresholdHours 12
```

## Authentication

### Interactive (Default)
```powershell
.\Get-VBAHealthCheck.ps1
```

### Managed Identity (Azure VMs/Containers)
```powershell
.\Get-VBAHealthCheck.ps1 -UseManagedIdentity
```

### Service Principal (Certificate — Recommended for Automation)
```powershell
.\Get-VBAHealthCheck.ps1 -ServicePrincipalId "app-id" -CertificateThumbprint "thumb" -TenantId "tenant-id"
```

### Device Code (Headless/Remote)
```powershell
.\Get-VBAHealthCheck.ps1 -UseDeviceCode
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `Subscriptions` | string[] | All | Subscription IDs or names to scan |
| `TenantId` | string | Current | Azure AD tenant ID |
| `Region` | string | All | Filter by Azure region |
| `ApplianceNamePattern` | string | `veeam|vba|vbazure` | Regex to identify VBA appliance VMs |
| `RPOThresholdHours` | int | 24 | Max hours since last successful backup |
| `SnapshotAgeWarningDays` | int | 30 | Warn on snapshots older than N days |
| `SnapshotAgeCriticalDays` | int | 90 | Critical alert for snapshots older than N days |
| `IncludeSnapshots` | switch | false | Enable managed disk snapshot analysis |
| `OutputPath` | string | Auto | Output folder path |
| `GenerateHTML` | switch | true | Generate HTML report |
| `ZipOutput` | switch | true | Create ZIP archive |
| `SkipModuleInstall` | switch | false | Error on missing modules instead of auto-installing |

## Health Score Methodology

The overall health score (0-100) is a weighted average across 7 categories:

| Category | Weight | What It Checks |
|----------|--------|----------------|
| Protection Coverage | 25% | % of VMs, SQL, File Shares with backup configured |
| Backup Job Health | 25% | Success rates, RPO compliance, policy configuration |
| Security & Compliance | 15% | Soft delete, immutability, encryption, TLS, RBAC |
| Appliance Health | 10% | VBA VM power state, sizing, provisioning |
| Snapshot Health | 10% | Age distribution, orphaned snapshots |
| Repository Health | 10% | Storage account state, redundancy, tier optimization |
| Network Health | 5% | NSG rules, private endpoints, connectivity |

Each finding scores: **100** (Healthy), **50** (Warning), or **0** (Critical).

**Grades:**
- **90-100**: Excellent
- **70-89**: Good
- **50-69**: Needs Attention
- **0-49**: Critical

## Output Files

| File | Description |
|------|-------------|
| `VBA-HealthCheck-Report.html` | Professional HTML report with executive summary |
| `health_check_findings.csv` | All findings with status, category, and recommendations |
| `health_score_summary.csv` | Overall and per-category scores with grades |
| `protection_coverage.csv` | Protected vs total resources by type |
| `unprotected_vms.csv` | List of VMs without backup configured |
| `backup_job_health.csv` | Per-item backup status and RPO compliance |
| `appliance_health.csv` | VBA appliance VM inventory and status |
| `snapshot_health.csv` | Snapshot age analysis and orphan detection |
| `security_posture.csv` | Vault security settings audit |
| `repository_health.csv` | Backup storage account configuration |
| `backup_policies.csv` | Backup policy inventory |
| `execution_log.csv` | Timestamped execution log |

## Examples

### Production Environment Health Check
```powershell
.\Get-VBAHealthCheck.ps1 `
  -Subscriptions "Prod-Sub-1","Prod-Sub-2" `
  -Region "eastus" `
  -RPOThresholdHours 12 `
  -IncludeSnapshots `
  -SnapshotAgeWarningDays 14 `
  -SnapshotAgeCriticalDays 45
```

### Automated Weekly Health Check (Service Principal)
```powershell
.\Get-VBAHealthCheck.ps1 `
  -ServicePrincipalId $env:AZURE_CLIENT_ID `
  -CertificateThumbprint $env:AZURE_CERT_THUMB `
  -TenantId $env:AZURE_TENANT_ID `
  -IncludeSnapshots `
  -OutputPath "C:\Reports\VBAHealthCheck"
```

### Quick Check (Minimal Scope)
```powershell
.\Get-VBAHealthCheck.ps1 -Subscriptions "Dev-Sub" -Region "westus2"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| No VBA appliances found | Ensure VBA VM names contain "veeam" or use `-ApplianceNamePattern` to match your naming convention |
| Missing modules error | Run `Install-Module Az -Scope CurrentUser` or remove `-SkipModuleInstall` to auto-install |
| Permission denied | Ensure your account has Reader role on target subscriptions |
| Slow snapshot analysis | Snapshot enumeration scales with count — use `-Region` to limit scope |
| No backup items found | Verify Recovery Services Vaults exist and contain protected items |

## Best Practices

1. **Schedule weekly health checks** using Azure Automation or CI/CD pipelines
2. **Use service principal auth** with certificate for automated runs
3. **Enable `-IncludeSnapshots`** for comprehensive snapshot hygiene analysis
4. **Set strict RPO thresholds** (`-RPOThresholdHours 12`) for production workloads
5. **Review unprotected VMs** from the CSV export after each run
6. **Address Critical findings** before Warning findings for maximum impact
7. **Archive HTML reports** for trend analysis and compliance auditing
