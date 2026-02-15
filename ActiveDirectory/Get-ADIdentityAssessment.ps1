<#
.SYNOPSIS
  Get-ADIdentityAssessment.ps1 - On-premises Active Directory identity structure assessment.

.DESCRIPTION (what this script does, in plain terms)
  1) Discovers all AD forests reachable from the executing host
  2) Enumerates domains, trusts, sites, subnets, and replication topology
  3) Counts identity objects: users, computers, groups, OUs, GPOs, service accounts
  4) Profiles FSMO role placement, schema version, functional levels
  5) Evaluates environment complexity across multiple dimensions
  6) Generates an HTML report with executive summary, topology map, and detail tables
  7) Optionally exports raw data as JSON for programmatic consumption

  The output helps infrastructure teams understand the scope, interdependencies,
  and operational complexity of their identity environment — critical inputs for
  disaster recovery planning, migration projects, and operational risk assessment.

QUICK START
  .\Get-ADIdentityAssessment.ps1

FULL RUN (includes stale object analysis and password policy audit)
  .\Get-ADIdentityAssessment.ps1 -Full

MULTI-FOREST (explicit list of forests to probe)
  .\Get-ADIdentityAssessment.ps1 -ForestNames "corp.contoso.com","partner.fabrikam.com"

REQUIREMENTS
  - Windows PowerShell 5.1+ or PowerShell 7+
  - ActiveDirectory module (RSAT) or connectivity to AD Web Services
  - Account with read access to AD (Domain Users is sufficient for most data)
  - For multi-forest: trust relationships or explicit credentials

NOTES
  - This script performs READ-ONLY operations. It makes zero changes to AD.
  - All queries use standard LDAP/ADWS — no schema extensions required.
  - Stale thresholds are configurable; defaults are industry-standard baselines.
  - Complexity scores are relative measures for comparison, not absolute ratings.

SECURITY
  - No credentials are stored or transmitted.
  - No data leaves the local machine.
  - Output folder can be restricted via NTFS ACLs as needed.

#>

[CmdletBinding(DefaultParameterSetName = 'Auto')]
param(
  # ===== Discovery Scope =====
  [Parameter(ParameterSetName='Manual')]
  [string[]]$ForestNames,                         # Explicit forest FQDNs to assess

  # ===== Run Level =====
  [switch]$Full,                                   # Include stale analysis, password policies, deeper metrics
  [switch]$IncludePrivilegedAudit,                 # Enumerate privileged group membership details

  # ===== Stale Object Thresholds (days) =====
  [ValidateRange(30, 730)][int]$StaleUserDays       = 90,
  [ValidateRange(30, 730)][int]$StaleComputerDays   = 90,

  # ===== Output =====
  [string]$OutFolder = ".\ADIdentityAssessment",
  [switch]$ExportJson,
  [switch]$ZipBundle,
  [switch]$SkipModuleCheck,

  # ===== Credential for cross-forest =====
  [PSCredential]$Credential
)

# ============================================================================
# GUARDRAILS
# ============================================================================
$ErrorActionPreference = "Stop"
$ProgressPreference    = 'SilentlyContinue'
$scriptVersion         = "1.0.0"
$scriptName            = "Get-ADIdentityAssessment"

if (-not $PSBoundParameters.ContainsKey('AutoDiscover') -and -not $PSBoundParameters.ContainsKey('ForestNames')) {
  $AutoDiscover = $true
}

# ============================================================================
# OUTPUT FOLDER
# ============================================================================
$stamp     = Get-Date -Format "yyyy-MM-dd_HHmm"
$runFolder = Join-Path $OutFolder "Run-$stamp"
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

$logPath = Join-Path $runFolder "AD-Assessment-Log-$stamp.txt"
$outHtml = Join-Path $runFolder "AD-Identity-Report-$stamp.html"
$outJson = Join-Path $runFolder "AD-Identity-Data-$stamp.json"

# ============================================================================
# LOGGING
# ============================================================================
function Write-Log {
  param([string]$Message, [ValidateSet('INFO','WARN','ERROR')]$Level = 'INFO')
  $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $line = "[$ts] [$Level] $Message"
  Add-Content -Path $logPath -Value $line
  switch ($Level) {
    'WARN'  { Write-Warning $Message }
    'ERROR' { Write-Host $Message -ForegroundColor Red }
    default { Write-Host $Message -ForegroundColor Cyan }
  }
}

# ============================================================================
# MODULE CHECK
# ============================================================================
function Assert-ADModule {
  if ($SkipModuleCheck) {
    Write-Log "Module check skipped by parameter." 'WARN'
    return
  }
  if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Log "ActiveDirectory module not found. Install RSAT: Active Directory module (on servers: Install-WindowsFeature RSAT-AD-PowerShell; on Windows 10/11 clients: Add-WindowsCapability -Online -Name RSAT.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0)." 'ERROR'
    throw "Required module 'ActiveDirectory' is not installed."
  }
  Import-Module ActiveDirectory -ErrorAction Stop
  Write-Log "ActiveDirectory module loaded successfully."
}

# ============================================================================
# HELPER: SAFE AD QUERIES (handle cross-forest failures gracefully)
# ============================================================================
function Invoke-ADQuery {
  param(
    [scriptblock]$Query,
    [string]$Server,
    [string]$Description = "AD query",
    $DefaultValue = $null
  )
  try {
    $params = @{}
    if ($Server)     { $params['Server']     = $Server }
    if ($Credential) { $params['Credential'] = $Credential }
    return & $Query @params
  }
  catch {
    Write-Log "$Description failed against ${Server}: $_" 'WARN'
    return $DefaultValue
  }
}

