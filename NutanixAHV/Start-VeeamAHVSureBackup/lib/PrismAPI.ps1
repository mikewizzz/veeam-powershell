# SPDX-License-Identifier: MIT
# =============================
# Nutanix Prism Central REST API (v3 + v4)
# =============================

function Initialize-PrismConnection {
  <#
  .SYNOPSIS
    Configure Prism Central REST API authentication and TLS settings
  #>

  # Handle self-signed certificates
  if ($SkipCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
      # PowerShell 7+ has native -SkipCertificateCheck on Invoke-RestMethod
      $script:SkipCert = $true
    }
    else {
      # PowerShell 5.1 - add certificate bypass
      if (-not ([System.Management.Automation.PSTypeName]"TrustAllCertsPolicy").Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
      }
      [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    # PS 5.1 only: force TLS 1.2 via ServicePointManager (not used in PS 7+)
    if ($PSVersionTable.PSVersion.Major -lt 7) {
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    Write-Log "TLS certificate validation disabled (lab mode)" -Level "WARNING"
  }

  # Build Basic Auth header — clear plaintext password from memory promptly
  $username = $PrismCredential.UserName
  $networkCred = $PrismCredential.GetNetworkCredential()
  $pair = "${username}:$($networkCred.Password)"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
  $base64 = [System.Convert]::ToBase64String($bytes)

  # Zero out temporary byte array and string references
  [Array]::Clear($bytes, 0, $bytes.Length)
  Remove-Variable -Name pair, networkCred -ErrorAction SilentlyContinue

  $script:PrismHeaders = @{
    "Authorization" = "Basic $base64"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
  }

  Write-Log "Prism Central auth configured for user: $username" -Level "INFO"
}

function Invoke-PrismAPI {
  <#
  .SYNOPSIS
    Execute a Prism Central REST API call with retry logic, rate-limit
    handling, correlation IDs, and deterministic timeouts.
    Supports both v3 and v4 API conventions.
  .PARAMETER Method
    HTTP method (GET, POST, PUT, DELETE)
  .PARAMETER Endpoint
    API endpoint path (appended to base URL)
  .PARAMETER Body
    Request body hashtable (converted to JSON)
  .PARAMETER IfMatch
    ETag value for v4 PUT/DELETE concurrency control (If-Match header)
  .PARAMETER RetryCount
    Number of retries on transient failure (default: 3)
  .PARAMETER TimeoutSec
    Per-request timeout in seconds (default: 30)
  .OUTPUTS
    For v4 PUT/DELETE with ETag, returns a PSCustomObject with .Body and .ETag.
    Otherwise returns the parsed response body.
  #>
  param(
    [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Endpoint,
    [hashtable]$Body,
    [string]$IfMatch,
    [ValidateRange(0, 10)][int]$RetryCount = 3,
    [ValidateRange(1, 300)][int]$TimeoutSec = 30
  )

  $url = "$($script:PrismBaseUrl)/$Endpoint"
  $attempt = 0
  $correlationId = [guid]::NewGuid().ToString("N").Substring(0, 12)

  # v4 mutations require NTNX-Request-Id for idempotency
  $needsRequestId = ($script:PrismApiVersion -eq "v4" -and $Method -in @("POST", "PUT", "DELETE"))
  # Capture response headers when we may need ETags (v4 GET)
  $captureHeaders = ($script:PrismApiVersion -eq "v4")

  while ($attempt -le $RetryCount) {
    $respHeaders = $null
    try {
      $requestHeaders = $script:PrismHeaders.Clone()
      $requestHeaders["X-Request-Id"] = $correlationId

      if ($needsRequestId) {
        $requestHeaders["NTNX-Request-Id"] = [guid]::NewGuid().ToString()
      }
      if ($IfMatch) {
        $requestHeaders["If-Match"] = $IfMatch
      }

      $params = @{
        Method      = $Method
        Uri         = $url
        Headers     = $requestHeaders
        TimeoutSec  = $TimeoutSec
      }

      if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
      }

      if ($script:SkipCert -and $PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipCertificateCheck = $true
      }

      # v4 ETag values may contain characters that PS rejects without this
      if ($IfMatch -and $PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipHeaderValidation = $true
      }

      # Capture response headers for ETag on v4
      if ($captureHeaders -and $PSVersionTable.PSVersion.Major -ge 7) {
        $params.ResponseHeadersVariable = "respHeaders"
      }

      if ($captureHeaders -and $PSVersionTable.PSVersion.Major -lt 7) {
        # PS 5.1 fallback: use Invoke-WebRequest to access response headers for ETag
        $webParams = $params.Clone()
        $webParams.UseBasicParsing = $true
        # PS 5.1: move Content-Type to dedicated parameter for reliability
        $webHeaders = $webParams.Headers.Clone()
        if ($webHeaders.ContainsKey("Content-Type")) {
          $webParams.ContentType = $webHeaders["Content-Type"]
          $webHeaders.Remove("Content-Type") | Out-Null
          $webParams.Headers = $webHeaders
        }
        $webResponse = Invoke-WebRequest @webParams -ErrorAction Stop
        $response = $webResponse.Content | ConvertFrom-Json
        $etag = $webResponse.Headers["ETag"]
        if ($etag) {
          return [PSCustomObject]@{ Body = $response; ETag = $etag }
        }
        return $response
      }

      $response = Invoke-RestMethod @params -ErrorAction Stop

      # Return ETag alongside body for v4 so callers can do updates
      if ($captureHeaders -and $PSVersionTable.PSVersion.Major -ge 7 -and $respHeaders -and $respHeaders.ContainsKey("ETag")) {
        return [PSCustomObject]@{ Body = $response; ETag = $respHeaders["ETag"][0] }
      }
      return $response
    }
    catch {
      $statusCode = $null
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      # SSL/TLS errors are not transient — fail immediately with guidance
      if ($_.Exception.Message -match 'SSL|TLS|certificate' -or
          ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match 'SSL|TLS|certificate')) {
        Write-Log "Prism API SSL/TLS error [correlation=$correlationId]: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Pass -SkipCertificateCheck to bypass certificate validation for self-signed certs" -Level "ERROR"
        throw
      }

      # Non-retryable client errors (except 429)
      if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
        Write-Log "Prism API client error ($statusCode) [correlation=$correlationId]: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }

      $attempt++
      if ($attempt -gt $RetryCount) {
        Write-Log "Prism API call failed after $RetryCount retries [correlation=$correlationId]: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }

      # Rate-limit: honour Retry-After header if present
      $waitSec = $null
      if ($statusCode -eq 429 -and $_.Exception.Response.Headers) {
        try {
          # PS 5.1: WebHeaderCollection uses indexed access, not key-value enumeration
          $retryAfterRaw = $_.Exception.Response.Headers["Retry-After"]
          # PS 7 may return IEnumerable<string> — extract scalar
          $retryAfter = if ($retryAfterRaw -is [System.Collections.IEnumerable] -and $retryAfterRaw -isnot [string]) { $retryAfterRaw[0] } else { $retryAfterRaw }
          if ($retryAfter) { $waitSec = [int]$retryAfter }
        }
        catch { }
      }

      if (-not $waitSec) {
        # Exponential backoff with jitter: base * 2^attempt + random(0..base)
        $baseSec = [math]::Min([int]([math]::Pow(2, $attempt)), 30)
        $jitter = Get-Random -Minimum 0 -Maximum ([math]::Max(1, $baseSec))
        $waitSec = $baseSec + $jitter
      }

      $reason = if ($statusCode -eq 429) { "rate-limited (429)" } else { "transient failure" }
      Write-Log "Prism API $reason (attempt $attempt/$RetryCount) [correlation=$correlationId], retrying in ${waitSec}s: $($_.Exception.Message)" -Level "WARNING"
      Start-Sleep -Seconds $waitSec
    }
  }
}

function Test-PrismConnection {
  <#
  .SYNOPSIS
    Validate Prism Central connectivity and credentials (v3 and v4)
  #>
  Write-Log "Testing Prism Central connectivity ($script:PrismApiVersion): $PrismCentral`:$PrismPort" -Level "INFO"

  try {
    if ($script:PrismApiVersion -eq "v4") {
      $result = Invoke-PrismAPI -Method "GET" -Endpoint "$($script:PrismEndpoints.Clusters)?`$limit=1"
      $raw = if ($result.Body) { $result.Body } else { $result }
      $clusterCount = if ($raw.metadata.totalAvailableResults) { $raw.metadata.totalAvailableResults } else { ($raw.data | Measure-Object).Count }

      # Probe vmm namespace — auto-downgrade to v3 if unavailable
      try {
        Invoke-PrismAPI -Method "GET" -Endpoint "vmm/v4.0/ahv/config/vms?`$filter=name eq '__probe__'&`$limit=1" -RetryCount 1
        Write-Log "Prism v4 vmm namespace available" -Level "INFO"
      }
      catch {
        Write-Log "Prism v4 vmm namespace unavailable — auto-downgrading to v3 API" -Level "WARNING"
        $script:PrismApiVersion = "v3"
        $script:PrismBaseUrl = "$($script:PrismOrigin)/api/nutanix/v3"
        $script:PrismEndpoints = @{
          VMs      = "vms"
          Subnets  = "subnets"
          Clusters = "clusters"
          Tasks    = "tasks"
        }
      }
    }
    else {
      $result = Invoke-PrismAPI -Method "POST" -Endpoint "clusters/list" -Body @{ kind = "cluster"; length = 1 }
      $clusterCount = $result.metadata.total_matches
    }
    Write-Log "Prism Central connected ($script:PrismApiVersion) - $clusterCount cluster(s) visible" -Level "SUCCESS"
    return $true
  }
  catch {
    Write-Log "Prism Central connection failed: $($_.Exception.Message)" -Level "ERROR"
    return $false
  }
}

function Resolve-PrismResponseBody {
  <#
  .SYNOPSIS
    Unwrap Invoke-PrismAPI response that may contain .Body/.ETag wrapper
  #>
  param([Parameter(Mandatory = $true)]$Response)
  if ($Response -and $Response.PSObject.Properties.Name -contains "Body" -and $Response.PSObject.Properties.Name -contains "ETag") {
    return $Response.Body
  }
  return $Response
}

function Get-PrismEntities {
  <#
  .SYNOPSIS
    Retrieve all entities from Prism Central with automatic pagination.
    Supports both v3 (POST list) and v4 (GET with OData) conventions.
  .PARAMETER EndpointKey
    Key into $script:PrismEndpoints (e.g., "Clusters", "Subnets", "VMs")
  .PARAMETER Filter
    v3: filter string in body; v4: OData $filter query parameter
  .PARAMETER PageSize
    Entities per page (v3 max 500, v4 max 100)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$EndpointKey,
    [string]$Filter,
    [int]$PageSize
  )

  $endpoint = $script:PrismEndpoints[$EndpointKey]
  if (-not $endpoint) { throw "Unknown Prism endpoint key: $EndpointKey" }

  $allEntities = New-Object System.Collections.Generic.List[object]

  if ($script:PrismApiVersion -eq "v4") {
    if (-not $PageSize) { $PageSize = 100 }
    $page = 0

    do {
      $qs = "`$page=$page&`$limit=$PageSize"
      if ($Filter) { $qs += "&`$filter=$Filter" }

      $raw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint "${endpoint}?${qs}")

      if ($raw.data) {
        foreach ($entity in $raw.data) {
          $allEntities.Add($entity)
        }
      }

      $totalAvailable = if ($raw.metadata.totalAvailableResults) { $raw.metadata.totalAvailableResults } else { 0 }
      $page++
    } while (($page * $PageSize) -lt $totalAvailable)
  }
  else {
    # v3: POST-based pagination
    if (-not $PageSize) { $PageSize = 250 }
    # Derive v3 kind from endpoint key
    $kindMap = @{ Clusters = "cluster"; Subnets = "subnet"; VMs = "vm" }
    $kind = $kindMap[$EndpointKey]
    if (-not $kind) { $kind = $EndpointKey.ToLower().TrimEnd("s") }
    $offset = 0

    do {
      $body = @{ kind = $kind; length = $PageSize; offset = $offset }
      if ($Filter) { $body.filter = $Filter }

      $result = Invoke-PrismAPI -Method "POST" -Endpoint "${kind}s/list" -Body $body

      if ($result.entities) {
        foreach ($entity in $result.entities) {
          $allEntities.Add($entity)
        }
      }

      $totalMatches = if ($result.metadata.total_matches) { $result.metadata.total_matches } else { 0 }
      $offset += $PageSize
    } while ($offset -lt $totalMatches)
  }

  return ,$allEntities.ToArray()
}

