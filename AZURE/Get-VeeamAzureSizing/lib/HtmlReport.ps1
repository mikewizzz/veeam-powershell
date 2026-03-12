# SPDX-License-Identifier: MIT
# =========================================================================
# HtmlReport.ps1 - Executive-grade HTML report generation (Fluent Design)
# =========================================================================

<#
.SYNOPSIS
  Generates an executive-grade HTML discovery report with inline SVG charts,
  dark gradient header, numbered collapsible sections, and glassmorphism KPI cards.
.DESCRIPTION
  Builds a professional multi-section HTML report covering VM inventory,
  VMSS, SQL databases, storage discovery, security posture (encryption,
  NSG exposure, managed identities), additional resources (Key Vault, AKS,
  App Services), and Azure Backup coverage analysis.
  CSS-only visuals, no JavaScript, no external dependencies. Works as a
  static file, prints correctly to PDF, responsive on mobile.
.PARAMETER VmInventory
  VM inventory collection.
.PARAMETER SqlInventory
  SQL inventory hashtable (Databases, ManagedInstances).
.PARAMETER StorageInventory
  Storage inventory hashtable (Files, Blobs).
.PARAMETER AzureBackupInventory
  Backup inventory hashtable (Vaults, Policies).
.PARAMETER VeeamSizing
  Source totals summary object.
.PARAMETER OutputPath
  Directory to write the HTML file.
.PARAMETER Subscriptions
  Array of subscription objects that were analyzed.
.PARAMETER StartTime
  Assessment start time for duration calculation.
.OUTPUTS
  Path to the generated HTML file.
