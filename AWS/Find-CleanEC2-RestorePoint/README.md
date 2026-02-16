# Find-CleanEC2-RestorePoint - VRO Pre-Step: Latest Clean Restore Point

PowerShell script that scans Veeam restore points from newest to oldest and identifies the most recent one verified clean by Veeam's security stack. Designed as a VRO plan pre-step that feeds the selected restore point ID into downstream restore steps.

## Features

- **Multi-layer malware verification** with prioritized hierarchy:
  1. Inline Malware Detection (VBR 12.1+ — highest confidence)
  2. SureBackup verification sessions
  3. Secure Restore antivirus scans
  4. Backup session success (fallback, lowest confidence)
- **VRO integration** — Outputs structured JSON for downstream step consumption
- **Configurable scan depth** — Control how many restore points to check
- **Minimum age filter** — Skip recent points that may not have completed scanning
- **Strict mode** — Optionally require an actual malware scan (reject session-only verification)
- **Exponential backoff retry** for transient failures
- **Detailed logging** to console and log file

## Use Cases

- **Ransomware recovery** — Find the last known-good restore point before infection
- **Compliance** — Ensure only verified backups are used in DR plans
- **VRO orchestration** — Chain with `Restore-VRO-AWS-EC2.ps1` as a pre-step

## Prerequisites

- PowerShell 5.1+ (7.x recommended)
- `Veeam.Backup.PowerShell` module (VBR 12+)
- Veeam Backup & Replication 12.0+ (12.1+ for inline malware detection)
- VRO Compatibility: Veeam Recovery Orchestrator 7.0+

## Quick Start

```powershell
# Find latest clean point for a backup
.\Find-CleanEC2-RestorePoint.ps1 -BackupName "Daily-FileServer"

# Strict mode: require actual malware scan, check up to 30 points
.\Find-CleanEC2-RestorePoint.ps1 -BackupName "SAP-Production" -VMName "SAP-APP01" `
  -RequireMalwareScan -MaxPointsToScan 30

# Skip points newer than 4 hours (allow time for scan completion)
.\Find-CleanEC2-RestorePoint.ps1 -BackupName "DC-Backup" -MinAge 4
```

## Parameters

### VBR Server Connection
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VBRServer` | String | `localhost` | VBR server hostname or IP |
| `-VBRCredential` | PSCredential | | Credential for VBR auth (omit for Windows integrated auth) |
| `-VBRPort` | Int | `9392` | VBR server port |

### Backup Selection
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-BackupName` | String | **(required)** | Veeam backup job name |
| `-VMName` | String | | Specific VM within a multi-VM backup |

### Scan Configuration
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-MaxPointsToScan` | Int | `14` | Max restore points to check (1-365) |
| `-RequireMalwareScan` | Switch | | Require positive malware scan result |
| `-MinAge` | Int | `0` | Minimum restore point age in hours (0-720) |

### VRO Integration
| Parameter | Type | Description |
|-----------|------|-------------|
| `-VROPlanName` | String | VRO recovery plan name (passed by VRO) |
| `-VROStepName` | String | VRO plan step name (passed by VRO) |

### Output
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-OutputPath` | String | `./CleanPointOutput_<timestamp>` | Output folder for logs and results |

## Outputs

Each run creates a timestamped folder with:

| File | Description |
|------|-------------|
| `CleanPoint-Log-*.txt` | Execution log with timestamped entries |
| `CleanPoint-Result-*.json` | Machine-readable result with restore point ID and verification details |

The script also writes a `VRO_OUTPUT:` JSON line to stdout for VRO downstream step variable capture.

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Clean restore point found |
| `1` | No clean restore point found — VRO should halt the recovery plan |

## Security Verification Hierarchy

The script checks each restore point against multiple verification sources in priority order and stops at the first verified-clean point:

1. **Inline Malware Detection** — Real-time scan during backup (highest confidence)
2. **SureBackup Sessions** — Automated verification lab results
3. **Secure Restore Scan** — On-demand antivirus scan
4. **Backup Session Success** — Job success only, no malware scan (lowest confidence, skipped if `-RequireMalwareScan` is set)
