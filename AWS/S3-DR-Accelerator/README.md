# Veeam S3 DR Accelerator

PowerShell tool that builds complete AWS infrastructure scaffolding in a fresh account so Veeam Backup & Replication can securely restore workloads from S3-based backup repositories.

## The Problem

Veeam customers store offsite backups in S3 (Veeam Vault, customer-managed S3, or S3-compatible storage), but when disaster strikes they discover the DR account has **nothing**: no VPC, no IAM roles, no encryption keys, no audit trail. Standing this up manually under pressure takes hours and is error-prone.

Customers without AWS Control Tower or landing zone automation are especially exposed.

## What This Solves

Run one command and get a production-ready DR environment in minutes:

- **Networking** - VPC, public/private subnets (2 AZs), Internet Gateway, NAT Gateway, route tables
- **S3 Access** - Gateway VPC Endpoint for zero-egress-cost, private access to backup bucket
- **IAM** - Least-privilege roles for Veeam restore operations (S3 read, EC2 create, KMS encrypt)
- **Cross-Account Access** - IAM role trust + setup script when backups are in a different account
- **Encryption** - KMS key for restored EBS volumes and snapshots
- **Audit** - CloudTrail logging for all DR operations
- **Security Groups** - Pre-configured for VBR server, proxies, and restored workloads
- **VBR Server** - Optional Windows Server EC2 instance with bootstrap script
- **Readiness Report** - Professional HTML report with validation checks and architecture diagram

## Quick Start

### Plan (dry-run, no changes)
```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Plan `
  -BackupBucketName "my-veeam-backups" `
  -BackupBucketRegion "us-east-1"
```

### Deploy
```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy `
  -BackupBucketName "my-veeam-backups" `
  -BackupBucketRegion "us-east-1" `
  -TargetRegion "us-west-2"
```

### Validate existing environment
```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Validate `
  -BackupBucketName "my-veeam-backups" `
  -BackupBucketRegion "us-east-1"
```

### Teardown (post-testing cleanup)
```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Teardown `
  -EnvironmentTag "VeeamDR" `
  -TargetRegion "us-west-2"
```

## Supported Scenarios

### 1. Same-Account Restore
Backup bucket and DR environment are in the same AWS account. Simplest configuration.

```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy `
  -BackupBucketName "my-veeam-backups" `
  -BackupBucketRegion "us-east-1"
```

### 2. Cross-Account Restore
Backup bucket is in the production account; restoring into a separate DR account. The script creates IAM trust policies and generates a setup script that the source account admin must run.

```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy `
  -BackupBucketName "prod-backups" `
  -BackupBucketRegion "us-east-1" `
  -BackupAccountId "123456789012" `
  -TargetRegion "us-west-2"
```

### 3. Veeam Vault / External S3
Backups are in Veeam Vault or non-AWS S3-compatible storage. IAM roles are still created for EC2 restore operations; S3 access uses credentials configured in VBR.

```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy `
  -BackupBucketName "vault-bucket" `
  -BackupBucketRegion "us-east-1" `
  -ExternalS3Endpoint "https://s3.veeam.com"
```

### 4. Full Deployment with VBR Server
Deploys everything including a Windows Server EC2 instance pre-configured for Veeam B&R installation.

```powershell
.\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy `
  -BackupBucketName "my-backups" `
  -BackupBucketRegion "us-east-1" `
  -DeployVbrServer `
  -KeyPairName "my-key-pair" `
  -VbrInstanceType "m5.xlarge" `
  -AllowedRdpCidr "203.0.113.0/24"
```

## Parameters

### Required
| Parameter | Description |
|-----------|-------------|
| `-Mode` | `Plan`, `Deploy`, `Validate`, or `Teardown` |
| `-BackupBucketName` | S3 bucket containing Veeam backups (required for Plan/Deploy/Validate) |
| `-BackupBucketRegion` | AWS region of the backup bucket (required for Plan/Deploy/Validate) |

### Networking
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-TargetRegion` | Same as backup region | AWS region for DR infrastructure |
| `-VpcCidr` | `10.200.0.0/16` | CIDR block for the DR VPC |
| `-SkipVpcCreation` | false | Use an existing VPC instead of creating one |
| `-ExistingVpcId` | — | VPC ID when using `-SkipVpcCreation` |
| `-ExistingSubnetId` | — | Subnet ID for Veeam component placement |

### Access
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-BackupAccountId` | — | Source account ID for cross-account scenarios |
| `-ExternalS3Endpoint` | — | Custom S3-compatible endpoint URL |

