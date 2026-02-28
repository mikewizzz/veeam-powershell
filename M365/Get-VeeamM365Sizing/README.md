# Veeam M365 Sizing Tool

Community-maintained PowerShell script for assessing Microsoft 365 backup requirements and estimating Microsoft Backup Storage (MBS) capacity.

## Overview

This tool analyzes Microsoft 365 tenants to provide:
- Current dataset size across Exchange Online, OneDrive for Business, and SharePoint Online
- User and workload counts with historical growth trends
- **MBS capacity estimation** for Azure storage budget planning
- Identity and security posture assessment (Full mode)
- License utilization analysis (Full mode)
- Algorithmic findings and prioritized recommendations (Full mode)
- Professional HTML report suitable for enterprise IT leadership

### What is MBS (Microsoft Backup Storage)?

**MBS is consumption-based pricing.** Microsoft charges for backup storage by the **GB/TB consumed in Azure**, not per-user licensing. This tool helps you **budget Azure storage costs** and right-size capacity allocation.

## Architecture

The script uses a modular `lib/` architecture:

```
Get-VeeamM365Sizing/
├── Get-VeeamM365Sizing.ps1    # Slim orchestrator
├── lib/
│   ├── Constants.ps1           # Unit conversions, thresholds
│   ├── Logging.ps1             # Write-Log, formatting helpers
│   ├── GraphApi.ps1            # Invoke-Graph with retry logic
│   ├── Auth.ps1                # All authentication methods
│   ├── DataCollection.ps1      # Usage reports, growth, group filtering
│   ├── IdentityAssessment.ps1  # MFA, admins, guests, stale, risky users, Secure Score
│   ├── LicenseAnalysis.ps1     # SKU retrieval and utilization analysis
│   ├── Findings.ps1            # Algorithmic findings, recommendations, readiness score
│   ├── Exports.ps1             # CSV, JSON, Notes exports
│   └── HtmlReport.ps1          # HTML report generation (Fluent Design)
├── test-minimal.ps1
└── README.md
```

## Quick Start

### Minimal Run (Quick Mode)
```powershell
.\Get-VeeamM365Sizing.ps1
```
- Delegated authentication (interactive login)
- Minimal Graph API permissions
- ~2-5 minutes for typical tenants

### Full Assessment
```powershell
.\Get-VeeamM365Sizing.ps1 -Full
```
- Identity assessment: MFA coverage, Global Admins, guest users, stale accounts, risky users
- License analysis: SKU utilization breakdown
- Microsoft Secure Score integration
- Entra ID configuration inventory (CA policies, Intune, directory roles)
- Algorithmic findings with Protection Readiness Score (0-100)
- Prioritized recommendations (Immediate / Short-Term / Strategic)
- Requires additional Graph API permissions (will prompt for consent)

### Full Assessment with All Exports
```powershell
.\Get-VeeamM365Sizing.ps1 -Full -EnableTelemetry -ExportJson
```

### Deep Exchange Sizing
```powershell
.\Get-VeeamM365Sizing.ps1 -IncludeArchive -IncludeRecoverableItems
```
- Measures Exchange In-Place Archive mailboxes
- Measures Recoverable Items Folders (RIF)
- **Note:** Significantly slower (sequential mailbox queries via Exchange Online PowerShell)

## Authentication

### Modern Authentication Methods (2026)

The script supports **all modern Microsoft Graph authentication patterns** with intelligent session reuse:

| Method | Use Case | Example |
|--------|----------|---------|
| **Delegated** (default) | Interactive use | `.\Get-VeeamM365Sizing.ps1` |
| **Device Code** | Browser-less environments | `.\Get-VeeamM365Sizing.ps1 -UseDeviceCode` |
| **Certificate** | Production automation | `-UseAppAccess -CertificateThumbprint "ABC..."` |
| **Managed Identity** | Azure VMs/containers | `-UseAppAccess -UseManagedIdentity` |
| **Access Token** | Pre-obtained tokens | `-UseAppAccess -AccessToken $token` |
| **Client Secret** | Legacy/development | `-UseAppAccess -ClientSecret $secret` |

### Required Scopes

**Quick Mode:**
- `Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All`

**Full Mode (adds):**
- `Application.Read.All`, `Policy.Read.All`
- `DeviceManagementManagedDevices.Read.All`, `DeviceManagementConfiguration.Read.All`
- `AuditLog.Read.All` (MFA registration, stale account detection)
- `IdentityRiskEvent.Read.All` (risky user detection)
- `SecurityEvents.Read.All` (Microsoft Secure Score)
- `Group.Read.All` (Teams count)

**Group Filtering (adds):**
- `Group.Read.All`

## Parameters

