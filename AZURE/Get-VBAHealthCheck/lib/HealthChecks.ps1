# SPDX-License-Identifier: MIT
# =========================================================================
# HealthChecks.ps1 - Findings engine and health score calculation
# =========================================================================
# Evaluates collected API data and generates findings with severity levels.
# All findings are algorithmically derived from actual data.
# =========================================================================

# =============================
# Findings Tracker
# =============================

<#
.SYNOPSIS
  Adds a finding to the global findings list.
.PARAMETER Category
  Health check category name.
.PARAMETER Status
  Finding severity: Healthy, Warning, or Critical.
.PARAMETER Check
  Short check name.
.PARAMETER Detail
  Detailed description of the finding.
.PARAMETER Recommendation
  Actionable recommendation.
.PARAMETER Resource
  Affected resource name.
#>
function Add-Finding {
  param(
    [Parameter(Mandatory=$true)][string]$Category,
    [Parameter(Mandatory=$true)][ValidateSet("Healthy","Warning","Critical")]
    [string]$Status,
    [Parameter(Mandatory=$true)][string]$Check,
    [Parameter(Mandatory=$true)][string]$Detail,
    [string]$Recommendation = "",
    [string]$Resource = ""
  )

  $script:Findings.Add([PSCustomObject]@{
    Category = $Category
    Status = $Status
    Check = $Check
    Detail = $Detail
    Recommendation = $Recommendation
    Resource = $Resource
  })
}

