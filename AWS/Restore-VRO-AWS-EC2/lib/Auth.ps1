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

  try {
    Invoke-WithRetry -OperationName "VBR Connection" -ScriptBlock {
      Connect-VBRServer @connectParams
    }
  }
  catch {
    Write-Log "Verify VBR service is running on $VBRServer and port $VBRPort is accessible. Test with: Test-NetConnection -ComputerName $VBRServer -Port $VBRPort" -Level ERROR
    throw
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

    try {
      $stsResult = Invoke-WithRetry -OperationName "STS AssumeRole" -ScriptBlock {
        Use-STSRole @assumeParams
      }
    }
    catch {
      Write-Log "Verify the IAM role trust policy allows the calling identity. Debug with: aws sts get-caller-identity" -Level ERROR
      throw
    }

    Set-AWSCredential -Credential $stsResult.Credentials
    $script:STSExpiration = $stsResult.Credentials.Expiration
    $script:STSAssumeParams = $assumeParams
    Write-Log "STS AssumeRole succeeded (expires: $($stsResult.Credentials.Expiration))" -Level SUCCESS
    Write-AuditEvent -EventType "AUTH" -Action "STS AssumeRole" -Resource $AWSRoleArn -Details @{ expiration = $stsResult.Credentials.Expiration.ToString("o") }
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
  try {
    Invoke-WithRetry -OperationName "AWS Connectivity Check" -ScriptBlock {
      $identity = Get-STSCallerIdentity -ErrorAction Stop
      Write-Log "AWS identity: Account=$($identity.Account), ARN=$($identity.Arn)" -Level SUCCESS
    }
  }
  catch {
    Write-Log "No AWS credentials found. Options: (1) Run on EC2 with an IAM instance profile, (2) Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, (3) Use -AWSProfile, (4) Use -AWSRoleArn" -Level ERROR
    throw
  }

  $script:AWSInitialized = $true
}

# =============================
# Credential Refresh
# =============================

<#
.SYNOPSIS
  Checks if the current STS session is approaching expiration and refreshes
  credentials if needed. Call periodically during long-running operations.
.PARAMETER ThresholdMinutes
  Minutes before expiration to trigger refresh. Default: 10.
#>
function Update-AWSCredentialIfNeeded {
  param([int]$ThresholdMinutes = 10)

  if (-not $AWSRoleArn -or -not $EnableCredentialRefresh) { return }
  if (-not $script:STSExpiration) { return }

  if ((Get-Date).AddMinutes($ThresholdMinutes) -ge $script:STSExpiration) {
    Write-Log "STS credentials expiring soon. Refreshing..." -Level WARNING
    try {
      $stsResult = Use-STSRole @script:STSAssumeParams
      Set-AWSCredential -Credential $stsResult.Credentials
      $script:STSExpiration = $stsResult.Credentials.Expiration
      Write-Log "STS credentials refreshed (new expiry: $($script:STSExpiration))" -Level SUCCESS
      Write-AuditEvent -EventType "AUTH" -Action "STS Credential Refresh" -Resource $AWSRoleArn
    }
    catch {
      Write-Log "Failed to refresh STS credentials: $($_.Exception.Message)" -Level ERROR
    }
  }
}
