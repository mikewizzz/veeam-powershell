# =========================================================================
# Logging.ps1 - Write-Log and formatting helpers
# =========================================================================

<#
.SYNOPSIS
  Writes timestamped log entries to the run log file if telemetry is enabled.
.PARAMETER msg
  The message to log.
#>
function Write-Log([string]$msg) {
  if ($EnableTelemetry) {
    "[$(Get-Date -Format s)] $msg" | Add-Content -Path $logPath
  }
}

<#
.SYNOPSIS
  Formats a decimal value as a percentage string (e.g., 0.15 -> "15.00%").
.PARAMETER p
  The decimal value to format.
#>
function Format-Pct([double]$p) { "{0:P2}" -f $p }

<#
.SYNOPSIS
  Formats a count or special string value for display.
.PARAMETER value
  The value to format - may be an integer, "access_denied", "not_available", etc.
.NOTES
  Returns human-readable strings for special Graph API response values.
#>
function Format-CountValue($value) {
  if ($null -eq $value) { return "N/A" }
  switch ($value) {
    "access_denied"  { return "Requires permission" }
    "not_available"  { return "Not provisioned" }
    "unknown"        { return "Unknown" }
    "present"        { return "Present" }
    default          { return "{0:N0}" -f [int]$value }
  }
}
