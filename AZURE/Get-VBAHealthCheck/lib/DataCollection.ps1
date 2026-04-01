# SPDX-License-Identifier: MIT
# =========================================================================
# DataCollection.ps1 - VBA REST API data retrieval functions
# =========================================================================
# Each function calls Invoke-VBAApi / Invoke-VBAApiPaginated and returns
# structured data. Failures are caught and logged; partial results returned.
# =========================================================================

# =============================
# System & Appliance
# =============================

<#
.SYNOPSIS
  Retrieves system information from the VBA appliance.
.OUTPUTS
  Hashtable with About, ServerInfo, Status, and ServiceIsUp keys.
#>
function Get-VBASystemInfo {
  Write-ProgressStep -Activity "System Health" -Status "Querying appliance info..."

  $systemData = @{
    ServiceIsUp = $true
    About = $null
    ServerInfo = $null
    Status = $null
  }

  try {
    $systemData.About = Invoke-VBAApi -Endpoint "/api/v8.1/system/about"
    Write-Log "Appliance version: $($systemData.About.serverVersion)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve system version info: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $systemData.ServerInfo = Invoke-VBAApi -Endpoint "/api/v8.1/system/serverInfo"
    Write-Log "Appliance region: $($systemData.ServerInfo.azureRegionName)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve server info: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $systemData.Status = Invoke-VBAApi -Endpoint "/api/v8.1/system/status"
    Write-Log "System state: $($systemData.Status.state)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve system status: $($_.Exception.Message)" -Level "WARNING"
  }

  return $systemData
}

# =============================
# License
# =============================

<#
.SYNOPSIS
  Retrieves license information and per-resource license state.
.OUTPUTS
  Hashtable with License and Resources keys.
#>
function Get-VBALicenseInfo {
  Write-ProgressStep -Activity "License Health" -Status "Checking license status..."

  $licenseData = @{
    License = $null
    Resources = @()
  }

  try {
    $licenseData.License = Invoke-VBAApi -Endpoint "/api/v8.1/license"
    $licType = if ($licenseData.License.isFreeEdition) { "Free Edition" } else { $licenseData.License.licenseType }
    Write-Log "License type: $licType, instances: $($licenseData.License.totalInstancesUses)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve license info: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $licenseData.Resources = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/license/resources"
    if ($null -eq $licenseData.Resources) { $licenseData.Resources = @() }
    Write-Log "License resources: $(@($licenseData.Resources).Count) items" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve license resources: $($_.Exception.Message)" -Level "WARNING"
  }

  return $licenseData
}

# =============================
# Configuration Check
# =============================

<#
.SYNOPSIS
  Triggers VBA's built-in configuration check and polls for results.
.PARAMETER TimeoutSeconds
  Max seconds to wait for check completion.
.OUTPUTS
  Configuration check result object.
#>
function Start-VBAConfigurationCheck {
  param([int]$TimeoutSeconds = 120)

  Write-ProgressStep -Activity "Configuration Check" -Status "Running VBA configuration check..."

  $configData = $null

  # Trigger the check
  try {
    $null = Invoke-VBAApi -Endpoint "/api/v8.1/configuration/check" -Method "POST"
    Write-Log "Configuration check triggered" -Level "INFO"
  }
  catch {
    Write-Log "Failed to trigger configuration check: $($_.Exception.Message)" -Level "WARNING"
    # Try to read existing results
    try {
      $configData = Invoke-VBAApi -Endpoint "/api/v8.1/configuration/checkSession"
      return $configData
    }
    catch {
      Write-Log "No configuration check results available" -Level "WARNING"
      return $null
    }
  }

  # Poll for results
  $elapsed = 0
  $pollInterval = 5
  while ($elapsed -lt $TimeoutSeconds) {
    Start-Sleep -Seconds $pollInterval
    $elapsed += $pollInterval

    try {
      $configData = Invoke-VBAApi -Endpoint "/api/v8.1/configuration/checkSession"

      $status = $configData.overallStatus
      if ($status -ne "Running" -and $status -ne "Unknown") {
        Write-Log "Configuration check completed: $status" -Level "INFO"
        return $configData
      }
    }
    catch {
      Write-Log "Error polling configuration check: $($_.Exception.Message)" -Level "WARNING"
    }
  }

  Write-Log "Configuration check timed out after ${TimeoutSeconds}s" -Level "WARNING"
  return $configData
}

