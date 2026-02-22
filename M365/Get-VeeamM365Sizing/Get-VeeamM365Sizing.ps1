<#
.SYNOPSIS
  Get-VeeamM365Sizing.ps1 - Microsoft 365 sizing (users + dataset + growth) with optional
  security posture signals and optional Exchange deep sizing (Archive + Recoverable Items).

.DESCRIPTION (what this script does, in plain terms)
  1) Pulls Microsoft 365 usage report CSVs via Microsoft Graph (Exchange, OneDrive, SharePoint)
  2) Calculates dataset totals in BOTH decimal (GB/TB) and binary (GiB/TiB) units
  3) Estimates a modeled "MBS" number (clearly labeled as a model, not a measured fact)
  4) Optionally pulls lightweight Entra/CA/Intune counts (security posture signals)
  5) Writes outputs to a timestamped folder and optionally zips the bundle

QUICK START (simple run)
  .\Get-VeeamM365Sizing.ps1

FULL RUN (includes posture signals; may require additional Graph consent)
  .\Get-VeeamM365Sizing.ps1 -Full

OPTIONAL (more accurate Exchange dataset; slower)
  .\Get-VeeamM365Sizing.ps1 -IncludeArchive -IncludeRecoverableItems

AUTHENTICATION (2026 Modern Methods)
  - Session reuse: no re-login within token lifetime
  - Supports all Microsoft Graph auth patterns:
    • Delegated (interactive) - default
    • Certificate-based (recommended for production)
    • Azure Managed Identity (zero credentials)
    • Access Token (advanced scenarios)
    • Client Secret (legacy, still supported)
  - Device Code Flow for browser-less environments
  - Automatic scope validation and token refresh

NOTES (critical truth)
  - "MBS Estimate" is a MODEL. It is not a measured billable quantity from Microsoft.
  - Exchange Archive/RIF are not in the standard Graph usage reports; deep options query EXO.
  - Group filtering is supported for Exchange + OneDrive only (SharePoint group filtering is not
    reliably achievable from usage reports without expensive extra graph traversal).

SECURITY
  - By default this script does NOT export per-user identifiers.
  - If you enable optional detail exports in the future, use -MaskUserIds.

#>

[CmdletBinding(DefaultParameterSetName = 'Quick')]
param(
  # ===== Auth =====
  [switch]$UseAppAccess,                      # Use client credentials (app-only) instead of delegated
  [string]$TenantId,
  [string]$ClientId,
  [securestring]$ClientSecret,                # Legacy: prefer certificate auth for production
  [string]$CertificateThumbprint,             # Modern: certificate-based authentication (preferred)
  [string]$CertificateSubjectName,            # Alternative certificate lookup by subject
  [switch]$UseManagedIdentity,                # Modern: Azure Managed Identity (for Azure VMs/containers)
  [switch]$UseDeviceCode,                     # Modern: Device Code flow for interactive scenarios
  [securestring]$AccessToken,                 # Advanced: provide pre-obtained access token

  # ===== Run level =====
  [Parameter(ParameterSetName='Quick')]
  [switch]$Quick,                             # Minimal permissions; fastest path (default behavior)

  [Parameter(ParameterSetName='Full')]
  [switch]$Full,                              # Includes posture signals (more Graph scopes)

  # ===== Scope filters =====
  [string]$ADGroup,                           # Include only members of this Entra ID group (DisplayName)
  [string]$ExcludeADGroup,                    # Exclude members of this Entra ID group (DisplayName)
  [ValidateSet(7,30,90,180)][int]$Period = 90,

  # ===== Exchange "deep" sizing (OFF by default; can be slow) =====
  [switch]$IncludeArchive,
  [switch]$IncludeRecoverableItems,

  # ===== MBS Capacity Estimation Parameters (MODELED) =====
  # Microsoft Backup Storage (MBS) is billed BY CONSUMPTION (GB/TB), not per-user.
  # These parameters project Azure storage capacity needed for Veeam Backup for Microsoft 365.
  # 
  # Why estimate MBS capacity?
  # - Microsoft charges for actual backup storage consumed in Azure (consumption-based pricing)
  # - Customers need to budget for Azure storage costs (not licensing costs)
  # - Backup storage != source data size due to retention, versioning, and incremental changes
  # 
  # Formula: MBS Estimate = (Projected Dataset × Retention) + Monthly Change Rate
  # 
  [ValidateRange(0.0, 5.0)][double]$AnnualGrowthPct = 0.15,     # Projected annual data growth (15% default)
  [ValidateRange(1.0, 10.0)][double]$RetentionMultiplier = 1.30,# Backup retention factor (1.30 = ~30% overhead for versioning)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateExchange = 0.015, # Daily change rate for Exchange (1.5% default)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateOneDrive = 0.004, # Daily change rate for OneDrive (0.4% default)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateSharePoint = 0.003,# Daily change rate for SharePoint (0.3% default)
  [ValidateRange(0.0, 1.0)][double]$BufferPct = 0.10,           # Safety buffer for capacity planning (10% headroom)

  # ===== Output & UX =====
  [string]$OutFolder = ".\VeeamM365SizingOutput",
  [switch]$ExportJson,
  [switch]$ZipBundle = $true,
  [switch]$MaskUserIds,                       # No effect unless exporting identifiers (kept for future-proofing)
  [switch]$SkipModuleInstall,                 # If set, missing modules will error with instructions
  [switch]$EnableTelemetry                    # Local log file in output folder
)

# =============================
# Guardrails / Defaults
# =============================
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# If user didn't specify -Quick or -Full, default to Quick behavior.
if (-not $PSBoundParameters.ContainsKey('Quick') -and -not $PSBoundParameters.ContainsKey('Full')) {
  $Quick = $true
}

# Compute once; referenced throughout the script for logging, CSV, and HTML.
$runMode = if ($Full) { "Full" } else { "Quick" }

# =============================
# Output folder structure
# =============================
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$runFolder = Join-Path $OutFolder "Run-$stamp"
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

$logPath     = Join-Path $runFolder "Veeam-M365-Log-$stamp.txt"
$outHtml     = Join-Path $runFolder "Veeam-M365-Report-$stamp.html"
$outSummary  = Join-Path $runFolder "Veeam-M365-Summary-$stamp.csv"
$outWorkload = Join-Path $runFolder "Veeam-M365-Workloads-$stamp.csv"
$outSecurity = Join-Path $runFolder "Veeam-M365-Security-$stamp.csv"
$outInputs   = Join-Path $runFolder "Veeam-M365-Inputs-$stamp.csv"
$outNotes    = Join-Path $runFolder "Veeam-M365-Notes-$stamp.txt"
$outJson     = Join-Path $runFolder "Veeam-M365-Bundle-$stamp.json"
$outZip      = Join-Path $OutFolder "Veeam-M365-SizingBundle-$stamp.zip"

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

Write-Log "Starting run (Mode: $runMode, Period: $Period days)"

# =============================
# Unit Conversion Constants & Functions
# =============================
# Decimal units (SI): 1 GB = 1,000,000,000 bytes
$GB  = [double]1e9
$TB  = [double]1e12

# Binary units (IEC): 1 GiB = 1,073,741,824 bytes
$GiB = [double]1024*1024*1024
$TiB = [double]1024*1024*1024*1024

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

# =============================
# Helper Functions
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
function Mask-UPN([string]$upn) {
  if (-not $MaskUserIds -or [string]::IsNullOrWhiteSpace($upn)) { return $upn }
  $bytes = [Text.Encoding]::UTF8.GetBytes($upn)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
    return "user_" + $hash.Substring(0,12)
  } finally {
    $sha.Dispose()
  }
}

