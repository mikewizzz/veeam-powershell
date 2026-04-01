# Get-VBAHealthCheck

Production-grade health check for Veeam Backup for Azure (VBA) appliances. Connects directly to the VBA REST API (v8.1) for comprehensive assessment across 9 health categories.

**Zero dependencies** - no Azure PowerShell modules required. Only needs PowerShell 5.1+ and network access to the VBA appliance.

## Quick Start

```powershell
# Interactive login with self-signed cert bypass
.\Get-VBAHealthCheck.ps1 -Server vba.example.com -SkipCertificateCheck

# Explicit credential
.\Get-VBAHealthCheck.ps1 -Server 10.0.0.5 -Credential (Get-Credential)

# Automation with pre-obtained token
.\Get-VBAHealthCheck.ps1 -Server vba.corp.com -Token "eyJ..." -SkipHTML

# Stricter thresholds
.\Get-VBAHealthCheck.ps1 -Server vba.example.com -RPOThresholdHours 12 -SLATargetPercent 99
```

## What It Checks

| Category | Weight | What's Assessed |
|----------|--------|-----------------|
| Protection Coverage | 20% | VM, SQL, File Share, Cosmos DB protection rates |
| Policy Health | 15% | Policy errors, disabled policies, SLA compliance |
| Configuration Check | 15% | VBA built-in check: roles, workers, repos, MFA, SSO |
| System Health | 10% | Services, version, system state, disabled features |
| License Health | 10% | Type, expiry, instance usage, grace period |
| Session Health | 10% | Success rate, recent failures, long-running policies |
| Repository Health | 10% | Status, encryption, immutability, storage tier |
| Worker Health | 5% | Worker status, bottlenecks (CPU, storage, wait time) |
| Configuration Backup | 5% | Enabled, last backup status, backup age |

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-Server` | string | **required** | VBA appliance hostname or IP |
| `-Port` | int | 443 | API port |
| `-Credential` | PSCredential | interactive | Username/password for OAuth2 |
| `-Token` | string | - | Pre-obtained bearer token |
| `-SkipCertificateCheck` | switch | false | Bypass TLS cert validation |
| `-RPOThresholdHours` | int | 24 | RPO compliance threshold |
| `-SLATargetPercent` | int | 95 | SLA compliance target |
| `-ConfigBackupAgeDays` | int | 7 | Max config backup age |
| `-LicenseExpiryWarningDays` | int | 30 | License expiry warning threshold |
| `-OutputPath` | string | auto-timestamped | Output directory |
| `-SkipHTML` | switch | false | Skip HTML report |
| `-SkipZip` | switch | false | Skip ZIP archive |

## Authentication

The tool supports three authentication methods:

1. **Interactive** (default) - prompts for credentials if neither `-Credential` nor `-Token` is provided
2. **PSCredential** - pass credentials via `-Credential (Get-Credential)` or pre-built credential objects
3. **Bearer Token** - pass a pre-obtained token via `-Token` for CI/CD pipelines

All authentication flows use the VBA OAuth2 endpoint (`POST /api/oauth2/token`). Tokens are automatically refreshed during long-running assessments.

## Output Files

| File | Content |
|------|---------|
| `VBA-HealthCheck-Report.html` | Executive-grade HTML report (Fluent Design) |
| `health_check_findings.csv` | All findings with severity and recommendations |
| `health_score_summary.csv` | Overall + per-category scores and grades |
| `protection_coverage.csv` | Workload protection statistics |
| `unprotected_vms.csv` | Unprotected VM inventory |
| `unprotected_sql.csv` | Unprotected SQL database inventory |
| `unprotected_fileshares.csv` | Unprotected file share inventory |
| `unprotected_cosmosdb.csv` | Unprotected Cosmos DB inventory |
| `policy_status.csv` | All policies with status |
| `sla_compliance.csv` | SLA compliance per policy |
| `session_failures.csv` | Recent failed sessions |
| `repository_health.csv` | Repository configuration details |
| `worker_health.csv` | Worker instance details |
| `license_resources.csv` | Per-resource license state |
| `configuration_check.csv` | VBA configuration check results |
| `system_info.csv` | Appliance system information |
| `health_check_data.json` | Machine-readable health score bundle |
| `execution_log.csv` | Full execution log |

All files are packaged into a ZIP archive by default.

## Health Score

The overall health score (0-100) is a weighted average across all 9 categories. Each finding scores:
- **Healthy**: 100 points
- **Warning**: 50 points
- **Critical**: 0 points

Grades: **Excellent** (>=90), **Good** (>=70), **Needs Attention** (>=50), **Critical** (<50).

## Prerequisites

- PowerShell 5.1 or later (7.x recommended)
- Network access to VBA appliance on port 443 (or custom port)
- VBA console user credentials with read access

## Troubleshooting

**Connection refused**: Verify the server address and port. The VBA API runs on port 443 by default.

**Certificate errors**: Use `-SkipCertificateCheck` for appliances with self-signed certificates.

**Authentication failed**: Verify credentials. The tool uses OAuth2 Password grant - MFA-enabled accounts are not yet supported.

**403 Forbidden**: The API user may lack required permissions. Ensure the user has console access.

**Configuration check timeout**: The built-in check has a 120-second timeout. Large environments may need more time - the tool will still report partial results.

## Architecture

```
Get-VBAHealthCheck/
  Get-VBAHealthCheck.ps1       # Main entry point
  lib/
    Helpers.ps1                # String/format utilities
    Logging.ps1                # Console logging, progress tracking
    ApiClient.ps1              # OAuth2 auth, retry, pagination
    DataCollection.ps1         # API data retrieval
    HealthChecks.ps1           # Findings engine, scoring
    Charts.ps1                 # SVG chart generators
    HtmlReport.ps1             # HTML report (Fluent Design)
    Exports.ps1                # CSV, JSON, ZIP export
  README.md
```

## Disclaimer

This is a community-maintained tool, not an official Veeam product. All API operations are read-only with the exception of triggering the built-in configuration check.