# ============================================================================
# PHASE 1: FOREST DISCOVERY
# ============================================================================
function Get-ForestTopology {
  param([string]$ForestName)

  Write-Log "Discovering forest: $ForestName"
  $forestObj = Invoke-ADQuery -Description "Get-ADForest $ForestName" -Server $ForestName -DefaultValue $null -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    Get-ADForest @p
  }

  if (-not $forestObj) {
    Write-Log "Cannot reach forest $ForestName — skipping." 'WARN'
    return $null
  }

  $topology = [ordered]@{
    ForestName           = $forestObj.Name
    ForestMode           = $forestObj.ForestMode.ToString()
    RootDomain           = $forestObj.RootDomain
    Domains              = @($forestObj.Domains)
    DomainCount          = $forestObj.Domains.Count
    GlobalCatalogs       = @($forestObj.GlobalCatalogs)
    GCCount              = $forestObj.GlobalCatalogs.Count
    Sites                = @($forestObj.Sites)
    SiteCount            = $forestObj.Sites.Count
    SchemaMaster         = $forestObj.SchemaMaster
    DomainNamingMaster   = $forestObj.DomainNamingMaster
    SPNSuffixes          = @($forestObj.SPNSuffixes)
    UPNSuffixes          = @($forestObj.UPNSuffixes)
    SchemaVersion        = $null
    DomainData           = @()
    Trusts               = @()
    SiteLinks            = @()
    Subnets              = @()
  }

  # Schema version
  $topology.SchemaVersion = Invoke-ADQuery -Description "Schema version" -Server $ForestName -DefaultValue "Unknown" -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    $schema = Get-ADObject (Get-ADRootDSE @p).schemaNamingContext -Property objectVersion @p
    $schema.objectVersion
  }

  # Site links
  $topology.SiteLinks = @(Invoke-ADQuery -Description "Site links" -Server $ForestName -DefaultValue @() -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    $configNC = (Get-ADRootDSE @p).configurationNamingContext
    Get-ADObject -Filter 'objectClass -eq "siteLink"' -SearchBase "CN=Sites,$configNC" -Property name,cost,replInterval,siteList @p |
      ForEach-Object {
        [ordered]@{
          Name            = $_.Name
          Cost            = $_.cost
          ReplIntervalMin = $_.replInterval
          SiteCount       = ($_.siteList | Measure-Object).Count
        }
      }
  })

  # Subnets
  $topology.Subnets = @(Invoke-ADQuery -Description "Subnets" -Server $ForestName -DefaultValue @() -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    $configNC = (Get-ADRootDSE @p).configurationNamingContext
    Get-ADObject -Filter 'objectClass -eq "subnet"' -SearchBase "CN=Subnets,CN=Sites,$configNC" -Property name,siteObject,location @p |
      ForEach-Object {
        [ordered]@{
          Subnet   = $_.Name
          Site     = if ($_.siteObject) { ($_.siteObject -split ',')[0] -replace 'CN=' } else { 'Unassigned' }
          Location = $_.location
        }
      }
  })

  # Per-domain enumeration
  foreach ($domainName in $forestObj.Domains) {
    $domainData = Get-DomainDetail -DomainName $domainName
    if ($domainData) {
      $topology.DomainData += $domainData
    }
  }

  # Cross-forest trusts (from root domain)
  $topology.Trusts = @(Invoke-ADQuery -Description "Forest trusts" -Server $ForestName -DefaultValue @() -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    Get-ADTrust -Filter * @p | ForEach-Object {
      [ordered]@{
        Source        = $_.Source
        Target        = $_.Target
        Direction     = $_.Direction.ToString()
        TrustType     = $_.TrustType.ToString()
        IsTransitive  = [bool]($_.ForestTransitive)
        IsIntraForest = $_.IntraForest
        SelectiveAuth = $_.SelectiveAuthentication
        SIDFiltering  = -not $_.SIDFilteringForestAware
      }
    }
  })

  return $topology
}

