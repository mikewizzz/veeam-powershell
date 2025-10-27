<#
.SYNOPSIS
  Presales discovery for sizing Veeam Backup for Azure.

.DESCRIPTION
  Inventories Azure VMs (IPs, tags, disks, VM size), Azure SQL (DB + MI),
  Azure Files, Azure Blob (optional size calc), and Azure Backup (vaults/policies).
  Optionally fetches Azure Backup retail pricing and estimates protected-instance tier per VM.

.PARAMETER Subscriptions
  One or more subscription IDs or names. Default = all accessible.

.PARAMETER TenantId
  Optional tenant to login to. If omitted, uses current/default.

.PARAMETER Region
  Optional Azure region filter (e.g., "westus2"). Case-insensitive equals match.

.PARAMETER TagFilter
  Optional hashtable of tag filters, e.g. @{ "Environment"="Prod"; "Owner"="IT" }.
  VM results will include only VMs matching ALL provided tag pairs.

.PARAMETER CalculateBlobSizes
  When set, enumerates blobs to sum container sizes (can be slow on large accounts).

.PARAMETER IncludePricing
  When set, queries the Azure Retail Prices API for Azure Backup protected instance tiers
  per VM’s region and emits an estimated monthly cost based on provisioned disk totals:
    - Tier S: ≤ 50 GB
    - Tier M: 50–500 GB
    - Tier L: > 500 GB
  Also attempts to fetch Backup Storage LRS/GRS $/GB for each region.

.PARAMETER OutputPath
  Folder to write CSVs. Will be created if not present.

.NOTES
  Requires Az modules:
    Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices, Az.Monitor
#>

[CmdletBinding()]
param(
  [string[]] $Subscriptions,
  [string]   $TenantId,
  [string]   $Region,
  [hashtable]$TagFilter,
  [switch]   $CalculateBlobSizes,
  [switch]   $IncludePricing,
  [string]   $OutputPath = ".\vb_azure_discovery"
)

#region Helpers

function Get-PublicIpFromId {
  param([Parameter(Mandatory=$true)][string]$ResourceId)
  try {
    $r = Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction Stop
    # Many PIPs expose .properties.ipAddress when allocated; may be $null if dynamic + deallocated
    return $r.Properties.ipAddress
  } catch {
    Write-Warning "PIP lookup failed for $ResourceId ($($_.Exception.Message))"
    return $null
  }
}

function Get-ResourceById {
  param([Parameter(Mandatory=$true)][string]$ResourceId)
  try { return Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction Stop }
  catch {
    Write-Verbose "Generic resource lookup failed for $ResourceId ($($_.Exception.Message))"
    return $null
  }
}

function Ensure-Connected {
  try {
    if (-not (Get-AzContext)) {
      if ($PSBoundParameters.ContainsKey('TenantId')) {
        Connect-AzAccount -Tenant $TenantId | Out-Null
      } else {
        Connect-AzAccount | Out-Null
      }
    }
  } catch {
    throw "Failed to authenticate to Azure: $($_.Exception.Message)"
  }
}

function Resolve-Subscriptions {
  $all = Get-AzSubscription
  if ($Subscriptions -and $Subscriptions.Count -gt 0) {
    $resolved = @()
    foreach ($s in $Subscriptions) {
      $hit = $all | Where-Object { $_.Id -eq $s -or $_.Name -eq $s }
      if (-not $hit) { Write-Warning "Subscription '$s' not found or not accessible."; continue }
      $resolved += $hit
    }
    return $resolved
  }
  return $all
}

function Matches-Region($resourceRegion) {
  if (-not $Region) { return $true }
  # Normalize both (Azure regions are lowercase in ARM)
  return ($resourceRegion -ieq $Region)
}

function Matches-Tags($tags) {
  if (-not $TagFilter -or $TagFilter.Keys.Count -eq 0) { return $true }
  if (-not $tags) { return $false }
  foreach ($k in $TagFilter.Keys) {
    if (-not $tags.ContainsKey($k)) { return $false }
    if ($TagFilter[$k] -ne $null -and ($tags[$k] -ne $TagFilter[$k])) { return $false }
  }
  return $true
}

function New-Output {
  if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
}

