# =============================
# Veeam Backup & Replication Integration
# =============================

function Connect-VBRSession {
  <#
  .SYNOPSIS
    Connect to Veeam Backup & Replication server
  #>
  Write-Log "Connecting to Veeam Backup & Replication: $VBRServer" -Level "INFO"

  # Load Veeam PowerShell module
  $moduleLoaded = $false

  # Try modern module first (VBR v12+)
  if (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
    Import-Module Veeam.Backup.PowerShell -ErrorAction SilentlyContinue
    $moduleLoaded = $true
  }
  # Fall back to PSSnapin (legacy VBR)
  elseif (Get-PSSnapin -Registered -Name VeeamPSSnapin -ErrorAction SilentlyContinue) {
    Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue
    $moduleLoaded = $true
  }

  if (-not $moduleLoaded) {
    throw "Veeam PowerShell module not found. Install Veeam Backup & Replication Console or the standalone PowerShell module."
  }

  # Connect
  $connectParams = @{
    Server = $VBRServer
    Port   = $VBRPort
  }

  if ($VBRCredential) {
    $connectParams.Credential = $VBRCredential
  }

  try {
    Connect-VBRServer @connectParams -ErrorAction Stop
    Write-Log "Connected to VBR server: $VBRServer" -Level "SUCCESS"
  }
  catch {
    Write-Log "VBR connection failed: $($_.Exception.Message)" -Level "ERROR"
    throw
  }
}

function Disconnect-VBRSession {
  <#
  .SYNOPSIS
    Gracefully disconnect from VBR server
  #>
  try {
    Disconnect-VBRServer -ErrorAction SilentlyContinue
    Write-Log "Disconnected from VBR server" -Level "INFO"
  }
  catch {
    Write-Log "VBR disconnect warning: $($_.Exception.Message)" -Level "WARNING"
  }
}

function Get-AHVBackupJobs {
  <#
  .SYNOPSIS
    Discover Veeam backup jobs protecting Nutanix AHV workloads
  #>
  Write-Log "Discovering AHV backup jobs..." -Level "INFO"

  # Get all backup jobs, filter for Nutanix AHV type
  $allJobs = Get-VBRJob -ErrorAction Stop

  # Filter for AHV jobs (TypeToString contains "Nutanix" or platform is AHV)
  $ahvJobs = $allJobs | Where-Object {
    $_.TypeToString -imatch "Nutanix|AHV" -or
    $_.BackupPlatform -imatch "Nutanix|AHV" -or
    $_.JobType -eq "NutanixBackup"
  }

  if ($BackupJobNames -and $BackupJobNames.Count -gt 0) {
    $ahvJobs = $ahvJobs | Where-Object { $_.Name -in $BackupJobNames }

    # Warn about jobs not found
    foreach ($jobName in $BackupJobNames) {
      if ($jobName -notin $ahvJobs.Name) {
        Write-Log "Backup job '$jobName' not found or is not an AHV job" -Level "WARNING"
      }
    }
  }

  if ($ahvJobs.Count -eq 0) {
    throw "No Nutanix AHV backup jobs found. Ensure AHV backup jobs exist and the VBR connection is correct."
  }

  Write-Log "Found $($ahvJobs.Count) AHV backup job(s): $(($ahvJobs | ForEach-Object { $_.Name }) -join ', ')" -Level "SUCCESS"
  return $ahvJobs
}