function Get-PrismClusters {
  <#
  .SYNOPSIS
    Retrieve all Nutanix clusters from Prism Central (paginated, v3/v4)
  #>
  return Get-PrismEntities -EndpointKey "Clusters"
}

function _GetPrismElementIPs {
  <#
  .SYNOPSIS
    Discover Prism Element cluster virtual IPs from Prism Central cluster data.
    Filters out the PC host itself so only PE addresses are returned.
  #>
  $peIPs = New-Object System.Collections.Generic.List[string]
  try {
    $clusters = Get-PrismClusters
    foreach ($cluster in $clusters) {
      $ip = $null
      if ($script:PrismApiVersion -eq "v4") {
        # v4 clustermgmt: cluster.network.externalAddress — may be string or object with ipv4.value
        if ($cluster.network -and $cluster.network.externalAddress) {
          $addr = $cluster.network.externalAddress
          if ($addr -is [string]) {
            $ip = $addr
          }
          elseif ($addr.ipv4 -and $addr.ipv4.value) {
            $ip = $addr.ipv4.value
          }
          elseif ($addr.value) {
            $ip = $addr.value
          }
        }
      }
      else {
        # v3: cluster.status.resources.network.external_ip
        if ($cluster.status -and $cluster.status.resources -and $cluster.status.resources.network) {
          $ip = $cluster.status.resources.network.external_ip
        }
      }

      # Skip null/empty IPs and the PC host itself
      if ($ip -and $ip -ne $PrismCentral) {
        $peIPs.Add($ip)
      }
    }
  }
  catch {
    Write-Log "Failed to discover PE IPs from cluster data: $($_.Exception.Message)" -Level "WARNING"
  }

  return ,$peIPs.ToArray()
}

