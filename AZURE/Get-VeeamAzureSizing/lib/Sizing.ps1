# =========================================================================
# Sizing.ps1 - Veeam Backup for Azure capacity calculations
# =========================================================================

<#
.SYNOPSIS
  Calculates aggregate Veeam sizing recommendations from VM and SQL inventory data.
.PARAMETER VmInventory
  Collection of VM inventory objects from Get-VMInventory.
.PARAMETER SqlInventory
  Hashtable with Databases and ManagedInstances lists from Get-SqlInventory.
.OUTPUTS
  PSCustomObject with totals and recommendations.
#>
function Get-VeeamSizing {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory
  )

  Write-ProgressStep -Activity "Calculating Veeam Sizing" -Status "Analyzing capacity requirements..."

  # VM totals
  $totalVMs = @($VmInventory).Count
  $totalVMStorage = ($VmInventory | Measure-Object -Property TotalProvisionedGB -Sum).Sum
  $totalSnapshotStorage = ($VmInventory | Measure-Object -Property VeeamSnapshotStorageGB -Sum).Sum
  $totalVMRepoStorage = ($VmInventory | Measure-Object -Property VeeamRepositoryGB -Sum).Sum

  # SQL totals
  $totalSQLDatabases = @($SqlInventory.Databases).Count
  $totalSQLMIs = @($SqlInventory.ManagedInstances).Count
  $totalSQLStorage = ($SqlInventory.Databases | Measure-Object -Property MaxSizeGB -Sum).Sum +
                     ($SqlInventory.ManagedInstances | Measure-Object -Property StorageSizeGB -Sum).Sum
  $totalSQLRepoStorage = ($SqlInventory.Databases | Measure-Object -Property VeeamRepositoryGB -Sum).Sum +
                         ($SqlInventory.ManagedInstances | Measure-Object -Property VeeamRepositoryGB -Sum).Sum

  # Combined totals
  $totalSourceStorage = $totalVMStorage + $totalSQLStorage
  $totalRepoStorage = $totalVMRepoStorage + $totalSQLRepoStorage

  # Recommendations
  $recommendations = @()

  if ($totalVMs -gt 0) {
    $recommendations += "Deploy Veeam Backup for Azure to protect $totalVMs Azure VMs"
    $recommendations += "Estimated snapshot storage required: $([math]::Ceiling($totalSnapshotStorage)) GB"
    $recommendations += "Estimated repository capacity required: $([math]::Ceiling($totalRepoStorage)) GB"
  }

  if ($totalSQLDatabases -gt 0 -or $totalSQLMIs -gt 0) {
    $recommendations += "Enable Azure SQL protection in Veeam Backup for Azure for $totalSQLDatabases databases and $totalSQLMIs managed instances"
  }

  return [PSCustomObject]@{
    TotalVMs = $totalVMs
    TotalVMStorageGB = [math]::Round($totalVMStorage, 2)
    TotalSnapshotStorageGB = [math]::Ceiling($totalSnapshotStorage)
    TotalVMRepositoryGB = [math]::Ceiling($totalVMRepoStorage)
    TotalSQLDatabases = $totalSQLDatabases
    TotalSQLManagedInstances = $totalSQLMIs
    TotalSQLStorageGB = [math]::Round($totalSQLStorage, 2)
    TotalSQLRepositoryGB = [math]::Ceiling($totalSQLRepoStorage)
    TotalSourceStorageGB = [math]::Round($totalSourceStorage, 2)
    TotalRepositoryGB = [math]::Ceiling($totalRepoStorage)
    Recommendations = $recommendations
  }
}
