# Veeam M365 Data Footprint Assessment

PowerShell script for assessing Microsoft 365 data footprint to support Veeam Data Cloud for Microsoft 365 presales engagements.

## Overview

This tool analyzes Microsoft 365 tenants to provide:
- User counts across Exchange Online, OneDrive for Business, SharePoint Online, and **Microsoft Teams**
- Dataset sizes per workload
- Observed historical growth trends
- Optional security posture signals (Entra ID, Conditional Access, Intune)

Run this before a customer call to get accurate tenant data for sales proposals.

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
| `-Quick` | Switch | Default | Fast execution, minimal permissions |
| `-Full` | Switch | | Includes security posture signals |

### Scope Filtering
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ADGroup` | String | | Filter Exchange/OneDrive/Teams by Entra ID group |
| `-ExcludeADGroup` | String | | Exclude members of this Entra ID group |
| `-Period` | Int | 90 | Report period in days (7, 30, 90, or 180) |

Group filtering applies to Exchange, OneDrive, and Teams only. SharePoint is always tenant-wide due to Graph API limitations.

### Exchange Deep Sizing
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IncludeArchive` | Switch | | Measure In-Place Archive mailboxes (slow) |
| `-IncludeRecoverableItems` | Switch | | Measure Recoverable Items Folders (slow) |

### Output Options
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-OutFolder` | String | `.\VeeamM365SizingOutput` | Output directory |
| `-ExportJson` | Switch | | Generate JSON bundle |
| `-ZipBundle` | Bool | `$true` | Compress outputs to ZIP file |
| `-EnableTelemetry` | Switch | | Write execution log |
| `-SkipModuleInstall` | Switch | | Require manual module installation |

## Outputs

Each run creates a timestamped folder with:

| File | Description |
|------|-------------|
| `Veeam-M365-Report-*.html` | Professional HTML report (Fluent Design) |
| `Veeam-M365-Summary-*.csv` | Executive summary (all metrics in one row) |
| `Veeam-M365-Workloads-*.csv` | Per-workload breakdown (Exchange, OneDrive, SharePoint, Teams) |
| `Veeam-M365-Security-*.csv` | Security posture signals (Full mode only) |
| `Veeam-M365-Inputs-*.csv` | Input parameters used for this run |
| `Veeam-M365-Notes-*.txt` | Methodology and data sources |
| `Veeam-M365-Bundle-*.json` | JSON bundle (if `-ExportJson` enabled) |
| `Veeam-M365-SizingBundle-*.zip` | Compressed bundle (if `-ZipBundle` enabled) |

## Understanding the Results

### Measured Data
- **Dataset totals:** Sourced from Microsoft Graph usage reports
- **User counts:** Unique active users across Exchange, OneDrive, and Teams
- **Teams:** Active teams, active channels, and active users. Teams files are stored in SharePoint; storage is included in SharePoint totals.
- **Archive mailboxes:** Measured directly from Exchange Online (if `-IncludeArchive` enabled)
- **Recoverable Items:** Measured directly from Exchange Online (if `-IncludeRecoverableItems` enabled)

### Observed Growth Trends
Growth rates are calculated from the earliest and latest data points in the report period, extrapolated to an annual rate. These are **historical observations**, not projections.

### SharePoint / OneDrive Overlap
The SharePoint usage report may include OneDrive personal sites, which could result in partial overlap between SharePoint and OneDrive totals.

## Examples

### Basic Assessment
```powershell
.\Get-VeeamM365Sizing.ps1
```

### Full Assessment
```powershell
.\Get-VeeamM365Sizing.ps1 -Full
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
.\Get-VeeamM365Sizing.ps1 -Full -IncludeArchive -IncludeRecoverableItems -Period 180
```

## Troubleshooting

### "Missing required Graph scopes"
Disconnect and re-run to consent additional permissions:
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

## Known Limitations

1. **SharePoint group filtering not supported** - Graph API usage reports don't reliably map SharePoint sites to group membership.
2. **Archive/RIF sizing is slow** - Sequential per-mailbox queries. Large tenants (>1000 mailboxes) may take 30+ minutes.
3. **Report masking breaks group filtering** - If M365 Admin Center has "concealed names" enabled, UPN-based filtering will fail.
4. **Teams files stored in SharePoint** - No separate Teams storage metric exists; Teams file storage is included in SharePoint totals.

## Changelog

### Version 3.0 (2026-03-31)
- **Veeam Data Cloud reframe**: Repositioned from MBS sizing to VDC data footprint assessment
- **Teams workload**: Added Microsoft Teams data collection (active teams, channels, users)
- **Removed MBS estimation**: Stripped all backup capacity planning math (no longer relevant for per-user VDC)
- **Function renames**: All functions now use PowerShell approved verbs
- **Bug fixes**: UTC timestamp, batched API call, Disconnect-MgGraph error handling

### Version 2.1 (2026-01-06)
- **Authentication improvement**: Session reuse prevents re-login on every run
- Added `Test-GraphSession` function for intelligent session validation

### Version 2.0 (2026-01-06)
- Redesigned HTML report with Microsoft Fluent Design System
- Enhanced error handling and retry logic

### Version 1.0 (Initial Release)
- Basic sizing functionality
- Quick and Full modes
- CSV/HTML/JSON outputs
