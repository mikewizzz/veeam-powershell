# Restore-VRO-AWS-EC2 - VRO Plan Step: Restore Veeam Backups to Amazon EC2

PowerShell script that bridges Veeam Recovery Orchestrator (VRO) and AWS by enabling automated restore of Veeam backups stored in S3 (direct repository or SOBR capacity tier) to Amazon EC2 instances. Includes enterprise features for ransomware recovery, SLA tracking, and DR drill automation.

## Features

- **Full restore pipeline** — From backup discovery through EC2 instance validation
- **Multiple backup sources** — S3 Direct Repository, SOBR with S3 Capacity Tier, VBA snapshots
- **IAM best practices** — Instance Profile, STS AssumeRole, Named Profiles, environment variables
- **Clean restore point scanning** — Optional malware-free point selection via Secure Restore
- **EC2 configuration** — Instance type, VPC/subnet/SG selection, EBS disk type, KMS encryption
- **Post-restore validation** — Instance health checks, EC2 status checks with timeout
- **Resource tagging** — Automatic governance and cost-tracking tags on all restored resources
- **VRO integration** — Structured JSON output for plan step variable capture
- **HTML restore report** — Professional report with Microsoft Fluent Design System
- **Dry run mode** — Validate parameters and connectivity without executing restore
- **Exponential backoff retry** for transient failures

### Enterprise Features (v2.0)

| Feature | Description |
|---------|-------------|
| **Network Isolation** | Isolated security group for clean room ransomware recovery |
| **Application Health Checks** | TCP port, HTTP endpoint, and SSM in-guest verification |
| **SLA/RTO Tracking** | Measures actual vs target RTO with compliance reporting |
| **Credential Refresh** | Auto-refreshes STS credentials during long restores |
| **Rollback on Failure** | Terminates orphaned resources when restore fails |
| **CloudWatch Alarms** | Creates CPU and status check alarms on restored instances |
| **Route53 DNS Failover** | Updates DNS records after successful restore |
| **SSM Post-Restore Scripts** | Executes configuration documents on restored instances |
| **DR Drill Mode** | Restore, validate, keep alive, auto-terminate with compliance report |
| **Compliance Audit Trail** | Structured JSONL event log for regulatory compliance |
| **AZ-Level Validation** | Validates instance type availability in target Availability Zone |
| **Private IP Check** | Detects IP collisions before restore |

## File Structure

```
Restore-VRO-AWS-EC2/
├── Restore-VRO-AWS-EC2.ps1        # Main script (params, init, orchestration)
├── Restore-VRO-AWS-EC2.Tests.ps1  # Pester 5.x test suite
├── README.md
└── lib/                            # Dot-sourced libraries (share script scope)
    ├── Logging.ps1                 # Write-Log, Write-VROOutput, Write-AuditEvent
    ├── Helpers.ps1                 # Invoke-WithRetry, Measure-RTOCompliance
    ├── Preflight.ps1               # Test-Prerequisites (module validation)
    ├── Auth.ps1                    # Connect-VBRSession, Connect-AWSSession, credential refresh
    ├── Restore.ps1                 # Backup discovery, EC2 target config, restore execution
    ├── Validation.ps1              # Instance health, TCP port, HTTP, SSM checks
    ├── AWSIntegrations.ps1         # Tagging, CloudWatch, Route53, SSM docs, cleanup, DR drill
    └── Reporting.ps1               # HTML restore report generation
```

All `lib/` files are dot-sourced by the main script at startup and share script-level scope (parameters, `$script:` variables). The load order matters — each file may depend on functions defined in files loaded before it.

## Prerequisites

- PowerShell 5.1+ (7.x recommended)
- `Veeam.Backup.PowerShell` module (VBR 12+, 12.1+ recommended)
- AWS PowerShell modules:
  - `AWS.Tools.Common`
  - `AWS.Tools.EC2`
  - `AWS.Tools.SecurityToken` (for STS AssumeRole)
  - `AWS.Tools.S3` (optional, for backup validation)
- VRO Compatibility: Veeam Recovery Orchestrator 7.0+

### Optional AWS Modules

| Module | Required For |
|--------|-------------|
| `AWS.Tools.SimpleSystemsManagement` | SSM health checks and post-restore scripts |
| `AWS.Tools.CloudWatch` | CloudWatch alarm creation |
| `AWS.Tools.Route53` | DNS record updates |

## Quick Start

