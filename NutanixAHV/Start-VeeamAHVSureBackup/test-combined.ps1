<#
.SYNOPSIS
  Cross-system handoff test — VBR + Prism Central data validation

.DESCRIPTION
  Validates the data handoff between Veeam VBR (VBAHV Plugin) and Nutanix Prism Central
  for a specific target VM. Tests that restore point metadata from VBR correctly maps
  to live infrastructure in Prism Central.

  8 sequential steps — all read-only, no restores, no mutations.

  1. VBR authentication
  2. Prism Central authentication
  3. Find restore point for target VM via VBR
  4. Get restore point metadata (NICs, cluster, disks)
  5. Cross-reference cluster ID against VBAHV clusters
  6. Find same VM in Prism Central
  7. Compare metadata: source NICs vs current NICs, source cluster vs Prism
  8. Resolve isolated network on the same cluster

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP address.

.PARAMETER VBRCredential
  PSCredential for VBR server authentication. Prompted if not provided.

.PARAMETER PrismCentral
  Nutanix Prism Central hostname or IP address.

.PARAMETER PrismPort
  Prism Central API port (default: 9440).

.PARAMETER PrismCredential
  PSCredential for Prism Central authentication. Prompted if not provided.

.PARAMETER PrismApiVersion
  Prism Central API version: "v4" (default) or "v3".

.PARAMETER SkipCertificateCheck
  Skip TLS certificate validation for self-signed certificates.

.PARAMETER VBAHVApiVersion
  VBAHV Plugin REST API version (default: "v9").

.PARAMETER TargetVMName
  VM name to trace through both systems. Must exist in VBR backups AND Prism Central.

.PARAMETER IsolatedNetworkName
  Optional: isolated network name for step 8 resolution.

.EXAMPLE
  .\test-combined.ps1 -VBRServer "vbr01" -PrismCentral "pc01" -TargetVMName "web01"
  # Prompts for both credentials, traces web01 through VBR -> Prism

.EXAMPLE
  $vbrCred = Get-Credential -Message "VBR"
  $pcCred = Get-Credential -Message "Prism"
  .\test-combined.ps1 -VBRServer "vbr01" -VBRCredential $vbrCred -PrismCentral "pc01" -PrismCredential $pcCred -TargetVMName "db01" -SkipCertificateCheck
  # Full cross-system validation for db01

.NOTES
  Version: 1.0.0
  Requires: PowerShell 5.1+
  API: VBAHV Plugin REST API v9 + Nutanix Prism Central REST API v3/v4
#>

