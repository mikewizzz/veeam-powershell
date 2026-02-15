<#
.SYNOPSIS
  Veeam S3 DR Accelerator - AWS Fresh-Account Restore Scaffolding

.DESCRIPTION
  Builds the complete AWS infrastructure scaffolding in a fresh (or existing) AWS account
  so that Veeam Backup & Replication can securely restore workloads from S3-based backup
  repositories (Veeam Vault, customer-managed S3, or S3-compatible storage).

  WHY THIS EXISTS:
  Many Veeam customers store offsite backups in S3 object storage but have NO pre-built
  DR environment ready for restore.  When disaster strikes (or during DR testing), they
  need a clean AWS account with networking, IAM, security, and connectivity to the backup
  bucket - all configured correctly BEFORE they can begin restoring.

  Without this accelerator, standing up the scaffolding manually takes hours of console
  clicking and is error-prone under pressure.  This script automates the entire process
  in minutes with security best-practices baked in.

  WHAT THIS SCRIPT DOES:
  1. Validates prerequisites (AWS modules, credentials, target region)
  2. Creates a DR-ready VPC with public/private subnets across 2 AZs
  3. Deploys Internet Gateway, NAT Gateway, and route tables
  4. Creates S3 Gateway VPC Endpoint (private, zero-egress-cost access to backup bucket)
  5. Configures least-privilege IAM roles and policies for Veeam restore operations
  6. Optionally configures cross-account S3 access (when backups live in a separate account)
  7. Creates KMS encryption key for restored volumes and snapshots
  8. Enables CloudTrail for audit logging of all DR operations
  9. Provisions security groups for Veeam Backup & Replication components
  10. Validates connectivity and IAM permissions against the backup bucket
  11. Generates a professional HTML readiness report with all resource details

  SUPPORTED SCENARIOS:
  - Same-account restore (backup bucket is in this AWS account)
  - Cross-account restore (backup bucket is in production account, restoring to DR account)
  - Veeam Vault / external S3-compatible storage (credentials-based access)

  MODES:
  - Plan    : Dry-run showing what WOULD be created (no AWS changes)
  - Deploy  : Creates all infrastructure resources
  - Validate: Checks an existing DR environment for readiness
  - Teardown: Removes DR infrastructure (for post-test cleanup)

.PARAMETER Mode
  Execution mode: Plan, Deploy, Validate, or Teardown.

.PARAMETER BackupBucketName
  Name of the S3 bucket containing Veeam backup data.

.PARAMETER BackupBucketRegion
  AWS region where the backup bucket resides (e.g., "us-east-1").

.PARAMETER TargetRegion
  AWS region where DR infrastructure will be built (e.g., "us-west-2").
  Defaults to BackupBucketRegion if not specified.

.PARAMETER BackupAccountId
  AWS account ID that owns the backup bucket (for cross-account scenarios).
  If omitted, same-account access is assumed.

.PARAMETER ExternalS3Endpoint
  Custom S3-compatible endpoint URL (for Veeam Vault or non-AWS S3 storage).

.PARAMETER VpcCidr
  CIDR block for the DR VPC (default: "10.200.0.0/16").

.PARAMETER EnvironmentTag
  Tag value applied to all created resources for identification (default: "VeeamDR").

.PARAMETER EnableCloudTrail
  Enable CloudTrail logging for audit trail (default: true).

.PARAMETER SkipVpcCreation
  Skip VPC creation and use an existing VPC.

.PARAMETER ExistingVpcId
  VPC ID to use when SkipVpcCreation is set.

.PARAMETER ExistingSubnetId
  Subnet ID for Veeam proxy/server placement when using existing VPC.

.PARAMETER VbrInstanceType
  EC2 instance type for the Veeam Backup & Replication server (default: "t3.xlarge").

.PARAMETER DeployVbrServer
  Deploy a Windows Server EC2 instance for Veeam B&R (requires AMI availability).

.PARAMETER KeyPairName
  Existing EC2 key pair name for VBR server RDP access.

.PARAMETER AllowedRdpCidr
  CIDR block allowed for RDP access to VBR server (default: "0.0.0.0/0" - RESTRICT IN PRODUCTION).

.PARAMETER OutputPath
  Output folder for reports and logs.

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Plan -BackupBucketName "my-veeam-backups" -BackupBucketRegion "us-east-1"
  # Dry-run: shows what would be created without making changes

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy -BackupBucketName "my-veeam-backups" -BackupBucketRegion "us-east-1" -TargetRegion "us-west-2"
  # Deploys full DR scaffolding in us-west-2 for backups stored in us-east-1

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy -BackupBucketName "prod-backups" -BackupBucketRegion "us-east-1" -BackupAccountId "123456789012"
  # Cross-account: builds DR environment with IAM role to access backups in another account

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy -BackupBucketName "my-backups" -BackupBucketRegion "us-east-1" -DeployVbrServer -KeyPairName "my-key"
  # Full deployment including a VBR server EC2 instance

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Validate -BackupBucketName "my-veeam-backups" -BackupBucketRegion "us-east-1"
  # Validates existing DR environment readiness

.EXAMPLE
  .\Start-VeeamS3DRAccelerator.ps1 -Mode Teardown -EnvironmentTag "VeeamDR" -TargetRegion "us-west-2"
  # Removes all DR resources tagged with "VeeamDR"

.NOTES
  Author: Veeam Sales Engineering
  Version: 1.0.0
  Date: 2026-02-15
  Requires: PowerShell 7.x or 5.1
  Modules: AWS.Tools.Common, AWS.Tools.EC2, AWS.Tools.S3, AWS.Tools.IdentityManagement,
           AWS.Tools.SecurityToken, AWS.Tools.KeyManagementService, AWS.Tools.CloudTrail
#>

[CmdletBinding()]
param(
  # Execution mode
  [Parameter(Mandatory=$true)]
  [ValidateSet("Plan", "Deploy", "Validate", "Teardown")]
  [string]$Mode,

  # Backup source
  [Parameter(Mandatory=$false)]
  [string]$BackupBucketName,

  [Parameter(Mandatory=$false)]
  [string]$BackupBucketRegion,

  [Parameter(Mandatory=$false)]
  [string]$TargetRegion,

  [Parameter(Mandatory=$false)]
  [string]$BackupAccountId,

  [Parameter(Mandatory=$false)]
  [string]$ExternalS3Endpoint,

  # VPC configuration
  [Parameter(Mandatory=$false)]
  [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
  [string]$VpcCidr = "10.200.0.0/16",

  [Parameter(Mandatory=$false)]
  [string]$EnvironmentTag = "VeeamDR",

  # Security options
  [Parameter(Mandatory=$false)]
  [bool]$EnableCloudTrail = $true,

  # Existing infrastructure
  [Parameter(Mandatory=$false)]
  [switch]$SkipVpcCreation,

  [Parameter(Mandatory=$false)]
  [string]$ExistingVpcId,

  [Parameter(Mandatory=$false)]
  [string]$ExistingSubnetId,

  # VBR server deployment
  [Parameter(Mandatory=$false)]
  [ValidateSet("t3.large", "t3.xlarge", "t3.2xlarge", "m5.xlarge", "m5.2xlarge", "r5.xlarge", "r5.2xlarge")]
  [string]$VbrInstanceType = "t3.xlarge",

  [Parameter(Mandatory=$false)]
  [switch]$DeployVbrServer,

  [Parameter(Mandatory=$false)]
  [string]$KeyPairName,

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/\d{1,2}$')]
  [string]$AllowedRdpCidr = "0.0.0.0/0",

  # Output
  [Parameter(Mandatory=$false)]
  [string]$OutputPath
)

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script-level variables
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:CreatedResources = New-Object System.Collections.Generic.List[object]
$script:ValidationResults = New-Object System.Collections.Generic.List[object]

# =============================
# Output folder structure
# =============================
if (-not $OutputPath) {
  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputPath = ".\VeeamS3DR_${Mode}_$timestamp"
}

if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$LogFile = Join-Path $OutputPath "execution_log.csv"
$outHtml = Join-Path $OutputPath "VeeamS3DR-Readiness-Report.html"
$outResources = Join-Path $OutputPath "created_resources.csv"
$outValidation = Join-Path $OutputPath "validation_results.csv"

#region Logging & Progress

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level = $Level
    Message = $Message
  }

  $script:LogEntries.Add($entry)

  $color = switch ($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default   { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Add-CreatedResource {
  param(
    [string]$ResourceType,
    [string]$ResourceId,
    [string]$ResourceName,
    [string]$Details
  )

  $script:CreatedResources.Add([PSCustomObject]@{
    ResourceType = $ResourceType
    ResourceId = $ResourceId
    ResourceName = $ResourceName
    Details = $Details
    CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
  })
}

function Add-ValidationResult {
  param(
    [string]$Check,
    [ValidateSet("PASS", "FAIL", "WARN", "SKIP")]
    [string]$Status,
    [string]$Details
  )

  $script:ValidationResults.Add([PSCustomObject]@{
    Check = $Check
    Status = $Status
    Details = $Details
  })
}

#endregion

#region Prerequisites Check

function Test-Prerequisites {
  Write-Log "Checking prerequisites..." -Level "INFO"

  # Check AWS PowerShell modules
  $requiredModules = @(
    'AWS.Tools.Common',
    'AWS.Tools.EC2',
    'AWS.Tools.S3',
    'AWS.Tools.IdentityManagement',
    'AWS.Tools.SecurityToken',
    'AWS.Tools.KeyManagementService',
    'AWS.Tools.CloudTrail'
  )

  $missingModules = @()
  foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
      $missingModules += $mod
    }
  }

  if ($missingModules.Count -gt 0) {
    Write-Log "Missing required AWS PowerShell modules:" -Level "ERROR"
    foreach ($mod in $missingModules) {
      Write-Log "  - $mod" -Level "ERROR"
    }
    Write-Host ""
    Write-Host "Install all AWS.Tools modules with:" -ForegroundColor Yellow
    Write-Host "  Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Or install the full AWS.Tools installer:" -ForegroundColor Yellow
    Write-Host "  Install-Module AWS.Tools.Installer -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host "  Install-AWSToolsModule $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    throw "Missing required AWS PowerShell modules. Install them and re-run."
  }

  Write-Log "All required AWS PowerShell modules found" -Level "SUCCESS"

  # Check AWS credentials
  try {
    $identity = Get-STSCallerIdentity -ErrorAction Stop
    Write-Log "AWS Identity: $($identity.Arn)" -Level "SUCCESS"
    Write-Log "AWS Account:  $($identity.Account)" -Level "INFO"
    $script:CurrentAccountId = $identity.Account
    $script:CurrentArn = $identity.Arn
  }
  catch {
    Write-Log "No valid AWS credentials found. Configure credentials first:" -Level "ERROR"
    Write-Host ""
    Write-Host "Option 1 - AWS CLI profile:" -ForegroundColor Yellow
    Write-Host "  aws configure --profile dr-account" -ForegroundColor Cyan
    Write-Host "  Set-AWSCredential -ProfileName dr-account" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Option 2 - Environment variables:" -ForegroundColor Yellow
    Write-Host '  $env:AWS_ACCESS_KEY_ID = "AKIA..."' -ForegroundColor Cyan
    Write-Host '  $env:AWS_SECRET_ACCESS_KEY = "..."' -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Option 3 - SSO:" -ForegroundColor Yellow
    Write-Host "  aws sso login --profile dr-account" -ForegroundColor Cyan
    Write-Host "  Set-AWSCredential -ProfileName dr-account" -ForegroundColor Cyan
    throw "AWS credentials not configured. See instructions above."
  }

  # Validate parameters based on mode
  if ($Mode -in @("Plan", "Deploy", "Validate")) {
    if (-not $BackupBucketName) {
      throw "BackupBucketName is required for $Mode mode."
    }
    if (-not $BackupBucketRegion) {
      throw "BackupBucketRegion is required for $Mode mode."
    }
  }

  # Set target region default
  if (-not $script:TargetRegion) {
    $script:TargetRegion = $BackupBucketRegion
    Write-Log "TargetRegion not specified, using BackupBucketRegion: $BackupBucketRegion" -Level "INFO"
  }
  else {
    $script:TargetRegion = $TargetRegion
  }

  # Validate VBR deployment params
  if ($DeployVbrServer -and -not $KeyPairName) {
    Write-Log "DeployVbrServer requires KeyPairName for RDP access" -Level "WARNING"
  }

  # Determine access scenario
  if ($ExternalS3Endpoint) {
    $script:AccessScenario = "ExternalS3"
    Write-Log "Access scenario: External S3-compatible storage" -Level "INFO"
  }
  elseif ($BackupAccountId -and $BackupAccountId -ne $script:CurrentAccountId) {
    $script:AccessScenario = "CrossAccount"
    Write-Log "Access scenario: Cross-account (backup in account $BackupAccountId)" -Level "INFO"
  }
  else {
    $script:AccessScenario = "SameAccount"
    Write-Log "Access scenario: Same-account access" -Level "INFO"
  }

  Write-Log "Prerequisites check passed" -Level "SUCCESS"
}

