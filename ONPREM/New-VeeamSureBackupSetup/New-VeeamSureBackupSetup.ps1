<#
.SYNOPSIS
  Simplified SureBackup Setup Wizard for Veeam Backup & Replication

.DESCRIPTION
  Eliminates the complexity of configuring SureBackup by automating the creation of:
  1. Virtual Lab (isolated network environment for VM verification)
  2. Application Group (VMs to verify with startup order and tests)
  3. SureBackup Job (ties everything together with scheduling)

  WHAT THIS SCRIPT DOES:
  - Discovers your infrastructure (hosts, datastores, networks, backup jobs)
  - Auto-generates isolated network configuration with proper IP schemes
  - Creates Virtual Lab with proxy appliance and network mapping
  - Builds Application Groups from existing backup jobs
  - Configures SureBackup Jobs with sensible defaults
  - Validates everything before applying changes
  - Generates an HTML summary report of the configuration

  SUPPORTED PLATFORMS:
  - VMware vSphere (Virtual Lab with proxy appliance)
  - Microsoft Hyper-V (Virtual Lab with network isolation)

  COMMON PAIN POINTS THIS SOLVES:
  - Isolated network IP addressing confusion
  - Proxy appliance network configuration
  - Network masquerading rules
  - Application Group VM ordering
  - Virtual Lab resource selection

  QUICK START:
  .\New-VeeamSureBackupSetup.ps1
  # Interactive wizard - discovers everything and guides you through

  GUIDED MODE:
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -Prefix "SB"
  # Creates SureBackup for a specific backup job with auto-naming

  FULLY AUTOMATED:
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -HostName "esxi01" -Auto
  # Zero-prompt mode for scripting and automation

.PARAMETER BackupJobName
  Name of an existing Veeam backup job to verify. If omitted, the wizard
  will display available jobs and let you choose.

.PARAMETER HostName
  ESXi host or Hyper-V server for the Virtual Lab. If omitted, the wizard
  will discover available hosts and let you choose.

.PARAMETER DatastoreName
  Datastore (VMware) or volume (Hyper-V) for Virtual Lab storage. If omitted,
  the wizard selects the datastore with the most free space on the chosen host.

.PARAMETER Prefix
  Naming prefix for all created objects (Virtual Lab, App Group, SureBackup Job).
  Default: "SB". Example: "SB-Exchange" produces "SB-Exchange-VirtualLab".

.PARAMETER IsolatedNetworkPrefix
  Network prefix for isolated networks. Default: "10.99". Produces subnets
  like 10.99.1.0/24, 10.99.2.0/24 for each mapped production network.

.PARAMETER ProxyApplianceIp
  IP address for the Virtual Lab proxy appliance. Default: auto-calculated
  from IsolatedNetworkPrefix (e.g., 10.99.0.1).

.PARAMETER ProxyApplianceNetmask
  Subnet mask for the proxy appliance. Default: 255.255.255.0.

.PARAMETER MaxVmsToVerify
  Maximum number of VMs to include in the Application Group. Default: 10.
  VMs are selected by priority (domain controllers first, then by size ascending).

.PARAMETER VerificationTests
  Tests to run on each VM. Default: "Heartbeat". Options: Heartbeat, Ping, Script.
  Heartbeat checks VMware Tools/Integration Services. Ping checks ICMP.

.PARAMETER StartupTimeout
  Seconds to wait for each VM to start before marking as failed. Default: 300.

.PARAMETER Auto
  Fully automated mode. Skips all interactive prompts and uses defaults or
  provided parameter values. Ideal for scripting and CI/CD pipelines.

.PARAMETER WhatIf
  Shows what would be created without making any changes. Generates the
  validation report but does not create any Veeam objects.

.PARAMETER OutputPath
  Output folder for the HTML summary report. Default: ./SureBackupSetup_[timestamp].

.PARAMETER GenerateHTML
  Generate an HTML summary report of the configuration. Default: true.

.EXAMPLE
  .\New-VeeamSureBackupSetup.ps1
  # Interactive wizard - best for first-time setup

.EXAMPLE
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -Prefix "Prod"
  # Semi-guided: specify the job, wizard handles the rest

.EXAMPLE
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "Daily Backup" -HostName "esxi01" -Auto
  # Fully automated with defaults

.EXAMPLE
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "SQL Backup" -Prefix "SQL" -MaxVmsToVerify 3 -WhatIf
  # Preview what would be created without making changes

.EXAMPLE
  .\New-VeeamSureBackupSetup.ps1 -BackupJobName "DC Backup" -IsolatedNetworkPrefix "172.30" -ProxyApplianceIp "172.30.0.1"
  # Custom isolated network addressing

.NOTES
  Version: 1.0.0
  Author: Veeam Software
  Requires: PowerShell 5.1+, Veeam Backup & Replication 12+ with PowerShell snap-in
  Platform: VMware vSphere or Microsoft Hyper-V
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
  # Core selection
  [string]$BackupJobName,
  [string]$HostName,
  [string]$DatastoreName,

  # Naming
  [ValidateLength(1, 20)]
  [string]$Prefix = "SB",

  # Isolated network configuration
  [ValidatePattern('^\d{1,3}\.\d{1,3}$')]
  [string]$IsolatedNetworkPrefix = "10.99",

  [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')]
  [string]$ProxyApplianceIp,

  [ValidatePattern('^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$')]
  [string]$ProxyApplianceNetmask = "255.255.255.0",

  # Application group options
  [ValidateRange(1, 50)]
  [int]$MaxVmsToVerify = 10,

  [ValidateSet("Heartbeat", "Ping", "Script")]
  [string[]]$VerificationTests = @("Heartbeat"),

  [ValidateRange(60, 1800)]
  [int]$StartupTimeout = 300,

  # Behavior
  [switch]$Auto,

  # Output
  [string]$OutputPath,
  [switch]$GenerateHTML = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-level variables
# =============================
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 8
$script:CurrentStep = 0
$script:Platform = $null  # "VMware" or "HyperV"

# Default proxy IP from prefix if not provided
if (-not $ProxyApplianceIp) {
  $ProxyApplianceIp = "$IsolatedNetworkPrefix.0.1"
}

# =============================
# Logging & Progress
# =============================

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
    "INFO"    { "White" }
    "WARNING" { "Yellow" }
    "ERROR"   { "Red" }
    "SUCCESS" { "Green" }
  }
  Write-Host "[$timestamp] $Level : $Message" -ForegroundColor $color
}

function Write-Step {
  param([string]$StepName)

  $script:CurrentStep++
  $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Host ""
  Write-Host "=" * 60 -ForegroundColor Cyan
  Write-Host "  Step $($script:CurrentStep)/$($script:TotalSteps) ($pct%) : $StepName" -ForegroundColor Cyan
  Write-Host "=" * 60 -ForegroundColor Cyan
  Write-Log "Step $($script:CurrentStep): $StepName"
}

function Write-Banner {
  $banner = @"

  ____                 ____             _                 ____       _
 / ___| _   _ _ __ ___| __ )  __ _  ___| | ___   _ _ __  / ___|  ___| |_ _   _ _ __
 \___ \| | | | '__/ _ \  _ \ / _` |/ __| |/ / | | | '_ \ \___ \ / _ \ __| | | | '_ \
  ___) | |_| | | |  __/ |_) | (_| | (__|   <| |_| | |_) | ___) |  __/ |_| |_| | |_) |
 |____/ \__,_|_|  \___|____/ \__,_|\___|_|\_\\__,_| .__/ |____/ \___|\__|\__,_| .__/
                                                   |_|                         |_|
  Veeam SureBackup Setup Wizard v1.0.0
  Simplifying backup verification since 2026

"@
  Write-Host $banner -ForegroundColor Green
}

# =============================
# Interactive Selection Helpers
# =============================

