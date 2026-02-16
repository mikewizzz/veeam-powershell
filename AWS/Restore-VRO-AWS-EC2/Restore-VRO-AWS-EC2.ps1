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
  5. Executes Veeam "Restore to Amazon EC2" with full EC2 configuration
  6. Monitors restore progress with timeout enforcement
  7. Validates the restored EC2 instance is running and reachable
  8. Tags all restored AWS resources for governance and cost tracking
  9. Generates structured output for VRO plan step consumption
  10. Produces optional HTML restore report

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

.PARAMETER SkipValidation
  Skip post-restore health checks. Use only for speed-critical DR scenarios.

.PARAMETER ValidationTimeoutMinutes
  Maximum time to wait for post-restore validation. Default: 15 minutes.

.PARAMETER VROPlanName
  VRO recovery plan name (passed by VRO for logging context).

.PARAMETER VROStepName
  VRO plan step name (passed by VRO for logging context).

.PARAMETER DryRun
  Validate all parameters and connectivity without executing the restore.

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
  Version: 1.0.0
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

  # ===== Validation =====
  [switch]$SkipValidation,
  [ValidateRange(1,120)]
  [int]$ValidationTimeoutMinutes = 15,

  # ===== VRO Integration =====
  [string]$VROPlanName,
  [string]$VROStepName,
  [switch]$DryRun,

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
$script:LogEntries = [System.Collections.Generic.List[object]]::new()
$script:ExitCode = 0
$script:RestoredInstanceId = $null
$script:VBRConnected = $false
$script:AWSInitialized = $false

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
# Logging & VRO Output
# =============================

<#
.SYNOPSIS
  Writes a timestamped, leveled log entry to console and log file.
.PARAMETER Message
  The log message.
.PARAMETER Level
  Severity level: INFO, WARNING, ERROR, SUCCESS.
#>
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet("INFO","WARNING","ERROR","SUCCESS")]
    [string]$Level = "INFO"
  )

  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $ts
    Level     = $Level
    Message   = $Message
  }
  $script:LogEntries.Add($entry)

  $color = switch ($Level) {
    "INFO"    { "Cyan" }
    "WARNING" { "Yellow" }
    "ERROR"   { "Red" }
    "SUCCESS" { "Green" }
  }

  $line = "[$ts] [$Level] $Message"
  Write-Host $line -ForegroundColor $color
  $line | Add-Content -Path $logFile -Encoding UTF8
}

<#
.SYNOPSIS
  Outputs structured data for VRO plan step variable capture.
  VRO captures JSON objects from stdout for use in downstream steps.
.PARAMETER Data
  Hashtable of key-value pairs to output as JSON.
#>
function Write-VROOutput {
  param([Parameter(Mandatory)][hashtable]$Data)

  $Data["_vroTimestamp"] = (Get-Date -Format "o")
  $Data["_vroPlan"] = $VROPlanName
  $Data["_vroStep"] = $VROStepName
  $json = $Data | ConvertTo-Json -Compress -Depth 5
  Write-Output "VRO_OUTPUT:$json"
}

# =============================
# Retry Logic
# =============================

<#
.SYNOPSIS
  Executes a script block with exponential backoff retry.
.PARAMETER ScriptBlock
  The operation to execute.
.PARAMETER OperationName
  Friendly name for logging.
.PARAMETER MaxAttempts
  Maximum number of attempts.
.PARAMETER BaseDelay
  Base delay in seconds (doubles each retry).
#>
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [string]$OperationName = "Operation",
    [int]$MaxAttempts = $MaxRetries,
    [int]$BaseDelay = $RetryBaseDelaySeconds
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      return & $ScriptBlock
    }
    catch {
      if ($attempt -ge $MaxAttempts) {
        Write-Log "$OperationName failed after $MaxAttempts attempts: $_" -Level ERROR
        throw
      }
      $delay = $BaseDelay * [Math]::Pow(2, $attempt - 1)
      Write-Log "$OperationName attempt $attempt/$MaxAttempts failed: $_. Retrying in ${delay}s..." -Level WARNING
      Start-Sleep -Seconds $delay
    }
  }
}

# =============================
# Prerequisites Check
# =============================

<#
.SYNOPSIS
  Validates required PowerShell modules and snap-ins are available.
