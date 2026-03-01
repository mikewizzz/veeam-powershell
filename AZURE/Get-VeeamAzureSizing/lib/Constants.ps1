# =========================================================================
# Constants.ps1 - Unit conversions, formatting helpers, and tag utilities
# =========================================================================

# Decimal units (SI): 1 GB = 1,000,000,000 bytes
$GB  = [double]1e9
$TB  = [double]1e12

# Binary units (IEC): 1 GiB = 1,073,741,824 bytes
$GiB = [double]1024*1024*1024
$TiB = [double]1024*1024*1024*1024

# =============================
# Unit Conversion Functions
# =============================

<#
.SYNOPSIS
  Converts bytes to decimal gigabytes.
.PARAMETER Bytes
  Number of bytes to convert.
#>
function Format-BytesToGB {
  param([Parameter(Mandatory=$true)][int64]$Bytes)
  [math]::Round($Bytes / 1GB, 2)
}

<#
.SYNOPSIS
  Converts bytes to decimal terabytes.
.PARAMETER Bytes
  Number of bytes to convert.
#>
function Format-BytesToTB {
  param([Parameter(Mandatory=$true)][int64]$Bytes)
  [math]::Round($Bytes / 1TB, 3)
}

<#
.SYNOPSIS
  Formats a GB value with the most readable unit (MB, GB, or TB).
.PARAMETER gb
  Value in decimal gigabytes.
.EXAMPLE
  Format-Storage 0.04  returns "40 MB"
  Format-Storage 2.5   returns "2.50 GB"
  Format-Storage 1200  returns "1.20 TB"
#>
function Format-Storage([double]$gb) {
  if ($gb -lt 0.01) { return "{0:N0} MB" -f ($gb * 1000) }
  if ($gb -lt 1)    { return "{0:N0} MB" -f ($gb * 1000) }
  if ($gb -ge 1000) { return "{0:N2} TB" -f ($gb / 1000) }
  return "{0:N2} GB" -f $gb
}

# =============================
# String Helper Functions
# =============================

<#
.SYNOPSIS
  Encodes a string for safe embedding in HTML to prevent XSS.
.PARAMETER s
  The string to encode.
.NOTES
  Uses .NET WebUtility for proper HTML entity encoding.
#>
function Escape-Html([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  return [System.Net.WebUtility]::HtmlEncode($s)
}

<#
.SYNOPSIS
  Flattens a hashtable of tags into a semicolon-delimited string.
.PARAMETER tags
  Hashtable of key-value tag pairs.
.EXAMPLE
  ConvertTo-FlatTags @{ Environment="Prod"; Owner="IT" }
  Returns "Environment=Prod;Owner=IT"
#>
function ConvertTo-FlatTags($tags) {
  if (-not $tags) { return "" }
  ($tags.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
}
