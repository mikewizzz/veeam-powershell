# SPDX-License-Identifier: MIT
# =========================================================================
# Exports.ps1 - CSV exports, JSON bundle, log export, and ZIP archive
# =========================================================================

<#
.SYNOPSIS
  Exports all health check data to CSV files and a JSON bundle.
#>
function Export-HealthCheckData {
  param(
    [Parameter(Mandatory=$true)]$HealthScore,
    [Parameter(Mandatory=$true)]$SystemData,
    [Parameter(Mandatory=$true)]$LicenseData,
    $ConfigCheckData,
    $ProtectionData,
    $UnprotectedResources,
    $PolicyData,
    $SLAReport,
    $FailedSessions,
    $Repositories,
    $Workers,
    $ProtectedItems,
    $StorageUsage
  )

  Write-ProgressStep -Activity "Exporting Data" -Status "Writing CSV files..."

  # =============================
  # Findings export (always)
  # =============================
  $findingsPath = Join-Path $OutputPath "health_check_findings.csv"
  if ($script:Findings.Count -gt 0) {
    @($script:Findings.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $findingsPath
    Write-Log "Exported $($script:Findings.Count) findings" -Level "INFO"
  }

  # =============================
  # Health score summary
  # =============================
  $scorePath = Join-Path $OutputPath "health_score_summary.csv"
  $scoreRows = New-Object System.Collections.Generic.List[object]
  $scoreRows.Add([PSCustomObject]@{
    Category = "OVERALL"
    Score = $HealthScore.OverallScore
    Grade = $HealthScore.Grade
    Weight = "1.0"
  })
  foreach ($cat in $script:CategoryWeights.Keys) {
    $catScore = 100
    if ($HealthScore.CategoryScores.ContainsKey($cat)) {
      $catScore = $HealthScore.CategoryScores[$cat]
    }
    $catGrade = Get-ScoreGrade -Score $catScore
    $scoreRows.Add([PSCustomObject]@{
      Category = $cat
      Score = $catScore
      Grade = $catGrade.Grade
      Weight = "$($script:CategoryWeights[$cat])"
    })
  }
  @($scoreRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $scorePath

  # =============================
  # Protection coverage
  # =============================
  if ($null -ne $ProtectionData) {
    $covPath = Join-Path $OutputPath "protection_coverage.csv"
    $covRows = New-Object System.Collections.Generic.List[object]
    $covRows.Add([PSCustomObject]@{
      ResourceType = "Virtual Machines"
      Total = $ProtectionData.virtualMachinesTotalCount
      Protected = $ProtectionData.virtualMachinesProtectedCount
      Unprotected = [int]$ProtectionData.virtualMachinesTotalCount - [int]$ProtectionData.virtualMachinesProtectedCount
      CoveragePercent = if ([int]$ProtectionData.virtualMachinesTotalCount -gt 0) { [math]::Round(([int]$ProtectionData.virtualMachinesProtectedCount / [int]$ProtectionData.virtualMachinesTotalCount) * 100, 1) } else { "N/A" }
    })
    $covRows.Add([PSCustomObject]@{
      ResourceType = "SQL Databases"
      Total = $ProtectionData.sqlDatabasesTotalCount
      Protected = $ProtectionData.sqlDatabasesProtectedCount
      Unprotected = [int]$ProtectionData.sqlDatabasesTotalCount - [int]$ProtectionData.sqlDatabasesProtectedCount
      CoveragePercent = if ([int]$ProtectionData.sqlDatabasesTotalCount -gt 0) { [math]::Round(([int]$ProtectionData.sqlDatabasesProtectedCount / [int]$ProtectionData.sqlDatabasesTotalCount) * 100, 1) } else { "N/A" }
    })
    $covRows.Add([PSCustomObject]@{
      ResourceType = "File Shares"
      Total = $ProtectionData.fileSharesTotalCount
      Protected = $ProtectionData.fileSharesProtectedCount
      Unprotected = [int]$ProtectionData.fileSharesTotalCount - [int]$ProtectionData.fileSharesProtectedCount
      CoveragePercent = if ([int]$ProtectionData.fileSharesTotalCount -gt 0) { [math]::Round(([int]$ProtectionData.fileSharesProtectedCount / [int]$ProtectionData.fileSharesTotalCount) * 100, 1) } else { "N/A" }
    })
    @($covRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $covPath
  }

  # =============================
  # Unprotected VMs (curated columns)
  # =============================
  if ($null -ne $UnprotectedResources -and @($UnprotectedResources.VMs).Count -gt 0) {
    $vmRows = New-Object System.Collections.Generic.List[object]
    foreach ($vm in @($UnprotectedResources.VMs)) {
      $vmRows.Add([PSCustomObject]@{
        Name             = $vm.name
        VMSize           = $vm.vmSize
        TotalDiskGB      = $vm.totalSizeInGB
        OSType           = $vm.osType
        Region           = $vm.regionName
        ResourceGroup    = $vm.resourceGroupName
        Subscription     = $vm.subscriptionName
        SubscriptionId   = $vm.subscriptionId
        PrivateIP        = $vm.privateIP
        PublicIP         = $vm.publicIP
        AvailabilityZone = $vm.availabilityZone
      })
    }
    @($vmRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "unprotected_vms.csv")
    Write-Log "Exported $($vmRows.Count) unprotected VMs with size details" -Level "INFO"
  }

  # =============================
  # Unprotected SQL (curated columns)
  # =============================
  if ($null -ne $UnprotectedResources -and @($UnprotectedResources.SQL).Count -gt 0) {
    $sqlRows = New-Object System.Collections.Generic.List[object]
    foreach ($db in @($UnprotectedResources.SQL)) {
      $sqlRows.Add([PSCustomObject]@{
        DatabaseName    = $db.name
        ServerName      = $db.serverName
        SizeMB          = $db.sizeInMb
        DatabaseType    = $db.databaseType
        Status          = $db.status
        Region          = $db.regionName
        ResourceGroup   = $db.resourceGroupName
        SubscriptionId  = $db.subscriptionId
        HasElasticPool  = $db.hasElasticPool
      })
    }
    @($sqlRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "unprotected_sql.csv")
  }

  # =============================
  # Unprotected File Shares (curated columns)
  # =============================
  if ($null -ne $UnprotectedResources -and @($UnprotectedResources.FileShares).Count -gt 0) {
    $fsRows = New-Object System.Collections.Generic.List[object]
    foreach ($fs in @($UnprotectedResources.FileShares)) {
      $sizeGB = 0
      if ($fs.size) { $sizeGB = [math]::Round([double]$fs.size / 1073741824, 2) }
      $fsRows.Add([PSCustomObject]@{
        Name            = $fs.name
        StorageAccount  = $fs.storageAccountName
        SizeGB          = $sizeGB
        AccessTier      = $fs.accessTier
        Region          = $fs.regionName
        ResourceGroup   = $fs.resourceGroupName
        SubscriptionId  = $fs.subscriptionId
      })
    }
    @($fsRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "unprotected_fileshares.csv")
  }

  # =============================
  # Unprotected Cosmos DB
  # =============================
  if ($null -ne $UnprotectedResources -and @($UnprotectedResources.CosmosDB).Count -gt 0) {
    $UnprotectedResources.CosmosDB | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "unprotected_cosmosdb.csv")
  }

  # =============================
  # Protected items inventory (VMs with last backup, restore points)
  # =============================
  if ($null -ne $ProtectedItems -and @($ProtectedItems.VMs).Count -gt 0) {
    $protVmRows = New-Object System.Collections.Generic.List[object]
    foreach ($vm in @($ProtectedItems.VMs)) {
      $rpCount = ""
      if ($null -ne $vm.protectionState -and $null -ne $vm.protectionState.restorePointCount) {
        $rpCount = $vm.protectionState.restorePointCount
      }
      $subName = ""
      if ($null -ne $vm.subscription) { $subName = $vm.subscription.name }
      $rgName = ""
      if ($null -ne $vm.resourceGroup) { $rgName = $vm.resourceGroup.name }
      $protVmRows.Add([PSCustomObject]@{
        Name             = $vm.name
        VMSize           = $vm.vmSize
        TotalDiskGB      = $vm.totalSizeInGB
        OSType           = $vm.osType
        Region           = $vm.regionName
        ResourceGroup    = $rgName
        Subscription     = $subName
        LastBackup       = $vm.lastBackup
        RestorePoints    = $rpCount
        AvailabilityZone = $vm.availabilityZone
      })
    }
    @($protVmRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "protected_vms.csv")
    Write-Log "Exported $($protVmRows.Count) protected VMs with backup details" -Level "INFO"
  }

  # Protected SQL with last backup
  if ($null -ne $ProtectedItems -and @($ProtectedItems.SQL).Count -gt 0) {
    $protSqlRows = New-Object System.Collections.Generic.List[object]
    foreach ($db in @($ProtectedItems.SQL)) {
      $rpCount = ""
      if ($null -ne $db.protectionState -and $null -ne $db.protectionState.restorePointCount) {
        $rpCount = $db.protectionState.restorePointCount
      }
      $subName = ""
      if ($null -ne $db.subscription) { $subName = $db.subscription.name }
      $serverName = ""
      if ($null -ne $db.sqlServer) { $serverName = $db.sqlServer.name }
      $protSqlRows.Add([PSCustomObject]@{
        DatabaseName  = $db.name
        ServerName    = $serverName
        SizeMB        = $db.sizeInMb
        Subscription  = $subName
        LastBackup    = $db.lastBackup
        RestorePoints = $rpCount
      })
    }
    @($protSqlRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "protected_sql.csv")
  }

  # Protected File Shares with last backup
  if ($null -ne $ProtectedItems -and @($ProtectedItems.FileShares).Count -gt 0) {
    $protFsRows = New-Object System.Collections.Generic.List[object]
    foreach ($fs in @($ProtectedItems.FileShares)) {
      $rpCount = ""
      if ($null -ne $fs.protectionState -and $null -ne $fs.protectionState.restorePointCount) {
        $rpCount = $fs.protectionState.restorePointCount
      }
      $subName = ""
      if ($null -ne $fs.subscription) { $subName = $fs.subscription.name }
      $saName = ""
      if ($null -ne $fs.storageAccount) { $saName = $fs.storageAccount.name }
      $protFsRows.Add([PSCustomObject]@{
        Name            = $fs.name
        StorageAccount  = $saName
        SizeMB          = $fs.sizeInMb
        Subscription    = $subName
        LastBackup      = $fs.lastBackup
        RestorePoints   = $rpCount
      })
    }
    @($protFsRows.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "protected_fileshares.csv")
  }

  # =============================
  # Storage usage summary
  # =============================
  if ($null -ne $StorageUsage) {
    $storagePath = Join-Path $OutputPath "storage_usage.csv"
    $storageRow = [PSCustomObject]@{
      TotalUsage    = $StorageUsage.totalUsage
      HotUsage      = $StorageUsage.hotUsage
      CoolUsage     = $StorageUsage.coolUsage
      ArchiveUsage  = $StorageUsage.archiveUsage
      SnapshotCount = $StorageUsage.snapshotsCount
      BackupCount   = $StorageUsage.backupCount
      ArchiveCount  = $StorageUsage.archivesCount
    }
    @($storageRow) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $storagePath
  }

  # =============================
  # Policies
  # =============================
  if ($null -ne $PolicyData) {
    $allPolicies = New-Object System.Collections.Generic.List[object]
    $policyTypes = @(
      @{ Items = $PolicyData.VM;       Type = "VM" }
      @{ Items = $PolicyData.SQL;      Type = "SQL" }
      @{ Items = $PolicyData.FileShare; Type = "FileShare" }
      @{ Items = $PolicyData.CosmosDB; Type = "CosmosDB" }
    )
    foreach ($pt in $policyTypes) {
      foreach ($p in @($pt.Items)) {
        $allPolicies.Add([PSCustomObject]@{
          PolicyType = $pt.Type
          Name = $p.name
          IsEnabled = $p.isEnabled
          BackupStatus = $p.backupStatus
          SnapshotStatus = $p.snapshotStatus
          NextExecution = $p.nextExecutionTime
        })
      }
    }
    if ($allPolicies.Count -gt 0) {
      @($allPolicies.GetEnumerator()) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "policy_status.csv")
    }
  }

  # =============================
  # SLA compliance
  # =============================
  if (@($SLAReport).Count -gt 0) {
    $SLAReport | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "sla_compliance.csv")
  }

  # =============================
  # Failed sessions
  # =============================
  if (@($FailedSessions).Count -gt 0) {
    $FailedSessions | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "session_failures.csv")
  }

  # =============================
  # Repositories
  # =============================
  if (@($Repositories).Count -gt 0) {
    $Repositories | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "repository_health.csv")
  }

  # =============================
  # Workers
  # =============================
  if (@($Workers).Count -gt 0) {
    $Workers | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "worker_health.csv")
  }

  # =============================
  # License resources
  # =============================
  if (@($LicenseData.Resources).Count -gt 0) {
    $LicenseData.Resources | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "license_resources.csv")
  }

  # =============================
  # Configuration check
  # =============================
  if ($null -ne $ConfigCheckData -and $ConfigCheckData.logLine) {
    $ConfigCheckData.logLine | Export-Csv -NoTypeInformation -Encoding UTF8 -Path (Join-Path $OutputPath "configuration_check.csv")
  }

  # =============================
  # System info
  # =============================
  $sysInfoPath = Join-Path $OutputPath "system_info.csv"
  $sysInfo = [PSCustomObject]@{
    ServerVersion = if ($SystemData.About) { $SystemData.About.serverVersion } else { "N/A" }
    WorkerVersion = if ($SystemData.About) { $SystemData.About.workerVersion } else { "N/A" }
    FlrVersion = if ($SystemData.About) { $SystemData.About.flrVersion } else { "N/A" }
    SystemState = if ($SystemData.Status) { $SystemData.Status.state } else { "N/A" }
    ServerName = if ($SystemData.ServerInfo) { $SystemData.ServerInfo.serverName } else { "N/A" }
    AzureRegion = if ($SystemData.ServerInfo) { $SystemData.ServerInfo.azureRegionName } else { "N/A" }
    ResourceGroup = if ($SystemData.ServerInfo) { $SystemData.ServerInfo.resourceGroup } else { "N/A" }
  }
  @($sysInfo) | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sysInfoPath

  # =============================
  # JSON bundle
  # =============================
  $jsonPath = Join-Path $OutputPath "health_check_data.json"
  $jsonBundle = @{
    GeneratedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    Server = $script:BaseUrl
    HealthScore = @{
      Overall = $HealthScore.OverallScore
      Grade = $HealthScore.Grade
      Categories = $HealthScore.CategoryScores
    }
    FindingCounts = @{
      Healthy = @($script:Findings | Where-Object { $_.Status -eq "Healthy" }).Count
      Warning = @($script:Findings | Where-Object { $_.Status -eq "Warning" }).Count
      Critical = @($script:Findings | Where-Object { $_.Status -eq "Critical" }).Count
    }
  }
  $jsonBundle | ConvertTo-Json -Depth 5 | Out-File -FilePath $jsonPath -Encoding UTF8

  Write-Log "Exported CSV files to: $OutputPath" -Level "SUCCESS"
}

<#
.SYNOPSIS
  Exports the execution log entries to CSV.
#>
function Export-LogData {
  try {
    $logPath = Join-Path $OutputPath "execution_log.csv"
    $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath
  }
  catch {
    Write-Host "Warning: Failed to export log data: $($_.Exception.Message)" -ForegroundColor Yellow
  }
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

  try {
    Remove-Item -Path $OutputPath -Recurse -Force -ErrorAction Stop
    Write-Log "Cleaned up uncompressed output: $OutputPath" -Level "INFO"
  }
  catch {
    Write-Log "Could not remove uncompressed output: $($_.Exception.Message)" -Level "WARNING"
  }

  return $zipPath
}
