# SPDX-License-Identifier: MIT
# ============================================================================
# Veeam Plug-in for Nutanix AHV REST API v9
# ============================================================================
# API Reference: https://helpcenter.veeam.com/references/vbahv/9/rest/
# ============================================================================

# Veeam Plug-in for Nutanix AHV extension GUID (constant across installations)
$script:VBAHV_EXTENSION_GUID = "799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2"

function Initialize-VBAHVPluginConnection {
  <#
  .SYNOPSIS
    Authenticate to the Veeam Plug-in for Nutanix AHV REST API via OAuth2
  .DESCRIPTION
    The plugin REST API runs as a VBR server extension. Authentication uses
    the VBR server's OAuth2 token endpoint. Only the v9 REST API is supported.

    Ref: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/SectionOverview
  #>
  $vbrHost = $VBRServer
  $vbrApiPort = 9419  # VBR REST API default port

  Write-Log "Authenticating to Veeam AHV Plugin REST API on VBR: ${vbrHost}:${vbrApiPort}" -Level "INFO"

  $tokenUrl = "https://${vbrHost}:${vbrApiPort}/api/oauth2/token"

  # Use VBR credentials if provided, otherwise try current session
  $tokenBody = @{ grant_type = "password" }
  if ($VBRCredential) {
    $networkCred = $VBRCredential.GetNetworkCredential()
    $tokenBody.username = $VBRCredential.UserName
    $tokenBody.password = $networkCred.Password
    Remove-Variable -Name networkCred -ErrorAction SilentlyContinue
  }
  else {
    throw "VBR credentials required for REST API authentication. Provide -VBRCredential parameter."
  }

  $tokenParams = @{
    Method      = "POST"
    Uri         = $tokenUrl
    Headers     = @{ "x-api-version" = "1.3-rev1" }
    Body        = $tokenBody
    ContentType = "application/x-www-form-urlencoded"
    TimeoutSec  = 30
    ErrorAction = "Stop"
  }

  if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 7) {
    $tokenParams.SkipCertificateCheck = $true
  }

  try {
    $tokenResponse = Invoke-RestMethod @tokenParams
    $apiVersion = if ($VBAHVApiVersion) { $VBAHVApiVersion } else { "v9" }
    # Extension API is served on port 443 (default HTTPS), not the VBR API port
    $script:VBAHVBaseUrl = "https://${vbrHost}/extension/$($script:VBAHV_EXTENSION_GUID)/api/$apiVersion"
    $script:VBAHVHeaders = @{
      "Authorization" = "Bearer $($tokenResponse.access_token)"
      "Content-Type"  = "application/json"
      "Accept"        = "application/json"
    }

    # Store refresh token and expiry for proactive token renewal during long runs
    $script:VBAHVTokenUrl = $tokenUrl
    $script:VBAHVRefreshToken = $tokenResponse.refresh_token
    $expiresIn = if ($tokenResponse.expires_in) { [int]$tokenResponse.expires_in } else { 900 }
    $script:VBAHVTokenExpiry = (Get-Date).AddSeconds($expiresIn)

    Write-Log "Veeam AHV Plugin REST API authenticated (API $apiVersion, token expires in ${expiresIn}s)" -Level "SUCCESS"
  }
  catch {
    throw "Veeam AHV Plugin authentication failed: $($_.Exception.Message). Verify VBR credentials and that the AHV plugin v9 is installed."
  }
}