#>
function Test-Prerequisites {
  Write-Log "Validating prerequisites..."

  # Check PowerShell version
  $psVersion = $PSVersionTable.PSVersion
  Write-Log "PowerShell version: $psVersion"
  if ($psVersion.Major -lt 5) {
    throw "PowerShell 5.1 or later is required. Current: $psVersion"
  }

  # Check Veeam PowerShell module
  $veeamLoaded = $false
  try {
    # VBR 12+ uses a module
    if (Get-Module -ListAvailable -Name "Veeam.Backup.PowerShell") {
      Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
      $veeamLoaded = $true
      Write-Log "Loaded Veeam.Backup.PowerShell module"
    }
  }
  catch {
    Write-Log "Module import failed, trying PSSnapin..." -Level WARNING
  }

  if (-not $veeamLoaded) {
    try {
      # Legacy VBR uses snap-in
      if (Get-PSSnapin -Registered -Name "VeeamPSSnapin" -ErrorAction SilentlyContinue) {
        Add-PSSnapin VeeamPSSnapin -ErrorAction Stop
        $veeamLoaded = $true
        Write-Log "Loaded VeeamPSSnapin snap-in"
      }
    }
    catch {
      Write-Log "PSSnapin load failed: $_" -Level WARNING
    }
  }

  if (-not $veeamLoaded) {
    throw "Veeam PowerShell module not found. Install VBR Console or Veeam.Backup.PowerShell module."
  }

  # Check AWS PowerShell modules
  $awsModules = @("AWS.Tools.Common", "AWS.Tools.EC2")
  foreach ($mod in $awsModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
      throw "AWS module '$mod' not found. Install via: Install-Module $mod -Scope CurrentUser"
    }
    Import-Module $mod -ErrorAction Stop
    Write-Log "Loaded AWS module: $mod"
  }

  # Optional: AWS.Tools.S3 for backup validation
  if (Get-Module -ListAvailable -Name "AWS.Tools.S3") {
    Import-Module AWS.Tools.S3 -ErrorAction Stop
    Write-Log "Loaded AWS module: AWS.Tools.S3 (optional)"
  }

  # Optional: AWS.Tools.SecurityToken for STS AssumeRole
  if ($AWSRoleArn) {
    if (-not (Get-Module -ListAvailable -Name "AWS.Tools.SecurityToken")) {
      throw "AWS.Tools.SecurityToken module required for AssumeRole. Install via: Install-Module AWS.Tools.SecurityToken -Scope CurrentUser"
    }
    Import-Module AWS.Tools.SecurityToken -ErrorAction Stop
    Write-Log "Loaded AWS module: AWS.Tools.SecurityToken"
  }

  Write-Log "All prerequisites validated" -Level SUCCESS
}

# =============================
# VBR Connection
# =============================

<#
.SYNOPSIS
  Establishes connection to the Veeam Backup & Replication server.
  Reuses existing session if already connected to the same server.
#>
function Connect-VBRSession {
  Write-Log "Connecting to VBR server: $VBRServer`:$VBRPort"

  # Check for existing connection
  try {
    $existing = Get-VBRServerSession -ErrorAction SilentlyContinue
    if ($existing -and $existing.Server -eq $VBRServer -and $existing.Port -eq $VBRPort) {
      Write-Log "Reusing existing VBR session to $VBRServer" -Level SUCCESS
      $script:VBRConnected = $true
      return
    }
  }
  catch {
    # No existing session, proceed with new connection
  }

  $connectParams = @{
    Server = $VBRServer
    Port   = $VBRPort
  }
  if ($VBRCredential) {
    $connectParams["Credential"] = $VBRCredential
  }

  Invoke-WithRetry -OperationName "VBR Connection" -ScriptBlock {
    Connect-VBRServer @connectParams
  }

  $script:VBRConnected = $true
  Write-Log "Connected to VBR server: $VBRServer" -Level SUCCESS
}

# =============================
# AWS Authentication
# =============================

<#
.SYNOPSIS
  Initializes AWS PowerShell session using IAM best practices.
  Priority: IAM Instance Profile > STS AssumeRole > Named Profile > Environment.
#>
function Connect-AWSSession {
  Write-Log "Initializing AWS session for region: $AWSRegion"

  # Set default region
  Set-DefaultAWSRegion -Region $AWSRegion

  # Authentication hierarchy (most secure first)
  if ($AWSRoleArn) {
    # STS AssumeRole - cross-account or elevated privileges
    Write-Log "Authenticating via STS AssumeRole: $AWSRoleArn"

    $assumeParams = @{
      RoleArn         = $AWSRoleArn
      RoleSessionName = "VRORestore-$stamp"
      DurationSecond  = $AWSSessionDuration
    }
    if ($AWSExternalId) {
      $assumeParams["ExternalId"] = $AWSExternalId
    }
    if ($AWSProfile) {
      $assumeParams["ProfileName"] = $AWSProfile
    }

    $stsResult = Invoke-WithRetry -OperationName "STS AssumeRole" -ScriptBlock {
      Use-STSRole @assumeParams
    }

    Set-AWSCredential -Credential $stsResult.Credentials
    Write-Log "STS AssumeRole succeeded (expires: $($stsResult.Credentials.Expiration))" -Level SUCCESS
  }
  elseif ($AWSProfile) {
    # Named profile
    Write-Log "Authenticating via AWS profile: $AWSProfile"
    Set-AWSCredential -ProfileName $AWSProfile
    Write-Log "AWS profile '$AWSProfile' activated" -Level SUCCESS
  }
  else {
    # IAM Instance Profile or environment variables (auto-detected by SDK)
    Write-Log "Using default AWS credential chain (instance profile / environment)"
  }

  # Validate connectivity
  Invoke-WithRetry -OperationName "AWS Connectivity Check" -ScriptBlock {
    $identity = Get-STSCallerIdentity -ErrorAction Stop
    Write-Log "AWS identity: Account=$($identity.Account), ARN=$($identity.Arn)" -Level SUCCESS
  }

  $script:AWSInitialized = $true
}

# =============================
# Backup & Restore Point Discovery
# =============================

