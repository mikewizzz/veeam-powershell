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
function Test-RegionMatch {
  [CmdletBinding()]
  param([string]$ResourceRegion)
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
function Test-TagMatch {
  [CmdletBinding()]
  param([hashtable]$Tags)
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
      # Do not retry non-transient errors (403 Forbidden, 404 Not Found, 401 Unauthorized)
      $statusCode = $null
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }
      if ($statusCode -eq 403 -or $statusCode -eq 404 -or $statusCode -eq 401) {
        Write-Log "Non-retryable error ($statusCode): $($_.Exception.Message)" -Level "WARNING"
        throw
      }
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
  $vmCount = 0

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning VMs in subscription: $($sub.Name)" -Level "INFO"
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    # Batch-fetch all NICs and PIPs for this subscription to avoid N+1 API calls
    $nicsCache = @{}
    $pipsCache = @{}
    try {
      $allNics = @(Get-AzNetworkInterface -ErrorAction Stop)
      foreach ($nic in $allNics) {
        $nicsCache[$nic.Id] = $nic
      }
      Write-Log "Cached $($allNics.Count) NICs for subscription $($sub.Name)" -Level "INFO"
    } catch {
      Write-Log "Failed to batch-fetch NICs for $($sub.Name), falling back to per-VM: $($_.Exception.Message)" -Level "WARNING"
    }

    # Server-side region filter when specified
    $getVmParams = @{ Status = $true; ErrorAction = "Stop" }
    if ($Region) { $getVmParams.Location = $Region }
    $vms = @(Invoke-AzWithRetry { Get-AzVM @getVmParams })

    foreach ($vm in $vms) {
      if (-not (Test-RegionMatch $vm.Location)) { continue }
      if (-not (Test-TagMatch $vm.Tags)) { continue }

      $vmCount++
      if ($vmCount % 10 -eq 0) {
        Write-Progress -Activity "Veeam Azure Sizing" -Status "Processed $vmCount VMs..." -PercentComplete (($script:CurrentStep / $script:TotalSteps) * 100)
      }

      # Network details
      $privateIps = @()
      $publicIps = @()

      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicId = $nicRef.Id

        # Use batch cache, fall back to individual fetch
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
      $osDiskGB = $vm.StorageProfile.OsDisk.DiskSizeGB
      if ($null -eq $osDiskGB) {
        Write-Log "VM $($vm.Name) has no reported OS disk size - defaulting to 30 GB" -Level "WARNING"
        $osDiskGB = 30
      } else {
        $osDiskGB = [int]$osDiskGB
      }
      $osDiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType

      $dataDisks = @()
      $dataSizeGB = 0
      foreach ($d in $vm.StorageProfile.DataDisks) {
        $size = $d.DiskSizeGB
        if ($null -eq $size) {
          Write-Log "VM $($vm.Name) data disk LUN$($d.Lun) has no reported size - defaulting to 0 GB" -Level "WARNING"
          $size = 0
        } else {
          $size = [int]$size
        }
        $dataSizeGB += $size
        $dataDisks += "LUN$($d.Lun):$($size)GB:$($d.ManagedDisk.StorageAccountType)"
      }

      $totalProvGB = $osDiskGB + $dataSizeGB

      # Snapshot sizing: provisioned capacity x (retention / 30) x daily change rate
      # Deallocated VMs have zero I/O, so change rate = 0
      $powerState = ($vm.PowerState -replace 'PowerState/', '')
      $effectiveChangeRate = $DailyChangeRate
      if ($powerState -like "*deallocated*" -or $powerState -like "*stopped*") {
        $effectiveChangeRate = 0
      }
      $snapshotStorageGB = [math]::Ceiling($totalProvGB * ($SnapshotRetentionDays / 30) * $effectiveChangeRate)
      $repositoryGB = [math]::Ceiling($totalProvGB * $RepositoryOverhead)

      # Default zone to N/A for non-zonal VMs
      $zoneValue = if ($vm.Zones -and $vm.Zones.Count -gt 0) { ($vm.Zones -join ',') } else { "N/A" }

      $results.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $vm.ResourceGroupName
        VmName = $vm.Name
        VmId = $vm.Id
        Location = $vm.Location
        Zone = $zoneValue
        PowerState = $powerState
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
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    # SQL Databases
    $servers = @(Invoke-AzWithRetry { Get-AzSqlServer -ErrorAction Stop })
    foreach ($srv in $servers) {
      if (-not (Test-RegionMatch $srv.Location)) { continue }

      $databases = @(Invoke-AzWithRetry { Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction Stop } |
        Where-Object { $_.DatabaseName -ne "master" })

      foreach ($db in $databases) {
        # Hyperscale tier has no fixed max size (MaxSizeBytes = 0)
        $isHyperscale = ($db.Edition -eq 'Hyperscale')
        $maxSizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)

        # Capture actual current size where available
        $currentSizeGB = $null
        if ($null -ne $db.CurrentSizeBytes -and $db.CurrentSizeBytes -gt 0) {
          $currentSizeGB = [math]::Round($db.CurrentSizeBytes / 1GB, 2)
        }

        # Use current size for sizing when available, otherwise max size
        $sizingGB = $maxSizeGB
        if ($null -ne $currentSizeGB -and $currentSizeGB -gt 0) {
          $sizingGB = $currentSizeGB
        }

        # Hyperscale: flag for manual sizing if no current size available
        $hyperscaleNote = $null
        if ($isHyperscale -and $maxSizeGB -eq 0 -and ($null -eq $currentSizeGB -or $currentSizeGB -eq 0)) {
          $hyperscaleNote = "Hyperscale: requires manual sizing"
          Write-Log "SQL DB $($db.DatabaseName) on $($srv.ServerName) is Hyperscale with unknown size — requires manual sizing" -Level "WARNING"
        }

        $veeamRepoGB = [math]::Ceiling($sizingGB * $RepositoryOverhead)

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
          CurrentSizeGB = $currentSizeGB
          SizingNote = $hyperscaleNote
          ZoneRedundant = $db.ZoneRedundant
          BackupStorageRedundancy = $db.BackupStorageRedundancy
          VeeamRepositoryGB = $veeamRepoGB
        })
      }
    }

    # Managed Instances
    $managed = @(Invoke-AzWithRetry { Get-AzSqlInstance -ErrorAction Stop })
    foreach ($mi in $managed) {
      if (-not (Test-RegionMatch $mi.Location)) { continue }

      $storageGB = $mi.StorageSizeInGB
      $veeamRepoGB = [math]::Ceiling($storageGB * $RepositoryOverhead)

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
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    $accts = @(Invoke-AzWithRetry { Get-AzStorageAccount -ErrorAction Stop })

    foreach ($acct in $accts) {
      if (-not (Test-RegionMatch $acct.Location)) { continue }

      # Storage context requires listkeys (Storage Account Contributor or higher)
      # RBAC-only accounts (no key access) produce null context
      $ctx = $null
      try {
        $ctx = $acct.Context
      } catch {
        Write-Log "Cannot access storage account key for $($acct.StorageAccountName) — requires Storage Account Key Operator or Contributor role" -Level "WARNING"
      }
      if ($null -eq $ctx) {
        Write-Log "Skipping $($acct.StorageAccountName) — null context (likely RBAC-only or insufficient permissions)" -Level "WARNING"
        continue
      }

      # Azure Files
      try {
        $shares = @(Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue)
        foreach ($sh in $shares) {
          $usageBytes = $null
          try {
            $rmShare = Get-AzRmStorageShare -ResourceGroupName $acct.ResourceGroupName -StorageAccountName $acct.StorageAccountName -Name $sh.Name -Expand "stats" -ErrorAction Stop
            $usageBytes = $rmShare.ShareUsageBytes
          } catch {
            Write-Log "Failed to retrieve share usage for $($sh.Name) in $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
          }

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
            $pageCount = 0
            $maxPages = 10000
            do {
              try {
                $page = Get-AzStorageBlob -Container $c.Name -Context $ctx -MaxCount 5000 -ContinuationToken $token -ErrorAction Stop
              } catch {
                Write-Log "Blob enumeration error in $($c.Name) on $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
                break
              }
              foreach ($b in $page) {
                $sizeBytes += [int64]($b.Length)
              }
              $token = if ($page) { ($page | Select-Object -Last 1).ContinuationToken } else { $null }
              $pageCount++
              if ($pageCount -ge $maxPages) {
                Write-Log "Blob enumeration capped at $maxPages pages for container $($c.Name) in $($acct.StorageAccountName) — size is approximate" -Level "WARNING"
                break
              }
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
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    $vaults = @(Invoke-AzWithRetry { Get-AzRecoveryServicesVault -ErrorAction Stop })

    foreach ($v in $vaults) {
      if (-not (Test-RegionMatch $v.Location)) { continue }

      # Wrap vault context in try/catch — one inaccessible vault should not kill the script
      try {
        Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null
      } catch {
        Write-Log "Cannot access vault $($v.Name): $($_.Exception.Message) — skipping" -Level "WARNING"
        continue
      }

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
          # Use ErrorAction Stop to detect throttling/failures (SilentlyContinue would silently drop to 0)
          $items = @(Get-AzRecoveryServicesBackupItem -VaultId $v.ID -BackupManagementType $wq.BackupManagementType -WorkloadType $wq.WorkloadType -ErrorAction Stop)
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
      $pols = @(Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $v.ID -ErrorAction SilentlyContinue)
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
