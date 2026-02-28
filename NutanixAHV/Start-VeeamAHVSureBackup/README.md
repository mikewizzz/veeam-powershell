# Veeam SureBackup for Nutanix AHV

Automated backup recoverability verification for Nutanix AHV workloads protected by Veeam Backup & Replication. Restores VMs to an isolated network, runs configurable verification tests, and generates professional reports.

## Prerequisites

| Component | Version |
|---|---|
| PowerShell | 5.1+ (7.x recommended) |
| Veeam Backup & Replication | 13.0.1+ with Nutanix AHV Plugin v9 |
| Nutanix Prism Central | pc.2024.1+ (REST API v3 or v4) |

Before running, create an **isolated network** in Prism Central with no route to production (e.g., `SureBackup-Isolated` on a dedicated VLAN). The script auto-detects subnets with `isolated`, `surebackup`, or `lab` in the name.

## Quick Start

```powershell
$vbrCred = Get-Credential   # VBR server credentials
$pcCred  = Get-Credential   # Prism Central credentials
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01.lab.local" `
                                 -VBRCredential $vbrCred `
                                 -PrismCentral "pc01.lab.local" `
                                 -PrismCredential $pcCred
```

## Usage Examples

```powershell
# Test specific jobs with port checks
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred `
    -PrismCentral "pc01" -PrismCredential $pcCred `
    -BackupJobNames "AHV-Production" -TestPorts @(22, 443, 3389) -SkipCertificateCheck

# Interactive VM selection
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred `
    -PrismCentral "pc01" -PrismCredential $pcCred -Interactive

# Application-group boot ordering (DCs first, then SQL, then app tier)
$groups = @{ 1 = @("dc01","dns01"); 2 = @("sql01"); 3 = @("app01","web01") }
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred `
    -PrismCentral "pc01" -PrismCredential $pcCred `
    -ApplicationGroups $groups -TestPorts @(53, 1433, 443)

# Dry run — validate connectivity without recovering VMs
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred `
    -PrismCentral "pc01" -PrismCredential $pcCred -DryRun
```

## Parameters

### Connection

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-VBRServer` | Yes | | VBR server hostname or IP |
| `-VBRCredential` | Yes | | PSCredential for VBR authentication |
| `-PrismCentral` | Yes | | Prism Central hostname or IP |
| `-PrismCredential` | Yes | | PSCredential for Prism Central |
| `-PrismPort` | No | `9440` | Prism Central API port |
| `-SkipCertificateCheck` | No | `$false` | Skip TLS cert validation (labs) |

### Scope & Recovery

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-BackupJobNames` | No | All AHV jobs | Backup job names to test |
| `-VMNames` | No | All VMs | Specific VM names to test |
| `-MaxConcurrentVMs` | No | `3` | Max simultaneous recoveries (1-10) |
| `-IsolatedNetworkName` | No | Auto-detect | Isolated subnet name |
| `-IsolatedNetworkUUID` | No | Auto-detect | Isolated subnet UUID |
| `-TargetClusterName` | No | Source cluster | Recovery target cluster |
| `-TargetContainerName` | No | Cluster default | Storage container for disks |

### Testing

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TestBootTimeoutSec` | No | `300` | Max seconds to wait for VM boot |
| `-TestPing` | No | `$true` | Enable ICMP ping test |
| `-TestPorts` | No | None | TCP ports to test (e.g., `@(22,443)`) |
| `-TestDNS` | No | `$false` | Enable DNS resolution test |
| `-TestHttpEndpoints` | No | None | HTTP URLs to test |
| `-TestCustomScript` | No | None | Custom verification script path |
| `-ApplicationGroups` | No | None | Boot-order group definitions |

### Behavior & Output

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-DryRun` | No | `$false` | Simulate without recovering VMs |
| `-Interactive` | No | `$false` | Search/filter VMs by name, then select interactively |
| `-CleanupOnFailure` | No | `$true` | Clean up VMs even if tests fail |
| `-SkipPreflight` | No | `$false` | Skip preflight health checks |
| `-OutputPath` | No | Auto-generated | Output folder for reports |
| `-GenerateHTML` | No | `$true` | Generate HTML report |
| `-ZipOutput` | No | `$true` | Create ZIP archive |

## Output Files

| File | Description |
|---|---|
| `SureBackup_Report.html` | HTML report with pass/fail summary |
| `SureBackup_TestResults.csv` | Per-test results |
| `SureBackup_Summary.json` | Machine-readable summary |
| `VeeamAHVSureBackup_*.zip` | ZIP archive of all outputs |

## Troubleshooting

| Error | Fix |
|---|---|
| "No AHV backup jobs found" | Verify jobs exist in VBR and credentials have API access |
| "Isolated network not found" | Create a subnet with `isolated`/`surebackup`/`lab` in the name, or use `-IsolatedNetworkName` |
| "VM did not obtain IP" | Increase `-TestBootTimeoutSec`, ensure DHCP on isolated VLAN, verify NGT installed |
| "Prism Central connection failed" | Check hostname/port, try `-SkipCertificateCheck`, verify admin role |
| "VBAHV Plugin auth failed" | Verify VBR credentials, ensure port 9419 reachable, plugin installed |

## Security

- Isolated network **must not** route to production
- All credentials use `[PSCredential]` (encrypted in memory)
- Use `-SkipCertificateCheck` only in lab environments

| System | Minimum Role |
|--------|-------------|
| Prism Central | `Prism Central Admin` or VM CRUD + Subnet Read |
| Veeam VBR | `Veeam Restore Operator` |

## Emergency Cleanup

If interrupted, orphaned VMs may remain. In Prism Central, filter VMs by prefix `SureBackup_` and delete them.

## Version History

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-02-28 | Initial release |

## License

MIT License - See [LICENSE](../../M365/LICENSE) in the repository root.
