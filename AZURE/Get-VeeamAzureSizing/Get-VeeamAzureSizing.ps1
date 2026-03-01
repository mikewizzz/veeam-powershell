<#
.SYNOPSIS
  Veeam Backup for Azure - Discovery & Sizing Tool

.DESCRIPTION
  Professional assessment tool for Veeam Backup for Azure deployments.

  WHAT THIS SCRIPT DOES:
  1. Inventories Azure VMs, SQL Databases, Managed Instances, Storage Accounts
  2. Analyzes current Azure Backup configuration (vaults, policies, protected items)
  3. Calculates Veeam sizing recommendations (snapshot storage, repository capacity)
  4. Generates professional HTML report with Microsoft Fluent Design System
  5. Provides executive summary with actionable recommendations

  QUICK START:
  .\Get-VeeamAzureSizing.ps1

  AUTHENTICATION (2026 Modern Methods):
  - Interactive (default): Browser-based login with session reuse
  - Managed Identity: Zero-credential for Azure VMs/containers
  - Service Principal: Certificate-based or client secret
  - Device Code: For headless/remote scenarios

.PARAMETER Subscriptions
  One or more subscription IDs or names. Default = all accessible subscriptions.

.PARAMETER TenantId
  Azure AD tenant ID (optional). If omitted, uses current/default tenant.

.PARAMETER Region
  Filter resources by Azure region (e.g., "eastus", "westeurope"). Case-insensitive.

.PARAMETER TagFilter
  Filter VMs by tags. Example: @{ "Environment"="Production"; "Owner"="IT" }
  Only VMs matching ALL tag pairs will be included.

.PARAMETER UseManagedIdentity
  Use Azure Managed Identity for authentication (Azure VMs/containers only).

.PARAMETER ServicePrincipalId
  Application (client) ID for service principal authentication.

.PARAMETER ServicePrincipalSecret
  Client secret for service principal (legacy - prefer certificate-based).

.PARAMETER CertificateThumbprint
  Certificate thumbprint for service principal authentication (recommended).

.PARAMETER UseDeviceCode
  Use device code flow for interactive authentication (headless scenarios).

.PARAMETER CalculateBlobSizes
  Enumerate all blobs to calculate container sizes. Warning: Can be slow on large storage accounts.

.PARAMETER SnapshotRetentionDays
  Snapshot retention for Veeam sizing (default: 14 days).

.PARAMETER RepositoryOverhead
  Repository overhead multiplier for Veeam sizing (default: 1.2 = 20% overhead).

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VeeamAzureSizing_[timestamp]).

.PARAMETER GenerateHTML
  Generate professional HTML report (default: true).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1
  # Quick start - analyzes all accessible subscriptions

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -Subscriptions "Production-Sub" -Region "eastus"
  # Filter by subscription and region

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -UseManagedIdentity
  # Use managed identity (Azure VM/container)

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -TagFilter @{"Environment"="Prod"} -SnapshotRetentionDays 30
  # Filter by tags and customize Veeam sizing parameters

.NOTES
  Version: 3.0.0
  Author: Community Contributors
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices
#>