#endregion

#region VPC & Networking

function New-DRVpc {
  Write-Log "Creating DR VPC ($VpcCidr) in $($script:TargetRegion)..." -Level "INFO"

  # Create VPC
  $vpc = New-EC2Vpc -CidrBlock $VpcCidr -Region $script:TargetRegion
  $vpcId = $vpc.VpcId

  # Enable DNS support and hostnames
  Edit-EC2VpcAttribute -VpcId $vpcId -EnableDnsSupport $true -Region $script:TargetRegion
  Edit-EC2VpcAttribute -VpcId $vpcId -EnableDnsHostnames $true -Region $script:TargetRegion

  # Tag VPC
  $tag = @{ Key = "Name"; Value = "$EnvironmentTag-VPC" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }
  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  New-EC2Tag -Resource $vpcId -Tag $tag, $envTag, $managedTag -Region $script:TargetRegion

  Add-CreatedResource -ResourceType "VPC" -ResourceId $vpcId -ResourceName "$EnvironmentTag-VPC" -Details "CIDR: $VpcCidr"
  Write-Log "Created VPC: $vpcId" -Level "SUCCESS"

  $script:VpcId = $vpcId
  return $vpcId
}

function New-DRSubnets {
  param([string]$VpcId)

  Write-Log "Creating subnets in 2 availability zones..." -Level "INFO"

  # Get available AZs in the target region
  $azs = Get-EC2AvailabilityZone -Region $script:TargetRegion -Filter @{ Name = "state"; Values = "available" }
  $az1 = $azs[0].ZoneName
  $az2 = $azs[1].ZoneName

  # Parse VPC CIDR to derive subnet CIDRs
  $cidrBase = $VpcCidr.Split('/')[0]
  $octets = $cidrBase.Split('.')

  # Public subnets  (/24 each)
  $pubSubnet1Cidr = "$($octets[0]).$($octets[1]).1.0/24"
  $pubSubnet2Cidr = "$($octets[0]).$($octets[1]).2.0/24"

  # Private subnets (/24 each)
  $privSubnet1Cidr = "$($octets[0]).$($octets[1]).10.0/24"
  $privSubnet2Cidr = "$($octets[0]).$($octets[1]).11.0/24"

  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }

  # Create public subnets
  $pubSn1 = New-EC2Subnet -VpcId $VpcId -CidrBlock $pubSubnet1Cidr -AvailabilityZone $az1 -Region $script:TargetRegion
  New-EC2Tag -Resource $pubSn1.SubnetId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Public-$az1" }, $envTag, $managedTag -Region $script:TargetRegion
  Edit-EC2SubnetAttribute -SubnetId $pubSn1.SubnetId -MapPublicIpOnLaunch $true -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "Subnet" -ResourceId $pubSn1.SubnetId -ResourceName "$EnvironmentTag-Public-$az1" -Details "Public, CIDR: $pubSubnet1Cidr"

  $pubSn2 = New-EC2Subnet -VpcId $VpcId -CidrBlock $pubSubnet2Cidr -AvailabilityZone $az2 -Region $script:TargetRegion
  New-EC2Tag -Resource $pubSn2.SubnetId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Public-$az2" }, $envTag, $managedTag -Region $script:TargetRegion
  Edit-EC2SubnetAttribute -SubnetId $pubSn2.SubnetId -MapPublicIpOnLaunch $true -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "Subnet" -ResourceId $pubSn2.SubnetId -ResourceName "$EnvironmentTag-Public-$az2" -Details "Public, CIDR: $pubSubnet2Cidr"

  # Create private subnets
  $privSn1 = New-EC2Subnet -VpcId $VpcId -CidrBlock $privSubnet1Cidr -AvailabilityZone $az1 -Region $script:TargetRegion
  New-EC2Tag -Resource $privSn1.SubnetId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Private-$az1" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "Subnet" -ResourceId $privSn1.SubnetId -ResourceName "$EnvironmentTag-Private-$az1" -Details "Private, CIDR: $privSubnet1Cidr"

  $privSn2 = New-EC2Subnet -VpcId $VpcId -CidrBlock $privSubnet2Cidr -AvailabilityZone $az2 -Region $script:TargetRegion
  New-EC2Tag -Resource $privSn2.SubnetId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Private-$az2" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "Subnet" -ResourceId $privSn2.SubnetId -ResourceName "$EnvironmentTag-Private-$az2" -Details "Private, CIDR: $privSubnet2Cidr"

  Write-Log "Created 4 subnets (2 public, 2 private) across $az1 and $az2" -Level "SUCCESS"

  $script:PublicSubnet1  = $pubSn1.SubnetId
  $script:PublicSubnet2  = $pubSn2.SubnetId
  $script:PrivateSubnet1 = $privSn1.SubnetId
  $script:PrivateSubnet2 = $privSn2.SubnetId

  return @{
    Public  = @($pubSn1.SubnetId, $pubSn2.SubnetId)
    Private = @($privSn1.SubnetId, $privSn2.SubnetId)
    AZ1 = $az1
    AZ2 = $az2
  }
}

function New-DRGateways {
  param([string]$VpcId)

  Write-Log "Creating Internet Gateway and NAT Gateway..." -Level "INFO"

  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }

  # Internet Gateway
  $igw = New-EC2InternetGateway -Region $script:TargetRegion
  Add-EC2InternetGateway -InternetGatewayId $igw.InternetGatewayId -VpcId $VpcId -Region $script:TargetRegion
  New-EC2Tag -Resource $igw.InternetGatewayId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-IGW" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "InternetGateway" -ResourceId $igw.InternetGatewayId -ResourceName "$EnvironmentTag-IGW" -Details "Attached to VPC $VpcId"
  Write-Log "Created Internet Gateway: $($igw.InternetGatewayId)" -Level "SUCCESS"

  # Elastic IP for NAT Gateway
  $eip = New-EC2Address -Domain vpc -Region $script:TargetRegion
  New-EC2Tag -Resource $eip.AllocationId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-NAT-EIP" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "ElasticIP" -ResourceId $eip.AllocationId -ResourceName "$EnvironmentTag-NAT-EIP" -Details "Public IP: $($eip.PublicIp)"

  # NAT Gateway (in first public subnet)
  $nat = New-EC2NatGateway -SubnetId $script:PublicSubnet1 -AllocationId $eip.AllocationId -Region $script:TargetRegion
  $natId = $nat.NatGateway.NatGatewayId

  # Wait for NAT Gateway to become available
  Write-Log "Waiting for NAT Gateway to become available..." -Level "INFO"
  $maxWait = 120
  $waited = 0
  do {
    Start-Sleep -Seconds 10
    $waited += 10
    $natStatus = (Get-EC2NatGateway -NatGatewayId $natId -Region $script:TargetRegion).State
  } while ($natStatus -ne "Available" -and $waited -lt $maxWait)

  if ($natStatus -ne "Available") {
    Write-Log "NAT Gateway still pending after ${maxWait}s - continuing (it will become available shortly)" -Level "WARNING"
  }

  New-EC2Tag -Resource $natId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-NAT" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "NATGateway" -ResourceId $natId -ResourceName "$EnvironmentTag-NAT" -Details "In subnet $($script:PublicSubnet1)"
  Write-Log "Created NAT Gateway: $natId" -Level "SUCCESS"

  $script:InternetGatewayId = $igw.InternetGatewayId
  $script:NatGatewayId = $natId

  return @{
    InternetGatewayId = $igw.InternetGatewayId
    NatGatewayId = $natId
    ElasticIpAllocationId = $eip.AllocationId
  }
}

function New-DRRouteTables {
  param([string]$VpcId)

  Write-Log "Creating route tables..." -Level "INFO"

  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }

  # Public route table (routes to Internet Gateway)
  $pubRt = New-EC2RouteTable -VpcId $VpcId -Region $script:TargetRegion
  New-EC2Tag -Resource $pubRt.RouteTableId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Public-RT" }, $envTag, $managedTag -Region $script:TargetRegion
  New-EC2Route -RouteTableId $pubRt.RouteTableId -DestinationCidrBlock "0.0.0.0/0" -GatewayId $script:InternetGatewayId -Region $script:TargetRegion | Out-Null

  # Associate public subnets
  Register-EC2RouteTable -RouteTableId $pubRt.RouteTableId -SubnetId $script:PublicSubnet1 -Region $script:TargetRegion | Out-Null
  Register-EC2RouteTable -RouteTableId $pubRt.RouteTableId -SubnetId $script:PublicSubnet2 -Region $script:TargetRegion | Out-Null
  Add-CreatedResource -ResourceType "RouteTable" -ResourceId $pubRt.RouteTableId -ResourceName "$EnvironmentTag-Public-RT" -Details "Default route to IGW"

  # Private route table (routes to NAT Gateway)
  $privRt = New-EC2RouteTable -VpcId $VpcId -Region $script:TargetRegion
  New-EC2Tag -Resource $privRt.RouteTableId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Private-RT" }, $envTag, $managedTag -Region $script:TargetRegion
  New-EC2Route -RouteTableId $privRt.RouteTableId -DestinationCidrBlock "0.0.0.0/0" -NatGatewayId $script:NatGatewayId -Region $script:TargetRegion | Out-Null

  # Associate private subnets
  Register-EC2RouteTable -RouteTableId $privRt.RouteTableId -SubnetId $script:PrivateSubnet1 -Region $script:TargetRegion | Out-Null
  Register-EC2RouteTable -RouteTableId $privRt.RouteTableId -SubnetId $script:PrivateSubnet2 -Region $script:TargetRegion | Out-Null
  Add-CreatedResource -ResourceType "RouteTable" -ResourceId $privRt.RouteTableId -ResourceName "$EnvironmentTag-Private-RT" -Details "Default route to NAT GW"

  Write-Log "Created route tables (public + private)" -Level "SUCCESS"

  $script:PublicRouteTableId = $pubRt.RouteTableId
  $script:PrivateRouteTableId = $privRt.RouteTableId

  return @{
    PublicRouteTableId  = $pubRt.RouteTableId
    PrivateRouteTableId = $privRt.RouteTableId
  }
}

