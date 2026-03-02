# =========================================================================
# Persistence.ps1 - Assessment history store and delta generation
# =========================================================================

<#
.SYNOPSIS
  Saves the current assessment snapshot to the assessment store.
.DESCRIPTION
  Persists a JSON snapshot of the current assessment including all sizing metrics,
  identity signals, findings, scores, and compliance data. Each snapshot is
  timestamped and identified by tenant OrgId for multi-tenant support.
.PARAMETER StorePath
  Directory path for the assessment history store.
.NOTES
  Creates the store directory if it doesn't exist. File naming convention:
  {OrgId}_{yyyy-MM-dd_HHmm}.json
#>
function Save-AssessmentSnapshot {
  param([Parameter(Mandatory)][string]$StorePath)

  if (-not (Test-Path $StorePath)) {
    New-Item -ItemType Directory -Path $StorePath -Force | Out-Null
  }

  $orgId = if ($script:OrgId) { $script:OrgId -replace '[^a-zA-Z0-9\-]', '' } else { "unknown" }
  $ts = Get-Date -Format "yyyy-MM-dd_HHmm"
  $fileName = "${orgId}_${ts}.json"
  $filePath = Join-Path $StorePath $fileName

  $snapshot = [ordered]@{
    SchemaVersion = 1
    Timestamp     = (Get-Date).ToString("o")
    TenantId      = $script:OrgId
    OrgName       = $script:OrgName
    DefaultDomain = $script:DefaultDomain
    Mode          = $(if ($Full) { "Full" } else { "Quick" })

    # Sizing metrics
    Sizing = [ordered]@{
      UsersToProtect     = $script:UsersToProtect
      ExchangeGB         = $script:exGB
      OneDriveGB         = $script:odGB
      SharePointGB       = $script:spGB
      TotalGB            = $script:totalGB
      TotalTB            = $script:totalTB
      ExchangeGrowthPct  = $script:exGrowth
      OneDriveGrowthPct  = $script:odGrowth
      SharePointGrowthPct = $script:spGrowth
      MbsEstimateGB      = $script:mbsEstimateGB
      SuggestedStartGB   = $script:suggestedStartGB
    }

    # Workload object counts
    WorkloadCounts = [ordered]@{
      ExchangeMailboxes  = if ($script:exUsers) { $script:exUsers.Count } else { 0 }
      SharedMailboxes    = if ($script:exShared) { $script:exShared.Count } else { 0 }
      OneDriveAccounts   = if ($script:odActive) { $script:odActive.Count } else { 0 }
      SharePointSites    = if ($script:spActive) { $script:spActive.Count } else { 0 }
      SharePointFiles    = $script:spFiles
    }
  }

  # Full mode identity and security signals
  if ($Full) {
    $globalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $script:globalAdmins }

    $snapshot["Identity"] = [ordered]@{
      UserCount          = $script:userCount
      GroupCount         = $script:groupCount
      AppRegistrations   = $script:appRegCount
      ServicePrincipals  = $script:spnCount
      GlobalAdminCount   = $globalAdminCount
      GuestUsers         = $script:guestUserCount
      MfaRegistered      = $script:mfaCount
      StaleAccounts      = $script:staleAccounts
      TeamsCount         = $script:teamsCount
      CopilotLicenses    = $script:copilotLicenses
    }

    $snapshot["Security"] = [ordered]@{
      CAPolicies              = $script:caPolicyCount
      NamedLocations          = $script:caNamedLocCount
      IntuneManagedDevices    = $script:intuneManagedDevices
      CompliancePolicies      = $script:intuneCompliancePolicies
      DeviceConfigurations    = $script:intuneDeviceConfigurations
      ConfigurationPolicies   = $script:intuneConfigurationPolicies
    }

    $snapshot["RiskyUsers"] = if ($script:riskyUsers -is [hashtable]) {
      [ordered]@{ High = $script:riskyUsers.High; Medium = $script:riskyUsers.Medium; Low = $script:riskyUsers.Low; Total = $script:riskyUsers.Total }
    } else { $script:riskyUsers }

    $snapshot["SecureScore"] = if ($script:secureScore -is [hashtable]) {
      [ordered]@{ Current = $script:secureScore.CurrentScore; Max = $script:secureScore.MaxScore; Percentage = $script:secureScore.Percentage }
    } else { $script:secureScore }

    $snapshot["Scores"] = [ordered]@{
      ReadinessScore = $script:readinessScore
      ZeroTrust      = if ($script:ztScores -is [hashtable]) { $script:ztScores } else { $null }
    }

    if ($script:complianceScores) {
      $snapshot["ComplianceScores"] = $script:complianceScores
    }
  }

  ($snapshot | ConvertTo-Json -Depth 8) | Set-Content -Path $filePath -Encoding UTF8
  Write-Log "Assessment snapshot saved: $filePath"
  return $filePath
}