# =============================
# Protection Coverage
# =============================

<#
.SYNOPSIS
  Retrieves the protected workloads overview report.
.OUTPUTS
  Protected workloads report object.
#>
function Get-VBAProtectedWorkloads {
  Write-ProgressStep -Activity "Protection Coverage" -Status "Analyzing workload protection..."

  $workloads = $null
  try {
    $workloads = Invoke-VBAApi -Endpoint "/api/v8.1/overview/protectedWorkloads"
    Write-Log "VMs: $($workloads.virtualMachinesProtectedCount)/$($workloads.virtualMachinesTotalCount) protected" -Level "INFO"
    Write-Log "SQL: $($workloads.sqlDatabasesProtectedCount)/$($workloads.sqlDatabasesTotalCount) protected" -Level "INFO"
    Write-Log "File Shares: $($workloads.fileSharesProtectedCount)/$($workloads.fileSharesTotalCount) protected" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve protected workloads: $($_.Exception.Message)" -Level "WARNING"
  }

  return $workloads
}

<#
.SYNOPSIS
  Retrieves lists of unprotected resources by type.
.OUTPUTS
  Hashtable with VMs, SQL, FileShares, and CosmosDB keys.
#>
function Get-VBAUnprotectedResources {
  $unprotected = @{
    VMs = @()
    SQL = @()
    FileShares = @()
    CosmosDB = @()
  }

  try {
    $unprotected.VMs = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/virtualMachines" -QueryParams @{ ProtectionStatus = "Unprotected" }
    if ($null -eq $unprotected.VMs) { $unprotected.VMs = @() }
    Write-Log "Unprotected VMs: $(@($unprotected.VMs).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve unprotected VMs: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $unprotected.SQL = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/databases" -QueryParams @{ ProtectionStatus = "Unprotected" }
    if ($null -eq $unprotected.SQL) { $unprotected.SQL = @() }
    Write-Log "Unprotected SQL databases: $(@($unprotected.SQL).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve unprotected SQL databases: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $unprotected.FileShares = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/fileShares" -QueryParams @{ ProtectionStatus = "Unprotected" }
    if ($null -eq $unprotected.FileShares) { $unprotected.FileShares = @() }
    Write-Log "Unprotected file shares: $(@($unprotected.FileShares).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve unprotected file shares: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $unprotected.CosmosDB = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/cosmosDb" -QueryParams @{ ProtectionStatus = "Unprotected" }
    if ($null -eq $unprotected.CosmosDB) { $unprotected.CosmosDB = @() }
    Write-Log "Unprotected Cosmos DB accounts: $(@($unprotected.CosmosDB).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve unprotected Cosmos DB accounts: $($_.Exception.Message)" -Level "WARNING"
  }

  return $unprotected
}

# =============================
# Protected Items Inventory
# =============================

<#
.SYNOPSIS
  Retrieves protected item inventories with last backup time, policy, and restore point data.
.OUTPUTS
  Hashtable with VMs, SQL, and FileShares keys.
#>
function Get-VBAProtectedItemInventory {
  Write-ProgressStep -Activity "Protected Items" -Status "Retrieving backup inventory..."

  $protectedItems = @{
    VMs = @()
    SQL = @()
    FileShares = @()
  }

  try {
    $protectedItems.VMs = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/protectedItem/virtualMachines"
    if ($null -eq $protectedItems.VMs) { $protectedItems.VMs = @() }
    Write-Log "Protected VMs with backup data: $(@($protectedItems.VMs).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve protected VM items: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $protectedItems.SQL = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/protectedItem/sql"
    if ($null -eq $protectedItems.SQL) { $protectedItems.SQL = @() }
    Write-Log "Protected SQL databases with backup data: $(@($protectedItems.SQL).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve protected SQL items: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $protectedItems.FileShares = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/protectedItem/fileShares"
    if ($null -eq $protectedItems.FileShares) { $protectedItems.FileShares = @() }
    Write-Log "Protected file shares with backup data: $(@($protectedItems.FileShares).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve protected file share items: $($_.Exception.Message)" -Level "WARNING"
  }

  return $protectedItems
}

# =============================
# Policies
# =============================

<#
.SYNOPSIS
  Retrieves all backup policies across workload types.
