<#
.SYNOPSIS
  Veeam SureBackup for Nutanix AHV - Automated Backup Verification & Recovery Testing

.DESCRIPTION
  Bridges the gap between Veeam's VMware SureBackup and Nutanix AHV by providing automated
  backup recoverability verification using Veeam Backup & Replication and Nutanix Prism Central
  REST APIs.

  WHAT THIS SCRIPT DOES:
  1. Connects to Veeam Backup & Replication server (PowerShell cmdlets)
  2. Connects to Nutanix Prism Central via REST API v3
  3. Discovers AHV backup jobs and latest restore points
  4. Performs Instant VM Recovery to an isolated AHV network (virtual lab)
  5. Runs configurable verification tests (heartbeat, ping, port, DNS, custom scripts)
  6. Generates professional HTML report with pass/fail results
  7. Cleans up all recovered VMs and temporary resources

  SUREBACKUP TEST PHASES:
  Phase 1 - VM Recovery:    Instant VM Recovery from Veeam backup to isolated AHV network
  Phase 2 - Boot Test:      Verify VM powers on and gets heartbeat via Nutanix Guest Tools
  Phase 3 - Network Test:   ICMP ping and TCP port connectivity checks
  Phase 4 - Application:    DNS resolution, HTTP endpoint, custom PowerShell script tests
  Phase 5 - Cleanup:        Stop instant recovery sessions, remove temporary resources

  QUICK START:
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01.lab.local" -PrismCentral "pc01.lab.local" -PrismCredential (Get-Credential)

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP address.

.PARAMETER VBRPort
  VBR server port (default: 9419).

.PARAMETER VBRCredential
  PSCredential for VBR server authentication. If omitted, uses current Windows session.

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
  Skip TLS certificate validation for self-signed Prism certificates (lab environments).

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

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential (Get-Credential)
  # Quick start - tests all AHV backup jobs with default settings

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential $cred -BackupJobNames "AHV-Production" -TestPorts @(22,443,3389) -SkipCertificateCheck
  # Test specific backup job with port checks, skip self-signed cert warnings

.EXAMPLE
  $groups = @{ 1 = @("dc01"); 2 = @("sql01"); 3 = @("app01","web01") }
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential $cred -ApplicationGroups $groups -TestPorts @(53,1433,443)
  # Application-group ordered testing with dependency boot order

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential $cred -DryRun
  # Dry run - validate connectivity and show what would be tested without recovering VMs

.EXAMPLE
  .\Start-VeeamAHVSureBackup.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -PrismCredential $cred -BackupJobNames "AHV-Tier1" -TestCustomScript "C:\Scripts\Verify-AppHealth.ps1"
  # Custom application-level verification script

.PARAMETER RestoreMethod
  Restore method: "InstantRecovery" (default) or "FullRestore".
  - InstantRecovery: Uses Start-VBRInstantRecoveryToNutanixAHV (fast, vPower NFS mount).
    The VM initially boots on the production network; the script powers it off, swaps
    the NIC to the isolated network via Prism API, then powers it back on.
  - FullRestore: Uses the Veeam Plug-in for Nutanix AHV REST API (v9) to perform a full
    VM restore with native network adapter mapping via POST /restorePoints/restore. The
    VM is created directly on the isolated network — zero production exposure. Slower
    (full disk copy) but inherently safer for network isolation. Requires VBR credentials.
    API Ref: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints

.PARAMETER VBAHVApiVersion
  Veeam Plug-in for Nutanix AHV REST API version (default: "v9").
  Only v8 and v9 are supported. Used when RestoreMethod is FullRestore.

.PARAMETER PreflightMaxAgeDays
  Maximum restore point age in days before preflight warns (default: 7).

.PARAMETER SkipPreflight
  Skip all preflight health checks. Not recommended for production.

.NOTES
  Version: 1.2.0
  Author: Community Contributors
  Date: 2026-02-28
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: Veeam.Backup.PowerShell (VBR Console), VeeamPSSnapin (legacy)
  Nutanix: Prism Central v4 API (pc.2024.3+ GA, default) or v3 (legacy)
  VBR: Veeam Backup & Replication v13.0.1+ with Nutanix AHV Plugin v9 (for FullRestore)
  AHV Plugin REST API: https://helpcenter.veeam.com/references/vbahv/9/rest/tag/RestorePoints