#>
function New-HtmlReport {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    [Parameter(Mandatory=$true)]$StorageInventory,
    [Parameter(Mandatory=$true)]$AzureBackupInventory,
    [Parameter(Mandatory=$true)]$VeeamSizing,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][array]$Subscriptions,
    [Parameter(Mandatory=$true)][datetime]$StartTime,
    $VMSSInventory = $null,
    $AdditionalResources = $null,
    $PaaSInventory = $null,
    $NetworkInventory = $null,
    $FilterMetadata = $null
  )

  Write-ProgressStep -Activity "Generating HTML Report" -Status "Building executive-grade report..."

  # =========================================================================
  # 1. Unwrap Generic.List collections to plain arrays
  # =========================================================================
  if ($null -eq $VmInventory) { $VmInventory = @() }
  elseif ($VmInventory -is [System.Collections.IList]) { $VmInventory = @($VmInventory.GetEnumerator()) }

  $sqlDbs = if ($null -eq $SqlInventory.Databases) { @() }
            elseif ($SqlInventory.Databases -is [System.Collections.IList]) { @($SqlInventory.Databases.GetEnumerator()) }
            else { @($SqlInventory.Databases) }

  $sqlMIs = if ($null -eq $SqlInventory.ManagedInstances) { @() }
            elseif ($SqlInventory.ManagedInstances -is [System.Collections.IList]) { @($SqlInventory.ManagedInstances.GetEnumerator()) }
            else { @($SqlInventory.ManagedInstances) }

  $fileShares = if ($null -eq $StorageInventory.Files) { @() }
                elseif ($StorageInventory.Files -is [System.Collections.IList]) { @($StorageInventory.Files.GetEnumerator()) }
                else { @($StorageInventory.Files) }

  $blobContainers = if ($null -eq $StorageInventory.Blobs) { @() }
                    elseif ($StorageInventory.Blobs -is [System.Collections.IList]) { @($StorageInventory.Blobs.GetEnumerator()) }
                    else { @($StorageInventory.Blobs) }

  $vaults = if ($null -eq $AzureBackupInventory.Vaults) { @() }
            elseif ($AzureBackupInventory.Vaults -is [System.Collections.IList]) { @($AzureBackupInventory.Vaults.GetEnumerator()) }
            else { @($AzureBackupInventory.Vaults) }

  $policies = if ($null -eq $AzureBackupInventory.Policies) { @() }
              elseif ($AzureBackupInventory.Policies -is [System.Collections.IList]) { @($AzureBackupInventory.Policies.GetEnumerator()) }
              else { @($AzureBackupInventory.Policies) }

  # VMSS
  $vmssItems = @()
  if ($null -ne $VMSSInventory) {
    if ($VMSSInventory -is [System.Collections.IList]) { $vmssItems = @($VMSSInventory.GetEnumerator()) }
    else { $vmssItems = @($VMSSInventory) }
  }

  # Storage accounts
  $storageAccts = @()
  if ($null -ne $StorageInventory.StorageAccounts) {
    if ($StorageInventory.StorageAccounts -is [System.Collections.IList]) { $storageAccts = @($StorageInventory.StorageAccounts.GetEnumerator()) }
    else { $storageAccts = @($StorageInventory.StorageAccounts) }
  }
  $skippedAccounts = if ($null -ne $StorageInventory.SkippedAccounts) { $StorageInventory.SkippedAccounts } else { 0 }

  # Additional resources
  $keyVaults = @()
  $aksClusters = @()
  $webApps = @()
  $functionApps = @()
  $containerRegistries = @()
  $logicApps2 = @()
  $dataFactories = @()
  $apiMgmt = @()
  $eventHubsArr = @()
  $serviceBusArr = @()
  $orphanedDisks = @()
  $snapshotsArr = @()
  $availSets = @()
  if ($null -ne $AdditionalResources) {
    if ($null -ne $AdditionalResources.KeyVaults) {
      if ($AdditionalResources.KeyVaults -is [System.Collections.IList]) { $keyVaults = @($AdditionalResources.KeyVaults.GetEnumerator()) }
      else { $keyVaults = @($AdditionalResources.KeyVaults) }
    }
    if ($null -ne $AdditionalResources.AKSClusters) {
      if ($AdditionalResources.AKSClusters -is [System.Collections.IList]) { $aksClusters = @($AdditionalResources.AKSClusters.GetEnumerator()) }
      else { $aksClusters = @($AdditionalResources.AKSClusters) }
    }
    if ($null -ne $AdditionalResources.WebApps) {
      if ($AdditionalResources.WebApps -is [System.Collections.IList]) { $webApps = @($AdditionalResources.WebApps.GetEnumerator()) }
      else { $webApps = @($AdditionalResources.WebApps) }
    }
    if ($null -ne $AdditionalResources.FunctionApps) {
      if ($AdditionalResources.FunctionApps -is [System.Collections.IList]) { $functionApps = @($AdditionalResources.FunctionApps.GetEnumerator()) }
      else { $functionApps = @($AdditionalResources.FunctionApps) }
    }
    if ($null -ne $AdditionalResources.ContainerRegistries) {
      if ($AdditionalResources.ContainerRegistries -is [System.Collections.IList]) { $containerRegistries = @($AdditionalResources.ContainerRegistries.GetEnumerator()) }
      else { $containerRegistries = @($AdditionalResources.ContainerRegistries) }
    }
    if ($null -ne $AdditionalResources.LogicApps) {
      if ($AdditionalResources.LogicApps -is [System.Collections.IList]) { $logicApps2 = @($AdditionalResources.LogicApps.GetEnumerator()) }
      else { $logicApps2 = @($AdditionalResources.LogicApps) }
    }
    if ($null -ne $AdditionalResources.DataFactories) {
      if ($AdditionalResources.DataFactories -is [System.Collections.IList]) { $dataFactories = @($AdditionalResources.DataFactories.GetEnumerator()) }
      else { $dataFactories = @($AdditionalResources.DataFactories) }
    }
    if ($null -ne $AdditionalResources.APIManagement) {
      if ($AdditionalResources.APIManagement -is [System.Collections.IList]) { $apiMgmt = @($AdditionalResources.APIManagement.GetEnumerator()) }
      else { $apiMgmt = @($AdditionalResources.APIManagement) }
    }
    if ($null -ne $AdditionalResources.EventHubs) {
      if ($AdditionalResources.EventHubs -is [System.Collections.IList]) { $eventHubsArr = @($AdditionalResources.EventHubs.GetEnumerator()) }
      else { $eventHubsArr = @($AdditionalResources.EventHubs) }
    }
    if ($null -ne $AdditionalResources.ServiceBus) {
      if ($AdditionalResources.ServiceBus -is [System.Collections.IList]) { $serviceBusArr = @($AdditionalResources.ServiceBus.GetEnumerator()) }
      else { $serviceBusArr = @($AdditionalResources.ServiceBus) }
    }
    if ($null -ne $AdditionalResources.OrphanedDisks) {
      if ($AdditionalResources.OrphanedDisks -is [System.Collections.IList]) { $orphanedDisks = @($AdditionalResources.OrphanedDisks.GetEnumerator()) }
      else { $orphanedDisks = @($AdditionalResources.OrphanedDisks) }
    }
    if ($null -ne $AdditionalResources.Snapshots) {
      if ($AdditionalResources.Snapshots -is [System.Collections.IList]) { $snapshotsArr = @($AdditionalResources.Snapshots.GetEnumerator()) }
      else { $snapshotsArr = @($AdditionalResources.Snapshots) }
    }
    if ($null -ne $AdditionalResources.AvailabilitySets) {
      if ($AdditionalResources.AvailabilitySets -is [System.Collections.IList]) { $availSets = @($AdditionalResources.AvailabilitySets.GetEnumerator()) }
      else { $availSets = @($AdditionalResources.AvailabilitySets) }
    }
  }

  # PaaS databases
  $pgServers = @()
  $mysqlServers = @()
  $cosmosAccounts = @()
  $redisCaches = @()
  if ($null -ne $PaaSInventory) {
    if ($null -ne $PaaSInventory.PostgreSQL) {
      if ($PaaSInventory.PostgreSQL -is [System.Collections.IList]) { $pgServers = @($PaaSInventory.PostgreSQL.GetEnumerator()) }
      else { $pgServers = @($PaaSInventory.PostgreSQL) }
    }
    if ($null -ne $PaaSInventory.MySQL) {
      if ($PaaSInventory.MySQL -is [System.Collections.IList]) { $mysqlServers = @($PaaSInventory.MySQL.GetEnumerator()) }
      else { $mysqlServers = @($PaaSInventory.MySQL) }
    }
    if ($null -ne $PaaSInventory.CosmosDB) {
      if ($PaaSInventory.CosmosDB -is [System.Collections.IList]) { $cosmosAccounts = @($PaaSInventory.CosmosDB.GetEnumerator()) }
      else { $cosmosAccounts = @($PaaSInventory.CosmosDB) }
    }
    if ($null -ne $PaaSInventory.Redis) {
      if ($PaaSInventory.Redis -is [System.Collections.IList]) { $redisCaches = @($PaaSInventory.Redis.GetEnumerator()) }
      else { $redisCaches = @($PaaSInventory.Redis) }
    }
  }

  # Network
  $vnetsArr = @()
  $privateEndpointsArr = @()
  if ($null -ne $NetworkInventory) {
    if ($null -ne $NetworkInventory.VNets) {
      if ($NetworkInventory.VNets -is [System.Collections.IList]) { $vnetsArr = @($NetworkInventory.VNets.GetEnumerator()) }
      else { $vnetsArr = @($NetworkInventory.VNets) }
    }
    if ($null -ne $NetworkInventory.PrivateEndpoints) {
      if ($NetworkInventory.PrivateEndpoints -is [System.Collections.IList]) { $privateEndpointsArr = @($NetworkInventory.PrivateEndpoints.GetEnumerator()) }
      else { $privateEndpointsArr = @($NetworkInventory.PrivateEndpoints) }
    }
  }

  # =========================================================================
  # 2. Compute derived metrics
  # =========================================================================
  $reportDate = Get-Date -Format "MMMM dd, yyyy 'at' HH:mm"
  $duration = (Get-Date) - $StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  # Core counts
  $totalVMs = $VeeamSizing.TotalVMs
  $totalVMSS = $VeeamSizing.TotalVMSS
  $totalVMSSInstances = $VeeamSizing.TotalVMSSInstances
  $totalSQLDbs = $VeeamSizing.TotalSQLDatabases
  $totalSQLMIs = $VeeamSizing.TotalSQLManagedInstances
  $subCount = $Subscriptions.Count
  $filesCount = $fileShares.Count
  $blobsCount = $blobContainers.Count
  $vaultsCount = $vaults.Count
  $policiesCount = $policies.Count
  $kvCount = $keyVaults.Count
  $aksCount = $aksClusters.Count
  $webAppCount = $webApps.Count
  $funcAppCount = $functionApps.Count
  $acrCount = $containerRegistries.Count
  $storageAcctCount = $storageAccts.Count
  $pgCount = $pgServers.Count
  $mysqlCount = $mysqlServers.Count
  $cosmosCount = $cosmosAccounts.Count
  $redisCount = $redisCaches.Count
  $orphanedDiskCount = $orphanedDisks.Count
  $snapshotCount = $snapshotsArr.Count
  $vnetCount = $vnetsArr.Count
  $peCount = $privateEndpointsArr.Count

  # Storage metrics
  $vmStorageGB = [math]::Round($VeeamSizing.TotalVMStorageGB, 0)
  $vmssStorageGB = [math]::Round($VeeamSizing.TotalVMSSStorageGB, 0)
  $sqlStorageGB = [math]::Round($VeeamSizing.TotalSQLStorageGB, 0)
  $fileStorageGB = [math]::Round($VeeamSizing.TotalFileShareStorageGB, 0)
  $pgStorageGB = if ($null -ne $VeeamSizing.TotalPostgreSQLStorageGB) { [math]::Round($VeeamSizing.TotalPostgreSQLStorageGB, 0) } else { 0 }
  $mysqlStorageGB = if ($null -ne $VeeamSizing.TotalMySQLStorageGB) { [math]::Round($VeeamSizing.TotalMySQLStorageGB, 0) } else { 0 }
  $orphanedDiskStorageGB = if ($null -ne $VeeamSizing.TotalOrphanedDiskStorageGB) { [math]::Round($VeeamSizing.TotalOrphanedDiskStorageGB, 0) } else { 0 }

  # Formatted storage strings
  $sourceFormatted = _FormatStorageGB $VeeamSizing.TotalSourceStorageGB

  # =========================================================================
  # Backup coverage / protection gap analysis
  # =========================================================================
  $protectedVMs = 0
  $protectedSQL = 0
  $protectedAFS = 0
  foreach ($v in $vaults) {
    $pvms = $v.ProtectedVMs
    if ($null -ne $pvms) { $protectedVMs += $pvms }
    $psql = $v.ProtectedSQL
    if ($null -ne $psql) { $protectedSQL += $psql }
    $pafs = $v.ProtectedFileShares
    if ($null -ne $pafs) { $protectedAFS += $pafs }
  }

  $unprotectedVMs = $totalVMs - $protectedVMs
  if ($unprotectedVMs -lt 0) { $unprotectedVMs = 0 }
  $unprotectedSQL = $totalSQLDbs - $protectedSQL
  if ($unprotectedSQL -lt 0) { $unprotectedSQL = 0 }

  # Coverage score (weighted: VM 60%, SQL 30%, AFS 10%)
  $coverageScore = 0
  $totalWeight = 0
  $weightedSum = 0

  if ($totalVMs -gt 0) {
    $vmCovPct = [math]::Min(($protectedVMs / $totalVMs) * 100, 100)
    $weightedSum += $vmCovPct * 60
    $totalWeight += 60
  }
  if ($totalSQLDbs -gt 0) {
    $sqlCovPct = [math]::Min(($protectedSQL / $totalSQLDbs) * 100, 100)
    $weightedSum += $sqlCovPct * 30
    $totalWeight += 30
  }
  if ($filesCount -gt 0) {
    $afsCovPct = [math]::Min(($protectedAFS / $filesCount) * 100, 100)
    $weightedSum += $afsCovPct * 10
    $totalWeight += 10
  }

  if ($totalWeight -gt 0) {
    $coverageScore = [math]::Round($weightedSum / $totalWeight, 0)
  }

  # SQL percentage of total workloads
  $totalWorkloads = $totalVMs + $totalVMSSInstances + $totalSQLDbs + $totalSQLMIs + $kvCount + $aksCount + $webAppCount + $funcAppCount + $pgCount + $mysqlCount + $cosmosCount + $redisCount
  $sqlPct = 0
  if ($totalWorkloads -gt 0) {
    $sqlPct = [math]::Round(($totalSQLDbs + $totalSQLMIs) / $totalWorkloads * 100, 0)
  }

  # Coverage percentage for vault KPI ring
  $coveragePct = $coverageScore

  # =========================================================================
  # Findings engine
  # =========================================================================
  $findings = New-Object System.Collections.Generic.List[object]

  if ($unprotectedVMs -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "High"
      Title       = "Unprotected Virtual Machines"
      Description = "$unprotectedVMs of $totalVMs VMs not protected by Azure Backup"
      Section     = "Coverage"
    })
  }

  if ($unprotectedSQL -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Medium"
      Title       = "Unprotected SQL Databases"
      Description = "$unprotectedSQL SQL databases without backup coverage"
      Section     = "Coverage"
    })
  }

  if ($vaultsCount -eq 0 -and ($totalVMs -gt 0 -or $totalSQLDbs -gt 0)) {
    $findings.Add([PSCustomObject]@{
      Severity    = "High"
      Title       = "No Backup Infrastructure"
      Description = "No Recovery Services Vaults detected — workloads are unprotected"
      Section     = "Infrastructure"
    })
  }

  if ($unprotectedVMs -eq 0 -and $totalVMs -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Full VM Protection"
      Description = "All $totalVMs Azure VMs have backup protection"
      Section     = "Coverage"
    })
  }

  # Encryption gap check
  $noEncryptionVMs = @($VmInventory | Where-Object { $_.EncryptionType -eq 'SSE-PMK' }).Count
  $adeVMs = @($VmInventory | Where-Object { $_.EncryptionType -eq 'ADE' }).Count
  $cmkVMs = @($VmInventory | Where-Object { $_.EncryptionType -eq 'SSE-CMK' }).Count
  if ($noEncryptionVMs -gt 0 -and $totalVMs -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Medium"
      Title       = "VMs Using Platform-Managed Encryption Only"
      Description = "$noEncryptionVMs of $totalVMs VMs use only platform-managed keys (SSE-PMK). Consider ADE or customer-managed keys for sensitive workloads."
      Section     = "Security"
    })
  }

  # NSG exposure check
  $criticalExposure = @($VmInventory | Where-Object { $_.ExposureLevel -eq 'Critical' }).Count
  $highExposure = @($VmInventory | Where-Object { $_.ExposureLevel -eq 'High' }).Count
  if ($criticalExposure -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "High"
      Title       = "Internet-Exposed VMs (All Ports)"
      Description = "$criticalExposure VM(s) have NSG rules allowing all inbound traffic from the internet"
      Section     = "Security"
    })
  }
  if ($highExposure -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "High"
      Title       = "Internet-Exposed Sensitive Ports"
      Description = "$highExposure VM(s) have NSG rules allowing inbound access to sensitive ports (SSH/RDP/SQL) from the internet"
      Section     = "Security"
    })
  }

  # Managed identity check
  $noIdentityVMs = @($VmInventory | Where-Object { $_.ManagedIdentity -eq 'None' }).Count
  if ($noIdentityVMs -gt 0 -and $totalVMs -gt 5) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "VMs Without Managed Identity"
      Description = "$noIdentityVMs of $totalVMs VMs have no managed identity assigned"
      Section     = "Security"
    })
  }

  # Storage account security
  $publicStorageAccounts = @($storageAccts | Where-Object { $_.AllowBlobPublicAccess -eq $true }).Count
  if ($publicStorageAccounts -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Medium"
      Title       = "Storage Accounts Allow Public Blob Access"
      Description = "$publicStorageAccounts storage account(s) allow public blob access"
      Section     = "Security"
    })
  }

  $openNetworkAccounts = @($storageAccts | Where-Object { $_.NetworkDefaultAction -eq 'Allow' }).Count
  if ($openNetworkAccounts -gt 0 -and $storageAcctCount -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Medium"
      Title       = "Storage Accounts Open to All Networks"
      Description = "$openNetworkAccounts of $storageAcctCount storage account(s) allow access from all networks"
      Section     = "Security"
    })
  }

  # Skipped storage accounts
  if ($skippedAccounts -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Storage Accounts Inaccessible"
      Description = "$skippedAccounts storage account(s) were skipped due to RBAC-only access or insufficient permissions — data may be incomplete"
      Section     = "Coverage"
    })
  }

  # Soft delete check
  $softDeleteMissing = 0
  foreach ($v in $vaults) {
    $sdState = "$($v.SoftDeleteState)"
    if ($sdState -notlike "*Enabled*" -and $sdState -notlike "*AlwaysOn*") {
      $softDeleteMissing++
    }
  }
  if ($softDeleteMissing -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Soft Delete Configuration"
      Description = "Soft delete not enabled on $softDeleteMissing Recovery Services Vault(s)"
      Section     = "Security"
    })
  }

  # Immutability check
  $hasImmutable = $false
  foreach ($v in $vaults) {
    $immState = "$($v.Immutability)"
    if ($immState -like "*Locked*" -or $immState -like "*Unlocked*") {
      $hasImmutable = $true
    }
  }
  if (-not $hasImmutable -and $vaultsCount -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Immutability Configuration"
      Description = "No immutable Recovery Services Vaults detected"
      Section     = "Security"
    })
  }

  # Orphaned disk finding
  if ($orphanedDiskCount -gt 0) {
    $orphanedTotalGB = _SafeSum $orphanedDisks 'DiskSizeGB'
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Orphaned Managed Disks"
      Description = "$orphanedDiskCount unattached managed disk(s) consuming $([math]::Round($orphanedTotalGB, 0)) GB — review for cleanup or backup inclusion"
      Section     = "Infrastructure"
    })
  }

  # ADLS Gen2 finding
  $adlsCount = @($storageAccts | Where-Object { $_.IsHnsEnabled -eq $true }).Count
  if ($adlsCount -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Info"
      Title       = "Data Lake Storage Gen2 Detected"
      Description = "$adlsCount storage account(s) with hierarchical namespace (ADLS Gen2) — ensure data lake backup strategy is defined"
      Section     = "Coverage"
    })
  }

  # PaaS databases without backup finding
  $totalPaasDBs = $pgCount + $mysqlCount + $cosmosCount
  if ($totalPaasDBs -gt 0) {
    $findings.Add([PSCustomObject]@{
      Severity    = "Medium"
      Title       = "PaaS Databases Require Backup Strategy"
      Description = "$totalPaasDBs PaaS database(s) discovered ($pgCount PostgreSQL, $mysqlCount MySQL, $cosmosCount Cosmos DB) — verify backup policies are configured"
      Section     = "Coverage"
    })
  }

  # Count findings by severity
  $findingsHigh = @($findings | Where-Object { $_.Severity -eq "High" }).Count
  $findingsMedium = @($findings | Where-Object { $_.Severity -eq "Medium" }).Count
  $findingsInfo = @($findings | Where-Object { $_.Severity -eq "Info" }).Count

  # =========================================================================
  # Recommendations engine
  # =========================================================================
  $recommendations = New-Object System.Collections.Generic.List[object]

  if ($unprotectedVMs -gt 0) {
    $recommendations.Add([PSCustomObject]@{
      Tier   = "Immediate"
      Action = "Deploy Veeam Backup for Azure to protect $unprotectedVMs unprotected VMs"
    })
  }

  if ($vaultsCount -eq 0 -and $totalVMs -gt 0) {
    $recommendations.Add([PSCustomObject]@{
      Tier   = "Immediate"
      Action = "Evaluate Veeam Backup for Azure for workload protection"
    })
  }

  if ($unprotectedSQL -gt 0) {
    $recommendations.Add([PSCustomObject]@{
      Tier   = "Short-Term"
      Action = "Extend backup coverage to $unprotectedSQL SQL databases"
    })
  }

  if ($unprotectedVMs -le 0 -and $unprotectedSQL -le 0) {
    $recommendations.Add([PSCustomObject]@{
      Tier   = "Strategic"
      Action = "Consider Veeam Backup for Azure for cross-region DR and immutable backups"
    })
  }

  if ($totalVMs -gt 50) {
    $recommendations.Add([PSCustomObject]@{
      Tier   = "Strategic"
      Action = "Plan phased rollout — prioritize production workloads by tag"
    })
  }

  # =========================================================================
  # 3. Build CSS
  # =========================================================================
  $cssBlock = @"
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --ms-blue-light: #50E6FF;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --veeam-green: #00B336;
  --color-success: #107C10;
  --color-warning: #F7630C;
  --color-danger: #D13438;
  --color-info: #0078D4;
  --color-purple: #8661C5;
  --header-dark: #1B1B2F;
  --header-mid: #1F4068;
  --header-deep: #162447;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
  -webkit-font-smoothing: antialiased;
  counter-reset: section-counter;
}

