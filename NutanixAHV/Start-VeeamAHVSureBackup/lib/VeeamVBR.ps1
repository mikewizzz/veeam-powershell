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

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -RecoveryVMUUID $vmUUID -VBRSession $session -Status "Running"
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
  catch {
    Write-Log "Instant recovery failed for '$vmName': $($_.Exception.Message)" -Level "ERROR"

    $recoveryInfo = _NewRecoveryInfo -OriginalVMName $vmName -RecoveryVMName $recoveryName -Status "Failed" -Error $_.Exception.Message
    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
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