function New-DRS3VpcEndpoint {
  param([string]$VpcId)

  Write-Log "Creating S3 Gateway VPC Endpoint (private S3 access, zero egress cost)..." -Level "INFO"

  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }

  $vpce = New-EC2VpcEndpoint `
    -VpcId $VpcId `
    -ServiceName "com.amazonaws.$($script:TargetRegion).s3" `
    -VpcEndpointType Gateway `
    -RouteTableId @($script:PublicRouteTableId, $script:PrivateRouteTableId) `
    -Region $script:TargetRegion

  $vpceId = $vpce.VpcEndpoint.VpcEndpointId
  New-EC2Tag -Resource $vpceId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-S3-Endpoint" }, $envTag, $managedTag -Region $script:TargetRegion
  Add-CreatedResource -ResourceType "VPCEndpoint" -ResourceId $vpceId -ResourceName "$EnvironmentTag-S3-Endpoint" -Details "S3 Gateway endpoint (zero egress cost)"

  Write-Log "Created S3 VPC Endpoint: $vpceId" -Level "SUCCESS"
  return $vpceId
}

#endregion

#region Security Groups

function New-DRSecurityGroups {
  param([string]$VpcId)

  Write-Log "Creating security groups for Veeam components..." -Level "INFO"

  $managedTag = @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" }
  $envTag = @{ Key = "Environment"; Value = $EnvironmentTag }

  # VBR Server security group
  $vbrSgId = New-EC2SecurityGroup `
    -GroupName "$EnvironmentTag-VBR-Server" `
    -GroupDescription "Veeam Backup & Replication Server - DR Accelerator" `
    -VpcId $VpcId `
    -Region $script:TargetRegion

  New-EC2Tag -Resource $vbrSgId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-VBR-Server-SG" }, $envTag, $managedTag -Region $script:TargetRegion

  # RDP access (restricted)
  $rdpPermission = @{
    IpProtocol = "tcp"
    FromPort = 3389
    ToPort = 3389
    IpRanges = @(@{ CidrIp = $AllowedRdpCidr; Description = "RDP access for VBR management" })
  }
  Grant-EC2SecurityGroupIngress -GroupId $vbrSgId -IpPermission $rdpPermission -Region $script:TargetRegion

  # HTTPS for VBR console (port 9443)
  $consolePermission = @{
    IpProtocol = "tcp"
    FromPort = 9443
    ToPort = 9443
    IpRanges = @(@{ CidrIp = $AllowedRdpCidr; Description = "Veeam B&R web console" })
  }
  Grant-EC2SecurityGroupIngress -GroupId $vbrSgId -IpPermission $consolePermission -Region $script:TargetRegion

  Add-CreatedResource -ResourceType "SecurityGroup" -ResourceId $vbrSgId -ResourceName "$EnvironmentTag-VBR-Server-SG" -Details "RDP ($AllowedRdpCidr), Console 9443"

  if ($AllowedRdpCidr -eq "0.0.0.0/0") {
    Write-Log "WARNING: RDP is open to 0.0.0.0/0 - restrict AllowedRdpCidr in production!" -Level "WARNING"
  }

  # Veeam Proxy security group
  $proxySgId = New-EC2SecurityGroup `
    -GroupName "$EnvironmentTag-VBR-Proxy" `
    -GroupDescription "Veeam Backup Proxy - DR Accelerator" `
    -VpcId $VpcId `
    -Region $script:TargetRegion

  New-EC2Tag -Resource $proxySgId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-VBR-Proxy-SG" }, $envTag, $managedTag -Region $script:TargetRegion

  # Allow VBR server to communicate with proxies (Veeam data mover ports)
  $vbrToProxyPermission = @{
    IpProtocol = "tcp"
    FromPort = 2500
    ToPort = 3300
    UserIdGroupPairs = @(@{ GroupId = $vbrSgId; Description = "Veeam data mover from VBR server" })
  }
  Grant-EC2SecurityGroupIngress -GroupId $proxySgId -IpPermission $vbrToProxyPermission -Region $script:TargetRegion

  Add-CreatedResource -ResourceType "SecurityGroup" -ResourceId $proxySgId -ResourceName "$EnvironmentTag-VBR-Proxy-SG" -Details "Data mover ports 2500-3300 from VBR SG"

  # Restored workloads security group (minimal - customer customizes)
  $workloadSgId = New-EC2SecurityGroup `
    -GroupName "$EnvironmentTag-Restored-Workloads" `
    -GroupDescription "Restored workloads - DR Accelerator (customize as needed)" `
    -VpcId $VpcId `
    -Region $script:TargetRegion

  New-EC2Tag -Resource $workloadSgId -Tag @{ Key = "Name"; Value = "$EnvironmentTag-Workloads-SG" }, $envTag, $managedTag -Region $script:TargetRegion

  # Allow all internal VPC traffic for restored workloads
  $internalPermission = @{
    IpProtocol = "-1"
    IpRanges = @(@{ CidrIp = $VpcCidr; Description = "Internal VPC communication" })
  }
  Grant-EC2SecurityGroupIngress -GroupId $workloadSgId -IpPermission $internalPermission -Region $script:TargetRegion

  Add-CreatedResource -ResourceType "SecurityGroup" -ResourceId $workloadSgId -ResourceName "$EnvironmentTag-Workloads-SG" -Details "Internal VPC traffic only (customize post-restore)"

  Write-Log "Created 3 security groups (VBR server, proxy, workloads)" -Level "SUCCESS"

  $script:VbrSecurityGroupId = $vbrSgId
  $script:ProxySecurityGroupId = $proxySgId
  $script:WorkloadSecurityGroupId = $workloadSgId

  return @{
    VbrServerSG  = $vbrSgId
    ProxySG      = $proxySgId
    WorkloadsSG  = $workloadSgId
  }
}

#endregion

#region IAM Configuration

function New-DRIAMRoles {
  Write-Log "Creating IAM roles and policies for Veeam restore operations..." -Level "INFO"

  # Trust policy for EC2 (VBR server instance profile)
  $ec2TrustPolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Effect = "Allow"
        Principal = @{ Service = "ec2.amazonaws.com" }
        Action = "sts:AssumeRole"
      }
    )
  } | ConvertTo-Json -Depth 10

  # --- VBR Server Role (attached to EC2 instance) ---
  $vbrRoleName = "$EnvironmentTag-VBR-Server-Role"
  try {
    $vbrRole = New-IAMRole `
      -RoleName $vbrRoleName `
      -AssumeRolePolicyDocument $ec2TrustPolicy `
      -Description "Veeam B&R server role for DR restore operations" `
      -Tag @(@{ Key = "Environment"; Value = $EnvironmentTag }, @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" })

    Write-Log "Created IAM role: $vbrRoleName" -Level "SUCCESS"
  }
  catch {
    if ($_.Exception.Message -match "EntityAlreadyExists") {
      Write-Log "IAM role $vbrRoleName already exists, skipping creation" -Level "WARNING"
      $vbrRole = Get-IAMRole -RoleName $vbrRoleName
    }
    else { throw }
  }

  # S3 read policy for backup bucket access
  $s3PolicyName = "$EnvironmentTag-S3-BackupAccess"
  $s3ReadPolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "ListBackupBucket"
        Effect = "Allow"
        Action = @(
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:GetBucketVersioning"
        )
        Resource = "arn:aws:s3:::$BackupBucketName"
      },
      @{
        Sid = "ReadBackupObjects"
        Effect = "Allow"
        Action = @(
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging",
          "s3:ListMultipartUploadParts"
        )
        Resource = "arn:aws:s3:::$BackupBucketName/*"
      }
    )
  } | ConvertTo-Json -Depth 10

  try {
    Write-IAMRolePolicy -RoleName $vbrRoleName -PolicyName $s3PolicyName -PolicyDocument $s3ReadPolicy
    Write-Log "Attached S3 backup read policy to $vbrRoleName" -Level "SUCCESS"
  }
  catch {
    Write-Log "Failed to attach S3 policy: $($_.Exception.Message)" -Level "ERROR"
    throw
  }

  # EC2 restore operations policy (create/manage EC2 instances during restore)
  $ec2PolicyName = "$EnvironmentTag-EC2-RestoreOps"
  $ec2RestorePolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "EC2RestoreOperations"
        Effect = "Allow"
        Action = @(
          "ec2:RunInstances",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:CreateTags",
          "ec2:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeSnapshots",
          "ec2:CreateSnapshot",
          "ec2:CreateVolume",
          "ec2:AttachVolume",
          "ec2:DetachVolume",
          "ec2:DeleteVolume",
          "ec2:DescribeVolumes",
          "ec2:ModifyInstanceAttribute",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeVpcs",
          "ec2:DescribeKeyPairs",
          "ec2:DescribeAvailabilityZones",
          "ec2:RegisterImage",
          "ec2:DeregisterImage",
          "ec2:ImportSnapshot",
          "ec2:DescribeImportSnapshotTasks",
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses"
        )
        Resource = "*"
        Condition = @{
          StringEquals = @{
            "aws:RequestedRegion" = $script:TargetRegion
          }
        }
      },
      @{
        Sid = "PassRoleForEC2"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = $vbrRole.Arn
      }
    )
  } | ConvertTo-Json -Depth 10

  Write-IAMRolePolicy -RoleName $vbrRoleName -PolicyName $ec2PolicyName -PolicyDocument $ec2RestorePolicy
  Write-Log "Attached EC2 restore operations policy to $vbrRoleName" -Level "SUCCESS"

  # KMS policy for encrypted volumes
  $kmsInlinePolicyName = "$EnvironmentTag-KMS-Access"
  $kmsInlinePolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "KMSForRestoreEncryption"
        Effect = "Allow"
        Action = @(
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        )
        Resource = "*"
        Condition = @{
          StringEquals = @{
            "aws:ResourceTag/Environment" = $EnvironmentTag
          }
        }
      }
    )
  } | ConvertTo-Json -Depth 10

  Write-IAMRolePolicy -RoleName $vbrRoleName -PolicyName $kmsInlinePolicyName -PolicyDocument $kmsInlinePolicy
  Write-Log "Attached KMS encryption policy to $vbrRoleName" -Level "SUCCESS"

  # Create instance profile
  $instanceProfileName = "$EnvironmentTag-VBR-InstanceProfile"
  try {
    $instanceProfile = New-IAMInstanceProfile -InstanceProfileName $instanceProfileName
    Add-IAMRoleToInstanceProfile -InstanceProfileName $instanceProfileName -RoleName $vbrRoleName

    # Wait for instance profile propagation
    Start-Sleep -Seconds 10
    Write-Log "Created instance profile: $instanceProfileName" -Level "SUCCESS"
  }
  catch {
    if ($_.Exception.Message -match "EntityAlreadyExists") {
      Write-Log "Instance profile $instanceProfileName already exists, skipping" -Level "WARNING"
      $instanceProfile = Get-IAMInstanceProfile -InstanceProfileName $instanceProfileName
    }
    else { throw }
  }

  Add-CreatedResource -ResourceType "IAMRole" -ResourceId $vbrRole.Arn -ResourceName $vbrRoleName -Details "VBR server role with S3, EC2, KMS policies"
  Add-CreatedResource -ResourceType "IAMInstanceProfile" -ResourceId $instanceProfile.Arn -ResourceName $instanceProfileName -Details "Attached to $vbrRoleName"

  $script:VbrRoleName = $vbrRoleName
  $script:VbrRoleArn = $vbrRole.Arn
  $script:InstanceProfileName = $instanceProfileName

  return @{
    RoleName = $vbrRoleName
    RoleArn = $vbrRole.Arn
    InstanceProfileName = $instanceProfileName
  }
}

function New-DRCrossAccountRole {
  Write-Log "Configuring cross-account access to backup bucket in account $BackupAccountId..." -Level "INFO"

  # This role lives in the CURRENT (DR) account and is assumed by the VBR server.
  # The backup account needs a corresponding bucket policy or role trust.
  # We create the policy document that the customer must apply in the source account.

  $crossAccountPolicyName = "$EnvironmentTag-CrossAccount-S3Access"
  $crossAccountPolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "AssumeRoleInBackupAccount"
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = "arn:aws:iam::${BackupAccountId}:role/$EnvironmentTag-BackupBucketAccess"
      }
    )
  } | ConvertTo-Json -Depth 10

  Write-IAMRolePolicy -RoleName $script:VbrRoleName -PolicyName $crossAccountPolicyName -PolicyDocument $crossAccountPolicy
  Write-Log "Attached cross-account assume-role policy to $($script:VbrRoleName)" -Level "SUCCESS"

  # Generate the bucket policy/role that needs to be created in the SOURCE account
  $sourceAccountRolePolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Effect = "Allow"
        Principal = @{ AWS = "arn:aws:iam::$($script:CurrentAccountId):role/$($script:VbrRoleName)" }
        Action = "sts:AssumeRole"
      }
    )
  } | ConvertTo-Json -Depth 10

  $sourceAccountS3Policy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "AllowDRAccountReadAccess"
        Effect = "Allow"
        Action = @(
          "s3:ListBucket",
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetBucketLocation"
        )
        Resource = @(
          "arn:aws:s3:::$BackupBucketName",
          "arn:aws:s3:::$BackupBucketName/*"
        )
      }
    )
  } | ConvertTo-Json -Depth 10

  # Save cross-account setup instructions
  $crossAccountInstructions = @"
# ============================================================
# CROSS-ACCOUNT SETUP INSTRUCTIONS
# ============================================================
# These steps must be performed in the SOURCE/BACKUP account ($BackupAccountId)
# to allow the DR account ($($script:CurrentAccountId)) to read backup data.
#
# OPTION A: Create an IAM Role in the source account
# ----------------------------------------------------------

# 1. Create the role with this trust policy:
`$trustPolicy = @'
$sourceAccountRolePolicy
'@

