# SPDX-License-Identifier: MIT
<#
.SYNOPSIS
  Veeam Backup for Azure - Discovery & Inventory Tool

.DESCRIPTION
  Professional discovery tool for Veeam Backup for Azure deployments.

  WHAT THIS SCRIPT DOES:
  1. Inventories Azure VMs, VMSS, SQL Databases, Managed Instances, Storage Accounts
  2. Discovers Key Vaults, AKS clusters, Web Apps, Function Apps, and Container Registries
  3. Inventories PaaS databases (PostgreSQL, MySQL, Cosmos DB, Redis)
  4. Maps network topology (VNets, Private Endpoints, Availability Sets)
  5. Discovers messaging services (Event Hubs, Service Bus), Logic Apps, Data Factory, API Management
  6. Analyzes disk encryption, managed identities, and NSG exposure
  7. Evaluates storage account security posture and identifies orphaned disks and snapshots
  8. Analyzes current Azure Backup configuration (vaults, policies, protected items)
  9. Aggregates source infrastructure totals for external sizing calculators
  10. Generates professional HTML report with Microsoft Fluent Design System
  11. Provides executive summary with actionable recommendations

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
$script:pgCsv          = Join-Path $OutputPath "azure_postgresql.csv"
$script:mysqlCsv       = Join-Path $OutputPath "azure_mysql.csv"
$script:cosmosCsv      = Join-Path $OutputPath "azure_cosmosdb.csv"
$script:redisCsv       = Join-Path $OutputPath "azure_redis.csv"
$script:webAppsCsv     = Join-Path $OutputPath "azure_web_apps.csv"
$script:funcAppsCsv    = Join-Path $OutputPath "azure_function_apps.csv"
$script:acrCsv         = Join-Path $OutputPath "azure_container_registries.csv"
$script:logicAppsCsv   = Join-Path $OutputPath "azure_logic_apps.csv"
$script:dfCsv          = Join-Path $OutputPath "azure_data_factories.csv"
$script:apimCsv        = Join-Path $OutputPath "azure_api_management.csv"
$script:ehCsv          = Join-Path $OutputPath "azure_event_hubs.csv"
$script:sbCsv          = Join-Path $OutputPath "azure_service_bus.csv"
$script:orphanedDisksCsv = Join-Path $OutputPath "azure_orphaned_disks.csv"
$script:snapshotsCsv   = Join-Path $OutputPath "azure_snapshots.csv"
$script:avSetsCsv      = Join-Path $OutputPath "azure_availability_sets.csv"
$script:vnetsCsv       = Join-Path $OutputPath "azure_vnets.csv"
$script:peCsv          = Join-Path $OutputPath "azure_private_endpoints.csv"
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
$script:TotalSteps = 14
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
  $paasInv  = Get-PaaSInventory
  $netInv   = Get-NetworkInventory

  # Sizing
  $veeamSizing = Get-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv `
    -StorageInventory $stInv -VMSSInventory $vmssInv `
    -PaaSInventory $paasInv -AdditionalResources $addlInv

  # Exports
  Export-InventoryData -VmInventory $vmInv -SqlInventory $sqlInv `
    -StorageInventory $stInv -AzureBackupInventory $abInv -VeeamSizing $veeamSizing `
    -VMSSInventory $vmssInv -AdditionalResources $addlInv -FilterMetadata $filterMetadata `
    -PaaSInventory $paasInv -NetworkInventory $netInv

  $htmlPath = $null
  if (-not $SkipHTML) {
    $htmlPath = New-HtmlReport -VmInventory $vmInv -SqlInventory $sqlInv `
      -StorageInventory $stInv -AzureBackupInventory $abInv `
      -VeeamSizing $veeamSizing -OutputPath $OutputPath `
      -Subscriptions $script:Subs -StartTime $script:StartTime `
      -VMSSInventory $vmssInv -AdditionalResources $addlInv `
      -FilterMetadata $filterMetadata -PaaSInventory $paasInv `
      -NetworkInventory $netInv
  }

  # Write log before ZIP (ZIP deletes output folder)
  Export-LogData

  $zipPath = $null
  if (-not $SkipZip) {
    $zipPath = New-OutputArchive
  }

  # Console summary
  Write-Progress -Activity "Veeam Azure Sizing" -Completed

  # Safe count helper for Generic.List or array
  $blobCount = if ($null -ne $stInv.Blobs -and $stInv.Blobs -is [System.Collections.IList]) { $stInv.Blobs.Count } else { 0 }
  $saCount = if ($null -ne $stInv.StorageAccounts -and $stInv.StorageAccounts -is [System.Collections.IList]) { $stInv.StorageAccounts.Count } else { 0 }
  $rvCount = if ($null -ne $abInv.Vaults -and $abInv.Vaults -is [System.Collections.IList]) { $abInv.Vaults.Count } else { 0 }
  $kvCount = if ($null -ne $addlInv.KeyVaults -and $addlInv.KeyVaults -is [System.Collections.IList]) { $addlInv.KeyVaults.Count } else { 0 }
  $aksCount = if ($null -ne $addlInv.AKSClusters -and $addlInv.AKSClusters -is [System.Collections.IList]) { $addlInv.AKSClusters.Count } else { 0 }
  $webAppCount = if ($null -ne $addlInv.WebApps -and $addlInv.WebApps -is [System.Collections.IList]) { $addlInv.WebApps.Count } else { 0 }
  $funcAppCount = if ($null -ne $addlInv.FunctionApps -and $addlInv.FunctionApps -is [System.Collections.IList]) { $addlInv.FunctionApps.Count } else { 0 }
  $pgCount = if ($null -ne $paasInv.PostgreSQL -and $paasInv.PostgreSQL -is [System.Collections.IList]) { $paasInv.PostgreSQL.Count } else { 0 }
  $myCount = if ($null -ne $paasInv.MySQL -and $paasInv.MySQL -is [System.Collections.IList]) { $paasInv.MySQL.Count } else { 0 }
  $cosmosCount = if ($null -ne $paasInv.CosmosDB -and $paasInv.CosmosDB -is [System.Collections.IList]) { $paasInv.CosmosDB.Count } else { 0 }
  $redisCount = if ($null -ne $paasInv.Redis -and $paasInv.Redis -is [System.Collections.IList]) { $paasInv.Redis.Count } else { 0 }
  $orphanDiskCount = if ($null -ne $addlInv.OrphanedDisks -and $addlInv.OrphanedDisks -is [System.Collections.IList]) { $addlInv.OrphanedDisks.Count } else { 0 }
  $vnetCount = if ($null -ne $netInv.VNets -and $netInv.VNets -is [System.Collections.IList]) { $netInv.VNets.Count } else { 0 }
  $skippedSA = if ($null -ne $stInv.SkippedAccounts) { $stInv.SkippedAccounts } else { 0 }

  Write-Host "`n========== Assessment Complete ==========" -ForegroundColor Green
  Write-Host "`nDiscovered Resources:" -ForegroundColor Cyan
  Write-Host "  - Azure VMs: $($veeamSizing.TotalVMs)" -ForegroundColor White
  Write-Host "  - VM Storage: $([math]::Round($veeamSizing.TotalVMStorageGB, 0)) GB" -ForegroundColor White
  Write-Host "  - VMSS Scale Sets: $($veeamSizing.TotalVMSS) ($($veeamSizing.TotalVMSSInstances) instances)" -ForegroundColor White
  Write-Host "  - SQL Databases: $($veeamSizing.TotalSQLDatabases)" -ForegroundColor White
  Write-Host "  - SQL Managed Instances: $($veeamSizing.TotalSQLManagedInstances)" -ForegroundColor White
  Write-Host "  - SQL Storage: $([math]::Round($veeamSizing.TotalSQLStorageGB, 0)) GB" -ForegroundColor White
  Write-Host "  - PostgreSQL Servers: $pgCount" -ForegroundColor White
  Write-Host "  - MySQL Servers: $myCount" -ForegroundColor White
  Write-Host "  - Cosmos DB Accounts: $cosmosCount" -ForegroundColor White
  Write-Host "  - Redis Caches: $redisCount" -ForegroundColor White
  Write-Host "  - Azure File Shares: $($veeamSizing.TotalFileShares)" -ForegroundColor White
  Write-Host "  - Blob Containers: $blobCount" -ForegroundColor White
  Write-Host "  - Storage Accounts: $saCount" -ForegroundColor White
  Write-Host "  - Recovery Services Vaults: $rvCount" -ForegroundColor White
  Write-Host "  - Key Vaults: $kvCount" -ForegroundColor White
  Write-Host "  - AKS Clusters: $aksCount" -ForegroundColor White
  Write-Host "  - Web Apps: $webAppCount" -ForegroundColor White
  Write-Host "  - Function Apps: $funcAppCount" -ForegroundColor White
  Write-Host "  - Orphaned Disks: $orphanDiskCount" -ForegroundColor White
  Write-Host "  - VNets: $vnetCount" -ForegroundColor White
  Write-Host "  - Total Source Storage: $([math]::Round($veeamSizing.TotalSourceStorageGB, 0)) GB" -ForegroundColor Green

  if ($skippedSA -gt 0) {
    Write-Host "`n  Note: $skippedSA storage account(s) skipped (RBAC-only/insufficient access)" -ForegroundColor Yellow
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
  # Log is already exported before ZIP in the try block; only export here on error path
  if (Test-Path $OutputPath) { Export-LogData }
  Write-Progress -Activity "Veeam Azure Sizing" -Completed
}