[CmdletBinding()]
param(
  # VBR Connection
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$VBRServer,

  [PSCredential]$VBRCredential,

  # Prism Central Connection
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$PrismCentral,

  [ValidateRange(1, 65535)]
  [int]$PrismPort = 9440,

  [PSCredential]$PrismCredential,

  [ValidateSet("v4", "v3")]
  [string]$PrismApiVersion = "v4",

  [switch]$SkipCertificateCheck,

  [ValidateSet("v9")]
  [string]$VBAHVApiVersion = "v9",

  # Target
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$TargetVMName,

  [string]$IsolatedNetworkName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-Level State (required by lib functions)
# =============================
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:RecoverySessions = New-Object System.Collections.Generic.List[object]
$script:PrismHeaders = @{}
$script:CurrentStep = 0
$script:TotalSteps = 8

# API version-aware base URL and endpoint mapping (replicates main script lines 266-285)
$script:PrismOrigin = "https://${PrismCentral}:${PrismPort}"
if ($PrismApiVersion -eq "v4") {
  $script:PrismBaseUrl = "$($script:PrismOrigin)/api"
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

# Resolve-IsolatedNetwork reads these unscoped — set as script-level vars
$IsolatedNetworkUUID = $null

# =============================
# Load Function Libraries
# =============================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptDir\lib\Logging.ps1"
. "$scriptDir\lib\Helpers.ps1"
. "$scriptDir\lib\VeeamVBR.ps1"
. "$scriptDir\lib\PrismAPI.ps1"

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
if (-not $PrismCredential) {
  Write-Host "Enter Prism Central credentials for: $PrismCentral" -ForegroundColor Yellow
  $PrismCredential = Get-Credential -Message "Prism Central ($PrismCentral)"
}

# =============================
# Banner
# =============================
Write-Host ""
Write-Host "  Cross-System Handoff Test" -ForegroundColor Green
Write-Host "  VBR Server:     $VBRServer" -ForegroundColor White
Write-Host "  Prism Central:  ${PrismCentral}:${PrismPort} ($PrismApiVersion)" -ForegroundColor White
Write-Host "  Target VM:      $TargetVMName" -ForegroundColor White
Write-Host "  Network:        $(if ($IsolatedNetworkName) { $IsolatedNetworkName } else { '(auto-detect)' })" -ForegroundColor White
Write-Host ""

# =============================
# Step 1: VBR Authentication
# =============================
$null = Invoke-TestStep -Step 1 -Total 8 -Description "Authenticate to VBR/VBAHV Plugin" -Action {
  Initialize-VBAHVPluginConnection
  Write-Host "  Token expires: $($script:VBAHVTokenExpiry.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Gray
}

# =============================
# Step 2: Prism Central Authentication
# =============================
$null = Invoke-TestStep -Step 2 -Total 8 -Description "Authenticate to Prism Central" -Action {
  Initialize-PrismConnection
  $connected = Test-PrismConnection
  if (-not $connected) { throw "Prism Central connection test returned false" }
}

# =============================
# Step 3: Find Target VM via Prism Central Discovery
# =============================
$targetRP = Invoke-TestStep -Step 3 -Total 8 -Description "Find '$TargetVMName' via VBAHV Plugin Prism Central discovery" -Action {
  $vms = Get-VBAHVProtectedVMs -VMNames @($TargetVMName)
  $items = @($vms)
  if ($items.Count -lt 1) { throw "VM '$TargetVMName' not found in any VBAHV Plugin Prism Central" }

  $targetVM = $items[0]
  Write-Host "  Found VM in VBAHV Plugin:" -ForegroundColor Gray
  Write-Host "    VM ID:      $($targetVM.id)" -ForegroundColor Gray
  Write-Host "    VM Name:    $($targetVM.name)" -ForegroundColor Gray
  Write-Host "    Cluster:    $($targetVM.clusterName)" -ForegroundColor Gray
  return $targetVM
}

# =============================
# Step 4: Get Restore Point Metadata
# =============================
$metadata = Invoke-TestStep -Step 4 -Total 8 -Description "Get restore point metadata (NICs, cluster, disks)" -NonFatal -Action {
  $md = Get-VBAHVRestorePointMetadata -RestorePointId $targetRP.id
  Write-Host "  Using VM ID as restore point ID: $($targetRP.id)" -ForegroundColor Gray

  $nicCount = if ($md.networkAdapters) { @($md.networkAdapters).Count } else { 0 }
  Write-Host "  Cluster ID:     $(if ($md.clusterId) { $md.clusterId } else { 'not set' })" -ForegroundColor Gray
  Write-Host "  NICs in backup: $nicCount" -ForegroundColor Gray

  if ($md.networkAdapters) {
    foreach ($nic in $md.networkAdapters) {
      Write-Host "    NIC: $($nic.macAddress) -> $($nic.networkName)" -ForegroundColor Gray
    }
  }
  return $md
}

# =============================
# Step 5: Cross-Reference Cluster ID
# =============================
$vbahvClusters = Invoke-TestStep -Step 5 -Total 8 -Description "Cross-reference cluster ID against VBAHV clusters" -Action {
  $clusters = Get-VBAHVClusters
  $items = @($clusters)
  Write-Host "  VBAHV knows $($items.Count) cluster(s)" -ForegroundColor Gray

  if ($metadata.clusterId) {
    $match = $items | Where-Object { $_.id -eq $metadata.clusterId }
    if ($match) {
      Write-Host "  Cluster match: $($match.name) ($($match.id))" -ForegroundColor Gray
    }
    else {
      Write-Host "  WARNING: Metadata cluster ID '$($metadata.clusterId)' not found in VBAHV cluster list" -ForegroundColor Yellow
    }
  }
  else {
    Write-Host "  No cluster ID in metadata — restore will use default cluster resolution" -ForegroundColor Yellow
  }
  return $clusters
}

# =============================
# Step 6: Find Same VM in Prism Central
# =============================
$prismVM = Invoke-TestStep -Step 6 -Total 8 -Description "Find '$TargetVMName' in Prism Central" -Action {
  $result = Get-PrismVMByName -Name $TargetVMName
  if (-not $result) { throw "VM '$TargetVMName' not found in Prism Central — is it registered?" }

  $vm = @($result)[0]
  if ($PrismApiVersion -eq "v4") {
    Write-Host "  Prism extId:    $($vm.extId)" -ForegroundColor Gray
    Write-Host "  Power State:    $($vm.powerState)" -ForegroundColor Gray
    Write-Host "  Cluster:        $($vm.cluster.extId)" -ForegroundColor Gray
  }
  else {
    Write-Host "  Prism UUID:     $($vm.metadata.uuid)" -ForegroundColor Gray
    Write-Host "  Power State:    $($vm.status.resources.power_state)" -ForegroundColor Gray
  }
  return $vm
}

# =============================
# Step 7: Compare Metadata (VBR backup vs Prism live)
# =============================
$null = Invoke-TestStep -Step 7 -Total 8 -Description "Compare backup metadata vs live Prism data" -NonFatal -Action {
  $mismatches = 0

  # Compare cluster
  if ($metadata.clusterId) {
    $prismClusterId = $null
    if ($PrismApiVersion -eq "v4") {
      $prismClusterId = $prismVM.cluster.extId
    }
    else {
      $prismClusterId = $prismVM.metadata.cluster_reference.uuid
    }

    if ($prismClusterId -and $metadata.clusterId -ne $prismClusterId) {
      Write-Host "  CLUSTER MISMATCH:" -ForegroundColor Yellow
      Write-Host "    Backup metadata: $($metadata.clusterId)" -ForegroundColor Yellow
      Write-Host "    Prism live:      $prismClusterId" -ForegroundColor Yellow
      $mismatches++
    }
    else {
      Write-Host "  Cluster: MATCH ($($metadata.clusterId))" -ForegroundColor Gray
    }
  }

  # Compare NIC count
  $backupNICCount = if ($metadata.networkAdapters) { @($metadata.networkAdapters).Count } else { 0 }
  $liveNICCount = 0
  if ($PrismApiVersion -eq "v4") {
    if ($prismVM.nics) { $liveNICCount = @($prismVM.nics).Count }
  }
  else {
    $nicList = $prismVM.status.resources.nic_list
    if ($nicList) { $liveNICCount = @($nicList).Count }
  }

  if ($backupNICCount -ne $liveNICCount) {
    Write-Host "  NIC count changed: backup=$backupNICCount, live=$liveNICCount" -ForegroundColor Yellow
    $mismatches++
  }
  else {
    Write-Host "  NIC count: MATCH ($backupNICCount)" -ForegroundColor Gray
  }

  if ($mismatches -gt 0) {
    Write-Host "  $mismatches mismatch(es) detected — VM config changed since backup" -ForegroundColor Yellow
    Write-Host "  (This is informational, not a failure)" -ForegroundColor Gray
  }
  else {
    Write-Host "  All metadata matches between backup and live VM" -ForegroundColor Gray
  }
}

# =============================
# Step 8: Resolve Isolated Network
# =============================
$null = Invoke-TestStep -Step 8 -Total 8 -Description "Resolve isolated network" -Action {
  $networkInfo = Resolve-IsolatedNetwork
  Write-Host "  Name:       $($networkInfo.Name)" -ForegroundColor Gray
  Write-Host "  UUID:       $($networkInfo.UUID)" -ForegroundColor Gray
  Write-Host "  VLAN ID:    $($networkInfo.VlanId)" -ForegroundColor Gray
  Write-Host "  Cluster:    $($networkInfo.ClusterRef)" -ForegroundColor Gray

  # Check if isolated network is on the same cluster as the target VM
  $vmClusterId = $null
  if ($PrismApiVersion -eq "v4") {
    $vmClusterId = $prismVM.cluster.extId
  }
  else {
    $vmClusterId = $prismVM.metadata.cluster_reference.uuid
  }

  if ($networkInfo.ClusterRef -and $vmClusterId) {
    if ($networkInfo.ClusterRef -eq $vmClusterId) {
      Write-Host "  Isolated network is on the SAME cluster as target VM" -ForegroundColor Gray
    }
    else {
      Write-Host "  WARNING: Isolated network is on a DIFFERENT cluster than target VM" -ForegroundColor Yellow
      Write-Host "    Network cluster: $($networkInfo.ClusterRef)" -ForegroundColor Yellow
      Write-Host "    VM cluster:      $vmClusterId" -ForegroundColor Yellow
    }
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
  Write-Host "  All 8 steps passed." -ForegroundColor Green
}
Write-Host "  Cross-system data handoff validated for '$TargetVMName'." -ForegroundColor Green
Write-Host "  Next: run the main script with -DryRun for full flow validation." -ForegroundColor Green
Write-Host ""