function _InvokePrismElementV2 {
  <#
  .SYNOPSIS
    Call a Prism Element v2 API endpoint directly (bypasses Invoke-PrismAPI which routes to PC).
    Reuses the same Basic Auth credentials configured for Prism Central.
  .PARAMETER PrismElementIP
    IP address of the Prism Element cluster
  .PARAMETER Endpoint
    v2 API endpoint path (e.g. "networks/?count=500")
  #>
  param(
    [Parameter(Mandatory = $true)][string]$PrismElementIP,
    [Parameter(Mandatory = $true)][string]$Endpoint
  )

  $url = "https://${PrismElementIP}:9440/api/nutanix/v2.0/${Endpoint}"
  $params = @{
    Method     = "GET"
    Uri        = $url
    Headers    = $script:PrismHeaders
    TimeoutSec = 30
  }
  if ($script:SkipCert -and $PSVersionTable.PSVersion.Major -ge 7) {
    $params.SkipCertificateCheck = $true
  }

  try {
    return Invoke-RestMethod @params -ErrorAction Stop
  }
  catch {
    $statusCode = $null
    if ($_.Exception.Response) {
      $statusCode = [int]$_.Exception.Response.StatusCode
    }
    if ($statusCode -eq 403) {
      Write-Log "PE v2 $Endpoint returned 403 at $PrismElementIP — grant 'Viewer' or 'Cluster Admin' role on Prism Element for this account to enable subnet discovery" -Level "ERROR"
    }
    throw
  }
}

function Resolve-PENetworkUUID {
  <#
  .SYNOPSIS
    Cross-validate an isolated network against Prism Element v2 API.
    Veeam's restore engine uses NutanixV2Client.CreateVmAsync (PE v2),
    so the network must exist at PE level — not just in Prism Central.
  .PARAMETER NetworkName
    Name of the network to look up on PE
  .PARAMETER PrismCentralUUID
    PC-level UUID to try as fallback match
  .OUTPUTS
    PSCustomObject with UUID, Name, VlanId, PeIP, MatchBy — or $null if not found
  #>
  param(
    [Parameter(Mandatory = $true)][string]$NetworkName,
    [string]$PrismCentralUUID
  )

  $peIPs = _GetPrismElementIPs
  if ($peIPs.Count -eq 0) {
    Write-Log "  Cannot cross-validate network against PE — no PE IPs discovered" -Level "WARNING"
    return $null
  }

  foreach ($peIP in $peIPs) {
    try {
      $v2Response = _InvokePrismElementV2 -PrismElementIP $peIP -Endpoint "networks/?count=500"
      if ($v2Response.entities) {
        # Try exact name match first
        $peNet = $v2Response.entities | Where-Object { $_.name -eq $NetworkName } | Select-Object -First 1
        if ($peNet) {
          return [PSCustomObject]@{
            UUID    = $peNet.uuid
            Name    = $peNet.name
            VlanId  = $peNet.vlan_id
            PeIP    = $peIP
            MatchBy = "name"
          }
        }
        # Try PC UUID match (in case PE uses same UUID)
        if ($PrismCentralUUID) {
          $peNet = $v2Response.entities | Where-Object { $_.uuid -eq $PrismCentralUUID } | Select-Object -First 1
          if ($peNet) {
            return [PSCustomObject]@{
              UUID    = $peNet.uuid
              Name    = $peNet.name
              VlanId  = $peNet.vlan_id
              PeIP    = $peIP
              MatchBy = "uuid"
            }
          }
        }
        # Not found — log what PE does have
        $peNames = ($v2Response.entities | ForEach-Object { "$($_.name) ($($_.uuid))" }) -join ', '
        Write-Log "  PE v2 networks at ${peIP}: $peNames" -Level "WARNING"
        Write-Log "  Isolated network '$NetworkName' NOT FOUND on Prism Element" -Level "ERROR"
        return $null
      }
    }
    catch {
      Write-Log "  PE v2 network query failed at ${peIP}: $($_.Exception.Message)" -Level "WARNING"
    }
  }
  return $null
}

function Get-PrismSubnets {
  <#
  .SYNOPSIS
    Retrieve all subnets from Prism Central (paginated, v3/v4).
    Falls back to v3 subnets/list if v4 networking namespace returns 500.
  #>
  if ($script:PrismApiVersion -eq "v4") {
    try {
      return Get-PrismEntities -EndpointKey "Subnets"
    }
    catch {
      Write-Log "v4 networking API unavailable ($($_.Exception.Message)), falling back to v3 subnets/list" -Level "WARNING"
      # v3 fallback via the v4 base URL — append nutanix/v3 path manually
      $allSubnets = New-Object System.Collections.Generic.List[object]
      $offset = 0
      $pageSize = 250
      do {
        $body = @{ kind = "subnet"; length = $pageSize; offset = $offset }
        $raw = Invoke-PrismAPI -Method "POST" -Endpoint "nutanix/v3/subnets/list" -Body $body
        $result = Resolve-PrismResponseBody $raw
        if ($result.entities) {
          foreach ($entity in $result.entities) {
            # Normalize v3 shape to v4 properties for downstream compatibility
            $clusterRef = $null
            if ($entity.spec.cluster_reference) {
              $clusterRef = [PSCustomObject]@{ extId = $entity.spec.cluster_reference.uuid }
            }
            $normalized = [PSCustomObject]@{
              extId            = $entity.metadata.uuid
              name             = $entity.spec.name
              vlanId           = $entity.spec.resources.vlan_id
              subnetType       = $entity.spec.resources.subnet_type
              clusterReference = $clusterRef
            }
            $allSubnets.Add($normalized)
          }
        }
        $totalMatches = if ($result.metadata.total_matches) { $result.metadata.total_matches } else { 0 }
        $offset += $pageSize
      } while ($offset -lt $totalMatches)

      # v3 returned 0 — query Prism Element v2 networks directly (required for Nutanix CE)
      if ($allSubnets.Count -eq 0) {
        Write-Log "v3 subnets/list returned 0 entities" -Level "WARNING"
        Write-Log "Discovering Prism Element IPs from cluster data..." -Level "INFO"
        $peIPs = _GetPrismElementIPs
        if ($peIPs.Count -eq 0) {
          Write-Log "No Prism Element IPs discovered from cluster data" -Level "WARNING"
        }
        foreach ($peIP in $peIPs) {
          Write-Log "Querying PE v2 networks API at https://${peIP}:9440/api/nutanix/v2.0/networks/" -Level "INFO"
          try {
            $v2Response = _InvokePrismElementV2 -PrismElementIP $peIP -Endpoint "networks/?count=500"
            if ($v2Response.entities) {
              foreach ($net in $v2Response.entities) {
                $normalized = [PSCustomObject]@{
                  extId            = $net.uuid
                  name             = $net.name
                  vlanId           = $net.vlan_id
                  subnetType       = if ($net.network_type) { $net.network_type } else { "VLAN" }
                  clusterReference = $null
                }
                $allSubnets.Add($normalized)
              }
              Write-Log "PE v2 networks returned $($allSubnets.Count) subnet(s)" -Level "INFO"
              break  # Stop after first PE that returns results
            }
          }
          catch {
            Write-Log "PE v2 networks failed at ${peIP}: $($_.Exception.Message)" -Level "WARNING"
          }
        }
      }

      return ,$allSubnets.ToArray()
    }
  }

  # v3 mode
  $v3Result = Get-PrismEntities -EndpointKey "Subnets"
  if (@($v3Result).Count -gt 0) { return $v3Result }

  # v3 returned 0 — query Prism Element v2 networks directly (required for Nutanix CE)
  Write-Log "v3 subnets returned 0 entities" -Level "WARNING"
  Write-Log "Discovering Prism Element IPs from cluster data..." -Level "INFO"
  $allSubnets = New-Object System.Collections.Generic.List[object]
  $peIPs = _GetPrismElementIPs
  if ($peIPs.Count -eq 0) {
    Write-Log "No Prism Element IPs discovered from cluster data" -Level "WARNING"
  }
  foreach ($peIP in $peIPs) {
    Write-Log "Querying PE v2 networks API at https://${peIP}:9440/api/nutanix/v2.0/networks/" -Level "INFO"
    try {
      $v2Response = _InvokePrismElementV2 -PrismElementIP $peIP -Endpoint "networks/?count=500"
      if ($v2Response.entities) {
        foreach ($net in $v2Response.entities) {
          # Normalize to v3 shape for downstream v3 accessors
          $allSubnets.Add([PSCustomObject]@{
            metadata = [PSCustomObject]@{ uuid = $net.uuid; kind = "subnet" }
            spec = [PSCustomObject]@{
              name      = $net.name
              resources = [PSCustomObject]@{
                vlan_id     = $net.vlan_id
                subnet_type = if ($net.network_type) { $net.network_type } else { "VLAN" }
              }
              cluster_reference = $null
            }
          })
        }
        Write-Log "PE v2 networks returned $($allSubnets.Count) subnet(s)" -Level "INFO"
        break  # Stop after first PE that returns results
      }
    }
    catch {
      Write-Log "PE v2 networks failed at ${peIP}: $($_.Exception.Message)" -Level "WARNING"
    }
  }
  return ,$allSubnets.ToArray()
}

