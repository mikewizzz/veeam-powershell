# Get-VeeamDiagram

Connects to the Veeam Backup & Replication v13 REST API and generates a **draw.io (.drawio) infrastructure diagram** along with a professional HTML report.

## What It Does

Discovers the complete VBR backup infrastructure topology and produces:

- **Draw.io diagram** (.drawio) with auto-layout showing all components and relationships
- **HTML report** with KPI cards, inventory tables, and job status (Microsoft Fluent Design)
- **CSV summary** of component counts
- **JSON bundle** (optional) with full raw API data
- **ZIP archive** (optional) of all outputs

### Components Discovered

| Component | API Endpoint | Diagram Icon |
|-----------|-------------|--------------|
| Backup Server | Connection target | Green Veeam server (center hub) |
| Managed Servers | `/v1/backupInfrastructure/managedServers` | vCenter, Hyper-V, Windows, Linux icons |
| Backup Proxies | `/v1/backupInfrastructure/proxies` | Green proxy icons with task counts |
| Repositories | `/v1/backupInfrastructure/repositories` | Yellow repo icons with capacity |
| Scale-Out Repos | `/v1/backupInfrastructure/scaleOutRepositories` | Red SOBR icons with extent links |
| WAN Accelerators | `/v1/backupInfrastructure/wanAccelerators` | Purple WAN accelerator icons |
| Backup Jobs | `/v1/jobs` (optional) | Color-coded by last result |
| Job States | `/v1/jobs/states` (optional) | Success/Warning/Failed indicators |

## Requirements

- PowerShell 7.x (recommended) or 5.1
- Network access to VBR server port 9419 (default REST API port)
- Veeam B&R v13 or later with REST API enabled
- Account with at least Viewer role on the VBR server
- No external PowerShell modules required

## Quick Start

```powershell
# Interactive authentication (prompts for credentials)
.\Get-VeeamDiagram.ps1 -Server "vbr01.contoso.com"

# Pre-built credentials
$cred = Get-Credential
.\Get-VeeamDiagram.ps1 -Server "vbr01" -Credential $cred -IncludeJobs

# Full discovery with self-signed cert
$cred = New-Object PSCredential("DOMAIN\admin", (ConvertTo-SecureString "P@ss" -AsPlainText -Force))
.\Get-VeeamDiagram.ps1 -Server "10.0.0.5" -Credential $cred -SkipCertificateCheck -IncludeJobs -IncludeJobSessions -ExportJson -ZipBundle
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `-Server` | String | Yes | - | VBR server hostname or IP |
| `-Port` | Int | No | 9419 | REST API port |
| `-Credential` | PSCredential | No | - | Pre-built credential object |
| `-Username` | String | No | - | Username (alternative to -Credential) |
| `-Password` | SecureString | No | - | Password (alternative to -Credential) |
| `-SkipCertificateCheck` | Switch | No | - | Skip TLS cert validation |
| `-IncludeJobs` | Switch | No | - | Include backup jobs in diagram |
| `-IncludeJobSessions` | Switch | No | - | Include job status colors |
| `-OutFolder` | String | No | Timestamped | Output directory |
| `-ExportJson` | Switch | No | - | Export raw data as JSON |
| `-DiagramLayout` | String | No | Hierarchical | Layout style |
| `-ZipBundle` | Switch | No | - | Compress outputs to ZIP |

## Output Files

```
VeeamDiagram_20260214_153000/
  Veeam-Infrastructure-2026-02-14_1530.drawio      # Draw.io diagram
  Veeam-Infrastructure-Report-2026-02-14_1530.html  # HTML report
  Veeam-Infrastructure-Summary-2026-02-14_1530.csv  # Component counts
  Veeam-Infrastructure-2026-02-14_1530.json         # Raw data (if -ExportJson)
  Veeam-Diagram-Log-2026-02-14_1530.txt             # Execution log
  Veeam-Diagram-Bundle-2026-02-14_1530.zip          # Archive (if -ZipBundle)
```

## Diagram Layout

The draw.io diagram uses a hierarchical top-down layout:

```
                    [VBR Server]
                         |
        ┌────────────────┼────────────────┐
   [vCenter 1]      [Hyper-V 1]     [Linux Host]
        |                |
   [Proxy 1]        [Proxy 2]       [Proxy 3]

   [Repo 1]    [Repo 2]    [SOBR 1]──[Extent 1]
                                   └──[Extent 2]

              [WAN Accelerator 1]

   [Job 1]    [Job 2]    [Job 3]    [Job 4]
```

- **Edges** connect components to show relationships (server-to-proxy, job-to-repository, SOBR-to-extent)
- **Colors** indicate component types and job status (green = success, yellow = warning, red = failed)
- **Tooltips** provide additional detail on hover in draw.io

## API Authentication

The tool uses OAuth 2.0 password grant against `/api/oauth2/token`. Three authentication methods are supported:

1. **PSCredential object** (`-Credential`) — recommended for scripted use
2. **Username + SecureString** (`-Username` + `-Password`) — alternative for automation
3. **Interactive prompt** — default when no credentials provided

Tokens are automatically managed with retry logic and exponential backoff for API throttling.

## Troubleshooting

| Issue | Resolution |
|-------|-----------|
| Certificate error | Use `-SkipCertificateCheck` for self-signed certs |
| 401 Unauthorized | Verify credentials and account permissions |
| Connection refused | Confirm port 9419 is open and REST API service is running |
| Empty diagram | Account may lack Viewer role — check VBR RBAC settings |
| Timeout errors | Script retries automatically (up to 4 attempts with exponential backoff) |
