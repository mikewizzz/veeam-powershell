# SPDX-License-Identifier: MIT
# =========================================================================
# Sizing.ps1 - Veeam Backup for Azure source data aggregation
# =========================================================================

<#
.SYNOPSIS
  Aggregates source infrastructure totals from VM, SQL, storage, and VMSS inventory data.
.PARAMETER VmInventory
  Collection of VM inventory objects from Get-VMInventory.
.PARAMETER SqlInventory
  Hashtable with Databases and ManagedInstances lists from Get-SqlInventory.
.PARAMETER StorageInventory
  Hashtable with Files and Blobs lists from Get-StorageInventory.
.PARAMETER VMSSInventory
  Collection of VMSS inventory objects from Get-VMSSInventory.
.OUTPUTS
  PSCustomObject with source totals for external sizing calculators.
#>
function Get-VeeamSizing {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    $StorageInventory = $null,
    $VMSSInventory = $null
  )

  Write-ProgressStep -Activity "Aggregating Source Totals" -Status "Summarizing discovered infrastructure..."

  # Unwrap Generic.List to plain array to avoid Measure-Object type mismatch
  if ($null -eq $VmInventory) {
    $VmInventory = @()
  } elseif ($VmInventory -is [System.Collections.IList]) {
    $VmInventory = @($VmInventory.GetEnumerator())
  }

  # VM totals
  $totalVMs = @($VmInventory).Count
  $totalVMStorage = _SafeSum $VmInventory 'TotalProvisionedGB'

  # VMSS totals
  $vmssArr = @()
  if ($null -ne $VMSSInventory) {
    if ($VMSSInventory -is [System.Collections.IList]) {
      $vmssArr = @($VMSSInventory.GetEnumerator())
    } else {
      $vmssArr = @($VMSSInventory)
    }
  }
  $totalVMSS = $vmssArr.Count
  $totalVMSSInstances = 0
  $totalVMSSStorageGB = [double]0
  foreach ($ss in $vmssArr) {
    if ($null -ne $ss.Capacity) { $totalVMSSInstances += $ss.Capacity }
    if ($null -ne $ss.TotalDiskAllInstances) { $totalVMSSStorageGB += $ss.TotalDiskAllInstances }
  }

  # Unwrap SQL collections
  $sqlDbs = if ($null -eq $SqlInventory.Databases) { @() }
            elseif ($SqlInventory.Databases -is [System.Collections.IList]) { @($SqlInventory.Databases.GetEnumerator()) }
            else { @($SqlInventory.Databases) }

  $sqlMIs = if ($null -eq $SqlInventory.ManagedInstances) { @() }
            elseif ($SqlInventory.ManagedInstances -is [System.Collections.IList]) { @($SqlInventory.ManagedInstances.GetEnumerator()) }
            else { @($SqlInventory.ManagedInstances) }

  # SQL totals — prefer CurrentSizeGB when available, fall back to MaxSizeGB
  $totalSQLDatabases = $sqlDbs.Count
  $totalSQLMIs = $sqlMIs.Count

  $sqlDbStorage = [double]0
  foreach ($db in $sqlDbs) {
    if ($null -ne $db.CurrentSizeGB -and $db.CurrentSizeGB -gt 0) {
      $sqlDbStorage += $db.CurrentSizeGB
    } elseif ($null -ne $db.MaxSizeGB) {
      $sqlDbStorage += $db.MaxSizeGB
    }
  }
  $totalSQLStorage = $sqlDbStorage + (_SafeSum $sqlMIs 'StorageSizeGB')

  # Azure Files totals
  $fileShares = @()
  if ($null -ne $StorageInventory -and $null -ne $StorageInventory.Files) {
    if ($StorageInventory.Files -is [System.Collections.IList]) {
      $fileShares = @($StorageInventory.Files.GetEnumerator())
    } else {
      $fileShares = @($StorageInventory.Files)
    }
  }
  $totalFileSharesCount = $fileShares.Count
  $totalFileShareStorageGB = _SafeSum $fileShares 'QuotaGiB'

  # Combined source totals (includes VMSS)
  $totalSourceStorage = $totalVMStorage + $totalVMSSStorageGB + $totalSQLStorage + $totalFileShareStorageGB

  return [PSCustomObject]@{
    TotalVMs = $totalVMs
    TotalVMStorageGB = [math]::Round($totalVMStorage, 2)
    TotalVMSS = $totalVMSS
    TotalVMSSInstances = $totalVMSSInstances
    TotalVMSSStorageGB = [math]::Round($totalVMSSStorageGB, 2)
    TotalSQLDatabases = $totalSQLDatabases
    TotalSQLManagedInstances = $totalSQLMIs
    TotalSQLStorageGB = [math]::Round($totalSQLStorage, 2)
    TotalFileShares = $totalFileSharesCount
    TotalFileShareStorageGB = [math]::Round($totalFileShareStorageGB, 2)
    TotalSourceStorageGB = [math]::Round($totalSourceStorage, 2)
  }
}