function Refresh-VBAHVToken {
  <#
  .SYNOPSIS
    Refresh the OAuth2 bearer token using the stored refresh token
  .DESCRIPTION
    VBR OAuth2 tokens expire in 30-60 minutes. Long SureBackup runs (many VMs)
    can exceed this window. This function uses the refresh_token grant to obtain
    a new access token without re-authenticating with credentials.
  #>
  if (-not $script:VBAHVRefreshToken -or -not $script:VBAHVTokenUrl) {
    Write-Log "No refresh token available — re-authenticating with credentials" -Level "WARNING"
    Initialize-VBAHVPluginConnection
    return
  }

  $refreshBody = @{
    grant_type    = "refresh_token"
    refresh_token = $script:VBAHVRefreshToken
  }

  $refreshParams = @{
    Method      = "POST"
    Uri         = $script:VBAHVTokenUrl
    Headers     = @{ "x-api-version" = "1.3-rev1" }
    Body        = $refreshBody
    ContentType = "application/x-www-form-urlencoded"
    TimeoutSec  = 30
    ErrorAction = "Stop"
  }

  if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 7) {
    $refreshParams.SkipCertificateCheck = $true
  }

  try {
    $tokenResponse = Invoke-RestMethod @refreshParams
    $script:VBAHVHeaders["Authorization"] = "Bearer $($tokenResponse.access_token)"

    if ($tokenResponse.refresh_token) {
      $script:VBAHVRefreshToken = $tokenResponse.refresh_token
    }

    $expiresIn = if ($tokenResponse.expires_in) { [int]$tokenResponse.expires_in } else { 900 }
    $script:VBAHVTokenExpiry = (Get-Date).AddSeconds($expiresIn)

    Write-Log "OAuth2 token refreshed (expires in ${expiresIn}s)" -Level "INFO"
  }
  catch {
    Write-Log "Token refresh failed: $($_.Exception.Message) — re-authenticating" -Level "WARNING"
    Initialize-VBAHVPluginConnection
  }
}

function Invoke-VBAHVPluginAPI {
  <#
  .SYNOPSIS
    Execute a REST API call to the Veeam Plug-in for Nutanix AHV with retry logic
  .DESCRIPTION
    Calls the plugin REST API via the VBR extension endpoint. Includes
    exponential backoff retry for transient failures.
  .PARAMETER Method
    HTTP method (GET, POST, PUT, DELETE)
  .PARAMETER Endpoint
    API endpoint path appended to the plugin base URL
  .PARAMETER Body
    Request body hashtable (serialized to JSON)
  .PARAMETER RetryCount
    Max retries on transient failure (default: 3)
  .PARAMETER TimeoutSec
    Per-request timeout (default: 60s)
  #>
  param(
    [Parameter(Mandatory = $true)][ValidateSet("GET", "POST", "PUT", "DELETE")][string]$Method,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$Endpoint,
    [hashtable]$Body,
    [ValidateRange(0, 10)][int]$RetryCount = 3,
    [ValidateRange(1, 600)][int]$TimeoutSec = 60
  )

  # Proactively refresh token if within 5 minutes of expiry
  if ($script:VBAHVTokenExpiry -and (Get-Date) -gt $script:VBAHVTokenExpiry.AddMinutes(-5)) {
    Refresh-VBAHVToken
  }

  $url = "$($script:VBAHVBaseUrl)/$Endpoint"
  $attempt = 0

  while ($attempt -le $RetryCount) {
    try {
      $params = @{
        Method     = $Method
        Uri        = $url
        Headers    = $script:VBAHVHeaders
        TimeoutSec = $TimeoutSec
      }

      if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
      }

      if ($SkipCertificateCheck -and $PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipCertificateCheck = $true
      }

      return Invoke-RestMethod @params -ErrorAction Stop
    }
    catch {
      $statusCode = $null
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
      }

      # 401 Unauthorized — token likely expired, refresh and retry once
      if ($statusCode -eq 401) {
        Write-Log "VBAHV Plugin API returned 401 — refreshing OAuth2 token" -Level "WARNING"
        Refresh-VBAHVToken
        $attempt++
        continue
      }

      # Non-retryable client errors (except 429 Too Many Requests)
      if ($statusCode -and $statusCode -ge 400 -and $statusCode -lt 500 -and $statusCode -ne 429) {
        Write-Log "VBAHV Plugin API error ($statusCode): $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }

      $attempt++
      if ($attempt -gt $RetryCount) {
        Write-Log "VBAHV Plugin API failed after $RetryCount retries: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }

      $waitSec = [math]::Min([int]([math]::Pow(2, $attempt)), 30)
      Write-Log "VBAHV Plugin API transient failure (attempt $attempt/$RetryCount), retrying in ${waitSec}s" -Level "WARNING"
      Start-Sleep -Seconds $waitSec
    }
  }
}