function Get-AHVRestorePoints {
  <#
  .SYNOPSIS
    Get latest restore points for AHV VMs from Veeam backups
  #>
  param(
    [Parameter(Mandatory = $true)]$BackupJobs
  )

  Write-Log "Discovering restore points for AHV VMs..." -Level "INFO"
  $restorePoints = @()

  foreach ($job in $BackupJobs) {
    try {
      # Get the backup object
      $backup = Get-VBRBackup -Name $job.Name -ErrorAction Stop

      if (-not $backup) {
        Write-Log "No backup data found for job: $($job.Name)" -Level "WARNING"
        continue
      }

      # Get all objects (VMs) in this backup
      $objects = $backup.GetObjects()

      foreach ($obj in $objects) {
        $vmName = $obj.Name

        # Apply VM name filter
        if ($VMNames -and $VMNames.Count -gt 0 -and $vmName -notin $VMNames) {
          continue
        }

        # Get the latest restore point for this VM
        $rps = Get-VBRRestorePoint -Backup $backup -Name $vmName -ErrorAction SilentlyContinue |
          Sort-Object CreationTime -Descending

        if ($rps -and $rps.Count -gt 0) {
          $latestRP = $rps[0]
          $rpInfo = [PSCustomObject]@{
            VMName       = $vmName
            JobName      = $job.Name
            RestorePoint = $latestRP
            CreationTime = $latestRP.CreationTime
            BackupSize   = $latestRP.ApproxSize
            IsConsistent = $latestRP.IsConsistent
          }
          $restorePoints += $rpInfo
          Write-Log "  Found restore point for '$vmName' from $($latestRP.CreationTime.ToString('yyyy-MM-dd HH:mm'))" -Level "INFO"
        }
        else {
          Write-Log "  No restore points found for '$vmName' in job '$($job.Name)'" -Level "WARNING"
        }
      }
    }
    catch {
      Write-Log "Error processing job '$($job.Name)': $($_.Exception.Message)" -Level "ERROR"
    }
  }

  if ($restorePoints.Count -eq 0) {
    throw "No restore points found for any AHV VMs. Ensure backups have completed successfully."
  }

  Write-Log "Discovered $($restorePoints.Count) VM restore point(s) across $($BackupJobs.Count) job(s)" -Level "SUCCESS"
  return $restorePoints
}

