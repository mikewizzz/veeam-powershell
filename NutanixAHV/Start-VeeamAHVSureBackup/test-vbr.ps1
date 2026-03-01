<#
.SYNOPSIS
  VBR/VBAHV Plugin API isolation test harness

.DESCRIPTION
  Tests the Veeam Plug-in for Nutanix AHV REST API v9 independently of Prism Central.
  Validates authentication, cluster discovery, storage containers, backup jobs,
  restore points, and restore point metadata in 6 sequential steps.

  All operations are read-only — no restores, no mutations.

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP address.

.PARAMETER VBRCredential
  PSCredential for VBR server authentication (OAuth2). Prompted if not provided.

.PARAMETER SkipCertificateCheck
  Skip TLS certificate validation for self-signed certificates.

.PARAMETER VBAHVApiVersion
  VBAHV Plugin REST API version (default: "v9"). Only v9 is supported.

.PARAMETER JobNameFilter
  Optional: only show jobs matching this name.

.PARAMETER VMNameFilter
  Optional: only show restore points for this VM name.

.EXAMPLE
  .\test-vbr.ps1 -VBRServer "vbr01.lab.local"
  # Prompts for credentials, tests all 6 steps

.EXAMPLE
  $cred = Get-Credential
  .\test-vbr.ps1 -VBRServer "vbr01" -VBRCredential $cred -SkipCertificateCheck -JobNameFilter "AHV-Prod"
  # Tests with specific job filter, skips cert validation

.NOTES
  Version: 1.0.0
  Requires: PowerShell 5.1+
  API: Veeam Plug-in for Nutanix AHV REST API v9
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$VBRServer,

  [PSCredential]$VBRCredential,

  [switch]$SkipCertificateCheck,

  [ValidateSet("v9")]
  [string]$VBAHVApiVersion = "v9",

  [string]$JobNameFilter,
  [string]$VMNameFilter
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-Level State (required by lib functions)
# =============================
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:RecoverySessions = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = 0
$script:TotalSteps = 6

# =============================
# Load Function Libraries
# =============================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptDir\lib\Logging.ps1"
. "$scriptDir\lib\Helpers.ps1"
. "$scriptDir\lib\VeeamVBR.ps1"

# =============================
# Test Helpers
# =============================
function Invoke-TestStep {
  param(
    [int]$Step,
    [int]$Total,
    [string]$Description,
    [scriptblock]$Action,
    [switch]$NonFatal
  )
  Write-Log "STEP ${Step}/${Total}: $Description" -Level "INFO"
  try {
    $result = & $Action
    Write-Log "  PASS: $Description" -Level "SUCCESS"
    return $result
  }
  catch {
    if ($NonFatal) {
      Write-Log "  WARN: $($_.Exception.Message) (non-fatal, continuing)" -Level "WARNING"
      return $null
    }
    Write-Log "  FAIL: $($_.Exception.Message)" -Level "ERROR"
    Write-Host ""
    Write-Host "Test halted at step ${Step}/${Total}. Fix the issue above and re-run." -ForegroundColor Red
    exit 1
  }
}

function Show-SampleData {
  param(
    [string]$Label,
    $Data,
    [string[]]$Properties,
    [int]$MaxItems = 5
  )
  if (-not $Data) { return }
  $items = @($Data)
  $showing = [math]::Min($items.Count, $MaxItems)
  Write-Host ""
  Write-Host "  $Label (showing $showing of $($items.Count)):" -ForegroundColor Cyan
  if ($Properties) {
    $items | Select-Object -First $MaxItems | Format-Table -Property $Properties -AutoSize | Out-String | Write-Host
  }
  else {
    $items | Select-Object -First $MaxItems | Format-Table -AutoSize | Out-String | Write-Host
  }
}

# =============================
# Credential Prompting
# =============================
if (-not $VBRCredential) {
  Write-Host "Enter VBR server credentials for: $VBRServer" -ForegroundColor Yellow
  $VBRCredential = Get-Credential -Message "VBR Server ($VBRServer)"
}

# =============================
# Banner
# =============================
Write-Host ""
Write-Host "  VBR/VBAHV Plugin API Test Harness" -ForegroundColor Green
Write-Host "  Server:      $VBRServer" -ForegroundColor White
Write-Host "  API Version: $VBAHVApiVersion" -ForegroundColor White
Write-Host "  Job Filter:  $(if ($JobNameFilter) { $JobNameFilter } else { '(all)' })" -ForegroundColor White
Write-Host "  VM Filter:   $(if ($VMNameFilter) { $VMNameFilter } else { '(all)' })" -ForegroundColor White
Write-Host ""

