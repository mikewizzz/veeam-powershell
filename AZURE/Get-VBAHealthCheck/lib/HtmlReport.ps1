# SPDX-License-Identifier: MIT
# =========================================================================
# HtmlReport.ps1 - Executive-grade HTML report (Fluent Design System)
# =========================================================================
# CSS-only visuals, no JavaScript, no external dependencies.
# XSS-safe via _EscapeHtml on all dynamic strings.
# =========================================================================

<#
.SYNOPSIS
  Generates the full HTML health check report.
.OUTPUTS
  Path to the generated HTML file.
#>
function New-HtmlReport {
  param(
    [Parameter(Mandatory=$true)]$HealthScore,
    [Parameter(Mandatory=$true)]$SystemData,
    [Parameter(Mandatory=$true)]$LicenseData,
    $ConfigCheckData,
    $ProtectionData,
    $UnprotectedResources,
    $PolicyData,
    $SLAReport,
    $SessionsSummary,
    $FailedSessions,
    $Repositories,
    $Workers,
    $WorkerStats,
    $Bottlenecks,
    $ConfigBackup,
    $ProtectedItems,
    $StorageUsage,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][datetime]$StartTime
  )

  Write-ProgressStep -Activity "Generating HTML Report" -Status "Building executive-grade report..."

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  # Finding counts
  $healthyCount = @($script:Findings | Where-Object { $_.Status -eq "Healthy" }).Count
  $warningCount = @($script:Findings | Where-Object { $_.Status -eq "Warning" }).Count
  $criticalCount = @($script:Findings | Where-Object { $_.Status -eq "Critical" }).Count

  # =============================
  # Version info
  # =============================
  $serverVersion = "N/A"
  $workerVersion = "N/A"
  $flrVersion = "N/A"
  $appRegion = "N/A"
  $appName = "N/A"
  $appRg = "N/A"
  if ($null -ne $SystemData.About) {
    $serverVersion = _EscapeHtml "$($SystemData.About.serverVersion)"
    $workerVersion = _EscapeHtml "$($SystemData.About.workerVersion)"
    $flrVersion = _EscapeHtml "$($SystemData.About.flrVersion)"
  }
  if ($null -ne $SystemData.ServerInfo) {
    $appRegion = _EscapeHtml "$($SystemData.ServerInfo.azureRegionName)"
    $appName = _EscapeHtml "$($SystemData.ServerInfo.serverName)"
    $appRg = _EscapeHtml "$($SystemData.ServerInfo.resourceGroup)"
  }

  # =============================
  # Gauge chart
  # =============================
  $gaugeChart = New-SvgGaugeChart -Score ([int]$HealthScore.OverallScore) -Label "Health Score"

  # =============================
  # Category score cards
  # =============================
  $categoryCards = ""
  $sortedCats = $script:CategoryWeights.GetEnumerator() | Sort-Object { $_.Value } -Descending
  foreach ($catEntry in $sortedCats) {
    $catName = $catEntry.Key
    $catWeight = [math]::Round($catEntry.Value * 100)
    $catScore = 100
    if ($HealthScore.CategoryScores.ContainsKey($catName)) {
      $catScore = $HealthScore.CategoryScores[$catName]
    }
    $catGrade = Get-ScoreGrade -Score $catScore
    $miniRing = New-SvgMiniRing -Percent $catScore -Color $catGrade.Color -Size 40
    $escapedCatName = _EscapeHtml $catName
    $categoryCards += @"
      <div class="kpi-card" style="border-top-color:$($catGrade.Color);">
        <div style="display:flex;justify-content:space-between;align-items:center;">
          <div class="kpi-label">$escapedCatName</div>
          $miniRing
        </div>
        <div class="kpi-value" style="color:$($catGrade.Color);">$catScore</div>
        <div class="kpi-subtext">$($catGrade.Grade) (Weight: ${catWeight}%)</div>
      </div>
"@
  }

  # =============================
  # Protection coverage section
  # =============================
  $protectionHtml = ""
  if ($null -ne $ProtectionData) {
    $vmTotal = [int]$ProtectionData.virtualMachinesTotalCount
    $vmProt = [int]$ProtectionData.virtualMachinesProtectedCount
    $vmUnprot = $vmTotal - $vmProt
    $sqlTotal = [int]$ProtectionData.sqlDatabasesTotalCount
    $sqlProt = [int]$ProtectionData.sqlDatabasesProtectedCount
    $sqlUnprot = $sqlTotal - $sqlProt
    $fsTotal = [int]$ProtectionData.fileSharesTotalCount
    $fsProt = [int]$ProtectionData.fileSharesProtectedCount
    $fsUnprot = $fsTotal - $fsProt

    # Donut chart
    $totalAll = $vmTotal + $sqlTotal + $fsTotal
    $protAll = $vmProt + $sqlProt + $fsProt
    $unprotAll = $totalAll - $protAll
    $donutChart = ""
    if ($totalAll -gt 0) {
      $donutChart = New-SvgDonutChart -Segments @(
        @{ Label = "Protected"; Value = $protAll; Color = "#00B336" }
        @{ Label = "Unprotected"; Value = $unprotAll; Color = "#D13438" }
      ) -CenterLabel "$([math]::Round(($protAll / $totalAll) * 100))%" -CenterSubLabel "Coverage" -Size 180
    }

    $coverageRows = ""
    $coverageItems = @(
      @{ Type = "Virtual Machines"; Total = $vmTotal; Protected = $vmProt; Unprotected = $vmUnprot }
      @{ Type = "SQL Databases"; Total = $sqlTotal; Protected = $sqlProt; Unprotected = $sqlUnprot }
      @{ Type = "File Shares"; Total = $fsTotal; Protected = $fsProt; Unprotected = $fsUnprot }
    )
    foreach ($item in $coverageItems) {
      $pctVal = 0
      if ($item.Total -gt 0) { $pctVal = [math]::Round(($item.Protected / $item.Total) * 100, 1) }
      $pctColor = if ($pctVal -ge 90) { "#00B336" } elseif ($pctVal -ge 50) { "#FF8C00" } else { "#D13438" }
      $escapedType = _EscapeHtml $item.Type
      $coverageRows += "<tr><td><strong>$escapedType</strong></td><td>$($item.Total)</td><td>$($item.Protected)</td><td>$($item.Unprotected)</td><td style='color:$pctColor;font-weight:600;'>$pctVal%</td></tr>`n"
    }

    $protectionHtml = @"
  <details class="section" open>
    <summary class="section-title">Protection Coverage</summary>
    <div style="display:flex;align-items:flex-start;gap:32px;flex-wrap:wrap;margin-bottom:20px;">
      $donutChart
    </div>
    <table>
      <thead><tr><th>Resource Type</th><th>Total</th><th>Protected</th><th>Unprotected</th><th>Coverage</th></tr></thead>
      <tbody>$coverageRows</tbody>
    </table>
  </details>
"@
  }

  # =============================
  # Unprotected resources section
  # =============================
  $unprotectedHtml = ""
  if ($null -ne $UnprotectedResources) {
    $unprotSections = ""

    # Unprotected VMs
    $unprotVMs = @($UnprotectedResources.VMs)
    if ($unprotVMs.Count -gt 0) {
      $maxShow = [math]::Min($unprotVMs.Count, 25)
      $vmRows = ""
      for ($i = 0; $i -lt $maxShow; $i++) {
        $vm = $unprotVMs[$i]
        $vmName = _EscapeHtml "$($vm.name)"
        $vmRegion = _EscapeHtml "$($vm.regionName)"
        $vmRg = _EscapeHtml "$($vm.resourceGroup)"
        $vmSize = _EscapeHtml "$($vm.vmSize)"
        $vmRows += "<tr><td>$vmName</td><td>$vmRegion</td><td>$vmRg</td><td>$vmSize</td></tr>`n"
      }
      if ($unprotVMs.Count -gt $maxShow) {
        $vmRows += "<tr><td colspan='4' style='font-style:italic;color:var(--ms-gray-90);'>... and $($unprotVMs.Count - $maxShow) more (see CSV export)</td></tr>`n"
      }
      $unprotSections += @"
    <h3 style="margin:16px 0 8px;font-size:15px;color:var(--ms-gray-130);">Unprotected Virtual Machines ($($unprotVMs.Count))</h3>
    <table>
      <thead><tr><th>VM Name</th><th>Region</th><th>Resource Group</th><th>Size</th></tr></thead>
      <tbody>$vmRows</tbody>
    </table>
"@
    }

    # Unprotected SQL
    $unprotSQL = @($UnprotectedResources.SQL)
    if ($unprotSQL.Count -gt 0) {
      $sqlRows = ""
      $maxShow = [math]::Min($unprotSQL.Count, 25)
      for ($i = 0; $i -lt $maxShow; $i++) {
        $db = $unprotSQL[$i]
        $dbName = _EscapeHtml "$($db.name)"
        $dbServer = _EscapeHtml "$($db.serverName)"
        $dbRegion = _EscapeHtml "$($db.regionName)"
        $sqlRows += "<tr><td>$dbName</td><td>$dbServer</td><td>$dbRegion</td></tr>`n"
      }
      if ($unprotSQL.Count -gt $maxShow) {
        $sqlRows += "<tr><td colspan='3' style='font-style:italic;color:var(--ms-gray-90);'>... and $($unprotSQL.Count - $maxShow) more (see CSV export)</td></tr>`n"
      }
      $unprotSections += @"
    <h3 style="margin:16px 0 8px;font-size:15px;color:var(--ms-gray-130);">Unprotected SQL Databases ($($unprotSQL.Count))</h3>
    <table>
      <thead><tr><th>Database</th><th>Server</th><th>Region</th></tr></thead>
      <tbody>$sqlRows</tbody>
    </table>
"@
    }

    # Unprotected File Shares
    $unprotFS = @($UnprotectedResources.FileShares)
    if ($unprotFS.Count -gt 0) {
      $fsRows = ""
      $maxShow = [math]::Min($unprotFS.Count, 25)
      for ($i = 0; $i -lt $maxShow; $i++) {
        $fs = $unprotFS[$i]
        $fsName = _EscapeHtml "$($fs.name)"
        $fsAcct = _EscapeHtml "$($fs.storageAccountName)"
        $fsRegion = _EscapeHtml "$($fs.regionName)"
        $fsRows += "<tr><td>$fsName</td><td>$fsAcct</td><td>$fsRegion</td></tr>`n"
      }
      if ($unprotFS.Count -gt $maxShow) {
        $fsRows += "<tr><td colspan='3' style='font-style:italic;color:var(--ms-gray-90);'>... and $($unprotFS.Count - $maxShow) more (see CSV export)</td></tr>`n"
      }
      $unprotSections += @"
    <h3 style="margin:16px 0 8px;font-size:15px;color:var(--ms-gray-130);">Unprotected File Shares ($($unprotFS.Count))</h3>
    <table>
      <thead><tr><th>File Share</th><th>Storage Account</th><th>Region</th></tr></thead>
      <tbody>$fsRows</tbody>
    </table>
"@
    }

    if ($unprotSections) {
      $unprotectedHtml = @"
  <details class="section">
    <summary class="section-title">Unprotected Resources</summary>
    $unprotSections
  </details>
"@
    }
  }

  # =============================
  # Protected items inventory section
  # =============================
  $protectedItemsHtml = ""
  if ($null -ne $ProtectedItems -and @($ProtectedItems.VMs).Count -gt 0) {
    $piRows = ""
    $maxShow = [math]::Min(@($ProtectedItems.VMs).Count, 30)
    # Sort by lastBackup ascending (oldest first) to surface stale backups
    $sortedVMs = @($ProtectedItems.VMs) | Sort-Object { $_.lastBackup }
    for ($i = 0; $i -lt $maxShow; $i++) {
      $pvm = $sortedVMs[$i]
      $pvmName = _EscapeHtml "$($pvm.name)"
      $pvmSize = _EscapeHtml "$($pvm.vmSize)"
      $pvmDisk = "$($pvm.totalSizeInGB)"
      $pvmOs = _EscapeHtml "$($pvm.osType)"
      $pvmRegion = _EscapeHtml "$($pvm.regionName)"
      $pvmLastBkp = _EscapeHtml "$($pvm.lastBackup)"
      $rpCount = ""
      if ($null -ne $pvm.protectionState -and $null -ne $pvm.protectionState.restorePointCount) {
        $rpCount = "$($pvm.protectionState.restorePointCount)"
      }
      $piRows += "<tr><td>$pvmName</td><td>$pvmSize</td><td>$pvmDisk</td><td>$pvmOs</td><td>$pvmRegion</td><td>$pvmLastBkp</td><td>$rpCount</td></tr>`n"
    }
    if (@($ProtectedItems.VMs).Count -gt $maxShow) {
      $piRows += "<tr><td colspan='7' style='font-style:italic;color:var(--ms-gray-90);'>... and $(@($ProtectedItems.VMs).Count - $maxShow) more (see protected_vms.csv)</td></tr>`n"
    }

    $protectedItemsHtml = @"
  <details class="section">
    <summary class="section-title">Protected VM Inventory</summary>
    <p style="margin:16px 0 8px;font-size:13px;color:var(--ms-gray-90);">Sorted by last backup time (oldest first) to highlight stale backups. $(@($ProtectedItems.VMs).Count) total protected VMs.</p>
    <table>
      <thead><tr><th>VM Name</th><th>VM Size</th><th>Disk (GB)</th><th>OS</th><th>Region</th><th>Last Backup</th><th>Restore Points</th></tr></thead>
      <tbody>$piRows</tbody>
    </table>
  </details>
"@
  }

  # =============================
  # Storage usage section
  # =============================
  $storageUsageHtml = ""
  if ($null -ne $StorageUsage) {
    $storageUsageHtml = @"
  <details class="section">
    <summary class="section-title">Storage Usage</summary>
    <div class="kpi-grid" style="margin-top:16px;">
      <div class="kpi-card"><div class="kpi-label">Total Usage</div><div class="kpi-value" style="font-size:20px;">$($StorageUsage.totalUsage) GB</div></div>
      <div class="kpi-card" style="border-top-color:#D13438;"><div class="kpi-label">Hot Tier</div><div class="kpi-value" style="font-size:20px;">$($StorageUsage.hotUsage) GB</div></div>
      <div class="kpi-card" style="border-top-color:#0078D4;"><div class="kpi-label">Cool Tier</div><div class="kpi-value" style="font-size:20px;">$($StorageUsage.coolUsage) GB</div></div>
      <div class="kpi-card" style="border-top-color:#605E5C;"><div class="kpi-label">Archive Tier</div><div class="kpi-value" style="font-size:20px;">$($StorageUsage.archiveUsage) GB</div></div>
      <div class="kpi-card"><div class="kpi-label">Snapshots</div><div class="kpi-value">$($StorageUsage.snapshotsCount)</div></div>
      <div class="kpi-card"><div class="kpi-label">Backups</div><div class="kpi-value">$($StorageUsage.backupCount)</div></div>
      <div class="kpi-card"><div class="kpi-label">Archives</div><div class="kpi-value">$($StorageUsage.archivesCount)</div></div>
    </div>
  </details>
"@
  }

  # =============================
  # Policy status section
  # =============================
  $policyHtml = ""
  if ($null -ne $PolicyData) {
    $policyRows = ""
    $policyTypes = @(
      @{ Items = @($PolicyData.VM);       Type = "VM" }
      @{ Items = @($PolicyData.SQL);      Type = "SQL" }
      @{ Items = @($PolicyData.FileShare); Type = "File Share" }
      @{ Items = @($PolicyData.CosmosDB); Type = "Cosmos DB" }
    )
    foreach ($pt in $policyTypes) {
      foreach ($p in $pt.Items) {
        $pName = _EscapeHtml "$($p.name)"
        $pEnabled = if ($p.isEnabled) { "<span style='color:#00B336;'>Enabled</span>" } else { "<span style='color:#D13438;'>Disabled</span>" }
        $snapColor = Get-HealthColor -Status (if($p.snapshotStatus -eq "Success"){"Healthy"}elseif($p.snapshotStatus -eq "Error"){"Critical"}elseif($p.snapshotStatus -eq "Warning"){"Warning"}else{"Info"})
        $bkpColor = Get-HealthColor -Status (if($p.backupStatus -eq "Success"){"Healthy"}elseif($p.backupStatus -eq "Error"){"Critical"}elseif($p.backupStatus -eq "Warning"){"Warning"}else{"Info"})
        $snapIcon = Get-StatusIcon -Status $p.snapshotStatus
        $bkpIcon = Get-StatusIcon -Status $p.backupStatus
        $escapedSnap = _EscapeHtml "$($p.snapshotStatus)"
        $escapedBkp = _EscapeHtml "$($p.backupStatus)"
        $nextExec = if ($p.nextExecutionTime) { _EscapeHtml "$($p.nextExecutionTime)" } else { "—" }

        $policyRows += "<tr><td>$pName</td><td>$($pt.Type)</td><td>$pEnabled</td><td><span style='color:$snapColor;'>$snapIcon $escapedSnap</span></td><td><span style='color:$bkpColor;'>$bkpIcon $escapedBkp</span></td><td>$nextExec</td></tr>`n"
      }
    }

    if ($policyRows) {
      $policyHtml = @"
  <details class="section" open>
    <summary class="section-title">Policy Status</summary>
    <table>
      <thead><tr><th>Policy Name</th><th>Type</th><th>Status</th><th>Snapshot</th><th>Backup</th><th>Next Execution</th></tr></thead>
      <tbody>$policyRows</tbody>
    </table>
  </details>
"@
    }
  }

  # =============================
  # SLA compliance section
  # =============================
  $slaHtml = ""
  if (@($SLAReport).Count -gt 0) {
    $slaItems = @()
    foreach ($sla in $SLAReport) {
      $pctVal = 0
      if ($sla.snapshotSlaReport -and $sla.snapshotSlaReport.achievedSlaPercent) {
        $pctVal = [math]::Round($sla.snapshotSlaReport.achievedSlaPercent, 1)
      }
      $slaColor = if ($pctVal -ge 95) { "#00B336" } elseif ($pctVal -ge 80) { "#FF8C00" } else { "#D13438" }
      $slaName = if ($sla.name) { $sla.name } else { "SLA Policy" }
      $slaItems += @{ Label = $slaName; Value = $pctVal; MaxValue = 100; Color = $slaColor }
    }

    $slaChart = New-SvgHorizontalBarChart -Items $slaItems -MaxBars 10

    $slaHtml = @"
  <details class="section">
    <summary class="section-title">SLA Compliance</summary>
    $slaChart
  </details>
"@
  }

  # =============================
  # Session health section
  # =============================
  $sessionHtml = ""
  if ($null -ne $SessionsSummary) {
    $success = [int]$SessionsSummary.latestSessionsSuccessCount
    $warnings = [int]$SessionsSummary.latestSessionsWarningCount
    $errors = [int]$SessionsSummary.latestSessionsErrorCount
    $running = [int]$SessionsSummary.latestSessionsRunningCount

    $stackedBar = New-SvgStackedBar -SuccessCount $success -WarningCount $warnings -ErrorCount $errors

    $failedRows = ""
    if (@($FailedSessions).Count -gt 0) {
      $maxShow = [math]::Min(@($FailedSessions).Count, 20)
      for ($i = 0; $i -lt $maxShow; $i++) {
        $sess = $FailedSessions[$i]
        $sessType = _EscapeHtml "$($sess.type)"
        $sessStart = _EscapeHtml "$($sess.executionStartTime)"
        $sessDur = _EscapeHtml "$($sess.executionDuration)"
        $sessPolicy = ""
        if ($sess.backupJobInfo -and $sess.backupJobInfo.policyName) {
          $sessPolicy = _EscapeHtml "$($sess.backupJobInfo.policyName)"
        }
        $failedRows += "<tr><td>$sessType</td><td>$sessPolicy</td><td>$sessStart</td><td>$sessDur</td></tr>`n"
      }
    }

    $failedTable = ""
    if ($failedRows) {
      $failedTable = @"
    <h3 style="margin:20px 0 8px;font-size:15px;color:var(--ms-gray-130);">Recent Failed Sessions</h3>
    <table>
      <thead><tr><th>Type</th><th>Policy</th><th>Start Time</th><th>Duration</th></tr></thead>
      <tbody>$failedRows</tbody>
    </table>
"@
    }

    $sessionHtml = @"
  <details class="section" open>
    <summary class="section-title">Session Health</summary>
    $stackedBar
    <div class="kpi-grid" style="margin-top:16px;">
      <div class="kpi-card" style="border-top-color:#00B336;"><div class="kpi-label">Successful</div><div class="kpi-value" style="color:#00B336;">$success</div></div>
      <div class="kpi-card" style="border-top-color:#FF8C00;"><div class="kpi-label">Warnings</div><div class="kpi-value" style="color:#FF8C00;">$warnings</div></div>
      <div class="kpi-card" style="border-top-color:#D13438;"><div class="kpi-label">Errors</div><div class="kpi-value" style="color:#D13438;">$errors</div></div>
      <div class="kpi-card"><div class="kpi-label">Running</div><div class="kpi-value">$running</div></div>
    </div>
    $failedTable
  </details>
"@
  }

  # =============================
  # Repository health section
  # =============================
  $repoHtml = ""
  if (@($Repositories).Count -gt 0) {
    $repoRows = ""
    foreach ($repo in $Repositories) {
      $rName = _EscapeHtml "$($repo.name)"
      $rType = _EscapeHtml "$($repo.repositoryType)"
      $rStatusColor = if ($repo.status -eq "Ready") { "#00B336" } elseif ($repo.status -eq "Failed") { "#D13438" } else { "#FF8C00" }
      $rStatus = _EscapeHtml "$($repo.status)"
      $rRegion = _EscapeHtml "$($repo.regionName)"
      $rEncrypt = if ($repo.enableEncryption) { "<span style='color:#00B336;'>&#10004; Yes</span>" } else { "<span style='color:#D13438;'>&#10006; No</span>" }
      $rImmut = if ($repo.immutabilityEnabled) { "<span style='color:#00B336;'>&#10004; Yes</span>" } else { "<span style='color:#D13438;'>&#10006; No</span>" }
      $rTier = _EscapeHtml "$($repo.storageTier)"

      $repoRows += "<tr><td>$rName</td><td>$rType</td><td><span style='color:$rStatusColor;font-weight:600;'>$rStatus</span></td><td>$rRegion</td><td>$rEncrypt</td><td>$rImmut</td><td>$rTier</td></tr>`n"
    }

    $repoHtml = @"
  <details class="section" open>
    <summary class="section-title">Repository Health</summary>
    <table>
      <thead><tr><th>Name</th><th>Type</th><th>Status</th><th>Region</th><th>Encryption</th><th>Immutability</th><th>Tier</th></tr></thead>
      <tbody>$repoRows</tbody>
    </table>
  </details>
"@
  }

  # =============================
  # Worker health section
  # =============================
  $workerHtml = ""
  if (@($Workers).Count -gt 0 -or $null -ne $WorkerStats) {
    $workerKpis = ""
    if ($null -ne $WorkerStats) {
      $workerKpis = @"
    <div class="kpi-grid">
      <div class="kpi-card"><div class="kpi-label">Total Workers</div><div class="kpi-value">$($WorkerStats.countOfWorkers)</div></div>
      <div class="kpi-card" style="border-top-color:#00B336;"><div class="kpi-label">Running</div><div class="kpi-value" style="color:#00B336;">$($WorkerStats.runningWorkers)</div></div>
      <div class="kpi-card"><div class="kpi-label">Deployed</div><div class="kpi-value">$($WorkerStats.deployedWorkers)</div></div>
      <div class="kpi-card"><div class="kpi-label">Used</div><div class="kpi-value">$($WorkerStats.usedWorkers)</div></div>
    </div>
"@
    }

    $workerRows = ""
    foreach ($w in @($Workers)) {
      $wName = _EscapeHtml "$($w.name)"
      $wStatusColor = if ($w.status -eq "Idle" -or $w.status -eq "Busy") { "#00B336" } elseif ($w.status -eq "Stopped" -or $w.status -eq "Removed") { "#D13438" } else { "#FF8C00" }
      $wStatus = _EscapeHtml "$($w.status)"
      $wRegion = _EscapeHtml "$($w.region)"
      $wType = _EscapeHtml "$($w.instanceType)"
      $wProfile = _EscapeHtml "$($w.profile)"
      $workerRows += "<tr><td>$wName</td><td><span style='color:$wStatusColor;font-weight:600;'>$wStatus</span></td><td>$wRegion</td><td>$wType</td><td>$wProfile</td></tr>`n"
    }

    $workerTable = ""
    if ($workerRows) {
      $workerTable = @"
    <table>
      <thead><tr><th>Name</th><th>Status</th><th>Region</th><th>Instance Type</th><th>Profile</th></tr></thead>
      <tbody>$workerRows</tbody>
    </table>
"@
    }

    # Bottleneck alerts
    $bottleneckHtml = ""
    if ($null -ne $Bottlenecks) {
      $alerts = New-Object System.Collections.Generic.List[string]
      if ($Bottlenecks.workerWaitTimeState -eq "Exceeded" -or $Bottlenecks.workerWaitTimeState -eq "Warning") {
        $alerts.Add("Worker wait time: avg $($Bottlenecks.averageWorkersWaitTimeMin)min, max $($Bottlenecks.maximumWorkersWaitTimeMin)min in $($Bottlenecks.workerBottleneckRegion)")
      }
      if ($Bottlenecks.cpuQuotaState -eq "Exceeded" -or $Bottlenecks.cpuQuotaState -eq "Warning") {
        $alerts.Add("CPU quota bottleneck in $($Bottlenecks.cpuQuotaBottleneckRegion)")
      }
      if ($Bottlenecks.storageAccountBottleneckState -eq "Exceeded" -or $Bottlenecks.storageAccountBottleneckState -eq "Warning") {
        $alerts.Add("Storage throttling: $($Bottlenecks.storageAccountBottleneckName) in $($Bottlenecks.storageAccountBottleneckRegion)")
      }

      if ($alerts.Count -gt 0) {
        $alertItems = ($alerts | ForEach-Object { "<li style='color:#D13438;'>$(_EscapeHtml $_)</li>" }) -join "`n"
        $bottleneckHtml = @"
    <div class="info-card" style="border-left-color:#D13438;">
      <div class="info-card-title">Infrastructure Bottlenecks Detected</div>
      <ul style="margin:8px 0 0 20px;font-size:13px;">$alertItems</ul>
    </div>
"@
      }
    }

    $workerHtml = @"
  <details class="section">
    <summary class="section-title">Worker Health</summary>
    $workerKpis
    $bottleneckHtml
    $workerTable
  </details>
"@
  }

  # =============================
  # Configuration backup section
  # =============================
  $configBkpHtml = ""
  if ($null -ne $ConfigBackup -and $null -ne $ConfigBackup.Settings) {
    $cbSettings = $ConfigBackup.Settings
    $cbEnabled = if ($cbSettings.isEnabled) { "<span style='color:#00B336;font-weight:600;'>Enabled</span>" } else { "<span style='color:#D13438;font-weight:600;'>Disabled</span>" }
    $cbRepo = _EscapeHtml "$($cbSettings.repositoryName)"
    $cbLastStatus = _EscapeHtml "$($cbSettings.lastBackupSessionStatus)"
    $cbLastTime = _EscapeHtml "$($cbSettings.lastBackupSessionStartTimeUtc)"

    $configBkpHtml = @"
  <details class="section">
    <summary class="section-title">Configuration Backup</summary>
    <div class="kpi-grid">
      <div class="kpi-card"><div class="kpi-label">Status</div><div class="kpi-value" style="font-size:18px;">$cbEnabled</div></div>
      <div class="kpi-card"><div class="kpi-label">Repository</div><div class="kpi-value" style="font-size:18px;">$cbRepo</div></div>
      <div class="kpi-card"><div class="kpi-label">Last Backup Status</div><div class="kpi-value" style="font-size:18px;">$cbLastStatus</div></div>
      <div class="kpi-card"><div class="kpi-label">Last Backup Time</div><div class="kpi-value" style="font-size:14px;">$cbLastTime</div></div>
    </div>
  </details>
"@
  }

  # =============================
  # License section
  # =============================
  $licenseHtml = ""
  if ($null -ne $LicenseData.License) {
    $lic = $LicenseData.License
    $licType = _EscapeHtml "$(if ($lic.isFreeEdition) { 'Free Edition' } else { $lic.licenseType })"
    $licCompany = _EscapeHtml "$($lic.company)"
    $licExpires = _EscapeHtml "$($lic.licenseExpires)"
    $licInstances = "$($lic.totalInstancesUses) / $($lic.instances)"
    $licVm = "$($lic.vmsInstancesUses)"
    $licSql = "$($lic.sqlInstancesUses)"
    $licFs = "$($lic.fileShareInstancesUses)"

    $licenseHtml = @"
  <details class="section">
    <summary class="section-title">License Information</summary>
    <div class="kpi-grid">
      <div class="kpi-card"><div class="kpi-label">License Type</div><div class="kpi-value" style="font-size:18px;">$licType</div><div class="kpi-subtext">$licCompany</div></div>
      <div class="kpi-card"><div class="kpi-label">Expiry Date</div><div class="kpi-value" style="font-size:18px;">$licExpires</div></div>
      <div class="kpi-card"><div class="kpi-label">Instance Usage</div><div class="kpi-value" style="font-size:18px;">$licInstances</div></div>
      <div class="kpi-card"><div class="kpi-label">By Type</div><div class="kpi-value" style="font-size:14px;">VM: $licVm | SQL: $licSql | FS: $licFs</div></div>
    </div>
  </details>
"@
  }

  # =============================
  # Configuration check section
  # =============================
  $configCheckHtml = ""
  if ($null -ne $ConfigCheckData -and $ConfigCheckData.logLine) {
    $overallBadge = ""
    $badgeColor = switch ($ConfigCheckData.overallStatus) {
      "Success" { "#00B336" }
      "Warning" { "#FF8C00" }
      "Failed"  { "#D13438" }
      default   { "#605E5C" }
    }
    $escapedOverall = _EscapeHtml "$($ConfigCheckData.overallStatus)"
    $overallBadge = "<span style='display:inline-block;padding:4px 12px;background:$badgeColor;color:white;border-radius:12px;font-size:12px;font-weight:600;'>$escapedOverall</span>"

    $checkRows = ""
    foreach ($line in $ConfigCheckData.logLine) {
      $lineTitle = _EscapeHtml "$($line.title)"
      $lineStatusColor = switch ($line.status) {
        "Success" { "#00B336" }
        "Warning" { "#FF8C00" }
        "Failed"  { "#D13438" }
        "Error"   { "#D13438" }
        default   { "#605E5C" }
      }
      $lineIcon = Get-StatusIcon -Status $line.status
      $lineResult = _EscapeHtml "$($line.result)"
      $escapedLineStatus = _EscapeHtml "$($line.status)"
      $checkRows += "<tr><td>$lineTitle</td><td><span style='color:$lineStatusColor;font-weight:600;'>$lineIcon $escapedLineStatus</span></td><td>$lineResult</td></tr>`n"
    }

    $configCheckHtml = @"
  <details class="section" open>
    <summary class="section-title">Configuration Check</summary>
    <p style="margin-bottom:16px;">Overall Status: $overallBadge</p>
    <table>
      <thead><tr><th>Check</th><th>Status</th><th>Result</th></tr></thead>
      <tbody>$checkRows</tbody>
    </table>
  </details>
"@
  }

  # =============================
  # All findings table
  # =============================
  $findingsRows = ($script:Findings | ForEach-Object {
    $statusColor = Get-HealthColor -Status $_.Status
    $statusIcon = Get-StatusIcon -Status $_.Status
    $escapedCat = _EscapeHtml $_.Category
    $escapedCheck = _EscapeHtml $_.Check
    $escapedDetail = _EscapeHtml $_.Detail
    $escapedRec = if ($_.Recommendation) { _EscapeHtml $_.Recommendation } else { "&#8212;" }
    "<tr><td><span style='color:$statusColor;font-weight:600;'>$statusIcon $($_.Status)</span></td><td>$escapedCat</td><td>$escapedCheck</td><td>$escapedDetail</td><td>$escapedRec</td></tr>"
  }) -join "`n"

  # =============================
  # Recommendations
  # =============================
  $critFindings = @($script:Findings | Where-Object { $_.Status -eq "Critical" -and $_.Recommendation })
  $warnFindings = @($script:Findings | Where-Object { $_.Status -eq "Warning" -and $_.Recommendation })

  $recsHtml = ""
  if ($critFindings.Count -gt 0 -or $warnFindings.Count -gt 0) {
    $immediateLi = ""
    foreach ($f in $critFindings) {
      $escapedRec = _EscapeHtml $f.Recommendation
      $immediateLi += "<li>$escapedRec</li>`n"
    }
    $shortTermLi = ""
    foreach ($f in $warnFindings) {
      $escapedRec = _EscapeHtml $f.Recommendation
      $shortTermLi += "<li>$escapedRec</li>`n"
    }

    $immediateSection = ""
    if ($immediateLi) {
      $immediateSection = @"
    <div class="info-card" style="border-left-color:#D13438;">
      <div class="info-card-title" style="color:#D13438;">Immediate Actions</div>
      <ul style="margin:8px 0 0 20px;font-size:13px;line-height:1.8;">$immediateLi</ul>
    </div>
"@
    }
    $shortTermSection = ""
    if ($shortTermLi) {
      $shortTermSection = @"
    <div class="info-card" style="border-left-color:#FF8C00;">
      <div class="info-card-title" style="color:#FF8C00;">Short-Term Improvements</div>
      <ul style="margin:8px 0 0 20px;font-size:13px;line-height:1.8;">$shortTermLi</ul>
    </div>
"@
    }

    $recsHtml = @"
  <details class="section" open>
    <summary class="section-title">Recommendations</summary>
    $immediateSection
    $shortTermSection
  </details>
"@
  }

  # =============================
  # Build weights description
  # =============================
  $weightsDesc = ($script:CategoryWeights.GetEnumerator() | Sort-Object { $_.Value } -Descending | ForEach-Object {
    "$($_.Key) ($([math]::Round($_.Value * 100))%)"
  }) -join ", "

  # =============================
  # Assemble final HTML
  # =============================
  $htmlPath = Join-Path $OutputPath "VBA-HealthCheck-Report.html"

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:;">
<title>Veeam Backup for Azure - Health Check Report</title>
<style>
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
  --header-dark: #1B1B2F;
  --header-mid: #1F4068;
  --header-deep: #162447;
  --shadow-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif; background: var(--ms-gray-10); color: var(--ms-gray-160); line-height: 1.6; font-size: 14px; -webkit-font-smoothing: antialiased; counter-reset: section-counter; }