function Flatten-Tags($tags) {
  if (-not $tags) { return "" }
  ($tags.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
}

#endregion Helpers

#region VM Inventory
function Get-VM-Inventory {
  $results = New-Object System.Collections.Generic.List[object]
  $nicsCache = @{}
  $pipsCache = @{}

  foreach ($sub in $script:Subs) {
    Write-Host "Processing VMs in subscription: $($sub.Name) [$($sub.Id)]" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    foreach ($vm in $vms) {
      if (-not (Matches-Region $vm.Location)) { continue }
      if (-not (Matches-Tags $vm.Tags)) { continue }

      # NICs, Private/Public IPs (direct, via LB, via NATGW)
      $nicIds = @()
      $privateIps = @()
      $publicIpsDirect = @()
      $publicIpsLB = @()
      $publicIpsNAT = @()

      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicId = $nicRef.Id
        $nicIds += $nicId

        if (-not $nicsCache.ContainsKey($nicId)) {
          try { $nicsCache[$nicId] = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop }
          catch { Write-Warning "[$($vm.Name)] No access to NIC $nicId ($($_.Exception.Message))"; continue }
        }
        $nic = $nicsCache[$nicId]
        if (-not $nic) { continue }

        foreach ($ipc in $nic.IpConfigurations) {
          if ($ipc.PrivateIpAddress) { $privateIps += $ipc.PrivateIpAddress }

          # ---- Direct Public IP on NIC ----
          if ($ipc.PublicIpAddress -and $ipc.PublicIpAddress.Id) {
            $pipId = $ipc.PublicIpAddress.Id
            if (-not $pipsCache.ContainsKey($pipId)) { $pipsCache[$pipId] = Get-PublicIpFromId -ResourceId $pipId }
            if ($pipsCache[$pipId]) { $publicIpsDirect += $pipsCache[$pipId] }
          }

          # ---- Public IPs via Load Balancer frontends ----
          foreach ($pool in ($ipc.LoadBalancerBackendAddressPools | Where-Object { $_.Id })) {
            try {
              $poolRes = Get-ResourceById -ResourceId $pool.Id
              $lbId = $null
              if ($poolRes -and $poolRes.Properties.loadBalancerBackendAddressPoolPropertiesFormat.loadBalancer.id) {
                $lbId = $poolRes.Properties.loadBalancerBackendAddressPoolPropertiesFormat.loadBalancer.id
              } else {
                $lbId = ($pool.Id -split '/backendAddressPools/')[0] # fallback: trim to LB id
              }
              $lbRes = Get-ResourceById -ResourceId $lbId
              if ($lbRes -and $lbRes.Properties.frontendIPConfigurations) {
                foreach ($fe in $lbRes.Properties.frontendIPConfigurations) {
                  $fePipId = $fe.properties.publicIPAddress.id
                  if ($fePipId) {
                    if (-not $pipsCache.ContainsKey($fePipId)) { $pipsCache[$fePipId] = Get-PublicIpFromId -ResourceId $fePipId }
                    if ($pipsCache[$fePipId]) { $publicIpsLB += $pipsCache[$fePipId] }
                  }
                }
              }
            } catch {
              Write-Verbose "[$($vm.Name)] Unable to resolve LB frontends for backend pool $($pool.Id): $($_.Exception.Message)"
            }
          }

          # ---- Public IPs via NAT Gateway on the subnet ----
          try {
            $subnetId = $ipc.Subnet.Id
            if ($subnetId) {
              $subnet = Get-ResourceById -ResourceId $subnetId
              $natAssoc = $subnet.Properties.natGateway
              if ($natAssoc -and $natAssoc.id) {
                $natRes = Get-ResourceById -ResourceId $natAssoc.id
                if ($natRes) {
                  $pubRefs = @()
                  if ($natRes.Properties.publicIpAddresses) { $pubRefs += $natRes.Properties.publicIpAddresses }
                  if ($natRes.Properties.publicIpPrefixes)  { $pubRefs += $natRes.Properties.publicIpPrefixes } # prefixes have no single ip
                  foreach ($pub in $pubRefs) {
                    $refId = $pub.id
                    if ($refId) {
                      if (-not $pipsCache.ContainsKey($refId)) { $pipsCache[$refId] = Get-PublicIpFromId -ResourceId $refId }
                      if ($pipsCache[$refId]) { $publicIpsNAT += $pipsCache[$refId] } # only actual PIPs resolve to ipAddress
                    }
                  }
                }
              }
            }
          } catch {
            Write-Verbose "[$($vm.Name)] NAT Gateway lookup failed: $($_.Exception.Message)"
          }
        }
      }

      # Combined set (dedup)
      $publicIpsAll = @($publicIpsDirect + $publicIpsLB + $publicIpsNAT | Select-Object -Unique)

      # Disks
      $osDiskGB = [int]($vm.StorageProfile.OsDisk.DiskSizeGB)
      $dataDisks = @()
      $dataSizeGB = 0
      foreach ($d in $vm.StorageProfile.DataDisks) {
        $size = [int]$d.DiskSizeGB
        $dataSizeGB += $size
        $dataDisks += ("LUN{0}:{1}GB:{2}" -f $d.Lun, $size, ($d.ManagedDisk.StorageAccountType))
      }
      $totalProvGB = ($osDiskGB + $dataSizeGB)

      $results.Add([pscustomobject]@{
        SubscriptionName     = $sub.Name
        SubscriptionId       = $sub.Id
        ResourceGroup        = $vm.ResourceGroupName
        VmName               = $vm.Name
        VmId                 = $vm.Id
        Location             = $vm.Location
        Zone                 = ($vm.Zones -join ',')
        PowerState           = ($vm.PowerState -replace 'PowerState/')
        OsType               = $vm.StorageProfile.OsDisk.OsType
        VmSize               = $vm.HardwareProfile.VmSize
        PrivateIPs           = ($privateIps -join ',')
        DirectPublicIPs      = ($publicIpsDirect -join ',')
        LbPublicIPs          = ($publicIpsLB     -join ',')
        NatGatewayPublicIPs  = ($publicIpsNAT    -join ',')
        PublicIPs            = ($publicIpsAll    -join ',')
        NicIds               = ($nicIds -join ',')
        Tags                 = (Flatten-Tags $vm.Tags)

        OsDiskType           = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
        OsDiskSizeGB         = $osDiskGB
        DataDiskCount        = $vm.StorageProfile.DataDisks.Count
        DataDiskSummary      = ($dataDisks -join ';')
        DataDiskTotalGB      = $dataSizeGB
        TotalProvisionedGB   = $totalProvGB
      })
    }
  }

  $results
}
#endregion

