# SPDX-License-Identifier: MIT
# =========================================================================
# Sizing.ps1 - Veeam Backup for Azure source data aggregation
# =========================================================================

<#
.SYNOPSIS
  Aggregates source infrastructure totals from VM, SQL, PaaS database, storage, and VMSS inventory data.
.PARAMETER VmInventory
  Collection of VM inventory objects from Get-VMInventory.
.PARAMETER SqlInventory
  Hashtable with Databases and ManagedInstances lists from Get-SqlInventory.
.PARAMETER StorageInventory
  Hashtable with Files and Blobs lists from Get-StorageInventory.
.PARAMETER VMSSInventory
  Collection of VMSS inventory objects from Get-VMSSInventory.
.PARAMETER PaaSInventory
  Hashtable with PostgreSQL, MySQL, CosmosDB, and Redis lists from Get-PaaSInventory.
.PARAMETER AdditionalResources
  Hashtable with OrphanedDisks list from Get-AdditionalResources.
.OUTPUTS
  PSCustomObject with source totals for external sizing calculators.
#>
function Get-VeeamSizing {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    $StorageInventory = $null,
    $VMSSInventory = $null,
    $PaaSInventory = $null,
    $AdditionalResources = $null
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

  # PaaS database totals — PostgreSQL
  $pgArr = @()
  if ($null -ne $PaaSInventory -and $null -ne $PaaSInventory.PostgreSQL) {
    if ($PaaSInventory.PostgreSQL -is [System.Collections.IList]) {
      $pgArr = @($PaaSInventory.PostgreSQL.GetEnumerator())
    } else {
      $pgArr = @($PaaSInventory.PostgreSQL)
    }
  }
  $totalPostgreSQL = $pgArr.Count
  $totalPostgreSQLStorageGB = _SafeSum $pgArr 'StorageSizeGB'

  # PaaS database totals — MySQL
  $mysqlArr = @()
  if ($null -ne $PaaSInventory -and $null -ne $PaaSInventory.MySQL) {
    if ($PaaSInventory.MySQL -is [System.Collections.IList]) {
      $mysqlArr = @($PaaSInventory.MySQL.GetEnumerator())
    } else {
      $mysqlArr = @($PaaSInventory.MySQL)
    }
  }
  $totalMySQL = $mysqlArr.Count
  $totalMySQLStorageGB = _SafeSum $mysqlArr 'StorageSizeGB'

  # PaaS database totals — Cosmos DB (count only; ARM does not expose storage metrics)
  $cosmosArr = @()
  if ($null -ne $PaaSInventory -and $null -ne $PaaSInventory.CosmosDB) {
    if ($PaaSInventory.CosmosDB -is [System.Collections.IList]) {
      $cosmosArr = @($PaaSInventory.CosmosDB.GetEnumerator())
    } else {
      $cosmosArr = @($PaaSInventory.CosmosDB)
    }
  }
  $totalCosmosDB = $cosmosArr.Count

  # PaaS database totals — Redis (count only; ARM does not expose storage metrics)
  $redisArr = @()
  if ($null -ne $PaaSInventory -and $null -ne $PaaSInventory.Redis) {
    if ($PaaSInventory.Redis -is [System.Collections.IList]) {
      $redisArr = @($PaaSInventory.Redis.GetEnumerator())
    } else {
      $redisArr = @($PaaSInventory.Redis)
    }
  }
  $totalRedis = $redisArr.Count

  # Orphaned disk totals
  $orphanedDisks = @()
  if ($null -ne $AdditionalResources -and $null -ne $AdditionalResources.OrphanedDisks) {
    if ($AdditionalResources.OrphanedDisks -is [System.Collections.IList]) {
      $orphanedDisks = @($AdditionalResources.OrphanedDisks.GetEnumerator())
    } else {
      $orphanedDisks = @($AdditionalResources.OrphanedDisks)
    }
  }
  $totalOrphanedDisks = $orphanedDisks.Count
  $totalOrphanedDiskStorageGB = _SafeSum $orphanedDisks 'DiskSizeGB'

  # Combined source totals (includes VMSS, PaaS databases, and orphaned disks)
  $totalPaaSStorage = $totalPostgreSQLStorageGB + $totalMySQLStorageGB
  $totalSourceStorage = $totalVMStorage + $totalVMSSStorageGB + $totalSQLStorage + $totalFileShareStorageGB + $totalPaaSStorage + $totalOrphanedDiskStorageGB

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
    TotalPostgreSQL = $totalPostgreSQL
    TotalPostgreSQLStorageGB = [math]::Round($totalPostgreSQLStorageGB, 2)
    TotalMySQL = $totalMySQL
    TotalMySQLStorageGB = [math]::Round($totalMySQLStorageGB, 2)
    TotalCosmosDB = $totalCosmosDB
    TotalRedis = $totalRedis
    TotalOrphanedDisks = $totalOrphanedDisks
    TotalOrphanedDiskStorageGB = [math]::Round($totalOrphanedDiskStorageGB, 2)
    TotalSourceStorageGB = [math]::Round($totalSourceStorage, 2)
  }
}
