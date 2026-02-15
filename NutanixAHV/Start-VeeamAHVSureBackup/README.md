# Veeam SureBackup for Nutanix AHV

Automated backup recoverability verification for Nutanix AHV workloads protected by Veeam Backup & Replication. Bridges the gap between Veeam's native VMware SureBackup and Nutanix AHV by orchestrating Instant VM Recovery, isolated network testing, and multi-tier application verification through the Prism Central REST API v3.

## The Problem

Veeam SureBackup is available for VMware vSphere but **not for Nutanix AHV**. Organizations running AHV have no automated way to verify that their Veeam backups are actually recoverable. This script fills that gap.

## What It Does

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SureBackup Verification Flow                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  1. CONNECT         VBR Server + Prism Central REST API             │
│         │                                                           │
│  2. DISCOVER        AHV backup jobs → latest restore points         │
│         │                                                           │
│  3. RECOVER         Instant VM Recovery → isolated AHV network      │
│         │                                                           │
│  4. TEST            Heartbeat → Ping → Ports → DNS → HTTP → Custom │
│         │                                                           │
│  5. REPORT          Professional HTML report + CSV + JSON           │
│         │                                                           │
│  6. CLEANUP         Stop recovery sessions, remove temp VMs         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

## Prerequisites

| Component | Version | Notes |
|---|---|---|
| PowerShell | 5.1+ (7.x recommended) | Cross-platform with PS 7 |
| Veeam Backup & Replication | 12.3+ | With Nutanix AHV plugin installed |
| Veeam PowerShell Module | `Veeam.Backup.PowerShell` | Installed with VBR Console |
| Nutanix Prism Central | pc.2024.1+ | REST API v3 |
| Nutanix AHV Plugin for Veeam | 5.0+ | Registered in VBR |

### Nutanix Setup: Isolated Network

Before running SureBackup, create an **isolated network** in Prism Central that has **no route to production**:

1. In Prism Central, go to **Network & Security > Subnets**
2. Create a new subnet (e.g., `SureBackup-Isolated` on VLAN 999)
3. Assign a non-routable IP range (e.g., `192.168.199.0/24`)
4. **Do NOT** configure a default gateway that routes to production
5. Optionally run a DHCP server on this VLAN for automatic IP assignment

The script will auto-detect subnets with `isolated`, `surebackup`, or `lab` in the name, or you can specify one explicitly.

## Quick Start

```powershell
# Basic - test all AHV backup jobs
$cred = Get-Credential  # Prism Central admin credentials
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01.lab.local" `
                                 -PrismCentral "pc01.lab.local" `
                                 -PrismCredential $cred
```

## Usage Examples

### Test Specific Backup Jobs with Port Checks

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -BackupJobNames "AHV-Production","AHV-Tier1" `
                                 -TestPorts @(22, 443, 3389) `
                                 -SkipCertificateCheck
```

### Application-Group Ordered Testing (Tiered Boot Order)

```powershell
# Domain controllers boot first, then SQL, then app/web servers
$groups = @{
    1 = @("dc01", "dns01")        # Infrastructure - boot first
    2 = @("sql01", "sql02")       # Database tier - boot after DC
    3 = @("app01", "web01")       # Application tier - boot last
}

.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -ApplicationGroups $groups `
                                 -TestPorts @(53, 1433, 443, 80) `
                                 -TestDNS
```

### Dry Run (Validate Without Recovering)

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -DryRun
```

### Full Verification with Custom Script

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -BackupJobNames "AHV-CriticalApps" `
                                 -TestPorts @(443, 1433, 5432) `
                                 -TestDNS `
                                 -TestHttpEndpoints @("http://localhost/health", "https://localhost/api/status") `
                                 -TestCustomScript "C:\Scripts\Verify-AppHealth.ps1" `
                                 -IsolatedNetworkName "SureBackup-Isolated" `
                                 -MaxConcurrentVMs 5
```

### Specific VMs Only

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -VMNames @("critical-db01", "critical-app01") `
                                 -TestBootTimeoutSec 600
```

## Parameters

### Connection

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-VBRServer` | Yes | | VBR server hostname or IP |
| `-VBRPort` | No | `9419` | VBR server port |
| `-VBRCredential` | No | Current session | PSCredential for VBR |
| `-PrismCentral` | Yes | | Prism Central hostname or IP |
| `-PrismPort` | No | `9440` | Prism Central API port |
| `-PrismCredential` | Yes | | PSCredential for Prism Central |
| `-SkipCertificateCheck` | No | `$false` | Skip TLS cert validation (labs) |