#region SQL Inventory
function Get-Sql-Inventory {
  $dbs = New-Object System.Collections.Generic.List[object]
  $mis = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Host "Processing Azure SQL in subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Single DBs
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($srv in $servers) {
      if (-not (Matches-Region $srv.Location)) { continue }
      $databases = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction SilentlyContinue | Where-Object { $_.DatabaseName -ne "master" }
      foreach ($db in $databases) {
        $dbs.Add([pscustomobject]@{
          SubscriptionName = $sub.Name
          SubscriptionId   = $sub.Id
          ResourceGroup    = $srv.ResourceGroupName
          ServerName       = $srv.ServerName
          DatabaseName     = $db.DatabaseName
          Location         = $db.Location
          Edition          = $db.Edition
          ServiceObjective = $db.CurrentServiceObjectiveName
          MaxSizeGB        = [math]::Round($db.MaxSizeBytes/1GB,2)
          ZoneRedundant    = $db.ZoneRedundant
          BackupStorageRedundancy = $db.BackupStorageRedundancy
        })
      }
    }

    # Managed Instances
    $managed = Get-AzSqlInstance -ErrorAction SilentlyContinue
    foreach ($mi in $managed) {
      if (-not (Matches-Region $mi.Location)) { continue }
      $mis.Add([pscustomobject]@{
        SubscriptionName = $sub.Name
        SubscriptionId   = $sub.Id
        ResourceGroup    = $mi.ResourceGroupName
        ManagedInstance  = $mi.Name
        Location         = $mi.Location
        VCores           = $mi.VCores
        StorageSizeGB    = $mi.StorageSizeInGB
        LicenseType      = $mi.LicenseType
        HaEnabled        = $mi.AutomaticHa
        Collation        = $mi.Collation
        SubnetId         = $mi.SubnetId
      })
    }
  }

  return @{
    Databases = $dbs
    ManagedInstances = $mis
  }
}
#endregion