.container { max-width: 1440px; margin: 0 auto; padding: 0 32px 40px; }

.header { background: linear-gradient(135deg, var(--header-dark) 0%, var(--header-mid) 50%, var(--header-deep) 100%); padding: 48px 32px 40px; margin-bottom: 32px; position: relative; overflow: hidden; }
.header-orb { position: absolute; top: -50%; right: -10%; width: 400px; height: 400px; background: radial-gradient(circle, rgba(255,255,255,0.04) 0%, transparent 70%); border-radius: 50%; }
.header-content { max-width: 1440px; margin: 0 auto; position: relative; z-index: 1; }
.header-badge { display: inline-block; padding: 4px 14px; background: rgba(255,255,255,0.10); color: #FFFFFF; border: 1px solid rgba(255,255,255,0.20); border-radius: 14px; font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; backdrop-filter: blur(12px); margin-bottom: 16px; }
.header-title { font-size: 36px; font-weight: 700; color: #FFFFFF; letter-spacing: -0.02em; margin-bottom: 6px; }
.header-subtitle { font-size: 16px; font-weight: 400; color: rgba(255,255,255,0.75); margin-bottom: 20px; }
.header-meta { display: flex; flex-wrap: wrap; gap: 24px; }
.header-meta span { font-size: 13px; color: rgba(255,255,255,0.6); }
.header-meta span strong { color: rgba(255,255,255,0.9); font-weight: 600; }

.score-banner { background: white; padding: 40px; margin-bottom: 32px; border-radius: 4px; box-shadow: var(--shadow-8); text-align: center; border-top: 4px solid $($HealthScore.GradeColor); }
.score-grade { font-size: 24px; font-weight: 600; color: $($HealthScore.GradeColor); margin-top: 8px; }
.score-summary { display: flex; justify-content: center; gap: 32px; margin-top: 24px; font-size: 14px; }
.score-stat { display: flex; align-items: center; gap: 8px; }
.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
.dot-green { background: #00B336; }
.dot-orange { background: #FF8C00; }
.dot-red { background: #D13438; }

.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }
.kpi-card { background: white; padding: 20px; border-radius: 4px; box-shadow: var(--shadow-4); border-top: 3px solid var(--veeam-green); }
.kpi-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 8px; }
.kpi-value { font-size: 28px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 4px; }
.kpi-subtext { font-size: 12px; color: var(--ms-gray-90); }

details.section { background: white; margin-bottom: 24px; border-radius: 4px; box-shadow: var(--shadow-4); }
details.section > summary { padding: 24px 32px; font-size: 18px; font-weight: 600; color: var(--ms-gray-160); cursor: pointer; list-style: none; border-bottom: 1px solid var(--ms-gray-30); counter-increment: section-counter; }
details.section > summary::before { content: counter(section-counter, decimal-leading-zero) " "; color: var(--ms-blue); font-weight: 700; margin-right: 8px; }
details.section > summary::-webkit-details-marker { display: none; }
details.section[open] > summary { border-bottom: 1px solid var(--ms-gray-30); }
details.section > :not(summary) { padding: 0 32px; }
details.section > :last-child { padding-bottom: 24px; }
details.section > table { margin: 0; }
details.section > table td, details.section > table th { padding-left: 32px; }
details.section > table td:last-child, details.section > table th:last-child { padding-right: 32px; }
details.section > div, details.section > p, details.section > h3 { padding-left: 32px; padding-right: 32px; }

table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 16px; }
thead { background: var(--ms-gray-20); }
th { padding: 10px 14px; text-align: left; font-weight: 600; color: var(--ms-gray-130); font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; border-bottom: 2px solid var(--ms-gray-50); }
td { padding: 12px 14px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); }
tbody tr:hover { background: var(--ms-gray-10); }

.info-card { background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue); padding: 20px 24px; margin: 16px 0; border-radius: 2px; }
.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 13px; line-height: 1.6; }

