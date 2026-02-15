# Test-VeeamVaultBackup - SureBackup for Azure

Automated recoverability testing of Azure VM backups stored in **Veeam Vault** — the cloud equivalent of Veeam SureBackup for on-premises environments.

## What It Does

1. **Discovers** restore points in Veeam Vault via the VBR REST API
2. **Creates** an isolated Azure test environment (VNet + NSG with no external connectivity)
3. **Restores** selected VMs from Vault into the isolated environment
4. **Verifies** each restored VM with four checks:
   - Boot verification (provisioning state + power state)
   - Heartbeat check (Azure VM Agent status)
   - TCP port verification (via Azure Run Command)
   - Custom script execution (user-provided)
5. **Reports** results in a professional HTML report with Microsoft Fluent Design System
6. **Cleans up** all test resources automatically

## Quick Start

```powershell
# Basic usage - tests up to 5 most recent restore points
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential)
```

## Prerequisites

| Requirement | Details |
|---|---|
| **PowerShell** | 7.x recommended, 5.1 supported |
| **Azure Modules** | Az.Accounts, Az.Resources, Az.Compute, Az.Network |
| **VBR Server** | Veeam Backup & Replication v12+ with REST API enabled (port 9419) |
| **Permissions** | VBR: Restore Operator or higher. Azure: Contributor on target subscription |

### Install Azure Modules

```powershell
Install-Module Az.Accounts, Az.Resources, Az.Compute, Az.Network -Scope CurrentUser
```

## Usage Examples

### Test a specific backup job

```powershell
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
  -BackupJobNames "Azure-Prod-VMs" -MaxVMsToTest 3
```

### Extended verification with SQL and HTTPS port checks

```powershell
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
  -VerificationPorts 3389,443,1433 -BootTimeoutMinutes 20
```

### Custom verification script with manual inspection

```powershell
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
  -VerificationScript "C:\Scripts\verify-app.ps1" -KeepTestEnvironment
```

### Non-interactive with Service Principal

```powershell
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential $vbrCred `
  -ServicePrincipalId $appId -CertificateThumbprint $thumbprint -TenantId $tenantId `
  -TestRegion "westeurope" -MaxRestorePointAgeDays 3
```

### Scheduled weekly DR validation

```powershell
# Run as a scheduled task for weekly compliance reporting
.\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential $vbrCred `
  -UseManagedIdentity -MaxVMsToTest 10 -ZipOutput
```

## Parameters

### VBR Connection

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `VBRServer` | string | Yes | — | VBR server hostname or IP |
| `VBRPort` | int | No | 9419 | VBR REST API port |
| `VBRCredential` | PSCredential | Yes | — | Credentials for VBR REST API |

### Azure Authentication

| Parameter | Type | Default | Description |
|---|---|---|---|
| `TenantId` | string | — | Azure AD tenant ID |
| `UseManagedIdentity` | switch | — | Managed Identity auth |
| `ServicePrincipalId` | string | — | App (client) ID |
| `ServicePrincipalSecret` | securestring | — | Client secret (legacy) |
| `CertificateThumbprint` | string | — | Certificate thumbprint (recommended) |
| `UseDeviceCode` | switch | — | Device code flow |

### Test Environment

| Parameter | Type | Default | Description |
|---|---|---|---|
| `TestResourceGroup` | string | auto-generated | Resource group for test VMs |
| `TestRegion` | string | eastus | Azure region for restores |
| `TestVmSize` | string | Standard_B2s | VM size for test restores |
| `TestVNetCIDR` | string | 10.255.0.0/24 | Isolated test network CIDR |

### Scope

| Parameter | Type | Default | Description |
|---|---|---|---|
| `BackupJobNames` | string[] | all Azure jobs | Filter to specific jobs |
| `MaxRestorePointAgeDays` | int | 7 | Only test recent restore points |
| `MaxVMsToTest` | int | 5 | Limit VMs per run |

### Verification

| Parameter | Type | Default | Description |
|---|---|---|---|
| `VerificationPorts` | int[] | 3389,22 | TCP ports to verify |
| `VerificationScript` | string | — | Custom PowerShell script path |
| `BootTimeoutMinutes` | int | 15 | Max wait for VM boot |

### Output

| Parameter | Type | Default | Description |
|---|---|---|---|
| `KeepTestEnvironment` | switch | false | Skip cleanup for inspection |
| `OutputPath` | string | auto-generated | Output folder |
| `ZipOutput` | switch | true | Create ZIP archive |

## Output Files

```
VeeamVaultTest_<timestamp>/
├── Veeam-Vault-Verification-Report.html    # Professional HTML report
├── verification_results.csv                 # Per-VM test results
├── restore_points_tested.csv                # Restore points that were tested
└── execution_log.csv                        # Detailed execution log

VeeamVaultTest_<timestamp>.zip               # Compressed archive
```

## How the Isolated Environment Works

The test environment is completely isolated from production:

- **Dedicated Resource Group** — tagged with `Purpose=VeeamVaultTest` and `AutoClean=true`
- **Isolated VNet** — separate address space (default `10.255.0.0/24`) with no peering
- **Restrictive NSG** — blocks all inbound/outbound except:
  - Intra-VNet traffic (for internal verification)
  - Azure platform services (VM Agent, Run Command)
- **No public IPs** — test VMs have no Internet-facing endpoints
- **Automatic cleanup** — entire resource group is deleted after testing

## Verification Checks

| Check | What It Tests | Method |
|---|---|---|
| **Boot** | VM provisioning and power state | Azure Resource Manager API |
| **Heartbeat** | VM Agent responsiveness | Azure VM Instance View |
| **Ports** | TCP services are listening | Azure Run Command (in-VM) |
| **Custom Script** | Application-specific validation | Azure Run Command (user script) |

## Compliance

Regular execution of this tool provides evidence for backup recoverability requirements in:

- **NIST SP 800-34** — IT Contingency Planning
- **ISO 27001 A.12.3** — Backup verification
- **SOC 2 CC7.5** — Backup testing controls
- **HIPAA §164.308(a)(7)(ii)(D)** — Testing and revision procedures

## Troubleshooting

### VBR authentication fails

Ensure the VBR REST API is enabled and accessible on port 9419. The REST API is enabled by default in VBR v12+. Verify with: `curl -k https://vbr-server:9419/api/v1/serverInfo`

### No restore points found

- Check that backup jobs are configured for Azure workloads
- Verify backups are targeting Veeam Vault (not local repository)
- Increase `-MaxRestorePointAgeDays` if recent backups are older

### VM boot timeout

- Increase `-BootTimeoutMinutes` for large VMs
- Check Azure subscription quotas in the test region
- Ensure the test VM size (`-TestVmSize`) is available in the region

### Cleanup failed

If automatic cleanup fails, manually delete the resource group:
```powershell
Remove-AzResourceGroup -Name "rg-veeam-vault-test-<timestamp>" -Force
```

## License

MIT — See [LICENSE](../../M365/LICENSE) for details.