#region Storage: Files and Blob
function Try-Get-ShareUsageBytes {
  param($share, $rg, $acctName)
  # Prefer new Az.Storage cmdlet (if available): Get-AzRmStorageShare -Expand "stats"
  try {
    if (Get-Command Get-AzRmStorageShare -ErrorAction SilentlyContinue) {
      $s = Get-AzRmStorageShare -ResourceGroupName $rg -StorageAccountName $acctName -Name $share.Name -Expand "stats" -ErrorAction Stop
      if ($s.ShareUsageBytes -ne $null) { return [int64]$s.ShareUsageBytes }
      if ($s.UsageInBytes     -ne $null) { return [int64]$s.UsageInBytes }
    }
  } catch {}
  return $null
}

function Get-Storage-Inventory {
  $files = New-Object System.Collections.Generic.List[object]
  $blobs = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Host "Processing Storage (Files/Blob) in subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $accts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($acct in $accts) {
      if (-not (Matches-Region $acct.Location)) { continue }
      $ctx = $acct.Context

      # Azure Files
      try {
        $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
        foreach ($sh in $shares) {
          $usageBytes = Try-Get-ShareUsageBytes -share $sh -rg $acct.ResourceGroupName -acctName $acct.StorageAccountName
          $files.Add([pscustomobject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceGroup    = $acct.ResourceGroupName
            StorageAccount   = $acct.StorageAccountName
            Location         = $acct.Location
            SkuName          = $acct.Sku.Name
            Kind             = $acct.Kind
            ShareName        = $sh.Name
            QuotaGiB         = $sh.Quota
            SnapshotCount    = $sh.SnapshotCount
            UsageBytes       = $usageBytes
            UsageGiB         = ($(if ($usageBytes){ [math]::Round($usageBytes/1GB,2) } else { $null }))
          })
        }
      } catch {}

      # Azure Blob
      try {
        $containers = Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue
        foreach ($c in $containers) {
          $sizeBytes = $null
          if ($CalculateBlobSizes.IsPresent) {
            # Summation can be slow — do it only if requested.
            $sizeBytes = 0
            $token = $null
            do {
              $page = Get-AzStorageBlob -Container $c.Name -Context $ctx -MaxCount 5000 -ContinuationToken $token -ErrorAction SilentlyContinue
              foreach ($b in $page) { $sizeBytes += [int64]($b.Length) }
              $token = $page.ContinuationToken
            } while ($token)
          }
          $blobs.Add([pscustomobject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            ResourceGroup    = $acct.ResourceGroupName
            StorageAccount   = $acct.StorageAccountName
            Location         = $acct.Location
            SkuName          = $acct.Sku.Name
            Kind             = $acct.Kind
            Container        = $c.Name
            PublicAccess     = $c.PublicAccess
            LastModified     = $c.CloudBlobContainer.Properties.LastModified.UtcDateTime
            EstimatedBytes   = $sizeBytes
            EstimatedGiB     = ($(if ($sizeBytes){ [math]::Round($sizeBytes/1GB,2) } else { $null }))
          })
        }
      } catch {}
    }
  }

  return @{
    Files = $files
    Blobs = $blobs
  }
}
#endregion

