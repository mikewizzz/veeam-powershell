# =========================================================================
# Constants.ps1 - Unit conversions, thresholds, and helper functions
# =========================================================================

# Decimal units (SI): 1 GB = 1,000,000,000 bytes
$GB  = [double]1e9
$TB  = [double]1e12

# Binary units (IEC): 1 GiB = 1,073,741,824 bytes
$GiB = [double]1024*1024*1024
$TiB = [double]1024*1024*1024*1024

# =============================
# Findings / Threshold Constants
# =============================
$MFA_THRESHOLD_HIGH   = 0.80   # Below 80% MFA = High severity
$MFA_THRESHOLD_MEDIUM = 0.95   # Below 95% MFA = Medium severity
$ADMIN_THRESHOLD      = 5      # More than 5 Global Admins = Medium severity
$STALE_THRESHOLD_PCT  = 0.10   # More than 10% stale accounts = Medium severity
$STALE_DAYS           = 90     # Accounts inactive for 90+ days
$CA_POLICY_THRESHOLD  = 3      # Fewer than 3 CA policies = Medium severity

# =============================
# Zero Trust Maturity Thresholds
# =============================
$ZT_ADVANCED_THRESHOLD  = 67   # 67+ = Advanced maturity
$ZT_DEVELOPING_THRESHOLD = 34  # 34-66 = Developing maturity; below 34 = Initial

# =============================
# Copilot SKU Part Numbers
# =============================
$COPILOT_SKU_PATTERNS = @(
  "Microsoft_365_Copilot",
  "COPILOT_*",
  "M365_COPILOT_*",
  "SPE_E5_COPILOT*"
)

# =============================
# Copilot Sizing Multipliers
# =============================
$COPILOT_DATA_MULTIPLIER     = 1.15   # 15% additional data generation per Copilot user
$COPILOT_EXCHANGE_MULTIPLIER = 1.20   # 20% more Exchange activity per Copilot user
$COPILOT_ONEDRIVE_MULTIPLIER = 1.10   # 10% more OneDrive content per Copilot user

# =============================
# Unit Conversion Functions
# =============================

<#
.SYNOPSIS
  Convert bytes to decimal/binary units with appropriate rounding.
.PARAMETER bytes
  Number of bytes to convert.
#>
function To-GB([double]$bytes)  { [math]::Round($bytes / $GB, 2) }
function To-TB([double]$bytes)  { [math]::Round($bytes / $TB, 4) }
function To-GiB([double]$bytes) { [math]::Round($bytes / $GiB, 2) }
function To-TiB([double]$bytes) { [math]::Round($bytes / $TiB, 4) }

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
  Escapes single quotes in OData filter strings to prevent query errors.
.PARAMETER s
  The string to escape.
.EXAMPLE
  Escape-ODataString "O'Brien" returns "O''Brien"
#>
function Escape-ODataString([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  return $s.Replace("'", "''")
}

<#
.SYNOPSIS
  Masks user principal names using SHA256 hashing for privacy.
.PARAMETER upn
  The user principal name to mask.
.NOTES
  Only masks if -MaskUserIds switch is enabled. Returns first 12 chars of hash.
#>
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

function Mask-UPN([string]$upn) {
  if (-not $MaskUserIds -or [string]::IsNullOrWhiteSpace($upn)) { return $upn }
  $bytes = [Text.Encoding]::UTF8.GetBytes($upn)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  $hash  = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  return "user_" + $hash.Substring(0,12)
}
