# =========================================================================
# Exports.ps1 - CSV, JSON, Notes exports
# =========================================================================

<#
.SYNOPSIS
  Exports inputs/assumptions CSV.
#>
function Export-InputsData {
  $inputs = @(
    [pscustomobject]@{ Key="Mode"; Value=$(if($Full){"Full"}else{"Quick"}) },
    [pscustomobject]@{ Key="PeriodDays"; Value=$Period },
    [pscustomobject]@{ Key="ADGroup"; Value=$(if($ADGroup){$ADGroup}else{""}) },
    [pscustomobject]@{ Key="ExcludeADGroup"; Value=$(if($ExcludeADGroup){$ExcludeADGroup}else{""}) },
    [pscustomobject]@{ Key="IncludeArchive"; Value=$IncludeArchive },
    [pscustomobject]@{ Key="IncludeRecoverableItems"; Value=$IncludeRecoverableItems },
    [pscustomobject]@{ Key="AnnualGrowthPct_Model"; Value=$AnnualGrowthPct },
    [pscustomobject]@{ Key="RetentionMultiplier_Model"; Value=$RetentionMultiplier },
    [pscustomobject]@{ Key="ChangeRateExchange_Model"; Value=$ChangeRateExchange },
    [pscustomobject]@{ Key="ChangeRateOneDrive_Model"; Value=$ChangeRateOneDrive },
    [pscustomobject]@{ Key="ChangeRateSharePoint_Model"; Value=$ChangeRateSharePoint },
    [pscustomobject]@{ Key="BufferPct_Heuristic"; Value=$BufferPct },
    [pscustomobject]@{ Key="SharePointGroupFiltering"; Value="Not supported from usage reports (by design)" }
  )
  $inputs | Export-Csv -NoTypeInformation -Path $outInputs
  return $inputs
}

<#
.SYNOPSIS
  Exports summary CSV with all sizing metrics and posture signals.
#>
function Export-SummaryData {
  $summaryProps = [ordered]@{
    ReportDate                = (Get-Date).ToString("s")
    OrgName                   = $script:OrgName
    OrgId                     = $script:OrgId
    DefaultDomain             = $script:DefaultDomain
    GraphEnvironment          = $script:envName
    TenantCategory            = $script:TenantCategory
    Mode                      = $(if($Full){"Full"}else{"Quick"})
    UsersToProtect            = $script:UsersToProtect

    Exchange_SourceBytes      = [int64]$script:exPrimaryBytes
    OneDrive_SourceBytes      = [int64]$script:odBytes
    SharePoint_SourceBytes    = [int64]$script:spBytes

    Exchange_SourceGB         = $script:exGB
    OneDrive_SourceGB         = $script:odGB
    SharePoint_SourceGB       = $script:spGB
    Total_SourceGB            = $script:totalGB

    Exchange_SourceGiB        = $script:exGiB
    OneDrive_SourceGiB        = $script:odGiB
    SharePoint_SourceGiB      = $script:spGiB
    Total_SourceGiB           = $script:totalGiB

    Total_SourceTB_Decimal    = $script:totalTB
    Total_SourceTiB_Binary    = $script:totalTiB

    Exchange_AnnualGrowthPct  = $script:exGrowth
    OneDrive_AnnualGrowthPct  = $script:odGrowth
    SharePoint_AnnualGrowthPct= $script:spGrowth

    AnnualGrowthPct_Model     = $AnnualGrowthPct
    RetentionMultiplier_Model = $RetentionMultiplier
    MonthChangeGB_Model       = $script:monthChangeGB
    MbsEstimateGB_Model       = $script:mbsEstimateGB

    SuggestedStartGB_Heuristic= $script:suggestedStartGB
    BufferPct_Heuristic       = $BufferPct

    IncludeArchiveGB_Measured     = (To-GB $script:archBytes)
    IncludeRecoverableGB_Measured = (To-GB $script:rifBytes)

    Dir_UserCount             = $script:userCount
    Dir_GroupCount            = $script:groupCount
    Dir_AppRegistrations      = $script:appRegCount
    Dir_ServicePrincipals     = $script:spnCount
    CA_PolicyCount            = $script:caPolicyCount
    CA_NamedLocations         = $script:caNamedLocCount
    Intune_ManagedDevices        = $script:intuneManagedDevices
    Intune_CompliancePolicies    = $script:intuneCompliancePolicies
    Intune_DeviceConfigurations  = $script:intuneDeviceConfigurations
    Intune_ConfigurationPolicies = $script:intuneConfigurationPolicies
  }

  # Add Full mode identity fields
  if ($Full) {
    $globalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $script:globalAdmins }
    $summaryProps["GlobalAdminCount"]  = $globalAdminCount
    $summaryProps["GuestUsers"]        = $script:guestUserCount
    $summaryProps["MFA_Percent"]       = if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) { [math]::Round(($script:mfaCount / $script:userCount) * 100, 1) } else { $script:mfaCount }
    $summaryProps["StaleAccounts"]     = $script:staleAccounts
    $summaryProps["RiskyUsers_High"]   = if ($script:riskyUsers -is [hashtable]) { $script:riskyUsers.High } else { $script:riskyUsers }
    $summaryProps["RiskyUsers_Medium"] = if ($script:riskyUsers -is [hashtable]) { $script:riskyUsers.Medium } else { $null }
    $summaryProps["RiskyUsers_Low"]    = if ($script:riskyUsers -is [hashtable]) { $script:riskyUsers.Low } else { $null }
    $summaryProps["SecureScore"]       = if ($script:secureScore -is [hashtable]) { $script:secureScore.Percentage } else { $script:secureScore }
    $summaryProps["TeamsCount"]        = $script:teamsCount
    $summaryProps["ProtectionReadinessScore"] = $script:readinessScore
    if ($script:ztScores -is [hashtable]) {
      $summaryProps["ZT_Identity"]  = $script:ztScores.Identity
      $summaryProps["ZT_Devices"]   = $script:ztScores.Devices
      $summaryProps["ZT_Access"]    = $script:ztScores.Access
      $summaryProps["ZT_Data"]      = $script:ztScores.Data
      $summaryProps["ZT_Apps"]      = $script:ztScores.Apps
      $summaryProps["ZT_Overall"]   = $script:ztScores.Overall
    }
  }

  $summary = [pscustomobject]$summaryProps
  $summary | Export-Csv -NoTypeInformation -Path $outSummary
  return $summary
}