#region Azure Backup (Vaults/Policies/Counts)
function Get-AzureBackup-Inventory {
  $vaultsOut   = New-Object System.Collections.Generic.List[object]
  $policiesOut = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Write-Host "Processing Azure Backup in subscription: $($sub.Name)" -ForegroundColor Cyan
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }

      # select vault
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null

      # Count protected items by workload type (VMs, SQL, Files if any)
      $items = Get-AzRecoveryServicesBackupItem -ErrorAction SilentlyContinue
      $vmCount   = ($items | Where-Object { $_.WorkloadType -eq "AzureVM" }).Count
      $sqlCount  = ($items | Where-Object { $_.WorkloadType -like "SQL*" }).Count
      $afsCount  = ($items | Where-Object { $_.WorkloadType -like "*AzureFileShare*" }).Count

      $vaultsOut.Add([pscustomobject]@{
        SubscriptionName = $sub.Name
        SubscriptionId   = $sub.Id
        ResourceGroup    = $v.ResourceGroupName
        VaultName        = $v.Name
        Location         = $v.Location
        Type             = $v.Type
        Sku              = $v.Sku
        SoftDeleteState  = $v.Properties.SoftDeleteFeatureState
        Immutability     = $v.Properties.ImmutabilityState
        MonitoringEnabled= $v.Properties.MonitoringSettings.AzureMonitorAlertSettings.State
        ProtectedVMs     = $vmCount
        ProtectedSQL     = $sqlCount
        ProtectedFileShares = $afsCount
      })

      # Policies
      $pols = Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue
      foreach ($p in $pols) {
        # Extract basics; schedule/retention vary by workload type
        $ret = $null; $sched = $null
        try { $ret = ($p.RetentionPolicy | ConvertTo-Json -Depth 5 -Compress) } catch {}
        try { $sched = ($p.SchedulePolicy  | ConvertTo-Json -Depth 5 -Compress) } catch {}

        $policiesOut.Add([pscustomobject]@{
          SubscriptionName = $sub.Name
          SubscriptionId   = $sub.Id
          ResourceGroup    = $v.ResourceGroupName
          VaultName        = $v.Name
          PolicyName       = $p.Name
          WorkloadType     = $p.WorkloadType
          BackupManagement = $p.BackupManagementType
          RetentionPolicy  = $ret
          SchedulePolicy   = $sched
        })
      }
    }
  }

  return @{
    Vaults   = $vaultsOut
    Policies = $policiesOut
  }
}
#endregion

#region Pricing (Protected Instances + Backup Storage)
function Invoke-PricesApi {
  param(
    [Parameter(Mandatory=$true)][string]$Filter
  )
  $base = "https://prices.azure.com/api/retail/prices"
  $results = @()
  $next = "$base`?`$filter=$([uri]::EscapeDataString($Filter))"
  while ($next) {
    $resp = Invoke-RestMethod -Method Get -Uri $next -UseBasicParsing
    if ($resp.Items) { $results += $resp.Items }
    $next = $resp.NextPageLink
  }
  return $results
}

function Get-BackupProtectedInstancePrices {
  param([string]$ArmRegionName)
  # serviceName eq 'Backup' AND armRegionName eq 'westus2' AND contains(productName,'Protected')
  $f = "serviceName eq 'Backup' and armRegionName eq '$ArmRegionName' and contains(productName,'Protected')"
  $items = Invoke-PricesApi -Filter $f
  # Return only monthly meters
  $items | Where-Object { $_.unitOfMeasure -like '*Month*' -and $_.type -eq "Consumption" }
}

function Get-BackupStoragePrices {
  param([string]$ArmRegionName)
  # Azure Backup Storage sometimes appears as productName contains 'Backup Storage'
  $f = "serviceName eq 'Backup' and armRegionName eq '$ArmRegionName' and contains(productName,'Backup Storage')"
  $items = Invoke-PricesApi -Filter $f
  $items | Where-Object { $_.unitOfMeasure -match 'GB' -and $_.type -eq "Consumption" }
}

function Map-Size-To-Tier {
  param([int]$TotalProvGB)
  if ($TotalProvGB -le 50) { return "S (≤50GB)" }
  elseif ($TotalProvGB -le 500) { return "M (50–500GB)" }
  else { return "L (>500GB)" }
}

function Find-Price-For-Tier {
  param(
    [array]$PriceItems,
    [string]$TierLabel
  )
  # Heuristics: look in productName/meterName for 50GB / 500GB keywords
  $needle = switch -Wildcard ($TierLabel) {
    "*≤50GB*"   { "50 GB" }
    "*50–500GB*" { "500 GB" }
    "*>500GB*"   { "> 500" }
    default { $null }
  }
  if (-not $needle) { return $null }

  # Try exact matches first on meterName, then productName
  $exact = $PriceItems | Where-Object {
    ($_.meterName -match [regex]::Escape($needle)) -or
    ($_.productName -match [regex]::Escape($needle))
  } | Select-Object -First 1

  if ($exact) { return [decimal]$exact.unitPrice }

  # Fall back: first monthly item
  $fallback = $PriceItems | Select-Object -First 1
  if ($fallback) { return [decimal]$fallback.unitPrice }

  return $null
}