function Select-FromList {
  <#
  .SYNOPSIS
    Presents a numbered list and returns the user's selection.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][object[]]$Items,
    [Parameter(Mandatory = $true)][string]$DisplayProperty,
    [string]$DetailProperty,
    [switch]$AllowMultiple
  )

  Write-Host ""
  Write-Host "  $Title" -ForegroundColor Yellow
  Write-Host "  $('-' * $Title.Length)" -ForegroundColor DarkGray

  for ($i = 0; $i -lt $Items.Count; $i++) {
    $display = $Items[$i].$DisplayProperty
    $detail = if ($DetailProperty) { " - $($Items[$i].$DetailProperty)" } else { "" }
    Write-Host "  [$($i + 1)] $display$detail" -ForegroundColor White
  }

  Write-Host ""
  if ($AllowMultiple) {
    Write-Host "  Enter numbers separated by commas (e.g., 1,3,5) or 'all':" -ForegroundColor DarkGray
  }
  else {
    Write-Host "  Enter number [1-$($Items.Count)]:" -ForegroundColor DarkGray
  }

  while ($true) {
    $input = Read-Host "  Selection"

    if ($AllowMultiple -and $input -eq 'all') {
      return $Items
    }

    if ($AllowMultiple) {
      $indices = $input -split ',' | ForEach-Object {
        $num = $_.Trim() -as [int]
        if ($num -ge 1 -and $num -le $Items.Count) { $num - 1 }
      }
      if ($indices.Count -gt 0) {
        return $Items[$indices]
      }
    }
    else {
      $num = $input.Trim() -as [int]
      if ($num -ge 1 -and $num -le $Items.Count) {
        return $Items[$num - 1]
      }
    }

    Write-Host "  Invalid selection. Please try again." -ForegroundColor Red
  }
}

function Confirm-Choice {
  <#
  .SYNOPSIS
    Yes/No confirmation prompt with a default.
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [bool]$Default = $true
  )

  if ($Auto) { return $Default }

  $options = if ($Default) { "[Y/n]" } else { "[y/N]" }
  Write-Host ""
  $response = Read-Host "  $Message $options"

  if ([string]::IsNullOrWhiteSpace($response)) { return $Default }
  return $response.Trim().ToLower() -eq 'y'
}

# =============================
# VBR Connection & Discovery
# =============================

function Connect-VBRIfNeeded {
  <#
  .SYNOPSIS
    Loads the Veeam PowerShell snap-in and connects to the local VBR server.
  #>
  Write-Step "Connecting to Veeam Backup & Replication"

  # Load snap-in or module
  $snapinLoaded = $false
  try {
    if (-not (Get-PSSnapin -Name VeeamPSSnapIn -ErrorAction SilentlyContinue)) {
      if (Get-PSSnapin -Registered -Name VeeamPSSnapIn -ErrorAction SilentlyContinue) {
        Add-PSSnapin VeeamPSSnapIn
        Write-Log "Loaded VeeamPSSnapIn snap-in" -Level SUCCESS
        $snapinLoaded = $true
      }
    }
    else {
      Write-Log "VeeamPSSnapIn already loaded" -Level SUCCESS
      $snapinLoaded = $true
    }
  }
  catch {
    Write-Log "Snap-in not available, trying module import" -Level WARNING
  }

  if (-not $snapinLoaded) {
    try {
      Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
      Write-Log "Loaded Veeam.Backup.PowerShell module" -Level SUCCESS
    }
    catch {
      Write-Log "FAILED: Cannot load Veeam PowerShell components" -Level ERROR
      Write-Log "Ensure Veeam Backup & Replication console is installed" -Level ERROR
      Write-Log "Run this script from the VBR server or a machine with the console installed" -Level ERROR
      throw "Veeam PowerShell snap-in/module not found. Install the VBR console first."
    }
  }

  # Connect to local VBR server if not already connected
  try {
    $server = Get-VBRServer -Type Local -ErrorAction SilentlyContinue
    if (-not $server) {
      Connect-VBRServer -Server localhost
      Write-Log "Connected to local VBR server" -Level SUCCESS
    }
    else {
      Write-Log "Already connected to VBR server: $($server.Name)" -Level SUCCESS
    }
  }
  catch {
    Write-Log "Connecting to localhost VBR server..." -Level INFO
    try {
      Connect-VBRServer -Server localhost
      Write-Log "Connected to VBR server" -Level SUCCESS
    }
    catch {
      throw "Cannot connect to VBR server. Ensure the Veeam Backup Service is running. Error: $_"
    }
  }
}

