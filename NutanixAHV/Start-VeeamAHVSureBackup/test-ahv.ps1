<#
.SYNOPSIS
  Prism Central API isolation test harness

.DESCRIPTION
  Tests the Nutanix Prism Central REST API (v3/v4) independently of Veeam VBR.
  Validates authentication, connectivity, cluster/subnet discovery, VM lookup,
  power state retrieval, and isolated network resolution in 7 sequential steps.

  All operations are read-only — no VMs created, modified, or deleted.

.PARAMETER PrismCentral
  Nutanix Prism Central hostname or IP address.

.PARAMETER PrismPort
  Prism Central API port (default: 9440).

.PARAMETER PrismCredential
  PSCredential for Prism Central authentication (Basic Auth). Prompted if not provided.

.PARAMETER PrismApiVersion
  Prism Central API version: "v4" (default, GA in pc.2024.3+) or "v3" (legacy).

.PARAMETER SkipCertificateCheck
  Skip TLS certificate validation for self-signed certificates.

.PARAMETER VMNameToFind
  Optional: look up a specific VM by name (steps 5-6).

.PARAMETER IsolatedNetworkName
  Optional: resolve a specific isolated network by name (step 7).

.EXAMPLE
  .\test-ahv.ps1 -PrismCentral "pc01.lab.local"
  # Prompts for credentials, tests all 7 steps

.EXAMPLE
  $cred = Get-Credential
  .\test-ahv.ps1 -PrismCentral "pc01" -PrismCredential $cred -SkipCertificateCheck -VMNameToFind "web01" -IsolatedNetworkName "SureBackup-Isolated"
  # Full test with VM lookup and network resolution

.NOTES
  Version: 1.0.0
  Requires: PowerShell 5.1+
  API: Nutanix Prism Central REST API v3/v4
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$PrismCentral,

  [ValidateRange(1, 65535)]
  [int]$PrismPort = 9440,

  [PSCredential]$PrismCredential,

  [ValidateSet("v4", "v3")]
  [string]$PrismApiVersion = "v4",

  [switch]$SkipCertificateCheck,

  [string]$VMNameToFind,
  [string]$IsolatedNetworkName
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-Level State (required by lib functions)
# =============================
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:PrismHeaders = @{}
$script:CurrentStep = 0
$script:TotalSteps = 7

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

# =============================
# Load Function Libraries
# =============================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
. "$scriptDir\lib\Logging.ps1"
. "$scriptDir\lib\Helpers.ps1"
. "$scriptDir\lib\PrismAPI.ps1"

