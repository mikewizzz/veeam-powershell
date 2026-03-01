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