### Security
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-EnvironmentTag` | `VeeamDR` | Tag applied to all resources |
| `-EnableCloudTrail` | `$true` | Enable CloudTrail audit logging |
| `-AllowedRdpCidr` | `0.0.0.0/0` | CIDR block for RDP access (**restrict in production**) |

### VBR Server
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-DeployVbrServer` | false | Deploy a Windows Server EC2 instance |
| `-VbrInstanceType` | `t3.xlarge` | EC2 instance type (`t3.large` through `r5.2xlarge`) |
| `-KeyPairName` | — | EC2 key pair for RDP access |

### Output
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-OutputPath` | Auto-generated with timestamp | Output folder for reports and logs |

## Modes

### Plan
Dry-run that shows exactly what would be created, estimated monthly costs, and the current state of the target environment. Makes **no changes** to AWS.

### Deploy
Creates all infrastructure resources. Idempotent for IAM resources (skips if they already exist). Runs validation after deployment and generates a readiness report.

### Validate
Checks an existing DR environment against all readiness criteria:
- VPC, subnets, gateways, S3 endpoint exist and are configured
- IAM roles and policies are in place
- S3 backup bucket is accessible and readable
- KMS encryption key is enabled
- CloudTrail is logging
- Security groups are configured

### Teardown
Removes all infrastructure tagged with the specified `EnvironmentTag`. Requires interactive confirmation (type `TEARDOWN`). Handles dependency ordering (instances before VPC, etc.). KMS keys are scheduled for deletion with a 7-day safety window.

## Output Files

| File | Description |
|------|-------------|
| `VeeamS3DR-Readiness-Report.html` | Professional HTML report with validation results, resource inventory, architecture diagram, and next steps |
| `created_resources.csv` | All provisioned AWS resources with IDs, names, and details |
| `validation_results.csv` | All validation checks with pass/fail/warn status |
| `execution_log.csv` | Timestamped log of all operations |
| `cross_account_setup.ps1` | (Cross-account only) Script for source account admin to run |

## Architecture

```
  DR Account                              Backup Account (optional)
 +-----------------------------------------------+    +---------------------------+
 |  VPC: 10.200.0.0/16                           |    |                           |
 |                                                |    |  S3: my-veeam-backups     |
 |  +-------------------+  +-------------------+  |    |  (Veeam Backup Data)      |
 |  | Public Subnet AZ1 |  | Public Subnet AZ2 |  |    |                           |
 |  |  - VBR Server     |  |  (standby)        |  |    +---------------------------+
 |  |  - NAT Gateway    |  |                   |  |
 |  +-------------------+  +-------------------+  |         Cross-Account
 |                                                |    <--- IAM Role Trust --->
 |  +-------------------+  +-------------------+  |
 |  | Private Subnet AZ1|  | Private Subnet AZ2|  |
 |  |  - Restored VMs   |  |  - Restored VMs   |  |
 |  |  - Veeam Proxies  |  |  - Veeam Proxies  |  |
 |  +-------------------+  +-------------------+  |
 |                                                |
 |  [S3 VPC Endpoint] --- zero-cost S3 access     |
 |  [KMS Key] --- encrypted volumes/snapshots     |
 |  [CloudTrail] --- audit logging                |
 +-----------------------------------------------+
