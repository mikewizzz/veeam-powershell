# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Veeam Backup for Azure - Health Check & Compliance Assessment Tool

.DESCRIPTION
  Production-grade health check that connects directly to the VBA appliance
  REST API (v8.1) for comprehensive health assessment.

  WHAT THIS SCRIPT DOES:
  1. Authenticates to the VBA appliance via OAuth2 or bearer token
  2. Validates system health (services, version, state)
  3. Checks license compliance (type, expiry, instance usage)
  4. Runs VBA's built-in configuration check (roles, workers, repos, MFA, SSO)
  5. Analyzes protection coverage (VMs, SQL, File Shares, Cosmos DB)
  6. Evaluates backup policy health (status, errors, SLA compliance)
  7. Analyzes session success rates and identifies failures
  8. Audits repository configuration (encryption, immutability, status)
  9. Checks worker health and infrastructure bottlenecks
  10. Validates configuration backup status
  11. Calculates weighted health score with actionable recommendations
  12. Generates professional HTML report with Microsoft Fluent Design System
  13. Exports all findings as structured CSV for further analysis

  QUICK START:
  .\Get-VBAHealthCheck.ps1 -Server vba.example.com -SkipCertificateCheck

  AUTHENTICATION:
  - Credential: Username/password via PSCredential (interactive prompt if omitted)
  - Token: Pre-obtained bearer token for automation scenarios
  - Self-signed certs: Use -SkipCertificateCheck for VBA appliances with self-signed certificates

  ZERO DEPENDENCIES:
  No Azure PowerShell modules required. This tool connects directly to the VBA
  appliance REST API. Only needs PowerShell 5.1+ and network access to port 443.

.PARAMETER Server
  VBA appliance hostname or IP address (required).

.PARAMETER Port
  API port (default: 443).

.PARAMETER Credential
  PSCredential for OAuth2 Password grant authentication. If omitted and -Token
  is not provided, you will be prompted interactively.

.PARAMETER Token
  Pre-obtained bearer token. Alternative to -Credential for automation.

.PARAMETER SkipCertificateCheck
  Bypass TLS certificate validation (for self-signed certificates).

.PARAMETER RPOThresholdHours
  Maximum acceptable hours since last successful backup (default: 24).

.PARAMETER SLATargetPercent
  Target SLA compliance percentage (default: 95).

.PARAMETER ConfigBackupAgeDays
  Maximum acceptable age in days for configuration backup (default: 7).

.PARAMETER LicenseExpiryWarningDays
  Days before license expiry to trigger a warning (default: 30).

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VBAHealthCheck_[timestamp]).

.PARAMETER SkipHTML
  Skip HTML report generation.

.PARAMETER SkipZip
  Skip ZIP archive creation.

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -Server vba.example.com -SkipCertificateCheck
  # Interactive login with self-signed cert bypass

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -Server 10.0.0.5 -Credential (Get-Credential)
  # Explicit credential

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -Server vba.corp.com -Token "eyJ..." -SkipHTML
  # Automation with pre-obtained token, CSV-only output

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -Server vba.example.com -RPOThresholdHours 12 -SLATargetPercent 99
  # Stricter thresholds

.NOTES
  Version: 2.0.0
  Author: Community Contributors
  Requires: PowerShell 5.1 or later
  Modules: None (connects directly to VBA REST API)

  DISCLAIMER: This is a community-maintained tool, not an official Veeam product.
  All operations are read-only except triggering the built-in configuration check.
#>

