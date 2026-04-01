# VB365-Sizing

## VeeamHub

This project is a community-driven open-source tool and is **NOT** created by Veeam R&D or validated by Veeam Q&A. It is maintained by community members. Veeam Support does not provide technical support for this script. Use at your own risk.

## Description

**VB365-Sizing** is a PowerShell tool that connects to Microsoft Graph API to size a Microsoft 365 tenant for [Veeam Backup for Microsoft 365](https://www.veeam.com/backup-microsoft-office-365.html). It collects Exchange Online, OneDrive for Business, and SharePoint Online usage data, calculates dataset totals and annualized growth rates, and inventories the Entra ID directory footprint.

**What it produces:**

- Professional HTML report with SVG charts, KPI cards, and workload breakdown
- Summary CSV with all sizing metrics in a single row
- Workloads CSV with per-workload breakdown (Exchange, OneDrive, SharePoint)

**Who it's for:** Presales SEs, architects, and IT admins performing M365 backup discovery and capacity planning.

## Sample Output

![Sample Report](sample-report.png)

The HTML report includes:
- Key performance indicators with mini progress rings
- Workload analysis with donut chart and detailed breakdown table
- Entra ID directory inventory (users, groups, apps, service principals)
- M365 license subscription utilization breakdown
- Cloud-native configuration counts (Conditional Access, Intune)

## License

MIT — see [LICENSE](../LICENSE)

## Requirements

| Requirement | Details |
|-------------|---------|
| PowerShell | 5.1 or 7.x |
| Graph Modules | `Microsoft.Graph.Authentication`, `Microsoft.Graph.Reports`, `Microsoft.Graph.Identity.DirectoryManagement` (auto-installed) |
| Permissions | `Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All` |
| Cloud Environments | Commercial, GCC, GCC High, DoD, China (21Vianet) — auto-detected |

## Prerequisites: Azure App Registration (for App-Only Auth)

Interactive login works with zero setup. For unattended or app-only authentication, create an Entra ID app registration:

1. Navigate to **Entra ID** > **App registrations** > **New registration**
   - Name: `VB365-Sizing` (or any name)
   - Supported account types: *Single tenant*
   - Redirect URI: leave blank

2. Under **API permissions** > **Add a permission** > **Microsoft Graph** > **Application permissions**, add:
   - `Reports.Read.All`
   - `Directory.Read.All`
   - `User.Read.All`
   - `Organization.Read.All`

3. Click **Grant admin consent** for your organization

4. Under **Certificates & secrets** > **Certificates**, upload a certificate
   - Generate a self-signed cert: `New-SelfSignedCertificate -Subject "CN=VB365-Sizing" -CertStoreLocation "Cert:\CurrentUser\My" -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddYears(2)`
   - Export the public key (`.cer`) and upload it

5. Record the following values:
   - **Application (client) ID** — from the app registration overview
   - **Directory (tenant) ID** — from the app registration overview
   - **Certificate thumbprint** — from the certificate you uploaded

## Quick Start

### Interactive Login (Zero Config)

```powershell
.\vb365-sizing.ps1
```

A browser window opens for Microsoft login. Consent to the required permissions when prompted.

### App-Only with Certificate

```powershell
.\vb365-sizing.ps1 -UseAppAccess -TenantId "contoso.onmicrosoft.com" -ClientId "12345678-abcd-..." -CertificateThumbprint "AABBCCDD..."
```

### Device Code (Browser-less Server)

```powershell
.\vb365-sizing.ps1 -UseDeviceCode
```

Displays a code to enter at https://microsoft.com/devicelogin from any browser.

### Scoped to a Group

```powershell
.\vb365-sizing.ps1 -ADGroup "Sales Department"
```

Sizes only Exchange mailboxes and OneDrive accounts belonging to the specified Entra ID group. SharePoint is always tenant-wide.

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-UseAppAccess` | Switch | — | Use app-only (service principal) authentication |
| `-TenantId` | String | — | Entra ID tenant ID (required for app-only) |
| `-ClientId` | String | — | App registration client ID |
| `-CertificateThumbprint` | String | — | Certificate thumbprint for app-only auth |
| `-UseDeviceCode` | Switch | — | Use device code flow (for servers without browsers) |
| `-ADGroup` | String | — | Include only this group's members (Exchange/OneDrive) |
| `-ExcludeADGroup` | String | — | Exclude this group's members (Exchange/OneDrive) |
| `-Period` | Int | `90` | Usage report period: 7, 30, 90, or 180 days |
| `-OutFolder` | String | `.\VB365SizingOutput` | Output directory for reports and CSVs |
| `-SkipModuleInstall` | Switch | — | Don't auto-install missing Graph modules |
| `-SkipHtmlReport` | Switch | — | Skip HTML report, produce CSV exports only |

## Outputs

| File | Description |
|------|-------------|
| `VB365-Sizing-Report-{timestamp}.html` | Professional HTML report with charts and directory inventory |
| `VB365-Sizing-Summary-{timestamp}.csv` | Single-row CSV with all sizing metrics and directory counts |
| `VB365-Sizing-Workloads-{timestamp}.csv` | Per-workload breakdown (Exchange, OneDrive, SharePoint) |
| `VB365-Sizing-{timestamp}.log` | Execution log with timestamped entries |

## How It Works

1. **Authenticates** to Microsoft Graph API (interactive, certificate, or device code)
2. **Downloads** usage report CSVs for Exchange, OneDrive, and SharePoint
3. **Calculates** source dataset totals and annualized growth rates from historical data
4. **Collects** Entra ID directory inventory (users, groups, apps, service principals, Intune configs)
5. **Retrieves** M365 license subscription utilization data
6. **Generates** HTML report with SVG charts + CSV exports

## FAQ

**What permissions does this need?**
`Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All`. For group filtering, also `Group.Read.All`.

**Does this modify anything in my tenant?**
No. This is a read-only tool. It queries Graph API reports and writes local files only.

**How long does it take to run?**
Typically 30-90 seconds for most tenants.

**Can I run this against multiple tenants?**
This community edition handles one tenant at a time. Run it separately for each tenant.

**What cloud environments are supported?**
Commercial, GCC, GCC High, DoD, and China (21Vianet). The environment is auto-detected from the Graph session.

## Known Limitations

1. **SharePoint group filtering not supported** — Graph API limitation; SharePoint sizing is always tenant-wide regardless of `-ADGroup` parameter
2. **Report masking breaks group filtering** — If M365 Admin Center has "concealed user/group/site names" enabled, UPN-based group filtering will fail
3. **Archive/Recoverable Items not included** — This community edition does not measure Exchange archive mailboxes or recoverable items folders
4. **Government cloud minimally tested** — Cloud environment endpoints are auto-detected but have limited community testing
5. **Growth rates are estimates** — Annual growth rates are linearly extrapolated from the report period; short periods may produce less reliable estimates

## Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| 403 Forbidden | Missing Graph permissions | Grant `Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All` and click "Grant admin consent" in Entra ID |
| 429 Too Many Requests | Graph API throttling | Automatic retry with exponential backoff; wait and re-run if persistent |
| Empty report data | Report masking enabled | Disable concealed names: M365 Admin Center > Settings > Org settings > Services > Reports |
| Module install fails | Insufficient permissions | Run PowerShell as administrator, or use `-SkipModuleInstall` and install modules manually |
| Certificate not found | Wrong thumbprint or cert not in store | Verify certificate is in `Cert:\CurrentUser\My` and thumbprint matches |

## Contributing

Contributions welcome. Please:

- Sign commits per [DCO](https://developercertificate.org/)
- Follow coding standards in [CONTRIBUTING.md](../CONTRIBUTING.md)
- Test changes against a real M365 tenant before submitting PRs
- Ensure scripts pass PSScriptAnalyzer cleanly
