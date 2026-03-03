# =========================================================================
# Helpers.ps1 - String helpers, tag utilities, and shared math functions
# =========================================================================

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
function _EscapeHtml([string]$s) {
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

# =============================
# Math Helper Functions
# =============================

<#
.SYNOPSIS
  Safely sums a numeric property across a collection, returning 0 for null or empty input.
.PARAMETER collection
  The collection to sum over.
.PARAMETER property
  The property name to sum.
.OUTPUTS
  [double] The sum, or 0 if the collection is null/empty.
#>
function _SafeSum($collection, [string]$property) {
  $val = ($collection | Measure-Object -Property $property -Sum -ErrorAction SilentlyContinue).Sum
  if ($null -eq $val) { return [double]0 }
  return $val
}