.footer { text-align: center; padding: 32px; color: var(--ms-gray-90); font-size: 12px; }

@media print {
  body { background: white; }
  .section, .kpi-card, .score-banner { box-shadow: none; border: 1px solid var(--ms-gray-30); }
  details.section { break-inside: avoid; }
}
@media (max-width: 768px) {
  .container { padding: 0 16px 20px; }
  .kpi-grid { grid-template-columns: 1fr 1fr; }
  .header-title { font-size: 24px; }
}
</style>
</head>
<body>

<div class="header">
  <div class="header-orb"></div>
  <div class="header-content">
    <div class="header-badge">VBA Appliance Health Assessment</div>
    <div class="header-title">Veeam Backup for Azure</div>
    <div class="header-subtitle">Health Check &amp; Compliance Report</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>Appliance:</strong> $appName</span>
      <span><strong>Version:</strong> $serverVersion</span>
      <span><strong>Region:</strong> $appRegion</span>
    </div>
  </div>
</div>

<div class="container">

  <div class="score-banner">
    $gaugeChart
    <div class="score-grade">$($HealthScore.Grade)</div>
    <div class="score-summary">
      <div class="score-stat"><span class="dot dot-green"></span> $healthyCount Healthy</div>
      <div class="score-stat"><span class="dot dot-orange"></span> $warningCount Warnings</div>
      <div class="score-stat"><span class="dot dot-red"></span> $criticalCount Critical</div>
    </div>
  </div>

  <div class="kpi-grid">
    $categoryCards
  </div>

  <details class="section" open>
    <summary class="section-title">System Information</summary>
    <div class="kpi-grid" style="margin-top:16px;">
      <div class="kpi-card"><div class="kpi-label">Server Version</div><div class="kpi-value" style="font-size:16px;">$serverVersion</div></div>
      <div class="kpi-card"><div class="kpi-label">Worker Version</div><div class="kpi-value" style="font-size:16px;">$workerVersion</div></div>
      <div class="kpi-card"><div class="kpi-label">FLR Version</div><div class="kpi-value" style="font-size:16px;">$flrVersion</div></div>
      <div class="kpi-card"><div class="kpi-label">Region</div><div class="kpi-value" style="font-size:16px;">$appRegion</div></div>
      <div class="kpi-card"><div class="kpi-label">Resource Group</div><div class="kpi-value" style="font-size:16px;">$appRg</div></div>
      <div class="kpi-card"><div class="kpi-label">System State</div><div class="kpi-value" style="font-size:16px;">$(if($SystemData.Status){_EscapeHtml "$($SystemData.Status.state)"}else{"N/A"})</div></div>
    </div>
  </details>

  $licenseHtml

  $configCheckHtml

  $protectionHtml

  $unprotectedHtml

  $protectedItemsHtml

  $storageUsageHtml

  $policyHtml

  $slaHtml

  $sessionHtml

  $repoHtml

  $workerHtml

  $configBkpHtml

  <details class="section" open>
    <summary class="section-title">All Findings</summary>
    <table>
      <thead><tr><th>Status</th><th>Category</th><th>Check</th><th>Detail</th><th>Recommendation</th></tr></thead>
      <tbody>$findingsRows</tbody>
    </table>
  </details>

  $recsHtml

  <details class="section">
    <summary class="section-title">Methodology</summary>
    <div class="info-card" style="margin-top:16px;">
      <div class="info-card-title">Data Collection</div>
      <div class="info-card-text">
        This health check connects directly to the Veeam Backup for Azure appliance REST API (v8.1) to assess system health, license compliance, protection coverage, policy status, session success rates, repository configuration, worker health, and configuration backup. All operations are read-only with the exception of triggering the built-in configuration check.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Health Score Calculation</div>
      <div class="info-card-text">
        The overall health score (0-100) is a weighted average across categories: $weightsDesc. Each finding scores 100 (Healthy), 50 (Warning), or 0 (Critical). Categories with no findings default to 100.
      </div>
    </div>
  </details>

  <div class="footer">
    <p>Veeam Backup for Azure &mdash; Health Check &amp; Compliance Report</p>
    <p>Generated by Get-VBAHealthCheck &mdash; open-source community tool</p>
    <p>Data source: VBA appliance REST API v8.1</p>
  </div>

</div>
</body>
</html>
"@

  $html | Out-File -FilePath $htmlPath -Encoding UTF8
  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}