# =============================
# System Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates system health from appliance data.
#>
function Invoke-SystemHealthChecks {
  param($SystemData)

  $cat = "System Health"

  # Service availability
  if ($SystemData.ServiceIsUp) {
    Add-Finding -Category $cat -Status "Healthy" -Check "Service Availability" `
      -Detail "VBA appliance services are running"
  }
  else {
    Add-Finding -Category $cat -Status "Critical" -Check "Service Availability" `
      -Detail "VBA appliance services are not responding" `
      -Recommendation "Check the VBA appliance VM status and restart services if needed"
  }

  # System state
  if ($null -ne $SystemData.Status) {
    if ($SystemData.Status.state -eq "Ready") {
      Add-Finding -Category $cat -Status "Healthy" -Check "System State" `
        -Detail "System is in Ready state"
    }
    elseif ($SystemData.Status.state -eq "Upgrading") {
      Add-Finding -Category $cat -Status "Warning" -Check "System State" `
        -Detail "System is currently upgrading" `
        -Recommendation "Wait for the upgrade to complete before running backup operations"
    }
    else {
      Add-Finding -Category $cat -Status "Critical" -Check "System State" `
        -Detail "System state is: $($SystemData.Status.state)" `
        -Recommendation "Investigate the appliance status and check system logs"
    }
  }

  # Version info
  if ($null -ne $SystemData.About) {
    Add-Finding -Category $cat -Status "Healthy" -Check "Appliance Version" `
      -Detail "Server: $($SystemData.About.serverVersion), Worker: $($SystemData.About.workerVersion), FLR: $($SystemData.About.flrVersion)"
  }

  # Disabled sections
  if ($null -ne $SystemData.ServerInfo -and $SystemData.ServerInfo.DisabledSections) {
    $disabled = $SystemData.ServerInfo.DisabledSections
    if ($disabled -and $disabled.Count -gt 0) {
      Add-Finding -Category $cat -Status "Warning" -Check "Disabled Features" `
        -Detail "The following features are disabled: $($disabled -join ', ')" `
        -Recommendation "Review disabled features and enable them if they are needed for protection"
    }
  }
}

# =============================
# License Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates license health.
#>
function Invoke-LicenseHealthChecks {
  param($LicenseData, [int]$ExpiryWarningDays)

  $cat = "License Health"
  $lic = $LicenseData.License

  if ($null -eq $lic) {
    Add-Finding -Category $cat -Status "Warning" -Check "License Status" `
      -Detail "Unable to retrieve license information" `
      -Recommendation "Verify the API user has permission to read license data"
    return
  }

  # Free edition check
  if ($lic.isFreeEdition) {
    Add-Finding -Category $cat -Status "Critical" -Check "License Type" `
      -Detail "Running on Free Edition - limited to 10 instances with restricted features" `
      -Recommendation "Upgrade to a paid license for full protection capabilities"
    return
  }

  # License expiry
  if ($lic.licenseExpires) {
    try {
      $expiryDate = [datetime]::Parse($lic.licenseExpires)
      $daysUntilExpiry = ($expiryDate - (Get-Date)).Days

      if ($daysUntilExpiry -le 0) {
        Add-Finding -Category $cat -Status "Critical" -Check "License Expiry" `
          -Detail "License expired on $($expiryDate.ToString('yyyy-MM-dd'))" `
          -Recommendation "Renew the license immediately to prevent backup operations from stopping"
      }
      elseif ($daysUntilExpiry -le $ExpiryWarningDays) {
        Add-Finding -Category $cat -Status "Warning" -Check "License Expiry" `
          -Detail "License expires in $daysUntilExpiry days ($($expiryDate.ToString('yyyy-MM-dd')))" `
          -Recommendation "Plan license renewal before expiry"
      }
      else {
        Add-Finding -Category $cat -Status "Healthy" -Check "License Expiry" `
          -Detail "License valid until $($expiryDate.ToString('yyyy-MM-dd')) ($daysUntilExpiry days remaining)"
      }
    }
    catch {
      Add-Finding -Category $cat -Status "Healthy" -Check "License Expiry" `
        -Detail "License expiry: $($lic.licenseExpires)"
    }
  }

  # Instance usage
  if ($lic.instances -gt 0 -and $lic.totalInstancesUses -gt 0) {
    $usagePct = [math]::Round(($lic.totalInstancesUses / $lic.instances) * 100, 1)
    if ($usagePct -ge 100) {
      Add-Finding -Category $cat -Status "Critical" -Check "Instance Usage" `
        -Detail "License instances exceeded: $($lic.totalInstancesUses) used of $($lic.instances) licensed ($usagePct%)" `
        -Recommendation "Increase licensed instance count or remove unused protected workloads"
    }
    elseif ($usagePct -ge 80) {
      Add-Finding -Category $cat -Status "Warning" -Check "Instance Usage" `
        -Detail "License instances approaching limit: $($lic.totalInstancesUses) of $($lic.instances) used ($usagePct%)" `
        -Recommendation "Monitor instance usage and plan for additional licenses"
    }
    else {
      Add-Finding -Category $cat -Status "Healthy" -Check "Instance Usage" `
        -Detail "License instances: $($lic.totalInstancesUses) of $($lic.instances) used ($usagePct%)"
    }
  }

  # Grace period
  if ($lic.gracePeriodDays -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Grace Period" `
      -Detail "License is in grace period ($($lic.gracePeriodDays) days remaining)" `
      -Recommendation "Activate or renew the license before the grace period ends"
  }

  # Per-resource license state
  $exceeded = @($LicenseData.Resources | Where-Object { $_.licensedState -eq "Exceeded" })
  $graced = @($LicenseData.Resources | Where-Object { $_.licensedState -eq "Graced" })

  if ($exceeded.Count -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Exceeded Resources" `
      -Detail "$($exceeded.Count) resources in Exceeded license state" `
      -Recommendation "Review license allocation for exceeded resources"
  }
  if ($graced.Count -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Graced Resources" `
      -Detail "$($graced.Count) resources in Graced license state" `
      -Recommendation "Ensure graced resources are properly licensed before grace period ends"
  }
}

# =============================
# Configuration Check Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates VBA's built-in configuration check results.
#>
function Invoke-ConfigurationCheckHealthChecks {
  param($ConfigCheckData)

  $cat = "Configuration Check"

  if ($null -eq $ConfigCheckData) {
    Add-Finding -Category $cat -Status "Warning" -Check "Configuration Check" `
      -Detail "Configuration check could not be executed" `
      -Recommendation "Verify the API user has administrative permissions"
    return
  }

  # Overall status
  switch ($ConfigCheckData.overallStatus) {
    "Success" {
      Add-Finding -Category $cat -Status "Healthy" -Check "Overall Configuration" `
        -Detail "VBA configuration check passed successfully"
    }
    "Warning" {
      Add-Finding -Category $cat -Status "Warning" -Check "Overall Configuration" `
        -Detail "VBA configuration check completed with warnings" `
        -Recommendation "Review the configuration check details and address warnings"
    }
    "VerificationNeeded" {
      Add-Finding -Category $cat -Status "Warning" -Check "Overall Configuration" `
        -Detail "VBA configuration requires manual verification" `
        -Recommendation "Log in to the VBA console and verify the flagged configuration items"
    }
    "Failed" {
      Add-Finding -Category $cat -Status "Critical" -Check "Overall Configuration" `
        -Detail "VBA configuration check failed" `
        -Recommendation "Address all configuration failures immediately"
    }
    default {
      Add-Finding -Category $cat -Status "Warning" -Check "Overall Configuration" `
        -Detail "Configuration check status: $($ConfigCheckData.overallStatus)"
    }
  }

  # Process individual log lines
  if ($ConfigCheckData.logLine) {
    foreach ($line in $ConfigCheckData.logLine) {
      $lineStatus = "Healthy"
      if ($line.status -eq "Failed" -or $line.status -eq "Error") { $lineStatus = "Critical" }
      elseif ($line.status -eq "Warning" -or $line.status -eq "VerificationNeeded") { $lineStatus = "Warning" }

      if ($lineStatus -ne "Healthy") {
        $lineTitle = if ($line.title) { $line.title } else { "Configuration Item" }
        $lineResult = if ($line.result) { $line.result } else { $line.status }
        Add-Finding -Category $cat -Status $lineStatus -Check $lineTitle `
          -Detail $lineResult
      }
    }
  }

  # Check response details
  $checkResp = $ConfigCheckData.checkResponse
  if ($null -ne $checkResp) {
    # Missing roles
    if ($null -ne $checkResp.missingRoles -and $checkResp.missingRoles.accounts) {
      $missingCount = @($checkResp.missingRoles.accounts).Count
      if ($missingCount -gt 0) {
        Add-Finding -Category $cat -Status "Critical" -Check "Azure Role Assignments" `
          -Detail "$missingCount service account(s) have missing Azure role assignments" `
          -Recommendation "Assign the required Azure roles to all VBA service accounts"
      }
    }

    # Worker configuration
    if ($null -ne $checkResp.workerConfiguration -and $checkResp.workerConfiguration.workerConfigurations) {
      $workerIssues = @($checkResp.workerConfiguration.workerConfigurations | Where-Object { $_.severity -ne "Success" -and $_.severity -ne "None" })
      if ($workerIssues.Count -gt 0) {
        Add-Finding -Category $cat -Status "Warning" -Check "Worker Configuration" `
          -Detail "$($workerIssues.Count) worker configuration issue(s) detected" `
          -Recommendation "Review worker network and profile settings for affected regions"
      }
    }

    # Repository issues
    if ($null -ne $checkResp.repositories -and $checkResp.repositories.repositories) {
      $repoIssues = @($checkResp.repositories.repositories | Where-Object { $_.severity -ne "Success" -and $_.severity -ne "None" })
      if ($repoIssues.Count -gt 0) {
        Add-Finding -Category $cat -Status "Warning" -Check "Repository Configuration" `
          -Detail "$($repoIssues.Count) repository configuration issue(s) detected" `
          -Recommendation "Review repository access and configuration settings"
      }
    }

    # Repository encryption
    if ($null -ne $checkResp.repositoryEncryption -and $checkResp.repositoryEncryption.repositories) {
      $unencrypted = @($checkResp.repositoryEncryption.repositories | Where-Object { -not $_.isEncrypted })
      if ($unencrypted.Count -gt 0) {
        Add-Finding -Category $cat -Status "Warning" -Check "Repository Encryption" `
          -Detail "$($unencrypted.Count) repository(s) without encryption" `
          -Recommendation "Enable encryption on all backup repositories for data protection"
      }
    }

    # MFA users
    if ($null -ne $checkResp.mfaUsers -and $checkResp.mfaUsers.users) {
      $noMfa = @($checkResp.mfaUsers.users)
      if ($noMfa.Count -gt 0) {
        Add-Finding -Category $cat -Status "Critical" -Check "MFA Configuration" `
          -Detail "$($noMfa.Count) user(s) without multi-factor authentication enabled" `
          -Recommendation "Enable MFA for all VBA console users to prevent unauthorized access"
      }
    }

    # SSO configuration
    if ($null -ne $checkResp.ssoConfiguration) {
      $ssoStatus = "$($checkResp.ssoConfiguration)"
      if ($ssoStatus -eq "NotConfiguredAtAll") {
        Add-Finding -Category $cat -Status "Warning" -Check "SSO Configuration" `
          -Detail "Single Sign-On is not configured" `
          -Recommendation "Configure SSO with your identity provider for centralized authentication"
      }
    }
  }
}