# ============================================================================
# VBAHV Plugin REST API — Prism Central & VM Discovery
# ============================================================================

function Get-VBAHVPrismCentrals {
  <#
  .SYNOPSIS
    List Prism Centrals registered in the VBAHV Plugin
  .DESCRIPTION
    GET /prismCentrals — retrieves all Prism Centrals to which the AHV plugin has access.
    Each Prism Central has an ID used to discover VMs via /prismCentrals/{id}/vms.
  #>
  Write-Log "Discovering Prism Centrals via VBAHV Plugin REST API..." -Level "INFO"
  $result = Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "prismCentrals"

  if (-not $result -or @($result).Count -eq 0) {
    throw "No Prism Centrals found in VBAHV Plugin. Ensure at least one Prism Central is registered."
  }

  $count = @($result).Count
  Write-Log "Found $count Prism Central(s) in VBAHV Plugin" -Level "SUCCESS"
  return $result
}

function Get-VBAHVPrismCentralVMs {
  <#
  .SYNOPSIS
    List VMs from a Prism Central via the VBAHV Plugin with pagination
  .DESCRIPTION
    GET /prismCentrals/{id}/vms — retrieves all VMs known to the plugin from the
    specified Prism Central. Supports pagination (offset/limit) and optional name filter.

    Each VirtualMachine object has: id, name, clusterId, clusterName, disks,
    networkAdapters, vmSize, protectionDomain, consistencyGroup, guestOsVersion.
  .PARAMETER PrismCentralId
    ID of the Prism Central (from Get-VBAHVPrismCentrals)
  .PARAMETER VMNames
    Optional filter: only return VMs matching these names
  .PARAMETER PageSize
    Number of VMs per page (default: 100)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$PrismCentralId,
    [string[]]$VMNames,
    [ValidateRange(1, 500)][int]$PageSize = 100
  )

  $allVMs = New-Object System.Collections.Generic.List[object]
  $offset = 0

  do {
    $endpoint = "prismCentrals/$PrismCentralId/vms?limit=$PageSize&offset=$offset"
    $page = Invoke-VBAHVPluginAPI -Method "GET" -Endpoint $endpoint

    # PageOfVirtualMachine response: { results, totalCount, offset, limit }
    $results = $page.results
    if (-not $results -or @($results).Count -eq 0) { break }

    foreach ($vm in $results) {
      $allVMs.Add($vm)
    }

    $offset += @($results).Count
    $tc = $page.totalCount -as [int]
    $totalCount = if ($null -ne $tc) { $tc } else { $offset }
  } while ($offset -lt $totalCount)

  # Apply VM name filter if specified
  if ($VMNames -and $VMNames.Count -gt 0) {
    $filtered = @($allVMs | Where-Object { $_.name -in $VMNames })

    foreach ($vmName in $VMNames) {
      if ($vmName -notin @($filtered | ForEach-Object { $_.name })) {
        Write-Log "VM '$vmName' not found in Prism Central $PrismCentralId" -Level "WARNING"
      }
    }

    return $filtered
  }

  return @($allVMs)
}

# ============================================================================
# VBAHV Plugin REST API — Job Discovery
# ============================================================================