```

## Security Design

### Least-Privilege IAM
- VBR server role has **read-only** access to the backup bucket (no write/delete)
- EC2 operations are restricted to the target region via IAM conditions
- KMS operations scoped to keys tagged with the environment tag
- No wildcard `*` on S3 actions

### Network Isolation
- Restored workloads in **private subnets** (no direct internet exposure)
- VBR server in public subnet with restricted security group rules
- S3 access via VPC Gateway Endpoint (never traverses public internet)
- Separate security groups for VBR server, proxies, and workloads

### Encryption
- Dedicated KMS key for all restored EBS volumes and snapshots
- VBR server boot and data volumes encrypted at rest
- CloudTrail log bucket blocks all public access

### Audit
- CloudTrail captures all API calls in the DR account
- Log file validation enabled (tamper detection)
- All resources tagged with `Environment` and `ManagedBy` for tracking

## Prerequisites

- **PowerShell** 7.x (recommended) or 5.1
- **AWS PowerShell Modules:**
  ```powershell
  Install-Module AWS.Tools.Installer -Scope CurrentUser
  Install-AWSToolsModule AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.S3, `
    AWS.Tools.IdentityManagement, AWS.Tools.SecurityToken, `
    AWS.Tools.KeyManagementService, AWS.Tools.CloudTrail -Scope CurrentUser
  ```
- **AWS Credentials** configured for the DR target account:
  ```powershell
  # Option 1: AWS CLI profile
  Set-AWSCredential -ProfileName dr-account

  # Option 2: SSO
  aws sso login --profile dr-account
  Set-AWSCredential -ProfileName dr-account

  # Option 3: Environment variables
  $env:AWS_ACCESS_KEY_ID = "AKIA..."
  $env:AWS_SECRET_ACCESS_KEY = "..."
  ```

### Required IAM Permissions (for the user/role running this script)
The identity running this script needs broad permissions to create infrastructure:
- `ec2:*` (VPC, subnets, gateways, security groups, instances)
- `iam:*` (roles, policies, instance profiles)
- `kms:*` (key creation, alias management)
- `cloudtrail:*` (trail creation)
- `s3:*` (bucket creation for CloudTrail, bucket access validation)
- `sts:GetCallerIdentity`

For production use, scope these down to only the specific actions needed.

## DR Testing Workflow

1. **Prepare** - Run with `-Mode Plan` to review what will be created
2. **Deploy** - Run with `-Mode Deploy` to build the DR environment
3. **Install VBR** - RDP to the VBR server, install Veeam Backup & Replication
4. **Connect Repository** - Add the S3 backup bucket as an object storage repository in VBR
5. **Import Backups** - Rescan the repository to discover backup chains
6. **Restore** - Perform test restores of critical workloads
7. **Validate** - Verify application functionality and data integrity
8. **Document** - Save the HTML readiness report for compliance
9. **Cleanup** - Run with `-Mode Teardown` to remove all DR infrastructure
10. **Repeat** - Schedule regular DR tests (quarterly recommended)

## Estimated Costs

Approximate monthly costs for a deployed DR environment (us-east-1):

| Resource | Cost |
|----------|------|
| NAT Gateway | ~$32/mo + data processing |
| Elastic IP | ~$3.65/mo |
| EC2 (t3.xlarge) | ~$120/mo (only if VBR server deployed) |
| EBS Storage (300 GB gp3) | ~$24/mo (only if VBR server deployed) |
| KMS Key | ~$1/mo |
| CloudTrail | ~$2/mo |
| S3 VPC Endpoint | Free |
| **Infrastructure only** | **~$39/mo** |
| **With VBR server** | **~$183/mo** |

Use `-Mode Teardown` after testing to avoid ongoing charges.

## Troubleshooting

### "Missing required AWS PowerShell modules"
Install the required modules:
```powershell
Install-Module AWS.Tools.Installer -Scope CurrentUser
Install-AWSToolsModule AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.S3, `
  AWS.Tools.IdentityManagement, AWS.Tools.SecurityToken, `
  AWS.Tools.KeyManagementService, AWS.Tools.CloudTrail -Scope CurrentUser
```

### "No valid AWS credentials found"
Configure credentials for the DR target account before running the script. See Prerequisites above.

### "Access Denied" on backup bucket
- **Same account:** Ensure the IAM user/role has `s3:ListBucket` and `s3:GetObject` on the bucket
- **Cross account:** Run the generated `cross_account_setup.ps1` in the source account
- **Veeam Vault:** Verify the S3-compatible credentials in VBR console

### NAT Gateway stuck in "pending"
NAT Gateways can take up to 5 minutes to provision. The script waits up to 2 minutes and continues. Check the AWS console if it doesn't become available.

### Teardown fails on VPC deletion
VPC deletion requires all dependencies removed first. If teardown fails:
1. Check for manually-created resources in the VPC
2. Remove ENIs, load balancers, or other resources not managed by this script
3. Re-run teardown or delete the VPC manually

### Cross-account role not working
Ensure the source account admin has:
1. Created the IAM role with the exact trust policy from `cross_account_setup.ps1`
2. Attached the S3 read policy to that role
3. The role name matches: `{EnvironmentTag}-BackupBucketAccess`

## FAQ

**Q: Can I use this with Veeam Vault?**
A: Yes. Use the `-ExternalS3Endpoint` parameter. The script still creates all the AWS infrastructure needed for restore. S3 authentication is handled through VBR's credential management.

**Q: Do I need to keep the DR environment running?**
A: No. Use `-Mode Teardown` after testing. When you need it again, re-deploy with `-Mode Deploy`. The entire process takes minutes.

**Q: Can I customize the VPC CIDR?**
A: Yes. Use `-VpcCidr "172.16.0.0/16"` or any valid CIDR. Subnets are automatically calculated.

**Q: What Veeam license do I need?**
A: Veeam Backup & Replication with an active support contract. For S3 object storage repository support, Veeam Universal License (VUL) is recommended.

**Q: Can I run this for multiple environments?**
A: Yes. Use different `-EnvironmentTag` values (e.g., `VeeamDR-Prod`, `VeeamDR-Dev`). Each tag creates isolated resources.

---

**&copy; 2026 Veeam Software**
