<#
.SYNOPSIS
  VB365-Sizing — Microsoft 365 backup sizing tool for Veeam Backup for Microsoft 365.

.DESCRIPTION
  Connects to Microsoft Graph API to collect Exchange Online, OneDrive for Business,
  and SharePoint Online usage data. Calculates dataset totals and growth rates
  for Veeam Backup for Microsoft 365.

  Outputs a professional HTML report with SVG charts, per-workload CSV breakdown,
  and a single-row summary CSV. Designed for presales sizing during M365 discovery.

  This is a community-maintained open-source tool and is NOT created by Veeam R&D
  or validated by Veeam Q&A. Veeam Support does not provide technical support.

.PARAMETER UseAppAccess
  Use application (app-only) authentication instead of delegated interactive login.

.PARAMETER TenantId
  Azure AD / Entra ID tenant ID. Required for app-only authentication.

.PARAMETER ClientId
  Application (client) ID from Entra ID app registration. Required for app-only and device code auth.

.PARAMETER CertificateThumbprint
  Certificate thumbprint for app-only authentication. Requires -UseAppAccess and -ClientId.

.PARAMETER UseDeviceCode
  Use device code flow for environments without a browser (e.g., SSH sessions, servers).

.PARAMETER ADGroup
  Include only members of this Entra ID group (by DisplayName) for Exchange and OneDrive sizing.
  SharePoint is always tenant-wide (Graph API limitation).

.PARAMETER ExcludeADGroup
  Exclude members of this Entra ID group from Exchange and OneDrive sizing.

.PARAMETER Period
  Usage report period in days. Valid values: 7, 30, 90, 180. Default: 90.

.PARAMETER OutFolder
  Output directory for generated reports and CSVs. Default: .\VB365SizingOutput.

.PARAMETER SkipModuleInstall
  Skip automatic installation of missing Graph modules. Errors if modules are not present.

.PARAMETER SkipHtmlReport
  Skip HTML report generation. Produces CSV exports only.

.EXAMPLE
  .\vb365-sizing.ps1
  Interactive login with default parameters.

.EXAMPLE
  .\vb365-sizing.ps1 -UseAppAccess -TenantId "contoso.onmicrosoft.com" -ClientId "abc123" -CertificateThumbprint "AABB..."
  App-only authentication with certificate.

.EXAMPLE
  .\vb365-sizing.ps1 -UseDeviceCode
  Device code flow for browser-less environments.

.EXAMPLE
  .\vb365-sizing.ps1 -ADGroup "Sales Department" -Period 180
  Scope sizing to a specific group with 180-day usage data.

.NOTES
  Version:        1.0.0
  License:        MIT
  Repository:     https://github.com/VeeamHub/powershell
  Prerequisites:  PowerShell 5.1+, Microsoft Graph modules (auto-installed)
  Permissions:    Reports.Read.All, Directory.Read.All, User.Read.All, Organization.Read.All
#>

#Requires -Version 5.1

# Suppress PSScriptAnalyzer rules that are false positives for single-file scripts:
# - Write-Host is intentional for CLI progress output in a sizing tool
# - Parameters are consumed by nested functions via script scope (PSScriptAnalyzer can't trace this)
# - Internal helper functions (To-GB, Escape-Html, etc.) don't need approved verbs
# - Plural nouns are appropriate for collection-returning functions
# - Write-Log is a custom function, not overwriting a built-in cmdlet
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseApprovedVerbs', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '')]
[CmdletBinding()]
param(
    # Authentication
    [switch]$UseAppAccess,
    [string]$TenantId,
    [string]$ClientId,
    [string]$CertificateThumbprint,
    [switch]$UseDeviceCode,

    # Scope
    [string]$ADGroup,
    [string]$ExcludeADGroup,
    [ValidateSet(7,30,90,180)][int]$Period = 90,

    # Output
    [string]$OutFolder = ".\VB365SizingOutput",
    [switch]$SkipModuleInstall,
    [switch]$SkipHtmlReport
)

# =========================================================================
# Section 3: Constants & Helpers
# =========================================================================

$ErrorActionPreference = "Stop"
$ProgressPreference    = 'SilentlyContinue'

# Unit constants
$script:GB  = [double]1e9
$script:TB  = [double]1e12
$script:GiB = [double](1024*1024*1024)
$script:TiB = [double](1024*1024*1024*1024)

function To-GB([double]$bytes)  { [math]::Round($bytes / $script:GB, 2) }
function To-TB([double]$bytes)  { [math]::Round($bytes / $script:TB, 4) }
function To-GiB([double]$bytes) { [math]::Round($bytes / $script:GiB, 2) }
function To-TiB([double]$bytes) { [math]::Round($bytes / $script:TiB, 4) }

function Format-Storage([double]$gb) {
    if ($gb -lt 1)    { return "{0:N0} MB" -f ($gb * 1000) }
    if ($gb -ge 1000) { return "{0:N2} TB" -f ($gb / 1000) }
    return "{0:N2} GB" -f $gb
}

function Format-Pct([double]$p) { "{0:P2}" -f $p }

function Format-CountValue($value) {
    if ($null -eq $value) { return "N/A" }
    switch ($value) {
        "access_denied"  { return "Requires permission" }
        "not_available"  { return "Not provisioned" }
        "unknown"        { return "Unknown" }
        default          { return "{0:N0}" -f [int]$value }
    }
}