.container { max-width: 1440px; margin: 0 auto; padding: 0 32px 40px; }

/* ===== Executive Dark Header ===== */
.header {
  background: linear-gradient(135deg, var(--header-dark) 0%, var(--header-mid) 50%, var(--header-deep) 100%);
  padding: 48px 32px 40px;
  margin-bottom: 32px;
  position: relative;
  overflow: hidden;
}
.header-orb {
  position: absolute;
  top: -50%;
  right: -10%;
  width: 400px;
  height: 400px;
  background: radial-gradient(circle, rgba(255,255,255,0.04) 0%, transparent 70%);
  border-radius: 50%;
}
.header-content {
  max-width: 1440px;
  margin: 0 auto;
  position: relative;
  z-index: 1;
}
.header-badge {
  display: inline-block;
  padding: 4px 14px;
  background: rgba(255,255,255,0.10);
  color: #FFFFFF;
  border: 1px solid rgba(255,255,255,0.20);
  border-radius: 14px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  backdrop-filter: blur(12px);
  margin-bottom: 16px;
}
.header-title {
  font-size: 36px;
  font-weight: 700;
  color: #FFFFFF;
  letter-spacing: -0.02em;
  margin-bottom: 6px;
}
.header-subtitle {
  font-size: 16px;
  font-weight: 400;
  color: rgba(255,255,255,0.75);
  margin-bottom: 20px;
}
.header-meta {
  display: flex;
  flex-wrap: wrap;
  gap: 24px;
  align-items: center;
}
.header-meta span {
  font-size: 13px;
  color: rgba(255,255,255,0.6);
}
.header-meta span strong {
  color: rgba(255,255,255,0.9);
  font-weight: 600;
}

/* ===== Assessment Details Bar ===== */
.details-bar {
  background: white;
  padding: 16px 32px;
  margin-bottom: 24px;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-4);
  display: flex;
  flex-wrap: wrap;
  gap: 24px;
}
.details-bar-item {
  display: flex;
  gap: 8px;
}
.details-bar-label {
  color: var(--ms-gray-90);
  font-size: 12px;
  font-weight: 400;
}
.details-bar-value {
  color: var(--ms-gray-160);
  font-size: 12px;
  font-weight: 600;
}

/* ===== Glassmorphism KPI Cards ===== */
.kpi-grid {
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 20px;
  margin-bottom: 24px;
}
.kpi-card {
  background: rgba(255,255,255,0.85);
  backdrop-filter: blur(12px);
  padding: 24px;
  border-radius: 8px;
  box-shadow: var(--shadow-depth-4);
  border: 1px solid rgba(255,255,255,0.6);
  transition: all 0.2s ease;
  display: flex;
  gap: 16px;
  align-items: flex-start;
}
.kpi-card:hover {
  box-shadow: var(--shadow-depth-8);
  transform: translateY(-2px);
}
.kpi-card-content { flex: 1; }
.kpi-label {
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--ms-gray-90);
  margin-bottom: 8px;
}
.kpi-value {
  font-size: 32px;
  font-weight: 700;
  color: var(--ms-gray-160);
  line-height: 1.1;
  margin-bottom: 6px;
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  font-variant-numeric: tabular-nums;
}
.kpi-subtext {
  font-size: 12px;
  color: var(--ms-gray-90);
  font-weight: 400;
}

/* ===== Collapsible Sections ===== */
.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-4);
}
details.section {
  counter-increment: section-counter;
}
details.section > summary {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 3px solid transparent;
  border-image: linear-gradient(90deg, var(--ms-blue), var(--veeam-green), transparent) 1;
  display: flex;
  align-items: baseline;
  gap: 12px;
  cursor: pointer;
  list-style: none;
  user-select: none;
}
details.section > summary::-webkit-details-marker { display: none; }
details.section > summary::before {
  content: counter(section-counter, decimal-leading-zero);
  font-size: 14px;
  font-weight: 700;
  color: var(--ms-blue);
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  min-width: 28px;
}
details.section > summary::after {
  content: '\25B6';
  font-size: 12px;
  color: var(--ms-gray-90);
  margin-left: auto;
  transition: transform 0.2s ease;
}
details[open].section > summary::after {
  transform: rotate(90deg);
}
details.section > summary:hover {
  color: var(--ms-blue-dark);
}

/* ===== Executive Summary 3-Column ===== */
.exec-summary-grid {
  display: grid;
  grid-template-columns: auto 1fr 1fr;
  gap: 32px;
  align-items: flex-start;
}
.exec-summary-gauge { text-align: center; min-width: 220px; }
.exec-summary-subtitle {
  font-weight: 700;
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--ms-gray-90);
  margin-bottom: 12px;
  padding-bottom: 8px;
  border-bottom: 2px solid var(--ms-gray-30);
}
.exec-risk-item {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 8px 0;
  border-bottom: 1px solid var(--ms-gray-20);
}
.exec-risk-item:last-child { border-bottom: none; }
.severity-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
  margin-top: 6px;
}
.severity-dot.high { background: var(--color-danger); }
.severity-dot.medium { background: var(--color-warning); }
.severity-dot.low { background: var(--color-info); }
.severity-dot.info { background: var(--color-success); }
.exec-risk-text { font-size: 13px; color: var(--ms-gray-130); line-height: 1.4; }
.exec-action-item {
  display: flex;
  align-items: flex-start;
  gap: 10px;
  padding: 8px 0;
  border-bottom: 1px solid var(--ms-gray-20);
}
.exec-action-item:last-child { border-bottom: none; }
.tier-dot {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: white;
  flex-shrink: 0;
  margin-top: 3px;
}
.tier-dot.immediate { background: var(--color-danger); }
.tier-dot.short-term { background: var(--color-warning); }
.tier-dot.strategic { background: var(--color-info); }
.exec-action-text { font-size: 13px; color: var(--ms-gray-130); line-height: 1.4; }

