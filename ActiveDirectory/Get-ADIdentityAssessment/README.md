# Get-ADIdentityAssessment - On-Premises Active Directory Identity Assessment

PowerShell script that performs a read-only assessment of on-premises Active Directory environments. Discovers forests, domains, trusts, sites, and identity objects, then generates a professional HTML report with executive summary and complexity scoring.

## Features

- **Multi-forest discovery** — Automatic or explicit forest enumeration
- **Identity object inventory** — Users, computers, groups, OUs, GPOs, service accounts
- **Topology mapping** — Domains, trusts, sites, subnets, replication topology
- **FSMO role placement** — Schema version, functional levels
- **Complexity scoring** — Multi-dimensional environment complexity evaluation
- **Stale object analysis** — Identify inactive users and computers (Full mode)
- **Password policy audit** — Domain password policies (Full mode)
- **Professional HTML report** — Executive summary with topology map and detail tables
- **JSON export** — Machine-readable data for programmatic consumption
- **ZIP bundle** — Compressed archive of all outputs

## Prerequisites

- Windows PowerShell 5.1+ or PowerShell 7+
- `ActiveDirectory` module (RSAT)
  - **Servers:** `Install-WindowsFeature RSAT-AD-PowerShell`
  - **Windows 10/11:** `Add-WindowsCapability -Online -Name RSAT.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0`
- Account with read access to AD (Domain Users is sufficient for most data)
- For multi-forest: trust relationships or explicit credentials

## Quick Start

```powershell
# Basic assessment — auto-discover reachable forests
.\Get-ADIdentityAssessment.ps1

# Full assessment (includes stale analysis and password policy audit)
.\Get-ADIdentityAssessment.ps1 -Full

# Multi-forest with explicit forest list
.\Get-ADIdentityAssessment.ps1 -ForestNames "corp.contoso.com","partner.fabrikam.com"

# Cross-forest with explicit credentials
.\Get-ADIdentityAssessment.ps1 -ForestNames "partner.fabrikam.com" -Credential (Get-Credential)
```

## Parameters

### Discovery Scope
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-ForestNames` | String[] | | Explicit forest FQDNs to assess (omit for auto-discovery) |

### Run Level
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Full` | Switch | | Include stale analysis, password policies, deeper metrics |

### Stale Object Thresholds
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-StaleUserDays` | Int | `90` | Days of inactivity before a user is considered stale (30-730) |
| `-StaleComputerDays` | Int | `90` | Days of inactivity before a computer is considered stale (30-730) |

### Output
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-OutFolder` | String | `.\ADIdentityAssessment` | Output directory |
| `-ExportJson` | Switch | | Generate JSON data export |
| `-ZipBundle` | Switch | | Compress outputs to ZIP |
| `-SkipModuleCheck` | Switch | | Skip ActiveDirectory module validation |

### Authentication
| Parameter | Type | Description |
|-----------|------|-------------|
| `-Credential` | PSCredential | Credential for cross-forest queries |

## Outputs

Each run creates a timestamped folder with:

| File | Description |
|------|-------------|
| `AD-Identity-Report-*.html` | Professional HTML report with executive summary |
| `AD-Assessment-Log-*.txt` | Execution log |
| `AD-Identity-Data-*.json` | Raw assessment data (if `-ExportJson` enabled) |

## Security

- **Read-only** — This script makes zero changes to Active Directory
- **Standard protocols** — All queries use LDAP/ADWS, no schema extensions required
- **No credential storage** — No credentials are stored or transmitted
- **Local output** — No data leaves the local machine
