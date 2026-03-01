<#
.SYNOPSIS
  VRO Plan Step: Restore Veeam Backups from AWS S3 to Amazon EC2

.DESCRIPTION
  Bridges the gap between Veeam Recovery Orchestrator (VRO) and AWS by enabling
  automated restore of Veeam backups stored in S3 (direct repository or SOBR
  capacity tier) to Amazon EC2 instances.

  WHAT THIS SCRIPT DOES:
  1. Connects to Veeam Backup & Replication server
  2. Authenticates to AWS using IAM best practices (roles, profiles, STS)
  3. Locates the backup and selects the appropriate restore point
  4. Optionally validates restore point is clean (malware-free) via Secure Restore
  5. Optionally creates network isolation (clean room) for ransomware recovery
  6. Executes Veeam "Restore to Amazon EC2" with full EC2 configuration
  7. Monitors restore progress with timeout enforcement and credential refresh
  8. Validates the restored EC2 instance via OS checks, TCP ports, HTTP, and SSM
  9. Tags all restored AWS resources for governance and cost tracking
  10. Optionally creates CloudWatch alarms and updates Route53 DNS records
  11. Optionally runs SSM post-restore configuration scripts
  12. Tracks SLA/RTO compliance and generates compliance audit trails
  13. Supports DR drill mode with auto-terminate for recovery testing
  14. Generates structured output for VRO plan step consumption
  15. Produces professional HTML restore report with health check results

  VRO INTEGRATION:
  - Designed as a VRO Plan Step (Custom Script)
  - Returns exit code 0 on success, 1 on failure
  - Outputs structured JSON to stdout for VRO variable capture
  - Supports VRO parameter pass-through for dynamic orchestration
  - Compatible with VRO pre/post step scripts

  SUPPORTED BACKUP SOURCES:
  - S3 Direct Repository (Veeam S3 Object Storage Repository)
  - SOBR with S3 Capacity Tier (Scale-Out Backup Repository)
  - Veeam Backup for AWS (VBA) snapshots tiered to S3

  AWS SECURITY MODEL:
  - IAM Instance Profile (recommended for VBR on EC2)
  - STS AssumeRole for cross-account restore
  - AWS CLI Named Profiles
  - Environment variables (CI/CD pipelines)
  - No plaintext credentials accepted

  PERFORMANCE OPTIMIZATIONS:
  - Parallel AWS resource discovery via runspaces
  - Connection reuse across Veeam and AWS sessions
  - Streaming progress with minimal API polling overhead
  - Regional S3 endpoint selection for lowest latency
  - gp3 default disk type (3x throughput vs gp2 at same cost)

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP. Default: localhost.

.PARAMETER VBRCredential
  PSCredential for VBR authentication. Omit to use integrated Windows auth.

.PARAMETER VBRPort
  VBR server connection port. Default: 9392.

.PARAMETER BackupName
  Name of the Veeam backup job or imported backup to restore from.

.PARAMETER VMName
  Specific VM name within the backup to restore. Required for multi-VM backups.

.PARAMETER RestorePointId
  Specific restore point ID. Omit to use the latest (or latest clean) point.

.PARAMETER UseLatestCleanPoint
  Find and use the most recent malware-free restore point via Secure Restore.
  Requires Veeam B&R 12+ with antivirus integration configured.

.PARAMETER AWSAccountName
  Name of the AWS account configured in VBR. If omitted, uses the first available.

.PARAMETER AWSRegion
  Target AWS region for the restored EC2 instance (e.g., us-east-1, eu-west-1).

.PARAMETER AWSProfile
  AWS CLI named profile for authentication. Mutually exclusive with AWSRoleArn.

.PARAMETER AWSRoleArn
  IAM Role ARN for STS AssumeRole (cross-account or elevated privileges).

.PARAMETER AWSExternalId
  External ID for STS AssumeRole (required by some trust policies).

.PARAMETER AWSSessionDuration
  STS session duration in seconds. Default: 3600 (1 hour). Max: 43200 (12 hours).

.PARAMETER VPCId
  Target VPC ID. If omitted, uses the default VPC in the target region.