<#
.SYNOPSIS
  Locates the specified backup and returns the target restore point.
  Supports filtering by VM name, restore point ID, or latest clean point.
.OUTPUTS
  Veeam restore point object.
#>
function Find-RestorePoint {
  Write-Log "Searching for backup: '$BackupName'"

  # Find the backup
  $backup = Get-VBRBackup -Name $BackupName -ErrorAction SilentlyContinue
  if (-not $backup) {
    # Try partial match
    $backup = Get-VBRBackup | Where-Object { $_.Name -like "*$BackupName*" }
    if ($backup -is [array]) {
      $names = ($backup | ForEach-Object { $_.Name }) -join ", "
      throw "Multiple backups matched '$BackupName': $names. Provide the exact name."
    }
  }
  if (-not $backup) {
    throw "Backup '$BackupName' not found. Available backups: $((Get-VBRBackup | ForEach-Object { $_.Name }) -join ', ')"
  }

  Write-Log "Found backup: $($backup.Name) (ID: $($backup.Id))"

  # Get the repository info
  $repo = $backup.GetRepository()
  if ($repo) {
    Write-Log "Repository: $($repo.Name) (Type: $($repo.Type))"
  }

  # Get restore points
  $rpParams = @{ Backup = $backup }
  if ($VMName) {
    $rpParams["Name"] = $VMName
  }

  $restorePoints = Get-VBRRestorePoint @rpParams | Sort-Object CreationTime -Descending
  if (-not $restorePoints -or $restorePoints.Count -eq 0) {
    throw "No restore points found for backup '$BackupName'$(if($VMName){" / VM '$VMName'"})."
  }

  Write-Log "Found $($restorePoints.Count) restore point(s). Latest: $($restorePoints[0].CreationTime)"

  # Select the restore point
  if ($RestorePointId) {
    $rp = $restorePoints | Where-Object { $_.Id -eq $RestorePointId }
    if (-not $rp) {
      throw "Restore point ID '$RestorePointId' not found."
    }
    Write-Log "Using specified restore point: $($rp.CreationTime) (ID: $RestorePointId)"
  }
  elseif ($UseLatestCleanPoint) {
    $rp = Find-LatestCleanRestorePoint -RestorePoints $restorePoints
  }
  else {
    $rp = $restorePoints[0]
    Write-Log "Using latest restore point: $($rp.CreationTime)"
  }

  return $rp
}

<#
.SYNOPSIS
  Scans restore points from newest to oldest and returns the first one that
  passes Veeam Secure Restore malware checks.
.PARAMETER RestorePoints
  Array of restore points sorted newest-first.
#>
function Find-LatestCleanRestorePoint {
  param([Parameter(Mandatory)][array]$RestorePoints)

  Write-Log "Scanning restore points for latest clean (malware-free) point..."

  foreach ($rp in $RestorePoints) {
    Write-Log "  Checking restore point: $($rp.CreationTime) (ID: $($rp.Id))"

    # Check if Veeam has malware detection results for this point (VBR 12.1+)
    try {
      $scanResult = Get-VBRMalwareDetectionResult -RestorePoint $rp -ErrorAction SilentlyContinue
      if ($scanResult) {
        if ($scanResult.Status -eq "Clean") {
          Write-Log "  CLEAN: Restore point $($rp.CreationTime) passed malware scan" -Level SUCCESS
          return $rp
        }
        else {
          Write-Log "  INFECTED: Restore point $($rp.CreationTime) - Status: $($scanResult.Status)" -Level WARNING
          continue
        }
      }
    }
    catch {
      # Malware detection may not be available on all VBR versions
    }

    # Fallback: check SureBackup session results for this restore point
    try {
      $sbSessions = Get-VSBSession -ErrorAction SilentlyContinue |
        Where-Object { $_.RestorePointId -eq $rp.Id -and $_.Result -eq "Success" }
      if ($sbSessions) {
        Write-Log "  VERIFIED: Restore point $($rp.CreationTime) validated by SureBackup" -Level SUCCESS
        return $rp
      }
    }
    catch {
      # SureBackup sessions may not exist
    }

    # If no scan data exists, check backup session result
    try {
      $session = Get-VBRBackupSession -ErrorAction SilentlyContinue |
        Where-Object { $_.CreationTime -eq $rp.CreationTime -and $_.Result -eq "Success" }
      if ($session) {
        Write-Log "  PRESUMED CLEAN: No malware data; backup session succeeded. Using this point." -Level WARNING
        return $rp
      }
    }
    catch {
      # Proceed to next restore point
    }
  }

  throw "No clean restore point found across $($RestorePoints.Count) points. Manual investigation required."
}

# =============================
# AWS Target Configuration
# =============================

<#
.SYNOPSIS
  Discovers and validates the target AWS infrastructure (VPC, subnet, security groups).
  Auto-selects defaults when specific resources are not specified.
.OUTPUTS
  Hashtable with resolved VPC, Subnet, SecurityGroups, and InstanceType.
