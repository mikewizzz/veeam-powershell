# =========================================================================
# DataCollection.ps1 - Usage reports, growth calc, group filtering, Exchange deep sizing
# =========================================================================

# =============================
# Group Filtering Functions
# =============================

<#
.SYNOPSIS
  Retrieves all user principal names (UPNs) from an Entra ID group.
.PARAMETER GroupName
  Display name of the Entra ID group.
.PARAMETER Required
  If true, throws error when group not found or contains no users.
.NOTES
  Uses transitive membership to include nested group members.
  Filters results to user objects only (excludes devices, service principals).
#>
function Get-GroupUPNs([string]$GroupName, [bool]$Required = $false) {
  if ([string]::IsNullOrWhiteSpace($GroupName)) { return @() }
  $safe = Escape-ODataString $GroupName
  $g = Get-MgGroup -Filter "DisplayName eq '$safe'"
  if (-not $g) {
    if ($Required) { throw "Entra ID group '$GroupName' not found." }
    return @()
  }
  $upns = New-Object System.Collections.Generic.List[string]
  Get-MgGroupTransitiveMember -GroupId $g.Id -All | ForEach-Object {
    if ($_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user') {
      $u = $_.AdditionalProperties['userPrincipalName']
      if ($u) { $upns.Add($u) }
    }
  }
  if ($Required -and $upns.Count -eq 0) { throw "No user UPNs found in group '$GroupName'." }
  return @($upns | Sort-Object -Unique)
}

<#
.SYNOPSIS
  Applies inclusion and exclusion filters to usage report data based on UPN.
.PARAMETER Data
  Array of report objects (Exchange or OneDrive usage data).
.PARAMETER UpnField
  Name of the field containing the user principal name.
#>
function Apply-UpnFilters([object[]]$Data, [string]$UpnField) {
  $Data = $Data | Where-Object { $_ -ne $null -and $_.'Is Deleted' -ne 'TRUE' }
  if ($script:GroupUPNs -and $script:GroupUPNs.Count -gt 0) {
    $Data = $Data | Where-Object { $script:GroupUPNs -contains $_.$UpnField }
  }
  if ($script:ExcludeUPNs -and $script:ExcludeUPNs.Count -gt 0) {
    $Data = $Data | Where-Object { $script:ExcludeUPNs -notcontains $_.$UpnField }
  }
  return $Data
}

# =============================
# Graph Report Functions
# =============================

<#
.SYNOPSIS
  Downloads and imports a Microsoft 365 usage report CSV from Graph API.
.PARAMETER ReportName
  Name of the Graph report (e.g., "getMailboxUsageDetail").
.PARAMETER PeriodDays
  Reporting period in days (7, 30, 90, or 180).
#>
function Get-GraphReportCsv {
  param([Parameter(Mandatory)][string]$ReportName,[int]$PeriodDays)
  $uri = "https://graph.microsoft.com/v1.0/reports/$ReportName(period='D$PeriodDays')"
  $tmp = Join-Path $runFolder "$ReportName.csv"
  Invoke-GraphDownloadCsv -Uri $uri -OutPath $tmp
  $data = Import-Csv $tmp
  # Remove raw CSV containing PII (UPNs, display names) after import
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  return $data
}

<#
.SYNOPSIS
  Calculates annualized growth rate from time-series usage data.
.PARAMETER csv
  Array of report objects with 'Report Date', 'Report Period', and target field.
.PARAMETER field
  Name of the numeric field to analyze (e.g., 'Storage Used (Byte)').
#>
function Annualize-GrowthPct {
  param([Parameter(Mandatory)][object[]]$csv,[Parameter(Mandatory)][string]$field)
  $rows = $csv | Sort-Object { [datetime]$_.'Report Date' } -Descending
  if (-not $rows -or $rows.Count -lt 2) { return 0.0 }

  $latest   = [double]$rows[0].$field
  $earliest = [double]$rows[-1].$field
  $days     = [int]$rows[0].'Report Period'

  if ($days -le 0 -or $earliest -le 0) { return 0.0 }

  $perDay  = ($latest - $earliest) / $days
  $perYear = $perDay * 365
  $pct     = $perYear / [math]::Max($earliest,1)

  return [math]::Round($pct, 4)
}

# =============================
# Core Data Collection
# =============================

<#
.SYNOPSIS
  Collects all M365 usage data from Graph API reports and computes sizing metrics.
