# SPDX-License-Identifier: MIT
# =========================================================================
# Logging.ps1 - Console logging and progress tracking
# =========================================================================

$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = 0

<#
.SYNOPSIS
  Logs a message to console (color-coded) and accumulates for CSV export.
.PARAMETER Message
  The log message text.
.PARAMETER Level
  Severity level: INFO, WARNING, ERROR, SUCCESS.
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
  Advances the progress bar and logs a step milestone.
.PARAMETER Activity
  Description of the current activity.
.PARAMETER Status
  Short status text.
#>
function Write-ProgressStep {
  param(
    [Parameter(Mandatory=$true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $percentComplete = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "VBA Health Check" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $script:CurrentStep/$script:TotalSteps`: $Activity" -Level "INFO"
}