# =============================
# Protection Coverage Checks
# =============================

<#
.SYNOPSIS
  Evaluates workload protection coverage.
#>
function Invoke-ProtectionCoverageHealthChecks {
  param($WorkloadsReport, $UnprotectedResources, $ProtectedItems, [int]$RPOThresholdHours = 24)

  $cat = "Protection Coverage"

  if ($null -eq $WorkloadsReport) {
    Add-Finding -Category $cat -Status "Warning" -Check "Protection Data" `
      -Detail "Unable to retrieve workload protection data" `
      -Recommendation "Verify API permissions and appliance connectivity"
    return
  }

  # VM coverage
  $vmTotal = [int]$WorkloadsReport.virtualMachinesTotalCount
  $vmProtected = [int]$WorkloadsReport.virtualMachinesProtectedCount
  if ($vmTotal -gt 0) {
    $vmPct = [math]::Round(($vmProtected / $vmTotal) * 100, 1)
    if ($vmPct -ge 90) {
      Add-Finding -Category $cat -Status "Healthy" -Check "VM Backup Coverage" `
        -Detail "$vmProtected of $vmTotal VMs protected ($vmPct%)"
    }
    elseif ($vmPct -ge 50) {
      Add-Finding -Category $cat -Status "Warning" -Check "VM Backup Coverage" `
        -Detail "$vmProtected of $vmTotal VMs protected ($vmPct%)" `
        -Recommendation "Create backup policies for unprotected VMs to improve coverage"
    }
    else {
      Add-Finding -Category $cat -Status "Critical" -Check "VM Backup Coverage" `
        -Detail "$vmProtected of $vmTotal VMs protected ($vmPct%)" `
        -Recommendation "Immediate action required: most VMs are unprotected"
    }
  }
  else {
    Add-Finding -Category $cat -Status "Healthy" -Check "VM Backup Coverage" `
      -Detail "No VMs discovered in scope"
  }

  # SQL coverage
  $sqlTotal = [int]$WorkloadsReport.sqlDatabasesTotalCount
  $sqlProtected = [int]$WorkloadsReport.sqlDatabasesProtectedCount
  if ($sqlTotal -gt 0) {
    $sqlPct = [math]::Round(($sqlProtected / $sqlTotal) * 100, 1)
    if ($sqlPct -ge 90) {
      Add-Finding -Category $cat -Status "Healthy" -Check "SQL Backup Coverage" `
        -Detail "$sqlProtected of $sqlTotal SQL databases protected ($sqlPct%)"
    }
    elseif ($sqlPct -ge 50) {
      Add-Finding -Category $cat -Status "Warning" -Check "SQL Backup Coverage" `
        -Detail "$sqlProtected of $sqlTotal SQL databases protected ($sqlPct%)" `
        -Recommendation "Create SQL backup policies for unprotected databases"
    }
    else {
      Add-Finding -Category $cat -Status "Critical" -Check "SQL Backup Coverage" `
        -Detail "$sqlProtected of $sqlTotal SQL databases protected ($sqlPct%)" `
        -Recommendation "Immediate action required: most SQL databases are unprotected"
    }
  }

  # File share coverage
  $fsTotal = [int]$WorkloadsReport.fileSharesTotalCount
  $fsProtected = [int]$WorkloadsReport.fileSharesProtectedCount
  if ($fsTotal -gt 0) {
    $fsPct = [math]::Round(($fsProtected / $fsTotal) * 100, 1)
    if ($fsPct -ge 80) {
      Add-Finding -Category $cat -Status "Healthy" -Check "File Share Backup Coverage" `
        -Detail "$fsProtected of $fsTotal file shares protected ($fsPct%)"
    }
    elseif ($fsPct -ge 40) {
      Add-Finding -Category $cat -Status "Warning" -Check "File Share Backup Coverage" `
        -Detail "$fsProtected of $fsTotal file shares protected ($fsPct%)" `
        -Recommendation "Extend file share protection policies to unprotected shares"
    }
    else {
      Add-Finding -Category $cat -Status "Critical" -Check "File Share Backup Coverage" `
        -Detail "$fsProtected of $fsTotal file shares protected ($fsPct%)" `
        -Recommendation "Immediate action required: most file shares are unprotected"
    }
  }

  # Cosmos DB coverage
  $cosmosCount = @($UnprotectedResources.CosmosDB).Count
  if ($cosmosCount -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Cosmos DB Backup Coverage" `
      -Detail "$cosmosCount Cosmos DB account(s) without backup protection" `
      -Recommendation "Configure backup policies for unprotected Cosmos DB accounts"
  }

  # Stale backup detection — protected VMs that haven't backed up within RPO threshold
  if ($null -ne $ProtectedItems -and @($ProtectedItems.VMs).Count -gt 0) {
    $rpoThreshold = (Get-Date).AddHours(-$RPOThresholdHours)
    $staleVMs = New-Object System.Collections.Generic.List[string]
    foreach ($vm in @($ProtectedItems.VMs)) {
      if ($vm.lastBackup) {
        try {
          $lastBkp = [datetime]::Parse("$($vm.lastBackup)")
          if ($lastBkp -lt $rpoThreshold) {
            $staleVMs.Add("$($vm.name)")
          }
        }
        catch {
          $null = $_ # skip unparseable dates
        }
      }
    }
    if ($staleVMs.Count -gt 0) {
      $names = ($staleVMs | Select-Object -First 5) -join ", "
      $suffix = if ($staleVMs.Count -gt 5) { " and $($staleVMs.Count - 5) more" } else { "" }
      Add-Finding -Category $cat -Status "Warning" -Check "Stale VM Backups" `
        -Detail "$($staleVMs.Count) protected VM(s) have not been backed up in the last ${RPOThresholdHours}h: $names$suffix" `
        -Recommendation "Investigate backup schedules and session failures for these VMs"
    }
    else {
      Add-Finding -Category $cat -Status "Healthy" -Check "RPO Compliance" `
        -Detail "All protected VMs have been backed up within the ${RPOThresholdHours}h RPO threshold"
    }

    # Low restore point detection
    $lowRp = @($ProtectedItems.VMs | Where-Object {
      $null -ne $_.protectionState -and
      $null -ne $_.protectionState.restorePointCount -and
      [int]$_.protectionState.restorePointCount -le 1
    })
    if ($lowRp.Count -gt 0) {
      Add-Finding -Category $cat -Status "Warning" -Check "Low Restore Points" `
        -Detail "$($lowRp.Count) protected VM(s) have 1 or fewer restore points" `
        -Recommendation "Review retention policies — limited restore points increase recovery risk"
    }
  }
}