# =============================
# Microsoft Graph API Functions with Retry Logic
# =============================

<#
.SYNOPSIS
  Executes a scriptblock with exponential backoff retry for transient/throttling errors.
.DESCRIPTION
  Centralised retry engine used by all Graph API callers. Handles Retry-After headers,
  exponential backoff (2^attempt, max 30s), and retryable-error detection.
.PARAMETER Action
  Scriptblock to execute (should call Invoke-MgGraphRequest or equivalent).
.PARAMETER Label
  Human-readable label for log messages (e.g. "Graph GET /users").
.PARAMETER MaxRetries
  Maximum retry attempts (default: 6).
#>
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$Action,
    [string]$Label = "request",
    [int]$MaxRetries = 6
  )
  $attempt = 0
  do {
    try {
      Write-Log $Label
      return (& $Action)
    } catch {
      $attempt++
      $msg = $_.Exception.Message
      $retryAfter = 0
      try {
        if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
          [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
        }
      } catch {}
      $isRetryable = ($msg -match 'Too Many Requests|throttle|429|5\d\d|temporarily unavailable')
      if ($attempt -le $MaxRetries -and $isRetryable) {
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
        Write-Log "Throttled/retryable error: sleeping $sleep sec (attempt $attempt/$MaxRetries)"
        Start-Sleep -Seconds $sleep
      } else {
        throw
      }
    }
  } while ($true)
}

<#
.SYNOPSIS
  Invokes Microsoft Graph API with exponential backoff retry logic for throttling.
.DESCRIPTION
  Wraps Invoke-MgGraphRequest with automatic retry on throttling (429) and transient errors.
  Delegates retry mechanics to Invoke-WithRetry.
.PARAMETER Uri
  The Graph API endpoint URI.
.PARAMETER Method
  HTTP method (GET, POST, PATCH, DELETE).
.PARAMETER Headers
  Optional hashtable of custom headers.
.PARAMETER Body
  Optional request body for POST/PATCH operations.
.PARAMETER MaxRetries
  Maximum number of retry attempts (default: 6).
#>
function Invoke-Graph {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method='GET',
    [hashtable]$Headers,
    $Body,
    [int]$MaxRetries = 6
  )
  $graphParams = @{ Method = $Method; Uri = $Uri }
  if ($Headers) { $graphParams.Headers = $Headers }
  if ($Body)    { $graphParams.Body    = $Body }

  Invoke-WithRetry -Label "Graph $Method $Uri" -MaxRetries $MaxRetries -Action {
    Invoke-MgGraphRequest @graphParams
  }
}

<#
.SYNOPSIS
  Downloads CSV files from Graph API with retry logic for throttling.
.PARAMETER Uri
  The Graph API report endpoint URI.
.PARAMETER OutPath
  Local file path to save the downloaded CSV.
.PARAMETER MaxRetries
  Maximum number of retry attempts (default: 6).
#>
function Invoke-GraphDownloadCsv {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][string]$OutPath,
    [int]$MaxRetries = 6
  )
  Invoke-WithRetry -Label "Graph DOWNLOAD $Uri -> $OutPath" -MaxRetries $MaxRetries -Action {
    Invoke-MgGraphRequest -Uri $Uri -OutputFilePath $OutPath | Out-Null
  }
}

# =============================
# Module management (optional install)
# =============================

<#
.SYNOPSIS
  Ensures a PowerShell module is available: installs if missing and allowed, then imports.
.PARAMETER Name
  Module name to install/import.
#>
function Assert-RequiredModule([string]$Name) {
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    if ($SkipModuleInstall) {
      throw "Missing required module '$Name'. Install with: Install-Module $Name -Scope CurrentUser"
    }
    Write-Log "Installing module $Name"
    Install-Module $Name -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $Name -ErrorAction Stop
}

$RequiredModules = @(
  'Microsoft.Graph.Authentication',
  'Microsoft.Graph.Reports',
  'Microsoft.Graph.Identity.DirectoryManagement'
)
if ($ADGroup -or $ExcludeADGroup) { $RequiredModules += 'Microsoft.Graph.Groups' }

foreach ($m in $RequiredModules) { Assert-RequiredModule $m }

# =============================
# Authentication & Authorization
# =============================

<#
.SYNOPSIS
  Validates that current Microsoft Graph session has required scopes.
.PARAMETER mustHaveScopes
  Array of required scope strings (e.g., "Reports.Read.All").
.NOTES
  Throws an error if any required scopes are missing from the current session.
  User must disconnect and reconnect to consent additional scopes.
#>
function Assert-Scopes([string[]]$mustHaveScopes) {
  $ctx = Get-MgContext
  $have = @()
  try { $have = @($ctx.Scopes) } catch { $have = @() }
  $missing = $mustHaveScopes | Where-Object { $_ -notin $have }
  if ($missing.Count -gt 0) {
    throw "Missing required Graph scopes in this session: $($missing -join ', '). Disconnect and reconnect to consent these scopes."
  }
}

<#
.SYNOPSIS
  Checks if there's a valid, reusable Microsoft Graph session.
.PARAMETER requiredScopes
  Array of scopes that must be present in the session.
.NOTES
  Returns $true if session exists and has all required scopes.
  Returns $false if no session, expired session, or missing scopes.
#>
function Test-GraphSession([string[]]$requiredScopes) {
  try {
    $ctx = Get-MgContext
    if (-not $ctx) { return $false }

    # Check token expiration for delegated/app-only auth (with 5-minute buffer)
    # Note: Managed Identity and Access Token don't have expiration in context
    if ($ctx.AuthType -in @("Delegated", "AppOnly") -and $ctx.TokenExpires -and $ctx.TokenExpires -lt (Get-Date).AddMinutes(5)) {
      Write-Log "Existing session token expires soon: $($ctx.TokenExpires)"
      return $false
    }

    # For app-only auth, check if we have the required scopes
    if ($ctx.AuthType -eq "AppOnly") {
      $haveScopes = @($ctx.Scopes)
      $missing = $requiredScopes | Where-Object { $_ -notin $haveScopes }
      if ($missing.Count -gt 0) {
        Write-Log "Existing app-only session missing scopes: $($missing -join ', ')"
        return $false
      }
    }

    # For delegated auth, scopes are dynamic - we'll validate after connection
    Write-Log "Reusing existing Graph session (type: $($ctx.AuthType), expires: $($ctx.TokenExpires))"
    return $true
  } catch {
    Write-Log "No valid Graph session found: $($_.Exception.Message)"
    return $false
  }
}