function Escape-Html([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    return [System.Net.WebUtility]::HtmlEncode($s)
}

function Escape-ODataString([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return $s }
    return $s.Replace("'", "''")
}

function Write-Log([string]$msg, [string]$Level = "INFO") {
    $timestamp = Get-Date -Format "HH:mm:ss"
    $formatted = "[$timestamp] $msg"
    switch ($Level) {
        "ERROR"   { Write-Host $formatted -ForegroundColor Red }
        "WARNING" { Write-Host $formatted -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $formatted -ForegroundColor Green }
        default   { Write-Host $formatted -ForegroundColor Gray }
    }
    if ($script:logFile) {
        "$Level $formatted" | Out-File -Append -FilePath $script:logFile -Encoding UTF8
    }
}

# SKU friendly name mapping for M365 license reporting
$script:SKU_NAMES = @{
    "SPE_E3"                        = "Microsoft 365 E3"
    "SPE_E5"                        = "Microsoft 365 E5"
    "SPE_F1"                        = "Microsoft 365 F1"
    "SPE_F3"                        = "Microsoft 365 F3"
    "ENTERPRISEPACK"                = "Office 365 E3"
    "ENTERPRISEPREMIUM"             = "Office 365 E5"
    "ENTERPRISEPREMIUM_NOPSTNCONF"  = "Office 365 E5 (No PSTN)"
    "DESKLESSPACK"                  = "Office 365 F3"
    "EXCHANGESTANDARD"              = "Exchange Online Plan 1"
    "EXCHANGEENTERPRISE"            = "Exchange Online Plan 2"
    "EXCHANGEESSENTIALS"            = "Exchange Online Essentials"
    "EXCHANGE_S_ESSENTIALS"         = "Exchange Online Essentials"
    "EMS_E3"                        = "Enterprise Mobility + Security E3"
    "EMS_E5"                        = "Enterprise Mobility + Security E5"
    "EMSPREMIUM"                    = "Enterprise Mobility + Security E5"
    "AAD_PREMIUM"                   = "Entra ID P1"
    "AAD_PREMIUM_P2"                = "Entra ID P2"
    "ATP_ENTERPRISE"                = "Microsoft Defender for Office 365 P1"
    "THREAT_INTELLIGENCE"           = "Microsoft Defender for Office 365 P2"
    "IDENTITY_THREAT_PROTECTION"    = "Microsoft 365 E5 Security"
    "INFORMATION_PROTECTION_COMPLIANCE" = "Microsoft 365 E5 Compliance"
    "ATA"                           = "Microsoft Defender for Identity"
    "WIN_DEF_ATP"                   = "Microsoft Defender for Endpoint P2"
    "MDATP_XPLAT"                   = "Microsoft Defender for Endpoint P2"
    "INTUNE_A"                      = "Microsoft Intune Plan 1"
    "O365_BUSINESS_ESSENTIALS"      = "Microsoft 365 Business Basic"
    "SMB_BUSINESS_ESSENTIALS"       = "Microsoft 365 Business Basic"
    "O365_BUSINESS_PREMIUM"         = "Microsoft 365 Business Standard"
    "SMB_BUSINESS_PREMIUM"          = "Microsoft 365 Business Standard"
    "SPB"                           = "Microsoft 365 Business Premium"
    "SHAREPOINTSTANDARD"            = "SharePoint Online Plan 1"
    "SHAREPOINTENTERPRISE"          = "SharePoint Online Plan 2"
    "PROJECTPREMIUM"                = "Project Plan 5"
    "PROJECTPROFESSIONAL"           = "Project Plan 3"
    "PROJECTESSENTIALS"             = "Project Plan 1"
    "VISIOONLINE_PLAN1"             = "Visio Plan 1"
    "VISIOCLIENT"                   = "Visio Plan 2"
    "POWER_BI_STANDARD"             = "Power BI Free"
    "POWER_BI_PRO"                  = "Power BI Pro"
    "POWER_BI_PREMIUM_P1"           = "Power BI Premium P1"
    "POWERAPPS_PER_USER"            = "Power Apps Per User"
    "FLOW_PER_USER"                 = "Power Automate Per User"
    "STREAM"                        = "Microsoft Stream"
    "MCOSTANDARD"                   = "Skype for Business Online Plan 2"
    "PHONESYSTEM_VIRTUALUSER"       = "Phone System Virtual User"
    "MCOCAP"                        = "Common Area Phone"
    "MCOPSTN1"                      = "Domestic Calling Plan"
    "MCOPSTN2"                      = "International Calling Plan"
    "MEETING_ROOM"                  = "Microsoft Teams Rooms Standard"
    "Teams_Ess"                     = "Microsoft Teams Essentials"
    "TEAMS_EXPLORATORY"             = "Microsoft Teams Exploratory"
    "M365_F1"                       = "Microsoft 365 F1"
    "STANDARDPACK"                  = "Office 365 E1"
    "ENTERPRISEWITHSCAL"            = "Office 365 E4"
    "RIGHTSMANAGEMENT"              = "Azure Information Protection P1"
    "RIGHTSMANAGEMENT_ADHOC"        = "Azure Rights Management"
    "M365EDU_A1"                    = "Microsoft 365 A1"
    "M365EDU_A3_FACULTY"            = "Microsoft 365 A3 (Faculty)"
    "M365EDU_A3_STUDENT"            = "Microsoft 365 A3 (Student)"
    "M365EDU_A5_FACULTY"            = "Microsoft 365 A5 (Faculty)"
    "M365EDU_A5_STUDENT"            = "Microsoft 365 A5 (Student)"
    "DEVELOPERPACK"                 = "Microsoft 365 E5 Developer"
    "DEVELOPERPACK_E5"              = "Microsoft 365 E5 Developer"
}

function Get-SkuFriendlyName([string]$SkuPartNumber) {
    if ($script:SKU_NAMES.ContainsKey($SkuPartNumber)) {
        return $script:SKU_NAMES[$SkuPartNumber]
    }
    # Fallback: replace underscores and title-case
    return ($SkuPartNumber -replace '_', ' ')
}

# =========================================================================
# Section 4: Graph API
# =========================================================================

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET','POST','PATCH','DELETE')][string]$Method = 'GET',
        [hashtable]$Headers,
        $Body,
        [int]$MaxRetries = 6
    )
    $attempt = 0
    do {
        try {
            Write-Log "Graph $Method $Uri"
            if ($Body) { return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body }
            else       { return Invoke-MgGraphRequest -Method $Method -Uri $Uri -Headers $Headers }
        } catch {
            $attempt++
            $msg = $_.Exception.Message
            $retryAfter = 0
            try {
                if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
                    [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
                }
            } catch { Write-Log "Retry-After header not parseable" }
            $isRetryable = ($msg -match 'Too Many Requests|throttle|429|5\d\d|temporarily unavailable')
            if ($attempt -le $MaxRetries -and $isRetryable) {
                $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
                if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
                Write-Log "Throttled: sleeping $sleep sec (attempt $attempt/$MaxRetries)" -Level WARNING
                Start-Sleep -Seconds $sleep
            } else {
                throw
            }
        }
    } while ($true)
}

function Invoke-GraphDownloadCsv {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutPath,
        [int]$MaxRetries = 6
    )
    $attempt = 0
    do {
        try {
            Write-Log "Graph DOWNLOAD $Uri"
            Invoke-MgGraphRequest -Uri $Uri -OutputFilePath $OutPath | Out-Null
            return
        } catch {
            $attempt++
            $msg = $_.Exception.Message
            $retryAfter = 0
            try {
                if ($_.Exception.Response -and $_.Exception.Response.Headers['Retry-After']) {
                    [int]::TryParse($_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) | Out-Null
                }
            } catch { Write-Log "Retry-After header not parseable" }
            $isRetryable = ($msg -match 'Too Many Requests|throttle|429|5\d\d|temporarily unavailable')
            if ($attempt -le $MaxRetries -and $isRetryable) {
                $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
                if ($retryAfter -gt 0) { $sleep = [Math]::Max($sleep, $retryAfter) }
                Write-Log "Throttled download: sleeping $sleep sec (attempt $attempt/$MaxRetries)" -Level WARNING
                Start-Sleep -Seconds $sleep
            } else {
                throw
            }
        }
    } while ($true)
}

function Get-GraphEntityCount {
    param([Parameter(Mandatory)][string]$Path)
    $headers = @{ "ConsistencyLevel" = "eventual" }
    $uri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1&`$count=true"
    try {
        $resp = Invoke-Graph -Uri $uri -Headers $headers
        if ($resp.'@odata.count') { return [int]$resp.'@odata.count' }
        elseif ($resp.value)      { return [int]@($resp.value).Count }
        else                      { return 0 }
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
            return "access_denied"
        }
        if ($msg -match '404|NotFound|No resource was found') {
            return "not_available"
        }
        try {
            $fallbackUri = "https://graph.microsoft.com/v1.0/${Path}?`$top=1"
            $fallback = Invoke-Graph -Uri $fallbackUri
            if ($fallback.value -and @($fallback.value).Count -gt 0) { return "present" }
            return 0
        } catch {
            $fallbackMsg = $_.Exception.Message
            if ($fallbackMsg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') { return "access_denied" }
            if ($fallbackMsg -match '404|NotFound|No resource was found') { return "not_available" }
            return "unknown"
        }
    }
}

# =========================================================================
# Section 5: Authentication
# =========================================================================

function Initialize-RequiredModules {
    $requiredModules = @(
        'Microsoft.Graph.Authentication',
        'Microsoft.Graph.Reports',
        'Microsoft.Graph.Identity.DirectoryManagement'
    )
    if ($ADGroup -or $ExcludeADGroup) { $requiredModules += 'Microsoft.Graph.Groups' }

    foreach ($m in $requiredModules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            if ($SkipModuleInstall) {
                throw "Missing required module '$m'. Install with: Install-Module $m -Scope CurrentUser"
            }
            Write-Host "Installing module $m..." -ForegroundColor Yellow
            Install-Module $m -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $m -ErrorAction Stop
    }
}