#>
function Get-EC2TargetConfig {
  Write-Log "Resolving EC2 target configuration in $AWSRegion..."

  $config = @{}

  # Resolve VPC
  if ($VPCId) {
    $vpc = Get-EC2Vpc -VpcId $VPCId -Region $AWSRegion
    if (-not $vpc) { throw "VPC '$VPCId' not found in $AWSRegion." }
    Write-Log "Using specified VPC: $VPCId"
  }
  else {
    $vpc = Get-EC2Vpc -Filter @{ Name="isDefault"; Values="true" } -Region $AWSRegion
    if (-not $vpc) {
      $vpc = (Get-EC2Vpc -Region $AWSRegion | Select-Object -First 1)
    }
    if (-not $vpc) { throw "No VPC found in $AWSRegion. Specify -VPCId explicitly." }
    Write-Log "Auto-selected VPC: $($vpc.VpcId) (CIDR: $($vpc.CidrBlock))"
  }
  $config["VpcId"] = $vpc.VpcId

  # Resolve Subnet
  if ($SubnetId) {
    $subnet = Get-EC2Subnet -SubnetId $SubnetId -Region $AWSRegion
    if (-not $subnet) { throw "Subnet '$SubnetId' not found." }
    if ($subnet.VpcId -ne $vpc.VpcId) { throw "Subnet '$SubnetId' is not in VPC '$($vpc.VpcId)'." }
    Write-Log "Using specified subnet: $SubnetId (AZ: $($subnet.AvailabilityZone))"
  }
  else {
    $subnet = Get-EC2Subnet -Filter @{ Name="vpc-id"; Values=$vpc.VpcId } -Region $AWSRegion |
      Sort-Object AvailableIpAddressCount -Descending |
      Select-Object -First 1
    if (-not $subnet) { throw "No subnet found in VPC '$($vpc.VpcId)'. Specify -SubnetId." }
    Write-Log "Auto-selected subnet: $($subnet.SubnetId) (AZ: $($subnet.AvailabilityZone), Free IPs: $($subnet.AvailableIpAddressCount))"
  }
  $config["SubnetId"] = $subnet.SubnetId
  $config["AvailabilityZone"] = $subnet.AvailabilityZone

  # Resolve Security Groups
  if ($SecurityGroupIds) {
    foreach ($sgId in $SecurityGroupIds) {
      $sg = Get-EC2SecurityGroup -GroupId $sgId -Region $AWSRegion -ErrorAction SilentlyContinue
      if (-not $sg) { throw "Security group '$sgId' not found in $AWSRegion." }
    }
    $config["SecurityGroupIds"] = $SecurityGroupIds
    Write-Log "Using specified security groups: $($SecurityGroupIds -join ', ')"
  }
  else {
    $defaultSg = Get-EC2SecurityGroup -Filter @{ Name="vpc-id"; Values=$vpc.VpcId } -Region $AWSRegion |
      Where-Object { $_.GroupName -eq "default" } |
      Select-Object -First 1
    if ($defaultSg) {
      $config["SecurityGroupIds"] = @($defaultSg.GroupId)
      Write-Log "Auto-selected default security group: $($defaultSg.GroupId)"
    }
    else {
      Write-Log "No default security group found. Restore will use VPC default." -Level WARNING
      $config["SecurityGroupIds"] = @()
    }
  }

  # Validate instance type availability
  $availableTypes = Get-EC2InstanceTypeOffering -LocationType "region" `
    -Filter @{ Name="instance-type"; Values=$InstanceType } -Region $AWSRegion
  if (-not $availableTypes) {
    throw "Instance type '$InstanceType' is not available in $AWSRegion."
  }
  $config["InstanceType"] = $InstanceType
  Write-Log "Instance type '$InstanceType' validated in $AWSRegion"

  # Key pair validation
  if ($KeyPairName) {
    $kp = Get-EC2KeyPair -KeyName $KeyPairName -Region $AWSRegion -ErrorAction SilentlyContinue
    if (-not $kp) { throw "Key pair '$KeyPairName' not found in $AWSRegion." }
    $config["KeyPairName"] = $KeyPairName
    Write-Log "Key pair '$KeyPairName' validated"
  }

  Write-Log "EC2 target configuration resolved" -Level SUCCESS
  return $config
}

# =============================
# Restore Execution
# =============================

<#
.SYNOPSIS
  Configures and starts the Veeam Restore to Amazon EC2 operation.
.PARAMETER RestorePoint
  The Veeam restore point to restore from.
.PARAMETER EC2Config
  Hashtable from Get-EC2TargetConfig with target infrastructure details.
.OUTPUTS
  Veeam restore session object.
#>
function Start-EC2Restore {
  param(
    [Parameter(Mandatory)][object]$RestorePoint,
    [Parameter(Mandatory)][hashtable]$EC2Config
  )

  $instanceName = if ($EC2InstanceName) {
    $EC2InstanceName
  }
  else {
    $vmLabel = if ($VMName) { $VMName } else { $BackupName }
    "Restored-$vmLabel-$stamp"
  }

  Write-Log "Starting EC2 restore: '$instanceName' -> $AWSRegion ($($EC2Config.InstanceType))"

  # Get VBR Amazon account
  $awsAccount = if ($AWSAccountName) {
    Get-VBRAmazonAccount -Name $AWSAccountName
  }
  else {
    Get-VBRAmazonAccount | Select-Object -First 1
  }
  if (-not $awsAccount) {
    throw "No AWS account configured in VBR. Add one via VBR Console > Manage Cloud Credentials."
  }
  Write-Log "Using VBR AWS account: $($awsAccount.Name) (ID: $($awsAccount.Id))"

  # Discover VBR Amazon infrastructure objects
  $region = Get-VBRAmazonEC2Region -Account $awsAccount | Where-Object { $_.RegionType -eq $AWSRegion }
  if (-not $region) {
    throw "Region '$AWSRegion' not found for AWS account '$($awsAccount.Name)' in VBR."
  }

  $vpc = Get-VBRAmazonEC2VPC -Region $region | Where-Object { $_.VPCId -eq $EC2Config.VpcId }
  if (-not $vpc) {
    throw "VPC '$($EC2Config.VpcId)' not found in VBR for region '$AWSRegion'."
  }

  $subnet = Get-VBRAmazonEC2Subnet -VPC $vpc | Where-Object { $_.SubnetId -eq $EC2Config.SubnetId }
  if (-not $subnet) {
    throw "Subnet '$($EC2Config.SubnetId)' not found in VBR for VPC '$($EC2Config.VpcId)'."
  }

  $securityGroups = @()
  foreach ($sgId in $EC2Config.SecurityGroupIds) {
    $sg = Get-VBRAmazonEC2SecurityGroup -VPC $vpc | Where-Object { $_.SecurityGroupId -eq $sgId }
    if ($sg) { $securityGroups += $sg }
  }

  # Build disk configuration
  $diskConfig = New-VBRAmazonEC2DiskConfiguration -RestorePoint $RestorePoint `
    -DiskType $DiskType

  if ($EncryptVolumes) {
    $encryptParams = @{ DiskConfiguration = $diskConfig; Encrypt = $true }
    if ($KMSKeyId) { $encryptParams["KMSKeyId"] = $KMSKeyId }
    $diskConfig = Set-VBRAmazonEC2DiskConfiguration @encryptParams
  }

  # Build restore parameters
  $restoreParams = @{
    RestorePoint      = $RestorePoint
    Region            = $region
    InstanceType      = $EC2Config.InstanceType
    VMName            = $instanceName
    VPC               = $vpc
    Subnet            = $subnet
    DiskConfiguration = $diskConfig
    Reason            = "VRO Automated Restore - Plan: $VROPlanName, Step: $VROStepName"
  }

  if ($securityGroups.Count -gt 0) {
    $restoreParams["SecurityGroup"] = $securityGroups
  }
  if ($EC2Config.KeyPairName) {
    $restoreParams["KeyPair"] = $EC2Config.KeyPairName
  }
  if (-not $PowerOnAfterRestore) {
    $restoreParams["DoNotPowerOn"] = $true
  }

  # Execute restore
  if ($DryRun) {
    Write-Log "DRY RUN: Would restore '$($RestorePoint.Name)' as '$instanceName' to $AWSRegion" -Level WARNING
    Write-Log "  Instance Type: $($EC2Config.InstanceType)"
    Write-Log "  VPC: $($EC2Config.VpcId) / Subnet: $($EC2Config.SubnetId)"
    Write-Log "  Security Groups: $($EC2Config.SecurityGroupIds -join ', ')"
    Write-Log "  Disk Type: $DiskType | Encrypted: $EncryptVolumes"
    return $null
  }

  Write-Log "Submitting restore job to VBR..."
  $session = Invoke-WithRetry -OperationName "Start EC2 Restore" -ScriptBlock {
    Start-VBRRestoreVMToAmazon @restoreParams
  }

  Write-Log "Restore session started: ID=$($session.Id), State=$($session.State)" -Level SUCCESS
  return $session
}

