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
  Enable ICMP ping test (default: true).

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

.NOTES
  Version: 1.0.0
  Author: Community Contributors
  Date: 2026-02-28
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: None
  Nutanix: Prism Central v4 API (pc.2024.3+ GA, default) or v3 (legacy)
  VBR: Veeam Backup & Replication v12.2+ with Nutanix AHV Plugin v9
  AHV Plugin REST API: https://helpcenter.veeam.com/references/vbahv/9/rest/
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
  [switch]$SkipPreflight
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
$script:TotalSteps = 9
$script:CurrentStep = 0

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

  # Get restore points via REST API and build info objects
  $allPluginRPs = Get-VBAHVRestorePoints -VMNames $VMNames
  $restorePoints = @()

  if ($allPluginRPs -and @($allPluginRPs).Count -gt 0) {
    # Group by VM name and take the latest restore point per VM
    $grouped = $allPluginRPs | Group-Object { $_.vmName }
    foreach ($group in $grouped) {
      $latestRP = $group.Group | Sort-Object { [datetime]$_.creationTime } -Descending | Select-Object -First 1
      $rpInfo = [PSCustomObject]@{
        VMName       = $latestRP.vmName
        JobName      = if ($latestRP.jobName) { $latestRP.jobName } else { "N/A" }
        RestorePointId = $latestRP.id
        CreationTime = [datetime]$latestRP.creationTime
        BackupSize   = if ($latestRP.backupSize) { $latestRP.backupSize } else { 0 }
        IsConsistent = if ($null -ne $latestRP.isConsistent) { $latestRP.isConsistent } else { $true }
      }
      $restorePoints += $rpInfo
      Write-Log "  Found restore point for '$($rpInfo.VMName)' from $($rpInfo.CreationTime.ToString('yyyy-MM-dd HH:mm'))" -Level "INFO"
    }
  }

  if ($restorePoints.Count -eq 0) {
    throw "No restore points found for any AHV VMs. Ensure backups have completed successfully."
  }

  Write-Log "Discovered $($restorePoints.Count) VM restore point(s)" -Level "SUCCESS"

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
      for ($i = 0; $i -lt $filteredRPs.Count; $i++) {
        $rp = $filteredRPs[$i]
        $age = _FormatTimeAgo -DateTime $rp.CreationTime
        $consistent = if ($rp.IsConsistent) { "App-Consistent" } else { "Crash-Consistent" }
        $line = "  [{0}] {1,-15} | Job: {2,-20} | {3,-15} | {4}" -f ($i + 1), $rp.VMName, $rp.JobName, $age, $consistent
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

    $preflightResult = Test-PreflightRequirements `
      -Clusters $clusters `
      -IsolatedNetwork $isolatedNet `
      -RestorePoints $restorePoints `
      -BackupJobs $ahvJobs `
      -MaxConcurrentVMs $MaxConcurrentVMs `
      -MaxAgeDays $PreflightMaxAgeDays

    if (-not $preflightResult.Success) {
      throw "Preflight health checks FAILED with $($preflightResult.Issues.Count) blocking issue(s). Fix the issues above and re-run, or use -SkipPreflight to bypass (not recommended)."
    }
  }

  # ---- Step 7: (Reserved — VBAHV Plugin already authenticated in Step 4) ----
  $script:CurrentStep++

  # ---- Step 8: Execute SureBackup recovery and testing ----
  Write-ProgressStep -Activity "Executing SureBackup Verification" -Status "Recovering and testing VMs..."

  $bootOrder = Get-VMBootOrder -RestorePoints $restorePoints

  foreach ($groupName in $bootOrder.Keys) {
    $groupRPs = $bootOrder[$groupName]
    Write-Log "--- Processing $groupName ($($groupRPs.Count) VM(s)) ---" -Level "INFO"

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

      foreach ($batch in $batches) {
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
          Invoke-VMVerificationTests -RecoveryInfo $recovery -IsolatedNetwork $isolatedNet
        }

        # Cleanup this batch before moving to next
        foreach ($recovery in $recoveries) {
          Stop-AHVFullRestore -RecoveryInfo $recovery
        }
      }
    }

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

  # ---- Step 9: Generate reports ----
  Write-ProgressStep -Activity "Generating Reports" -Status "Creating HTML report and CSVs..."
  Export-Results -TestResults $script:TestResults -RestorePoints $restorePoints -IsolatedNetwork $isolatedNet

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
  Write-Log "  Duration:     $((Get-Date) - $script:StartTime)" -Level "INFO"
  Write-Log "  Report:       $OutputPath" -Level "INFO"
  Write-Log "========================================" -Level "INFO"

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
  }
}
catch {
  Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

  # Emergency cleanup — always clean up recovered VMs to prevent production exposure.
  if ($script:RecoverySessions.Count -gt 0) {
    Write-Log "Performing emergency cleanup of $($script:RecoverySessions.Count) recovery session(s)..." -Level "WARNING"
    Invoke-Cleanup
  }

  throw
}
finally {
  # Close progress bar
  Write-Progress -Activity "Veeam AHV SureBackup" -Completed
}