[CmdletBinding()]
param(
  # ===== Connection =====
  [Parameter(Mandatory=$true)]
  [string]$Server,

  [int]$Port = 443,

  # ===== Authentication =====
  [System.Management.Automation.PSCredential]$Credential,

  [string]$Token,

  [switch]$SkipCertificateCheck,

  # ===== Thresholds =====
  [ValidateRange(1,720)]
  [int]$RPOThresholdHours = 24,

  [ValidateRange(1,100)]
  [int]$SLATargetPercent = 95,

  [ValidateRange(1,365)]
  [int]$ConfigBackupAgeDays = 7,

  [ValidateRange(1,365)]
  [int]$LicenseExpiryWarningDays = 30,

  # ===== Output =====
  [string]$OutputPath,

  [switch]$SkipHTML,

  [switch]$SkipZip
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# =============================
# Script-level variables
# =============================
$script:StartTime = Get-Date
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:BaseUrl = "https://${Server}:${Port}"
$script:SkipCertCheck = [bool]$SkipCertificateCheck
$script:VBACredential = $Credential
$script:ProvidedToken = $Token
$script:AuthToken = $null
$script:RefreshToken = $null
$script:TokenExpiry = $null
$script:OriginalCertPolicy = $null

# Health score weights (must sum to 1.0)
$script:CategoryWeights = @{
  "System Health"          = 0.10
  "License Health"         = 0.10
  "Configuration Check"    = 0.15
  "Protection Coverage"    = 0.20
  "Policy Health"          = 0.15
  "Session Health"         = 0.10
  "Repository Health"      = 0.10
  "Worker Health"          = 0.05
  "Configuration Backup"   = 0.05
}

# =============================
# Output folder
# =============================
if (-not $OutputPath) {
  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputPath = ".\VBAHealthCheck_$timestamp"
}

$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ($OutputPath.StartsWith('\\')) {
  throw "UNC paths are not supported for OutputPath. Use a local directory."
}

if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# =============================
# Load Function Libraries
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Helpers.ps1",
  "Logging.ps1",
  "ApiClient.ps1",
  "DataCollection.ps1",
  "HealthChecks.ps1",
  "Charts.ps1",
  "HtmlReport.ps1",
  "Exports.ps1"
)
foreach ($lib in $requiredLibs) {
  $libFile = Join-Path $libPath $lib
  if (-not (Test-Path $libFile)) {
    throw "Required library not found: $libFile. Ensure all files in lib/ are present."
  }
  . $libFile
}

# Set total progress steps dynamically
# auth + system + license + config-check + protection + unprotected + policies + sla +
# sessions + repos + workers + bottlenecks + config-backup + scoring + export + optional html + optional zip
$script:TotalSteps = 16
if (-not $SkipHTML) { $script:TotalSteps++ }
if (-not $SkipZip)  { $script:TotalSteps++ }