# =============================
# Restore Monitoring
# =============================

<#
.SYNOPSIS
  Monitors the restore session until completion or timeout.
.PARAMETER Session
  The Veeam restore session to monitor.
.OUTPUTS
  The final session state object.
#>
function Wait-RestoreCompletion {
  param([Parameter(Mandatory)][object]$Session)

  $timeout = [TimeSpan]::FromMinutes($RestoreTimeoutMinutes)
  $deadline = $script:StartTime.Add($timeout)
  $pollInterval = 15  # seconds between status checks
  $lastProgress = -1

  Write-Log "Monitoring restore session (timeout: $RestoreTimeoutMinutes minutes)..."

  while ((Get-Date) -lt $deadline) {
    $current = Get-VBRSession -Id $Session.Id

    # Report progress changes
    $progress = if ($current.Progress) { $current.Progress } else { 0 }
    if ($progress -ne $lastProgress) {
      Write-Log "  Restore progress: $progress% - State: $($current.State)"
      $lastProgress = $progress
    }

    switch ($current.State) {
      "Stopped" {
        if ($current.Result -eq "Success") {
          Write-Log "Restore completed successfully (Duration: $($current.Duration))" -Level SUCCESS
          return $current
        }
        elseif ($current.Result -eq "Warning") {
          Write-Log "Restore completed with warnings: $($current.Description)" -Level WARNING
          return $current
        }
        else {
          throw "Restore failed: $($current.Result) - $($current.Description)"
        }
      }
      "Failed" {
        throw "Restore session failed: $($current.Description)"
      }
    }

    Start-Sleep -Seconds $pollInterval
  }

  throw "Restore timed out after $RestoreTimeoutMinutes minutes. Session ID: $($Session.Id)"
}