New-IAMRole -RoleName "$EnvironmentTag-BackupBucketAccess" ``
  -AssumeRolePolicyDocument `$trustPolicy ``
  -Description "Allow DR account to read Veeam backups"

# 2. Attach this S3 access policy to the role:
`$s3Policy = @'
$sourceAccountS3Policy
'@

Write-IAMRolePolicy -RoleName "$EnvironmentTag-BackupBucketAccess" ``
  -PolicyName "$EnvironmentTag-S3Read" ``
  -PolicyDocument `$s3Policy

# OPTION B: Add a Bucket Policy (simpler, less flexible)
# ----------------------------------------------------------
# Add this statement to the bucket policy on s3://$BackupBucketName:
#
# {
#   "Sid": "AllowDRAccountAccess",
#   "Effect": "Allow",
#   "Principal": { "AWS": "arn:aws:iam::$($script:CurrentAccountId):root" },
#   "Action": ["s3:ListBucket", "s3:GetObject", "s3:GetObjectVersion"],
#   "Resource": [
#     "arn:aws:s3:::$BackupBucketName",
#     "arn:aws:s3:::$BackupBucketName/*"
#   ]
# }
# ============================================================
"@

  $crossAccountFile = Join-Path $OutputPath "cross_account_setup.ps1"
  $crossAccountInstructions | Out-File -FilePath $crossAccountFile -Encoding UTF8
  Write-Log "Cross-account setup instructions saved to: $crossAccountFile" -Level "SUCCESS"
  Write-Log "IMPORTANT: The source account admin must run the cross-account setup script" -Level "WARNING"

  Add-CreatedResource -ResourceType "IAMPolicy" -ResourceId "inline" -ResourceName $crossAccountPolicyName -Details "Cross-account assume role to $BackupAccountId"

  return @{
    CrossAccountPolicyName = $crossAccountPolicyName
    SetupScriptPath = $crossAccountFile
  }
}

#endregion

#region KMS & Security

function New-DRKmsKey {
  Write-Log "Creating KMS key for DR encryption..." -Level "INFO"

  $keyPolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "EnableRootAccountAccess"
        Effect = "Allow"
        Principal = @{ AWS = "arn:aws:iam::$($script:CurrentAccountId):root" }
        Action = "kms:*"
        Resource = "*"
      },
      @{
        Sid = "AllowVBRServerKeyUsage"
        Effect = "Allow"
        Principal = @{ AWS = $script:VbrRoleArn }
        Action = @(
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:CreateGrant"
        )
        Resource = "*"
      }
    )
  } | ConvertTo-Json -Depth 10

  $key = New-KMSKey `
    -Description "Veeam DR Accelerator - encryption for restored volumes and snapshots" `
    -KeyUsage ENCRYPT_DECRYPT `
    -Origin AWS_KMS `
    -Policy $keyPolicy `
    -Tag @(@{ TagKey = "Environment"; TagValue = $EnvironmentTag }, @{ TagKey = "ManagedBy"; TagValue = "VeeamS3DRAccelerator" }) `
    -Region $script:TargetRegion

  # Create alias for easy reference
  $aliasName = "alias/$EnvironmentTag-restore-key"
  New-KMSAlias -AliasName $aliasName -TargetKeyId $key.KeyId -Region $script:TargetRegion

  Add-CreatedResource -ResourceType "KMSKey" -ResourceId $key.KeyId -ResourceName $aliasName -Details "AES-256 encryption for restored volumes"
  Write-Log "Created KMS key: $($key.KeyId) (alias: $aliasName)" -Level "SUCCESS"

  $script:KmsKeyId = $key.KeyId
  $script:KmsKeyArn = $key.Arn

  return @{
    KeyId = $key.KeyId
    KeyArn = $key.Arn
    Alias = $aliasName
  }
}

function New-DRCloudTrail {
  Write-Log "Enabling CloudTrail for DR operations audit logging..." -Level "INFO"

  # Create CloudTrail logging bucket
  $trailBucketName = "$($EnvironmentTag.ToLower())-cloudtrail-$($script:CurrentAccountId)-$(Get-Date -Format 'yyyyMMdd')"

  try {
    if ($script:TargetRegion -eq "us-east-1") {
      New-S3Bucket -BucketName $trailBucketName -Region $script:TargetRegion
    }
    else {
      New-S3Bucket -BucketName $trailBucketName -Region $script:TargetRegion -CreateBucketConfiguration_LocationConstraint $script:TargetRegion
    }
  }
  catch {
    if ($_.Exception.Message -match "BucketAlreadyOwnedByYou") {
      Write-Log "CloudTrail bucket already exists, reusing" -Level "WARNING"
    }
    else { throw }
  }

  # Block public access on CloudTrail bucket
  Write-S3PublicAccessBlock -BucketName $trailBucketName -PublicAccessBlockConfiguration_BlockPublicAcls $true `
    -PublicAccessBlockConfiguration_BlockPublicPolicy $true `
    -PublicAccessBlockConfiguration_IgnorePublicAcls $true `
    -PublicAccessBlockConfiguration_RestrictPublicBuckets $true `
    -Region $script:TargetRegion

  # Bucket policy for CloudTrail
  $trailBucketPolicy = @{
    Version = "2012-10-17"
    Statement = @(
      @{
        Sid = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = @{ Service = "cloudtrail.amazonaws.com" }
        Action = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::$trailBucketName"
      },
      @{
        Sid = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = @{ Service = "cloudtrail.amazonaws.com" }
        Action = "s3:PutObject"
        Resource = "arn:aws:s3:::$trailBucketName/AWSLogs/$($script:CurrentAccountId)/*"
        Condition = @{
          StringEquals = @{
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    )
  } | ConvertTo-Json -Depth 10

  Write-S3BucketPolicy -BucketName $trailBucketName -Policy $trailBucketPolicy -Region $script:TargetRegion

  # Create trail
  $trailName = "$EnvironmentTag-DR-Trail"
  try {
    New-CTTrail `
      -Name $trailName `
      -S3BucketName $trailBucketName `
      -IsMultiRegionTrail $false `
      -EnableLogFileValidation $true `
      -Region $script:TargetRegion

    Start-CTLogging -Name $trailName -Region $script:TargetRegion
    Write-Log "Created and started CloudTrail: $trailName" -Level "SUCCESS"
  }
  catch {
    if ($_.Exception.Message -match "TrailAlreadyExists") {
      Write-Log "CloudTrail $trailName already exists" -Level "WARNING"
    }
    else { throw }
  }

  Add-CreatedResource -ResourceType "S3Bucket" -ResourceId $trailBucketName -ResourceName $trailBucketName -Details "CloudTrail log storage"
  Add-CreatedResource -ResourceType "CloudTrail" -ResourceId $trailName -ResourceName $trailName -Details "DR operations audit logging"

  return @{
    TrailName = $trailName
    LogBucket = $trailBucketName
  }
}

#endregion

#region VBR Server Deployment

function New-DRVbrServer {
  Write-Log "Deploying Veeam Backup & Replication server instance..." -Level "INFO"

  # Find latest Windows Server 2022 AMI
  $amiFilter = @(
    @{ Name = "name"; Values = "Windows_Server-2022-English-Full-Base-*" },
    @{ Name = "state"; Values = "available" },
    @{ Name = "architecture"; Values = "x86_64" }
  )

  $amis = Get-EC2Image -Owner "amazon" -Filter $amiFilter -Region $script:TargetRegion |
    Sort-Object -Property CreationDate -Descending |
    Select-Object -First 1

  if (-not $amis) {
    Write-Log "Could not find Windows Server 2022 AMI in $($script:TargetRegion)" -Level "ERROR"
    Write-Log "VBR server deployment skipped - deploy manually using your preferred AMI" -Level "WARNING"
    return $null
  }

  $amiId = $amis.ImageId
  Write-Log "Using AMI: $amiId ($($amis.Name))" -Level "INFO"

  # User data script to prepare the instance
  $userData = @"
<powershell>
# Veeam DR Accelerator - VBR Server Bootstrap
# This script prepares the Windows Server for Veeam B&R installation

# Set timezone and hostname
Set-TimeZone -Id "UTC"
Rename-Computer -NewName "VEEAM-DR-VBR" -Force

# Enable WinRM for remote management
Enable-PSRemoting -Force -SkipNetworkProfileCheck
Set-Item WSMan:\localhost\Client\TrustedHosts -Value "*" -Force

# Install NuGet provider and AWS tools
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name AWS.Tools.Installer -Force -Scope AllUsers
Install-AWSToolsModule AWS.Tools.S3, AWS.Tools.EC2 -Force -Scope AllUsers

# Create marker file for bootstrap completion
New-Item -Path "C:\VeeamDR\bootstrap_complete.txt" -ItemType File -Force
Set-Content -Path "C:\VeeamDR\bootstrap_complete.txt" -Value "Bootstrap completed at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC')"
Set-Content -Path "C:\VeeamDR\restore_config.txt" -Value @"

Veeam S3 DR Accelerator - Restore Configuration
=================================================
Backup Bucket:     $BackupBucketName
Bucket Region:     $BackupBucketRegion
Access Scenario:   $($script:AccessScenario)
KMS Key ID:        $($script:KmsKeyId)
Environment Tag:   $EnvironmentTag

Next Steps:
1. Install Veeam Backup & Replication (download from veeam.com)
2. Add S3 object storage repository pointing to: $BackupBucketName
3. Import backups from the repository
4. Begin restore operations

"@

# Schedule restart to apply hostname change
Restart-Computer -Force -Delay 30
</powershell>
"@

  $userDataBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))

  # Launch instance
  $instanceParams = @{
    ImageId = $amiId
    InstanceType = $VbrInstanceType
    SubnetId = $script:PublicSubnet1
    SecurityGroupId = $script:VbrSecurityGroupId
    IamInstanceProfile_Name = $script:InstanceProfileName
    UserData = $userDataBase64
    BlockDeviceMapping = @(
      @{
        DeviceName = "/dev/sda1"
        Ebs = @{
          VolumeSize = 100
          VolumeType = "gp3"
          Encrypted = $true
          KmsKeyId = $script:KmsKeyId
          DeleteOnTermination = $true
        }
      },
      @{
        DeviceName = "xvdf"
        Ebs = @{
          VolumeSize = 200
          VolumeType = "gp3"
          Encrypted = $true
          KmsKeyId = $script:KmsKeyId
          DeleteOnTermination = $true
          Iops = 3000
          Throughput = 250
        }
      }
    )
    TagSpecification = @(
      @{
        ResourceType = "instance"
        Tags = @(
          @{ Key = "Name"; Value = "$EnvironmentTag-VBR-Server" },
          @{ Key = "Environment"; Value = $EnvironmentTag },
          @{ Key = "ManagedBy"; Value = "VeeamS3DRAccelerator" },
          @{ Key = "Role"; Value = "VeeamBackupServer" }
        )
      }
    )
    Region = $script:TargetRegion
  }

  if ($KeyPairName) {
    $instanceParams.KeyName = $KeyPairName
  }

  $instance = New-EC2Instance @instanceParams
  $instanceId = $instance.Instances[0].InstanceId

  Write-Log "Launched VBR server instance: $instanceId" -Level "SUCCESS"
  Write-Log "Instance type: $VbrInstanceType, OS disk: 100 GB, Data disk: 200 GB (both encrypted)" -Level "INFO"

  # Wait for instance to be running
  Write-Log "Waiting for instance to enter running state..." -Level "INFO"
  $maxWait = 180
  $waited = 0
  do {
    Start-Sleep -Seconds 15
    $waited += 15
    $status = (Get-EC2Instance -InstanceId $instanceId -Region $script:TargetRegion).Instances[0].State.Name
  } while ($status -ne "running" -and $waited -lt $maxWait)

  if ($status -eq "running") {
    $instanceDetails = (Get-EC2Instance -InstanceId $instanceId -Region $script:TargetRegion).Instances[0]
    $publicIp = $instanceDetails.PublicIpAddress
    $privateIp = $instanceDetails.PrivateIpAddress
    Write-Log "VBR server is running - Public IP: $publicIp, Private IP: $privateIp" -Level "SUCCESS"
  }
  else {
    Write-Log "Instance still starting after ${maxWait}s - check AWS console for status" -Level "WARNING"
    $publicIp = "pending"
    $privateIp = "pending"
  }

  Add-CreatedResource -ResourceType "EC2Instance" -ResourceId $instanceId -ResourceName "$EnvironmentTag-VBR-Server" -Details "Type: $VbrInstanceType, IP: $publicIp"

  $script:VbrInstanceId = $instanceId
  $script:VbrPublicIp = $publicIp
  $script:VbrPrivateIp = $privateIp

  return @{
    InstanceId = $instanceId
    PublicIp = $publicIp
    PrivateIp = $privateIp
    AmiId = $amiId
  }
}