.PARAMETER SubnetId
  Target subnet ID. If omitted, uses the first available subnet in the VPC.

.PARAMETER SecurityGroupIds
  One or more security group IDs. If omitted, uses the VPC default security group.

.PARAMETER InstanceType
  EC2 instance type. Default: t3.medium. Validated against available types in region.

.PARAMETER KeyPairName
  EC2 key pair name for SSH access. Omit if not needed (Windows RDP uses password).

.PARAMETER RestoreMode
  FullRestore: Complete disk-level restore (default, most reliable).
  InstantRestore: Instant VM Recovery to EC2 (requires VBR 12+ with direct S3 support).

.PARAMETER EC2InstanceName
  Name tag for the restored EC2 instance. Default: Restored-<VMName>-<timestamp>.

.PARAMETER Tags
  Hashtable of additional tags to apply to all restored resources.
  Example: @{ "Environment"="DR"; "CostCenter"="IT-Recovery" }

.PARAMETER DiskType
  EBS volume type for restored disks. Default: gp3 (best price-performance).

.PARAMETER EncryptVolumes
  Encrypt all restored EBS volumes using AWS KMS.

.PARAMETER KMSKeyId
  KMS key ID or ARN for volume encryption. Omit to use the AWS-managed default key.

.PARAMETER PowerOnAfterRestore
  Start the EC2 instance after restore completes. Default: true.

.PARAMETER AssociatePublicIP
  Associate a public IP with the restored instance. Default: false (security best practice).

.PARAMETER PrivateIPAddress
  Specific private IP to assign. Omit for automatic assignment from subnet CIDR.

.PARAMETER IsolateNetwork
  Create an isolated security group blocking all inbound/outbound traffic.
  For ransomware recovery scenarios - prevents lateral movement from restored instance.

.PARAMETER IsolatedSGName
  Name for the isolated security group. Default: VeeamIsolated-<timestamp>.

.PARAMETER SkipValidation
  Skip post-restore health checks. Use only for speed-critical DR scenarios.

.PARAMETER ValidationTimeoutMinutes
  Maximum time to wait for post-restore validation. Default: 15 minutes.

.PARAMETER HealthCheckPorts
  TCP ports to verify post-restore (e.g., 22, 80, 443, 3389).