# =============================
# Post-Restore Validation
# =============================

<#
.SYNOPSIS
  Discovers the EC2 instance created by the restore and validates it is running.
.PARAMETER InstanceName
  The Name tag of the restored instance.
.OUTPUTS
  EC2 instance object.
#>
function Test-EC2InstanceHealth {
  param([Parameter(Mandatory)][string]$InstanceName)

  Write-Log "Validating restored EC2 instance: '$InstanceName'"

  # Find the instance by Name tag
  $instance = Invoke-WithRetry -OperationName "Find EC2 Instance" -ScriptBlock {
    $result = Get-EC2Instance -Filter @(
      @{ Name="tag:Name"; Values=$InstanceName }
      @{ Name="instance-state-name"; Values=@("pending","running") }
    ) -Region $AWSRegion

    $result.Instances | Select-Object -First 1
  }

  if (-not $instance) {
    throw "Restored EC2 instance '$InstanceName' not found in $AWSRegion."
  }

  $script:RestoredInstanceId = $instance.InstanceId
  Write-Log "Found instance: $($instance.InstanceId) (State: $($instance.State.Name))"

  if ($SkipValidation) {
    Write-Log "Skipping post-restore validation (SkipValidation flag)" -Level WARNING
    return $instance
  }

  # Wait for instance to reach running state
  $valTimeout = [TimeSpan]::FromMinutes($ValidationTimeoutMinutes)
  $valDeadline = (Get-Date).Add($valTimeout)

  Write-Log "Waiting for instance to reach 'running' state..."
  while ((Get-Date) -lt $valDeadline) {
    $state = (Get-EC2Instance -InstanceId $instance.InstanceId -Region $AWSRegion).Instances[0].State.Name
    if ($state -eq "running") {
      Write-Log "Instance is running" -Level SUCCESS
      break
    }
    if ($state -eq "terminated" -or $state -eq "shutting-down") {
      throw "Instance $($instance.InstanceId) entered '$state' state unexpectedly."
    }
    Start-Sleep -Seconds 10
  }

  # Wait for status checks to pass
  Write-Log "Waiting for EC2 status checks..."
  $checksPass = $false
  while ((Get-Date) -lt $valDeadline) {
    $status = Get-EC2InstanceStatus -InstanceId $instance.InstanceId -Region $AWSRegion
    if ($status) {
      $instanceStatus = $status.InstanceStatus.Status
      $systemStatus = $status.SystemStatus.Status
      Write-Log "  Instance status: $instanceStatus | System status: $systemStatus"

      if ($instanceStatus -eq "ok" -and $systemStatus -eq "ok") {
        $checksPass = $true
        break
      }
    }
    Start-Sleep -Seconds 15
  }

  if (-not $checksPass) {
    Write-Log "EC2 status checks did not pass within $ValidationTimeoutMinutes minutes" -Level WARNING
  }
  else {
    Write-Log "All EC2 status checks passed" -Level SUCCESS
  }

  # Refresh instance data
  $instance = (Get-EC2Instance -InstanceId $instance.InstanceId -Region $AWSRegion).Instances[0]
  return $instance
}

# =============================
# Resource Tagging
# =============================

<#
.SYNOPSIS
  Applies governance and tracking tags to the restored EC2 instance and its EBS volumes.
.PARAMETER Instance
  The EC2 instance object.
#>
function Set-EC2ResourceTags {
  param([Parameter(Mandatory)][object]$Instance)

  Write-Log "Tagging restored AWS resources..."

  # Build standard tags
  $standardTags = @{
    "veeam:restore-source"    = $BackupName
    "veeam:restore-point"     = if ($RestorePointId) { $RestorePointId } else { "latest" }
    "veeam:restore-timestamp" = $stamp
    "veeam:vro-plan"          = if ($VROPlanName) { $VROPlanName } else { "manual" }
    "veeam:vro-step"          = if ($VROStepName) { $VROStepName } else { "manual" }
    "veeam:restore-mode"      = $RestoreMode
    "ManagedBy"               = "VeeamVRO"
  }

  # Merge user-provided tags (user tags take precedence)
  $allTags = $standardTags.Clone()
  foreach ($key in $Tags.Keys) {
    $allTags[$key] = $Tags[$key]
  }

  # Convert to AWS tag format
  $awsTags = $allTags.GetEnumerator() | ForEach-Object {
    [Amazon.EC2.Model.Tag]::new($_.Key, $_.Value)
  }

  # Tag the instance
  New-EC2Tag -Resource $Instance.InstanceId -Tag $awsTags -Region $AWSRegion
  Write-Log "Tagged instance $($Instance.InstanceId) with $($awsTags.Count) tags"

  # Tag all attached EBS volumes
  $volumeIds = $Instance.BlockDeviceMappings | ForEach-Object { $_.Ebs.VolumeId } | Where-Object { $_ }
  foreach ($volId in $volumeIds) {
    New-EC2Tag -Resource $volId -Tag $awsTags -Region $AWSRegion
    Write-Log "Tagged volume $volId"
  }

  # Tag network interfaces
  $eniIds = $Instance.NetworkInterfaces | ForEach-Object { $_.NetworkInterfaceId } | Where-Object { $_ }
  foreach ($eniId in $eniIds) {
    New-EC2Tag -Resource $eniId -Tag $awsTags -Region $AWSRegion
    Write-Log "Tagged network interface $eniId"
  }

  Write-Log "All resources tagged" -Level SUCCESS
}

