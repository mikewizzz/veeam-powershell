# =========================================================================
# Exports.ps1 - CSV exports, log export, and ZIP archive creation
# =========================================================================

<#
.SYNOPSIS
  Exports all inventory and sizing data to CSV files.
.PARAMETER VmInventory
  VM inventory collection.
.PARAMETER SqlInventory
  SQL inventory hashtable (Databases, ManagedInstances).
.PARAMETER StorageInventory
  Storage inventory hashtable (Files, Blobs).
.PARAMETER AzureBackupInventory
  Backup inventory hashtable (Vaults, Policies).
.PARAMETER VeeamSizing
  Veeam sizing summary object.
#>
function Export-InventoryData {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    [Parameter(Mandatory=$true)]$StorageInventory,
    [Parameter(Mandatory=$true)]$AzureBackupInventory,
    [Parameter(Mandatory=$true)]$VeeamSizing
  )

  Write-ProgressStep -Activity "Exporting Data" -Status "Writing CSV files..."

  # Helper: export collection to CSV, skip if empty to avoid header-less files
  $csvExports = @(
    @{ Data = $VmInventory;                       Path = $script:vmCsv }
    @{ Data = $SqlInventory.Databases;            Path = $script:sqlDbCsv }
    @{ Data = $SqlInventory.ManagedInstances;     Path = $script:sqlMiCsv }
    @{ Data = $StorageInventory.Files;            Path = $script:filesCsv }
    @{ Data = $StorageInventory.Blobs;            Path = $script:blobCsv }
    @{ Data = $AzureBackupInventory.Vaults;       Path = $script:vaultsCsv }
    @{ Data = $AzureBackupInventory.Policies;     Path = $script:polCsv }
    @{ Data = $VeeamSizing;                       Path = $script:sizingCsv }
  )
  foreach ($export in $csvExports) {
    $collection = $export.Data
    if ($null -eq $collection) { continue }
    $items = @($collection)
    if ($items.Count -eq 0) { continue }
    $items | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $export.Path
  }

  # JSON sizing bundle (machine-readable)
  $jsonPath = Join-Path $OutputPath "veeam_sizing_summary.json"
  $VeeamSizing | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8

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