# =============================
# Policy Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates backup policy configuration and status.
#>
function Invoke-PolicyHealthChecks {
  param($Policies, $SLAReport, [int]$SLATarget)

  $cat = "Policy Health"

  # Aggregate all policies
  $allPolicies = New-Object System.Collections.Generic.List[object]
  foreach ($p in @($Policies.VM)) { $allPolicies.Add($p) }
  foreach ($p in @($Policies.SQL)) { $allPolicies.Add($p) }
  foreach ($p in @($Policies.FileShare)) { $allPolicies.Add($p) }
  foreach ($p in @($Policies.CosmosDB)) { $allPolicies.Add($p) }

  if ($allPolicies.Count -eq 0 -and @($Policies.SLA).Count -eq 0) {
    Add-Finding -Category $cat -Status "Critical" -Check "Backup Policies" `
      -Detail "No backup policies are configured" `
      -Recommendation "Create backup policies to protect your Azure workloads"
    return
  }

  Add-Finding -Category $cat -Status "Healthy" -Check "Backup Policies" `
    -Detail "Total policies configured: $($allPolicies.Count) schedule-based, $(@($Policies.SLA).Count) SLA-based"

  # Check for error states
  $errorPolicies = @($allPolicies | Where-Object {
    $_.backupStatus -eq "Error" -or $_.snapshotStatus -eq "Error" -or $_.archiveStatus -eq "Error"
  })
  if ($errorPolicies.Count -gt 0) {
    $names = ($errorPolicies | Select-Object -First 5 | ForEach-Object { $_.name }) -join ", "
    Add-Finding -Category $cat -Status "Critical" -Check "Policy Errors" `
      -Detail "$($errorPolicies.Count) policy(s) in error state: $names" `
      -Recommendation "Investigate and resolve policy errors to restore backup protection"
  }

  # Check for warning states
  $warningPolicies = @($allPolicies | Where-Object {
    ($_.backupStatus -eq "Warning" -or $_.snapshotStatus -eq "Warning") -and
    $_.backupStatus -ne "Error" -and $_.snapshotStatus -ne "Error"
  })
  if ($warningPolicies.Count -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Policy Warnings" `
      -Detail "$($warningPolicies.Count) policy(s) completed with warnings" `
      -Recommendation "Review policy execution logs for warning details"
  }

  # Check for disabled policies
  $disabledPolicies = @($allPolicies | Where-Object { -not $_.isEnabled })
  if ($disabledPolicies.Count -gt 0) {
    $names = ($disabledPolicies | Select-Object -First 5 | ForEach-Object { $_.name }) -join ", "
    Add-Finding -Category $cat -Status "Warning" -Check "Disabled Policies" `
      -Detail "$($disabledPolicies.Count) policy(s) are disabled: $names" `
      -Recommendation "Enable disabled policies or remove them if no longer needed"
  }

  # Check for policies that have never executed
  $neverRun = @($allPolicies | Where-Object {
    $_.backupStatus -eq "NeverExecuted" -and $_.snapshotStatus -eq "NeverExecuted"
  })
  if ($neverRun.Count -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Unexecuted Policies" `
      -Detail "$($neverRun.Count) policy(s) have never been executed" `
      -Recommendation "Verify policy schedules and trigger a manual run to validate configuration"
  }

  # SLA compliance
  if (@($SLAReport).Count -gt 0) {
    $missedSla = @($SLAReport | Where-Object {
      $_.snapshotSlaReport.status -eq "MissedSla" -or
      $_.backupSlaReport.status -eq "MissedSla"
    })

    if ($missedSla.Count -gt 0) {
      $pctMet = [math]::Round(((@($SLAReport).Count - $missedSla.Count) / @($SLAReport).Count) * 100, 1)
      if ($pctMet -lt 90) {
        Add-Finding -Category $cat -Status "Critical" -Check "SLA Compliance" `
          -Detail "$($missedSla.Count) of $(@($SLAReport).Count) SLA policies missed their targets ($pctMet% compliance)" `
          -Recommendation "Investigate SLA failures and adjust policy schedules or worker capacity"
      }
      elseif ($pctMet -lt $SLATarget) {
        Add-Finding -Category $cat -Status "Warning" -Check "SLA Compliance" `
          -Detail "SLA compliance at $pctMet% (target: $SLATarget%)" `
          -Recommendation "Review missed SLA policies to improve compliance"
      }
    }
    else {
      Add-Finding -Category $cat -Status "Healthy" -Check "SLA Compliance" `
        -Detail "All $(@($SLAReport).Count) SLA-based policies are meeting their targets"
    }
  }
}

