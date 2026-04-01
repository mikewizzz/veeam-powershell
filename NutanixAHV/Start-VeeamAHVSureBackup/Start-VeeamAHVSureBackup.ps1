<#
.SYNOPSIS
  Veeam SureBackup for Nutanix AHV - Automated Backup Verification & Recovery Testing

.DESCRIPTION
  Bridges the gap between Veeam's VMware SureBackup and Nutanix AHV by providing automated
  backup recoverability verification using the Veeam Plug-in for Nutanix AHV REST API (v9)
  and Nutanix Prism Central REST API.

  DISCLAIMER: This is a community-developed script, not an official Veeam product feature.
  Veeam's native SureBackup for Nutanix AHV supports backup verification and content scan
  only. This script extends that capability by using public REST APIs to perform full VM
  restore and boot testing — functionality not available in the product natively.

  WHAT THIS SCRIPT DOES:
  1. Authenticates to Veeam AHV Plugin REST API via VBR OAuth2
  2. Connects to Nutanix Prism Central via REST API v3/v4
  3. Discovers AHV backup jobs and latest restore points via VBAHV REST API
  4. Performs Full VM Restore to an isolated AHV network (zero production exposure)
  5. Runs configurable verification tests (heartbeat, ping, port, DNS, custom scripts)
  6. Generates professional HTML report with pass/fail results
  7. Cleans up all recovered VMs via Prism API

  SUREBACKUP TEST PHASES:
  Phase 1 - VM Recovery:    Full VM Restore via VBAHV REST API to isolated AHV network
  Phase 2 - Boot Test:      Verify VM powers on and gets heartbeat via Nutanix Guest Tools
  Phase 3 - Network Test:   ICMP ping and TCP port connectivity checks
  Phase 4 - Application:    DNS resolution, HTTP endpoint, custom PowerShell script tests
  Phase 5 - Cleanup:        Power off + delete restored VMs via Prism API

  QUICK START:
  $vbrCred = Get-Credential   # VBR server credentials
  $pcCred  = Get-Credential   # Prism Central credentials
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01.lab.local" -VBRCredential $vbrCred -PrismCentral "pc01.lab.local" -PrismCredential $pcCred

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP address.

.PARAMETER VBRCredential
  PSCredential for VBR server authentication (required for REST API OAuth2).

.PARAMETER PrismCentral
  Nutanix Prism Central hostname or IP address for REST API calls.

.PARAMETER PrismPort
  Prism Central API port (default: 9440).

.PARAMETER PrismCredential
  PSCredential for Prism Central authentication (required).

.PARAMETER PrismApiVersion
  Prism Central API version to use: "v4" (default, GA in pc.2024.3+) or "v3" (legacy).
  v4 uses namespace-based endpoints (vmm, networking, clustermgmt), ETag concurrency,
  NTNX-Request-Id idempotency, and OData filtering. Use "v3" for older Prism Central.

.PARAMETER SkipCertificateCheck
  Skip TLS certificate validation for self-signed certificates (lab environments).

.PARAMETER BackupJobNames
  One or more Veeam backup job names to test. If omitted, discovers all AHV backup jobs.

.PARAMETER VMNames
  Specific VM names to test from backup jobs. If omitted, tests all VMs in selected jobs.

.PARAMETER MaxConcurrentVMs
  Maximum VMs to recover and test simultaneously (default: 3).

.PARAMETER IsolatedNetworkName
  Name of the pre-configured isolated AHV network/subnet for recovery testing.
  This network should have NO route to production. Create it in Prism before running.

.PARAMETER IsolatedNetworkUUID
  UUID of the isolated AHV subnet. Alternative to IsolatedNetworkName.

.PARAMETER TargetClusterName
  Nutanix cluster to recover VMs to. If omitted, uses the original source cluster.

.PARAMETER TargetContainerName
  Storage container for recovered VM disks (default: uses cluster default).

.PARAMETER TestBootTimeoutSec
  Maximum seconds to wait for VM boot and heartbeat (default: 300).

.PARAMETER TestPing
  Enable ICMP ping test (default: true). Requires Layer 3 (routed) connectivity
  from the script host to the isolated network. If the isolated network is truly
  air-gapped with no routing, ICMP tests will always fail. Set to $false in
  that case and rely on heartbeat/NGT tests instead.

.PARAMETER TestPorts
  TCP ports to test connectivity on recovered VMs (e.g., 22, 80, 443, 3389).

.PARAMETER TestDNS
  Enable DNS resolution test from recovered VMs (default: false).

.PARAMETER TestHttpEndpoints
  HTTP/HTTPS URLs to test on recovered VMs (e.g., "http://localhost/health").

.PARAMETER TestCustomScript
  Path to a custom PowerShell script to run against each recovered VM.
  Script receives $VMName, $VMIPAddress, $VMUuid as parameters.
  Must return $true for pass, $false for fail.

.PARAMETER ApplicationGroups
  Hashtable defining VM boot order groups and dependencies.
  Example: @{ 1 = @("dc01","dns01"); 2 = @("sql01"); 3 = @("app01","web01") }
  Group 1 boots first, then Group 2 after Group 1 passes tests, etc.

.PARAMETER OutputPath
  Output folder for reports, CSVs, and logs (default: ./VeeamAHVSureBackup_[timestamp]).

.PARAMETER GenerateHTML
  Generate professional HTML report (default: true).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.PARAMETER CleanupOnFailure
  Clean up recovered VMs even if tests fail (default: true).

.PARAMETER DryRun
  Simulate the entire SureBackup process without performing actual recovery.
  Validates connectivity, discovers backups, and shows what would be tested.

.PARAMETER RestoreTimeoutSec
  Maximum seconds to wait for a full VM restore to complete (default: 3600).
  Large VMs with multi-TB disks may need longer timeouts.

.PARAMETER VBAHVApiVersion
  Veeam Plug-in for Nutanix AHV REST API version (default: "v9").
  Only v9 is supported. This script uses v9-only endpoints (e.g., /restorePoints/{id}/metadata).

.PARAMETER RestoreToOriginal
  Restore VMs to their original location. Default: false (SureBackup uses isolated network).

.PARAMETER RestoreVmCategories
  Restore VM categories/tags during recovery. Default: false.

.PARAMETER Interactive
  Enable interactive VM selection with search/filter after restore point discovery.
  Type a partial name to filter, select by number, 'A' for all shown, or 'B' to re-filter.