function Get-SubnetName {
  <#
  .SYNOPSIS
    Extract subnet name from a v3 or v4 entity object
  #>
  param([Parameter(Mandatory = $true)]$Subnet)
  if ($script:PrismApiVersion -eq "v4") { return $Subnet.name }
  return $Subnet.spec.name
}

function Get-SubnetUUID {
  <#
  .SYNOPSIS
    Extract subnet UUID/extId from a v3 or v4 entity object
  #>
  param([Parameter(Mandatory = $true)]$Subnet)
  if ($script:PrismApiVersion -eq "v4") { return $Subnet.extId }
  return $Subnet.metadata.uuid
}

function Resolve-IsolatedNetwork {
  <#
  .SYNOPSIS
    Find and validate the isolated network for SureBackup recovery (v3/v4)
  #>
  Write-Log "Resolving isolated network for SureBackup lab..." -Level "INFO"

  $subnets = Get-PrismSubnets

  if ($IsolatedNetworkUUID) {
    $target = $subnets | Where-Object { (Get-SubnetUUID $_) -eq $IsolatedNetworkUUID }
    if (-not $target) {
      throw "Isolated network UUID '$IsolatedNetworkUUID' not found in Prism Central"
    }
  }
  elseif ($IsolatedNetworkName) {
    $target = $subnets | Where-Object { (Get-SubnetName $_) -eq $IsolatedNetworkName }
    if (-not $target) {
      throw "Isolated network '$IsolatedNetworkName' not found in Prism Central. Available: $(($subnets | ForEach-Object { Get-SubnetName $_ }) -join ', ')"
    }
    if ($target.Count -gt 1) {
      Write-Log "Multiple subnets named '$IsolatedNetworkName' found, using first match" -Level "WARNING"
      $target = $target[0]
    }
  }
  else {
    # Look for a subnet with 'isolated', 'surebackup', or 'lab' in the name
    $target = $subnets | Where-Object {
      (Get-SubnetName $_) -imatch "isolated|surebackup|lab|sandbox|test-recovery"
    } | Select-Object -First 1

    if (-not $target) {
      throw "No isolated network specified and none auto-detected. Use -IsolatedNetworkName or -IsolatedNetworkUUID, or create a subnet with 'isolated'/'surebackup'/'lab' in its name."
    }
    Write-Log "Auto-detected isolated network: $(Get-SubnetName $target)" -Level "WARNING"
  }

  # Normalize to a common structure regardless of API version
  if ($script:PrismApiVersion -eq "v4") {
    # Extract IPAM subnet config for static IP detection (may be $null if no IPAM)
    $v4IpConfig = $target.ipConfig
    $netAddr = if ($v4IpConfig -and $v4IpConfig.ipv4Config) { $v4IpConfig.ipv4Config.networkAddress } else { $null }
    $prefixLen = if ($v4IpConfig -and $v4IpConfig.ipv4Config) { $v4IpConfig.ipv4Config.prefixLength } else { $null }

    $networkInfo = [PSCustomObject]@{
      Name           = $target.name
      UUID           = $target.extId
      VlanId         = $target.vlanId
      SubnetType     = $target.subnetType
      ClusterRef     = if ($target.clusterReference) { $target.clusterReference.extId } else { $null }
      NetworkAddress = $netAddr
      PrefixLength   = $prefixLen
    }
  }
  else {
    # Extract IPAM subnet config for static IP detection (may be $null if no IPAM)
    $v3IpConfig = $target.spec.resources.ip_config
    $netAddr = if ($v3IpConfig) { $v3IpConfig.network_address } else { $null }
    $prefixLen = if ($v3IpConfig) { $v3IpConfig.prefix_length } else { $null }

    $networkInfo = [PSCustomObject]@{
      Name           = $target.spec.name
      UUID           = $target.metadata.uuid
      VlanId         = $target.spec.resources.vlan_id
      SubnetType     = $target.spec.resources.subnet_type
      ClusterRef     = if ($target.spec.cluster_reference) { $target.spec.cluster_reference.uuid } else { $null }
      NetworkAddress = $netAddr
      PrefixLength   = $prefixLen
    }
  }

  Write-Log "Isolated network resolved: $($networkInfo.Name) [VLAN $($networkInfo.VlanId)] on cluster $($networkInfo.ClusterRef)" -Level "SUCCESS"
  return $networkInfo
}

function Test-NetworkIsolation {
  <#
  .SYNOPSIS
    Validate that the isolated network differs from the VM's production NIC subnet(s)
  .DESCRIPTION
    Checks the recovered VM's current NIC subnet(s) against the target isolated network.
    Warns if the isolated network UUID matches a production NIC — this indicates a
    misconfiguration where the "isolated" network is actually a production network.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$VMUUID,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  try {
    if ($script:PrismApiVersion -eq "v4") {
      $nicsEndpoint = "$($script:PrismEndpoints.VMs)/$VMUUID/nics"
      $nicsRaw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint $nicsEndpoint)
      $nics = if ($nicsRaw.data) { $nicsRaw.data } else { @() }

      foreach ($nic in $nics) {
        $nicSubnetId = $null
        if ($nic.networkInfo -and $nic.networkInfo.subnet) {
          $nicSubnetId = $nic.networkInfo.subnet.extId
        }
        if ($nicSubnetId -and $nicSubnetId -eq $IsolatedNetwork.UUID) {
          Write-Log "  WARNING: VM's production NIC is already on the 'isolated' network ($($IsolatedNetwork.Name)). Verify network isolation is correctly configured." -Level "WARNING"
        }
      }
    }
    else {
      $vmSpec = Get-PrismVMByUUID -UUID $VMUUID
      $nicList = $vmSpec.spec.resources.nic_list
      if ($nicList) {
        foreach ($nic in $nicList) {
          $nicSubnetId = $nic.subnet_reference.uuid
          if ($nicSubnetId -and $nicSubnetId -eq $IsolatedNetwork.UUID) {
            Write-Log "  WARNING: VM's production NIC is already on the 'isolated' network ($($IsolatedNetwork.Name)). Verify network isolation is correctly configured." -Level "WARNING"
          }
        }
      }
    }
  }
  catch {
    Write-Log "  Could not validate network isolation: $($_.Exception.Message)" -Level "WARNING"
  }
}