# =============================
# Session Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates backup session success rates.
#>
function Invoke-SessionHealthChecks {
  param($SessionsSummary, $FailedSessions, $TopDuration)

  $cat = "Session Health"

  if ($null -eq $SessionsSummary) {
    Add-Finding -Category $cat -Status "Warning" -Check "Session Data" `
      -Detail "Unable to retrieve session summary data"
    return
  }

  $success = [int]$SessionsSummary.latestSessionsSuccessCount
  $warnings = [int]$SessionsSummary.latestSessionsWarningCount
  $errors = [int]$SessionsSummary.latestSessionsErrorCount
  $running = [int]$SessionsSummary.latestSessionsRunningCount
  $total = $success + $warnings + $errors

  if ($total -gt 0) {
    $successRate = [math]::Round(($success / $total) * 100, 1)
    if ($successRate -ge 95) {
      Add-Finding -Category $cat -Status "Healthy" -Check "Session Success Rate" `
        -Detail "Session success rate: $successRate% ($success success, $warnings warnings, $errors errors)"
    }
    elseif ($successRate -ge 80) {
      Add-Finding -Category $cat -Status "Warning" -Check "Session Success Rate" `
        -Detail "Session success rate: $successRate% ($success success, $warnings warnings, $errors errors)" `
        -Recommendation "Investigate session warnings and errors to improve reliability"
    }
    else {
      Add-Finding -Category $cat -Status "Critical" -Check "Session Success Rate" `
        -Detail "Session success rate: $successRate% ($success success, $warnings warnings, $errors errors)" `
        -Recommendation "Urgent: review and resolve session failures to restore backup reliability"
    }
  }
  else {
    Add-Finding -Category $cat -Status "Warning" -Check "Session Activity" `
      -Detail "No completed sessions found" `
      -Recommendation "Verify that backup policies are scheduled and executing"
  }

  # Failed sessions
  if (@($FailedSessions).Count -gt 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Recent Failures" `
      -Detail "$(@($FailedSessions).Count) failed session(s) detected" `
      -Recommendation "Review failed session logs for root cause analysis"
  }

  # Running sessions
  if ($running -gt 0) {
    Add-Finding -Category $cat -Status "Healthy" -Check "Active Sessions" `
      -Detail "$running session(s) currently running"
  }

  # Long-running policies
  if ($null -ne $TopDuration -and $TopDuration.data) {
    $slowPolicies = @($TopDuration.data | Where-Object {
      $_.deviationFromAvgDuration -gt 0 -and $_.avgPercentage -gt 200
    })
    if ($slowPolicies.Count -gt 0) {
      $names = ($slowPolicies | Select-Object -First 3 | ForEach-Object { $_.policyName }) -join ", "
      Add-Finding -Category $cat -Status "Warning" -Check "Long-Running Policies" `
        -Detail "$($slowPolicies.Count) policy(s) running significantly longer than average: $names" `
        -Recommendation "Review policy scope and worker capacity for slow-running policies"
    }
  }
}