<#
.SYNOPSIS
  Exports workloads CSV.
#>
function Export-WorkloadData {
  $wl = @(
    [pscustomobject]@{
      Workload         = "Exchange"
      Objects          = $script:exUsers.Count
      SharedObjects    = $script:exShared.Count
      SourceBytes      = [int64]$script:exPrimaryBytes
      SourceGB         = $script:exGB
      SourceGiB        = $script:exGiB
      AnnualGrowthPct  = $script:exGrowth
      Notes            = "Includes shared mailbox bytes from usage report; Archive/RIF added only if enabled."
    },
    [pscustomobject]@{
      Workload         = "OneDrive"
      Objects          = $script:odActive.Count
      SharedObjects    = $null
      SourceBytes      = [int64]$script:odBytes
      SourceGB         = $script:odGB
      SourceGiB        = $script:odGiB
      AnnualGrowthPct  = $script:odGrowth
      Notes            = "Accounts from usage detail; group filter applies to OneDrive owners only."
    },
    [pscustomobject]@{
      Workload         = "SharePoint"
      Objects          = $script:spActive.Count
      SharedObjects    = $script:spFiles
      SourceBytes      = [int64]$script:spBytes
      SourceGB         = $script:spGB
      SourceGiB        = $script:spGiB
      AnnualGrowthPct  = $script:spGrowth
      Notes            = "SharePoint group filtering not supported from usage reports; totals are tenant-wide."
    }
  )
  $wl | Export-Csv -NoTypeInformation -Path $outWorkload
  return $wl
}

<#
.SYNOPSIS
  Exports security CSV (Full mode only, counts only).
