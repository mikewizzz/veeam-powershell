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

  # Unwrap Generic.List to plain array to avoid Measure-Object type mismatch
  if ($null -eq $VmInventory) {
    $VmInventory = @()
  } elseif ($VmInventory -is [System.Collections.IList]) {
    $VmInventory = @($VmInventory.GetEnumerator())
  }

  # VM totals
  $totalVMs = @($VmInventory).Count
  $totalVMStorage = _SafeSum $VmInventory 'TotalProvisionedGB'
  $totalSnapshotStorage = _SafeSum $VmInventory 'VeeamSnapshotStorageGB'
  $totalVMRepoStorage = _SafeSum $VmInventory 'VeeamRepositoryGB'

  # Unwrap SQL collections
  $sqlDbs = if ($null -eq $SqlInventory.Databases) { @() }
            elseif ($SqlInventory.Databases -is [System.Collections.IList]) { @($SqlInventory.Databases.GetEnumerator()) }
            else { @($SqlInventory.Databases) }

  $sqlMIs = if ($null -eq $SqlInventory.ManagedInstances) { @() }
            elseif ($SqlInventory.ManagedInstances -is [System.Collections.IList]) { @($SqlInventory.ManagedInstances.GetEnumerator()) }
            else { @($SqlInventory.ManagedInstances) }

  # SQL totals
  $totalSQLDatabases = $sqlDbs.Count
  $totalSQLMIs = $sqlMIs.Count
  $totalSQLStorage = (_SafeSum $sqlDbs 'MaxSizeGB') +
                     (_SafeSum $sqlMIs 'StorageSizeGB')
  $totalSQLRepoStorage = (_SafeSum $sqlDbs 'VeeamRepositoryGB') +
                         (_SafeSum $sqlMIs 'VeeamRepositoryGB')

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
