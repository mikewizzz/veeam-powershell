# =========================================================================
# Findings.ps1 - Findings engine, recommendations generator, readiness score
# =========================================================================

<#
.SYNOPSIS
  Creates a structured finding object.
.PARAMETER Title
  Short title for the finding.
.PARAMETER Detail
  Detailed description with specific data.
.PARAMETER Severity
  Finding severity: High, Medium, Low, or Info.
.PARAMETER Category
  Finding category (e.g., "Identity", "Data Protection", "Compliance").
.PARAMETER Tone
  Positive framing: "Strong", "Opportunity", "Informational".
#>
function New-Finding {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Detail,
    [ValidateSet("High","Medium","Low","Info")][string]$Severity = "Info",
    [string]$Category = "General",
    [string]$Tone = "Informational"
  )
  return [PSCustomObject]@{
    Title    = $Title
    Detail   = $Detail
    Severity = $Severity
    Category = $Category
    Tone     = $Tone
  }
}

<#
.SYNOPSIS
  Creates a structured recommendation object.
.PARAMETER Title
  Short recommendation title.
.PARAMETER Detail
  What to do.
.PARAMETER Rationale
  Why this matters.
.PARAMETER Tier
  Priority tier: Immediate, Short-Term, or Strategic.
#>
function New-Recommendation {
  param(
    [Parameter(Mandatory)][string]$Title,
    [Parameter(Mandatory)][string]$Detail,
    [string]$Rationale = "",
    [ValidateSet("Immediate","Short-Term","Strategic")][string]$Tier = "Strategic"
  )
  return [PSCustomObject]@{
    Title     = $Title
    Detail    = $Detail
    Rationale = $Rationale
    Tier      = $Tier
  }
}

<#
.SYNOPSIS
  Generates algorithmic findings from collected data thresholds.
.DESCRIPTION
  Analyzes identity, security, and data protection signals against defined
  thresholds. Uses positive framing throughout.
.NOTES
  Only runs in Full mode. Returns empty array in Quick mode.
