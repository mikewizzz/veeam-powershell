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

  # Validate AWS 50-tag limit
  $MAX_AWS_TAGS = 50
  if ($allTags.Count -gt $MAX_AWS_TAGS) {
    Write-Log "Tag count ($($allTags.Count)) exceeds AWS limit ($MAX_AWS_TAGS). Truncating user tags to fit." -Level WARNING
    $userTagsAllowed = $MAX_AWS_TAGS - $standardTags.Count
    $allTags = $standardTags.Clone()
    $userKeysAdded = 0
    foreach ($key in $Tags.Keys) {
      if ($userKeysAdded -ge $userTagsAllowed) { break }
      $allTags[$key] = $Tags[$key]
      $userKeysAdded++
    }
    Write-Log "Applied $($standardTags.Count) standard + $userKeysAdded user tags ($($allTags.Count) total)"
  }

  # Convert to AWS tag format
  $awsTags = $allTags.GetEnumerator() | ForEach-Object {
    New-Object Amazon.EC2.Model.Tag($_.Key, $_.Value)
  }

  # Tag the instance
  try {
    New-EC2Tag -Resource $Instance.InstanceId -Tag $awsTags -Region $AWSRegion
    Write-Log "Tagged instance $($Instance.InstanceId) with $($awsTags.Count) tags"
  }
  catch {
    Write-Log "Failed to tag instance $($Instance.InstanceId): $($_.Exception.Message)" -Level WARNING
  }

  # Tag all attached EBS volumes
  $volumeIds = $Instance.BlockDeviceMappings | ForEach-Object { $_.Ebs.VolumeId } | Where-Object { $_ }
  foreach ($volId in $volumeIds) {
    try {
      New-EC2Tag -Resource $volId -Tag $awsTags -Region $AWSRegion
      Write-Log "Tagged volume $volId"
    }
    catch {
      Write-Log "Failed to tag volume $volId`: $($_.Exception.Message)" -Level WARNING
    }
  }

  # Tag network interfaces
  $eniIds = $Instance.NetworkInterfaces | ForEach-Object { $_.NetworkInterfaceId } | Where-Object { $_ }
  foreach ($eniId in $eniIds) {
    try {
      New-EC2Tag -Resource $eniId -Tag $awsTags -Region $AWSRegion
      Write-Log "Tagged network interface $eniId"
    }
    catch {
      Write-Log "Failed to tag ENI $eniId`: $($_.Exception.Message)" -Level WARNING
    }
  }

  Write-Log "All resources tagged" -Level SUCCESS
  Write-AuditEvent -EventType "TAG" -Action "Resources tagged" -Resource $Instance.InstanceId -Details @{ tagCount = $allTags.Count }
}

# =============================
# CloudWatch Integration
# =============================

<#
.SYNOPSIS
  Creates CloudWatch alarms for the restored EC2 instance.
.PARAMETER InstanceId
  The EC2 instance ID to monitor.