#endregion

#region Validation

function Test-DRReadiness {
  Write-Log "Running DR environment readiness validation..." -Level "INFO"

  # 1. VPC validation
  Write-Log "Validating VPC configuration..." -Level "INFO"
  try {
    $vpcs = Get-EC2Vpc -Filter @{ Name = "tag:Environment"; Values = $EnvironmentTag } -Region $script:TargetRegion
    if ($vpcs) {
      Add-ValidationResult -Check "VPC exists" -Status "PASS" -Details "VPC: $($vpcs[0].VpcId), CIDR: $($vpcs[0].CidrBlock)"
      $validationVpcId = $vpcs[0].VpcId
    }
    else {
      Add-ValidationResult -Check "VPC exists" -Status "FAIL" -Details "No VPC found with tag Environment=$EnvironmentTag"
      $validationVpcId = $null
    }
  }
  catch {
    Add-ValidationResult -Check "VPC exists" -Status "FAIL" -Details $_.Exception.Message
    $validationVpcId = $null
  }

  # 2. Subnet validation
  if ($validationVpcId) {
    try {
      $subnets = Get-EC2Subnet -Filter @{ Name = "vpc-id"; Values = $validationVpcId } -Region $script:TargetRegion
      $publicSubnets = $subnets | Where-Object { $_.MapPublicIpOnLaunch -eq $true }
      $privateSubnets = $subnets | Where-Object { $_.MapPublicIpOnLaunch -ne $true }

      if ($publicSubnets.Count -ge 2 -and $privateSubnets.Count -ge 2) {
        Add-ValidationResult -Check "Subnets (2 public + 2 private)" -Status "PASS" -Details "$($publicSubnets.Count) public, $($privateSubnets.Count) private subnets"
      }
      else {
        Add-ValidationResult -Check "Subnets (2 public + 2 private)" -Status "WARN" -Details "$($publicSubnets.Count) public, $($privateSubnets.Count) private subnets (recommend 2+2)"
      }
    }
    catch {
      Add-ValidationResult -Check "Subnets" -Status "FAIL" -Details $_.Exception.Message
    }
  }

  # 3. Internet connectivity
  if ($validationVpcId) {
    try {
      $igws = Get-EC2InternetGateway -Filter @{ Name = "attachment.vpc-id"; Values = $validationVpcId } -Region $script:TargetRegion
      if ($igws) {
        Add-ValidationResult -Check "Internet Gateway attached" -Status "PASS" -Details "IGW: $($igws[0].InternetGatewayId)"
      }
      else {
        Add-ValidationResult -Check "Internet Gateway attached" -Status "FAIL" -Details "No IGW found attached to VPC"
      }
    }
    catch {
      Add-ValidationResult -Check "Internet Gateway" -Status "FAIL" -Details $_.Exception.Message
    }

    try {
      $nats = Get-EC2NatGateway -Filter @{ Name = "vpc-id"; Values = $validationVpcId }, @{ Name = "state"; Values = "available" } -Region $script:TargetRegion
      if ($nats) {
        Add-ValidationResult -Check "NAT Gateway available" -Status "PASS" -Details "NAT: $($nats[0].NatGatewayId)"
      }
      else {
        Add-ValidationResult -Check "NAT Gateway available" -Status "WARN" -Details "No active NAT Gateway (private subnets will lack internet access)"
      }
    }
    catch {
      Add-ValidationResult -Check "NAT Gateway" -Status "FAIL" -Details $_.Exception.Message
    }
  }

  # 4. S3 VPC Endpoint
  if ($validationVpcId) {
    try {
      $endpoints = Get-EC2VpcEndpoint -Filter @{ Name = "vpc-id"; Values = $validationVpcId }, @{ Name = "service-name"; Values = "com.amazonaws.$($script:TargetRegion).s3" } -Region $script:TargetRegion
      if ($endpoints) {
        Add-ValidationResult -Check "S3 VPC Endpoint" -Status "PASS" -Details "Endpoint: $($endpoints[0].VpcEndpointId) (zero-cost S3 access)"
      }
      else {
        Add-ValidationResult -Check "S3 VPC Endpoint" -Status "WARN" -Details "No S3 endpoint (S3 traffic will use NAT Gateway with egress charges)"
      }
    }
    catch {
      Add-ValidationResult -Check "S3 VPC Endpoint" -Status "FAIL" -Details $_.Exception.Message
    }
  }

  # 5. IAM role validation
  Write-Log "Validating IAM configuration..." -Level "INFO"
  $vbrRoleName = "$EnvironmentTag-VBR-Server-Role"
  try {
    $role = Get-IAMRole -RoleName $vbrRoleName
    Add-ValidationResult -Check "VBR Server IAM Role" -Status "PASS" -Details "Role: $vbrRoleName ($($role.Arn))"

    # Check inline policies
    $policies = Get-IAMRolePolicyList -RoleName $vbrRoleName
    $expectedPolicies = @("$EnvironmentTag-S3-BackupAccess", "$EnvironmentTag-EC2-RestoreOps", "$EnvironmentTag-KMS-Access")
    foreach ($expected in $expectedPolicies) {
      if ($policies -contains $expected) {
        Add-ValidationResult -Check "IAM Policy: $expected" -Status "PASS" -Details "Policy attached to $vbrRoleName"
      }
      else {
        Add-ValidationResult -Check "IAM Policy: $expected" -Status "FAIL" -Details "Policy NOT found on $vbrRoleName"
      }
    }
  }
  catch {
    Add-ValidationResult -Check "VBR Server IAM Role" -Status "FAIL" -Details "Role $vbrRoleName not found"
  }

  # 6. S3 bucket accessibility
  Write-Log "Validating S3 backup bucket access..." -Level "INFO"
  if (-not $ExternalS3Endpoint) {
    try {
      $bucketLocation = Get-S3BucketLocation -BucketName $BackupBucketName -Region $BackupBucketRegion
      Add-ValidationResult -Check "S3 backup bucket accessible" -Status "PASS" -Details "Bucket: $BackupBucketName (region: $BackupBucketRegion)"

      # Try listing objects (first few)
      $objects = Get-S3Object -BucketName $BackupBucketName -MaxKey 5 -Region $BackupBucketRegion
      if ($objects) {
        Add-ValidationResult -Check "S3 backup bucket readable" -Status "PASS" -Details "Successfully listed objects ($($objects.Count) sample objects)"
      }
      else {
        Add-ValidationResult -Check "S3 backup bucket readable" -Status "WARN" -Details "Bucket accessible but appears empty"
      }
    }
    catch {
      if ($_.Exception.Message -match "AccessDenied") {
        Add-ValidationResult -Check "S3 backup bucket accessible" -Status "FAIL" -Details "Access Denied - check IAM permissions or cross-account setup"
      }
      elseif ($_.Exception.Message -match "NoSuchBucket") {
        Add-ValidationResult -Check "S3 backup bucket accessible" -Status "FAIL" -Details "Bucket '$BackupBucketName' does not exist"
      }
      else {
        Add-ValidationResult -Check "S3 backup bucket accessible" -Status "FAIL" -Details $_.Exception.Message
      }
    }
  }
  else {
    Add-ValidationResult -Check "S3 backup bucket" -Status "SKIP" -Details "External S3 endpoint - manual validation required"
  }

  # 7. KMS key validation
  try {
    $aliasName = "alias/$EnvironmentTag-restore-key"
    $alias = Get-KMSAliasList -Region $script:TargetRegion | Where-Object { $_.AliasName -eq $aliasName }
    if ($alias) {
      $keyInfo = Get-KMSKey -KeyId $alias.TargetKeyId -Region $script:TargetRegion
      if ($keyInfo.KeyState -eq "Enabled") {
        Add-ValidationResult -Check "KMS encryption key" -Status "PASS" -Details "Key: $($alias.TargetKeyId) (Enabled)"
      }
      else {
        Add-ValidationResult -Check "KMS encryption key" -Status "FAIL" -Details "Key exists but state is: $($keyInfo.KeyState)"
      }
    }
    else {
      Add-ValidationResult -Check "KMS encryption key" -Status "WARN" -Details "No KMS key alias '$aliasName' found (restored volumes will use default encryption)"
    }
  }
  catch {
    Add-ValidationResult -Check "KMS encryption key" -Status "FAIL" -Details $_.Exception.Message
  }

  # 8. Security groups
  if ($validationVpcId) {
    try {
      $sgs = Get-EC2SecurityGroup -Filter @{ Name = "vpc-id"; Values = $validationVpcId }, @{ Name = "tag:ManagedBy"; Values = "VeeamS3DRAccelerator" } -Region $script:TargetRegion
      if ($sgs.Count -ge 3) {
        Add-ValidationResult -Check "Security groups" -Status "PASS" -Details "$($sgs.Count) security groups configured"
      }
      elseif ($sgs.Count -gt 0) {
        Add-ValidationResult -Check "Security groups" -Status "WARN" -Details "Only $($sgs.Count) security groups (expected 3)"
      }
      else {
        Add-ValidationResult -Check "Security groups" -Status "FAIL" -Details "No DR security groups found"
      }
    }
    catch {
      Add-ValidationResult -Check "Security groups" -Status "FAIL" -Details $_.Exception.Message
    }
  }

  # 9. CloudTrail
  try {
    $trails = Get-CTTrail -Region $script:TargetRegion | Where-Object { $_.Name -eq "$EnvironmentTag-DR-Trail" }
    if ($trails) {
      $trailStatus = Get-CTTrailStatus -Name "$EnvironmentTag-DR-Trail" -Region $script:TargetRegion
      if ($trailStatus.IsLogging) {
        Add-ValidationResult -Check "CloudTrail audit logging" -Status "PASS" -Details "Trail: $EnvironmentTag-DR-Trail (logging active)"
      }
      else {
        Add-ValidationResult -Check "CloudTrail audit logging" -Status "WARN" -Details "Trail exists but logging is stopped"
      }
    }
    else {
      Add-ValidationResult -Check "CloudTrail audit logging" -Status "WARN" -Details "No DR-specific CloudTrail found"
    }
  }
  catch {
    Add-ValidationResult -Check "CloudTrail audit logging" -Status "WARN" -Details "Could not verify CloudTrail: $($_.Exception.Message)"
  }

  # Summary
  $passCount = ($script:ValidationResults | Where-Object { $_.Status -eq "PASS" }).Count
  $failCount = ($script:ValidationResults | Where-Object { $_.Status -eq "FAIL" }).Count
  $warnCount = ($script:ValidationResults | Where-Object { $_.Status -eq "WARN" }).Count
  $totalCount = $script:ValidationResults.Count

  Write-Log "Validation complete: $passCount PASS, $failCount FAIL, $warnCount WARN (of $totalCount checks)" -Level $(if ($failCount -gt 0) { "ERROR" } elseif ($warnCount -gt 0) { "WARNING" } else { "SUCCESS" })

  return @{
    Pass = $passCount
    Fail = $failCount
    Warn = $warnCount
    Total = $totalCount
  }
}