# ============================================================================
# PHASE 2: DOMAIN DETAIL
# ============================================================================
function Get-DomainDetail {
  param([string]$DomainName)

  Write-Log "  Enumerating domain: $DomainName"

  $domainObj = Invoke-ADQuery -Description "Get-ADDomain $DomainName" -Server $DomainName -DefaultValue $null -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    Get-ADDomain @p
  }

  if (-not $domainObj) { return $null }

  $dc = $domainObj.PDCEmulator  # Use PDC as preferred query target

  # ---------- Object counts (parallel-safe individual queries) ----------
  $userCount = Invoke-ADQuery -Description "User count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADUser -Filter 'Enabled -eq $true' @p | Measure-Object).Count
  }

  $disabledUserCount = Invoke-ADQuery -Description "Disabled user count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADUser -Filter 'Enabled -eq $false' @p | Measure-Object).Count
  }

  $computerCount = Invoke-ADQuery -Description "Computer count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADComputer -Filter 'Enabled -eq $true' @p | Measure-Object).Count
  }

  $groupCount = Invoke-ADQuery -Description "Group count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADGroup -Filter * @p | Measure-Object).Count
  }

  $ouCount = Invoke-ADQuery -Description "OU count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADOrganizationalUnit -Filter * @p | Measure-Object).Count
  }

  $gpoCount = Invoke-ADQuery -Description "GPO count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    # Try to use the GroupPolicy module (Get-GPO) when available; fall back to LDAP if not.
    if (Get-Command Get-GPO -ErrorAction SilentlyContinue) {
      try {
        (Get-GPO -All -Domain ($Server -replace ':.*') @p | Measure-Object).Count
      } catch {
        0
      }
    } else {
      0
    }
  }
  # GPO count via AD object if GroupPolicy module unavailable
  if ($gpoCount -eq 0) {
    $gpoCount = Invoke-ADQuery -Description "GPO count (LDAP)" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      $domDN = (Get-ADDomain @p).DistinguishedName
      (Get-ADObject -Filter 'objectClass -eq "groupPolicyContainer"' -SearchBase "CN=Policies,CN=System,$domDN" @p | Measure-Object).Count
    }
  }

  # Domain Controllers
  $domainControllers = @(Invoke-ADQuery -Description "Domain controllers" -Server $dc -DefaultValue @() -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    Get-ADDomainController -Filter * @p | ForEach-Object {
      [ordered]@{
        Name             = $_.Name
        IPv4Address      = $_.IPv4Address
        Site             = $_.Site
        IsGlobalCatalog  = $_.IsGlobalCatalog
        IsReadOnly       = $_.IsReadOnly
        OperatingSystem  = $_.OperatingSystem
        OSVersion        = $_.OperatingSystemVersion
        Roles            = @($_.OperationMasterRoles | ForEach-Object { $_.ToString() })
      }
    }
  })

  # Service accounts (MSA + gMSA)
  $msaCount = Invoke-ADQuery -Description "MSA/gMSA count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADServiceAccount -Filter * @p | Measure-Object).Count
  }

  # Fine-grained password policies
  $fgppCount = Invoke-ADQuery -Description "FGPP count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    (Get-ADFineGrainedPasswordPolicy -Filter * @p | Measure-Object).Count
  }

  # Intra-forest trusts for this domain
  $domainTrusts = @(Invoke-ADQuery -Description "Domain trusts" -Server $dc -DefaultValue @() -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    Get-ADTrust -Filter * @p | ForEach-Object {
      [ordered]@{
        Source       = $_.Source
        Target       = $_.Target
        Direction    = $_.Direction.ToString()
        TrustType    = $_.TrustType.ToString()
        IntraForest  = $_.IntraForest
      }
    }
  })

  # DNS zones (AD-integrated)
  $dnsZoneCount = Invoke-ADQuery -Description "DNS zone count" -Server $dc -DefaultValue 0 -Query {
    param($Server, $Credential)
    $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
    $domDN = (Get-ADDomain @p).DistinguishedName
    (Get-ADObject -Filter 'objectClass -eq "dnsZone"' -SearchBase "CN=MicrosoftDNS,DC=DomainDnsZones,$domDN" @p -ErrorAction SilentlyContinue | Measure-Object).Count
  }

  # ---------- Stale / hygiene analysis (Full mode only) ----------
  $staleUsers     = 0
  $staleComputers = 0
  $neverLoggedOn  = 0
  $pwdNeverExpire = 0
  $adminCount     = 0

  if ($Full) {
    Write-Log "  Running deep analysis for $DomainName (Full mode)"
    $staleCutoff = (Get-Date).AddDays(-$StaleUserDays)
    $staleCompCutoff = (Get-Date).AddDays(-$StaleComputerDays)

    $staleUsers = Invoke-ADQuery -Description "Stale users" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      $cutoff = $staleCutoff
      (Get-ADUser -Filter { Enabled -eq $true -and LastLogonDate -lt $cutoff } -Property LastLogonDate @p | Measure-Object).Count
    }

    $staleComputers = Invoke-ADQuery -Description "Stale computers" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      $cutoff = $staleCompCutoff
      (Get-ADComputer -Filter { Enabled -eq $true -and LastLogonDate -lt $cutoff } -Property LastLogonDate @p | Measure-Object).Count
    }

    $neverLoggedOn = Invoke-ADQuery -Description "Never logged on" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      (Get-ADUser -Filter { Enabled -eq $true -and LastLogonDate -notlike "*" } -Property LastLogonDate @p | Measure-Object).Count
    }

    $pwdNeverExpire = Invoke-ADQuery -Description "Password never expires" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      (Get-ADUser -Filter { Enabled -eq $true -and PasswordNeverExpires -eq $true } @p | Measure-Object).Count
    }

    $adminCount = Invoke-ADQuery -Description "AdminCount objects" -Server $dc -DefaultValue 0 -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      (Get-ADUser -Filter { AdminCount -eq 1 -and Enabled -eq $true } @p | Measure-Object).Count
    }
  }

  # ---------- Privileged group membership ----------
  $privilegedGroups = @()
  $knownPrivGroups  = @(
    'Domain Admins', 'Enterprise Admins', 'Schema Admins',
    'Administrators', 'Account Operators', 'Server Operators',
    'Backup Operators', 'Print Operators'
  )

  foreach ($grpName in $knownPrivGroups) {
    $members = Invoke-ADQuery -Description "Group: $grpName" -Server $dc -DefaultValue @() -Query {
      param($Server, $Credential)
      $p = @{}; if ($Server) { $p['Server'] = $Server }; if ($Credential) { $p['Credential'] = $Credential }
      try {
        @(Get-ADGroupMember -Identity $using:grpName -Recursive @p -ErrorAction SilentlyContinue)
      } catch { @() }
    }
    $privilegedGroups += [ordered]@{
      GroupName   = $grpName
      MemberCount = ($members | Measure-Object).Count
    }
  }

  # ---------- Assemble domain data ----------
  return [ordered]@{
    DomainName          = $domainObj.DNSRoot
    DomainNetBIOS       = $domainObj.NetBIOSName
    DomainMode          = $domainObj.DomainMode.ToString()
    DomainDN            = $domainObj.DistinguishedName
    PDCEmulator         = $domainObj.PDCEmulator
    RIDMaster           = $domainObj.RIDMaster
    InfrastructureMaster = $domainObj.InfrastructureMaster

    # Identity counts
    EnabledUsers        = $userCount
    DisabledUsers       = $disabledUserCount
    TotalUsers          = $userCount + $disabledUserCount
    EnabledComputers    = $computerCount
    Groups              = $groupCount
    OUs                 = $ouCount
    GPOs                = $gpoCount
    ServiceAccounts     = $msaCount
    FGPPs               = $fgppCount
    DNSZones            = $dnsZoneCount

    # Infrastructure
    DomainControllers   = $domainControllers
    DCCount             = $domainControllers.Count
    Trusts              = $domainTrusts
    TrustCount          = $domainTrusts.Count

    # Privileged access
    PrivilegedGroups    = $privilegedGroups
    TotalPrivilegedUsers = ($privilegedGroups | Measure-Object -Property MemberCount -Sum).Sum

    # Hygiene (Full mode)
    StaleUsers          = $staleUsers
    StaleComputers      = $staleComputers
    NeverLoggedOn       = $neverLoggedOn
    PwdNeverExpires     = $pwdNeverExpire
    AdminCountObjects   = $adminCount
  }
}