/* ===== Key Takeaway Bar ===== */
.takeaway-bar {
  border-radius: 6px;
  padding: 14px 24px;
  margin-top: 24px;
  font-size: 14px;
  text-align: center;
}
.takeaway-bar.danger { background: #FDE7E9; color: #6E0811; }
.takeaway-bar.warning { background: #FFF4CE; color: #6D4E00; }
.takeaway-bar.success { background: #DFF6DD; color: #0E700E; }
.takeaway-bar strong { font-weight: 700; }

/* ===== Tables ===== */
.table-container { overflow-x: auto; margin-top: 16px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th {
  padding: 12px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}
td {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
  font-variant-numeric: tabular-nums;
}
tbody tr:hover { background: var(--ms-gray-10); }
tbody tr:last-child td { border-bottom: none; }
td.mono {
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
}

/* ===== Status Dots ===== */
.status-dot {
  display: inline-block;
  width: 10px;
  height: 10px;
  border-radius: 50%;
  margin-right: 6px;
  vertical-align: middle;
}
.status-dot.green { background: var(--color-success); }
.status-dot.orange { background: var(--color-warning); }
.status-dot.gray { background: var(--ms-gray-50); }

/* ===== Info Cards ===== */
.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--ms-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}
.info-card-title {
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 8px;
  font-size: 14px;
}
.info-card-text {
  color: var(--ms-gray-90);
  font-size: 13px;
  line-height: 1.6;
  margin-bottom: 8px;
}
.info-card-text:last-child { margin-bottom: 0; }

/* ===== Finding Cards ===== */
.finding-card {
  background: white;
  border-left: 4px solid var(--ms-gray-50);
  padding: 16px 20px;
  margin: 12px 0;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}
.finding-card.severity-high { border-left-color: var(--color-danger); }
.finding-card.severity-medium { border-left-color: var(--color-warning); }
.finding-card.severity-low { border-left-color: var(--color-info); }
.finding-card.severity-info { border-left-color: var(--color-success); }
.finding-card-title { font-weight: 600; font-size: 14px; margin-bottom: 6px; }
.finding-card-detail { font-size: 13px; color: var(--ms-gray-90); line-height: 1.5; }

/* ===== Recommendation Cards ===== */
.rec-phase-header {
  font-size: 15px;
  font-weight: 700;
  color: var(--ms-gray-160);
  margin: 24px 0 12px;
  padding-bottom: 8px;
  border-bottom: 2px solid var(--ms-gray-30);
}
.rec-phase-header:first-child { margin-top: 0; }
.recommendation-card {
  background: white;
  padding: 20px 24px;
  margin: 12px 0;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-4);
  border-left: 4px solid var(--ms-gray-50);
}
.recommendation-card.tier-immediate { border-left-color: var(--color-danger); }
.recommendation-card.tier-short-term { border-left-color: var(--color-warning); }
.recommendation-card.tier-strategic { border-left-color: var(--color-info); }
.priority-badge {
  display: inline-block;
  padding: 3px 10px;
  border-radius: 4px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: white;
  margin-bottom: 8px;
}
.priority-badge.immediate { background: var(--color-danger); }
.priority-badge.short-term { background: var(--color-warning); }
.priority-badge.strategic { background: var(--color-info); }
.rec-action { font-size: 14px; color: var(--ms-gray-130); line-height: 1.5; }

/* ===== Protection Gap Bars ===== */
.gap-bar-container { margin: 12px 0; }
.gap-bar-label {
  font-size: 13px;
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 4px;
}
.gap-bar-track {
  width: 100%;
  height: 24px;
  background: var(--ms-gray-30);
  border-radius: 12px;
  overflow: hidden;
  position: relative;
}
.gap-bar-fill {
  height: 100%;
  border-radius: 12px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 12px;
  font-weight: 600;
  color: white;
  min-width: 40px;
  background: var(--color-success);
}

/* ===== Workload Flex (Donut + Table) ===== */
.workload-flex {
  display: flex;
  gap: 32px;
  align-items: flex-start;
  flex-wrap: wrap;
}
.workload-chart { flex-shrink: 0; }
.workload-table { flex: 1; min-width: 0; }

/* ===== SVG Containers ===== */
.svg-container { margin: 16px 0; }
.svg-container svg { max-width: 100%; height: auto; }

/* ===== Code Block ===== */
.code-block {
  background: var(--ms-gray-160);
  color: var(--ms-blue-light);
  padding: 20px 24px;
  border-radius: 4px;
  font-family: 'Cascadia Code', 'Consolas', 'Monaco', 'Courier New', monospace;
  font-size: 13px;
  line-height: 1.8;
  overflow-x: auto;
  margin-top: 16px;
}
.code-line { display: block; white-space: nowrap; }

/* ===== Professional Footer ===== */
.footer {
  text-align: center;
  padding: 32px 0 16px;
  border-top: 1px solid var(--ms-gray-30);
  margin-top: 16px;
}
.footer-conf {
  font-size: 11px;
  color: var(--ms-gray-90);
  font-style: italic;
  margin-bottom: 4px;
}
.footer-stamp {
  font-size: 11px;
  color: var(--ms-gray-50);
  font-family: 'Cascadia Code', 'Consolas', monospace;
}

/* ===== Responsive ===== */
@media (max-width: 768px) {
  .container { padding: 0 16px 20px; }
  .header { padding: 32px 16px 28px; }
  .header-title { font-size: 24px; }
  .kpi-grid { grid-template-columns: 1fr; }
  .exec-summary-grid { grid-template-columns: 1fr; }
  .section { padding: 20px; }
  .details-bar { flex-direction: column; gap: 12px; }
  .workload-flex { flex-direction: column; }
}

/* ===== Print ===== */
@media print {
  body { background: white; font-size: 12px; }
  .container { max-width: 100%; padding: 0; }
  .header {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
    padding: 32px 24px;
  }
  .kpi-card, .section, .details-bar {
    box-shadow: none;
    border: 1px solid var(--ms-gray-30);
    page-break-inside: avoid;
  }
  .kpi-card:hover { transform: none; }
  .kpi-card { backdrop-filter: none; background: white; }
  .finding-card, .recommendation-card {
    box-shadow: none;
    border: 1px solid var(--ms-gray-30);
    page-break-inside: avoid;
  }
  .gap-bar-fill, .priority-badge, .severity-dot, .tier-dot, .status-dot, .header-badge {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
  }
  .takeaway-bar {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
  }
  svg {
    print-color-adjust: exact;
    -webkit-print-color-adjust: exact;
  }
  .section { page-break-inside: avoid; }
  details.section { display: block; }
  details.section > summary::after { display: none; }
}
"@

  # =========================================================================
  # 4. Build HTML sections
  # =========================================================================

  # ---- Header ----
  $safeReportDate = _EscapeHtml $reportDate
  $safeDurationStr = _EscapeHtml $durationStr

  $headerHtml = @"
  <div class="header">
    <div class="header-orb"></div>
    <div class="header-content">
      <div class="header-badge">Azure Infrastructure Assessment</div>
      <h1 class="header-title">Veeam Backup for Azure</h1>
      <p class="header-subtitle">Discovery &amp; Inventory Report</p>
      <div class="header-meta">
        <span><strong>Generated:</strong> $safeReportDate</span>
        <span><strong>Duration:</strong> $safeDurationStr</span>
        <span><strong>Subscriptions:</strong> $subCount</span>
      </div>
    </div>
  </div>
"@

  # ---- Assessment Details Bar ----
  $detailsBarHtml = @"
  <div class="details-bar">
    <div class="details-bar-item">
      <span class="details-bar-label">Subscriptions Scanned:</span>
      <span class="details-bar-value">$subCount</span>
    </div>
    <div class="details-bar-item">
      <span class="details-bar-label">Workloads Discovered:</span>
      <span class="details-bar-value">$totalWorkloads</span>
    </div>
    <div class="details-bar-item">
      <span class="details-bar-label">Total Source Data:</span>
      <span class="details-bar-value">$(_EscapeHtml $sourceFormatted)</span>
    </div>
  </div>
"@

  # ---- KPI Grid (6 cards with mini-rings) ----
  $vmRing = New-SvgMiniRing -Percent 100 -Color "#0078D4"
  $sqlRing = New-SvgMiniRing -Percent $sqlPct -Color "#8661C5"
  # Storage discovery completeness: ratio of enumerated vs total containers
  $storageDiscoveryPct = 0
  $totalStorageItems = $filesCount + $blobsCount
  if ($totalStorageItems -gt 0) {
    $enumeratedItems = @($fileShares | Where-Object { $null -ne $_.UsageGiB }).Count + @($blobContainers | Where-Object { $null -ne $_.EstimatedGiB }).Count
    $storageDiscoveryPct = [math]::Min([math]::Round(($enumeratedItems / $totalStorageItems) * 100, 0), 100)
  }
  $storageRing = New-SvgMiniRing -Percent $storageDiscoveryPct -Color "#F7630C"
  $vaultRing = New-SvgMiniRing -Percent $coveragePct -Color "#107C10"
  $sourceRing = New-SvgMiniRing -Percent 100 -Color "#00B336"

  $safeVmStorage = _EscapeHtml "$vmStorageGB GB provisioned"
  $safeVmssSub = _EscapeHtml "$totalVMSSInstances instances, $vmssStorageGB GB"
  $safeSqlSub = _EscapeHtml "$totalSQLDbs databases + $totalSQLMIs managed instances"
  $safeStorageSub = _EscapeHtml "$storageAcctCount accounts, $filesCount shares, $blobsCount containers"
  $safeVaultSub = _EscapeHtml "$policiesCount backup policies"
  $safeSourceLabel = _EscapeHtml $sourceFormatted

  $kpiHtml = @"
  <div class="kpi-grid">
    <div class="kpi-card">
      $vmRing
      <div class="kpi-card-content">
        <div class="kpi-label">Azure VMs</div>
        <div class="kpi-value">$totalVMs</div>
        <div class="kpi-subtext">$safeVmStorage</div>
      </div>
    </div>
    <div class="kpi-card">
      $(New-SvgMiniRing -Percent 100 -Color "#D83B01")
      <div class="kpi-card-content">
        <div class="kpi-label">VM Scale Sets</div>
        <div class="kpi-value">$totalVMSS</div>
        <div class="kpi-subtext">$safeVmssSub</div>
      </div>
    </div>
    <div class="kpi-card">
      $sqlRing
      <div class="kpi-card-content">
        <div class="kpi-label">SQL Workloads</div>
        <div class="kpi-value">$($totalSQLDbs + $totalSQLMIs)</div>
        <div class="kpi-subtext">$safeSqlSub</div>
      </div>
    </div>
    <div class="kpi-card">
      $storageRing
      <div class="kpi-card-content">
        <div class="kpi-label">Storage Discovery</div>
        <div class="kpi-value">$storageAcctCount</div>
        <div class="kpi-subtext">$safeStorageSub</div>
      </div>
    </div>
    <div class="kpi-card">
      $vaultRing
      <div class="kpi-card-content">
        <div class="kpi-label">Backup Vaults</div>
        <div class="kpi-value">$vaultsCount</div>
        <div class="kpi-subtext">$safeVaultSub</div>
      </div>
    </div>
    <div class="kpi-card">
      $sourceRing
      <div class="kpi-card-content">
        <div class="kpi-label">Total Source Data</div>
        <div class="kpi-value">$safeSourceLabel</div>
        <div class="kpi-subtext">across all workloads</div>
      </div>
    </div>
  </div>
"@

  # ---- Section 01: Executive Summary ----
  $gaugeHtml = New-SvgGaugeChart -Score $coverageScore -Label "Backup Coverage"

  # Top findings for summary
  $topFindings = @($findings | Where-Object { $_.Severity -ne "Info" } | Select-Object -First 3)
  $risksHtml = ""
  foreach ($f in $topFindings) {
    $sevClass = $f.Severity.ToLower()
    $safeTitle = _EscapeHtml $f.Title
    $risksHtml += @"
        <div class="exec-risk-item">
          <span class="severity-dot $sevClass"></span>
          <span class="exec-risk-text">$safeTitle</span>
        </div>
"@
  }
  if ($risksHtml -eq "") {
    $risksHtml = '        <div class="exec-risk-item"><span class="severity-dot info"></span><span class="exec-risk-text">No significant risks identified</span></div>'
  }

  # Top actions for summary
  $topActions = @($recommendations | Select-Object -First 3)
  $actionsHtml = ""
  foreach ($r in $topActions) {
    $tierClass = $r.Tier.ToLower() -replace ' ', '-'
    $safeAction = _EscapeHtml $r.Action
    $safeTier = _EscapeHtml $r.Tier
    $actionsHtml += @"
        <div class="exec-action-item">
          <span class="tier-dot $tierClass">$safeTier</span>
          <span class="exec-action-text">$safeAction</span>
        </div>
"@
  }
  if ($actionsHtml -eq "") {
    $actionsHtml = '        <div class="exec-action-item"><span class="tier-dot strategic">Info</span><span class="exec-action-text">No immediate actions required</span></div>'
  }

  # Takeaway bar
  $takeawayClass = "success"
  $takeawayMessage = "All discovered workloads have backup coverage. Consider Veeam Backup for Azure for advanced cross-region DR and immutable backup capabilities."
  if ($coverageScore -lt 40) {
    $takeawayClass = "danger"
    $takeawayMessage = "Significant protection gaps detected. $unprotectedVMs VMs and $unprotectedSQL SQL databases lack backup coverage. Immediate action recommended."
  }
  elseif ($coverageScore -lt 70) {
    $takeawayClass = "warning"
    $takeawayMessage = "Partial backup coverage detected. Extending protection to all workloads would strengthen disaster recovery readiness."
  }

  $execSummaryHtml = @"
  <details class="section" open>
    <summary>Executive Summary</summary>
    <div class="section-content">
    <div class="exec-summary-grid">
      <div class="exec-summary-gauge">
        <div class="svg-container">
$gaugeHtml
        </div>
      </div>
      <div>
        <div class="exec-summary-subtitle">Key Findings</div>
        <div style="font-size: 13px; color: var(--ms-gray-90); margin-bottom: 8px;">$findingsHigh High &middot; $findingsMedium Medium &middot; $findingsInfo Informational</div>
$risksHtml
      </div>
      <div>
        <div class="exec-summary-subtitle">Quick Actions</div>
$actionsHtml
      </div>
    </div>
    <div class="takeaway-bar $takeawayClass">
      <strong>Coverage Score: $coverageScore/100</strong> &mdash; $takeawayMessage
    </div>
    </div>
  </details>
"@

  # ---- Section 02: Workload Distribution ----
  $donutSegments = New-Object System.Collections.Generic.List[object]
  if ($vmStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "VM Storage"; Value = $vmStorageGB; Color = "#0078D4" })
  }
  if ($vmssStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "VMSS Storage"; Value = $vmssStorageGB; Color = "#D83B01" })
  }
  if ($sqlStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "SQL Storage"; Value = $sqlStorageGB; Color = "#8661C5" })
  }
  if ($pgStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "PostgreSQL"; Value = $pgStorageGB; Color = "#336791" })
  }
  if ($mysqlStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "MySQL"; Value = $mysqlStorageGB; Color = "#4479A1" })
  }
  if ($orphanedDiskStorageGB -gt 0) {
    $donutSegments.Add(@{ Label = "Orphaned Disks"; Value = $orphanedDiskStorageGB; Color = "#605E5C" })
  }

  $donutChart = New-SvgDonutChart -Segments $donutSegments -CenterLabel $sourceFormatted -CenterSubLabel "Source Data"

  $workloadRows = ""
  $workloadRows += "              <tr><td><strong>Virtual Machines</strong></td><td>$totalVMs</td><td>$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalVMStorageGB))</td></tr>`n"
  if ($totalVMSS -gt 0) {
    $workloadRows += "              <tr><td><strong>VM Scale Sets</strong></td><td>$totalVMSS ($totalVMSSInstances instances)</td><td>$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalVMSSStorageGB))</td></tr>`n"
  }
  $workloadRows += "              <tr><td><strong>SQL Databases</strong></td><td>$totalSQLDbs</td><td>$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalSQLStorageGB))</td></tr>`n"
  if ($totalSQLMIs -gt 0) {
    $miStorage = _SafeSum $sqlMIs 'StorageSizeGB'
    $workloadRows += "              <tr><td><strong>Managed Instances</strong></td><td>$totalSQLMIs</td><td>$(_EscapeHtml (_FormatStorageGB $miStorage))</td></tr>`n"
  }
  if ($filesCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Azure File Shares</strong></td><td>$filesCount</td><td>$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalFileShareStorageGB))</td></tr>`n"
  }
  if ($pgCount -gt 0) {
    $workloadRows += "              <tr><td><strong>PostgreSQL Servers</strong></td><td>$pgCount</td><td>$(_EscapeHtml (_FormatStorageGB $pgStorageGB))</td></tr>`n"
  }
  if ($mysqlCount -gt 0) {
    $workloadRows += "              <tr><td><strong>MySQL Servers</strong></td><td>$mysqlCount</td><td>$(_EscapeHtml (_FormatStorageGB $mysqlStorageGB))</td></tr>`n"
  }
  if ($cosmosCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Cosmos DB Accounts</strong></td><td>$cosmosCount</td><td>&mdash;</td></tr>`n"
  }
  if ($redisCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Redis Caches</strong></td><td>$redisCount</td><td>&mdash;</td></tr>`n"
  }
  if ($kvCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Key Vaults</strong></td><td>$kvCount</td><td>&mdash;</td></tr>`n"
  }
  if ($aksCount -gt 0) {
    $totalNodes = 0
    foreach ($c in $aksClusters) { if ($null -ne $c.TotalNodeCount) { $totalNodes += $c.TotalNodeCount } }
    $workloadRows += "              <tr><td><strong>AKS Clusters</strong></td><td>$aksCount ($totalNodes nodes)</td><td>&mdash;</td></tr>`n"
  }
  if ($webAppCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Web Apps</strong></td><td>$webAppCount</td><td>&mdash;</td></tr>`n"
  }
  if ($funcAppCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Function Apps</strong></td><td>$funcAppCount</td><td>&mdash;</td></tr>`n"
  }
  if ($orphanedDiskCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Orphaned Disks</strong></td><td>$orphanedDiskCount</td><td>$(_EscapeHtml (_FormatStorageGB $orphanedDiskStorageGB))</td></tr>`n"
  }
  if ($vnetCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Virtual Networks</strong></td><td>$vnetCount</td><td>&mdash;</td></tr>`n"
  }
  if ($acrCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Container Registries</strong></td><td>$acrCount</td><td>&mdash;</td></tr>`n"
  }
  if ($storageAcctCount -gt 0) {
    $workloadRows += "              <tr><td><strong>Storage Accounts</strong></td><td>$storageAcctCount</td><td>&mdash;</td></tr>`n"
  }

  $workloadDistHtml = @"
  <details class="section" open>
    <summary>Workload Distribution</summary>
    <div class="section-content">
    <div class="workload-flex">
      <div class="workload-chart svg-container">