```powershell
# Restore latest point to EC2 using defaults
.\Restore-VRO-AWS-EC2.ps1 -BackupName "Daily-FileServer" -AWSRegion "us-east-1"

# Production DR restore with specific networking and encryption
.\Restore-VRO-AWS-EC2.ps1 -BackupName "SAP-Production" -VMName "SAP-APP01" `
  -AWSRegion "eu-west-1" -VPCId "vpc-0abc123" -SubnetId "subnet-0def456" `
  -SecurityGroupIds "sg-0ghi789" -InstanceType "r5.xlarge" -EncryptVolumes `
  -Tags @{ "Environment"="DR"; "Application"="SAP" }

# Ransomware recovery: find latest clean restore point
.\Restore-VRO-AWS-EC2.ps1 -BackupName "DC-Backup" -UseLatestCleanPoint `
  -AWSRegion "us-west-2" -InstanceType "m5.large" -KeyPairName "dr-keypair"

# Cross-account dry run with STS AssumeRole
.\Restore-VRO-AWS-EC2.ps1 -BackupName "WebServer" -AWSRegion "us-east-1" `
  -AWSRoleArn "arn:aws:iam::123456789012:role/VeeamRestoreRole" `
  -AWSExternalId "VeeamDR2026" -DryRun
```

### Advanced Examples

```powershell
# Ransomware recovery with network isolation
.\Restore-VRO-AWS-EC2.ps1 -BackupName "DC-Backup" -UseLatestCleanPoint `
  -AWSRegion "us-west-2" -IsolateNetwork -CleanupOnFailure `
  -HealthCheckPorts @(3389) -RTOTargetMinutes 60

# DR drill with compliance audit
.\Restore-VRO-AWS-EC2.ps1 -BackupName "SAP-Production" -VMName "SAP-APP01" `
  -AWSRegion "eu-west-1" -DRDrillMode -DRDrillKeepMinutes 15 `
  -EnableAuditTrail -HealthCheckPorts @(443, 1433) -RTOTargetMinutes 120

# Full enterprise restore with DNS, CloudWatch, and SSM
.\Restore-VRO-AWS-EC2.ps1 -BackupName "WebServer" -AWSRegion "us-east-1" `
  -VPCId "vpc-abc123" -SubnetId "subnet-def456" `
  -InstanceType "m5.xlarge" -EncryptVolumes `
  -HealthCheckPorts @(80, 443) -HealthCheckUrls @("http://localhost/health") `
  -Route53HostedZoneId "Z1234567" -Route53RecordName "app.dr.example.com" `
  -CreateCloudWatchAlarms -CloudWatchSNSTopicArn "arn:aws:sns:us-east-1:123456789012:DR-Alerts" `
  -PostRestoreSSMDocument "AWS-RunPowerShellScript" `
  -PostRestoreSSMParameters @{ commands = @("Set-Service -Name 'AppService' -StartupType Automatic") } `
  -RTOTargetMinutes 90 -EnableAuditTrail
```

## Parameters

### VBR Server Connection
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VBRServer` | String | `localhost` | VBR server hostname or IP |
| `-VBRCredential` | PSCredential | | Credential for VBR auth |
| `-VBRPort` | Int | `9392` | VBR server port |

### Backup Selection
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-BackupName` | String | **(required)** | Backup job name |
| `-VMName` | String | | Specific VM within a multi-VM backup |
| `-RestorePointId` | String | | Specific restore point ID (omit for latest) |
| `-UseLatestCleanPoint` | Switch | | Find most recent malware-free point |

### AWS Authentication
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-AWSRegion` | String | **(required)** | Target AWS region (e.g., `us-east-1`) |
| `-AWSAccountName` | String | | VBR AWS account name |
| `-AWSProfile` | String | | AWS CLI named profile |
| `-AWSRoleArn` | String | | IAM Role ARN for STS AssumeRole |
| `-AWSExternalId` | String | | External ID for STS AssumeRole |
| `-AWSSessionDuration` | Int | `3600` | STS session duration in seconds |
| `-EnableCredentialRefresh` | Switch | | Auto-refresh STS creds during long restores |

### EC2 Target Configuration
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VPCId` | String | | Target VPC ID (auto-selects default VPC) |
| `-SubnetId` | String | | Target subnet ID |
| `-SecurityGroupIds` | String[] | | Security group IDs |
| `-InstanceType` | String | `t3.medium` | EC2 instance type (validated per AZ) |
| `-KeyPairName` | String | | EC2 key pair for SSH access |