function Connect-GraphSession {
    $script:baseScopes = @("Reports.Read.All", "Directory.Read.All", "User.Read.All", "Organization.Read.All")
    if ($ADGroup -or $ExcludeADGroup) { $script:baseScopes += "Group.Read.All" }

    if (-not $UseAppAccess) {
        # Check for existing valid session
        try {
            $ctx = Get-MgContext
            if ($ctx) {
                Write-Host "Reusing existing Microsoft Graph session..." -ForegroundColor Green
                return
            }
        } catch { Write-Log "No existing Graph session found" }

        Write-Host "Connecting to Microsoft Graph (delegated)..." -ForegroundColor Green
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { Write-Log "No prior session to disconnect" }

        $connectParams = @{
            Scopes    = $script:baseScopes
            NoWelcome = $true
        }
        if ($UseDeviceCode) { $connectParams.UseDeviceCode = $true }

        Connect-MgGraph @connectParams
    } else {
        # App-only authentication
        if (-not $TenantId) { throw "-UseAppAccess requires -TenantId" }

        $connectParams = @{
            NoWelcome = $true
            TenantId  = $TenantId
        }

        if ($CertificateThumbprint) {
            if (-not $ClientId) { throw "-CertificateThumbprint requires -ClientId" }
            Write-Host "Connecting to Microsoft Graph (certificate)..." -ForegroundColor Green
            $connectParams.ClientId             = $ClientId
            $connectParams.CertificateThumbprint = $CertificateThumbprint
        } else {
            throw "For -UseAppAccess, provide -CertificateThumbprint and -ClientId. See README for app registration setup."
        }

        Connect-MgGraph @connectParams
    }
}

function Get-TenantInfo {
    $ctx = Get-MgContext

    # SDK v2.x returns Environment as a string, v1.x as an object
    $rawEnv = $ctx.Environment
    if ($null -ne $rawEnv -and $rawEnv.PSObject.Properties['Name']) {
        $script:envName = $rawEnv.Name
    } else {
        $script:envName = [string]$rawEnv
    }

    $script:TenantCategory = switch ($script:envName) {
        "AzureCloud"        { "Commercial" }
        "Global"            { "Commercial" }
        "AzureUSGovernment" { "US Government (GCC/GCC High/DoD)" }
        "USGov"             { "US Government (GCC/GCC High/DoD)" }
        "USGovDoD"          { "US Government (DoD)" }
        "AzureChinaCloud"   { "China (21Vianet)" }
        "China"             { "China (21Vianet)" }
        default             { "Unknown" }
    }

    try {
        $orgResult = Get-MgOrganization -ErrorAction Stop
        $org = if ($orgResult -is [array]) { $orgResult[0] } else { $orgResult }
        $script:OrgId = $org.Id
        $script:OrgName = $org.DisplayName
        $script:DefaultDomain = ($org.VerifiedDomains | Where-Object { $_.IsDefault -eq $true } | Select-Object -First 1).Name
    } catch {
        Write-Log "Get-MgOrganization failed, trying Graph REST" -Level WARNING
        try {
            $orgResp = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/organization"
            $orgData = $orgResp.value[0]
            $script:OrgId = $orgData.id
            $script:OrgName = $orgData.displayName
            $script:DefaultDomain = ($orgData.verifiedDomains | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1).name
        } catch {
            Write-Log "Could not retrieve tenant info: $($_.Exception.Message)" -Level ERROR
        }
    }

    Write-Log "Tenant: $($script:OrgName) ($($script:OrgId)), Env: $($script:envName), Category: $($script:TenantCategory)"
}

# =========================================================================
# Section 6: Data Collection
# =========================================================================

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

function Apply-UpnFilters([object[]]$Data, [string]$UpnField) {
    $Data = @($Data | Where-Object { $_ -ne $null -and $_.'Is Deleted' -ne 'TRUE' })
    if ($script:GroupUPNs -and $script:GroupUPNs.Count -gt 0) {
        $Data = @($Data | Where-Object { $script:GroupUPNs -contains $_.$UpnField })
    }
    if ($script:ExcludeUPNs -and $script:ExcludeUPNs.Count -gt 0) {
        $Data = @($Data | Where-Object { $script:ExcludeUPNs -notcontains $_.$UpnField })
    }
    return ,$Data
}

function Get-GraphReportCsv {
    param([Parameter(Mandatory)][string]$ReportName, [int]$PeriodDays)
    $uri = "https://graph.microsoft.com/v1.0/reports/$ReportName(period='D$PeriodDays')"
    $tmp = Join-Path $script:runFolder "$ReportName.csv"
    Invoke-GraphDownloadCsv -Uri $uri -OutPath $tmp
    $data = Import-Csv $tmp
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    return $data
}

function Annualize-GrowthPct {
    param([Parameter(Mandatory)][object[]]$csv, [Parameter(Mandatory)][string]$field)
    $rows = @($csv | Sort-Object { [datetime]$_.'Report Date' } -Descending)
    if (-not $rows -or $rows.Count -lt 2) { return 0.0 }

    $latest   = [double]$rows[0].$field
    $earliest = [double]$rows[-1].$field
    $days     = [int]$rows[0].'Report Period'

    if ($days -le 0 -or $earliest -le 0) { return 0.0 }

    $perDay  = ($latest - $earliest) / $days
    $perYear = $perDay * 365
    $pct     = $perYear / [math]::Max($earliest, 1)

    return [math]::Round($pct, 4)
}