function Assert-VMNetworkIsolation {
  <#
  .SYNOPSIS
    Verify ALL NICs on a restored VM are connected to the isolated subnet
  .DESCRIPTION
    Safety-critical function called after restore, before power-on. Queries
    the VM's NIC configuration and verifies every NIC is on the expected
    isolated subnet UUID. Returns $false if any NIC is on a different subnet,
    preventing production network exposure.
  .PARAMETER VMUUID
    UUID of the restored VM to verify
  .PARAMETER IsolatedNetwork
    Resolved isolated network object with UUID property
  .OUTPUTS
    $true if all NICs are on the isolated network, $false otherwise
  #>
  param(
    [Parameter(Mandatory = $true)][string]$VMUUID,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  try {
    if ($script:PrismApiVersion -eq "v4") {
      $nicsEndpoint = "$($script:PrismEndpoints.VMs)/$VMUUID/nics"
      $nicsRaw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint $nicsEndpoint)
      $nics = if ($nicsRaw.data) { @($nicsRaw.data) } else { @() }

      if ($nics.Count -eq 0) {
        Write-Log "  VM has no NICs — network isolation verified (no network exposure)" -Level "INFO"
        return $true
      }

      foreach ($nic in $nics) {
        $nicSubnetId = $null
        if ($nic.networkInfo -and $nic.networkInfo.subnet) {
          $nicSubnetId = $nic.networkInfo.subnet.extId
        }
        if (-not $nicSubnetId) {
          # Disconnected/unattached NIC — no network exposure risk
          Write-Log "  NIC $($nic.extId) has no subnet (disconnected) — skipping" -Level "INFO"
          continue
        }
        if ($nicSubnetId -ne $IsolatedNetwork.UUID) {
          Write-Log "  NIC $($nic.extId) is on subnet '$nicSubnetId' — expected '$($IsolatedNetwork.UUID)'" -Level "ERROR"
          return $false
        }
      }
    }
    else {
      $vmResult = Get-PrismVMByUUID -UUID $VMUUID
      $nicList = $vmResult.spec.resources.nic_list
      if (-not $nicList -or @($nicList).Count -eq 0) {
        Write-Log "  VM has no NICs — network isolation verified (no network exposure)" -Level "INFO"
        return $true
      }

      foreach ($nic in $nicList) {
        $nicSubnetId = if ($nic.subnet_reference) { $nic.subnet_reference.uuid } else { $null }
        if (-not $nicSubnetId -or $nicSubnetId -ne $IsolatedNetwork.UUID) {
          Write-Log "  NIC is on subnet '$nicSubnetId' — expected '$($IsolatedNetwork.UUID)'" -Level "ERROR"
          return $false
        }
      }
    }

    Write-Log "  Network isolation verified: all NICs on '$($IsolatedNetwork.Name)'" -Level "SUCCESS"
    return $true
  }
  catch {
    Write-Log "  Network isolation check failed: $($_.Exception.Message) — blocking power-on for safety" -Level "ERROR"
    return $false
  }
}

function Get-PrismVMByName {
  <#
  .SYNOPSIS
    Find a VM by name in Prism Central (v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$Name)

  if ($script:PrismApiVersion -eq "v4") {
    $escapedName = $Name -replace "'", "''"
    $endpoint = "$($script:PrismEndpoints.VMs)?`$filter=name eq '$escapedName'"
    $raw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint $endpoint)
    return $raw.data | Where-Object { $_.name -eq $Name }
  }
  else {
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "vms/list" -Body @{
      kind   = "vm"
      length = 50
      filter = "vm_name==$Name"
    }
    return $result.entities | Where-Object { $_.spec.name -eq $Name }
  }
}

function Get-PrismVMByUUID {
  <#
  .SYNOPSIS
    Get a VM by UUID/extId from Prism Central (v3/v4).
    Returns a PSCustomObject with .Body and .ETag on v4 (PS7+), raw response on v3.
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  if ($script:PrismApiVersion -eq "v4") {
    $result = Invoke-PrismAPI -Method "GET" -Endpoint "$($script:PrismEndpoints.VMs)/$UUID"
    # Unwrap to get the vm data from .data if present
    $raw = if ($result.Body) { $result.Body } else { $result }
    $vmData = if ($raw.data) { $raw.data } else { $raw }
    $etag = if ($result.ETag) { $result.ETag } else { $null }
    return [PSCustomObject]@{ VM = $vmData; ETag = $etag }
  }
  else {
    return Invoke-PrismAPI -Method "GET" -Endpoint "vms/$UUID"
  }
}

function Get-PrismVMIPAddress {
  <#
  .SYNOPSIS
    Retrieve IP address(es) from a Nutanix VM via NGT or NIC info (v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  try {
    $vmResult = Get-PrismVMByUUID -UUID $UUID

    if ($script:PrismApiVersion -eq "v4") {
      # v4: NICs are a sub-resource, not inline on the VM object
      $nicsEndpoint = "$($script:PrismEndpoints.VMs)/$UUID/nics"
      $nicsRaw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint $nicsEndpoint)
      $nics = if ($nicsRaw.data) { @($nicsRaw.data) } else { @() }
      foreach ($nic in $nics) {
        # v4: IPs only under networkInfo.ipv4Info (per VMM v4 SDK Nic model)
        $ipEndpoints = $nic.networkInfo.ipv4Info.learnedIpAddresses
        if (-not $ipEndpoints) { $ipEndpoints = $nic.networkInfo.ipv4Info.ipAddresses }
        foreach ($ip in $ipEndpoints) {
          $addr = if ($ip.value) { $ip.value } else { "$ip" }
          if ($addr -and $addr -notmatch "^169\.254") { return $addr }
        }
      }
    }
    else {
      $nics = $vmResult.status.resources.nic_list
      foreach ($nic in $nics) {
        $endpoints = $nic.ip_endpoint_list
        foreach ($ep in $endpoints) {
          if ($ep.ip -and $ep.ip -notmatch "^169\.254") {
            return $ep.ip
          }
        }
      }
    }
  }
  catch {
    Write-Log "Could not retrieve IP for VM $UUID - $($_.Exception.Message)" -Level "WARNING"
  }
  return $null
}

function Get-PrismVMPowerState {
  <#
  .SYNOPSIS
    Extract power state string from a VM object (v3/v4)
  #>
  param([Parameter(Mandatory = $true)]$VMResult)

  if ($script:PrismApiVersion -eq "v4") {
    $vm = if ($VMResult.VM) { $VMResult.VM } else { $VMResult }
    return $vm.powerState
  }
  return $VMResult.status.resources.power_state
}

