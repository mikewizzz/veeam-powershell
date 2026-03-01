# =========================================================================
# DataCollection.ps1 - Azure resource inventory (VMs, SQL, Storage, Backup)
# =========================================================================

#region Filter Helpers

<#
.SYNOPSIS
  Tests whether a resource's region matches the user-specified region filter.
.PARAMETER ResourceRegion
  The Azure region of the resource.
.OUTPUTS
  [bool] True if the resource matches or no filter is set.
#>
function Test-RegionMatch($ResourceRegion) {
  if (-not $Region) { return $true }
  return ($ResourceRegion -ieq $Region)
}

<#
.SYNOPSIS
  Tests whether a resource's tags match all key-value pairs in the user-specified tag filter.
.PARAMETER Tags
  Hashtable of tags from the Azure resource.
.OUTPUTS
  [bool] True if all tag pairs match or no filter is set.
#>
function Test-TagMatch($Tags) {
  if (-not $TagFilter -or $TagFilter.Keys.Count -eq 0) { return $true }
  if (-not $Tags) { return $false }

  foreach ($k in $TagFilter.Keys) {
    if (-not $Tags.ContainsKey($k)) { return $false }
    if ($null -ne $TagFilter[$k] -and ($Tags[$k] -ne $TagFilter[$k])) { return $false }
  }
  return $true
}

#endregion

#region Retry Wrapper

<#
.SYNOPSIS
  Executes a script block with exponential backoff retry for transient Azure failures.
.PARAMETER ScriptBlock
  The code to execute.
.PARAMETER MaxRetries
  Maximum number of retry attempts (default: 3).
.OUTPUTS
  The result of the script block.
#>
function Invoke-AzWithRetry {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$ScriptBlock,
    [int]$MaxRetries = 3
  )

  $attempt = 0
  do {
    try {
      return (& $ScriptBlock)
    } catch {
      $attempt++
      if ($attempt -gt $MaxRetries) { throw }
      $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
      Write-Log "Retry $attempt/$MaxRetries after ${sleep}s: $($_.Exception.Message)" -Level "WARNING"
      Start-Sleep -Seconds $sleep
    }
  } while ($true)
}

#endregion

#region VM Inventory

<#
.SYNOPSIS
  Discovers all Azure VMs across subscriptions with disk, network, and sizing details.
.OUTPUTS
  Generic List of PSCustomObject with VM inventory and Veeam sizing estimates.
#>
function Get-VMInventory {
  Write-ProgressStep -Activity "Discovering Azure VMs" -Status "Scanning subscriptions..."

  $results = New-Object System.Collections.Generic.List[object]
  $nicsCache = @{}
  $pipsCache = @{}
  $vmCount = 0

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning VMs in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vms = @(Get-AzVM -Status -ErrorAction SilentlyContinue)

    foreach ($vm in $vms) {
      if (-not (Test-RegionMatch $vm.Location)) { continue }
      if (-not (Test-TagMatch $vm.Tags)) { continue }

      $vmCount++
      if ($vmCount % 10 -eq 0) {
        Write-Progress -Activity "Veeam Azure Sizing" -Status "Processed $vmCount VMs..." -PercentComplete (($script:CurrentStep / $script:TotalSteps) * 100)
      }

      # Network details
      $nicIds = @()
      $privateIps = @()
      $publicIps = @()

      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicId = $nicRef.Id
        $nicIds += $nicId

        if (-not $nicsCache.ContainsKey($nicId)) {
          try {
            $nicsCache[$nicId] = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
          } catch {
            Write-Log "Failed to retrieve NIC for VM $($vm.Name): $($_.Exception.Message)" -Level "WARNING"
            continue
          }
        }

        $nic = $nicsCache[$nicId]
        if (-not $nic) { continue }

        foreach ($ipc in $nic.IpConfigurations) {
          if ($ipc.PrivateIpAddress) { $privateIps += $ipc.PrivateIpAddress }

          if ($ipc.PublicIpAddress -and $ipc.PublicIpAddress.Id) {
            $pipId = $ipc.PublicIpAddress.Id
            if (-not $pipsCache.ContainsKey($pipId)) {
              try {
                $r = Get-AzResource -ResourceId $pipId -ExpandProperties -ErrorAction Stop
                $pipsCache[$pipId] = $r.Properties.ipAddress
              } catch {
                $pipsCache[$pipId] = $null
              }
            }
            if ($pipsCache[$pipId]) { $publicIps += $pipsCache[$pipId] }
          }
        }
      }

      # Disk analysis
      $osDiskGB = [int]($vm.StorageProfile.OsDisk.DiskSizeGB)
      $osDiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType

      $dataDisks = @()
      $dataSizeGB = 0
      foreach ($d in $vm.StorageProfile.DataDisks) {
        $size = [int]$d.DiskSizeGB
        $dataSizeGB += $size
        $dataDisks += "LUN$($d.Lun):$($size)GB:$($d.ManagedDisk.StorageAccountType)"
      }

      $totalProvGB = $osDiskGB + $dataSizeGB

      # Veeam sizing: 10% daily change rate for snapshot estimation
      $snapshotStorageGB = [math]::Ceiling($totalProvGB * ($SnapshotRetentionDays / 30.0) * 0.1)
      $repositoryGB = [math]::Ceiling($totalProvGB * $RepositoryOverhead)

      $results.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $vm.ResourceGroupName
        VmName = $vm.Name
        VmId = $vm.Id
        Location = $vm.Location
        Zone = ($vm.Zones -join ',')
        PowerState = ($vm.PowerState -replace 'PowerState/', '')
        OsType = $vm.StorageProfile.OsDisk.OsType
        VmSize = $vm.HardwareProfile.VmSize
        PrivateIPs = ($privateIps -join ', ')
        PublicIPs = ($publicIps -join ', ')
        Tags = (ConvertTo-FlatTags $vm.Tags)
        OsDiskType = $osDiskType
        OsDiskSizeGB = $osDiskGB
        DataDiskCount = $vm.StorageProfile.DataDisks.Count
        DataDiskSummary = ($dataDisks -join '; ')
        DataDiskTotalGB = $dataSizeGB
        TotalProvisionedGB = $totalProvGB
        VeeamSnapshotStorageGB = $snapshotStorageGB
        VeeamRepositoryGB = $repositoryGB
      })
    }
  }

  Write-Log "Discovered $vmCount Azure VMs" -Level "SUCCESS"
  return ,$results
}

