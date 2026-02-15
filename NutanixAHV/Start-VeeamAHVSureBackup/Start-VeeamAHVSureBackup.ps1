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

.NOTES
  Version: 1.0.0
  Author: Veeam Software
  Date: 2026-02-15
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: Veeam.Backup.PowerShell (VBR Console), VeeamPSSnapin (legacy)
  Nutanix: Prism Central v3 API (pc.2024.1+)
  VBR: Veeam Backup & Replication v12.3+ with Nutanix AHV plugin
#>

[CmdletBinding(DefaultParameterSetName = "NetworkByName")]
param(
  # VBR Connection
  [Parameter(Mandatory = $true)]
  [string]$VBRServer,
  [int]$VBRPort = 9419,
  [PSCredential]$VBRCredential,

  # Nutanix Prism Central Connection
  [Parameter(Mandatory = $true)]
  [string]$PrismCentral,
  [int]$PrismPort = 9440,
  [Parameter(Mandatory = $true)]
  [PSCredential]$PrismCredential,
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
  [int[]]$TestPorts,
  [switch]$TestDNS,
  [string[]]$TestHttpEndpoints,
  [string]$TestCustomScript,

  # Application Groups (boot order)
  [hashtable]$ApplicationGroups,

  # Output
  [string]$OutputPath,
  [bool]$GenerateHTML = $true,
  [bool]$ZipOutput = $true,

  # Behavior
  [bool]$CleanupOnFailure = $true,
  [switch]$DryRun
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
$script:PrismBaseUrl = "https://${PrismCentral}:${PrismPort}/api/nutanix/v3"
$script:PrismHeaders = @{}
$script:TotalSteps = 8
$script:CurrentStep = 0

# Output folder
if (-not $OutputPath) {
  $OutputPath = ".\VeeamAHVSureBackup_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
}

#region Logging & Progress
# =============================
# Logging & Progress
# =============================

function Write-Log {
  param(
    [Parameter(Mandatory = $true)][string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS", "TEST-PASS", "TEST-FAIL")]
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
    "ERROR"     { "Red" }
    "WARNING"   { "Yellow" }
    "SUCCESS"   { "Green" }
    "TEST-PASS" { "Cyan" }
    "TEST-FAIL" { "Magenta" }
    default     { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-ProgressStep {
  param(
    [Parameter(Mandatory = $true)][string]$Activity,
    [string]$Status = "Processing..."
  )

  $script:CurrentStep++
  $percentComplete = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Veeam AHV SureBackup" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity" -Level "INFO"
}

function Write-Banner {
  $banner = @"

  ╔══════════════════════════════════════════════════════════════════╗
  ║          Veeam SureBackup for Nutanix AHV  v1.0.0              ║
  ║          Automated Backup Verification & Recovery Testing       ║
  ╚══════════════════════════════════════════════════════════════════╝

"@
  Write-Host $banner -ForegroundColor Green

  if ($DryRun) {
    Write-Host "  >>> DRY RUN MODE - No VMs will be recovered <<<" -ForegroundColor Yellow
    Write-Host ""
  }
}

#endregion

#region Nutanix Prism Central REST API
# =============================
# Nutanix Prism Central REST API v3
# =============================

function Initialize-PrismConnection {
  <#
  .SYNOPSIS
    Configure Prism Central REST API authentication and TLS settings
  #>

  # Handle self-signed certificates
  if ($SkipCertificateCheck) {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
      # PowerShell 7+ has native -SkipCertificateCheck on Invoke-RestMethod
      $script:SkipCert = $true
    }
    else {
      # PowerShell 5.1 - add certificate bypass
      if (-not ([System.Management.Automation.PSTypeName]"TrustAllCertsPolicy").Type) {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
      }
      [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }
    # Enable TLS 1.2 and 1.3 for better security and future compatibility
    try {
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 -bor [System.Net.SecurityProtocolType]::Tls13
    }
    catch {
      # Fallback for environments where Tls13 is not supported
      [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    }
    Write-Log "TLS certificate validation disabled (lab mode)" -Level "WARNING"
  }

  # Build Basic Auth header
  $username = $PrismCredential.UserName
  $password = $PrismCredential.GetNetworkCredential().Password
  $pair = "${username}:${password}"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
  $base64 = [System.Convert]::ToBase64String($bytes)

  $script:PrismHeaders = @{
    "Authorization" = "Basic $base64"
    "Content-Type"  = "application/json"
    "Accept"        = "application/json"
  }

  Write-Log "Prism Central auth configured for user: $username" -Level "INFO"
}

function Invoke-PrismAPI {
  <#
  .SYNOPSIS
    Execute a Prism Central v3 REST API call with retry logic
  .PARAMETER Method
    HTTP method (GET, POST, PUT, DELETE)
  .PARAMETER Endpoint
    API endpoint path (appended to base URL)
  .PARAMETER Body
    Request body hashtable (converted to JSON)
  .PARAMETER RetryCount
    Number of retries on transient failure (default: 3)
  #>
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [hashtable]$Body,
    [int]$RetryCount = 3
  )

  $url = "$($script:PrismBaseUrl)/$Endpoint"
  $attempt = 0

  while ($attempt -le $RetryCount) {
    try {
      $params = @{
        Method  = $Method
        Uri     = $url
        Headers = $script:PrismHeaders
      }

      if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
      }

      if ($script:SkipCert -and $PSVersionTable.PSVersion.Major -ge 7) {
        $params.SkipCertificateCheck = $true
      }

      $response = Invoke-RestMethod @params -ErrorAction Stop
      return $response
    }
    catch {
      $attempt++
      if ($attempt -gt $RetryCount) {
        Write-Log "Prism API call failed after $RetryCount retries: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }
      $waitSec = [math]::Pow(2, $attempt)
      Write-Log "Prism API transient failure (attempt $attempt/$RetryCount), retrying in ${waitSec}s: $($_.Exception.Message)" -Level "WARNING"
      Start-Sleep -Seconds $waitSec
    }
  }
}

function Test-PrismConnection {
  <#
  .SYNOPSIS
    Validate Prism Central connectivity and credentials
  #>
  Write-Log "Testing Prism Central connectivity: $PrismCentral`:$PrismPort" -Level "INFO"

  try {
    $cluster = Invoke-PrismAPI -Method "POST" -Endpoint "clusters/list" -Body @{ kind = "cluster"; length = 1 }
    $clusterCount = $cluster.metadata.total_matches
    Write-Log "Prism Central connected - $clusterCount cluster(s) visible" -Level "SUCCESS"
    return $true
  }
  catch {
    Write-Log "Prism Central connection failed: $($_.Exception.Message)" -Level "ERROR"
    return $false
  }
}

function Get-PrismClusters {
  <#
  .SYNOPSIS
    Retrieve all Nutanix clusters from Prism Central
  .NOTES
    Uses a hardcoded length of 500 results, which should be sufficient for most environments.
    For deployments with >500 clusters, implement pagination using the 'offset' parameter.
  #>
  $result = Invoke-PrismAPI -Method "POST" -Endpoint "clusters/list" -Body @{
    kind   = "cluster"
    length = 500
  }
  return $result.entities
}

function Get-PrismSubnets {
  <#
  .SYNOPSIS
    Retrieve all subnets from Prism Central
  .NOTES
    Uses a hardcoded length of 500 results, which should be sufficient for most environments.
    For deployments with >500 subnets, implement pagination using the 'offset' parameter.
  #>
  $result = Invoke-PrismAPI -Method "POST" -Endpoint "subnets/list" -Body @{
    kind   = "subnet"
    length = 500
  }
  return $result.entities
}

function Resolve-IsolatedNetwork {
  <#
  .SYNOPSIS
    Find and validate the isolated network for SureBackup recovery
  #>
  Write-Log "Resolving isolated network for SureBackup lab..." -Level "INFO"

  $subnets = Get-PrismSubnets

  if ($IsolatedNetworkUUID) {
    $target = $subnets | Where-Object { $_.metadata.uuid -eq $IsolatedNetworkUUID }
    if (-not $target) {
      throw "Isolated network UUID '$IsolatedNetworkUUID' not found in Prism Central"
    }
  }
  elseif ($IsolatedNetworkName) {
    $target = $subnets | Where-Object { $_.spec.name -eq $IsolatedNetworkName }
    if (-not $target) {
      throw "Isolated network '$IsolatedNetworkName' not found in Prism Central. Available: $(($subnets | ForEach-Object { $_.spec.name }) -join ', ')"
    }
    if ($target.Count -gt 1) {
      Write-Log "Multiple subnets named '$IsolatedNetworkName' found, using first match" -Level "WARNING"
      $target = $target[0]
    }
  }
  else {
    # Look for a subnet with 'isolated', 'surebackup', or 'lab' in the name
    $target = $subnets | Where-Object {
      $_.spec.name -imatch "isolated|surebackup|lab|sandbox|test-recovery"
    } | Select-Object -First 1

    if (-not $target) {
      throw "No isolated network specified and none auto-detected. Use -IsolatedNetworkName or -IsolatedNetworkUUID, or create a subnet with 'isolated'/'surebackup'/'lab' in its name."
    }
    Write-Log "Auto-detected isolated network: $($target.spec.name)" -Level "WARNING"
  }

  $networkInfo = [PSCustomObject]@{
    Name       = $target.spec.name
    UUID       = $target.metadata.uuid
    VlanId     = $target.spec.resources.vlan_id
    SubnetType = $target.spec.resources.subnet_type
    ClusterRef = $target.spec.cluster_reference.uuid
  }

  Write-Log "Isolated network resolved: $($networkInfo.Name) [VLAN $($networkInfo.VlanId)] on cluster $($networkInfo.ClusterRef)" -Level "SUCCESS"
  return $networkInfo
}

function Get-PrismVMByName {
  <#
  .SYNOPSIS
    Find a VM by name in Prism Central
  #>
  param([Parameter(Mandatory = $true)][string]$Name)

  $result = Invoke-PrismAPI -Method "POST" -Endpoint "vms/list" -Body @{
    kind   = "vm"
    length = 50
    filter = "vm_name==$Name"
  }
  return $result.entities | Where-Object { $_.spec.name -eq $Name }
}

function Get-PrismVMByUUID {
  <#
  .SYNOPSIS
    Get a VM by UUID from Prism Central
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  return Invoke-PrismAPI -Method "GET" -Endpoint "vms/$UUID"
}

function Get-PrismVMIPAddress {
  <#
  .SYNOPSIS
    Retrieve IP address(es) from a Nutanix VM via NGT or NIC info
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  try {
    $vm = Get-PrismVMByUUID -UUID $UUID
    $nics = $vm.status.resources.nic_list

    foreach ($nic in $nics) {
      $endpoints = $nic.ip_endpoint_list
      foreach ($ep in $endpoints) {
        if ($ep.ip -and $ep.ip -notmatch "^169\.254") {
          return $ep.ip
        }
      }
    }
  }
  catch {
    Write-Log "Could not retrieve IP for VM $UUID - $($_.Exception.Message)" -Level "WARNING"
  }
  return $null
}

function Wait-PrismVMPowerState {
  <#
  .SYNOPSIS
    Wait for a VM to reach a specific power state
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [Parameter(Mandatory = $true)][ValidateSet("ON", "OFF")][string]$State,
    [int]$TimeoutSec = 300
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    try {
      $vm = Get-PrismVMByUUID -UUID $UUID
      $currentState = $vm.status.resources.power_state

      if ($currentState -eq $State) {
        return $true
      }
    }
    catch {
      # VM may not be ready yet
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Wait-PrismVMIPAddress {
  <#
  .SYNOPSIS
    Wait for a VM to obtain an IP address via NGT or DHCP
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [int]$TimeoutSec = 300
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    $ip = Get-PrismVMIPAddress -UUID $UUID
    if ($ip) {
      return $ip
    }
    Start-Sleep -Seconds 10
  }
  return $null
}

function Remove-PrismVM {
  <#
  .SYNOPSIS
    Delete a VM from Nutanix (cleanup)
  #>
  param([Parameter(Mandatory = $true)][string]$UUID)

  try {
    Invoke-PrismAPI -Method "DELETE" -Endpoint "vms/$UUID"
    Write-Log "Deleted VM: $UUID" -Level "INFO"
    return $true
  }
  catch {
    Write-Log "Failed to delete VM $UUID - $($_.Exception.Message)" -Level "WARNING"
    return $false
  }
}

function Get-PrismTaskStatus {
  <#
  .SYNOPSIS
    Check the status of an async Prism task
  #>
  param([Parameter(Mandatory = $true)][string]$TaskUUID)

  return Invoke-PrismAPI -Method "GET" -Endpoint "tasks/$TaskUUID"
}

function Wait-PrismTask {
  <#
  .SYNOPSIS
    Wait for a Prism async task to complete
  #>
  param(
    [Parameter(Mandatory = $true)][string]$TaskUUID,
    [int]$TimeoutSec = 600
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSec)

  while ((Get-Date) -lt $deadline) {
    $task = Get-PrismTaskStatus -TaskUUID $TaskUUID
    $status = $task.status

    if ($status -eq "SUCCEEDED") {
      return $task
    }
    elseif ($status -eq "FAILED") {
      throw "Prism task $TaskUUID failed: $($task.error_detail)"
    }

    Start-Sleep -Seconds 5
  }

  throw "Prism task $TaskUUID timed out after ${TimeoutSec}s"
}

#endregion

#region Veeam Backup & Replication
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
  $recoveryName = "SureBackup_${vmName}_$(Get-Date -Format 'HHmmss')"

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
    $session = Start-VBRInstantRecoveryToNutanixAHV @irParams -ErrorAction Stop

    Write-Log "Instant recovery started for '$vmName' as '$recoveryName'" -Level "SUCCESS"

    # Wait briefly for the VM to appear in Prism
    Start-Sleep -Seconds 15

    # Find the recovered VM in Prism Central to reconfigure its network
    $recoveredVM = Get-PrismVMByName -Name $recoveryName

    if ($recoveredVM) {
      # Normalize to array and take the first VM (handles single object, array, or empty)
      $vmObject = @($recoveredVM)[0]
      $vmUUID   = $vmObject?.metadata?.uuid

      if ($vmUUID) {
        # Update VM NIC to use isolated network
        try {
          $vmSpec = Get-PrismVMByUUID -UUID $vmUUID
          $specVersion = $vmSpec.metadata.spec_version

          # Build the NIC update - replace all NICs with isolated network
          $nicList = @(
            @{
              subnet_reference = @{
                kind = "subnet"
                uuid = $IsolatedNetwork.UUID
              }
              is_connected     = $true
            }
          )

          $updateBody = @{
            metadata = @{
              kind         = "vm"
              uuid         = $vmUUID
              spec_version = $specVersion
            }
            spec     = $vmSpec.spec
          }
          $updateBody.spec.resources.nic_list = $nicList

          Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$vmUUID" -Body $updateBody
          Write-Log "  NIC reconfigured to isolated network: $($IsolatedNetwork.Name)" -Level "INFO"
        }
        catch {
          Write-Log "  Warning: Could not reconfigure NIC to isolated network: $($_.Exception.Message)" -Level "WARNING"
        }
      }
      else {
        Write-Log "  Warning: Recovered VM object found but UUID is missing; skipping NIC reconfiguration." -Level "WARNING"
        $vmUUID = $null
      }
    }
    else {
      Write-Log "  Recovered VM '$recoveryName' not yet visible in Prism Central" -Level "WARNING"
      $vmUUID = $null
    }

    $recoveryInfo = [PSCustomObject]@{
      OriginalVMName = $vmName
      RecoveryVMName = $recoveryName
      RecoveryVMUUID = $vmUUID
      VBRSession     = $session
      StartTime      = Get-Date
      Status         = "Running"
    }

    $script:RecoverySessions.Add($recoveryInfo)
    return $recoveryInfo
  }
  catch {
    Write-Log "Instant recovery failed for '$vmName': $($_.Exception.Message)" -Level "ERROR"

    $recoveryInfo = [PSCustomObject]@{
      OriginalVMName = $vmName
      RecoveryVMName = $recoveryName
      RecoveryVMUUID = $null
      VBRSession     = $null
      StartTime      = Get-Date
      Status         = "Failed"
      Error          = $_.Exception.Message
    }

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
        # Power off first if still running
        try {
          $powerBody = @{
            spec     = @{
              resources = @{
                power_state = "OFF"
              }
            }
            metadata = @{
              kind = "vm"
              uuid = $RecoveryInfo.RecoveryVMUUID
            }
          }
          # Use Prism to force power off, then delete
          Write-Log "  Force powering off lingering VM: $($RecoveryInfo.RecoveryVMName)" -Level "WARNING"
          Invoke-PrismAPI -Method "PUT" -Endpoint "vms/$($RecoveryInfo.RecoveryVMUUID)" -Body $powerBody
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

#endregion

#region SureBackup Verification Tests
# =============================
# SureBackup Verification Tests
# =============================

function Test-VMHeartbeat {
  <#
  .SYNOPSIS
    Test VM heartbeat via Nutanix Guest Tools (NGT) status
  #>
  param(
    [Parameter(Mandatory = $true)][string]$UUID,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "Heartbeat (NGT)"
  $startTime = Get-Date

  try {
    $vm = Get-PrismVMByUUID -UUID $UUID
    $powerState = $vm.status.resources.power_state
    $ngtEnabled = $vm.status.resources.guest_tools

    $passed = ($powerState -eq "ON")
    $details = "Power: $powerState"

    if ($ngtEnabled) {
      $ngtStatus = $ngtEnabled.nutanix_guest_tools.state
      $details += ", NGT: $ngtStatus"
      if ($ngtStatus -eq "ENABLED") {
        $details += " (Guest tools communicating)"
      }
    }
    else {
      $details += ", NGT: Not installed"
    }

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "Error: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Test-VMPing {
  <#
  .SYNOPSIS
    Test ICMP connectivity to a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "ICMP Ping"
  $startTime = Get-Date

  try {
    $pingResult = Test-Connection -ComputerName $IPAddress -Count 4 -Quiet -ErrorAction SilentlyContinue
    $passed = $pingResult

    if ($passed) {
      # Get latency details
      $pingDetail = Test-Connection -ComputerName $IPAddress -Count 2 -ErrorAction SilentlyContinue
      if ($pingDetail -and $pingDetail.Count -gt 0) {
        $avgLatency = ($pingDetail | Measure-Object -Property ResponseTime -Average).Average
        $details = "Reply from $IPAddress - Avg latency: $([math]::Round($avgLatency, 1))ms"
      }
      else {
        $details = "Reply from $IPAddress - latency information unavailable"
      }
    }
    else {
      $details = "No reply from $IPAddress (4 packets sent, 0 received)"
    }

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "Error: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Test-VMPort {
  <#
  .SYNOPSIS
    Test TCP port connectivity on a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][int]$Port,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "TCP Port $Port"
  $startTime = Get-Date

  try {
    $tcpClient = New-Object System.Net.Sockets.TcpClient
    $connectTask = $tcpClient.ConnectAsync($IPAddress, $Port)
    $waitResult = $connectTask.Wait(5000)

    if ($waitResult -and $tcpClient.Connected) {
      $passed = $true
      $details = "Port $Port is open on $IPAddress"
    }
    else {
      $passed = $false
      $details = "Port $Port connection timed out on $IPAddress"
    }

    $tcpClient.Close()
    $tcpClient.Dispose()

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "Port $Port refused/unreachable on ${IPAddress}: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"

    if ($tcpClient) {
      $tcpClient.Dispose()
    }
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Test-VMDNS {
  <#
  .SYNOPSIS
    Test DNS resolution capability
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  $testName = "DNS Resolution"
  $startTime = Get-Date

  try {
    # Test if the VM can be resolved by its name and if DNS is functional
    $resolved = [System.Net.Dns]::GetHostEntry($IPAddress)
    $passed = ($null -ne $resolved)
    $details = "Reverse DNS: $($resolved.HostName)"

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "DNS resolution failed for ${IPAddress}: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Test-VMHttpEndpoint {
  <#
  .SYNOPSIS
    Test HTTP/HTTPS endpoint accessibility on a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$IPAddress,
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$VMName
  )

  # Replace localhost/127.0.0.1 in URL with actual VM IP
  $testUrl = $Url -replace "(localhost|127\.0\.0\.1)", $IPAddress

  $testName = "HTTP $testUrl"
  $startTime = Get-Date

  try {
    $response = Invoke-WebRequest -Uri $testUrl -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
    $passed = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400)
    $details = "HTTP $($response.StatusCode) - Content-Length: $($response.Headers.'Content-Length')"

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "HTTP request failed: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Test-VMCustomScript {
  <#
  .SYNOPSIS
    Execute a custom verification script against a recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$VMIPAddress,
    [string]$VMUuid
  )

  $testName = "Custom Script: $(Split-Path $ScriptPath -Leaf)"
  $startTime = Get-Date

  if (-not (Test-Path $ScriptPath)) {
    $details = "Script not found: $ScriptPath"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
    return [PSCustomObject]@{
      VMName    = $VMName
      TestName  = $testName
      Passed    = $false
      Details   = $details
      Duration  = ((Get-Date) - $startTime).TotalSeconds
      Timestamp = Get-Date
    }
  }

  try {
    $result = & $ScriptPath -VMName $VMName -VMIPAddress $VMIPAddress -VMUuid $VMUuid
    $passed = ($result -eq $true)
    $details = if ($passed) { "Custom script returned success" } else { "Custom script returned failure: $result" }

    $level = if ($passed) { "TEST-PASS" } else { "TEST-FAIL" }
    Write-Log "  [$VMName] $testName : $(if($passed){'PASS'}else{'FAIL'}) - $details" -Level $level
  }
  catch {
    $passed = $false
    $details = "Custom script error: $($_.Exception.Message)"
    Write-Log "  [$VMName] $testName : FAIL - $details" -Level "TEST-FAIL"
  }

  return [PSCustomObject]@{
    VMName    = $VMName
    TestName  = $testName
    Passed    = $passed
    Details   = $details
    Duration  = ((Get-Date) - $startTime).TotalSeconds
    Timestamp = Get-Date
  }
}

function Invoke-VMVerificationTests {
  <#
  .SYNOPSIS
    Run all configured verification tests against a single recovered VM
  #>
  param(
    [Parameter(Mandatory = $true)]$RecoveryInfo,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $vmName = $RecoveryInfo.OriginalVMName
  $vmUUID = $RecoveryInfo.RecoveryVMUUID

  Write-Log "Running verification tests on '$vmName'..." -Level "INFO"
  $vmResults = @()

  if (-not $vmUUID) {
    $vmResults += [PSCustomObject]@{
      VMName    = $vmName
      TestName  = "VM Recovery"
      Passed    = $false
      Details   = "VM not recovered - $($RecoveryInfo.Error)"
      Duration  = 0
      Timestamp = Get-Date
    }
    return $vmResults
  }

  # Test 1: Heartbeat / Power State
  $vmResults += Test-VMHeartbeat -UUID $vmUUID -VMName $vmName

  # Test 2: Wait for IP address
  Write-Log "  [$vmName] Waiting for IP address (timeout: ${TestBootTimeoutSec}s)..." -Level "INFO"
  $ipAddress = Wait-PrismVMIPAddress -UUID $vmUUID -TimeoutSec $TestBootTimeoutSec

  if (-not $ipAddress) {
    $vmResults += [PSCustomObject]@{
      VMName    = $vmName
      TestName  = "IP Address Assignment"
      Passed    = $false
      Details   = "VM did not obtain IP within ${TestBootTimeoutSec}s timeout"
      Duration  = $TestBootTimeoutSec
      Timestamp = Get-Date
    }
    Write-Log "  [$vmName] No IP address obtained - skipping network tests" -Level "TEST-FAIL"
    $script:TestResults.AddRange([object[]]$vmResults)
    return $vmResults
  }

  $vmResults += [PSCustomObject]@{
    VMName    = $vmName
    TestName  = "IP Address Assignment"
    Passed    = $true
    Details   = "VM obtained IP: $ipAddress"
    Duration  = 0
    Timestamp = Get-Date
  }
  Write-Log "  [$vmName] IP address obtained: $ipAddress" -Level "TEST-PASS"

  # Test 3: ICMP Ping
  if ($TestPing) {
    $vmResults += Test-VMPing -IPAddress $ipAddress -VMName $vmName
  }

  # Test 4: TCP Port checks
  if ($TestPorts -and $TestPorts.Count -gt 0) {
    foreach ($port in $TestPorts) {
      $vmResults += Test-VMPort -IPAddress $ipAddress -Port $port -VMName $vmName
    }
  }

  # Test 5: DNS resolution
  if ($TestDNS) {
    $vmResults += Test-VMDNS -IPAddress $ipAddress -VMName $vmName
  }

  # Test 6: HTTP endpoint checks
  if ($TestHttpEndpoints -and $TestHttpEndpoints.Count -gt 0) {
    foreach ($endpoint in $TestHttpEndpoints) {
      $vmResults += Test-VMHttpEndpoint -IPAddress $ipAddress -Url $endpoint -VMName $vmName
    }
  }

  # Test 7: Custom script
  if ($TestCustomScript) {
    $vmResults += Test-VMCustomScript -ScriptPath $TestCustomScript -VMName $vmName -VMIPAddress $ipAddress -VMUuid $vmUUID
  }

  # Add all results to global tracker
  foreach ($r in $vmResults) {
    $script:TestResults.Add($r)
  }

  return $vmResults
}

#endregion

#region Application Group Orchestration
# =============================
# Application Group Orchestration
# =============================

function Get-VMBootOrder {
  <#
  .SYNOPSIS
    Determine VM boot order from ApplicationGroups or return flat list
  .DESCRIPTION
    If ApplicationGroups is defined, VMs boot in group order (group 1 first, then 2, etc.)
    VMs within the same group boot concurrently up to MaxConcurrentVMs.
    VMs not in any group are added to a final catch-all group.
  #>
  param(
    [Parameter(Mandatory = $true)]$RestorePoints
  )

  $ordered = [ordered]@{}

  if ($ApplicationGroups -and $ApplicationGroups.Count -gt 0) {
    $assignedVMs = @()

    # Process defined groups in order
    $sortedKeys = $ApplicationGroups.Keys | Sort-Object
    foreach ($groupId in $sortedKeys) {
      $groupVMs = $ApplicationGroups[$groupId]
      $groupRPs = @()

      foreach ($vmName in $groupVMs) {
        $rp = $RestorePoints | Where-Object { $_.VMName -eq $vmName }
        if ($rp) {
          $groupRPs += $rp
          $assignedVMs += $vmName
        }
        else {
          Write-Log "Application group $groupId : VM '$vmName' has no restore point - skipping" -Level "WARNING"
        }
      }

      if ($groupRPs.Count -gt 0) {
        $ordered["Group $groupId"] = $groupRPs
      }
    }

    # Add unassigned VMs to catch-all group
    $unassigned = $RestorePoints | Where-Object { $_.VMName -notin $assignedVMs }
    if ($unassigned.Count -gt 0) {
      $ordered["Ungrouped"] = @($unassigned)
    }
  }
  else {
    # No groups defined - single flat group
    $ordered["All VMs"] = @($RestorePoints)
  }

  return $ordered
}

#endregion

#region HTML Report Generation
# =============================
# HTML Report Generation
# =============================

function Generate-HTMLReport {
  <#
  .SYNOPSIS
    Generate a professional HTML report with SureBackup test results
  #>
  param(
    [Parameter(Mandatory = $true)]$TestResults,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  # Load System.Web assembly for HTML encoding to prevent XSS
  Add-Type -AssemblyName System.Web

  # Helper function to safely encode HTML
  function Encode-Html {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return "" }
    return [System.Web.HttpUtility]::HtmlEncode($Text)
  }

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "{0:hh\:mm\:ss}" -f $duration

  # Calculate summary stats
  $totalTests = $TestResults.Count
  $passedTests = ($TestResults | Where-Object { $_.Passed }).Count
  $failedTests = $totalTests - $passedTests
  $passRate = if ($totalTests -gt 0) { [math]::Round(($passedTests / $totalTests) * 100, 1) } else { 0 }

  $uniqueVMs = ($TestResults | Select-Object -ExpandProperty VMName -Unique)
  $totalVMs = $uniqueVMs.Count
  $fullyPassedVMs = 0
  foreach ($vm in $uniqueVMs) {
    $vmTests = $TestResults | Where-Object { $_.VMName -eq $vm }
    if (($vmTests | Where-Object { -not $_.Passed }).Count -eq 0) {
      $fullyPassedVMs++
    }
  }
  $vmPassRate = if ($totalVMs -gt 0) { [math]::Round(($fullyPassedVMs / $totalVMs) * 100, 1) } else { 0 }

  $overallStatus = if ($failedTests -eq 0) { "ALL TESTS PASSED" } else { "$failedTests TEST(S) FAILED" }
  $statusColor = if ($failedTests -eq 0) { "#00B336" } else { "#D13438" }

  # Build VM detail rows
  $vmDetailRows = ""
  foreach ($vm in $uniqueVMs) {
    $vmTests = $TestResults | Where-Object { $_.VMName -eq $vm }
    $vmPassed = ($vmTests | Where-Object { $_.Passed }).Count
    $vmTotal = $vmTests.Count
    $vmStatus = if ($vmPassed -eq $vmTotal) { "PASS" } else { "FAIL" }
    $vmStatusClass = if ($vmPassed -eq $vmTotal) { "status-pass" } else { "status-fail" }

    # Get restore point info
    $rpInfo = $RestorePoints | Where-Object { $_.VMName -eq $vm }
    $rpDate = if ($rpInfo) { $rpInfo.CreationTime.ToString("yyyy-MM-dd HH:mm") } else { "N/A" }
    $rpJob = if ($rpInfo) { $rpInfo.JobName } else { "N/A" }

    # Encode user-controlled data for HTML output
    $vmEncoded = Encode-Html $vm
    $rpJobEncoded = Encode-Html $rpJob

    $vmDetailRows += @"
    <tr>
      <td><strong>$vmEncoded</strong></td>
      <td>$rpJobEncoded</td>
      <td>$rpDate</td>
      <td>$vmPassed / $vmTotal</td>
      <td><span class="$vmStatusClass">$vmStatus</span></td>
    </tr>
"@
  }

  # Build individual test result rows
  $testDetailRows = ""
  foreach ($result in $TestResults) {
    $statusClass = if ($result.Passed) { "status-pass" } else { "status-fail" }
    $statusText = if ($result.Passed) { "PASS" } else { "FAIL" }
    $durationText = "$([math]::Round($result.Duration, 1))s"

    # Encode user-controlled data for HTML output
    $vmNameEncoded = Encode-Html $result.VMName
    $testNameEncoded = Encode-Html $result.TestName
    $detailsEncoded = Encode-Html $result.Details

    $testDetailRows += @"
    <tr>
      <td>$vmNameEncoded</td>
      <td>$testNameEncoded</td>
      <td><span class="$statusClass">$statusText</span></td>
      <td>$detailsEncoded</td>
      <td>$durationText</td>
    </tr>
"@
  }

  # Build log rows
  $logRows = ""
  foreach ($log in $script:LogEntries) {
    $logClass = switch ($log.Level) {
      "ERROR"     { "log-error" }
      "WARNING"   { "log-warning" }
      "SUCCESS"   { "log-success" }
      "TEST-PASS" { "log-success" }
      "TEST-FAIL" { "log-error" }
      default     { "log-info" }
    }
    # Encode log message for HTML output
    $logMessageEncoded = Encode-Html $log.Message
    $logRows += "    <tr class=`"$logClass`"><td>$($log.Timestamp)</td><td>$($log.Level)</td><td>$logMessageEncoded</td></tr>`n"
  }

  # Encode script-level variables for HTML output
  $isolatedNetworkNameEncoded = Encode-Html $IsolatedNetwork.Name
  $vbrServerEncoded = Encode-Html $script:VBRServer
  $prismCentralEncoded = Encode-Html $script:PrismCentral
  $testCustomScriptEncoded = Encode-Html $script:TestCustomScript
  $testPortsDisplay = if ($script:TestPorts) { Encode-Html ($script:TestPorts -join ', ') } else { "None" }
  $testHttpEndpointsDisplay = if ($script:TestHttpEndpoints) { Encode-Html ($script:TestHttpEndpoints -join ', ') } else { "None" }
  $testCustomScriptDisplay = if ($script:TestCustomScript) { $testCustomScriptEncoded } else { "None" }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam SureBackup for Nutanix AHV - Verification Report</title>
<style>
:root {
  --veeam-green: #00B336;
  --veeam-dark: #005F28;
  --nutanix-blue: #024DA1;
  --nutanix-dark: #1A1F36;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --ms-red: #D13438;
  --ms-blue: #0078D4;
  --shadow-depth-4: 0 1.6px 3.6px rgba(0,0,0,.132), 0 0.3px 0.9px rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px rgba(0,0,0,.132), 0 0.6px 1.8px rgba(0,0,0,.108);
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.5;
}

.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 40px 32px;
}

.header {
  background: white;
  border-left: 4px solid var(--veeam-green);
  padding: 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
}

.header-title {
  font-size: 32px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 4px;
}

.header-subtitle {
  font-size: 16px;
  color: var(--ms-gray-90);
  margin-bottom: 4px;
}

.header-platform {
  font-size: 14px;
  color: var(--nutanix-blue);
  font-weight: 600;
  margin-bottom: 24px;
}

.header-meta {
  display: flex;
  gap: 32px;
  flex-wrap: wrap;
  font-size: 13px;
  color: var(--ms-gray-90);
}

.overall-status {
  background: white;
  padding: 24px 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
  border-left: 6px solid ${statusColor};
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.overall-status-text {
  font-size: 24px;
  font-weight: 600;
  color: ${statusColor};
}

.overall-status-detail {
  font-size: 14px;
  color: var(--ms-gray-90);
}

.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 24px;
  margin-bottom: 32px;
}

.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
  border-top: 3px solid var(--veeam-green);
}

.kpi-card.fail { border-top-color: var(--ms-red); }
.kpi-card.nutanix { border-top-color: var(--nutanix-blue); }

.kpi-label {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--ms-gray-90);
  margin-bottom: 8px;
}

.kpi-value {
  font-size: 36px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 4px;
}

.kpi-subtext {
  font-size: 13px;
  color: var(--ms-gray-90);
}

.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}

.section-title {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--ms-gray-30);
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
  margin-top: 16px;
}

thead { background: var(--ms-gray-20); }

th {
  padding: 12px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}

td {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

tbody tr:hover { background: var(--ms-gray-10); }

.status-pass {
  background: #DFF6DD;
  color: #0E700E;
  padding: 4px 12px;
  border-radius: 12px;
  font-weight: 600;
  font-size: 12px;
}

.status-fail {
  background: #FDE7E9;
  color: #D13438;
  padding: 4px 12px;
  border-radius: 12px;
  font-weight: 600;
  font-size: 12px;
}

.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--nutanix-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}

.info-card-title {
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 8px;
  font-size: 14px;
}

.info-card-text {
  color: var(--ms-gray-90);
  font-size: 14px;
  line-height: 1.6;
}

.log-section { max-height: 400px; overflow-y: auto; }
.log-error td { color: var(--ms-red); }
.log-warning td { color: #986F0B; }
.log-success td { color: #0E700E; }
.log-info td { color: var(--ms-gray-90); }

.footer {
  text-align: center;
  padding: 32px;
  color: var(--ms-gray-90);
  font-size: 13px;
}

.dry-run-banner {
  background: #FFF4CE;
  border: 2px solid #986F0B;
  color: #986F0B;
  padding: 16px 24px;
  margin-bottom: 24px;
  border-radius: 4px;
  font-weight: 600;
  font-size: 16px;
  text-align: center;
}

@media print {
  body { background: white; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); }
  .log-section { max-height: none; }
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="header-title">Veeam SureBackup Verification Report</div>
    <div class="header-subtitle">Automated Backup Recoverability Testing</div>
    <div class="header-platform">Nutanix AHV Platform</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>VBR Server:</strong> $VBRServer</span>
      <span><strong>Prism Central:</strong> $PrismCentral</span>
    </div>
  </div>

  $(if ($DryRun) { '<div class="dry-run-banner">DRY RUN - No VMs were recovered. Results below show connectivity validation only.</div>' })

  <div class="overall-status">
    <div>
      <div class="overall-status-text">$overallStatus</div>
      <div class="overall-status-detail">$passedTests of $totalTests tests passed across $totalVMs VM(s)</div>
    </div>
    <div style="text-align: right;">
      <div style="font-size: 48px; font-weight: 300; color: ${statusColor};">$passRate%</div>
      <div style="font-size: 13px; color: var(--ms-gray-90);">Test Pass Rate</div>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">VMs Tested</div>
      <div class="kpi-value">$totalVMs</div>
      <div class="kpi-subtext">$fullyPassedVMs fully passed</div>
    </div>
    <div class="kpi-card$(if($failedTests -gt 0){' fail'})">
      <div class="kpi-label">Total Tests</div>
      <div class="kpi-value">$totalTests</div>
      <div class="kpi-subtext">$passedTests passed, $failedTests failed</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">VM Pass Rate</div>
      <div class="kpi-value">$vmPassRate%</div>
      <div class="kpi-subtext">VMs with all tests passing</div>
    </div>
    <div class="kpi-card nutanix">
      <div class="kpi-label">Isolated Network</div>
      <div class="kpi-value" style="font-size: 20px;">$isolatedNetworkNameEncoded</div>
      <div class="kpi-subtext">VLAN $($IsolatedNetwork.VlanId)</div>
    </div>
  </div>

  <div class="section">
    <div class="section-title">VM Verification Summary</div>
    <table>
      <thead>
        <tr>
          <th>VM Name</th>
          <th>Backup Job</th>
          <th>Restore Point</th>
          <th>Tests (Pass/Total)</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
$vmDetailRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-title">Detailed Test Results</div>
    <table>
      <thead>
        <tr>
          <th>VM Name</th>
          <th>Test</th>
          <th>Result</th>
          <th>Details</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody>
$testDetailRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-title">Test Configuration</div>
    <div class="info-card">
      <div class="info-card-title">SureBackup Parameters</div>
      <div class="info-card-text">
        <strong>VBR Server:</strong> $vbrServerEncoded |
        <strong>Prism Central:</strong> $prismCentralEncoded<br>
        <strong>Isolated Network:</strong> $isolatedNetworkNameEncoded (VLAN $($IsolatedNetwork.VlanId))<br>
        <strong>Boot Timeout:</strong> ${TestBootTimeoutSec}s |
        <strong>Ping Test:</strong> $TestPing |
        <strong>Port Tests:</strong> $testPortsDisplay<br>
        <strong>DNS Test:</strong> $TestDNS |
        <strong>HTTP Endpoints:</strong> $testHttpEndpointsDisplay<br>
        <strong>Custom Script:</strong> $testCustomScriptDisplay |
        <strong>Max Concurrent VMs:</strong> $MaxConcurrentVMs<br>
        <strong>Application Groups:</strong> $(if($ApplicationGroups){"$($ApplicationGroups.Count) group(s) defined"}else{"None (parallel recovery)"})
      </div>
    </div>
  </div>

  <div class="section">
    <div class="section-title">Execution Log</div>
    <div class="log-section">
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
    <p>Veeam SureBackup for Nutanix AHV v1.0.0 | Report generated on $reportDate</p>
    <p>Veeam Backup & Replication + Nutanix Prism Central REST API v3</p>
  </div>
</div>
</body>
</html>
"@

  return $html
}

#endregion

#region Output & Cleanup
# =============================
# Output & Cleanup
# =============================

function Export-Results {
  <#
  .SYNOPSIS
    Export all SureBackup results to files (HTML, CSV, log)
  #>
  param(
    [Parameter(Mandatory = $true)]$TestResults,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  # Create output directory
  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
  }

  Write-Log "Exporting results to: $OutputPath" -Level "INFO"

  # CSV: Test Results
  $csvPath = Join-Path $OutputPath "SureBackup_TestResults.csv"
  $TestResults | Select-Object VMName, TestName, Passed, Details, Duration, Timestamp |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Log "  CSV report: $csvPath" -Level "INFO"

  # CSV: Restore Points
  $rpCsvPath = Join-Path $OutputPath "SureBackup_RestorePoints.csv"
  $RestorePoints | Select-Object VMName, JobName, CreationTime, IsConsistent |
    Export-Csv -Path $rpCsvPath -NoTypeInformation -Encoding UTF8

  # HTML Report
  if ($GenerateHTML) {
    $htmlPath = Join-Path $OutputPath "SureBackup_Report.html"
    $htmlContent = Generate-HTMLReport -TestResults $TestResults -RestorePoints $RestorePoints -IsolatedNetwork $IsolatedNetwork
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "  HTML report: $htmlPath" -Level "SUCCESS"
  }

  # Execution log
  $logPath = Join-Path $OutputPath "SureBackup_ExecutionLog.csv"
  $script:LogEntries | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

  # Summary JSON
  $summaryPath = Join-Path $OutputPath "SureBackup_Summary.json"
  $summary = [PSCustomObject]@{
    Timestamp        = Get-Date -Format "o"
    VBRServer        = $VBRServer
    PrismCentral     = $PrismCentral
    IsolatedNetwork  = $IsolatedNetwork.Name
    DryRun           = [bool]$DryRun
    TotalVMs         = ($TestResults | Select-Object -ExpandProperty VMName -Unique).Count
    TotalTests       = $TestResults.Count
    PassedTests      = ($TestResults | Where-Object { $_.Passed }).Count
    FailedTests      = ($TestResults | Where-Object { -not $_.Passed }).Count
    Duration         = ((Get-Date) - $script:StartTime).ToString()
    Results          = $TestResults
  }
  $summary | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding UTF8

  # ZIP archive
  if ($ZipOutput) {
    $zipPath = "$OutputPath.zip"
    try {
      Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force
      Write-Log "  ZIP archive: $zipPath" -Level "SUCCESS"
    }
    catch {
      Write-Log "  ZIP creation failed: $($_.Exception.Message)" -Level "WARNING"
    }
  }
}

function Invoke-Cleanup {
  <#
  .SYNOPSIS
    Clean up all instant recovery sessions and temporary resources
  #>
  Write-Log "Starting cleanup of $($script:RecoverySessions.Count) recovery session(s)..." -Level "INFO"

  foreach ($session in $script:RecoverySessions) {
    if ($session.Status -eq "Running" -or $session.Status -eq "Failed") {
      Stop-AHVInstantRecovery -RecoveryInfo $session
    }
  }

  $cleanedCount = ($script:RecoverySessions | Where-Object { $_.Status -eq "CleanedUp" }).Count
  Write-Log "Cleanup complete: $cleanedCount session(s) cleaned up" -Level "SUCCESS"
}

#endregion

#region Main Execution
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
  Write-Log "Isolated network: $($isolatedNet.Name) (VLAN $($isolatedNet.VlanId))" -Level "INFO"
  Write-Log "Tests: Heartbeat$(if($TestPing){', Ping'})$(if($TestPorts){', Ports: '+($TestPorts -join ',')})$(if($TestDNS){', DNS'})$(if($TestHttpEndpoints){', HTTP'})$(if($TestCustomScript){', Custom Script'})" -Level "INFO"
  Write-Log "" -Level "INFO"

  # ---- Step 6: Execute SureBackup recovery and testing ----
  Write-ProgressStep -Activity "Executing SureBackup Verification" -Status "Recovering and testing VMs..."

  $bootOrder = Get-VMBootOrder -RestorePoints $restorePoints

  foreach ($groupName in $bootOrder.Keys) {
    $groupRPs = $bootOrder[$groupName]
    Write-Log "--- Processing $groupName ($($groupRPs.Count) VM(s)) ---" -Level "INFO"

    if ($DryRun) {
      # Dry run - just validate and report what would happen
      foreach ($rp in $groupRPs) {
        Write-Log "  [DRY RUN] Would recover '$($rp.VMName)' from $($rp.CreationTime.ToString('yyyy-MM-dd HH:mm')) to isolated network '$($isolatedNet.Name)'" -Level "INFO"

        $script:TestResults.Add([PSCustomObject]@{
          VMName    = $rp.VMName
          TestName  = "Dry Run - Recovery Plan"
          Passed    = $true
          Details   = "Restore point: $($rp.CreationTime.ToString('yyyy-MM-dd HH:mm')), Job: $($rp.JobName), Consistent: $($rp.IsConsistent)"
          Duration  = 0
          Timestamp = Get-Date
        })
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

        # Start instant recovery for each VM in the batch
        foreach ($rp in $batch) {
          Write-Log "Recovering '$($rp.VMName)'..." -Level "INFO"
          $recovery = Start-AHVInstantRecovery -RestorePointInfo $rp -IsolatedNetwork $isolatedNet
          $recoveries += $recovery
        }

        # Wait for all VMs in batch to boot
        Write-Log "Waiting for VMs to boot (timeout: ${TestBootTimeoutSec}s)..." -Level "INFO"
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
          Stop-AHVInstantRecovery -RecoveryInfo $recovery
        }
      }
    }

    # If using application groups, only proceed to next group if current group passed
    if ($ApplicationGroups -and $groupName -ne "Ungrouped") {
      $groupVMNames = $groupRPs | ForEach-Object { $_.VMName }
      $groupResults = $script:TestResults | Where-Object { $_.VMName -in $groupVMNames }
      $groupFailures = $groupResults | Where-Object { -not $_.Passed }

      if ($groupFailures.Count -gt 0 -and -not $DryRun) {
        Write-Log "$groupName has $($groupFailures.Count) test failure(s) - subsequent groups depend on this group" -Level "WARNING"
        Write-Log "Continuing with remaining groups (failures noted in report)..." -Level "WARNING"
      }
      else {
        Write-Log "$groupName : All tests passed" -Level "SUCCESS"
      }
    }
  }

  # ---- Step 7: Generate reports ----
  Write-ProgressStep -Activity "Generating Reports" -Status "Creating HTML report and CSVs..."
  Export-Results -TestResults $script:TestResults -RestorePoints $restorePoints -IsolatedNetwork $isolatedNet

  # ---- Step 8: Final summary ----
  Write-ProgressStep -Activity "Complete" -Status "SureBackup verification finished"

  $totalTests = $script:TestResults.Count
  $passedTests = ($script:TestResults | Where-Object { $_.Passed }).Count
  $failedTests = $totalTests - $passedTests
  $passRate = if ($totalTests -gt 0) { [math]::Round(($passedTests / $totalTests) * 100, 1) } else { 0 }

  Write-Log "" -Level "INFO"
  Write-Log "========================================" -Level "INFO"
  Write-Log "  SUREBACKUP VERIFICATION COMPLETE" -Level "SUCCESS"
  Write-Log "========================================" -Level "INFO"
  Write-Log "  VMs Tested:   $($restorePoints.Count)" -Level "INFO"
  Write-Log "  Total Tests:  $totalTests" -Level "INFO"
  Write-Log "  Passed:       $passedTests" -Level "SUCCESS"

  if ($failedTests -gt 0) {
    Write-Log "  Failed:       $failedTests" -Level "ERROR"
  }
  else {
    Write-Log "  Failed:       0" -Level "SUCCESS"
  }

  Write-Log "  Pass Rate:    $passRate%" -Level $(if ($failedTests -eq 0) { "SUCCESS" } else { "WARNING" })
  Write-Log "  Duration:     $((Get-Date) - $script:StartTime)" -Level "INFO"
  Write-Log "  Report:       $OutputPath" -Level "INFO"
  Write-Log "========================================" -Level "INFO"

  # Return structured result for pipeline use
  [PSCustomObject]@{
    Success     = ($failedTests -eq 0)
    TotalVMs    = $restorePoints.Count
    TotalTests  = $totalTests
    Passed      = $passedTests
    Failed      = $failedTests
    PassRate    = $passRate
    Duration    = ((Get-Date) - $script:StartTime).ToString()
    OutputPath  = (Resolve-Path $OutputPath -ErrorAction SilentlyContinue)
    DryRun      = [bool]$DryRun
    Results     = $script:TestResults
  }
}
catch {
  Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

  # Emergency cleanup
  if ($script:RecoverySessions.Count -gt 0 -and $CleanupOnFailure) {
    Write-Log "Performing emergency cleanup..." -Level "WARNING"
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

#endregion
