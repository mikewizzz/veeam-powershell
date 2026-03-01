# =========================================================================
# Constants.ps1 - String helpers and tag utilities
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