.OUTPUTS
  Hashtable with VM, SQL, FileShare, CosmosDB, VNet, and SLA keys.
#>
function Get-VBAPolicies {
  Write-ProgressStep -Activity "Policy Health" -Status "Retrieving backup policies..."

  $policies = @{
    VM = @()
    SQL = @()
    FileShare = @()
    CosmosDB = @()
    VNet = $null
    SLA = @()
  }

  try {
    $policies.VM = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policies/virtualMachines"
    if ($null -eq $policies.VM) { $policies.VM = @() }
    Write-Log "VM backup policies: $(@($policies.VM).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve VM policies: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $policies.SQL = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policies/sql"
    if ($null -eq $policies.SQL) { $policies.SQL = @() }
    Write-Log "SQL backup policies: $(@($policies.SQL).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve SQL policies: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $policies.FileShare = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policies/fileShares"
    if ($null -eq $policies.FileShare) { $policies.FileShare = @() }
    Write-Log "File share backup policies: $(@($policies.FileShare).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve file share policies: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $policies.CosmosDB = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policies/cosmosDb"
    if ($null -eq $policies.CosmosDB) { $policies.CosmosDB = @() }
    Write-Log "Cosmos DB backup policies: $(@($policies.CosmosDB).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve Cosmos DB policies: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $policies.VNet = Invoke-VBAApi -Endpoint "/api/v8.1/policy/vnet"
    Write-Log "VNet policy: $(if($policies.VNet.isEnabled){'Enabled'}else{'Disabled'})" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve VNet policy: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $policies.SLA = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policy/slaBased/virtualMachines"
    if ($null -eq $policies.SLA) { $policies.SLA = @() }
    Write-Log "SLA-based policies: $(@($policies.SLA).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve SLA-based policies: $($_.Exception.Message)" -Level "WARNING"
  }

  return $policies
}

<#
.SYNOPSIS
  Retrieves the SLA compliance report for SLA-based policies.
.OUTPUTS
  Array of SLA report entries.
#>
function Get-VBASLAReport {
  $slaReport = @()
  try {
    $slaReport = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/policy/slaBased/virtualMachines/slaReport"
    if ($null -eq $slaReport) { $slaReport = @() }
    Write-Log "SLA compliance entries: $(@($slaReport).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve SLA report: $($_.Exception.Message)" -Level "WARNING"
  }
  return $slaReport
}

# =============================
# Sessions
# =============================

<#
.SYNOPSIS
  Retrieves the sessions summary report.
.OUTPUTS
  Sessions summary report object.
#>
function Get-VBASessionsSummary {
  Write-ProgressStep -Activity "Session Health" -Status "Analyzing backup sessions..."

  $summary = $null
  try {
    $summary = Invoke-VBAApi -Endpoint "/api/v8.1/overview/sessionsSummary"
    Write-Log "Sessions - Success: $($summary.latestSessionsSuccessCount), Warnings: $($summary.latestSessionsWarningCount), Errors: $($summary.latestSessionsErrorCount)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve sessions summary: $($_.Exception.Message)" -Level "WARNING"
  }
  return $summary
}

<#
.SYNOPSIS
  Retrieves recent failed job sessions.
.PARAMETER Limit
  Maximum number of failed sessions to retrieve.
.OUTPUTS
  Array of failed session objects.
#>
function Get-VBAFailedSessions {
  param([int]$Limit = 50)

  $failed = @()
  try {
    $failed = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/jobSessions" -QueryParams @{ Status = "Error"; Limit = $Limit }
    if ($null -eq $failed) { $failed = @() }
    Write-Log "Failed sessions retrieved: $(@($failed).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve failed sessions: $($_.Exception.Message)" -Level "WARNING"
  }
  return $failed
}

<#
.SYNOPSIS
  Retrieves top policies by execution duration.
.OUTPUTS
  Top policies duration report object.
#>
function Get-VBATopPoliciesDuration {
  $topDuration = $null
  try {
    $topDuration = Invoke-VBAApi -Endpoint "/api/v8.1/overview/topPoliciesDuration" -QueryParams @{ source = "all"; count = 10 }
  }
  catch {
    Write-Log "Failed to retrieve policy duration data: $($_.Exception.Message)" -Level "WARNING"
  }
  return $topDuration
}

