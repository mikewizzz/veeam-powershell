# VB365-Sizing

## Author

* Michael Wisniewski

## Function

Microsoft 365 backup sizing tool for [Veeam Backup for Microsoft 365](https://www.veeam.com/backup-microsoft-office-365.html). Connects to Microsoft Graph API to collect Exchange Online, OneDrive for Business, and SharePoint Online usage data. Calculates dataset totals and annualized growth rates, inventories the Entra ID directory footprint, and generates professional HTML/CSV reports.

**What it produces:**

* Professional HTML report with SVG charts, KPI cards, and workload breakdown
* Summary CSV with all sizing metrics in a single row
* Workloads CSV with per-workload breakdown (Exchange, OneDrive, SharePoint)

## Requirements

* PowerShell 5.1+
* Microsoft Graph modules (auto-installed unless `-SkipModuleInstall`):
  * `Microsoft.Graph.Authentication`
  * `Microsoft.Graph.Reports`
  * `Microsoft.Graph.Identity.DirectoryManagement`
* Graph API permissions: `Reports.Read.All`, `Directory.Read.All`, `User.Read.All`, `Organization.Read.All`
* Supported cloud environments: Commercial, GCC, GCC High, DoD, China (21Vianet)

## Usage

Interactive login (zero config):

```powershell
.\vb365-sizing.ps1
```

App-only with certificate:

```powershell
.\vb365-sizing.ps1 -UseAppAccess -TenantId "contoso.onmicrosoft.com" -ClientId "12345678-abcd-..." -CertificateThumbprint "AABBCCDD..."
```

Device code (browser-less server):

```powershell
.\vb365-sizing.ps1 -UseDeviceCode
```

Scoped to a group:

```powershell
.\vb365-sizing.ps1 -ADGroup "Sales Department"
```

For full parameter documentation:

```powershell
Get-Help .\vb365-sizing.ps1 -Full
```

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

## Known Limitations

* **SharePoint group filtering not supported** — Graph API limitation; SharePoint sizing is always tenant-wide regardless of `-ADGroup` parameter
* **Report masking breaks group filtering** — If M365 Admin Center has "concealed user/group/site names" enabled, UPN-based group filtering will fail
* **Growth rates are estimates** — Annual growth rates are linearly extrapolated from the report period; short periods may produce less reliable estimates

## Distributed under MIT license

Copyright (c) 2026 VeeamHub

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