.PARAMETER HealthCheckUrls
  HTTP/HTTPS endpoints to verify (e.g., http://localhost/health).

.PARAMETER SSMHealthCheckCommand
  AWS SSM RunCommand to execute inside the VM for application-level verification.

.PARAMETER RTOTargetMinutes
  Target Recovery Time Objective in minutes. Tracks actual vs planned in report.

.PARAMETER VROPlanName
  VRO recovery plan name (passed by VRO for logging context).

.PARAMETER VROStepName
  VRO plan step name (passed by VRO for logging context).

.PARAMETER DryRun
  Validate all parameters and connectivity without executing the restore.

.PARAMETER CleanupOnFailure
  Terminate restored EC2 instance and delete created resources if restore fails.

.PARAMETER DRDrillMode
  Full DR drill: restore, validate, keep alive, then auto-terminate with compliance report.

.PARAMETER DRDrillKeepMinutes
  How long to keep the restored instance alive in DR drill mode. Default: 30 minutes.

.PARAMETER EnableCredentialRefresh
  Automatically refresh STS credentials before expiration during long restores.

.PARAMETER CreateCloudWatchAlarms
  Create CPU and status check CloudWatch alarms on the restored instance.

.PARAMETER CloudWatchSNSTopicArn
  SNS topic ARN for CloudWatch alarm notifications.

.PARAMETER Route53HostedZoneId
  Route53 hosted zone ID for DNS record update after successful restore.

.PARAMETER Route53RecordName
  DNS record name to create/update (e.g., app.dr.example.com).

.PARAMETER Route53RecordType
  DNS record type: A or CNAME. Default: A.

.PARAMETER PostRestoreSSMDocument
  SSM document name or ARN to execute on the restored instance after validation.

.PARAMETER PostRestoreSSMParameters
  Parameters hashtable for the SSM document.

.PARAMETER EnableAuditTrail
  Write a detailed JSON event log for compliance auditing.

.PARAMETER OutputPath
  Output folder for logs and reports. Default: ./VRORestoreOutput_<timestamp>.

.PARAMETER GenerateReport
  Generate an HTML restore report. Default: true.

.PARAMETER RestoreTimeoutMinutes
  Maximum time to wait for restore completion. Default: 120 minutes.

.PARAMETER MaxRetries
  Maximum retry attempts for transient failures. Default: 3.

.PARAMETER RetryBaseDelaySeconds
  Base delay for exponential backoff retries. Default: 2 seconds.

.EXAMPLE
  .\Restore-VRO-AWS-EC2.ps1 -BackupName "Daily-FileServer" -AWSRegion "us-east-1"
  # Restore latest point to EC2 using defaults (VBR localhost, default VPC, t3.medium)

.EXAMPLE
  .\Restore-VRO-AWS-EC2.ps1 -BackupName "SAP-Production" -VMName "SAP-APP01" `
    -AWSRegion "eu-west-1" -VPCId "vpc-0abc123" -SubnetId "subnet-0def456" `
    -SecurityGroupIds "sg-0ghi789" -InstanceType "r5.xlarge" -EncryptVolumes `
    -Tags @{ "Environment"="DR"; "Application"="SAP" }
  # Production DR restore with specific networking and encryption

.EXAMPLE
  .\Restore-VRO-AWS-EC2.ps1 -BackupName "DC-Backup" -UseLatestCleanPoint `
    -AWSRegion "us-west-2" -InstanceType "m5.large" -KeyPairName "dr-keypair"
  # Ransomware recovery: find latest clean restore point, restore to EC2

.EXAMPLE
  .\Restore-VRO-AWS-EC2.ps1 -BackupName "WebServer" -AWSRegion "us-east-1" `
    -AWSRoleArn "arn:aws:iam::123456789012:role/VeeamRestoreRole" `
    -AWSExternalId "VeeamDR2026" -DryRun
  # Cross-account dry run with STS AssumeRole

.NOTES
  Version: 2.1.0
  Author: Community Contributors
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: Veeam.Backup.PowerShell (VBR 12+), AWS.Tools.Common, AWS.Tools.EC2
  VRO Compatibility: Veeam Recovery Orchestrator 7.0+
  VBR Compatibility: Veeam Backup & Replication 12.0+ (12.1+ recommended)
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  # ===== VBR Server Connection =====
  [string]$VBRServer = "localhost",
  [PSCredential]$VBRCredential,
  [ValidateRange(1,65535)]
  [int]$VBRPort = 9392,

  # ===== Backup Selection =====
  [Parameter(Mandatory)]
  [string]$BackupName,
  [string]$VMName,
  [string]$RestorePointId,
  [switch]$UseLatestCleanPoint,

  # ===== AWS Account & Auth =====
  [string]$AWSAccountName,
  [Parameter(Mandatory)]
  [ValidatePattern('^[a-z]{2}(-gov)?-(north|south|east|west|central|northeast|southeast|northwest|southwest)-\d$')]
  [string]$AWSRegion,
  [string]$AWSProfile,
  [ValidatePattern('^arn:aws(-cn|-us-gov)?:iam::\d{12}:role/.+$')]
  [string]$AWSRoleArn,
  [string]$AWSExternalId,
  [ValidateRange(900,43200)]
  [int]$AWSSessionDuration = 3600,

  # ===== EC2 Target Configuration =====
  [ValidatePattern('^vpc-[a-f0-9]+$')]
  [string]$VPCId,
  [ValidatePattern('^subnet-[a-f0-9]+$')]
  [string]$SubnetId,
  [ValidateScript({ $_ | ForEach-Object { $_ -match '^sg-[a-f0-9]+$' } })]
  [string[]]$SecurityGroupIds,
  [ValidatePattern('^\w+\.\w+$')]
  [string]$InstanceType = "t3.medium",
  [string]$KeyPairName,

  # ===== Restore Options =====
  [ValidateSet("FullRestore","InstantRestore")]
  [string]$RestoreMode = "FullRestore",
  [string]$EC2InstanceName,
  [hashtable]$Tags = @{},
  [ValidateSet("gp3","gp2","io1","io2","st1","sc1")]
  [string]$DiskType = "gp3",
  [switch]$EncryptVolumes,
  [string]$KMSKeyId,
  [bool]$PowerOnAfterRestore = $true,

  # ===== Network =====
  [switch]$AssociatePublicIP,
  [ValidatePattern('^(\d{1,3}\.){3}\d{1,3}$')]
  [string]$PrivateIPAddress,

  # ===== Network Isolation (Clean Room Recovery) =====
  [switch]$IsolateNetwork,
  [string]$IsolatedSGName,

  # ===== Validation =====
  [switch]$SkipValidation,
  [ValidateRange(1,120)]
  [int]$ValidationTimeoutMinutes = 15,

  # ===== Application Health Checks =====
  [int[]]$HealthCheckPorts,
  [string[]]$HealthCheckUrls,
  [string]$SSMHealthCheckCommand,

  # ===== SLA/RTO Tracking =====
  [ValidateRange(1,1440)]
  [int]$RTOTargetMinutes,

  # ===== VRO Integration =====
  [string]$VROPlanName,
  [string]$VROStepName,
  [switch]$DryRun,

  # ===== Rollback & Cleanup =====
  [switch]$CleanupOnFailure,

  # ===== DR Drill Mode =====
  [switch]$DRDrillMode,
  [ValidateRange(1,480)]
  [int]$DRDrillKeepMinutes = 30,

  # ===== Credential Management =====
  [switch]$EnableCredentialRefresh,

  # ===== CloudWatch Integration =====
  [switch]$CreateCloudWatchAlarms,
  [string]$CloudWatchSNSTopicArn,

  # ===== Route53 DNS Failover =====
  [string]$Route53HostedZoneId,
  [string]$Route53RecordName,
  [ValidateSet("A","CNAME")]
  [string]$Route53RecordType = "A",

  # ===== SSM Post-Restore Scripts =====
  [string]$PostRestoreSSMDocument,
  [hashtable]$PostRestoreSSMParameters = @{},

  # ===== Compliance Audit Trail =====
  [switch]$EnableAuditTrail,

  # ===== Output & Logging =====
  [string]$OutputPath,
  [bool]$GenerateReport = $true,

  # ===== Timeouts & Retries =====
  [ValidateRange(10,720)]
  [int]$RestoreTimeoutMinutes = 120,
  [ValidateRange(1,10)]
  [int]$MaxRetries = 3,
  [ValidateRange(1,30)]
  [int]$RetryBaseDelaySeconds = 2
)

