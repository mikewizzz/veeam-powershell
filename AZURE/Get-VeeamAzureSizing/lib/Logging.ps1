# =========================================================================
# Logging.ps1 - Console logging and progress tracking
# =========================================================================

$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 10
$script:CurrentStep = 0

<#
.SYNOPSIS
  Writes a timestamped, color-coded log entry to console and stores it for CSV export.
.PARAMETER Message
  The message to log.
.PARAMETER Level
  Severity level: INFO, WARNING, ERROR, or SUCCESS.
#>
function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("INFO","WARNING","ERROR","SUCCESS")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level = $Level
    Message = $Message
  }
  $script:LogEntries.Add($entry)

  $color = switch($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default   { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

<#
.SYNOPSIS
  Advances the progress bar and logs the current step.
.PARAMETER Activity
  Description of the current step.
.PARAMETER Status
  Optional status message shown alongside the activity.
#>
function Write-ProgressStep {
  param(
    [Parameter(Mandatory=$true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $percentComplete = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Veeam Azure Sizing" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $script:CurrentStep/$script:TotalSteps`: $Activity" -Level "INFO"
}