function Get-VBAHVJobs {
  <#
  .SYNOPSIS
    List backup jobs from the VBAHV Plugin REST API
  .DESCRIPTION
    GET /jobs — retrieves all backup jobs managed by the AHV plugin.
  .PARAMETER JobNames
    Optional filter: only return jobs matching these names
  #>
  param(
    [string[]]$JobNames
  )

  Write-Log "Discovering AHV backup jobs via VBAHV Plugin REST API..." -Level "INFO"
  $response = Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "jobs"
  # GET /jobs returns PageOfJob { results[] }
  $allJobs = @($response.results)

  if ($JobNames -and $JobNames.Count -gt 0) {
    $filtered = @($allJobs | Where-Object { $_.name -in $JobNames })

    # Warn about jobs not found
    foreach ($jobName in $JobNames) {
      if ($jobName -notin $filtered.name) {
        Write-Log "Backup job '$jobName' not found in VBAHV Plugin" -Level "WARNING"
      }
    }

    $allJobs = $filtered
  }

  if (-not $allJobs -or @($allJobs).Count -eq 0) {
    throw "No Nutanix AHV backup jobs found. Ensure AHV backup jobs exist and the VBAHV Plugin is configured."
  }

  $jobCount = @($allJobs).Count
  $jobNames = @($allJobs | ForEach-Object { $_.name }) -join ", "
  Write-Log "Found $jobCount AHV backup job(s): $jobNames" -Level "SUCCESS"
  return $allJobs
}

function Get-VBAHVProtectedVMs {
  <#
  .SYNOPSIS
    Discover protected VMs across all Prism Centrals via VBAHV Plugin REST API
  .DESCRIPTION
    The v9 API has no flat GET /restorePoints endpoint. VM discovery goes through:
    1. GET /prismCentrals — list all registered Prism Centrals
    2. GET /prismCentrals/{id}/vms — paginated VM list per Prism Central

    Each VirtualMachine object includes id, name, clusterId, clusterName, disks,
    networkAdapters. The VM id is the Nutanix environment UUID. For restore operations,
    the restorePointId required by POST /restorePoints/restore comes from the VBR core
    REST API (GET /api/v1/backupObjects/{id}/restorePoints), not from this endpoint.

    NOTE: The VM id from this endpoint may work directly as restorePointId for
    /restorePoints/{id}/metadata — verify against real infrastructure.
  .PARAMETER VMNames
    Optional filter: only return VMs matching these names
  #>
  param(
    [string[]]$VMNames
  )

  Write-Log "Discovering protected VMs via VBAHV Plugin (prismCentrals -> VMs)..." -Level "INFO"

  $prismCentrals = Get-VBAHVPrismCentrals
  $allVMs = New-Object System.Collections.Generic.List[object]

  foreach ($pc in @($prismCentrals)) {
    # PrismCentral objects may expose id directly or via settings
    $pcId = $pc.id
    if (-not $pcId) {
      # Some API versions nest the ID differently
      $pcId = $pc.settings.id
    }
    if (-not $pcId) {
      Write-Log "  Skipping Prism Central with no ID (address: $($pc.settings.address))" -Level "WARNING"
      continue
    }

    $pcAddress = if ($pc.settings.address) { $pc.settings.address } else { $pcId }
    Write-Log "  Querying Prism Central: $pcAddress ($pcId)" -Level "INFO"

    try {
      $vms = Get-VBAHVPrismCentralVMs -PrismCentralId $pcId -VMNames $VMNames
      if ($vms -and @($vms).Count -gt 0) {
        foreach ($vm in @($vms)) {
          $allVMs.Add($vm)
        }
        Write-Log "    Found $(@($vms).Count) VM(s) from $pcAddress" -Level "INFO"
      }
      else {
        Write-Log "    No VMs found in $pcAddress$(if ($VMNames) { " matching filter" })" -Level "WARNING"
      }
    }
    catch {
      Write-Log "    Failed to query VMs from $pcAddress`: $($_.Exception.Message)" -Level "WARNING"
    }
  }

  $totalCount = @($allVMs).Count
  if ($totalCount -eq 0) {
    Write-Log "No protected VMs found across any Prism Central" -Level "WARNING"
    return @()
  }

  Write-Log "Discovered $totalCount protected VM(s) across $(@($prismCentrals).Count) Prism Central(s)" -Level "SUCCESS"
  return @($allVMs)
}

