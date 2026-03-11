# =========================================================================
# BackupWindow.ps1 - Backup window estimation engine
# =========================================================================
# Estimates initial full and daily incremental backup durations based on
# documented Microsoft Graph API throttling limits and estimated efficiency
# factors. Exchange and SPO/ODB use separate throttle scopes and run in
# parallel from t=0; SPO and ODB share the same RU pool.
# =========================================================================

<#
.SYNOPSIS
  Returns the RU tier for a given license count from the documented table.
.PARAMETER LicenseCount
  Total M365 license count for the tenant.
.OUTPUTS
  Hashtable with TenantRU5Min, AppRUPerMin, and TierLabel.
#>
function Get-ThrottleTier {
  param([int]$LicenseCount)

  foreach ($tier in $BW_SPO_RU_TIERS) {
    if ($LicenseCount -le $tier.MaxLicenses) {
      if ($tier.MaxLicenses -eq [int]::MaxValue) {
        $label = "50,001+"
      } else {
        $label = "up to {0:N0}" -f $tier.MaxLicenses
      }
      return @{
        TenantRU5Min = $tier.TenantRU5Min
        AppRUPerMin  = $tier.AppRUPerMin
        TierLabel    = $label
      }
    }
  }

  # Fallback to highest tier
  $last = $BW_SPO_RU_TIERS[-1]
  return @{
    TenantRU5Min = $last.TenantRU5Min
    AppRUPerMin  = $last.AppRUPerMin
    TierLabel    = "50,001+"
  }
}

<#
.SYNOPSIS
  Estimates backup window durations for Exchange and SPO+ODB workloads.
.DESCRIPTION
  Uses $script: scoped variables set by Invoke-DataCollection:
    $script:exGB, $script:exUsers, $script:exShared,
    $script:odGB, $script:odActive,
    $script:spGB, $script:spActive, $script:spFiles,
    $script:licenseData (Full mode only)
  Uses change rate parameters from the main script scope:
    $ChangeRateExchange, $ChangeRateOneDrive, $ChangeRateSharePoint
.OUTPUTS
  PSCustomObject with all 3 bands + binding constraints + transparency arrays.