function Get-InfrastructurePlatform {
  <#
  .SYNOPSIS
    Detects whether the environment is VMware or Hyper-V based on managed servers.
  #>
  Write-Step "Detecting Infrastructure Platform"

  $viServers = @(Get-VBRServer -Type ESXi -ErrorAction SilentlyContinue) +
               @(Get-VBRServer -Type VcdSystem -ErrorAction SilentlyContinue)
  $hvServers = @(Get-VBRServer -Type HvServer -ErrorAction SilentlyContinue) +
               @(Get-VBRServer -Type HvCluster -ErrorAction SilentlyContinue)

  # Also check for vCenter
  $vcServers = @(Get-VBRServer -Type VC -ErrorAction SilentlyContinue)
  $viServers = $viServers + $vcServers

  if ($viServers.Count -gt 0 -and $hvServers.Count -gt 0) {
    Write-Log "Both VMware and Hyper-V hosts detected" -Level WARNING

    if ($Auto) {
      # Prefer VMware in auto mode (more common SureBackup use case)
      $script:Platform = "VMware"
      Write-Log "Auto-selected VMware (more hosts detected)" -Level INFO
    }
    else {
      $platformChoice = Select-FromList -Title "Multiple platforms detected. Select platform:" `
        -Items @(
        [PSCustomObject]@{ Name = "VMware vSphere"; Detail = "$($viServers.Count) host(s)/vCenter(s)" },
        [PSCustomObject]@{ Name = "Microsoft Hyper-V"; Detail = "$($hvServers.Count) host(s)/cluster(s)" }
      ) -DisplayProperty "Name" -DetailProperty "Detail"

      $script:Platform = if ($platformChoice.Name -like "*VMware*") { "VMware" } else { "HyperV" }
    }
  }
  elseif ($viServers.Count -gt 0) {
    $script:Platform = "VMware"
  }
  elseif ($hvServers.Count -gt 0) {
    $script:Platform = "HyperV"
  }
  else {
    throw "No VMware or Hyper-V hosts found in VBR. Add managed infrastructure first."
  }

  Write-Log "Platform: $($script:Platform)" -Level SUCCESS
  return $script:Platform
}

# =============================
# VMware Discovery
# =============================

function Get-VMwareHosts {
  <#
  .SYNOPSIS
    Discovers available ESXi hosts via VBR, returns list with resource info.
  #>
  $servers = @()

  # Get vCenter servers and their ESXi hosts
  $vcServers = Get-VBRServer -Type VC -ErrorAction SilentlyContinue
  foreach ($vc in $vcServers) {
    $esxiHosts = Get-VBRServer -Type ESXi -ErrorAction SilentlyContinue |
      Where-Object { $_.ParentId -eq $vc.Id }
    $servers += $esxiHosts
  }

  # Also get standalone ESXi hosts
  $standaloneEsxi = Get-VBRServer -Type ESXi -ErrorAction SilentlyContinue |
    Where-Object { $null -eq $_.ParentId }
  $servers += $standaloneEsxi

  if ($servers.Count -eq 0) {
    throw "No ESXi hosts found in VBR managed infrastructure."
  }

  $hostList = foreach ($srv in $servers) {
    [PSCustomObject]@{
      Name       = $srv.Name
      ServerObj  = $srv
      Detail     = "ESXi Host"
    }
  }

  return $hostList
}

function Get-VMwareDatastores {
  <#
  .SYNOPSIS
    Gets datastores available on a given ESXi host.
  #>
  param([object]$ServerObj)

  $datastores = Find-VBRViEntity -Server $ServerObj -DatastoresAndVMs -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq "Datastore" }

  if (-not $datastores -or $datastores.Count -eq 0) {
    # Fallback: try getting all datastores
    $datastores = Find-VBRViEntity -DatastoresAndVMs -ErrorAction SilentlyContinue |
      Where-Object { $_.Type -eq "Datastore" }
  }

  $dsList = foreach ($ds in $datastores) {
    $freeGB = [math]::Round($ds.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($ds.ProvisionedSize / 1GB, 1)
    $usedPct = if ($totalGB -gt 0) { [math]::Round((1 - $freeGB / $totalGB) * 100, 0) } else { 0 }

    [PSCustomObject]@{
      Name      = $ds.Name
      FreeGB    = $freeGB
      TotalGB   = $totalGB
      UsedPct   = $usedPct
      EntityObj = $ds
      Detail    = "${freeGB} GB free / ${totalGB} GB total (${usedPct}% used)"
    }
  }

  return $dsList | Sort-Object FreeGB -Descending
}

function Get-VMwareNetworks {
  <#
  .SYNOPSIS
    Discovers production networks (port groups) from the VBR-managed infrastructure.
  #>
  param([object]$ServerObj)

  $networks = Find-VBRViEntity -Server $ServerObj -Networks -ErrorAction SilentlyContinue

  if (-not $networks -or $networks.Count -eq 0) {
    $networks = Find-VBRViEntity -Networks -ErrorAction SilentlyContinue
  }

  $netList = foreach ($net in $networks) {
    [PSCustomObject]@{
      Name      = $net.Name
      EntityObj = $net
      Detail    = "Port Group"
    }
  }

  return $netList
}

# =============================
# Hyper-V Discovery
# =============================

function Get-HyperVHosts {
  <#
  .SYNOPSIS
    Discovers available Hyper-V hosts via VBR.
  #>
  $servers = @()
  $servers += @(Get-VBRServer -Type HvServer -ErrorAction SilentlyContinue)
  $servers += @(Get-VBRServer -Type HvCluster -ErrorAction SilentlyContinue)

  if ($servers.Count -eq 0) {
    throw "No Hyper-V hosts or clusters found in VBR managed infrastructure."
  }

  $hostList = foreach ($srv in $servers) {
    $type = if ($srv.Type -eq "HvCluster") { "Cluster" } else { "Standalone" }
    [PSCustomObject]@{
      Name      = $srv.Name
      ServerObj = $srv
      Detail    = "Hyper-V $type"
    }
  }

  return $hostList
}

function Get-HyperVVolumes {
  <#
  .SYNOPSIS
    Gets storage volumes available on a Hyper-V host for Virtual Lab placement.
  #>
  param([object]$ServerObj)

  $volumes = Find-VBRHvEntity -Server $ServerObj -ErrorAction SilentlyContinue |
    Where-Object { $_.Type -eq "Volume" }

  $volList = foreach ($vol in $volumes) {
    $freeGB = [math]::Round($vol.FreeSpace / 1GB, 1)
    $totalGB = [math]::Round($vol.ProvisionedSize / 1GB, 1)

    [PSCustomObject]@{
      Name      = $vol.Name
      FreeGB    = $freeGB
      TotalGB   = $totalGB
      EntityObj = $vol
      Detail    = "${freeGB} GB free / ${totalGB} GB total"
    }
  }

  return $volList | Sort-Object FreeGB -Descending
}

# =============================
# Backup Job Discovery
# =============================

function Get-EligibleBackupJobs {
  <#
  .SYNOPSIS
    Returns backup jobs that have restore points and can be used for SureBackup verification.
  #>
  $allJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object {
    $_.JobType -eq "Backup" -and $_.IsScheduleEnabled -eq $true
  }

  if ($allJobs.Count -eq 0) {
    # Also try disabled jobs
    $allJobs = Get-VBRJob -WarningAction SilentlyContinue | Where-Object {
      $_.JobType -eq "Backup"
    }
  }

  $jobList = foreach ($job in $allJobs) {
    $restorePoints = Get-VBRRestorePoint -Backup (Get-VBRBackup -Name $job.Name -ErrorAction SilentlyContinue) -ErrorAction SilentlyContinue
    $rpCount = if ($restorePoints) { $restorePoints.Count } else { 0 }
    $vmCount = ($job.GetObjectsInJob()).Count
    $lastRun = if ($job.LatestRunLocal) { $job.LatestRunLocal.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
    $status = if ($rpCount -gt 0) { "Ready" } else { "No restore points" }

    [PSCustomObject]@{
      Name          = $job.Name
      JobObj        = $job
      VmCount       = $vmCount
      RestorePoints = $rpCount
      LastRun       = $lastRun
      Status        = $status
      Detail        = "$vmCount VM(s) | $rpCount restore point(s) | Last: $lastRun | $status"
    }
  }

  return $jobList | Sort-Object RestorePoints -Descending
}

function Get-JobVMs {
  <#
  .SYNOPSIS
    Gets VMs from a backup job, prioritized for SureBackup verification.
    Domain controllers and small VMs first (they boot faster and verify quicker).
  #>
  param(
    [object]$BackupJob,
    [int]$MaxVMs = 10
  )

  $objects = $BackupJob.GetObjectsInJob()
  $backup = Get-VBRBackup -Name $BackupJob.Name -ErrorAction SilentlyContinue

  $vmList = foreach ($obj in $objects) {
    $name = $obj.Name
    # Heuristic: detect domain controllers by name pattern
    $isDC = $name -match 'dc|domain|ad[s]?\d|pdc|bdc' -and $name -notmatch 'podcast|produce'
    $priority = if ($isDC) { 1 } else { 5 }

    # Try to get size from restore point
    $sizeGB = 0
    if ($backup) {
      $rp = Get-VBRRestorePoint -Backup $backup -Name $name -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($rp) {
        $sizeGB = [math]::Round($rp.ApproxSize / 1GB, 1)
      }
    }

    [PSCustomObject]@{
      Name       = $name
      SizeGB     = $sizeGB
      IsDC       = $isDC
      Priority   = $priority
      Role       = if ($isDC) { "Domain Controller (detected)" } else { "Application Server" }
      ObjectInJob = $obj
      Detail     = "$(if ($isDC) {'[DC] '})${sizeGB} GB - $name"
    }
  }

  # Sort: DCs first, then smallest VMs first (boot faster)
  $sorted = $vmList | Sort-Object Priority, SizeGB
  return $sorted | Select-Object -First $MaxVMs
}

# =============================
# Network Configuration Builder
# =============================

function Build-NetworkMapping {
  <#
  .SYNOPSIS
    Auto-generates isolated network mappings from production networks.
    Each production network gets a corresponding isolated network with
    a unique subnet from the IsolatedNetworkPrefix.
  #>
  param(
    [object[]]$ProductionNetworks,
    [string]$NetPrefix
  )

  $subnetIndex = 1
  $mappings = foreach ($net in $ProductionNetworks) {
    $isolatedSubnet = "$NetPrefix.$subnetIndex.0"
    $isolatedGateway = "$NetPrefix.$subnetIndex.1"
    $isolatedDHCPStart = "$NetPrefix.$subnetIndex.10"
    $isolatedDHCPEnd = "$NetPrefix.$subnetIndex.200"

    [PSCustomObject]@{
      ProductionNetwork  = $net.Name
      IsolatedSubnet     = "$isolatedSubnet/24"
      IsolatedGateway    = $isolatedGateway
      IsolatedMask       = "255.255.255.0"
      DHCPStart          = $isolatedDHCPStart
      DHCPEnd            = $isolatedDHCPEnd
      MasqueradeEnabled  = $true
      NetworkObj         = $net.EntityObj
      SubnetIndex        = $subnetIndex
    }

    $subnetIndex++
  }

  return $mappings
}

function Get-NetworksForVMs {
  <#
  .SYNOPSIS
    Discovers which production networks the selected VMs use.
    Returns unique networks that need isolation mapping.
  #>
  param(
    [object[]]$VMs,
    [object]$ServerObj
  )

  # Get all available networks for this host
  if ($script:Platform -eq "VMware") {
    $allNetworks = Get-VMwareNetworks -ServerObj $ServerObj
  }
  else {
    # Hyper-V: get virtual switches
    $allNetworks = @()
    $switches = Find-VBRHvEntity -Server $ServerObj -ErrorAction SilentlyContinue |
      Where-Object { $_.Type -eq "Network" }
    foreach ($sw in $switches) {
      $allNetworks += [PSCustomObject]@{
        Name      = $sw.Name
        EntityObj = $sw
        Detail    = "Virtual Switch"
      }
    }
  }

  if (-not $allNetworks -or $allNetworks.Count -eq 0) {
    Write-Log "Could not auto-detect VM networks. Using default network." -Level WARNING
    # Return a placeholder that user will need to configure
    return @([PSCustomObject]@{
        Name      = "VM Network"
        EntityObj = $null
        Detail    = "Default (manual configuration may be needed)"
      })
  }

  return $allNetworks
}

# =============================
# Virtual Lab Creation
# =============================

function New-SureBackupVirtualLab {
  <#
  .SYNOPSIS
    Creates a Virtual Lab with proxy appliance and isolated network configuration.
  #>
  param(
    [string]$LabName,
    [object]$ServerObj,
    [object]$DatastoreObj,
    [object[]]$NetworkMappings,
    [string]$ProxyIp,
    [string]$ProxyMask
  )

  Write-Log "Creating Virtual Lab: $LabName" -Level INFO

  if ($script:Platform -eq "VMware") {
    return New-VMwareVirtualLab -LabName $LabName -ServerObj $ServerObj `
      -DatastoreObj $DatastoreObj -NetworkMappings $NetworkMappings `
      -ProxyIp $ProxyIp -ProxyMask $ProxyMask
  }
  else {
    return New-HyperVVirtualLab -LabName $LabName -ServerObj $ServerObj `
      -NetworkMappings $NetworkMappings -ProxyIp $ProxyIp -ProxyMask $ProxyMask
  }
}

function New-VMwareVirtualLab {
  param(
    [string]$LabName,
    [object]$ServerObj,
    [object]$DatastoreObj,
    [object[]]$NetworkMappings,
    [string]$ProxyIp,
    [string]$ProxyMask
  )

  # Build proxy appliance configuration
  $proxyParams = @{
    NetworkId = if ($NetworkMappings[0].NetworkObj) { $NetworkMappings[0].NetworkObj.Id } else { $null }
    IpAddress = $ProxyIp
    SubnetMask = $ProxyMask
  }

  # Build isolated network options for each production network
  $isolatedNetworks = foreach ($mapping in $NetworkMappings) {
    $isolatedNetParams = @{
      IsolatedNetworkName = "Isolated-$($mapping.ProductionNetwork)"
      Gateway             = $mapping.IsolatedGateway
      IPAddress           = $mapping.IsolatedGateway
      SubnetMask          = $mapping.IsolatedMask
      DHCPEnabled         = $true
      DHCPStartAddress    = $mapping.DHCPStart
      DHCPEndAddress      = $mapping.DHCPEnd
      EnableMasquerade    = $mapping.MasqueradeEnabled
    }
    $isolatedNetParams
  }

  # Create the Virtual Lab using Veeam cmdlets
  try {
    # Build network mapping objects
    $networkMappingOptions = @()
    foreach ($mapping in $NetworkMappings) {
      if ($mapping.NetworkObj) {
        $netMapping = New-VBRViVirtualLabNetworkMapping `
          -ProductionNetwork $mapping.NetworkObj `
          -IsolatedNetworkName "Isolated-$($mapping.ProductionNetwork)" `
          -RoutedNetworkGateway $mapping.IsolatedGateway `
          -RoutedNetworkAddress "$($mapping.IsolatedSubnet.Split('/')[0])" `
          -RoutedNetworkMask $mapping.IsolatedMask `
          -DHCPEnabled `
          -DHCPStartAddress $mapping.DHCPStart `
          -DHCPEndAddress $mapping.DHCPEnd `
          -ErrorAction Stop

        $networkMappingOptions += $netMapping
      }
    }

    # Create proxy appliance options
    $proxyAppliance = New-VBRViVirtualLabProxyAppliance `
      -Server $ServerObj `
      -Datastore $DatastoreObj `
      -IpAddress $ProxyIp `
      -SubnetMask $ProxyMask `
      -ErrorAction Stop

    # Create the Virtual Lab
    $lab = Add-VBRViVirtualLab `
      -Name $LabName `
      -Server $ServerObj `
      -Datastore $DatastoreObj `
      -ProxyAppliance $proxyAppliance `
      -NetworkMapping $networkMappingOptions `
      -ErrorAction Stop

    Write-Log "Virtual Lab '$LabName' created successfully" -Level SUCCESS
    return $lab
  }
  catch {
    Write-Log "Error creating VMware Virtual Lab: $_" -Level ERROR
    throw
  }
}

function New-HyperVVirtualLab {
  param(
    [string]$LabName,
    [object]$ServerObj,
    [object[]]$NetworkMappings,
    [string]$ProxyIp,
    [string]$ProxyMask
  )

  try {
    # Build network mapping for Hyper-V
    $networkMappingOptions = @()
    foreach ($mapping in $NetworkMappings) {
      if ($mapping.NetworkObj) {
        $netMapping = New-VBRHvVirtualLabNetworkMapping `
          -ProductionNetwork $mapping.NetworkObj `
          -IsolatedNetworkName "Isolated-$($mapping.ProductionNetwork)" `
          -DHCPEnabled `
          -DHCPStartAddress $mapping.DHCPStart `
          -DHCPEndAddress $mapping.DHCPEnd `
          -ErrorAction Stop

        $networkMappingOptions += $netMapping
      }
    }

    # Create proxy appliance for Hyper-V
    $proxyAppliance = New-VBRHvVirtualLabProxyAppliance `
      -Server $ServerObj `
      -IpAddress $ProxyIp `
      -SubnetMask $ProxyMask `
      -ErrorAction Stop

    # Create Hyper-V Virtual Lab
    $lab = Add-VBRHvVirtualLab `
      -Name $LabName `
      -Server $ServerObj `
      -ProxyAppliance $proxyAppliance `
      -NetworkMapping $networkMappingOptions `
      -ErrorAction Stop

    Write-Log "Hyper-V Virtual Lab '$LabName' created successfully" -Level SUCCESS
    return $lab
  }
  catch {
    Write-Log "Error creating Hyper-V Virtual Lab: $_" -Level ERROR
    throw
  }
}

# =============================
# Application Group Creation
# =============================

function New-SureBackupAppGroup {
  <#
  .SYNOPSIS
    Creates an Application Group with VMs in priority order and verification tests.
  #>
  param(
    [string]$GroupName,
    [object[]]$VMs,
    [object]$BackupJob,
    [string[]]$Tests,
    [int]$Timeout
  )

  Write-Log "Creating Application Group: $GroupName" -Level INFO

  try {
    # Build VM startup options with ordering
    $startupOrder = 1
    $vmOptions = foreach ($vm in $VMs) {
      $testOptions = @()

      foreach ($test in $Tests) {
        switch ($test) {
          "Heartbeat" {
            $testOpt = New-VBRSureBackupTestOption -Heartbeat -ErrorAction SilentlyContinue
            if ($testOpt) { $testOptions += $testOpt }
          }
          "Ping" {
            $testOpt = New-VBRSureBackupTestOption -Ping -ErrorAction SilentlyContinue
            if ($testOpt) { $testOptions += $testOpt }
          }
          "Script" {
            Write-Log "Script-based tests require manual configuration for VM '$($vm.Name)'" -Level WARNING
          }
        }
      }

      # Set startup delay: DCs get no delay, others get 30s between each
      $delay = if ($vm.IsDC) { 0 } else { 30 * ($startupOrder - 1) }

      $vmStartupParams = @{
        RestorePoint = $vm.Name
        StartupOrder = $startupOrder
        StartupDelay = $delay
        TestOptions  = $testOptions
        Timeout      = $Timeout
      }

      $startupOrder++
      $vmStartupParams
    }

    # Get the backup object
    $backup = Get-VBRBackup -Name $BackupJob.Name -ErrorAction Stop

    # Build application group VM list
    $appGroupVMs = @()
    foreach ($vm in $VMs) {
      $restorePoint = Get-VBRRestorePoint -Backup $backup -Name $vm.Name -ErrorAction SilentlyContinue |
        Sort-Object CreationTime -Descending | Select-Object -First 1

      if ($restorePoint) {
        $vmConfig = New-VBRSureBackupVM `
          -RestorePoint $restorePoint `
          -StartupOrder ($VMs.IndexOf($vm) + 1) `
          -ErrorAction SilentlyContinue

        if ($vmConfig) {
          $appGroupVMs += $vmConfig
        }
        else {
          Write-Log "Could not configure VM '$($vm.Name)' for SureBackup" -Level WARNING
        }
      }
      else {
        Write-Log "No restore point found for VM '$($vm.Name)' - skipping" -Level WARNING
      }
    }

    if ($appGroupVMs.Count -eq 0) {
      throw "No VMs could be configured for the Application Group. Ensure backup jobs have restore points."
    }

    # Create the Application Group
    $appGroup = Add-VBRApplicationGroup `
      -Name $GroupName `
      -VM $appGroupVMs `
      -ErrorAction Stop

    Write-Log "Application Group '$GroupName' created with $($appGroupVMs.Count) VM(s)" -Level SUCCESS
    return $appGroup
  }
  catch {
    Write-Log "Error creating Application Group: $_" -Level ERROR
    throw
  }
}

# =============================
# SureBackup Job Creation
# =============================

function New-SureBackupVerificationJob {
  <#
  .SYNOPSIS
    Creates the SureBackup job that ties the Virtual Lab and Application Group together.
  #>
  param(
    [string]$JobName,
    [object]$VirtualLab,
    [object]$AppGroup
  )

  Write-Log "Creating SureBackup Job: $JobName" -Level INFO

  try {
    $sbJob = Add-VBRSureBackupJob `
      -Name $JobName `
      -VirtualLab $VirtualLab `
      -ApplicationGroup $AppGroup `
      -ErrorAction Stop

    Write-Log "SureBackup Job '$JobName' created successfully" -Level SUCCESS
    return $sbJob
  }
  catch {
    Write-Log "Error creating SureBackup Job: $_" -Level ERROR
    throw
  }
}

# =============================
# Validation & Pre-flight Checks
# =============================

function Test-Configuration {
  <#
  .SYNOPSIS
    Validates the planned configuration before creating any objects.
  #>
  param(
    [hashtable]$Config
  )

  Write-Step "Validating Configuration"

  $issues = @()
  $warnings = @()

  # Check host connectivity
  Write-Log "Checking host: $($Config.HostName)" -Level INFO
  if (-not $Config.HostObj) {
    $issues += "Selected host '$($Config.HostName)' is not accessible"
  }

  # Check datastore space (need at least 10 GB for Virtual Lab overhead)
  if ($Config.DatastoreFreeGB -and $Config.DatastoreFreeGB -lt 10) {
    $issues += "Datastore '$($Config.DatastoreName)' has less than 10 GB free ($($Config.DatastoreFreeGB) GB)"
  }
  elseif ($Config.DatastoreFreeGB -and $Config.DatastoreFreeGB -lt 50) {
    $warnings += "Datastore '$($Config.DatastoreName)' has limited free space ($($Config.DatastoreFreeGB) GB). Consider using a larger datastore."
  }

  # Check backup job has restore points
  if ($Config.RestorePointCount -eq 0) {
    $issues += "Backup job '$($Config.BackupJobName)' has no restore points. Run the backup job first."
  }

  # Check network prefix is valid
  $octets = $Config.IsolatedNetworkPrefix -split '\.'
  foreach ($octet in $octets) {
    $num = [int]$octet
    if ($num -lt 0 -or $num -gt 255) {
      $issues += "Invalid network prefix '$($Config.IsolatedNetworkPrefix)'. Each octet must be 0-255."
    }
  }

  # Check for naming conflicts
  $existingLabs = Get-VBRVirtualLab -ErrorAction SilentlyContinue
  if ($existingLabs | Where-Object { $_.Name -eq $Config.VirtualLabName }) {
    $issues += "A Virtual Lab named '$($Config.VirtualLabName)' already exists. Choose a different prefix."
  }

  $existingAppGroups = Get-VBRApplicationGroup -ErrorAction SilentlyContinue
  if ($existingAppGroups | Where-Object { $_.Name -eq $Config.AppGroupName }) {
    $issues += "An Application Group named '$($Config.AppGroupName)' already exists. Choose a different prefix."
  }

  $existingSBJobs = Get-VBRSureBackupJob -ErrorAction SilentlyContinue
  if ($existingSBJobs | Where-Object { $_.Name -eq $Config.SureBackupJobName }) {
    $issues += "A SureBackup Job named '$($Config.SureBackupJobName)' already exists. Choose a different prefix."
  }

  # Check proxy IP doesn't conflict
  try {
    $pingResult = Test-Connection -ComputerName $Config.ProxyApplianceIp -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($pingResult) {
      $warnings += "Proxy appliance IP '$($Config.ProxyApplianceIp)' responds to ping - may conflict with existing device."
    }
  }
  catch {
    # Ping failed = IP is likely available, which is good
  }

  # Report results
  if ($issues.Count -gt 0) {
    Write-Host ""
    Write-Host "  VALIDATION ERRORS:" -ForegroundColor Red
    foreach ($issue in $issues) {
      Write-Host "    [X] $issue" -ForegroundColor Red
      Write-Log "Validation error: $issue" -Level ERROR
    }
  }

  if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "  WARNINGS:" -ForegroundColor Yellow
    foreach ($warn in $warnings) {
      Write-Host "    [!] $warn" -ForegroundColor Yellow
      Write-Log "Validation warning: $warn" -Level WARNING
    }
  }

  if ($issues.Count -eq 0) {
    Write-Host ""
    Write-Host "  All validation checks passed" -ForegroundColor Green
    Write-Log "Validation passed" -Level SUCCESS
    return $true
  }
  else {
    Write-Log "Validation failed with $($issues.Count) error(s)" -Level ERROR
    return $false
  }
}

# =============================
# Configuration Summary Display
# =============================

function Show-ConfigurationSummary {
  <#
  .SYNOPSIS
    Displays the planned configuration for user review before creation.
  #>
  param([hashtable]$Config)

  Write-Host ""
  Write-Host "=" * 60 -ForegroundColor Cyan
  Write-Host "  SUREBACKUP CONFIGURATION SUMMARY" -ForegroundColor Cyan
  Write-Host "=" * 60 -ForegroundColor Cyan
  Write-Host ""

  Write-Host "  Platform:              $($Config.Platform)" -ForegroundColor White
  Write-Host ""

  Write-Host "  --- Virtual Lab ---" -ForegroundColor Yellow
  Write-Host "  Name:                  $($Config.VirtualLabName)" -ForegroundColor White
  Write-Host "  Host:                  $($Config.HostName)" -ForegroundColor White
  Write-Host "  Datastore:             $($Config.DatastoreName) ($($Config.DatastoreFreeGB) GB free)" -ForegroundColor White
  Write-Host "  Proxy Appliance IP:    $($Config.ProxyApplianceIp)" -ForegroundColor White
  Write-Host "  Proxy Netmask:         $($Config.ProxyApplianceNetmask)" -ForegroundColor White
  Write-Host ""

  Write-Host "  --- Network Mappings ---" -ForegroundColor Yellow
  foreach ($mapping in $Config.NetworkMappings) {
    Write-Host "  Production:            $($mapping.ProductionNetwork)" -ForegroundColor White
    Write-Host "    Isolated Subnet:     $($mapping.IsolatedSubnet)" -ForegroundColor DarkGray
    Write-Host "    Gateway:             $($mapping.IsolatedGateway)" -ForegroundColor DarkGray
    Write-Host "    DHCP Range:          $($mapping.DHCPStart) - $($mapping.DHCPEnd)" -ForegroundColor DarkGray
    Write-Host "    Masquerade:          $($mapping.MasqueradeEnabled)" -ForegroundColor DarkGray
    Write-Host ""
  }

  Write-Host "  --- Application Group ---" -ForegroundColor Yellow
  Write-Host "  Name:                  $($Config.AppGroupName)" -ForegroundColor White
  Write-Host "  Source Backup Job:     $($Config.BackupJobName)" -ForegroundColor White
  Write-Host "  Verification Tests:    $($Config.VerificationTests -join ', ')" -ForegroundColor White
  Write-Host "  Startup Timeout:       $($Config.StartupTimeout)s" -ForegroundColor White
  Write-Host "  VMs to Verify:" -ForegroundColor White
  $order = 1
  foreach ($vm in $Config.VMs) {
    $role = if ($vm.IsDC) { " [DC]" } else { "" }
    Write-Host "    $order. $($vm.Name)$role ($($vm.SizeGB) GB)" -ForegroundColor DarkGray
    $order++
  }
  Write-Host ""

  Write-Host "  --- SureBackup Job ---" -ForegroundColor Yellow
  Write-Host "  Name:                  $($Config.SureBackupJobName)" -ForegroundColor White
  Write-Host ""
  Write-Host "=" * 60 -ForegroundColor Cyan
}

# =============================
# HTML Report Generation
# =============================

function Export-HTMLReport {
  <#
  .SYNOPSIS
    Generates a professional HTML summary report of the SureBackup configuration.
  #>
  param(
    [hashtable]$Config,
    [string]$OutputFile
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime

  $vmRows = ""
  $order = 1
  foreach ($vm in $Config.VMs) {
    $role = if ($vm.IsDC) { '<span class="badge dc">Domain Controller</span>' } else { '<span class="badge app">Application</span>' }
    $vmRows += @"
      <tr>
        <td>$order</td>
        <td><strong>$($vm.Name)</strong></td>
        <td>$role</td>
        <td>$($vm.SizeGB) GB</td>
      </tr>
"@
    $order++
  }

  $networkRows = ""
  foreach ($mapping in $Config.NetworkMappings) {
    $masq = if ($mapping.MasqueradeEnabled) { "Enabled" } else { "Disabled" }
    $networkRows += @"
      <tr>
        <td><strong>$($mapping.ProductionNetwork)</strong></td>
        <td>$($mapping.IsolatedSubnet)</td>
        <td>$($mapping.IsolatedGateway)</td>
        <td>$($mapping.DHCPStart) - $($mapping.DHCPEnd)</td>
        <td>$masq</td>
      </tr>
"@
  }

  $logRows = ""
  foreach ($entry in $script:LogEntries) {
    $levelClass = switch ($entry.Level) {
      "ERROR"   { "log-error" }
      "WARNING" { "log-warn" }
      "SUCCESS" { "log-success" }
      default   { "log-info" }
    }
    $logRows += @"
      <tr class="$levelClass">
        <td>$($entry.Timestamp)</td>
        <td>$($entry.Level)</td>
        <td>$($entry.Message)</td>
      </tr>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>SureBackup Setup Report - $($Config.SureBackupJobName)</title>
  <style>
    :root {
      --veeam-green: #00b336;
      --veeam-dark: #005f1a;
      --veeam-light: #e6f9ed;
      --gray-50: #f8f9fa;
      --gray-100: #f0f1f3;
      --gray-200: #d9dbde;
      --gray-600: #6c757d;
      --gray-800: #343a40;
      --danger: #dc3545;
      --warning: #ffc107;
      --info: #0dcaf0;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
      background: var(--gray-50);
      color: var(--gray-800);
      line-height: 1.6;
    }

    .header {
      background: linear-gradient(135deg, var(--veeam-dark) 0%, var(--veeam-green) 100%);
      color: white;
      padding: 2rem 3rem;
    }

    .header h1 { font-size: 1.8rem; font-weight: 600; }
    .header .subtitle { opacity: 0.85; margin-top: 0.25rem; }
    .header .meta { margin-top: 1rem; font-size: 0.85rem; opacity: 0.7; }

    .container { max-width: 1100px; margin: 2rem auto; padding: 0 2rem; }

    .cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }

    .card {
      background: white;
      border-radius: 8px;
      padding: 1.25rem;
      box-shadow: 0 1px 3px rgba(0,0,0,0.08);
      border-left: 4px solid var(--veeam-green);
    }

    .card .label { font-size: 0.8rem; color: var(--gray-600); text-transform: uppercase; letter-spacing: 0.5px; }
    .card .value { font-size: 1.4rem; font-weight: 600; margin-top: 0.25rem; color: var(--gray-800); }
    .card .detail { font-size: 0.85rem; color: var(--gray-600); margin-top: 0.25rem; }

    .section {
      background: white;
      border-radius: 8px;
      padding: 1.5rem;
      margin-bottom: 1.5rem;
      box-shadow: 0 1px 3px rgba(0,0,0,0.08);
    }

    .section h2 {
      font-size: 1.2rem;
      font-weight: 600;
      margin-bottom: 1rem;
      padding-bottom: 0.5rem;
      border-bottom: 2px solid var(--veeam-light);
      color: var(--veeam-dark);
    }

    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 0.9rem;
    }

    thead th {
      background: var(--gray-100);
      padding: 0.6rem 0.8rem;
      text-align: left;
      font-weight: 600;
      font-size: 0.8rem;
      text-transform: uppercase;
      letter-spacing: 0.3px;
      color: var(--gray-600);
    }

    tbody td {
      padding: 0.6rem 0.8rem;
      border-bottom: 1px solid var(--gray-100);
    }

    tbody tr:hover { background: var(--gray-50); }

    .badge {
      display: inline-block;
      padding: 0.15rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
      font-weight: 600;
    }

    .badge.dc { background: #fff3cd; color: #856404; }
    .badge.app { background: #d1ecf1; color: #0c5460; }

    .config-grid {
      display: grid;
      grid-template-columns: 180px 1fr;
      gap: 0.4rem 1rem;
    }

    .config-grid .key { color: var(--gray-600); font-size: 0.85rem; }
    .config-grid .val { font-weight: 500; }

    .log-error td { color: var(--danger); }
    .log-warn td { color: #856404; }
    .log-success td { color: var(--veeam-dark); }
    .log-info td { color: var(--gray-600); }

    .footer {
      text-align: center;
      padding: 2rem;
      color: var(--gray-600);
      font-size: 0.8rem;
    }

    .status-ok { color: var(--veeam-green); font-weight: 600; }
    .status-warn { color: var(--warning); font-weight: 600; }
    .status-err { color: var(--danger); font-weight: 600; }

    @media print {
      body { background: white; }
      .header { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      .section { break-inside: avoid; box-shadow: none; border: 1px solid var(--gray-200); }
    }
  </style>
</head>
<body>

<div class="header">
  <h1>SureBackup Setup Report</h1>
  <div class="subtitle">Automated backup verification configuration</div>
  <div class="meta">Generated: $timestamp | Duration: $([math]::Round($duration.TotalSeconds, 1))s | Platform: $($Config.Platform)</div>
</div>

<div class="container">

  <div class="cards">
    <div class="card">
      <div class="label">Virtual Lab</div>
      <div class="value">$($Config.VirtualLabName)</div>
      <div class="detail">$($Config.HostName)</div>
    </div>
    <div class="card">
      <div class="label">App Group</div>
      <div class="value">$($Config.AppGroupName)</div>
      <div class="detail">$($Config.VMs.Count) VM(s)</div>
    </div>
    <div class="card">
      <div class="label">SureBackup Job</div>
      <div class="value">$($Config.SureBackupJobName)</div>
      <div class="detail">$($Config.VerificationTests -join ', ')</div>
    </div>
    <div class="card">
      <div class="label">Source Backup</div>
      <div class="value">$($Config.BackupJobName)</div>
      <div class="detail">$($Config.RestorePointCount) restore point(s)</div>
    </div>
  </div>

  <div class="section">
    <h2>Virtual Lab Configuration</h2>
    <div class="config-grid">
      <div class="key">Lab Name</div><div class="val">$($Config.VirtualLabName)</div>
      <div class="key">Host</div><div class="val">$($Config.HostName)</div>
      <div class="key">Datastore</div><div class="val">$($Config.DatastoreName) ($($Config.DatastoreFreeGB) GB free)</div>
      <div class="key">Proxy IP</div><div class="val">$($Config.ProxyApplianceIp)</div>
      <div class="key">Proxy Netmask</div><div class="val">$($Config.ProxyApplianceNetmask)</div>
    </div>
  </div>

  <div class="section">
    <h2>Network Isolation Mappings</h2>
    <p style="margin-bottom: 1rem; color: var(--gray-600); font-size: 0.85rem;">
      Each production network is mapped to an isolated subnet. The proxy appliance handles
      masquerading (NAT) so isolated VMs can reach production DNS/AD for verification.
    </p>
    <table>
      <thead>
        <tr>
          <th>Production Network</th>
          <th>Isolated Subnet</th>
          <th>Gateway</th>
          <th>DHCP Range</th>
          <th>Masquerade</th>
        </tr>
      </thead>
      <tbody>
        $networkRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2>Application Group - VM Verification Order</h2>
    <p style="margin-bottom: 1rem; color: var(--gray-600); font-size: 0.85rem;">
      VMs are started in order. Domain controllers boot first so dependent services
      can authenticate. Each VM is verified with: $($Config.VerificationTests -join ', ').
      Startup timeout: $($Config.StartupTimeout) seconds per VM.
    </p>
    <table>
      <thead>
        <tr>
          <th>Order</th>
          <th>VM Name</th>
          <th>Role</th>
          <th>Size</th>
        </tr>
      </thead>
      <tbody>
        $vmRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2>How It Works</h2>
    <div style="color: var(--gray-600); font-size: 0.9rem; line-height: 1.8;">
      <p><strong>1. Virtual Lab</strong> creates an isolated network bubble using the proxy appliance.
      VMs boot from backup files (no production impact) into this isolated environment.</p>
      <p style="margin-top: 0.5rem;"><strong>2. Network Masquerading</strong> lets isolated VMs reach
      specific production services (DNS, AD) through the proxy while remaining fully isolated.</p>
      <p style="margin-top: 0.5rem;"><strong>3. Verification Tests</strong> confirm each VM boots
      successfully (heartbeat), responds on the network (ping), and runs application-specific checks.</p>
      <p style="margin-top: 0.5rem;"><strong>4. SureBackup Job</strong> orchestrates the entire process:
      powers on VMs in order, waits for verification, reports results, then cleans up.</p>
    </div>
  </div>

  <div class="section">
    <h2>Setup Log</h2>
    <table>
      <thead>
        <tr><th>Timestamp</th><th>Level</th><th>Message</th></tr>
      </thead>
      <tbody>
        $logRows
      </tbody>
    </table>
  </div>

</div>

<div class="footer">
  Generated by New-VeeamSureBackupSetup v1.0.0 | Veeam Backup & Replication
</div>

</body>
</html>
"@

  $html | Out-File -FilePath $OutputFile -Encoding UTF8
  Write-Log "HTML report saved: $OutputFile" -Level SUCCESS
}

# =============================
# Main Execution
# =============================

try {
  Write-Banner

  # Step 1: Connect to VBR
  Connect-VBRIfNeeded

  # Step 2: Detect platform
  $platform = Get-InfrastructurePlatform

  # Step 3: Select or discover backup job
  Write-Step "Selecting Backup Job"

  $backupJobs = Get-EligibleBackupJobs

  if ($backupJobs.Count -eq 0) {
    throw "No backup jobs found. Create at least one backup job with restore points before setting up SureBackup."
  }

  $selectedJob = $null
  if ($BackupJobName) {
    $selectedJob = $backupJobs | Where-Object { $_.Name -eq $BackupJobName }
    if (-not $selectedJob) {
      Write-Log "Backup job '$BackupJobName' not found" -Level ERROR
      Write-Log "Available jobs: $($backupJobs.Name -join ', ')" -Level INFO
      throw "Backup job '$BackupJobName' not found. Check the name and try again."
    }
    Write-Log "Selected backup job: $($selectedJob.Name)" -Level INFO
  }
  elseif ($Auto) {
    # Auto mode: pick job with most restore points
    $selectedJob = $backupJobs | Select-Object -First 1
    Write-Log "Auto-selected backup job: $($selectedJob.Name) ($($selectedJob.RestorePoints) restore points)" -Level INFO
  }
  else {
    $selectedJob = Select-FromList -Title "Select a backup job to verify with SureBackup:" `
      -Items $backupJobs -DisplayProperty "Name" -DetailProperty "Detail"
    Write-Log "Selected backup job: $($selectedJob.Name)" -Level INFO
  }

  # Step 4: Select host
  Write-Step "Selecting Host for Virtual Lab"

  $hosts = if ($platform -eq "VMware") { Get-VMwareHosts } else { Get-HyperVHosts }

  $selectedHost = $null
  if ($HostName) {
    $selectedHost = $hosts | Where-Object { $_.Name -eq $HostName -or $_.Name -like "*$HostName*" }
    if (-not $selectedHost) {
      Write-Log "Host '$HostName' not found" -Level ERROR
      throw "Host '$HostName' not found in VBR managed infrastructure."
    }
    if ($selectedHost -is [array]) { $selectedHost = $selectedHost[0] }
    Write-Log "Selected host: $($selectedHost.Name)" -Level INFO
  }
  elseif ($Auto) {
    $selectedHost = $hosts | Select-Object -First 1
    Write-Log "Auto-selected host: $($selectedHost.Name)" -Level INFO
  }
  else {
    $selectedHost = Select-FromList -Title "Select a host for the Virtual Lab:" `
      -Items $hosts -DisplayProperty "Name" -DetailProperty "Detail"
    Write-Log "Selected host: $($selectedHost.Name)" -Level INFO
  }

  # Step 5: Select datastore and discover networks
  Write-Step "Configuring Storage & Networks"

  $selectedDatastore = $null
  if ($platform -eq "VMware") {
    $datastores = Get-VMwareDatastores -ServerObj $selectedHost.ServerObj

    if ($DatastoreName) {
      $selectedDatastore = $datastores | Where-Object { $_.Name -eq $DatastoreName -or $_.Name -like "*$DatastoreName*" }
      if ($selectedDatastore -is [array]) { $selectedDatastore = $selectedDatastore[0] }
    }
    elseif ($Auto) {
      $selectedDatastore = $datastores | Select-Object -First 1  # Most free space (pre-sorted)
    }
    else {
      $selectedDatastore = Select-FromList -Title "Select a datastore for the Virtual Lab:" `
        -Items $datastores -DisplayProperty "Name" -DetailProperty "Detail"
    }

    if (-not $selectedDatastore) {
      throw "No suitable datastore found. Ensure the selected host has accessible datastores."
    }

    Write-Log "Selected datastore: $($selectedDatastore.Name) ($($selectedDatastore.FreeGB) GB free)" -Level INFO
  }
  else {
    # Hyper-V: use volume or default path
    $volumes = Get-HyperVVolumes -ServerObj $selectedHost.ServerObj

    if ($volumes -and $volumes.Count -gt 0) {
      if ($Auto) {
        $selectedDatastore = $volumes | Select-Object -First 1
      }
      else {
        $selectedDatastore = Select-FromList -Title "Select a volume for the Virtual Lab:" `
          -Items $volumes -DisplayProperty "Name" -DetailProperty "Detail"
      }
      Write-Log "Selected volume: $($selectedDatastore.Name)" -Level INFO
    }
    else {
      Write-Log "No volumes discovered - Virtual Lab will use default Hyper-V path" -Level WARNING
      $selectedDatastore = [PSCustomObject]@{ Name = "Default"; FreeGB = 0; EntityObj = $null }
    }
  }

  # Discover VMs in the backup job and their networks
  $selectedVMs = Get-JobVMs -BackupJob $selectedJob.JobObj -MaxVMs $MaxVmsToVerify

  if (-not $Auto -and $selectedVMs.Count -gt 1) {
    Write-Host ""
    Write-Host "  VMs to include in verification (sorted by priority):" -ForegroundColor Yellow
    $i = 1
    foreach ($vm in $selectedVMs) {
      $role = if ($vm.IsDC) { " [DC]" } else { "" }
      Write-Host "    $i. $($vm.Name)$role ($($vm.SizeGB) GB)" -ForegroundColor White
      $i++
    }

    if (-not (Confirm-Choice "Include all $($selectedVMs.Count) VMs in Application Group?")) {
      $selectedVMs = Select-FromList -Title "Select VMs to include:" `
        -Items $selectedVMs -DisplayProperty "Name" -DetailProperty "Detail" -AllowMultiple
    }
  }

  Write-Log "Selected $($selectedVMs.Count) VM(s) for verification" -Level INFO

  # Discover networks
  $productionNetworks = Get-NetworksForVMs -VMs $selectedVMs -ServerObj $selectedHost.ServerObj

  if (-not $Auto -and $productionNetworks.Count -gt 1) {
    Write-Host ""
    Write-Host "  Select which production networks need isolation mapping:" -ForegroundColor Yellow
    $productionNetworks = Select-FromList -Title "Select production networks to map:" `
      -Items $productionNetworks -DisplayProperty "Name" -DetailProperty "Detail" -AllowMultiple
  }

  # Build network mappings
  $networkMappings = Build-NetworkMapping -ProductionNetworks $productionNetworks -NetPrefix $IsolatedNetworkPrefix
  Write-Log "Built $($networkMappings.Count) network isolation mapping(s)" -Level SUCCESS

  # Step 6: Build configuration object
  Write-Step "Building Configuration"

  $config = @{
    Platform               = $platform
    VirtualLabName         = "$Prefix-VirtualLab"
    AppGroupName           = "$Prefix-AppGroup"
    SureBackupJobName      = "$Prefix-SureBackupJob"
    HostName               = $selectedHost.Name
    HostObj                = $selectedHost.ServerObj
    DatastoreName          = $selectedDatastore.Name
    DatastoreFreeGB        = $selectedDatastore.FreeGB
    DatastoreObj           = $selectedDatastore.EntityObj
    BackupJobName          = $selectedJob.Name
    BackupJobObj           = $selectedJob.JobObj
    RestorePointCount      = $selectedJob.RestorePoints
    VMs                    = $selectedVMs
    NetworkMappings        = $networkMappings
    IsolatedNetworkPrefix  = $IsolatedNetworkPrefix
    ProxyApplianceIp       = $ProxyApplianceIp
    ProxyApplianceNetmask  = $ProxyApplianceNetmask
    VerificationTests      = $VerificationTests
    StartupTimeout         = $StartupTimeout
  }

  # Show summary
  Show-ConfigurationSummary -Config $config

  # Step 7: Validate
  $valid = Test-Configuration -Config $config

  if (-not $valid) {
    throw "Configuration validation failed. Fix the issues above and try again."
  }

  # Confirm before creating (unless WhatIf or Auto)
  if ($WhatIfPreference) {
    Write-Host ""
    Write-Host "  [WhatIf] No changes made. Review the configuration above." -ForegroundColor Yellow
    Write-Log "WhatIf mode - no objects created" -Level INFO
  }
  else {
    if (-not $Auto) {
      if (-not (Confirm-Choice "Create all SureBackup objects now?")) {
        Write-Log "User cancelled creation" -Level WARNING
        Write-Host ""
        Write-Host "  Setup cancelled. No changes were made." -ForegroundColor Yellow
        return
      }
    }

    # Step 8: Create everything
    Write-Step "Creating SureBackup Objects"

    # Create Virtual Lab
    Write-Log "Creating Virtual Lab..." -Level INFO
    $virtualLab = New-SureBackupVirtualLab `
      -LabName $config.VirtualLabName `
      -ServerObj $config.HostObj `
      -DatastoreObj $config.DatastoreObj `
      -NetworkMappings $config.NetworkMappings `
      -ProxyIp $config.ProxyApplianceIp `
      -ProxyMask $config.ProxyApplianceNetmask

    # Create Application Group
    Write-Log "Creating Application Group..." -Level INFO
    $appGroup = New-SureBackupAppGroup `
      -GroupName $config.AppGroupName `
      -VMs $config.VMs `
      -BackupJob $config.BackupJobObj `
      -Tests $config.VerificationTests `
      -Timeout $config.StartupTimeout

    # Create SureBackup Job
    Write-Log "Creating SureBackup Job..." -Level INFO
    $sbJob = New-SureBackupVerificationJob `
      -JobName $config.SureBackupJobName `
      -VirtualLab $virtualLab `
      -AppGroup $appGroup

    Write-Host ""
    Write-Host "  SureBackup setup completed successfully!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
    Write-Host "  1. Open Veeam Backup & Replication console" -ForegroundColor White
    Write-Host "  2. Navigate to Backup Infrastructure > SureBackup" -ForegroundColor White
    Write-Host "  3. Find job '$($config.SureBackupJobName)'" -ForegroundColor White
    Write-Host "  4. Right-click > Start to run your first verification" -ForegroundColor White
    Write-Host "  5. (Optional) Configure a schedule for automated verification" -ForegroundColor White
    Write-Host ""
    Write-Log "SureBackup setup completed successfully" -Level SUCCESS
  }

  # Generate HTML report
  if ($GenerateHTML) {
    if (-not $OutputPath) {
      $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
      $OutputPath = Join-Path $PSScriptRoot "SureBackupSetup_$timestamp"
    }

    if (-not (Test-Path $OutputPath)) {
      New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }

    $htmlFile = Join-Path $OutputPath "SureBackup-Setup-Report.html"
    Export-HTMLReport -Config $config -OutputFile $htmlFile
    Write-Host "  Report saved: $htmlFile" -ForegroundColor Green
  }
}
catch {
  Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
  Write-Host ""
  Write-Host "  TROUBLESHOOTING:" -ForegroundColor Cyan
  Write-Host "  - Ensure Veeam Backup & Replication service is running" -ForegroundColor White
  Write-Host "  - Run this script as Administrator on the VBR server" -ForegroundColor White
  Write-Host "  - Verify managed infrastructure is accessible in the VBR console" -ForegroundColor White
  Write-Host "  - Check that at least one backup job has completed successfully" -ForegroundColor White
  Write-Host ""
  Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ""

  # Still generate report with error log if possible
  if ($GenerateHTML -and $config) {
    try {
      if (-not $OutputPath) {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
        $OutputPath = Join-Path $PSScriptRoot "SureBackupSetup_$timestamp"
      }
      if (-not (Test-Path $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
      }
      $htmlFile = Join-Path $OutputPath "SureBackup-Setup-Report.html"
      Export-HTMLReport -Config $config -OutputFile $htmlFile
      Write-Host "  Error report saved: $htmlFile" -ForegroundColor Yellow
    }
    catch {
      # Report generation failed too - nothing more to do
    }
  }

  exit 1
}
finally {
  $elapsed = (Get-Date) - $script:StartTime
  Write-Host ""
  Write-Log "Total execution time: $([math]::Round($elapsed.TotalSeconds, 1)) seconds" -Level INFO
}