### Restore Options
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-RestoreMode` | String | `FullRestore` | `FullRestore` (InstantRestore not yet supported) |
| `-EC2InstanceName` | String | `Restored-<VM>-<timestamp>` | Name tag for restored instance |
| `-Tags` | Hashtable | `@{}` | Additional tags (AWS 50-tag limit enforced) |
| `-DiskType` | String | `gp3` | EBS volume type |
| `-EncryptVolumes` | Switch | | Encrypt EBS volumes with KMS |
| `-KMSKeyId` | String | | KMS key for encryption |
| `-PowerOnAfterRestore` | Bool | `$true` | Start instance after restore |

### Network Isolation
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-IsolateNetwork` | Switch | | Create isolated SG blocking all traffic |
| `-IsolatedSGName` | String | `VeeamIsolated-<timestamp>` | Custom name for isolated SG |

### Validation & Health Checks
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SkipValidation` | Switch | | Skip all post-restore checks |
| `-ValidationTimeoutMinutes` | Int | `15` | Max wait for validation |
| `-HealthCheckPorts` | Int[] | | TCP ports to verify (e.g., `22, 443, 3389`) |
| `-HealthCheckUrls` | String[] | | HTTP endpoints to verify |
| `-SSMHealthCheckCommand` | String | | SSM command to run inside the VM |

### SLA/RTO Tracking
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-RTOTargetMinutes` | Int | | Target RTO in minutes (tracked in report) |

### VRO Integration
| Parameter | Type | Description |
|-----------|------|-------------|
| `-VROPlanName` | String | VRO recovery plan name |
| `-VROStepName` | String | VRO plan step name |
| `-DryRun` | Switch | Validate without executing |

### Rollback & DR Drill
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-CleanupOnFailure` | Switch | | Terminate resources on failure |
| `-DRDrillMode` | Switch | | Full drill: restore, validate, auto-terminate |
| `-DRDrillKeepMinutes` | Int | `30` | Keep-alive duration in drill mode |

### CloudWatch & Route53
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-CreateCloudWatchAlarms` | Switch | | Create CPU/status check alarms |
| `-CloudWatchSNSTopicArn` | String | | SNS topic for alarm notifications |
| `-Route53HostedZoneId` | String | | Route53 zone for DNS update |
| `-Route53RecordName` | String | | DNS record to create/update |
| `-Route53RecordType` | String | `A` | `A` or `CNAME` |

### SSM Post-Restore Scripts
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-PostRestoreSSMDocument` | String | | SSM document to execute post-restore |
| `-PostRestoreSSMParameters` | Hashtable | `@{}` | Parameters for the SSM document |

### Compliance
| Parameter | Type | Description |
|-----------|------|-------------|
| `-EnableAuditTrail` | Switch | Write JSONL audit event log |

## Outputs

Each run creates a timestamped folder with:

| File | Description |
|------|-------------|
| `Restore-Log-*.txt` | Execution log with timestamps and levels |
| `Restore-Report-*.html` | HTML report with SLA/RTO and health check results |
| `Restore-Result-*.json` | Machine-readable result with instance details |
| `Restore-AuditTrail-*.jsonl` | Compliance audit trail (when `-EnableAuditTrail` is set) |

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Restore completed successfully |
| `1` | Restore failed |

## AWS Security Model

Authentication follows IAM best practices in priority order:
1. **STS AssumeRole** — Cross-account or elevated privileges via `-AWSRoleArn`
2. **Named Profile** — AWS CLI profile via `-AWSProfile`
3. **Default credential chain** — IAM Instance Profile or environment variables (auto-detected)

No plaintext credentials are accepted. STS sessions are automatically refreshed when `-EnableCredentialRefresh` is set.

## Resource Tagging

All restored resources (EC2 instance, EBS volumes, network interfaces) are automatically tagged with:
- `veeam:restore-source`, `veeam:restore-point`, `veeam:restore-timestamp`
- `veeam:vro-plan`, `veeam:vro-step`, `veeam:restore-mode`
- `ManagedBy: VeeamVRO`
- Any additional tags provided via the `-Tags` parameter

AWS 50-tag limit is enforced. Standard tags are preserved; user tags are truncated if the limit is exceeded.

## Testing

```powershell
# Install Pester 5.x
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser

# Run all tests
Invoke-Pester ./Restore-VRO-AWS-EC2.Tests.ps1 -Output Detailed

# Run with code coverage
Invoke-Pester ./Restore-VRO-AWS-EC2.Tests.ps1 -CodeCoverage ./Restore-VRO-AWS-EC2.ps1
```
