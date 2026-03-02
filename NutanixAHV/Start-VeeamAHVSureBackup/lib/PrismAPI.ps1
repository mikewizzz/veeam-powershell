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
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
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
  $needsRequestId = ($PrismApiVersion -eq "v4" -and $Method -in @("POST", "PUT", "DELETE"))
  # Capture response headers when we may need ETags (v4 GET)
  $captureHeaders = ($PrismApiVersion -eq "v4")

  while ($attempt -le $RetryCount) {
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
          $retryAfter = $_.Exception.Response.Headers | Where-Object { $_.Key -eq "Retry-After" } | Select-Object -ExpandProperty Value -First 1
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
  Write-Log "Testing Prism Central connectivity ($PrismApiVersion): $PrismCentral`:$PrismPort" -Level "INFO"

  try {
    if ($PrismApiVersion -eq "v4") {
      $result = Invoke-PrismAPI -Method "GET" -Endpoint "$($script:PrismEndpoints.Clusters)?`$limit=1"
      $raw = if ($result.Body) { $result.Body } else { $result }
      $clusterCount = if ($raw.metadata.totalAvailableResults) { $raw.metadata.totalAvailableResults } else { ($raw.data | Measure-Object).Count }
    }
    else {
      $result = Invoke-PrismAPI -Method "POST" -Endpoint "clusters/list" -Body @{ kind = "cluster"; length = 1 }
      $clusterCount = $result.metadata.total_matches
    }
    Write-Log "Prism Central connected ($PrismApiVersion) - $clusterCount cluster(s) visible" -Level "SUCCESS"
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

  if ($PrismApiVersion -eq "v4") {
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

function Get-PrismSubnets {
  <#
  .SYNOPSIS
    Retrieve all subnets from Prism Central (paginated, v3/v4).
    Falls back to v3 subnets/list if v4 networking namespace returns 500.
  #>
  if ($PrismApiVersion -eq "v4") {
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
      return ,$allSubnets.ToArray()
    }
  }
  return Get-PrismEntities -EndpointKey "Subnets"
}

function Get-SubnetName {
  <#
  .SYNOPSIS
    Extract subnet name from a v3 or v4 entity object
  #>
  param([Parameter(Mandatory = $true)]$Subnet)
  if ($PrismApiVersion -eq "v4") { return $Subnet.name }
  return $Subnet.spec.name
}

function Get-SubnetUUID {
  <#
  .SYNOPSIS
    Extract subnet UUID/extId from a v3 or v4 entity object
  #>
  param([Parameter(Mandatory = $true)]$Subnet)
  if ($PrismApiVersion -eq "v4") { return $Subnet.extId }
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
  if ($PrismApiVersion -eq "v4") {
    $networkInfo = [PSCustomObject]@{
      Name       = $target.name
      UUID       = $target.extId
      VlanId     = $target.vlanId
      SubnetType = $target.subnetType
      ClusterRef = if ($target.clusterReference) { $target.clusterReference.extId } else { $null }
    }
  }
  else {
    $networkInfo = [PSCustomObject]@{
      Name       = $target.spec.name
      UUID       = $target.metadata.uuid
      VlanId     = $target.spec.resources.vlan_id
      SubnetType = $target.spec.resources.subnet_type
      ClusterRef = $target.spec.cluster_reference.uuid
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
    if ($PrismApiVersion -eq "v4") {
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

function Get-PrismVMByName {
  <#
  .SYNOPSIS
    Find a VM by name in Prism Central (v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$Name)

  if ($PrismApiVersion -eq "v4") {
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

  if ($PrismApiVersion -eq "v4") {
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

    if ($PrismApiVersion -eq "v4") {
      $vm = $vmResult.VM
      $nics = $vm.nics
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

  if ($PrismApiVersion -eq "v4") {
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

  if ($PrismApiVersion -eq "v4") {
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

      # Update subnet reference on existing NIC
      if ($nicData.networkInfo) {
        $nicData.networkInfo.subnet = @{ extId = $SubnetUUID }
      }
      else {
        $nicData.networkInfo = @{ subnet = @{ extId = $SubnetUUID } }
      }
      $putResult = Invoke-PrismAPI -Method "PUT" -Endpoint "$nicsEndpoint/$nicId" -Body $nicData -IfMatch $nicEtag
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
    # v3: update nic_list in VM spec
    $vmSpec = Get-PrismVMByUUID -UUID $VMUUID
    $vmSpec.spec.resources.nic_list = @(
      @{ subnet_reference = @{ kind = "subnet"; uuid = $SubnetUUID }; is_connected = $true }
    )
    $body = @{
      metadata = @{ kind = "vm"; uuid = $VMUUID; spec_version = $vmSpec.metadata.spec_version }
      spec     = $vmSpec.spec
    }
    Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$VMUUID" -Body $body
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

  if ($PrismApiVersion -eq "v4") {
    # v4: dedicated action endpoint per Nutanix VMM v4 SDK
    $action = if ($State -eq "OFF") { "power-off" } else { "power-on" }
    $result = Invoke-PrismAPI -Method "POST" -Endpoint "$($script:PrismEndpoints.VMs)/$UUID/`$actions/$action" -Body @{}
    $taskId = _ExtractTaskId $result
    if ($taskId) { Wait-PrismTask -TaskUUID $taskId -TimeoutSec 120 }
  }
  else {
    # v3: GET spec, modify power_state, PUT with spec_version
    $vmSpec = Get-PrismVMByUUID -UUID $UUID
    $vmSpec.spec.resources.power_state = $State
    $body = @{
      metadata = @{ kind = "vm"; uuid = $UUID; spec_version = $vmSpec.metadata.spec_version }
      spec     = $vmSpec.spec
    }
    Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$UUID" -Body $body
  }
}

function Remove-PrismVM {
  <#
  .SYNOPSIS
    Delete a VM from Nutanix (cleanup, v3/v4)
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  try {
    if ($PrismApiVersion -eq "v4") {
      # v4 DELETE requires ETag via If-Match
      $vmResult = Get-PrismVMByUUID -UUID $UUID
      $etag = if ($vmResult.ETag) { $vmResult.ETag } else { $null }
      Invoke-PrismAPI -Method "DELETE" -Endpoint "$($script:PrismEndpoints.VMs)/$UUID" -IfMatch $etag
    }
    else {
      Invoke-PrismAPI -Method "DELETE" -Endpoint "vms/$UUID"
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

  if ($PrismApiVersion -eq "v4") {
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
      $errorMsg = if ($PrismApiVersion -eq "v4") {
        if ($task.errorMessages -and $task.errorMessages.Count -gt 0) { ($task.errorMessages | ForEach-Object { if ($_.message) { $_.message } else { "$_" } }) -join "; " } else { "unknown" }
      } else {
        if ($task.error_detail) { $task.error_detail } else { "unknown" }
      }
      throw "Prism task $TaskUUID failed: $errorMsg"
    }

    Start-Sleep -Seconds 5
  }

  throw "Prism task $TaskUUID timed out after ${TimeoutSec}s"
}
