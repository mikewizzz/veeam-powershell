<#
.SYNOPSIS
  Veeam Backup & Replication v13 Infrastructure Diagram Generator

.DESCRIPTION
  Connects to the Veeam Backup & Replication v13 REST API and discovers the complete
  backup infrastructure topology. Generates a draw.io (.drawio) diagram showing:

  - Backup server (central hub)
  - Managed servers (vCenter, Hyper-V, SCVMM, physical hosts)
  - Backup proxies (VMware, Hyper-V, Agent)
  - Backup repositories (standard, hardened, object storage)
  - Scale-out backup repositories (SOBR) with performance and capacity extents
  - WAN accelerators
  - Backup jobs and their target repositories
  - Job-to-proxy assignments

  The diagram uses proper Veeam iconography and auto-layout for immediate use
  in architecture documentation and presales deliverables.

.PARAMETER Server
  Hostname or IP address of the Veeam Backup & Replication server.

.PARAMETER Port
  REST API port. Default: 9419.

.PARAMETER Credential
  PSCredential object for authentication. If not provided, prompts interactively.

.PARAMETER Username
  Username for authentication (alternative to -Credential).

.PARAMETER Password
  Password as SecureString (alternative to -Credential).

.PARAMETER SkipCertificateCheck
  Skip TLS certificate validation for self-signed certificates.

.PARAMETER IncludeJobs
  Include backup jobs and their relationships in the diagram.

.PARAMETER IncludeJobSessions
  Include recent job session status indicators (last run result).

.PARAMETER OutFolder
  Output folder for generated files. Default: current directory with timestamp.

.PARAMETER ExportJson
  Also export the raw infrastructure data as a JSON bundle.

.PARAMETER DiagramLayout
  Diagram layout style. Default: Hierarchical.

.PARAMETER ZipBundle
  Compress all outputs into a ZIP archive.

.EXAMPLE
  .\Get-VeeamDiagram.ps1 -Server "vbr01.contoso.com"
  Connects interactively and generates a diagram.

.EXAMPLE
  .\Get-VeeamDiagram.ps1 -Server "vbr01" -Credential (Get-Credential) -IncludeJobs
  Connects with pre-built credentials and includes job mappings.

.EXAMPLE
  $cred = New-Object PSCredential("admin", (ConvertTo-SecureString "P@ss" -AsPlainText -Force))
  .\Get-VeeamDiagram.ps1 -Server "10.0.0.5" -Credential $cred -SkipCertificateCheck -IncludeJobs -ExportJson
  Full discovery with self-signed cert, jobs, and JSON export.

.NOTES
  Author:  Veeam Sales Engineering
  Version: 1.0.0
  Date:    2026-02-14
  Requires: PowerShell 7.x or 5.1
  API:     Veeam B&R v13 REST API (v1, x-api-version 1.3-rev1)
  No external module dependencies — uses Invoke-RestMethod directly.
#>

[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
  # ===== Connection =====
  [Parameter(Mandatory = $true)]
  [string]$Server,

  [ValidateRange(1, 65535)]
  [int]$Port = 9419,

  # ===== Authentication =====
  [Parameter(ParameterSetName = 'Credential')]
  [System.Management.Automation.PSCredential]$Credential,

  [Parameter(ParameterSetName = 'UsernamePassword')]
  [string]$Username,

  [Parameter(ParameterSetName = 'UsernamePassword')]
  [securestring]$Password,

  # ===== TLS =====
  [switch]$SkipCertificateCheck,

  # ===== Scope =====
  [switch]$IncludeJobs,

  [switch]$IncludeJobSessions,

  # ===== Output =====
  [string]$OutFolder = ".\VeeamDiagram_$(Get-Date -Format 'yyyyMMdd_HHmmss')",

  [switch]$ExportJson,

  [ValidateSet("Hierarchical", "Radial")]
  [string]$DiagramLayout = "Hierarchical",

  [switch]$ZipBundle
)

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Constants
# =============================

$API_VERSION = "1.3-rev1"
$BASE_URL = "https://${Server}:${Port}/api"

# =============================
# Output Setup
# =============================

if (-not (Test-Path $OutFolder)) {
  New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null
}

$stamp    = Get-Date -Format "yyyy-MM-dd_HHmm"
$logPath  = Join-Path $OutFolder "Veeam-Diagram-Log-$stamp.txt"
$outDiagram = Join-Path $OutFolder "Veeam-Infrastructure-$stamp.drawio"
$outHtml  = Join-Path $OutFolder "Veeam-Infrastructure-Report-$stamp.html"
$outJson  = Join-Path $OutFolder "Veeam-Infrastructure-$stamp.json"
$outCsv   = Join-Path $OutFolder "Veeam-Infrastructure-Summary-$stamp.csv"
$outZip   = Join-Path $OutFolder "Veeam-Diagram-Bundle-$stamp.zip"

# =============================
# Logging
# =============================