function Wait-PrismVMPowerState {
  <#
  .SYNOPSIS
    Wait for a VM to reach a specific power state (v3/v4)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [Parameter(Mandatory = $true)][ValidateSet("ON", "OFF")][string]$State,
    [int]$TimeoutSec = 300
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    try {
      $vmResult = Get-PrismVMByUUID -UUID $UUID
      $currentState = Get-PrismVMPowerState $vmResult

      if ($currentState -eq $State) {
        return $true
      }
    }
    catch {
      # VM may not be ready yet
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Wait-PrismVMIPAddress {
  <#
  .SYNOPSIS
    Wait for a VM to obtain an IP address via NGT or DHCP
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [int]$TimeoutSec = 300
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    $ip = Get-PrismVMIPAddress -UUID $UUID
    if ($ip) {
      return $ip
    }
    Start-Sleep -Seconds 10
  }
  return $null
}

function Set-PrismVMNIC {
  <#
  .SYNOPSIS
    Update all VM NICs to use a specific subnet (v3/v4).
    v4: uses dedicated NIC sub-resource endpoints per Nutanix VMM v4 SDK.
    v3: updates nic_list in VM spec via PUT.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$VMUUID,
    [Parameter(Mandatory = $true)][string]$SubnetUUID
  )

  if ($script:PrismApiVersion -eq "v4") {
    # v4: list NICs, then update each NIC's subnet via dedicated endpoint
    $nicsEndpoint = "$($script:PrismEndpoints.VMs)/$VMUUID/nics"
    $nicsRaw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint $nicsEndpoint)
    $nics = if ($nicsRaw.data) { $nicsRaw.data } else { @() }

    foreach ($nic in $nics) {
      $nicId = $nic.extId
      $nicResult = Invoke-PrismAPI -Method "GET" -Endpoint "$nicsEndpoint/$nicId"
      $raw = if ($nicResult.Body) { $nicResult.Body } else { $nicResult }
      $nicData = if ($raw.data) { $raw.data } else { $raw }
      $nicEtag = if ($nicResult.ETag) { $nicResult.ETag } else { $null }

      # Convert PSCustomObject to hashtable for -Body parameter
      $nicBody = @{}
      foreach ($prop in $nicData.PSObject.Properties) {
        $nicBody[$prop.Name] = $prop.Value
      }

      # Update subnet reference on existing NIC
      if ($nicBody.ContainsKey("networkInfo") -and $nicBody["networkInfo"]) {
        $netInfo = @{}
        foreach ($prop in ([PSCustomObject]$nicBody["networkInfo"]).PSObject.Properties) {
          $netInfo[$prop.Name] = $prop.Value
        }
        $netInfo["subnet"] = @{ extId = $SubnetUUID }
        $nicBody["networkInfo"] = $netInfo
      }
      else {
        $nicBody["networkInfo"] = @{ subnet = @{ extId = $SubnetUUID } }
      }
      $putResult = Invoke-PrismAPI -Method "PUT" -Endpoint "$nicsEndpoint/$nicId" -Body $nicBody -IfMatch $nicEtag
      $taskId = _ExtractTaskId $putResult
      if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
    }

    if ($nics.Count -eq 0) {
      # No existing NICs - create one on the isolated network
      $newNic = @{
        backingInfo = @{ model = "VIRTIO"; isConnected = $true }
        networkInfo = @{ nicType = "NORMAL_NIC"; subnet = @{ extId = $SubnetUUID } }
      }
      $postResult = Invoke-PrismAPI -Method "POST" -Endpoint $nicsEndpoint -Body $newNic
      $taskId = _ExtractTaskId $postResult
      if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
    }
  }
  else {
    # v3: update nic_list in VM spec — preserve full metadata to avoid stripping categories/owner
    $vmSpec = Get-PrismVMByUUID -UUID $VMUUID
    $vmSpec.spec.resources.nic_list = @(
      @{ subnet_reference = @{ kind = "subnet"; uuid = $SubnetUUID }; is_connected = $true }
    )
    $body = @{
      metadata = $vmSpec.metadata
      spec     = $vmSpec.spec
    }
    $putResult = Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$VMUUID" -Body $body
    $taskId = _ExtractTaskId $putResult
    if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
  }
}

function Set-PrismVMPowerState {
  <#
  .SYNOPSIS
    Change VM power state (v3/v4).
    v4: uses POST $actions/power-off or power-on endpoint.
    v3: updates power_state in VM spec via PUT.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [Parameter(Mandatory = $true)][ValidateSet("ON", "OFF")][string]$State
  )

  if ($script:PrismApiVersion -eq "v4") {
    # v4: dedicated action endpoint per Nutanix VMM v4 SDK
    $action = if ($State -eq "OFF") { "power-off" } else { "power-on" }
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "$($script:PrismEndpoints.VMs)/$UUID/`$actions/$action" -Body @{}
    $taskId = _ExtractTaskId $result
    if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
  }
  else {
    # v3: GET spec, modify power_state, PUT — preserve full metadata
    $vmSpec = Get-PrismVMByUUID -UUID $UUID
    $vmSpec.spec.resources.power_state = $State
    $body = @{
      metadata = $vmSpec.metadata
      spec     = $vmSpec.spec
    }
    $putResult = Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$UUID" -Body $body
    $taskId = _ExtractTaskId $putResult
    if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
  }
}

function Remove-PrismVM {
  <#
  .SYNOPSIS
    Delete a VM from Nutanix and wait for the async task to complete (cleanup, v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  try {
    if ($script:PrismApiVersion -eq "v4") {
      # v4 DELETE requires ETag via If-Match
      $vmResult = Get-PrismVMByUUID -UUID $UUID
      $etag = if ($vmResult.ETag) { $vmResult.ETag } else { $null }
      $deleteResult = Invoke-PrismAPI -Method "DELETE" -Endpoint "$($script:PrismEndpoints.VMs)/$UUID" -IfMatch $etag
      $taskId = _ExtractTaskId $deleteResult
      if ($taskId) {
        Wait-PrismTask -TaskUUID $taskId -TimeoutSec 300
      }
    }
    else {
      $deleteResult = Invoke-PrismAPI -Method "DELETE" -Endpoint "vms/$UUID"
      $taskId = $null
      if ($deleteResult.status -and $deleteResult.status.execution_context -and $deleteResult.status.execution_context.task_uuid) {
        $taskId = $deleteResult.status.execution_context.task_uuid
      }
      if ($taskId) {
        Wait-PrismTask -TaskUUID $taskId -TimeoutSec 300
      }
    }
    Write-Log "Deleted VM: $UUID" -Level "INFO"
    return $true
  }
  catch {
    Write-Log "Failed to delete VM $UUID - $($_.Exception.Message)" -Level "WARNING"
    return $false
  }
}

function Get-PrismTaskStatus {
  <#
  .SYNOPSIS
    Check the status of an async Prism task (v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$TaskUUID)

  if ($script:PrismApiVersion -eq "v4") {
    $raw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint "$($script:PrismEndpoints.Tasks)/$TaskUUID")
    return $(if ($raw.data) { $raw.data } else { $raw })
  }
  return Invoke-PrismAPI -Method "GET" -Endpoint "tasks/$TaskUUID"
}