<#
.SYNOPSIS
  Loads the most recent prior assessment snapshot for a tenant.
.PARAMETER StorePath
  Directory path for the assessment history store.
.PARAMETER TenantId
  The OrgId of the tenant to find prior assessments for.
.NOTES
  Returns $null if no prior assessment exists.
  Skips the current run by checking timestamp difference.
#>
function Get-PriorAssessment {
  param(
    [Parameter(Mandatory)][string]$StorePath,
    [string]$TenantId
  )

  if (-not (Test-Path $StorePath)) { return $null }

  $orgId = if ($TenantId) { $TenantId -replace '[^a-zA-Z0-9\-]', '' } else { "*" }
  $pattern = "${orgId}_*.json"
  $files = Get-ChildItem -Path $StorePath -Filter $pattern -File | Sort-Object LastWriteTime -Descending

  # Skip files written in the last 60 seconds (current run)
  $cutoff = (Get-Date).AddSeconds(-60)
  $priorFiles = @($files | Where-Object { $_.LastWriteTime -lt $cutoff })

  if ($priorFiles.Count -eq 0) { return $null }

  $priorPath = $priorFiles[0].FullName
  try {
    $content = Get-Content -Path $priorPath -Raw -Encoding UTF8
    $prior = $content | ConvertFrom-Json
    Write-Log "Loaded prior assessment: $priorPath ($(if ($prior.Timestamp) { $prior.Timestamp } else { 'unknown date' }))"
    return $prior
  } catch {
    Write-Log "Failed to load prior assessment: $($_.Exception.Message)" -Level "WARNING"
    return $null
  }
}

<#
.SYNOPSIS
  Generates a delta report comparing current assessment to a prior snapshot.
.PARAMETER Prior
  The prior assessment object from Get-PriorAssessment.
.NOTES
  Returns a structured delta object with changes for each metric area.
  Positive delta = growth/increase, negative = reduction.
  Each metric includes: Prior, Current, Delta, DeltaPct, Direction (Up/Down/Stable).
#>
function Get-AssessmentDelta {
  param([Parameter(Mandatory)]$Prior)

  $delta = [ordered]@{
    PriorDate     = $Prior.Timestamp
    CurrentDate   = (Get-Date).ToString("o")
    DaysBetween   = [int]((Get-Date) - [datetime]$Prior.Timestamp).TotalDays
  }

  # --- Sizing Deltas ---
  $sizingDelta = [ordered]@{}
  $sizingFields = @(
    @{ Name = "UsersToProtect";  Current = $script:UsersToProtect;    Prior = $Prior.Sizing.UsersToProtect },
    @{ Name = "ExchangeGB";      Current = $script:exGB;              Prior = $Prior.Sizing.ExchangeGB },
    @{ Name = "OneDriveGB";      Current = $script:odGB;              Prior = $Prior.Sizing.OneDriveGB },
    @{ Name = "SharePointGB";    Current = $script:spGB;              Prior = $Prior.Sizing.SharePointGB },
    @{ Name = "TotalGB";         Current = $script:totalGB;           Prior = $Prior.Sizing.TotalGB },
    @{ Name = "MbsEstimateGB";   Current = $script:mbsEstimateGB;     Prior = $Prior.Sizing.MbsEstimateGB },
    @{ Name = "SuggestedStartGB";Current = $script:suggestedStartGB;  Prior = $Prior.Sizing.SuggestedStartGB }
  )

  foreach ($field in $sizingFields) {
    $sizingDelta[$field.Name] = _CalcDelta -Current $field.Current -Prior $field.Prior
  }
  $delta["Sizing"] = $sizingDelta

  # --- Identity Deltas (Full mode) ---
  if ($Full -and $Prior.Identity) {
    $identityDelta = [ordered]@{}
    $identityFields = @(
      @{ Name = "UserCount";       Current = $script:userCount;       Prior = $Prior.Identity.UserCount },
      @{ Name = "GroupCount";      Current = $script:groupCount;      Prior = $Prior.Identity.GroupCount },
      @{ Name = "GuestUsers";     Current = $script:guestUserCount;  Prior = $Prior.Identity.GuestUsers },
      @{ Name = "MfaRegistered";  Current = $script:mfaCount;        Prior = $Prior.Identity.MfaRegistered },
      @{ Name = "StaleAccounts";  Current = $script:staleAccounts;   Prior = $Prior.Identity.StaleAccounts },
      @{ Name = "TeamsCount";     Current = $script:teamsCount;       Prior = $Prior.Identity.TeamsCount },
      @{ Name = "CopilotLicenses";Current = $script:copilotLicenses; Prior = $Prior.Identity.CopilotLicenses }
    )

    foreach ($field in $identityFields) {
      $identityDelta[$field.Name] = _CalcDelta -Current $field.Current -Prior $field.Prior
    }
    $delta["Identity"] = $identityDelta
  }

  # --- Score Deltas (Full mode) ---
  if ($Full -and $Prior.Scores) {
    $scoreDelta = [ordered]@{}
    $scoreDelta["ReadinessScore"] = _CalcDelta -Current $script:readinessScore -Prior $Prior.Scores.ReadinessScore

    if ($script:ztScores -is [hashtable] -and $Prior.Scores.ZeroTrust) {
      foreach ($pillar in @("Identity", "Devices", "Access", "Data", "Apps", "Overall")) {
        $priorVal = $Prior.Scores.ZeroTrust.$pillar
        $currentVal = $script:ztScores[$pillar]
        $scoreDelta["ZT_$pillar"] = _CalcDelta -Current $currentVal -Prior $priorVal
      }
    }

    $delta["Scores"] = $scoreDelta
  }

  # --- Compliance Score Deltas ---
  if ($script:complianceScores -and $Prior.ComplianceScores) {
    $compDelta = [ordered]@{}
    foreach ($fw in @("NIS2", "SOC2", "ISO27001", "Overall")) {
      $priorScore = if ($Prior.ComplianceScores.$fw) { $Prior.ComplianceScores.$fw.Score } else { $null }
      $currentScore = if ($script:complianceScores[$fw]) { $script:complianceScores[$fw].Score } else { $null }
      $compDelta[$fw] = _CalcDelta -Current $currentScore -Prior $priorScore
    }
    $delta["ComplianceScores"] = $compDelta
  }

  return $delta
}

