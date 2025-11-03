<# 
.SYNOPSIS
  Get-VeeamM365Sizing.ps1 — Veeam M365 sizing (users + storage + growth) with tenant type, 
  security licensing, and Entra ID posture signals. 2025-hardened with retry/backoff, 
  safe defaults, PII masking, and JSON/HTML/CSV outputs.

.NOTES
  Author : Veeam Sr. Cloud Architect
  Version: 2025.10.26
#>

[CmdletBinding()]
param(
  # Auth
  [switch]$UseAppAccess,                      # Use client credentials instead of delegated user
  [string]$TenantId,
  [string]$ClientId,
  [securestring]$ClientSecret,

  # Scope (optional)
  [string]$ADGroup,                           # Only this Entra ID group (DisplayName)
  [string]$ExcludeADGroup,                    # Exclude this Entra ID group (DisplayName)
  [ValidateSet(7,30,90,180)][int]$Period = 90,

  # Deep Exchange (off by default to avoid throttling)
  [switch]$IncludeArchive,
  [switch]$IncludeRecoverableItems,

  # Estimation knobs for MBS (Metered Backup Storage)
  [double]$AnnualGrowthPct = 0.15,            # org-wide projection
  [double]$RetentionMultiplier = 1.30,        # retention factor (e.g., 45 daily + 6 weekly)
  [double]$ChangeRateExchange = 0.015,        # daily change rate
  [double]$ChangeRateOneDrive = 0.004,
  [double]$ChangeRateSharePoint = 0.003,

  # Output & UX
  [string]$OutFolder = ".",
  [switch]$ExportJson,                        # also emit a JSON bundle
  [switch]$MaskUserIds,                       # obfuscate UPNs in outputs (PII reduction)
  [int]$ThrottleLimit = 6,                    # used for EXO deep loops
  [switch]$EnableTelemetry                    # lightweight local log
)

# ========== Guardrails ==========
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'
$stamp    = Get-Date -Format "yyyy-MM-dd_HHmm"
$outHtml  = Join-Path $OutFolder "Veeam-M365-Sizing-$stamp.html"
$outCsv   = Join-Path $OutFolder "Veeam-M365-Summary-$stamp.csv"
$outWlCsv = Join-Path $OutFolder "Veeam-M365-Workloads-$stamp.csv"
$outSecCsv= Join-Path $OutFolder "Veeam-M365-Security-$stamp.csv"
$outJson  = Join-Path $OutFolder "Veeam-M365-Bundle-$stamp.json"
$logPath  = Join-Path $OutFolder "Veeam-M365-Log-$stamp.txt"

if ($EnableTelemetry) { "[$(Get-Date -Format s)] Starting run" | Add-Content $logPath }

# ========== Units ==========
$GB = [double]1e9
function To-GB([long]$bytes){ [math]::Round($bytes / $GB, 2) }

# ========== Retry / Backoff helper ==========
function Invoke-Graph {
  param(
    [Parameter(Mandatory)][string]$Uri,
    [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method='GET',
    [hashtable]$Headers,
    $Body,
    [int]$MaxRetries = 6
  )
  $attempt = 0
  do {
    try {
      if ($EnableTelemetry) { "[$(Get-Date -Format s)] Graph $Method $Uri" | Add-Content $logPath }
      if ($Body) {
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body
      } else {
        return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers
      }
    } catch {
      $attempt++
      $msg = $_.Exception.Message
      $retryAfter = 0
      # Try to honor Retry-After header if present
      if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
        [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
      }
      if ($attempt -le $MaxRetries -and ($msg -match 'Too Many Requests|throttle|429|5\d\d')) {
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
        if ($EnableTelemetry) { "[$(Get-Date -Format s)] Throttled: sleeping $sleep sec (attempt $attempt/$MaxRetries)" | Add-Content $logPath }
        Start-Sleep -Seconds $sleep
      } else {
        throw
      }
    }
  } while ($true)
}

# ========== Module checks ==========
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Reports)) {
  if ($EnableTelemetry) { "Installing Microsoft.Graph.Reports" | Add-Content $logPath }
  Install-Module Microsoft.Graph.Reports -Scope CurrentUser -Force
}
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
  if ($EnableTelemetry) { "Installing Microsoft.Graph" | Add-Content $logPath }
  Install-Module Microsoft.Graph -Scope CurrentUser -Force
}
Import-Module Microsoft.Graph.Reports
Import-Module Microsoft.Graph