#endregion

#region SQL Inventory

<#
.SYNOPSIS
  Discovers Azure SQL Databases and Managed Instances across subscriptions.
.OUTPUTS
  Hashtable with Databases and ManagedInstances lists.
#>
function Get-SqlInventory {
  Write-ProgressStep -Activity "Discovering Azure SQL" -Status "Scanning databases and managed instances..."

  $dbs = New-Object System.Collections.Generic.List[object]
  $mis = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Azure SQL in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # SQL Databases
    $servers = @(Get-AzSqlServer -ErrorAction SilentlyContinue)
    foreach ($srv in $servers) {
      if (-not (Test-RegionMatch $srv.Location)) { continue }

      $databases = @(Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.DatabaseName -ne "master" })

      foreach ($db in $databases) {
        $maxSizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)
        $veeamRepoGB = [math]::Ceiling($maxSizeGB * 1.3)

        $dbs.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $srv.ResourceGroupName
          ServerName = $srv.ServerName
          DatabaseName = $db.DatabaseName
          Location = $db.Location
          Edition = $db.Edition
          ServiceObjective = $db.CurrentServiceObjectiveName
          MaxSizeGB = $maxSizeGB
          ZoneRedundant = $db.ZoneRedundant
          BackupStorageRedundancy = $db.BackupStorageRedundancy
          VeeamRepositoryGB = $veeamRepoGB
        })
      }
    }

    # Managed Instances
    $managed = @(Get-AzSqlInstance -ErrorAction SilentlyContinue)
    foreach ($mi in $managed) {
      if (-not (Test-RegionMatch $mi.Location)) { continue }

      $storageGB = $mi.StorageSizeInGB
      $veeamRepoGB = [math]::Ceiling($storageGB * 1.3)

      $mis.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $mi.ResourceGroupName
        ManagedInstance = $mi.Name
        Location = $mi.Location
        VCores = $mi.VCores
        StorageSizeGB = $storageGB
        LicenseType = $mi.LicenseType
        VeeamRepositoryGB = $veeamRepoGB
      })
    }
  }

  Write-Log "Discovered $($dbs.Count) SQL Databases and $($mis.Count) Managed Instances" -Level "SUCCESS"

  return @{
    Databases = $dbs
    ManagedInstances = $mis
  }
}

#endregion

#region Storage Inventory

<#
.SYNOPSIS
  Discovers Azure Files shares and Blob containers across subscriptions.
.OUTPUTS
  Hashtable with Files and Blobs lists.