function Estimate-AzureBackupPricing {
  param([array]$VmInventory)

  $estimate = New-Object System.Collections.Generic.List[object]
  # Cache prices per region
  $cache = @{}

  foreach ($vm in $VmInventory) {
    $armRegion = $vm.Location.ToLower()
    if (-not $cache.ContainsKey($armRegion)) {
      try {
        $pi = Get-BackupProtectedInstancePrices -ArmRegionName $armRegion
        $bs = Get-BackupStoragePrices         -ArmRegionName $armRegion
        $cache[$armRegion] = @{ PI=$pi; BS=$bs }
      } catch {
        $cache[$armRegion] = @{ PI=@(); BS=@() }
      }
    }
    $bag = $cache[$armRegion]
    $tier = Map-Size-To-Tier -TotalProvGB $vm.TotalProvisionedGB
    $piPrice = Find-Price-For-Tier -PriceItems $bag.PI -TierLabel $tier

    # Storage price (unknown redundancy from AKV policy here; emit both if found)
    $lrs = ($bag.BS | Where-Object { $_.meterName -match 'LRS' } | Select-Object -First 1)
    $grs = ($bag.BS | Where-Object { $_.meterName -match 'GRS' } | Select-Object -First 1)

    $estimate.Add([pscustomobject]@{
      SubscriptionName   = $vm.SubscriptionName
      SubscriptionId     = $vm.SubscriptionId
      ResourceGroup      = $vm.ResourceGroup
      VmName             = $vm.VmName
      Location           = $armRegion
      VmSize             = $vm.VmSize
      TotalProvisionedGB = $vm.TotalProvisionedGB
      ProtectedTier      = $tier
      Est_PI_MonthlyUSD  = $piPrice
      BackupStorage_LRS_USDperGB = ($(if($lrs){ [decimal]$lrs.unitPrice } else { $null }))
      BackupStorage_GRS_USDperGB = ($(if($grs){ [decimal]$grs.unitPrice } else { $null }))
      Note               = "PI price = indicative list; actual bills depend on policy, churn, compression, retention."
    })
  }
  return $estimate
}
#endregion

#region Main
try {
  New-Output
  Ensure-Connected
  $script:Subs = Resolve-Subscriptions

  # INVENTORY
  $vmInv   = Get-VM-Inventory
  $sqlInv  = Get-Sql-Inventory
  $stInv   = Get-Storage-Inventory
  $abInv   = Get-AzureBackup-Inventory

  # EXPORT
  $vmCsv     = Join-Path $OutputPath "azure_vms.csv"
  $sqlDbCsv  = Join-Path $OutputPath "azure_sql_databases.csv"
  $sqlMiCsv  = Join-Path $OutputPath "azure_sql_managed_instances.csv"
  $filesCsv  = Join-Path $OutputPath "azure_files.csv"
  $blobCsv   = Join-Path $OutputPath "azure_blob.csv"
  $vaultsCsv = Join-Path $OutputPath "azure_backup_vaults.csv"
  $polCsv    = Join-Path $OutputPath "azure_backup_policies.csv"

  $vmInv                        | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $vmCsv
  $sqlInv.Databases             | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sqlDbCsv
  $sqlInv.ManagedInstances      | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sqlMiCsv
  $stInv.Files                  | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $filesCsv
  $stInv.Blobs                  | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $blobCsv
  $abInv.Vaults                 | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $vaultsCsv
  $abInv.Policies               | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $polCsv

  Write-Host "`nWrote CSVs to: $OutputPath" -ForegroundColor Green

  if ($IncludePricing.IsPresent) {
    Write-Host "Calculating indicative Azure Backup pricing via Retail Prices API..." -ForegroundColor Yellow
    $pricing = Estimate-AzureBackupPricing -VmInventory $vmInv
    $priceCsv = Join-Path $OutputPath "azure_backup_pricing_estimate.csv"
    $pricing | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $priceCsv
    Write-Host "Wrote pricing estimate: $priceCsv" -ForegroundColor Green
  }

  # Simple console summary
  $vmCount = ($vmInv | Measure-Object).Count
  $bySub = $vmInv | Group-Object SubscriptionName | Select-Object Name, @{n='VMs';e={$_.Count}}
  Write-Host "`nVMs discovered: $vmCount" -ForegroundColor Cyan
  $bySub | Format-Table -AutoSize | Out-String | Write-Host

} catch {
  Write-Error $_.Exception.Message
}
#endregion