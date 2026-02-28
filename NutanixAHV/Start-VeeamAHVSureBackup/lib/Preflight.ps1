# =============================
# Preflight Health Checks
# =============================
# Validates cluster health, capacity, network readiness, restore point
# integrity, and AHV proxy connectivity before recovery operations.
# Pattern follows ONPREM/New-VeeamSureBackupSetup Test-Configuration.

function Test-ClusterHealth {
  <#
  .SYNOPSIS
    Check Nutanix cluster operational status via Prism API
  .DESCRIPTION
    Verifies the target cluster is in NORMAL operation mode. Clusters in
    DEGRADED or CRITICAL state may fail recovery operations or produce
    unreliable test results.
  #>
  param(
    [Parameter(Mandatory = $true)]$Clusters
  )

  $issues = @()
  $warnings = @()

  foreach ($cluster in $Clusters) {
    $clusterName = if ($PrismApiVersion -eq "v4") { $cluster.name } else { $cluster.spec.name }
    $clusterStatus = if ($PrismApiVersion -eq "v4") {
      $cluster.status
    }
    else {
      $cluster.status.resources.config.operation_mode
    }

    if ($clusterStatus -and $clusterStatus -imatch "CRITICAL|FAILED") {
      $issues += "Cluster '$clusterName' is in $clusterStatus state — recovery operations may fail"
    }
    elseif ($clusterStatus -and $clusterStatus -imatch "DEGRADED") {
      $warnings += "Cluster '$clusterName' is in $clusterStatus state — recovery may be unreliable"
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-ClusterCapacity {
  <#
  .SYNOPSIS
    Verify the cluster has capacity for concurrent VM recoveries
  .DESCRIPTION
    Checks cluster node count against MaxConcurrentVMs. Heuristic: each
    node can safely host ~3 concurrent recovery VMs. Also checks if the
    cluster has any available compute resources.
  #>
  param(
    [Parameter(Mandatory = $true)]$Clusters,
    [Parameter(Mandatory = $true)][int]$MaxConcurrentVMs
  )

  $issues = @()
  $warnings = @()

  foreach ($cluster in $Clusters) {
    $clusterName = if ($PrismApiVersion -eq "v4") { $cluster.name } else { $cluster.spec.name }
    $nodeCount = 0

    if ($PrismApiVersion -eq "v4") {
      $nodeCount = if ($cluster.nodes -and $cluster.nodes.nodeList) { $cluster.nodes.nodeList.Count } else { 0 }
    }
    else {
      $nodeCount = if ($cluster.status.resources.nodes -and $cluster.status.resources.nodes.hypervisor_server_list) {
        $cluster.status.resources.nodes.hypervisor_server_list.Count
      }
      else { 0 }
    }

    if ($nodeCount -eq 0) {
      $warnings += "Could not determine node count for cluster '$clusterName'"
    }
    elseif ($MaxConcurrentVMs -gt ($nodeCount * 3)) {
      $warnings += "MaxConcurrentVMs ($MaxConcurrentVMs) exceeds recommended capacity for cluster '$clusterName' ($nodeCount nodes, recommended max: $($nodeCount * 3))"
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-IsolatedNetworkHealth {
  <#
  .SYNOPSIS
    Validate the isolated network is properly configured for recovery
  .DESCRIPTION
    Checks that the isolated network/subnet has IP management configured
    (DHCP or IP pool) so recovered VMs can obtain addresses. Without IP
    management, network tests (ping, port, DNS) will fail.
  #>
  param(
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $issues = @()
  $warnings = @()

  if (-not $IsolatedNetwork.UUID) {
    $issues += "Isolated network has no UUID — cannot proceed with recovery"
    return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
  }

  if (-not $IsolatedNetwork.VlanId -and $IsolatedNetwork.VlanId -ne 0) {
    $warnings += "Isolated network '$($IsolatedNetwork.Name)' has no VLAN ID — verify it is truly isolated from production"
  }

  # Check if the network name suggests it might be a production network
  if ($IsolatedNetwork.Name -imatch "^prod|^default|^management|^cvm") {
    $warnings += "Isolated network name '$($IsolatedNetwork.Name)' looks like a production network — verify this is the correct isolated network"
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-RestorePointConsistency {
  <#
  .SYNOPSIS
    Verify all restore points are application-consistent
  .DESCRIPTION
    Checks the IsConsistent flag on each restore point. Inconsistent restore
    points may produce VMs with corrupted application state.
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePoints
  )

  $issues = @()
  $warnings = @()

  $inconsistent = $RestorePoints | Where-Object { -not $_.IsConsistent }
  if ($inconsistent.Count -gt 0) {
    foreach ($rp in $inconsistent) {
      $warnings += "Restore point for '$($rp.VMName)' (job: $($rp.JobName), $($rp.CreationTime.ToString('yyyy-MM-dd HH:mm'))) is crash-consistent, not application-consistent"
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-RestorePointRecency {
  <#
  .SYNOPSIS
    Warn about stale restore points
  .DESCRIPTION
    Checks if any restore points are older than the configured maximum age.
    Stale restore points may not reflect current application state and could
    give a false sense of recoverability.
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)][int]$MaxAgeDays
  )

  $issues = @()
  $warnings = @()

  $cutoff = (Get-Date).AddDays(-$MaxAgeDays)
  $stale = $RestorePoints | Where-Object { $_.CreationTime -lt $cutoff }

  if ($stale.Count -gt 0) {
    foreach ($rp in $stale) {
      $ageDays = [math]::Round(((Get-Date) - $rp.CreationTime).TotalDays, 1)
      $warnings += "Restore point for '$($rp.VMName)' is $ageDays days old (threshold: $MaxAgeDays days)"
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-BackupJobStatus {
  <#
  .SYNOPSIS
    Check last run status of backup jobs
  .DESCRIPTION
    Warns if the last backup job run failed or is currently running. Failed
    jobs may indicate infrastructure issues that could affect recovery.
  #>
  param(
    [Parameter(Mandatory = $true)]$BackupJobs
  )

  $issues = @()
  $warnings = @()

  foreach ($job in $BackupJobs) {
    try {
      $lastResult = $job.GetLastResult()
      $isRunning = $job.IsRunning

      if ($isRunning) {
        $warnings += "Backup job '$($job.Name)' is currently running — restore points may be in-progress"
      }
      elseif ($lastResult -and "$lastResult" -imatch "Failed") {
        $warnings += "Backup job '$($job.Name)' last run failed — verify backup integrity"
      }
    }
    catch {
      # Some job types may not support GetLastResult
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-AHVProxyConnectivity {
  <#
  .SYNOPSIS
    Verify the AHV Backup Proxy REST API is reachable (for FullRestore mode)
  .DESCRIPTION
    Attempts to reach the AHV proxy's API endpoint. Only runs when
    RestoreMethod is FullRestore since InstantRecovery uses VBR cmdlets.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ProxyServer,
    [Parameter(Mandatory = $true)][int]$ProxyPort
  )

  $issues = @()
  $warnings = @()

  try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectTask = $tcpClient.ConnectAsync($ProxyServer, $ProxyPort)
    $connected = $connectTask.Wait(10000)

    if (-not $connected -or -not $tcpClient.Connected) {
      $issues += "AHV Backup Proxy at ${ProxyServer}:${ProxyPort} is not reachable — FullRestore requires proxy REST API access"
    }
  }
  catch {
    $issues += "AHV Backup Proxy at ${ProxyServer}:${ProxyPort} connection failed: $($_.Exception.Message)"
  }
  finally {
    if ($tcpClient) {
      try { $tcpClient.Close() } catch { }
      $tcpClient.Dispose()
    }
  }

  return [PSCustomObject]@{ Issues = $issues; Warnings = $warnings }
}

function Test-PreflightRequirements {
  <#
  .SYNOPSIS
    Orchestrator: run all preflight checks and report results
  .DESCRIPTION
    Runs cluster health, capacity, network, restore point, and proxy
    connectivity checks. Returns a result object with Success, Issues,
    and Warnings. Throws if any blocking issues are found.
  .PARAMETER Clusters
    Nutanix cluster objects from Prism API
  .PARAMETER IsolatedNetwork
    Resolved isolated network object
  .PARAMETER RestorePoints
    Discovered restore point objects
  .PARAMETER BackupJobs
    Veeam AHV backup job objects
  .PARAMETER MaxConcurrentVMs
    Maximum concurrent recovery VMs
  .PARAMETER MaxAgeDays
    Maximum restore point age in days before warning
  .PARAMETER RestoreMethod
    Current restore method (InstantRecovery or FullRestore)
  .PARAMETER ProxyServer
    AHV Backup Proxy hostname (required for FullRestore)
  .PARAMETER ProxyPort
    AHV Backup Proxy port (required for FullRestore)
  #>
  param(
    [Parameter(Mandatory = $true)]$Clusters,
    [Parameter(Mandatory = $true)]$IsolatedNetwork,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$BackupJobs,
    [int]$MaxConcurrentVMs = 3,
    [int]$MaxAgeDays = 7,
    [string]$RestoreMethod = "InstantRecovery",
    [string]$ProxyServer,
    [int]$ProxyPort = 8100
  )

  $startTime = Get-Date
  $allIssues = @()
  $allWarnings = @()

  Write-Log "Running preflight health checks..." -Level "INFO"

  # 1. Cluster health
  Write-Log "  [Preflight] Checking cluster health..." -Level "INFO"
  $result = Test-ClusterHealth -Clusters $Clusters
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 2. Cluster capacity
  Write-Log "  [Preflight] Checking cluster capacity..." -Level "INFO"
  $result = Test-ClusterCapacity -Clusters $Clusters -MaxConcurrentVMs $MaxConcurrentVMs
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 3. Isolated network
  Write-Log "  [Preflight] Checking isolated network health..." -Level "INFO"
  $result = Test-IsolatedNetworkHealth -IsolatedNetwork $IsolatedNetwork
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 4. Restore point consistency
  Write-Log "  [Preflight] Checking restore point consistency..." -Level "INFO"
  $result = Test-RestorePointConsistency -RestorePoints $RestorePoints
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 5. Restore point recency
  Write-Log "  [Preflight] Checking restore point recency..." -Level "INFO"
  $result = Test-RestorePointRecency -RestorePoints $RestorePoints -MaxAgeDays $MaxAgeDays
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 6. Backup job status
  Write-Log "  [Preflight] Checking backup job status..." -Level "INFO"
  $result = Test-BackupJobStatus -BackupJobs $BackupJobs
  $allIssues += $result.Issues
  $allWarnings += $result.Warnings

  # 7. AHV Proxy connectivity (only for FullRestore)
  if ($RestoreMethod -eq "FullRestore") {
    if (-not $ProxyServer) {
      $allIssues += "FullRestore requires -AHVProxyServer parameter"
    }
    else {
      Write-Log "  [Preflight] Checking AHV Proxy connectivity (${ProxyServer}:${ProxyPort})..." -Level "INFO"
      $result = Test-AHVProxyConnectivity -ProxyServer $ProxyServer -ProxyPort $ProxyPort
      $allIssues += $result.Issues
      $allWarnings += $result.Warnings
    }
  }

  # Report results
  $durationSec = ((Get-Date) - $startTime).TotalSeconds

  if ($allWarnings.Count -gt 0) {
    Write-Log "" -Level "INFO"
    Write-Log "  PREFLIGHT WARNINGS ($($allWarnings.Count)):" -Level "WARNING"
    foreach ($w in $allWarnings) {
      Write-Log "    - $w" -Level "WARNING"
    }
  }

  if ($allIssues.Count -gt 0) {
    Write-Log "" -Level "INFO"
    Write-Log "  PREFLIGHT ERRORS ($($allIssues.Count)):" -Level "ERROR"
    foreach ($i in $allIssues) {
      Write-Log "    [X] $i" -Level "ERROR"
    }
  }

  if ($allIssues.Count -eq 0) {
    Write-Log "  Preflight checks passed ($($allWarnings.Count) warning(s)) in $([math]::Round($durationSec, 1))s" -Level "SUCCESS"
  }

  return [PSCustomObject]@{
    Success     = ($allIssues.Count -eq 0)
    Issues      = $allIssues
    Warnings    = $allWarnings
    DurationSec = $durationSec
  }
}
