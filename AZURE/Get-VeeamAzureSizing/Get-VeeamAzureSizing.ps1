# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Veeam Backup for Azure - Discovery & Inventory Tool

.DESCRIPTION
  Professional discovery tool for Veeam Backup for Azure deployments.

  WHAT THIS SCRIPT DOES:
  1. Inventories Azure VMs, VMSS, SQL Databases, Managed Instances, Storage Accounts
  2. Discovers Key Vaults, AKS clusters, and App Services
  3. Analyzes disk encryption, managed identities, and NSG exposure
  4. Evaluates storage account security posture
  5. Analyzes current Azure Backup configuration (vaults, policies, protected items)
  6. Aggregates source infrastructure totals for external sizing calculators
  7. Generates professional HTML report with Microsoft Fluent Design System
  8. Provides executive summary with actionable recommendations

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
  Entra ID tenant ID (optional). If omitted, uses current/default tenant.

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

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VeeamAzureSizing_[timestamp]).

.PARAMETER SkipHTML
  Skip HTML report generation.

.PARAMETER SkipZip
  Skip ZIP archive creation.

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
  .\Get-VeeamAzureSizing.ps1 -TagFilter @{"Environment"="Prod"}
  # Filter by tags

.NOTES
  Version: 5.0.0
  Author: Community Contributors
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices

  DISCLAIMER: This is a community-maintained tool, not an official Veeam product.
  Source data collected here is intended for use with external Veeam sizing calculators.
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

  # Output
  [string]$OutputPath,
  [switch]$SkipHTML,
  [switch]$SkipZip
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

# Validate OutputPath: resolve to full path and reject UNC paths
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)
if ($OutputPath.StartsWith('\\')) {
  throw "UNC paths are not supported for OutputPath. Use a local directory."
}

if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# Output file paths
$script:vmCsv          = Join-Path $OutputPath "azure_vms.csv"
$script:vmssCsv        = Join-Path $OutputPath "azure_vmss.csv"
$script:sqlDbCsv       = Join-Path $OutputPath "azure_sql_databases.csv"
$script:sqlMiCsv       = Join-Path $OutputPath "azure_sql_managed_instances.csv"
$script:filesCsv       = Join-Path $OutputPath "azure_files.csv"
$script:blobCsv        = Join-Path $OutputPath "azure_blob.csv"
$script:storageAcctsCsv = Join-Path $OutputPath "azure_storage_accounts.csv"
$script:vaultsCsv      = Join-Path $OutputPath "azure_backup_vaults.csv"
$script:polCsv         = Join-Path $OutputPath "azure_backup_policies.csv"
$script:kvCsv          = Join-Path $OutputPath "azure_key_vaults.csv"
$script:aksCsv         = Join-Path $OutputPath "azure_aks_clusters.csv"
$script:appSvcCsv      = Join-Path $OutputPath "azure_app_services.csv"
$script:logCsv         = Join-Path $OutputPath "execution_log.csv"

# =============================
# Load Function Libraries
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Helpers.ps1",
  "Logging.ps1",
  "Auth.ps1",
  "DataCollection.ps1",
  "Sizing.ps1",
  "Exports.ps1",
  "Charts.ps1",
  "HtmlReport.ps1"
)
foreach ($lib in $requiredLibs) {
  $libFile = Join-Path $libPath $lib
  if (-not (Test-Path $libFile)) {
    throw "Required library not found: $libFile. Ensure all files in lib/ are present."
  }
  . $libFile
}

# Set total progress steps dynamically
# auth + resolve + access-check + 6 inventory + sizing + export + optional html + optional zip
$script:TotalSteps = 12
if (-not $SkipHTML) { $script:TotalSteps++ }
if (-not $SkipZip)  { $script:TotalSteps++ }

