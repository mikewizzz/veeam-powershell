<#
.SYNOPSIS
  Get-VeeamM365Sizing.ps1 - Microsoft 365 sizing (users + dataset + growth) with optional
  security posture signals, identity assessment, and optional Exchange deep sizing.

.DESCRIPTION (what this script does, in plain terms)
  1) Pulls Microsoft 365 usage report CSVs via Microsoft Graph (Exchange, OneDrive, SharePoint)
  2) Calculates dataset totals in BOTH decimal (GB/TB) and binary (GiB/TiB) units
  3) Estimates a modeled "MBS" number (clearly labeled as a model, not a measured fact)
  4) Optionally pulls Entra ID/CA/Intune counts, identity signals, license analysis,
     and generates algorithmic findings and recommendations (Full mode)
  5) Writes outputs to a timestamped folder and optionally zips the bundle

QUICK START (simple run)
  .\Get-VeeamM365Sizing.ps1

FULL RUN (includes identity assessment, license analysis, findings & recommendations)
  .\Get-VeeamM365Sizing.ps1 -Full

OPTIONAL (more accurate Exchange dataset; slower)
  .\Get-VeeamM365Sizing.ps1 -IncludeArchive -IncludeRecoverableItems

AUTHENTICATION (2026 Modern Methods)
  - Session reuse: no re-login within token lifetime
  - Supports all Microsoft Graph auth patterns:
    * Delegated (interactive) - default
    * Certificate-based (recommended for production)
    * Azure Managed Identity (zero credentials)
    * Access Token (advanced scenarios)
    * Client Secret (legacy, still supported)
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
  [switch]$Full,                              # Includes identity assessment, license analysis, findings

  # ===== Scope filters =====
  [string]$ADGroup,                           # Include only members of this Entra ID group (DisplayName)
  [string]$ExcludeADGroup,                    # Exclude members of this Entra ID group (DisplayName)
  [ValidateSet(7,30,90,180)][int]$Period = 90,

  # ===== Exchange "deep" sizing (OFF by default; can be slow) =====
  [switch]$IncludeArchive,
  [switch]$IncludeRecoverableItems,

  # ===== MBS Capacity Estimation Parameters (MODELED) =====
  # Microsoft Backup Storage (MBS) is billed BY CONSUMPTION (GB/TB), not per-user.
  # These parameters project Azure storage capacity needed for backup workloads.
  #
  # Formula: MBS Estimate = (Projected Dataset x Retention) + Monthly Change Rate
  #
  [ValidateRange(0.0, 5.0)][double]$AnnualGrowthPct = 0.15,     # Projected annual data growth (15% default)
  [ValidateRange(1.0, 10.0)][double]$RetentionMultiplier = 1.30,# Backup retention factor (1.30 = ~30% overhead)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateExchange = 0.015, # Daily change rate for Exchange (1.5%)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateOneDrive = 0.004, # Daily change rate for OneDrive (0.4%)
  [ValidateRange(0.0, 1.0)][double]$ChangeRateSharePoint = 0.003,# Daily change rate for SharePoint (0.3%)
  [ValidateRange(0.0, 1.0)][double]$BufferPct = 0.10,           # Safety buffer for capacity planning (10%)

  # ===== Output & UX =====
  [string]$OutFolder = ".\VeeamM365SizingOutput",
  [switch]$ExportJson,
  [switch]$ZipBundle = $true,
  [switch]$MaskUserIds,                       # No effect unless exporting identifiers (future-proofing)
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

# =============================
# Load Function Libraries
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Constants.ps1",
  "Charts.ps1",
  "Logging.ps1",
  "GraphApi.ps1",
  "Auth.ps1",
  "DataCollection.ps1",
  "IdentityAssessment.ps1",
  "LicenseAnalysis.ps1",
  "Findings.ps1",
  "Exports.ps1",
  "HtmlReport.ps1"
)
foreach ($lib in $requiredLibs) {
  $libFile = Join-Path $libPath $lib
  if (-not (Test-Path $libFile)) {
    throw "Required library not found: $libFile. Ensure all files in lib/ are present."
  }
  . $libFile
}

# =============================
# Main Execution
# =============================
Write-Log "Starting run (Mode: $(if($Full){'Full'}else{'Quick'}), Period: $Period days)"

# Step 1: Module management
Initialize-RequiredModules

# Step 2: Authenticate to Microsoft Graph
Connect-GraphSession

# Step 3: Get tenant information
Get-TenantInfo

# Step 4: Collect usage data (Exchange, OneDrive, SharePoint, growth, MBS)
Invoke-DataCollection

# Step 5: Identity & security assessment (Full mode only)
Invoke-IdentityAssessment

# Step 6: License analysis (Full mode only)
$script:licenseData = $null
if ($Full) {
  Write-Host "Analyzing license SKUs..." -ForegroundColor Green
  $script:licenseData = Get-LicenseAnalysis
}

# Step 7: Generate findings & recommendations (Full mode only)
$script:findings = Get-Findings
$script:recommendations = Get-Recommendations
$script:readinessScore = Get-ProtectionReadinessScore

# Step 8: Export data files
$inputs  = Export-InputsData
$summary = Export-SummaryData
$wl      = Export-WorkloadData
$sec     = Export-SecurityData

Export-LicenseData
Export-FindingsData
Export-RecommendationsData
Export-NotesFile -inputs $inputs
Export-JsonBundle -inputs $inputs -summary $summary -wl $wl -sec $sec

# Step 9: Generate HTML report
Build-HtmlReport

# Step 10: Zip bundle
if ($ZipBundle) {
  if (Test-Path $outZip) { Remove-Item $outZip -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path (Join-Path $runFolder "*") -DestinationPath $outZip -Force
}

# Step 11: Cleanup
Disconnect-MgGraph | Out-Null
Write-Log "Completed run"

# =============================
# Final console output
# =============================
Write-Host ""
Write-Host "Sizing complete." -ForegroundColor Green
Write-Host "Output folder : $runFolder"
Write-Host "HTML report   : $outHtml"
Write-Host "Summary CSV   : $outSummary"
Write-Host "Workloads CSV : $outWorkload"
Write-Host "Inputs CSV    : $outInputs"
Write-Host "Notes TXT     : $outNotes"
if ($Full) {
  Write-Host "Security CSV  : $outSecurity"
  if ($script:outLicenses)        { Write-Host "Licenses CSV  : $($script:outLicenses)" }
  if ($script:outFindings)        { Write-Host "Findings CSV  : $($script:outFindings)" }
  if ($script:outRecommendations) { Write-Host "Recs CSV      : $($script:outRecommendations)" }
  if ($script:readinessScore -ne $null) {
    Write-Host "Readiness     : $($script:readinessScore)/100" -ForegroundColor $(if($script:readinessScore -ge 70){"Green"}elseif($script:readinessScore -ge 40){"Yellow"}else{"Red"})
  }
}
if ($ExportJson) { Write-Host "JSON bundle   : $outJson" }
if ($ZipBundle)  { Write-Host "ZIP bundle    : $outZip" }
Write-Host ""