# ========== Auth ==========
if ($UseAppAccess) {
  if (-not $TenantId -or -not $ClientId -or -not $ClientSecret) {
    throw "For -UseAppAccess please provide -TenantId, -ClientId, -ClientSecret."
  }
  $clientSecretCred = [System.Management.Automation.PSCredential]::new($ClientId, $ClientSecret)
  Connect-MgGraph -TenantId $TenantId -ClientSecretCredential $clientSecretCred -NoWelcome
} else {
  # Include Application.Read.All for app reg counts; Policy.Read.All for CA policies
  Connect-MgGraph -Scopes "Reports.Read.All","Directory.Read.All","User.Read.All","Group.Read.All","Organization.Read.All","Application.Read.All","Policy.Read.All" -NoWelcome
}

# ========== Tenant env/type ==========
$ctx = Get-MgContext
$envName = try { $ctx.Environment.Name } catch { "Unknown" }
$TenantCategory = switch ($envName) {
  "AzureUSGovernment" { "US Government (GCC/GCC High/DoD)" }
  "AzureChinaCloud"   { "China (21Vianet)" }
  "AzureCloud"        { "Commercial" }
  default             { "Unknown" }
}
$org = (Get-MgOrganization)[0]
$OrgId = $org.Id
$OrgName = $org.DisplayName
$DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1).Name

# ========== Helpers ==========
function Get-GraphReportCsv {
  param([Parameter(Mandatory)][string]$ReportName,[int]$PeriodDays)
  $uri = if ($PeriodDays) { "https://graph.microsoft.com/v1.0/reports/$ReportName(period='D$PeriodDays')" }
         else { "https://graph.microsoft.com/v1.0/reports/$ReportName" }
  $tmp = Join-Path $env:TEMP "$ReportName.csv"
  Invoke-MgGraphRequest -Uri $uri -OutputFilePath $tmp | Out-Null
  return (Import-Csv $tmp)
}
function Annualize-Growth {
  param([Parameter(Mandatory)][object[]]$csv,[Parameter(Mandatory)][string]$field)
  $rows = $csv | Sort-Object { [datetime]$_.'Report Date' } -Descending
  if(-not $rows){ return 0.0 }
  $latest   = [double]$rows[0].$field
  $earliest = [double]$rows[-1].$field
  $days     = [int]$rows[0].'Report Period'
  if($days -le 0 -or $latest -le 0){ return 0.0 }
  $perDay   = ($latest - $earliest) / $days
  $perYear  = $perDay * 365
  return [math]::Round(($perYear / [math]::Max($latest,1)),2)
}
function Get-GraphEntityCount {
  param([Parameter(Mandatory)][string]$Path)  # 'users','groups','applications','servicePrincipals','identity/conditionalAccess/policies','identity/conditionalAccess/namedLocations'
  $uri = "https://graph.microsoft.com/v1.0/$Path?`$top=1&`$count=true"
  $headers = @{ "ConsistencyLevel" = "eventual" }
  try {
    $resp = Invoke-Graph -Uri $uri -Headers $headers
    if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
    elseif ($resp.value)      { return [int]$resp.value.Count }
    else                      { return 0 }
  } catch {
    return "access_denied"
  }
}
function Mask-UPN([string]$upn){
  if (-not $MaskUserIds -or [string]::IsNullOrWhiteSpace($upn)) { return $upn }
  $hash = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes($upn)))).Hash
  return "user_" + $hash.Substring(0,12).ToLower()
}