### Authentication
| Parameter | Type | Description |
|-----------|------|-------------|
| `-UseAppAccess` | Switch | Use app-only authentication (service principal) |
| `-TenantId` | String | Azure AD tenant ID (for app-only auth) |
| `-ClientId` | String | Application (client) ID (for app-only auth) |
| `-ClientSecret` | SecureString | Client secret (legacy - avoid in production) |
| `-CertificateThumbprint` | String | Certificate thumbprint for cert-based auth |
| `-CertificateSubjectName` | String | Certificate subject name for cert-based auth |
| `-UseManagedIdentity` | Switch | Use Azure Managed Identity |
| `-UseDeviceCode` | Switch | Use device code flow for delegated auth |
| `-AccessToken` | SecureString | Pre-obtained access token |

### Run Mode
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Quick` | Switch | Default | Fast execution, minimal permissions |
| `-Full` | Switch | | Identity assessment, license analysis, findings, recommendations |

### Scope Filtering
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ADGroup` | String | | Filter Exchange/OneDrive by Entra ID group (DisplayName) |
| `-ExcludeADGroup` | String | | Exclude members of this Entra ID group |
| `-Period` | Int | 90 | Report period in days (7, 30, 90, or 180) |

**Note:** Group filtering applies to Exchange and OneDrive only. SharePoint is always tenant-wide due to Graph API limitations.

### Exchange Deep Sizing
| Parameter | Type | Description |
|-----------|------|-------------|
| `-IncludeArchive` | Switch | Measure In-Place Archive mailboxes (slow) |
| `-IncludeRecoverableItems` | Switch | Measure Recoverable Items Folders (slow) |

### MBS Capacity Estimation
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-AnnualGrowthPct` | Double | 0.15 | Projected annual growth rate (0.0-5.0) |
| `-RetentionMultiplier` | Double | 1.30 | Backup retention factor (1.0-10.0) |
| `-ChangeRateExchange` | Double | 0.015 | Daily change rate for Exchange (0.0-1.0) |
| `-ChangeRateOneDrive` | Double | 0.004 | Daily change rate for OneDrive (0.0-1.0) |
| `-ChangeRateSharePoint` | Double | 0.003 | Daily change rate for SharePoint (0.0-1.0) |
| `-BufferPct` | Double | 0.10 | Safety buffer for capacity planning (0.0-1.0) |

### Output Options
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-OutFolder` | String | `.\VeeamM365SizingOutput` | Output directory |
| `-ExportJson` | Switch | | Generate JSON bundle |
| `-ZipBundle` | Switch | On | Compress outputs to ZIP file |
| `-EnableTelemetry` | Switch | | Write execution log |
| `-SkipModuleInstall` | Switch | | Require manual module installation |

## Outputs

### Quick Mode Files
| File | Description |
|------|-------------|
| `Veeam-M365-Report-*.html` | Professional HTML report (Fluent Design) |
| `Veeam-M365-Summary-*.csv` | Executive summary (all metrics in one row) |
| `Veeam-M365-Workloads-*.csv` | Per-workload breakdown |
| `Veeam-M365-Security-*.csv` | Security signals (empty in Quick mode) |
| `Veeam-M365-Inputs-*.csv` | Input parameters for this run |
| `Veeam-M365-Notes-*.txt` | Methodology and definitions |

### Full Mode Additional Files
| File | Description |
|------|-------------|
| `Veeam-M365-Licenses-*.csv` | License SKU breakdown with utilization |
| `Veeam-M365-Findings-*.csv` | Algorithmic assessment findings |
| `Veeam-M365-Recommendations-*.csv` | Prioritized recommendations |

### Optional Files
| File | When Generated |
|------|---------------|
| `Veeam-M365-Bundle-*.json` | `-ExportJson` flag |
| `Veeam-M365-Log-*.txt` | `-EnableTelemetry` flag |
| `Veeam-M365-SizingBundle-*.zip` | `-ZipBundle` flag (default) |

## Full Mode HTML Report Sections

1. **Executive Summary** - Protection Readiness Score (0-100), top findings
2. **KPI Grid** - Users, dataset, growth, recommended MBS capacity
3. **License Overview** - SKU table with utilization progress bars
4. **Workload Analysis** - Exchange, OneDrive, SharePoint breakdown
5. **Data Protection Landscape** - Shared Responsibility Model, coverage grid including Entra ID configuration
6. **Identity & Access Security** - Global Admins, guests, MFA progress bar, Secure Score, stale/risky users
7. **Methodology** - Data sources and MBS estimation formula
8. **Sizing Parameters** - All model inputs
9. **Recommendations** - Prioritized by tier (Immediate, Short-Term, Strategic)
10. **Generated Artifacts** - List of output files

## Understanding the Results

### Protection Readiness Score (Full Mode)

Composite score (0-100) calculated from weighted identity and security signals:

| Signal | Weight | Scoring |
|--------|--------|---------|
| MFA Coverage | 25 pts | Proportional to registration % |
| Admin Hygiene | 15 pts | Fewer Global Admins = higher |
| Conditional Access | 15 pts | More policies = higher |
| Stale Accounts | 10 pts | Fewer stale = higher |
| Risky Users | 10 pts | No risky users = highest |
| Microsoft Secure Score | 25 pts | Proportional to Secure Score % |

