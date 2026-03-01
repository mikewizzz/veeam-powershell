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
# Compliance Audit Trail
# =============================

<#
.SYNOPSIS
  Records a structured audit event to the compliance event log.
.PARAMETER EventType
  Category: AUTH, RESTORE, VALIDATE, TAG, CLEANUP, CONFIG, DNS, ALARM, SSM, DRILL.
.PARAMETER Action
  Specific action taken.
.PARAMETER Resource
  AWS resource identifier affected.
.PARAMETER Details
  Additional details hashtable.
#>
<#
.SYNOPSIS
  Displays a visual startup banner with version, mode, and key parameters.
#>
function Write-Banner {
  $mode = if ($DRDrillMode) { "DR DRILL" }
          elseif ($DryRun) { "DRY RUN" }
          else { "LIVE" }

  $banner = @"

  ╔══════════════════════════════════════════════════════════════════╗
  ║       VRO AWS EC2 Restore  v2.1.0                              ║
  ║       Automated Backup Restore to Amazon EC2                   ║
  ╚══════════════════════════════════════════════════════════════════╝

  Backup:    $BackupName
  Region:    $AWSRegion
  VBR:       ${VBRServer}:${VBRPort}

"@
  Write-Host $banner -ForegroundColor Cyan

  if ($DryRun) {
    Write-Host "  >>> DRY RUN MODE — No changes will be made <<<" -ForegroundColor Yellow
    Write-Host ""
  }
  elseif ($DRDrillMode) {
    Write-Host "  >>> DR DRILL MODE — Instance will auto-terminate after ${DRDrillKeepMinutes}m <<<" -ForegroundColor Yellow
    Write-Host ""
  }

  Write-Log "VRO AWS EC2 Restore v2.1.0 | Mode: $mode | Backup: $BackupName | Region: $AWSRegion"
  if ($VROPlanName) { Write-Log "VRO Plan: $VROPlanName / Step: $VROStepName" }
}

<#
.SYNOPSIS
  Logs a numbered step and updates the Write-Progress bar.
.PARAMETER Activity
  Short description of the current step.
.PARAMETER Status
  Status text shown in the progress bar.
#>
function Write-ProgressStep {
  param(
    [Parameter(Mandatory)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "VRO AWS EC2 Restore" -Status "$Activity - $Status" -PercentComplete $pct
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity"
}

<#
.SYNOPSIS
  Displays a pre-execution restore plan summary showing the resolved configuration.
.PARAMETER RestorePoint
  The selected Veeam restore point object.
.PARAMETER EC2Config
  Hashtable from Get-EC2TargetConfig with resolved infrastructure details.
#>
function Write-RestorePlan {
  param(
    [Parameter(Mandatory)][object]$RestorePoint,
    [Parameter(Mandatory)][hashtable]$EC2Config
  )

  $rpTime = if ($RestorePoint.CreationTime) { $RestorePoint.CreationTime.ToString("yyyy-MM-dd HH:mm:ss") } else { "N/A" }
  $rpLabel = if ($UseLatestCleanPoint) { "$rpTime (latest clean)" }
             elseif ($RestorePointId) { "$rpTime (specified)" }
             else { "$rpTime (latest)" }

  $vmLabel = if ($VMName) { $VMName } else { "(all)" }
  $sgLabel = if ($EC2Config.SecurityGroupIds) { $EC2Config.SecurityGroupIds -join ", " } else { "(default)" }
  $encLabel = if ($EncryptVolumes) {
    $keyLabel = if ($KMSKeyId) { "KMS $KMSKeyId" } else { "KMS default key" }
    "Yes ($keyLabel)"
  } else { "No" }
  $isoLabel = if ($IsolateNetwork) { "Yes" } else { "No" }
  $powerLabel = if ($PowerOnAfterRestore) { "Yes" } else { "No" }

  $plan = @"

=== Restore Plan ===
Backup:           $BackupName
VM:               $vmLabel
Restore Point:    $rpLabel
Target Region:    $AWSRegion
Instance Type:    $($EC2Config.InstanceType)
VPC / Subnet:     $($EC2Config.VpcId) / $($EC2Config.SubnetId) ($($EC2Config.AvailabilityZone))
Security Groups:  $sgLabel
Disk Type:        $DiskType
Encrypted:        $encLabel
Network Isolated: $isoLabel
Power On:         $powerLabel
====================

"@

  Write-Host $plan -ForegroundColor White
  Write-Log "Restore plan displayed — target: $($EC2Config.InstanceType) in $($EC2Config.AvailabilityZone)"
}

function Write-AuditEvent {
  param(
    [Parameter(Mandatory)][string]$EventType,
    [Parameter(Mandatory)][string]$Action,
    [string]$Resource = "",
    [hashtable]$Details = @{}
  )

  if (-not $EnableAuditTrail) { return }

  $auditEntry = [PSCustomObject]@{
    timestamp = (Get-Date -Format "o")
    eventType = $EventType
    action    = $Action
    resource  = $Resource
    vroPlan   = $VROPlanName
    vroStep   = $VROStepName
    details   = $Details
  }
  $script:AuditTrail.Add($auditEntry)
}
