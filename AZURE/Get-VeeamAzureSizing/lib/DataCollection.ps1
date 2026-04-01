# SPDX-License-Identifier: MIT
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
      # Parse Retry-After header from 429/503 responses; fall back to exponential backoff
      $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
      if ($_.Exception.Response -and $_.Exception.Response.Headers) {
        try {
          $retryAfter = $_.Exception.Response.Headers | Where-Object { $_.Key -eq 'Retry-After' } | Select-Object -First 1
          if ($retryAfter -and $retryAfter.Value) {
            $retryVal = "$($retryAfter.Value)" -replace '[^\d]', ''
            if ($retryVal -match '^\d+$') {
              $parsedSleep = [int]$retryVal
              if ($parsedSleep -gt 0 -and $parsedSleep -le 120) {
                $sleep = $parsedSleep
              }
            }
          }
        } catch [System.Exception] {
          Write-Log "Retry-After header parse failed, using exponential backoff" -Level "INFO"
        }
      }
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

    # Batch-fetch all NICs, PIPs, and NSGs for this subscription to avoid N+1 API calls
    $nicsCache = @{}
    $pipsCache = @{}
    $nsgsCache = @{}
    try {
      $allNics = @(Get-AzNetworkInterface -ErrorAction Stop)
      foreach ($nic in $allNics) {
        $nicsCache[$nic.Id] = $nic
      }
      Write-Log "Cached $($allNics.Count) NICs for subscription $($sub.Name)" -Level "INFO"
    } catch {
      Write-Log "Failed to batch-fetch NICs for $($sub.Name), falling back to per-VM: $($_.Exception.Message)" -Level "WARNING"
    }

    # Batch-fetch NSGs for exposure analysis
    try {
      $allNsgs = @(Get-AzNetworkSecurityGroup -ErrorAction Stop)
      foreach ($nsg in $allNsgs) {
        $nsgsCache[$nsg.Id] = $nsg
      }
      Write-Log "Cached $($allNsgs.Count) NSGs for subscription $($sub.Name)" -Level "INFO"
    } catch {
      Write-Log "Failed to batch-fetch NSGs for $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
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

      # NSG exposure analysis — check for dangerous inbound rules
      $nsgNames = New-Object System.Collections.Generic.List[string]
      $exposedPorts = New-Object System.Collections.Generic.List[string]
      $dangerousPorts = @(22, 3389, 1433, 3306, 5432, 445)
      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicId = $nicRef.Id
        if ($nicsCache.ContainsKey($nicId)) {
          $nic = $nicsCache[$nicId]
          if ($null -ne $nic.NetworkSecurityGroup -and $null -ne $nic.NetworkSecurityGroup.Id) {
            $nsgId = $nic.NetworkSecurityGroup.Id
            if ($nsgsCache.ContainsKey($nsgId)) {
              $nsg = $nsgsCache[$nsgId]
              if (-not $nsgNames.Contains($nsg.Name)) { $nsgNames.Add($nsg.Name) }
              foreach ($rule in $nsg.SecurityRules) {
                if ($rule.Direction -eq 'Inbound' -and $rule.Access -eq 'Allow') {
                  $srcAny = ($rule.SourceAddressPrefix -eq '*' -or $rule.SourceAddressPrefix -eq '0.0.0.0/0' -or $rule.SourceAddressPrefix -eq 'Internet')
                  if ($srcAny) {
                    $portRange = "$($rule.DestinationPortRange)"
                    if ($portRange -eq '*') {
                      if (-not $exposedPorts.Contains('*')) { $exposedPorts.Add('*') }
                    } else {
                      foreach ($dp in $dangerousPorts) {
                        if ($portRange -match "(^|,)$dp($|,|-)" -or $portRange -eq "$dp") {
                          $portStr = "$dp"
                          if (-not $exposedPorts.Contains($portStr)) { $exposedPorts.Add($portStr) }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
      $nsgDisplay = if ($nsgNames.Count -gt 0) { $nsgNames -join ', ' } else { "None" }
      $exposureLevel = "Low"
      if ($exposedPorts.Count -gt 0) {
        if ($exposedPorts.Contains('*')) { $exposureLevel = "Critical" }
        else { $exposureLevel = "High" }
      } elseif ($publicIps.Count -gt 0) {
        $exposureLevel = "Medium"
      }
      $exposedPortsDisplay = if ($exposedPorts.Count -gt 0) { $exposedPorts -join ', ' } else { "None" }

      # Disk analysis — null means size unknown (do NOT fabricate a default)
      $osDiskGB = $vm.StorageProfile.OsDisk.DiskSizeGB
      $osDiskUnknown = $false
      if ($null -eq $osDiskGB) {
        Write-Log "VM $($vm.Name) has no reported OS disk size — marked as unknown" -Level "WARNING"
        $osDiskUnknown = $true
        $osDiskGB = 0
      } else {
        $osDiskGB = [int]$osDiskGB
      }
      $osDiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType

      # Disk encryption status
      $encryptionType = "None"
      $diskEncryptionSetId = $vm.StorageProfile.OsDisk.ManagedDisk.DiskEncryptionSetId
      if ($null -ne $vm.StorageProfile.OsDisk.EncryptionSettings -and $vm.StorageProfile.OsDisk.EncryptionSettings.Enabled -eq $true) {
        $encryptionType = "ADE"
      } elseif (-not [string]::IsNullOrWhiteSpace($diskEncryptionSetId)) {
        $encryptionType = "SSE-CMK"
      } else {
        # Platform-managed (SSE-PMK) is always on for managed disks — flag it
        $encryptionType = "SSE-PMK"
      }

      # Managed identity
      $identityType = "None"
      if ($null -ne $vm.Identity -and $null -ne $vm.Identity.Type) {
        $identityType = "$($vm.Identity.Type)"
      }

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

      $powerState = ($vm.PowerState -replace 'PowerState/', '')

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
        OsDiskUnknownSize = $osDiskUnknown
        DataDiskCount = $vm.StorageProfile.DataDisks.Count
        DataDiskSummary = ($dataDisks -join '; ')
        DataDiskTotalGB = $dataSizeGB
        TotalProvisionedGB = $totalProvGB
        EncryptionType = $encryptionType
        ManagedIdentity = $identityType
        NSGs = $nsgDisplay
        ExposureLevel = $exposureLevel
        ExposedPorts = $exposedPortsDisplay
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
        })
      }
    }

    # Managed Instances
    $managed = @(Invoke-AzWithRetry { Get-AzSqlInstance -ErrorAction Stop })
    foreach ($mi in $managed) {
      if (-not (Test-RegionMatch $mi.Location)) { continue }

      $storageGB = $mi.StorageSizeInGB

      $mis.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $mi.ResourceGroupName
        ManagedInstance = $mi.Name
        Location = $mi.Location
        VCores = $mi.VCores
        StorageSizeGB = $storageGB
        LicenseType = $mi.LicenseType
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

#region VMSS Inventory

<#
.SYNOPSIS
  Discovers Azure Virtual Machine Scale Sets across subscriptions.
.OUTPUTS
  Generic List of PSCustomObject with VMSS inventory.
#>
function Get-VMSSInventory {
  Write-ProgressStep -Activity "Discovering VMSS" -Status "Scanning scale sets..."

  $results = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning VMSS in subscription: $($sub.Name)" -Level "INFO"
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    $scaleSets = @(Invoke-AzWithRetry { Get-AzVmss -ErrorAction Stop })

    foreach ($vmss in $scaleSets) {
      if (-not (Test-RegionMatch $vmss.Location)) { continue }

      $capacity = 0
      if ($null -ne $vmss.Sku -and $null -ne $vmss.Sku.Capacity) {
        $capacity = [int]$vmss.Sku.Capacity
      }
      $skuName = if ($null -ne $vmss.Sku) { $vmss.Sku.Name } else { "Unknown" }

      # OS disk size per instance
      $osDiskGB = 0
      if ($null -ne $vmss.VirtualMachineProfile -and $null -ne $vmss.VirtualMachineProfile.StorageProfile) {
        $osDiskSize = $vmss.VirtualMachineProfile.StorageProfile.OsDisk.DiskSizeGB
        if ($null -ne $osDiskSize) { $osDiskGB = [int]$osDiskSize }
      }

      # Data disks per instance
      $dataDiskCount = 0
      $dataDiskGB = 0
      if ($null -ne $vmss.VirtualMachineProfile -and $null -ne $vmss.VirtualMachineProfile.StorageProfile -and $null -ne $vmss.VirtualMachineProfile.StorageProfile.DataDisks) {
        $dataDiskCount = $vmss.VirtualMachineProfile.StorageProfile.DataDisks.Count
        foreach ($d in $vmss.VirtualMachineProfile.StorageProfile.DataDisks) {
          if ($null -ne $d.DiskSizeGB) { $dataDiskGB += [int]$d.DiskSizeGB }
        }
      }

      $totalDiskPerInstance = $osDiskGB + $dataDiskGB
      $totalDiskAllInstances = $totalDiskPerInstance * $capacity

      # Identity
      $identityType = "None"
      if ($null -ne $vmss.Identity -and $null -ne $vmss.Identity.Type) {
        $identityType = "$($vmss.Identity.Type)"
      }

      $zoneValue = if ($vmss.Zones -and $vmss.Zones.Count -gt 0) { ($vmss.Zones -join ',') } else { "N/A" }

      $results.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $vmss.ResourceGroupName
        Name = $vmss.Name
        Location = $vmss.Location
        Zone = $zoneValue
        SkuName = $skuName
        Capacity = $capacity
        OsDiskGB = $osDiskGB
        DataDiskCount = $dataDiskCount
        DataDiskGB = $dataDiskGB
        TotalDiskPerInstance = $totalDiskPerInstance
        TotalDiskAllInstances = $totalDiskAllInstances
        ManagedIdentity = $identityType
        Tags = (ConvertTo-FlatTags $vmss.Tags)
      })
    }
  }

  Write-Log "Discovered $($results.Count) Virtual Machine Scale Sets" -Level "SUCCESS"
  return ,$results
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
  $storageAccounts = New-Object System.Collections.Generic.List[object]
  $skippedAccounts = 0

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

      # Storage account security posture
      $httpsOnly = $acct.EnableHttpsTrafficOnly
      $minTls = if ($null -ne $acct.MinimumTlsVersion) { "$($acct.MinimumTlsVersion)" } else { "Unknown" }
      $publicAccess = if ($null -ne $acct.AllowBlobPublicAccess) { $acct.AllowBlobPublicAccess } else { $true }
      $networkDefault = "Allow"
      if ($null -ne $acct.NetworkRuleSet -and $null -ne $acct.NetworkRuleSet.DefaultAction) {
        $networkDefault = "$($acct.NetworkRuleSet.DefaultAction)"
      }
      $keyAccess = if ($null -ne $acct.AllowSharedKeyAccess) { $acct.AllowSharedKeyAccess } else { $true }

      # ADLS Gen2 detection — hierarchical namespace enabled
      $isHnsEnabled = if ($null -ne $acct.EnableHierarchicalNamespace) { $acct.EnableHierarchicalNamespace } else { $false }

      $storageAccounts.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $acct.ResourceGroupName
        StorageAccount = $acct.StorageAccountName
        Location = $acct.Location
        Kind = $acct.Kind
        SkuName = $acct.Sku.Name
        IsHnsEnabled = $isHnsEnabled
        HttpsOnly = $httpsOnly
        MinTlsVersion = $minTls
        AllowBlobPublicAccess = $publicAccess
        NetworkDefaultAction = $networkDefault
        AllowSharedKeyAccess = $keyAccess
      })

      # Storage context requires listkeys (Storage Account Contributor or higher)
      # RBAC-only accounts (no key access) produce null context
      $ctx = $null
      try {
        $ctx = $acct.Context
      } catch {
        Write-Log "Cannot access storage account key for $($acct.StorageAccountName) — requires Storage Account Key Operator or Contributor role" -Level "WARNING"
      }
      if ($null -eq $ctx) {
        Write-Log "Skipping $($acct.StorageAccountName) data enumeration — null context (likely RBAC-only or insufficient permissions)" -Level "WARNING"
        $skippedAccounts++
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

  if ($skippedAccounts -gt 0) {
    Write-Log "$skippedAccounts storage account(s) skipped due to RBAC-only or insufficient permissions" -Level "WARNING"
  }
  Write-Log "Discovered $($storageAccounts.Count) storage accounts, $($files.Count) Azure File Shares, and $($blobs.Count) Blob containers" -Level "SUCCESS"

  return @{
    Files = $files
    Blobs = $blobs
    StorageAccounts = $storageAccounts
    SkippedAccounts = $skippedAccounts
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

#region Additional Resource Discovery

<#
.SYNOPSIS
  Discovers Key Vaults, AKS clusters, and App Services across subscriptions.
.OUTPUTS
  Hashtable with KeyVaults, AKSClusters, and AppServices lists.
#>
function Get-AdditionalResources {
  Write-ProgressStep -Activity "Discovering Additional Resources" -Status "Scanning Key Vaults, AKS, App Services, and more..."

  $keyVaults = New-Object System.Collections.Generic.List[object]
  $aksClusters = New-Object System.Collections.Generic.List[object]
  $webApps = New-Object System.Collections.Generic.List[object]
  $functionApps = New-Object System.Collections.Generic.List[object]
  $containerRegistries = New-Object System.Collections.Generic.List[object]
  $logicApps = New-Object System.Collections.Generic.List[object]
  $dataFactories = New-Object System.Collections.Generic.List[object]
  $apiManagement = New-Object System.Collections.Generic.List[object]
  $eventHubs = New-Object System.Collections.Generic.List[object]
  $serviceBus = New-Object System.Collections.Generic.List[object]
  $orphanedDisks = New-Object System.Collections.Generic.List[object]
  $snapshots = New-Object System.Collections.Generic.List[object]
  $availabilitySets = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning additional resources in subscription: $($sub.Name)" -Level "INFO"
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    # Key Vaults — use Az.Resources generic query (no extra module dependency)
    try {
      $vaults = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.KeyVault/vaults' -ExpandProperties -ErrorAction Stop })
      foreach ($kv in $vaults) {
        if (-not (Test-RegionMatch $kv.Location)) { continue }
        $props = $kv.Properties
        $softDelete = if ($null -ne $props -and $null -ne $props.enableSoftDelete) { $props.enableSoftDelete } else { $false }
        $purgeProtection = if ($null -ne $props -and $null -ne $props.enablePurgeProtection) { $props.enablePurgeProtection } else { $false }
        $keyVaults.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $kv.ResourceGroupName
          Name = $kv.Name
          Location = $kv.Location
          SoftDeleteEnabled = $softDelete
          PurgeProtection = $purgeProtection
        })
      }
    } catch {
      Write-Log "Failed to enumerate Key Vaults in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # AKS Clusters — deep node pool profiling
    try {
      $clusters = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.ContainerService/managedClusters' -ExpandProperties -ErrorAction Stop })
      foreach ($aks in $clusters) {
        if (-not (Test-RegionMatch $aks.Location)) { continue }
        $props = $aks.Properties
        $nodeCount = 0
        $poolCount = 0
        $poolDetails = New-Object System.Collections.Generic.List[string]
        if ($null -ne $props -and $null -ne $props.agentPoolProfiles) {
          $poolCount = @($props.agentPoolProfiles).Count
          foreach ($pool in $props.agentPoolProfiles) {
            $pCount = if ($null -ne $pool.count) { [int]$pool.count } else { 0 }
            $nodeCount += $pCount
            $pName = if ($null -ne $pool.name) { "$($pool.name)" } else { "unknown" }
            $pSize = if ($null -ne $pool.vmSize) { "$($pool.vmSize)" } else { "?" }
            $pMode = if ($null -ne $pool.mode) { "$($pool.mode)" } else { "?" }
            $pOs = if ($null -ne $pool.osType) { "$($pool.osType)" } else { "?" }
            $poolDetails.Add("${pName}:${pCount}x${pSize}(${pMode},${pOs})")
          }
        }
        $k8sVersion = if ($null -ne $props -and $null -ne $props.kubernetesVersion) { $props.kubernetesVersion } else { "Unknown" }
        $networkPlugin = if ($null -ne $props -and $null -ne $props.networkProfile -and $null -ne $props.networkProfile.networkPlugin) { "$($props.networkProfile.networkPlugin)" } else { "Unknown" }
        $networkPolicy = if ($null -ne $props -and $null -ne $props.networkProfile -and $null -ne $props.networkProfile.networkPolicy) { "$($props.networkProfile.networkPolicy)" } else { "None" }
        $poolDisplay = if ($poolDetails.Count -gt 0) { $poolDetails -join '; ' } else { "None" }
        $aksClusters.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $aks.ResourceGroupName
          Name = $aks.Name
          Location = $aks.Location
          KubernetesVersion = $k8sVersion
          TotalNodeCount = $nodeCount
          NodePoolCount = $poolCount
          NodePoolProfiles = $poolDisplay
          NetworkPlugin = $networkPlugin
          NetworkPolicy = $networkPolicy
        })
      }
    } catch {
      Write-Log "Failed to enumerate AKS clusters in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # App Services — split Web Apps from Function Apps
    try {
      $allSites = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Web/sites' -ExpandProperties -ErrorAction Stop })
      foreach ($app in $allSites) {
        if (-not (Test-RegionMatch $app.Location)) { continue }
        $props = $app.Properties
        $kind = if ($null -ne $app.Kind) { "$($app.Kind)" } else { "app" }
        $state = if ($null -ne $props -and $null -ne $props.state) { "$($props.state)" } else { "Unknown" }
        $httpsOnly = if ($null -ne $props -and $null -ne $props.httpsOnly) { $props.httpsOnly } else { $false }
        $runtime = if ($null -ne $props -and $null -ne $props.siteConfig -and $null -ne $props.siteConfig.linuxFxVersion) { "$($props.siteConfig.linuxFxVersion)" } else { "" }

        $siteObj = [PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $app.ResourceGroupName
          Name = $app.Name
          Location = $app.Location
          Kind = $kind
          State = $state
          HttpsOnly = $httpsOnly
          Runtime = $runtime
        }

        if ($kind -like "*functionapp*") {
          $functionApps.Add($siteObj)
        } else {
          $webApps.Add($siteObj)
        }
      }
    } catch {
      Write-Log "Failed to enumerate App Services in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Azure Container Registry
    try {
      $registries = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.ContainerRegistry/registries' -ExpandProperties -ErrorAction Stop })
      foreach ($acr in $registries) {
        if (-not (Test-RegionMatch $acr.Location)) { continue }
        $props = $acr.Properties
        $acrSku = if ($null -ne $acr.Sku -and $null -ne $acr.Sku.name) { "$($acr.Sku.name)" } else { "Unknown" }
        $adminEnabled = if ($null -ne $props -and $null -ne $props.adminUserEnabled) { $props.adminUserEnabled } else { $false }
        $geoReplication = $false
        if ($null -ne $props -and $null -ne $props.policies -and $null -ne $props.policies.replicationPolicy) {
          $geoReplication = ($props.policies.replicationPolicy.status -eq 'enabled')
        }
        $containerRegistries.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $acr.ResourceGroupName
          Name = $acr.Name
          Location = $acr.Location
          Sku = $acrSku
          AdminEnabled = $adminEnabled
          GeoReplication = $geoReplication
        })
      }
    } catch {
      Write-Log "Failed to enumerate Container Registries in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Logic Apps
    try {
      $workflows = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Logic/workflows' -ExpandProperties -ErrorAction Stop })
      foreach ($la in $workflows) {
        if (-not (Test-RegionMatch $la.Location)) { continue }
        $props = $la.Properties
        $laState = if ($null -ne $props -and $null -ne $props.state) { "$($props.state)" } else { "Unknown" }
        $triggerCount = 0
        $actionCount = 0
        if ($null -ne $props -and $null -ne $props.definition) {
          if ($null -ne $props.definition.triggers) { $triggerCount = @($props.definition.triggers.PSObject.Properties).Count }
          if ($null -ne $props.definition.actions) { $actionCount = @($props.definition.actions.PSObject.Properties).Count }
        }
        $logicApps.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $la.ResourceGroupName
          Name = $la.Name
          Location = $la.Location
          State = $laState
          TriggerCount = $triggerCount
          ActionCount = $actionCount
        })
      }
    } catch {
      Write-Log "Failed to enumerate Logic Apps in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Data Factory
    try {
      $factories = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.DataFactory/factories' -ExpandProperties -ErrorAction Stop })
      foreach ($df in $factories) {
        if (-not (Test-RegionMatch $df.Location)) { continue }
        $props = $df.Properties
        $provState = if ($null -ne $props -and $null -ne $props.provisioningState) { "$($props.provisioningState)" } else { "Unknown" }
        $gitConfigured = $false
        if ($null -ne $props -and $null -ne $props.repoConfiguration) { $gitConfigured = $true }
        $dataFactories.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $df.ResourceGroupName
          Name = $df.Name
          Location = $df.Location
          ProvisioningState = $provState
          GitConfigured = $gitConfigured
        })
      }
    } catch {
      Write-Log "Failed to enumerate Data Factories in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # API Management
    try {
      $apims = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.ApiManagement/service' -ExpandProperties -ErrorAction Stop })
      foreach ($apim in $apims) {
        if (-not (Test-RegionMatch $apim.Location)) { continue }
        $props = $apim.Properties
        $apimSku = if ($null -ne $apim.Sku -and $null -ne $apim.Sku.name) { "$($apim.Sku.name)" } else { "Unknown" }
        $apimCapacity = if ($null -ne $apim.Sku -and $null -ne $apim.Sku.capacity) { [int]$apim.Sku.capacity } else { 0 }
        $gatewayUrl = if ($null -ne $props -and $null -ne $props.gatewayUrl) { "$($props.gatewayUrl)" } else { "" }
        $apiManagement.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $apim.ResourceGroupName
          Name = $apim.Name
          Location = $apim.Location
          Sku = $apimSku
          Capacity = $apimCapacity
          GatewayUrl = $gatewayUrl
        })
      }
    } catch {
      Write-Log "Failed to enumerate API Management in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Event Hubs
    try {
      $ehNamespaces = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.EventHub/namespaces' -ExpandProperties -ErrorAction Stop })
      foreach ($eh in $ehNamespaces) {
        if (-not (Test-RegionMatch $eh.Location)) { continue }
        $props = $eh.Properties
        $ehSku = if ($null -ne $eh.Sku -and $null -ne $eh.Sku.name) { "$($eh.Sku.name)" } else { "Unknown" }
        $ehCapacity = if ($null -ne $eh.Sku -and $null -ne $eh.Sku.capacity) { [int]$eh.Sku.capacity } else { 0 }
        $captureEnabled = $false
        $retentionDays = 0
        if ($null -ne $props -and $null -ne $props.kafkaEnabled) { }
        if ($null -ne $props -and $null -ne $props.maximumThroughputUnits) { $ehCapacity = [int]$props.maximumThroughputUnits }
        $eventHubs.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $eh.ResourceGroupName
          Name = $eh.Name
          Location = $eh.Location
          Sku = $ehSku
          ThroughputUnits = $ehCapacity
        })
      }
    } catch {
      Write-Log "Failed to enumerate Event Hubs in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Service Bus
    try {
      $sbNamespaces = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.ServiceBus/namespaces' -ExpandProperties -ErrorAction Stop })
      foreach ($sb in $sbNamespaces) {
        if (-not (Test-RegionMatch $sb.Location)) { continue }
        $sbSku = if ($null -ne $sb.Sku -and $null -ne $sb.Sku.name) { "$($sb.Sku.name)" } else { "Unknown" }
        $serviceBus.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $sb.ResourceGroupName
          Name = $sb.Name
          Location = $sb.Location
          Sku = $sbSku
        })
      }
    } catch {
      Write-Log "Failed to enumerate Service Bus in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Orphaned Managed Disks (not attached to any VM)
    try {
      $allDisks = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Compute/disks' -ExpandProperties -ErrorAction Stop })
      foreach ($disk in $allDisks) {
        if (-not (Test-RegionMatch $disk.Location)) { continue }
        $props = $disk.Properties
        $managedBy = if ($null -ne $props -and $null -ne $props.managedBy) { "$($props.managedBy)" } else { $null }
        if ([string]::IsNullOrWhiteSpace($managedBy)) {
          $diskSizeGB = 0
          if ($null -ne $props -and $null -ne $props.diskSizeGB) { $diskSizeGB = [int]$props.diskSizeGB }
          $diskSku = if ($null -ne $disk.Sku -and $null -ne $disk.Sku.name) { "$($disk.Sku.name)" } else { "Unknown" }
          $diskState = if ($null -ne $props -and $null -ne $props.diskState) { "$($props.diskState)" } else { "Unknown" }
          $encType = "SSE-PMK"
          if ($null -ne $props -and $null -ne $props.encryption -and $null -ne $props.encryption.diskEncryptionSetId) {
            $encType = "SSE-CMK"
          }
          $orphanedDisks.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId = $sub.Id
            ResourceGroup = $disk.ResourceGroupName
            Name = $disk.Name
            Location = $disk.Location
            DiskSizeGB = $diskSizeGB
            Sku = $diskSku
            DiskState = $diskState
            EncryptionType = $encType
          })
        }
      }
    } catch {
      Write-Log "Failed to enumerate managed disks in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Existing Snapshots
    try {
      $allSnapshots = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Compute/snapshots' -ExpandProperties -ErrorAction Stop })
      foreach ($snap in $allSnapshots) {
        if (-not (Test-RegionMatch $snap.Location)) { continue }
        $props = $snap.Properties
        $snapSizeGB = 0
        if ($null -ne $props -and $null -ne $props.diskSizeGB) { $snapSizeGB = [int]$props.diskSizeGB }
        $sourceId = if ($null -ne $props -and $null -ne $props.creationData -and $null -ne $props.creationData.sourceResourceId) { "$($props.creationData.sourceResourceId)" } else { "" }
        $sourceDiskName = ""
        if ($sourceId -ne "") {
          $sourceDiskName = ($sourceId -split '/')[-1]
        }
        $incremental = if ($null -ne $props -and $null -ne $props.incremental) { $props.incremental } else { $false }
        $snapshots.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $snap.ResourceGroupName
          Name = $snap.Name
          Location = $snap.Location
          DiskSizeGB = $snapSizeGB
          SourceDisk = $sourceDiskName
          Incremental = $incremental
        })
      }
    } catch {
      Write-Log "Failed to enumerate snapshots in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Availability Sets
    try {
      $allAvSets = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Compute/availabilitySets' -ExpandProperties -ErrorAction Stop })
      foreach ($avSet in $allAvSets) {
        if (-not (Test-RegionMatch $avSet.Location)) { continue }
        $props = $avSet.Properties
        $faultDomains = if ($null -ne $props -and $null -ne $props.platformFaultDomainCount) { [int]$props.platformFaultDomainCount } else { 0 }
        $updateDomains = if ($null -ne $props -and $null -ne $props.platformUpdateDomainCount) { [int]$props.platformUpdateDomainCount } else { 0 }
        $vmCount = 0
        if ($null -ne $props -and $null -ne $props.virtualMachines) { $vmCount = @($props.virtualMachines).Count }
        $availabilitySets.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $avSet.ResourceGroupName
          Name = $avSet.Name
          Location = $avSet.Location
          FaultDomains = $faultDomains
          UpdateDomains = $updateDomains
          VMCount = $vmCount
        })
      }
    } catch {
      Write-Log "Failed to enumerate availability sets in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }
  }

  $totalWebApps = $webApps.Count
  $totalFuncApps = $functionApps.Count
  Write-Log "Discovered $($keyVaults.Count) Key Vaults, $($aksClusters.Count) AKS clusters, $totalWebApps Web Apps, $totalFuncApps Function Apps, $($containerRegistries.Count) Container Registries, $($logicApps.Count) Logic Apps, $($dataFactories.Count) Data Factories, $($apiManagement.Count) API Management, $($eventHubs.Count) Event Hubs, $($serviceBus.Count) Service Bus, $($orphanedDisks.Count) orphaned disks, $($snapshots.Count) snapshots, $($availabilitySets.Count) availability sets" -Level "SUCCESS"

  return @{
    KeyVaults = $keyVaults
    AKSClusters = $aksClusters
    WebApps = $webApps
    FunctionApps = $functionApps
    ContainerRegistries = $containerRegistries
    LogicApps = $logicApps
    DataFactories = $dataFactories
    APIManagement = $apiManagement
    EventHubs = $eventHubs
    ServiceBus = $serviceBus
    OrphanedDisks = $orphanedDisks
    Snapshots = $snapshots
    AvailabilitySets = $availabilitySets
  }
}