#>
function Export-SecurityData {
  $sec = @()
  if ($Full) {
    $sec += @(
      [pscustomobject]@{ Section="Directory"; Name="Users"; Value=$script:userCount },
      [pscustomobject]@{ Section="Directory"; Name="Groups"; Value=$script:groupCount },
      [pscustomobject]@{ Section="Directory"; Name="AppRegistrations"; Value=$script:appRegCount },
      [pscustomobject]@{ Section="Directory"; Name="ServicePrincipals"; Value=$script:spnCount },
      [pscustomobject]@{ Section="ConditionalAccess"; Name="Policies"; Value=$script:caPolicyCount },
      [pscustomobject]@{ Section="ConditionalAccess"; Name="NamedLocations"; Value=$script:caNamedLocCount },
      [pscustomobject]@{ Section="Intune"; Name="ManagedDevices"; Value=$script:intuneManagedDevices },
      [pscustomobject]@{ Section="Intune"; Name="DeviceCompliancePolicies"; Value=$script:intuneCompliancePolicies },
      [pscustomobject]@{ Section="Intune"; Name="DeviceConfigurations"; Value=$script:intuneDeviceConfigurations },
      [pscustomobject]@{ Section="Intune"; Name="ConfigurationPolicies"; Value=$script:intuneConfigurationPolicies }
    )

    # New identity assessment fields
    $globalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $script:globalAdmins }
    $sec += @(
      [pscustomobject]@{ Section="Identity"; Name="GlobalAdministrators"; Value=$globalAdminCount },
      [pscustomobject]@{ Section="Identity"; Name="GuestUsers"; Value=$script:guestUserCount },
      [pscustomobject]@{ Section="Identity"; Name="MFA_RegisteredUsers"; Value=$script:mfaCount },
      [pscustomobject]@{ Section="Identity"; Name="StaleAccounts_${STALE_DAYS}d"; Value=$script:staleAccounts },
      [pscustomobject]@{ Section="Identity"; Name="RiskyUsers_High"; Value=$(if($script:riskyUsers -is [hashtable]){$script:riskyUsers.High}else{$script:riskyUsers}) },
      [pscustomobject]@{ Section="Identity"; Name="RiskyUsers_Medium"; Value=$(if($script:riskyUsers -is [hashtable]){$script:riskyUsers.Medium}else{$null}) },
      [pscustomobject]@{ Section="Identity"; Name="RiskyUsers_Low"; Value=$(if($script:riskyUsers -is [hashtable]){$script:riskyUsers.Low}else{$null}) },
      [pscustomobject]@{ Section="Identity"; Name="SecureScore_Pct"; Value=$(if($script:secureScore -is [hashtable]){$script:secureScore.Percentage}else{$script:secureScore}) },
      [pscustomobject]@{ Section="Collaboration"; Name="TeamsCount"; Value=$script:teamsCount }
    )

    # Zero Trust pillar scores
    if ($script:ztScores -is [hashtable]) {
      $sec += @(
        [pscustomobject]@{ Section="ZeroTrust"; Name="Identity_Score"; Value=$script:ztScores.Identity },
        [pscustomobject]@{ Section="ZeroTrust"; Name="Devices_Score"; Value=$script:ztScores.Devices },
        [pscustomobject]@{ Section="ZeroTrust"; Name="Access_Score"; Value=$script:ztScores.Access },
        [pscustomobject]@{ Section="ZeroTrust"; Name="Data_Score"; Value=$script:ztScores.Data },
        [pscustomobject]@{ Section="ZeroTrust"; Name="Apps_Score"; Value=$script:ztScores.Apps },
        [pscustomobject]@{ Section="ZeroTrust"; Name="Overall_Score"; Value=$script:ztScores.Overall }
      )
    }
  }
  $sec | Export-Csv -NoTypeInformation -Path $outSecurity
  return $sec
}

<#
.SYNOPSIS
  Exports license SKUs CSV (Full mode only).
#>
function Export-LicenseData {
  if (-not $Full -or -not $script:licenseData -or $script:licenseData -is [string]) { return }
  $outLicenses = Join-Path $runFolder "Veeam-M365-Licenses-$stamp.csv"
  $script:licenseData | Export-Csv -NoTypeInformation -Path $outLicenses
  $script:outLicenses = $outLicenses
}

<#
.SYNOPSIS
  Exports findings CSV (Full mode only).
#>
function Export-FindingsData {
  if (-not $Full -or -not $script:findings -or $script:findings.Count -eq 0) { return }
  $outFindings = Join-Path $runFolder "Veeam-M365-Findings-$stamp.csv"
  $script:findings | Export-Csv -NoTypeInformation -Path $outFindings
  $script:outFindings = $outFindings
}

<#
.SYNOPSIS
  Exports recommendations CSV (Full mode only).
#>
function Export-RecommendationsData {
  if (-not $Full -or -not $script:recommendations -or $script:recommendations.Count -eq 0) { return }
  $outRecs = Join-Path $runFolder "Veeam-M365-Recommendations-$stamp.csv"
  $script:recommendations | Export-Csv -NoTypeInformation -Path $outRecs
  $script:outRecommendations = $outRecs
}

<#
.SYNOPSIS
  Exports the methodology notes TXT file.