# ============================================================================
# PHASE 3: COMPLEXITY & RECOVERY RISK SCORING
# ============================================================================
function Get-EnvironmentComplexity {
  param($Forests)

  # Aggregate across all forests
  $totalDomains    = ($Forests | Measure-Object -Property DomainCount -Sum).Sum
  $totalSites      = ($Forests | Measure-Object -Property SiteCount -Sum).Sum
  $totalGCs        = ($Forests | Measure-Object -Property GCCount -Sum).Sum
  $allDomainData   = $Forests | ForEach-Object { $_.DomainData } | Where-Object { $_ }
  $totalUsers      = ($allDomainData | Measure-Object -Property EnabledUsers -Sum).Sum
  $totalComputers  = ($allDomainData | Measure-Object -Property EnabledComputers -Sum).Sum
  $totalDCs        = ($allDomainData | Measure-Object -Property DCCount -Sum).Sum
  $totalGPOs       = ($allDomainData | Measure-Object -Property GPOs -Sum).Sum
  $totalOUs        = ($allDomainData | Measure-Object -Property OUs -Sum).Sum
  $totalGroups     = ($allDomainData | Measure-Object -Property Groups -Sum).Sum
  $totalTrusts     = ($Forests | ForEach-Object { $_.Trusts } | Measure-Object).Count
  $totalSiteLinks  = ($Forests | ForEach-Object { $_.SiteLinks } | Measure-Object).Count
  $totalPrivUsers  = ($allDomainData | Measure-Object -Property TotalPrivilegedUsers -Sum).Sum
  $forestCount     = $Forests.Count

  # ---- Weighted scoring dimensions ----
  # Each dimension scored 0-100, then weighted

  $scores = [ordered]@{}

  # 1. Forest complexity (multi-forest = exponential complexity for recovery)
  $scores['ForestTopology'] = [ordered]@{
    Weight      = 20
    Description = "Number of forests, domains, and trust relationships"
    RawInputs   = "Forests=$forestCount, Domains=$totalDomains, Trusts=$totalTrusts"
    Score       = [math]::Min(100, ($forestCount * 25) + ($totalDomains * 10) + ($totalTrusts * 8))
  }

  # 2. Identity scale
  $userScale = switch ($true) {
    ($totalUsers -gt 50000) { 90 }
    ($totalUsers -gt 20000) { 70 }
    ($totalUsers -gt 5000)  { 50 }
    ($totalUsers -gt 1000)  { 30 }
    default                 { 15 }
  }
  $scores['IdentityScale'] = [ordered]@{
    Weight      = 15
    Description = "Total enabled users, computers, and service accounts"
    RawInputs   = "Users=$totalUsers, Computers=$totalComputers"
    Score       = $userScale
  }

  # 3. Replication topology (sites, site links, subnets)
  $topoScore = [math]::Min(100, ($totalSites * 5) + ($totalSiteLinks * 3))
  $scores['ReplicationTopology'] = [ordered]@{
    Weight      = 15
    Description = "AD sites, site links, and replication paths"
    RawInputs   = "Sites=$totalSites, SiteLinks=$totalSiteLinks"
    Score       = $topoScore
  }

  # 4. FSMO / DC distribution
  $dcScore = [math]::Min(100, ($totalDCs * 4) + ($totalGCs * 3))
  $scores['DCInfrastructure'] = [ordered]@{
    Weight      = 15
    Description = "Domain controller count, FSMO placement, GC distribution"
    RawInputs   = "DCs=$totalDCs, GCs=$totalGCs"
    Score       = $dcScore
  }

  # 5. Group Policy complexity
  $gpoScore = switch ($true) {
    ($totalGPOs -gt 500) { 95 }
    ($totalGPOs -gt 200) { 75 }
    ($totalGPOs -gt 100) { 55 }
    ($totalGPOs -gt 30)  { 35 }
    default              { 15 }
  }
  $scores['GroupPolicy'] = [ordered]@{
    Weight      = 10
    Description = "GPO count and OU structure depth"
    RawInputs   = "GPOs=$totalGPOs, OUs=$totalOUs"
    Score       = $gpoScore
  }

  # 6. Privileged access surface
  $privScore = switch ($true) {
    ($totalPrivUsers -gt 100) { 90 }
    ($totalPrivUsers -gt 50)  { 70 }
    ($totalPrivUsers -gt 20)  { 45 }
    default                   { 20 }
  }
  $scores['PrivilegedAccess'] = [ordered]@{
    Weight      = 15
    Description = "Privileged group membership breadth"
    RawInputs   = "PrivilegedUsers=$totalPrivUsers"
    Score       = $privScore
  }

  # 7. Dependency sprawl (DNS zones, service accounts, UPN suffixes)
  $totalMSAs   = ($allDomainData | Measure-Object -Property ServiceAccounts -Sum).Sum
  $totalUPNs   = ($Forests | ForEach-Object { $_.UPNSuffixes } | Measure-Object).Count
  $dnsZones    = ($allDomainData | Measure-Object -Property DNSZones -Sum).Sum
  $depScore    = [math]::Min(100, ($totalMSAs * 3) + ($totalUPNs * 5) + ($dnsZones * 2))
  $scores['ServiceDependencies'] = [ordered]@{
    Weight      = 10
    Description = "Service accounts, UPN suffixes, AD-integrated DNS zones"
    RawInputs   = "MSAs=$totalMSAs, UPNs=$totalUPNs, DNSZones=$dnsZones"
    Score       = $depScore
  }

  # ---- Composite score ----
  $weightedSum   = 0
  $totalWeight   = 0
  foreach ($dim in $scores.Keys) {
    $weightedSum += $scores[$dim].Score * $scores[$dim].Weight
    $totalWeight += $scores[$dim].Weight
  }
  $compositeScore = [math]::Round($weightedSum / $totalWeight, 1)

  # ---- Recovery impact tier ----
  $tier = switch ($true) {
    ($compositeScore -ge 75) { "Critical" }
    ($compositeScore -ge 50) { "High" }
    ($compositeScore -ge 30) { "Moderate" }
    default                  { "Standard" }
  }

  # ---- Estimated manual recovery considerations ----
  $recoveryConsiderations = @()

  if ($forestCount -gt 1) {
    $recoveryConsiderations += "Multi-forest topology requires coordinated recovery sequencing across $forestCount forests with independent schema and configuration partitions."
  }
  if ($totalTrusts -gt 0) {
    $recoveryConsiderations += "$totalTrusts trust relationship(s) must be re-established in correct order post-recovery to restore cross-domain/forest authentication."
  }
  if ($totalDomains -gt 1) {
    $recoveryConsiderations += "$totalDomains domains require domain-level recovery with FSMO role seizure/transfer decisions per domain."
  }
  if ($totalSites -gt 5) {
    $recoveryConsiderations += "$totalSites AD sites with $totalSiteLinks site link(s) — replication topology rebuild requires precise configuration to avoid lingering objects."
  }
  if ($totalDCs -gt 10) {
    $recoveryConsiderations += "$totalDCs domain controllers — each must be recovered or rebuilt with correct NTDS settings; DC recovery order matters."
  }
  if ($totalGPOs -gt 100) {
    $recoveryConsiderations += "$totalGPOs Group Policy Objects — GPO GUID-to-link mappings must be preserved to maintain security posture post-recovery."
  }
  if ($totalPrivUsers -gt 50) {
    $recoveryConsiderations += "$totalPrivUsers privileged accounts — Tier-0 identity recovery verification is critical for security baseline restoration."
  }
  if ($totalUsers -gt 10000) {
    $recoveryConsiderations += "${totalUsers} user objects — large-scale identity re-authentication post-recovery requires careful DNS and DC placement."
  }
  if ($totalMSAs -gt 0) {
    $recoveryConsiderations += "$totalMSAs managed service account(s) — application dependencies on gMSA/MSA key distribution require KDS root key availability."
  }
  $fgpps = ($allDomainData | Measure-Object -Property FGPPs -Sum).Sum
  if ($fgpps -gt 0) {
    $recoveryConsiderations += "$fgpps fine-grained password policies — must be verified post-recovery to maintain compliance posture."
  }

  return [ordered]@{
    CompositeScore           = $compositeScore
    Tier                     = $tier
    Dimensions               = $scores
    Totals                   = [ordered]@{
      Forests            = $forestCount
      Domains            = $totalDomains
      Sites              = $totalSites
      SiteLinks          = $totalSiteLinks
      DomainControllers  = $totalDCs
      GlobalCatalogs     = $totalGCs
      Trusts             = $totalTrusts
      EnabledUsers       = $totalUsers
      EnabledComputers   = $totalComputers
      Groups             = $totalGroups
      OUs                = $totalOUs
      GPOs               = $totalGPOs
      ServiceAccounts    = $totalMSAs
      PrivilegedUsers    = $totalPrivUsers
    }
    RecoveryConsiderations  = $recoveryConsiderations
  }
}