#>
function Get-Findings {
  $findings = New-Object System.Collections.Generic.List[object]

  if (-not $Full) { return @() }

  # --- MFA Coverage ---
  if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $mfaPct = $script:mfaCount / $script:userCount
    if ($mfaPct -ge $MFA_THRESHOLD_MEDIUM) {
      $findings.Add((New-Finding -Title "Strong MFA Adoption" -Detail "$(Format-Pct $mfaPct) of users have MFA registered ($($script:mfaCount) of $($script:userCount))." -Severity "Info" -Category "Identity" -Tone "Strong"))
    } elseif ($mfaPct -ge $MFA_THRESHOLD_HIGH) {
      $findings.Add((New-Finding -Title "MFA Adoption Opportunity" -Detail "$(Format-Pct $mfaPct) of users have MFA registered. Industry best practice targets 95%+ coverage." -Severity "Medium" -Category "Identity" -Tone "Opportunity"))
    } else {
      $findings.Add((New-Finding -Title "MFA Coverage Below Recommended Threshold" -Detail "$(Format-Pct $mfaPct) of users have MFA registered ($($script:mfaCount) of $($script:userCount)). Organizations with less than 80% MFA face significantly elevated identity compromise risk." -Severity "High" -Category "Identity" -Tone "Opportunity"))
    }
  } elseif ($script:mfaCount -eq "access_denied") {
    $findings.Add((New-Finding -Title "MFA Data Not Available" -Detail "MFA registration data requires AuditLog.Read.All permission. Grant this scope to enable MFA coverage analysis." -Severity "Info" -Category "Identity" -Tone "Informational"))
  }

  # --- Global Admins ---
  if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) {
    $adminCount = @($script:globalAdmins).Count
    $adminWord = if ($adminCount -eq 1) { "Global Administrator" } else { "Global Administrators" }
    if ($adminCount -le $ADMIN_THRESHOLD) {
      $findings.Add((New-Finding -Title "Well-Managed Admin Accounts" -Detail "$adminCount $adminWord detected. This is within the recommended threshold of $ADMIN_THRESHOLD or fewer." -Severity "Info" -Category "Identity" -Tone "Strong"))
    } else {
      $findings.Add((New-Finding -Title "Elevated Global Administrator Count" -Detail "$adminCount $adminWord detected. Microsoft recommends no more than $ADMIN_THRESHOLD to minimize blast radius of compromised privileged accounts." -Severity "Medium" -Category "Identity" -Tone "Opportunity"))
    }
  }

  # --- Risky Users ---
  if ($script:riskyUsers -is [hashtable]) {
    $highRisk = $script:riskyUsers.High
    if ($highRisk -gt 0) {
      $findings.Add((New-Finding -Title "High-Risk Users Detected" -Detail "$highRisk user(s) flagged as high risk by Microsoft Identity Protection. Additionally: $($script:riskyUsers.Medium) medium risk, $($script:riskyUsers.Low) low risk." -Severity "High" -Category "Identity" -Tone "Opportunity"))
    } elseif ($script:riskyUsers.Total -gt 0) {
      $findings.Add((New-Finding -Title "Risky Users Present" -Detail "$($script:riskyUsers.Total) user(s) flagged at risk (Medium: $($script:riskyUsers.Medium), Low: $($script:riskyUsers.Low)). No high-risk users detected." -Severity "Medium" -Category "Identity" -Tone "Opportunity"))
    } else {
      $findings.Add((New-Finding -Title "No Risky Users Detected" -Detail "Microsoft Identity Protection reports no users at elevated risk. This indicates strong identity hygiene." -Severity "Info" -Category "Identity" -Tone "Strong"))
    }
  }

  # --- Stale Accounts ---
  if ($script:staleAccounts -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $stalePct = $script:staleAccounts / $script:userCount
    if ($stalePct -gt $STALE_THRESHOLD_PCT) {
      $findings.Add((New-Finding -Title "Stale Account Cleanup Opportunity" -Detail "$($script:staleAccounts) accounts ($(Format-Pct $stalePct)) have not signed in for $STALE_DAYS+ days. Inactive accounts increase attack surface and consume licenses." -Severity "Medium" -Category "Identity" -Tone "Opportunity"))
    } else {
      $findings.Add((New-Finding -Title "Active Account Hygiene" -Detail "Only $($script:staleAccounts) accounts ($(Format-Pct $stalePct)) are inactive for $STALE_DAYS+ days, within the recommended threshold." -Severity "Info" -Category "Identity" -Tone "Strong"))
    }
  }

  # --- Conditional Access Policies ---
  if ($script:caPolicyCount -is [int]) {
    if ($script:caPolicyCount -lt $CA_POLICY_THRESHOLD) {
      $caWord = if ($script:caPolicyCount -eq 1) { "policy" } else { "policies" }
      $findings.Add((New-Finding -Title "Limited Conditional Access Policies" -Detail "$($script:caPolicyCount) Conditional Access $caWord detected. Microsoft recommends at least $CA_POLICY_THRESHOLD policies covering MFA enforcement, location-based access, and device compliance." -Severity "Medium" -Category "Identity" -Tone "Opportunity"))
    } else {
      $caWord = if ($script:caPolicyCount -eq 1) { "policy" } else { "policies" }
      $findings.Add((New-Finding -Title "Conditional Access Policies Configured" -Detail "$($script:caPolicyCount) Conditional Access $caWord in place. This demonstrates proactive access governance." -Severity "Info" -Category "Identity" -Tone "Strong"))
    }
  }

  # --- Guest Users ---
  if ($script:guestUserCount -is [int] -and $script:guestUserCount -gt 0) {
    $findings.Add((New-Finding -Title "External Guest Users Present" -Detail "$($script:guestUserCount) guest user(s) in the directory. Ensure guest access reviews are configured to periodically validate external user access." -Severity "Low" -Category "Identity" -Tone "Informational"))
  }

  # --- Data Protection: Dataset summary ---
  $totalDataGB = $script:exGB + $script:odGB + $script:spGB
  if ($totalDataGB -gt 0) {
    $findings.Add((New-Finding -Title "Data Protection Scope Identified" -Detail "$('{0:N2}' -f $totalDataGB) GB across Exchange ($('{0:N2}' -f $script:exGB) GB), OneDrive ($('{0:N2}' -f $script:odGB) GB), and SharePoint ($('{0:N2}' -f $script:spGB) GB). Verify that your backup and retention policies cover the full scope per Microsoft's Shared Responsibility Model." -Severity "Info" -Category "Data Protection" -Tone "Informational"))
  }

  # --- Teams ---
  if ($script:teamsCount -is [int] -and $script:teamsCount -gt 0) {
    $findings.Add((New-Finding -Title "Microsoft Teams Workload Detected" -Detail "$($script:teamsCount) Teams detected. Teams data spans Exchange (conversations) and SharePoint (files); confirm your data protection strategy includes Teams-specific coverage." -Severity "Info" -Category "Data Protection" -Tone "Informational"))
  }

  return ,$findings.ToArray()
}