#endregion

#region PaaS Database Inventory

<#
.SYNOPSIS
  Discovers PaaS database services (PostgreSQL, MySQL, Cosmos DB, Redis) with source sizing data.
.OUTPUTS
  Hashtable with PostgreSQL, MySQL, CosmosDB, and Redis lists.
#>
function Get-PaaSInventory {
  Write-ProgressStep -Activity "Discovering PaaS Databases" -Status "Scanning PostgreSQL, MySQL, Cosmos DB, Redis..."

  $postgresql = New-Object System.Collections.Generic.List[object]
  $mysql = New-Object System.Collections.Generic.List[object]
  $cosmosdb = New-Object System.Collections.Generic.List[object]
  $redis = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning PaaS databases in subscription: $($sub.Name)" -Level "INFO"
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    # PostgreSQL Flexible Servers
    try {
      $pgServers = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.DBforPostgreSQL/flexibleServers' -ExpandProperties -ErrorAction Stop })
      foreach ($pg in $pgServers) {
        if (-not (Test-RegionMatch $pg.Location)) { continue }
        $props = $pg.Properties
        $storageGB = 0
        if ($null -ne $props -and $null -ne $props.storage -and $null -ne $props.storage.storageSizeGB) {
          $storageGB = [int]$props.storage.storageSizeGB
        }
        $version = if ($null -ne $props -and $null -ne $props.version) { "$($props.version)" } else { "Unknown" }
        $sku = if ($null -ne $pg.Sku -and $null -ne $pg.Sku.name) { "$($pg.Sku.name)" } else { "Unknown" }
        $tier = if ($null -ne $pg.Sku -and $null -ne $pg.Sku.tier) { "$($pg.Sku.tier)" } else { "Unknown" }
        $haMode = if ($null -ne $props -and $null -ne $props.highAvailability -and $null -ne $props.highAvailability.mode) { "$($props.highAvailability.mode)" } else { "Disabled" }
        $pgState = if ($null -ne $props -and $null -ne $props.state) { "$($props.state)" } else { "Unknown" }
        $postgresql.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $pg.ResourceGroupName
          Name = $pg.Name
          Location = $pg.Location
          Version = $version
          Sku = $sku
          Tier = $tier
          StorageSizeGB = $storageGB
          HAMode = $haMode
          State = $pgState
        })
      }
    } catch {
      Write-Log "Failed to enumerate PostgreSQL servers in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # MySQL Flexible Servers
    try {
      $mysqlServers = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.DBforMySQL/flexibleServers' -ExpandProperties -ErrorAction Stop })
      foreach ($my in $mysqlServers) {
        if (-not (Test-RegionMatch $my.Location)) { continue }
        $props = $my.Properties
        $storageGB = 0
        if ($null -ne $props -and $null -ne $props.storage -and $null -ne $props.storage.storageSizeGB) {
          $storageGB = [int]$props.storage.storageSizeGB
        }
        $version = if ($null -ne $props -and $null -ne $props.version) { "$($props.version)" } else { "Unknown" }
        $sku = if ($null -ne $my.Sku -and $null -ne $my.Sku.name) { "$($my.Sku.name)" } else { "Unknown" }
        $tier = if ($null -ne $my.Sku -and $null -ne $my.Sku.tier) { "$($my.Sku.tier)" } else { "Unknown" }
        $haMode = if ($null -ne $props -and $null -ne $props.highAvailability -and $null -ne $props.highAvailability.mode) { "$($props.highAvailability.mode)" } else { "Disabled" }
        $myState = if ($null -ne $props -and $null -ne $props.state) { "$($props.state)" } else { "Unknown" }
        $mysql.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $my.ResourceGroupName
          Name = $my.Name
          Location = $my.Location
          Version = $version
          Sku = $sku
          Tier = $tier
          StorageSizeGB = $storageGB
          HAMode = $haMode
          State = $myState
        })
      }
    } catch {
      Write-Log "Failed to enumerate MySQL servers in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Cosmos DB Accounts
    try {
      $cosmosAccounts = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.DocumentDB/databaseAccounts' -ExpandProperties -ErrorAction Stop })
      foreach ($cosmos in $cosmosAccounts) {
        if (-not (Test-RegionMatch $cosmos.Location)) { continue }
        $props = $cosmos.Properties
        $kind = if ($null -ne $cosmos.Kind) { "$($cosmos.Kind)" } else { "GlobalDocumentDB" }
        $consistency = if ($null -ne $props -and $null -ne $props.consistencyPolicy -and $null -ne $props.consistencyPolicy.defaultConsistencyLevel) { "$($props.consistencyPolicy.defaultConsistencyLevel)" } else { "Unknown" }
        $offerType = if ($null -ne $props -and $null -ne $props.databaseAccountOfferType) { "$($props.databaseAccountOfferType)" } else { "Unknown" }
        $replicaLocations = New-Object System.Collections.Generic.List[string]
        if ($null -ne $props -and $null -ne $props.locations) {
          foreach ($loc in $props.locations) {
            if ($null -ne $loc.locationName) { $replicaLocations.Add("$($loc.locationName)") }
          }
        }
        $locDisplay = if ($replicaLocations.Count -gt 0) { $replicaLocations -join ', ' } else { $cosmos.Location }
        $multiWrite = if ($null -ne $props -and $null -ne $props.enableMultipleWriteLocations) { $props.enableMultipleWriteLocations } else { $false }
        $cosmosdb.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $cosmos.ResourceGroupName
          Name = $cosmos.Name
          Location = $cosmos.Location
          Kind = $kind
          ConsistencyLevel = $consistency
          OfferType = $offerType
          Locations = $locDisplay
          MultiRegionWrite = $multiWrite
        })
      }
    } catch {
      Write-Log "Failed to enumerate Cosmos DB accounts in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Azure Cache for Redis
    try {
      $redisCaches = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Cache/redis' -ExpandProperties -ErrorAction Stop })
      foreach ($rc in $redisCaches) {
        if (-not (Test-RegionMatch $rc.Location)) { continue }
        $props = $rc.Properties
        $rSku = if ($null -ne $rc.Sku -and $null -ne $rc.Sku.name) { "$($rc.Sku.name)" } else { "Unknown" }
        $rCapacity = if ($null -ne $rc.Sku -and $null -ne $rc.Sku.capacity) { [int]$rc.Sku.capacity } else { 0 }
        $rFamily = if ($null -ne $rc.Sku -and $null -ne $rc.Sku.family) { "$($rc.Sku.family)" } else { "" }
        $shardCount = 0
        if ($null -ne $props -and $null -ne $props.shardCount) { $shardCount = [int]$props.shardCount }
        $rVersion = if ($null -ne $props -and $null -ne $props.redisVersion) { "$($props.redisVersion)" } else { "Unknown" }
        $redis.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $rc.ResourceGroupName
          Name = $rc.Name
          Location = $rc.Location
          SkuName = $rSku
          SkuFamily = $rFamily
          SkuCapacity = $rCapacity
          ShardCount = $shardCount
          Version = $rVersion
        })
      }
    } catch {
      Write-Log "Failed to enumerate Redis caches in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }
  }

  Write-Log "Discovered $($postgresql.Count) PostgreSQL, $($mysql.Count) MySQL, $($cosmosdb.Count) Cosmos DB, $($redis.Count) Redis" -Level "SUCCESS"

  return @{
    PostgreSQL = $postgresql
    MySQL = $mysql
    CosmosDB = $cosmosdb
    Redis = $redis
  }
}