#>
function Get-StorageInventory {
  Write-ProgressStep -Activity "Discovering Azure Storage" -Status "Scanning Files and Blob containers..."

  $files = New-Object System.Collections.Generic.List[object]
  $blobs = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Storage in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $accts = @(Get-AzStorageAccount -ErrorAction SilentlyContinue)

    foreach ($acct in $accts) {
      if (-not (Test-RegionMatch $acct.Location)) { continue }

      $ctx = $acct.Context

      # Azure Files
      try {
        $shares = @(Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue)
        foreach ($sh in $shares) {
          $usageBytes = $null
          try {
            $rmShare = Get-AzRmStorageShare -ResourceGroupName $acct.ResourceGroupName -StorageAccountName $acct.StorageAccountName -Name $sh.Name -Expand "stats" -ErrorAction Stop
            $usageBytes = $rmShare.ShareUsageBytes
          } catch {}

          $usageGiB = if ($usageBytes) { [math]::Round($usageBytes / 1GB, 2) } else { $null }

          $files.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId = $sub.Id
            ResourceGroup = $acct.ResourceGroupName
            StorageAccount = $acct.StorageAccountName
            Location = $acct.Location
            ShareName = $sh.Name
            QuotaGiB = $sh.Quota
            UsageGiB = $usageGiB
          })
        }
      } catch {
        Write-Log "Failed to enumerate Azure Files in $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
      }

      # Azure Blob
      try {
        $containers = @(Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue)
        foreach ($c in $containers) {
          $sizeBytes = $null

          if ($CalculateBlobSizes) {
            $sizeBytes = 0
            $token = $null
            do {
              $page = Get-AzStorageBlob -Container $c.Name -Context $ctx -MaxCount 5000 -ContinuationToken $token -ErrorAction SilentlyContinue
              foreach ($b in $page) {
                $sizeBytes += [int64]($b.Length)
              }
              $token = $page.ContinuationToken
            } while ($token)
          }

          $sizeGiB = if ($sizeBytes) { [math]::Round($sizeBytes / 1GB, 2) } else { $null }

          $blobs.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId = $sub.Id
            ResourceGroup = $acct.ResourceGroupName
            StorageAccount = $acct.StorageAccountName
            Location = $acct.Location
            Container = $c.Name
            PublicAccess = $c.PublicAccess
            EstimatedGiB = $sizeGiB
          })
        }
      } catch {
        Write-Log "Failed to enumerate Blob containers in $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
      }
    }
  }

  Write-Log "Discovered $($files.Count) Azure File Shares and $($blobs.Count) Blob containers" -Level "SUCCESS"

  return @{
    Files = $files
    Blobs = $blobs
  }
}

#endregion

#region Azure Backup Inventory

<#
.SYNOPSIS
  Discovers Recovery Services Vaults, protected items, and backup policies.
.OUTPUTS
  Hashtable with Vaults and Policies lists.
#>
function Get-AzureBackupInventory {
  Write-ProgressStep -Activity "Analyzing Azure Backup" -Status "Scanning Recovery Services Vaults..."

  $vaultsOut = New-Object System.Collections.Generic.List[object]
  $policiesOut = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Azure Backup in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vaults = @(Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue)

    foreach ($v in $vaults) {
      if (-not (Test-RegionMatch $v.Location)) { continue }

      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null

      # Count protected items by workload type
      $vmCount = 0
      $sqlCount = 0
      $afsCount = 0

      $workloadQueries = @(
        @{ BackupManagementType = "AzureIaasVM"; WorkloadType = "AzureVM"; Counter = "vm" },
        @{ BackupManagementType = "AzureWorkload"; WorkloadType = "MSSQL"; Counter = "sql" },
        @{ BackupManagementType = "AzureStorage"; WorkloadType = "AzureFiles"; Counter = "afs" }
      )

      foreach ($wq in $workloadQueries) {
        try {
          $items = @(Get-AzRecoveryServicesBackupItem -VaultId $v.ID -BackupManagementType $wq.BackupManagementType -WorkloadType $wq.WorkloadType -ErrorAction SilentlyContinue)
          switch ($wq.Counter) {
            "vm"  { $vmCount = $items.Count }
            "sql" { $sqlCount = $items.Count }
            "afs" { $afsCount = $items.Count }
          }
        } catch {
          Write-Log "Failed to query $($wq.WorkloadType) items in vault $($v.Name): $($_.Exception.Message)" -Level "WARNING"
        }
      }

      $vaultsOut.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $v.ResourceGroupName
        VaultName = $v.Name
        Location = $v.Location
        SoftDeleteState = $v.Properties.SoftDeleteFeatureState
        Immutability = $v.Properties.ImmutabilityState
        ProtectedVMs = $vmCount
        ProtectedSQL = $sqlCount
        ProtectedFileShares = $afsCount
      })

      # Policies
      $pols = @(Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue)
      foreach ($p in $pols) {
        $policiesOut.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          VaultName = $v.Name
          PolicyName = $p.Name
          WorkloadType = $p.WorkloadType
          BackupManagement = $p.BackupManagementType
        })
      }
    }
  }

  Write-Log "Discovered $($vaultsOut.Count) Recovery Services Vaults with $($policiesOut.Count) policies" -Level "SUCCESS"

  return @{
    Vaults = $vaultsOut
    Policies = $policiesOut
  }
}

#endregion