#>
function Export-NotesFile {
  param($inputs)
  @"
Veeam M365 Sizing Notes ($stamp)

========================================
WHAT IS MBS (MICROSOFT BACKUP STORAGE)?
========================================
Microsoft Backup Storage (MBS) is CONSUMPTION-BASED PRICING for Veeam Backup for Microsoft 365.
- Microsoft charges by GB/TB of backup storage consumed in Azure (not per-user licensing)
- Backup storage is larger than source data due to retention, versioning, and incremental changes
- This assessment helps you budget Azure storage costs and right-size capacity allocation

========================================
MEASURED DATA (from Microsoft reports)
========================================
- Exchange / OneDrive / SharePoint dataset totals: Microsoft Graph Reports CSVs
- Exchange Archive and Recoverable Items: Measured directly from Exchange Online (if enabled)
  Note: Archive/RIF are NOT included in Graph usage reports

========================================
MBS CAPACITY ESTIMATION (MODELED)
========================================
This is a CAPACITY PLANNING MODEL for Azure storage, not a measured billable quantity.

Formula:
  ProjectedDatasetGB = TotalSourceGB x (1 + AnnualGrowthPct_Model)
  MonthlyChangeGB    = 30 x (ExGB x ChangeRateExchange + OdGB x ChangeRateOneDrive + SpGB x ChangeRateSharePoint)
  MbsEstimateGB      = (ProjectedDatasetGB x RetentionMultiplier_Model) + MonthlyChangeGB
  SuggestedStartGB   = MbsEstimateGB x (1 + BufferPct_Heuristic)

Why these parameters matter:
- AnnualGrowthPct: Your data grows over time; plan for future capacity needs
- RetentionMultiplier: Backups keep multiple versions; storage > source data size
- ChangeRate: Incremental backups accumulate daily changes
- BufferPct: Safety headroom to avoid capacity shortfalls

IMPORTANT: This model helps with CAPACITY PLANNING and COST BUDGETING for Azure storage consumption.

GROUP FILTERING:
- ADGroup / ExcludeADGroup filters apply to Exchange user mailboxes and OneDrive owners only.
- SharePoint usage reports do not reliably support group membership filtering without expensive graph traversal, so SharePoint is tenant-wide in this script by design.

OUTPUTS:
- Summary CSV: $outSummary
- Workloads CSV: $outWorkload
- Security CSV: $outSecurity
- Inputs CSV: $outInputs
$(if($ExportJson){"- JSON bundle: $outJson"}else{""})
$(if($Full -and $script:outLicenses){"- Licenses CSV: $($script:outLicenses)"}else{""})
$(if($Full -and $script:outFindings){"- Findings CSV: $($script:outFindings)"}else{""})
$(if($Full -and $script:outRecommendations){"- Recommendations CSV: $($script:outRecommendations)"}else{""})
"@ | Set-Content -Path $outNotes -Encoding UTF8
}

<#
.SYNOPSIS
  Exports JSON bundle with all data (optional).
#>
function Export-JsonBundle {
  param($inputs, $summary, $wl, $sec)
  if (-not $ExportJson) { return }

  $bundle = [ordered]@{
    ReportDate = (Get-Date).ToString("s")
    Tenant = [ordered]@{
      OrgName = $script:OrgName
      OrgId = $script:OrgId
      DefaultDomain = $script:DefaultDomain
      GraphEnvironment = $script:envName
      TenantCategory = $script:TenantCategory
      Mode = $(if($Full){"Full"}else{"Quick"})
    }
    Inputs = $inputs
    Summary = $summary
    Workloads = $wl
    Security = $sec
  }

  # Add Full mode data
  if ($Full) {
    if ($script:licenseData -and $script:licenseData -isnot [string]) {
      $bundle["Licenses"] = $script:licenseData
    }
    if ($script:findings -and $script:findings.Count -gt 0) {
      $bundle["Findings"] = $script:findings
    }
    if ($script:recommendations -and $script:recommendations.Count -gt 0) {
      $bundle["Recommendations"] = $script:recommendations
    }
    $bundle["IdentityRisk"] = [ordered]@{
      GlobalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $script:globalAdmins }
      GuestUsers       = $script:guestUserCount
      MfaRegistered    = $script:mfaCount
      StaleAccounts    = $script:staleAccounts
      RiskyUsers       = $script:riskyUsers
      SecureScore      = $script:secureScore
      TeamsCount       = $script:teamsCount
      ReadinessScore   = $script:readinessScore
    }
    if ($script:ztScores -is [hashtable]) {
      $bundle["ZeroTrustScores"] = [ordered]@{
        Identity = $script:ztScores.Identity
        Devices  = $script:ztScores.Devices
        Access   = $script:ztScores.Access
        Data     = $script:ztScores.Data
        Apps     = $script:ztScores.Apps
        Overall  = $script:ztScores.Overall
      }
    }
  }

  ($bundle | ConvertTo-Json -Depth 6) | Set-Content -Path $outJson -Encoding UTF8
}
