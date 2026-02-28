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
| Veeam Backup & Replication | 13.0.1+ | With Nutanix AHV plugin v9 installed |
| Veeam PowerShell Module | `Veeam.Backup.PowerShell` | Installed with VBR Console |
| Nutanix Prism Central | pc.2024.1+ | REST API v3 or v4 |
| Veeam Plug-in for Nutanix AHV | v9 (v8 supported) | Registered in VBR; REST API for FullRestore |

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

### Full Restore with Network Selection (Zero Production Exposure)

```powershell
# Uses the Veeam Plug-in for Nutanix AHV REST API (v9) to perform a full VM restore
# with native network adapter mapping — VM is created directly on the isolated network.
# Slower than InstantRecovery (full disk copy) but inherently safer.
# API Ref: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints
$vbrCred = Get-Credential   # VBR server credentials (required for REST API auth)
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -VBRCredential $vbrCred `
                                 -RestoreMethod "FullRestore" `
                                 -TestPorts @(22, 443)
```

### Skip Preflight Checks (Not Recommended)

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
                                 -PrismCentral "pc01" `
                                 -PrismCredential $cred `
                                 -SkipPreflight
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

### Restore Method

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-RestoreMethod` | No | `InstantRecovery` | `InstantRecovery` (fast, NIC swap) or `FullRestore` (slower, native network mapping via [VBAHV REST API](https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints)) |
| `-VBAHVApiVersion` | No | `v9` | Veeam AHV Plugin REST API version (`v8` or `v9`). Only `v8` and `v9` are supported by the plugin |

### Preflight Health Checks

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-PreflightMaxAgeDays` | No | `7` | Max restore point age (days) before warning |
| `-SkipPreflight` | No | `$false` | Skip all preflight checks (not recommended) |

## Verification Tests

### Phase 0: Preflight Health Checks (NEW)
Validates cluster health, capacity, network configuration, restore point integrity/recency, and backup job status before any recovery operations. Prevents wasting time on recoveries that are likely to fail.

### Phase 1: VM Recovery

**InstantRecovery (default):** Veeam Instant VM Recovery mounts the backup as a live VM via vPower NFS. The script powers the VM off, switches the NIC to the isolated network via Prism API, then powers it back on. Fast (~30s) but has a brief production network exposure window.

**FullRestore:** Uses the [Veeam Plug-in for Nutanix AHV REST API v9](https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints) `POST /restorePoints/restore` with `networkAdapters` mapping. The VM is created directly on the isolated network — zero production exposure. Slower (full disk copy, minutes) but inherently safer.

| Aspect | InstantRecovery | FullRestore |
|--------|----------------|-------------|
| Speed | Fast (~30s vPower mount) | Slow (minutes, full disk copy) |
| Network safety | Power-off/NIC-swap workaround | Native network mapping — zero exposure |
| Production exposure | Brief (~5-15s during VM discovery) | None |
| Cleanup method | `Stop-VBRInstantRecovery` | Power off + delete VM from Prism |
| VBR session | Yes (vPower NFS mount) | No (independent VM) |
| Requires | VBR PowerShell cmdlets | VBR OAuth2 + AHV Plugin REST API (v8/v9) |

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

### "VM failed to power off within 120s"
- The script powers off recovered VMs before switching NICs (network isolation safety)
- If this times out, the VM may have a guest OS issue or Nutanix cluster contention
- Check Prism Central for task failures: **Settings > Tasks > Filter by VM name**
- Ensure the Prism user has VM power management permissions

### "Network isolation failure: NIC reconfiguration failed"
- The isolated network subnet UUID may have changed since the script started
- Verify the isolated network still exists: `GET /api/networking/v4.0/config/subnets`
- Check that the Prism user has VM NIC update permissions (`VM Admin` or `Cluster Admin`)
- If using Nutanix Flow microsegmentation, ensure the policy allows NIC changes

### "Custom script errors"
- Custom scripts must be `.ps1` PowerShell files executed on the VBR server (not the recovered VM)
- Scripts receive `-VMName`, `-VMIPAddress`, and `-VMUuid` parameters
- Check execution policy: `Get-ExecutionPolicy` (must be `RemoteSigned` or `Unrestricted`)
- Scripts must return `$true` (pass) or `$false` (fail)

### "Script hangs at a particular step"
- Check the log file in the output directory for the last message
- Common hang points: Prism API timeouts, DHCP lease exhaustion, VM discovery delays
- Use `Ctrl+C` to interrupt, then check for orphaned VMs in Prism Central
- Recovered VM names start with `SureBackup_` — delete any orphans manually

## Security Considerations

### Network Isolation (Critical)
- The isolated network **must not** route to production to prevent backup-based lateral movement
- **How it works:** Veeam's `Start-VBRInstantRecoveryToNutanixAHV` does not accept a network parameter, so recovered VMs initially boot on the production network. The script immediately powers them off, switches the NIC to the isolated network, then powers them back on. The production exposure window is minimized to the VM discovery time (~5-15 seconds)
- **Recommended setup:** Create a dedicated VLAN with no default gateway, no routing to production subnets, and a DHCP scope for test IPs only
- **Validation:** The script warns if the isolated network UUID matches the VM's original production NIC — this indicates a misconfiguration