<#
.SYNOPSIS
  Generates prioritized recommendations from findings.
.DESCRIPTION
  Translates findings into actionable recommendations grouped by tier.
.NOTES
  Three tiers: Immediate (red), Short-Term (yellow), Strategic (blue).
#>
function Get-Recommendations {
  $recs = New-Object System.Collections.Generic.List[object]

  if (-not $Full) { return @() }

  # --- MFA ---
  if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $mfaPct = $script:mfaCount / $script:userCount
    if ($mfaPct -lt $MFA_THRESHOLD_HIGH) {
      $recs.Add((New-Recommendation -Title "Accelerate MFA Enrollment" -Detail "Deploy MFA registration campaigns targeting the $('{0:N0}' -f ($script:userCount - $script:mfaCount)) users without MFA. Consider Security Defaults or Conditional Access policies requiring MFA for all users." -Rationale "MFA blocks 99.9% of account compromise attacks. Current coverage ($(Format-Pct $mfaPct)) leaves significant gaps." -Tier "Immediate"))
    } elseif ($mfaPct -lt $MFA_THRESHOLD_MEDIUM) {
      $recs.Add((New-Recommendation -Title "Close MFA Coverage Gaps" -Detail "Identify the remaining $('{0:N0}' -f ($script:userCount - $script:mfaCount)) users without MFA and enforce registration through Conditional Access policies." -Rationale "Reaching 95%+ MFA coverage significantly reduces identity compromise risk across the organization." -Tier "Short-Term"))
    }
  }

  # --- Global Admins ---
  if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) {
    $adminCount = @($script:globalAdmins).Count
    if ($adminCount -gt $ADMIN_THRESHOLD) {
      $recs.Add((New-Recommendation -Title "Reduce Global Administrator Accounts" -Detail "Review the $adminCount Global Administrators and reassign to least-privilege roles (e.g., Exchange Admin, SharePoint Admin, User Admin) where possible." -Rationale "Limiting Global Admins to $ADMIN_THRESHOLD or fewer reduces the blast radius if a privileged account is compromised." -Tier "Immediate"))
    }
  }

  # --- Risky Users ---
  if ($script:riskyUsers -is [hashtable] -and $script:riskyUsers.High -gt 0) {
    $recs.Add((New-Recommendation -Title "Investigate High-Risk Users" -Detail "Review and remediate the $($script:riskyUsers.High) high-risk user(s) in Microsoft Entra Identity Protection. Force password reset and MFA re-registration for confirmed compromises." -Rationale "High-risk users may have compromised credentials actively being exploited." -Tier "Immediate"))
  }

  # --- Stale Accounts ---
  if ($script:staleAccounts -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $stalePct = $script:staleAccounts / $script:userCount
    if ($stalePct -gt $STALE_THRESHOLD_PCT) {
      $recs.Add((New-Recommendation -Title "Clean Up Stale Accounts" -Detail "Review and disable the $($script:staleAccounts) accounts inactive for $STALE_DAYS+ days. Implement automated lifecycle policies to disable accounts after extended inactivity." -Rationale "Stale accounts are prime targets for credential stuffing attacks and consume license seats unnecessarily." -Tier "Short-Term"))
    }
  }

  # --- Conditional Access ---
  if ($script:caPolicyCount -is [int] -and $script:caPolicyCount -lt $CA_POLICY_THRESHOLD) {
    $recs.Add((New-Recommendation -Title "Expand Conditional Access Policies" -Detail "Implement additional Conditional Access policies. Start with: (1) Require MFA for all users, (2) Block legacy authentication, (3) Require compliant devices for sensitive apps." -Rationale "Conditional Access is the primary zero-trust enforcement mechanism. $($script:caPolicyCount) policies may not cover critical scenarios." -Tier "Short-Term"))
  }

  # --- Guest Users ---
  if ($script:guestUserCount -is [int] -and $script:guestUserCount -gt 0) {
    $recs.Add((New-Recommendation -Title "Implement Guest Access Reviews" -Detail "Configure recurring access reviews for the $($script:guestUserCount) guest users. Set reviews to quarterly cadence with automatic removal of unreviewed access." -Rationale "Unmanaged guest access can lead to data leakage and compliance violations." -Tier "Short-Term"))
  }

  # --- Backup Strategy ---
  $recs.Add((New-Recommendation -Title "Review Data Protection Coverage" -Detail "Validate that Exchange, OneDrive, SharePoint, and Teams data are covered by your organization's backup and retention strategy per Microsoft's Shared Responsibility Model." -Rationale "Under the Shared Responsibility Model, Microsoft manages infrastructure availability while the customer is responsible for data protection and retention configuration." -Tier "Strategic"))

  # --- Teams ---
  if ($script:teamsCount -is [int] -and $script:teamsCount -gt 0) {
    $recs.Add((New-Recommendation -Title "Include Teams in Data Protection Scope" -Detail "Verify that your data protection strategy covers all $($script:teamsCount) Teams including conversations, channel files, and team settings. Teams data spans Exchange (conversations) and SharePoint (files)." -Rationale "Teams is a critical collaboration workload. Ensure your retention and recovery capabilities extend to Teams-specific data." -Tier "Strategic"))
  }

  return ,$recs.ToArray()
}

