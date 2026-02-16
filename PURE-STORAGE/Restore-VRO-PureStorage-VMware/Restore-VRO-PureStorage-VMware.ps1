<#
.SYNOPSIS
  Pure Storage FlashArray Snapshot Recovery to VMware - Veeam Recovery Orchestrator Integration

.DESCRIPTION
  Recovery tool that restores Veeam-protected VMs from Pure Storage FlashArray snapshots
  to VMware vSphere infrastructure.

  WHAT THIS SCRIPT DOES:
  1. Connects to Pure Storage FlashArray and discovers available snapshots
  2. Connects to VMware vCenter for VM restoration
  3. Clones selected snapshot to a new FlashArray volume
  4. Presents the cloned volume to the target ESXi host
  5. Registers the VMFS datastore and inventories VMs on it
  6. Registers and optionally powers on recovered VMs
  7. Generates professional HTML recovery report
  8. Optionally cleans up temporary volumes after recovery

  RECOVERY WORKFLOW:
  Pure Snapshot -> Clone Volume -> Present to ESXi -> Mount Datastore -> Register VMs -> Verify

  QUICK START:
  .\Restore-VRO-PureStorage-VMware.ps1 -FlashArrayEndpoint "pure01.corp.local" -VCenterServer "vcsa.corp.local"

  AUTHENTICATION:
  - Pure Storage: API token (recommended) or credential-based
  - VMware: Credential-based or existing PowerCLI session

.PARAMETER FlashArrayEndpoint
  FQDN or IP of the Pure Storage FlashArray management interface.

.PARAMETER PureApiToken
  Pure Storage API token for authentication (recommended over credentials).

.PARAMETER PureCredential
  PSCredential for Pure Storage authentication (alternative to API token).

.PARAMETER VCenterServer
  FQDN or IP of the VMware vCenter Server.

.PARAMETER VCenterCredential
  PSCredential for vCenter authentication. If omitted, uses current Windows session or prompts.

.PARAMETER ProtectionGroupName
  Name of the Pure Storage Protection Group containing the VM volumes.
  If omitted, all protection groups are listed for selection.

.PARAMETER SnapshotName
  Specific snapshot name to restore from. If omitted, available snapshots are listed for selection.

.PARAMETER TargetHostName
  ESXi host name where recovered VMs will be registered. If omitted, available hosts are listed.

.PARAMETER TargetDatastoreName
  Name for the recovered datastore. Default: "DS-PureRecovery-<timestamp>".

.PARAMETER TargetPortGroup
  VMware port group to attach recovered VM NICs to. If omitted, VMs keep original network config.

.PARAMETER TargetFolder
  VMware VM folder for recovered VMs. Default: "Recovered-VMs".

.PARAMETER TargetResourcePool
  Resource pool for recovered VMs. If omitted, uses the host default resource pool.

.PARAMETER VMNamePrefix
  Prefix to add to recovered VM names to avoid conflicts. Default: "REC-".

.PARAMETER VMNames
  Filter to specific VM names within the snapshot. If omitted, all VMs on the datastore are recovered.

.PARAMETER PowerOnVMs
  Power on recovered VMs after registration. Default: false (safe mode).

.PARAMETER AnswerSourceVM
  Answer "I Copied It" when asked about VM UUID to avoid conflicts with source VMs.
  Default: true.

.PARAMETER HostGroupName
  Pure Storage Host Group name for volume presentation. If omitted, auto-detected from existing mappings.

.PARAMETER Protocol
  Storage protocol for volume presentation: "FC" (Fibre Channel) or "iSCSI". Default: auto-detect.

.PARAMETER CleanupOnFailure
  Automatically remove cloned volumes and datastore if recovery fails. Default: true.

.PARAMETER SkipDatastoreRescan
  Skip storage rescan on ESXi host (use if rescan is slow). Default: false.

.PARAMETER OutputPath
  Output folder for reports and logs. Default: ./PureRecovery_<timestamp>.

.PARAMETER GenerateHTML
  Generate professional HTML recovery report. Default: true.

.PARAMETER ZipOutput
  Create ZIP archive of all outputs. Default: true.

.PARAMETER WhatIf
  Preview recovery actions without making changes. Useful for validation.

.EXAMPLE
  .\Restore-VRO-PureStorage-VMware.ps1 -FlashArrayEndpoint "pure01.corp.local" -VCenterServer "vcsa.corp.local"
  # Interactive mode - prompts for credentials and lists available snapshots

.EXAMPLE
  $pureCred = Get-Credential -UserName "pureuser"
  $vcCred = Get-Credential -UserName "administrator@vsphere.local"
  .\Restore-VRO-PureStorage-VMware.ps1 `
    -FlashArrayEndpoint "pure01.corp.local" `
    -PureApiToken "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -VCenterServer "vcsa.corp.local" `
    -VCenterCredential $vcCred `
    -ProtectionGroupName "PG-VeeamVMs" `
    -TargetHostName "esxi01.corp.local" `
    -PowerOnVMs

.EXAMPLE
  .\Restore-VRO-PureStorage-VMware.ps1 `
    -FlashArrayEndpoint "pure01.corp.local" `
    -PureApiToken $token `
    -VCenterServer "vcsa.corp.local" `
    -ProtectionGroupName "PG-VeeamVMs" `
    -VMNames @("SQL-Prod-01","APP-Prod-01") `
    -TargetPortGroup "VLAN100-Prod" `
    -VMNamePrefix "DR-" `
    -PowerOnVMs
  # Recover specific VMs with custom prefix and network mapping

.EXAMPLE
  .\Restore-VRO-PureStorage-VMware.ps1 `
    -FlashArrayEndpoint "pure01.corp.local" `
    -VCenterServer "vcsa.corp.local" `
    -WhatIf
  # Preview mode - shows what would happen without making changes

.NOTES
  Version: 1.0.0
  Date: 2026-02-15
  Author: Community Contributors
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: PureStoragePowerShellSDK2, VMware.PowerCLI
#>

