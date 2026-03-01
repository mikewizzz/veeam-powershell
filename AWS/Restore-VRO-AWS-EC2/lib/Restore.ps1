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
    $vpc = Invoke-WithRetry -OperationName "Get VPC" -ScriptBlock {
      Get-EC2Vpc -VpcId $VPCId -Region $AWSRegion
    }
    if (-not $vpc) { throw "VPC '$VPCId' not found in $AWSRegion." }
    Write-Log "Using specified VPC: $VPCId"
  }
  else {
    $vpc = Invoke-WithRetry -OperationName "Get default VPC" -ScriptBlock {
      Get-EC2Vpc -Filter @{ Name="isDefault"; Values="true" } -Region $AWSRegion
    }
    if (-not $vpc) {
      $vpc = Invoke-WithRetry -OperationName "Get first VPC" -ScriptBlock {
        Get-EC2Vpc -Region $AWSRegion | Select-Object -First 1
      }
    }
    if (-not $vpc) { throw "No VPC found in $AWSRegion. Specify -VPCId explicitly." }
    Write-Log "Auto-selected VPC: $($vpc.VpcId) (CIDR: $($vpc.CidrBlock))"
  }
  $config["VpcId"] = $vpc.VpcId

  # Resolve Subnet
  if ($SubnetId) {
    $subnet = Invoke-WithRetry -OperationName "Get subnet" -ScriptBlock {
      Get-EC2Subnet -SubnetId $SubnetId -Region $AWSRegion
    }
    if (-not $subnet) { throw "Subnet '$SubnetId' not found." }
    if ($subnet.VpcId -ne $vpc.VpcId) { throw "Subnet '$SubnetId' is not in VPC '$($vpc.VpcId)'." }
    Write-Log "Using specified subnet: $SubnetId (AZ: $($subnet.AvailabilityZone))"
  }
  else {
    $subnet = Invoke-WithRetry -OperationName "Get subnet in VPC" -ScriptBlock {
      Get-EC2Subnet -Filter @{ Name="vpc-id"; Values=$vpc.VpcId } -Region $AWSRegion |
        Sort-Object AvailableIpAddressCount -Descending |
        Select-Object -First 1
    }
    if (-not $subnet) { throw "No subnet found in VPC '$($vpc.VpcId)'. Specify -SubnetId." }
    Write-Log "Auto-selected subnet: $($subnet.SubnetId) (AZ: $($subnet.AvailabilityZone), Free IPs: $($subnet.AvailableIpAddressCount))"
  }
  $config["SubnetId"] = $subnet.SubnetId
  $config["AvailabilityZone"] = $subnet.AvailabilityZone

  # Validate private IP availability
  if ($PrivateIPAddress) {
    $existingENI = Invoke-WithRetry -OperationName "Check private IP" -ScriptBlock {
      Get-EC2NetworkInterface -Filter @(
        @{ Name="addresses.private-ip-address"; Values=$PrivateIPAddress }
        @{ Name="subnet-id"; Values=$subnet.SubnetId }
      ) -Region $AWSRegion -ErrorAction SilentlyContinue
    }
    if ($existingENI) {
      throw "Private IP '$PrivateIPAddress' is already in use in subnet '$($subnet.SubnetId)' (ENI: $($existingENI[0].NetworkInterfaceId))."
    }
    Write-Log "Private IP '$PrivateIPAddress' is available in subnet $($subnet.SubnetId)"
  }

  # Resolve Security Groups
  if ($SecurityGroupIds) {
    foreach ($sgId in $SecurityGroupIds) {
      $sg = Invoke-WithRetry -OperationName "Validate SG $sgId" -ScriptBlock {
        Get-EC2SecurityGroup -GroupId $sgId -Region $AWSRegion -ErrorAction SilentlyContinue
      }
      if (-not $sg) { throw "Security group '$sgId' not found in $AWSRegion." }
    }
    $config["SecurityGroupIds"] = $SecurityGroupIds
    Write-Log "Using specified security groups: $($SecurityGroupIds -join ', ')"
  }
  else {
    $defaultSg = Invoke-WithRetry -OperationName "Get default SG" -ScriptBlock {
      Get-EC2SecurityGroup -Filter @{ Name="vpc-id"; Values=$vpc.VpcId } -Region $AWSRegion |
        Where-Object { $_.GroupName -eq "default" } |
        Select-Object -First 1
    }
    if ($defaultSg) {
      $config["SecurityGroupIds"] = @($defaultSg.GroupId)
      Write-Log "Auto-selected default security group: $($defaultSg.GroupId)"
    }
    else {
      Write-Log "No default security group found. Restore will use VPC default." -Level WARNING
      $config["SecurityGroupIds"] = @()
    }
  }

  # Network isolation: override security groups with an isolated SG
  if ($IsolateNetwork) {
    Write-Log "Network isolation mode: creating isolated security group..."
    $isolatedSGId = New-IsolatedSecurityGroup -VpcId $vpc.VpcId
    $config["SecurityGroupIds"] = @($isolatedSGId)
    $config["IsolatedSGId"] = $isolatedSGId
    $script:IsolatedSGId = $isolatedSGId
    Write-Log "Network isolation SG created: $isolatedSGId (all traffic blocked)" -Level SUCCESS
  }

  # Validate instance type availability in specific AZ
  $availableTypes = Invoke-WithRetry -OperationName "Validate instance type" -ScriptBlock {
    Get-EC2InstanceTypeOffering -LocationType "availability-zone" `
      -Filter @(
        @{ Name="instance-type"; Values=$InstanceType }
        @{ Name="location"; Values=$subnet.AvailabilityZone }
      ) -Region $AWSRegion
  }
  if (-not $availableTypes) {
    throw "Instance type '$InstanceType' is not available in AZ '$($subnet.AvailabilityZone)' ($AWSRegion)."
  }
  $config["InstanceType"] = $InstanceType
  Write-Log "Instance type '$InstanceType' validated in AZ $($subnet.AvailabilityZone)"

  # Key pair validation
  if ($KeyPairName) {
    $kp = Invoke-WithRetry -OperationName "Validate key pair" -ScriptBlock {
      Get-EC2KeyPair -KeyName $KeyPairName -Region $AWSRegion -ErrorAction SilentlyContinue
    }
    if (-not $kp) { throw "Key pair '$KeyPairName' not found in $AWSRegion." }
    $config["KeyPairName"] = $KeyPairName
    Write-Log "Key pair '$KeyPairName' validated"
  }

  Write-Log "EC2 target configuration resolved" -Level SUCCESS
  return $config
}

# =============================
# Network Isolation (Clean Room)
# =============================

<#
.SYNOPSIS
  Creates an isolated security group that blocks all inbound/outbound traffic
  for clean room ransomware recovery scenarios.
.PARAMETER VpcId
  The VPC ID to create the security group in.
.OUTPUTS
  Security group ID of the newly created isolated group.
#>
function New-IsolatedSecurityGroup {
  param([Parameter(Mandatory)][string]$VpcId)

  $sgName = if ($IsolatedSGName) { $IsolatedSGName } else { "VeeamIsolated-$stamp" }

  $sgId = New-EC2SecurityGroup -GroupName $sgName `
    -Description "Veeam VRO isolated recovery - all traffic blocked" `
    -VpcId $VpcId -Region $AWSRegion

  # Revoke the default outbound "allow all" rule
  $defaultEgress = Get-EC2SecurityGroup -GroupId $sgId -Region $AWSRegion |
    Select-Object -ExpandProperty IpPermissionsEgress
  if ($defaultEgress) {
    Revoke-EC2SecurityGroupEgress -GroupId $sgId -IpPermission $defaultEgress -Region $AWSRegion
  }

  # Tag the SG for identification
  $sgTags = @(
    (New-Object Amazon.EC2.Model.Tag("Name", $sgName)),
    (New-Object Amazon.EC2.Model.Tag("ManagedBy", "VeeamVRO")),
    (New-Object Amazon.EC2.Model.Tag("veeam:purpose", "network-isolation")),
    (New-Object Amazon.EC2.Model.Tag("veeam:restore-timestamp", $stamp))
  )
  New-EC2Tag -Resource $sgId -Tag $sgTags -Region $AWSRegion

  $script:CreatedResources.Add([PSCustomObject]@{ Type = "SecurityGroup"; Id = $sgId })
  Write-AuditEvent -EventType "CONFIG" -Action "Created isolated security group" -Resource $sgId

  return $sgId
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

  if ($RestoreMode -eq "InstantRestore") {
    throw "InstantRestore mode is not yet implemented for EC2 restores. Use 'FullRestore' (default)."
  }

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
    Write-Log "" -Level SUCCESS
    Write-Log "DRY RUN COMPLETE — No restore will be executed." -Level SUCCESS
    Write-Log "Validated:" -Level SUCCESS
    Write-Log "  [PASS] VBR connection to ${VBRServer}:${VBRPort}" -Level SUCCESS
    Write-Log "  [PASS] AWS authentication" -Level SUCCESS
    Write-Log "  [PASS] Backup '$BackupName' found ($($RestorePoint.Name))" -Level SUCCESS
    Write-Log "  [PASS] VPC $($EC2Config.VpcId) / Subnet $($EC2Config.SubnetId) ($($EC2Config.AvailabilityZone))" -Level SUCCESS
    $sgDisplay = if ($EC2Config.SecurityGroupIds) { $EC2Config.SecurityGroupIds -join ", " } else { "(default)" }
    Write-Log "  [PASS] Security groups: $sgDisplay" -Level SUCCESS
    Write-Log "  [PASS] Instance type $($EC2Config.InstanceType) available in $($EC2Config.AvailabilityZone)" -Level SUCCESS
    $encDisplay = if ($EncryptVolumes) { "enabled" } else { "disabled" }
    Write-Log "  [PASS] Disk type $DiskType, encryption $encDisplay" -Level SUCCESS
    Write-Log "" -Level SUCCESS
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
  $deadline = (Get-Date).Add($timeout)
  $pollInterval = 15  # seconds between status checks
  $lastProgress = -1

  Write-Log "Monitoring restore session (timeout: $RestoreTimeoutMinutes minutes)..."

  while ((Get-Date) -lt $deadline) {
    $current = Get-VBRSession -Id $Session.Id

    if (-not $current) {
      throw "Restore session lost: session ID $($Session.Id) no longer exists."
    }

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
    Update-AWSCredentialIfNeeded
  }

  throw "Restore timed out after $RestoreTimeoutMinutes minutes. Session ID: $($Session.Id)"
}