# =============================
# Main Execution
# =============================
try {
  Write-Log "========== Veeam Backup for Azure - Health Check ==========" -Level "SUCCESS"
  Write-Log "Target: $script:BaseUrl" -Level "INFO"
  Write-Log "Output folder: $OutputPath" -Level "INFO"
  Write-Log "Thresholds - RPO: ${RPOThresholdHours}h, SLA: ${SLATargetPercent}%, Config backup: ${ConfigBackupAgeDays}d" -Level "INFO"

  # ===== 1. Connect =====
  Initialize-VBAConnection

  # ===== 2. System Health =====
  $systemData = Get-VBASystemInfo
  Invoke-SystemHealthChecks -SystemData $systemData

  # ===== 3. License Health =====
  $licenseData = Get-VBALicenseInfo
  Invoke-LicenseHealthChecks -LicenseData $licenseData -ExpiryWarningDays $LicenseExpiryWarningDays

  # ===== 4. Configuration Check =====
  $configCheckData = Start-VBAConfigurationCheck
  Invoke-ConfigurationCheckHealthChecks -ConfigCheckData $configCheckData

  # ===== 5. Protection Coverage =====
  $protectionData = Get-VBAProtectedWorkloads
  $unprotectedResources = Get-VBAUnprotectedResources
  $protectedItems = Get-VBAProtectedItemInventory
  Invoke-ProtectionCoverageHealthChecks -WorkloadsReport $protectionData -UnprotectedResources $unprotectedResources `
    -ProtectedItems $protectedItems -RPOThresholdHours $RPOThresholdHours

  # ===== 6. Policy Health =====
  $policyData = Get-VBAPolicies
  $slaReport = Get-VBASLAReport
  Invoke-PolicyHealthChecks -Policies $policyData -SLAReport $slaReport -SLATarget $SLATargetPercent

  # ===== 7. Session Health =====
  $sessionsSummary = Get-VBASessionsSummary
  $failedSessions = Get-VBAFailedSessions
  $topDuration = Get-VBATopPoliciesDuration
  Invoke-SessionHealthChecks -SessionsSummary $sessionsSummary -FailedSessions $failedSessions -TopDuration $topDuration

  # ===== 8. Repository Health =====
  $repositories = Get-VBARepositories
  Invoke-RepositoryHealthChecks -Repositories $repositories

  # ===== 9. Worker Health =====
  $workers = Get-VBAWorkers
  $workerStats = Get-VBAWorkerStatistics
  $bottlenecks = Get-VBABottlenecks
  Invoke-WorkerHealthChecks -Workers $workers -WorkerStats $workerStats -Bottlenecks $bottlenecks

  # ===== 10. Configuration Backup =====
  $configBackup = Get-VBAConfigBackup
  Invoke-ConfigBackupHealthChecks -ConfigBackup $configBackup -MaxAgeDays $ConfigBackupAgeDays

  # ===== 11. Storage Usage =====
  $storageUsage = Get-VBAStorageUsage

  # ===== 12. Calculate Health Score =====
  $healthScore = Measure-HealthScore

  # ===== 13. Export Data =====
  Export-HealthCheckData -HealthScore $healthScore -SystemData $systemData `
    -LicenseData $licenseData -ConfigCheckData $configCheckData `
    -ProtectionData $protectionData -UnprotectedResources $unprotectedResources `
    -PolicyData $policyData -SLAReport $slaReport `
    -FailedSessions $failedSessions `
    -Repositories $repositories -Workers $workers `
    -ProtectedItems $protectedItems -StorageUsage $storageUsage

  # ===== 14. HTML Report =====
  if (-not $SkipHTML) {
    $htmlPath = New-HtmlReport -HealthScore $healthScore -SystemData $systemData `
      -LicenseData $licenseData -ConfigCheckData $configCheckData `
      -ProtectionData $protectionData -UnprotectedResources $unprotectedResources `
      -PolicyData $policyData -SLAReport $slaReport `
      -SessionsSummary $sessionsSummary -FailedSessions $failedSessions `
      -Repositories $repositories -Workers $workers `
      -WorkerStats $workerStats -Bottlenecks $bottlenecks `
      -ConfigBackup $configBackup `
      -ProtectedItems $protectedItems -StorageUsage $storageUsage `
      -OutputPath $OutputPath -StartTime $script:StartTime
  }

  # ===== 15. ZIP Archive =====
  $zipPath = $null
  if (-not $SkipZip) {
    Export-LogData
    $zipPath = New-OutputArchive
  }
  else {
    Export-LogData
  }

  # ===== Console Summary =====
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  $healthyCount = @($script:Findings | Where-Object { $_.Status -eq "Healthy" }).Count
  $warningCount = @($script:Findings | Where-Object { $_.Status -eq "Warning" }).Count
  $criticalCount = @($script:Findings | Where-Object { $_.Status -eq "Critical" }).Count

  Write-Log "" -Level "INFO"
  Write-Log "========== Health Check Complete ==========" -Level "SUCCESS"
  Write-Log "Appliance: $Server" -Level "INFO"
  Write-Log "Health Score: $($healthScore.OverallScore)/100 ($($healthScore.Grade))" -Level "SUCCESS"
  Write-Log "Findings: $healthyCount Healthy, $warningCount Warnings, $criticalCount Critical" -Level "INFO"
  Write-Log "Duration: $durationStr" -Level "INFO"

  if ($zipPath) {
    Write-Log "Output: $zipPath" -Level "SUCCESS"
  }
  else {
    Write-Log "Output: $OutputPath" -Level "SUCCESS"
  }

}
catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  Export-LogData
  throw
}
finally {
  Restore-CertificatePolicy
  Write-Progress -Activity "VBA Health Check" -Completed
}
