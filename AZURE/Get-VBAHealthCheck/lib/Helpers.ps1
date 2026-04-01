# SPDX-License-Identifier: MIT
# =========================================================================
# Helpers.ps1 - String helpers and shared formatting functions
# =========================================================================

# =============================
# String Helper Functions
# =============================

<#
.SYNOPSIS
  Encodes a string for safe embedding in HTML to prevent XSS.
.PARAMETER s
  The string to encode.
#>
function _EscapeHtml([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

# =============================
# Health Score Helpers
# =============================

<#
.SYNOPSIS
  Returns the color hex value for a health status.
.PARAMETER Status
  One of: Healthy, Warning, Critical.
#>
function Get-HealthColor {
  param([string]$Status)
  switch ($Status) {
    "Healthy"  { return "#00B336" }
    "Warning"  { return "#FF8C00" }
    "Critical" { return "#D13438" }
    default    { return "#605E5C" }
  }
}

<#
.SYNOPSIS
  Returns grade label and color for a numeric score.
.PARAMETER Score
  Numeric score from 0 to 100.
.OUTPUTS
  Hashtable with Grade and Color keys.
#>
function Get-ScoreGrade {
  param([double]$Score)
  if ($Score -ge 90) { return @{ Grade = "Excellent"; Color = "#00B336" } }
  if ($Score -ge 70) { return @{ Grade = "Good"; Color = "#0078D4" } }
  if ($Score -ge 50) { return @{ Grade = "Needs Attention"; Color = "#FF8C00" } }
  return @{ Grade = "Critical"; Color = "#D13438" }
}

# =============================
# Formatting Helpers
# =============================

<#
.SYNOPSIS
  Formats a byte value into a human-readable size string.
.PARAMETER Bytes
  Storage size in bytes.
#>
function _FormatBytes([double]$Bytes) {
  if ($Bytes -ge 1099511627776) { return "{0:N2} TB" -f ($Bytes / 1099511627776) }
  if ($Bytes -ge 1073741824)    { return "{0:N2} GB" -f ($Bytes / 1073741824) }
  if ($Bytes -ge 1048576)       { return "{0:N2} MB" -f ($Bytes / 1048576) }
  if ($Bytes -ge 1024)          { return "{0:N1} KB" -f ($Bytes / 1024) }
  return "{0:N0} B" -f $Bytes
}

<#
.SYNOPSIS
  Formats a duration in seconds to a human-readable string.
.PARAMETER Seconds
  Duration in seconds.
#>
function _FormatDuration([double]$Seconds) {
  if ($Seconds -ge 3600) {
    $h = [math]::Floor($Seconds / 3600)
    $m = [math]::Floor(($Seconds % 3600) / 60)
    return "${h}h ${m}m"
  }
  if ($Seconds -ge 60) {
    $m = [math]::Floor($Seconds / 60)
    $s = [math]::Floor($Seconds % 60)
    return "${m}m ${s}s"
  }
  return "{0:N0}s" -f $Seconds
}

<#
.SYNOPSIS
  Safely sums a numeric property across a collection.
.PARAMETER collection
  The collection to sum over.
.PARAMETER property
  The property name to sum.
#>
function _SafeSum($collection, [string]$property) {
  $val = ($collection | Measure-Object -Property $property -Sum -ErrorAction SilentlyContinue).Sum
  if ($null -eq $val) { return [double]0 }
  return $val
}

<#
.SYNOPSIS
  Returns a status icon HTML entity for a given status string.
.PARAMETER Status
  Status string (Healthy, Warning, Critical, Success, Error, etc.)
#>
function Get-StatusIcon {
  param([string]$Status)
  switch -Wildcard ($Status) {
    "Healthy"    { return "&#10004;" }
    "Success"    { return "&#10004;" }
    "Warning"    { return "&#9888;" }
    "Critical"   { return "&#10006;" }
    "Error"      { return "&#10006;" }
    "Failed"     { return "&#10006;" }
    "Running*"   { return "&#9654;" }
    "Disabled"   { return "&#9679;" }
    "Info"       { return "&#8505;" }
    default      { return "&#8226;" }
  }
}