# ========== SKU helpers ==========
function Get-SubscribedSkuSummary {
  $skus = Get-MgSubscribedSku
  $map = @()
  foreach($s in $skus){
    $map += [pscustomobject]@{
      SkuPartNumber = $s.SkuPartNumber
      Consumed      = $s.ConsumedUnits
      Enabled       = $s.PrepaidUnits.Enabled
    }
  }
  return $map
}
$SkuFriendly = @{
  "ENTERPRISEPREMIUM"         = "Office 365 E5"
  "ENTERPRISEPACK"            = "Office 365 E3"
  "STANDARDPACK"              = "Office 365 E1"
  "SPE_E5"                    = "Microsoft 365 E5"
  "SPE_E3"                    = "Microsoft 365 E3"
  "M365EDU_A5_FACULTY"        = "Microsoft 365 A5 Faculty"
  "M365EDU_A5_STUUSEBNFT"     = "Microsoft 365 A5 Student"
  "M365EDU_A3_FACULTY"        = "Microsoft 365 A3 Faculty"
  "M365EDU_A3_STUUSEBNFT"     = "Microsoft 365 A3 Student"
  "BUSINESS_PREMIUM"          = "Microsoft 365 Business Premium"
  "F3"                        = "Microsoft 365 F3"
  "EXCHANGE_S_ENTERPRISE"     = "Exchange Online Plan 2"
  "EXCHANGE_S_STANDARD"       = "Exchange Online Plan 1"
  # Security suites / add-ons (add more as needed)
  "AAD_PREMIUM"               = "Azure AD Premium P1"
  "AAD_PREMIUM_P2"            = "Azure AD Premium P2"
  "EMSPREMIUM"                = "Enterprise Mobility + Security E3"
  "ATP_ENTERPRISE"            = "Defender for Office 365 Plan 2"
}
function Label-Sku([string]$p){ if($SkuFriendly.ContainsKey($p)){ $SkuFriendly[$p] } else { $p } }
$LicenseBuckets = @{
  Office365E5      = @('ENTERPRISEPREMIUM')
  Office365E3      = @('ENTERPRISEPACK')
  Microsoft365E5   = @('SPE_E5')
  Microsoft365E3   = @('SPE_E3')
  A5Faculty        = @('M365EDU_A5_FACULTY')
  A5Student        = @('M365EDU_A5_STUUSEBNFT')
  A3Faculty        = @('M365EDU_A3_FACULTY')
  A3Student        = @('M365EDU_A3_STUUSEBNFT')
  BusinessPremium  = @('BUSINESS_PREMIUM')
  F3               = @('F3')
  AzureADP2        = @('AAD_PREMIUM_P2')
  AzureADP1        = @('AAD_PREMIUM')
  EMSE3            = @('EMSPREMIUM')
  DefenderO365P2   = @('ATP_ENTERPRISE')
}

# ========== Optional AD group filter ==========
$GroupUPNs = $null; $ExcludeUPNs = $null
if ($ADGroup -or $ExcludeADGroup){
  if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Groups)) {
    Install-Module Microsoft.Graph.Groups -Scope CurrentUser -Force
  }
  Import-Module Microsoft.Graph.Groups
}
if ($ADGroup){
  $g = Get-MgGroup -Filter "DisplayName eq '$ADGroup'"
  if(-not $g){ throw "AD Group '$ADGroup' not found." }
  $members = Get-MgGroupTransitiveMember -GroupId $g.Id -All
  $GroupUPNs = @()
  foreach($m in $members){
    if ($m.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user'){
      $GroupUPNs += $m.AdditionalProperties['userPrincipalName']
    }
  }
  if(-not $GroupUPNs){ throw "No user UPNs in group '$ADGroup'." }
}
if ($ExcludeADGroup){
  $gx = Get-MgGroup -Filter "DisplayName eq '$ExcludeADGroup'"
  if($gx){
    $ExcludeUPNs = @()
    (Get-MgGroupTransitiveMember -GroupId $gx.Id -All) | % {
      if ($_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.user'){
        $ExcludeUPNs += $_.AdditionalProperties['userPrincipalName']
      }
    }
  }
}

# ========== Reports (v1.0) ==========
Write-Host "Pulling Microsoft 365 usage reports..." -ForegroundColor Green
$exDetail   = Get-GraphReportCsv -ReportName "getMailboxUsageDetail" -PeriodDays $Period
$exCounts   = Get-GraphReportCsv -ReportName "getMailboxUsageMailboxCounts" -PeriodDays $Period
$odDetail   = Get-GraphReportCsv -ReportName "getOneDriveUsageAccountDetail" -PeriodDays $Period
$odStorage  = Get-GraphReportCsv -ReportName "getOneDriveUsageStorage" -PeriodDays $Period
$spDetail   = Get-GraphReportCsv -ReportName "getSharePointSiteUsageDetail" -PeriodDays $Period
$spStorage  = Get-GraphReportCsv -ReportName "getSharePointSiteUsageStorage" -PeriodDays $Period