### Credentials
- Prism credentials are passed as `[PSCredential]` (encrypted in memory by PowerShell)
- For scheduled tasks, store credentials securely:
  ```powershell
  # Export encrypted credential (user-specific, machine-specific)
  Get-Credential | Export-Clixml -Path "C:\SecureStore\prism-cred.xml"
  # Import in scheduled task
  $cred = Import-Clixml -Path "C:\SecureStore\prism-cred.xml"
  ```
- Use a dedicated service account with minimum required permissions

### Minimum Required Permissions

| System | Role / Permission | Purpose |
|--------|-------------------|---------|
| Prism Central | `Prism Central Admin` or custom role with VM CRUD + Subnet Read | VM discovery, NIC reconfiguration, power management |
| Veeam VBR | `Veeam Restore Operator` | Instant recovery, restore point access |
| Windows (VBR host) | Local administrator or Veeam service account | PowerShell module loading, remote connection |

### TLS Certificates
- Use `-SkipCertificateCheck` only in lab environments with self-signed certificates
- On PowerShell 5.1, the TLS bypass is applied globally to the entire session
- On PowerShell 7+, the bypass is scoped per-request
- For production, install a trusted CA certificate on Prism Central

### Custom Script Security
- Custom scripts (`-TestCustomScript`) run in the context of the executing user on the VBR server
- Ensure script paths are read-only for non-admin users to prevent tampering
- Scripts have network access to the isolated network — verify they cannot exfiltrate data

### Report Security
- HTML reports contain VM names, IP addresses, test results, and log entries
- All values are HTML-escaped to prevent XSS (cross-site scripting)
- Store reports in access-controlled directories if they contain sensitive infrastructure details

## Performance & Capacity Planning

| Parameter | Default | Impact | Guidance |
|-----------|---------|--------|----------|
| `MaxConcurrentVMs` | 3 | Higher = more cluster resources consumed during recovery | Start with 3, increase to 5-10 on large clusters (>16 nodes) |
| `TestBootTimeoutSec` | 300s | Higher = longer wait for slow VMs before timeout | Set to 600-900s for VMs with slow storage or large OS |
| `TestPorts` | none | Each port test adds ~5s per VM | Limit to 3-5 critical ports |
| `TestHttpEndpoints` | none | Each HTTP test adds ~15s per VM (with timeout) | Test 1-2 key endpoints per application |

### Expected Runtime

| VMs | MaxConcurrent | Tests | Estimated Time |
|-----|---------------|-------|---------------|
| 5 | 3 | Heartbeat + Ping | 5-10 min |
| 10 | 5 | Heartbeat + Ping + Ports | 15-25 min |
| 50 | 5 | Full verification | 60-120 min |
| 100+ | 10 | Full verification | 2-4 hours |

### Cluster Resource Impact
- Each recovered VM consumes CPU, memory, and storage I/O on the target AHV cluster
- Instant recovery uses Veeam's vPower NFS datastore — ensure the VBR server has sufficient disk I/O
- Recovery operations are serial within a batch; batches run sequentially

## Dry Run Mode

Use `-DryRun` to validate configuration without recovering any VMs:

```powershell
.\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" `
  -PrismCentral "pc01" -PrismCredential $cred `
  -DryRun
```

**What DryRun validates:**
- Prism Central connectivity and credentials
- Isolated network resolution
- VBR connectivity and module loading
- Backup job discovery and restore point availability
- Application group configuration

**What DryRun does NOT validate:**
- Actual VM recovery (no VMs are powered on)
- Network connectivity tests (no NICs to test)
- Custom script execution

## Emergency Cleanup

If the script is interrupted or crashes, recovered VMs may be left running on the isolated network. To clean up:

1. **Check for orphaned VMs** in Prism Central:
   - Filter by name prefix: `SureBackup_`
   - These are safe to delete — they are instant recovery mounts

2. **Stop Veeam instant recovery sessions:**
   ```powershell
   # List active instant recovery sessions
   Get-VBRInstantRecovery | Where-Object { $_.VMName -like "SureBackup_*" }
   # Stop a specific session
   Get-VBRInstantRecovery | Where-Object { $_.VMName -like "SureBackup_*" } | Stop-VBRInstantRecovery
   ```

3. **Force-delete VMs from Prism** (if Veeam cleanup fails):
   ```
   Prism Central > VMs > Filter "SureBackup_" > Power Off > Delete
   ```

## Version History

| Version | Date | Changes |
|---|---|---|
| 1.2.0 | 2026-02-28 | Preflight health checks, Full Restore via [VBAHV Plugin REST API v9](https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints) with native network mapping, `-RestoreMethod` parameter, `-SkipPreflight` / `-PreflightMaxAgeDays` params |
| 1.1.0 | 2026-02-22 | Network isolation hardening: power-off-before-NIC-switch, fatal NIC failure, XSS protection, application group dependency enforcement, expanded tests |
| 1.0.0 | 2026-02-15 | Initial release - SureBackup for Nutanix AHV |

## License

MIT License - See [LICENSE](../../M365/LICENSE) in the repository root.
