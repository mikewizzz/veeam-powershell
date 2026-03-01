# =============================
# Parameter Conflict Detection
# =============================

<#
.SYNOPSIS
  Detects mutually exclusive or misconfigured parameter combinations.
  Called before module loading to fail fast with clear messages.
#>
function Test-ParameterConflicts {
  # Fatal conflicts — throw immediately
  if ($UseLatestCleanPoint -and $RestorePointId) {
    throw "Cannot use both -UseLatestCleanPoint and -RestorePointId. Remove one."
  }

  if ($IsolateNetwork -and $AssociatePublicIP) {
    throw "Cannot associate a public IP with an isolated network. Remove -AssociatePublicIP or -IsolateNetwork."
  }

  if ($Route53RecordName -and -not $Route53HostedZoneId) {
    throw "-Route53RecordName requires -Route53HostedZoneId. Provide the hosted zone ID."
  }

  # Warnings — log but continue
  if ($SkipValidation -and ($HealthCheckPorts -or $HealthCheckUrls -or $SSMHealthCheckCommand)) {
    Write-Log "Health check parameters ignored because -SkipValidation is set." -Level WARNING
  }

  if ($CloudWatchSNSTopicArn -and -not $CreateCloudWatchAlarms) {
    Write-Log "-CloudWatchSNSTopicArn has no effect without -CreateCloudWatchAlarms." -Level WARNING
  }

  if ($KMSKeyId -and -not $EncryptVolumes) {
    Write-Log "-KMSKeyId has no effect without -EncryptVolumes." -Level WARNING
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
  Test-ParameterConflicts

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

  # Optional: AWS.Tools.SimpleSystemsManagement for SSM integration
  if ($SSMHealthCheckCommand -or $PostRestoreSSMDocument) {
    if (-not (Get-Module -ListAvailable -Name "AWS.Tools.SimpleSystemsManagement")) {
      throw "AWS.Tools.SimpleSystemsManagement module required for SSM features. Install via: Install-Module AWS.Tools.SimpleSystemsManagement -Scope CurrentUser"
    }
    Import-Module AWS.Tools.SimpleSystemsManagement -ErrorAction Stop
    Write-Log "Loaded AWS module: AWS.Tools.SimpleSystemsManagement"
  }

  # Optional: AWS.Tools.CloudWatch for alarm creation
  if ($CreateCloudWatchAlarms) {
    if (-not (Get-Module -ListAvailable -Name "AWS.Tools.CloudWatch")) {
      throw "AWS.Tools.CloudWatch module required for -CreateCloudWatchAlarms. Install via: Install-Module AWS.Tools.CloudWatch -Scope CurrentUser"
    }
    Import-Module AWS.Tools.CloudWatch -ErrorAction Stop
    Write-Log "Loaded AWS module: AWS.Tools.CloudWatch"
  }

  # Optional: AWS.Tools.Route53 for DNS updates
  if ($Route53HostedZoneId) {
    if (-not (Get-Module -ListAvailable -Name "AWS.Tools.Route53")) {
      throw "AWS.Tools.Route53 module required for DNS updates. Install via: Install-Module AWS.Tools.Route53 -Scope CurrentUser"
    }
    Import-Module AWS.Tools.Route53 -ErrorAction Stop
    Write-Log "Loaded AWS module: AWS.Tools.Route53"
  }

  Write-Log "All prerequisites validated" -Level SUCCESS
}
