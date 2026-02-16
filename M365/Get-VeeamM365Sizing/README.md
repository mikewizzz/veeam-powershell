# Veeam M365 Sizing Tool

PowerShell script for assessing Microsoft 365 backup requirements and estimating Microsoft Backup Storage (MBS) capacity for Veeam Backup for Microsoft 365.

## Overview

This tool analyzes Microsoft 365 tenants to provide:
- Current dataset size across Exchange Online, OneDrive for Business, and SharePoint Online
- User and workload counts
- Historical growth trends
- **MBS capacity estimation** for Azure storage budget planning
- Optional security posture signals (Entra ID, Conditional Access, Intune)

### What is MBS (Microsoft Backup Storage)?

**MBS is consumption-based pricing.** Microsoft charges for Veeam Backup for Microsoft 365 by the **GB/TB of backup storage consumed in Azure**, not per-user licensing.

**Why backup storage ≠ source data:**
- Retention policies keep multiple backup versions over time
- Incremental backups accumulate daily changes
- Deleted items remain in retention windows

This tool helps you **budget Azure storage costs accurately** and right-size capacity allocation.

## Quick Start

### Minimal Run (Quick Mode)
```powershell
.\Get-VeeamM365Sizing.ps1
```
- Uses delegated authentication (interactive login)
- Minimal Graph API permissions required
- Fastest execution (~2-5 minutes for typical tenants)

### Full Assessment
```powershell
.\Get-VeeamM365Sizing.ps1 -Full
```
- Includes security posture signals (users, groups, policies, devices)
- Requires additional Graph API permissions (will prompt for consent)

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

#### 1. Delegated Authentication (Interactive)
**Default method** - most common for interactive use:
```powershell
.\Get-VeeamM365Sizing.ps1
```
- **Session reuse**: No re-login required within token lifetime
- **Device Code Flow**: Use `-UseDeviceCode` for browser-less environments

#### 2. Certificate-Based Authentication (Recommended for Production)
**Most secure** for service principals:
```powershell
.\Get-VeeamM365Sizing.ps1 -UseAppAccess `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "12345678-1234-1234-1234-123456789abc" `
    -CertificateThumbprint "ABC123..."
```

#### 3. Azure Managed Identity (For Azure Resources)
**Zero credential management** for VMs/containers/functions:
```powershell
.\Get-VeeamM365Sizing.ps1 -UseAppAccess -UseManagedIdentity
```

#### 4. Access Token (Advanced Scenarios)
**Provide pre-obtained tokens**:
```powershell
.\Get-VeeamM365Sizing.ps1 -UseAppAccess -AccessToken $token
```

#### 5. Client Secret (Legacy - Still Supported)
**Less secure but simple** for development/testing:
```powershell
.\Get-VeeamM365Sizing.ps1 -UseAppAccess `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "12345678-1234-1234-1234-123456789abc" `
    -ClientSecret $clientSecret
```

### Security Hierarchy (Most to Least Secure)
1. **Managed Identity** - Zero credentials stored
2. **Certificate-based** - Private keys secured in certificate stores
3. **Access Token** - Short-lived, programmatically obtained
4. **Client Secret** - Static credential (avoid in production)

### Session Management
- **Automatic reuse**: No re-authentication within token lifetime (~1 hour)
- **Scope validation**: Ensures current session has required permissions
- **Clean transitions**: Properly disconnects when switching auth methods
- **Token refresh**: Handles token expiration gracefully

### Required Scopes
**Quick Mode:**
- `Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All`

**Full Mode (adds):**
- `Application.Read.All`, `Policy.Read.All`, `DeviceManagementManagedDevices.Read.All`, `DeviceManagementConfiguration.Read.All`

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
| `-Quick` | Switch | ✓ | Fast execution, minimal permissions |
| `-Full` | Switch | | Includes security posture signals |

### Scope Filtering
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ADGroup` | String | | Filter Exchange/OneDrive by Entra ID group (DisplayName) |
| `-ExcludeADGroup` | String | | Exclude members of this Entra ID group |
| `-Period` | Int | 90 | Report period in days (7, 30, 90, or 180) |

**⚠️ Important:** Group filtering applies to Exchange and OneDrive only. SharePoint is always tenant-wide due to Graph API limitations.

### Exchange Deep Sizing
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IncludeArchive` | Switch | | Measure In-Place Archive mailboxes (slow) |
| `-IncludeRecoverableItems` | Switch | | Measure Recoverable Items Folders (slow) |

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
| `-ZipBundle` | Switch | ✓ | Compress outputs to ZIP file |
| `-EnableTelemetry` | Switch | | Write execution log |
| `-SkipModuleInstall` | Switch | | Require manual module installation |

## Outputs

Each run creates a timestamped folder with:

### Generated Files
| File | Description |
|------|-------------|
| `Veeam-M365-Report-*.html` | Professional HTML report (Fluent Design) |
| `Veeam-M365-Summary-*.csv` | Executive summary (all metrics in one row) |
| `Veeam-M365-Workloads-*.csv` | Per-workload breakdown (Exchange, OneDrive, SharePoint) |
| `Veeam-M365-Security-*.csv` | Security posture signals (Full mode only) |
| `Veeam-M365-Inputs-*.csv` | Input parameters used for this run |
| `Veeam-M365-Notes-*.txt` | Methodology and definitions |
| `Veeam-M365-Bundle-*.json` | JSON bundle (if `-ExportJson` enabled) |
| `Veeam-M365-Log-*.txt` | Execution log (if `-EnableTelemetry` enabled) |
| `Veeam-M365-SizingBundle-*.zip` | Compressed bundle (if `-ZipBundle` enabled) |