# =============================
# Repository Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates backup repository health and configuration.
#>
function Invoke-RepositoryHealthChecks {
  param($Repositories)

  $cat = "Repository Health"

  if (@($Repositories).Count -eq 0) {
    Add-Finding -Category $cat -Status "Warning" -Check "Repository Discovery" `
      -Detail "No backup repositories configured" `
      -Recommendation "Configure at least one backup repository for storing backup data"
    return
  }

  Add-Finding -Category $cat -Status "Healthy" -Check "Repository Count" `
    -Detail "$(@($Repositories).Count) backup repository(s) configured"

  foreach ($repo in $Repositories) {
    $repoName = if ($repo.name) { $repo.name } else { "Unnamed" }

    # Status check
    if ($repo.status -eq "Failed") {
      Add-Finding -Category $cat -Status "Critical" -Check "Repository Status" `
        -Detail "Repository '$repoName' is in Failed state" `
        -Recommendation "Investigate repository failure and restore connectivity" `
        -Resource $repoName
    }
    elseif ($repo.status -eq "ReadOnly") {
      Add-Finding -Category $cat -Status "Warning" -Check "Repository Status" `
        -Detail "Repository '$repoName' is in ReadOnly state" `
        -Recommendation "Check repository permissions and storage account access" `
        -Resource $repoName
    }
    elseif ($repo.status -eq "Creating" -or $repo.status -eq "Importing") {
      Add-Finding -Category $cat -Status "Healthy" -Check "Repository Status" `
        -Detail "Repository '$repoName' is being set up (status: $($repo.status))" `
        -Resource $repoName
    }

    # Encryption
    if (-not $repo.enableEncryption) {
      Add-Finding -Category $cat -Status "Warning" -Check "Repository Encryption" `
        -Detail "Repository '$repoName' does not have encryption enabled" `
        -Recommendation "Enable encryption to protect backup data at rest" `
        -Resource $repoName
    }

    # Immutability
    if (-not $repo.immutabilityEnabled) {
      Add-Finding -Category $cat -Status "Warning" -Check "Repository Immutability" `
        -Detail "Repository '$repoName' does not have immutability enabled" `
        -Recommendation "Enable immutability to protect against ransomware and accidental deletion" `
        -Resource $repoName
    }

    # Storage tier optimization
    if ($repo.storageTier -eq "Hot") {
      Add-Finding -Category $cat -Status "Warning" -Check "Storage Tier" `
        -Detail "Repository '$repoName' uses Hot storage tier" `
        -Recommendation "Consider Cool or Archive tier for cost optimization on infrequently accessed backups" `
        -Resource $repoName
    }
  }
}