[CmdletBinding()]
param(
  # Scope
  [string[]]$Subscriptions,
  [string]$TenantId,
  [string]$Region,
  [hashtable]$TagFilter,

  # Authentication (2026 modern methods)
  [switch]$UseManagedIdentity,
  [string]$ServicePrincipalId,
  [securestring]$ServicePrincipalSecret,
  [string]$CertificateThumbprint,
  [switch]$UseDeviceCode,

  # Discovery options
  [switch]$CalculateBlobSizes,

  # Veeam sizing parameters
  [ValidateRange(1,365)]
  [int]$SnapshotRetentionDays = 14,
  [ValidateRange(1.0,3.0)]
  [double]$RepositoryOverhead = 1.2,

  # Output
  [string]$OutputPath,
  [switch]$GenerateHTML = $true,
  [switch]$ZipOutput = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script-level timing
$script:StartTime = Get-Date
$script:Subs = @()

# =============================
# Output folder structure
# =============================
if (-not $OutputPath) {
  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputPath = ".\VeeamAzureSizing_$timestamp"
}

if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# Output file paths
$script:vmCsv     = Join-Path $OutputPath "azure_vms.csv"
$script:sqlDbCsv  = Join-Path $OutputPath "azure_sql_databases.csv"
$script:sqlMiCsv  = Join-Path $OutputPath "azure_sql_managed_instances.csv"
$script:filesCsv  = Join-Path $OutputPath "azure_files.csv"
$script:blobCsv   = Join-Path $OutputPath "azure_blob.csv"
$script:vaultsCsv = Join-Path $OutputPath "azure_backup_vaults.csv"
$script:polCsv    = Join-Path $OutputPath "azure_backup_policies.csv"
$script:sizingCsv = Join-Path $OutputPath "veeam_sizing_summary.csv"
$script:logCsv    = Join-Path $OutputPath "execution_log.csv"

# =============================
# Load Function Libraries
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Constants.ps1",
  "Logging.ps1",
  "Auth.ps1",
  "DataCollection.ps1",
  "Sizing.ps1",
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
try {
  Write-Log "========== Veeam Backup for Azure - Sizing Assessment ==========" -Level "SUCCESS"
  Write-Log "Output folder: $OutputPath" -Level "INFO"

  # Authenticate and resolve scope
  Initialize-RequiredModules
  Connect-AzureModern
  $script:Subs = Resolve-Subscriptions

  # Discovery
  $vmInv  = Get-VMInventory
  $sqlInv = Get-SqlInventory
  $stInv  = Get-StorageInventory
  $abInv  = Get-AzureBackupInventory

  # Sizing
  $veeamSizing = Get-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv

  # Exports
  Export-InventoryData -VmInventory $vmInv -SqlInventory $sqlInv `
    -StorageInventory $stInv -AzureBackupInventory $abInv -VeeamSizing $veeamSizing

  $htmlPath = $null
  if ($GenerateHTML) {
    $htmlPath = Build-HtmlReport -VmInventory $vmInv -SqlInventory $sqlInv `
      -StorageInventory $stInv -AzureBackupInventory $abInv `
      -VeeamSizing $veeamSizing -OutputPath $OutputPath
  }

  Export-LogData

  $zipPath = $null
  if ($ZipOutput) {
    $zipPath = New-OutputArchive
  }

  # Console summary
  Write-Progress -Activity "Veeam Azure Sizing" -Completed

  Write-Host "`n========== Assessment Complete ==========" -ForegroundColor Green
  Write-Host "`nDiscovered Resources:" -ForegroundColor Cyan
  Write-Host "  - Azure VMs: $($veeamSizing.TotalVMs)" -ForegroundColor White
  Write-Host "  - SQL Databases: $($veeamSizing.TotalSQLDatabases)" -ForegroundColor White
  Write-Host "  - SQL Managed Instances: $($veeamSizing.TotalSQLManagedInstances)" -ForegroundColor White
  Write-Host "  - Azure File Shares: $(@($stInv.Files).Count)" -ForegroundColor White
  Write-Host "  - Blob Containers: $(@($stInv.Blobs).Count)" -ForegroundColor White
  Write-Host "  - Recovery Services Vaults: $(@($abInv.Vaults).Count)" -ForegroundColor White

  Write-Host "`nVeeam Sizing Recommendations:" -ForegroundColor Cyan
  Write-Host "  - Snapshot Storage: $([math]::Ceiling($veeamSizing.TotalSnapshotStorageGB)) GB ($([math]::Round($veeamSizing.TotalSnapshotStorageGB / 1024, 2)) TB)" -ForegroundColor Green
  Write-Host "  - Repository Capacity: $([math]::Ceiling($veeamSizing.TotalRepositoryGB)) GB ($([math]::Round($veeamSizing.TotalRepositoryGB / 1024, 2)) TB)" -ForegroundColor Green

  Write-Host "`nOutput Files:" -ForegroundColor Cyan
  if ($htmlPath)  { Write-Host "  - HTML Report: $htmlPath" -ForegroundColor White }
  Write-Host "  - CSV Exports: $OutputPath" -ForegroundColor White
  if ($zipPath)   { Write-Host "  - ZIP Archive: $zipPath" -ForegroundColor White }

  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Log "Assessment completed successfully" -Level "SUCCESS"

} catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  Write-Host "`nAssessment failed. Check execution_log.csv for details." -ForegroundColor Red
  throw
} finally {
  Write-Progress -Activity "Veeam Azure Sizing" -Completed
}