<#
.SYNOPSIS
  Calculates delta between current and prior values.
.NOTES
  Returns hashtable with Prior, Current, Delta, DeltaPct, Direction.
  Handles non-numeric and null values gracefully.
#>
function _CalcDelta {
  param($Current, $Prior)

  $result = [ordered]@{
    Prior     = $Prior
    Current   = $Current
    Delta     = $null
    DeltaPct  = $null
    Direction = "Unknown"
  }

  # Skip if either value is non-numeric
  if ($null -eq $Current -or $null -eq $Prior) {
    $result.Direction = "No Data"
    return $result
  }
  if ($Current -is [string] -or $Prior -is [string]) {
    $result.Direction = "N/A"
    return $result
  }

  try {
    $c = [double]$Current
    $p = [double]$Prior
    $result.Delta = [math]::Round($c - $p, 2)
    $result.DeltaPct = if ($p -ne 0) { [math]::Round((($c - $p) / [math]::Abs($p)) * 100, 1) } else { $null }

    if ($result.Delta -gt 0) { $result.Direction = "Up" }
    elseif ($result.Delta -lt 0) { $result.Direction = "Down" }
    else { $result.Direction = "Stable" }
  } catch {
    $result.Direction = "Error"
  }

  return $result
}

<#
.SYNOPSIS
  Lists all assessment snapshots for a tenant.
.PARAMETER StorePath
  Directory path for the assessment history store.
.PARAMETER TenantId
  Optional filter by OrgId. If empty, returns all tenants.
.NOTES
  Returns array of summary objects with filename, date, tenant info.
#>
function Get-AssessmentHistory {
  param(
    [Parameter(Mandatory)][string]$StorePath,
    [string]$TenantId
  )

  if (-not (Test-Path $StorePath)) { return @() }

  $orgId = if ($TenantId) { $TenantId -replace '[^a-zA-Z0-9\-]', '' } else { "*" }
  $pattern = "${orgId}_*.json"
  $files = Get-ChildItem -Path $StorePath -Filter $pattern -File | Sort-Object LastWriteTime -Descending

  $history = New-Object System.Collections.Generic.List[object]
  foreach ($f in $files) {
    try {
      $content = Get-Content -Path $f.FullName -Raw -Encoding UTF8
      $snap = $content | ConvertFrom-Json
      $history.Add([PSCustomObject]@{
        File        = $f.Name
        Date        = $snap.Timestamp
        OrgName     = $snap.OrgName
        TenantId    = $snap.TenantId
        Mode        = $snap.Mode
        TotalGB     = if ($snap.Sizing) { $snap.Sizing.TotalGB } else { $null }
        Users       = if ($snap.Sizing) { $snap.Sizing.UsersToProtect } else { $null }
        Readiness   = if ($snap.Scores) { $snap.Scores.ReadinessScore } else { $null }
      })
    } catch {
      # Skip corrupt files
    }
  }

  return ,@($history)
}