# Filter active + group filters
$exActiveUsers = $exDetail | Where-Object { $_.'Is Deleted' -eq 'FALSE' -and $_.'Recipient Type' -ne 'Shared' }
$exShared      = $exDetail | Where-Object { $_.'Is Deleted' -eq 'FALSE' -and $_.'Recipient Type' -eq 'Shared' }
$odActive      = $odDetail | Where-Object { $_.'Is Deleted' -eq 'FALSE' }
$spActive      = $spDetail | Where-Object { $_.'Is Deleted' -eq 'FALSE' }

if ($GroupUPNs){
  $exActiveUsers = $exActiveUsers | Where-Object { $GroupUPNs -contains $_.'User Principal Name' }
  $odActive      = $odActive      | Where-Object { $GroupUPNs -contains $_.'Owner Principal Name' }
}
if ($ExcludeUPNs){
  $exActiveUsers = $exActiveUsers | Where-Object { $ExcludeUPNs -notcontains $_.'User Principal Name' }
  $odActive      = $odActive      | Where-Object { $ExcludeUPNs -notcontains $_.'Owner Principal Name' }
}

# Unique users to protect (UPN union)
$exUPN = $exActiveUsers.'User Principal Name'
$odUPN = $odActive.'Owner Principal Name'
$uniqueUPN = @() + $exUPN + $odUPN | Where-Object { $_ -and $_ -ne "" } | Sort-Object -Unique
$UsersToProtect = $uniqueUPN.Count