# =============================
# Step 1: Authenticate to VBAHV Plugin
# =============================
$null = Invoke-TestStep -Step 1 -Total 6 -Description "Authenticate to VBAHV Plugin REST API" -Action {
  Initialize-VBAHVPluginConnection
  Write-Host "  Token expires: $($script:VBAHVTokenExpiry.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
}

# =============================
# Step 2: List Clusters
# =============================
$clusters = Invoke-TestStep -Step 2 -Total 6 -Description "Discover AHV clusters via VBAHV Plugin" -NonFatal -Action {
  $result = Get-VBAHVClusters
  $items = @($result)
  if ($items.Count -lt 1) { throw "No clusters returned" }
  Show-SampleData -Label "Clusters" -Data $items -Properties @("id", "name")
  return $result
}

# =============================
# Step 3: Storage Containers (first cluster)
# =============================
if ($clusters) {
  $null = Invoke-TestStep -Step 3 -Total 6 -Description "List storage containers (first cluster)" -NonFatal -Action {
    $firstCluster = @($clusters)[0]
    $clusterId = $firstCluster.id
    $clusterName = $firstCluster.name
    Write-Host "  Using cluster: $clusterName ($clusterId)" -ForegroundColor Gray
    $containers = Get-VBAHVStorageContainers -ClusterId $clusterId
    if (-not $containers) { throw "No storage containers returned for cluster '$clusterName'" }
    Show-SampleData -Label "Storage Containers" -Data $containers -Properties @("id", "name")
  }
}
else {
  Write-Log "STEP 3/6: List storage containers — SKIPPED (no clusters from step 2)" -Level "WARNING"
}

# =============================
# Step 4: List Backup Jobs
# =============================
$jobs = Invoke-TestStep -Step 4 -Total 6 -Description "Discover AHV backup jobs" -Action {
  $jobNames = if ($JobNameFilter) { @($JobNameFilter) } else { $null }
  $result = Get-VBAHVJobs -JobNames $jobNames
  Show-SampleData -Label "Backup Jobs" -Data $result -Properties @("id", "name")
  return $result
}

# =============================
# Step 5: List Restore Points
# =============================
$restorePoints = Invoke-TestStep -Step 5 -Total 6 -Description "Discover restore points" -Action {
  $vmNames = if ($VMNameFilter) { @($VMNameFilter) } else { $null }
  $result = Get-VBAHVRestorePoints -VMNames $vmNames
  $items = @($result)
  if ($items.Count -lt 1) { throw "No restore points found$(if ($VMNameFilter) { " for VM '$VMNameFilter'" })" }
  Write-Host "  Found $($items.Count) restore point(s)" -ForegroundColor Gray
  Show-SampleData -Label "Restore Points" -Data $items -Properties @("id", "vmName", "creationTime") -MaxItems 10
  return $result
}

# =============================
# Step 6: Restore Point Metadata (first RP)
# =============================
$null = Invoke-TestStep -Step 6 -Total 6 -Description "Get restore point metadata" -Action {
  $firstRP = @($restorePoints)[0]
  $rpId = $firstRP.id
  Write-Host "  Using RP: $rpId (VM: $($firstRP.vmName))" -ForegroundColor Gray
  $metadata = Get-VBAHVRestorePointMetadata -RestorePointId $rpId

  # Validate key fields
  $hasNICs = ($metadata.networkAdapters -and @($metadata.networkAdapters).Count -gt 0)
  $hasCluster = [bool]$metadata.clusterId

  Write-Host "  NICs in backup:   $(if ($hasNICs) { @($metadata.networkAdapters).Count } else { 'none' })" -ForegroundColor Gray
  Write-Host "  Cluster ID:       $(if ($hasCluster) { $metadata.clusterId } else { 'not set' })" -ForegroundColor Gray

  if ($hasNICs) {
    foreach ($nic in $metadata.networkAdapters) {
      Write-Host "    NIC: $($nic.macAddress) -> $($nic.networkName)" -ForegroundColor Gray
    }
  }

  if (-not $hasNICs -and -not $hasCluster) {
    throw "Metadata missing both NICs and cluster data"
  }
}

# =============================
# Summary
# =============================
Write-Host ""
$warnings = @($script:LogEntries | Where-Object { $_.Level -eq "WARNING" }).Count
if ($warnings -gt 0) {
  Write-Host "  Core steps passed ($warnings non-fatal warning(s))." -ForegroundColor Yellow
}
else {
  Write-Host "  All 6 steps passed." -ForegroundColor Green
}
Write-Host "  VBR API layer is healthy. Ready for combined testing." -ForegroundColor Green
Write-Host ""
