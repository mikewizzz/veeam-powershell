# Restore-VRO-AWS-EC2 - VRO Plan Step: Restore Veeam Backups to Amazon EC2

PowerShell script that bridges Veeam Recovery Orchestrator (VRO) and AWS by enabling automated restore of Veeam backups stored in S3 (direct repository or SOBR capacity tier) to Amazon EC2 instances.

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

## Prerequisites

- PowerShell 5.1+ (7.x recommended)
- `Veeam.Backup.PowerShell` module (VBR 12+, 12.1+ recommended)
- AWS PowerShell modules:
  - `AWS.Tools.Common`
  - `AWS.Tools.EC2`
  - `AWS.Tools.SecurityToken` (for STS AssumeRole)
  - `AWS.Tools.S3` (optional, for backup validation)
- VRO Compatibility: Veeam Recovery Orchestrator 7.0+

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

### EC2 Target Configuration
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-VPCId` | String | | Target VPC ID (auto-selects default VPC) |
| `-SubnetId` | String | | Target subnet ID |
| `-SecurityGroupIds` | String[] | | Security group IDs |
| `-InstanceType` | String | `t3.medium` | EC2 instance type |
| `-KeyPairName` | String | | EC2 key pair for SSH access |

### Restore Options
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-RestoreMode` | String | `FullRestore` | `FullRestore` or `InstantRestore` |
| `-EC2InstanceName` | String | `Restored-<VM>-<timestamp>` | Name tag for restored instance |
| `-Tags` | Hashtable | `@{}` | Additional tags for restored resources |
| `-DiskType` | String | `gp3` | EBS volume type |
| `-EncryptVolumes` | Switch | | Encrypt EBS volumes with KMS |
| `-KMSKeyId` | String | | KMS key for encryption |
| `-PowerOnAfterRestore` | Bool | `$true` | Start instance after restore |

### Validation
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-SkipValidation` | Switch | | Skip post-restore health checks |
| `-ValidationTimeoutMinutes` | Int | `15` | Max wait for validation |
| `-RestoreTimeoutMinutes` | Int | `120` | Max wait for restore completion |

### VRO Integration
| Parameter | Type | Description |
|-----------|------|-------------|
| `-VROPlanName` | String | VRO recovery plan name |
| `-VROStepName` | String | VRO plan step name |
| `-DryRun` | Switch | Validate without executing |

## Outputs

Each run creates a timestamped folder with:

| File | Description |
|------|-------------|
| `Restore-Log-*.txt` | Execution log |
| `Restore-Report-*.html` | Professional HTML restore report |
| `Restore-Result-*.json` | Machine-readable result with instance details |

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

No plaintext credentials are accepted.

## Resource Tagging

All restored resources (EC2 instance, EBS volumes, network interfaces) are automatically tagged with:
- `veeam:restore-source`, `veeam:restore-point`, `veeam:restore-timestamp`
- `veeam:vro-plan`, `veeam:vro-step`, `veeam:restore-mode`
- `ManagedBy: VeeamVRO`
- Any additional tags provided via the `-Tags` parameter