# ============================================================================
# PHASE 4: HTML REPORT GENERATION
# ============================================================================
function New-HtmlReport {
  param($Forests, $Complexity, [string]$OutputPath)

  $t = $Complexity.Totals
  $generated = Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"

  # Schema version friendly name
  $schemaMap = @{
    87  = "Windows Server 2016"
    88  = "Windows Server 2019"
    89  = "Windows Server 2022"
    90  = "Windows Server 2025"
  }

  # ---- Build score dimensions table rows ----
  $dimRows = ""
  foreach ($key in $Complexity.Dimensions.Keys) {
    $d = $Complexity.Dimensions[$key]
    $barColor = switch ($true) {
      ($d.Score -ge 75) { "#e74c3c" }
      ($d.Score -ge 50) { "#f39c12" }
      ($d.Score -ge 30) { "#3498db" }
      default           { "#2ecc71" }
    }
    $dimRows += @"
      <tr>
        <td><strong>$key</strong></td>
        <td>$($d.Description)</td>
        <td>$($d.RawInputs)</td>
        <td style="text-align:center;">$($d.Weight)%</td>
        <td style="min-width:180px;">
          <div style="background:#ecf0f1;border-radius:4px;overflow:hidden;height:22px;position:relative;">
            <div style="background:${barColor};width:$($d.Score)%;height:100%;"></div>
            <span style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);font-weight:600;font-size:12px;">$($d.Score)</span>
          </div>
        </td>
      </tr>
"@
  }

  # ---- Build forest detail sections ----
  $forestSections = ""
  foreach ($f in $Forests) {
    $schemaFriendly = if ($schemaMap.ContainsKey([int]$f.SchemaVersion)) {
      "$($f.SchemaVersion) ($($schemaMap[[int]$f.SchemaVersion]))"
    } else { $f.SchemaVersion }

    $forestSections += @"
    <div class="section">
      <h2>Forest: $($f.ForestName)</h2>
      <table>
        <tr><td style="width:250px;"><strong>Forest Functional Level</strong></td><td>$($f.ForestMode)</td></tr>
        <tr><td><strong>Root Domain</strong></td><td>$($f.RootDomain)</td></tr>
        <tr><td><strong>Schema Version</strong></td><td>$schemaFriendly</td></tr>
        <tr><td><strong>Domains</strong></td><td>$($f.DomainCount) — $($f.Domains -join ', ')</td></tr>
        <tr><td><strong>Sites</strong></td><td>$($f.SiteCount) — $($f.Sites -join ', ')</td></tr>
        <tr><td><strong>Global Catalogs</strong></td><td>$($f.GCCount)</td></tr>
        <tr><td><strong>Schema Master</strong></td><td>$($f.SchemaMaster)</td></tr>
        <tr><td><strong>Domain Naming Master</strong></td><td>$($f.DomainNamingMaster)</td></tr>
        <tr><td><strong>UPN Suffixes</strong></td><td>$(if ($f.UPNSuffixes.Count -gt 0) { $f.UPNSuffixes -join ', ' } else { '(default only)' })</td></tr>
      </table>
"@

    # Trust table
    if ($f.Trusts.Count -gt 0) {
      $forestSections += @"
      <h3>Trust Relationships</h3>
      <table>
        <tr><th>Source</th><th>Target</th><th>Direction</th><th>Type</th><th>Transitive</th><th>Selective Auth</th></tr>
"@
      foreach ($trust in $f.Trusts) {
        $forestSections += "        <tr><td>$($trust.Source)</td><td>$($trust.Target)</td><td>$($trust.Direction)</td><td>$($trust.TrustType)</td><td>$($trust.IsTransitive)</td><td>$($trust.SelectiveAuth)</td></tr>`n"
      }
      $forestSections += "      </table>`n"
    }

    # Site links
    if ($f.SiteLinks.Count -gt 0) {
      $forestSections += @"
      <h3>Site Links</h3>
      <table>
        <tr><th>Name</th><th>Cost</th><th>Replication Interval (min)</th><th>Connected Sites</th></tr>
"@
      foreach ($sl in $f.SiteLinks) {
        $forestSections += "        <tr><td>$($sl.Name)</td><td>$($sl.Cost)</td><td>$($sl.ReplIntervalMin)</td><td>$($sl.SiteCount)</td></tr>`n"
      }
      $forestSections += "      </table>`n"
    }

    # Subnets
    if ($f.Subnets.Count -gt 0) {
      $forestSections += @"
      <h3>AD Subnets</h3>
      <table>
        <tr><th>Subnet</th><th>Site</th><th>Location</th></tr>
"@
      foreach ($sn in $f.Subnets) {
        $forestSections += "        <tr><td>$($sn.Subnet)</td><td>$($sn.Site)</td><td>$($sn.Location)</td></tr>`n"
      }
      $forestSections += "      </table>`n"
    }

    # Per-domain details
    foreach ($dom in $f.DomainData) {
      $forestSections += @"
      <div class="domain-detail">
        <h3>Domain: $($dom.DomainName)</h3>
        <div class="metric-grid">
          <div class="metric-card">
            <div class="metric-value">$($dom.EnabledUsers)</div>
            <div class="metric-label">Enabled Users</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.DisabledUsers)</div>
            <div class="metric-label">Disabled Users</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.EnabledComputers)</div>
            <div class="metric-label">Computers</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.Groups)</div>
            <div class="metric-label">Groups</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.OUs)</div>
            <div class="metric-label">OUs</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.GPOs)</div>
            <div class="metric-label">GPOs</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.ServiceAccounts)</div>
            <div class="metric-label">Service Accounts</div>
          </div>
          <div class="metric-card">
            <div class="metric-value">$($dom.DCCount)</div>
            <div class="metric-label">Domain Controllers</div>
          </div>
        </div>

        <table>
          <tr><td style="width:250px;"><strong>Domain Functional Level</strong></td><td>$($dom.DomainMode)</td></tr>
          <tr><td><strong>NetBIOS Name</strong></td><td>$($dom.DomainNetBIOS)</td></tr>
          <tr><td><strong>PDC Emulator</strong></td><td>$($dom.PDCEmulator)</td></tr>
          <tr><td><strong>RID Master</strong></td><td>$($dom.RIDMaster)</td></tr>
          <tr><td><strong>Infrastructure Master</strong></td><td>$($dom.InfrastructureMaster)</td></tr>
          <tr><td><strong>Fine-Grained Password Policies</strong></td><td>$($dom.FGPPs)</td></tr>
          <tr><td><strong>AD-Integrated DNS Zones</strong></td><td>$($dom.DNSZones)</td></tr>
        </table>