[CmdletBinding(SupportsShouldProcess)]
param(
  # ===== Pure Storage Connection =====
  [Parameter(Mandatory=$true)]
  [string]$FlashArrayEndpoint,

  [string]$PureApiToken,

  [PSCredential]$PureCredential,

  # ===== VMware Connection =====
  [Parameter(Mandatory=$true)]
  [string]$VCenterServer,

  [PSCredential]$VCenterCredential,

  # ===== Snapshot Selection =====
  [string]$ProtectionGroupName,

  [string]$SnapshotName,

  # ===== Target Configuration =====
  [string]$TargetHostName,

  [string]$TargetDatastoreName,

  [string]$TargetPortGroup,

  [string]$TargetFolder = "Recovered-VMs",

  [string]$TargetResourcePool,

  [string]$VMNamePrefix = "REC-",

  [string[]]$VMNames,

  [switch]$PowerOnVMs,

  [bool]$AnswerSourceVM = $true,

  # ===== Storage Presentation =====
  [string]$HostGroupName,

  [ValidateSet("FC","iSCSI","Auto")]
  [string]$Protocol = "Auto",

  # ===== Behavior =====
  [bool]$CleanupOnFailure = $true,

  [switch]$SkipDatastoreRescan,

  # ===== Output =====
  [string]$OutputPath,

  [bool]$GenerateHTML = $true,

  [bool]$ZipOutput = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-Level Variables
# =============================

$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:RecoveryActions = New-Object System.Collections.Generic.List[object]
$script:RecoveredVMs = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 10
$script:CurrentStep = 0
$script:FlashArray = $null
$script:VIConnection = $null
$script:ClonedVolumeName = $null
$script:MountedDatastore = $null
$script:RecoverySucceeded = $false

# =============================
# Logging & Progress
# =============================
#region Logging

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("INFO","WARNING","ERROR","SUCCESS","DEBUG")]
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
    "DEBUG"   { "DarkGray" }
    default   { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-ProgressStep {
  param(
    [Parameter(Mandatory=$true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $percentComplete = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Pure Storage VM Recovery" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity" -Level "INFO"
}

function Add-RecoveryAction {
  param(
    [Parameter(Mandatory=$true)][string]$Action,
    [Parameter(Mandatory=$true)][string]$Target,
    [ValidateSet("Pending","InProgress","Success","Failed","Skipped")]
    [string]$Status = "Pending",
    [string]$Detail = ""
  )

  $entry = [PSCustomObject]@{
    Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Action    = $Action
    Target    = $Target
    Status    = $Status
    Detail    = $Detail
  }
  $script:RecoveryActions.Add($entry)
}

#endregion

# =============================
# Module Verification
# =============================
#region Modules

function Assert-RequiredModules {
  Write-ProgressStep -Activity "Checking prerequisites" -Status "Verifying modules..."

  $modules = @(
    @{ Name = "PureStoragePowerShellSDK2"; Display = "Pure Storage PowerShell SDK 2" }
    @{ Name = "VMware.PowerCLI";           Display = "VMware PowerCLI" }
  )

  $missing = @()
  foreach ($mod in $modules) {
    if (Get-Module -ListAvailable -Name $mod.Name) {
      Import-Module $mod.Name -ErrorAction Stop
      Write-Log "Module loaded: $($mod.Display)" -Level "SUCCESS"
    } else {
      $missing += $mod
      Write-Log "Module missing: $($mod.Display)" -Level "ERROR"
    }
  }

  if ($missing.Count -gt 0) {
    $installCmds = ($missing | ForEach-Object { "Install-Module -Name $($_.Name) -Scope CurrentUser -Force" }) -join "`n"
    throw @"
Missing required PowerShell modules. Install them with:

$installCmds

Then re-run this script.
"@
  }

  # Suppress VMware CEIP warning
  try {
    $null = Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false -ErrorAction SilentlyContinue
    $null = Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false -ErrorAction SilentlyContinue
  } catch {
    Write-Log "Could not configure PowerCLI CEIP/certificate settings (non-fatal)" -Level "DEBUG"
  }
}

#endregion

# =============================
# Pure Storage Connection
# =============================
#region PureStorage

function Connect-PureArray {
  Write-ProgressStep -Activity "Connecting to Pure Storage FlashArray" -Status "$FlashArrayEndpoint"
  Add-RecoveryAction -Action "Connect to FlashArray" -Target $FlashArrayEndpoint -Status "InProgress"

  try {
    if ($PureApiToken) {
      Write-Log "Authenticating to FlashArray with API token..." -Level "INFO"
      $script:FlashArray = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint -ApiToken $PureApiToken -IgnoreCertificateError
    }
    elseif ($PureCredential) {
      Write-Log "Authenticating to FlashArray with credentials..." -Level "INFO"
      $script:FlashArray = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint -Credential $PureCredential -IgnoreCertificateError
    }
    else {
      Write-Log "No Pure Storage credentials provided - prompting..." -Level "WARNING"
      $cred = Get-Credential -Message "Enter Pure Storage FlashArray credentials for $FlashArrayEndpoint"
      $script:FlashArray = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint -Credential $cred -IgnoreCertificateError
    }

    $arrayInfo = Get-Pfa2Array
    Write-Log "Connected to FlashArray: $($arrayInfo.Name) (Model: $($arrayInfo.Model), OS: $($arrayInfo.Os))" -Level "SUCCESS"
    Add-RecoveryAction -Action "Connect to FlashArray" -Target $FlashArrayEndpoint -Status "Success" -Detail "Array: $($arrayInfo.Name)"
  }
  catch {
    Add-RecoveryAction -Action "Connect to FlashArray" -Target $FlashArrayEndpoint -Status "Failed" -Detail $_.Exception.Message
    throw "Failed to connect to Pure Storage FlashArray '$FlashArrayEndpoint': $($_.Exception.Message)"
  }
}

function Get-PureProtectionGroups {
  Write-Log "Discovering Protection Groups..." -Level "INFO"

  $allPGs = Get-Pfa2ProtectionGroup

  if ($allPGs.Count -eq 0) {
    throw "No Protection Groups found on FlashArray '$FlashArrayEndpoint'."
  }

  Write-Log "Found $($allPGs.Count) Protection Group(s)" -Level "INFO"
  return $allPGs
}

function Select-Snapshot {
  Write-ProgressStep -Activity "Discovering snapshots" -Status "Querying FlashArray..."

  # Get protection group snapshots
  if ($ProtectionGroupName) {
    Write-Log "Listing snapshots for Protection Group: $ProtectionGroupName" -Level "INFO"
    $snapshots = Get-Pfa2ProtectionGroupSnapshot -Name "$ProtectionGroupName.*" | Sort-Object -Property Created -Descending
  }
  else {
    # List protection groups for selection
    $pgs = Get-PureProtectionGroups

    Write-Host ""
    Write-Host "Available Protection Groups:" -ForegroundColor Cyan
    Write-Host ("-" * 60) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $pgs.Count; $i++) {
      $volCount = ($pgs[$i].Volumes).Count
      Write-Host "  [$($i+1)] $($pgs[$i].Name) ($volCount volume(s))" -ForegroundColor White
    }
    Write-Host ""

    do {
      $selection = Read-Host "Select Protection Group [1-$($pgs.Count)]"
    } while ($selection -lt 1 -or $selection -gt $pgs.Count)

    $ProtectionGroupName = $pgs[$selection - 1].Name
    Write-Log "Selected Protection Group: $ProtectionGroupName" -Level "INFO"
    $snapshots = Get-Pfa2ProtectionGroupSnapshot -Name "$ProtectionGroupName.*" | Sort-Object -Property Created -Descending
  }

  if ($snapshots.Count -eq 0) {
    throw "No snapshots found for Protection Group '$ProtectionGroupName'."
  }

  # If specific snapshot requested, find it
  if ($SnapshotName) {
    $selected = $snapshots | Where-Object { $_.Name -eq $SnapshotName }
    if (-not $selected) {
      throw "Snapshot '$SnapshotName' not found in Protection Group '$ProtectionGroupName'."
    }
    Write-Log "Using specified snapshot: $SnapshotName" -Level "INFO"
    return $selected
  }

  # Interactive selection - show most recent snapshots
  $showCount = [math]::Min($snapshots.Count, 20)
  Write-Host ""
  Write-Host "Available Snapshots (most recent $showCount of $($snapshots.Count)):" -ForegroundColor Cyan
  Write-Host ("-" * 80) -ForegroundColor DarkGray
  Write-Host ("  {0,-4} {1,-50} {2,-25}" -f "#", "Snapshot Name", "Created") -ForegroundColor DarkCyan

  for ($i = 0; $i -lt $showCount; $i++) {
    $created = $snapshots[$i].Created.ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host ("  [{0,-2}] {1,-50} {2,-25}" -f ($i+1), $snapshots[$i].Name, $created) -ForegroundColor White
  }
  Write-Host ""

  do {
    $selection = Read-Host "Select snapshot [1-$showCount]"
  } while ($selection -lt 1 -or $selection -gt $showCount)

  $selected = $snapshots[$selection - 1]
  Write-Log "Selected snapshot: $($selected.Name) (Created: $($selected.Created))" -Level "SUCCESS"
  Add-RecoveryAction -Action "Select Snapshot" -Target $selected.Name -Status "Success" -Detail "Created: $($selected.Created)"

  return $selected
}

function Get-SnapshotVolumes {
  param(
    [Parameter(Mandatory=$true)]$Snapshot
  )

  Write-Log "Discovering volumes in snapshot: $($Snapshot.Name)..." -Level "INFO"

  # Get the volume snapshots within this protection group snapshot
  $volSnaps = Get-Pfa2VolumeSnapshot -Name "$($Snapshot.Name).*"

  if ($volSnaps.Count -eq 0) {
    throw "No volume snapshots found in '$($Snapshot.Name)'."
  }

  Write-Log "Found $($volSnaps.Count) volume snapshot(s) in protection group snapshot" -Level "INFO"

  foreach ($vs in $volSnaps) {
    $sizeGB = [math]::Round($vs.Provisioned / 1GB, 2)
    Write-Log "  Volume: $($vs.Name) ($sizeGB GB)" -Level "INFO"
  }

  return $volSnaps
}

#endregion

# =============================
# VMware Connection
# =============================
#region VMware

function Connect-VCenterServer {
  Write-ProgressStep -Activity "Connecting to VMware vCenter" -Status "$VCenterServer"
  Add-RecoveryAction -Action "Connect to vCenter" -Target $VCenterServer -Status "InProgress"

  try {
    # Check for existing connection
    $existing = $global:DefaultVIServers | Where-Object { $_.Name -eq $VCenterServer -and $_.IsConnected }
    if ($existing) {
      Write-Log "Reusing existing vCenter connection: $VCenterServer" -Level "SUCCESS"
      $script:VIConnection = $existing
      Add-RecoveryAction -Action "Connect to vCenter" -Target $VCenterServer -Status "Success" -Detail "Reused session"
      return
    }

    if ($VCenterCredential) {
      $script:VIConnection = Connect-VIServer -Server $VCenterServer -Credential $VCenterCredential -ErrorAction Stop
    }
    else {
      Write-Log "No vCenter credentials provided - prompting..." -Level "WARNING"
      $script:VIConnection = Connect-VIServer -Server $VCenterServer -ErrorAction Stop
    }

    Write-Log "Connected to vCenter: $VCenterServer (Version: $($script:VIConnection.Version))" -Level "SUCCESS"
    Add-RecoveryAction -Action "Connect to vCenter" -Target $VCenterServer -Status "Success" -Detail "Version: $($script:VIConnection.Version)"
  }
  catch {
    Add-RecoveryAction -Action "Connect to vCenter" -Target $VCenterServer -Status "Failed" -Detail $_.Exception.Message
    throw "Failed to connect to vCenter '$VCenterServer': $($_.Exception.Message)"
  }
}

function Select-TargetHost {
  Write-ProgressStep -Activity "Selecting target ESXi host" -Status "Querying vCenter..."

  if ($TargetHostName) {
    $vmHost = Get-VMHost -Name $TargetHostName -ErrorAction SilentlyContinue
    if (-not $vmHost) {
      throw "ESXi host '$TargetHostName' not found in vCenter."
    }
    if ($vmHost.ConnectionState -ne "Connected") {
      throw "ESXi host '$TargetHostName' is not connected (State: $($vmHost.ConnectionState))."
    }
    Write-Log "Using specified ESXi host: $TargetHostName" -Level "INFO"
    return $vmHost
  }

  # Interactive selection
  $hosts = Get-VMHost | Where-Object { $_.ConnectionState -eq "Connected" } | Sort-Object Name
  if ($hosts.Count -eq 0) {
    throw "No connected ESXi hosts found in vCenter."
  }

  Write-Host ""
  Write-Host "Available ESXi Hosts:" -ForegroundColor Cyan
  Write-Host ("-" * 80) -ForegroundColor DarkGray
  Write-Host ("  {0,-4} {1,-40} {2,-10} {3,-15}" -f "#", "Host", "State", "Version") -ForegroundColor DarkCyan

  for ($i = 0; $i -lt $hosts.Count; $i++) {
    Write-Host ("  [{0,-2}] {1,-40} {2,-10} {3,-15}" -f ($i+1), $hosts[$i].Name, $hosts[$i].ConnectionState, $hosts[$i].Version) -ForegroundColor White
  }
  Write-Host ""

  do {
    $selection = Read-Host "Select target ESXi host [1-$($hosts.Count)]"
  } while ($selection -lt 1 -or $selection -gt $hosts.Count)

  $selected = $hosts[$selection - 1]
  Write-Log "Selected ESXi host: $($selected.Name)" -Level "SUCCESS"
  return $selected
}

#endregion

# =============================
# Volume Clone & Presentation
# =============================
#region VolumePresentation

function New-SnapshotClone {
  param(
    [Parameter(Mandatory=$true)]$VolumeSnapshots
  )

  Write-ProgressStep -Activity "Cloning snapshot volumes" -Status "Creating FlashArray clones..."

  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $clonedVolumes = @()

  foreach ($volSnap in $VolumeSnapshots) {
    # Derive a clean volume name from the snapshot
    $baseVolName = ($volSnap.Name -split "\.")[-1]
    $cloneName = "veeam-recovery-$baseVolName-$timestamp"
    $script:ClonedVolumeName = $cloneName

    if ($PSCmdlet.ShouldProcess($cloneName, "Create volume clone from $($volSnap.Name)")) {
      try {
        Add-RecoveryAction -Action "Clone Volume" -Target $cloneName -Status "InProgress" -Detail "Source: $($volSnap.Name)"

        $cloned = New-Pfa2Volume -Name $cloneName -SourceName $volSnap.Name
        $sizeGB = [math]::Round($cloned.Provisioned / 1GB, 2)
        Write-Log "Cloned volume: $cloneName ($sizeGB GB) from $($volSnap.Name)" -Level "SUCCESS"

        Add-RecoveryAction -Action "Clone Volume" -Target $cloneName -Status "Success" -Detail "$sizeGB GB"

        $clonedVolumes += [PSCustomObject]@{
          VolumeName   = $cloneName
          SourceSnap   = $volSnap.Name
          SizeGB       = $sizeGB
          Serial       = $cloned.Serial
          PureObject   = $cloned
        }
      }
      catch {
        Add-RecoveryAction -Action "Clone Volume" -Target $cloneName -Status "Failed" -Detail $_.Exception.Message
        throw "Failed to clone volume snapshot '$($volSnap.Name)': $($_.Exception.Message)"
      }
    }
    else {
      Add-RecoveryAction -Action "Clone Volume" -Target $cloneName -Status "Skipped" -Detail "WhatIf mode"
      Write-Log "[WhatIf] Would clone $($volSnap.Name) -> $cloneName" -Level "INFO"
    }
  }

  return $clonedVolumes
}

function Resolve-HostGroup {
  param(
    [Parameter(Mandatory=$true)]$VMHost
  )

  Write-Log "Resolving Pure Storage Host Group for ESXi host: $($VMHost.Name)..." -Level "INFO"

  if ($HostGroupName) {
    $hg = Get-Pfa2HostGroup -Name $HostGroupName -ErrorAction SilentlyContinue
    if (-not $hg) {
      throw "Host Group '$HostGroupName' not found on FlashArray."
    }
    Write-Log "Using specified Host Group: $HostGroupName" -Level "INFO"
    return $HostGroupName
  }

  # Auto-detect: match ESXi host WWNs or IQN to Pure hosts, then find host group
  $hostAdapters = Get-VMHostHBA -VMHost $VMHost -ErrorAction SilentlyContinue

  # Try Fibre Channel first
  $fcWWNs = @()
  $iscsiIQNs = @()

  foreach ($hba in $hostAdapters) {
    if ($hba.Type -eq "FibreChannel" -and $hba.Status -eq "online") {
      # Format WWN to match Pure format (lowercase, no colons)
      $wwn = ($hba.PortWorldWideName.ToString().ToLower()) -replace "[:-]",""
      $fcWWNs += $wwn
    }
    elseif ($hba.Type -eq "IScsi") {
      $iscsiIQNs += $hba.IScsiName
    }
  }

  Write-Log "ESXi host adapters - FC WWNs: $($fcWWNs.Count), iSCSI IQNs: $($iscsiIQNs.Count)" -Level "DEBUG"

  # Search Pure hosts for a match
  $pureHosts = Get-Pfa2Host

  foreach ($ph in $pureHosts) {
    # Check FC WWNs
    if ($ph.Wwns) {
      foreach ($pureWWN in $ph.Wwns) {
        $normalizedPureWWN = $pureWWN.ToLower() -replace "[:-]",""
        if ($fcWWNs -contains $normalizedPureWWN) {
          if ($ph.HostGroup.Name) {
            Write-Log "Auto-detected Host Group: $($ph.HostGroup.Name) (via FC WWN match on host '$($ph.Name)')" -Level "SUCCESS"
            if ($Protocol -eq "Auto") { $script:DetectedProtocol = "FC" }
            return $ph.HostGroup.Name
          }
          # Host found but not in a group - use host directly
          Write-Log "ESXi host matches Pure host '$($ph.Name)' but has no Host Group - will connect to host directly" -Level "WARNING"
          return $null
        }
      }
    }

    # Check iSCSI IQNs
    if ($ph.Iqns) {
      foreach ($pureIQN in $ph.Iqns) {
        if ($iscsiIQNs -contains $pureIQN) {
          if ($ph.HostGroup.Name) {
            Write-Log "Auto-detected Host Group: $($ph.HostGroup.Name) (via iSCSI IQN match on host '$($ph.Name)')" -Level "SUCCESS"
            if ($Protocol -eq "Auto") { $script:DetectedProtocol = "iSCSI" }
            return $ph.HostGroup.Name
          }
          Write-Log "ESXi host matches Pure host '$($ph.Name)' but has no Host Group" -Level "WARNING"
          return $null
        }
      }
    }
  }

  # No auto-match found - list host groups for selection
  Write-Log "Could not auto-detect Host Group mapping. Listing available groups..." -Level "WARNING"
  $allHGs = Get-Pfa2HostGroup

  if ($allHGs.Count -eq 0) {
    throw "No Host Groups found on FlashArray. Create a Host Group with the ESXi host mapped first."
  }

  Write-Host ""
  Write-Host "Available Host Groups:" -ForegroundColor Cyan
  Write-Host ("-" * 60) -ForegroundColor DarkGray
  for ($i = 0; $i -lt $allHGs.Count; $i++) {
    $hostCount = ($allHGs[$i].Hosts).Count
    Write-Host "  [$($i+1)] $($allHGs[$i].Name) ($hostCount host(s))" -ForegroundColor White
  }
  Write-Host ""

  do {
    $selection = Read-Host "Select Host Group [1-$($allHGs.Count)]"
  } while ($selection -lt 1 -or $selection -gt $allHGs.Count)

  $selectedHG = $allHGs[$selection - 1].Name
  Write-Log "Selected Host Group: $selectedHG" -Level "INFO"
  return $selectedHG
}

function Connect-VolumeToHost {
  param(
    [Parameter(Mandatory=$true)]$ClonedVolumes,
    [Parameter(Mandatory=$true)]$VMHost,
    [string]$ResolvedHostGroup
  )

  Write-ProgressStep -Activity "Presenting volumes to ESXi host" -Status "Creating host connections..."

  foreach ($vol in $ClonedVolumes) {
    if ($PSCmdlet.ShouldProcess($vol.VolumeName, "Connect volume to host group '$ResolvedHostGroup'")) {
      try {
        Add-RecoveryAction -Action "Present Volume" -Target $vol.VolumeName -Status "InProgress" -Detail "Host Group: $ResolvedHostGroup"

        if ($ResolvedHostGroup) {
          New-Pfa2Connection -VolumeName $vol.VolumeName -HostGroupName $ResolvedHostGroup
          Write-Log "Connected volume '$($vol.VolumeName)' to Host Group '$ResolvedHostGroup'" -Level "SUCCESS"
        }
        else {
          # Find the matching Pure host name for direct connection
          $pureHostName = Find-PureHostForESXi -VMHost $VMHost
          New-Pfa2Connection -VolumeName $vol.VolumeName -HostName $pureHostName
          Write-Log "Connected volume '$($vol.VolumeName)' to Pure host '$pureHostName'" -Level "SUCCESS"
        }

        Add-RecoveryAction -Action "Present Volume" -Target $vol.VolumeName -Status "Success"
      }
      catch {
        Add-RecoveryAction -Action "Present Volume" -Target $vol.VolumeName -Status "Failed" -Detail $_.Exception.Message
        throw "Failed to connect volume '$($vol.VolumeName)': $($_.Exception.Message)"
      }
    }
    else {
      Add-RecoveryAction -Action "Present Volume" -Target $vol.VolumeName -Status "Skipped" -Detail "WhatIf mode"
    }
  }
}

function Find-PureHostForESXi {
  param(
    [Parameter(Mandatory=$true)]$VMHost
  )

  $hostAdapters = Get-VMHostHBA -VMHost $VMHost -ErrorAction SilentlyContinue
  $fcWWNs = @()
  $iscsiIQNs = @()

  foreach ($hba in $hostAdapters) {
    if ($hba.Type -eq "FibreChannel" -and $hba.Status -eq "online") {
      $wwn = ($hba.PortWorldWideName.ToString().ToLower()) -replace "[:-]",""
      $fcWWNs += $wwn
    }
    elseif ($hba.Type -eq "IScsi") {
      $iscsiIQNs += $hba.IScsiName
    }
  }

  $pureHosts = Get-Pfa2Host
  foreach ($ph in $pureHosts) {
    if ($ph.Wwns) {
      foreach ($pureWWN in $ph.Wwns) {
        if ($fcWWNs -contains ($pureWWN.ToLower() -replace "[:-]","")) {
          return $ph.Name
        }
      }
    }
    if ($ph.Iqns) {
      foreach ($pureIQN in $ph.Iqns) {
        if ($iscsiIQNs -contains $pureIQN) {
          return $ph.Name
        }
      }
    }
  }

  throw "Could not find a Pure Storage host entry matching ESXi host '$($VMHost.Name)'. Ensure the host is registered on the FlashArray."
}

#endregion

# =============================
# Datastore & VM Registration
# =============================
#region VMRegistration

function Mount-RecoveredDatastore {
  param(
    [Parameter(Mandatory=$true)]$VMHost,
    [Parameter(Mandatory=$true)]$ClonedVolumes
  )

  Write-ProgressStep -Activity "Mounting recovered datastore" -Status "Rescanning storage on $($VMHost.Name)..."

  if (-not $SkipDatastoreRescan) {
    if ($PSCmdlet.ShouldProcess($VMHost.Name, "Rescan storage adapters")) {
      try {
        Write-Log "Rescanning HBA storage adapters on $($VMHost.Name)..." -Level "INFO"
        Get-VMHostStorage -VMHost $VMHost -RescanAllHba -ErrorAction Stop | Out-Null
        Write-Log "Rescanning VMFS volumes..." -Level "INFO"
        Get-VMHostStorage -VMHost $VMHost -RescanVmfs -ErrorAction Stop | Out-Null
        Write-Log "Storage rescan complete" -Level "SUCCESS"
      }
      catch {
        Write-Log "Storage rescan warning: $($_.Exception.Message)" -Level "WARNING"
      }
    }
  }
  else {
    Write-Log "Skipping storage rescan (SkipDatastoreRescan = true)" -Level "INFO"
  }

  # Wait briefly for the rescan to settle
  Start-Sleep -Seconds 5

  # Find the new VMFS datastore by matching the Pure volume serial
  Write-Log "Searching for new VMFS datastore from cloned volume..." -Level "INFO"

  foreach ($vol in $ClonedVolumes) {
    $pureSerial = $vol.Serial.ToLower()
    # Pure serial as seen by ESXi is typically the NAA ID with a prefix
    # Pure volumes appear as naa.624a9370<serial>
    $naaId = "naa.624a9370$pureSerial"

    Write-Log "Looking for LUN with NAA ID: $naaId" -Level "DEBUG"

    # Try to find the datastore using ESXCLI
    $esxcli = Get-EsxCli -VMHost $VMHost -V2
    $devices = $esxcli.storage.core.device.list.Invoke()
    $matchedDevice = $devices | Where-Object { $_.Device.ToLower() -like "*$pureSerial*" }

    if ($matchedDevice) {
      Write-Log "Found LUN device: $($matchedDevice.Device) (Size: $($matchedDevice.Size) MB)" -Level "SUCCESS"
    }
    else {
      Write-Log "LUN device not yet visible. Waiting 10 seconds and rescanning..." -Level "WARNING"
      Start-Sleep -Seconds 10
      Get-VMHostStorage -VMHost $VMHost -RescanAllHba -ErrorAction SilentlyContinue | Out-Null
      Get-VMHostStorage -VMHost $VMHost -RescanVmfs -ErrorAction SilentlyContinue | Out-Null
      Start-Sleep -Seconds 5
    }
  }

  # Look for the new datastore - it may auto-mount as a snapshot datastore
  $snapDatastores = Get-Datastore -VMHost $VMHost -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "snap-*" -or $_.Name -like "ds-*" -or $_.ExtensionData.Info.Vmfs.Extent.DiskName -like "*624a9370*" }

  if ($snapDatastores) {
    Write-Log "Found snapshot-mounted datastore(s):" -Level "INFO"
    foreach ($ds in $snapDatastores) {
      Write-Log "  Datastore: $($ds.Name) (Capacity: $([math]::Round($ds.CapacityGB, 2)) GB)" -Level "INFO"
    }
  }

  # Attempt to resignature or force-mount the VMFS datastore
  $newDSName = if ($TargetDatastoreName) { $TargetDatastoreName } else { "DS-PureRecovery-$(Get-Date -Format 'yyyyMMdd-HHmm')" }

  if ($PSCmdlet.ShouldProcess($newDSName, "Mount/resignature VMFS datastore")) {
    try {
      Add-RecoveryAction -Action "Mount Datastore" -Target $newDSName -Status "InProgress"

      # Get unresolved VMFS volumes (snapshot LUNs that need resignaturing)
      $storSys = Get-View ($VMHost.ExtensionData.ConfigManager.StorageSystem)
      $unresolvedVmfs = $storSys.QueryUnresolvedVmfsVolumes()

      if ($unresolvedVmfs.Count -gt 0) {
        Write-Log "Found $($unresolvedVmfs.Count) unresolved VMFS volume(s) - performing resignature..." -Level "INFO"

        foreach ($unresolved in $unresolvedVmfs) {
          $extentPaths = $unresolved.Extent | ForEach-Object { $_.Device.DiskName }
          $matchesPure = $extentPaths | Where-Object { $_.ToLower() -like "*624a9370*" }

          if ($matchesPure) {
            Write-Log "Resignaturing VMFS volume: $($unresolved.VmfsLabel) (Extents: $($extentPaths -join ', '))" -Level "INFO"

            # Build the resignature spec
            $resolutionSpec = New-Object VMware.Vim.HostUnresolvedVmfsResignatureSpec
            $resolutionSpec.ExtentDevicePath = $unresolved.Extent[0].Device.DevicePath

            $result = $storSys.ResolveMultipleUnresolvedVmfsVolumes(@($resolutionSpec))

            if ($result) {
              Write-Log "VMFS resignature successful" -Level "SUCCESS"
              Start-Sleep -Seconds 3
              # Rescan to pick up the new datastore
              Get-VMHostStorage -VMHost $VMHost -RescanVmfs -ErrorAction SilentlyContinue | Out-Null
            }
          }
        }
      }

      # Find the newly mounted datastore
      Start-Sleep -Seconds 3
      $allDatastores = Get-Datastore -VMHost $VMHost -ErrorAction SilentlyContinue

      # Look for datastores that appeared with "snap-" prefix (resignatured datastores)
      $recoveredDS = $allDatastores | Where-Object {
        $_.Name -like "snap-*" -and
        $_.CapacityGB -gt 0 -and
        $_.State -eq "Available"
      } | Sort-Object -Property Name -Descending | Select-Object -First 1

      if (-not $recoveredDS) {
        # Try matching by Pure volume serial in the extent disk names
        foreach ($ds in $allDatastores) {
          try {
            $extents = $ds.ExtensionData.Info.Vmfs.Extent
            foreach ($ext in $extents) {
              foreach ($vol in $ClonedVolumes) {
                if ($ext.DiskName.ToLower() -like "*$($vol.Serial.ToLower())*") {
                  $recoveredDS = $ds
                  break
                }
              }
              if ($recoveredDS) { break }
            }
            if ($recoveredDS) { break }
          } catch { continue }
        }
      }

      if ($recoveredDS) {
        # Rename to our desired name
        if ($recoveredDS.Name -ne $newDSName) {
          Set-Datastore -Datastore $recoveredDS -Name $newDSName -ErrorAction SilentlyContinue | Out-Null
          Write-Log "Renamed datastore to: $newDSName" -Level "INFO"
        }
        $script:MountedDatastore = Get-Datastore -Name $newDSName -ErrorAction SilentlyContinue
        if (-not $script:MountedDatastore) { $script:MountedDatastore = $recoveredDS }

        Write-Log "Recovered datastore mounted: $($script:MountedDatastore.Name) (Capacity: $([math]::Round($script:MountedDatastore.CapacityGB, 2)) GB, Free: $([math]::Round($script:MountedDatastore.FreeSpaceGB, 2)) GB)" -Level "SUCCESS"
        Add-RecoveryAction -Action "Mount Datastore" -Target $script:MountedDatastore.Name -Status "Success" -Detail "$([math]::Round($script:MountedDatastore.CapacityGB, 2)) GB capacity"
      }
      else {
        Add-RecoveryAction -Action "Mount Datastore" -Target $newDSName -Status "Failed" -Detail "Could not locate mounted datastore"
        throw "Failed to locate the recovered datastore after resignature. Manual intervention may be required."
      }
    }
    catch {
      Add-RecoveryAction -Action "Mount Datastore" -Target $newDSName -Status "Failed" -Detail $_.Exception.Message
      throw "Failed to mount recovered datastore: $($_.Exception.Message)"
    }
  }
  else {
    Add-RecoveryAction -Action "Mount Datastore" -Target $newDSName -Status "Skipped" -Detail "WhatIf mode"
  }
}

function Register-RecoveredVMs {
  param(
    [Parameter(Mandatory=$true)]$VMHost,
    [Parameter(Mandatory=$true)]$Datastore
  )

  Write-ProgressStep -Activity "Registering recovered VMs" -Status "Scanning datastore for VMX files..."

  Add-RecoveryAction -Action "Register VMs" -Target $Datastore.Name -Status "InProgress"

  # Browse the datastore for .vmx files
  $dsBrowser = Get-View $Datastore.ExtensionData.Browser
  $dsPath = "[$($Datastore.Name)]"

  $searchSpec = New-Object VMware.Vim.HostDatastoreBrowserSearchSpec
  $searchSpec.MatchPattern = @("*.vmx")
  $searchSpec.Details = New-Object VMware.Vim.FileQueryFlags
  $searchSpec.Details.FileSize = $true
  $searchSpec.Details.FileType = $true
  $searchSpec.Details.Modification = $true

  try {
    $searchResult = $dsBrowser.SearchDatastoreSubFolders($dsPath, $searchSpec)
  }
  catch {
    throw "Failed to search datastore '$($Datastore.Name)' for VMX files: $($_.Exception.Message)"
  }

  $vmxFiles = @()
  foreach ($folder in $searchResult) {
    foreach ($file in $folder.File) {
      if ($file.Path -like "*.vmx") {
        $vmxPath = "$($folder.FolderPath)$($file.Path)"
        $vmxFiles += $vmxPath
      }
    }
  }

  if ($vmxFiles.Count -eq 0) {
    Write-Log "No VMX files found on datastore '$($Datastore.Name)'" -Level "WARNING"
    Add-RecoveryAction -Action "Register VMs" -Target $Datastore.Name -Status "Failed" -Detail "No VMX files found"
    return
  }

  Write-Log "Found $($vmxFiles.Count) VMX file(s) on datastore" -Level "INFO"

  # Ensure target folder exists
  $folder = $null
  if ($PSCmdlet.ShouldProcess($TargetFolder, "Create VM folder")) {
    try {
      $folder = Get-Folder -Name $TargetFolder -Type VM -ErrorAction SilentlyContinue
      if (-not $folder) {
        $datacenter = Get-Datacenter -VMHost $VMHost | Select-Object -First 1
        $vmFolder = Get-Folder -Type VM -Name "vm" -Location $datacenter -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($vmFolder) {
          $folder = New-Folder -Name $TargetFolder -Location $vmFolder -ErrorAction Stop
          Write-Log "Created VM folder: $TargetFolder" -Level "INFO"
        }
      }
    }
    catch {
      Write-Log "Could not create folder '$TargetFolder', using default: $($_.Exception.Message)" -Level "WARNING"
    }
  }

  # Get resource pool
  $resPool = $null
  if ($TargetResourcePool) {
    $resPool = Get-ResourcePool -Name $TargetResourcePool -ErrorAction SilentlyContinue
    if (-not $resPool) {
      Write-Log "Resource pool '$TargetResourcePool' not found, using host default" -Level "WARNING"
    }
  }
  if (-not $resPool) {
    $resPool = Get-ResourcePool -Location (Get-VMHost $VMHost) | Where-Object { $_.Name -eq "Resources" } | Select-Object -First 1
  }

  # Register each VM
  $registeredCount = 0
  foreach ($vmxPath in $vmxFiles) {
    # Extract VM name from path
    $vmDirName = ($vmxPath -replace "^\[.*?\]\s*", "" -split "/")[0]
    $originalName = [System.IO.Path]::GetFileNameWithoutExtension(($vmxPath -split "/")[-1])

    # Filter by VMNames if specified
    if ($VMNames -and $VMNames.Count -gt 0) {
      $match = $VMNames | Where-Object {
        $originalName -like "*$_*" -or $vmDirName -like "*$_*"
      }
      if (-not $match) {
        Write-Log "Skipping VM '$originalName' (not in VMNames filter)" -Level "DEBUG"
        continue
      }
    }

    $newName = "$VMNamePrefix$originalName"

    # Check if VM with this name already exists
    $existingVM = Get-VM -Name $newName -ErrorAction SilentlyContinue
    if ($existingVM) {
      Write-Log "VM '$newName' already exists in inventory - skipping" -Level "WARNING"
      Add-RecoveryAction -Action "Register VM" -Target $newName -Status "Skipped" -Detail "Already exists"
      continue
    }

    if ($PSCmdlet.ShouldProcess($newName, "Register VM from $vmxPath")) {
      try {
        Add-RecoveryAction -Action "Register VM" -Target $newName -Status "InProgress" -Detail "Source: $vmxPath"

        $registerParams = @{
          VMFilePath    = $vmxPath
          VMHost        = $VMHost
          Name          = $newName
          ErrorAction   = "Stop"
        }

        if ($resPool) { $registerParams.ResourcePool = $resPool }
        if ($folder)  { $registerParams.Location = $folder }

        $vm = New-VM @registerParams

        Write-Log "Registered VM: $newName" -Level "SUCCESS"

        # Answer the "I Copied It" question to avoid UUID conflicts
        if ($AnswerSourceVM) {
          try {
            $vmQuestion = Get-VMQuestion -VM $vm -ErrorAction SilentlyContinue
            if ($vmQuestion) {
              Set-VMQuestion -VMQuestion $vmQuestion -Option "button.uuid.copiedTheVM" -ErrorAction SilentlyContinue
              Write-Log "Answered VM UUID question for '$newName' (Copied)" -Level "DEBUG"
            }
          }
          catch {
            Write-Log "Could not auto-answer UUID question for '$newName': $($_.Exception.Message)" -Level "DEBUG"
          }
        }

        # Reconfigure network if target port group specified
        if ($TargetPortGroup) {
          try {
            $adapters = Get-NetworkAdapter -VM $vm -ErrorAction SilentlyContinue
            foreach ($adapter in $adapters) {
              Set-NetworkAdapter -NetworkAdapter $adapter -NetworkName $TargetPortGroup -Confirm:$false -ErrorAction Stop | Out-Null
              Write-Log "  NIC '$($adapter.Name)' -> Port Group '$TargetPortGroup'" -Level "INFO"
            }
          }
          catch {
            Write-Log "  Could not reconfigure network for '$newName': $($_.Exception.Message)" -Level "WARNING"
          }
        }

        # Power on if requested
        if ($PowerOnVMs) {
          try {
            Start-VM -VM $vm -ErrorAction Stop | Out-Null
            Write-Log "Powered on VM: $newName" -Level "SUCCESS"

            # Answer UUID question again after power-on
            if ($AnswerSourceVM) {
              Start-Sleep -Seconds 3
              $vmQuestion = Get-VMQuestion -VM $vm -ErrorAction SilentlyContinue
              if ($vmQuestion) {
                Set-VMQuestion -VMQuestion $vmQuestion -Option "button.uuid.copiedTheVM" -ErrorAction SilentlyContinue
              }
            }
          }
          catch {
            Write-Log "Failed to power on '$newName': $($_.Exception.Message)" -Level "WARNING"
          }
        }

        # Collect recovered VM info
        $vmObj = Get-VM -Name $newName -ErrorAction SilentlyContinue
        $script:RecoveredVMs.Add([PSCustomObject]@{
          Name          = $newName
          OriginalName  = $originalName
          VMXPath       = $vmxPath
          NumCPU        = $vmObj.NumCpu
          MemoryGB      = $vmObj.MemoryGB
          PowerState    = $vmObj.PowerState
          GuestOS       = $vmObj.GuestId
          NetworkAdapters = ($vmObj | Get-NetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object { $_.NetworkName }) -join ", "
          DiskCount     = ($vmObj | Get-HardDisk -ErrorAction SilentlyContinue).Count
          Status        = "Recovered"
        })

        $registeredCount++
        Add-RecoveryAction -Action "Register VM" -Target $newName -Status "Success" -Detail "CPU: $($vmObj.NumCpu), RAM: $($vmObj.MemoryGB) GB"
      }
      catch {
        Write-Log "Failed to register VM '$newName': $($_.Exception.Message)" -Level "ERROR"
        Add-RecoveryAction -Action "Register VM" -Target $newName -Status "Failed" -Detail $_.Exception.Message

        $script:RecoveredVMs.Add([PSCustomObject]@{
          Name          = $newName
          OriginalName  = $originalName
          VMXPath       = $vmxPath
          NumCPU        = "N/A"
          MemoryGB      = "N/A"
          PowerState    = "N/A"
          GuestOS       = "N/A"
          NetworkAdapters = "N/A"
          DiskCount     = "N/A"
          Status        = "Failed: $($_.Exception.Message)"
        })
      }
    }
    else {
      Add-RecoveryAction -Action "Register VM" -Target $newName -Status "Skipped" -Detail "WhatIf mode"
    }
  }

  Write-Log "VM registration complete: $registeredCount of $($vmxFiles.Count) VM(s) registered" -Level $(if ($registeredCount -gt 0) { "SUCCESS" } else { "WARNING" })
  Add-RecoveryAction -Action "Register VMs" -Target $Datastore.Name -Status $(if ($registeredCount -gt 0) { "Success" } else { "Failed" }) -Detail "$registeredCount of $($vmxFiles.Count) VMs"
}

#endregion

# =============================
# Cleanup & Rollback
# =============================
#region Cleanup

function Invoke-RecoveryCleanup {
  param(
    [switch]$Force
  )

  if (-not $Force -and $script:RecoverySucceeded) {
    Write-Log "Recovery succeeded - skipping cleanup" -Level "INFO"
    return
  }

  if (-not $Force -and -not $CleanupOnFailure) {
    Write-Log "CleanupOnFailure is disabled - leaving recovery artifacts in place" -Level "WARNING"
    return
  }

  Write-Log "Performing recovery cleanup..." -Level "WARNING"

  # Remove VMs from inventory (do not delete from disk)
  foreach ($vmInfo in $script:RecoveredVMs) {
    try {
      $vm = Get-VM -Name $vmInfo.Name -ErrorAction SilentlyContinue
      if ($vm) {
        if ($vm.PowerState -eq "PoweredOn") {
          Stop-VM -VM $vm -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        }
        Remove-VM -VM $vm -Confirm:$false -ErrorAction SilentlyContinue
        Write-Log "Removed VM from inventory: $($vmInfo.Name)" -Level "INFO"
      }
    }
    catch {
      Write-Log "Could not remove VM '$($vmInfo.Name)': $($_.Exception.Message)" -Level "WARNING"
    }
  }

  # Unmount datastore
  if ($script:MountedDatastore) {
    try {
      Remove-Datastore -Datastore $script:MountedDatastore -VMHost (Get-VMHost) -Confirm:$false -ErrorAction SilentlyContinue
      Write-Log "Removed datastore: $($script:MountedDatastore.Name)" -Level "INFO"
    }
    catch {
      Write-Log "Could not remove datastore: $($_.Exception.Message)" -Level "WARNING"
    }
  }

  # Disconnect and destroy cloned volumes
  if ($script:ClonedVolumeName -and $script:FlashArray) {
    try {
      # Remove host connection
      Get-Pfa2Connection -VolumeName $script:ClonedVolumeName -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Pfa2Connection -VolumeName $script:ClonedVolumeName -HostGroupName $_.HostGroup.Name -ErrorAction SilentlyContinue }

      # Destroy volume
      Remove-Pfa2Volume -Name $script:ClonedVolumeName -ErrorAction SilentlyContinue
      Remove-Pfa2Volume -Name $script:ClonedVolumeName -Eradicate -ErrorAction SilentlyContinue
      Write-Log "Destroyed cloned volume: $script:ClonedVolumeName" -Level "INFO"
    }
    catch {
      Write-Log "Could not clean up volume '$($script:ClonedVolumeName)': $($_.Exception.Message)" -Level "WARNING"
    }
  }
}

#endregion

# =============================
# HTML Report Generation
# =============================
#region Report

function New-RecoveryReport {
  param(
    [Parameter(Mandatory=$true)][string]$ReportPath
  )

  Write-ProgressStep -Activity "Generating recovery report" -Status "Building HTML..."

  $duration = (Get-Date) - $script:StartTime
  $durationStr = "{0:hh\:mm\:ss}" -f $duration

  $statusColor = if ($script:RecoverySucceeded) { "#22c55e" } else { "#ef4444" }
  $statusText  = if ($script:RecoverySucceeded) { "RECOVERY SUCCESSFUL" } else { "RECOVERY FAILED" }
  $statusIcon  = if ($script:RecoverySucceeded) { "&#10004;" } else { "&#10008;" }

  $successCount = ($script:RecoveredVMs | Where-Object { $_.Status -eq "Recovered" }).Count
  $failedCount  = ($script:RecoveredVMs | Where-Object { $_.Status -like "Failed*" }).Count
  $totalVMs     = $script:RecoveredVMs.Count

  # Build VM table rows
  $vmRows = ""
  foreach ($vm in $script:RecoveredVMs) {
    $rowColor = if ($vm.Status -eq "Recovered") { "#f0fdf4" } else { "#fef2f2" }
    $statusBadge = if ($vm.Status -eq "Recovered") {
      '<span style="background:#22c55e;color:#fff;padding:2px 8px;border-radius:4px;font-size:12px;">Recovered</span>'
    } else {
      '<span style="background:#ef4444;color:#fff;padding:2px 8px;border-radius:4px;font-size:12px;">Failed</span>'
    }
    $vmRows += @"
    <tr style="background:$rowColor;">
      <td style="padding:8px 12px;">$($vm.Name)</td>
      <td style="padding:8px 12px;">$($vm.OriginalName)</td>
      <td style="padding:8px 12px;">$($vm.NumCPU)</td>
      <td style="padding:8px 12px;">$($vm.MemoryGB) GB</td>
      <td style="padding:8px 12px;">$($vm.DiskCount)</td>
      <td style="padding:8px 12px;">$($vm.NetworkAdapters)</td>
      <td style="padding:8px 12px;">$($vm.PowerState)</td>
      <td style="padding:8px 12px;">$statusBadge</td>
    </tr>
"@
  }

  # Build action log rows
  $actionRows = ""
  foreach ($action in $script:RecoveryActions) {
    $actionStatusColor = switch ($action.Status) {
      "Success" { "#22c55e" }
      "Failed"  { "#ef4444" }
      "Skipped" { "#f59e0b" }
      default   { "#6b7280" }
    }
    $actionRows += @"
    <tr>
      <td style="padding:6px 12px;font-size:13px;">$($action.Timestamp)</td>
      <td style="padding:6px 12px;font-size:13px;">$($action.Action)</td>
      <td style="padding:6px 12px;font-size:13px;">$($action.Target)</td>
      <td style="padding:6px 12px;font-size:13px;color:$actionStatusColor;font-weight:600;">$($action.Status)</td>
      <td style="padding:6px 12px;font-size:13px;">$($action.Detail)</td>
    </tr>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Pure Storage Recovery Report</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background: #f8fafc; color: #1e293b; line-height: 1.6; }
    .header { background: linear-gradient(135deg, #1e293b 0%, #334155 100%); color: #fff; padding: 40px; }
    .header h1 { font-size: 28px; font-weight: 300; margin-bottom: 8px; }
    .header .subtitle { font-size: 14px; color: #94a3b8; }
    .status-banner { padding: 20px 40px; background: $statusColor; color: #fff; font-size: 20px; font-weight: 600; display: flex; align-items: center; gap: 12px; }
    .status-banner .icon { font-size: 28px; }
    .container { max-width: 1200px; margin: 0 auto; padding: 32px 40px; }
    .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 32px; }
    .summary-card { background: #fff; border-radius: 8px; padding: 20px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); border-left: 4px solid #6366f1; }
    .summary-card .label { font-size: 12px; text-transform: uppercase; color: #64748b; letter-spacing: 0.5px; margin-bottom: 4px; }
    .summary-card .value { font-size: 22px; font-weight: 600; color: #1e293b; }
    .section { margin-bottom: 32px; }
    .section h2 { font-size: 18px; font-weight: 600; color: #1e293b; margin-bottom: 16px; padding-bottom: 8px; border-bottom: 2px solid #e2e8f0; }
    table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
    th { background: #f1f5f9; color: #475569; font-size: 12px; text-transform: uppercase; letter-spacing: 0.5px; padding: 10px 12px; text-align: left; font-weight: 600; }
    td { border-bottom: 1px solid #f1f5f9; }
    .footer { text-align: center; padding: 24px; color: #94a3b8; font-size: 12px; border-top: 1px solid #e2e8f0; margin-top: 32px; }
    .logo-row { display: flex; align-items: center; gap: 16px; margin-bottom: 16px; }
    .logo-row .pure { color: #fe5000; font-weight: 700; font-size: 16px; }
    .logo-row .veeam { color: #00b336; font-weight: 700; font-size: 16px; }
    .logo-row .vmware { color: #696566; font-weight: 700; font-size: 16px; }
    .logo-row .sep { color: #94a3b8; }
    @media print { .header { background: #1e293b !important; -webkit-print-color-adjust: exact; print-color-adjust: exact; } }
  </style>
</head>
<body>
  <div class="header">
    <div class="logo-row">
      <span class="pure">Pure Storage</span>
      <span class="sep">+</span>
      <span class="veeam">Veeam</span>
      <span class="sep">&#8594;</span>
      <span class="vmware">VMware</span>
    </div>
    <h1>Snapshot Recovery Report</h1>
    <div class="subtitle">Generated $(Get-Date -Format "yyyy-MM-dd HH:mm:ss") | Duration: $durationStr</div>
  </div>

  <div class="status-banner">
    <span class="icon">$statusIcon</span>
    $statusText
  </div>

  <div class="container">
    <div class="summary-grid">
      <div class="summary-card">
        <div class="label">FlashArray</div>
        <div class="value">$FlashArrayEndpoint</div>
      </div>
      <div class="summary-card">
        <div class="label">vCenter</div>
        <div class="value">$VCenterServer</div>
      </div>
      <div class="summary-card">
        <div class="label">VMs Recovered</div>
        <div class="value" style="color:#22c55e;">$successCount / $totalVMs</div>
      </div>
      <div class="summary-card">
        <div class="label">Failed</div>
        <div class="value" style="color:$(if ($failedCount -gt 0) { '#ef4444' } else { '#22c55e' });">$failedCount</div>
      </div>
      <div class="summary-card">
        <div class="label">Duration</div>
        <div class="value">$durationStr</div>
      </div>
    </div>

    <div class="section">
      <h2>Recovered Virtual Machines</h2>
      $(if ($script:RecoveredVMs.Count -gt 0) {
        @"
        <table>
          <thead>
            <tr>
              <th>VM Name</th>
              <th>Original Name</th>
              <th>CPU</th>
              <th>Memory</th>
              <th>Disks</th>
              <th>Network</th>
              <th>Power State</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>$vmRows</tbody>
        </table>
"@
      } else {
        '<p style="color:#64748b;font-style:italic;">No VMs were recovered in this session.</p>'
      })
    </div>

    <div class="section">
      <h2>Recovery Action Log</h2>
      <table>
        <thead>
          <tr>
            <th>Timestamp</th>
            <th>Action</th>
            <th>Target</th>
            <th>Status</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>$actionRows</tbody>
      </table>
    </div>
  </div>

  <div class="footer">
    Pure Storage FlashArray Snapshot Recovery for Veeam &bull; Veeam Recovery Orchestrator Integration &bull; $(Get-Date -Format "yyyy")
  </div>
</body>
</html>
"@

  $html | Out-File -FilePath $ReportPath -Encoding UTF8 -Force
  Write-Log "HTML report saved: $ReportPath" -Level "SUCCESS"
}

#endregion

# =============================
# Output & Export
# =============================
#region Output

function Export-RecoveryOutputs {
  Write-ProgressStep -Activity "Exporting recovery outputs" -Status "Saving logs and reports..."

  # Setup output directory
  $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
  if (-not $OutputPath) {
    $OutputPath = Join-Path (Get-Location) "PureRecovery_$timestamp"
  }

  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
  }

  # Export log
  $logPath = Join-Path $OutputPath "RecoveryLog.csv"
  $script:LogEntries | Export-Csv -Path $logPath -NoTypeInformation -Force
  Write-Log "Log exported: $logPath" -Level "INFO"

  # Export recovery actions
  $actionsPath = Join-Path $OutputPath "RecoveryActions.csv"
  $script:RecoveryActions | Export-Csv -Path $actionsPath -NoTypeInformation -Force
  Write-Log "Actions exported: $actionsPath" -Level "INFO"

  # Export recovered VMs
  if ($script:RecoveredVMs.Count -gt 0) {
    $vmsPath = Join-Path $OutputPath "RecoveredVMs.csv"
    $script:RecoveredVMs | Export-Csv -Path $vmsPath -NoTypeInformation -Force
    Write-Log "Recovered VMs exported: $vmsPath" -Level "INFO"
  }

  # Generate HTML report
  if ($GenerateHTML) {
    $htmlPath = Join-Path $OutputPath "RecoveryReport.html"
    New-RecoveryReport -ReportPath $htmlPath
  }

  # Create ZIP archive
  if ($ZipOutput) {
    try {
      $zipPath = "$OutputPath.zip"
      Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force
      Write-Log "ZIP archive created: $zipPath" -Level "SUCCESS"
    }
    catch {
      Write-Log "Could not create ZIP archive: $($_.Exception.Message)" -Level "WARNING"
    }
  }

  return $OutputPath
}

#endregion

# =============================
# Main Recovery Orchestration
# =============================
#region Main

function Invoke-PureStorageRecovery {
  <#
  .SYNOPSIS
    Main orchestration function for Pure Storage snapshot recovery to VMware.
  .DESCRIPTION
    Coordinates the full recovery workflow: connect, discover, clone, present, mount, register, report.
  #>

  Write-Host ""
  Write-Host "=" * 70 -ForegroundColor DarkCyan
  Write-Host "  Pure Storage FlashArray -> VMware VM Recovery" -ForegroundColor Cyan
  Write-Host "  Veeam Recovery Orchestrator Integration" -ForegroundColor DarkCyan
  Write-Host "=" * 70 -ForegroundColor DarkCyan
  Write-Host ""
  Write-Log "Recovery started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level "INFO"
  Write-Log "PowerShell version: $($PSVersionTable.PSVersion)" -Level "INFO"

  if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "  *** WHATIF MODE - No changes will be made ***" -ForegroundColor Yellow
    Write-Host ""
    Write-Log "Running in WhatIf (preview) mode" -Level "WARNING"
  }

  try {
    # Step 1: Prerequisites
    Assert-RequiredModules

    # Step 2: Connect to Pure Storage
    Connect-PureArray

    # Step 3: Connect to vCenter
    Connect-VCenterServer

    # Step 4: Select snapshot
    $snapshot = Select-Snapshot

    # Step 5: Get volume snapshots within the protection group snapshot
    $volumeSnapshots = Get-SnapshotVolumes -Snapshot $snapshot

    # Step 6: Select target ESXi host
    $targetHost = Select-TargetHost

    # Step 7: Clone snapshot volumes
    $clonedVolumes = New-SnapshotClone -VolumeSnapshots $volumeSnapshots

    # Step 8: Resolve host group and present volumes
    $resolvedHG = Resolve-HostGroup -VMHost $targetHost
    Connect-VolumeToHost -ClonedVolumes $clonedVolumes -VMHost $targetHost -ResolvedHostGroup $resolvedHG

    # Step 9: Mount datastore and register VMs
    Mount-RecoveredDatastore -VMHost $targetHost -ClonedVolumes $clonedVolumes
    Register-RecoveredVMs -VMHost $targetHost -Datastore $script:MountedDatastore

    # Mark success
    $script:RecoverySucceeded = $true
    Write-Log "Recovery completed successfully" -Level "SUCCESS"
  }
  catch {
    $script:RecoverySucceeded = $false
    Write-Log "Recovery FAILED: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "DEBUG"

    # Attempt cleanup on failure
    if ($CleanupOnFailure -and -not $WhatIfPreference) {
      Write-Log "Initiating failure cleanup..." -Level "WARNING"
      try {
        Invoke-RecoveryCleanup -Force
      }
      catch {
        Write-Log "Cleanup also failed: $($_.Exception.Message)" -Level "ERROR"
      }
    }
  }
  finally {
    # Step 10: Export outputs and generate report
    $outputDir = Export-RecoveryOutputs

    $duration = (Get-Date) - $script:StartTime

    Write-Host ""
    Write-Host "=" * 70 -ForegroundColor DarkCyan
    if ($script:RecoverySucceeded) {
      Write-Host "  RECOVERY COMPLETE" -ForegroundColor Green
      Write-Host "  VMs Recovered: $($script:RecoveredVMs.Count)" -ForegroundColor Green
    }
    else {
      Write-Host "  RECOVERY FAILED" -ForegroundColor Red
      Write-Host "  Check logs for details" -ForegroundColor Red
    }
    Write-Host "  Duration: $("{0:hh\:mm\:ss}" -f $duration)" -ForegroundColor DarkCyan
    Write-Host "  Output: $outputDir" -ForegroundColor DarkCyan
    Write-Host "=" * 70 -ForegroundColor DarkCyan
    Write-Host ""

    # Disconnect sessions (non-destructive)
    try {
      if ($script:FlashArray) {
        Disconnect-Pfa2Array -ErrorAction SilentlyContinue
      }
    }
    catch { }

    Write-Progress -Activity "Pure Storage VM Recovery" -Completed
  }
}

#endregion

# =============================
# Execute
# =============================

Invoke-PureStorageRecovery