function Get-VBAHVRestorePointMetadata {
  <#
  .SYNOPSIS
    Get VM metadata from a restore point (NICs, disks, cluster info)
  .DESCRIPTION
    GET /restorePoints/{id}/metadata — retrieves the original VM's full
    metadata from the backup. Includes network adapters, disks, cluster info.
  .PARAMETER RestorePointId
    The restore point ID from the plugin
  #>
  param(
    [Parameter(Mandatory = $true)][string]$RestorePointId
  )

  return Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "restorePoints/$RestorePointId/metadata"
}

# ============================================================================
# VBAHV Plugin REST API — Cluster & Infrastructure Discovery
# ============================================================================

function Get-VBAHVClusters {
  <#
  .SYNOPSIS
    List clusters from the VBAHV Plugin REST API
  .DESCRIPTION
    GET /clusters — retrieves all Nutanix clusters registered with the plugin.
    Used for resolving targetVmClusterId for restore operations.
  #>
  return Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "clusters"
}

function Get-VBAHVStorageContainers {
  <#
  .SYNOPSIS
    List storage containers for a cluster
  .DESCRIPTION
    GET /clusters/{id}/storageContainers — retrieves storage containers
    available on the specified cluster. Used for resolving storageContainerId.
  .PARAMETER ClusterId
    The cluster ID from the plugin
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ClusterId
  )

  # GET /clusters/{id}/storageContainers returns PageOfStorageContainer { results[] }
  $response = Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "clusters/$ClusterId/storageContainers"
  $containers = @($response.results)
  return $containers
}

# ============================================================================
# Full VM Restore via VBAHV Plugin REST API v9
# ============================================================================