#endregion

#region Teardown

function Remove-DRInfrastructure {
  Write-Log "Starting DR infrastructure teardown for environment: $EnvironmentTag" -Level "WARNING"
  Write-Log "This will DELETE all resources tagged with Environment=$EnvironmentTag in $($script:TargetRegion)" -Level "WARNING"

  # Confirm with user
  Write-Host ""
  Write-Host "========================================" -ForegroundColor Red
  Write-Host "  DR INFRASTRUCTURE TEARDOWN" -ForegroundColor Red
  Write-Host "========================================" -ForegroundColor Red
  Write-Host ""
  Write-Host "This will permanently delete ALL resources" -ForegroundColor Yellow
  Write-Host "tagged with Environment = $EnvironmentTag" -ForegroundColor Yellow
  Write-Host "in region $($script:TargetRegion)" -ForegroundColor Yellow
  Write-Host ""

  $confirm = Read-Host "Type 'TEARDOWN' to confirm (anything else to cancel)"
  if ($confirm -ne "TEARDOWN") {
    Write-Log "Teardown cancelled by user" -Level "INFO"
    return
  }

  # 1. Terminate EC2 instances
  Write-Log "Terminating EC2 instances..." -Level "INFO"
  try {
    $instances = (Get-EC2Instance -Filter @{ Name = "tag:Environment"; Values = $EnvironmentTag }, @{ Name = "instance-state-name"; Values = @("running", "stopped") } -Region $script:TargetRegion).Instances
    foreach ($inst in $instances) {
      Remove-EC2Instance -InstanceId $inst.InstanceId -Force -Region $script:TargetRegion
      Write-Log "Terminated instance: $($inst.InstanceId)" -Level "INFO"
    }
    if ($instances.Count -gt 0) {
      Write-Log "Waiting for instances to terminate..." -Level "INFO"
      Start-Sleep -Seconds 30
    }
  }
  catch { Write-Log "Error terminating instances: $($_.Exception.Message)" -Level "WARNING" }

  # 2. Delete NAT Gateway
  Write-Log "Deleting NAT Gateways..." -Level "INFO"
  try {
    $vpcs = Get-EC2Vpc -Filter @{ Name = "tag:Environment"; Values = $EnvironmentTag } -Region $script:TargetRegion
    foreach ($vpc in $vpcs) {
      $nats = Get-EC2NatGateway -Filter @{ Name = "vpc-id"; Values = $vpc.VpcId }, @{ Name = "state"; Values = @("available", "pending") } -Region $script:TargetRegion
      foreach ($nat in $nats) {
        Remove-EC2NatGateway -NatGatewayId $nat.NatGatewayId -Force -Region $script:TargetRegion
        Write-Log "Deleted NAT Gateway: $($nat.NatGatewayId)" -Level "INFO"
      }
    }
    if ($nats.Count -gt 0) {
      Write-Log "Waiting for NAT Gateways to delete..." -Level "INFO"
      Start-Sleep -Seconds 60
    }
  }
  catch { Write-Log "Error deleting NAT Gateways: $($_.Exception.Message)" -Level "WARNING" }

  # 3. Release Elastic IPs
  Write-Log "Releasing Elastic IPs..." -Level "INFO"
  try {
    $eips = Get-EC2Address -Filter @{ Name = "tag:Environment"; Values = $EnvironmentTag } -Region $script:TargetRegion
    foreach ($eip in $eips) {
      Remove-EC2Address -AllocationId $eip.AllocationId -Force -Region $script:TargetRegion
      Write-Log "Released EIP: $($eip.AllocationId)" -Level "INFO"
    }
  }
  catch { Write-Log "Error releasing EIPs: $($_.Exception.Message)" -Level "WARNING" }

  # 4. Delete VPC Endpoints
  Write-Log "Deleting VPC Endpoints..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      $endpoints = Get-EC2VpcEndpoint -Filter @{ Name = "vpc-id"; Values = $vpc.VpcId } -Region $script:TargetRegion
      foreach ($ep in $endpoints) {
        Remove-EC2VpcEndpoint -VpcEndpointId $ep.VpcEndpointId -Force -Region $script:TargetRegion
        Write-Log "Deleted VPC Endpoint: $($ep.VpcEndpointId)" -Level "INFO"
      }
    }
  }
  catch { Write-Log "Error deleting VPC Endpoints: $($_.Exception.Message)" -Level "WARNING" }

  # 5. Delete security groups (non-default)
  Write-Log "Deleting security groups..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      $sgs = Get-EC2SecurityGroup -Filter @{ Name = "vpc-id"; Values = $vpc.VpcId }, @{ Name = "tag:ManagedBy"; Values = "VeeamS3DRAccelerator" } -Region $script:TargetRegion
      foreach ($sg in $sgs) {
        Remove-EC2SecurityGroup -GroupId $sg.GroupId -Force -Region $script:TargetRegion
        Write-Log "Deleted security group: $($sg.GroupId) ($($sg.GroupName))" -Level "INFO"
      }
    }
  }
  catch { Write-Log "Error deleting security groups: $($_.Exception.Message)" -Level "WARNING" }

  # 6. Delete subnets
  Write-Log "Deleting subnets..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      $subnets = Get-EC2Subnet -Filter @{ Name = "vpc-id"; Values = $vpc.VpcId } -Region $script:TargetRegion
      foreach ($sn in $subnets) {
        Remove-EC2Subnet -SubnetId $sn.SubnetId -Force -Region $script:TargetRegion
        Write-Log "Deleted subnet: $($sn.SubnetId)" -Level "INFO"
      }
    }
  }
  catch { Write-Log "Error deleting subnets: $($_.Exception.Message)" -Level "WARNING" }

  # 7. Delete route tables (non-main)
  Write-Log "Deleting route tables..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      $rts = Get-EC2RouteTable -Filter @{ Name = "vpc-id"; Values = $vpc.VpcId }, @{ Name = "tag:ManagedBy"; Values = "VeeamS3DRAccelerator" } -Region $script:TargetRegion
      foreach ($rt in $rts) {
        # Disassociate first
        $associations = $rt.Associations | Where-Object { -not $_.Main }
        foreach ($assoc in $associations) {
          Unregister-EC2RouteTable -AssociationId $assoc.RouteTableAssociationId -Force -Region $script:TargetRegion
        }
        Remove-EC2RouteTable -RouteTableId $rt.RouteTableId -Force -Region $script:TargetRegion
        Write-Log "Deleted route table: $($rt.RouteTableId)" -Level "INFO"
      }
    }
  }
  catch { Write-Log "Error deleting route tables: $($_.Exception.Message)" -Level "WARNING" }

  # 8. Detach and delete Internet Gateway
  Write-Log "Deleting Internet Gateways..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      $igws = Get-EC2InternetGateway -Filter @{ Name = "attachment.vpc-id"; Values = $vpc.VpcId } -Region $script:TargetRegion
      foreach ($igw in $igws) {
        Dismount-EC2InternetGateway -InternetGatewayId $igw.InternetGatewayId -VpcId $vpc.VpcId -Force -Region $script:TargetRegion
        Remove-EC2InternetGateway -InternetGatewayId $igw.InternetGatewayId -Force -Region $script:TargetRegion
        Write-Log "Deleted Internet Gateway: $($igw.InternetGatewayId)" -Level "INFO"
      }
    }
  }
  catch { Write-Log "Error deleting IGWs: $($_.Exception.Message)" -Level "WARNING" }

  # 9. Delete VPC
  Write-Log "Deleting VPCs..." -Level "INFO"
  try {
    foreach ($vpc in $vpcs) {
      Remove-EC2Vpc -VpcId $vpc.VpcId -Force -Region $script:TargetRegion
      Write-Log "Deleted VPC: $($vpc.VpcId)" -Level "INFO"
    }
  }
  catch { Write-Log "Error deleting VPCs: $($_.Exception.Message)" -Level "WARNING" }

  # 10. Delete IAM resources
  Write-Log "Deleting IAM roles and policies..." -Level "INFO"
  $vbrRoleName = "$EnvironmentTag-VBR-Server-Role"
  $instanceProfileName = "$EnvironmentTag-VBR-InstanceProfile"
  try {
    # Remove role from instance profile
    try {
      Remove-IAMRoleFromInstanceProfile -InstanceProfileName $instanceProfileName -RoleName $vbrRoleName -Force
    } catch {}

    # Delete instance profile
    try {
      Remove-IAMInstanceProfile -InstanceProfileName $instanceProfileName -Force
      Write-Log "Deleted instance profile: $instanceProfileName" -Level "INFO"
    } catch {}

    # Delete inline policies
    try {
      $policies = Get-IAMRolePolicyList -RoleName $vbrRoleName
      foreach ($pol in $policies) {
        Remove-IAMRolePolicy -RoleName $vbrRoleName -PolicyName $pol -Force
      }
    } catch {}

    # Delete role
    Remove-IAMRole -RoleName $vbrRoleName -Force
    Write-Log "Deleted IAM role: $vbrRoleName" -Level "INFO"
  }
  catch { Write-Log "Error deleting IAM resources: $($_.Exception.Message)" -Level "WARNING" }

  # 11. Schedule KMS key deletion (minimum 7 days)
  Write-Log "Scheduling KMS key deletion..." -Level "INFO"
  try {
    $aliasName = "alias/$EnvironmentTag-restore-key"
    $alias = Get-KMSAliasList -Region $script:TargetRegion | Where-Object { $_.AliasName -eq $aliasName }
    if ($alias) {
      Remove-KMSAlias -AliasName $aliasName -Force -Region $script:TargetRegion
      Request-KMSKeyDeletion -KeyId $alias.TargetKeyId -PendingWindowInDays 7 -Region $script:TargetRegion
      Write-Log "KMS key $($alias.TargetKeyId) scheduled for deletion in 7 days" -Level "INFO"
    }
  }
  catch { Write-Log "Error scheduling KMS key deletion: $($_.Exception.Message)" -Level "WARNING" }

  # 12. Delete CloudTrail
  Write-Log "Deleting CloudTrail..." -Level "INFO"
  try {
    $trailName = "$EnvironmentTag-DR-Trail"
    Stop-CTLogging -Name $trailName -Region $script:TargetRegion
    Remove-CTTrail -Name $trailName -Force -Region $script:TargetRegion
    Write-Log "Deleted CloudTrail: $trailName" -Level "INFO"
  }
  catch { Write-Log "Error deleting CloudTrail: $($_.Exception.Message)" -Level "WARNING" }

  Write-Log "Teardown complete. Some resources (KMS keys, CloudTrail S3 bucket) may require manual cleanup." -Level "SUCCESS"
}

#endregion

#region HTML Report Generation