# =============================
# Guardrails & Initialization
# =============================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:ExitCode = 0
$script:RestoredInstanceId = $null
$script:VBRConnected = $false
$script:AWSInitialized = $false
$script:CreatedResources = New-Object System.Collections.Generic.List[object]
$script:IsolatedSGId = $null
$script:STSExpiration = $null
$script:STSAssumeParams = $null
$script:HealthCheckResults = @()
$script:AuditTrail = New-Object System.Collections.Generic.List[object]

# Output folder
$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
if (-not $OutputPath) {
  $OutputPath = Join-Path "." "VRORestoreOutput_$stamp"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$logFile = Join-Path $OutputPath "Restore-Log-$stamp.txt"
$reportFile = Join-Path $OutputPath "Restore-Report-$stamp.html"
$jsonFile = Join-Path $OutputPath "Restore-Result-$stamp.json"

# =============================
# Load Library Files
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Logging.ps1",
  "Helpers.ps1",
  "Preflight.ps1",
  "Auth.ps1",
  "Restore.ps1",
  "Validation.ps1",
  "AWSIntegrations.ps1",
  "Reporting.ps1"
)
foreach ($lib in $requiredLibs) {
  $libFile = Join-Path $libPath $lib
  if (-not (Test-Path $libFile)) {
    throw "Required library not found: $libFile. Ensure all files in lib/ are present."
  }
  . $libFile
}

# =============================
# Main Execution
# =============================

# Guard: allow Pester to dot-source functions without triggering execution
if ($MyInvocation.InvocationName -eq '.') { return }

$restorePoint = $null
$ec2Config = $null
$instance = $null
$success = $false
$errorMsg = $null