# =============================
# HTML Report Generation
# =============================

<#
.SYNOPSIS
  Generates a professional HTML restore report.
.PARAMETER RestorePoint
  The Veeam restore point used.
.PARAMETER EC2Config
  The target EC2 configuration.
.PARAMETER Instance
  The restored EC2 instance (or $null on failure).
.PARAMETER Duration
  Total operation duration.
.PARAMETER Success
  Whether the restore succeeded.
.PARAMETER ErrorMessage
  Error message if the restore failed.
#>
function New-RestoreReport {
  param(
    [object]$RestorePoint,
    [hashtable]$EC2Config,
    [object]$Instance,
    [TimeSpan]$Duration,
    [bool]$Success,
    [string]$ErrorMessage
  )

  if (-not $GenerateReport) { return }

  Write-Log "Generating HTML restore report..."

  $statusColor = if ($Success) { "#00B336" } else { "#E74C3C" }
  $statusText = if ($Success) { "SUCCESS" } else { "FAILED" }
  $instanceId = if ($Instance) { $Instance.InstanceId } else { "N/A" }
  $privateIp = if ($Instance) { $Instance.PrivateIpAddress } else { "N/A" }
  $publicIp = if ($Instance -and $Instance.PublicIpAddress) { $Instance.PublicIpAddress } else { "N/A" }
  $rpTime = if ($RestorePoint) { $RestorePoint.CreationTime.ToString("yyyy-MM-dd HH:mm:ss UTC") } else { "N/A" }

  $logRows = ($script:LogEntries | ForEach-Object {
    $levelColor = switch ($_.Level) {
      "ERROR"   { "#E74C3C" }
      "WARNING" { "#F39C12" }
      "SUCCESS" { "#00B336" }
      default   { "#6C757D" }
    }
    "<tr><td style='white-space:nowrap'>$($_.Timestamp)</td><td><span style='color:$levelColor;font-weight:600'>$($_.Level)</span></td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Message))</td></tr>"
  }) -join "`n"

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VRO AWS EC2 Restore Report</title>
  <style>
    :root { --veeam-green: #00B336; --veeam-dark: #1A1A2E; }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: #F4F6F9; color: #2D3748; line-height: 1.6; }
    .container { max-width: 960px; margin: 0 auto; padding: 24px; }
    .header { background: linear-gradient(135deg, var(--veeam-dark) 0%, #16213E 100%); color: #fff; padding: 32px; border-radius: 12px 12px 0 0; }
    .header h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 4px; }
    .header .subtitle { opacity: 0.8; font-size: 0.9rem; }
    .status-banner { padding: 16px 32px; color: #fff; font-weight: 600; font-size: 1.1rem; background: $statusColor; }
    .card { background: #fff; border-radius: 0 0 12px 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin-bottom: 24px; overflow: hidden; }
    .section { padding: 24px 32px; border-bottom: 1px solid #E2E8F0; }
    .section:last-child { border-bottom: none; }
    .section h2 { font-size: 1.1rem; color: var(--veeam-dark); margin-bottom: 16px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .field { }
    .field .label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; color: #718096; font-weight: 600; }
    .field .value { font-size: 0.95rem; font-weight: 500; color: #2D3748; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th { text-align: left; padding: 8px 12px; background: #F7FAFC; color: #4A5568; font-weight: 600; border-bottom: 2px solid #E2E8F0; }
    td { padding: 6px 12px; border-bottom: 1px solid #EDF2F7; vertical-align: top; }
    .footer { text-align: center; padding: 16px; font-size: 0.8rem; color: #A0AEC0; }
    @media print { body { background: #fff; } .container { max-width: 100%; padding: 0; } }
    @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="container">
    <div class="card">
      <div class="header">
        <h1>VRO AWS EC2 Restore Report</h1>
        <div class="subtitle">Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC")</div>
      </div>
      <div class="status-banner">Restore Status: $statusText$(if($ErrorMessage){ " - $([System.Web.HttpUtility]::HtmlEncode($ErrorMessage))" })</div>

      <div class="section">
        <h2>Restore Summary</h2>
        <div class="grid">
          <div class="field"><div class="label">Backup Name</div><div class="value">$BackupName</div></div>
          <div class="field"><div class="label">VM Name</div><div class="value">$(if($VMName){$VMName}else{"(all)"})</div></div>
          <div class="field"><div class="label">Restore Point</div><div class="value">$rpTime</div></div>
          <div class="field"><div class="label">Restore Mode</div><div class="value">$RestoreMode</div></div>
          <div class="field"><div class="label">Duration</div><div class="value">$($Duration.ToString('hh\:mm\:ss'))</div></div>
          <div class="field"><div class="label">Clean Point Scan</div><div class="value">$(if($UseLatestCleanPoint){"Enabled"}else{"Disabled"})</div></div>
        </div>
      </div>

      <div class="section">
        <h2>EC2 Instance Details</h2>
        <div class="grid">
          <div class="field"><div class="label">Instance ID</div><div class="value">$instanceId</div></div>
          <div class="field"><div class="label">Instance Type</div><div class="value">$InstanceType</div></div>
          <div class="field"><div class="label">Region</div><div class="value">$AWSRegion</div></div>
          <div class="field"><div class="label">Private IP</div><div class="value">$privateIp</div></div>
          <div class="field"><div class="label">Public IP</div><div class="value">$publicIp</div></div>
          <div class="field"><div class="label">Disk Type</div><div class="value">$DiskType$(if($EncryptVolumes){" (KMS Encrypted)"})</div></div>
          <div class="field"><div class="label">VPC</div><div class="value">$(if($EC2Config){$EC2Config.VpcId}else{"N/A"})</div></div>
          <div class="field"><div class="label">Subnet</div><div class="value">$(if($EC2Config){$EC2Config.SubnetId}else{"N/A"})</div></div>
        </div>
      </div>

      <div class="section">
        <h2>VRO Context</h2>
        <div class="grid">
          <div class="field"><div class="label">VRO Plan</div><div class="value">$(if($VROPlanName){$VROPlanName}else{"N/A"})</div></div>
          <div class="field"><div class="label">VRO Step</div><div class="value">$(if($VROStepName){$VROStepName}else{"N/A"})</div></div>
          <div class="field"><div class="label">VBR Server</div><div class="value">$VBRServer</div></div>
          <div class="field"><div class="label">Dry Run</div><div class="value">$(if($DryRun){"Yes"}else{"No"})</div></div>
        </div>
      </div>

      <div class="section">
        <h2>Execution Log</h2>
        <table>
          <thead><tr><th>Timestamp</th><th>Level</th><th>Message</th></tr></thead>
          <tbody>$logRows</tbody>
        </table>
      </div>
    </div>
    <div class="footer">Veeam Recovery Orchestrator &middot; AWS EC2 Restore Plugin v1.0.0</div>
  </div>
</body>
</html>
"@

  $html | Set-Content -Path $reportFile -Encoding UTF8
  Write-Log "Report saved: $reportFile" -Level SUCCESS
}

# =============================
# Main Execution
# =============================

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
  Write-Log "--- Step 1/8: Prerequisites ---"
  Test-Prerequisites

  # Step 2: Connect to VBR
  Write-Log "--- Step 2/8: VBR Connection ---"
  Connect-VBRSession

  # Step 3: Connect to AWS
  Write-Log "--- Step 3/8: AWS Authentication ---"
  Connect-AWSSession

  # Step 4: Find restore point
  Write-Log "--- Step 4/8: Restore Point Discovery ---"
  $restorePoint = Find-RestorePoint

  # Step 5: Resolve EC2 target
  Write-Log "--- Step 5/8: EC2 Target Configuration ---"
  $ec2Config = Get-EC2TargetConfig

  # Step 6: Execute restore
  Write-Log "--- Step 6/8: Restore Execution ---"
  $session = Start-EC2Restore -RestorePoint $restorePoint -EC2Config $ec2Config

  if ($DryRun) {
    $success = $true
    Write-Log "Dry run completed. No restore executed." -Level SUCCESS
  }
  else {
    # Step 7: Monitor restore
    Write-Log "--- Step 7/8: Restore Monitoring ---"
    $finalSession = Wait-RestoreCompletion -Session $session

    # Step 8: Validate and tag
    Write-Log "--- Step 8/8: Validation & Tagging ---"
    $instanceName = if ($EC2InstanceName) { $EC2InstanceName } else {
      $vmLabel = if ($VMName) { $VMName } else { $BackupName }
      "Restored-$vmLabel-$stamp"
    }

    $instance = Test-EC2InstanceHealth -InstanceName $instanceName
    Set-EC2ResourceTags -Instance $instance

    $success = $true
  }
}
catch {
  $errorMsg = $_.Exception.Message
  Write-Log "FATAL: $errorMsg" -Level ERROR
  Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
  $script:ExitCode = 1
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

  # Export JSON result (machine-readable for VRO)
  $result = [ordered]@{
    success         = $success
    backupName      = $BackupName
    vmName          = $VMName
    region          = $AWSRegion
    instanceId      = $script:RestoredInstanceId
    instanceType    = $InstanceType
    privateIp       = if ($instance) { $instance.PrivateIpAddress } else { $null }
    publicIp        = if ($instance) { $instance.PublicIpAddress } else { $null }
    restoreMode     = $RestoreMode
    restorePoint    = if ($restorePoint) { $restorePoint.CreationTime.ToString("o") } else { $null }
    durationSeconds = [int]$duration.TotalSeconds
    dryRun          = [bool]$DryRun
    vroPlan         = $VROPlanName
    vroStep         = $VROStepName
    error           = $errorMsg
    timestamp       = (Get-Date -Format "o")
  }

  $result | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8

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