### Sample Output Structure
```
VeeamM365SizingOutput/
├── Run-2026-01-06_1430/
│   ├── Veeam-M365-Report-2026-01-06_1430.html
│   ├── Veeam-M365-Summary-2026-01-06_1430.csv
│   ├── Veeam-M365-Workloads-2026-01-06_1430.csv
│   ├── Veeam-M365-Security-2026-01-06_1430.csv
│   ├── Veeam-M365-Inputs-2026-01-06_1430.csv
│   └── Veeam-M365-Notes-2026-01-06_1430.txt
└── Veeam-M365-SizingBundle-2026-01-06_1430.zip
```

## Understanding the Results

### Measured Data
- **Dataset totals:** Sourced from Microsoft Graph usage reports
- **Archive mailboxes:** Measured directly from Exchange Online (if `-IncludeArchive` enabled)
- **Recoverable Items:** Measured directly from Exchange Online (if `-IncludeRecoverableItems` enabled)

### MBS Capacity Estimation (Modeled)
This is a **capacity planning model**, not a measured billable quantity.

**Formula:**
```
ProjectedDatasetGB = TotalSourceGB × (1 + AnnualGrowthPct)
MonthlyChangeGB = 30 × (ExGB×ChangeRateEx + OdGB×ChangeRateOd + SpGB×ChangeRateSp)
MbsEstimateGB = (ProjectedDatasetGB × RetentionMultiplier) + MonthlyChangeGB
RecommendedMBS = MbsEstimateGB × (1 + BufferPct)
```

**Why these parameters matter:**
- **AnnualGrowthPct:** Data grows over time; plan for future capacity
- **RetentionMultiplier:** Backups keep multiple versions; storage > source data
- **ChangeRate:** Incremental backups accumulate daily changes
- **BufferPct:** Safety headroom to avoid capacity shortfalls

## Examples

### Basic Assessment
```powershell
# Default quick assessment with 90-day reporting period
.\Get-VeeamM365Sizing.ps1
```

### Full Assessment with Custom Growth Rate
```powershell
# Full mode with 20% projected annual growth
.\Get-VeeamM365Sizing.ps1 -Full -AnnualGrowthPct 0.20
```

### Filtered Assessment
```powershell
# Only assess users in "Sales Department" group
.\Get-VeeamM365Sizing.ps1 -ADGroup "Sales Department"

# Assess all users except "Test Users" group
.\Get-VeeamM365Sizing.ps1 -ExcludeADGroup "Test Users"
```

### Comprehensive Assessment
```powershell
# Full assessment with deep Exchange sizing
.\Get-VeeamM365Sizing.ps1 -Full -IncludeArchive -IncludeRecoverableItems -Period 180
```

### App-Only Authentication
```powershell
$clientSecret = ConvertTo-SecureString "your-secret" -AsPlainText -Force
.\Get-VeeamM365Sizing.ps1 -UseAppAccess `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "12345678-1234-1234-1234-123456789abc" `
    -ClientSecret $clientSecret
```

## Troubleshooting

### "Missing required Graph scopes"
**Solution:** Disconnect and re-run to consent additional permissions:
```powershell
Disconnect-MgGraph
.\Get-VeeamM365Sizing.ps1 -Full
```

### "Group filtering matched 0 users"
**Causes:**
1. Usage reports have concealed user identifiers (masked)
2. Group display name doesn't match exactly
3. Group contains no users

**Solution for masked reports:**
1. Open [Microsoft 365 Admin Center](https://admin.microsoft.com)
2. Navigate to **Settings** > **Org settings** > **Services** > **Reports**
3. Disable "Display concealed user, group, and site names in all reports"
4. Wait 24-48 hours for reports to refresh
5. Re-run script

### Slow Performance
**Quick fixes:**
- Avoid `-IncludeArchive` and `-IncludeRecoverableItems` unless necessary
- Use shorter `-Period` (e.g., 30 days instead of 180)
- Avoid group filtering for large tenants (use Full mode for unfiltered assessment)

## Known Limitations

1. **SharePoint group filtering not supported** - Graph API usage reports don't reliably map SharePoint sites to group membership without expensive traversal.

2. **Archive/RIF sizing is slow** - Sequential per-mailbox queries to Exchange Online. Large tenants (>1000 mailboxes) may take 30+ minutes.

3. **Report masking breaks group filtering** - If M365 Admin Center has "concealed names" enabled, UPN-based filtering will fail.

4. **MBS estimate is a model** - Actual MBS consumption depends on backup configuration, retention policies, and workload characteristics. Use this as a planning guide, not a billing guarantee.

## Security & Privacy

- **No PII exported by default** - Script exports aggregate counts and totals only
- **Future-proofing:** `-MaskUserIds` parameter reserved for potential per-user exports
- **Credential security:** Use `-UseAppAccess` with certificate-based auth for production automation

## Contributing

Contributions welcome! Please:
1. Follow existing code style (KISS principles)
2. Add comment-based help for new functions
3. Test with both Quick and Full modes
4. Update README with new parameters/features

## License

[Specify your license here]

## Support

For issues, questions, or feature requests:
- Open an issue on GitHub
- Contact: [Your contact information]

## Changelog

### Version 2.1 (2026-01-06)
- **Authentication improvement**: Session reuse prevents re-login on every run
- Added `Test-GraphSession` function for intelligent session validation
- Token expiration checking with 5-minute buffer
- Better scope validation before reconnecting

### Version 2.0 (2026-01-06)
- Redesigned HTML report with Microsoft Fluent Design System
- Comprehensive MBS capacity estimation documentation
- Enhanced error handling and retry logic
- Improved function documentation

### Version 1.0 (Initial Release)
- Basic sizing functionality
- Quick and Full modes
- CSV/HTML/JSON outputs
