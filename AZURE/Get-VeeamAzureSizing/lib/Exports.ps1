# SPDX-License-Identifier: MIT
# =========================================================================
# Exports.ps1 - CSV exports, log export, and ZIP archive creation
# =========================================================================

<#
.SYNOPSIS
  Exports all inventory data to CSV files, source totals to JSON, and filter metadata.
.PARAMETER VmInventory
  VM inventory collection.
.PARAMETER SqlInventory
  SQL inventory hashtable (Databases, ManagedInstances).
.PARAMETER StorageInventory
  Storage inventory hashtable (Files, Blobs, StorageAccounts, SkippedAccounts).
.PARAMETER AzureBackupInventory
  Backup inventory hashtable (Vaults, Policies).
.PARAMETER VeeamSizing
  Source totals summary object.
.PARAMETER VMSSInventory
  VMSS inventory collection.
.PARAMETER AdditionalResources
  Hashtable with KeyVaults, AKSClusters, WebApps, FunctionApps, ContainerRegistries, etc.
.PARAMETER PaaSInventory
  Hashtable with PostgreSQL, MySQL, CosmosDB, Redis.
.PARAMETER NetworkInventory
  Hashtable with VNets, PrivateEndpoints.
.PARAMETER FilterMetadata
  Hashtable with runtime parameters for audit trail.
#>
function Export-InventoryData {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    [Parameter(Mandatory=$true)]$StorageInventory,
    [Parameter(Mandatory=$true)]$AzureBackupInventory,
    [Parameter(Mandatory=$true)]$VeeamSizing,
    $VMSSInventory = $null,
    $AdditionalResources = $null,
    $PaaSInventory = $null,
    $NetworkInventory = $null,
    $FilterMetadata = $null
  )

  Write-ProgressStep -Activity "Exporting Data" -Status "Writing CSV files..."

  # Helper: export collection to CSV, skip if empty to avoid header-less files
  $csvExports = New-Object System.Collections.Generic.List[object]
  $csvExports.Add(@{ Data = $VmInventory;                       Path = $script:vmCsv })
  $csvExports.Add(@{ Data = $SqlInventory.Databases;            Path = $script:sqlDbCsv })
  $csvExports.Add(@{ Data = $SqlInventory.ManagedInstances;     Path = $script:sqlMiCsv })
  $csvExports.Add(@{ Data = $StorageInventory.Files;            Path = $script:filesCsv })
  $csvExports.Add(@{ Data = $StorageInventory.Blobs;            Path = $script:blobCsv })
  $csvExports.Add(@{ Data = $StorageInventory.StorageAccounts;  Path = $script:storageAcctsCsv })
  $csvExports.Add(@{ Data = $AzureBackupInventory.Vaults;       Path = $script:vaultsCsv })
  $csvExports.Add(@{ Data = $AzureBackupInventory.Policies;     Path = $script:polCsv })
  $csvExports.Add(@{ Data = $VMSSInventory;                     Path = $script:vmssCsv })

  # Additional resource exports
  if ($null -ne $AdditionalResources) {
    $csvExports.Add(@{ Data = $AdditionalResources.KeyVaults;          Path = $script:kvCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.AKSClusters;        Path = $script:aksCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.WebApps;            Path = $script:webAppsCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.FunctionApps;       Path = $script:funcAppsCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.ContainerRegistries; Path = $script:acrCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.LogicApps;          Path = $script:logicAppsCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.DataFactories;      Path = $script:dfCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.APIManagement;      Path = $script:apimCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.EventHubs;          Path = $script:ehCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.ServiceBus;         Path = $script:sbCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.OrphanedDisks;      Path = $script:orphanedDisksCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.Snapshots;          Path = $script:snapshotsCsv })
    $csvExports.Add(@{ Data = $AdditionalResources.AvailabilitySets;   Path = $script:avSetsCsv })
  }

  # PaaS database exports
  if ($null -ne $PaaSInventory) {
    $csvExports.Add(@{ Data = $PaaSInventory.PostgreSQL; Path = $script:pgCsv })
    $csvExports.Add(@{ Data = $PaaSInventory.MySQL;      Path = $script:mysqlCsv })
    $csvExports.Add(@{ Data = $PaaSInventory.CosmosDB;   Path = $script:cosmosCsv })
    $csvExports.Add(@{ Data = $PaaSInventory.Redis;      Path = $script:redisCsv })
  }

  # Network resource exports
  if ($null -ne $NetworkInventory) {
    $csvExports.Add(@{ Data = $NetworkInventory.VNets;            Path = $script:vnetsCsv })
    $csvExports.Add(@{ Data = $NetworkInventory.PrivateEndpoints; Path = $script:peCsv })
  }

  foreach ($export in $csvExports) {
    $collection = $export.Data
    if ($null -eq $collection) { continue }
    # Unwrap Generic.List to plain array
    if ($collection -is [System.Collections.IList]) {
      $items = @($collection.GetEnumerator())
    } else {
      $items = @($collection)
    }
    if ($items.Count -eq 0) { continue }
    $items | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $export.Path
  }

  # JSON source totals bundle with filter metadata for audit trail
  $jsonPath = Join-Path $OutputPath "source_totals.json"
  $jsonBundle = @{
    SizingTotals = $VeeamSizing
    SkippedResources = @{
      StorageAccountsSkipped = if ($null -ne $StorageInventory.SkippedAccounts) { $StorageInventory.SkippedAccounts } else { 0 }
    }
  }
  if ($null -ne $FilterMetadata) {
    $jsonBundle.FilterMetadata = $FilterMetadata
  }
  $jsonBundle | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8

  Write-Log "Exported CSV files to: $OutputPath" -Level "SUCCESS"
}

<#
.SYNOPSIS
  Exports the execution log entries to a CSV file.
#>
function Export-LogData {
  try {
    $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:logCsv
  } catch {
    Write-Host "Warning: Failed to export log data: $($_.Exception.Message)" -ForegroundColor Yellow
  }
}

<#
.SYNOPSIS
  Creates a ZIP archive of all output files.
#>
function New-OutputArchive {
  Write-ProgressStep -Activity "Creating Archive" -Status "Compressing output files..."
  $zipPath = Join-Path (Split-Path $OutputPath -Parent) "$(Split-Path $OutputPath -Leaf).zip"
  Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $zipPath -Force
  Write-Log "Created ZIP archive: $zipPath" -Level "SUCCESS"

  # Clean up uncompressed output directory after successful ZIP creation
  try {
    Remove-Item -Path $OutputPath -Recurse -Force -ErrorAction Stop
    Write-Log "Cleaned up uncompressed output: $OutputPath" -Level "INFO"
  } catch {
    Write-Log "Could not remove uncompressed output: $($_.Exception.Message)" -Level "WARNING"
  }

  return $zipPath
}