Signals that aren't available (permission denied) are excluded and the score is proportionally adjusted.

### MBS Capacity Estimation

```
ProjectedDatasetGB = TotalSourceGB x (1 + AnnualGrowthPct)
MonthlyChangeGB = 30 x (ExGB x ChangeRateEx + OdGB x ChangeRateOd + SpGB x ChangeRateSp)
MbsEstimateGB = (ProjectedDatasetGB x RetentionMultiplier) + MonthlyChangeGB
RecommendedMBS = MbsEstimateGB x (1 + BufferPct)
```

### Graceful Degradation

Every identity signal handles permission denials independently. If a scope isn't granted:
- The metric shows "Requires permission" in the HTML report
- It's excluded from the readiness score calculation
- Other signals continue to function normally

## Examples

```powershell
# Default quick assessment
.\Get-VeeamM365Sizing.ps1

# Full assessment with JSON export
.\Get-VeeamM365Sizing.ps1 -Full -ExportJson

# Full mode with custom growth rate
.\Get-VeeamM365Sizing.ps1 -Full -AnnualGrowthPct 0.20

# Filter to specific group
.\Get-VeeamM365Sizing.ps1 -ADGroup "Sales Department"

# Comprehensive assessment with deep Exchange sizing
.\Get-VeeamM365Sizing.ps1 -Full -IncludeArchive -IncludeRecoverableItems -Period 180

# Certificate-based auth for automation
.\Get-VeeamM365Sizing.ps1 -UseAppAccess `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "12345678-..." `
    -CertificateThumbprint "ABC123..."
```

## Troubleshooting

### "Missing required Graph scopes"
Disconnect and re-run to consent additional permissions:
```powershell
Disconnect-MgGraph
.\Get-VeeamM365Sizing.ps1 -Full
```

### "Group filtering matched 0 users"
Causes: usage reports have concealed user identifiers, or group name doesn't match exactly.

Fix: In [M365 Admin Center](https://admin.microsoft.com) > Settings > Org settings > Services > Reports, disable "Display concealed user, group, and site names." Wait 24-48 hours, then re-run.

### Slow Performance
- Avoid `-IncludeArchive` and `-IncludeRecoverableItems` unless necessary
- Use shorter `-Period` (e.g., 30 days instead of 180)
- Full mode adds ~30-60 seconds for identity signals

## Known Limitations

1. **SharePoint group filtering not supported** - Graph API limitation
2. **Archive/RIF sizing is slow** - Sequential per-mailbox queries; large tenants may take 30+ minutes
3. **Report masking breaks group filtering** - Admin Center "concealed names" prevents UPN matching
4. **MBS estimate is a model** - Actual consumption depends on backup configuration

## Dependencies

| Module | Required For |
|--------|-------------|
| `Microsoft.Graph.Authentication` | All modes |
| `Microsoft.Graph.Reports` | All modes |
| `Microsoft.Graph.Identity.DirectoryManagement` | All modes |
| `Microsoft.Graph.Groups` | Group filtering (`-ADGroup` / `-ExcludeADGroup`) |
| `ExchangeOnlineManagement` | Archive/RIF sizing only |

PowerShell 7.x recommended; 5.1 supported.

## Contributing

Contributions welcome! Please:
1. Follow existing code style and the conventions in `CONTRIBUTING.md`
2. Add comment-based help for new functions
3. Test with both Quick and Full modes
4. Update README with new parameters/features
5. Ensure all lib/ files are present and properly dot-sourced

## License

MIT

## Changelog

### Version 3.0 (2026-02-28)
- **Modular architecture**: Split into `lib/` modules matching NutanixAHV pattern
- **Identity assessment**: MFA coverage, Global Admins, guest users, stale accounts, risky users
- **License analysis**: SKU retrieval with utilization percentages
- **Microsoft Secure Score**: Integration via Graph API
- **Teams count**: Detection of Teams workloads
- **Entra ID configuration**: Inventory of CA policies, Intune configs, directory roles as backup-eligible objects
- **Findings engine**: Algorithmic findings from measured data thresholds
- **Recommendations**: Prioritized tiers (Immediate, Short-Term, Strategic)
- **Protection Readiness Score**: Composite 0-100 score from identity/security signals
- **Enhanced HTML report**: Executive summary, license overview, data protection landscape, identity section
- **New exports**: Licenses CSV, Findings CSV, Recommendations CSV
- **Expanded JSON bundle**: Licenses, Findings, Recommendations, IdentityRisk objects
- **New scopes**: AuditLog.Read.All, IdentityRiskEvent.Read.All, SecurityEvents.Read.All, Group.Read.All

### Version 2.1 (2026-01-06)
- Session reuse prevents re-login on every run
- Token expiration checking with 5-minute buffer

### Version 2.0 (2026-01-06)
- Redesigned HTML report with Microsoft Fluent Design System
- MBS capacity estimation
- Enhanced error handling and retry logic

### Version 1.0 (Initial Release)
- Basic sizing functionality
- Quick and Full modes
- CSV/HTML/JSON outputs