# =============================
# Worker Health Checks
# =============================

<#
.SYNOPSIS
  Evaluates worker instance health and infrastructure bottlenecks.
#>
function Invoke-WorkerHealthChecks {
  param($Workers, $WorkerStats, $Bottlenecks)

  $cat = "Worker Health"

  # Worker instances
  if (@($Workers).Count -gt 0) {
    $stopped = @($Workers | Where-Object { $_.status -eq "Stopped" -or $_.status -eq "Removed" -or $_.status -eq "Deallocated" })
    $recovering = @($Workers | Where-Object { $_.status -eq "Recovering" })

    if ($stopped.Count -gt 0) {
      Add-Finding -Category $cat -Status "Critical" -Check "Worker Status" `
        -Detail "$($stopped.Count) worker(s) in stopped/removed/deallocated state" `
        -Recommendation "Investigate stopped workers and redeploy if needed"
    }

    if ($recovering.Count -gt 0) {
      Add-Finding -Category $cat -Status "Warning" -Check "Worker Recovery" `
        -Detail "$($recovering.Count) worker(s) in recovering state" `
        -Recommendation "Monitor recovering workers - they may need manual intervention"
    }

    $healthy = @($Workers | Where-Object { $_.status -eq "Idle" -or $_.status -eq "Busy" })
    if ($healthy.Count -gt 0) {
      Add-Finding -Category $cat -Status "Healthy" -Check "Worker Availability" `
        -Detail "$($healthy.Count) of $(@($Workers).Count) worker(s) available (Idle or Busy)"
    }
  }

  # Worker statistics
  if ($null -ne $WorkerStats) {
    Add-Finding -Category $cat -Status "Healthy" -Check "Worker Pool" `
      -Detail "Total: $($WorkerStats.countOfWorkers), Running: $($WorkerStats.runningWorkers), Deployed: $($WorkerStats.deployedWorkers)"
  }

  # Bottlenecks
  if ($null -ne $Bottlenecks) {
    # Worker wait time
    if ($Bottlenecks.workerWaitTimeState -eq "Exceeded" -or $Bottlenecks.workerWaitTimeState -eq "Warning") {
      $avgWait = $Bottlenecks.averageWorkersWaitTimeMin
      $maxWait = $Bottlenecks.maximumWorkersWaitTimeMin
      Add-Finding -Category $cat -Status "Warning" -Check "Worker Wait Time" `
        -Detail "Worker wait time bottleneck detected (avg: ${avgWait}min, max: ${maxWait}min) in region $($Bottlenecks.workerBottleneckRegion)" `
        -Recommendation "Add more workers or increase worker profile size in the affected region"
    }

    # CPU quota
    if ($Bottlenecks.cpuQuotaState -eq "Exceeded" -or $Bottlenecks.cpuQuotaState -eq "Warning") {
      Add-Finding -Category $cat -Status "Warning" -Check "CPU Quota" `
        -Detail "CPU quota bottleneck in region $($Bottlenecks.cpuQuotaBottleneckRegion)" `
        -Recommendation "Request a CPU quota increase from Azure for the affected region"
    }

    # Storage account throttling
    if ($Bottlenecks.storageAccountBottleneckState -eq "Exceeded" -or $Bottlenecks.storageAccountBottleneckState -eq "Warning") {
      Add-Finding -Category $cat -Status "Warning" -Check "Storage Throttling" `
        -Detail "Storage account throttling detected: $($Bottlenecks.storageAccountBottleneckName) in $($Bottlenecks.storageAccountBottleneckRegion)" `
        -Recommendation "Consider splitting data across multiple storage accounts or upgrading the account type"
    }

    # All clear
    if ($Bottlenecks.workerWaitTimeState -ne "Exceeded" -and $Bottlenecks.workerWaitTimeState -ne "Warning" -and
        $Bottlenecks.cpuQuotaState -ne "Exceeded" -and $Bottlenecks.cpuQuotaState -ne "Warning" -and
        $Bottlenecks.storageAccountBottleneckState -ne "Exceeded" -and $Bottlenecks.storageAccountBottleneckState -ne "Warning") {
      Add-Finding -Category $cat -Status "Healthy" -Check "Infrastructure Bottlenecks" `
        -Detail "No infrastructure bottlenecks detected"
    }
  }
}

# =============================
# Configuration Backup Checks
# =============================

<#
.SYNOPSIS
  Evaluates configuration backup status.
#>
function Invoke-ConfigBackupHealthChecks {
  param($ConfigBackup, [int]$MaxAgeDays)

  $cat = "Configuration Backup"
  $settings = $ConfigBackup.Settings

  if ($null -eq $settings) {
    Add-Finding -Category $cat -Status "Warning" -Check "Config Backup" `
      -Detail "Unable to retrieve configuration backup settings"
    return
  }

  # Enabled check
  if (-not $settings.isEnabled) {
    Add-Finding -Category $cat -Status "Critical" -Check "Config Backup Status" `
      -Detail "Configuration backup is not enabled" `
      -Recommendation "Enable configuration backup to protect against appliance failure"
    return
  }

  Add-Finding -Category $cat -Status "Healthy" -Check "Config Backup Status" `
    -Detail "Configuration backup is enabled (repository: $($settings.repositoryName))"

  # Last backup status
  if ($settings.lastBackupSessionStatus) {
    if ($settings.lastBackupSessionStatus -eq "Error" -or $settings.lastBackupSessionStatus -eq "Failed") {
      Add-Finding -Category $cat -Status "Warning" -Check "Last Config Backup" `
        -Detail "Last configuration backup failed (status: $($settings.lastBackupSessionStatus))" `
        -Recommendation "Investigate the configuration backup failure and trigger a manual backup"
    }
    elseif ($settings.lastBackupSessionStatus -eq "Success") {
      Add-Finding -Category $cat -Status "Healthy" -Check "Last Config Backup" `
        -Detail "Last configuration backup completed successfully"
    }
  }

  # Last backup age
  if ($settings.lastBackupSessionStartTimeUtc) {
    try {
      $lastBackup = [datetime]::Parse($settings.lastBackupSessionStartTimeUtc)
      $ageDays = ((Get-Date) - $lastBackup).Days

      if ($ageDays -gt $MaxAgeDays) {
        Add-Finding -Category $cat -Status "Warning" -Check "Config Backup Age" `
          -Detail "Last configuration backup is $ageDays days old (threshold: $MaxAgeDays days)" `
          -Recommendation "Run a configuration backup to ensure a current backup exists"
      }
    }
    catch {
      $null = $_ # Date parsing failed — skip age check for non-standard formats
    }
  }
}