$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = 0
$script:TotalSteps = 10

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level     = $Level
    Message   = $Message
  }

  $script:LogEntries.Add($entry)

  $color = switch ($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default   { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-ProgressStep {
  param(
    [Parameter(Mandatory = $true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Veeam Infrastructure Discovery" `
                 -Status "$Activity - $Status" `
                 -PercentComplete $pct
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity"
}

# =============================
# TLS Certificate Handling
# =============================

if ($SkipCertificateCheck) {
  # PowerShell 5.1 workaround — add a callback that trusts all certs
  if ($PSVersionTable.PSVersion.Major -lt 7) {
    if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
      Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
  public bool CheckValidationResult(
    ServicePoint srvPoint, X509Certificate certificate,
    WebRequest request, int certificateProblem) { return true; }
}
"@
    }
    [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
  }
  Write-Log "TLS certificate validation disabled (SkipCertificateCheck)" -Level "WARNING"
}

# Common splat for Invoke-RestMethod across PS versions
function Get-RestParams {
  param([hashtable]$Extra = @{})

  $params = @{ ErrorAction = "Stop" }

  # PS7+ supports -SkipCertificateCheck natively
  if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 7) {
    $params.SkipCertificateCheck = $true
  }

  foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
  return $params
}

# =============================
# API Helper Functions
# =============================

$script:AccessToken = $null
$script:RefreshToken = $null

function Connect-VBRServer {
  <#
  .SYNOPSIS
    Authenticates to the VBR REST API via OAuth2 password grant.
  #>

  Write-Log "Authenticating to $BASE_URL ..."

  # Resolve credentials
  if ($Credential) {
    $user = $Credential.UserName
    $pass = $Credential.GetNetworkCredential().Password
  }
  elseif ($Username -and $Password) {
    $user = $Username
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    $pass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
  }
  else {
    # Interactive prompt
    $cred = Get-Credential -Message "Enter Veeam B&R credentials for $Server"
    if (-not $cred) { throw "No credentials provided." }
    $user = $cred.UserName
    $pass = $cred.GetNetworkCredential().Password
  }

  $body = "grant_type=password&username=$([uri]::EscapeDataString($user))&password=$([uri]::EscapeDataString($pass))"

  $restParams = Get-RestParams -Extra @{
    Uri         = "$BASE_URL/oauth2/token"
    Method      = "POST"
    ContentType = "application/x-www-form-urlencoded"
    Body        = $body
  }

  try {
    $response = Invoke-RestMethod @restParams
    $script:AccessToken  = $response.access_token
    $script:RefreshToken = $response.refresh_token
    Write-Log "Authenticated successfully (token expires in $($response.expires_in)s)" -Level "SUCCESS"
  }
  catch {
    Write-Log "Authentication failed: $($_.Exception.Message)" -Level "ERROR"
    throw
  }
}

function Invoke-VBRApi {
  <#
  .SYNOPSIS
    Calls a VBR REST API endpoint with retry and pagination support.
  .PARAMETER Uri
    Relative path (e.g., "/v1/backupInfrastructure/proxies") or full URL.
  .PARAMETER MaxRetries
    Maximum retry attempts for transient errors.
  .PARAMETER Paginate
    Automatically follow pagination to collect all items.
  #>
  param(
    [Parameter(Mandatory)][string]$Uri,
    [string]$Method = "GET",
    [int]$MaxRetries = 4,
    [switch]$Paginate
  )

  # Build full URL if relative
  if ($Uri -notmatch '^https?://') {
    $Uri = "$BASE_URL$Uri"
  }

  $headers = @{
    "Authorization"   = "Bearer $($script:AccessToken)"
    "x-api-version"   = $API_VERSION
    "Accept"          = "application/json"
  }

  if ($Paginate) {
    return Invoke-VBRApiPaginated -Uri $Uri -Headers $headers -MaxRetries $MaxRetries
  }

  $attempt = 0
  do {
    try {
      $restParams = Get-RestParams -Extra @{
        Uri     = $Uri
        Method  = $Method
        Headers = $headers
      }
      return Invoke-RestMethod @restParams
    }
    catch {
      $attempt++
      $msg = $_.Exception.Message

      $isRetryable = ($msg -match '429|throttle|Too Many Requests|5\d\d|temporarily unavailable|timeout')

      if ($attempt -le $MaxRetries -and $isRetryable) {
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        Write-Log "Retryable error on $Uri : sleeping ${sleep}s (attempt $attempt/$MaxRetries)" -Level "WARNING"
        Start-Sleep -Seconds $sleep
      }
      else {
        throw
      }
    }
  } while ($true)
}

function Invoke-VBRApiPaginated {
  <#
  .SYNOPSIS
    Handles pagination — collects all items from a paginated endpoint.
  #>
  param(
    [string]$Uri,
    [hashtable]$Headers,
    [int]$MaxRetries = 4
  )

  $allItems = New-Object System.Collections.Generic.List[object]
  $skip = 0
  $limit = 200

  do {
    $separator = if ($Uri.Contains("?")) { "&" } else { "?" }
    $pageUri = "${Uri}${separator}limit=${limit}&skip=${skip}"

    $attempt = 0
    $response = $null
    do {
      try {
        $restParams = Get-RestParams -Extra @{
          Uri     = $pageUri
          Method  = "GET"
          Headers = $Headers
        }
        $response = Invoke-RestMethod @restParams
        break
      }
      catch {
        $attempt++
        $msg = $_.Exception.Message
        $isRetryable = ($msg -match '429|throttle|5\d\d|temporarily unavailable|timeout')

        if ($attempt -le $MaxRetries -and $isRetryable) {
          $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
          Write-Log "Paginated retry on $pageUri : ${sleep}s (attempt $attempt)" -Level "WARNING"
          Start-Sleep -Seconds $sleep
        }
        else { throw }
      }
    } while ($true)

    if ($response.data) {
      foreach ($item in $response.data) {
        $allItems.Add($item)
      }
    }

    $total = if ($response.pagination) { $response.pagination.total } else { 0 }
    $skip += $limit
  } while ($skip -lt $total)

  return $allItems
}

# =============================
# Infrastructure Discovery
# =============================

function Get-VBRInfrastructure {
  <#
  .SYNOPSIS
    Discovers the complete Veeam backup infrastructure via REST API.
  .DESCRIPTION
    Returns a hashtable containing all infrastructure components:
    managedServers, proxies, repositories, sobrs, wanAccelerators, jobs, jobStates.
  #>

  $infra = [ordered]@{
    ServerName       = $Server
    ServerPort       = $Port
    DiscoveryTime    = (Get-Date).ToString("s")
    ManagedServers   = @()
    Proxies          = @()
    Repositories     = @()
    RepositoryStates = @()
    SOBRs            = @()
    WanAccelerators  = @()
    Jobs             = @()
    JobStates        = @()
  }

  # --- Server Time ---
  Write-ProgressStep "Checking server connectivity"
  try {
    $serverTime = Invoke-VBRApi -Uri "/v1/serverTime"
    $infra.ServerTime = $serverTime.dateTime
    Write-Log "Server time: $($serverTime.dateTime)" -Level "SUCCESS"
  }
  catch {
    Write-Log "Could not retrieve server time: $($_.Exception.Message)" -Level "WARNING"
  }

  # --- Managed Servers ---
  Write-ProgressStep "Discovering managed servers"
  try {
    $infra.ManagedServers = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/managedServers" -Paginate)
    Write-Log "Found $($infra.ManagedServers.Count) managed server(s)" -Level "SUCCESS"
  }
  catch {
    Write-Log "Failed to retrieve managed servers: $($_.Exception.Message)" -Level "ERROR"
  }

  # --- Proxies ---
  Write-ProgressStep "Discovering backup proxies"
  try {
    $infra.Proxies = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/proxies" -Paginate)
    Write-Log "Found $($infra.Proxies.Count) proxy/proxies" -Level "SUCCESS"
  }
  catch {
    Write-Log "Failed to retrieve proxies: $($_.Exception.Message)" -Level "ERROR"
  }

  # --- Repositories ---
  Write-ProgressStep "Discovering backup repositories"
  try {
    $infra.Repositories = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/repositories" -Paginate)
    Write-Log "Found $($infra.Repositories.Count) repository/repositories" -Level "SUCCESS"
  }
  catch {
    Write-Log "Failed to retrieve repositories: $($_.Exception.Message)" -Level "ERROR"
  }

  # --- Repository States ---
  try {
    $infra.RepositoryStates = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/repositories/states" -Paginate)
  }
  catch {
    Write-Log "Could not retrieve repository states: $($_.Exception.Message)" -Level "WARNING"
  }

  # --- Scale-Out Repositories ---
  Write-ProgressStep "Discovering scale-out repositories"
  try {
    $infra.SOBRs = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/scaleOutRepositories" -Paginate)
    Write-Log "Found $($infra.SOBRs.Count) SOBR(s)" -Level "SUCCESS"
  }
  catch {
    Write-Log "Failed to retrieve SOBRs: $($_.Exception.Message)" -Level "ERROR"
  }

  # --- WAN Accelerators ---
  Write-ProgressStep "Discovering WAN accelerators"
  try {
    $infra.WanAccelerators = @(Invoke-VBRApi -Uri "/v1/backupInfrastructure/wanAccelerators" -Paginate)
    Write-Log "Found $($infra.WanAccelerators.Count) WAN accelerator(s)" -Level "SUCCESS"
  }
  catch {
    Write-Log "Could not retrieve WAN accelerators: $($_.Exception.Message)" -Level "WARNING"
  }

  # --- Jobs ---
  if ($IncludeJobs) {
    Write-ProgressStep "Discovering backup jobs"
    try {
      $infra.Jobs = @(Invoke-VBRApi -Uri "/v1/jobs" -Paginate)
      Write-Log "Found $($infra.Jobs.Count) job(s)" -Level "SUCCESS"
    }
    catch {
      Write-Log "Failed to retrieve jobs: $($_.Exception.Message)" -Level "ERROR"
    }

    # --- Job States ---
    if ($IncludeJobSessions) {
      Write-ProgressStep "Retrieving job states"
      try {
        $infra.JobStates = @(Invoke-VBRApi -Uri "/v1/jobs/states" -Paginate)
        Write-Log "Retrieved $($infra.JobStates.Count) job state(s)" -Level "SUCCESS"
      }
      catch {
        Write-Log "Could not retrieve job states: $($_.Exception.Message)" -Level "WARNING"
      }
    }
    else {
      $script:CurrentStep++
    }
  }
  else {
    $script:CurrentStep += 2
  }

  return $infra
}

# =============================
# Draw.io XML Generation
# =============================

function New-DrawioDiagram {
  <#
  .SYNOPSIS
    Generates a draw.io XML diagram from the discovered infrastructure.
  .PARAMETER Infrastructure
    The infrastructure hashtable from Get-VBRInfrastructure.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Infrastructure
  )

  Write-ProgressStep "Generating draw.io diagram"

  $cellId = 0
  function Get-NextId { $script:cellId++; return "cell_$($script:cellId)" }

  # Collect all cells — each is a hashtable with id, xml
  $cells = New-Object System.Collections.Generic.List[object]
  $edges = New-Object System.Collections.Generic.List[string]

  # Track IDs for relationship mapping
  $nodeIds = @{}      # key = component type + id or name => drawio cell id
  $repoIdMap = @{}    # VBR repo id => drawio cell id

  # ===== Layout coordinates =====
  # Hierarchical layout: rows from top to bottom
  #   Row 0: Backup Server (center)
  #   Row 1: Managed Servers (vCenters, Hyper-V, etc.)
  #   Row 2: Proxies
  #   Row 3: Repositories + SOBRs
  #   Row 4: WAN Accelerators
  #   Row 5: Jobs (if included)

  $colWidth  = 200
  $rowHeight = 160
  $iconW     = 80
  $iconH     = 80
  $startX    = 40

  # ===== Style definitions =====
  # Veeam-inspired styles using draw.io shape attributes

  $styleBackupServer = "shape=mxgraph.veeam2.veeam_server;fillColor=#00B336;fontColor=#333333;strokeColor=#00802A;fontSize=11;fontStyle=1;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleVCenter      = "shape=mxgraph.veeam2.vmware_vcenter;fillColor=#0078D4;fontColor=#333333;strokeColor=#005A9E;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleHyperV       = "shape=mxgraph.veeam2.hyper_v_host;fillColor=#7B83EB;fontColor=#333333;strokeColor=#5B5FC7;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleLinuxServer  = "shape=mxgraph.veeam2.linux_server;fillColor=#E87400;fontColor=#333333;strokeColor=#C66300;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleWinServer    = "shape=mxgraph.veeam2.windows_server;fillColor=#0078D4;fontColor=#333333;strokeColor=#005A9E;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleProxy        = "shape=mxgraph.veeam2.veeam_proxy;fillColor=#00B336;fontColor=#333333;strokeColor=#00802A;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleRepository   = "shape=mxgraph.veeam2.veeam_repository;fillColor=#FFB900;fontColor=#333333;strokeColor=#D99C00;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleSOBR         = "shape=mxgraph.veeam2.veeam_repository;fillColor=#D83B01;fontColor=#333333;strokeColor=#B83200;fontSize=10;fontStyle=1;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleObjectStorage= "shape=mxgraph.veeam2.veeam_cloud_repository;fillColor=#0078D4;fontColor=#333333;strokeColor=#005A9E;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleWanAccel     = "shape=mxgraph.veeam2.wan_accelerator;fillColor=#8764B8;fontColor=#333333;strokeColor=#6B4FA0;fontSize=10;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleJob          = "shape=mxgraph.veeam2.veeam_backup_job;fillColor=#E6E6E6;fontColor=#333333;strokeColor=#999999;fontSize=9;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleJobSuccess   = "shape=mxgraph.veeam2.veeam_backup_job;fillColor=#DFF6DD;fontColor=#107C10;strokeColor=#107C10;fontSize=9;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleJobWarning   = "shape=mxgraph.veeam2.veeam_backup_job;fillColor=#FFF4CE;fontColor=#797600;strokeColor=#797600;fontSize=9;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"
  $styleJobFailed    = "shape=mxgraph.veeam2.veeam_backup_job;fillColor=#FDE7E9;fontColor=#D13438;strokeColor=#D13438;fontSize=9;whiteSpace=wrap;verticalLabelPosition=bottom;verticalAlign=top;"

  $edgeStyle         = "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=#666666;strokeWidth=1;"
  $edgeStyleRepo     = "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=#D99C00;strokeWidth=2;dashed=1;"
  $edgeStyleSOBR     = "edgeStyle=orthogonalEdgeStyle;rounded=1;orthogonalLoop=1;jettySize=auto;html=1;strokeColor=#D83B01;strokeWidth=2;"

  # Helper to XML-encode text
  function Escape-Xml([string]$text) {
    if (-not $text) { return "" }
    return $text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;").Replace("'", "&apos;")
  }

  # Helper to add a node cell
  function Add-Node {
    param([string]$Id, [string]$Label, [string]$Style, [int]$X, [int]$Y, [int]$W = $iconW, [int]$H = $iconH, [string]$Tooltip = "")
    $safeLabel = Escape-Xml $Label
    $safeTip   = Escape-Xml $Tooltip
    $xml = "      <mxCell id=`"$Id`" value=`"$safeLabel`" style=`"$Style`" vertex=`"1`" parent=`"1`">`n"
    $xml += "        <mxGeometry x=`"$X`" y=`"$Y`" width=`"$W`" height=`"$H`" as=`"geometry`" />`n"
    $xml += "      </mxCell>"
    if ($safeTip) {
      $xml = $xml.Replace("vertex=`"1`"", "vertex=`"1`" tooltip=`"$safeTip`"")
    }
    $cells.Add($xml)
  }

  # Helper to add an edge
  function Add-Edge {
    param([string]$SourceId, [string]$TargetId, [string]$Style = $edgeStyle, [string]$Label = "")
    $eId = Get-NextId
    $safeLabel = Escape-Xml $Label
    $xml = "      <mxCell id=`"$eId`" value=`"$safeLabel`" style=`"$Style`" edge=`"1`" source=`"$SourceId`" target=`"$TargetId`" parent=`"1`">`n"
    $xml += "        <mxGeometry relative=`"1`" as=`"geometry`" />`n"
    $xml += "      </mxCell>"
    $edges.Add($xml)
  }

  # ===== Row 0: Backup Server =====
  $vbrId = Get-NextId
  $totalComponents = $Infrastructure.ManagedServers.Count +
                     $Infrastructure.Proxies.Count +
                     $Infrastructure.Repositories.Count +
                     $Infrastructure.SOBRs.Count
  $pageWidth = [Math]::Max(($totalComponents + 2) * $colWidth, 1200)
  $centerX = [int]($pageWidth / 2) - [int]($iconW / 2)

  Add-Node -Id $vbrId -Label "VBR Server`n$Server" -Style $styleBackupServer `
           -X $centerX -Y 40 -W 100 -H 100 `
           -Tooltip "Veeam Backup & Replication Server: $Server`:$Port"

  # ===== Row 1: Managed Servers =====
  $row1Y = 40 + $rowHeight
  $managedCount = $Infrastructure.ManagedServers.Count
  if ($managedCount -gt 0) {
    $row1StartX = [int]($centerX + ($iconW / 2) - ($managedCount * $colWidth / 2))

    for ($i = 0; $i -lt $managedCount; $i++) {
      $ms = $Infrastructure.ManagedServers[$i]
      $msId = Get-NextId
      $msName = if ($ms.name) { $ms.name } else { $ms.id }
      $msType = if ($ms.type) { $ms.type } else { "Unknown" }

      # Pick style based on managed server type
      $msStyle = switch -Wildcard ($msType) {
        "*vCenter*"       { $styleVCenter }
        "*VirtualCenter*" { $styleVCenter }
        "*Vc*"            { $styleVCenter }
        "*HyperV*"        { $styleHyperV }
        "*Hv*"            { $styleHyperV }
        "*SCVMM*"         { $styleHyperV }
        "*Linux*"         { $styleLinuxServer }
        "*Windows*"       { $styleWinServer }
        default           { $styleWinServer }
      }

      $x = $row1StartX + ($i * $colWidth)
      Add-Node -Id $msId -Label "$msName`n($msType)" -Style $msStyle `
               -X $x -Y $row1Y `
               -Tooltip "Managed Server: $msName | Type: $msType"

      $nodeIds["ms_$($ms.id)"] = $msId
      Add-Edge -SourceId $vbrId -TargetId $msId
    }
  }

  # ===== Row 2: Proxies =====
  $row2Y = $row1Y + $rowHeight
  $proxyCount = $Infrastructure.Proxies.Count
  if ($proxyCount -gt 0) {
    $row2StartX = [int]($centerX + ($iconW / 2) - ($proxyCount * $colWidth / 2))

    for ($i = 0; $i -lt $proxyCount; $i++) {
      $px = $Infrastructure.Proxies[$i]
      $pxId = Get-NextId
      $pxName = if ($px.name) { $px.name }
                elseif ($px.server -and $px.server.name) { $px.server.name }
                else { $px.id }
      $pxType = if ($px.type) { $px.type } else { "Proxy" }
      $pxTasks = if ($px.maxTaskCount) { $px.maxTaskCount } else { "N/A" }

      $x = $row2StartX + ($i * $colWidth)
      Add-Node -Id $pxId -Label "$pxName`n($pxType)`nTasks: $pxTasks" -Style $styleProxy `
               -X $x -Y $row2Y `
               -Tooltip "Proxy: $pxName | Type: $pxType | Max Tasks: $pxTasks"

      $nodeIds["proxy_$($px.id)"] = $pxId

      # Connect proxy to its host managed server if available
      $hostId = if ($px.server -and $px.server.id) { $px.server.id }
                elseif ($px.hostId) { $px.hostId }
                else { $null }

      if ($hostId -and $nodeIds.ContainsKey("ms_$hostId")) {
        Add-Edge -SourceId $nodeIds["ms_$hostId"] -TargetId $pxId
      }
      else {
        Add-Edge -SourceId $vbrId -TargetId $pxId
      }
    }
  }

  # ===== Row 3: Repositories =====
  $row3Y = $row2Y + $rowHeight

  # Standard repos
  $repoCount = $Infrastructure.Repositories.Count
  $sobrCount = $Infrastructure.SOBRs.Count
  $totalRow3 = $repoCount + $sobrCount
  if ($totalRow3 -gt 0) {
    $row3StartX = [int]($centerX + ($iconW / 2) - ($totalRow3 * $colWidth / 2))
  }

  # Build repo state lookup
  $repoStateMap = @{}
  foreach ($rs in $Infrastructure.RepositoryStates) {
    if ($rs.id) { $repoStateMap[$rs.id] = $rs }
  }

  $col = 0
  foreach ($repo in $Infrastructure.Repositories) {
    $rId = Get-NextId
    $rName = if ($repo.name) { $repo.name } else { $repo.id }
    $rType = if ($repo.type) { $repo.type } else { "Repository" }

    # Capacity info from states
    $capacityInfo = ""
    if ($repoStateMap.ContainsKey($repo.id)) {
      $state = $repoStateMap[$repo.id]
      if ($state.capacityGB -and $state.freeGB) {
        $usedGB = [math]::Round($state.capacityGB - $state.freeGB, 1)
        $capacityInfo = "`nUsed: ${usedGB} / $([math]::Round($state.capacityGB, 1)) GB"
      }
    }

    # Style by repo type
    $rStyle = if ($rType -match 'Object|S3|Azure|Cloud') { $styleObjectStorage } else { $styleRepository }

    $x = $row3StartX + ($col * $colWidth)
    Add-Node -Id $rId -Label "$rName`n($rType)$capacityInfo" -Style $rStyle `
             -X $x -Y $row3Y `
             -Tooltip "Repository: $rName | Type: $rType"

    $nodeIds["repo_$($repo.id)"] = $rId
    $repoIdMap[$repo.id] = $rId
    Add-Edge -SourceId $vbrId -TargetId $rId -Style $edgeStyleRepo
    $col++
  }

  # SOBRs
  foreach ($sobr in $Infrastructure.SOBRs) {
    $sId = Get-NextId
    $sName = if ($sobr.name) { $sobr.name } else { $sobr.id }

    $x = $row3StartX + ($col * $colWidth)
    Add-Node -Id $sId -Label "SOBR`n$sName" -Style $styleSOBR `
             -X $x -Y $row3Y -W 100 -H 90 `
             -Tooltip "Scale-Out Backup Repository: $sName"

    $nodeIds["sobr_$($sobr.id)"] = $sId
    $repoIdMap[$sobr.id] = $sId
    Add-Edge -SourceId $vbrId -TargetId $sId -Style $edgeStyleSOBR

    # Connect SOBR extents to their child repositories
    if ($sobr.performanceTier -and $sobr.performanceTier.performanceExtents) {
      foreach ($extent in $sobr.performanceTier.performanceExtents) {
        $extRepoId = if ($extent.repositoryId) { $extent.repositoryId }
                     elseif ($extent.repository -and $extent.repository.id) { $extent.repository.id }
                     else { $null }
        if ($extRepoId -and $nodeIds.ContainsKey("repo_$extRepoId")) {
          Add-Edge -SourceId $sId -TargetId $nodeIds["repo_$extRepoId"] -Style $edgeStyleSOBR -Label "perf extent"
        }
      }
    }
    if ($sobr.capacityTier -and $sobr.capacityTier.repositoryId) {
      $ctId = $sobr.capacityTier.repositoryId
      if ($nodeIds.ContainsKey("repo_$ctId")) {
        Add-Edge -SourceId $sId -TargetId $nodeIds["repo_$ctId"] -Style $edgeStyleSOBR -Label "capacity tier"
      }
    }

    $col++
  }

  # ===== Row 4: WAN Accelerators =====
  $row4Y = $row3Y + $rowHeight
  $wanCount = $Infrastructure.WanAccelerators.Count
  if ($wanCount -gt 0) {
    $row4StartX = [int]($centerX + ($iconW / 2) - ($wanCount * $colWidth / 2))

    for ($i = 0; $i -lt $wanCount; $i++) {
      $wan = $Infrastructure.WanAccelerators[$i]
      $wId = Get-NextId
      $wName = if ($wan.name) { $wan.name } else { $wan.id }

      $x = $row4StartX + ($i * $colWidth)
      Add-Node -Id $wId -Label "WAN Accel`n$wName" -Style $styleWanAccel `
               -X $x -Y $row4Y `
               -Tooltip "WAN Accelerator: $wName"

      $nodeIds["wan_$($wan.id)"] = $wId
      Add-Edge -SourceId $vbrId -TargetId $wId
    }
  }

  # ===== Row 5: Jobs =====
  if ($IncludeJobs -and $Infrastructure.Jobs.Count -gt 0) {
    $row5Y = $row4Y + $rowHeight
    $jobCount = $Infrastructure.Jobs.Count

    # Build job state lookup
    $jobStateMap = @{}
    foreach ($js in $Infrastructure.JobStates) {
      $jsId = if ($js.id) { $js.id } elseif ($js.jobId) { $js.jobId } else { $null }
      if ($jsId) { $jobStateMap[$jsId] = $js }
    }

    $row5StartX = [int]($centerX + ($iconW / 2) - ($jobCount * ($colWidth * 0.7) / 2))

    for ($i = 0; $i -lt $jobCount; $i++) {
      $job = $Infrastructure.Jobs[$i]
      $jId = Get-NextId
      $jName = if ($job.name) { $job.name } else { $job.id }
      $jType = if ($job.type) { $job.type } else { "Job" }

      # Determine job status style
      $jStyle = $styleJob
      if ($jobStateMap.ContainsKey($job.id)) {
        $state = $jobStateMap[$job.id]
        $lastResult = if ($state.lastResult) { $state.lastResult }
                      elseif ($state.status) { $state.status }
                      else { "" }

        $jStyle = switch -Wildcard ($lastResult) {
          "*Success*" { $styleJobSuccess }
          "*Warning*" { $styleJobWarning }
          "*Failed*"  { $styleJobFailed }
          "*Error*"   { $styleJobFailed }
          default     { $styleJob }
        }
        $jName = "$jName`n[$lastResult]"
      }

      $x = $row5StartX + ($i * [int]($colWidth * 0.7))
      Add-Node -Id $jId -Label "$jName`n($jType)" -Style $jStyle `
               -X $x -Y $row5Y -W 70 -H 70 `
               -Tooltip "Job: $($job.name) | Type: $jType"

      $nodeIds["job_$($job.id)"] = $jId

      # Connect job to its target repository
      $targetRepoId = if ($job.storage -and $job.storage.backupRepositoryId) { $job.storage.backupRepositoryId }
                      elseif ($job.repositoryId) { $job.repositoryId }
                      else { $null }

      if ($targetRepoId -and $repoIdMap.ContainsKey($targetRepoId)) {
        Add-Edge -SourceId $jId -TargetId $repoIdMap[$targetRepoId] -Style $edgeStyleRepo -Label ""
      }
      else {
        # Connect to VBR server as fallback
        Add-Edge -SourceId $vbrId -TargetId $jId
      }

      # Connect job to its assigned proxy if specified
      if ($job.storage -and $job.storage.backupProxies -and $job.storage.backupProxies.autoSelection -eq $false) {
        foreach ($proxyRef in $job.storage.backupProxies.proxyIds) {
          if ($nodeIds.ContainsKey("proxy_$proxyRef")) {
            Add-Edge -SourceId $nodeIds["proxy_$proxyRef"] -TargetId $jId
          }
        }
      }
    }
  }

  # ===== Assemble the XML =====
  $allCellsXml = ($cells + $edges) -join "`n"

  $diagramXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<mxfile host="draw.io" type="device" version="24.0.0">
  <diagram id="veeam-infra" name="Veeam Infrastructure">
    <mxGraphModel dx="1422" dy="762" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="$($pageWidth + 200)" pageHeight="$($row4Y + $rowHeight + 200)" math="0" shadow="0">
      <root>
        <mxCell id="0" />
        <mxCell id="1" parent="0" />
$allCellsXml
      </root>
    </mxGraphModel>
  </diagram>
</mxfile>
"@

  return $diagramXml
}

# =============================
# HTML Report Generation
# =============================

function New-InfrastructureReport {
  <#
  .SYNOPSIS
    Generates a professional HTML report summarizing the infrastructure.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Infrastructure
  )

  Write-ProgressStep "Generating HTML report"

  $reportDate = Get-Date -Format "MMMM dd, yyyy HH:mm"

  # Build managed server rows
  $msRows = ""
  foreach ($ms in $Infrastructure.ManagedServers) {
    $name = if ($ms.name) { $ms.name } else { $ms.id }
    $type = if ($ms.type) { $ms.type } else { "Unknown" }
    $desc = if ($ms.description) { $ms.description } else { "-" }
    $msRows += "          <tr><td>$([System.Web.HttpUtility]::HtmlEncode($name))</td><td>$([System.Web.HttpUtility]::HtmlEncode($type))</td><td>$([System.Web.HttpUtility]::HtmlEncode($desc))</td></tr>`n"
  }
  if (-not $msRows) { $msRows = "          <tr><td colspan='3'>No managed servers found</td></tr>`n" }

  # Build proxy rows
  $pxRows = ""
  foreach ($px in $Infrastructure.Proxies) {
    $name = if ($px.name) { $px.name }
            elseif ($px.server -and $px.server.name) { $px.server.name }
            else { $px.id }
    $type = if ($px.type) { $px.type } else { "Proxy" }
    $tasks = if ($px.maxTaskCount) { $px.maxTaskCount } else { "N/A" }
    $pxRows += "          <tr><td>$([System.Web.HttpUtility]::HtmlEncode($name))</td><td>$([System.Web.HttpUtility]::HtmlEncode($type))</td><td>$tasks</td></tr>`n"
  }
  if (-not $pxRows) { $pxRows = "          <tr><td colspan='3'>No proxies found</td></tr>`n" }

  # Build repository rows
  $repoRows = ""
  $repoStateMap = @{}
  foreach ($rs in $Infrastructure.RepositoryStates) {
    if ($rs.id) { $repoStateMap[$rs.id] = $rs }
  }
  foreach ($repo in $Infrastructure.Repositories) {
    $name = if ($repo.name) { $repo.name } else { $repo.id }
    $type = if ($repo.type) { $repo.type } else { "Repository" }
    $capacity = "-"
    if ($repoStateMap.ContainsKey($repo.id)) {
      $state = $repoStateMap[$repo.id]
      if ($state.capacityGB -and $state.freeGB) {
        $usedGB = [math]::Round($state.capacityGB - $state.freeGB, 1)
        $capacity = "$usedGB / $([math]::Round($state.capacityGB, 1)) GB"
      }
    }
    $repoRows += "          <tr><td>$([System.Web.HttpUtility]::HtmlEncode($name))</td><td>$([System.Web.HttpUtility]::HtmlEncode($type))</td><td>$capacity</td></tr>`n"
  }
  if (-not $repoRows) { $repoRows = "          <tr><td colspan='3'>No repositories found</td></tr>`n" }

  # Build SOBR rows
  $sobrRows = ""
  foreach ($sobr in $Infrastructure.SOBRs) {
    $name = if ($sobr.name) { $sobr.name } else { $sobr.id }
    $extCount = 0
    if ($sobr.performanceTier -and $sobr.performanceTier.performanceExtents) {
      $extCount = $sobr.performanceTier.performanceExtents.Count
    }
    $capTier = if ($sobr.capacityTier -and $sobr.capacityTier.isEnabled) { "Enabled" } else { "Disabled" }
    $sobrRows += "          <tr><td>$([System.Web.HttpUtility]::HtmlEncode($name))</td><td>$extCount extent(s)</td><td>Capacity Tier: $capTier</td></tr>`n"
  }
  if (-not $sobrRows) { $sobrRows = "          <tr><td colspan='3'>No SOBRs configured</td></tr>`n" }

  # Build job rows
  $jobRows = ""
  if ($IncludeJobs) {
    $jobStateMap = @{}
    foreach ($js in $Infrastructure.JobStates) {
      $jsId = if ($js.id) { $js.id } elseif ($js.jobId) { $js.jobId } else { $null }
      if ($jsId) { $jobStateMap[$jsId] = $js }
    }
    foreach ($job in $Infrastructure.Jobs) {
      $name = if ($job.name) { $job.name } else { $job.id }
      $type = if ($job.type) { $job.type } else { "Job" }
      $status = "N/A"
      $statusClass = ""
      if ($jobStateMap.ContainsKey($job.id)) {
        $state = $jobStateMap[$job.id]
        $status = if ($state.lastResult) { $state.lastResult }
                  elseif ($state.status) { $state.status }
                  else { "Unknown" }
        $statusClass = switch -Wildcard ($status) {
          "*Success*" { "status-success" }
          "*Warning*" { "status-warning" }
          "*Failed*"  { "status-failed" }
          "*Error*"   { "status-failed" }
          default     { "" }
        }
      }
      $jobRows += "          <tr><td>$([System.Web.HttpUtility]::HtmlEncode($name))</td><td>$([System.Web.HttpUtility]::HtmlEncode($type))</td><td class='$statusClass'>$([System.Web.HttpUtility]::HtmlEncode($status))</td></tr>`n"
    }
    if (-not $jobRows) { $jobRows = "          <tr><td colspan='3'>No jobs found</td></tr>`n" }
  }

  # KPI card values
  $kpiManagedServers = $Infrastructure.ManagedServers.Count
  $kpiProxies        = $Infrastructure.Proxies.Count
  $kpiRepos          = $Infrastructure.Repositories.Count + $Infrastructure.SOBRs.Count
  $kpiJobs           = $Infrastructure.Jobs.Count

  # Job section HTML (conditional)
  $jobSectionHtml = ""
  if ($IncludeJobs) {
    $jobSectionHtml = @"
      <div class="section">
        <h2>Backup Jobs</h2>
        <table>
          <thead><tr><th>Job Name</th><th>Type</th><th>Last Result</th></tr></thead>
          <tbody>
$jobRows
          </tbody>
        </table>
      </div>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam B&amp;R Infrastructure Report | $([System.Web.HttpUtility]::HtmlEncode($Server))</title>
<style>
:root {
  --veeam-green: #00B336;
  --veeam-green-dark: #00802A;
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --color-success: #107C10;
  --color-warning: #797600;
  --color-error: #D13438;
  --shadow-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132);
  --shadow-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
}
.container { max-width: 1440px; margin: 0 auto; padding: 40px 32px; }
.header {
  background: white;
  border-left: 4px solid var(--veeam-green);
  padding: 32px;
  margin-bottom: 32px;
  box-shadow: var(--shadow-4);
  border-radius: 2px;
}
.header-title { font-size: 28px; font-weight: 600; color: var(--ms-gray-160); margin-bottom: 4px; letter-spacing: -0.02em; }
.header-subtitle { font-size: 14px; color: var(--ms-gray-90); }
.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-4);
  text-align: center;
  border-top: 3px solid var(--veeam-green);
}
.kpi-value { font-size: 36px; font-weight: 700; color: var(--veeam-green); }
.kpi-label { font-size: 12px; color: var(--ms-gray-90); text-transform: uppercase; letter-spacing: 0.05em; margin-top: 4px; }
.section {
  background: white;
  padding: 24px 32px;
  margin-bottom: 24px;
  box-shadow: var(--shadow-4);
  border-radius: 2px;
}
.section h2 {
  font-size: 18px;
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 16px;
  padding-bottom: 8px;
  border-bottom: 1px solid var(--ms-gray-30);
}
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th {
  padding: 10px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
}
td { padding: 12px 16px; border-bottom: 1px solid var(--ms-gray-30); }
tbody tr:hover { background: var(--ms-gray-10); }
.status-success { color: var(--color-success); font-weight: 600; }
.status-warning { color: var(--color-warning); font-weight: 600; }
.status-failed { color: var(--color-error); font-weight: 600; }
.footer {
  text-align: center;
  padding: 24px;
  color: var(--ms-gray-90);
  font-size: 12px;
}
.note {
  background: #FFF4CE;
  border-left: 4px solid var(--color-warning);
  padding: 12px 16px;
  margin-bottom: 24px;
  font-size: 13px;
  color: #494800;
  border-radius: 2px;
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="header-title">Veeam B&amp;R Infrastructure Report</div>
    <div class="header-subtitle">Server: $([System.Web.HttpUtility]::HtmlEncode($Server)):$Port | Generated: $reportDate</div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-value">$kpiManagedServers</div>
      <div class="kpi-label">Managed Servers</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-value">$kpiProxies</div>
      <div class="kpi-label">Backup Proxies</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-value">$kpiRepos</div>
      <div class="kpi-label">Repositories</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-value">$kpiJobs</div>
      <div class="kpi-label">Backup Jobs</div>
    </div>
  </div>

  <div class="note">
    A draw.io diagram file (<code>.drawio</code>) has been generated alongside this report.
    Open it in <a href="https://app.diagrams.net" target="_blank">draw.io</a> or the draw.io desktop app for an interactive infrastructure topology view.
  </div>

  <div class="section">
    <h2>Managed Servers</h2>
    <table>
      <thead><tr><th>Server Name</th><th>Type</th><th>Description</th></tr></thead>
      <tbody>
$msRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2>Backup Proxies</h2>
    <table>
      <thead><tr><th>Proxy Name</th><th>Type</th><th>Max Tasks</th></tr></thead>
      <tbody>
$pxRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2>Backup Repositories</h2>
    <table>
      <thead><tr><th>Repository Name</th><th>Type</th><th>Capacity (Used / Total)</th></tr></thead>
      <tbody>
$repoRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2>Scale-Out Backup Repositories</h2>
    <table>
      <thead><tr><th>SOBR Name</th><th>Performance Extents</th><th>Capacity Tier</th></tr></thead>
      <tbody>
$sobrRows
      </tbody>
    </table>
  </div>

$jobSectionHtml

  <div class="footer">
    Generated by Get-VeeamDiagram.ps1 v1.0.0 | Veeam Backup &amp; Replication v13 REST API | $reportDate
  </div>
</div>
</body>
</html>
"@

  return $html
}

# =============================
# CSV Summary Export
# =============================

function Export-InfrastructureSummary {
  <#
  .SYNOPSIS
    Exports a summary CSV of the discovered infrastructure.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Infrastructure
  )

  $summary = [PSCustomObject]@{
    ReportDate         = (Get-Date).ToString("s")
    VBRServer          = $Infrastructure.ServerName
    VBRPort            = $Infrastructure.ServerPort
    ManagedServers     = $Infrastructure.ManagedServers.Count
    Proxies            = $Infrastructure.Proxies.Count
    Repositories       = $Infrastructure.Repositories.Count
    ScaleOutRepos      = $Infrastructure.SOBRs.Count
    WanAccelerators    = $Infrastructure.WanAccelerators.Count
    BackupJobs         = $Infrastructure.Jobs.Count
  }

  $summary | Export-Csv -Path $outCsv -NoTypeInformation -Encoding UTF8
  Write-Log "Summary CSV exported: $outCsv" -Level "INFO"
}

# =============================
# JSON Bundle Export
# =============================

function Export-InfrastructureJson {
  <#
  .SYNOPSIS
    Exports the full infrastructure discovery as a JSON bundle.
  #>
  param(
    [Parameter(Mandatory)][hashtable]$Infrastructure
  )

  $bundle = [ordered]@{
    ReportDate   = (Get-Date).ToString("s")
    VBRServer    = $Infrastructure.ServerName
    VBRPort      = $Infrastructure.ServerPort
    Infrastructure = [ordered]@{
      ManagedServers  = $Infrastructure.ManagedServers
      Proxies         = $Infrastructure.Proxies
      Repositories    = $Infrastructure.Repositories
      ScaleOutRepos   = $Infrastructure.SOBRs
      WanAccelerators = $Infrastructure.WanAccelerators
      Jobs            = $Infrastructure.Jobs
      JobStates       = $Infrastructure.JobStates
    }
  }

  ($bundle | ConvertTo-Json -Depth 10) | Set-Content -Path $outJson -Encoding UTF8
  Write-Log "JSON bundle exported: $outJson" -Level "INFO"
}

# =============================
# Main Execution
# =============================

$banner = @"

 ╔══════════════════════════════════════════════════════════════╗
 ║  Veeam B&R Infrastructure Diagram Generator  v1.0.0        ║
 ║  REST API v1 (x-api-version $API_VERSION)                  ║
 ╚══════════════════════════════════════════════════════════════╝

"@

Write-Host $banner -ForegroundColor Green

Write-Log "Target server: ${Server}:${Port}"
Write-Log "Output folder: $OutFolder"

# Step 1: Authenticate
try {
  Connect-VBRServer
}
catch {
  Write-Log "Cannot proceed without authentication. Exiting." -Level "ERROR"
  exit 1
}

# Step 2: Discover infrastructure
$infra = Get-VBRInfrastructure

# Step 3: Generate draw.io diagram
$diagramXml = New-DrawioDiagram -Infrastructure $infra
$diagramXml | Set-Content -Path $outDiagram -Encoding UTF8
Write-Log "Draw.io diagram saved: $outDiagram" -Level "SUCCESS"

# Step 4: Generate HTML report
$htmlContent = New-InfrastructureReport -Infrastructure $infra
$htmlContent | Set-Content -Path $outHtml -Encoding UTF8
Write-Log "HTML report saved: $outHtml" -Level "SUCCESS"

# Step 5: Export CSV summary
Export-InfrastructureSummary -Infrastructure $infra

# Step 6: Export JSON (optional)
if ($ExportJson) {
  Export-InfrastructureJson -Infrastructure $infra
}

# Step 7: Save log
$script:LogEntries | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

# Step 8: ZIP bundle (optional)
if ($ZipBundle) {
  Write-ProgressStep "Creating ZIP bundle"
  if (Test-Path $outZip) { Remove-Item $outZip -Force -ErrorAction SilentlyContinue }
  $filesToZip = Get-ChildItem -Path $OutFolder -File | Where-Object { $_.Extension -ne ".zip" }
  Compress-Archive -Path ($filesToZip.FullName) -DestinationPath $outZip -Force
  Write-Log "ZIP bundle created: $outZip" -Level "SUCCESS"
}

# Final summary
Write-Progress -Activity "Veeam Infrastructure Discovery" -Completed

Write-Host ""
Write-Host "Discovery complete." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor DarkGray
Write-Host "Draw.io diagram : $outDiagram"
Write-Host "HTML report      : $outHtml"
Write-Host "Summary CSV      : $outCsv"
Write-Host "Execution log    : $logPath"
if ($ExportJson) { Write-Host "JSON bundle      : $outJson" }
if ($ZipBundle)  { Write-Host "ZIP archive      : $outZip" }
Write-Host "========================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Infrastructure Totals:" -ForegroundColor Cyan
Write-Host "  Managed Servers  : $($infra.ManagedServers.Count)"
Write-Host "  Backup Proxies   : $($infra.Proxies.Count)"
Write-Host "  Repositories     : $($infra.Repositories.Count)"
Write-Host "  Scale-Out Repos  : $($infra.SOBRs.Count)"
Write-Host "  WAN Accelerators : $($infra.WanAccelerators.Count)"
if ($IncludeJobs) {
  Write-Host "  Backup Jobs      : $($infra.Jobs.Count)"
}
Write-Host ""
Write-Host "Open the .drawio file in https://app.diagrams.net or the draw.io desktop app." -ForegroundColor Yellow