try {
  Write-Log "========================================="
  Write-Log "VRO AWS EC2 Restore - Starting"
  Write-Log "========================================="
  Write-Log "Backup: $BackupName | Region: $AWSRegion | Mode: $RestoreMode"
  if ($VROPlanName) { Write-Log "VRO Plan: $VROPlanName / Step: $VROStepName" }
  if ($DryRun) { Write-Log "*** DRY RUN MODE - No changes will be made ***" -Level WARNING }

  # Step 1: Prerequisites
  Write-Log "--- Step 1: Prerequisites ---"
  Test-Prerequisites

  # Step 2: Connect to VBR
  Write-Log "--- Step 2: VBR Connection ---"
  Connect-VBRSession

  # Step 3: Connect to AWS
  Write-Log "--- Step 3: AWS Authentication ---"
  Connect-AWSSession

  # Step 4: Find restore point
  Write-Log "--- Step 4: Restore Point Discovery ---"
  $restorePoint = Find-RestorePoint

  # Step 5: Resolve EC2 target
  Write-Log "--- Step 5: EC2 Target Configuration ---"
  $ec2Config = Get-EC2TargetConfig

  # Step 6: Execute restore
  Write-Log "--- Step 6: Restore Execution ---"
  $session = Start-EC2Restore -RestorePoint $restorePoint -EC2Config $ec2Config

  if ($DryRun) {
    $success = $true
    Write-Log "Dry run completed. No restore executed." -Level SUCCESS
  }
  else {
    # Step 7: Monitor restore
    Write-Log "--- Step 7: Restore Monitoring ---"
    $finalSession = Wait-RestoreCompletion -Session $session

    # Step 8: Validate and tag
    Write-Log "--- Step 8: Validation & Tagging ---"
    $instanceName = if ($EC2InstanceName) { $EC2InstanceName } else {
      $vmLabel = if ($VMName) { $VMName } else { $BackupName }
      "Restored-$vmLabel-$stamp"
    }

    $instance = Test-EC2InstanceHealth -InstanceName $instanceName
    Set-EC2ResourceTags -Instance $instance

    # Step 9: CloudWatch Alarms (optional)
    if ($CreateCloudWatchAlarms -and $instance) {
      Write-Log "--- Step 9: CloudWatch Alarms ---"
      New-EC2CloudWatchAlarms -InstanceId $instance.InstanceId
    }

    # Step 10: Route53 DNS Update (optional)
    if ($Route53HostedZoneId -and $Route53RecordName -and $instance) {
      Write-Log "--- Step 10: Route53 DNS Update ---"
      $dnsIP = if ($AssociatePublicIP -and $instance.PublicIpAddress) {
        $instance.PublicIpAddress
      }
      else {
        $instance.PrivateIpAddress
      }
      Update-Route53Record -InstanceIP $dnsIP
    }

    # Step 11: SSM Post-Restore Script (optional)
    if ($PostRestoreSSMDocument -and $instance) {
      Write-Log "--- Step 11: Post-Restore SSM Document ---"
      $ssmResult = Invoke-PostRestoreSSMDocument -InstanceId $instance.InstanceId `
        -DocumentName $PostRestoreSSMDocument -Parameters $PostRestoreSSMParameters
      $ssmLevel = if ($ssmResult.Status -eq "Success") { "SUCCESS" } else { "WARNING" }
      Write-Log "SSM document completed: $($ssmResult.Status)" -Level $ssmLevel
    }

    $success = $true

    # Step 12: DR Drill Lifecycle (optional, runs after success)
    if ($DRDrillMode -and $instance) {
      Write-Log "--- Step 12: DR Drill Lifecycle ---"
      Invoke-DRDrill -Instance $instance -KeepMinutes $DRDrillKeepMinutes
    }
  }
}
catch {
  $errorMsg = $_.Exception.Message
  Write-Log "FATAL: $errorMsg" -Level ERROR
  Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
  $script:ExitCode = 1
  Write-AuditEvent -EventType "RESTORE" -Action "Restore failed" -Details @{ error = $errorMsg }

  # Rollback on failure
  if ($CleanupOnFailure -or $DRDrillMode) {
    Write-Log "CleanupOnFailure enabled - initiating rollback..." -Level WARNING
    try {
      Invoke-RestoreCleanup -InstanceId $script:RestoredInstanceId -IsolatedSecurityGroupId $script:IsolatedSGId
    }
    catch {
      Write-Log "Cleanup failed: $($_.Exception.Message)" -Level ERROR
    }
  }
}
finally {
  $duration = (Get-Date) - $script:StartTime

  # Generate report
  try {
    New-RestoreReport -RestorePoint $restorePoint -EC2Config $ec2Config -Instance $instance `
      -Duration $duration -Success $success -ErrorMessage $errorMsg
  }
  catch {
    Write-Log "Failed to generate report: $_" -Level WARNING
  }

  # RTO compliance measurement
  $rtoResult = if ($RTOTargetMinutes) { Measure-RTOCompliance -ActualDuration $duration } else { $null }

  # Export JSON result (machine-readable for VRO)
  $result = [ordered]@{
    success          = $success
    backupName       = $BackupName
    vmName           = $VMName
    region           = $AWSRegion
    instanceId       = $script:RestoredInstanceId
    instanceType     = $InstanceType
    privateIp        = if ($instance) { $instance.PrivateIpAddress } else { $null }
    publicIp         = if ($instance) { $instance.PublicIpAddress } else { $null }
    restoreMode      = $RestoreMode
    restorePoint     = if ($restorePoint) { $restorePoint.CreationTime.ToString("o") } else { $null }
    durationSeconds  = [int]$duration.TotalSeconds
    dryRun           = [bool]$DryRun
    vroPlan          = $VROPlanName
    vroStep          = $VROStepName
    rtoTargetMinutes = $RTOTargetMinutes
    rtoActualMinutes = if ($rtoResult) { $rtoResult.RTOActual } else { $null }
    rtoMet           = if ($rtoResult) { $rtoResult.Met } else { $null }
    healthChecks     = if ($script:HealthCheckResults.Count -gt 0) {
      $script:HealthCheckResults | ForEach-Object {
        [ordered]@{ test = $_.TestName; passed = $_.Passed; details = $_.Details; duration = $_.Duration }
      }
    } else { $null }
    drDrill          = [bool]$DRDrillMode
    networkIsolated  = [bool]$IsolateNetwork
    error            = $errorMsg
    timestamp        = (Get-Date -Format "o")
  }

  $result | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8

  # Export audit trail
  if ($EnableAuditTrail -and $script:AuditTrail.Count -gt 0) {
    $auditFile = Join-Path $OutputPath "Restore-AuditTrail-$stamp.jsonl"
    $script:AuditTrail | ForEach-Object {
      $_ | ConvertTo-Json -Compress -Depth 5
    } | Set-Content -Path $auditFile -Encoding UTF8
    Write-Log "Audit trail saved: $auditFile ($($script:AuditTrail.Count) events)"
  }

  # Output for VRO capture
  Write-VROOutput -Data @{
    status     = if ($success) { "Success" } else { "Failed" }
    instanceId = if ($script:RestoredInstanceId) { $script:RestoredInstanceId } else { "" }
    privateIp  = if ($instance) { $instance.PrivateIpAddress } else { "" }
    region     = $AWSRegion
    error      = if ($errorMsg) { $errorMsg } else { "" }
  }

  # Disconnect VBR (non-fatal)
  if ($script:VBRConnected) {
    try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch {}
  }

  # Summary
  Write-Log "========================================="
  if ($success) {
    Write-Log "RESTORE COMPLETED SUCCESSFULLY" -Level SUCCESS
    if ($instance) {
      Write-Log "  Instance: $($instance.InstanceId) ($AWSRegion)" -Level SUCCESS
      Write-Log "  Private IP: $($instance.PrivateIpAddress)" -Level SUCCESS
    }
  }
  else {
    Write-Log "RESTORE FAILED: $errorMsg" -Level ERROR
  }
  Write-Log "Duration: $($duration.ToString('hh\:mm\:ss'))"
  Write-Log "Output: $OutputPath"
  Write-Log "========================================="
}

exit $script:ExitCode