.PARAMETER PreflightMaxAgeDays
  Maximum restore point age in days before preflight warns (default: 7).

.PARAMETER SkipPreflight
  Skip all preflight health checks. Not recommended for production.

.PARAMETER TargetRTOMinutes
  Target Recovery Time Objective in minutes (e.g., 60 = 1-hour RTO).
  When provided, the report includes SLA compliance scoring showing
  what percentage of VMs met the RTO target.

.PARAMETER TargetRPOHours
  Target Recovery Point Objective in hours (e.g., 24 = daily RPO).
  When provided, the report includes SLA compliance scoring and
  preflight checks use RPO as the restore point recency threshold
  if stricter than -PreflightMaxAgeDays.

.PARAMETER ResumeCheckpoint
  Path to SureBackup_Checkpoint.json from an interrupted run.
  Skips completed groups/batches and restores prior test results.

.PARAMETER UseJumpVM
  Enable jump VM for isolated network testing. Deploys a dual-homed Ubuntu VM
  (management NIC + isolated NIC) and proxies network tests (ping, port, DNS, HTTP)
  through it via SSH. Solves the air-gapped isolated network problem where the
  script host has no L3 path to recovered VMs. Same pattern as Veeam's VMware
  SureBackup proxy appliance.

.PARAMETER JumpVMImageName
  Override: use this pre-uploaded image for the jump VM instead of auto-downloading
  Ubuntu Minimal. Required for air-gapped clusters with no internet access.

.PARAMETER ManagementNetworkName
  Override: name of the management network reachable from the script host.
  If omitted with -UseJumpVM, the management network is auto-detected by
  keyword (mgmt, management, admin, default, prod, infra), DHCP heuristic,
  or single-remaining-network logic. Use -Interactive for a picker fallback.

.PARAMETER ManagementNetworkUUID
  Override: UUID of the management network. Alternative to -ManagementNetworkName.

.PARAMETER JumpVMBootTimeoutSec
  Maximum seconds to wait for the jump VM to boot and obtain a management IP
  (default: 180).

.EXAMPLE
  $vbrCred = Get-Credential
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred
  # Quick start - tests all AHV backup jobs with default settings

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -BackupJobNames "AHV-Production" -TestPorts @(22,443,3389) -SkipCertificateCheck
  # Test specific backup job with port checks, skip self-signed cert warnings

.EXAMPLE
  $groups = @{ 1 = @("dc01"); 2 = @("sql01"); 3 = @("app01","web01") }
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -ApplicationGroups $groups -TestPorts @(53,1433,443)
  # Application-group ordered testing with dependency boot order

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -DryRun
  # Dry run - validate connectivity and show what would be tested without recovering VMs

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -Interactive
  # Interactive mode - search/filter VMs by name, then select which to test

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -UseJumpVM -TestPorts @(22,443)
  # Jump VM mode - auto-detects management network, deploys dual-homed proxy VM, tests isolated VMs via SSH

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -UseJumpVM -ManagementNetworkName "MGMT" -TestPorts @(22,443)
  # Jump VM with explicit management network override (bypasses auto-detection)

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $cred -UseJumpVM -JumpVMImageName "my-cloud-image"
  # Jump VM with pre-uploaded image (air-gapped cluster, no internet)

.NOTES
  Version: 1.4.0
  Author: Community Contributors
  Date: 2026-03-11
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: None
  Nutanix: Prism Central v4 API (pc.2024.3+ GA, default) or v3 (legacy)
  VBR: Veeam Backup & Replication v12.2+ with Nutanix AHV Plugin v9
  AHV Plugin REST API: https://helpcenter.veeam.com/references/vbahv/9/rest/

  Static IP handling:
    VMs with static IPs boot on the isolated VLAN but retain their production IP.
    The script detects when a VM's IP is outside the isolated subnet CIDR and
    automatically skips network tests (ping, port, DNS, HTTP) to avoid false failures.
    Backup integrity is still verified via heartbeat/NGT. For full network testing of
    static IP VMs, pre-configure DHCP on the isolated VLAN or use -TestCustomScript.
#>