### Backup Scope

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-BackupJobNames` | No | All AHV jobs | Specific backup job names to test |
| `-VMNames` | No | All VMs | Specific VM names to test |
| `-MaxConcurrentVMs` | No | `3` | Max simultaneous VM recoveries (1-10) |

### Isolated Network

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-IsolatedNetworkName` | No | Auto-detect | Subnet name for isolated recovery |
| `-IsolatedNetworkUUID` | No | Auto-detect | Subnet UUID (alternative to name) |
| `-TargetClusterName` | No | First AHV server | Nutanix cluster for recovery |
| `-TargetContainerName` | No | Cluster default | Storage container for VM disks |

### Test Configuration

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TestBootTimeoutSec` | No | `300` | Max seconds to wait for VM boot (60-1800) |
| `-TestPing` | No | `$true` | Enable ICMP ping test |
| `-TestPorts` | No | None | TCP ports to test (e.g., `@(22,443)`) |
| `-TestDNS` | No | `$false` | Enable DNS resolution test |
| `-TestHttpEndpoints` | No | None | HTTP URLs to test |
| `-TestCustomScript` | No | None | Path to custom verification script |
| `-ApplicationGroups` | No | None | Boot-order group definitions |

### Output

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-OutputPath` | No | `./VeeamAHVSureBackup_[timestamp]` | Output folder |
| `-GenerateHTML` | No | `$true` | Generate HTML report |
| `-ZipOutput` | No | `$true` | Create ZIP archive |

### Behavior

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-CleanupOnFailure` | No | `$true` | Clean up VMs even if tests fail |
| `-DryRun` | No | `$false` | Simulate without recovering VMs |

## Verification Tests

### Phase 1: VM Recovery
Veeam Instant VM Recovery mounts the backup as a live VM on the Nutanix cluster, connected to the isolated network. No production network exposure.

### Phase 2: Heartbeat (NGT)
Checks VM power state and Nutanix Guest Tools (NGT) communication to verify the OS booted successfully.

### Phase 3: Network Tests
- **ICMP Ping**: 4-packet ping test with latency measurement
- **TCP Port**: Connection test on specified ports (SSH, HTTPS, RDP, SQL, etc.)

### Phase 4: Application Tests
- **DNS Resolution**: Reverse DNS lookup to verify DNS infrastructure
- **HTTP Endpoints**: GET request to health/status URLs with status code validation
- **Custom Script**: Execute arbitrary PowerShell verification logic

### Phase 5: Cleanup
Stops all Veeam Instant Recovery sessions and removes temporary VMs from the cluster.

## Custom Verification Scripts

Custom scripts receive three parameters and must return `$true` (pass) or `$false` (fail):

```powershell
# Example: Verify-AppHealth.ps1
param(
    [string]$VMName,
    [string]$VMIPAddress,
    [string]$VMUuid
)