# =============================
# Repositories
# =============================

<#
.SYNOPSIS
  Retrieves all configured repositories.
.OUTPUTS
  Array of repository objects.
#>
function Get-VBARepositories {
  Write-ProgressStep -Activity "Repository Health" -Status "Checking repositories..."

  $repos = @()
  try {
    $repos = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/repositories"
    if ($null -eq $repos) { $repos = @() }
    Write-Log "Repositories: $(@($repos).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve repositories: $($_.Exception.Message)" -Level "WARNING"
  }
  return $repos
}

# =============================
# Workers
# =============================

<#
.SYNOPSIS
  Retrieves all worker instances.
.OUTPUTS
  Array of worker objects.
#>
function Get-VBAWorkers {
  Write-ProgressStep -Activity "Worker Health" -Status "Checking worker instances..."

  $workers = @()
  try {
    $workers = Invoke-VBAApiPaginated -Endpoint "/api/v8.1/workers"
    if ($null -eq $workers) { $workers = @() }
    Write-Log "Workers: $(@($workers).Count)" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve workers: $($_.Exception.Message)" -Level "WARNING"
  }
  return $workers
}

<#
.SYNOPSIS
  Retrieves aggregate worker statistics.
.OUTPUTS
  Worker statistics object.
#>
function Get-VBAWorkerStatistics {
  $stats = $null
  try {
    $stats = Invoke-VBAApi -Endpoint "/api/v8.1/workers/statistics"
  }
  catch {
    Write-Log "Failed to retrieve worker statistics: $($_.Exception.Message)" -Level "WARNING"
  }
  return $stats
}

<#
.SYNOPSIS
  Retrieves infrastructure bottleneck indicators.
.OUTPUTS
  Bottlenecks overview report object.
#>
function Get-VBABottlenecks {
  $bottlenecks = $null
  try {
    $bottlenecks = Invoke-VBAApi -Endpoint "/api/v8.1/overview/bottlenecksOverview"
  }
  catch {
    Write-Log "Failed to retrieve bottleneck data: $($_.Exception.Message)" -Level "WARNING"
  }
  return $bottlenecks
}

# =============================
# Configuration Backup
# =============================

<#
.SYNOPSIS
  Retrieves configuration backup settings and appliance statistics.
.OUTPUTS
  Hashtable with Settings and Stats keys.
#>
function Get-VBAConfigBackup {
  Write-ProgressStep -Activity "Configuration Backup" -Status "Checking config backup..."

  $configBackup = @{
    Settings = $null
    Stats = $null
  }

  try {
    $configBackup.Settings = Invoke-VBAApi -Endpoint "/api/v8.1/configurationBackup/settings"
    $enabled = if ($configBackup.Settings.isEnabled) { "Enabled" } else { "Disabled" }
    Write-Log "Configuration backup: $enabled" -Level "INFO"
  }
  catch {
    Write-Log "Failed to retrieve config backup settings: $($_.Exception.Message)" -Level "WARNING"
  }

  try {
    $configBackup.Stats = Invoke-VBAApi -Endpoint "/api/v8.1/configurationBackup/stats"
  }
  catch {
    Write-Log "Failed to retrieve config backup stats: $($_.Exception.Message)" -Level "WARNING"
  }

  return $configBackup
}

# =============================
# Storage Usage
# =============================

<#
.SYNOPSIS
  Retrieves storage usage overview.
.OUTPUTS
  Storage usage report object.
#>
function Get-VBAStorageUsage {
  $storageUsage = $null
  try {
    $storageUsage = Invoke-VBAApi -Endpoint "/api/v8.1/overview/storageUsage"
  }
  catch {
    Write-Log "Failed to retrieve storage usage: $($_.Exception.Message)" -Level "WARNING"
  }
  return $storageUsage
}

# =============================
# Overview Statistics
# =============================

<#
.SYNOPSIS
  Retrieves policy summary statistics.
.OUTPUTS
  Policy statistics report object.
#>
function Get-VBAOverviewStatistics {
  $stats = $null
  try {
    $stats = Invoke-VBAApi -Endpoint "/api/v8.1/overview/statistics"
  }
  catch {
    Write-Log "Failed to retrieve overview statistics: $($_.Exception.Message)" -Level "WARNING"
  }
  return $stats
}