function Invoke-DataCollection {
    # Group filtering
    $script:GroupUPNs   = Get-GroupUPNs -GroupName $ADGroup -Required:$false
    $script:ExcludeUPNs = Get-GroupUPNs -GroupName $ExcludeADGroup -Required:$false

    Write-Host "Pulling Microsoft 365 usage reports..." -ForegroundColor Green

    $script:exDetail  = Get-GraphReportCsv -ReportName "getMailboxUsageDetail"          -PeriodDays $Period
    $script:exCounts  = Get-GraphReportCsv -ReportName "getMailboxUsageMailboxCounts"    -PeriodDays $Period
    $script:odDetail  = Get-GraphReportCsv -ReportName "getOneDriveUsageAccountDetail"  -PeriodDays $Period
    $script:odStorage = Get-GraphReportCsv -ReportName "getOneDriveUsageStorage"        -PeriodDays $Period
    $script:spDetail  = Get-GraphReportCsv -ReportName "getSharePointSiteUsageDetail"   -PeriodDays $Period
    $script:spStorage = Get-GraphReportCsv -ReportName "getSharePointSiteUsageStorage"  -PeriodDays $Period

    # Exchange: filter active, separate shared
    $exUsersAll  = @($script:exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -ne 'Shared' })
    $exSharedAll = @($script:exDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' -and $_.'Recipient Type' -eq 'Shared' })

    $script:exUsers  = Apply-UpnFilters $exUsersAll  'User Principal Name'
    $script:exShared = $exSharedAll

    $odActiveAll     = @($script:odDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' })
    $script:odActive = Apply-UpnFilters $odActiveAll 'Owner Principal Name'

    # SharePoint: no group filtering (Graph API limitation)
    $script:spActive = @($script:spDetail | Where-Object { $_.'Is Deleted' -ne 'TRUE' })

    # Group filtering sanity check
    if ($ADGroup) {
        $sampleUpn = ($exUsersAll | Select-Object -First 5).'User Principal Name'
        $looksMasked = $false
        if ($sampleUpn) {
            $maskedCount = @($sampleUpn | Where-Object { $_ -notmatch '@' -or $_ -match '^Anonymous' }).Count
            if ($maskedCount -ge 3) { $looksMasked = $true }
        }
        if ($looksMasked) {
            throw "Usage reports appear to have user identifiers concealed (masked). Group filtering will fail. Disable concealed names in M365 Admin Center > Settings > Org settings > Services > Reports, then re-run."
        }
        if ($script:GroupUPNs.Count -gt 0 -and $script:exUsers.Count -eq 0 -and $script:odActive.Count -eq 0) {
            throw "ADGroup filtering matched 0 Exchange users and 0 OneDrive accounts. Check report masking settings and group membership."
        }
    }

    # Unique users to protect
    $uniqueUPN = @()
    $uniqueUPN += @($script:exUsers.'User Principal Name')
    $uniqueUPN += @($script:odActive.'Owner Principal Name')
    $script:UsersToProtect = (@($uniqueUPN | Where-Object { $_ } | Sort-Object -Unique)).Count

    # Source bytes
    $script:exUserBytes    = [double](($script:exUsers  | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
    $script:exSharedBytes  = [double](($script:exShared | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
    $script:exPrimaryBytes = [double]($script:exUserBytes + $script:exSharedBytes)
    $script:odBytes        = [double](($script:odActive | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)
    $script:spBytes        = [double](($script:spActive | Measure-Object -Property 'Storage Used (Byte)' -Sum).Sum)

    # Growth (annualized)
    $script:exGrowth = Annualize-GrowthPct -csv (Get-GraphReportCsv -ReportName "getMailboxUsageStorage" -PeriodDays $Period) -field 'Storage Used (Byte)'
    $script:odGrowth = Annualize-GrowthPct -csv $script:odStorage -field 'Storage Used (Byte)'
    $script:spGrowth = Annualize-GrowthPct -csv $script:spStorage -field 'Storage Used (Byte)'

    # Convert totals (decimal + binary)
    $script:exGB    = To-GB  $script:exPrimaryBytes
    $script:odGB    = To-GB  $script:odBytes
    $script:spGB    = To-GB  $script:spBytes
    $script:totalGB = [math]::Round($script:exGB + $script:odGB + $script:spGB, 2)

    $script:exGiB    = To-GiB $script:exPrimaryBytes
    $script:odGiB    = To-GiB $script:odBytes
    $script:spGiB    = To-GiB $script:spBytes
    $script:totalGiB = [math]::Round($script:exGiB + $script:odGiB + $script:spGiB, 2)

    $script:totalTB  = [math]::Round($script:totalGB / 1000, 4)
    $script:totalTiB = [math]::Round($script:totalGiB / 1024, 4)

    # SharePoint file count
    $script:spFiles = ($script:spActive | Measure-Object -Property 'File Count' -Sum).Sum

}

function Invoke-DirectoryInventory {
    Write-Host "Collecting Entra ID directory inventory..." -ForegroundColor Green

    $script:userCount   = Get-GraphEntityCount -Path "users"
    $script:groupCount  = Get-GraphEntityCount -Path "groups"
    $script:appRegCount = Get-GraphEntityCount -Path "applications"
    $script:spnCount    = Get-GraphEntityCount -Path "servicePrincipals"
    $script:caPolicyCount = Get-GraphEntityCount -Path "identity/conditionalAccess/policies"

    # Intune / Endpoint Manager (cloud-native configs that need protection)
    $script:intuneManagedDeviceCount    = Get-GraphEntityCount -Path "deviceManagement/managedDevices"
    $script:intuneCompliancePolicyCount = Get-GraphEntityCount -Path "deviceManagement/deviceCompliancePolicies"
    $script:intuneDeviceConfigCount     = Get-GraphEntityCount -Path "deviceManagement/deviceConfigurations"

    # Licensed M365 users
    try {
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=assignedLicenses/`$count ne 0&`$top=1&`$count=true"
        $resp = Invoke-Graph -Uri $uri -Headers @{ "ConsistencyLevel" = "eventual" }
        $script:licensedUserCount = if ($resp.'@odata.count') { [int]$resp.'@odata.count' } else { "unknown" }
    } catch {
        $script:licensedUserCount = "unknown"
    }

    # Guest users
    try {
        $uri = "https://graph.microsoft.com/v1.0/users?`$filter=userType eq 'Guest'&`$top=1&`$count=true"
        $resp = Invoke-Graph -Uri $uri -Headers @{ "ConsistencyLevel" = "eventual" }
        $script:guestUserCount = if ($resp.'@odata.count') { [int]$resp.'@odata.count' } else { 0 }
    } catch {
        $script:guestUserCount = "unknown"
    }

    Write-Log "Directory: Users=$($script:userCount), Licensed=$($script:licensedUserCount), Guests=$($script:guestUserCount), Groups=$($script:groupCount), Apps=$($script:appRegCount), SPNs=$($script:spnCount), CAPolicies=$($script:caPolicyCount)"
    Write-Log "Endpoint: ManagedDevices=$($script:intuneManagedDeviceCount), CompliancePolicies=$($script:intuneCompliancePolicyCount), DeviceConfigs=$($script:intuneDeviceConfigCount)"

    # M365 License SKUs
    try {
        $skuResp = Invoke-Graph -Uri "https://graph.microsoft.com/v1.0/subscribedSkus"
        $skuList = New-Object System.Collections.Generic.List[object]
        foreach ($sku in $skuResp.value) {
            if ($sku.appliesTo -ne 'User') { continue }
            $enabled = 0
            if ($sku.prepaidUnits -and $sku.prepaidUnits.enabled) {
                $enabled = [int]$sku.prepaidUnits.enabled
            }
            if ($enabled -le 0) { continue }
            $consumed = if ($sku.consumedUnits) { [int]$sku.consumedUnits } else { 0 }
            $utilPct = if ($enabled -gt 0) { [math]::Round(($consumed / $enabled) * 100, 1) } else { 0 }
            $skuList.Add([pscustomobject]@{
                SkuPartNumber    = $sku.skuPartNumber
                FriendlyName     = Get-SkuFriendlyName $sku.skuPartNumber
                ConsumedUnits    = $consumed
                TotalUnits       = $enabled
                UtilizationPct   = $utilPct
                CapabilityStatus = $sku.capabilityStatus
            })
        }
        $script:subscribedSkus = $skuList | Sort-Object -Property ConsumedUnits -Descending
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'Insufficient privileges|Authorization_RequestDenied|access denied|permission|consent|401|403|Forbidden') {
            $script:subscribedSkus = "access_denied"
        } else {
            Write-Log "License SKU retrieval failed: $msg" -Level WARNING
            $script:subscribedSkus = "error"
        }
    }

    if ($script:subscribedSkus -isnot [string]) { Write-Log "Licenses: $($script:subscribedSkus.Count) subscription types" }
}

# =========================================================================
# Section 7: SVG Charts
# Pure functions that return SVG markup strings — no system state changes.
# =========================================================================

function New-SvgDonutChart {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [array]$Segments = @(),
        [string]$CenterLabel = "",
        [string]$CenterSubLabel = "",
        [int]$Size = 200
    )

    if ($Segments.Count -eq 0) { return "" }

    $cx = 100; $cy = 100; $r = 70
    $strokeWidth = 24
    $total = 0
    foreach ($seg in $Segments) { $total += $seg.Value }
    if ($total -le 0) { return "" }

    $circles = ""
    $legendItems = ""
    $offset = 25

    foreach ($seg in $Segments) {
        $pct = ($seg.Value / $total) * 100
        $gap = 100 - $pct
        $segColor = $seg.Color
        $circles += "      <circle cx=`"$cx`" cy=`"$cy`" r=`"$r`" fill=`"none`" stroke=`"$segColor`" stroke-width=`"$strokeWidth`" pathLength=`"100`" stroke-dasharray=`"$([Math]::Round($pct,2)), $([Math]::Round($gap,2))`" stroke-dashoffset=`"$([Math]::Round(-$offset,2))`" />`n"
        $offset += $pct

        $pctDisplay = [Math]::Round($pct, 0)
        $escapedSegLabel = Escape-Html $seg.Label
        $legendItems += "      <div style=`"display:flex;align-items:center;gap:8px;font-size:12px;color:#605E5C`"><span style=`"width:10px;height:10px;border-radius:2px;background:$segColor;flex-shrink:0`"></span>$escapedSegLabel ($pctDisplay%)</div>`n"
    }

    $escapedCenter = Escape-Html $CenterLabel
    $escapedSub = Escape-Html $CenterSubLabel

    return @"
    <div style="display:flex;align-items:center;gap:24px;flex-wrap:wrap">
      <svg viewBox="0 0 200 200" width="$Size" height="$Size" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Donut chart">
        <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="#EDEBE9" stroke-width="$strokeWidth" />
$circles
        <text x="$cx" y="$($cy - 4)" text-anchor="middle" dominant-baseline="middle" fill="#323130" font-size="22" font-weight="700" font-family="'Cascadia Code','Consolas',monospace">$escapedCenter</text>
        <text x="$cx" y="$($cy + 16)" text-anchor="middle" fill="#605E5C" font-size="11" font-family="'Segoe UI',sans-serif">$escapedSub</text>
      </svg>
      <div style="display:flex;flex-direction:column;gap:6px">
$legendItems
      </div>
    </div>
"@
}

function New-SvgMiniRing {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param(
        [double]$Percent = 0,
        [string]$Color = "#0078D4",
        [int]$Size = 48
    )

    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }

    $cx = 24; $cy = 24; $r = 18
    $dashFill = [Math]::Round($Percent, 1)
    $dashGap = 100

    return @"
<svg viewBox="0 0 48 48" width="$Size" height="$Size" xmlns="http://www.w3.org/2000/svg" style="transform:rotate(-90deg)">
  <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="#EDEBE9" stroke-width="5" />
  <circle cx="$cx" cy="$cy" r="$r" fill="none" stroke="$Color" stroke-width="5" pathLength="100" stroke-dasharray="$dashFill, $dashGap" stroke-linecap="round" />
</svg>
"@
}

# =========================================================================
# Section 8: HTML Report
# =========================================================================

function Build-HtmlReport {
    $css = @"
:root {
  --ms-blue: #0078D4; --ms-blue-dark: #106EBE; --ms-blue-light: #50E6FF;
  --ms-gray-10: #FAF9F8; --ms-gray-20: #F3F2F1; --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE; --ms-gray-90: #605E5C; --ms-gray-130: #323130; --ms-gray-160: #201F1E;
  --veeam-green: #00B336;
  --color-success: #107C10; --color-warning: #F7630C; --color-danger: #D13438; --color-info: #0078D4;
  --header-dark: #1B1B2F; --header-mid: #1F4068;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
  background: var(--ms-gray-10); color: var(--ms-gray-160); line-height: 1.6; font-size: 14px;
  -webkit-font-smoothing: antialiased; counter-reset: section-counter;
}
.container { max-width: 1440px; margin: 0 auto; padding: 0 32px 40px; }
.exec-header {
  background: linear-gradient(135deg, var(--header-dark) 0%, var(--header-mid) 100%);
  padding: 48px 32px 40px; margin-bottom: 32px; position: relative; overflow: hidden;
}
.exec-header::before {
  content: ''; position: absolute; top: -50%; right: -10%; width: 400px; height: 400px;
  background: radial-gradient(circle, rgba(255,255,255,0.04) 0%, transparent 70%); border-radius: 50%;
}
.exec-header-inner { max-width: 1440px; margin: 0 auto; position: relative; z-index: 1; }
.exec-header-org { font-size: 36px; font-weight: 700; color: #FFFFFF; letter-spacing: -0.02em; margin-bottom: 6px; }
.exec-header-title { font-size: 16px; font-weight: 400; color: rgba(255,255,255,0.75); margin-bottom: 20px; }
.exec-header-meta { display: flex; flex-wrap: wrap; gap: 24px; align-items: center; }
.exec-header-meta-item { font-size: 13px; color: rgba(255,255,255,0.6); }
.exec-header-meta-item strong { color: rgba(255,255,255,0.9); font-weight: 600; }
.exec-badge {
  display: inline-block; padding: 4px 14px; background: rgba(255,255,255,0.15); color: #FFFFFF;
  border: 1px solid rgba(255,255,255,0.25); border-radius: 14px; font-size: 11px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.08em; backdrop-filter: blur(4px);
}
details.section {
  background: white; padding: 32px; margin-bottom: 24px; border-radius: 4px;
  box-shadow: var(--shadow-depth-4); counter-increment: section-counter;
}
details.section > summary {
  font-size: 20px; font-weight: 600; color: var(--ms-gray-160); margin-bottom: 20px; padding-bottom: 12px;
  border-bottom: 3px solid transparent;
  border-image: linear-gradient(90deg, var(--ms-blue), var(--veeam-green), transparent) 1;
  display: flex; align-items: baseline; gap: 12px; cursor: pointer; list-style: none; user-select: none;
}
details.section > summary::-webkit-details-marker { display: none; }
details.section > summary::before {
  content: counter(section-counter, decimal-leading-zero);
  font-size: 14px; font-weight: 700; color: var(--ms-blue);
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace; min-width: 28px;
}
details.section > summary::after { content: '\25B6'; font-size: 12px; color: var(--ms-gray-90); margin-left: auto; transition: transform 0.2s ease; }
details[open].section > summary::after { transform: rotate(90deg); }
details.section > summary:hover { color: var(--ms-blue-dark); }
.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-bottom: 24px; }
.kpi-card {
  background: rgba(255,255,255,0.85); backdrop-filter: blur(12px); padding: 24px; border-radius: 8px;
  box-shadow: var(--shadow-depth-4); border: 1px solid rgba(255,255,255,0.6); transition: all 0.2s ease;
  display: flex; gap: 16px; align-items: flex-start;
}
.kpi-card:hover { box-shadow: var(--shadow-depth-8); transform: translateY(-2px); }
.kpi-card-content { flex: 1; }
.kpi-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ms-gray-90); margin-bottom: 8px; }
.kpi-value { font-size: 32px; font-weight: 700; color: var(--ms-gray-160); line-height: 1.1; margin-bottom: 6px; font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace; font-variant-numeric: tabular-nums; }
.kpi-subtext { font-size: 12px; color: var(--ms-gray-90); font-weight: 400; }
.tenant-info { background: white; padding: 24px 32px; margin-bottom: 24px; border-radius: 4px; box-shadow: var(--shadow-depth-4); }
.tenant-info-title { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.06em; color: var(--ms-gray-90); margin-bottom: 12px; }
.tenant-info-row { display: flex; flex-wrap: wrap; gap: 24px; padding: 8px 0; border-bottom: 1px solid var(--ms-gray-30); }
.tenant-info-row:last-child { border-bottom: none; }
.tenant-info-item { display: flex; gap: 8px; }
.tenant-info-label { color: var(--ms-gray-90); font-weight: 400; }
.tenant-info-value { color: var(--ms-gray-160); font-weight: 600; }
.table-container { overflow-x: auto; margin-top: 16px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th { padding: 12px 16px; text-align: left; font-weight: 600; color: var(--ms-gray-130); font-size: 12px; text-transform: uppercase; letter-spacing: 0.03em; border-bottom: 2px solid var(--ms-gray-50); }
td { padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); font-variant-numeric: tabular-nums; }
tbody tr:hover { background: var(--ms-gray-10); }
tbody tr:last-child td { border-bottom: none; }
.info-card { background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue); padding: 20px 24px; margin: 16px 0; border-radius: 2px; }
.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 13px; line-height: 1.6; margin-bottom: 8px; }
.info-card-text:last-child { margin-bottom: 0; }
.code-block { background: var(--ms-gray-160); color: var(--ms-blue-light); padding: 20px 24px; border-radius: 4px; font-family: 'Cascadia Code', 'Consolas', 'Monaco', 'Courier New', monospace; font-size: 13px; line-height: 1.8; overflow-x: auto; margin-top: 16px; }
.code-line { display: block; white-space: nowrap; }
.workload-flex { display: flex; gap: 32px; align-items: flex-start; flex-wrap: wrap; }
.workload-chart { flex-shrink: 0; }
.workload-table { flex: 1; min-width: 0; }
.identity-kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin: 16px 0; }
.identity-kpi { background: var(--ms-gray-10); padding: 16px; border-radius: 4px; text-align: center; }
.identity-kpi-value { font-size: 28px; font-weight: 600; color: var(--ms-gray-160); font-family: 'Cascadia Code', 'Consolas', monospace; font-variant-numeric: tabular-nums; }
.identity-kpi-label { font-size: 12px; color: var(--ms-gray-90); margin-top: 4px; }
.cloud-native-label { font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; color: var(--ms-gray-90); margin: 24px 0 8px; font-weight: 600; }
.identity-kpi.cloud-native { border-left: 3px solid var(--veeam-green); }
.file-list { list-style: none; padding: 0; margin: 16px 0 0 0; }
.file-item { padding: 10px 16px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-130); font-size: 13px; font-family: 'Cascadia Code', 'Consolas', monospace; }
.file-item:last-child { border-bottom: none; }
.exec-footer { text-align: center; padding: 32px 0 16px; border-top: 1px solid var(--ms-gray-30); margin-top: 16px; }
.exec-footer-org { font-size: 13px; font-weight: 600; color: var(--ms-gray-130); margin-bottom: 4px; }
.exec-footer-conf { font-size: 11px; color: var(--ms-gray-90); margin-bottom: 4px; font-style: italic; }
.exec-footer-stamp { font-size: 11px; color: var(--ms-gray-50); font-family: 'Cascadia Code', 'Consolas', monospace; }
.svg-container { margin: 16px 0; }
.svg-container svg { max-width: 100%; height: auto; }
@media (max-width: 768px) {
  .container { padding: 0 16px 20px; } .exec-header { padding: 32px 16px 28px; }
  .exec-header-org { font-size: 24px; } .kpi-grid { grid-template-columns: 1fr; }
  details.section { padding: 20px; } .tenant-info-row { flex-direction: column; gap: 12px; }
  .identity-kpi-grid { grid-template-columns: repeat(2, 1fr); } .workload-flex { flex-direction: column; }
}
@media print {
  body { background: white; font-size: 12px; } .container { max-width: 100%; padding: 0; }
  .exec-header { print-color-adjust: exact; -webkit-print-color-adjust: exact; padding: 32px 24px; }
  .kpi-card, details.section, .tenant-info { box-shadow: none; border: 1px solid var(--ms-gray-30); page-break-inside: avoid; }
  .kpi-card:hover { transform: none; } .kpi-card { backdrop-filter: none; background: white; }
  svg { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
  details.section { display: block; } details.section > summary::after { display: none; }
  details.section > .section-content { display: block !important; }
}
"@

    $htmlParts = New-Object System.Collections.Generic.List[string]
    $orgDisplay = if ($script:OrgName) { $script:OrgName } else { "Microsoft 365 Tenant" }

    # DOCTYPE + head
    $htmlParts.Add(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VB365 Backup Sizing Report - $(Escape-Html $orgDisplay)</title>
<style>
$css
</style>
</head>
<body>
"@)

    # Header
    $htmlParts.Add(@"
  <div class="exec-header">
    <div class="exec-header-inner">
      <div class="exec-header-org">$(Escape-Html $orgDisplay)</div>
      <div class="exec-header-title">Veeam Backup for Microsoft 365 - Sizing Report</div>
      <div class="exec-header-meta">
        <span class="exec-badge">SIZING</span>
        <span class="exec-header-meta-item"><strong>Generated:</strong> $((Get-Date).ToUniversalTime().ToString("MMMM dd, yyyy 'at' HH:mm")) UTC</span>
        $(if($script:DefaultDomain){"<span class='exec-header-meta-item'><strong>Domain:</strong> $(Escape-Html $script:DefaultDomain)</span>"}else{""})
        $(if($script:TenantCategory){"<span class='exec-header-meta-item'><strong>Environment:</strong> $(Escape-Html $script:TenantCategory)</span>"}else{""})
      </div>
    </div>
  </div>
  <div class="container">
"@)

    # Tenant Info
    $htmlParts.Add(@"
  <div class="tenant-info">
    <div class="tenant-info-title">Tenant Details</div>
    <div class="tenant-info-row">
      $(if($script:OrgName){"<div class='tenant-info-item'><span class='tenant-info-label'>Organization:</span><span class='tenant-info-value'>$(Escape-Html $script:OrgName)</span></div>"}else{""})
      $(if($script:OrgId){"<div class='tenant-info-item'><span class='tenant-info-label'>Tenant ID:</span><span class='tenant-info-value'>$(Escape-Html $script:OrgId)</span></div>"}else{""})
    </div>
    <div class="tenant-info-row">
      $(if($script:DefaultDomain){"<div class='tenant-info-item'><span class='tenant-info-label'>Default Domain:</span><span class='tenant-info-value'>$(Escape-Html $script:DefaultDomain)</span></div>"}else{""})
      <div class="tenant-info-item"><span class="tenant-info-label">Environment:</span><span class="tenant-info-value">$(Escape-Html $script:envName)</span></div>
      $(if($script:TenantCategory){"<div class='tenant-info-item'><span class='tenant-info-label'>Category:</span><span class='tenant-info-value'>$(Escape-Html $script:TenantCategory)</span></div>"}else{""})
    </div>
  </div>
"@)

    # KPI Grid
    $usersRing   = New-SvgMiniRing -Percent 100 -Color "#0078D4"
    $datasetRing = New-SvgMiniRing -Percent 75 -Color "#106EBE"

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Key Performance Indicators</summary>
    <div class="section-content">
    <div class="kpi-grid">
      <div class="kpi-card">
        $usersRing
        <div class="kpi-card-content">
          <div class="kpi-label">Users to Protect</div>
          <div class="kpi-value">$($script:UsersToProtect)</div>
          <div class="kpi-subtext">Active user accounts</div>
        </div>
      </div>
      <div class="kpi-card">
        $datasetRing
        <div class="kpi-card-content">
          <div class="kpi-label">Total Dataset</div>
          <div class="kpi-value">$(Format-Storage $script:totalGB)</div>
          <div class="kpi-subtext">$($script:totalGB) GB | $($script:totalTiB) TiB (binary)</div>
        </div>
      </div>
    </div>
    </div>
  </details>
"@)

    # Workload Analysis
    $donutSegments = New-Object System.Collections.Generic.List[object]
    if ($script:exGB -gt 0) { $donutSegments.Add(@{ Label = "Exchange Online"; Value = $script:exGB; Color = "#0078D4" }) }
    if ($script:odGB -gt 0) { $donutSegments.Add(@{ Label = "OneDrive"; Value = $script:odGB; Color = "#106EBE" }) }
    if ($script:spGB -gt 0) { $donutSegments.Add(@{ Label = "SharePoint"; Value = $script:spGB; Color = "#00B336" }) }
    $donutChart = New-SvgDonutChart -Segments $donutSegments -CenterLabel (Format-Storage $script:totalGB) -CenterSubLabel "Total"

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Workload Analysis</summary>
    <div class="section-content">
    <div class="workload-flex">
      <div class="workload-chart svg-container">
$donutChart
      </div>
      <div class="workload-table">
        <div class="table-container">
          <table>
            <thead>
              <tr><th>Workload</th><th>Objects</th><th>Secondary</th><th>Source (GB)</th><th>Source (GiB)</th><th>Growth</th><th>Notes</th></tr>
            </thead>
            <tbody>
              <tr>
                <td><strong>Exchange Online</strong></td>
                <td>$($script:exUsers.Count)</td>
                <td>$($script:exShared.Count) shared</td>
                <td>$($script:exGB)</td>
                <td>$($script:exGiB)</td>
                <td>$(Format-Pct $script:exGrowth)</td>
                <td>User + shared mailboxes</td>
              </tr>
              <tr>
                <td><strong>OneDrive for Business</strong></td>
                <td>$($script:odActive.Count)</td>
                <td>&mdash;</td>
                <td>$($script:odGB)</td>
                <td>$($script:odGiB)</td>
                <td>$(Format-Pct $script:odGrowth)</td>
                <td>$(if($ADGroup){"AD group filtered"}else{"All accounts"})</td>
              </tr>
              <tr>
                <td><strong>SharePoint Online</strong></td>
                <td>$($script:spActive.Count)</td>
                <td>$($script:spFiles) files</td>
                <td>$($script:spGB)</td>
                <td>$($script:spGiB)</td>
                <td>$(Format-Pct $script:spGrowth)</td>
                <td>Tenant-wide (no group filter)</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    </div>
  </details>
"@)

    # Directory Inventory
    $htmlParts.Add(@"
  <details class="section">
    <summary>Directory Inventory</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">Entra ID Protection Scope</div>
      <div class="info-card-text">
        These counts represent the Entra ID identity footprint and cloud-native endpoint management configurations in scope for backup protection with Veeam Backup for Microsoft 365. Conditional Access policies, compliance rules, and device configurations exist only in the cloud and cannot be recovered from on-premises systems.
      </div>
    </div>
    <div class="identity-kpi-grid">
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:userCount)</div>
        <div class="identity-kpi-label">Total Users</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:licensedUserCount)</div>
        <div class="identity-kpi-label">Licensed M365 Users</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:guestUserCount)</div>
        <div class="identity-kpi-label">Guest Accounts</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:groupCount)</div>
        <div class="identity-kpi-label">Groups</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:appRegCount)</div>
        <div class="identity-kpi-label">App Registrations</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:spnCount)</div>
        <div class="identity-kpi-label">Service Principals</div>
      </div>
    </div>
    <div class="cloud-native-label">Cloud-Native Configurations</div>
    <div class="identity-kpi-grid">
      <div class="identity-kpi cloud-native">
        <div class="identity-kpi-value">$(Format-CountValue $script:caPolicyCount)</div>
        <div class="identity-kpi-label">Conditional Access Policies</div>
      </div>
      <div class="identity-kpi cloud-native">
        <div class="identity-kpi-value">$(Format-CountValue $script:intuneManagedDeviceCount)</div>
        <div class="identity-kpi-label">Managed Devices</div>
      </div>
      <div class="identity-kpi cloud-native">
        <div class="identity-kpi-value">$(Format-CountValue $script:intuneCompliancePolicyCount)</div>
        <div class="identity-kpi-label">Compliance Policies</div>
      </div>
      <div class="identity-kpi cloud-native">
        <div class="identity-kpi-value">$(Format-CountValue $script:intuneDeviceConfigCount)</div>
        <div class="identity-kpi-label">Device Configurations</div>
      </div>
    </div>