#>
function New-EC2CloudWatchAlarms {
  param([Parameter(Mandatory)][string]$InstanceId)

  Write-Log "Creating CloudWatch alarms for $InstanceId..."

  $alarmActions = @()
  if ($CloudWatchSNSTopicArn) {
    $alarmActions = @($CloudWatchSNSTopicArn)
  }

  $instanceDimension = New-Object Amazon.CloudWatch.Model.Dimension
  $instanceDimension.Name = "InstanceId"
  $instanceDimension.Value = $InstanceId

  # Status check alarm
  $statusAlarmName = "VeeamRestore-StatusCheck-$InstanceId"
  $statusAlarmParams = @{
    AlarmName          = $statusAlarmName
    AlarmDescription   = "VRO restore: EC2 status check failed for $InstanceId"
    Namespace          = "AWS/EC2"
    MetricName         = "StatusCheckFailed"
    Statistic          = "Maximum"
    Period             = 60
    EvaluationPeriod   = 2
    Threshold          = 1
    ComparisonOperator = "GreaterThanOrEqualToThreshold"
    Dimension          = $instanceDimension
    Region             = $AWSRegion
  }
  if ($alarmActions.Count -gt 0) {
    $statusAlarmParams["AlarmAction"] = $alarmActions
  }
  try {
    Write-CWMetricAlarm @statusAlarmParams
    $script:CreatedResources.Add([PSCustomObject]@{ Type = "CloudWatchAlarm"; Id = $statusAlarmName })
    Write-Log "Created StatusCheckFailed alarm"
  }
  catch {
    Write-Log "Failed to create StatusCheckFailed alarm: $($_.Exception.Message)" -Level WARNING
  }

  # CPU utilization alarm
  $cpuAlarmName = "VeeamRestore-HighCPU-$InstanceId"
  $cpuAlarmParams = @{
    AlarmName          = $cpuAlarmName
    AlarmDescription   = "VRO restore: CPU > 90% for $InstanceId"
    Namespace          = "AWS/EC2"
    MetricName         = "CPUUtilization"
    Statistic          = "Average"
    Period             = 300
    EvaluationPeriod   = 3
    Threshold          = 90
    ComparisonOperator = "GreaterThanThreshold"
    Dimension          = $instanceDimension
    Region             = $AWSRegion
  }
  if ($alarmActions.Count -gt 0) {
    $cpuAlarmParams["AlarmAction"] = $alarmActions
  }
  try {
    Write-CWMetricAlarm @cpuAlarmParams
    $script:CreatedResources.Add([PSCustomObject]@{ Type = "CloudWatchAlarm"; Id = $cpuAlarmName })
    Write-Log "Created CPUUtilization alarm"
  }
  catch {
    Write-Log "Failed to create CPUUtilization alarm: $($_.Exception.Message)" -Level WARNING
  }

  Write-Log "CloudWatch alarms created" -Level SUCCESS
  Write-AuditEvent -EventType "ALARM" -Action "Created CloudWatch alarms" -Resource $InstanceId
}

# =============================
# Route53 DNS Failover
# =============================

<#
.SYNOPSIS
  Creates or updates a Route53 DNS record pointing to the restored instance.
.PARAMETER InstanceIP
  The IP address to point the record to.