# =============================
# Health Score Calculation
# =============================

<#
.SYNOPSIS
  Calculates the weighted health score across all categories.
.OUTPUTS
  Hashtable with OverallScore, Grade, GradeColor, and CategoryScores.
#>
function Measure-HealthScore {
  Write-ProgressStep -Activity "Calculating Health Score" -Status "Weighting findings..."

  $categoryScores = @{}

  foreach ($category in $script:CategoryWeights.Keys) {
    $catFindings = @($script:Findings | Where-Object { $_.Category -eq $category })

    if ($catFindings.Count -eq 0) {
      $categoryScores[$category] = 100
      continue
    }

    $totalPoints = 0
    foreach ($f in $catFindings) {
      $totalPoints += switch ($f.Status) {
        "Healthy"  { 100 }
        "Warning"  { 50 }
        "Critical" { 0 }
        default    { 50 }
      }
    }

    $categoryScores[$category] = [math]::Round($totalPoints / $catFindings.Count, 1)
  }

  # Weighted overall score
  $overallScore = 0
  foreach ($category in $script:CategoryWeights.Keys) {
    $weight = $script:CategoryWeights[$category]
    $score = $categoryScores[$category]
    $overallScore += $weight * $score
  }
  $overallScore = [math]::Round($overallScore, 1)

  $grade = Get-ScoreGrade -Score $overallScore

  Write-Log "Overall Health Score: $overallScore/100 ($($grade.Grade))" -Level "SUCCESS"

  return @{
    OverallScore = $overallScore
    Grade = $grade.Grade
    GradeColor = $grade.Color
    CategoryScores = $categoryScores
  }
}