<#
.SYNOPSIS
  Calculates Protection Readiness Score (0-100).
.DESCRIPTION
  Composite score from weighted identity and security signals.
  - MFA coverage: 25 points
  - Admin hygiene: 15 points
  - Conditional Access: 15 points
  - Stale accounts: 10 points
  - Risky users: 10 points
  - Secure Score: 25 points
.NOTES
  Returns integer 0-100. Signals that return "access_denied" are excluded
  from scoring (score is proportionally adjusted).
#>
function Get-ProtectionReadinessScore {
  if (-not $Full) { return $null }

  $totalWeight = 0
  $earnedPoints = 0

  # MFA (25 pts)
  if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $totalWeight += 25
    $mfaPct = $script:mfaCount / $script:userCount
    $earnedPoints += [math]::Min(25, [math]::Round($mfaPct * 25, 0))
  }

  # Admin hygiene (15 pts) - fewer admins = better
  if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) {
    $totalWeight += 15
    $adminCount = @($script:globalAdmins).Count
    if ($adminCount -le 2) { $earnedPoints += 15 }
    elseif ($adminCount -le $ADMIN_THRESHOLD) { $earnedPoints += 12 }
    elseif ($adminCount -le 8) { $earnedPoints += 7 }
    else { $earnedPoints += 3 }
  }

  # Conditional Access (15 pts)
  if ($script:caPolicyCount -is [int]) {
    $totalWeight += 15
    if ($script:caPolicyCount -ge 5) { $earnedPoints += 15 }
    elseif ($script:caPolicyCount -ge $CA_POLICY_THRESHOLD) { $earnedPoints += 10 }
    elseif ($script:caPolicyCount -ge 1) { $earnedPoints += 5 }
  }

  # Stale accounts (10 pts) - fewer stale = better
  if ($script:staleAccounts -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
    $totalWeight += 10
    $stalePct = $script:staleAccounts / $script:userCount
    if ($stalePct -le 0.03) { $earnedPoints += 10 }
    elseif ($stalePct -le $STALE_THRESHOLD_PCT) { $earnedPoints += 7 }
    elseif ($stalePct -le 0.20) { $earnedPoints += 4 }
    else { $earnedPoints += 1 }
  }

  # Risky users (10 pts) - no risky = best
  if ($script:riskyUsers -is [hashtable]) {
    $totalWeight += 10
    if ($script:riskyUsers.Total -eq 0) { $earnedPoints += 10 }
    elseif ($script:riskyUsers.High -eq 0) { $earnedPoints += 6 }
    elseif ($script:riskyUsers.High -le 3) { $earnedPoints += 3 }
    else { $earnedPoints += 1 }
  }

  # Secure Score (25 pts) - proportional
  if ($script:secureScore -is [hashtable] -and $script:secureScore.MaxScore -gt 0) {
    $totalWeight += 25
    $earnedPoints += [math]::Round(($script:secureScore.Percentage / 100) * 25, 0)
  }

  # Normalize to 0-100 based on available signals
  if ($totalWeight -eq 0) { return $null }
  return [int][math]::Round(($earnedPoints / $totalWeight) * 100, 0)
}