#>
function Update-Route53Record {
  param([Parameter(Mandatory)][string]$InstanceIP)

  Write-Log "Updating Route53 DNS: $Route53RecordName -> $InstanceIP ($Route53RecordType)"

  $resourceRecord = New-Object Amazon.Route53.Model.ResourceRecord
  $resourceRecord.Value = $InstanceIP

  $recordSet = New-Object Amazon.Route53.Model.ResourceRecordSet
  $recordSet.Name = $Route53RecordName
  $recordSet.Type = $Route53RecordType
  $recordSet.TTL = 60
  $recordSet.ResourceRecords = New-Object System.Collections.Generic.List[Amazon.Route53.Model.ResourceRecord]
  $recordSet.ResourceRecords.Add($resourceRecord)

  $change = New-Object Amazon.Route53.Model.Change
  $change.Action = "UPSERT"
  $change.ResourceRecordSet = $recordSet

  try {
    $changeResult = Edit-R53ResourceRecordSet -HostedZoneId $Route53HostedZoneId `
      -ChangeBatch_Change $change -Region $AWSRegion

    $script:CreatedResources.Add([PSCustomObject]@{ Type = "Route53Record"; Id = "$Route53HostedZoneId/$Route53RecordName" })
    Write-Log "Route53 change submitted: $($changeResult.ChangeInfo.Id) (Status: $($changeResult.ChangeInfo.Status))"

    # Wait for propagation (max 60s)
    $r53Deadline = (Get-Date).AddSeconds(60)
    $propagated = $false
    while ((Get-Date) -lt $r53Deadline) {
      $changeStatus = Get-R53Change -Id $changeResult.ChangeInfo.Id -Region $AWSRegion
      if ($changeStatus.ChangeInfo.Status -eq "INSYNC") {
        Write-Log "Route53 DNS record propagated: $Route53RecordName -> $InstanceIP" -Level SUCCESS
        $propagated = $true
        break
      }
      Start-Sleep -Seconds 5
    }
    if (-not $propagated) {
      Write-Log "Route53 propagation timed out after 60s — record may still be pending" -Level WARNING
    }
  }
  catch {
    Write-Log "Failed to update Route53 record: $($_.Exception.Message)" -Level WARNING
  }

  Write-AuditEvent -EventType "DNS" -Action "Route53 record updated" -Resource $Route53RecordName -Details @{
    ip = $InstanceIP; type = $Route53RecordType; zoneId = $Route53HostedZoneId
  }
}

# =============================
# SSM Post-Restore Scripts
# =============================

<#
.SYNOPSIS
  Executes an SSM document on the restored instance for post-restore configuration.
.PARAMETER InstanceId
  The EC2 instance to target.
.PARAMETER DocumentName
  The SSM document name or ARN.
.PARAMETER Parameters
  Hashtable of document parameters.
.PARAMETER TimeoutMinutes
  Max wait time. Default: 30.
.OUTPUTS
  PSCustomObject with Status, Output, Duration.
#>
function Invoke-PostRestoreSSMDocument {
  param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$DocumentName,
    [hashtable]$Parameters = @{},
    [int]$TimeoutMinutes = 30
  )

  Write-Log "Executing SSM document '$DocumentName' on $InstanceId..."
  Write-AuditEvent -EventType "SSM" -Action "Executing post-restore document" -Resource $InstanceId -Details @{ document = $DocumentName }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  $sendParams = @{
    InstanceId   = @($InstanceId)
    DocumentName = $DocumentName
    Region       = $AWSRegion
  }
  if ($Parameters.Count -gt 0) {
    $sendParams["Parameter"] = $Parameters
  }

  $ssmResult = Invoke-WithRetry -OperationName "SSM SendCommand" -ScriptBlock {
    Send-SSMCommand @sendParams
  }
  $commandId = $ssmResult.CommandId
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    $invocation = Get-SSMCommandInvocation -CommandId $commandId `
      -InstanceId $InstanceId -Details:$true -Region $AWSRegion

    if ($invocation.Status -in @("Success", "Failed", "Cancelled", "TimedOut")) {
      $sw.Stop()
      $output = if ($invocation.CommandPlugins) { $invocation.CommandPlugins[0].Output } else { "" }

      Write-AuditEvent -EventType "SSM" -Action "Post-restore document completed" -Resource $InstanceId -Details @{
        status = $invocation.Status; commandId = $commandId
      }

      return [PSCustomObject]@{
        Status   = $invocation.Status
        Output   = $output
        Duration = $sw.Elapsed.TotalSeconds
      }
    }
  }

  $sw.Stop()
  return [PSCustomObject]@{
    Status   = "TimedOut"
    Output   = "Command timed out after $TimeoutMinutes minutes"
    Duration = $sw.Elapsed.TotalSeconds
  }
}

# =============================
# Rollback / Cleanup
# =============================

<#
.SYNOPSIS
  Cleans up AWS resources created during a failed restore.
  Best-effort: never throws, logs all actions.
.PARAMETER InstanceId
  The EC2 instance ID to terminate.
.PARAMETER IsolatedSecurityGroupId
  The isolated SG to delete.