"@)

    # M365 License Subscriptions
    if ($script:subscribedSkus -eq "access_denied") {
        $htmlParts.Add(@"
    <div class="cloud-native-label">M365 License Subscriptions</div>
    <div class="info-card">
      <div class="info-card-text">License subscription data is not available. Grant <strong>Directory.Read.All</strong> permission to include license details.</div>
    </div>
"@)
    } elseif ($script:subscribedSkus -is [string]) {
        $htmlParts.Add(@"
    <div class="cloud-native-label">M365 License Subscriptions</div>
    <div class="info-card">
      <div class="info-card-text">License subscription data could not be retrieved. Check network connectivity and retry.</div>
    </div>
"@)
    } elseif ($script:subscribedSkus -and @($script:subscribedSkus).Count -gt 0) {
        $skuRows = ""
        foreach ($sku in $script:subscribedSkus) {
            $available = $sku.TotalUnits - $sku.ConsumedUnits
            $barColor = "#0078D4"
            if ($sku.UtilizationPct -ge 95) { $barColor = "#D13438" }
            elseif ($sku.UtilizationPct -ge 80) { $barColor = "#F7630C" }
            $barWidth = [Math]::Round($sku.UtilizationPct * 0.8, 1)
            if ($barWidth -lt 1 -and $sku.ConsumedUnits -gt 0) { $barWidth = 1 }
            $statusBadge = ""
            if ($sku.CapabilityStatus -ne "Enabled") {
                $statusBadge = " <span style=`"display:inline-block;padding:1px 6px;background:#FFF4CE;color:#8A6914;border-radius:3px;font-size:10px;font-weight:600;margin-left:6px`">$([System.Net.WebUtility]::HtmlEncode($sku.CapabilityStatus))</span>"
            }
            $skuRows += @"
              <tr>
                <td><strong>$(Escape-Html $sku.FriendlyName)</strong>$statusBadge</td>
                <td style="font-size:12px;color:var(--ms-gray-90);font-family:'Cascadia Code','Consolas',monospace">$(Escape-Html $sku.SkuPartNumber)</td>
                <td>$($sku.ConsumedUnits)</td>
                <td>$available</td>
                <td>
                  <div style="display:flex;align-items:center;gap:8px">
                    <div style="width:80px;height:8px;background:var(--ms-gray-30);border-radius:4px;overflow:hidden">
                      <div style="width:$($barWidth)px;height:100%;background:$barColor;border-radius:4px"></div>
                    </div>
                    <span style="font-size:12px;font-weight:600;color:var(--ms-gray-130)">$($sku.UtilizationPct)%</span>
                  </div>
                </td>
              </tr>

"@
        }
        $htmlParts.Add(@"
    <div class="cloud-native-label">M365 License Subscriptions</div>
    <div class="table-container">
      <table>
        <thead>
          <tr><th>License</th><th>SKU Part Number</th><th>Consumed</th><th>Available</th><th>Utilization</th></tr>
        </thead>
        <tbody>
$skuRows
        </tbody>
      </table>
    </div>
"@)
    }

    $htmlParts.Add(@"
    </div>
  </details>
"@)

    # Methodology
    $htmlParts.Add(@"
  <details class="section">
    <summary>Methodology</summary>
    <div class="section-content">
    <div class="info-card">
      <div class="info-card-title">Measured Data</div>
      <div class="info-card-text">
        Dataset totals are sourced from Microsoft Graph usage reports ($Period-day period). These reflect actual storage consumption as reported by Microsoft.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Growth Rate Calculation</div>
      <div class="info-card-text">
        Annual growth rates are estimated by linear extrapolation from the usage report period. The difference between the earliest and latest storage values in the $Period-day window is divided by the period length to produce a daily rate, then projected to 365 days. Growth percentage is relative to the earliest observed value. Short report periods or tenants with minimal data may produce less reliable growth estimates.
      </div>
    </div>
    </div>
  </details>
"@)

    # Sizing Parameters
    $htmlParts.Add(@"
  <details class="section">
    <summary>Sizing Parameters</summary>
    <div class="section-content">
    <div class="table-container">
      <table>
        <thead><tr><th>Parameter</th><th>Value</th></tr></thead>
        <tbody>
          <tr><td>Report Period</td><td>$Period days</td></tr>
          <tr><td>Include AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ADGroup)){"None"}else{Escape-Html $ADGroup})</td></tr>
          <tr><td>Exclude AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ExcludeADGroup)){"None"}else{Escape-Html $ExcludeADGroup})</td></tr>
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@)

    # Generated Artifacts
    $htmlParts.Add(@"
  <details class="section">
    <summary>Generated Artifacts</summary>
    <div class="section-content">
    <div class="file-list">
      <div class="file-item">Summary CSV: $(Split-Path $script:outSummary -Leaf)</div>
      <div class="file-item">Workloads CSV: $(Split-Path $script:outWorkload -Leaf)</div>
      <div class="file-item">HTML Report: $(Split-Path $script:outHtml -Leaf)</div>
    </div>
    </div>
  </details>
"@)

    # Footer
    $htmlParts.Add(@"
  <footer class="exec-footer">
    <div class="exec-footer-org">Prepared for $(Escape-Html $orgDisplay)</div>
    <div class="exec-footer-conf">This is a community-maintained open-source tool (VeeamHub). Not created by Veeam R&amp;D or validated by Veeam Q&amp;A. Veeam Support does not provide technical support.</div>
    <div class="exec-footer-stamp">$((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC | VB365-Sizing v1.0.0</div>
  </footer>
</div>
</body>
</html>
"@)

    # Write HTML
    $html = $htmlParts -join "`n"
    $html | Set-Content -Path $script:outHtml -Encoding UTF8
}

# =========================================================================
# Section 9: Exports
# =========================================================================

function Export-SummaryData {
    $summaryProps = [ordered]@{
        ReportDate             = (Get-Date).ToString("s")
        OrgName                = $script:OrgName
        OrgId                  = $script:OrgId
        DefaultDomain          = $script:DefaultDomain
        GraphEnvironment       = $script:envName
        TenantCategory         = $script:TenantCategory
        UsersToProtect         = $script:UsersToProtect

        Exchange_SourceBytes   = [int64]$script:exPrimaryBytes
        OneDrive_SourceBytes   = [int64]$script:odBytes
        SharePoint_SourceBytes = [int64]$script:spBytes

        Exchange_SourceGB      = $script:exGB
        OneDrive_SourceGB      = $script:odGB
        SharePoint_SourceGB    = $script:spGB
        Total_SourceGB         = $script:totalGB

        Exchange_SourceGiB     = $script:exGiB
        OneDrive_SourceGiB     = $script:odGiB
        SharePoint_SourceGiB   = $script:spGiB
        Total_SourceGiB        = $script:totalGiB

        Total_SourceTB         = $script:totalTB
        Total_SourceTiB        = $script:totalTiB

        Exchange_AnnualGrowthPct  = $script:exGrowth
        OneDrive_AnnualGrowthPct  = $script:odGrowth
        SharePoint_AnnualGrowthPct = $script:spGrowth

        Dir_UserCount          = $script:userCount
        Dir_LicensedUsers      = $script:licensedUserCount
        Dir_GuestUsers         = $script:guestUserCount
        Dir_GroupCount         = $script:groupCount
        Dir_AppRegistrations   = $script:appRegCount
        Dir_ServicePrincipals  = $script:spnCount
        Dir_CAPolicies         = $script:caPolicyCount
        Dir_IntuneManagedDevices    = $script:intuneManagedDeviceCount
        Dir_IntuneCompliancePolicies = $script:intuneCompliancePolicyCount
        Dir_IntuneDeviceConfigs     = $script:intuneDeviceConfigCount

        LicenseSkus            = if ($script:subscribedSkus -isnot [string] -and $script:subscribedSkus) {
            ($script:subscribedSkus | ForEach-Object { "$($_.FriendlyName):$($_.ConsumedUnits)/$($_.TotalUnits)" }) -join ";"
        } else { "" }
    }

    $summary = [pscustomobject]$summaryProps
    $summary | Export-Csv -NoTypeInformation -Path $script:outSummary -Encoding UTF8
    return $summary
}

function Export-WorkloadData {
    $wl = @(
        [pscustomobject]@{
            Workload        = "Exchange"
            Objects         = $script:exUsers.Count
            SharedObjects   = $script:exShared.Count
            SourceBytes     = [int64]$script:exPrimaryBytes
            SourceGB        = $script:exGB
            SourceGiB       = $script:exGiB
            AnnualGrowthPct = $script:exGrowth
            Notes           = "Includes shared mailbox bytes from usage report."
        },
        [pscustomobject]@{
            Workload        = "OneDrive"
            Objects         = $script:odActive.Count
            SharedObjects   = $null
            SourceBytes     = [int64]$script:odBytes
            SourceGB        = $script:odGB
            SourceGiB       = $script:odGiB
            AnnualGrowthPct = $script:odGrowth
            Notes           = "Group filter applies to OneDrive owners only."
        },
        [pscustomobject]@{
            Workload        = "SharePoint"
            Objects         = $script:spActive.Count
            SharedObjects   = $script:spFiles
            SourceBytes     = [int64]$script:spBytes
            SourceGB        = $script:spGB
            SourceGiB       = $script:spGiB
            AnnualGrowthPct = $script:spGrowth
            Notes           = "SharePoint group filtering not supported; totals are tenant-wide."
        }
    )
    $wl | Export-Csv -NoTypeInformation -Path $script:outWorkload -Encoding UTF8
    return $wl
}

# =========================================================================
# Section 10: Main Orchestration
# =========================================================================

$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"

# Output folder
New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
$script:runFolder   = $OutFolder
$script:outHtml     = Join-Path $OutFolder "VB365-Sizing-Report-$stamp.html"
$script:outSummary  = Join-Path $OutFolder "VB365-Sizing-Summary-$stamp.csv"
$script:outWorkload = Join-Path $OutFolder "VB365-Sizing-Workloads-$stamp.csv"
$script:logFile     = Join-Path $OutFolder "VB365-Sizing-$stamp.log"

try {
    # Step 1: Modules
    Write-Host "Initializing..." -ForegroundColor Green
    Initialize-RequiredModules

    # Step 2: Auth
    Connect-GraphSession

    # Step 3: Tenant info
    Get-TenantInfo
    Write-Host "Tenant: $($script:OrgName) ($($script:DefaultDomain))" -ForegroundColor Cyan

    # Step 4: Data collection
    Invoke-DataCollection

    # Step 5: Directory inventory
    Invoke-DirectoryInventory

    # Step 6: Exports
    Write-Host "Exporting data..." -ForegroundColor Green
    Export-SummaryData  | Out-Null
    Export-WorkloadData | Out-Null

    # Step 7: HTML report
    if (-not $SkipHtmlReport) {
        Write-Host "Generating HTML report..." -ForegroundColor Green
        Build-HtmlReport
    }

    # Step 8: Cleanup
    try { Disconnect-MgGraph | Out-Null } catch { Write-Log "Graph session already disconnected" }

    # Console summary
    Write-Host ""
    Write-Host "Sizing complete." -ForegroundColor Green
    Write-Host "  Tenant        : $($script:OrgName) ($($script:TenantCategory))"
    Write-Host "  Users         : $($script:UsersToProtect)"
    Write-Host "  Total dataset : $(Format-Storage $script:totalGB) ($($script:totalGB) GB)"
    Write-Host ""
    Write-Host "  Directory     : $(Format-CountValue $script:userCount) users, $(Format-CountValue $script:licensedUserCount) licensed, $(Format-CountValue $script:guestUserCount) guests"
    Write-Host "                  $(Format-CountValue $script:groupCount) groups, $(Format-CountValue $script:appRegCount) apps, $(Format-CountValue $script:spnCount) SPNs"
    Write-Host "  Cloud configs : $(Format-CountValue $script:caPolicyCount) CA policies, $(Format-CountValue $script:intuneManagedDeviceCount) managed devices"
    Write-Host "                  $(Format-CountValue $script:intuneCompliancePolicyCount) compliance policies, $(Format-CountValue $script:intuneDeviceConfigCount) device configs"
    if ($script:subscribedSkus -isnot [string] -and $script:subscribedSkus -and @($script:subscribedSkus).Count -gt 0) {
        $skuArr = @($script:subscribedSkus)
        Write-Host "  Licenses      : $($skuArr.Count) subscription type(s)"
        $showCount = [Math]::Min($skuArr.Count, 5)
        for ($i = 0; $i -lt $showCount; $i++) {
            $s = $skuArr[$i]
            $name = $s.FriendlyName.PadRight(40)
            Write-Host "                  $name $($s.ConsumedUnits)/$($s.TotalUnits) ($($s.UtilizationPct)%)"
        }
        if ($skuArr.Count -gt 5) {
            Write-Host "                  ... and $($skuArr.Count - 5) more"
        }
    }
    Write-Host ""
    Write-Host "  Summary CSV   : $($script:outSummary)"
    Write-Host "  Workloads CSV : $($script:outWorkload)"
    if (-not $SkipHtmlReport) {
        Write-Host "  HTML report   : $($script:outHtml)"
    }
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""

    # Common error guidance
    if ($_.Exception.Message -match '403|Forbidden|Insufficient privileges') {
        Write-Host "TROUBLESHOOTING: Missing Graph API permissions." -ForegroundColor Yellow
        Write-Host "  Required: Reports.Read.All, Directory.Read.All, User.Read.All, Organization.Read.All" -ForegroundColor Yellow
        Write-Host "  Grant admin consent in Entra ID > App registrations > API permissions" -ForegroundColor Yellow
    }
    elseif ($_.Exception.Message -match '401|Unauthorized') {
        Write-Host "TROUBLESHOOTING: Authentication failed." -ForegroundColor Yellow
        Write-Host "  Verify TenantId, ClientId, and CertificateThumbprint are correct." -ForegroundColor Yellow
    }
    elseif ($_.Exception.Message -match 'concealed|masked') {
        Write-Host "TROUBLESHOOTING: Report masking is enabled." -ForegroundColor Yellow
        Write-Host "  Disable in M365 Admin Center > Settings > Org settings > Services > Reports" -ForegroundColor Yellow
    }

    throw
}