function New-DRReadinessReport {
  Write-Log "Generating DR readiness report..." -Level "INFO"

  $duration = (Get-Date) - $script:StartTime
  $durationStr = "{0:mm}m {0:ss}s" -f $duration

  # Build validation rows
  $validationRows = ""
  foreach ($v in $script:ValidationResults) {
    $statusColor = switch ($v.Status) {
      "PASS" { "#107c10" }
      "FAIL" { "#d13438" }
      "WARN" { "#ca5010" }
      "SKIP" { "#605e5c" }
    }
    $statusIcon = switch ($v.Status) {
      "PASS" { "&#10004;" }
      "FAIL" { "&#10008;" }
      "WARN" { "&#9888;" }
      "SKIP" { "&#8212;" }
    }
    $validationRows += @"
      <tr>
        <td style="font-weight:500">$($v.Check)</td>
        <td style="color:$statusColor;font-weight:700;text-align:center">$statusIcon $($v.Status)</td>
        <td style="color:#605e5c;font-size:13px">$($v.Details)</td>
      </tr>
"@
  }

  # Build resource inventory rows
  $resourceRows = ""
  foreach ($r in $script:CreatedResources) {
    $resourceRows += @"
      <tr>
        <td><span class="badge">$($r.ResourceType)</span></td>
        <td style="font-family:monospace;font-size:13px">$($r.ResourceId)</td>
        <td style="font-weight:500">$($r.ResourceName)</td>
        <td style="color:#605e5c;font-size:13px">$($r.Details)</td>
      </tr>
"@
  }

  # Determine overall status
  $failCount = ($script:ValidationResults | Where-Object { $_.Status -eq "FAIL" }).Count
  $warnCount = ($script:ValidationResults | Where-Object { $_.Status -eq "WARN" }).Count
  $passCount = ($script:ValidationResults | Where-Object { $_.Status -eq "PASS" }).Count

  if ($failCount -gt 0) {
    $overallStatus = "NOT READY"
    $overallColor = "#d13438"
    $overallBg = "#fde7e9"
  }
  elseif ($warnCount -gt 0) {
    $overallStatus = "READY (with warnings)"
    $overallColor = "#ca5010"
    $overallBg = "#fff4ce"
  }
  else {
    $overallStatus = "READY"
    $overallColor = "#107c10"
    $overallBg = "#dff6dd"
  }

  # Cross-account banner
  $crossAccountBanner = ""
  if ($script:AccessScenario -eq "CrossAccount") {
    $crossAccountBanner = @"
    <div style="background:#fff4ce;border:1px solid #ca5010;border-radius:8px;padding:16px;margin:20px 0">
      <h3 style="color:#ca5010;margin:0 0 8px 0">&#9888; Cross-Account Action Required</h3>
      <p style="margin:0;color:#323130">The backup bucket is in AWS account <strong>$BackupAccountId</strong>.
      The source account administrator must run the cross-account setup script to grant this DR account read access.
      See <code>cross_account_setup.ps1</code> in the output folder.</p>
    </div>
"@
  }

  # VBR connection info
  $vbrConnectionInfo = ""
  if ($script:VbrInstanceId) {
    $vbrConnectionInfo = @"
    <div class="card">
      <h3>VBR Server Connection Details</h3>
      <table class="data-table">
        <tr><td style="font-weight:500;width:200px">Instance ID</td><td style="font-family:monospace">$($script:VbrInstanceId)</td></tr>
        <tr><td style="font-weight:500">Public IP</td><td style="font-family:monospace">$($script:VbrPublicIp)</td></tr>
        <tr><td style="font-weight:500">Private IP</td><td style="font-family:monospace">$($script:VbrPrivateIp)</td></tr>
        <tr><td style="font-weight:500">Instance Type</td><td>$VbrInstanceType</td></tr>
        <tr><td style="font-weight:500">RDP Access</td><td>Allowed from $AllowedRdpCidr</td></tr>
        <tr><td style="font-weight:500">Console (9443)</td><td>https://$($script:VbrPublicIp):9443</td></tr>
      </table>
      <div style="background:#dff6dd;border-radius:6px;padding:12px;margin-top:12px">
        <strong>Next Steps:</strong>
        <ol style="margin:8px 0 0 0">
          <li>RDP to the server using your key pair</li>
          <li>Download and install Veeam Backup & Replication from <a href="https://www.veeam.com/downloads.html">veeam.com</a></li>
          <li>Add S3 object storage repository pointing to <code>$BackupBucketName</code></li>
          <li>Import backups and begin restore operations</li>
        </ol>
      </div>
    </div>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Veeam S3 DR Accelerator - Readiness Report</title>
  <style>
    :root {
      --veeam-green: #00b336;
      --veeam-dark: #1a1a2e;
      --bg-primary: #faf9f8;
      --bg-card: #ffffff;
      --text-primary: #323130;
      --text-secondary: #605e5c;
      --border: #edebe9;
      --pass: #107c10;
      --fail: #d13438;
      --warn: #ca5010;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
      background: var(--bg-primary);
      color: var(--text-primary);
      line-height: 1.5;
    }
    .container { max-width: 1100px; margin: 0 auto; padding: 24px; }
    .header {
      background: linear-gradient(135deg, var(--veeam-dark) 0%, #16213e 100%);
      color: white;
      padding: 40px;
      border-radius: 12px;
      margin-bottom: 24px;
    }
    .header h1 { font-size: 28px; font-weight: 600; margin-bottom: 8px; }
    .header p { color: #a0a0b0; font-size: 15px; }
    .header .subtitle { color: var(--veeam-green); font-size: 16px; font-weight: 600; margin-bottom: 4px; }
    .status-banner {
      background: $overallBg;
      border: 2px solid $overallColor;
      border-radius: 10px;
      padding: 20px 24px;
      margin-bottom: 24px;
      display: flex;
      align-items: center;
      justify-content: space-between;
    }
    .status-banner .status-text {
      font-size: 22px;
      font-weight: 700;
      color: $overallColor;
    }
    .status-banner .status-meta { color: var(--text-secondary); font-size: 14px; }
    .metrics {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 16px;
      margin-bottom: 24px;
    }
    .metric {
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 20px;
      text-align: center;
    }
    .metric .value { font-size: 32px; font-weight: 700; }
    .metric .label { color: var(--text-secondary); font-size: 13px; margin-top: 4px; }
    .card {
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 24px;
      margin-bottom: 20px;
    }
    .card h3 {
      font-size: 18px;
      font-weight: 600;
      margin-bottom: 16px;
      padding-bottom: 8px;
      border-bottom: 2px solid var(--veeam-green);
    }
    .data-table { width: 100%; border-collapse: collapse; }
    .data-table th {
      text-align: left;
      padding: 10px 12px;
      background: #f3f2f1;
      font-weight: 600;
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: var(--text-secondary);
      border-bottom: 2px solid var(--border);
    }
    .data-table td {
      padding: 10px 12px;
      border-bottom: 1px solid var(--border);
    }
    .data-table tr:hover { background: #f9f9f9; }
    .badge {
      display: inline-block;
      padding: 3px 10px;
      border-radius: 12px;
      font-size: 12px;
      font-weight: 600;
      background: #e1dfdd;
      color: var(--text-primary);
    }
    .next-steps {
      background: linear-gradient(135deg, #f0fdf4 0%, #ecfdf5 100%);
      border: 1px solid #86efac;
      border-radius: 8px;
      padding: 24px;
      margin-bottom: 20px;
    }
    .next-steps h3 { color: var(--pass); border-bottom-color: var(--pass); }
    .next-steps ol { padding-left: 20px; }
    .next-steps li { margin-bottom: 8px; }
    .footer {
      text-align: center;
      padding: 20px;
      color: var(--text-secondary);
      font-size: 13px;
      border-top: 1px solid var(--border);
      margin-top: 24px;
    }
    code {
      background: #f3f2f1;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: 'Cascadia Code', 'Fira Code', Consolas, monospace;
      font-size: 13px;
    }
    @media print {
      body { background: white; }
      .container { max-width: 100%; padding: 0; }
      .header { border-radius: 0; }
    }
  </style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="subtitle">VEEAM S3 DR ACCELERATOR</div>
    <h1>DR Environment Readiness Report</h1>
    <p>Generated $(Get-Date -Format "MMMM d, yyyy 'at' h:mm tt 'UTC'") | Mode: $Mode | Duration: $durationStr</p>
  </div>

  <div class="status-banner">
    <div>
      <div class="status-text">$overallStatus</div>
      <div class="status-meta">$passCount passed, $failCount failed, $warnCount warnings of $($script:ValidationResults.Count) checks</div>
    </div>
  </div>

  <div class="metrics">
    <div class="metric">
      <div class="value" style="color:var(--pass)">$passCount</div>
      <div class="label">Checks Passed</div>
    </div>
    <div class="metric">
      <div class="value" style="color:var(--fail)">$failCount</div>
      <div class="label">Checks Failed</div>
    </div>
    <div class="metric">
      <div class="value" style="color:var(--warn)">$warnCount</div>
      <div class="label">Warnings</div>
    </div>
    <div class="metric">
      <div class="value">$($script:CreatedResources.Count)</div>
      <div class="label">Resources Provisioned</div>
    </div>
  </div>

  <div class="card">
    <h3>Environment Configuration</h3>
    <table class="data-table">
      <tr><td style="font-weight:500;width:220px">AWS Account</td><td style="font-family:monospace">$($script:CurrentAccountId)</td></tr>
      <tr><td style="font-weight:500">Target Region</td><td>$($script:TargetRegion)</td></tr>
      <tr><td style="font-weight:500">Backup Bucket</td><td style="font-family:monospace">$BackupBucketName</td></tr>
      <tr><td style="font-weight:500">Backup Region</td><td>$BackupBucketRegion</td></tr>
      <tr><td style="font-weight:500">Access Scenario</td><td>$($script:AccessScenario)$(if ($BackupAccountId) { " (Account: $BackupAccountId)" })</td></tr>
      <tr><td style="font-weight:500">Environment Tag</td><td>$EnvironmentTag</td></tr>
      <tr><td style="font-weight:500">VPC CIDR</td><td style="font-family:monospace">$VpcCidr</td></tr>
      <tr><td style="font-weight:500">Caller Identity</td><td style="font-family:monospace;font-size:13px">$($script:CurrentArn)</td></tr>
    </table>
  </div>

  $crossAccountBanner

  <div class="card">
    <h3>Validation Results</h3>
    <table class="data-table">
      <tr>
        <th>Check</th>
        <th style="text-align:center;width:100px">Status</th>
        <th>Details</th>
      </tr>
      $validationRows
    </table>
  </div>

  $(if ($script:CreatedResources.Count -gt 0) {
    @"
  <div class="card">
    <h3>Provisioned Resources</h3>
    <table class="data-table">
      <tr>
        <th>Type</th>
        <th>Resource ID</th>
        <th>Name</th>
        <th>Details</th>
      </tr>
      $resourceRows
    </table>
  </div>
"@
  })

  $vbrConnectionInfo

  <div class="next-steps">
    <h3>Restore Workflow - Next Steps</h3>
    <ol>
      <li><strong>Install Veeam B&R</strong> - Deploy Veeam Backup & Replication on the VBR server (or an existing server with network access)</li>
      <li><strong>Add S3 Repository</strong> - In VBR console: Backup Infrastructure &gt; Backup Repositories &gt; Add &gt; Object Storage &gt; S3-Compatible
        <ul style="margin-top:4px;color:#605e5c">
          <li>Bucket: <code>$BackupBucketName</code></li>
          <li>Region: <code>$BackupBucketRegion</code></li>
          <li>Authentication: IAM instance role (no credentials needed if using the provisioned EC2 instance)</li>
        </ul>
      </li>
      <li><strong>Import Backups</strong> - Right-click the repository &gt; Rescan to discover existing backup chains</li>
      <li><strong>Configure Restore</strong> - Right-click backup job &gt; Restore &gt; select target VPC, subnet, and security group from this DR environment</li>
      <li><strong>Validate</strong> - Test restored workloads, verify data integrity, confirm application functionality</li>
      <li><strong>Post-DR Cleanup</strong> - When testing is complete, run this script with <code>-Mode Teardown</code> to remove all DR infrastructure</li>
    </ol>
  </div>

  <div class="card">
    <h3>Architecture Diagram</h3>
    <pre style="font-family:'Cascadia Code','Fira Code',Consolas,monospace;font-size:12px;line-height:1.6;background:#f8f8f8;padding:20px;border-radius:6px;overflow-x:auto">
  DR Account ($($script:CurrentAccountId))                    $(if($BackupAccountId){"Backup Account ($BackupAccountId)"})
  Region: $($script:TargetRegion)                                     $(if($BackupAccountId){"Region: $BackupBucketRegion"})
 +-----------------------------------------------+     $(if($BackupAccountId){"+---------------------------+"})
 |  VPC: $VpcCidr                            |     $(if($BackupAccountId){"|                           |"})
 |                                               |     $(if($BackupAccountId){"|  S3: $BackupBucketName"})
 |  +-------------------+  +-------------------+ |     $(if($BackupAccountId){"|  (Veeam Backups)          |"})
 |  | Public Subnet AZ1 |  | Public Subnet AZ2 | |     $(if($BackupAccountId){"|                           |"})
 |  |  - VBR Server     |  |  (standby)        | |     $(if($BackupAccountId){"+---------------------------+"})
 |  |  - NAT Gateway    |  |                   | |
 |  +-------------------+  +-------------------+ |              $(if($BackupAccountId){"Cross-Account"})
 |                                               |     $(if($BackupAccountId){"<----  IAM Role Trust  ---->"})
 |  +-------------------+  +-------------------+ |
 |  | Private Subnet AZ1|  | Private Subnet AZ2| |
 |  |  - Restored VMs   |  |  - Restored VMs   | |
 |  |  - Veeam Proxies  |  |  - Veeam Proxies  | |
 |  +-------------------+  +-------------------+ |
 |                                               |
 |  [S3 VPC Endpoint] --- zero-cost S3 access    |
 |  [KMS Key] --- encrypted volumes/snapshots    |
 |  [CloudTrail] --- audit logging               |
 +-----------------------------------------------+
    </pre>
  </div>

  <div class="footer">
    <p>&copy; 2026 Veeam Software | DR Accelerator for S3 Backup Restore</p>
    <p>For questions or assistance, contact your Veeam Solutions Architect</p>
  </div>
</div>
</body>
</html>
"@

  $html | Out-File -FilePath $outHtml -Encoding UTF8
  Write-Log "Generated HTML readiness report: $outHtml" -Level "SUCCESS"
  return $outHtml
}

#endregion

#region Plan Mode

function Show-DeploymentPlan {
  Write-Log "========== DEPLOYMENT PLAN (DRY RUN) ==========" -Level "INFO"

  Write-Host ""
  Write-Host "========================================" -ForegroundColor Cyan
  Write-Host "  Veeam S3 DR Accelerator - Plan Mode" -ForegroundColor Cyan
  Write-Host "========================================" -ForegroundColor Cyan
  Write-Host ""
  Write-Host "The following resources WOULD be created:" -ForegroundColor White
  Write-Host ""

  $planItems = @(
    @{ Resource = "VPC"; Details = "CIDR $VpcCidr in $($script:TargetRegion)" },
    @{ Resource = "Subnets (4)"; Details = "2 public + 2 private across 2 AZs" },
    @{ Resource = "Internet Gateway"; Details = "Attached to VPC for public internet access" },
    @{ Resource = "NAT Gateway"; Details = "In public subnet for private subnet outbound" },
    @{ Resource = "Elastic IP"; Details = "For NAT Gateway" },
    @{ Resource = "S3 VPC Endpoint"; Details = "Gateway endpoint for zero-cost S3 access" },
    @{ Resource = "Route Tables (2)"; Details = "Public (IGW) + Private (NAT)" },
    @{ Resource = "Security Groups (3)"; Details = "VBR server, proxy, workloads" },
    @{ Resource = "IAM Role"; Details = "$EnvironmentTag-VBR-Server-Role (S3 read, EC2 ops, KMS)" },
    @{ Resource = "IAM Instance Profile"; Details = "$EnvironmentTag-VBR-InstanceProfile" },
    @{ Resource = "KMS Key"; Details = "AES-256 for restored volume encryption" },
    @{ Resource = "KMS Alias"; Details = "alias/$EnvironmentTag-restore-key" }
  )

  if ($EnableCloudTrail) {
    $planItems += @{ Resource = "CloudTrail"; Details = "DR operations audit trail" }
    $planItems += @{ Resource = "S3 Bucket"; Details = "CloudTrail log storage" }
  }

  if ($script:AccessScenario -eq "CrossAccount") {
    $planItems += @{ Resource = "Cross-Account Policy"; Details = "Assume role in account $BackupAccountId" }
    $planItems += @{ Resource = "Setup Script"; Details = "Instructions for source account admin" }
  }

  if ($DeployVbrServer) {
    $planItems += @{ Resource = "EC2 Instance"; Details = "Windows Server 2022, $VbrInstanceType, 100GB OS + 200GB data" }
  }

  foreach ($item in $planItems) {
    Write-Host "  + $($item.Resource)" -ForegroundColor Green -NoNewline
    Write-Host " - $($item.Details)" -ForegroundColor Gray
  }

  Write-Host ""

  # Cost estimate
  Write-Host "Estimated Monthly Cost (approximate):" -ForegroundColor Cyan
  Write-Host "  NAT Gateway:    ~`$32/mo + data processing" -ForegroundColor White
  Write-Host "  Elastic IP:     ~`$3.65/mo (if unused)" -ForegroundColor White
  if ($DeployVbrServer) {
    $instanceCosts = @{
      "t3.large"   = "~`$60/mo"
      "t3.xlarge"  = "~`$120/mo"
      "t3.2xlarge" = "~`$240/mo"
      "m5.xlarge"  = "~`$140/mo"
      "m5.2xlarge" = "~`$280/mo"
      "r5.xlarge"  = "~`$180/mo"
      "r5.2xlarge" = "~`$360/mo"
    }
    Write-Host "  EC2 ($VbrInstanceType): $($instanceCosts[$VbrInstanceType])" -ForegroundColor White
    Write-Host "  EBS Storage:    ~`$24/mo (300 GB gp3)" -ForegroundColor White
  }
  Write-Host "  S3 VPC Endpoint: Free (gateway type)" -ForegroundColor White
  Write-Host "  KMS Key:        ~`$1/mo" -ForegroundColor White
  Write-Host "  CloudTrail:     ~`$2/mo (single-region)" -ForegroundColor White
  Write-Host ""

  Write-Host "To deploy, re-run with:" -ForegroundColor Yellow
  $deployCmd = ".\Start-VeeamS3DRAccelerator.ps1 -Mode Deploy -BackupBucketName `"$BackupBucketName`" -BackupBucketRegion `"$BackupBucketRegion`""
  if ($TargetRegion -and $TargetRegion -ne $BackupBucketRegion) {
    $deployCmd += " -TargetRegion `"$TargetRegion`""
  }
  if ($BackupAccountId) {
    $deployCmd += " -BackupAccountId `"$BackupAccountId`""
  }
  if ($DeployVbrServer) {
    $deployCmd += " -DeployVbrServer -KeyPairName `"$KeyPairName`""
  }
  Write-Host "  $deployCmd" -ForegroundColor Cyan
  Write-Host ""
}

#endregion

#region Main Execution

try {
  Write-Host ""
  Write-Host "========================================================" -ForegroundColor Green
  Write-Host "  Veeam S3 DR Accelerator v1.0.0" -ForegroundColor Green
  Write-Host "  Fresh-Account Restore Scaffolding for AWS" -ForegroundColor Green
  Write-Host "========================================================" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Mode:            $Mode" -ForegroundColor White
  Write-Host "  Backup Bucket:   $BackupBucketName" -ForegroundColor White
  Write-Host "  Bucket Region:   $BackupBucketRegion" -ForegroundColor White
  Write-Host "  Target Region:   $(if ($TargetRegion) { $TargetRegion } else { $BackupBucketRegion })" -ForegroundColor White
  Write-Host "  Environment Tag: $EnvironmentTag" -ForegroundColor White
  Write-Host "  Output:          $OutputPath" -ForegroundColor White
  Write-Host ""

  # Step 1: Prerequisites
  Test-Prerequisites

  switch ($Mode) {

    "Plan" {
      Show-DeploymentPlan

      # Run validation to show current state
      Write-Log "Running validation against current state..." -Level "INFO"
      Test-DRReadiness

      # Generate report
      New-DRReadinessReport | Out-Null
    }

    "Deploy" {
      Write-Log "========== Starting DR Infrastructure Deployment ==========" -Level "SUCCESS"

      # Step 2: VPC & Networking
      if ($SkipVpcCreation) {
        if (-not $ExistingVpcId) {
          throw "SkipVpcCreation requires ExistingVpcId parameter"
        }
        $script:VpcId = $ExistingVpcId
        Write-Log "Using existing VPC: $ExistingVpcId" -Level "INFO"
      }
      else {
        New-DRVpc
      }

      # Step 3: Subnets
      if (-not $SkipVpcCreation) {
        New-DRSubnets -VpcId $script:VpcId
      }
      elseif ($ExistingSubnetId) {
        $script:PublicSubnet1 = $ExistingSubnetId
        Write-Log "Using existing subnet: $ExistingSubnetId" -Level "INFO"
      }

      # Step 4: Gateways
      if (-not $SkipVpcCreation) {
        New-DRGateways -VpcId $script:VpcId
      }

      # Step 5: Route tables
      if (-not $SkipVpcCreation) {
        New-DRRouteTables -VpcId $script:VpcId
      }

      # Step 6: S3 VPC Endpoint
      if (-not $SkipVpcCreation -and -not $ExternalS3Endpoint) {
        New-DRS3VpcEndpoint -VpcId $script:VpcId
      }

      # Step 7: Security Groups
      New-DRSecurityGroups -VpcId $script:VpcId

      # Step 8: IAM Roles & Policies
      New-DRIAMRoles

      # Step 9: Cross-Account Access (if needed)
      if ($script:AccessScenario -eq "CrossAccount") {
        New-DRCrossAccountRole
      }

      # Step 10: KMS Key
      New-DRKmsKey

      # Step 11: CloudTrail
      if ($EnableCloudTrail) {
        New-DRCloudTrail
      }

      # Step 12: VBR Server (optional)
      if ($DeployVbrServer) {
        New-DRVbrServer
      }

      # Step 13: Validation
      Test-DRReadiness

      # Step 14: Reports
      New-DRReadinessReport | Out-Null

      # Export resource inventory
      $script:CreatedResources | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outResources

      # Summary
      Write-Host ""
      Write-Host "========== Deployment Complete ==========" -ForegroundColor Green
      Write-Host ""
      Write-Host "Resources Created: $($script:CreatedResources.Count)" -ForegroundColor Cyan
      Write-Host ""

      foreach ($r in $script:CreatedResources) {
        Write-Host "  $($r.ResourceType): $($r.ResourceId)" -ForegroundColor White
      }

      if ($script:VbrInstanceId) {
        Write-Host ""
        Write-Host "VBR Server Connection:" -ForegroundColor Cyan
        Write-Host "  Instance: $($script:VbrInstanceId)" -ForegroundColor White
        Write-Host "  Public IP: $($script:VbrPublicIp)" -ForegroundColor White
        Write-Host "  RDP: mstsc /v:$($script:VbrPublicIp)" -ForegroundColor Green
      }

      if ($script:AccessScenario -eq "CrossAccount") {
        Write-Host ""
        Write-Host "IMPORTANT: Cross-account setup required!" -ForegroundColor Yellow
        Write-Host "  Run cross_account_setup.ps1 in the backup account ($BackupAccountId)" -ForegroundColor Yellow
      }
    }

    "Validate" {
      Test-DRReadiness
      New-DRReadinessReport | Out-Null
    }

    "Teardown" {
      Remove-DRInfrastructure
    }
  }

  # Export logs and validation results
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $LogFile
  if ($script:ValidationResults.Count -gt 0) {
    $script:ValidationResults | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $outValidation
  }

  Write-Host ""
  Write-Host "Output Files:" -ForegroundColor Cyan
  Write-Host "  HTML Report:     $outHtml" -ForegroundColor White
  Write-Host "  Execution Log:   $LogFile" -ForegroundColor White
  if (Test-Path $outResources) {
    Write-Host "  Resources CSV:   $outResources" -ForegroundColor White
  }
  if (Test-Path $outValidation) {
    Write-Host "  Validation CSV:  $outValidation" -ForegroundColor White
  }
  Write-Host ""
  Write-Host "=========================================" -ForegroundColor Green

  Write-Log "DR Accelerator completed successfully ($Mode mode)" -Level "SUCCESS"

}
catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

  # Still export logs on failure
  if ($script:LogEntries.Count -gt 0) {
    $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $LogFile
  }

  Write-Host ""
  Write-Host "DR Accelerator failed. Check execution_log.csv for details." -ForegroundColor Red
  throw
}

#endregion