# Source bytes
$exUserBytes   = ($exActiveUsers | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum
$exSharedBytes = ($exShared      | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum
$exPrimaryBytes  = [int64]($exUserBytes + $exSharedBytes)
$odBytes       = ($odActive     | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum
$spBytes       = ($spActive     | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum

# Optional EXO deep scans
$archBytes = 0; $rifBytes = 0
if ($IncludeArchive -or $IncludeRecoverableItems){
  if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module ExchangeOnlineManagement -Scope CurrentUser -Force
  }
  Import-Module ExchangeOnlineManagement
  if ($UseAppAccess){
    Write-Warning "EXO deep scanning with app auth requires proper app/permissions; using delegated as fallback prompt."
    Connect-ExchangeOnline -ShowBanner:$false
  } else {
    Connect-ExchangeOnline -ShowBanner:$false
  }

  if ($IncludeArchive){
    $withArchive = $exActiveUsers | Where-Object { $_.'Has Archive' -eq 'TRUE' }
    $sem = [System.Threading.SemaphoreSlim]::new($ThrottleLimit, $ThrottleLimit)
    $tasks = foreach($u in $withArchive){
      $null = $sem.Wait()
      [System.Threading.Tasks.Task]::Run({
        try{
          $s = Get-EXOMailboxStatistics -Archive -Identity $using:u.'User Principal Name'
          if ($s.TotalItemSize -match '\(([^)]+) bytes\)'){ [int64]($matches[1] -replace ',','') } else { 0 }
        } catch { 0 } finally { $using:sem.Release() | Out-Null }
      })
    }
    [System.Threading.Tasks.Task]::WaitAll($tasks)
    $archBytes = ($tasks | % { $_.Result } | Measure-Object -Sum).Sum
    $exPrimaryBytes += $archBytes
  }

  if ($IncludeRecoverableItems){
    $allEx = $exActiveUsers + $exShared
    $sem2 = [System.Threading.SemaphoreSlim]::new($ThrottleLimit, $ThrottleLimit)
    $tasks2 = foreach($u in $allEx){
      $null = $sem2.Wait()
      [System.Threading.Tasks.Task]::Run({
        try{
          $total = 0L
          $stats = Get-MailboxFolderStatistics -Identity $using:u.'User Principal Name' -FolderScope RecoverableItems | 
                   Where-Object { $_.FolderPath -in '/Deletions','/Purges','/Versions','/DiscoveryHolds' }
          foreach($f in $stats){
            if ($f.FolderSize -match '\(([^)]+) bytes\)'){ $total += [int64]($matches[1] -replace ',','') }
          }
          $total
        } catch { 0L } finally { $using:sem2.Release() | Out-Null }
      })
    }
    [System.Threading.Tasks.Task]::WaitAll($tasks2)
    $rifBytes = ($tasks2 | % { $_.Result } | Measure-Object -Sum).Sum
    $exPrimaryBytes += $rifBytes
  }
  Disconnect-ExchangeOnline -Confirm:$false
}

# Annual growth per workload
$exGrowth = Annualize-Growth -csv (Get-GraphReportCsv -ReportName "getMailboxUsageStorage" -PeriodDays $Period) -field 'Storage Used (Byte)'
$odGrowth = Annualize-Growth -csv $odStorage -field 'Storage Used (Byte)'
$spGrowth = Annualize-Growth -csv $spStorage -field 'Storage Used (Byte)'

# Licensing
$skuSummary  = Get-SubscribedSkuSummary | Sort-Object SkuPartNumber
$licenseTable = $skuSummary | Select-Object @{n='SKU';e={Label-Sku $_.SkuPartNumber}}, Consumed, Enabled
$bucketCounts = [ordered]@{
  Office365E5=0; Office365E3=0; Microsoft365E5=0; Microsoft365E3=0;
  A5Faculty=0; A5Student=0; A3Faculty=0; A3Student=0; BusinessPremium=0; F3=0;
  AzureADP2=0; AzureADP1=0; EMSE3=0; DefenderO365P2=0
}
foreach($row in $skuSummary){
  foreach($b in $LicenseBuckets.Keys){
    if ($LicenseBuckets[$b] -contains $row.SkuPartNumber){
      $bucketCounts[$b] += [int]$row.Consumed
    }
  }
}

# Entra ID posture
$userCount           = Get-GraphEntityCount -Path "users"
$groupCount          = Get-GraphEntityCount -Path "groups"
$appRegCount         = Get-GraphEntityCount -Path "applications"
$spnCount            = Get-GraphEntityCount -Path "servicePrincipals"
$caPolicyCount       = Get-GraphEntityCount -Path "identity/conditionalAccess/policies"
$caNamedLocCount     = Get-GraphEntityCount -Path "identity/conditionalAccess/namedLocations"

# Compute GBs + MBS estimate
$exGB = To-GB $exPrimaryBytes
$odGB = To-GB $odBytes
$spGB = To-GB $spBytes
$totalGB = [math]::Round($exGB + $odGB + $spGB,2)

$dailyChangeGB = ($exGB * $ChangeRateExchange) + ($odGB * $ChangeRateOneDrive) + ($spGB * $ChangeRateSharePoint)
$monthChangeGB = [math]::Round($dailyChangeGB * 30,2)
$projGB = [math]::Round($totalGB * (1 + $AnnualGrowthPct),2)
$mbsEstimateGB = [math]::Round(($projGB * $RetentionMultiplier) + $monthChangeGB,2)

# ========== CSV #1 Summary ==========
$summary = [pscustomobject]@{
  ReportDate                  = (Get-Date).ToString("s")
  OrgName                     = $OrgName
  OrgId                       = $OrgId
  DefaultDomain               = $DefaultDomain
  GraphEnvironment            = $envName
  TenantCategory              = $TenantCategory

  UsersToProtect              = $UsersToProtect
  Exchange_SourceGB           = $exGB
  OneDrive_SourceGB           = $odGB
  SharePoint_SourceGB         = $spGB
  Total_SourceGB              = $totalGB

  Exchange_AnnualGrowthPct    = $exGrowth
  OneDrive_AnnualGrowthPct    = $odGrowth
  SharePoint_AnnualGrowthPct  = $spGrowth

  AnnualGrowthPct_Target      = $AnnualGrowthPct
  RetentionMultiplier         = $RetentionMultiplier
  MonthChangeGB               = $monthChangeGB
  MbsEstimateGB               = $mbsEstimateGB

  Lic_Office365E5             = $bucketCounts.Office365E5
  Lic_Office365E3             = $bucketCounts.Office365E3
  Lic_Microsoft365E5          = $bucketCounts.Microsoft365E5
  Lic_Microsoft365E3          = $bucketCounts.Microsoft365E3
  Lic_A5Faculty               = $bucketCounts.A5Faculty
  Lic_A5Student               = $bucketCounts.A5Student
  Lic_A3Faculty               = $bucketCounts.A3Faculty
  Lic_A3Student               = $bucketCounts.A3Student
  Lic_BusinessPremium         = $bucketCounts.BusinessPremium
  Lic_F3                      = $bucketCounts.F3
  Lic_AzureAD_P2              = $bucketCounts.AzureADP2
  Lic_AzureAD_P1              = $bucketCounts.AzureADP1
  Lic_EMS_E3                  = $bucketCounts.EMSE3
  Lic_DefenderO365_P2         = $bucketCounts.DefenderO365P2

  Dir_UserCount               = $userCount
  Dir_GroupCount              = $groupCount
  Dir_AppRegistrations        = $appRegCount
  Dir_ServicePrincipals       = $spnCount
  CA_PolicyCount              = $caPolicyCount
  CA_NamedLocations           = $caNamedLocCount

  IncludeArchiveGB            = (To-GB $archBytes)
  IncludeRecoverableGB        = (To-GB $rifBytes)
}
$summary | Export-Csv -NoTypeInformation -Path $outCsv

# ========== CSV #2 Workloads ==========
$wl = @()
$wl += [pscustomobject]@{
  Workload              = "Exchange"
  Objects               = $exActiveUsers.Count
  SharedMailboxes       = $exShared.Count
  SourceBytes           = [int64]$exPrimaryBytes
  SourceGB              = $exGB
  AnnualGrowthPct       = $exGrowth
  DailyChangeRate       = $ChangeRateExchange
  Included_ArchiveGB    = (To-GB $archBytes)
  Included_RIF_GB       = (To-GB $rifBytes)
}
$wl += [pscustomobject]@{
  Workload              = "OneDrive"
  Objects               = $odActive.Count
  SharedMailboxes       = $null
  SourceBytes           = [int64]$odBytes
  SourceGB              = $odGB
  AnnualGrowthPct       = $odGrowth
  DailyChangeRate       = $ChangeRateOneDrive
  Included_ArchiveGB    = 0
  Included_RIF_GB       = 0
}
$spFiles = ($spActive | Measure-Object -Property 'File Count' -Sum).Sum
$wl += [pscustomobject]@{
  Workload              = "SharePoint"
  Objects               = $spActive.Count      # Sites
  SharedMailboxes       = $spFiles             # Using this column to show total file count for SP sites
  SourceBytes           = [int64]$spBytes
  SourceGB              = $spGB
  AnnualGrowthPct       = $spGrowth
  DailyChangeRate       = $ChangeRateSharePoint
  Included_ArchiveGB    = 0
  Included_RIF_GB       = 0
}
$wl | Export-Csv -NoTypeInformation -Path $outWlCsv

# ========== CSV #3 Security & Licensing ==========
$sec = @()
foreach($row in $skuSummary){
  $sec += [pscustomobject]@{
    Section     = "Licenses"
    SKU         = Label-Sku $row.SkuPartNumber
    SkuPart     = $row.SkuPartNumber
    Assigned    = $row.Consumed
    Enabled     = $row.Enabled
  }
}
foreach($k in $bucketCounts.Keys){
  $sec += [pscustomobject]@{
    Section     = "LicenseBucket"
    Bucket      = $k
    Assigned    = $bucketCounts[$k]
  }
}
$sec += [pscustomobject]@{ Section="Directory";         Metric="Users";             Value=$userCount }
$sec += [pscustomobject]@{ Section="Directory";         Metric="Groups";            Value=$groupCount }
$sec += [pscustomobject]@{ Section="Directory";         Metric="AppRegistrations";  Value=$appRegCount }
$sec += [pscustomobject]@{ Section="Directory";         Metric="ServicePrincipals"; Value=$spnCount }
$sec += [pscustomobject]@{ Section="ConditionalAccess"; Metric="Policies";          Value=$caPolicyCount }
$sec += [pscustomobject]@{ Section="ConditionalAccess"; Metric="NamedLocations";    Value=$caNamedLocCount }
$sec | Export-Csv -NoTypeInformation -Path $outSecCsv

# Optional JSON bundle (nice for automation)
if ($ExportJson) {
  $bundle = [ordered]@{
    ReportDate = (Get-Date).ToString("s")
    Tenant = [ordered]@{
      OrgName = $OrgName; OrgId = $OrgId; DefaultDomain = $DefaultDomain
      GraphEnvironment = $envName; TenantCategory = $TenantCategory
    }
    Summary = $summary
    Workloads = $wl
    Security  = $sec
  }
  ($bundle | ConvertTo-Json -Depth 6) | Set-Content -Path $outJson -Encoding UTF8
}

# ========== HTML report ==========
$skuRows = ($licenseTable | ForEach-Object { "<tr><td>$($_.SKU)</td><td>$($_.Consumed)</td><td>$($_.Enabled)</td></tr>" }) -join "`n"
$html = @"
<!doctype html>
<html><head><meta charset="utf-8"><title>Veeam M365 Sizing ($stamp)</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:16px}
h1{margin:0 0 8px 0}
h2{margin:18px 0 6px 0}
table{border-collapse:collapse;width:100%;margin:12px 0}
th,td{border:1px solid #ddd;padding:8px;text-align:left}
thead{background:#f3f6f9}
.kpi{display:grid;grid-template-columns:repeat(4,minmax(220px,1fr));gap:12px}
.card{border:1px solid #e5eaf0;border-radius:12px;padding:12px}
.val{font-size:22px;font-weight:700}
.sub{color:#666}
.small{color:#444;font-size:12px}
</style></head>
<body>
<h1>Veeam Microsoft 365 Sizing</h1>

<div class="card">
  <div class="sub">Tenant</div>
  <div class="small">Org: <b>$OrgName</b> ($OrgId) • Default domain: <b>$DefaultDomain</b></div>
  <div class="small">Graph Environment: <b>$envName</b> • Tenant Category: <b>$TenantCategory</b></div>
</div>

<div class="kpi">
  <div class="card"><div class="sub">Users to protect</div><div class="val">$UsersToProtect</div></div>
  <div class="card"><div class="sub">Exchange source (GB)</div><div class="val">$exGB</div><div class="small">Growth (annualized): $exGrowth</div></div>
  <div class="card"><div class="sub">OneDrive source (GB)</div><div class="val">$odGB</div><div class="small">Growth (annualized): $odGrowth</div></div>
  <div class="card"><div class="sub">SharePoint source (GB)</div><div class="val">$spGB</div><div class="small">Growth (annualized): $spGrowth</div></div>
</div>

<div class="kpi">
  <div class="card"><div class="sub">Total dataset (GB)</div><div class="val">$totalGB</div></div>
  <div class="card"><div class="sub">Monthly change (GB)</div><div class="val">$monthChangeGB</div></div>
  <div class="card"><div class="sub">Retention multiplier</div><div class="val">$RetentionMultiplier</div></div>
  <div class="card"><div class="sub">Estimated MBS (GB)</div><div class="val">$mbsEstimateGB</div></div>
</div>

<h2>License inventory (subscribed SKUs)</h2>
<table><thead><tr><th>SKU</th><th>Assigned</th><th>Enabled</th></tr></thead><tbody>
$skuRows
</tbody></table>

<h2>Entra ID posture (signals for Entra ID backup)</h2>
<table>
  <thead><tr><th>Metric</th><th>Value</th></tr></thead>
  <tbody>
    <tr><td>Directory Users</td><td>$userCount</td></tr>
    <tr><td>Directory Groups</td><td>$groupCount</td></tr>
    <tr><td>App Registrations</td><td>$appRegCount</td></tr>
    <tr><td>Service Principals</td><td>$spnCount</td></tr>
    <tr><td>Conditional Access Policies</td><td>$caPolicyCount</td></tr>
    <tr><td>CA Named Locations</td><td>$caNamedLocCount</td></tr>
  </tbody>
</table>

<h2>Files generated</h2>
<ul>
  <li>Summary CSV: $outCsv</li>
  <li>Workloads CSV: $outWlCsv</li>
  <li>Security CSV: $outSecCsv</li>
  $(if ($ExportJson) {"<li>JSON bundle: $outJson</li>"})
</ul>

</body></html>
"@
$html | Set-Content -Path $outHtml -Encoding UTF8

Disconnect-MgGraph | Out-Null

Write-Host "`nSizing complete." -ForegroundColor Green
Write-Host "HTML     : $outHtml"
Write-Host "Summary  : $outCsv"
Write-Host "Workloads: $outWlCsv"
Write-Host "Security : $outSecCsv"
if ($ExportJson) { Write-Host "JSON     : $outJson" }
if ($EnableTelemetry) { "[$(Get-Date -Format s)] Completed run" | Add-Content $logPath }