function Wait-PrismTask {
  <#
  .SYNOPSIS
    Wait for a Prism async task to complete (v3/v4)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$TaskUUID,
    [int]$TimeoutSec = 600
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    $task = Get-PrismTaskStatus -TaskUUID $TaskUUID
    $status = $task.status

    if ($status -eq "SUCCEEDED") {
      return $task
    }
    elseif ($status -eq "FAILED") {
      $errorMsg = if ($script:PrismApiVersion -eq "v4") {
        if ($task.errorMessages -and $task.errorMessages.Count -gt 0) { ($task.errorMessages | ForEach-Object { if ($_.message) { $_.message } else { "$_" } }) -join "; " } else { "unknown" }
      } else {
        if ($task.error_detail) { $task.error_detail } else { "unknown" }
      }
      throw "Prism task $TaskUUID failed: $errorMsg"
    }
    elseif ($status -imatch "CANCEL|ABORT") {
      throw "Prism task $TaskUUID was cancelled/aborted (status: $status)"
    }

    Start-Sleep -Seconds 5
  }

  throw "Prism task $TaskUUID timed out after ${TimeoutSec}s"
}

# =============================
# Jump VM Image & VM Management
# =============================

function Get-PrismImages {
  <#
  .SYNOPSIS
    Retrieve images from Prism Central image service (v3/v4)
  #>
  if ($script:PrismApiVersion -eq "v4") {
    $endpoint = "vmm/v4.0/images"
    $raw = Resolve-PrismResponseBody (Invoke-PrismAPI -Method "GET" -Endpoint "${endpoint}?`$limit=100")
    if ($raw.data) { return @($raw.data) }
    return @()
  }
  else {
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "images/list" -Body @{ kind = "image"; length = 100 }
    if ($result.entities) { return @($result.entities) }
    return @()
  }
}

function Get-OrCreateJumpVMImage {
  <#
  .SYNOPSIS
    Resolve the jump VM image UUID. Uses cached image if available,
    downloads Ubuntu Minimal cloud image if not.
  .PARAMETER JumpVMImageName
    Override: use this pre-uploaded image name (for air-gapped clusters)
  .OUTPUTS
    Image UUID string
  #>
  param([string]$JumpVMImageName)

  $defaultImageName = "SureBackup_JumpVM_Image"
  $targetName = if ($JumpVMImageName) { $JumpVMImageName } else { $defaultImageName }

  Write-Log "Resolving jump VM image '$targetName'..." -Level "INFO"

  # Check if image already exists in Prism
  $images = Get-PrismImages
  foreach ($img in $images) {
    $imgName = if ($script:PrismApiVersion -eq "v4") { $img.name } else { $img.spec.name }
    $imgId = if ($script:PrismApiVersion -eq "v4") { $img.extId } else { $img.metadata.uuid }
    if ($imgName -eq $targetName) {
      Write-Log "Jump VM image found in Prism: $targetName ($imgId)" -Level "SUCCESS"
      return $imgId
    }
  }

  # Image not found — if user specified a custom name, it must already exist
  if ($JumpVMImageName) {
    throw "Jump VM image '$JumpVMImageName' not found in Prism image service. Upload it manually or omit -JumpVMImageName to auto-download Ubuntu Minimal."
  }

  # Auto-download Ubuntu Minimal cloud image and upload to Prism
  Write-Log "Image '$defaultImageName' not found — downloading Ubuntu Minimal cloud image..." -Level "INFO"
  $ubuntuUrl = "https://cloud-images.ubuntu.com/minimal/releases/jammy/release/ubuntu-22.04-minimal-cloudimg-amd64.img"

  if ($script:PrismApiVersion -eq "v4") {
    # v4: create image with source URL (Prism downloads it)
    $imageBody = @{
      name       = $defaultImageName
      type       = "DISK_IMAGE"
      source     = @{
        url = $ubuntuUrl
      }
    }
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "vmm/v4.0/images" -Body $imageBody -TimeoutSec 120
    $taskId = _ExtractTaskId $result
  }
  else {
    # v3: create image with source_uri
    $imageBody = @{
      spec = @{
        name      = $defaultImageName
        resources = @{
          image_type = "DISK_IMAGE"
          source_uri = $ubuntuUrl
        }
      }
      metadata = @{ kind = "image" }
    }
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "images" -Body $imageBody -TimeoutSec 120
    $taskId = _ExtractTaskId $result
  }

  if ($taskId) {
    Write-Log "Image upload task started ($taskId) — waiting for completion (this may take a few minutes)..." -Level "INFO"
    $completedTask = Wait-PrismTask -TaskUUID $taskId -TimeoutSec 600
  }

  # Re-query to get the image UUID
  $images = Get-PrismImages
  foreach ($img in $images) {
    $imgName = if ($script:PrismApiVersion -eq "v4") { $img.name } else { $img.spec.name }
    $imgId = if ($script:PrismApiVersion -eq "v4") { $img.extId } else { $img.metadata.uuid }
    if ($imgName -eq $defaultImageName) {
      Write-Log "Jump VM image uploaded successfully: $defaultImageName ($imgId)" -Level "SUCCESS"
      return $imgId
    }
  }

  throw "Failed to create jump VM image — image not found after upload task completed"
}

function New-PrismVM {
  <#
  .SYNOPSIS
    Create a new VM in Prism Central with dual NICs and cloud-init (v3/v4)
  .PARAMETER Name
    VM display name
  .PARAMETER ImageUUID
    Boot disk image UUID (clone source)
  .PARAMETER ManagementSubnetUUID
    NIC 1 subnet UUID (management/reachable network)
  .PARAMETER IsolatedSubnetUUID
    NIC 2 subnet UUID (isolated SureBackup network)
  .PARAMETER CloudInitUserdata
    Cloud-init userdata string (will be base64-encoded)
  .PARAMETER ClusterUUID
    Target cluster UUID (optional — required if multi-cluster)
  .OUTPUTS
    VM UUID string
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ImageUUID,
    [Parameter(Mandatory = $true)][string]$ManagementSubnetUUID,
    [Parameter(Mandatory = $true)][string]$IsolatedSubnetUUID,
    [Parameter(Mandatory = $true)][string]$CloudInitUserdata,
    [string]$ClusterUUID
  )

  $userdataB64 = [System.Convert]::ToBase64String(
    [System.Text.Encoding]::UTF8.GetBytes($CloudInitUserdata)
  )

  if ($script:PrismApiVersion -eq "v4") {
    $vmBody = @{
      name              = $Name
      numSockets        = 1
      numCoresPerSocket = 1
      memorySizeBytes   = 1073741824  # 1 GB
      nics              = @(
        @{ networkInfo = @{ subnet = @{ extId = $ManagementSubnetUUID } } }
        @{ networkInfo = @{ subnet = @{ extId = $IsolatedSubnetUUID } } }
      )
      disks             = @(
        @{
          backingInfo = @{
            vmDisk = @{
              dataSourceReference = @{ extId = $ImageUUID }
            }
          }
        }
      )
      guestCustomization = @{
        config = @{
          cloudInit = @{ cloudInitScript = $userdataB64 }
        }
      }
    }
    if ($ClusterUUID) {
      $vmBody.cluster = @{ extId = $ClusterUUID }
    }

    $result = Invoke-PrismAPI -Method "POST" -Endpoint $script:PrismEndpoints.VMs -Body $vmBody -TimeoutSec 120
    $taskId = _ExtractTaskId $result
  }
  else {
    $vmBody = @{
      metadata = @{ kind = "vm" }
      spec     = @{
        name      = $Name
        resources = @{
          num_sockets          = 1
          num_vcpus_per_socket = 1
          memory_size_mib      = 1024
          power_state          = "OFF"
          nic_list             = @(
            @{ subnet_reference = @{ kind = "subnet"; uuid = $ManagementSubnetUUID }; is_connected = $true }
            @{ subnet_reference = @{ kind = "subnet"; uuid = $IsolatedSubnetUUID }; is_connected = $true }
          )
          disk_list            = @(
            @{
              data_source_reference = @{ kind = "image"; uuid = $ImageUUID }
              device_properties     = @{
                device_type  = "DISK"
                disk_address = @{ adapter_type = "SCSI"; device_index = 0 }
              }
            }
          )
          guest_customization  = @{
            cloud_init = @{ user_data = $userdataB64 }
          }
        }
      }
    }
    if ($ClusterUUID) {
      $vmBody.spec.cluster_reference = @{ kind = "cluster"; uuid = $ClusterUUID }
    }

    $result = Invoke-PrismAPI -Method "POST" -Endpoint "vms" -Body $vmBody -TimeoutSec 120
    $taskId = _ExtractTaskId $result
  }

  if ($taskId) {
    Write-Log "Jump VM create task: $taskId" -Level "INFO"
    $completedTask = Wait-PrismTask -TaskUUID $taskId -TimeoutSec 300
  }

  # Find the VM by name to get its UUID
  $vm = Get-PrismVMByName -Name $Name
  if (-not $vm) {
    throw "Jump VM '$Name' not found after creation task completed"
  }
  $vmUUID = if ($script:PrismApiVersion -eq "v4") { $vm.extId } else { $vm.metadata.uuid }

  Write-Log "Jump VM created: $Name ($vmUUID)" -Level "SUCCESS"
  return $vmUUID
}