#>
function Invoke-RestoreCleanup {
  param(
    [string]$InstanceId,
    [string]$IsolatedSecurityGroupId
  )

  Write-Log "Initiating resource cleanup..." -Level WARNING

  # Terminate EC2 instance
  if ($InstanceId) {
    try {
      Write-Log "Terminating instance $InstanceId..."
      Remove-EC2Instance -InstanceId $InstanceId -Force -Region $AWSRegion
      Write-Log "Instance $InstanceId termination initiated" -Level SUCCESS
      Write-AuditEvent -EventType "CLEANUP" -Action "Instance terminated" -Resource $InstanceId
    }
    catch {
      Write-Log "Failed to terminate instance $InstanceId`: $($_.Exception.Message)" -Level WARNING
    }
  }

  # Delete isolated security group (must wait for ENI detachment)
  if ($IsolatedSecurityGroupId) {
    try {
      Write-Log "Waiting for ENI detachment before deleting SG $IsolatedSecurityGroupId..."
      $sgDeadline = (Get-Date).AddMinutes(5)
      $sgDeleted = $false
      while ((Get-Date) -lt $sgDeadline) {
        try {
          Remove-EC2SecurityGroup -GroupId $IsolatedSecurityGroupId -Region $AWSRegion -Force
          $sgDeleted = $true
          Write-Log "Deleted isolated SG $IsolatedSecurityGroupId" -Level SUCCESS
          Write-AuditEvent -EventType "CLEANUP" -Action "Security group deleted" -Resource $IsolatedSecurityGroupId
          break
        }
        catch {
          Start-Sleep -Seconds 10
        }
      }
      if (-not $sgDeleted) {
        Write-Log "Could not delete SG $IsolatedSecurityGroupId within timeout. Delete manually." -Level WARNING
      }
    }
    catch {
      Write-Log "SG cleanup error: $($_.Exception.Message)" -Level WARNING
    }
  }

  # Delete CloudWatch alarms created during this restore
  $cwAlarms = @($script:CreatedResources | Where-Object { $_.Type -eq "CloudWatchAlarm" })
  foreach ($alarm in $cwAlarms) {
    try {
      Remove-CWAlarm -AlarmName $alarm.Id -Force -Region $AWSRegion
      Write-Log "Deleted CloudWatch alarm: $($alarm.Id)" -Level SUCCESS
      Write-AuditEvent -EventType "CLEANUP" -Action "CloudWatch alarm deleted" -Resource $alarm.Id
    }
    catch {
      Write-Log "Failed to delete CloudWatch alarm $($alarm.Id): $($_.Exception.Message)" -Level WARNING
    }
  }

  Write-Log "Cleanup completed" -Level WARNING
}

# =============================
# DR Drill Mode
# =============================

<#
.SYNOPSIS
  Executes DR drill lifecycle: keep instance alive for specified duration, then
  auto-terminate. Produces compliance-ready drill report.
.PARAMETER Instance
  The restored EC2 instance.
.PARAMETER KeepMinutes
  How long to keep the instance alive before cleanup.
#>
function Invoke-DRDrill {
  param(
    [Parameter(Mandatory)][object]$Instance,
    [int]$KeepMinutes = 30
  )

  Write-Log "DR Drill: Instance $($Instance.InstanceId) will be kept alive for $KeepMinutes minutes"
  Write-AuditEvent -EventType "DRILL" -Action "DR drill started" -Resource $Instance.InstanceId -Details @{ keepMinutes = $KeepMinutes }

  # Tag as DR drill
  $drillTags = @(
    (New-Object Amazon.EC2.Model.Tag("veeam:dr-drill", "true")),
    (New-Object Amazon.EC2.Model.Tag("veeam:dr-drill-expiry", (Get-Date).AddMinutes($KeepMinutes).ToString("o")))
  )
  New-EC2Tag -Resource $Instance.InstanceId -Tag $drillTags -Region $AWSRegion

  # Wait with periodic credential refresh
  $drillDeadline = (Get-Date).AddMinutes($KeepMinutes)
  while ((Get-Date) -lt $drillDeadline) {
    $remaining = [Math]::Round(($drillDeadline - (Get-Date)).TotalMinutes, 0)
    Write-Log "DR Drill: $remaining minutes remaining before cleanup"
    $sleepSec = [Math]::Max(0, [Math]::Min(60, ($drillDeadline - (Get-Date)).TotalSeconds))
    if ($sleepSec -gt 0) { Start-Sleep -Seconds $sleepSec }
    Update-AWSCredentialIfNeeded
  }

  # Auto-terminate
  Write-Log "DR Drill: Keep-alive period expired. Initiating cleanup..."
  Invoke-RestoreCleanup -InstanceId $Instance.InstanceId -IsolatedSecurityGroupId $script:IsolatedSGId

  Write-AuditEvent -EventType "DRILL" -Action "DR drill completed" -Resource $Instance.InstanceId
  Write-Log "DR Drill completed - instance terminated after $KeepMinutes minutes" -Level SUCCESS
}