#endregion

#region Network Inventory

<#
.SYNOPSIS
  Discovers VNets, subnets, peering, and private endpoints for backup data path context.
.OUTPUTS
  Hashtable with VNets and PrivateEndpoints lists.
#>
function Get-NetworkInventory {
  Write-ProgressStep -Activity "Discovering Network Topology" -Status "Scanning VNets, subnets, private endpoints..."

  $vnets = New-Object System.Collections.Generic.List[object]
  $privateEndpoints = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Log "Scanning network topology in subscription: $($sub.Name)" -Level "INFO"
    try {
      Set-AzContext -SubscriptionId $sub.Id | Out-Null
    } catch {
      Write-Log "Failed to set context for subscription $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
      continue
    }

    # Virtual Networks with subnets and peering
    try {
      $allVnets = @(Invoke-AzWithRetry { Get-AzVirtualNetwork -ErrorAction Stop })
      foreach ($vnet in $allVnets) {
        if (-not (Test-RegionMatch $vnet.Location)) { continue }
        $addressSpace = if ($null -ne $vnet.AddressSpace -and $null -ne $vnet.AddressSpace.AddressPrefixes) { ($vnet.AddressSpace.AddressPrefixes -join ', ') } else { "" }
        $subnetCount = if ($null -ne $vnet.Subnets) { $vnet.Subnets.Count } else { 0 }
        $peeringCount = if ($null -ne $vnet.VirtualNetworkPeerings) { $vnet.VirtualNetworkPeerings.Count } else { 0 }
        $peeringDetails = New-Object System.Collections.Generic.List[string]
        if ($null -ne $vnet.VirtualNetworkPeerings) {
          foreach ($peer in $vnet.VirtualNetworkPeerings) {
            $remoteVnet = if ($null -ne $peer.RemoteVirtualNetwork -and $null -ne $peer.RemoteVirtualNetwork.Id) { ($peer.RemoteVirtualNetwork.Id -split '/')[-1] } else { "?" }
            $peerState = if ($null -ne $peer.PeeringState) { "$($peer.PeeringState)" } else { "?" }
            $peeringDetails.Add("${remoteVnet}($peerState)")
          }
        }
        $peerDisplay = if ($peeringDetails.Count -gt 0) { $peeringDetails -join '; ' } else { "None" }
        $vnets.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $vnet.ResourceGroupName
          Name = $vnet.Name
          Location = $vnet.Location
          AddressSpace = $addressSpace
          SubnetCount = $subnetCount
          PeeringCount = $peeringCount
          Peerings = $peerDisplay
        })
      }
    } catch {
      Write-Log "Failed to enumerate VNets in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }

    # Private Endpoints
    try {
      $allPe = @(Invoke-AzWithRetry { Get-AzResource -ResourceType 'Microsoft.Network/privateEndpoints' -ExpandProperties -ErrorAction Stop })
      foreach ($pe in $allPe) {
        if (-not (Test-RegionMatch $pe.Location)) { continue }
        $props = $pe.Properties
        $targetResource = ""
        if ($null -ne $props -and $null -ne $props.privateLinkServiceConnections) {
          foreach ($conn in $props.privateLinkServiceConnections) {
            if ($null -ne $conn.properties -and $null -ne $conn.properties.privateLinkServiceId) {
              $targetResource = ($conn.properties.privateLinkServiceId -split '/')[-1]
              break
            }
          }
        }
        $subnetId = ""
        if ($null -ne $props -and $null -ne $props.subnet -and $null -ne $props.subnet.id) {
          $subnetParts = $props.subnet.id -split '/'
          $subnetId = "$($subnetParts[-3])/$($subnetParts[-1])"
        }
        $privateEndpoints.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $pe.ResourceGroupName
          Name = $pe.Name
          Location = $pe.Location
          TargetResource = $targetResource
          Subnet = $subnetId
        })
      }
    } catch {
      Write-Log "Failed to enumerate private endpoints in $($sub.Name): $($_.Exception.Message)" -Level "WARNING"
    }
  }

  Write-Log "Discovered $($vnets.Count) VNets and $($privateEndpoints.Count) private endpoints" -Level "SUCCESS"

  return @{
    VNets = $vnets
    PrivateEndpoints = $privateEndpoints
  }
}

#endregion