#>

[CmdletBinding(DefaultParameterSetName = "NetworkByName")]
param(
  # VBR Connection
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$VBRServer,
  [ValidateRange(1, 65535)]
  [int]$VBRPort = 9419,
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

  # Restore Method
  [ValidateSet("InstantRecovery", "FullRestore")]
  [string]$RestoreMethod = "InstantRecovery",
  [ValidateSet("v8", "v9")]
  [string]$VBAHVApiVersion = "v9",

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

  # ---- Step 2: Connect to Prism Central ----
  Write-ProgressStep -Activity "Connecting to Nutanix Prism Central" -Status "$PrismCentral`:$PrismPort"
  Initialize-PrismConnection

  if (-not (Test-PrismConnection)) {
    throw "Cannot connect to Prism Central at $PrismCentral`:$PrismPort. Verify hostname, port, and credentials."
  }

  # ---- Step 3: Resolve isolated network ----
  Write-ProgressStep -Activity "Resolving Isolated Network" -Status "Finding SureBackup virtual lab network..."
  $isolatedNet = Resolve-IsolatedNetwork

  # ---- Step 4: Connect to VBR ----
  Write-ProgressStep -Activity "Connecting to Veeam Backup & Replication" -Status "$VBRServer`:$VBRPort"
  Connect-VBRSession

  # ---- Step 5: Discover AHV backup jobs and restore points ----
  Write-ProgressStep -Activity "Discovering AHV Backups" -Status "Scanning backup jobs and restore points..."
  $ahvJobs = Get-AHVBackupJobs
  $restorePoints = Get-AHVRestorePoints -BackupJobs $ahvJobs

  Write-Log "" -Level "INFO"
  Write-Log "=== SureBackup Test Plan ===" -Level "INFO"
  Write-Log "VMs to test: $($restorePoints.Count)" -Level "INFO"
  Write-Log "Restore method: $RestoreMethod" -Level "INFO"
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
      -MaxAgeDays $PreflightMaxAgeDays `
      -RestoreMethod $RestoreMethod

    if (-not $preflightResult.Success) {
      throw "Preflight health checks FAILED with $($preflightResult.Issues.Count) blocking issue(s). Fix the issues above and re-run, or use -SkipPreflight to bypass (not recommended)."
    }
  }

  # ---- Step 7: Initialize VBAHV Plugin API (for FullRestore mode) ----
  if ($RestoreMethod -eq "FullRestore") {
    Write-ProgressStep -Activity "Connecting to VBAHV Plugin REST API" -Status "Authenticating via VBR OAuth2..."
    Initialize-VBAHVPluginConnection
  }
  else {
    $script:CurrentStep++  # Skip this step for InstantRecovery
  }

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
          Write-Log "Recovering '$($rp.VMName)' via $RestoreMethod..." -Level "INFO"
          if ($RestoreMethod -eq "FullRestore") {
            $recovery = Start-AHVFullRestore -RestorePointInfo $rp -IsolatedNetwork $isolatedNet
          }
          else {
            $recovery = Start-AHVInstantRecovery -RestorePointInfo $rp -IsolatedNetwork $isolatedNet
          }
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
          if ($recovery.RestoreMethod -eq "FullRestore") {
            Stop-AHVFullRestore -RecoveryInfo $recovery
          }
          else {
            Stop-AHVInstantRecovery -RecoveryInfo $recovery
          }
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
  # CleanupOnFailure controls whether test failures cause early abort, NOT
  # whether recovered VMs are cleaned up (those must always be removed).
  if ($script:RecoverySessions.Count -gt 0) {
    Write-Log "Performing emergency cleanup of $($script:RecoverySessions.Count) recovery session(s)..." -Level "WARNING"
    Invoke-Cleanup
  }

  throw
}
finally {
  # Always disconnect from VBR
  Disconnect-VBRSession

  # Close progress bar
  Write-Progress -Activity "Veeam AHV SureBackup" -Completed
}