# =============================
# Test Helpers
# =============================
function Invoke-TestStep {
  param(
    [int]$Step,
    [int]$Total,
    [string]$Description,
    [scriptblock]$Action
  )
  Write-Log "STEP ${Step}/${Total}: $Description" -Level "INFO"
  try {
    $result = & $Action
    Write-Log "  PASS: $Description" -Level "SUCCESS"
    return $result
  }
  catch {
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
if (-not $PrismCredential) {
  Write-Host "Enter Prism Central credentials for: $PrismCentral" -ForegroundColor Yellow
  $PrismCredential = Get-Credential -Message "Prism Central ($PrismCentral)"
}

# =============================
# Banner
# =============================
$stepCount = 7
if (-not $VMNameToFind) { $stepCount = 5 }  # steps 5-6 skipped without VM name

Write-Host ""
Write-Host "  Prism Central API Test Harness" -ForegroundColor Green
Write-Host "  Server:      ${PrismCentral}:${PrismPort}" -ForegroundColor White
Write-Host "  API Version: $PrismApiVersion" -ForegroundColor White
Write-Host "  VM Lookup:   $(if ($VMNameToFind) { $VMNameToFind } else { '(skipped)' })" -ForegroundColor White
Write-Host "  Network:     $(if ($IsolatedNetworkName) { $IsolatedNetworkName } else { '(auto-detect)' })" -ForegroundColor White
Write-Host ""

# =============================
# Step 1: Configure Prism Authentication
# =============================
$null = Invoke-TestStep -Step 1 -Total $stepCount -Description "Configure Prism Central authentication" -Action {
  Initialize-PrismConnection
}

# =============================
# Step 2: Test Prism Connectivity
# =============================
$null = Invoke-TestStep -Step 2 -Total $stepCount -Description "Test Prism Central connectivity" -Action {
  $connected = Test-PrismConnection
  if (-not $connected) { throw "Prism Central connection test returned false" }
}

# =============================
# Step 3: List Clusters
# =============================
$clusters = Invoke-TestStep -Step 3 -Total $stepCount -Description "Discover Nutanix clusters" -Action {
  $result = Get-PrismClusters
  $items = @($result)
  if ($items.Count -lt 1) { throw "No clusters returned from Prism Central" }

  if ($PrismApiVersion -eq "v4") {
    Show-SampleData -Label "Clusters" -Data $items -Properties @("extId", "name")
  }
  else {
    $display = $items | ForEach-Object {
      [PSCustomObject]@{
        UUID = $_.metadata.uuid
        Name = $_.spec.name
      }
    }
    Show-SampleData -Label "Clusters" -Data $display -Properties @("UUID", "Name")
  }
  return $result
}

# =============================
# Step 4: List Subnets
# =============================
$subnets = Invoke-TestStep -Step 4 -Total $stepCount -Description "Discover subnets" -Action {
  $result = Get-PrismSubnets
  $items = @($result)
  if ($items.Count -lt 1) { throw "No subnets returned from Prism Central" }

  $display = $items | ForEach-Object {
    [PSCustomObject]@{
      UUID = Get-SubnetUUID $_
      Name = Get-SubnetName $_
    }
  }
  Show-SampleData -Label "Subnets" -Data $display -Properties @("UUID", "Name") -MaxItems 10
  return $result
}

# =============================
# Step 5: VM Lookup (optional)
# =============================
$foundVM = $null
if ($VMNameToFind) {
  $foundVM = Invoke-TestStep -Step 5 -Total $stepCount -Description "Find VM by name: $VMNameToFind" -Action {
    $result = Get-PrismVMByName -Name $VMNameToFind
    if (-not $result) { throw "VM '$VMNameToFind' not found in Prism Central" }

    $vm = @($result)[0]
    if ($PrismApiVersion -eq "v4") {
      Write-Host "  VM extId:     $($vm.extId)" -ForegroundColor Gray
      Write-Host "  VM Name:      $($vm.name)" -ForegroundColor Gray
      Write-Host "  Power State:  $($vm.powerState)" -ForegroundColor Gray
      Write-Host "  Cluster:      $($vm.cluster.extId)" -ForegroundColor Gray
    }
    else {
      Write-Host "  VM UUID:      $($vm.metadata.uuid)" -ForegroundColor Gray
      Write-Host "  VM Name:      $($vm.spec.name)" -ForegroundColor Gray
      Write-Host "  Power State:  $($vm.status.resources.power_state)" -ForegroundColor Gray
    }
    return $vm
  }

  # =============================
  # Step 6: Get VM Power State (if VM found)
  # =============================
  $null = Invoke-TestStep -Step 6 -Total $stepCount -Description "Get VM power state via Get-PrismVMByUUID" -Action {
    $vmUUID = if ($PrismApiVersion -eq "v4") { $foundVM.extId } else { $foundVM.metadata.uuid }
    $vmResult = Get-PrismVMByUUID -UUID $vmUUID
    $powerState = Get-PrismVMPowerState $vmResult
    if (-not $powerState) { throw "Power state returned null for VM '$VMNameToFind'" }
    Write-Host "  Power state: $powerState" -ForegroundColor Gray
  }
}

# =============================
# Step 7 (or 5): Resolve Isolated Network
# =============================
$networkStep = if ($VMNameToFind) { 7 } else { 5 }
# Set script-level vars that Resolve-IsolatedNetwork reads (unscoped)
$IsolatedNetworkUUID = $null

$null = Invoke-TestStep -Step $networkStep -Total $stepCount -Description "Resolve isolated network" -Action {
  $networkInfo = Resolve-IsolatedNetwork
  Write-Host "  Name:       $($networkInfo.Name)" -ForegroundColor Gray
  Write-Host "  UUID:       $($networkInfo.UUID)" -ForegroundColor Gray
  Write-Host "  VLAN ID:    $($networkInfo.VlanId)" -ForegroundColor Gray
  Write-Host "  Type:       $($networkInfo.SubnetType)" -ForegroundColor Gray
  Write-Host "  Cluster:    $($networkInfo.ClusterRef)" -ForegroundColor Gray
}

# =============================
# Summary
# =============================
Write-Host ""
Write-Host "  All $stepCount steps passed." -ForegroundColor Green
Write-Host "  Prism Central API layer is healthy. Ready for combined testing." -ForegroundColor Green
Write-Host ""