if (-not $UseAppAccess) {
  # Determine required scopes based on run mode
  $baseScopes = @("Reports.Read.All","Directory.Read.All","User.Read.All","Organization.Read.All")
  if ($ADGroup -or $ExcludeADGroup) { $baseScopes += "Group.Read.All" }

  if ($Full) {
    # posture signals
    $baseScopes += @(
      "Application.Read.All",
      "Policy.Read.All",
      "DeviceManagementManagedDevices.Read.All",
      "DeviceManagementConfiguration.Read.All"
    )
  }

  # Check if we can reuse existing session
  if (Test-GraphSession -requiredScopes $baseScopes) {
    Write-Host "Reusing existing Microsoft Graph session..." -ForegroundColor Green
  } else {
    # Need to establish new session
    Write-Host "Connecting to Microsoft Graph (delegated)..." -ForegroundColor Green
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch {}

    $connectParams = @{
      Scopes = $baseScopes
      NoWelcome = $true
    }

    # Use device code flow if requested (modern interactive auth)
    if ($UseDeviceCode) {
      $connectParams.UseDeviceCode = $true
    }

    Connect-MgGraph @connectParams
  }

  # Self-check: confirm session includes scopes we asked for
  Assert-Scopes -mustHaveScopes $baseScopes
} else {
  # App-only authentication (service principal)
  $connectParams = @{
    NoWelcome = $true
    TenantId = $TenantId
  }

  # Modern authentication hierarchy (most secure first)
  if ($AccessToken) {
    # Most advanced: pre-obtained access token
    Write-Host "Connecting to Microsoft Graph (access token)..." -ForegroundColor Green
    $connectParams.AccessToken = $AccessToken
  } elseif ($UseManagedIdentity) {
    # Azure Managed Identity (for VMs, containers, functions)
    Write-Host "Connecting to Microsoft Graph (managed identity)..." -ForegroundColor Green
    $connectParams.Identity = $true
  } elseif ($CertificateThumbprint) {
    # Certificate-based authentication (most secure for service principals)
    if (-not $ClientId) { throw "CertificateThumbprint requires -ClientId" }
    Write-Host "Connecting to Microsoft Graph (certificate)..." -ForegroundColor Green
    $connectParams.ClientId = $ClientId
    $connectParams.CertificateThumbprint = $CertificateThumbprint
  } elseif ($CertificateSubjectName) {
    # Alternative certificate lookup
    if (-not $ClientId) { throw "CertificateSubjectName requires -ClientId" }
    Write-Host "Connecting to Microsoft Graph (certificate by subject)..." -ForegroundColor Green
    $connectParams.ClientId = $ClientId
    $connectParams.CertificateSubjectName = $CertificateSubjectName
  } elseif ($ClientSecret) {
    # Legacy: client secret (less secure, but still supported)
    if (-not $ClientId) { throw "ClientSecret requires -ClientId" }
    Write-Host "Connecting to Microsoft Graph (client secret)..." -ForegroundColor Green
    $clientSecretCred = [System.Management.Automation.PSCredential]::new($ClientId, $ClientSecret)
    $connectParams.ClientSecretCredential = $clientSecretCred
  } else {
    throw "For -UseAppAccess please provide one of: -AccessToken, -UseManagedIdentity, -CertificateThumbprint, -CertificateSubjectName, or -ClientSecret/-ClientId"
  }

  Connect-MgGraph @connectParams
}

$ctx = Get-MgContext
$envName = try { $ctx.Environment.Name } catch { "Unknown" }

# Tenant env/type
$TenantCategory = switch ($envName) {
  "AzureUSGovernment" { "US Government (GCC/GCC High/DoD)" }
  "AzureChinaCloud"   { "China (21Vianet)" }
  "AzureCloud"        { "Commercial" }
  default             { "Unknown" }
}

$org = (Get-MgOrganization)[0]
$OrgId = $org.Id
$OrgName = $org.DisplayName
$DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1).Name

Write-Log "Tenant: $OrgName ($OrgId), DefaultDomain: $DefaultDomain, Env: $envName, Category: $TenantCategory"

# =============================
# Group Filtering Functions
# =============================
# Note: Group filtering applies to Exchange and OneDrive only.
# SharePoint group filtering is not supported due to Graph API limitations.

<#
.SYNOPSIS
  Retrieves all user principal names (UPNs) from an Entra ID group.
.PARAMETER GroupName
  Display name of the Entra ID group.
.PARAMETER Required
  If true, throws error when group not found or contains no users.
.NOTES
  Uses transitive membership to include nested group members.
  Filters results to user objects only (excludes devices, service principals).
#>
function Get-GroupUPNs([string]$GroupName, [bool]$Required = $false) {
  if ([string]::IsNullOrWhiteSpace($GroupName)) { return @() }
  $safe = Escape-ODataString $GroupName
  $g = Get-MgGroup -Filter "DisplayName eq '$safe'"
  if (-not $g) {
    if ($Required) { throw "Entra ID group '$GroupName' not found." }
    return @()
  }
  $upns = New-Object System.Collections.Generic.List[string]
  Get-MgGroupTransitiveMember -GroupId $g.Id -All | ForEach-Object {
    if ($_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user') {
      $u = $_.AdditionalProperties['userPrincipalName']
      if ($u) { $upns.Add($u) }
    }
  }
  if ($Required -and $upns.Count -eq 0) { throw "No user UPNs found in group '$GroupName'." }
  return @($upns | Sort-Object -Unique)
}

# Retrieve group membership lists for filtering
$GroupUPNs   = Get-GroupUPNs -GroupName $ADGroup -Required:$false
$ExcludeUPNs = Get-GroupUPNs -GroupName $ExcludeADGroup -Required:$false

<#
.SYNOPSIS
  Applies inclusion and exclusion filters to usage report data based on UPN.
.PARAMETER Data
  Array of report objects (Exchange or OneDrive usage data).
.PARAMETER UpnField
  Name of the field containing the user principal name.
.NOTES
  Always filters out deleted items first.
  Then applies inclusion filter (if ADGroup specified).
  Finally applies exclusion filter (if ExcludeADGroup specified).
#>
function Apply-UpnFilters([object[]]$Data, [string]$UpnField) {
  # Remove deleted items first
  $Data = $Data | Where-Object { $_ -ne $null -and $_.'Is Deleted' -ne 'TRUE' }
  
  # Apply inclusion filter (if specified)
  if ($GroupUPNs -and $GroupUPNs.Count -gt 0) {
    $Data = $Data | Where-Object { $GroupUPNs -contains $_.$UpnField }
  }
  
  # Apply exclusion filter (if specified)
  if ($ExcludeUPNs -and $ExcludeUPNs.Count -gt 0) {
    $Data = $Data | Where-Object { $ExcludeUPNs -notcontains $_.$UpnField }
  }
  
  return $Data
}

# =============================
# Microsoft Graph Usage Reports
# =============================

<#
.SYNOPSIS
  Downloads and imports a Microsoft 365 usage report CSV from Graph API.
.PARAMETER ReportName
  Name of the Graph report (e.g., "getMailboxUsageDetail").
.PARAMETER PeriodDays
  Reporting period in days (7, 30, 90, or 180).
.NOTES
  Reports are saved to the run folder and imported as PowerShell objects.
#>
function Get-GraphReportCsv {
  param([Parameter(Mandatory)][string]$ReportName,[int]$PeriodDays)
  $uri = "https://graph.microsoft.com/v1.0/reports/$ReportName(period='D$PeriodDays')"
  $tmp = Join-Path $runFolder "$ReportName.csv"
  Invoke-GraphDownloadCsv -Uri $uri -OutPath $tmp
  return (Import-Csv $tmp)
}

<#
.SYNOPSIS
  Calculates annualized growth rate from time-series usage data.
.PARAMETER csv
  Array of report objects with 'Report Date', 'Report Period', and target field.
.PARAMETER field
  Name of the numeric field to analyze (e.g., 'Storage Used (Byte)').
.NOTES
  Compares earliest vs latest values in the report period.
  Extrapolates daily change rate to annual percentage.
  Returns 0.0 if insufficient data or invalid values.