$donutChart
      </div>
      <div class="workload-table">
        <div class="table-container">
          <table>
            <thead>
              <tr>
                <th>Workload</th>
                <th>Count</th>
                <th>Source Data</th>
              </tr>
            </thead>
            <tbody>
$workloadRows
            </tbody>
          </table>
        </div>
      </div>
    </div>
    </div>
  </details>
"@

  # ---- Section 03: VM Inventory ----
  # Hoist disk type map above the loop to avoid rebuilding per VM
  $diskTypeMap = @{
    'Premium_LRS'      = 'Premium SSD'
    'Premium_ZRS'      = 'Premium SSD'
    'StandardSSD_LRS'  = 'Standard SSD'
    'StandardSSD_ZRS'  = 'Standard SSD'
    'Standard_LRS'     = 'Standard HDD'
    'UltraSSD_LRS'     = 'Ultra SSD'
    'PremiumV2_LRS'    = 'Premium SSD v2'
  }

  $vmRowsList = New-Object System.Collections.Generic.List[string]
  foreach ($vm in $VmInventory) {
    $safeName = _EscapeHtml $vm.VmName
    $safeSub = _EscapeHtml $vm.SubscriptionName
    $safeRegion = _EscapeHtml $vm.Location
    $safeSize = _EscapeHtml $vm.VmSize
    $safeOs = _EscapeHtml $vm.OsType

    # OS icon
    $osIcon = "&#128421;"
    if ($safeOs -eq "Windows") { $osIcon = "&#9638;" }
    elseif ($safeOs -eq "Linux") { $osIcon = "&#9650;" }

    # Power state dot — default to "Unknown" for null
    $powerState = "$($vm.PowerState)"
    if ([string]::IsNullOrWhiteSpace($powerState)) { $powerState = "Unknown" }
    $powerState = $powerState.ToLower()
    $dotClass = "orange"
    $powerLabel = _EscapeHtml $vm.PowerState
    if ($powerState -like "*running*") {
      $dotClass = "green"
    }
    elseif ($powerState -like "*deallocated*" -or $powerState -like "*stopped*") {
      $dotClass = "gray"
    }

    # Disk info
    $osDiskGB = $vm.OsDiskSizeGB
    $dataDiskCount = $vm.DataDiskCount
    $totalGB = $vm.TotalProvisionedGB
    # Disk type label (using hoisted $diskTypeMap)
    $rawOsType = "$($vm.OsDiskType)"
    $osTypeLabel = if ($diskTypeMap.ContainsKey($rawOsType)) { $diskTypeMap[$rawOsType] } else { $rawOsType }

    # Collect unique data disk types from DataDiskSummary (format: LUN0:128GB:Premium_LRS; LUN1:256GB:Standard_LRS)
    $allDiskTypes = New-Object System.Collections.Generic.List[string]
    $allDiskTypes.Add($osTypeLabel)
    $hasUltra = ($rawOsType -eq 'UltraSSD_LRS')
    if (-not [string]::IsNullOrWhiteSpace($vm.DataDiskSummary)) {
      foreach ($entry in ($vm.DataDiskSummary -split ';\s*')) {
        $parts = $entry -split ':'
        if ($parts.Count -ge 3) {
          $rawDataType = $parts[2].Trim()
          if ($rawDataType -eq 'UltraSSD_LRS') { $hasUltra = $true }
          $dataLabel = if ($diskTypeMap.ContainsKey($rawDataType)) { $diskTypeMap[$rawDataType] } else { $rawDataType }
          if (-not $allDiskTypes.Contains($dataLabel)) {
            $allDiskTypes.Add($dataLabel)
          }
        }
      }
    }

    $diskTypeDisplay = _EscapeHtml ($allDiskTypes -join ' + ')
    $diskTypeTd = if ($hasUltra) {
      "<td><span style=`"background:#D83B01;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;`">$diskTypeDisplay</span></td>"
    } else {
      "<td>$diskTypeDisplay</td>"
    }

    # Encryption badge
    $encType = "$($vm.EncryptionType)"
    $encBadge = $encType
    if ($encType -eq 'ADE') {
      $encBadge = "<span style=`"background:#107C10;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;`">ADE</span>"
    } elseif ($encType -eq 'SSE-CMK') {
      $encBadge = "<span style=`"background:#0078D4;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;`">CMK</span>"
    } elseif ($encType -eq 'SSE-PMK') {
      $encBadge = "<span style=`"color:#605E5C;`">PMK</span>"
    }

    # Exposure badge
    $expLevel = "$($vm.ExposureLevel)"
    $expBadge = $expLevel
    if ($expLevel -eq 'Critical') {
      $expBadge = "<span style=`"background:#D13438;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;`">Critical</span>"
    } elseif ($expLevel -eq 'High') {
      $expBadge = "<span style=`"background:#F7630C;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;`">High</span>"
    } elseif ($expLevel -eq 'Medium') {
      $expBadge = "<span style=`"color:#F7630C;`">Medium</span>"
    } else {
      $expBadge = "<span style=`"color:#107C10;`">Low</span>"
    }

    # Identity
    $safeIdentity = _EscapeHtml "$($vm.ManagedIdentity)"

    # Disk display — flag unknown sizes
    $diskDisplay = "${osDiskGB}+${dataDiskCount}d"
    if ($vm.OsDiskUnknownSize -eq $true) {
      $diskDisplay = "<span style=`"color:#D13438;`" title=`"OS disk size unknown`">?+${dataDiskCount}d</span>"
    }

    $vmRowsList.Add(@"
              <tr>
                <td><strong>$safeName</strong></td>
                <td>$safeSub</td>
                <td>$safeRegion</td>
                <td>$osIcon $safeOs</td>
                <td>$safeSize</td>
                <td><span class="status-dot $dotClass"></span>$powerLabel</td>
                <td class="mono">$diskDisplay</td>
                $diskTypeTd
                <td class="mono">$totalGB GB</td>
                <td>$encBadge</td>
                <td>$expBadge</td>
                <td>$safeIdentity</td>
              </tr>
"@)
  }
  $vmTableRows = $vmRowsList -join "`n"

  $vmInventoryHtml = ""
  if ($VmInventory.Count -gt 0) {
    $vmInventoryHtml = @"
  <details class="section" open>
    <summary>VM Inventory</summary>
    <div class="section-content">
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>VM Name</th>
            <th>Subscription</th>
            <th>Region</th>
            <th>OS</th>
            <th>VM Size</th>
            <th>Power State</th>
            <th>Disks (OS+Data)</th>
            <th>Disk Type</th>
            <th>Total Storage</th>
            <th>Encryption</th>
            <th>Exposure</th>
            <th>Identity</th>
          </tr>
        </thead>
        <tbody>
$vmTableRows
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@
  }
  else {
    $vmInventoryHtml = @"
  <details class="section" open>
    <summary>VM Inventory</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">No Virtual Machines Discovered</div>
      <div class="info-card-text">No Azure VMs were found in the scanned subscriptions.</div>
    </div>
    </div>
  </details>
"@
  }

  # ---- Section 04: VMs by Region ----
  $vmsByLocation = $VmInventory | Group-Object Location | Sort-Object Count -Descending

  $regionBarItems = New-Object System.Collections.Generic.List[object]
  $regionTableRows = ""
  foreach ($group in $vmsByLocation) {
    $safeLoc = _EscapeHtml $group.Name
    $regionCount = $group.Count
    $sumVal = ($group.Group | Measure-Object -Property TotalProvisionedGB -Sum -ErrorAction SilentlyContinue).Sum
    $regionStorageGB = if ($null -eq $sumVal) { 0 } else { [math]::Round($sumVal, 0) }

    $regionBarItems.Add(@{
      Label    = $group.Name
      Value    = $regionCount
      MaxValue = 0
      Color    = "#0078D4"
    })

    $regionTableRows += "              <tr><td>$safeLoc</td><td class=`"mono`">$regionCount</td><td class=`"mono`">$(_EscapeHtml (_FormatStorageGB $regionStorageGB))</td></tr>`n"
  }

  $regionBarChart = ""
  if ($regionBarItems.Count -gt 0) {
    $regionBarChart = New-SvgHorizontalBarChart -Items $regionBarItems
  }

  $vmsByRegionHtml = ""
  if ($vmsByLocation.Count -gt 0) {
    $vmsByRegionHtml = @"
  <details class="section">
    <summary>VMs by Region</summary>
    <div class="section-content">
    <div class="svg-container">
$regionBarChart
    </div>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Region</th>
            <th>VM Count</th>
            <th>Total Storage</th>
          </tr>
        </thead>
        <tbody>
$regionTableRows
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@
  }
  else {
    $vmsByRegionHtml = @"
  <details class="section">
    <summary>VMs by Region</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">No Regional Data</div>
      <div class="info-card-text">No VMs discovered to analyze regional distribution.</div>
    </div>
    </div>
  </details>
"@
  }

  # ---- Section 05: VMSS Inventory ----
  $vmssHtml = ""
  if ($vmssItems.Count -gt 0) {
    $vmssTableRows = ""
    foreach ($ss in $vmssItems) {
      $safeSsName = _EscapeHtml $ss.Name
      $safeSsSub = _EscapeHtml $ss.SubscriptionName
      $safeSsLoc = _EscapeHtml $ss.Location
      $safeSsSku = _EscapeHtml $ss.SkuName
      $safeSsIdentity = _EscapeHtml $ss.ManagedIdentity
      $ssCapacity = if ($null -ne $ss.Capacity) { $ss.Capacity } else { 0 }
      $ssTotalGB = if ($null -ne $ss.TotalDiskAllInstances) { $ss.TotalDiskAllInstances } else { 0 }
      $vmssTableRows += "              <tr><td><strong>$safeSsName</strong></td><td>$safeSsSub</td><td>$safeSsLoc</td><td>$safeSsSku</td><td class=`"mono`">$ssCapacity</td><td class=`"mono`">$ssTotalGB GB</td><td>$safeSsIdentity</td></tr>`n"
    }
    $vmssHtml = @"
  <details class="section">
    <summary>VM Scale Sets</summary>
    <div class="section-content">
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Scale Set</th>
            <th>Subscription</th>
            <th>Region</th>
            <th>VM Size</th>
            <th>Instances</th>
            <th>Total Storage</th>
            <th>Identity</th>
          </tr>
        </thead>
        <tbody>
$vmssTableRows
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@
  }

  # ---- Section 05b: Security Posture ----
  $securityPostureHtml = ""
  $hasSecurityData = ($VmInventory.Count -gt 0 -or $storageAccts.Count -gt 0)
  if ($hasSecurityData) {
    $secContent = ""

    # Encryption summary
    if ($VmInventory.Count -gt 0) {
      $secContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">VM Disk Encryption</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Encryption Type</th><th>Count</th><th>Percentage</th></tr></thead>
        <tbody>
          <tr><td><span style="background:#107C10;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;">ADE</span> Azure Disk Encryption</td><td class="mono">$adeVMs</td><td class="mono">$(if ($totalVMs -gt 0) { [math]::Round($adeVMs / $totalVMs * 100, 0) } else { 0 })%</td></tr>
          <tr><td><span style="background:#0078D4;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;">CMK</span> Customer-Managed Keys</td><td class="mono">$cmkVMs</td><td class="mono">$(if ($totalVMs -gt 0) { [math]::Round($cmkVMs / $totalVMs * 100, 0) } else { 0 })%</td></tr>
          <tr><td><span style="color:#605E5C;">PMK</span> Platform-Managed Keys</td><td class="mono">$noEncryptionVMs</td><td class="mono">$(if ($totalVMs -gt 0) { [math]::Round($noEncryptionVMs / $totalVMs * 100, 0) } else { 0 })%</td></tr>
        </tbody>
      </table>
    </div>
"@
    }

    # Exposure summary
    if ($VmInventory.Count -gt 0) {
      $lowExposure = @($VmInventory | Where-Object { $_.ExposureLevel -eq 'Low' }).Count
      $medExposure = @($VmInventory | Where-Object { $_.ExposureLevel -eq 'Medium' }).Count
      $secContent += @"

    <div style="margin-top: 24px; font-weight: 600; font-size: 14px; margin-bottom: 12px;">Network Exposure</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Exposure Level</th><th>Count</th><th>Description</th></tr></thead>
        <tbody>
          <tr><td><span style="background:#D13438;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;">Critical</span></td><td class="mono">$criticalExposure</td><td>All ports open to internet</td></tr>
          <tr><td><span style="background:#F7630C;color:#fff;padding:2px 8px;border-radius:10px;font-size:0.85em;">High</span></td><td class="mono">$highExposure</td><td>Sensitive ports (SSH/RDP/SQL) open to internet</td></tr>
          <tr><td><span style="color:#F7630C;">Medium</span></td><td class="mono">$medExposure</td><td>Public IP assigned (no dangerous inbound rules detected)</td></tr>
          <tr><td><span style="color:#107C10;">Low</span></td><td class="mono">$lowExposure</td><td>No public IP, no dangerous inbound rules</td></tr>
        </tbody>
      </table>
    </div>
"@
    }

    # Storage security summary
    if ($storageAccts.Count -gt 0) {
      $httpsOnlyCount = @($storageAccts | Where-Object { $_.HttpsOnly -eq $true }).Count
      $firewallCount = @($storageAccts | Where-Object { $_.NetworkDefaultAction -eq 'Deny' }).Count
      $noKeyAccessCount = @($storageAccts | Where-Object { $_.AllowSharedKeyAccess -eq $false }).Count
      $secContent += @"

    <div style="margin-top: 24px; font-weight: 600; font-size: 14px; margin-bottom: 12px;">Storage Account Security ($storageAcctCount accounts)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Security Control</th><th>Enabled</th><th>Coverage</th></tr></thead>
        <tbody>
          <tr><td>HTTPS Only</td><td class="mono">$httpsOnlyCount / $storageAcctCount</td><td class="mono">$(if ($storageAcctCount -gt 0) { [math]::Round($httpsOnlyCount / $storageAcctCount * 100, 0) } else { 0 })%</td></tr>
          <tr><td>Firewall (Deny Default)</td><td class="mono">$firewallCount / $storageAcctCount</td><td class="mono">$(if ($storageAcctCount -gt 0) { [math]::Round($firewallCount / $storageAcctCount * 100, 0) } else { 0 })%</td></tr>
          <tr><td>Blob Public Access Disabled</td><td class="mono">$($storageAcctCount - $publicStorageAccounts) / $storageAcctCount</td><td class="mono">$(if ($storageAcctCount -gt 0) { [math]::Round(($storageAcctCount - $publicStorageAccounts) / $storageAcctCount * 100, 0) } else { 0 })%</td></tr>
          <tr><td>Shared Key Access Disabled (RBAC-only)</td><td class="mono">$noKeyAccessCount / $storageAcctCount</td><td class="mono">$(if ($storageAcctCount -gt 0) { [math]::Round($noKeyAccessCount / $storageAcctCount * 100, 0) } else { 0 })%</td></tr>
        </tbody>
      </table>
    </div>
"@
      if ($skippedAccounts -gt 0) {
        $secContent += @"
    <div class="info-card" style="margin-top: 12px; border-left-color: var(--color-warning);">
      <div class="info-card-text">$skippedAccounts storage account(s) were inaccessible (RBAC-only or insufficient permissions) and could not be enumerated for file shares and blob containers.</div>
    </div>
"@
      }
    }

    $securityPostureHtml = @"
  <details class="section" open>
    <summary>Security Posture</summary>
    <div class="section-content">
$secContent
    </div>
  </details>
"@
  }

  # ---- Section 05c: Additional Resources ----
  $additionalResourcesHtml = ""
  $hasAdditional = ($kvCount -gt 0 -or $aksCount -gt 0 -or $webAppCount -gt 0 -or $funcAppCount -gt 0 -or $acrCount -gt 0)
  if ($hasAdditional) {
    $addlContent = ""

    if ($kvCount -gt 0) {
      $kvRows = ""
      foreach ($kv in $keyVaults) {
        $safeKvName = _EscapeHtml $kv.Name
        $safeKvLoc = _EscapeHtml $kv.Location
        $safeKvSub = _EscapeHtml $kv.SubscriptionName
        $sdBadge = if ($kv.SoftDeleteEnabled) { "<span class=`"status-dot green`"></span>Enabled" } else { "<span class=`"status-dot orange`"></span>Disabled" }
        $ppBadge = if ($kv.PurgeProtection) { "<span class=`"status-dot green`"></span>Enabled" } else { "<span class=`"status-dot orange`"></span>Disabled" }
        $kvRows += "              <tr><td><strong>$safeKvName</strong></td><td>$safeKvSub</td><td>$safeKvLoc</td><td>$sdBadge</td><td>$ppBadge</td></tr>`n"
      }
      $addlContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Key Vaults ($kvCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Soft Delete</th><th>Purge Protection</th></tr></thead>
        <tbody>
$kvRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($aksCount -gt 0) {
      $aksRows = ""
      foreach ($aks in $aksClusters) {
        $safeAksName = _EscapeHtml $aks.Name
        $safeAksLoc = _EscapeHtml $aks.Location
        $safeAksSub = _EscapeHtml $aks.SubscriptionName
        $safeAksVer = _EscapeHtml $aks.KubernetesVersion
        $aksNodes = if ($null -ne $aks.TotalNodeCount) { $aks.TotalNodeCount } else { 0 }
        $aksRows += "              <tr><td><strong>$safeAksName</strong></td><td>$safeAksSub</td><td>$safeAksLoc</td><td>$safeAksVer</td><td class=`"mono`">$aksNodes</td></tr>`n"
      }
      if ($kvCount -gt 0) { $addlContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $addlContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">AKS Clusters ($aksCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>K8s Version</th><th>Nodes</th></tr></thead>
        <tbody>
$aksRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($webAppCount -gt 0) {
      $waRows = ""
      foreach ($app in $webApps) {
        $safeAppName = _EscapeHtml $app.Name
        $safeAppLoc = _EscapeHtml $app.Location
        $safeAppSub = _EscapeHtml $app.SubscriptionName
        $safeAppKind = _EscapeHtml $app.Kind
        $safeAppState = _EscapeHtml $app.State
        $httpsBadge = if ($app.HttpsOnly) { "<span class=`"status-dot green`"></span>Yes" } else { "<span class=`"status-dot orange`"></span>No" }
        $waRows += "              <tr><td><strong>$safeAppName</strong></td><td>$safeAppSub</td><td>$safeAppLoc</td><td>$safeAppKind</td><td>$safeAppState</td><td>$httpsBadge</td></tr>`n"
      }
      if ($kvCount -gt 0 -or $aksCount -gt 0) { $addlContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $addlContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Web Apps ($webAppCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Kind</th><th>State</th><th>HTTPS Only</th></tr></thead>
        <tbody>
$waRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($funcAppCount -gt 0) {
      $faRows = ""
      foreach ($app in $functionApps) {
        $safeAppName = _EscapeHtml $app.Name
        $safeAppLoc = _EscapeHtml $app.Location
        $safeAppSub = _EscapeHtml $app.SubscriptionName
        $safeAppState = _EscapeHtml $app.State
        $safeRuntime = _EscapeHtml $app.Runtime
        $httpsBadge = if ($app.HttpsOnly) { "<span class=`"status-dot green`"></span>Yes" } else { "<span class=`"status-dot orange`"></span>No" }
        $faRows += "              <tr><td><strong>$safeAppName</strong></td><td>$safeAppSub</td><td>$safeAppLoc</td><td>$safeAppState</td><td>$safeRuntime</td><td>$httpsBadge</td></tr>`n"
      }
      if ($kvCount -gt 0 -or $aksCount -gt 0 -or $webAppCount -gt 0) { $addlContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $addlContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Function Apps ($funcAppCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>State</th><th>Runtime</th><th>HTTPS Only</th></tr></thead>
        <tbody>
$faRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($acrCount -gt 0) {
      $acrRows = ""
      foreach ($reg in $containerRegistries) {
        $safeName = _EscapeHtml $reg.Name
        $safeLoc = _EscapeHtml $reg.Location
        $safeSub = _EscapeHtml $reg.SubscriptionName
        $safeSku = _EscapeHtml $reg.Sku
        $adminBadge = if ($reg.AdminEnabled) { "<span class=`"status-dot orange`"></span>Enabled" } else { "<span class=`"status-dot green`"></span>Disabled" }
        $acrRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeSku</td><td>$adminBadge</td></tr>`n"
      }
      $addlContent += "`n    <div style=`"margin-top: 24px;`"></div>`n"
      $addlContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Container Registries ($acrCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>SKU</th><th>Admin User</th></tr></thead>
        <tbody>
$acrRows
        </tbody>
      </table>
    </div>
"@
    }

    $additionalResourcesHtml = @"
  <details class="section">
    <summary>Additional Resources</summary>
    <div class="section-content">
$addlContent
    </div>
  </details>
"@
  }

  # ---- Section 06: SQL Databases ----
  $sqlHtml = ""
  $hasSqlData = ($sqlDbs.Count -gt 0 -or $sqlMIs.Count -gt 0)

  if ($hasSqlData) {
    $sqlSectionContent = ""

    # SQL Databases table
    if ($sqlDbs.Count -gt 0) {
      $sqlDbRows = ""
      foreach ($db in $sqlDbs) {
        $safeServer = _EscapeHtml $db.ServerName
        $safeDbName = _EscapeHtml $db.DatabaseName
        $safeEdition = _EscapeHtml $db.Edition
        $safeLoc = _EscapeHtml $db.Location
        $safeRedundancy = _EscapeHtml $db.BackupStorageRedundancy
        $dbMaxSize = if ($null -ne $db.MaxSizeGB) { $db.MaxSizeGB } else { 0 }
        $dbCurrentSize = if ($null -ne $db.CurrentSizeGB -and $db.CurrentSizeGB -gt 0) { "$($db.CurrentSizeGB) GB" } else { "&mdash;" }

        $sqlDbRows += "              <tr><td>$safeServer</td><td><strong>$safeDbName</strong></td><td>$safeEdition</td><td>$safeLoc</td><td class=`"mono`">$dbMaxSize GB</td><td class=`"mono`">$dbCurrentSize</td><td>$safeRedundancy</td></tr>`n"
      }

      $sqlSectionContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">SQL Databases ($($sqlDbs.Count))</div>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Server</th>
            <th>Database</th>
            <th>Edition</th>
            <th>Region</th>
            <th>Max Size</th>
            <th>Current Size</th>
            <th>Backup Redundancy</th>
          </tr>
        </thead>
        <tbody>
$sqlDbRows
        </tbody>
      </table>
    </div>
"@
    }

    # Managed Instances table
    if ($sqlMIs.Count -gt 0) {
      $miRows = ""
      foreach ($mi in $sqlMIs) {
        $safeMiName = _EscapeHtml $mi.ManagedInstance
        $safeMiLoc = _EscapeHtml $mi.Location
        $safeLicense = _EscapeHtml $mi.LicenseType
        $miVCores = if ($null -ne $mi.VCores) { $mi.VCores } else { 0 }
        $miStorageGB = if ($null -ne $mi.StorageSizeGB) { $mi.StorageSizeGB } else { 0 }

        $miRows += "              <tr><td><strong>$safeMiName</strong></td><td>$safeMiLoc</td><td class=`"mono`">$miVCores</td><td class=`"mono`">$miStorageGB GB</td><td>$safeLicense</td></tr>`n"
      }

      if ($sqlDbs.Count -gt 0) {
        $sqlSectionContent += "`n    <div style=`"margin-top: 32px;`"></div>`n"
      }

      $sqlSectionContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Managed Instances ($($sqlMIs.Count))</div>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Instance</th>
            <th>Region</th>
            <th>vCores</th>
            <th>Storage</th>
            <th>License</th>
          </tr>
        </thead>
        <tbody>
$miRows
        </tbody>
      </table>
    </div>
"@
    }

    $sqlHtml = @"
  <details class="section">
    <summary>SQL Databases</summary>
    <div class="section-content">
$sqlSectionContent
    </div>
  </details>
"@
  }
  else {
    $sqlHtml = @"
  <details class="section">
    <summary>SQL Databases</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">No SQL Workloads Discovered</div>
      <div class="info-card-text">No Azure SQL databases or managed instances were found in the scanned subscriptions.</div>
    </div>
    </div>
  </details>
"@
  }

  # ---- Section: PaaS Databases ----
  $paasHtml = ""
  $hasPaasData = ($pgCount -gt 0 -or $mysqlCount -gt 0 -or $cosmosCount -gt 0 -or $redisCount -gt 0)
  if ($hasPaasData) {
    $paasContent = ""

    if ($pgCount -gt 0) {
      $pgRows = ""
      foreach ($pg in $pgServers) {
        $safeName = _EscapeHtml $pg.Name
        $safeLoc = _EscapeHtml $pg.Location
        $safeSub = _EscapeHtml $pg.SubscriptionName
        $safeVer = _EscapeHtml $pg.Version
        $safeSku = _EscapeHtml $pg.Sku
        $safeTier = _EscapeHtml $pg.Tier
        $safeHA = _EscapeHtml $pg.HAMode
        $pgStorage = if ($null -ne $pg.StorageSizeGB) { $pg.StorageSizeGB } else { 0 }
        $pgRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeVer</td><td>$safeSku / $safeTier</td><td class=`"mono`">$pgStorage GB</td><td>$safeHA</td></tr>`n"
      }
      $paasContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">PostgreSQL Flexible Servers ($pgCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Version</th><th>SKU</th><th>Storage</th><th>HA Mode</th></tr></thead>
        <tbody>
$pgRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($mysqlCount -gt 0) {
      $myRows = ""
      foreach ($my in $mysqlServers) {
        $safeName = _EscapeHtml $my.Name
        $safeLoc = _EscapeHtml $my.Location
        $safeSub = _EscapeHtml $my.SubscriptionName
        $safeVer = _EscapeHtml $my.Version
        $safeSku = _EscapeHtml $my.Sku
        $safeTier = _EscapeHtml $my.Tier
        $safeHA = _EscapeHtml $my.HAMode
        $myStorage = if ($null -ne $my.StorageSizeGB) { $my.StorageSizeGB } else { 0 }
        $myRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeVer</td><td>$safeSku / $safeTier</td><td class=`"mono`">$myStorage GB</td><td>$safeHA</td></tr>`n"
      }
      if ($pgCount -gt 0) { $paasContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $paasContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">MySQL Flexible Servers ($mysqlCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Version</th><th>SKU</th><th>Storage</th><th>HA Mode</th></tr></thead>
        <tbody>
$myRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($cosmosCount -gt 0) {
      $cosmosRows = ""
      foreach ($c in $cosmosAccounts) {
        $safeName = _EscapeHtml $c.Name
        $safeLoc = _EscapeHtml $c.Location
        $safeSub = _EscapeHtml $c.SubscriptionName
        $safeKind = _EscapeHtml $c.Kind
        $safeCon = _EscapeHtml $c.ConsistencyLevel
        $safeLocs = _EscapeHtml $c.Locations
        $mrBadge = if ($c.MultiRegionWrite) { "<span class=`"status-dot green`"></span>Yes" } else { "No" }
        $cosmosRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeKind</td><td>$safeCon</td><td>$safeLocs</td><td>$mrBadge</td></tr>`n"
      }
      if ($pgCount -gt 0 -or $mysqlCount -gt 0) { $paasContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $paasContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Cosmos DB Accounts ($cosmosCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Kind</th><th>Consistency</th><th>Locations</th><th>Multi-Region Write</th></tr></thead>
        <tbody>
$cosmosRows
        </tbody>
      </table>
    </div>
    <div class="info-card" style="margin-top: 8px; border-left-color: var(--color-info);">
      <div class="info-card-text">Cosmos DB storage size is not available via ARM APIs. Use Azure Monitor metrics or the Azure portal to determine actual data sizes for backup sizing.</div>
    </div>
"@
    }

    if ($redisCount -gt 0) {
      $redisRows = ""
      foreach ($r in $redisCaches) {
        $safeName = _EscapeHtml $r.Name
        $safeLoc = _EscapeHtml $r.Location
        $safeSub = _EscapeHtml $r.SubscriptionName
        $safeSku = _EscapeHtml $r.SkuName
        $safeVer = _EscapeHtml $r.Version
        $rCap = if ($null -ne $r.SkuCapacity) { $r.SkuCapacity } else { 0 }
        $rShards = if ($null -ne $r.ShardCount -and $r.ShardCount -gt 0) { $r.ShardCount } else { "&mdash;" }
        $redisRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeSku</td><td class=`"mono`">$rCap</td><td class=`"mono`">$rShards</td><td>$safeVer</td></tr>`n"
      }
      if ($pgCount -gt 0 -or $mysqlCount -gt 0 -or $cosmosCount -gt 0) { $paasContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $paasContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Azure Cache for Redis ($redisCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>SKU</th><th>Capacity</th><th>Shards</th><th>Version</th></tr></thead>
        <tbody>
$redisRows
        </tbody>
      </table>
    </div>
"@
    }

    $paasHtml = @"
  <details class="section">
    <summary>PaaS Databases</summary>
    <div class="section-content">
$paasContent
    </div>
  </details>
"@
  }

  # ---- Section: Network Topology ----
  $networkHtml = ""
  if ($vnetCount -gt 0 -or $peCount -gt 0) {
    $netContent = ""

    if ($vnetCount -gt 0) {
      $vnetRows = ""
      foreach ($vn in $vnetsArr) {
        $safeName = _EscapeHtml $vn.Name
        $safeLoc = _EscapeHtml $vn.Location
        $safeSub = _EscapeHtml $vn.SubscriptionName
        $safeAddr = _EscapeHtml $vn.AddressSpace
        $safePeers = _EscapeHtml $vn.Peerings
        $vnSubnets = if ($null -ne $vn.SubnetCount) { $vn.SubnetCount } else { 0 }
        $vnPeering = if ($null -ne $vn.PeeringCount) { $vn.PeeringCount } else { 0 }
        $vnetRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td class=`"mono`">$safeAddr</td><td class=`"mono`">$vnSubnets</td><td class=`"mono`">$vnPeering</td><td>$safePeers</td></tr>`n"
      }
      $netContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Virtual Networks ($vnetCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Address Space</th><th>Subnets</th><th>Peerings</th><th>Peering Details</th></tr></thead>
        <tbody>
$vnetRows
        </tbody>
      </table>
    </div>
"@
    }

    if ($peCount -gt 0) {
      $peRows = ""
      foreach ($endpoint in $privateEndpointsArr) {
        $safeName = _EscapeHtml $endpoint.Name
        $safeLoc = _EscapeHtml $endpoint.Location
        $safeSub = _EscapeHtml $endpoint.SubscriptionName
        $safeTarget = _EscapeHtml $endpoint.TargetResource
        $safeSubnet = _EscapeHtml $endpoint.Subnet
        $peRows += "              <tr><td><strong>$safeName</strong></td><td>$safeSub</td><td>$safeLoc</td><td>$safeTarget</td><td>$safeSubnet</td></tr>`n"
      }
      if ($vnetCount -gt 0) { $netContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" }
      $netContent += @"
    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Private Endpoints ($peCount)</div>
    <div class="table-container">
      <table>
        <thead><tr><th>Name</th><th>Subscription</th><th>Region</th><th>Target Resource</th><th>Subnet</th></tr></thead>
        <tbody>
$peRows
        </tbody>
      </table>
    </div>
"@
    }

    $networkHtml = @"
  <details class="section">
    <summary>Network Topology</summary>
    <div class="section-content">
$netContent
    </div>
  </details>
"@
  }

  # ---- Section 06: Azure Backup Coverage ----
  # Protection gap bars
  $gapBarsHtml = ""

  if ($totalVMs -gt 0) {
    $vmPct = [math]::Min([math]::Round(($protectedVMs / $totalVMs) * 100, 0), 100)
    $vmPctWidth = if ($vmPct -lt 1 -and $protectedVMs -gt 0) { 1 } else { $vmPct }
    $gapBarsHtml += @"
    <div class="gap-bar-container">
      <div class="gap-bar-label">Virtual Machines: $protectedVMs / $totalVMs protected (${vmPct}%)</div>
      <div class="gap-bar-track">
        <div class="gap-bar-fill" style="width: ${vmPctWidth}%">${vmPct}%</div>
      </div>
    </div>
"@
  }

  if ($totalSQLDbs -gt 0) {
    $sqlPctBar = [math]::Min([math]::Round(($protectedSQL / $totalSQLDbs) * 100, 0), 100)
    $sqlPctWidth = if ($sqlPctBar -lt 1 -and $protectedSQL -gt 0) { 1 } else { $sqlPctBar }
    $gapBarsHtml += @"
    <div class="gap-bar-container">
      <div class="gap-bar-label">SQL Databases: $protectedSQL / $totalSQLDbs protected (${sqlPctBar}%)</div>
      <div class="gap-bar-track">
        <div class="gap-bar-fill" style="width: ${sqlPctWidth}%">${sqlPctBar}%</div>
      </div>
    </div>
"@
  }

  if ($filesCount -gt 0) {
    $afsPctBar = [math]::Min([math]::Round(($protectedAFS / $filesCount) * 100, 0), 100)
    $afsPctWidth = if ($afsPctBar -lt 1 -and $protectedAFS -gt 0) { 1 } else { $afsPctBar }
    $gapBarsHtml += @"
    <div class="gap-bar-container">
      <div class="gap-bar-label">Azure File Shares: $protectedAFS / $filesCount protected (${afsPctBar}%)</div>
      <div class="gap-bar-track">
        <div class="gap-bar-fill" style="width: ${afsPctWidth}%">${afsPctBar}%</div>
      </div>
    </div>
"@
  }

  # Vault detail table
  $vaultTableRows = ""
  foreach ($v in $vaults) {
    $safeVaultName = _EscapeHtml $v.VaultName
    $safeVaultLoc = _EscapeHtml $v.Location
    $safeSoftDelete = _EscapeHtml "$($v.SoftDeleteState)"
    $safeImmutability = _EscapeHtml "$($v.Immutability)"
    $vProtVMs = if ($null -ne $v.ProtectedVMs) { $v.ProtectedVMs } else { 0 }
    $vProtSQL = if ($null -ne $v.ProtectedSQL) { $v.ProtectedSQL } else { 0 }
    $vProtAFS = if ($null -ne $v.ProtectedFileShares) { $v.ProtectedFileShares } else { 0 }

    $vaultTableRows += "              <tr><td><strong>$safeVaultName</strong></td><td>$safeVaultLoc</td><td>$safeSoftDelete</td><td>$safeImmutability</td><td class=`"mono`">$vProtVMs</td><td class=`"mono`">$vProtSQL</td><td class=`"mono`">$vProtAFS</td></tr>`n"
  }

  # Vault security observations
  $vaultObservations = ""
  foreach ($f in $findings) {
    if ($f.Section -eq "Security") {
      $sevClass = $f.Severity.ToLower()
      $safeFTitle = _EscapeHtml $f.Title
      $safeFDesc = _EscapeHtml $f.Description
      $vaultObservations += @"
    <div class="finding-card severity-$sevClass">
      <div class="finding-card-title">$safeFTitle</div>
      <div class="finding-card-detail">$safeFDesc</div>
    </div>
"@
    }
  }

  $backupCoverageContent = $gapBarsHtml
  if ($vaults.Count -gt 0) {
    $backupCoverageContent += @"

    <div style="margin-top: 24px; font-weight: 600; font-size: 14px; margin-bottom: 12px;">Recovery Services Vaults ($vaultsCount)</div>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Vault Name</th>
            <th>Region</th>
            <th>Soft Delete</th>
            <th>Immutability</th>
            <th>Protected VMs</th>
            <th>Protected SQL</th>
            <th>Protected AFS</th>
          </tr>
        </thead>
        <tbody>
$vaultTableRows
        </tbody>
      </table>
    </div>
"@
  }
  elseif ($totalVMs -gt 0 -or $totalSQLDbs -gt 0) {
    $backupCoverageContent += @"
    <div class="info-card" style="border-left-color: var(--color-danger);">
      <div class="info-card-title">No Recovery Services Vaults</div>
      <div class="info-card-text">No backup vaults were found in the scanned subscriptions. Workloads are not protected by Azure Backup.</div>
    </div>
"@
  }

  if ($vaultObservations -ne "") {
    $backupCoverageContent += "`n    <div style=`"margin-top: 24px;`"></div>`n" + $vaultObservations
  }

  $backupCoverageHtml = @"
  <details class="section" open>
    <summary>Azure Backup Coverage</summary>
    <div class="section-content">
$backupCoverageContent
    </div>
  </details>
"@

  # ---- Section 07: Source Data Summary ----
  $sourceSummaryTableHtml = @"
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Component</th>
            <th>Value</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>VM Source Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalVMStorageGB))</td>
            <td>Total provisioned disk capacity across $totalVMs VMs</td>
          </tr>
          <tr>
            <td><strong>VMSS Source Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalVMSSStorageGB))</td>
            <td>$totalVMSS scale sets ($totalVMSSInstances instances)</td>
          </tr>
          <tr>
            <td><strong>SQL Source Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalSQLStorageGB))</td>
            <td>$totalSQLDbs databases + $totalSQLMIs managed instances</td>
          </tr>
          <tr>
            <td><strong>Azure Files Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalFileShareStorageGB))</td>
            <td>$filesCount file shares (quota-based)</td>
          </tr>
          <tr>
            <td><strong>PostgreSQL Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $pgStorageGB))</td>
            <td>$pgCount PostgreSQL flexible servers</td>
          </tr>
          <tr>
            <td><strong>MySQL Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $mysqlStorageGB))</td>
            <td>$mysqlCount MySQL flexible servers</td>
          </tr>
          <tr>
            <td><strong>Orphaned Disk Storage</strong></td>
            <td class="mono">$(_EscapeHtml (_FormatStorageGB $orphanedDiskStorageGB))</td>
            <td>$orphanedDiskCount unattached managed disks</td>
          </tr>
          <tr>
            <td><strong>Total Source Data</strong></td>
            <td class="mono" style="color: var(--ms-blue); font-weight: 700;">$(_EscapeHtml (_FormatStorageGB $VeeamSizing.TotalSourceStorageGB))</td>
            <td>Combined VM + VMSS + SQL + Files + PaaS + Orphaned Disks</td>
          </tr>
        </tbody>
      </table>
    </div>
"@

  # Tiered recommendations
  $recsHtml = ""
  $tierOrder = @(
    @{ Name = "Immediate"; Phase = "Phase 1: Immediate Actions" }
    @{ Name = "Short-Term"; Phase = "Phase 2: Short-Term Improvements" }
    @{ Name = "Strategic"; Phase = "Phase 3: Strategic Initiatives" }
  )
  foreach ($tierInfo in $tierOrder) {
    $tierRecs = @($recommendations | Where-Object { $_.Tier -eq $tierInfo.Name })
    if ($tierRecs.Count -eq 0) { continue }
    $tierClass = $tierInfo.Name.ToLower() -replace ' ', '-'
    $safePhase = _EscapeHtml $tierInfo.Phase
    $recsHtml += "    <div class=`"rec-phase-header`">$safePhase</div>`n"
    foreach ($r in $tierRecs) {
      $safeRecAction = _EscapeHtml $r.Action
      $safeRecTier = _EscapeHtml $r.Tier
      $recsHtml += @"
      <div class="recommendation-card tier-$tierClass">
        <div class="priority-badge $tierClass">$safeRecTier</div>
        <div class="rec-action">$safeRecAction</div>
      </div>
"@
    }
  }

  $sourceSummaryHtml = @"
  <details class="section" open>
    <summary>Source Data Summary</summary>
    <div class="section-content">
$sourceSummaryTableHtml
$recsHtml
    <div class="info-card" style="margin-top: 16px; border-left-color: var(--color-info);">
      <div class="info-card-title">Next Step</div>
      <div class="info-card-text">
        Use these source totals with the Veeam Backup for Azure sizing calculator to determine snapshot storage and repository capacity requirements for your environment.
      </div>
    </div>
    </div>
  </details>
"@

  # ---- Section 08: Subscriptions ----
  $subTableRows = ""
  foreach ($sub in $Subscriptions) {
    $safeName = _EscapeHtml $sub.Name
    $safeId = _EscapeHtml $sub.Id
    $subTableRows += "              <tr><td><strong>$safeName</strong></td><td class=`"mono`">$safeId</td></tr>`n"
  }

  $subscriptionsHtml = @"
  <details class="section">
    <summary>Subscriptions</summary>
    <div class="section-content">
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Subscription Name</th>
            <th>Subscription ID</th>
          </tr>
        </thead>
        <tbody>
$subTableRows
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@

  # ---- Section 09: Methodology ----
  # Filter metadata audit trail
  $filterAuditHtml = ""
  if ($null -ne $FilterMetadata) {
    $safeRegionFilter = _EscapeHtml "$($FilterMetadata.Region)"
    $safeTagFilter = _EscapeHtml "$($FilterMetadata.TagFilter)"
    $safeSubFilter = _EscapeHtml "$($FilterMetadata.Subscriptions)"
    $safeTimestamp = _EscapeHtml "$($FilterMetadata.RunTimestamp)"
    $safePsVersion = _EscapeHtml "$($FilterMetadata.PowerShellVersion)"
    $calcBlobs = if ($FilterMetadata.CalculateBlobSizes) { "Yes" } else { "No" }
    $filterAuditHtml = @"
    <div class="info-card" style="margin-top: 16px;">
      <div class="info-card-title">Assessment Parameters</div>
      <div class="info-card-text">
        <table style="font-size: 13px; width: auto;">
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">Run Timestamp</td><td>$safeTimestamp</td></tr>
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">Region Filter</td><td>$safeRegionFilter</td></tr>
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">Tag Filter</td><td>$safeTagFilter</td></tr>
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">Subscriptions</td><td>$safeSubFilter</td></tr>
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">Blob Size Calculation</td><td>$calcBlobs</td></tr>
          <tr><td style="padding: 4px 16px 4px 0; font-weight: 600;">PowerShell Version</td><td>$safePsVersion</td></tr>
        </table>
      </div>
    </div>
"@
  }

  $methodologyHtml = @"
  <details class="section">
    <summary>Methodology</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">Data Collection</div>
      <div class="info-card-text">
        This assessment uses Azure Resource Manager APIs to inventory VMs, VMSS, SQL databases, PaaS databases (PostgreSQL, MySQL, Cosmos DB, Redis), storage accounts, Key Vaults, AKS clusters, container registries, web apps, function apps, messaging services (Event Hubs, Service Bus), Logic Apps, Data Factory, API Management, virtual networks, and private endpoints, along with existing Azure Backup configuration across $subCount subscription(s). Disk encryption status, managed identities, and NSG exposure are analyzed for security posture assessment. All data is read-only and no changes are made to your environment.
      </div>
    </div>
$filterAuditHtml
    <div class="info-card" style="margin-top: 16px;">
      <div class="info-card-title">Backup Coverage Score</div>
      <div class="info-card-text">
        The coverage score is a weighted composite: <code>VM coverage (60%) + SQL coverage (30%) + File Share coverage (10%)</code>. Only categories with discovered workloads are included in the calculation. Protected workload counts are derived from Recovery Services Vault metadata.
      </div>
    </div>
    <div class="info-card" style="border-left-color: var(--color-warning);">
      <div class="info-card-title">Disclaimer</div>
      <div class="info-card-text">
        This is a community-maintained discovery tool, not an official Veeam product. Source data collected here is intended for use with external Veeam sizing calculators. Actual storage requirements depend on backup policies, data change rates, compression ratios, and workload characteristics.
      </div>
    </div>
    </div>
  </details>
"@

  # ---- Footer ----
  $footerHtml = @"
  <footer class="footer">
    <div class="footer-conf">This report is confidential and intended for authorized recipients only.</div>
    <div class="footer-conf">Community-maintained tool &mdash; not an official Veeam product.</div>
    <div class="footer-stamp">$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC | Veeam Backup for Azure Sizing Tool</div>
  </footer>
"@

  # =========================================================================
  # 5. Assemble final HTML
  # =========================================================================
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
<title>Veeam Backup for Azure - Discovery &amp; Inventory</title>
<style>
$cssBlock
</style>
</head>
<body>
$headerHtml
<div class="container">
$detailsBarHtml
$kpiHtml
$execSummaryHtml
$workloadDistHtml
$vmInventoryHtml
$vmsByRegionHtml
$vmssHtml
$securityPostureHtml
$additionalResourcesHtml
$networkHtml
$sqlHtml
$paasHtml
$backupCoverageHtml
$sourceSummaryHtml
$subscriptionsHtml
$methodologyHtml
$footerHtml
</div>
</body>
</html>
"@

  # =========================================================================
  # 6. Write file and return path
  # =========================================================================
  $htmlPath = Join-Path $OutputPath "Veeam-Azure-Sizing-Report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8

  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}