function Resolve-SubnetUUID {
  <#
  .SYNOPSIS
    Resolve a subnet by name or UUID, return the UUID
  .PARAMETER SubnetName
    Subnet name to look up
  .PARAMETER SubnetUUID
    Subnet UUID (returned directly if provided)
  #>
  param(
    [string]$SubnetName,
    [string]$SubnetUUID
  )

  if ($SubnetUUID) { return $SubnetUUID }
  if (-not $SubnetName) { throw "Either SubnetName or SubnetUUID must be provided" }

  $subnets = Get-PrismSubnets
  $target = $subnets | Where-Object { (Get-SubnetName $_) -eq $SubnetName }
  if (-not $target) {
    $available = ($subnets | ForEach-Object { Get-SubnetName $_ }) -join ", "
    throw "Management network '$SubnetName' not found in Prism Central. Available: $available"
  }
  if ($target.Count -gt 1) {
    $target = $target[0]
  }
  return (Get-SubnetUUID $target)
}

function Resolve-ManagementNetwork {
  <#
  .SYNOPSIS
    Auto-detect or resolve the management network for the jump VM
  .DESCRIPTION
    3-tier resolution mirroring Resolve-IsolatedNetwork:
    1. Explicit UUID override
    2. Explicit name override
    3. Auto-detect by keyword, DHCP heuristic, single-remaining, or interactive picker
  .PARAMETER ManagementNetworkName
    Explicit network name override
  .PARAMETER ManagementNetworkUUID
    Explicit network UUID override
  .PARAMETER IsolatedNetworkUUID
    UUID of the isolated network to exclude from candidates
  .PARAMETER Interactive
    Enable interactive picker fallback when auto-detect is ambiguous
  #>
  param(
    [string]$ManagementNetworkName,
    [string]$ManagementNetworkUUID,
    [string]$IsolatedNetworkUUID,
    [switch]$Interactive
  )

  $subnets = Get-PrismSubnets

  # Tier 1: Explicit UUID
  if ($ManagementNetworkUUID) {
    $target = $subnets | Where-Object { (Get-SubnetUUID $_) -eq $ManagementNetworkUUID }
    if (-not $target) {
      throw "Management network UUID '$ManagementNetworkUUID' not found in Prism Central"
    }
    return (Get-SubnetUUID $target)
  }

  # Tier 2: Explicit name
  if ($ManagementNetworkName) {
    $target = $subnets | Where-Object { (Get-SubnetName $_) -eq $ManagementNetworkName }
    if (-not $target) {
      $available = ($subnets | ForEach-Object { Get-SubnetName $_ }) -join ", "
      throw "Management network '$ManagementNetworkName' not found in Prism Central. Available: $available"
    }
    if (@($target).Count -gt 1) {
      $target = @($target)[0]
    }
    return (Get-SubnetUUID $target)
  }

  # Tier 3: Auto-detect — exclude isolated network from candidates
  $candidates = @($subnets | Where-Object { (Get-SubnetUUID $_) -ne $IsolatedNetworkUUID })

  # 3a. Keyword match: management, mgmt, admin, default, production, prod, infra
  $target = $candidates | Where-Object {
    (Get-SubnetName $_) -imatch "^mgmt|^management|^admin|^default$|^prod|^infra"
  } | Select-Object -First 1

  # 3b. DHCP heuristic — first non-isolated subnet with IPAM/DHCP configured
  if (-not $target) {
    $target = $candidates | Where-Object {
      $hasIPAM = if ($script:PrismApiVersion -eq "v4") {
        $null -ne $_.ipConfig
      } else {
        $ipCfg = $null
        if ($_.spec -and $_.spec.resources) { $ipCfg = $_.spec.resources.ip_config }
        $null -ne $ipCfg
      }
      $hasIPAM
    } | Select-Object -First 1
  }

  # 3c. Single remaining network — if only one non-isolated subnet exists, use it
  if (-not $target -and $candidates.Count -eq 1) {
    $target = $candidates | Select-Object -First 1
  }

  # 3d. Interactive picker fallback
  if (-not $target -and $Interactive) {
    Write-Log "Multiple networks found. Select the management network (reachable from this host):" -Level "INFO"
    for ($i = 0; $i -lt $candidates.Count; $i++) {
      $name = Get-SubnetName $candidates[$i]
      $vlan = if ($script:PrismApiVersion -eq "v4") {
        $candidates[$i].vlanId
      } else {
        if ($candidates[$i].spec -and $candidates[$i].spec.resources) { $candidates[$i].spec.resources.vlan_id } else { "N/A" }
      }
      Write-Log "  [$($i + 1)] $name (VLAN $vlan)" -Level "INFO"
    }
    $selection = Read-Host "  Selection"
    $idx = 0
    if ([int]::TryParse($selection, [ref]$idx) -and $idx -ge 1 -and $idx -le $candidates.Count) {
      $target = $candidates[$idx - 1]
    } else {
      throw "Invalid selection. Use -ManagementNetworkName to specify the management network explicitly."
    }
  }

  # 3e. Fail with actionable error
  if (-not $target) {
    $available = ($candidates | ForEach-Object { Get-SubnetName $_ }) -join ", "
    throw "Cannot auto-detect management network. Available: $available. Use -ManagementNetworkName or -Interactive."
  }

  Write-Log "Auto-detected management network: $(Get-SubnetName $target)" -Level "WARNING"
  return (Get-SubnetUUID $target)
}