function Start-AHVInstantRecovery {
  <#
  .SYNOPSIS
    Start Veeam Instant VM Recovery to Nutanix AHV in the isolated network
  .DESCRIPTION
    Uses Veeam's Instant VM Recovery for Nutanix AHV to mount the backup
    as a running VM on the target cluster, connected to the isolated network.
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePointInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $vmName = $RestorePointInfo.VMName
  $uniqueId = [guid]::NewGuid().ToString().Substring(0, 8)
  $recoveryName = "SureBackup_${vmName}_$(Get-Date -Format 'HHmmss')_${uniqueId}"

  Write-Log "Starting Instant VM Recovery: $vmName -> $recoveryName" -Level "INFO"

  try {
    # Get the Nutanix cluster/server object from VBR
    $ahvServers = Get-VBRServer -Type NutanixAhv -ErrorAction Stop

    if ($ahvServers.Count -eq 0) {
      throw "No Nutanix AHV servers registered in VBR. Add the AHV cluster via VBR console first."
    }

    $targetServer = $null
    if ($TargetClusterName) {
      $targetServer = $ahvServers | Where-Object { $_.Name -imatch $TargetClusterName }
    }
    if (-not $targetServer) {
      $targetServer = $ahvServers[0]
      Write-Log "Using AHV server: $($targetServer.Name)" -Level "INFO"
    }

    # Build instant recovery parameters
    $irParams = @{
      RestorePoint = $RestorePointInfo.RestorePoint
      Server       = $targetServer
      VMName       = $recoveryName
      Reason       = "SureBackup automated verification test - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    # Start Instant VM Recovery to AHV
    # NOTE: Start-VBRInstantRecoveryToNutanixAHV does not accept a network parameter,
    # so the VM initially boots with its original production NIC configuration.
    # We must immediately power it off and reconfigure the NIC before allowing it to run.
    $session = Start-VBRInstantRecoveryToNutanixAHV @irParams -ErrorAction Stop

    Write-Log "Instant recovery started for '$vmName' as '$recoveryName'" -Level "SUCCESS"

    # Poll for the VM to appear in Prism Central (retry instead of fixed sleep)
    $discoveryTimeout = 60
    $discoveryInterval = 5
    $elapsed = 0
    $recoveredVM = $null

    Write-Log "  Waiting for VM to appear in Prism Central (timeout: ${discoveryTimeout}s)..." -Level "INFO"
    while ($elapsed -lt $discoveryTimeout) {
      Start-Sleep -Seconds $discoveryInterval
      $elapsed += $discoveryInterval
      $recoveredVM = Get-PrismVMByName -Name $recoveryName
      if ($recoveredVM) { break }
    }

    if (-not $recoveredVM) {
      Write-Log "  CRITICAL: Recovered VM '$recoveryName' not found in Prism after ${discoveryTimeout}s" -Level "ERROR"
      Write-Log "  Stopping VBR recovery session to prevent orphaned VM on production network" -Level "ERROR"
      try { Stop-VBRInstantRecovery -InstantRecovery $session -ErrorAction Stop } catch { }
      throw "Network isolation failure: VM '$recoveryName' not discoverable in Prism Central — cannot reconfigure NIC"
    }

    $vmUUID = if ($PrismApiVersion -eq "v4") { $recoveredVM[0].extId } else { $recoveredVM[0].metadata.uuid }

    # Validate the isolated network is different from VM's original production network
    Test-NetworkIsolation -VMUUID $vmUUID -IsolatedNetwork $IsolatedNetwork

    # SAFETY: Immediately power off the VM to minimize production network exposure.
    # The VM was recovered with its original production NIC config because
    # Start-VBRInstantRecoveryToNutanixAHV does not accept a network parameter.
    Write-Log "  Powering off VM to isolate from production network..." -Level "INFO"
    try {
      Set-PrismVMPowerState -UUID $vmUUID -State "OFF"
      $isOff = Wait-PrismVMPowerState -UUID $vmUUID -State "OFF" -TimeoutSec 120
      if (-not $isOff) {
        throw "VM '$recoveryName' did not power off within 120s"
      }
    }
    catch {
      Write-Log "  CRITICAL: Cannot power off VM for network isolation: $($_.Exception.Message)" -Level "ERROR"
      Write-Log "  Aborting recovery to prevent production network exposure" -Level "ERROR"
      try { Stop-VBRInstantRecovery -InstantRecovery $session -ErrorAction Stop } catch { }
      throw "Network isolation failure: could not power off VM. Recovery aborted."
    }

    # Reconfigure NIC to isolated network while VM is powered off (safe)
    try {
      Set-PrismVMNIC -VMUUID $vmUUID -SubnetUUID $IsolatedNetwork.UUID
      Write-Log "  NIC reconfigured to isolated network: $($IsolatedNetwork.Name)" -Level "SUCCESS"
    }
    catch {
      # NIC reconfiguration failed — VM must NOT be powered back on with production NIC
      Write-Log "  CRITICAL: NIC reconfiguration failed: $($_.Exception.Message)" -Level "ERROR"
      Write-Log "  VM remains powered off. Aborting to prevent production exposure." -Level "ERROR"
      try { Stop-VBRInstantRecovery -InstantRecovery $session -ErrorAction Stop } catch { }
      throw "Network isolation failure: NIC reconfiguration failed. Recovery aborted."
    }

    # Power on the VM — it will now boot on the isolated network
    Write-Log "  Powering on VM on isolated network..." -Level "INFO"
    Set-PrismVMPowerState -UUID $vmUUID -State "ON"

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -RecoveryVMUUID $vmUUID -VBRSession $session -Status "Running" -RestoreMethod "InstantRecovery"
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
  catch {
    Write-Log "Instant recovery failed for '$vmName': $($_.Exception.Message)" -Level "ERROR"

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -Status "Failed" -Error $_.Exception.Message -RestoreMethod "InstantRecovery"
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
}

# ============================================================================
# Veeam Plug-in for Nutanix AHV REST API v9 (Full Restore)
# ============================================================================
# Since Veeam Plug-in for Nutanix AHV v8+, the plugin runs as a VBR server
# extension (no separate backup appliance). The REST API is accessed at:
#   https://<VBR-server>/extension/799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2/api/v9/
#
# Full VM restore via POST /restorePoints/restore supports network adapter
# mapping, which allows the VM to be created directly on the isolated network
# with zero production exposure — unlike instant recovery which has no network
# parameter.
#
# API Reference: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints
# Swagger UI:    https://<VBR-server>/extension/799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2/swagger/index.html
#
# RestoreSettings schema (from VeeamHub/veeam-nutanix auto-generated Swagger client):
#   sourceVmId                     (string, required) - Source VM ID in Nutanix AHV
#   restorePointId                 (string, required) - Restore point ID from the plugin
#   targetVmName                   (string)           - New VM name
#   storageContainerId             (string)           - Target storage container UUID
#   networkAdapters                (NetworkAdapterRemap[]) - NIC-to-network mapping
#   reason                         (string)           - Restore reason
#   powerOnVmAfterRestore          (bool)             - Power on after restore
#   disconnectNetworksAfterRestore (bool)             - Disconnect all NICs after restore
#   preserveOriginalVmId           (bool)             - Keep source VM ID
#
# NetworkAdapterRemap schema:
#   macAddress (string) - Source NIC MAC address (empty for new NICs)
#   value      (NetworkAdapter) - Target NIC config with networkId, networkName, etc.
#
# NetworkAdapter schema (GET /restorePoints/{id}/networkAdapters):
#   id          (string)   - NIC ID in Nutanix AHV
#   networkId   (string)   - Network UUID the NIC is connected to
#   networkName (string)   - Network name
#   ipAddresses (string[]) - IP addresses on the NIC
#   macAddress  (string)   - MAC address
# ============================================================================

# Veeam Plug-in for Nutanix AHV extension GUID (constant across installations)
$script:VBAHV_EXTENSION_GUID = "799a5a3e-ae1e-4eaf-86eb-8a9acc2670e2"

function Initialize-VBAHVPluginConnection {
  <#
  .SYNOPSIS
    Authenticate to the Veeam Plug-in for Nutanix AHV REST API via OAuth2
  .DESCRIPTION
    The plugin REST API runs as a VBR server extension (since v8, there is
    no separate backup appliance). Authentication uses the VBR server's
    OAuth2 token endpoint.

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
    throw "VBR credentials required for Full Restore mode. Provide -VBRCredential parameter."
  }

  $tokenParams = @{
    Method      = "POST"
    Uri         = $tokenUrl
    Body        = $tokenBody
    ContentType = "application/x-www-form-urlencoded"
    TimeoutSec  = 30
    ErrorAction = "Stop"
  }

  if ($PSVersionTable.PSVersion.Major -ge 7) {
    $tokenParams.SkipCertificateCheck = $true
  }

  try {
    $tokenResponse = Invoke-RestMethod @tokenParams
    $apiVersion = if ($VBAHVApiVersion) { $VBAHVApiVersion } else { "v9" }
    $script:VBAHVBaseUrl = "https://${vbrHost}:${vbrApiPort}/extension/$($script:VBAHV_EXTENSION_GUID)/api/$apiVersion"
    $script:VBAHVHeaders = @{
      "Authorization" = "Bearer $($tokenResponse.access_token)"
      "Content-Type"  = "application/json"
      "Accept"        = "application/json"
    }
    Write-Log "Veeam AHV Plugin REST API authenticated (API $apiVersion)" -Level "SUCCESS"
  }
  catch {
    throw "Veeam AHV Plugin authentication failed: $($_.Exception.Message). Verify VBR credentials and that the AHV plugin (v8+) is installed."
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

      if ($PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipCertificateCheck = $true
      }

      return Invoke-RestMethod @params -ErrorAction Stop
    }
    catch {
      $statusCode = $null
      if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
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

function Get-VBAHVRestorePoints {
  <#
  .SYNOPSIS
    List restore points from the Veeam AHV Plugin REST API
  .DESCRIPTION
    GET /restorePoints — retrieves all restore points available in the plugin.
    Used to find the plugin-side restore point ID corresponding to a VBR
    restore point.
  #>
  return Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "restorePoints"
}

function Get-VBAHVNetworkAdapters {
  <#
  .SYNOPSIS
    Get source NIC metadata from a restore point
  .DESCRIPTION
    GET /restorePoints/{id}/networkAdapters — retrieves the original VM's
    network adapter configuration from the backup metadata. Available for
    backups and backup snapshots only (not PD snapshots).

    Returns NetworkAdapter objects with: id, networkId, networkName,
    ipAddresses, macAddress.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$RestorePointId
  )

  return Invoke-VBAHVPluginAPI -Method "GET" -Endpoint "restorePoints/$RestorePointId/networkAdapters"
}

function Start-AHVFullRestore {
  <#
  .SYNOPSIS
    Full VM restore via Veeam AHV Plugin REST API with network selection
  .DESCRIPTION
    Performs a full VM restore using POST /restorePoints/restore on the
    Veeam Plug-in for Nutanix AHV REST API (v9). This approach places the
    VM directly on the isolated network during restore — zero production
    network exposure, unlike instant recovery which requires NIC hot-swap.

    The VM is created as an independent VM (not a vPower NFS mount). Cleanup
    is performed by powering off and deleting via Nutanix Prism API.

    Workflow:
    1. GET /restorePoints — find matching restore point in plugin
    2. GET /restorePoints/{id}/networkAdapters — get source NIC metadata
    3. POST /restorePoints/restore — submit restore with networkAdapters
       mapping each NIC to the isolated network
    4. GET /sessions/{id} — poll async task until completion
    5. Find restored VM in Prism, power on

    API Reference: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints
  .PARAMETER RestorePointInfo
    Restore point info object from Get-AHVRestorePoints
  .PARAMETER IsolatedNetwork
    Resolved isolated network object from Resolve-IsolatedNetwork
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePointInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $vmName = $RestorePointInfo.VMName
  $uniqueId = [guid]::NewGuid().ToString().Substring(0, 8)
  $recoveryName = "SureBackup_${vmName}_$(Get-Date -Format 'HHmmss')_${uniqueId}"

  Write-Log "Starting Full VM Restore via VBAHV Plugin REST API: $vmName -> $recoveryName" -Level "INFO"

  try {
    # Step 1: Find the corresponding restore point in the plugin
    Write-Log "  Querying VBAHV Plugin for restore points..." -Level "INFO"
    $pluginRPs = Get-VBAHVRestorePoints

    # Match by VM name and closest creation time
    $targetCreationTime = $RestorePointInfo.CreationTime
    $matchedRP = $null

    $candidates = @($pluginRPs | Where-Object {
      $_.vmName -eq $vmName -or $_.name -imatch [regex]::Escape($vmName)
    })

    if ($candidates.Count -gt 0) {
      $matchedRP = $candidates | Sort-Object {
        [math]::Abs(([datetime]$_.creationTime - $targetCreationTime).TotalSeconds)
      } | Select-Object -First 1
    }

    if (-not $matchedRP) {
      throw "No matching restore point for '$vmName' in VBAHV Plugin. Ensure the plugin has access to the backup repository."
    }

    $pluginRPId = $matchedRP.id
    # sourceVmId is required by RestoreSettings schema
    $sourceVmId = $matchedRP.vmId
    if (-not $sourceVmId) {
      $sourceVmId = $matchedRP.sourceVmId
    }

    Write-Log "  Matched plugin restore point: $pluginRPId (VM ID: $sourceVmId, created: $($matchedRP.creationTime))" -Level "INFO"

    # Step 2: Get source network adapters (GET /restorePoints/{id}/networkAdapters)
    Write-Log "  Retrieving source network adapter configuration..." -Level "INFO"
    $sourceNICs = Get-VBAHVNetworkAdapters -RestorePointId $pluginRPId

    # Step 3: Build networkAdapters array (NetworkAdapterRemap schema)
    # Each element maps a source MAC to a target NetworkAdapter with networkId
    $networkAdapterRemaps = @()
    if ($sourceNICs -and $sourceNICs.Count -gt 0) {
      foreach ($nic in $sourceNICs) {
        $remap = @{
          macAddress = if ($nic.macAddress) { $nic.macAddress } else { "" }
          value      = @{
            networkId   = $IsolatedNetwork.UUID
            networkName = $IsolatedNetwork.Name
          }
        }
        $networkAdapterRemaps += $remap
        Write-Log "  NIC $($nic.macAddress): $($nic.networkName) -> $($IsolatedNetwork.Name)" -Level "INFO"
      }
    }
    else {
      Write-Log "  No source NICs in backup metadata — VM will use disconnectNetworksAfterRestore" -Level "WARNING"
    }

    # Step 4: Build RestoreSettings body and POST /restorePoints/restore
    $restoreBody = @{
      sourceVmId            = $sourceVmId
      restorePointId        = $pluginRPId
      targetVmName          = $recoveryName
      powerOnVmAfterRestore = $false
      reason                = "SureBackup automated verification - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    }

    if ($networkAdapterRemaps.Count -gt 0) {
      $restoreBody.networkAdapters = $networkAdapterRemaps
    }
    else {
      $restoreBody.disconnectNetworksAfterRestore = $true
    }

    if ($TargetContainerName) {
      $restoreBody.storageContainerId = $TargetContainerName
    }

    Write-Log "  Submitting full restore to VBAHV Plugin API..." -Level "INFO"
    $restoreResult = Invoke-VBAHVPluginAPI -Method "POST" -Endpoint "restorePoints/restore" -Body $restoreBody -TimeoutSec 120

    # Step 5: Poll async task via GET /sessions/{id}
    # The POST returns an AsyncTask with an id to track progress
    $sessionId = $restoreResult.id
    if (-not $sessionId) { $sessionId = $restoreResult.sessionId }

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

          if ($state -imatch "Success|Completed|Finished") {
            Write-Log "  Full restore completed in ${elapsed}s" -Level "SUCCESS"
            break
          }
          elseif ($state -imatch "Failed|Error|Canceled") {
            $errMsg = if ($sessionStatus.message) { $sessionStatus.message } else { "unknown error" }
            throw "Full restore session failed: $errMsg"
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
      Write-Log "  Full restore completed (synchronous response)" -Level "SUCCESS"
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
    Unlike instant recovery (which stops a VBR vPower session), full restore
    creates an independent VM. Cleanup = power off + Remove-PrismVM.
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

function Stop-AHVInstantRecovery {
  <#
  .SYNOPSIS
    Stop an Instant VM Recovery session and clean up the recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)]$RecoveryInfo
  )

  $vmName = $RecoveryInfo.OriginalVMName

  try {
    if ($RecoveryInfo.VBRSession) {
      Stop-VBRInstantRecovery -InstantRecovery $RecoveryInfo.VBRSession -ErrorAction Stop
      Write-Log "Stopped instant recovery session for '$vmName'" -Level "SUCCESS"
    }

    # Double-check: remove VM from Prism if it persists
    if ($RecoveryInfo.RecoveryVMUUID) {
      Start-Sleep -Seconds 5
      $stillExists = $null
      try {
        $stillExists = Get-PrismVMByUUID -UUID $RecoveryInfo.RecoveryVMUUID
      }
      catch { }

      if ($stillExists) {
        # Power off first if still running, then delete
        Write-Log "  Force powering off lingering VM: $($RecoveryInfo.RecoveryVMName)" -Level "WARNING"
        try {
          Set-PrismVMPowerState -UUID $RecoveryInfo.RecoveryVMUUID -State "OFF"
          Start-Sleep -Seconds 10
        }
        catch { }

        Remove-PrismVM -UUID $RecoveryInfo.RecoveryVMUUID
      }
    }

    $RecoveryInfo.Status = "CleanedUp"
  }
  catch {
    Write-Log "Cleanup warning for '$vmName': $($_.Exception.Message)" -Level "WARNING"
    $RecoveryInfo.Status = "CleanupFailed"
  }
}