"@

      # DC table
      if ($dom.DomainControllers.Count -gt 0) {
        $forestSections += @"
        <h4>Domain Controllers</h4>
        <table>
          <tr><th>Name</th><th>IP</th><th>Site</th><th>OS</th><th>GC</th><th>RODC</th><th>FSMO Roles</th></tr>
"@
        foreach ($dcInfo in $dom.DomainControllers) {
          $roles = if ($dcInfo.Roles.Count -gt 0) { $dcInfo.Roles -join ', ' } else { '-' }
          $forestSections += "          <tr><td>$($dcInfo.Name)</td><td>$($dcInfo.IPv4Address)</td><td>$($dcInfo.Site)</td><td>$($dcInfo.OperatingSystem)</td><td>$($dcInfo.IsGlobalCatalog)</td><td>$($dcInfo.IsReadOnly)</td><td>$roles</td></tr>`n"
        }
        $forestSections += "        </table>`n"
      }

      # Privileged groups
      if ($dom.PrivilegedGroups.Count -gt 0) {
        $forestSections += @"
        <h4>Privileged Group Membership</h4>
        <table>
          <tr><th>Group</th><th>Members (Recursive)</th><th>Risk</th></tr>
"@
        foreach ($pg in $dom.PrivilegedGroups) {
          $risk = switch ($true) {
            ($pg.MemberCount -gt 25) { '<span style="color:#e74c3c;font-weight:700;">HIGH</span>' }
            ($pg.MemberCount -gt 10) { '<span style="color:#f39c12;font-weight:700;">ELEVATED</span>' }
            ($pg.MemberCount -gt 0)  { '<span style="color:#3498db;">NORMAL</span>' }
            default                  { '<span style="color:#95a5a6;">EMPTY</span>' }
          }
          $forestSections += "          <tr><td>$($pg.GroupName)</td><td style='text-align:center;'>$($pg.MemberCount)</td><td style='text-align:center;'>$risk</td></tr>`n"
        }
        $forestSections += "        </table>`n"
      }

      # Hygiene metrics (Full mode)
      if ($Full) {
        $forestSections += @"
        <h4>Identity Hygiene Indicators</h4>
        <table>
          <tr><th>Indicator</th><th>Count</th><th>Threshold</th><th>Assessment</th></tr>
          <tr><td>Stale Users (no logon in $StaleUserDays days)</td><td>$($dom.StaleUsers)</td><td>$StaleUserDays days</td><td>$(if ($dom.StaleUsers -gt ($dom.EnabledUsers * 0.1)) { '<span style="color:#e74c3c;">Review Recommended</span>' } else { '<span style="color:#2ecc71;">Acceptable</span>' })</td></tr>
          <tr><td>Stale Computers (no logon in $StaleComputerDays days)</td><td>$($dom.StaleComputers)</td><td>$StaleComputerDays days</td><td>$(if ($dom.StaleComputers -gt ($dom.EnabledComputers * 0.1)) { '<span style="color:#e74c3c;">Review Recommended</span>' } else { '<span style="color:#2ecc71;">Acceptable</span>' })</td></tr>
          <tr><td>Never Logged On (enabled)</td><td>$($dom.NeverLoggedOn)</td><td>-</td><td>$(if ($dom.NeverLoggedOn -gt 50) { '<span style="color:#f39c12;">Investigate</span>' } else { '<span style="color:#2ecc71;">Acceptable</span>' })</td></tr>
          <tr><td>Password Never Expires</td><td>$($dom.PwdNeverExpires)</td><td>-</td><td>$(if ($dom.PwdNeverExpires -gt 20) { '<span style="color:#e74c3c;">Security Risk</span>' } else { '<span style="color:#2ecc71;">Acceptable</span>' })</td></tr>
          <tr><td>AdminCount = 1 (orphaned SDProp)</td><td>$($dom.AdminCountObjects)</td><td>-</td><td>$(if ($dom.AdminCountObjects -gt $dom.TotalPrivilegedUsers) { '<span style="color:#f39c12;">Stale AdminCount Flags</span>' } else { '<span style="color:#2ecc71;">Consistent</span>' })</td></tr>
        </table>
"@
      }

      $forestSections += "      </div>`n"  # close domain-detail
    }

    $forestSections += "    </div>`n"  # close forest section
  }

  # ---- Recovery considerations list ----
  $recoveryHtml = ""
  if ($Complexity.RecoveryConsiderations.Count -gt 0) {
    $recoveryHtml = "<div class='section'><h2>Operational Recovery Considerations</h2><p>Based on the environment topology and scale, the following factors contribute to recovery complexity in a full identity infrastructure loss scenario:</p><ul>`n"
    foreach ($item in $Complexity.RecoveryConsiderations) {
      $recoveryHtml += "        <li>$item</li>`n"
    }
    $recoveryHtml += "      </ul>"

    # Tier-specific advisory
    $advisoryText = switch ($Complexity.Tier) {
      "Critical" {
        "This environment exhibits <strong>critical complexity</strong> across multiple dimensions. Manual forest recovery procedures for an environment of this scale and interdependency would require extensive coordination, precise sequencing, and significant elapsed time. The risk of configuration drift, missed dependencies, or incomplete restoration is elevated. Organizations with similar profiles typically prioritize <strong>automated, orchestrated recovery capabilities</strong> that can execute validated recovery runbooks with deterministic outcomes."
      }
      "High" {
        "This environment has <strong>significant complexity</strong> with multiple domains, trust relationships, or distributed infrastructure. Manual recovery procedures are feasible but carry meaningful risk of human error and extended downtime. The number of interdependent components increases the probability that a manual process will miss a dependency or sequence step incorrectly. <strong>Structured, repeatable recovery processes</strong> — ideally with automation — significantly reduce both risk and recovery time."
      }
      "Moderate" {
        "This environment has <strong>moderate complexity</strong>. While manual recovery procedures may be manageable, the combination of identity objects, Group Policy, and infrastructure components means that recovery is not a trivial exercise. Having <strong>documented, tested recovery procedures</strong> and considering automation for key steps would materially reduce recovery risk."
      }
      "Standard" {
        "This environment has a <strong>relatively straightforward</strong> identity topology. Recovery procedures are less complex but should still be documented, tested, and validated regularly. Even simple environments benefit from <strong>consistent, repeatable recovery processes</strong> to minimize human error under pressure."
      }
    }
    $recoveryHtml += "      <div class='advisory-box tier-$($Complexity.Tier.ToLower())'><p>$advisoryText</p></div></div>"
  }

  # ---- Tier color and badge ----
  $tierColor = switch ($Complexity.Tier) {
    "Critical" { "#e74c3c" }
    "High"     { "#f39c12" }
    "Moderate" { "#3498db" }
    default    { "#2ecc71" }
  }

  # ---- Assemble full HTML ----
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Active Directory Identity Structure Assessment</title>
  <style>
    :root { --primary: #1a252f; --accent: #005f4b; --bg: #f7f8fa; --card: #ffffff; --border: #e1e4e8; }
    * { margin:0; padding:0; box-sizing:border-box; }
    body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background:var(--bg); color:#2c3e50; line-height:1.5; }
    .container { max-width:1200px; margin:0 auto; padding:24px; }

    .header { background:linear-gradient(135deg, var(--primary) 0%, #2c3e50 100%); color:#fff; padding:40px; border-radius:12px; margin-bottom:24px; }
    .header h1 { font-size:28px; font-weight:700; margin-bottom:8px; }
    .header .subtitle { font-size:15px; opacity:0.85; }
    .header .meta { margin-top:16px; font-size:13px; opacity:0.7; }

    .score-banner { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:32px; margin-bottom:24px; display:flex; align-items:center; gap:32px; flex-wrap:wrap; }
    .score-circle { width:120px; height:120px; border-radius:50%; display:flex; flex-direction:column; align-items:center; justify-content:center; color:#fff; font-size:32px; font-weight:800; flex-shrink:0; }
    .score-circle .label { font-size:11px; font-weight:400; text-transform:uppercase; letter-spacing:1px; margin-top:2px; }
    .score-details { flex:1; min-width:300px; }
    .score-details h2 { font-size:20px; margin-bottom:8px; }

    .summary-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(140px,1fr)); gap:12px; margin-top:16px; }
    .summary-item { text-align:center; padding:12px; background:var(--bg); border-radius:8px; }
    .summary-item .val { font-size:22px; font-weight:700; color:var(--primary); }
    .summary-item .lbl { font-size:11px; color:#7f8c8d; text-transform:uppercase; letter-spacing:0.5px; }

    .section { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:24px; margin-bottom:24px; }
    .section h2 { font-size:20px; margin-bottom:16px; padding-bottom:8px; border-bottom:2px solid var(--border); }
    .section h3 { font-size:17px; margin:20px 0 10px; color:var(--primary); }
    .section h4 { font-size:15px; margin:16px 0 8px; color:#34495e; }

    table { width:100%; border-collapse:collapse; margin-bottom:16px; font-size:13px; }
    th, td { padding:8px 12px; text-align:left; border-bottom:1px solid var(--border); }
    th { background:var(--bg); font-weight:600; color:var(--primary); position:sticky; top:0; }
    tr:hover td { background:#f0f3f5; }

    .metric-grid { display:grid; grid-template-columns:repeat(auto-fit, minmax(130px, 1fr)); gap:12px; margin-bottom:16px; }
    .metric-card { background:var(--bg); border-radius:8px; padding:16px; text-align:center; }
    .metric-value { font-size:24px; font-weight:700; color:var(--primary); }
    .metric-label { font-size:11px; color:#7f8c8d; text-transform:uppercase; margin-top:4px; }

    .domain-detail { margin:16px 0; padding:16px; border:1px solid var(--border); border-radius:8px; background:#fafbfc; }

    .advisory-box { margin-top:20px; padding:20px; border-radius:8px; border-left:4px solid; }
    .tier-critical { background:#fef5f5; border-color:#e74c3c; }
    .tier-high { background:#fef9f0; border-color:#f39c12; }
    .tier-moderate { background:#f0f7ff; border-color:#3498db; }
    .tier-standard { background:#f0faf5; border-color:#2ecc71; }

    .footer { text-align:center; color:#95a5a6; font-size:12px; margin-top:24px; padding:16px; }

    @media print {
      body { background:#fff; }
      .container { max-width:100%; padding:0; }
      .section, .score-banner { break-inside:avoid; box-shadow:none; }
    }
  </style>
</head>
<body>
<div class="container">

  <div class="header">
    <h1>Active Directory Identity Structure Assessment</h1>
    <div class="subtitle">Comprehensive analysis of on-premises identity topology, scale, and operational complexity</div>
    <div class="meta">Generated: $generated &nbsp;|&nbsp; Script: $scriptName v$scriptVersion &nbsp;|&nbsp; Mode: $(if ($Full) { 'Full' } else { 'Standard' })</div>
  </div>

  <!-- EXECUTIVE SCORE -->
  <div class="score-banner">
    <div class="score-circle" style="background:${tierColor};">
      $($Complexity.CompositeScore)
      <span class="label">$($Complexity.Tier)</span>
    </div>
    <div class="score-details">
      <h2>Environment Complexity Score</h2>
      <p style="color:#7f8c8d;font-size:14px;">Weighted assessment across topology, scale, replication, policy, privileged access, and service dependencies. Higher scores indicate greater interdependency and recovery coordination requirements.</p>
      <div class="summary-grid">
        <div class="summary-item"><div class="val">$($t.Forests)</div><div class="lbl">Forests</div></div>
        <div class="summary-item"><div class="val">$($t.Domains)</div><div class="lbl">Domains</div></div>
        <div class="summary-item"><div class="val">$($t.DomainControllers)</div><div class="lbl">Domain Controllers</div></div>
        <div class="summary-item"><div class="val">$($t.Sites)</div><div class="lbl">Sites</div></div>
        <div class="summary-item"><div class="val">$($t.Trusts)</div><div class="lbl">Trusts</div></div>
        <div class="summary-item"><div class="val">$([string]::Format("{0:N0}", $t.EnabledUsers))</div><div class="lbl">Users</div></div>
        <div class="summary-item"><div class="val">$([string]::Format("{0:N0}", $t.EnabledComputers))</div><div class="lbl">Computers</div></div>
        <div class="summary-item"><div class="val">$($t.GPOs)</div><div class="lbl">GPOs</div></div>
      </div>
    </div>
  </div>

  <!-- COMPLEXITY DIMENSIONS -->
  <div class="section">
    <h2>Complexity Dimensions</h2>
    <p style="color:#7f8c8d;margin-bottom:16px;font-size:14px;">Each dimension is scored 0–100 and weighted by its impact on operational and recovery complexity.</p>
    <table>
      <tr><th>Dimension</th><th>Description</th><th>Inputs</th><th>Weight</th><th>Score</th></tr>
      $dimRows
    </table>
  </div>

  <!-- FOREST DETAILS -->
  $forestSections

  <!-- RECOVERY CONSIDERATIONS -->
  $recoveryHtml

  <div class="footer">
    Active Directory Identity Structure Assessment &mdash; $scriptName v$scriptVersion &mdash; Generated $generated<br>
    This report contains read-only analysis. No changes were made to Active Directory.
  </div>

</div>
</body>
</html>
"@

  $html | Out-File -FilePath $OutputPath -Encoding UTF8
  Write-Log "HTML report written to: $OutputPath"
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================
function Main {
  $sw = [System.Diagnostics.Stopwatch]::StartNew()

  Write-Log "============================================="
  Write-Log "$scriptName v$scriptVersion — starting"
  Write-Log "Run mode: $(if ($Full) { 'Full' } else { 'Standard' })"
  Write-Log "============================================="

  # Step 1: Module check
  Assert-ADModule

  # Step 2: Determine forests to assess
  $forestList = @()
  if ($ForestNames) {
    $forestList = $ForestNames
    Write-Log "Manual forest list: $($forestList -join ', ')"
  }
  else {
    Write-Log "Auto-discovering forest from current domain context..."
    $currentForest = Invoke-ADQuery -Description "Current forest" -DefaultValue $null -Query {
      param($Server, $Credential)
      $p = @{}; if ($Credential) { $p['Credential'] = $Credential }
      (Get-ADForest @p).Name
    }
    if (-not $currentForest) {
      throw "Cannot determine current forest. Ensure this machine is domain-joined or use -ForestNames."
    }
    $forestList = @($currentForest)

    # Discover trusted forests
    $trustedForests = @(Invoke-ADQuery -Description "Trusted forests" -DefaultValue @() -Query {
      param($Server, $Credential)
      $p = @{}; if ($Credential) { $p['Credential'] = $Credential }
      Get-ADTrust -Filter { ForestTransitive -eq $true } @p | Select-Object -ExpandProperty Target
    })
    if ($trustedForests.Count -gt 0) {
      Write-Log "Discovered $($trustedForests.Count) trusted forest(s): $($trustedForests -join ', ')"
      $forestList += $trustedForests
    }
  }

  # Step 3: Enumerate each forest
  $allForests = @()
  foreach ($forestName in $forestList) {
    $forestData = Get-ForestTopology -ForestName $forestName
    if ($forestData) {
      $allForests += $forestData
    }
  }

  if ($allForests.Count -eq 0) {
    Write-Log "No forests could be enumerated. Exiting." 'ERROR'
    throw "No AD forests reachable. Check connectivity and permissions."
  }

  Write-Log "Enumerated $($allForests.Count) forest(s) successfully."

  # Step 4: Calculate complexity
  Write-Log "Calculating environment complexity scores..."
  $complexity = Get-EnvironmentComplexity -Forests $allForests

  Write-Log "Composite Score: $($complexity.CompositeScore) — Tier: $($complexity.Tier)"

  # Step 5: Generate report
  Write-Log "Generating HTML report..."
  New-HtmlReport -Forests $allForests -Complexity $complexity -OutputPath $outHtml

  # Step 6: JSON export (optional)
  if ($ExportJson) {
    $jsonPayload = [ordered]@{
      ScriptVersion  = $scriptVersion
      GeneratedAt    = (Get-Date -Format "o")
      RunMode        = if ($Full) { 'Full' } else { 'Standard' }
      Complexity     = $complexity
      Forests        = $allForests
    }
    $jsonPayload | ConvertTo-Json -Depth 10 | Out-File -FilePath $outJson -Encoding UTF8
    Write-Log "JSON data written to: $outJson"
  }

  # Step 7: Zip bundle (optional)
  if ($ZipBundle) {
    $zipPath = "$runFolder.zip"
    try {
      Compress-Archive -Path "$runFolder\*" -DestinationPath $zipPath -Force
      Write-Log "Zip bundle: $zipPath"
    }
    catch {
      Write-Log "Zip creation failed: $_" 'WARN'
    }
  }

  # Step 8: Summary to console
  $sw.Stop()
  $elapsed = $sw.Elapsed.ToString("mm\:ss")

  Write-Host ""
  Write-Host "======================================================" -ForegroundColor Green
  Write-Host " AD Identity Structure Assessment Complete" -ForegroundColor Green
  Write-Host "======================================================" -ForegroundColor Green
  Write-Host ""
  Write-Host "  Forests assessed      : $($allForests.Count)" -ForegroundColor White
  Write-Host "  Total domains         : $($complexity.Totals.Domains)" -ForegroundColor White
  Write-Host "  Total users (enabled) : $([string]::Format('{0:N0}', $complexity.Totals.EnabledUsers))" -ForegroundColor White
  Write-Host "  Total computers       : $([string]::Format('{0:N0}', $complexity.Totals.EnabledComputers))" -ForegroundColor White
  Write-Host "  Domain controllers    : $($complexity.Totals.DomainControllers)" -ForegroundColor White
  Write-Host "  GPOs                  : $($complexity.Totals.GPOs)" -ForegroundColor White
  Write-Host "  Trusts                : $($complexity.Totals.Trusts)" -ForegroundColor White
  Write-Host ""
  Write-Host "  Complexity Score      : $($complexity.CompositeScore) / 100" -ForegroundColor Yellow
  Write-Host "  Complexity Tier       : $($complexity.Tier)" -ForegroundColor $( switch($complexity.Tier) { 'Critical' {'Red'} 'High' {'Yellow'} 'Moderate' {'Cyan'} default {'Green'} })
  Write-Host ""
  Write-Host "  Report : $outHtml" -ForegroundColor Gray
  Write-Host "  Log    : $logPath" -ForegroundColor Gray
  if ($ExportJson) { Write-Host "  JSON   : $outJson" -ForegroundColor Gray }
  Write-Host "  Elapsed: $elapsed" -ForegroundColor Gray
  Write-Host ""

  # Return object for pipeline use
  return [PSCustomObject]@{
    Forests        = $allForests
    Complexity     = $complexity
    ReportPath     = $outHtml
    LogPath        = $logPath
    JsonPath       = if ($ExportJson) { $outJson } else { $null }
  }
}

# ---- Entry point ----
Main