.DESCRIPTION
  Downloads Exchange, OneDrive, SharePoint reports; applies group filters;
  computes growth rates; handles optional Archive/RIF deep sizing;
  calculates MBS capacity estimates.
.NOTES
  Sets numerous script-level variables consumed by exports and HTML report.
#>
function Invoke-DataCollection {
  # Retrieve group membership lists for filtering
  $script:GroupUPNs   = Get-GroupUPNs -GroupName $ADGroup -Required:$false
  $script:ExcludeUPNs = Get-GroupUPNs -GroupName $ExcludeADGroup -Required:$false

  Write-Host "Pulling Microsoft 365 usage reports (Graph)..." -ForegroundColor Green

  $script:exDetail   = Get-GraphReportCsv -ReportName "getMailboxUsageDetail"          -PeriodDays $Period
  $script:exCounts   = Get-GraphReportCsv -ReportName "getMailboxUsageMailboxCounts"  -PeriodDays $Period
  $script:odDetail   = Get-GraphReportCsv -ReportName "getOneDriveUsageAccountDetail" -PeriodDays $Period
  $script:odStorage  = Get-GraphReportCsv -ReportName "getOneDriveUsageStorage"       -PeriodDays $Period
  $script:spDetail   = Get-GraphReportCsv -ReportName "getSharePointSiteUsageDetail"  -PeriodDays $Period
  $script:spStorage  = Get-GraphReportCsv -ReportName "getSharePointSiteUsageStorage" -PeriodDays $Period

  # Exchange: filter active, separate shared mailboxes
  $exUsersAll  = $script:exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -ne 'Shared' }
  $exSharedAll = $script:exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -eq 'Shared' }

  # Apply group filters (Exchange + OneDrive only)
  $script:exUsers  = Apply-UpnFilters $exUsersAll  'User Principal Name'
  $script:exShared = $exSharedAll

  $odActiveAll      = $script:odDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' }
  $script:odActive  = Apply-UpnFilters $odActiveAll 'Owner Principal Name'

  # SharePoint: no group filtering (Graph API limitation)
  $script:spActive = $script:spDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' }

  # Group filtering sanity check
  if ($ADGroup) {
    $sampleUpn = ($exUsersAll | Select-Object -First 5).'User Principal Name'
    $looksMasked = $false
    if ($sampleUpn) {
      $maskedCount = ($sampleUpn | Where-Object { $_ -notmatch '@' -or $_ -match '^Anonymous' }).Count
      if ($maskedCount -ge 3) { $looksMasked = $true }
    }
    if ($looksMasked) {
      throw "Your M365 usage reports appear to have user identifiers concealed (masked). Group filtering by UPN will fail. Unmask reports in M365 Admin Center -> Settings -> Org settings -> Services -> Reports -> disable concealed names, then re-run."
    }
    if ($script:GroupUPNs.Count -gt 0 -and $script:exUsers.Count -eq 0 -and $script:odActive.Count -eq 0) {
      throw "ADGroup filtering matched 0 Exchange users and 0 OneDrive accounts. This is usually caused by report masking or an unexpected UPN mismatch. Re-check report settings and group membership."
    }
  }

  # Unique users to protect
  $uniqueUPN = @()
  $uniqueUPN += @($script:exUsers.'User Principal Name')
  $uniqueUPN += @($script:odActive.'Owner Principal Name')
  $script:UsersToProtect = (@($uniqueUPN | Where-Object { $_ } | Sort-Object -Unique)).Count

  # Source bytes
  $script:exUserBytes    = [double](($script:exUsers   | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
  $script:exSharedBytes  = [double](($script:exShared  | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
  $script:exPrimaryBytes = [double]($script:exUserBytes + $script:exSharedBytes)
  $script:odBytes        = [double](($script:odActive  | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
  $script:spBytes        = [double](($script:spActive  | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)

  # Optional Exchange deep sizing
  $script:archBytes = 0.0
  $script:rifBytes  = 0.0

  if ($IncludeArchive -or $IncludeRecoverableItems) {
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
      if ($SkipModuleInstall) {
        throw "Missing required module 'ExchangeOnlineManagement'. Install with: Install-Module ExchangeOnlineManagement -Scope CurrentUser"
      }
      Write-Log "Installing ExchangeOnlineManagement"
      Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
    }
    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    Write-Host "Connecting to Exchange Online for deep sizing (Archive/RIF)..." -ForegroundColor Yellow
    try {
      Connect-ExchangeOnline -ShowBanner:$false
    } catch {
      throw "Failed to connect to Exchange Online. If you do not need Archive/RIF sizing, re-run without -IncludeArchive / -IncludeRecoverableItems. Error: $($_.Exception.Message)"
    }

    if ($IncludeArchive) {
      $withArchive = $exUsersAll | Where-Object { $_.'Has Archive' -eq 'TRUE' }
      $count = $withArchive.Count
      Write-Host "Measuring Exchange In-Place Archive size for $count mailboxes (sequential)..." -ForegroundColor Yellow

      $i = 0
      foreach ($u in $withArchive) {
        $i++
        if (($i % 25) -eq 0) { Write-Host "  Archive progress: $i / $count" }
        $id = $u.'User Principal Name'
        try {
          $s = Get-EXOMailboxStatistics -Archive -Identity $id -ErrorAction Stop
          if ($s.TotalItemSize -match '\(([^)]+) bytes\)') {
            $script:archBytes += [double]([int64]($matches[1] -replace ',',''))
          }
        } catch {
          Write-Log "Archive stats failed for $id : $($_.Exception.Message)"
        }
      }
      $script:exPrimaryBytes += $script:archBytes
    }

    if ($IncludeRecoverableItems) {
      $allEx = @($exUsersAll + $exSharedAll)
      $count = $allEx.Count
      Write-Host "Measuring Exchange Recoverable Items size for $count mailboxes (sequential)..." -ForegroundColor Yellow

      $recoverableItemsSpecialFolders = @("/Deletions","/Purges","/Versions","/DiscoveryHolds")
      $i = 0
      foreach ($u in $allEx) {
        $i++
        if (($i % 25) -eq 0) { Write-Host "  RIF progress: $i / $count" }
        $id = $u.'User Principal Name'
        if ([string]::IsNullOrWhiteSpace($id)) { continue }
        try {
          $stats = Get-MailboxFolderStatistics -Identity $id -FolderScope RecoverableItems -ErrorAction Stop |
                   Where-Object { $recoverableItemsSpecialFolders -contains $_.FolderPath }
          foreach ($f in $stats) {
            if ($f.FolderSize -match '\(([^)]+) bytes\)') {
              $script:rifBytes += [double]([int64]($matches[1] -replace ',',''))
            }
          }
        } catch {
          Write-Log "RIF stats failed for $id : $($_.Exception.Message)"
        }
      }
      $script:exPrimaryBytes += $script:rifBytes
    }

    Disconnect-ExchangeOnline -Confirm:$false | Out-Null
  }

  # Growth (annualized)
  $script:exGrowth = Annualize-GrowthPct -csv (Get-GraphReportCsv -ReportName "getMailboxUsageStorage" -PeriodDays $Period) -field 'Storage Used (Byte)'
  $script:odGrowth = Annualize-GrowthPct -csv $script:odStorage -field 'Storage Used (Byte)'
  $script:spGrowth = Annualize-GrowthPct -csv $script:spStorage -field 'Storage Used (Byte)'

  # Convert totals (decimal + binary)
  $script:exGB  = To-GB  $script:exPrimaryBytes
  $script:odGB  = To-GB  $script:odBytes
  $script:spGB  = To-GB  $script:spBytes
  $script:totalGB = [math]::Round($script:exGB + $script:odGB + $script:spGB, 2)

  $script:exGiB = To-GiB $script:exPrimaryBytes
  $script:odGiB = To-GiB $script:odBytes
  $script:spGiB = To-GiB $script:spBytes
  $script:totalGiB = [math]::Round($script:exGiB + $script:odGiB + $script:spGiB, 2)

  $script:totalTB  = [math]::Round($script:totalGB / 1000, 4)
  $script:totalTiB = [math]::Round($script:totalGiB / 1024, 4)

  # SharePoint file count
  $script:spFiles = ($script:spActive | Measure-Object -Property 'File Count' -Sum).Sum

  # MBS Capacity Estimation
  $script:dailyChangeGB = ($script:exGB * $ChangeRateExchange) + ($script:odGB * $ChangeRateOneDrive) + ($script:spGB * $ChangeRateSharePoint)
  $script:monthChangeGB = [math]::Round($script:dailyChangeGB * 30, 2)

  $script:projGB = [math]::Round($script:totalGB * (1 + $AnnualGrowthPct), 2)
  $script:mbsEstimateGB = [math]::Round(($script:projGB * $RetentionMultiplier) + $script:monthChangeGB, 2)
  $script:suggestedStartGB = [math]::Round($script:mbsEstimateGB * (1 + $BufferPct), 2)
}