function Start-AHVFullRestore {
  <#
  .SYNOPSIS
    Full VM restore via Veeam AHV Plugin REST API with network selection
  .DESCRIPTION
    Performs a full VM restore using POST /restorePoints/restore on the
    Veeam Plug-in for Nutanix AHV REST API (v9). This approach places the
    VM directly on the isolated network during restore — zero production
    network exposure.

    The VM is created as an independent VM (not a vPower NFS mount). Cleanup
    is performed by powering off and deleting via Nutanix Prism API.

    Workflow:
    1. Find matching restore point in plugin (from pre-discovered list)
    2. GET /restorePoints/{id}/metadata — get source NIC/disk/cluster info
    3. Resolve cluster ID and storage container ID
    4. POST /restorePoints/restore — submit restore with networkAdapters
       mapping each NIC to the isolated network
    5. GET /sessions/{id} — poll async task until completion
    6. Find restored VM in Prism, power on

    API Reference: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints
  .PARAMETER RestorePointInfo
    Restore point info object with VMName, RestorePointId, CreationTime
  .PARAMETER IsolatedNetwork
    Resolved isolated network object from Resolve-IsolatedNetwork
  .PARAMETER RestoreToOriginal
    Restore to original location (default: false for SureBackup)
  .PARAMETER RestoreVmCategories
    Restore VM categories/tags (default: false)
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePointInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork,
    [switch]$RestoreToOriginal,
    [switch]$RestoreVmCategories
  )

  $vmName = $RestorePointInfo.VMName
  $uniqueId = [guid]::NewGuid().ToString().Substring(0, 8)
  $recoveryName = "SureBackup_${vmName}_$(Get-Date -Format 'HHmmss')_${uniqueId}"

  Write-Log "Starting Full VM Restore via VBAHV Plugin REST API: $vmName -> $recoveryName" -Level "INFO"

  try {
    # Step 1: Use the restore point ID from the pre-discovered VM/restore point info
    # The RestorePointId comes from VM discovery via Get-VBAHVProtectedVMs (VM id from
    # prismCentrals/{pcId}/vms) or from VBR core API backup object restore points.
    $pluginRPId = $RestorePointInfo.RestorePointId
    if (-not $pluginRPId) {
      throw "No restore point ID available for '$vmName'. Ensure VM was discovered via Get-VBAHVProtectedVMs."
    }
    Write-Log "  Using restore point ID: $pluginRPId" -Level "INFO"

    # Step 2: Get VM metadata (NICs, disks, cluster) via /metadata endpoint
    Write-Log "  Retrieving restore point metadata..." -Level "INFO"
    $metadata = Get-VBAHVRestorePointMetadata -RestorePointId $pluginRPId

    # Extract cluster ID from metadata for targetVmClusterId
    $targetClusterId = $null
    if ($metadata.clusterId) {
      $targetClusterId = $metadata.clusterId
    }
    elseif ($TargetClusterName) {
      # Resolve cluster by name via GET /clusters
      $clusters = Get-VBAHVClusters
      $targetCluster = $clusters | Where-Object { $_.name -imatch [regex]::Escape($TargetClusterName) } | Select-Object -First 1
      if ($targetCluster) {
        $targetClusterId = $targetCluster.id
      }
    }

    # Resolve storage container ID
    $storageContainerId = $null
    if ($TargetContainerName -and $targetClusterId) {
      $containers = Get-VBAHVStorageContainers -ClusterId $targetClusterId
      $targetContainer = $containers | Where-Object { $_.name -imatch [regex]::Escape($TargetContainerName) } | Select-Object -First 1
      if ($targetContainer) {
        $storageContainerId = $targetContainer.id
      }
    }

    # Step 3: Build networkAdapters array using metadata
    # v9 schema: originalMacAddress + value { networkId, ipAddresses, macAddress }
    $sourceNICs = $metadata.networkAdapters
    $networkAdapterRemaps = @()
    if ($sourceNICs -and @($sourceNICs).Count -gt 0) {
      foreach ($nic in $sourceNICs) {
        $remap = @{
          originalMacAddress = if ($nic.macAddress) { $nic.macAddress } else { "" }
          value              = @{
            networkId = $IsolatedNetwork.UUID
          }
        }
        $networkAdapterRemaps += $remap
        Write-Log "  NIC $($nic.macAddress): $($nic.networkName) -> $($IsolatedNetwork.Name)" -Level "INFO"
      }
    }
    else {
      Write-Log "  No source NICs in backup metadata — VM will be restored without network" -Level "WARNING"
    }

    # Step 4: Build RestoreSettings body and POST /restorePoints/restore
    # Required fields per v9 spec: restoreToOriginal, powerOnVmAfterRestore, restoreVmCategories
    $restoreBody = @{
      restorePointId        = $pluginRPId
      targetVmName          = $recoveryName
      restoreToOriginal     = [bool]$RestoreToOriginal
      powerOnVmAfterRestore = $false
      restoreVmCategories   = [bool]$RestoreVmCategories
      reason                = "SureBackup automated verification - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    if ($targetClusterId) {
      $restoreBody.targetVmClusterId = $targetClusterId
    }

    if ($storageContainerId) {
      $restoreBody.storageContainerId = $storageContainerId
    }

    if ($networkAdapterRemaps.Count -gt 0) {
      $restoreBody.networkAdapters = $networkAdapterRemaps
    }

    Write-Log "  Submitting full restore to VBAHV Plugin API..." -Level "INFO"
    $restoreResult = Invoke-VBAHVPluginAPI -Method "POST" -Endpoint "restorePoints/restore" -Body $restoreBody -TimeoutSec 120

    # Step 5: Poll async task via GET /sessions/{id}
    # AsyncTask schema: { sessionId: string } — sessionId is the only documented field
    $sessionId = $restoreResult.sessionId

    if ($sessionId) {
      Write-Log "  Restore session: $sessionId — polling for completion..." -Level "INFO"
      $restoreTimeout = 1800  # 30 min max for full disk copy
      $pollInterval = 15
      $elapsed = 0

      while ($elapsed -lt $restoreTimeout) {
        Start-Sleep -Seconds $pollInterval
        $elapsed += $pollInterval

        try {
          $sessionStatus = Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "sessions/$sessionId"
          $state = $sessionStatus.state

          # SessionState enum: Unknown, Starting, Running, Finished, Cancelling, Cancelled
          # SessionResult enum: Unknown, None, Success, Warning, Error
          if ($state -eq "Finished") {
            $result = $sessionStatus.result
            if ($result -eq "Success" -or $result -eq "Warning") {
              Write-Log "  Full restore completed in ${elapsed}s (result: $result)" -Level "SUCCESS"
              break
            }
            else {
              $errMsg = if ($sessionStatus.progressState.events) {
                ($sessionStatus.progressState.events | Where-Object { $_.severity -eq "Error" } |
                 Select-Object -First 1).message
              } else { "result: $result" }
              throw "Full restore session failed: $errMsg"
            }
          }
          elseif ($state -eq "Cancelled") {
            throw "Full restore session was cancelled"
          }

          if ($elapsed % 60 -eq 0) {
            Write-Log "  Restore in progress... (${elapsed}s, state: $state)" -Level "INFO"
          }
        }
        catch {
          if ($_.Exception.Message -imatch "Full restore session failed") { throw }
        }
      }

      if ($elapsed -ge $restoreTimeout) {
        throw "Full restore timed out after ${restoreTimeout}s"
      }
    }
    else {
      throw "Restore API returned no sessionId — unexpected response format"
    }

    # Step 6: Find restored VM in Prism Central
    $discoveryTimeout = 120
    $discoveryInterval = 10
    $elapsed = 0
    $recoveredVM = $null

    Write-Log "  Locating restored VM in Prism Central..." -Level "INFO"
    while ($elapsed -lt $discoveryTimeout) {
      Start-Sleep -Seconds $discoveryInterval
      $elapsed += $discoveryInterval
      $recoveredVM = Get-PrismVMByName -Name $recoveryName
      if ($recoveredVM) { break }
    }

    if (-not $recoveredVM) {
      throw "Restored VM '$recoveryName' not found in Prism Central after ${discoveryTimeout}s"
    }

    $vmUUID = if ($PrismApiVersion -eq "v4") { $recoveredVM[0].extId } else { $recoveredVM[0].metadata.uuid }
    Write-Log "  Restored VM found: $vmUUID" -Level "SUCCESS"

    # Step 7: Power on — VM is already on isolated network (no NIC swap needed)
    Write-Log "  Powering on VM (already on isolated network '$($IsolatedNetwork.Name)')..." -Level "INFO"
    Set-PrismVMPowerState -UUID $vmUUID -State "ON"

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -RecoveryVMUUID $vmUUID -Status "Running" -RestoreMethod "FullRestore"
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
  catch {
    Write-Log "Full restore failed for '$vmName': $($_.Exception.Message)" -Level "ERROR"

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -Status "Failed" -Error $_.Exception.Message -RestoreMethod "FullRestore"
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
}

function Stop-AHVFullRestore {
  <#
  .SYNOPSIS
    Clean up a full-restore VM (power off + delete from Prism)
  .DESCRIPTION
    Full restore creates an independent VM. Cleanup = power off + Remove-PrismVM.
  #>
  param(
    [Parameter(Mandatory = $true)]$RecoveryInfo
  )

  $vmName = $RecoveryInfo.OriginalVMName

  try {
    if ($RecoveryInfo.RecoveryVMUUID) {
      # Power off
      Write-Log "  Powering off full-restore VM: $($RecoveryInfo.RecoveryVMName)" -Level "INFO"
      try {
        Set-PrismVMPowerState -UUID $RecoveryInfo.RecoveryVMUUID -State "OFF"
        Wait-PrismVMPowerState -UUID $RecoveryInfo.RecoveryVMUUID -State "OFF" -TimeoutSec 120 | Out-Null
      }
      catch { }

      # Delete VM from Prism
      Remove-PrismVM -UUID $RecoveryInfo.RecoveryVMUUID
      Write-Log "Cleaned up full-restore VM for '$vmName'" -Level "SUCCESS"
    }

    $RecoveryInfo.Status = "CleanedUp"
  }
  catch {
    Write-Log "Cleanup warning for '$vmName': $($_.Exception.Message)" -Level "WARNING"
    $RecoveryInfo.Status = "CleanupFailed"
  }
}
