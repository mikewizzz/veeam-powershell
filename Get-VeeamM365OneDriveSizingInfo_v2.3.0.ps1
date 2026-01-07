#Requires -Modules Microsoft.Graph.Authentication,Microsoft.Graph.Users,Microsoft.Graph.Identity.DirectoryManagement

<#PSScriptInfo
.VERSION 2.3.2
.GUID 3c8f9c2a-0a2d-4f5a-8a52-8f7fd64d5ad1
.AUTHOR Veeam Field Architecture (Cloud + SaaS)
.COMPANYNAME Veeam Software
.TAGS M365 Sizing Discovery ReadOnly Veeam OneDrive EntraID ExchangeOnline MicrosoftGraph PnP
.EXTERNALMODULEDEPENDENCIES Microsoft.Graph.Authentication,Microsoft.Graph.Users,Microsoft.Graph.Identity.DirectoryManagement
.RELEASENOTES
2.3.2 - KISS + MS PowerShell best practices: #Requires modules, simplified license logic, Graph retry/backoff,
        - Consolidated disconnect patterns, improved parameter validation (ValidatePattern), cleaner error handling
2.3.1 - Fix Graph auth scope corruption (AADSTS70011) + avoid importing Microsoft.Graph meta-module (performance)
#>

<#
.SYNOPSIS
  Read-only M365 sizing tool for Veeam: OneDrive users + used size, license category, mailbox counts.

.DESCRIPTION
  Business outcomes (P0):
    - OneDrive users (count) and OneDrive used size (sum + per-user)
    - License type category (E3/E5/F-Series/Gov/Education/Other) per user
    - Mailbox counts (type breakdown)

  Data sources:
    - Microsoft Graph: tenant info, verified domains, subscribed SKUs, users + assignedLicenses
    - SharePoint Admin (PnP): OneDrive personal sites + StorageUsageCurrent (used size)
    - Exchange Online: mailbox counts

  Output contract (in a single run folder):
    - tenant.csv    (tenantId, domains, timestamp)
    - licenses.csv  (UPN, licenseCategory, skuParts)
    - onedrive.csv  (UPN, siteUrl, usedGB, usedMB, lastModified, licenseCategory, joinStatus)
    - mailboxes.csv (type, count)
    - summary.csv   (counts + totals + unknownJoinRate)
    - errors.json   (structured warnings/errors)

  Security posture:
    - Prefer certificate-based app-only auth (supported)
    - Never writes secrets to disk
    - No outbound calls to non-Microsoft endpoints

.RECOMMENDED RUN (interactive)
  ./Get-VeeamM365OneDriveSizingInfo.ps1