# =============================
# Filter metadata for audit trail
# =============================
$filterMetadata = @{
  RunTimestamp     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  Region          = if ($Region) { $Region } else { "All" }
  TagFilter       = if ($TagFilter) { ($TagFilter.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; ' } else { "None" }
  Subscriptions   = if ($Subscriptions) { $Subscriptions -join ', ' } else { "All accessible" }
  CalculateBlobSizes = [bool]$CalculateBlobSizes
  PowerShellVersion = "$($PSVersionTable.PSVersion)"
}

# =============================
# Main Execution
# =============================
try {
  Write-Log "========== Veeam Backup for Azure - Discovery Assessment ==========" -Level "SUCCESS"
  Write-Log "Output folder: $OutputPath" -Level "INFO"
  if ($Region) { Write-Log "Region filter: $Region" -Level "INFO" }
  if ($TagFilter) { Write-Log "Tag filter: $($filterMetadata.TagFilter)" -Level "INFO" }

  # Authenticate and resolve scope
  Initialize-RequiredModules
  Connect-AzureModern
  $script:Subs = Resolve-Subscriptions

  # Pre-flight permission check
  $script:Subs = Test-SubscriptionAccess -Subs $script:Subs

  # Discovery
  $vmInv    = Get-VMInventory
  $vmssInv  = Get-VMSSInventory
  $sqlInv   = Get-SqlInventory
  $stInv    = Get-StorageInventory
  $abInv    = Get-AzureBackupInventory
  $addlInv  = Get-AdditionalResources

  # Sizing
  $veeamSizing = Get-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
    -StorageInventory $stInv -VMSSInventory $vmssInv

  # Exports
  Export-InventoryData -VmInventory $vmInv -SqlInventory $sqlInv `
    -StorageInventory $stInv -AzureBackupInventory $abInv -VeeamSizing $veeamSizing `
    -VMSSInventory $vmssInv -AdditionalResources $addlInv -FilterMetadata $filterMetadata

  $htmlPath = $null
  if (-not $SkipHTML) {
    $htmlPath = New-HtmlReport -VmInventory $vmInv -SqlInventory $sqlInv `
      -StorageInventory $stInv -AzureBackupInventory $abInv `
      -VeeamSizing $veeamSizing -OutputPath $OutputPath `
      -Subscriptions $script:Subs -StartTime $script:StartTime `
      -VMSSInventory $vmssInv -AdditionalResources $addlInv `
      -FilterMetadata $filterMetadata
  }

  $zipPath = $null
  if (-not $SkipZip) {
    $zipPath = New-OutputArchive
  }

  # Console summary
  Write-Progress -Activity "Veeam Azure Sizing" -Completed

  # Counts for additional resources
  $kvCount = if ($null -ne $addlInv.KeyVaults) { @($addlInv.KeyVaults).Count } else { 0 }
  $aksCount = if ($null -ne $addlInv.AKSClusters) { @($addlInv.AKSClusters).Count } else { 0 }
  $appSvcCount = if ($null -ne $addlInv.AppServices) { @($addlInv.AppServices).Count } else { 0 }

  Write-Host "`n========== Assessment Complete ==========" -ForegroundColor Green
  Write-Host "`nDiscovered Resources:" -ForegroundColor Cyan
  Write-Host "  - Azure VMs: $($veeamSizing.TotalVMs)" -ForegroundColor White
  Write-Host "  - VM Storage: $([math]::Round($veeamSizing.TotalVMStorageGB, 0)) GB" -ForegroundColor White
  Write-Host "  - VMSS Scale Sets: $($veeamSizing.TotalVMSS) ($($veeamSizing.TotalVMSSInstances) instances)" -ForegroundColor White
  Write-Host "  - SQL Databases: $($veeamSizing.TotalSQLDatabases)" -ForegroundColor White
  Write-Host "  - SQL Managed Instances: $($veeamSizing.TotalSQLManagedInstances)" -ForegroundColor White
  Write-Host "  - SQL Storage: $([math]::Round($veeamSizing.TotalSQLStorageGB, 0)) GB" -ForegroundColor White
  Write-Host "  - Azure File Shares: $($veeamSizing.TotalFileShares)" -ForegroundColor White
  Write-Host "  - Blob Containers: $(if ($stInv.Blobs -is [System.Collections.IList]) { $stInv.Blobs.Count } else { @($stInv.Blobs).Count })" -ForegroundColor White
  Write-Host "  - Storage Accounts: $(if ($stInv.StorageAccounts -is [System.Collections.IList]) { $stInv.StorageAccounts.Count } else { @($stInv.StorageAccounts).Count })" -ForegroundColor White
  Write-Host "  - Recovery Services Vaults: $(if ($abInv.Vaults -is [System.Collections.IList]) { $abInv.Vaults.Count } else { @($abInv.Vaults).Count })" -ForegroundColor White
  Write-Host "  - Key Vaults: $kvCount" -ForegroundColor White
  Write-Host "  - AKS Clusters: $aksCount" -ForegroundColor White
  Write-Host "  - App Services: $appSvcCount" -ForegroundColor White
  Write-Host "  - Total Source Storage: $([math]::Round($veeamSizing.TotalSourceStorageGB, 0)) GB" -ForegroundColor Green

  if ($stInv.SkippedAccounts -gt 0) {
    Write-Host "`n  Note: $($stInv.SkippedAccounts) storage account(s) skipped (RBAC-only/insufficient access)" -ForegroundColor Yellow
  }

  Write-Host "`nOutput Files:" -ForegroundColor Cyan
  if ($htmlPath)  { Write-Host "  - HTML Report: $htmlPath" -ForegroundColor White }
  Write-Host "  - CSV Exports: $OutputPath" -ForegroundColor White
  if ($zipPath)   { Write-Host "  - ZIP Archive: $zipPath" -ForegroundColor White }

  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Log "Assessment completed successfully" -Level "SUCCESS"

} catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace logged to execution_log.csv" -Level "ERROR"
  # Full stack trace goes to log file only, not console
  $script:LogEntries.Add([PSCustomObject]@{
    Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Level = "DEBUG"
    Message = "Stack trace: $($_.ScriptStackTrace)"
  })
  Write-Host "`nAssessment failed. Check execution_log.csv for details." -ForegroundColor Red
  exit 1
} finally {
  Export-LogData
  Write-Progress -Activity "Veeam Azure Sizing" -Completed
}