#>
function Get-BackupWindowEstimate {
  # ── Determine mailbox count ──
  $mbxCount = 0
  if ($script:exUsers -and $script:exUsers.Count -gt 0) {
    $mbxCount = $script:exUsers.Count
  }
  $sharedCount = 0
  if ($script:exShared -and $script:exShared.Count -gt 0) {
    $sharedCount = $script:exShared.Count
  }
  $totalMbx = $mbxCount + $sharedCount

  # ── Determine ODB account count ──
  $odbCount = 0
  if ($script:odActive -and $script:odActive.Count -gt 0) {
    $odbCount = $script:odActive.Count
  }

  # ── Determine license count for RU tier ──
  $licCount = 0
  if ($script:licenseData -and $script:licenseData -isnot [string] -and @($script:licenseData).Count -gt 0) {
    foreach ($lic in $script:licenseData) {
      if ($lic.PSObject.Properties.Name -contains "Purchased") {
        $licCount += $lic.Purchased
      }
    }
  }
  # Fallback: max of mailbox count and ODB count
  if ($licCount -le 0) {
    $licCount = [Math]::Max($totalMbx, $odbCount)
  }
  if ($licCount -le 0) { $licCount = 1 }

  $throttleTier = Get-ThrottleTier -LicenseCount $licCount

  # ── Exchange calculation ──
  $exTotalGB = if ($script:exGB) { [double]$script:exGB } else { 0.0 }
  $exMinHrs = 0.0; $exLikelyHrs = 0.0; $exMaxHrs = 0.0
  $exIncrMin = 0.0; $exIncrLikely = 0.0; $exIncrMax = 0.0
  $exBinding = "N/A"

  if ($totalMbx -gt 0 -and $exTotalGB -gt 0) {
    $avgMbxGB = $exTotalGB / $totalMbx
    $ceiling = [double]$BW_EX_GB_PER_MBX_PER_HR

    foreach ($band in @("Min", "Likely", "Max")) {
      $concurrency = $BW_VDC_CONCURRENT_MBX[$band]
      $efficiency  = $BW_EX_EFFICIENCY[$band]

      $timePerMbx = $avgMbxGB / ($ceiling * $efficiency)
      $hours = ($totalMbx / $concurrency) * $timePerMbx
      $hours = [Math]::Round($hours, 2)

      # Incremental: daily change rate applied to total GB
      $changeRate = if ($ChangeRateExchange) { $ChangeRateExchange } else { 0.015 }
      $dailyChangeGB = $exTotalGB * $changeRate
      $incrHours = ($totalMbx / $concurrency) * (($dailyChangeGB / $totalMbx) / ($ceiling * $efficiency))
      $incrHours = [Math]::Round($incrHours, 2)

      switch ($band) {
        "Min"    { $exMinHrs = $hours; $exIncrMin = $incrHours }
        "Likely" { $exLikelyHrs = $hours; $exIncrLikely = $incrHours }
        "Max"    { $exMaxHrs = $hours; $exIncrMax = $incrHours }
      }
    }
    $exBinding = "Per-mailbox upload ceiling ({0:N1} GB/hr)" -f $ceiling
  }

  # ── SPO + ODB combined calculation ──
  $odTotalGB = if ($script:odGB) { [double]$script:odGB } else { 0.0 }
  $spTotalGB = if ($script:spGB) { [double]$script:spGB } else { 0.0 }
  $combinedGB = $odTotalGB + $spTotalGB

  $spoMinHrs = 0.0; $spoLikelyHrs = 0.0; $spoMaxHrs = 0.0
  $spoIncrMin = 0.0; $spoIncrLikely = 0.0; $spoIncrMax = 0.0
  $spoBinding = "N/A"

  if ($combinedGB -gt 0) {
    # File count: use actual spFiles if available, estimate the rest
    $knownFiles = 0
    if ($script:spFiles -and $script:spFiles -gt 0) {
      $knownFiles = [int]$script:spFiles
    }
    # Estimate ODB files from ODB size
    $odbEstFiles = [Math]::Ceiling(($odTotalGB * 1024) / $BW_SPO_AVG_FILE_SIZE_MB)
    # If we have SP files from data collection use that; otherwise estimate
    if ($knownFiles -gt 0) {
      $totalFiles = $knownFiles + $odbEstFiles
    } else {
      $spEstFiles = [Math]::Ceiling(($spTotalGB * 1024) / $BW_SPO_AVG_FILE_SIZE_MB)
      $totalFiles = $spEstFiles + $odbEstFiles
    }
    if ($totalFiles -le 0) { $totalFiles = 1 }

    $totalRU = $totalFiles * $BW_SPO_BLENDED_RU_PER_FILE
    $appRUPerHour = $throttleTier.AppRUPerMin * 60

    foreach ($band in @("Min", "Likely", "Max")) {
      $efficiency = $BW_SPO_EFFICIENCY[$band]

      # RU-limited time
      $ruTime = $totalRU / ($appRUPerHour * $efficiency)
      # Bandwidth-limited time
      $bwTime = $combinedGB / ($BW_SPO_EGRESS_GB_PER_HR * $efficiency)

      $hours = [Math]::Max($ruTime, $bwTime)
      $hours = [Math]::Round($hours, 2)

      $bindingThis = if ($ruTime -ge $bwTime) { "RU throttle" } else { "Bandwidth (400 GB/hr)" }

      # Incremental
      $odChange = if ($ChangeRateOneDrive) { $ChangeRateOneDrive } else { 0.004 }
      $spChange = if ($ChangeRateSharePoint) { $ChangeRateSharePoint } else { 0.003 }
      $dailyIncrGB = ($odTotalGB * $odChange) + ($spTotalGB * $spChange)
      $incrFiles = [Math]::Ceiling(($dailyIncrGB * 1024) / $BW_SPO_AVG_FILE_SIZE_MB)
      $incrRU = $incrFiles * $BW_SPO_BLENDED_RU_PER_FILE
      $incrRuTime = $incrRU / ($appRUPerHour * $efficiency)
      $incrBwTime = $dailyIncrGB / ($BW_SPO_EGRESS_GB_PER_HR * $efficiency)
      $incrHours = [Math]::Max($incrRuTime, $incrBwTime)
      $incrHours = [Math]::Round($incrHours, 2)

      switch ($band) {
        "Min"    { $spoMinHrs = $hours; $spoIncrMin = $incrHours }
        "Likely" { $spoLikelyHrs = $hours; $spoIncrLikely = $incrHours; $spoBinding = $bindingThis }
        "Max"    { $spoMaxHrs = $hours; $spoIncrMax = $incrHours }
      }
    }
  }

  # ── Total: parallel max ──
  $totalMin     = [Math]::Round([Math]::Max($exMinHrs,     $spoMinHrs),     2)
  $totalLikely  = [Math]::Round([Math]::Max($exLikelyHrs,  $spoLikelyHrs),  2)
  $totalMax     = [Math]::Round([Math]::Max($exMaxHrs,     $spoMaxHrs),     2)
  $totalIncrMin    = [Math]::Round([Math]::Max($exIncrMin,    $spoIncrMin),    2)
  $totalIncrLikely = [Math]::Round([Math]::Max($exIncrLikely, $spoIncrLikely), 2)
  $totalIncrMax    = [Math]::Round([Math]::Max($exIncrMax,    $spoIncrMax),    2)

  # ── Transparency arrays ──
  $documented = @(
    "Exchange: 150 MB upload / 5 min / mailbox (learn.microsoft.com)"
    "Exchange: 10,000 requests / 10 min / app / mailbox (learn.microsoft.com)"
    "Exchange: 4 concurrent requests per mailbox (learn.microsoft.com)"
    "SharePoint/ODB: Resource Unit costs - 1 (download/delta), 2 (list/create/upload) (learn.microsoft.com)"
    "SharePoint/ODB: 400 GB/hr app bandwidth egress cap (learn.microsoft.com)"
    "SharePoint/ODB: Tenant RU/5min tiers by license count (learn.microsoft.com)"
    "SharePoint/ODB: App RU/min tiers by license count (learn.microsoft.com)"
  )

  $estimated = @(
    "VDC concurrent mailboxes: {0} (best) / {1} (likely) / {2} (conservative)" -f $BW_VDC_CONCURRENT_MBX.Min, $BW_VDC_CONCURRENT_MBX.Likely, $BW_VDC_CONCURRENT_MBX.Max
    "Exchange efficiency factor: {0:P0} / {1:P0} / {2:P0}" -f $BW_EX_EFFICIENCY.Min, $BW_EX_EFFICIENCY.Likely, $BW_EX_EFFICIENCY.Max
    "SPO/ODB efficiency factor: {0:P0} / {1:P0} / {2:P0}" -f $BW_SPO_EFFICIENCY.Min, $BW_SPO_EFFICIENCY.Likely, $BW_SPO_EFFICIENCY.Max
    "Average email item size: $BW_EX_AVG_ITEM_SIZE_KB KB"
    "Average file size: $BW_SPO_AVG_FILE_SIZE_MB MB"
    "Blended RU cost per file: $BW_SPO_BLENDED_RU_PER_FILE"
    "VDC concurrent mailbox processing count (VDC-managed, not published)"
    "VDC app registration strategy (single vs multiple Entra apps)"
    "Whether VDC uses Microsoft Service Prioritization (paid 2x-10x boost)"
    "Fixed MB/s for OneDrive operations (Microsoft does not publish this)"
  )

  return [PSCustomObject]@{
    LicenseCount        = $licCount
    ThrottleTierLabel   = $throttleTier.TierLabel
    # Exchange
    Ex_MailboxCount     = $totalMbx
    Ex_TotalGB          = $exTotalGB
    Ex_BindingConstraint = $exBinding
    Ex_MinHours         = $exMinHrs
    Ex_LikelyHours      = $exLikelyHrs
    Ex_MaxHours         = $exMaxHrs
    Ex_IncrMinHours     = $exIncrMin
    Ex_IncrLikelyHours  = $exIncrLikely
    Ex_IncrMaxHours     = $exIncrMax
    # SPO + ODB combined
    SPO_CombinedGB      = $combinedGB
    SPO_FileCount       = $totalFiles
    SPO_BindingConstraint = $spoBinding
    SPO_MinHours        = $spoMinHrs
    SPO_LikelyHours     = $spoLikelyHrs
    SPO_MaxHours        = $spoMaxHrs
    SPO_IncrMinHours    = $spoIncrMin
    SPO_IncrLikelyHours = $spoIncrLikely
    SPO_IncrMaxHours    = $spoIncrMax
    # Total (parallel)
    Total_MinHours      = $totalMin
    Total_LikelyHours   = $totalLikely
    Total_MaxHours      = $totalMax
    Total_IncrMinHours  = $totalIncrMin
    Total_IncrLikelyHours = $totalIncrLikely
    Total_IncrMaxHours  = $totalIncrMax
    # Transparency
    DocumentedLimits    = $documented
    EstimatedAssumptions = $estimated
  }
}