try {
    # Test application-specific health endpoint
    $response = Invoke-RestMethod -Uri "https://${VMIPAddress}:8443/api/health" `
                                   -SkipCertificateCheck -TimeoutSec 10

    if ($response.status -eq "healthy") {
        Write-Host "  $VMName application health check passed"
        return $true
    }

    Write-Host "  $VMName application reports unhealthy: $($response.status)"
    return $false
}
catch {
    Write-Host "  $VMName health check failed: $($_.Exception.Message)"
    return $false
}
```

## Application Groups (Boot Order)

For multi-tier applications, define boot-order groups to ensure dependencies start before dependents:

```powershell
$groups = @{
    1 = @("dc01", "dns01")        # Group 1: Infrastructure (boots first)
    2 = @("sql01")                # Group 2: Database (boots after Group 1 passes)
    3 = @("app01", "web01")       # Group 3: Application (boots after Group 2 passes)
}
```

- Groups execute in numeric order (1, 2, 3, ...)
- VMs within the same group recover concurrently (up to `-MaxConcurrentVMs`)
- Each group's tests must complete before the next group starts
- VMs not assigned to any group run last in a catch-all batch

## Output Files

| File | Description |
|---|---|
| `SureBackup_Report.html` | Professional HTML report with pass/fail summary |
| `SureBackup_TestResults.csv` | Per-test results (VM, test name, pass/fail, details) |
| `SureBackup_RestorePoints.csv` | Restore point metadata for tested VMs |
| `SureBackup_Summary.json` | Machine-readable summary for automation pipelines |
| `SureBackup_ExecutionLog.csv` | Full execution log with timestamps |
| `VeeamAHVSureBackup_*.zip` | ZIP archive of all outputs |

## Pipeline Integration

The script returns a structured object for CI/CD pipeline integration:

```powershell
$result = .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential $cred

if (-not $result.Success) {
    Send-MailMessage -To "backup-team@company.com" `
                     -Subject "SureBackup FAILED: $($result.Failed) test(s)" `
                     -Body "Pass rate: $($result.PassRate)%. See report: $($result.OutputPath)"
    exit 1
}
```

### Scheduled Task Example

```powershell
# Run SureBackup nightly at 2 AM
$action = New-ScheduledTaskAction -Execute "pwsh.exe" -Argument @"
-NoProfile -File "C:\Scripts\Start-VeeamAHVSureBackup.ps1" -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential (Import-Clixml C:\Scripts\prism-cred.xml) -BackupJobNames "AHV-Production" -TestPorts @(22,443)
"@
$trigger = New-ScheduledTaskTrigger -Daily -At 2am
Register-ScheduledTask -TaskName "Veeam-AHV-SureBackup" -Action $action -Trigger $trigger
```

## Architecture

```
┌──────────────┐     PowerShell      ┌──────────────────────┐
│  This Script │────cmdlets─────────▶│  Veeam Backup &      │
│              │                     │  Replication Server   │
│              │                     │  (VBR 12.3+)         │
│              │                     └──────────┬───────────┘
│              │                                │
│              │                     Instant VM Recovery
│              │                     (AHV Plugin)
│              │                                │
│              │     REST API v3     ┌──────────▼───────────┐
│              │────────────────────▶│  Nutanix Prism       │
│              │                     │  Central              │
│              │                     └──────────┬───────────┘
│              │                                │
│              │                     ┌──────────▼───────────┐
│              │◀───test results────│  Recovered VMs on     │
│              │                     │  Isolated Network     │
└──────────────┘                     │  (No production       │
       │                             │   route)              │
       ▼                             └──────────────────────┘
  HTML Report
  CSV Export
  JSON Summary
```

## Troubleshooting

### "No Nutanix AHV backup jobs found"
- Verify AHV backup jobs exist in VBR console
- Ensure the VBR connection user has permission to view all jobs
- Check that the Nutanix AHV plugin is installed and licensed

### "Isolated network not found"
- Create a subnet in Prism Central with `isolated`, `surebackup`, or `lab` in its name
- Or specify explicitly: `-IsolatedNetworkName "YourSubnetName"`
- Verify Prism Central credentials have subnet read permissions

### "VM did not obtain IP within timeout"
- Increase `-TestBootTimeoutSec` (default 300s)
- Ensure DHCP is available on the isolated VLAN
- Verify Nutanix Guest Tools (NGT) is installed in the source VM
- Check that the isolated network VLAN is trunked to the AHV hosts

### "Prism Central connection failed"
- Verify hostname/IP and port (default 9440)
- Use `-SkipCertificateCheck` for self-signed certificates
- Ensure the Prism user has `Prism Central Admin` or equivalent role
- Test manually: `curl -k https://pc01:9440/api/nutanix/v3/clusters/list -X POST -d '{"kind":"cluster"}' -u admin`

### "VBR connection failed"
- Ensure Veeam PowerShell module is installed (`Get-Module -ListAvailable Veeam.*`)
- Verify VBR server is reachable on port 9419
- Check Windows firewall rules on VBR server
- Use `-VBRCredential` if running from a non-domain machine

## Security Considerations

- Prism credentials are passed as `[PSCredential]` (encrypted in memory)
- The isolated network **must not** route to production to prevent backup-based lateral movement
- Use `-SkipCertificateCheck` only in lab environments
- Custom scripts run in the context of the user executing this tool
- Consider using a dedicated service account with minimal Prism Central permissions

## Version History

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-02-15 | Initial release - SureBackup for Nutanix AHV |

## License

MIT License - See [LICENSE](../../M365/LICENSE) in the repository root.