#>
function Annualize-GrowthPct {
  param([Parameter(Mandatory)][object[]]$csv,[Parameter(Mandatory)][string]$field)
  $rows = $csv | Sort-Object { [datetime]$_.'Report Date' } -Descending
  if (-not $rows -or $rows.Count -lt 2) { return 0.0 }
  
  $latest   = [double]$rows[0].$field
  $earliest = [double]$rows[-1].$field
  $days     = [int]$rows[0].'Report Period'
  
  if ($days -le 0 -or $latest -le 0) { return 0.0 }
  
  $perDay  = ($latest - $earliest) / $days
  $perYear = $perDay * 365
  $pct     = $perYear / [math]::Max($latest,1)
  
  return [math]::Round($pct, 4)
}

Write-Host "Pulling Microsoft 365 usage reports (Graph)..." -ForegroundColor Green

$exDetail   = Get-GraphReportCsv -ReportName "getMailboxUsageDetail"          -PeriodDays $Period
$exCounts   = Get-GraphReportCsv -ReportName "getMailboxUsageMailboxCounts"  -PeriodDays $Period
$odDetail   = Get-GraphReportCsv -ReportName "getOneDriveUsageAccountDetail" -PeriodDays $Period
$odStorage  = Get-GraphReportCsv -ReportName "getOneDriveUsageStorage"       -PeriodDays $Period
$spDetail   = Get-GraphReportCsv -ReportName "getSharePointSiteUsageDetail"  -PeriodDays $Period
$spStorage  = Get-GraphReportCsv -ReportName "getSharePointSiteUsageStorage" -PeriodDays $Period

# Exchange: filter active, exclude shared from "user list" but keep shared count separately
$exUsersAll = $exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -ne 'Shared' }
$exSharedAll = $exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -eq 'Shared' }

# Apply group filters (Exchange + OneDrive only)
$exUsers   = Apply-UpnFilters $exUsersAll  'User Principal Name'
$exShared  = $exSharedAll  # keep shared independent of group filtering (shared mailboxes aren't "users"; keep them visible)

$odActiveAll = $odDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' }
$odActive    = Apply-UpnFilters $odActiveAll 'Owner Principal Name'

# SharePoint: DO NOT apply group filtering (not reliable from usage report alone)
$spActive = $spDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' }

# Group filtering sanity check (avoid silent wrong results)
if ($ADGroup) {
  # If reports are "anonymized", UPN matching will fail.
  $sampleUpn = ($exUsersAll | Select-Object -First 5).'User Principal Name'
  $looksMasked = $false
  if ($sampleUpn) {
    $maskedCount = ($sampleUpn | Where-Object { $_ -notmatch '@' -or $_ -match '^Anonymous' }).Count
    if ($maskedCount -ge 3) { $looksMasked = $true }
  }
  if ($looksMasked) {
    throw "Your M365 usage reports appear to have user identifiers concealed (masked). Group filtering by UPN will fail. Unmask reports in M365 Admin Center -> Settings -> Org settings -> Services -> Reports -> disable concealed names, then re-run."
  }
  if ($GroupUPNs.Count -gt 0 -and $exUsers.Count -eq 0 -and $odActive.Count -eq 0) {
    throw "ADGroup filtering matched 0 Exchange users and 0 OneDrive accounts. This is usually caused by report masking or an unexpected UPN mismatch. Re-check report settings and group membership."
  }
}

# Unique users to protect (union of Exchange users + OneDrive owners)
$uniqueUPN = @()
$uniqueUPN += @($exUsers.'User Principal Name')
$uniqueUPN += @($odActive.'Owner Principal Name')
$UsersToProtect = (@($uniqueUPN | Where-Object { $_ } | Sort-Object -Unique)).Count

