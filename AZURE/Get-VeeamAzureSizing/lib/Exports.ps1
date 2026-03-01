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

  $VmInventory            | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:vmCsv
  $SqlInventory.Databases | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:sqlDbCsv
  $SqlInventory.ManagedInstances | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:sqlMiCsv
  $StorageInventory.Files | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:filesCsv
  $StorageInventory.Blobs | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:blobCsv
  $AzureBackupInventory.Vaults   | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:vaultsCsv
  $AzureBackupInventory.Policies | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:polCsv
  $VeeamSizing            | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:sizingCsv

  Write-Log "Exported CSV files to: $OutputPath" -Level "SUCCESS"
}

<#
.SYNOPSIS
  Exports the execution log entries to a CSV file.
#>
function Export-LogData {
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $script:logCsv
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
  return $zipPath
}