APP-ONLY RUN (enterprise)
  ./Get-VeeamM365OneDriveSizingInfo.ps1 -AppOnly -TenantId <tenant-guid> -ClientId <app-id> -CertThumbprint <thumb> `
    -ExchangeOrganization contoso.onmicrosoft.com

.NOTES
  - SharePointAdminUrl is auto-derived when possible. You can still override it explicitly.
  - Sovereign clouds (GCC/DoD) may require an explicit SharePointAdminUrl.
#>

[CmdletBinding(PositionalBinding=$false)]
param(
  [Parameter(Mandatory=$false)]
  [switch]$Version,

  [Parameter(Mandatory=$false)]
  [ValidateNotNullOrEmpty()]
  [string]$OutputPath = (Get-Location).Path,

  [Parameter(Mandatory=$false)]
  [switch]$NoZip,

  [Parameter(Mandatory=$false)]
  [bool]$KeepRawFiles = $true,

  # Optional override (auto-derived when not provided)
  [Parameter(Mandatory=$false)]
  [string]$SharePointAdminUrl,  # e.g. https://contoso-admin.sharepoint.com

  # Exchange app-only needs an organization value
  [Parameter(Mandatory=$false)]
  [string]$ExchangeOrganization, # e.g. contoso.onmicrosoft.com

  # Auth modes
  [Parameter(Mandatory=$false)]
  [switch]$DeviceCode,

  [Parameter(Mandatory=$false)]
  [switch]$AppOnly,

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$', ErrorMessage='Invalid GUID format for TenantId')]
  [string]$TenantId,

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$', ErrorMessage='Invalid GUID format for ClientId')]
  [string]$ClientId,

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^[a-fA-F0-9]{40}$', ErrorMessage='Invalid thumbprint format (must be 40 hex chars)')]
  [string]$CertThumbprint,

  # Toggles
  [Parameter(Mandatory=$false)][switch]$GraphOnly,       # skip PnP + EXO
  [Parameter(Mandatory=$false)][switch]$SkipSharePoint,  # skip OneDrive used size
  [Parameter(Mandatory=$false)][switch]$SkipExchange,    # skip mailbox counts

  # Optional license mapping override
  [Parameter(Mandatory=$false)]
  [ValidateScript({
    if ([string]::IsNullOrWhiteSpace($_)) { return $true }
    if (-not (Test-Path -LiteralPath $_)) { throw "LicenseMapPath not found: $_" }
    try { Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json -ErrorAction Stop | Out-Null; $true }
    catch { throw "LicenseMapPath is not valid JSON: $_" }
  })]
  [string]$LicenseMapPath        # JSON rules: [{ "Category":"E5","Patterns":["M365_E5","ENTERPRISEPREMIUM"] }, ...]
)

# -----------------------------
# Constants / fast exits
# -----------------------------
$ToolName    = 'Get-VeeamM365OneDriveSizingInfo.ps1'
$ToolVersion = '2.3.3'

# Module version requirements
$ModuleVersionRequirements = @{
  'Microsoft.Graph.Authentication'            = [version]'2.34.0'
  'Microsoft.Graph.Users'                     = [version]'2.34.0'
  'Microsoft.Graph.Identity.DirectoryManagement' = [version]'2.34.0'
  'PnP.PowerShell'                            = [version]'1.12.0'
  'ExchangeOnlineManagement'                  = [version]'3.0.0'
}

if ($Version) { Write-Output "$ToolName version $ToolVersion"; return }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Helper: Transient error detection for retry logic
function Is-TransientError([System.Management.Automation.ErrorRecord]$ErrorRecord) {
  $ex = $ErrorRecord.Exception
  if ($null -eq $ex) { return $false }
  
  # HTTP 429 (throttle), 503 (service unavailable), 504 (gateway timeout)
  if ($ex -match '429|503|504') { return $true }
  # Timeout exceptions
  if ($ex -is [System.TimeoutException]) { return $true }
  if ($ex.InnerException -is [System.TimeoutException]) { return $true }
  # Network connectivity
  if ($ex -is [System.Net.Http.HttpRequestException]) { return $true }
  if ($ex -match 'timeout|temporarily|unavailable') { return $true }
  return $false
}

# Helper: Retry with exponential backoff for transient failures
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [int]$MaxRetries = 3,
    [int]$InitialDelayMs = 1000,
    [string]$OperationName = 'Operation'
  )
  $retries = 0
  $lastError = $null
  
  do {
    try {
      return & $ScriptBlock
    } catch {
      $lastError = $_
      if ($retries -lt $MaxRetries -and (Is-TransientError $_)) {
        $retries++
        $delay = $InitialDelayMs * [math]::Pow(2, $retries - 1)
        Write-Verbose "$OperationName failed (attempt $retries/$MaxRetries). Retrying in ${delay}ms..."
        Start-Sleep -Milliseconds $delay
      } else {
        throw
      }
    }
  } while ($retries -lt $MaxRetries)
  
  throw $lastError
}

# -----------------------------
# Single logger + run context
# -----------------------------
function Ensure-Directory([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
}

function New-RunFolder([string]$Base) {
  $ts = (Get-Date).ToString('yyyyMMdd_HHmmss')
  $folder = Join-Path $Base "veeam_m365_sizing_$ts"
  Ensure-Directory $folder
  return [pscustomobject]@{
    Timestamp = $ts
    Folder    = $folder
    LogFile   = Join-Path $folder "run.jsonl"
    Errors    = New-Object System.Collections.Generic.List[object]
  }
}

function Log($Run, [string]$Level, [string]$Code, [string]$Message) {
  $e = [ordered]@{ ts=(Get-Date).ToString('o'); level=$Level; code=$Code; msg=$Message }
  Add-Content -LiteralPath $Run.LogFile -Value ($e | ConvertTo-Json -Compress)
  if ($Level -eq 'WARN') { Write-Warning $Message }
  elseif ($Level -eq 'ERROR') { Write-Error $Message -ErrorAction Continue }
  else { Write-Verbose $Message }
}

function AddErr($Run, [string]$Code, [string]$Message, [string]$Hint) {
  $Run.Errors.Add([pscustomobject]@{ ts=(Get-Date).ToString('o'); code=$Code; msg=$Message; hint=$Hint }) | Out-Null
  Log $Run 'WARN' $Code ($Message + " Hint: " + $Hint)
}

# -----------------------------
# Export helpers (CSV/JSON)
# -----------------------------
function Export-CsvContract {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Rows,
    [Parameter(Mandatory)][string[]]$Columns
  )
  $arr = @($Rows)
  if ($arr.Count -eq 0) {
    # deterministic empty file with headers
    ($Columns -join ',') | Out-File -LiteralPath $Path -Encoding UTF8
    return $false
  }
  $arr | Select-Object -Property $Columns | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
  return $true
}

function Export-JsonContract {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)]$Object,
    [int]$Depth = 10
  )
  $Object | ConvertTo-Json -Depth $Depth | Out-File -LiteralPath $Path -Encoding UTF8
}

function MBtoGiB([double]$MB) {
  if ($MB -eq $null) { return $null }
  return [math]::Round(($MB / 1024.0), 2)
}

# -----------------------------
# License rules (simple + configurable)
# -----------------------------
function Default-LicenseRules {
  @(
    @{ Category='Gov';       Patterns=@('GCC','GOV','DOD') },
    @{ Category='Education'; Patterns=@('EDU','STUDENT','FACULTY') },
    @{ Category='F-Series';  Patterns=@('(^|;)M365_F', '(^|;)F1($|;)', '(^|;)F3($|;)', '(^|;)F5($|;)', 'FRONTLINE') },
    @{ Category='E5';        Patterns=@('(^|;)M365_E5($|;)', '(^|;)ENTERPRISEPREMIUM($|;)', 'E5') },
    @{ Category='E3';        Patterns=@('(^|;)M365_E3($|;)', 'E3') }
  )
}

function Load-LicenseRules([string]$Path) {
  $defaultRules = @(
    @{ Category='Gov';       Pattern='(GCC|GOV|DOD)' },
    @{ Category='Education'; Pattern='(EDU|STUDENT|FACULTY)' },
    @{ Category='F-Series';  Pattern='(M365_F|F[135]|FRONTLINE)' },
    @{ Category='E5';        Pattern='(M365_E5|ENTERPRISEPREMIUM)' },
    @{ Category='E3';        Pattern='M365_E3' }
  )
  
  if (-not [string]::IsNullOrWhiteSpace($Path)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "LicenseMapPath not found: $Path" }
    try {
      $custom = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
      $customRules = @($custom | Where-Object { $_.Category -and $_.Pattern })
      if ($customRules.Count -gt 0) { return $customRules }
    } catch {
      Write-Warning "Failed to parse license rules from $Path; using defaults. $_"
    }
  }
  return $defaultRules
}

function Categorize-SkuParts([string[]]$SkuParts, $Rules) {
  if (-not $SkuParts -or $SkuParts.Count -eq 0) { return 'Unlicensed/Unknown' }
  $joined = (';' + (($SkuParts | Sort-Object -Unique) -join ';') + ';').ToUpperInvariant()
  foreach ($rule in $Rules) {
    if ($joined -match $rule.Pattern) { return $rule.Category }
  }
  return 'Other'
}

# -----------------------------
# Modules (IMPORTANT: do NOT Import-Module Microsoft.Graph meta-module)
# -----------------------------
function Assert-Modules($Run) {
  # Ensure required Graph submodules are available (do NOT import meta-module Microsoft.Graph)
  $graphModules = @(
    "Microsoft.Graph.Authentication",
    "Microsoft.Graph.Users",
    "Microsoft.Graph.Identity.DirectoryManagement"
  )

  foreach ($m in $graphModules) {
    if (-not (Get-Module -ListAvailable -Name $m)) {
      throw "Missing module $m. Install-Module $m or Install-Module Microsoft.Graph."
    }
    
    # Version check (MVP-level quality)
    $installed = Get-Module -ListAvailable -Name $m | Sort-Object -Property Version -Descending | Select-Object -First 1
    if ($ModuleVersionRequirements.ContainsKey($m)) {
      $required = $ModuleVersionRequirements[$m]
      if ($installed.Version -lt $required) {
        throw "Module $m version $($installed.Version) is too old. Minimum required: $required. Run: Update-Module $m"
      }
    }
    
    Import-Module $m -ErrorAction Stop | Out-Null
  }

  # Optional modules (best-effort import; failures logged as warnings)
  @(
    @{ Name='PnP.PowerShell'; Required=(-not $GraphOnly -and -not $SkipSharePoint); Code='PNP_MISSING'; Msg='OneDrive sizing unavailable.'; Hint='Install-Module PnP.PowerShell' },
    @{ Name='ExchangeOnlineManagement'; Required=(-not $GraphOnly -and -not $SkipExchange); Code='EXO_MISSING'; Msg='Mailbox counts unavailable.'; Hint='Install-Module ExchangeOnlineManagement' }
  ) | ForEach-Object {
    if ($_.Required) {
      try { 
        Import-Module $_.Name -ErrorAction Stop | Out-Null
        # Version check for optional modules
        if ($ModuleVersionRequirements.ContainsKey($_.Name)) {
          $installed = Get-Module -ListAvailable -Name $_.Name | Sort-Object -Property Version -Descending | Select-Object -First 1
          $required = $ModuleVersionRequirements[$_.Name]
          if ($installed.Version -lt $required) {
            AddErr $Run "$($_.Code)_VERSION" "Module $($_.Name) version is $($installed.Version); minimum: $required" "Run: Update-Module $($_.Name)"
          }
        }
      }
      catch { AddErr $Run $_.Code $_.Msg $_.Hint }
    }
  }
}

# -----------------------------
# Graph connect + guardrails (fixes AADSTS70011 scope corruption)
# -----------------------------
function Assert-ValidGraphScopes([string[]]$Scopes) {
  if (-not $Scopes -or $Scopes.Count -eq 0) { throw "Scopes cannot be empty for delegated auth." }
  foreach ($s in $Scopes) {
    if ($s -isnot [string]) { throw "Invalid scope value (non-string) detected: $($s | Out-String)" }
    if ($s.Trim() -match '^\@\{' ) { throw "Invalid scope value detected (looks like a PowerShell object/hashtable): $s" }
    if ($s -match '\s') { throw "Invalid scope '$s' (contains whitespace). Provide scopes as separate strings." }
  }
}

function Connect-VeeamGraph($Run) {
  Log $Run 'INFO' 'GRAPH_CONNECT' "Connecting to Microsoft Graph (AppOnly=$AppOnly, DeviceCode=$DeviceCode)..."
  try {
    if ($AppOnly) {
      if (-not $TenantId -or -not $ClientId -or -not $CertThumbprint) {
        throw "AppOnly requires -TenantId, -ClientId, -CertThumbprint."
      }
      Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertThumbprint -NoWelcome -ErrorAction Stop | Out-Null
    } else {
      # Delegated scopes as string[] (never concatenate; never include openid/profile/offline_access)
      $GraphScopes = @(
        'Organization.Read.All',
        'User.Read.All',
        'Directory.Read.All',
        'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementConfiguration.Read.All'
      )
      Assert-ValidGraphScopes -Scopes $GraphScopes

      if ($DeviceCode) {
        Connect-MgGraph -Scopes $GraphScopes -UseDeviceCode -NoWelcome -ErrorAction Stop | Out-Null
      } else {
        Connect-MgGraph -Scopes $GraphScopes -NoWelcome -ErrorAction Stop | Out-Null
      }
    }
  } catch {
    AddErr $Run 'GRAPH_CONNECT_FAILED' ("Graph connect failed. " + $_.Exception.Message) 'Verify Graph permissions/admin consent; verify app/cert config for app-only.'
    throw
  }

  $ctx = Get-MgContext
  Log $Run 'INFO' 'GRAPH_CONNECTED' ("Graph connected. TenantId=" + $ctx.TenantId + " AuthType=" + $ctx.AuthType)
}

function Get-TenantInfo {
  Invoke-WithRetry -ScriptBlock {
    $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
    $domains = @()
    $defaultDomain = $null
    foreach ($d in @($org.VerifiedDomains)) {
      $domains += [string]$d.Name
      if ($d.IsDefault) { $defaultDomain = [string]$d.Name }
    }
    [pscustomobject]@{
      TenantId          = [string]$org.Id
      TenantDisplayName = [string]$org.DisplayName
      DefaultDomain     = $defaultDomain
      VerifiedDomains   = ($domains | Sort-Object)
    }
  } -OperationName 'Retrieve tenant info'
}

function Get-SkuRows {
  Invoke-WithRetry -ScriptBlock {
    $skus = Get-MgSubscribedSku -All -ErrorAction Stop
    foreach ($s in @($skus)) {
      [pscustomobject]@{
        SkuId         = $s.SkuId.ToString()
        SkuPartNumber = [string]$s.SkuPartNumber
        EnabledUnits  = $s.PrepaidUnits.Enabled
        ConsumedUnits = $s.ConsumedUnits
      }
    }
  } -OperationName 'Enumerate SKUs'
}

function Get-UserRows($Run) {
  # Explicit pagination with progress reporting (safer for 500k+ user tenants)
  Log $Run 'INFO' 'GRAPH_USERS_ENUM' 'Enumerating users with explicit pagination...'
  
  $users = @()
  $pageNum = 0
  $pageSize = 100
  
  try {
    $allUsers = Invoke-WithRetry -ScriptBlock {
      Get-MgUser -Property "userPrincipalName,assignedLicenses" -PageSize $pageSize -All -ErrorAction Stop
    } -OperationName 'Enumerate users'
    
    foreach ($u in $allUsers) {
      $upn = [string]$u.UserPrincipalName
      $skuIds = @()
      foreach ($l in @($u.AssignedLicenses)) { if ($l.SkuId) { $skuIds += $l.SkuId.ToString() } }
      $skuIds = $skuIds | Sort-Object -Unique
      $users += [pscustomobject]@{
        UPN            = $upn
        AssignedSkuIds = ($skuIds -join ';')
      }
      
      if (++$pageNum % 500 -eq 0) {
        Write-Verbose "Processed $pageNum users..."
      }
    }
  } catch {
    AddErr $Run 'GRAPH_USERS_ENUM_FAILED' ("User enumeration failed: " + $_.Exception.Message) 'Verify Graph User.Read.All scope and tenant permissions.'
    throw
  }
  
  Log $Run 'INFO' 'GRAPH_USERS_ENUM_COMPLETE' "User enumeration complete: $(@($users).Count) users"
  return ,@($users)
}

function Build-SkuLookup($SkuRows) {
  $h = @{}
  foreach ($s in @($SkuRows)) {
    if (-not $h.ContainsKey($s.SkuId)) { $h[$s.SkuId] = $s.SkuPartNumber }
  }
  return $h
}

function Build-LicenseRowsAndIndex($UserRows, $SkuLookup, $Rules) {
  $idx = @{} # upn -> license row
  $userRowsArray = @($UserRows)
  
  $rows = foreach ($u in $userRowsArray) {
    $upnNorm = ([string]$u.UPN).Trim().ToLowerInvariant()
    $skuParts = @()
    foreach ($id in (($u.AssignedSkuIds -split ';') | Where-Object { $_ })) {
      if ($SkuLookup.ContainsKey($id)) { $skuParts += $SkuLookup[$id] }
    }
    $skuParts = $skuParts | Sort-Object -Unique
    $cat = Categorize-SkuParts -SkuParts $skuParts -Rules $Rules
    $row = [pscustomobject]@{
      UPN             = $upnNorm
      licenseCategory = $cat
      skuParts        = ($skuParts -join ';')
    }
    $idx[$upnNorm] = $row
    $row
  }
  return [pscustomobject]@{ Rows = @($rows); Index = $idx }
}

# -----------------------------
# SharePoint Admin URL auto-derivation
# -----------------------------
function Derive-SharePointAdminUrl($TenantInfo) {
  $onms = @($TenantInfo.VerifiedDomains | Where-Object {
    $_ -like '*.onmicrosoft.com' -and $_ -notlike '*.mail.onmicrosoft.com'
  })

  if ($onms.Count -gt 0) {
    $defaultOnms = $onms | Where-Object { $_ -eq $TenantInfo.DefaultDomain } | Select-Object -First 1
    $pick = if ($defaultOnms) { $defaultOnms } else { ($onms | Select-Object -First 1) }
    $tenantShort = ($pick -split '\.')[0]
    if (-not [string]::IsNullOrWhiteSpace($tenantShort)) {
      return ("https://{0}-admin.sharepoint.com" -f $tenantShort)
    }
  }
  return $null
}

# -----------------------------
# PnP OneDrive collection (deterministic join)
# -----------------------------
function Connect-PnP($Run, [string]$ResolvedSharePointAdminUrl) {
  if ($GraphOnly -or $SkipSharePoint) { return $false }
  if (-not (Get-Module -ListAvailable -Name PnP.PowerShell)) { return $false }

  if ([string]::IsNullOrWhiteSpace($ResolvedSharePointAdminUrl)) {
    AddErr $Run 'SPO_ADMINURL_UNRESOLVED' 'Could not resolve SharePoint Admin URL automatically.' 'Provide -SharePointAdminUrl explicitly (e.g., https://<tenant>-admin.sharepoint.com).'
    return $false
  }

  Log $Run 'INFO' 'SPO_CONNECT' ("Connecting to SharePoint Admin via PnP: " + $ResolvedSharePointAdminUrl)
  try {
    Invoke-WithRetry -ScriptBlock {
      if ($AppOnly) {
        Connect-PnPOnline -Url $ResolvedSharePointAdminUrl -ClientId $ClientId -Tenant $TenantId -Thumbprint $CertThumbprint -ErrorAction Stop
      } else {
        Connect-PnPOnline -Url $ResolvedSharePointAdminUrl -Interactive -ErrorAction Stop
      }
    } -OperationName 'Connect to SharePoint Admin' | Out-Null
    return $true
  } catch {
    AddErr $Run 'SPO_CONNECT_FAILED' ("SharePoint connect failed. " + $_.Exception.Message) 'Ensure SharePoint admin access (interactive) or correct app-only SPO permissions.'
    return $false
  }
}

function Normalize-Upn([string]$Upn) {
  if ([string]::IsNullOrWhiteSpace($Upn)) { return '' }
  return $Upn.Trim().ToLowerInvariant()
}

function Get-OneDriveRows($Run, $LicenseIndex) {
  Log $Run 'INFO' 'SPO_ENUM' 'Enumerating OneDrive personal sites (PnP)...'
  try {
    $sites = Invoke-WithRetry -ScriptBlock {
      Get-PnPTenantSite -Detailed -IncludeOneDriveSites -ErrorAction Stop
    } -OperationName 'Enumerate OneDrive sites'
  } catch {
    AddErr $Run 'SPO_ENUM_FAILED' ("Tenant site enumeration failed. " + $_.Exception.Message) 'If blocked, rerun with -SkipSharePoint or fix SharePoint admin permissions.'
    return @()
  }

  $od = @($sites | Where-Object {
    ($_.Template -eq 'SPSPERS') -or ($_.Url -match '-my\.sharepoint\.com/personal/')
  })

  Log $Run 'INFO' 'SPO_OD_COUNT' ("OneDrive personal sites found: " + $od.Count)

  $rows = foreach ($s in $od) {
    # Multi-strategy owner extraction (Owner field is primary)
    $ownerRaw = $null
    $ownerUpn = ''
    
    # Strategy 1: Try Owner property (PnP may populate this)
    if ($s.PSObject.Properties.Match('Owner').Count -gt 0 -and $s.Owner) {
      $ownerRaw = [string]$s.Owner
      if ($ownerRaw -match '@') {
        $ownerUpn = Normalize-Upn $ownerRaw
      }
    }
    
    # Strategy 2: Extract from URL path if no valid Owner (OneDrive URL: /personal/firstname.lastname@contoso.com)
    if (-not $ownerUpn -and $s.Url -match '/personal/(.+?)(?:[/_]|$)') {
      $urlPart = $matches[1]
      # URL decode the part (replace %40 with @, etc.)
      $decoded = [System.Web.HttpUtility]::UrlDecode($urlPart)
      if ($decoded -match '@') {
        $ownerUpn = Normalize-Upn $decoded
      }
    }

    $joinStatus = 'Unknown'
    $licCat = 'Unlicensed/Unknown'

    if ($ownerUpn -ne '') {
      if ($LicenseIndex.ContainsKey($ownerUpn)) {
        $licRow = $LicenseIndex[$ownerUpn]
        $licCat = $licRow.licenseCategory
        $joinStatus = 'Matched'
      } else {
        $joinStatus = 'NoMatch'  # Owner found but not in Graph users list
      }
    }

    $usedMB = [double]$s.StorageUsageCurrent
    $usedGB = MBtoGiB $usedMB

    [pscustomobject]@{
      UPN             = $ownerUpn
      siteUrl         = [string]$s.Url
      usedGB          = $usedGB
      usedMB          = [math]::Round($usedMB, 2)
      lastModified    = $s.LastContentModifiedDate
      licenseCategory = $licCat
      joinStatus      = $joinStatus
    }
  }

  return ,@($rows)
}

# -----------------------------
# Exchange mailbox counts (EXO) -> mailboxes.csv contract
# -----------------------------
function Connect-EXO($Run) {
  if ($GraphOnly -or $SkipExchange) { return $false }
  if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) { return $false }

  Log $Run 'INFO' 'EXO_CONNECT' 'Connecting to Exchange Online...'
  try {
    Invoke-WithRetry -ScriptBlock {
      if ($AppOnly) {
        if ([string]::IsNullOrWhiteSpace($ExchangeOrganization)) {
          throw 'App-only Exchange requires -ExchangeOrganization (e.g. contoso.onmicrosoft.com).'
        }
        Connect-ExchangeOnline -AppId $ClientId -CertificateThumbprint $CertThumbprint -Organization $ExchangeOrganization -ShowBanner:$false -ErrorAction Stop | Out-Null
      } else {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
      }
    } -OperationName 'Connect to Exchange Online' | Out-Null
    return $true
  } catch {
    if ($_.Exception.Message -match 'App-only Exchange requires') {
      AddErr $Run 'EXO_ORG_MISSING' $_.Exception.Message 'Provide -ExchangeOrganization or run interactive.'
      return $false
    }
    AddErr $Run 'EXO_CONNECT_FAILED' ("Exchange connect failed. " + $_.Exception.Message) 'If Exchange is blocked, rerun with -SkipExchange or fix permissions.'
    return $false
  }
}

function Get-MailboxRows($Run) {
  Log $Run 'INFO' 'EXO_ENUM' 'Enumerating mailboxes for counts (Get-EXOMailbox)...'
  try {
    $mbx = Invoke-WithRetry -ScriptBlock {
      Get-EXOMailbox -ResultSize Unlimited -PropertySets Minimum -ErrorAction Stop
    } -OperationName 'Enumerate mailboxes'
  } catch {
    AddErr $Run 'EXO_ENUM_FAILED' ("Mailbox enumeration failed. " + $_.Exception.Message) 'Grant View-Only Recipients (or equivalent) and retry.'
    return @()
  }

  $all = @($mbx).Count
  $user = @($mbx | Where-Object { $_.RecipientTypeDetails -eq 'UserMailbox' }).Count
  $shared = @($mbx | Where-Object { $_.RecipientTypeDetails -eq 'SharedMailbox' }).Count
  $room = @($mbx | Where-Object { $_.RecipientTypeDetails -eq 'RoomMailbox' }).Count
  $equip = @($mbx | Where-Object { $_.RecipientTypeDetails -eq 'EquipmentMailbox' }).Count
  $other = $all - ($user + $shared + $room + $equip)

  @(
    [pscustomobject]@{ type='TotalMailboxes';     count=$all },
    [pscustomobject]@{ type='UserMailbox';       count=$user },
    [pscustomobject]@{ type='SharedMailbox';     count=$shared },
    [pscustomobject]@{ type='RoomMailbox';       count=$room },
    [pscustomobject]@{ type='EquipmentMailbox';  count=$equip },
    [pscustomobject]@{ type='OtherMailbox';      count=$other }
  )
}

# -----------------------------
# Entra ID posture collection
# -----------------------------
function Get-GraphEntityCount($Run, [string]$Path) {
  try {
    Invoke-WithRetry -ScriptBlock {
      $result = Invoke-MgGraphRequest -Uri $Path -Method GET -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop
      if ($result.value) { 
        return @($result.value).Count 
      } elseif ($result.'@odata.count') { 
        return [int]$result.'@odata.count'
      }
      return 0
    } -OperationName "Graph posture query ($Path)"
  } catch {
    Log $Run 'WARN' 'GRAPH_POSTURE_QUERY' ("Graph posture query failed ($Path): " + $_.Exception.Message)
    return "unknown"
  }
}

function Get-EntradIdPostureMetrics($Run) {
  $posture = @{}
  
  # Directory Users (already have from Get-UserRows, but this is explicit count)
  $posture['Directory Users'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/users?$count=true'
  
  # Directory Groups
  $posture['Directory Groups'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/groups?$count=true'
  
  # App Registrations
  $posture['App Registrations'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/applications?$count=true'
  
  # Service Principals
  $posture['Service Principals'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/servicePrincipals?$count=true'
  
  # Conditional Access Policies
  $posture['Conditional Access Policies'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$count=true'
  
  # CA Named Locations
  $posture['CA Named Locations'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/namedLocations?$count=true'
  
  # Intune Managed Devices
  $posture['Intune Managed Devices'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?$count=true'
  
  # Intune Compliance Policies
  $posture['Intune Compliance Policies'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies?$count=true'
  
  # Intune Device Configurations
  $posture['Intune Device Configurations'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations?$count=true'
  
  # Intune Configuration Policies (newer endpoint)
  $posture['Intune Configuration Policies'] = Get-GraphEntityCount $Run 'https://graph.microsoft.com/beta/deviceManagement/configurationPolicies?$count=true'
  
  return $posture
}

# -----------------------------
# Summary.csv contract
# -----------------------------
function Build-HtmlReport($TenantInfo, $LicenseRows, $OneDriveRows, $MailboxRows, $SkuRows, $PostureMetrics, $Run, [string]$Timestamp) {
  $totalUsers = @($LicenseRows).Count
  $licensedUsers = @($LicenseRows | Where-Object { $_.licenseCategory -ne 'Unlicensed/Unknown' }).Count
  $unlicensedUsers = $totalUsers - $licensedUsers
  
  $licenseBreakdown = @($LicenseRows) | Group-Object -Property licenseCategory | 
    ForEach-Object { [pscustomobject]@{ Category = $_.Name; Count = $_.Count } } | 
    Sort-Object -Property Count -Descending
  
  $odCount = @($OneDriveRows).Count
  $odUsedGB = 0.0
  if ($odCount -gt 0) {
    $odMeasure = @($OneDriveRows) | Measure-Object -Property usedGB -Sum
    if ($odMeasure -and $odMeasure.PSObject.Properties.Match('Sum').Count -gt 0) {
      $odUsedGB = [double]($odMeasure.Sum)
    }
  }
  $odUsedGBRounded = [math]::Round($odUsedGB, 1)
  
  $mailTotal = 0
  $mailTotalRow = @($MailboxRows | Where-Object { $_.type -eq 'TotalMailboxes' } | Select-Object -First 1)
  if ($mailTotalRow.Count -gt 0) { $mailTotal = [int]$mailTotalRow[0].count }
  
  $skuCount = @($SkuRows).Count
  
  $licenseRows = ($licenseBreakdown | ConvertTo-Html -Fragment -As Table) -join "`n"
  $errorRows = if ($Run.Errors.Count -gt 0) {
    (@($Run.Errors) | ConvertTo-Html -Fragment -As Table) -join "`n"
  } else {
    '<p style="color:#28a745;"><strong>✓ No errors</strong></p>'
  }
  
  # Build Entra ID posture table
  $postureRows = @()
  if ($PostureMetrics -and $PostureMetrics.Count -gt 0) {
    $postureRows = $PostureMetrics.GetEnumerator() | ForEach-Object {
      [pscustomobject]@{ Metric = $_.Name; Value = $_.Value }
    }
  }
  $postureTable = if ($postureRows.Count -gt 0) {
    ($postureRows | ConvertTo-Html -Fragment -As Table) -join "`n"
  } else {
    '<p style="color:#999;">No Entra ID posture data collected.</p>'
  }
  
  $reportDate = (Get-Date).ToString('MMMM dd, yyyy HH:mm:ss')
  
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Microsoft 365 Sizing Assessment - Veeam Backup for Microsoft 365</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, Roboto, 'Helvetica Neue', Arial, sans-serif;
      background: #f3f2f1;
      color: #323130;
      line-height: 1.6;
    }
    .page-wrapper {
      max-width: 1400px;
      margin: 0 auto;
      background: white;
      box-shadow: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
    }
    
    /* Microsoft Professional Services Header */
    .ms-header {
      background: linear-gradient(135deg, #0078d4 0%, #106ebe 100%);
      padding: 48px 60px;
      position: relative;
      overflow: hidden;
    }
    .ms-header::after {
      content: '';
      position: absolute;
      top: -50%;
      right: -10%;
      width: 600px;
      height: 600px;
      background: rgba(255,255,255,0.08);
      border-radius: 50%;
    }
    .ms-header-content {
      position: relative;
      z-index: 1;
    }
    .ms-logo-area {
      display: flex;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 24px;
    }
    .ms-brand {
      display: flex;
      align-items: center;
      gap: 16px;
    }
    .ms-logo {
      width: 48px;
      height: 48px;
      background: white;
      border-radius: 4px;
      display: flex;
      align-items: center;
      justify-content: center;
      font-weight: 700;
      font-size: 20px;
      color: #0078d4;
      box-shadow: 0 2px 4px rgba(0,0,0,0.2);
    }
    .ms-division {
      color: white;
      font-size: 16px;
      font-weight: 300;
      letter-spacing: 0.5px;
    }
    .report-type {
      color: rgba(255,255,255,0.9);
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 1.5px;
      font-weight: 600;
    }
    .ms-header h1 {
      color: white;
      font-size: 36px;
      font-weight: 600;
      margin: 0 0 12px 0;
      letter-spacing: -0.5px;
    }
    .ms-header .subtitle {
      color: rgba(255,255,255,0.95);
      font-size: 18px;
      font-weight: 400;
      margin-bottom: 8px;
    }
    .ms-header .date {
      color: rgba(255,255,255,0.8);
      font-size: 14px;
      font-weight: 300;
    }
    
    /* Executive Summary Bar */
    .exec-summary {
      background: linear-gradient(to right, #005a9e 0%, #0078d4 100%);
      padding: 32px 60px;
      color: white;
    }
    .exec-summary h2 {
      font-size: 20px;
      font-weight: 600;
      margin-bottom: 16px;
      color: white;
    }
    
    /* Tenant Information */
    .tenant-info {
      background: #faf9f8;
      padding: 32px 60px;
      border-bottom: 1px solid #edebe9;
    }
    .tenant-info h3 {
      font-size: 16px;
      font-weight: 600;
      color: #323130;
      margin-bottom: 20px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .info-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
      gap: 16px;
    }
    .info-item {
      display: flex;
      padding: 12px 0;
    }
    .info-label {
      font-weight: 600;
      color: #605e5c;
      min-width: 140px;
      font-size: 14px;
    }
    .info-value {
      color: #323130;
      font-size: 14px;
      flex: 1;
    }
    
    /* KPI Dashboard */
    .kpi-dashboard {
      padding: 48px 60px;
      background: white;
    }
    .kpi-dashboard h2 {
      font-size: 24px;
      font-weight: 600;
      color: #323130;
      margin-bottom: 32px;
      padding-bottom: 12px;
      border-bottom: 3px solid #0078d4;
    }
    .kpi-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 24px;
    }
    .kpi-card {
      background: white;
      border: 1px solid #edebe9;
      border-radius: 4px;
      padding: 24px;
      position: relative;
      transition: all 0.3s cubic-bezier(0.4, 0, 0.2, 1);
      box-shadow: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
    }
    .kpi-card:hover {
      transform: translateY(-4px);
      box-shadow: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
      border-color: #0078d4;
    }
    .kpi-card::before {
      content: '';
      position: absolute;
      top: 0;
      left: 0;
      right: 0;
      height: 4px;
      background: linear-gradient(to right, #0078d4, #106ebe);
      border-radius: 4px 4px 0 0;
    }
    .kpi-label {
      font-size: 13px;
      color: #605e5c;
      text-transform: uppercase;
      letter-spacing: 0.8px;
      font-weight: 600;
      margin-bottom: 12px;
    }
    .kpi-value {
      font-size: 42px;
      font-weight: 600;
      color: #0078d4;
      line-height: 1;
      margin-bottom: 8px;
    }
    .kpi-subtext {
      font-size: 13px;
      color: #8a8886;
      font-weight: 400;
    }
    
    /* Section Styling */
    .section {
      padding: 48px 60px;
      border-top: 1px solid #edebe9;
    }
    .section h2 {
      font-size: 22px;
      font-weight: 600;
      color: #323130;
      margin-bottom: 24px;
      padding-bottom: 12px;
      border-bottom: 2px solid #0078d4;
    }
    .section-description {
      color: #605e5c;
      font-size: 14px;
      margin-bottom: 24px;
      line-height: 1.6;
    }
    
    /* Professional Table Styling */
    table {
      width: 100%;
      border-collapse: separate;
      border-spacing: 0;
      font-size: 14px;
      background: white;
      border: 1px solid #edebe9;
      border-radius: 4px;
      overflow: hidden;
    }
    th {
      background: #f3f2f1;
      padding: 16px;
      text-align: left;
      font-weight: 600;
      color: #323130;
      border-bottom: 2px solid #0078d4;
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    td {
      padding: 16px;
      border-bottom: 1px solid #edebe9;
      color: #323130;
    }
    tr:last-child td {
      border-bottom: none;
    }
    tbody tr {
      transition: background-color 0.2s;
    }
    tbody tr:hover {
      background-color: #f8f9fa;
    }
    
    /* Status Indicators */
    .status-success {
      background: #dff6dd;
      border-left: 4px solid #107c10;
      padding: 20px;
      border-radius: 4px;
      margin: 20px 0;
    }
    .status-success strong {
      color: #107c10;
      font-weight: 600;
    }
    .status-warning {
      background: #fff4ce;
      border-left: 4px solid #fce100;
      padding: 20px;
      border-radius: 4px;
      margin: 20px 0;
    }
    .status-warning strong {
      color: #8a8886;
      font-weight: 600;
    }
    
    /* Footer */
    .ms-footer {
      background: #f3f2f1;
      padding: 40px 60px;
      border-top: 1px solid #edebe9;
    }
    .footer-content {
      display: grid;
      grid-template-columns: 2fr 1fr;
      gap: 40px;
      margin-bottom: 24px;
    }
    .footer-section h4 {
      font-size: 14px;
      font-weight: 600;
      color: #323130;
      margin-bottom: 12px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
    }
    .footer-section p {
      font-size: 13px;
      color: #605e5c;
      line-height: 1.6;
      margin: 8px 0;
    }
    .footer-divider {
      height: 1px;
      background: #edebe9;
      margin: 24px 0;
    }
    .footer-legal {
      font-size: 12px;
      color: #8a8886;
      text-align: center;
    }
    
    /* Print Styles */
    @media print {
      body { background: white; }
      .page-wrapper { box-shadow: none; }
      .kpi-card { page-break-inside: avoid; }
      .section { page-break-inside: avoid; }
    }
  </style>
</head>
<body>
  <div class="page-wrapper">
    <!-- Microsoft Professional Services Header -->
    <div class="ms-header">
      <div class="ms-header-content">
        <div class="ms-logo-area">
          <div class="ms-brand">
            <div class="ms-logo">M</div>
            <div class="ms-division">Microsoft 365</div>
          </div>
          <div class="report-type">Assessment Report</div>
        </div>
        <h1>Veeam Backup for Microsoft 365</h1>
        <div class="subtitle">Sizing Assessment & Infrastructure Planning</div>
        <div class="date">Generated: $reportDate</div>
      </div>
    </div>
    
    <div class="exec-summary">
      <h2>Executive Summary</h2>
      <p style="font-size: 15px; line-height: 1.8;">This comprehensive assessment provides detailed insights into your Microsoft 365 environment to support accurate sizing and deployment planning for Veeam Backup for Microsoft 365. The analysis includes user licensing distribution, OneDrive utilization, Exchange mailbox inventory, and Entra ID security posture metrics.</p>
    </div>
    
    <div class="tenant-info">
      <h3>Environment Details</h3>
      <div class="info-grid">
        <div class="info-item">
          <span class="info-label">Organization:</span>
          <span class="info-value">$($TenantInfo.TenantDisplayName)</span>
        </div>
        <div class="info-item">
          <span class="info-label">Tenant ID:</span>
          <span class="info-value">$($TenantInfo.TenantId)</span>
        </div>
        <div class="info-item">
          <span class="info-label">Verified Domains:</span>
          <span class="info-value">$($TenantInfo.VerifiedDomains -join ', ')</span>
        </div>
      </div>
    </div>
    
    <div class="kpi-dashboard">
      <h2>Infrastructure Metrics</h2>
      <div class="kpi-grid">
        <div class="kpi-card">
          <div class="kpi-label">Total Users</div>
          <div class="kpi-value">$totalUsers</div>
          <div class="kpi-subtext">Active directory accounts</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Licensed Users</div>
          <div class="kpi-value">$licensedUsers</div>
          <div class="kpi-subtext">$unlicensedUsers without licenses</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">OneDrive Sites</div>
          <div class="kpi-value">$odCount</div>
          <div class="kpi-subtext">Personal storage locations</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Storage Used</div>
          <div class="kpi-value">$odUsedGBRounded</div>
          <div class="kpi-subtext">GB across OneDrive</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">Mailboxes</div>
          <div class="kpi-value">$mailTotal</div>
          <div class="kpi-subtext">Exchange Online mailboxes</div>
        </div>
        <div class="kpi-card">
          <div class="kpi-label">License SKUs</div>
          <div class="kpi-value">$skuCount</div>
          <div class="kpi-subtext">Unique subscription types</div>
        </div>
      </div>
    </div>
    
    <div class="section">
      <h2>License Distribution Analysis</h2>
      <p class="section-description">Breakdown of Microsoft 365 licenses by category, providing insights into licensing structure and potential backup requirements across different user tiers.</p>
      $licenseRows
    </div>
    
    <div class="section">
      <h2>Entra ID Security Posture</h2>
      <p class="section-description">Identity and device management metrics indicating the scope of Entra ID objects that may require backup protection. These signals help assess the security and compliance requirements for identity configuration backups.</p>
      $postureTable
    </div>
    
    <div class="section">
      <h2>Data Collection Status</h2>
      $(if ($Run.Errors.Count -gt 0) {
        "<div class='status-warning'><strong>⚠ Assessment Completed with Warnings ($($Run.Errors.Count))</strong><br><br>"
        $errorRows
        "</div>"
      } else {
        "<div class='status-success'><strong>✓ Assessment Completed Successfully</strong><br><br>All data collection operations completed without errors. The environment scan captured complete telemetry across Microsoft Graph API, SharePoint Online, and Exchange Online endpoints.</div>"
      })
    </div>
    
    <div class="ms-footer">
      <div class="footer-content">
        <div class="footer-section">
          <h4>About This Assessment</h4>
          <p>This report was generated using automated discovery tools to analyze your Microsoft 365 environment. The data collected is read-only and does not modify any tenant configuration.</p>
          <p><strong>Tool Version:</strong> Get-VeeamM365OneDriveSizingInfo v2.3.3</p>
          <p><strong>Report Generated:</strong> $reportDate</p>
        </div>
        <div class="footer-section">
          <h4>Next Steps</h4>
          <p>• Review sizing recommendations</p>
          <p>• Validate backup scope requirements</p>
          <p>• Plan infrastructure deployment</p>
          <p>• Schedule implementation review</p>
        </div>
      </div>
      <div class="footer-divider"></div>
      <div class="footer-legal">
        <p>© 2025 Veeam Software. This report contains confidential information. Microsoft 365 and related trademarks are property of Microsoft Corporation.</p>
        <p>For questions or support, contact your Veeam Account Team or Microsoft Professional Services.</p>
      </div>
    </div>
  </div>
</body>
</html>
"@
  
  return $html
}

function Build-SummaryRows($TenantInfo, $LicenseRows, $OneDriveRows, $MailboxRows, [string]$Timestamp) {
  $summary = New-Object System.Collections.Generic.List[object]

  $totalUsers = @($LicenseRows).Count
  $licensedKnown = @($LicenseRows | Where-Object { $_.licenseCategory -ne 'Unlicensed/Unknown' }).Count

  $odCount = @($OneDriveRows).Count
  $odUsedGBTotal = 0.0
  $odMeasure = @($OneDriveRows) | Measure-Object -Property usedGB -Sum
  if ($odMeasure -and $odMeasure.PSObject.Properties.Match('Sum').Count -gt 0 -and $null -ne $odMeasure.Sum) {
    $odUsedGBTotal = [double]$odMeasure.Sum
  }
  $odUnknown = @($OneDriveRows | Where-Object { $_.joinStatus -eq 'Unknown' }).Count
  $odNoMatch  = @($OneDriveRows | Where-Object { $_.joinStatus -eq 'NoMatch' }).Count
  $odMatched  = @($OneDriveRows | Where-Object { $_.joinStatus -eq 'Matched' }).Count
  $unknownRate = if ($odCount -gt 0) { [math]::Round(($odUnknown / [double]$odCount), 4) } else { 0 }

  $mailTotal = 0
  $mailTotalRow = @($MailboxRows | Where-Object { $_.type -eq 'TotalMailboxes' } | Select-Object -First 1)
  if ($mailTotalRow.Count -gt 0) { $mailTotal = [int]$mailTotalRow[0].count }

  $summary.Add([pscustomobject]@{ key='timestamp'; value=$Timestamp }) | Out-Null
  $summary.Add([pscustomobject]@{ key='tenantId'; value=$TenantInfo.TenantId }) | Out-Null
  $summary.Add([pscustomobject]@{ key='domains'; value=($TenantInfo.VerifiedDomains -join ';') }) | Out-Null

  $summary.Add([pscustomobject]@{ key='totalUsers'; value=$totalUsers }) | Out-Null
  $summary.Add([pscustomobject]@{ key='licensedUsersKnownCategory'; value=$licensedKnown }) | Out-Null

  $summary.Add([pscustomobject]@{ key='oneDriveSites'; value=$odCount }) | Out-Null
  $summary.Add([pscustomobject]@{ key='oneDriveUsedGBTotal'; value=[math]::Round($odUsedGBTotal, 2) }) | Out-Null
  $summary.Add([pscustomobject]@{ key='oneDriveJoinMatched'; value=$odMatched }) | Out-Null
  $summary.Add([pscustomobject]@{ key='oneDriveJoinNoMatch'; value=$odNoMatch }) | Out-Null
  $summary.Add([pscustomobject]@{ key='oneDriveJoinUnknown'; value=$odUnknown }) | Out-Null
  $summary.Add([pscustomobject]@{ key='oneDriveUnknownJoinRate'; value=$unknownRate }) | Out-Null

  $summary.Add([pscustomobject]@{ key='mailboxesTotal'; value=$mailTotal }) | Out-Null

  return $summary.ToArray()
}

# -----------------------------
# Main
# -----------------------------
$Run = $null
$perfMetrics = @{}
try {
  Ensure-Directory $OutputPath
  $Run = New-RunFolder $OutputPath
  Log $Run 'INFO' 'RUN_START' "Starting $ToolName v$ToolVersion. Output=$($Run.Folder)"

  $swOverall = [System.Diagnostics.Stopwatch]::StartNew()

  Assert-Modules $Run
  $rules = Load-LicenseRules -Path $LicenseMapPath
  Log $Run 'INFO' 'LIC_RULES' ("License rules loaded: " + $rules.Count)

  # Graph is required
  $swGraph = [System.Diagnostics.Stopwatch]::StartNew()
  Connect-VeeamGraph $Run
  $swGraph.Stop()
  $perfMetrics['Graph_Connect'] = $swGraph.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_GRAPH_CONNECT' "Graph connection completed in $($swGraph.ElapsedMilliseconds)ms"

  $swTenant = [System.Diagnostics.Stopwatch]::StartNew()
  $tenantInfo = Get-TenantInfo
  $swTenant.Stop()
  $perfMetrics['Tenant_Info'] = $swTenant.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_TENANT_INFO' "Tenant info retrieval completed in $($swTenant.ElapsedMilliseconds)ms"

  $swSkus = [System.Diagnostics.Stopwatch]::StartNew()
  $skuRows = Get-SkuRows
  $skuLookup = Build-SkuLookup $skuRows
  $swSkus.Stop()
  $perfMetrics['SKU_Enum'] = $swSkus.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_SKU_ENUM' "SKU enumeration completed in $($swSkus.ElapsedMilliseconds)ms"

  $swUsers = [System.Diagnostics.Stopwatch]::StartNew()
  $userRows = Get-UserRows $Run
  $swUsers.Stop()
  $perfMetrics['User_Enum'] = $swUsers.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_USER_ENUM' "User enumeration completed in $($swUsers.ElapsedMilliseconds)ms"
  Log $Run 'INFO' 'GRAPH_COUNTS' ("Users=" + @($userRows).Count + " SKUs=" + @($skuRows).Count)

  # Collect Entra ID posture metrics
  $swPosture = [System.Diagnostics.Stopwatch]::StartNew()
  $postureMetrics = Get-EntradIdPostureMetrics $Run
  $swPosture.Stop()
  $perfMetrics['Posture_Metrics'] = $swPosture.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_POSTURE' "Entra ID posture metrics collected in $($swPosture.ElapsedMilliseconds)ms"
  Log $Run 'INFO' 'POSTURE_COLLECTED' "Entra ID posture metrics collected."

  $lic = Build-LicenseRowsAndIndex -UserRows $userRows -SkuLookup $skuLookup -Rules $rules
  $licenseRows = $lic.Rows
  $licenseIndex = $lic.Index

  # Resolve SPO admin URL (override wins)
  $resolvedSpoAdminUrl = $null
  if (-not [string]::IsNullOrWhiteSpace($SharePointAdminUrl)) {
    $resolvedSpoAdminUrl = $SharePointAdminUrl
    Log $Run 'INFO' 'SPO_ADMINURL_OVERRIDE' ("Using provided SharePointAdminUrl: " + $resolvedSpoAdminUrl)
  } else {
    $resolvedSpoAdminUrl = Derive-SharePointAdminUrl -TenantInfo $tenantInfo
    if ($resolvedSpoAdminUrl) {
      Log $Run 'INFO' 'SPO_ADMINURL_DERIVED' ("Derived SharePointAdminUrl: " + $resolvedSpoAdminUrl)
    } else {
      AddErr $Run 'SPO_ADMINURL_DERIVE_FAILED' 'Failed to derive SharePointAdminUrl from verified domains.' 'Provide -SharePointAdminUrl explicitly (e.g., https://<tenant>-admin.sharepoint.com).'
    }
  }

  # OneDrive sizing (PnP)
  $oneDriveRows = @()
  if (-not $GraphOnly -and -not $SkipSharePoint) {
    $swOneDrive = [System.Diagnostics.Stopwatch]::StartNew()
    $spoOk = Connect-PnP -Run $Run -ResolvedSharePointAdminUrl $resolvedSpoAdminUrl
    if ($spoOk) { $oneDriveRows = Get-OneDriveRows -Run $Run -LicenseIndex $licenseIndex }
    else { Log $Run 'WARN' 'SPO_NOT_AVAILABLE' 'OneDrive used size not collected (PnP unavailable, skipped, or URL unresolved).' }
    $swOneDrive.Stop()
    $perfMetrics['OneDrive_Enum'] = $swOneDrive.ElapsedMilliseconds
    Log $Run 'INFO' 'PERF_ONEDRIVE' "OneDrive enumeration completed in $($swOneDrive.ElapsedMilliseconds)ms"
  }

  # Exchange mailbox counts
  $mailboxRows = @()
  if (-not $GraphOnly -and -not $SkipExchange) {
    $swExchange = [System.Diagnostics.Stopwatch]::StartNew()
    $exoOk = Connect-EXO $Run
    if ($exoOk) { $mailboxRows = Get-MailboxRows -Run $Run }
    else { Log $Run 'WARN' 'EXO_NOT_AVAILABLE' 'Mailbox counts not collected (EXO unavailable or skipped).' }
    $swExchange.Stop()
    $perfMetrics['Exchange_Enum'] = $swExchange.ElapsedMilliseconds
    Log $Run 'INFO' 'PERF_EXCHANGE' "Exchange enumeration completed in $($swExchange.ElapsedMilliseconds)ms"
  }

  # Build output contracts
  $tenantCsv   = Join-Path $Run.Folder "tenant.csv"
  $licensesCsv = Join-Path $Run.Folder "licenses.csv"
  $onedriveCsv = Join-Path $Run.Folder "onedrive.csv"
  $mailboxesCsv= Join-Path $Run.Folder "mailboxes.csv"
  $summaryCsv  = Join-Path $Run.Folder "summary.csv"
  $errorsJson  = Join-Path $Run.Folder "errors.json"
  $skuMapCsv   = Join-Path $Run.Folder "sku_map.csv" # useful but not part of the minimal contract

  # tenant.csv contract
  $tenantRow = [pscustomobject]@{
    tenantId   = $tenantInfo.TenantId
    domains    = ($tenantInfo.VerifiedDomains -join ';')
    timestamp  = $Run.Timestamp
  }
  Export-CsvContract -Path $tenantCsv -Rows @($tenantRow) -Columns @('tenantId','domains','timestamp') | Out-Null

  # licenses.csv contract
  Export-CsvContract -Path $licensesCsv -Rows $licenseRows -Columns @('UPN','licenseCategory','skuParts') | Out-Null

  # onedrive.csv contract
  Export-CsvContract -Path $onedriveCsv -Rows $oneDriveRows -Columns @('UPN','siteUrl','usedGB','usedMB','lastModified','licenseCategory','joinStatus') | Out-Null

  # mailboxes.csv contract
  Export-CsvContract -Path $mailboxesCsv -Rows $mailboxRows -Columns @('type','count') | Out-Null

  # summary.csv contract
  $summaryRows = Build-SummaryRows -TenantInfo $tenantInfo -LicenseRows $licenseRows -OneDriveRows $oneDriveRows -MailboxRows $mailboxRows -Timestamp $Run.Timestamp
  Export-CsvContract -Path $summaryCsv -Rows $summaryRows -Columns @('key','value') | Out-Null

  # HTML report (executive summary)
  $htmlReport = Build-HtmlReport -TenantInfo $tenantInfo -LicenseRows $licenseRows -OneDriveRows $oneDriveRows -MailboxRows $mailboxRows -SkuRows $skuRows -PostureMetrics $postureMetrics -Run $Run -Timestamp $Run.Timestamp
  $htmlPath = Join-Path $Run.Folder 'report.html'
  $htmlReport | Out-File -FilePath $htmlPath -Encoding UTF8
  Write-Verbose "HTML report generated: $htmlPath"

  # errors.json contract
  Export-JsonContract -Path $errorsJson -Object $Run.Errors -Depth 10

  # extra: sku map (helps troubleshooting license mapping)
  Export-CsvContract -Path $skuMapCsv -Rows $skuRows -Columns @('SkuId','SkuPartNumber','EnabledUnits','ConsumedUnits') | Out-Null

  # Zip bundle
  $zipPath = Join-Path $OutputPath "veeam_m365_sizing_results_$($Run.Timestamp).zip"
  if (-not $NoZip) {
    $files = Get-ChildItem -LiteralPath $Run.Folder -File | Select-Object -ExpandProperty FullName
    if ($files.Count -gt 0) {
      if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
      Compress-Archive -LiteralPath $files -DestinationPath $zipPath -CompressionLevel Optimal
      Write-Host "Zip created: $zipPath"
    }
    if (-not $KeepRawFiles) {
      Remove-Item -LiteralPath $Run.Folder -Recurse -Force
      Write-Host "Raw output folder removed (KeepRawFiles=false)."
    }
  } else {
    Write-Host "NoZip=true; outputs in: $($Run.Folder)"
  }

  Write-Host "Outputs (contract):"
  Write-Host " - $tenantCsv"
  Write-Host " - $licensesCsv"
  Write-Host " - $onedriveCsv"
  Write-Host " - $mailboxesCsv"
  Write-Host " - $summaryCsv"
  Write-Host " - $errorsJson"
  Write-Host " - $htmlPath (executive summary report)"

  $swOverall.Stop()
  $perfMetrics['Total'] = $swOverall.ElapsedMilliseconds
  Log $Run 'INFO' 'PERF_TOTAL' "Total runtime: $($swOverall.ElapsedMilliseconds)ms"
  
  # Log performance summary
  Write-Verbose "=== Performance Summary ==="
  $perfMetrics.GetEnumerator() | Sort-Object -Property Value -Descending | ForEach-Object {
    Write-Verbose "$($_.Name): $($_.Value)ms"
  }
  Write-Verbose "==========================="

  Log $Run 'INFO' 'RUN_END' 'Run finished.'
}
catch {
  if ($Run) { Log $Run 'ERROR' 'RUN_FATAL' ("Fatal error: " + $_.Exception.Message) }
  throw
}
finally {
  # Clean disconnect from all services (best-effort; ignore errors)
  @(
    @{ Service='MgGraph'; Action={ Disconnect-MgGraph -ErrorAction SilentlyContinue } },
    @{ Service='EXO'; Action={ Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } },
    @{ Service='PnP'; Action={ Disconnect-PnPOnline -ErrorAction SilentlyContinue } }
  ) | ForEach-Object {
    try { & $_.Action | Out-Null } catch { <# silently ignore any disconnect failures #> }
  }
}