[CmdletBinding(DefaultParameterSetName = "NetworkByName")]
param(
  # VBR Connection (REST API only — no PowerShell module needed)
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$VBRServer,
  [Parameter(Mandatory = $true)]
  [PSCredential]$VBRCredential,

  # Nutanix Prism Central Connection
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$PrismCentral,
  [ValidateRange(1, 65535)]
  [int]$PrismPort = 9440,
  [Parameter(Mandatory = $true)]
  [PSCredential]$PrismCredential,
  [ValidateSet("v4", "v3")]
  [string]$PrismApiVersion = "v4",
  [switch]$SkipCertificateCheck,

  # Backup Scope
  [string[]]$BackupJobNames,
  [string[]]$VMNames,
  [ValidateRange(1, 10)]
  [int]$MaxConcurrentVMs = 3,

  # Isolated Network (virtual lab)
  [Parameter(ParameterSetName = "NetworkByName")]
  [string]$IsolatedNetworkName,
  [Parameter(ParameterSetName = "NetworkByUUID")]
  [string]$IsolatedNetworkUUID,

  # Recovery Target
  [string]$TargetClusterName,
  [string]$TargetContainerName,

  # Test Configuration
  [ValidateRange(60, 1800)]
  [int]$TestBootTimeoutSec = 300,
  [bool]$TestPing = $true,
  [ValidateScript({ foreach ($p in $_) { if ($p -lt 1 -or $p -gt 65535) { throw "Port $p is out of valid range (1-65535)" } }; $true })]
  [int[]]$TestPorts,
  [switch]$TestDNS,
  [ValidateScript({ foreach ($u in $_) { if ($u -notmatch '^https?://') { throw "Endpoint '$u' must start with http:// or https://" } }; $true })]
  [string[]]$TestHttpEndpoints,
  [ValidateScript({ if ($_ -and -not (Test-Path $_)) { throw "Custom script not found: $_" }; $true })]
  [string]$TestCustomScript,

  # Application Groups (boot order)
  [hashtable]$ApplicationGroups,

  # Output
  [string]$OutputPath,
  [bool]$GenerateHTML = $true,
  [bool]$ZipOutput = $true,

  # Behavior
  [bool]$CleanupOnFailure = $true,
  [switch]$DryRun,

  # Restore Timing
  [ValidateRange(300, 14400)]
  [int]$RestoreTimeoutSec = 3600,

  # VBAHV Plugin REST API
  [ValidateSet("v9")]
  [string]$VBAHVApiVersion = "v9",

  # Restore Options
  [switch]$RestoreToOriginal,
  [switch]$RestoreVmCategories,
  [switch]$Interactive,

  # Preflight Health Checks
  [ValidateRange(1, 365)]
  [int]$PreflightMaxAgeDays = 7,
  [switch]$SkipPreflight,

  # SLA Targets (optional — enables compliance scoring in reports)
  [ValidateRange(1, 1440)]
  [int]$TargetRTOMinutes,
  [ValidateRange(1, 8760)]
  [int]$TargetRPOHours,

  # Checkpoint / Resume
  [string]$ResumeCheckpoint,

  # Jump VM (isolated network testing)
  [switch]$UseJumpVM,
  [string]$JumpVMImageName,
  [string]$ManagementNetworkName,
  [string]$ManagementNetworkUUID,
  [ValidateRange(60, 600)]
  [int]$JumpVMBootTimeoutSec = 180
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-Level State
# =============================
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:TestResults = New-Object System.Collections.Generic.List[object]
$script:RecoverySessions = New-Object System.Collections.Generic.List[object]
$script:PrismHeaders = @{}
$script:TotalSteps = 10
$script:CurrentStep = 0
$script:FatalError = $false
$script:CompletedSuccessfully = $false
$script:JumpVM = $null
$script:VMTimings = New-Object System.Collections.Generic.List[object]

# API version-aware base URL and endpoint mapping
$script:PrismOrigin = "https://${PrismCentral}:${PrismPort}"
if ($PrismApiVersion -eq "v4") {
  $script:PrismBaseUrl = "$($script:PrismOrigin)/api"
  # v4 namespace-based endpoints (GA in pc.2024.3+)
  $script:PrismEndpoints = @{
    VMs      = "vmm/v4.0/ahv/config/vms"
    Subnets  = "networking/v4.0/config/subnets"
    Clusters = "clustermgmt/v4.0/config/clusters"
    Tasks    = "prism/v4.0/config/tasks"
  }
}
else {
  $script:PrismBaseUrl = "$($script:PrismOrigin)/api/nutanix/v3"
  $script:PrismEndpoints = @{
    VMs      = "vms"
    Subnets  = "subnets"
    Clusters = "clusters"
    Tasks    = "tasks"
  }
}
$script:PrismApiVersion = $PrismApiVersion

# Output folder
if (-not $OutputPath) {
  $OutputPath = ".\VeeamAHVSureBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

# =============================
# Load Function Libraries
# =============================
$libPath = Join-Path $PSScriptRoot "lib"
$requiredLibs = @(
  "Logging.ps1", "Helpers.ps1", "PrismAPI.ps1", "VeeamVBR.ps1",
  "Verification.ps1", "Orchestration.ps1", "Reporting.ps1", "Output.ps1",
  "Preflight.ps1"
)
foreach ($lib in $requiredLibs) {
  $libFile = Join-Path $libPath $lib
  if (-not (Test-Path $libFile)) {
    throw "Required library not found: $libFile. Ensure all files in lib/ are present."
  }
  . $libFile
}

# =============================
# Main Execution
# =============================

try {
  Write-Banner

  # ---- Step 1: Initialize output ----
  Write-ProgressStep -Activity "Initializing" -Status "Setting up output directory..."
  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
  }
  Write-Log "Output directory: $OutputPath" -Level "INFO"
  Write-Log "Mode: $(if($DryRun){'DRY RUN (simulation only)'}else{'LIVE - VMs will be recovered'})" -Level $(if($DryRun){"WARNING"}else{"INFO"})
  Write-Log "Architecture: VBAHV Plugin REST API v9 + Prism Central REST API" -Level "INFO"

  # ---- Step 2: Connect to Prism Central ----
  Write-ProgressStep -Activity "Connecting to Nutanix Prism Central" -Status "$PrismCentral`:$PrismPort"
  Initialize-PrismConnection

  if (-not (Test-PrismConnection)) {
    throw "Cannot connect to Prism Central at $PrismCentral`:$PrismPort. Verify hostname, port, and credentials."
  }

  # ---- Step 3: Resolve isolated network ----
  Write-ProgressStep -Activity "Resolving Isolated Network" -Status "Finding SureBackup virtual lab network..."
  $isolatedNet = Resolve-IsolatedNetwork

  # ---- Step 4: Authenticate to VBAHV Plugin REST API ----
  Write-ProgressStep -Activity "Connecting to VBAHV Plugin REST API" -Status "Authenticating via VBR OAuth2..."
  Initialize-VBAHVPluginConnection

  # ---- Step 5: Discover AHV backup jobs and restore points ----
  Write-ProgressStep -Activity "Discovering AHV Backups" -Status "Scanning backup jobs and restore points..."
  $ahvJobs = Get-VBAHVJobs -JobNames $BackupJobNames

  # Discover protected VMs via VBAHV Plugin (prismCentrals -> VMs)
  $allProtectedVMs = Get-VBAHVProtectedVMs -VMNames $VMNames
  $restorePointsList = New-Object System.Collections.Generic.List[object]

  if ($allProtectedVMs -and @($allProtectedVMs).Count -gt 0) {
    Write-Log "Resolving real restore points via VBR Core REST API..." -Level "INFO"
    foreach ($vm in @($allProtectedVMs)) {
      # Look up real restore point metadata from VBR Core API
      $vbrRP = Get-VBRObjectRestorePoints -VMName $vm.name

      if ($vbrRP) {
        $rpInfo = [PSCustomObject]@{
          VMName         = $vm.name
          JobName        = if ($vm.protectionDomain) { $vm.protectionDomain } elseif ($vbrRP.BackupName) { $vbrRP.BackupName } else { "N/A" }
          RestorePointId = $vbrRP.Id
          CreationTime   = $vbrRP.CreationTime
          BackupSize     = if ($vm.vmSize) { $vm.vmSize } else { 0 }
          IsConsistent   = $true
          ClusterId      = $vm.clusterId
          ClusterName    = $vm.clusterName
        }
      }
      else {
        # Fallback: use VBAHV Plugin VM ID if VBR Core API lookup fails
        Write-Log "  VBR Core API lookup failed for '$($vm.name)' — using plugin VM ID as fallback" -Level "WARNING"
        $rpInfo = [PSCustomObject]@{
          VMName         = $vm.name
          JobName        = if ($vm.protectionDomain) { $vm.protectionDomain } else { "N/A" }
          RestorePointId = $vm.id
          CreationTime   = Get-Date
          BackupSize     = if ($vm.vmSize) { $vm.vmSize } else { 0 }
          IsConsistent   = $true
          ClusterId      = $vm.clusterId
          ClusterName    = $vm.clusterName
        }
      }
      $restorePointsList.Add($rpInfo)
      Write-Log "  Found protected VM: '$($rpInfo.VMName)' on cluster '$($rpInfo.ClusterName)' (restore point: $($rpInfo.CreationTime.ToString('yyyy-MM-dd HH:mm')))" -Level "INFO"
    }
  }

  $restorePoints = @($restorePointsList.ToArray())

  if ($restorePoints.Count -eq 0) {
    throw "No protected VMs found in any Prism Central. Ensure AHV backup jobs exist and the VBAHV Plugin is configured."
  }

  # Filter by backup job names if specified
  if ($BackupJobNames -and $BackupJobNames.Count -gt 0) {
    $beforeCount = $restorePoints.Count
    $restorePoints = @($restorePoints | Where-Object { $_.JobName -in $BackupJobNames })
    if ($restorePoints.Count -eq 0) {
      throw "No VMs matched -BackupJobNames filter ($($BackupJobNames -join ', ')). Found $beforeCount VM(s) but none associated with the specified job(s)."
    }
    Write-Log "Filtered to $($restorePoints.Count) VM(s) matching -BackupJobNames ($($BackupJobNames -join ', '))" -Level "INFO"
  }

  Write-Log "Discovered $($restorePoints.Count) protected VM(s)" -Level "SUCCESS"

  # Tip for large VM lists when not using interactive mode
  if ($restorePoints.Count -gt 10 -and -not $Interactive) {
    Write-Log "Tip: Use -Interactive to search and select specific VMs from the list" -Level "INFO"
  }

  # ---- Interactive VM selection with search/filter ----
  if ($Interactive -and -not $DryRun) {
    $totalVMs = $restorePoints.Count
    $selectedRPs = $null

    do {
      Write-Log "" -Level "INFO"
      Write-Log "=== Available VMs for SureBackup Testing ($totalVMs found) ===" -Level "INFO"
      Write-Log "" -Level "INFO"
      Write-Log "Filter VMs by name, or press Enter to show all:" -Level "INFO"

      $filter = Read-Host "  Filter"
      $filter = if ($filter) { $filter.Trim() } else { "" }

      # Apply wildcard filter or show all
      if ($filter -ne "") {
        $filteredRPs = @($restorePoints | Where-Object { $_.VMName -like "*$filter*" })
      }
      else {
        $filteredRPs = @($restorePoints)
      }

      if ($filteredRPs.Count -eq 0) {
        Write-Log "No VMs match filter '$filter'. Try a different search term." -Level "WARNING"
        continue
      }

      # Display matching VMs with relative time
      $matchLabel = if ($filter -ne "") { "Matching VMs ($($filteredRPs.Count) of $totalVMs)" } else { "All VMs ($totalVMs)" }
      Write-Log "" -Level "INFO"
      Write-Log "${matchLabel}:" -Level "INFO"
      $nameWidth = [math]::Max(15, ($filteredRPs | ForEach-Object { $_.VMName.Length } | Measure-Object -Maximum).Maximum + 2)
      $jobWidth = [math]::Max(20, ($filteredRPs | ForEach-Object { $_.JobName.Length } | Measure-Object -Maximum).Maximum + 2)
      for ($i = 0; $i -lt $filteredRPs.Count; $i++) {
        $rp = $filteredRPs[$i]
        $age = _FormatTimeAgo -DateTime $rp.CreationTime
        $consistent = if ($rp.IsConsistent) { "App-Consistent" } else { "Crash-Consistent" }
        $line = "  [{0}] {1,-$nameWidth} | Job: {2,-$jobWidth} | {3,-15} | {4}" -f ($i + 1), $rp.VMName, $rp.JobName, $age, $consistent
        Write-Log $line -Level "INFO"
      }

      Write-Log "" -Level "INFO"
      Write-Log "Enter VM numbers (comma-separated), 'A' for all shown, or 'B' to re-filter:" -Level "INFO"

      $selection = Read-Host "  Selection"
      $selection = if ($selection) { $selection.Trim().ToUpper() } else { "" }

      if ($selection -eq "B" -or $selection -eq "") {
        continue
      }

      if ($selection -eq "A") {
        $selectedRPs = $filteredRPs
      }
      else {
        $indices = @()
        foreach ($part in ($selection -split ",")) {
          $idx = 0
          if ([int]::TryParse($part.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $filteredRPs.Count) {
            $indices += ($idx - 1)
          }
        }

        if ($indices.Count -gt 0) {
          $selectedRPs = @($indices | ForEach-Object { $filteredRPs[$_] })
        }
        else {
          Write-Log "Invalid selection. Enter numbers from the list, 'A' for all, or 'B' to re-filter." -Level "WARNING"
          continue
        }
      }
    } while ($null -eq $selectedRPs)

    $restorePoints = $selectedRPs
    Write-Log "Selected $($restorePoints.Count) VM(s) for testing" -Level "INFO"
  }

  Write-Log "" -Level "INFO"
  Write-Log "=== SureBackup Test Plan ===" -Level "INFO"
  Write-Log "VMs to test: $($restorePoints.Count)" -Level "INFO"
  Write-Log "Restore method: Full VM Restore (VBAHV REST API)" -Level "INFO"
  Write-Log "Isolated network: $($isolatedNet.Name) (VLAN $($isolatedNet.VlanId))" -Level "INFO"
  Write-Log "Tests: Heartbeat$(if($TestPing){', Ping'})$(if($TestPorts){', Ports: '+($TestPorts -join ',')})$(if($TestDNS){', DNS'})$(if($TestHttpEndpoints){', HTTP'})$(if($TestCustomScript){', Custom Script'})" -Level "INFO"
  if ($UseJumpVM) {
    Write-Log "Jump VM: ENABLED — network tests will execute via SSH proxy on isolated network" -Level "INFO"
  }

  # Runtime estimate
  $vmCount = $restorePoints.Count
  $batchCount = [math]::Ceiling($vmCount / $MaxConcurrentVMs)
  # Estimate: ~5 min restore + boot + tests per batch, plus ~2 min cleanup per batch
  $estimatedMinutes = $batchCount * 7
  if ($estimatedMinutes -gt 0 -and -not $DryRun) {
    Write-Log "Estimated runtime: ~$estimatedMinutes minutes ($vmCount VMs, $batchCount batch(es) of $MaxConcurrentVMs)" -Level "INFO"
  }
  Write-Log "" -Level "INFO"

  # ---- Step 6: Preflight health checks ----
  if ($SkipPreflight) {
    Write-ProgressStep -Activity "Preflight Health Checks" -Status "SKIPPED (-SkipPreflight)"
    Write-Log "Preflight health checks SKIPPED by user request" -Level "WARNING"
  }
  else {
    Write-ProgressStep -Activity "Preflight Health Checks" -Status "Validating cluster, network, and backup health..."

    # Get cluster info for preflight checks
    $clusters = @()
    try {
      if ($PrismApiVersion -eq "v4") {
        $clustersRaw = Invoke-PrismAPI -Method "GET" -Endpoint $script:PrismEndpoints.Clusters
        $clustersBody = Resolve-PrismResponseBody $clustersRaw
        $clusters = if ($clustersBody.data) { @($clustersBody.data) } else { @() }
      }
      else {
        $listBody = @{ kind = "cluster"; length = 100 }
        $clustersRaw = Invoke-PrismAPI -Method "POST" -Endpoint "$($script:PrismEndpoints.Clusters)/list" -Body $listBody
        $clusters = if ($clustersRaw.entities) { @($clustersRaw.entities) } else { @() }
      }
    }
    catch {
      Write-Log "  Could not retrieve cluster info for preflight: $($_.Exception.Message)" -Level "WARNING"
    }

    $preflightParams = @{
      Clusters        = $clusters
      IsolatedNetwork = $isolatedNet
      RestorePoints   = $restorePoints
      BackupJobs      = $ahvJobs
      MaxConcurrentVMs = $MaxConcurrentVMs
      MaxAgeDays      = $PreflightMaxAgeDays
    }
    if ($TargetRPOHours) { $preflightParams.TargetRPOHours = $TargetRPOHours }
    if ($UseJumpVM) {
      $preflightParams.UseJumpVM = $true
      if ($JumpVMImageName) { $preflightParams.JumpVMImageName = $JumpVMImageName }
      if ($ManagementNetworkName) { $preflightParams.ManagementNetworkName = $ManagementNetworkName }
      if ($ManagementNetworkUUID) { $preflightParams.ManagementNetworkUUID = $ManagementNetworkUUID }
    }
    $preflightResult = Test-PreflightRequirements @preflightParams

    if (-not $preflightResult.Success) {
      throw "Preflight health checks FAILED with $($preflightResult.Issues.Count) blocking issue(s). Fix the issues above and re-run, or use -SkipPreflight to bypass (not recommended)."
    }
  }

  # ---- Step 7: Deploy Jump VM (if -UseJumpVM) ----
  if ($UseJumpVM -and -not $DryRun) {
    Write-ProgressStep -Activity "Deploying Jump VM" -Status "Creating dual-homed proxy VM for isolated network testing..."

    # 1. Generate ephemeral SSH keypair
    $sshKey = New-EphemeralSSHKey
    Write-Log "Ephemeral SSH keypair generated: $($sshKey.PrivatePath)" -Level "INFO"

    # 2. Resolve management network UUID (auto-detect if not explicitly provided)
    $mgmtNetUUID = Resolve-ManagementNetwork `
      -ManagementNetworkName $ManagementNetworkName `
      -ManagementNetworkUUID $ManagementNetworkUUID `
      -IsolatedNetworkUUID $isolatedNet.UUID `
      -Interactive:$Interactive
    Write-Log "Management network resolved: $mgmtNetUUID" -Level "INFO"

    # 3. Resolve jump VM image UUID
    $jumpImageUUID = Get-OrCreateJumpVMImage -JumpVMImageName $JumpVMImageName

    # 4. Build cloud-init userdata
    $jumpVMName = "SureBackup_JumpVM_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $cloudInitUserdata = @"
#cloud-config
ssh_authorized_keys:
  - $($sshKey.PublicKey)
package_update: false
package_upgrade: false
"@

    # 5. Create VM via Prism API
    $jumpVMUUID = New-PrismVM -Name $jumpVMName -ImageUUID $jumpImageUUID `
      -ManagementSubnetUUID $mgmtNetUUID -IsolatedSubnetUUID $isolatedNet.UUID `
      -CloudInitUserdata $cloudInitUserdata `
      -ClusterUUID $isolatedNet.ClusterRef

    # 6. Power on
    Write-Log "Powering on jump VM '$jumpVMName'..." -Level "INFO"
    Set-PrismVMPowerState -UUID $jumpVMUUID -State "ON"

    # 7. Wait for IP on management NIC
    Write-Log "Waiting for jump VM management IP (timeout: ${JumpVMBootTimeoutSec}s)..." -Level "INFO"
    $jumpIP = Wait-PrismVMIPAddress -UUID $jumpVMUUID -TimeoutSec $JumpVMBootTimeoutSec

    if (-not $jumpIP) {
      throw "Jump VM did not obtain an IP address within ${JumpVMBootTimeoutSec}s. Check DHCP on management network."
    }
    Write-Log "Jump VM management IP: $jumpIP" -Level "SUCCESS"

    # 8. SSH connectivity test (retry loop — cloud-init needs time to inject key)
    $sshReady = $false
    $sshDeadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $sshDeadline) {
      $testResult = Invoke-SSHCommand -HostIP $jumpIP -KeyPath $sshKey.PrivatePath -User "ubuntu" `
        -Command "echo ready" -TimeoutSec 5
      if ($testResult.ExitCode -eq 0 -and $testResult.Output -match "ready") {
        $sshReady = $true
        break
      }
      Start-Sleep -Seconds 5
    }

    if (-not $sshReady) {
      throw "Jump VM SSH not reachable at $jumpIP after 90s. Verify cloud-init and SSH key injection."
    }
    Write-Log "Jump VM SSH connectivity verified" -Level "SUCCESS"

    # 9. Store jump VM info for test functions
    $script:JumpVM = @{
      IP      = $jumpIP
      KeyPath = $sshKey.PrivatePath
      User    = "ubuntu"
      UUID    = $jumpVMUUID
      Name    = $jumpVMName
    }
    Write-Log "Jump VM ready: $jumpVMName ($jumpIP) — network tests will proxy through this VM" -Level "SUCCESS"
  }
  elseif ($UseJumpVM -and $DryRun) {
    Write-ProgressStep -Activity "Jump VM (Dry Run)" -Status "Would deploy dual-homed jump VM for isolated network testing"
    # Resolve management network even in dry run to show the user what would be selected
    try {
      $dryRunMgmtUUID = Resolve-ManagementNetwork `
        -ManagementNetworkName $ManagementNetworkName `
        -ManagementNetworkUUID $ManagementNetworkUUID `
        -IsolatedNetworkUUID $isolatedNet.UUID `
        -Interactive:$Interactive
      $dryRunSubnets = Get-PrismSubnets
      $dryRunMgmtNet = $dryRunSubnets | Where-Object { (Get-SubnetUUID $_) -eq $dryRunMgmtUUID }
      $dryRunMgmtName = if ($dryRunMgmtNet) { Get-SubnetName $dryRunMgmtNet } else { $dryRunMgmtUUID }
      Write-Log "[DRY RUN] Would deploy jump VM with management NIC on '$dryRunMgmtName' and isolated NIC on '$($isolatedNet.Name)'" -Level "INFO"
    }
    catch {
      Write-Log "[DRY RUN] Would deploy jump VM (management network resolution failed: $($_.Exception.Message))" -Level "WARNING"
    }
  }
  else {
    $script:CurrentStep++
  }

  # ---- Step 8: Execute SureBackup recovery and testing ----
  Write-ProgressStep -Activity "Executing SureBackup Verification" -Status "Recovering and testing VMs..."

  $bootOrder = Get-VMBootOrder -RestorePoints $restorePoints

  # Checkpoint / Resume state
  $completedGroups = New-Object System.Collections.Generic.List[string]
  $checkpointPath = Join-Path $OutputPath "SureBackup_Checkpoint.json"
  $resumeFromGroup = $null
  $resumeFromBatch = 0

  if ($ResumeCheckpoint) {
    $ckpt = Import-SureBackupCheckpoint -CheckpointPath $ResumeCheckpoint
    Write-Log "Resuming from checkpoint: $($ckpt.Timestamp) (status: $($ckpt.Status))" -Level "WARNING"

    foreach ($g in $ckpt.CompletedGroups) { $completedGroups.Add($g) }
    $resumeFromGroup = $ckpt.CurrentGroup
    $resumeFromBatch = $ckpt.CurrentBatch

    # Restore test results from checkpoint
    foreach ($tr in $ckpt.TestResults) {
      $script:TestResults.Add([PSCustomObject]@{
        VMName    = $tr.VMName
        TestName  = $tr.TestName
        Passed    = $tr.Passed
        Details   = $tr.Details
        Duration  = $tr.Duration
        Timestamp = [datetime]$tr.Timestamp
      })
    }
    Write-Log "  Restored $($script:TestResults.Count) test result(s) from checkpoint" -Level "INFO"

    # Warn about orphaned VMs from interrupted run
    $orphans = @($ckpt.RecoverySessions | Where-Object { $_.Status -eq "Running" })
    if ($orphans.Count -gt 0) {
      Write-Log "  WARNING: $($orphans.Count) VM(s) from previous run may still exist:" -Level "WARNING"
      foreach ($o in $orphans) {
        Write-Log "    - $($o.RecoveryVMName) (UUID: $($o.RecoveryVMUUID))" -Level "WARNING"
      }
    }
  }

  foreach ($groupName in $bootOrder.Keys) {
    # Skip groups already completed in previous run
    if ($completedGroups -contains $groupName) {
      Write-Log "--- Skipping $groupName (completed in previous run) ---" -Level "INFO"
      continue
    }
    $groupRPs = @($bootOrder[$groupName])
    Write-Log "--- Processing $groupName ($($groupRPs.Count) VM(s)) ---" -Level "INFO"

    # Handle empty groups (all VMs missing from restore points)
    if ($groupRPs.Count -eq 0) {
      Write-Log "--- $groupName has no VMs with restore points — FAILED (all VMs missing) ---" -Level "ERROR"
      if ($ApplicationGroups -and $groupName -ne "Ungrouped" -and -not $DryRun) {
        Write-Log "Halting subsequent application groups — $groupName dependency not satisfied" -Level "ERROR"
        break
      }
      continue
    }

    if ($DryRun) {
      # Dry run - just validate and report what would happen
      foreach ($rp in $groupRPs) {
        Write-Log "  [DRY RUN] Would recover '$($rp.VMName)' from $($rp.CreationTime.ToString('yyyy-MM-dd HH:mm')) to isolated network '$($isolatedNet.Name)'" -Level "INFO"

        $now = Get-Date
        $script:TestResults.Add((_NewTestResult -VMName $rp.VMName -TestName "Dry Run - Recovery Plan" -Passed $true -Details "Restore point: $($rp.CreationTime.ToString('yyyy-MM-dd HH:mm')), Job: $($rp.JobName), Consistent: $($rp.IsConsistent)" -StartTime $now))
      }
    }
    else {
      # Live execution - recover VMs in batches
      $batches = @()
      for ($i = 0; $i -lt $groupRPs.Count; $i += $MaxConcurrentVMs) {
        $batchEnd = [math]::Min($i + $MaxConcurrentVMs, $groupRPs.Count)
        $batches += , @($groupRPs[$i..($batchEnd - 1)])
      }

      $batchIndex = 0
      foreach ($batch in $batches) {
        # Skip batches completed in previous run (same group, earlier batch)
        if ($groupName -eq $resumeFromGroup -and $batchIndex -lt $resumeFromBatch) {
          Write-Log "  Skipping batch $($batchIndex + 1) (completed in previous run)" -Level "INFO"
          $batchIndex++
          continue
        }
        if ($resumeFromGroup -eq $groupName) { $resumeFromGroup = $null }

        $recoveries = @()

        # Start recovery for each VM in the batch
        foreach ($rp in $batch) {
          Write-Log "Recovering '$($rp.VMName)' via Full VM Restore..." -Level "INFO"
          $recovery = Start-AHVFullRestore -RestorePointInfo $rp -IsolatedNetwork $isolatedNet `
            -RestoreToOriginal:$RestoreToOriginal -RestoreVmCategories:$RestoreVmCategories
          $recoveries += $recovery
        }

        # Wait for all VMs in batch to finish booting on isolated network
        Write-Log "Waiting for VMs to boot on isolated network (timeout: ${TestBootTimeoutSec}s)..." -Level "INFO"
        foreach ($recovery in $recoveries) {
          if ($recovery.RecoveryVMUUID) {
            $powered = Wait-PrismVMPowerState -UUID $recovery.RecoveryVMUUID -State "ON" -TimeoutSec $TestBootTimeoutSec
            if ($powered) {
              Write-Log "  '$($recovery.OriginalVMName)' powered ON" -Level "SUCCESS"
            }
            else {
              Write-Log "  '$($recovery.OriginalVMName)' failed to power on within timeout" -Level "ERROR"
            }
          }
        }

        # Run verification tests on each recovered VM
        foreach ($recovery in $recoveries) {
          $verifyParams = @{ RecoveryInfo = $recovery; IsolatedNetwork = $isolatedNet }
          if ($script:JumpVM) { $verifyParams.JumpVM = $script:JumpVM }
          $null = Invoke-VMVerificationTests @verifyParams
        }

        # Capture per-VM timing data for SLA scoring (before cleanup destroys recovery info)
        foreach ($recovery in $recoveries) {
          $vmTests = @($script:TestResults | Where-Object { $_.VMName -eq $recovery.OriginalVMName })
          $lastTest = if ($vmTests.Count -gt 0) {
            ($vmTests | Sort-Object Timestamp | Select-Object -Last 1).Timestamp
          } else { Get-Date }

          $script:VMTimings.Add([PSCustomObject]@{
            VMName        = $recovery.OriginalVMName
            RecoveryStart = $recovery.StartTime
            TestsComplete = $lastTest
            RTOMinutes    = [math]::Round(($lastTest - $recovery.StartTime).TotalMinutes, 1)
            RPOHours      = $null
          })
        }

        # Cleanup this batch before moving to next
        foreach ($recovery in $recoveries) {
          Stop-AHVFullRestore -RecoveryInfo $recovery
        }

        # Save checkpoint after batch completes
        $batchIndex++
        Save-SureBackupCheckpoint -CheckpointPath $checkpointPath `
          -CurrentGroup $groupName -CurrentBatch $batchIndex -Status "in-progress" `
          -CompletedGroups @($completedGroups)
      }
    }

    # Mark group as completed for checkpoint tracking
    $completedGroups.Add($groupName)

    # If using application groups, enforce dependency chain: stop if current group failed
    if ($ApplicationGroups -and $groupName -ne "Ungrouped") {
      $groupVMNames = $groupRPs | ForEach-Object { $_.VMName }
      $groupResults = $script:TestResults | Where-Object { $_.VMName -in $groupVMNames }
      $groupFailures = $groupResults | Where-Object { -not $_.Passed }

      if ($groupFailures.Count -gt 0 -and -not $DryRun) {
        Write-Log "$groupName FAILED: $($groupFailures.Count) test failure(s)" -Level "ERROR"
        Write-Log "Halting subsequent application groups — downstream groups depend on $groupName" -Level "ERROR"
        Write-Log "Failed tests:" -Level "ERROR"
        foreach ($f in $groupFailures) {
          Write-Log "  - $($f.VMName)/$($f.TestName): $($f.Details)" -Level "ERROR"
        }
        break
      }
      else {
        Write-Log "$groupName : All tests passed" -Level "SUCCESS"
      }
    }
  }

  # ---- SLA scoring (before reports) ----
  $slaSummary = $null
  if (($TargetRTOMinutes -or $TargetRPOHours) -and $script:VMTimings.Count -gt 0) {
    # Populate RPO from restore points
    foreach ($timing in $script:VMTimings) {
      $rp = $restorePoints | Where-Object { $_.VMName -eq $timing.VMName } | Select-Object -First 1
      if ($rp) {
        $timing.RPOHours = [math]::Round(((Get-Date) - $rp.CreationTime).TotalHours, 1)
      }
    }
    $slaSummary = _GetSLASummary -VMTimings $script:VMTimings `
      -TargetRTOMinutes $TargetRTOMinutes -TargetRPOHours $TargetRPOHours
  }

  # ---- Step 9: Generate reports ----
  Write-ProgressStep -Activity "Generating Reports" -Status "Creating HTML report and CSVs..."
  $exportParams = @{
    TestResults     = $script:TestResults
    RestorePoints   = $restorePoints
    IsolatedNetwork = $isolatedNet
  }
  if ($slaSummary) { $exportParams.SLASummary = $slaSummary }
  if ($script:VMTimings.Count -gt 0) { $exportParams.VMTimings = $script:VMTimings }
  Export-Results @exportParams

  # ---- Final summary ----
  Write-ProgressStep -Activity "Complete" -Status "SureBackup verification finished"

  $summary = _GetTestSummary -TestResults $script:TestResults

  Write-Log "" -Level "INFO"
  Write-Log "========================================" -Level "INFO"
  Write-Log "  SUREBACKUP VERIFICATION COMPLETE" -Level "SUCCESS"
  Write-Log "========================================" -Level "INFO"
  Write-Log "  VMs Tested:   $($restorePoints.Count)" -Level "INFO"
  Write-Log "  Total Tests:  $($summary.TotalTests)" -Level "INFO"
  Write-Log "  Passed:       $($summary.PassedTests)" -Level "SUCCESS"

  if ($summary.FailedTests -gt 0) {
    Write-Log "  Failed:       $($summary.FailedTests)" -Level "ERROR"
  }
  else {
    Write-Log "  Failed:       0" -Level "SUCCESS"
  }

  Write-Log "  Pass Rate:    $($summary.PassRate)%" -Level $(if ($summary.FailedTests -eq 0) { "SUCCESS" } else { "WARNING" })

  if ($slaSummary) {
    if ($slaSummary.RPOTarget) {
      Write-Log "  RPO Target:   $($slaSummary.RPOTarget)h - $($slaSummary.RPORate)% compliant (avg: $($slaSummary.AvgRPOHours)h, worst: $($slaSummary.WorstRPOHours)h)" -Level $(if ($slaSummary.RPORate -ge 95) { "SUCCESS" } else { "WARNING" })
    }
    if ($slaSummary.RTOTarget) {
      Write-Log "  RTO Target:   $($slaSummary.RTOTarget)min - $($slaSummary.RTORate)% compliant (avg: $($slaSummary.AvgRTOMinutes)min, worst: $($slaSummary.WorstRTOMinutes)min)" -Level $(if ($slaSummary.RTORate -ge 95) { "SUCCESS" } else { "WARNING" })
    }
  }

  Write-Log "  Duration:     $((Get-Date) - $script:StartTime)" -Level "INFO"
  Write-Log "  Report:       $OutputPath" -Level "INFO"
  Write-Log "========================================" -Level "INFO"

  $script:CompletedSuccessfully = $true

  # Save completed checkpoint
  if (Test-Path $OutputPath) {
    Save-SureBackupCheckpoint -CheckpointPath $checkpointPath `
      -CurrentGroup "" -CurrentBatch 0 -Status "completed" `
      -CompletedGroups @($completedGroups)
  }

  # Return structured result for pipeline use
  [PSCustomObject]@{
    Success     = ($summary.FailedTests -eq 0)
    TotalVMs    = $restorePoints.Count
    TotalTests  = $summary.TotalTests
    Passed      = $summary.PassedTests
    Failed      = $summary.FailedTests
    PassRate    = $summary.PassRate
    Duration    = ((Get-Date) - $script:StartTime).ToString()
    OutputPath  = (Resolve-Path $OutputPath -ErrorAction SilentlyContinue)
    DryRun      = [bool]$DryRun
    Results     = $script:TestResults
    SLA         = if ($slaSummary) {
      [PSCustomObject]@{
        RTOTarget     = $slaSummary.RTOTarget
        RTORate       = $slaSummary.RTORate
        RPOTarget     = $slaSummary.RPOTarget
        RPORate       = $slaSummary.RPORate
        AvgRTOMinutes = $slaSummary.AvgRTOMinutes
        AvgRPOHours   = $slaSummary.AvgRPOHours
      }
    } else { $null }
  }
}
catch {
  Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

  $script:FatalError = $true
  throw
}
finally {
  # Ctrl+C (PipelineStoppedException) skips catch on PS 5.1 — detect it here.
  # Only flag as fatal if the script didn't complete normally.
  if (-not $script:FatalError -and -not $script:CompletedSuccessfully -and $script:RecoverySessions.Count -gt 0) {
    $script:FatalError = $true
  }

  # Save checkpoint for resume on interruption
  try {
    if (-not $script:CompletedSuccessfully -and $OutputPath -and (Test-Path $OutputPath)) {
      $interruptCkptPath = Join-Path $OutputPath "SureBackup_Checkpoint.json"
      Save-SureBackupCheckpoint -CheckpointPath $interruptCkptPath `
        -CurrentGroup "" -CurrentBatch 0 -Status "interrupted" `
        -CompletedGroups @(if ($completedGroups) { $completedGroups } else { @() })
      Write-Log "Checkpoint saved. Resume with: -ResumeCheckpoint '$interruptCkptPath'" -Level "WARNING"
    }
  } catch { }

  # Emergency cleanup — always clean up recovered VMs to prevent production exposure.
  # Wrapped in try to ensure credential cleanup always runs.
  try {
    if ($script:RecoverySessions.Count -gt 0) {
      $shouldCleanup = $true
      if (-not $CleanupOnFailure -and $script:FatalError) {
        Write-Log "Skipping cleanup (-CleanupOnFailure is false) — VMs left for debugging" -Level "WARNING"
        foreach ($session in $script:RecoverySessions) {
          if ($session.RecoveryVMUUID -and $session.Status -ne "CleanedUp") {
            Write-Log "  Orphaned VM: $($session.RecoveryVMName) (UUID: $($session.RecoveryVMUUID))" -Level "WARNING"
          }
        }
        $shouldCleanup = $false
      }

      if ($shouldCleanup) {
        $pendingSessions = @($script:RecoverySessions | Where-Object { $_.Status -ne "CleanedUp" })
        if (@($pendingSessions).Count -gt 0) {
          Write-Log "Performing cleanup of $(@($pendingSessions).Count) recovery session(s)..." -Level "WARNING"
          Invoke-Cleanup
        }
      }
    }
  }
  catch {
    # Cleanup itself failed — ensure we still clear credentials below
  }

  # Jump VM cleanup — tear down after all recovered VMs are cleaned up
  try {
    if ($script:JumpVM -and $script:JumpVM.UUID) {
      Write-Log "Cleaning up jump VM '$($script:JumpVM.Name)'..." -Level "INFO"
      try {
        Set-PrismVMPowerState -UUID $script:JumpVM.UUID -State "OFF"
        Start-Sleep -Seconds 5
      }
      catch { }
      Remove-PrismVM -UUID $script:JumpVM.UUID
      Write-Log "Jump VM deleted: $($script:JumpVM.Name)" -Level "SUCCESS"
    }
    if ($script:JumpVM -and $script:JumpVM.KeyPath) {
      Remove-EphemeralSSHKey -KeyPath $script:JumpVM.KeyPath
      Write-Log "Ephemeral SSH keypair deleted" -Level "INFO"
    }
  }
  catch {
    if ($script:JumpVM) {
      Write-Log "Jump VM cleanup failed: $($_.Exception.Message). Manual cleanup may be needed for VM '$($script:JumpVM.Name)' (UUID: $($script:JumpVM.UUID))" -Level "WARNING"
    }
  }
  $script:JumpVM = $null

  # Credential cleanup — clear sensitive tokens and headers from memory
  try {
    if ($script:VBAHVHeaders) { $script:VBAHVHeaders.Clear() }
    $script:VBAHVRefreshToken = $null
    $script:VBAHVTokenExpiry = $null
    if ($script:PrismHeaders) { $script:PrismHeaders.Clear() }
  }
  catch { }

  # Close progress bar
  Write-Progress -Activity "Veeam AHV SureBackup" -Completed

  # Set process exit code for automation/CI
  if ($script:FatalError) {
    $LASTEXITCODE = 1
    if ($Host.Name -eq 'ConsoleHost') { $host.SetShouldExit(1) }
  }
}