# Source bytes (Graph usage reports)
$exUserBytes   = [double](($exUsers   | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
$exSharedBytes = [double](($exShared  | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
$exPrimaryBytes = [double]($exUserBytes + $exSharedBytes)

$odBytes = [double](($odActive | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
$spBytes = [double](($spActive | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)

# Optional Exchange deep sizing (sequential, reliable)
$archBytes = 0.0
$rifBytes  = 0.0

if ($IncludeArchive -or $IncludeRecoverableItems) {
  Assert-RequiredModule 'ExchangeOnlineManagement'

  Write-Host "Connecting to Exchange Online for deep sizing (Archive/RIF)..." -ForegroundColor Yellow
  try {
    Connect-ExchangeOnline -ShowBanner:$false
  } catch {
    throw "Failed to connect to Exchange Online. If you do not need Archive/RIF sizing, re-run without -IncludeArchive / -IncludeRecoverableItems. Error: $($_.Exception.Message)"
  }

  if ($IncludeArchive) {
    $withArchive = $exUsersAll | Where-Object { $_.'Has Archive' -eq 'TRUE' }  # include all users (not group-filtered) to avoid undercount surprise
    $count = $withArchive.Count
    Write-Host "Measuring Exchange In-Place Archive size for $count mailboxes (sequential)..." -ForegroundColor Yellow

    $i = 0
    foreach ($u in $withArchive) {
      $i++
      if (($i % 25) -eq 0) { Write-Host "  Archive progress: $i / $count" }
      $id = $u.'User Principal Name'
      try {
        $s = Get-EXOMailboxStatistics -Archive -Identity $id -ErrorAction Stop
        if ($s.TotalItemSize -match '\(([^)]+) bytes\)') {
          $archBytes += [double]([int64]($matches[1] -replace ',',''))
        }
      } catch {
        Write-Log "Archive stats failed for $id : $($_.Exception.Message)"
      }
    }
    $exPrimaryBytes += $archBytes
  }

  if ($IncludeRecoverableItems) {
    $allEx = @($exUsersAll + $exSharedAll)
    $count = $allEx.Count
    Write-Host "Measuring Exchange Recoverable Items size for $count mailboxes (sequential)..." -ForegroundColor Yellow

    $recoverableItemsSpecialFolders = @("/Deletions","/Purges","/Versions","/DiscoveryHolds")
    $i = 0
    foreach ($u in $allEx) {
      $i++
      if (($i % 25) -eq 0) { Write-Host "  RIF progress: $i / $count" }
      $id = $u.'User Principal Name'
      if ([string]::IsNullOrWhiteSpace($id)) { continue }
      try {
        $stats = Get-MailboxFolderStatistics -Identity $id -FolderScope RecoverableItems -ErrorAction Stop |
                 Where-Object { $recoverableItemsSpecialFolders -contains $_.FolderPath }
        foreach ($f in $stats) {
          if ($f.FolderSize -match '\(([^)]+) bytes\)') {
            $rifBytes += [double]([int64]($matches[1] -replace ',',''))
          }
        }
      } catch {
        Write-Log "RIF stats failed for $id : $($_.Exception.Message)"
      }
    }
    $exPrimaryBytes += $rifBytes
  }

  Disconnect-ExchangeOnline -Confirm:$false | Out-Null
}

# Growth (annualized, from usage history)
$exGrowth = Annualize-GrowthPct -csv (Get-GraphReportCsv -ReportName "getMailboxUsageStorage" -PeriodDays $Period) -field 'Storage Used (Byte)'
$odGrowth = Annualize-GrowthPct -csv $odStorage -field 'Storage Used (Byte)'
$spGrowth = Annualize-GrowthPct -csv $spStorage -field 'Storage Used (Byte)'

# Convert totals (decimal + binary)
$exGB  = To-GB  $exPrimaryBytes
$odGB  = To-GB  $odBytes
$spGB  = To-GB  $spBytes
$totalGB = [math]::Round($exGB + $odGB + $spGB, 2)

$exGiB = To-GiB $exPrimaryBytes
$odGiB = To-GiB $odBytes
$spGiB = To-GiB $spBytes
$totalGiB = [math]::Round($exGiB + $odGiB + $spGiB, 2)

$totalTB  = [math]::Round($totalGB / 1000, 4)
$totalTiB = [math]::Round($totalGiB / 1024, 4)

# =============================
# Microsoft Backup Storage (MBS) Capacity Estimation
# =============================
# IMPORTANT: This is a CAPACITY MODEL for Azure storage planning, not a licensing calculation.
# Microsoft charges for Veeam Backup for Microsoft 365 by CONSUMPTION (GB/TB of backup storage used).
# 
# Why backup storage > source data:
# - Retention policies keep multiple backup versions over time
# - Incremental backups accumulate daily changes
# - Deleted items remain in retention windows
# 
# This model helps customers:
# 1. Budget Azure storage costs accurately
# 2. Right-size MBS capacity allocation
# 3. Avoid unexpected consumption overages
#

# Calculate daily data change rate (incremental backup size per day)
$dailyChangeGB = ($exGB * $ChangeRateExchange) + ($odGB * $ChangeRateOneDrive) + ($spGB * $ChangeRateSharePoint)
$monthChangeGB = [math]::Round($dailyChangeGB * 30, 2)  # 30 days of incremental changes

# Project dataset growth over next year
$projGB = [math]::Round($totalGB * (1 + $AnnualGrowthPct), 2)

# Apply retention multiplier (accounts for keeping multiple backup generations)
# Example: 1.30 multiplier = base data + 30% overhead for versions/retention
$mbsEstimateGB = [math]::Round(($projGB * $RetentionMultiplier) + $monthChangeGB, 2)

# Add safety buffer for capacity planning (recommended practice)
$suggestedStartGB = [math]::Round($mbsEstimateGB * (1 + $BufferPct), 2)

# =============================
# Security Posture Signals (Full Mode Only)
# =============================

<#
.SYNOPSIS
  Counts entities in Microsoft Graph (users, groups, devices, policies, etc.).
.PARAMETER Path
  Graph API path relative to v1.0 (e.g., "users", "groups").
.NOTES
  Uses $count=true with eventual consistency for efficient counting.
  Returns special strings for permission/availability errors:
  - "access_denied": Insufficient permissions
  - "not_available": Resource not provisioned in tenant
  - "unknown": Unexpected error
  - "present": Entity exists but count unavailable
#>
function Get-GraphEntityCount {
  param([Parameter(Mandatory)][string]$Path)
  $headers = @{ "ConsistencyLevel" = "eventual" }
  $uri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1&`$count=true"
  try {
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    elseif ($resp.value)      { return [int]@($resp.value).Count }
    else                      { return 0 }
  } catch {
    $msg = $_.Exception.Message
    # Permission/consent errors (delegated or app-only)
    if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
      return "access_denied"
    }
    # Resource not available in tenant (e.g., Intune/Conditional Access not provisioned)
    if ($msg -match '404|NotFound|No resource was found') {
      return "not_available"
    }
    try {
      $fallbackUri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1"
      $fallback = Invoke-Graph -Uri $fallbackUri
      if ($fallback.value -and @($fallback.value).Count -gt 0) { return "present" }
      return 0
    } catch {
      $fallbackMsg = $_.Exception.Message
      if ($fallbackMsg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
      if ($fallbackMsg -match '404|NotFound|No resource was found') { return "not_available" }
      return "unknown"
    }
  }
}

$userCount = $null
$groupCount = $null
$appRegCount = $null
$spnCount = $null
$caPolicyCount = $null
$caNamedLocCount = $null
$intuneManagedDevices = $null
$intuneCompliancePolicies = $null
$intuneDeviceConfigurations = $null
$intuneConfigurationPolicies = $null

if ($Full) {
  Write-Host "Collecting posture signals (directory/CA/Intune)..." -ForegroundColor Green
  $userCount       = Get-GraphEntityCount -Path "users"
  $groupCount      = Get-GraphEntityCount -Path "groups"
  $appRegCount     = Get-GraphEntityCount -Path "applications"
  $spnCount        = Get-GraphEntityCount -Path "servicePrincipals"
  $caPolicyCount   = Get-GraphEntityCount -Path "identity/conditionalAccess/policies"
  $caNamedLocCount = Get-GraphEntityCount -Path "identity/conditionalAccess/namedLocations"

  $intuneManagedDevices        = Get-GraphEntityCount -Path "deviceManagement/managedDevices"
  $intuneCompliancePolicies    = Get-GraphEntityCount -Path "deviceManagement/deviceCompliancePolicies"
  $intuneDeviceConfigurations  = Get-GraphEntityCount -Path "deviceManagement/deviceConfigurations"
  $intuneConfigurationPolicies = Get-GraphEntityCount -Path "deviceManagement/configurationPolicies"
}

# =============================
# Inputs export (raw totals + assumptions, no per-user identifiers)
# =============================
$inputs = @(
  [pscustomobject]@{ Key="Mode"; Value=$runMode },
  [pscustomobject]@{ Key="PeriodDays"; Value=$Period },
  [pscustomobject]@{ Key="ADGroup"; Value=($ADGroup ?? "") },
  [pscustomobject]@{ Key="ExcludeADGroup"; Value=($ExcludeADGroup ?? "") },
  [pscustomobject]@{ Key="IncludeArchive"; Value=$IncludeArchive },
  [pscustomobject]@{ Key="IncludeRecoverableItems"; Value=$IncludeRecoverableItems },
  [pscustomobject]@{ Key="AnnualGrowthPct_Model"; Value=$AnnualGrowthPct },
  [pscustomobject]@{ Key="RetentionMultiplier_Model"; Value=$RetentionMultiplier },
  [pscustomobject]@{ Key="ChangeRateExchange_Model"; Value=$ChangeRateExchange },
  [pscustomobject]@{ Key="ChangeRateOneDrive_Model"; Value=$ChangeRateOneDrive },
  [pscustomobject]@{ Key="ChangeRateSharePoint_Model"; Value=$ChangeRateSharePoint },
  [pscustomobject]@{ Key="BufferPct_Heuristic"; Value=$BufferPct },
  [pscustomobject]@{ Key="SharePointGroupFiltering"; Value="Not supported from usage reports (by design)" }
)
$inputs | Export-Csv -NoTypeInformation -Path $outInputs

# =============================
# Summary CSV
# =============================
$summary = [pscustomobject]@{
  ReportDate                = (Get-Date).ToString("s")
  OrgName                   = $OrgName
  OrgId                     = $OrgId
  DefaultDomain             = $DefaultDomain
  GraphEnvironment          = $envName
  TenantCategory            = $TenantCategory
  Mode                      = $runMode

  UsersToProtect            = $UsersToProtect

  Exchange_SourceBytes      = [int64]$exPrimaryBytes
  OneDrive_SourceBytes      = [int64]$odBytes
  SharePoint_SourceBytes    = [int64]$spBytes

  Exchange_SourceGB         = $exGB
  OneDrive_SourceGB         = $odGB
  SharePoint_SourceGB       = $spGB
  Total_SourceGB            = $totalGB

  Exchange_SourceGiB        = $exGiB
  OneDrive_SourceGiB        = $odGiB
  SharePoint_SourceGiB      = $spGiB
  Total_SourceGiB           = $totalGiB

  Total_SourceTB_Decimal    = $totalTB
  Total_SourceTiB_Binary    = $totalTiB

  Exchange_AnnualGrowthPct  = $exGrowth
  OneDrive_AnnualGrowthPct  = $odGrowth
  SharePoint_AnnualGrowthPct= $spGrowth

  # Modeled sizing
  AnnualGrowthPct_Model     = $AnnualGrowthPct
  RetentionMultiplier_Model = $RetentionMultiplier
  MonthChangeGB_Model       = $monthChangeGB
  MbsEstimateGB_Model       = $mbsEstimateGB

  SuggestedStartGB_Heuristic= $suggestedStartGB
  BufferPct_Heuristic       = $BufferPct

  IncludeArchiveGB_Measured = (To-GB $archBytes)
  IncludeRecoverableGB_Measured = (To-GB $rifBytes)

  # Posture signals (Full only)
  Dir_UserCount             = $userCount
  Dir_GroupCount            = $groupCount
  Dir_AppRegistrations      = $appRegCount
  Dir_ServicePrincipals     = $spnCount
  CA_PolicyCount            = $caPolicyCount
  CA_NamedLocations         = $caNamedLocCount
  Intune_ManagedDevices        = $intuneManagedDevices
  Intune_CompliancePolicies    = $intuneCompliancePolicies
  Intune_DeviceConfigurations  = $intuneDeviceConfigurations
  Intune_ConfigurationPolicies = $intuneConfigurationPolicies
}
$summary | Export-Csv -NoTypeInformation -Path $outSummary

# =============================
# Workloads CSV (totals only)
# =============================
$spFiles = ($spActive | Measure-Object -Property 'File Count' -Sum).Sum

$wl = @(
  [pscustomobject]@{
    Workload         = "Exchange"
    Objects          = $exUsers.Count
    SharedObjects    = $exShared.Count
    SourceBytes      = [int64]$exPrimaryBytes
    SourceGB         = $exGB
    SourceGiB        = $exGiB
    AnnualGrowthPct  = $exGrowth
    Notes            = "Includes shared mailbox bytes from usage report; Archive/RIF added only if enabled."
  },
  [pscustomobject]@{
    Workload         = "OneDrive"
    Objects          = $odActive.Count
    SharedObjects    = $null
    SourceBytes      = [int64]$odBytes
    SourceGB         = $odGB
    SourceGiB        = $odGiB
    AnnualGrowthPct  = $odGrowth
    Notes            = "Accounts from usage detail; group filter applies to OneDrive owners only."
  },
  [pscustomobject]@{
    Workload         = "SharePoint"
    Objects          = $spActive.Count
    SharedObjects    = $spFiles
    SourceBytes      = [int64]$spBytes
    SourceGB         = $spGB
    SourceGiB        = $spGiB
    AnnualGrowthPct  = $spGrowth
    Notes            = "SharePoint group filtering not supported from usage reports; totals are tenant-wide (or site-wide view)."
  }
)
$wl | Export-Csv -NoTypeInformation -Path $outWorkload

# =============================
# Security CSV (Full mode only, counts only)
# =============================
$sec = @()
if ($Full) {
  $sec += @(
    [pscustomobject]@{ Section="Directory"; Name="Users"; Value=$userCount },
    [pscustomobject]@{ Section="Directory"; Name="Groups"; Value=$groupCount },
    [pscustomobject]@{ Section="Directory"; Name="AppRegistrations"; Value=$appRegCount },
    [pscustomobject]@{ Section="Directory"; Name="ServicePrincipals"; Value=$spnCount },
    [pscustomobject]@{ Section="ConditionalAccess"; Name="Policies"; Value=$caPolicyCount },
    [pscustomobject]@{ Section="ConditionalAccess"; Name="NamedLocations"; Value=$caNamedLocCount },
    [pscustomobject]@{ Section="Intune"; Name="ManagedDevices"; Value=$intuneManagedDevices },
    [pscustomobject]@{ Section="Intune"; Name="DeviceCompliancePolicies"; Value=$intuneCompliancePolicies },
    [pscustomobject]@{ Section="Intune"; Name="DeviceConfigurations"; Value=$intuneDeviceConfigurations },
    [pscustomobject]@{ Section="Intune"; Name="ConfigurationPolicies"; Value=$intuneConfigurationPolicies }
  )
}
$sec | Export-Csv -NoTypeInformation -Path $outSecurity

# =============================
# Optional JSON bundle
# =============================
if ($ExportJson) {
  $bundle = [ordered]@{
    ReportDate = (Get-Date).ToString("s")
    Tenant = [ordered]@{
      OrgName = $OrgName
      OrgId = $OrgId
      DefaultDomain = $DefaultDomain
      GraphEnvironment = $envName
      TenantCategory = $TenantCategory
      Mode = $runMode
    }
    Inputs = $inputs
    Summary = $summary
    Workloads = $wl
    Security = $sec
  }
  ($bundle | ConvertTo-Json -Depth 6) | Set-Content -Path $outJson -Encoding UTF8
}

# =============================
# Notes file (Measured vs Modeled)
# =============================
@"
Veeam M365 Sizing Notes ($stamp)

========================================
WHAT IS MBS (MICROSOFT BACKUP STORAGE)?
========================================
Microsoft Backup Storage (MBS) is CONSUMPTION-BASED PRICING for Veeam Backup for Microsoft 365.
- Microsoft charges by GB/TB of backup storage consumed in Azure (not per-user licensing)
- Backup storage is larger than source data due to retention, versioning, and incremental changes
- This assessment helps you budget Azure storage costs and right-size capacity allocation

========================================
MEASURED DATA (from Microsoft reports)
========================================
- Exchange / OneDrive / SharePoint dataset totals: Microsoft Graph Reports CSVs
- Exchange Archive and Recoverable Items: Measured directly from Exchange Online (if enabled)
  Note: Archive/RIF are NOT included in Graph usage reports

========================================
MBS CAPACITY ESTIMATION (MODELED)
========================================
This is a CAPACITY PLANNING MODEL for Azure storage, not a measured billable quantity.

Formula:
  ProjectedDatasetGB = TotalSourceGB × (1 + AnnualGrowthPct_Model)
  MonthlyChangeGB    = 30 × (ExGB×ChangeRateExchange + OdGB×ChangeRateOneDrive + SpGB×ChangeRateSharePoint)
  MbsEstimateGB      = (ProjectedDatasetGB × RetentionMultiplier_Model) + MonthlyChangeGB
  SuggestedStartGB   = MbsEstimateGB × (1 + BufferPct_Heuristic)

Why these parameters matter:
- AnnualGrowthPct: Your data grows over time; plan for future capacity needs
- RetentionMultiplier: Backups keep multiple versions; storage > source data size
- ChangeRate: Incremental backups accumulate daily changes
- BufferPct: Safety headroom to avoid capacity shortfalls

IMPORTANT: This model helps with CAPACITY PLANNING and COST BUDGETING for Azure storage consumption.

GROUP FILTERING:
- ADGroup / ExcludeADGroup filters apply to Exchange user mailboxes and OneDrive owners only.
- SharePoint usage reports do not reliably support "group membership filtering" without expensive graph traversal, so SharePoint is tenant-wide in this script by design.

OUTPUTS:
- Summary CSV: $outSummary
- Workloads CSV: $outWorkload
- Security CSV: $outSecurity
- Inputs CSV: $outInputs
$(if($ExportJson){"- JSON bundle: $outJson"}else{""})
"@ | Set-Content -Path $outNotes -Encoding UTF8

# =============================
# HTML Report Generation
# =============================
# Generates a professional Microsoft Fluent Design System report
# with comprehensive sizing data, methodology, and artifacts list.

<#
.SYNOPSIS
  Formats a decimal value as a percentage string (e.g., 0.15 -> "15.00%").
#>
function Format-Pct([double]$p) { "{0:P2}" -f $p }

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Microsoft 365 Backup Sizing Assessment | Veeam</title>
<style>
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --ms-blue-light: #50E6FF;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --veeam-green: #00B336;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
  -webkit-font-smoothing: antialiased;
  -moz-osx-font-smoothing: grayscale;
}

.container {
  max-width: 1440px;
  margin: 0 auto;
  padding: 40px 32px;
}

/* Header */
.header {
  background: white;
  border-left: 4px solid var(--ms-blue);
  padding: 32px;
  margin-bottom: 32px;
  box-shadow: var(--shadow-depth-4);
  border-radius: 2px;
}

.header-title {
  font-size: 28px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 8px;
  letter-spacing: -0.02em;
}

.header-subtitle {
  font-size: 16px;
  color: var(--ms-gray-90);
  font-weight: 400;
}

.badge {
  display: inline-block;
  padding: 4px 12px;
  background: var(--ms-blue);
  color: white;
  border-radius: 12px;
  font-size: 12px;
  font-weight: 600;
  margin-left: 12px;
  text-transform: uppercase;
  letter-spacing: 0.05em;
}

/* Tenant Info */
.tenant-info {
  background: white;
  padding: 24px 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}

.tenant-info-title {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--ms-gray-90);
  margin-bottom: 12px;
}

.tenant-info-row {
  display: flex;
  flex-wrap: wrap;
  gap: 24px;
  padding: 8px 0;
  border-bottom: 1px solid var(--ms-gray-30);
}

.tenant-info-row:last-child {
  border-bottom: none;
}

.tenant-info-item {
  display: flex;
  gap: 8px;
}

.tenant-info-label {
  color: var(--ms-gray-90);
  font-weight: 400;
}

.tenant-info-value {
  color: var(--ms-gray-160);
  font-weight: 600;
}

/* KPI Cards */
.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 24px;
  margin-bottom: 32px;
}

.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
  transition: all 0.2s ease;
  border-top: 3px solid var(--ms-blue);
}

.kpi-card:hover {
  box-shadow: var(--shadow-depth-8);
  transform: translateY(-2px);
}

.kpi-card:nth-child(4) {
  border-top-color: var(--veeam-green);
}

.kpi-label {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--ms-gray-90);
  margin-bottom: 12px;
}

.kpi-value {
  font-size: 36px;
  font-weight: 600;
  color: var(--ms-gray-160);
  line-height: 1.2;
  margin-bottom: 8px;
}

.kpi-subtext {
  font-size: 13px;
  color: var(--ms-gray-90);
  font-weight: 400;
}

/* Section */
.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}

.section-title {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 2px solid var(--ms-gray-30);
}

/* Tables */
.table-container {
  overflow-x: auto;
  margin-top: 16px;
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}

thead {
  background: var(--ms-gray-20);
}

th {
  padding: 12px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}

td {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

tbody tr:hover {
  background: var(--ms-gray-10);
}

tbody tr:last-child td {
  border-bottom: none;
}

/* Info Cards */
.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--ms-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}

.info-card-title {
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 8px;
  font-size: 14px;
}

.info-card-text {
  color: var(--ms-gray-90);
  font-size: 13px;
  line-height: 1.6;
  margin-bottom: 8px;
}

.info-card-text:last-child {
  margin-bottom: 0;
}

/* Code Block */
.code-block {
  background: var(--ms-gray-160);
  color: var(--ms-blue-light);
  padding: 20px 24px;
  border-radius: 2px;
  font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
  font-size: 13px;
  line-height: 1.8;
  overflow-x: auto;
  margin-top: 16px;
  box-shadow: inset 0 2px 4px rgba(0,0,0,0.1);
}

.code-line {
  display: block;
  white-space: nowrap;
}

/* File List */
.file-list {
  list-style: none;
  padding: 0;
  margin: 16px 0 0 0;
}

.file-list li {
  padding: 10px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-130);
  font-size: 13px;
  display: flex;
  align-items: center;
  gap: 12px;
}

.file-list li:last-child {
  border-bottom: none;
}

.file-list li::before {
  content: "📄";
  font-size: 16px;
}

.file-path {
  color: var(--ms-gray-90);
  font-family: 'Consolas', monospace;
  font-size: 12px;
}

/* Footer */
.footer {
  text-align: center;
  padding: 32px 0;
  color: var(--ms-gray-90);
  font-size: 12px;
}

/* Responsive */
@media (max-width: 768px) {
  .container {
    padding: 20px 16px;
  }
  
  .header {
    padding: 20px;
  }
  
  .header-title {
    font-size: 22px;
  }
  
  .kpi-grid {
    grid-template-columns: 1fr;
  }
  
  .section {
    padding: 20px;
  }
  
  .tenant-info-row {
    flex-direction: column;
    gap: 12px;
  }
}

@media print {
  body {
    background: white;
  }
  
  .container {
    max-width: 100%;
  }
  
  .kpi-card, .section, .tenant-info {
    box-shadow: none;
    border: 1px solid var(--ms-gray-30);
  }
  
  .kpi-card:hover {
    transform: none;
  }
}
</style>
</head>
<body>

<div class="container">
  <div class="header">
    <h1 class="header-title">
      Microsoft 365 Backup Sizing Assessment
      <span class="badge">$runMode</span>
    </h1>
    <div class="header-subtitle">Generated: $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm") UTC</div>
  </div>

  <div class="tenant-info">
    <div class="tenant-info-title">Tenant Information</div>
    <div class="tenant-info-row">
      <div class="tenant-info-item">
        <span class="tenant-info-label">Organization:</span>
        <span class="tenant-info-value">$OrgName</span>
      </div>
      <div class="tenant-info-item">
        <span class="tenant-info-label">Tenant ID:</span>
        <span class="tenant-info-value">$OrgId</span>
      </div>
    </div>
    <div class="tenant-info-row">
      <div class="tenant-info-item">
        <span class="tenant-info-label">Default Domain:</span>
        <span class="tenant-info-value">$DefaultDomain</span>
      </div>
      <div class="tenant-info-item">
        <span class="tenant-info-label">Environment:</span>
        <span class="tenant-info-value">$envName</span>
      </div>
      <div class="tenant-info-item">
        <span class="tenant-info-label">Category:</span>
        <span class="tenant-info-value">$TenantCategory</span>
      </div>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">Users to Protect</div>
      <div class="kpi-value">$UsersToProtect</div>
      <div class="kpi-subtext">Active user accounts</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Total Dataset</div>
      <div class="kpi-value">$totalTB TB</div>
      <div class="kpi-subtext">$totalGB GB | $totalTiB TiB (binary)</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Projected Growth</div>
      <div class="kpi-value">$(Format-Pct $AnnualGrowthPct)</div>
      <div class="kpi-subtext">Annual growth rate (modeled)</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Recommended MBS</div>
      <div class="kpi-value">$suggestedStartGB GB</div>
      <div class="kpi-subtext">Modeled estimate: $mbsEstimateGB GB + $(Format-Pct $BufferPct) buffer</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Workload Analysis</h2>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Workload</th>
            <th>Objects</th>
            <th>Secondary</th>
            <th>Source (GB)</th>
            <th>Source (GiB)</th>
            <th>Annual Growth</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>Exchange Online</strong></td>
            <td>$($exUsers.Count)</td>
            <td>$($exShared.Count) shared</td>
            <td>$exGB</td>
            <td>$exGiB</td>
            <td>$(Format-Pct $exGrowth)</td>
            <td>Archive/RIF included only if enabled</td>
          </tr>
          <tr>
            <td><strong>OneDrive for Business</strong></td>
            <td>$($odActive.Count)</td>
            <td>—</td>
            <td>$odGB</td>
            <td>$odGiB</td>
            <td>$(Format-Pct $odGrowth)</td>
            <td>Filtered by AD group (if specified)</td>
          </tr>
          <tr>
            <td><strong>SharePoint Online</strong></td>
            <td>$($spActive.Count)</td>
            <td>$spFiles files</td>
            <td>$spGB</td>
            <td>$spGiB</td>
            <td>$(Format-Pct $spGrowth)</td>
            <td>Tenant-wide (no group filtering)</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">📊 Measured Data</div>
      <div class="info-card-text">
        Dataset totals are sourced from Microsoft Graph usage reports ($Period-day period). Exchange Archive and Recoverable Items are measured directly from Exchange Online when enabled, as they are not included in standard Graph reports.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">💰 Understanding MBS (Microsoft Backup Storage)</div>
      <div class="info-card-text">
        <strong>MBS is consumption-based pricing:</strong> Microsoft charges for Veeam Backup for Microsoft 365 by the GB/TB of backup storage actually consumed in Azure, not per-user licensing.
      </div>
      <div class="info-card-text">
        <strong>Why backup storage ≠ source data:</strong> Backup storage is larger than source data due to retention policies (keeping multiple versions), incremental changes accumulating over time, and deleted items remaining within retention windows.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">📈 MBS Capacity Estimation (Modeled)</div>
      <div class="info-card-text">
        This assessment provides a <strong>capacity planning model</strong> to help you budget Azure storage costs and right-size your MBS allocation. The estimate incorporates projected growth, retention multipliers, daily change rates, and a safety buffer. These are sizing recommendations for planning purposes, not measured billable quantities.
      </div>
    </div>
    <div class="code-block">
      <span class="code-line">ProjectedDatasetGB = TotalSourceGB × (1 + AnnualGrowthPct)</span>
      <span class="code-line">MonthlyChangeGB = 30 × (ExGB×ChangeRateExchange + OdGB×ChangeRateOneDrive + SpGB×ChangeRateSharePoint)</span>
      <span class="code-line">MbsEstimateGB = (ProjectedDatasetGB × RetentionMultiplier) + MonthlyChangeGB</span>
      <span class="code-line">RecommendedMBS = MbsEstimateGB × (1 + BufferPct)</span>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Sizing Parameters</h2>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Parameter</th>
            <th>Value</th>
          </tr>
        </thead>
        <tbody>
          <tr><td>Annual Growth Rate (Modeled)</td><td>$(Format-Pct $AnnualGrowthPct)</td></tr>
          <tr><td>Retention Multiplier (Modeled)</td><td>$RetentionMultiplier</td></tr>
          <tr><td>Exchange Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateExchange)</td></tr>
          <tr><td>OneDrive Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateOneDrive)</td></tr>
          <tr><td>SharePoint Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateSharePoint)</td></tr>
          <tr><td>Capacity Buffer (Heuristic)</td><td>$(Format-Pct $BufferPct)</td></tr>
          <tr><td>Report Period</td><td>$Period days</td></tr>
          <tr><td>Include AD Group</td><td>$([string]::IsNullOrWhiteSpace($ADGroup) ? "None" : $ADGroup)</td></tr>
          <tr><td>Exclude AD Group</td><td>$([string]::IsNullOrWhiteSpace($ExcludeADGroup) ? "None" : $ExcludeADGroup)</td></tr>
          <tr><td>Archive Mailboxes</td><td>$(if($IncludeArchive){"Included"}else{"Not included"})</td></tr>
          <tr><td>Recoverable Items</td><td>$(if($IncludeRecoverableItems){"Included"}else{"Not included"})</td></tr>
        </tbody>
      </table>
    </div>
  </div>

$(if($Full){
@"
  <div class="section">
    <h2 class="section-title">Security Posture (Full Mode)</h2>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Category</th>
            <th>Metric</th>
            <th>Value</th>
          </tr>
        </thead>
        <tbody>
          <tr><td><strong>Directory</strong></td><td>Users</td><td>$userCount</td></tr>
          <tr><td><strong>Directory</strong></td><td>Groups</td><td>$groupCount</td></tr>
          <tr><td><strong>Directory</strong></td><td>App Registrations</td><td>$appRegCount</td></tr>
          <tr><td><strong>Directory</strong></td><td>Service Principals</td><td>$spnCount</td></tr>
          <tr><td><strong>Conditional Access</strong></td><td>Policies</td><td>$caPolicyCount</td></tr>
          <tr><td><strong>Conditional Access</strong></td><td>Named Locations</td><td>$caNamedLocCount</td></tr>
          <tr><td><strong>Intune</strong></td><td>Managed Devices</td><td>$intuneManagedDevices</td></tr>
          <tr><td><strong>Intune</strong></td><td>Compliance Policies</td><td>$intuneCompliancePolicies</td></tr>
          <tr><td><strong>Intune</strong></td><td>Device Configurations</td><td>$intuneDeviceConfigurations</td></tr>
          <tr><td><strong>Intune</strong></td><td>Configuration Policies</td><td>$intuneConfigurationPolicies</td></tr>
        </tbody>
      </table>
    </div>
  </div>
"@
} else {""})

  <div class="section">
    <h2 class="section-title">Generated Artifacts</h2>
    <div class="file-list">
      <div class="file-item">📄 <strong>Summary CSV:</strong> $(Split-Path $outSummary -Leaf)</div>
      <div class="file-item">📄 <strong>Workloads CSV:</strong> $(Split-Path $outWorkload -Leaf)</div>
      <div class="file-item">📄 <strong>Security CSV:</strong> $(Split-Path $outSecurity -Leaf)</div>
      <div class="file-item">📄 <strong>Inputs CSV:</strong> $(Split-Path $outInputs -Leaf)</div>
      <div class="file-item">📄 <strong>Notes TXT:</strong> $(Split-Path $outNotes -Leaf)</div>
      $(if ($ExportJson) {"<div class='file-item'>📄 <strong>JSON Bundle:</strong> $(Split-Path $outJson -Leaf)</div>"})
    </div>
  </div>

  <footer class="footer">
    <div class="footer-text">Generated by Veeam M365 Sizing Tool | $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
    <div class="footer-text">Microsoft 365 Backup Assessment Report</div>
  </footer>
</div>

</body>
</html>
"@

$html | Set-Content -Path $outHtml -Encoding UTF8

# =============================
# Zip bundle (runbook-friendly)
# =============================
if ($ZipBundle) {
  if (Test-Path $outZip) { Remove-Item $outZip -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path (Join-Path $runFolder "*") -DestinationPath $outZip -Force
}

Disconnect-MgGraph | Out-Null
Write-Log "Completed run"

# =============================
# Final console output (simple)
# =============================
Write-Host ""
Write-Host "Sizing complete." -ForegroundColor Green
Write-Host "Output folder : $runFolder"
Write-Host "HTML report   : $outHtml"
Write-Host "Summary CSV   : $outSummary"
Write-Host "Workloads CSV : $outWorkload"
Write-Host "Inputs CSV    : $outInputs"
Write-Host "Notes TXT     : $outNotes"
if ($Full) { Write-Host "Security CSV  : $outSecurity" }
if ($ExportJson) { Write-Host "JSON bundle   : $outJson" }
if ($ZipBundle)  { Write-Host "ZIP bundle    : $outZip" }
Write-Host ""
