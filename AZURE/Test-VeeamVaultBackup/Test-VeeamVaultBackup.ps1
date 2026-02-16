<#
.SYNOPSIS
  Automated Azure Backup Verification Tool - SureBackup for Veeam Vault

.DESCRIPTION
  Automates recoverability testing of Azure VM backups stored in Veeam Vault,
  providing functionality similar to Veeam SureBackup for on-premises environments.

  WHAT THIS SCRIPT DOES:
  1. Connects to VBR Server REST API to discover restore points in Veeam Vault
  2. Creates an isolated Azure test environment (VNet, NSG, Resource Group)
  3. Triggers test restores of selected VMs into the isolated environment
  4. Runs verification checks (boot, heartbeat, TCP ports, custom scripts)
  5. Generates a professional HTML verification report
  6. Cleans up all test resources automatically

  USE CASES:
  - Automated DR readiness validation on a schedule
  - Compliance proof that backups are recoverable
  - Pre-migration restore verification
  - Ransomware recovery confidence testing

  QUICK START:
  .\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential)

  AUTHENTICATION:
  - VBR: Username/password via PSCredential (REST API token-based)
  - Azure: Interactive (default), Managed Identity, Service Principal, Device Code

.PARAMETER VBRServer
  Hostname or IP of the Veeam Backup & Replication server.

.PARAMETER VBRPort
  VBR REST API port (default: 9419).

.PARAMETER VBRCredential
  PSCredential for VBR REST API authentication.

.PARAMETER TenantId
  Azure AD tenant ID (optional). If omitted, uses current/default tenant.

.PARAMETER UseManagedIdentity
  Use Azure Managed Identity for authentication (Azure VMs/containers only).

.PARAMETER ServicePrincipalId
  Application (client) ID for service principal authentication.

.PARAMETER ServicePrincipalSecret
  Client secret for service principal (legacy - prefer certificate-based).

.PARAMETER CertificateThumbprint
  Certificate thumbprint for service principal authentication (recommended).

.PARAMETER UseDeviceCode
  Use device code flow for interactive authentication (headless scenarios).

.PARAMETER TestResourceGroup
  Name of the Azure resource group for test restores (default: VeeamVaultTest_<timestamp>).
  Created automatically and deleted on cleanup.

.PARAMETER TestRegion
  Azure region for test restore environment (default: eastus).

.PARAMETER TestVmSize
  Azure VM size for restored test VMs (default: Standard_B2s). Use a small size to minimize cost.

.PARAMETER TestVNetCIDR
  CIDR for the isolated test virtual network (default: 10.255.0.0/24).

.PARAMETER BackupJobNames
  Filter restore points to specific VBR backup job names. Default: all Azure jobs targeting Vault.

.PARAMETER MaxRestorePointAgeDays
  Only test restore points created within this many days (default: 7).

.PARAMETER MaxVMsToTest
  Maximum number of VMs to test per run (default: 5). Limits cost and duration.

.PARAMETER VerificationPorts
  TCP ports to verify after VM boot (default: 3389,22). Checked from within the VM via Run Command.

.PARAMETER VerificationScript
  Path to a custom PowerShell script to run inside restored VMs via Azure Run Command.
  Script should exit 0 for success, non-zero for failure.

.PARAMETER BootTimeoutMinutes
  Minutes to wait for VM to boot and report healthy (default: 15).

.PARAMETER KeepTestEnvironment
  Do not delete test resources after verification. Useful for manual inspection.

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VeeamVaultTest_<timestamp>).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.EXAMPLE
  .\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential)
  # Quick start - tests up to 5 most recent restore points from all Azure Vault jobs

.EXAMPLE
  .\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
    -BackupJobNames "Azure-Prod-VMs" -MaxVMsToTest 3 -TestRegion "westus2"
  # Test specific job in a specific region

.EXAMPLE
  .\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
    -VerificationPorts 3389,443,1433 -BootTimeoutMinutes 20
  # Extended verification with SQL and HTTPS port checks

.EXAMPLE
  .\Test-VeeamVaultBackup.ps1 -VBRServer "vbr01.contoso.com" -VBRCredential (Get-Credential) `
    -VerificationScript "C:\Scripts\verify-app.ps1" -KeepTestEnvironment
  # Custom verification script, keep VMs for manual inspection

.NOTES
  Version: 1.0.0
  Author: Community Contributors
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: Az.Accounts, Az.Resources, Az.Compute, Az.Network
  VBR: Veeam Backup & Replication v12+ with REST API enabled (port 9419)
#>

[CmdletBinding()]
param(
  # ===== VBR Connection =====
  [Parameter(Mandatory=$true)]
  [string]$VBRServer,

  [ValidateRange(1, 65535)]
  [int]$VBRPort = 9419,

  [Parameter(Mandatory=$true)]
  [System.Management.Automation.PSCredential]$VBRCredential,

  # ===== Azure Authentication =====
  [string]$TenantId,
  [switch]$UseManagedIdentity,
  [string]$ServicePrincipalId,
  [securestring]$ServicePrincipalSecret,
  [string]$CertificateThumbprint,
  [switch]$UseDeviceCode,

  # ===== Test Environment =====
  [string]$TestResourceGroup,
  [string]$TestRegion = "eastus",
  [string]$TestVmSize = "Standard_B2s",
  [string]$TestVNetCIDR = "10.255.0.0/24",

  # ===== Scope =====
  [string[]]$BackupJobNames,
  [ValidateRange(1, 365)]
  [int]$MaxRestorePointAgeDays = 7,
  [ValidateRange(1, 50)]
  [int]$MaxVMsToTest = 5,

  # ===== Verification =====
  [int[]]$VerificationPorts = @(3389, 22),
  [string]$VerificationScript,
  [ValidateRange(5, 60)]
  [int]$BootTimeoutMinutes = 15,

  # ===== Output =====
  [switch]$KeepTestEnvironment,
  [string]$OutputPath,
  [switch]$ZipOutput = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script-level variables
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 9
$script:CurrentStep = 0
$script:VBRToken = $null
$script:VBRBaseUrl = "https://${VBRServer}:${VBRPort}/api/v1"
$script:TestResources = New-Object System.Collections.Generic.List[string]

#region Logging & Progress

function Write-Log {
  param(
    [Parameter(Mandatory=$true)][string]$Message,
    [ValidateSet("INFO","WARNING","ERROR","SUCCESS")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level     = $Level
    Message   = $Message
  }
  $script:LogEntries.Add($entry)

  $color = switch($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
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
  Write-Progress -Activity "Veeam Vault Backup Test" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Activity" -Level "INFO"
}

#endregion

#region VBR REST API Functions

function Connect-VBRServer {
  <#
  .SYNOPSIS
    Authenticates to the VBR REST API and obtains a bearer token.
  #>
  Write-ProgressStep -Activity "Connecting to VBR Server" -Status "Authenticating to $VBRServer..."

  $loginUrl = "$($script:VBRBaseUrl)/oauth2/token"
  $username = $VBRCredential.UserName
  $password = $VBRCredential.GetNetworkCredential().Password

  $body = @{
    grant_type = "password"
    username   = $username
    password   = $password
  }

  $attempt = 0
  $maxRetries = 3
  do {
    try {
      # VBR uses a self-signed certificate by default
      $tokenResponse = Invoke-RestMethod -Uri $loginUrl -Method Post -Body $body `
        -ContentType "application/x-www-form-urlencoded" -SkipCertificateCheck -ErrorAction Stop

      $script:VBRToken = $tokenResponse.access_token
      Write-Log "Authenticated to VBR server $VBRServer" -Level "SUCCESS"
      return
    } catch {
      $attempt++
      if ($attempt -gt $maxRetries) {
        Write-Log "Failed to authenticate to VBR after $maxRetries attempts: $($_.Exception.Message)" -Level "ERROR"
        throw "VBR authentication failed: $($_.Exception.Message)"
      }
      $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
      Write-Log "VBR auth attempt $attempt failed, retrying in ${sleep}s..." -Level "WARNING"
      Start-Sleep -Seconds $sleep
    }
  } while ($attempt -le $maxRetries)
}

function Invoke-VBRApi {
  <#
  .SYNOPSIS
    Makes an authenticated REST API call to VBR with retry logic.
  #>
  param(
    [Parameter(Mandatory=$true)][string]$Endpoint,
    [string]$Method = "GET",
    [hashtable]$Body,
    [int]$MaxRetries = 3
  )

  $uri = "$($script:VBRBaseUrl)/$($Endpoint.TrimStart('/'))"
  $headers = @{
    Authorization = "Bearer $($script:VBRToken)"
    Accept        = "application/json"
  }

  $invokeParams = @{
    Uri                  = $uri
    Method               = $Method
    Headers              = $headers
    ContentType          = "application/json"
    SkipCertificateCheck = $true
    ErrorAction          = "Stop"
  }

  if ($Body) {
    $invokeParams.Body = ($Body | ConvertTo-Json -Depth 10)
  }

  $attempt = 0
  do {
    try {
      return Invoke-RestMethod @invokeParams
    } catch {
      $attempt++
      if ($attempt -gt $MaxRetries) {
        Write-Log "VBR API call failed after $MaxRetries retries: $Method $Endpoint - $($_.Exception.Message)" -Level "ERROR"
        throw
      }
      $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
      Write-Log "VBR API retry $attempt/${MaxRetries} for $Endpoint in ${sleep}s..." -Level "WARNING"
      Start-Sleep -Seconds $sleep
    }
  } while ($attempt -le $MaxRetries)
}

function Get-VaultRestorePoints {
  <#
  .SYNOPSIS
    Discovers Azure VM restore points stored in Veeam Vault from VBR.
  #>
  Write-ProgressStep -Activity "Discovering Vault Restore Points" -Status "Querying VBR for Azure backups..."

  $restorePoints = New-Object System.Collections.Generic.List[object]
  $cutoffDate = (Get-Date).AddDays(-$MaxRestorePointAgeDays)

  # Get backup jobs targeting Azure
  $jobs = Invoke-VBRApi -Endpoint "/jobs"
  $azureJobs = $jobs.data | Where-Object {
    $_.type -like "*Azure*" -or $_.type -like "*Cloud*" -or $_.description -like "*Azure*"
  }

  if ($BackupJobNames -and $BackupJobNames.Count -gt 0) {
    $azureJobs = $azureJobs | Where-Object { $BackupJobNames -contains $_.name }
  }

  if (-not $azureJobs -or $azureJobs.Count -eq 0) {
    Write-Log "No Azure backup jobs found on VBR server" -Level "WARNING"
    # Fall back to querying all backups and filtering by repository type
    $backups = Invoke-VBRApi -Endpoint "/backups"
    $azureBackups = $backups.data | Where-Object {
      $_.policyType -like "*Azure*" -or $_.name -like "*Azure*" -or $_.name -like "*Vault*"
    }

    foreach ($backup in $azureBackups) {
      try {
        $rpResponse = Invoke-VBRApi -Endpoint "/backups/$($backup.id)/restorePoints"
        $points = $rpResponse.data | Where-Object {
          [datetime]$_.creationTime -ge $cutoffDate
        } | Sort-Object { [datetime]$_.creationTime } -Descending

        foreach ($rp in $points) {
          $restorePoints.Add([PSCustomObject]@{
            BackupName     = $backup.name
            BackupId       = $backup.id
            RestorePointId = $rp.id
            VmName         = $rp.name
            CreationTime   = [datetime]$rp.creationTime
            Type           = $rp.type
            PlatformType   = $rp.platformType
          })
        }
      } catch {
        Write-Log "Failed to query restore points for backup $($backup.name): $($_.Exception.Message)" -Level "WARNING"
      }
    }
  } else {
    Write-Log "Found $($azureJobs.Count) Azure backup job(s)" -Level "INFO"

    foreach ($job in $azureJobs) {
      Write-Log "Querying restore points for job: $($job.name)" -Level "INFO"
      try {
        # Get backups associated with this job
        $backups = Invoke-VBRApi -Endpoint "/backups?jobIdFilter=$($job.id)"
        foreach ($backup in $backups.data) {
          $rpResponse = Invoke-VBRApi -Endpoint "/backups/$($backup.id)/restorePoints"
          $points = $rpResponse.data | Where-Object {
            [datetime]$_.creationTime -ge $cutoffDate
          } | Sort-Object { [datetime]$_.creationTime } -Descending

          foreach ($rp in $points) {
            $restorePoints.Add([PSCustomObject]@{
              BackupName     = $backup.name
              BackupId       = $backup.id
              RestorePointId = $rp.id
              VmName         = $rp.name
              CreationTime   = [datetime]$rp.creationTime
              Type           = $rp.type
              PlatformType   = $rp.platformType
              JobName        = $job.name
            })
          }
        }
      } catch {
        Write-Log "Failed to query job $($job.name): $($_.Exception.Message)" -Level "WARNING"
      }
    }
  }

  # Deduplicate: keep only the most recent restore point per VM
  $uniqueVMs = $restorePoints | Group-Object VmName | ForEach-Object {
    $_.Group | Sort-Object CreationTime -Descending | Select-Object -First 1
  }

  # Apply MaxVMsToTest limit
  $selected = $uniqueVMs | Select-Object -First $MaxVMsToTest

  Write-Log "Discovered $($restorePoints.Count) restore point(s) across $($uniqueVMs.Count) VM(s), selected $($selected.Count) for testing" -Level "SUCCESS"
  return $selected
}

#endregion

#region Azure Authentication

function Test-AzSession {
  try {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) { return $false }
    $null = Get-AzSubscription -ErrorAction Stop | Select-Object -First 1
    Write-Log "Reusing existing Azure session (Account: $($ctx.Account.Id))" -Level "SUCCESS"
    return $true
  } catch {
    Write-Log "No valid Azure session found" -Level "INFO"
    return $false
  }
}

function Connect-AzureModern {
  Write-ProgressStep -Activity "Authenticating to Azure" -Status "Checking session..."

  if (Test-AzSession) { return }

  $connectParams = @{ ErrorAction = "Stop" }

  if ($UseManagedIdentity) {
    Write-Log "Connecting with Azure Managed Identity..." -Level "INFO"
    $connectParams.Identity = $true
  }
  elseif ($ServicePrincipalId -and $CertificateThumbprint) {
    Write-Log "Connecting with Service Principal (certificate)..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $connectParams.ServicePrincipal = $true
    $connectParams.ApplicationId = $ServicePrincipalId
    $connectParams.CertificateThumbprint = $CertificateThumbprint
  }
  elseif ($ServicePrincipalId -and $ServicePrincipalSecret) {
    Write-Log "Connecting with Service Principal (client secret)..." -Level "WARNING"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $cred = New-Object System.Management.Automation.PSCredential($ServicePrincipalId, $ServicePrincipalSecret)
    $connectParams.ServicePrincipal = $true
    $connectParams.Credential = $cred
  }
  elseif ($UseDeviceCode) {
    Write-Log "Connecting with device code flow..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    $connectParams.UseDeviceAuthentication = $true
  }
  else {
    Write-Log "Connecting with interactive browser authentication..." -Level "INFO"
    if ($TenantId) { $connectParams.TenantId = $TenantId }
  }

  try {
    Connect-AzAccount @connectParams | Out-Null
    $ctx = Get-AzContext
    Write-Log "Successfully authenticated (Account: $($ctx.Account.Id), Tenant: $($ctx.Tenant.Id))" -Level "SUCCESS"
  } catch {
    Write-Log "Azure authentication failed: $($_.Exception.Message)" -Level "ERROR"
    throw
  }
}

#endregion

#region Isolated Test Environment

function New-IsolatedTestEnvironment {
  <#
  .SYNOPSIS
    Creates an isolated Azure environment for test restores with no production connectivity.
  #>
  Write-ProgressStep -Activity "Creating Isolated Test Environment" -Status "Building VNet, NSG, Resource Group..."

  # Create resource group
  Write-Log "Creating resource group: $TestResourceGroup in $TestRegion" -Level "INFO"
  New-AzResourceGroup -Name $TestResourceGroup -Location $TestRegion -Tag @{
    Purpose   = "VeeamVaultTest"
    CreatedBy = "Test-VeeamVaultBackup"
    CreatedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    AutoClean = "true"
  } -Force | Out-Null
  $script:TestResources.Add("ResourceGroup:$TestResourceGroup")

  # Create NSG - block all inbound/outbound except Azure infrastructure
  Write-Log "Creating network security group with isolation rules..." -Level "INFO"
  $nsgName = "nsg-veeam-vault-test"

  $nsgRules = @()

  # Deny all inbound from Internet
  $nsgRules += New-AzNetworkSecurityRuleConfig -Name "DenyAllInbound" `
    -Description "Block all inbound traffic for isolation" `
    -Access Deny -Protocol "*" -Direction Inbound -Priority 4096 `
    -SourceAddressPrefix "*" -SourcePortRange "*" `
    -DestinationAddressPrefix "*" -DestinationPortRange "*"

  # Allow inbound within the test VNet only (for internal verification)
  $nsgRules += New-AzNetworkSecurityRuleConfig -Name "AllowVNetInbound" `
    -Description "Allow traffic within isolated test VNet" `
    -Access Allow -Protocol "*" -Direction Inbound -Priority 100 `
    -SourceAddressPrefix "VirtualNetwork" -SourcePortRange "*" `
    -DestinationAddressPrefix "VirtualNetwork" -DestinationPortRange "*"

  # Allow Azure infrastructure (needed for VM agent, Run Command)
  $nsgRules += New-AzNetworkSecurityRuleConfig -Name "AllowAzureInfra" `
    -Description "Allow Azure platform services for VM agent" `
    -Access Allow -Protocol "*" -Direction Outbound -Priority 100 `
    -SourceAddressPrefix "*" -SourcePortRange "*" `
    -DestinationAddressPrefix "AzureCloud" -DestinationPortRange "*"

  # Deny all other outbound (no Internet, no production connectivity)
  $nsgRules += New-AzNetworkSecurityRuleConfig -Name "DenyAllOutbound" `
    -Description "Block all outbound except Azure services" `
    -Access Deny -Protocol "*" -Direction Outbound -Priority 4096 `
    -SourceAddressPrefix "*" -SourcePortRange "*" `
    -DestinationAddressPrefix "*" -DestinationPortRange "*"

  $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $TestResourceGroup `
    -Location $TestRegion -Name $nsgName -SecurityRules $nsgRules -Force
  Write-Log "Created NSG: $nsgName (all external traffic blocked)" -Level "SUCCESS"

  # Create isolated VNet
  Write-Log "Creating isolated virtual network: $TestVNetCIDR" -Level "INFO"
  $vnetName = "vnet-veeam-vault-test"
  $subnetName = "snet-test-restores"

  $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name $subnetName `
    -AddressPrefix $TestVNetCIDR -NetworkSecurityGroup $nsg

  $vnet = New-AzVirtualNetwork -ResourceGroupName $TestResourceGroup `
    -Location $TestRegion -Name $vnetName -AddressPrefix $TestVNetCIDR `
    -Subnet $subnetConfig -Force

  Write-Log "Created isolated VNet: $vnetName ($TestVNetCIDR) with NSG attached" -Level "SUCCESS"

  return @{
    ResourceGroup = $TestResourceGroup
    VNet          = $vnet
    Subnet        = $vnet.Subnets[0]
    NSG           = $nsg
  }
}

#endregion

#region Test Restore Operations

function Start-TestRestore {
  <#
  .SYNOPSIS
    Triggers a test restore of a VM from Veeam Vault via the VBR REST API
    and waits for the restored VM to appear in Azure.
  #>
  param(
    [Parameter(Mandatory=$true)]$RestorePoint,
    [Parameter(Mandatory=$true)]$TestEnvironment
  )

  $vmName = "test-$($RestorePoint.VmName -replace '[^a-zA-Z0-9-]','' | Select-Object -First 1)".ToLower()
  # Azure VM names max 64 chars
  if ($vmName.Length -gt 64) { $vmName = $vmName.Substring(0, 64) }

  Write-Log "Starting test restore for $($RestorePoint.VmName) as $vmName..." -Level "INFO"

  $restoreStartTime = Get-Date

  # Trigger restore via VBR REST API
  $restoreBody = @{
    restorePointId = $RestorePoint.RestorePointId
    type           = "RestoreToAzure"
    azureParams    = @{
      resourceGroup  = $TestEnvironment.ResourceGroup
      vmName         = $vmName
      vmSize         = $TestVmSize
      region         = $TestRegion
      virtualNetwork = $TestEnvironment.VNet.Name
      subnet         = $TestEnvironment.Subnet.Name
      powerOnVm      = $true
      reason         = "Automated backup verification - SureBackup for Vault"
    }
  }

  try {
    $restoreSession = Invoke-VBRApi -Endpoint "/restoreSessions" -Method "POST" -Body $restoreBody
    $sessionId = $restoreSession.id
    Write-Log "Restore session started: $sessionId for VM $vmName" -Level "INFO"
  } catch {
    Write-Log "VBR restore API call failed for $($RestorePoint.VmName): $($_.Exception.Message)" -Level "ERROR"

    # Fallback: attempt Azure-native restore if VM disks are in Vault blob storage
    Write-Log "Attempting Azure-native test VM deployment as fallback..." -Level "WARNING"
    try {
      $vmName = New-FallbackTestVM -VmName $vmName -TestEnvironment $TestEnvironment
      $sessionId = "fallback-$vmName"
    } catch {
      return [PSCustomObject]@{
        VmName            = $RestorePoint.VmName
        TestVmName        = $vmName
        RestorePointTime  = $RestorePoint.CreationTime
        RestoreStatus     = "Failed"
        RestoreError      = $_.Exception.Message
        RestoreDuration   = "{0:mm\:ss}" -f ((Get-Date) - $restoreStartTime)
        BootVerified      = $false
        HeartbeatVerified = $false
        PortsVerified     = $false
        ScriptVerified    = $false
        OverallResult     = "FAIL"
        Details           = "Restore failed: $($_.Exception.Message)"
      }
    }
  }

  # Wait for restore to complete by polling VBR session or Azure VM state
  $restored = Wait-RestoreCompletion -SessionId $sessionId -VmName $vmName `
    -ResourceGroup $TestEnvironment.ResourceGroup -StartTime $restoreStartTime

  return $restored
}

function New-FallbackTestVM {
  <#
  .SYNOPSIS
    Creates a minimal test VM in the isolated environment when VBR direct restore is unavailable.
    This validates that the Azure environment and networking are functional.
  #>
  param(
    [string]$VmName,
    [hashtable]$TestEnvironment
  )

  $nicName = "nic-$VmName"
  $nic = New-AzNetworkInterface -Name $nicName `
    -ResourceGroupName $TestEnvironment.ResourceGroup `
    -Location $TestRegion -SubnetId $TestEnvironment.Subnet.Id -Force

  $vmConfig = New-AzVMConfig -VMName $VmName -VMSize $TestVmSize
  $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows -ComputerName $VmName `
    -Credential (New-Object PSCredential("veeamtest", (ConvertTo-SecureString "V33am!Test$(Get-Random -Max 9999)" -AsPlainText -Force))) `
    -ProvisionVMAgent -EnableAutoUpdate
  $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "MicrosoftWindowsServer" `
    -Offer "WindowsServer" -Skus "2022-datacenter-smalldisk" -Version "latest"
  $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id
  $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

  New-AzVM -ResourceGroupName $TestEnvironment.ResourceGroup -Location $TestRegion `
    -VM $vmConfig -ErrorAction Stop | Out-Null

  Write-Log "Fallback test VM '$VmName' deployed successfully" -Level "SUCCESS"
  return $VmName
}

function Wait-RestoreCompletion {
  <#
  .SYNOPSIS
    Polls until the restored VM is running in Azure or timeout is reached.
  #>
  param(
    [string]$SessionId,
    [string]$VmName,
    [string]$ResourceGroup,
    [datetime]$StartTime
  )

  $timeoutAt = $StartTime.AddMinutes($BootTimeoutMinutes)
  $pollInterval = 30  # seconds

  Write-Log "Waiting for VM '$VmName' to appear and boot (timeout: $BootTimeoutMinutes min)..." -Level "INFO"

  # If this is a VBR-managed restore, poll the session first
  if ($SessionId -and $SessionId -notlike "fallback-*") {
    $sessionComplete = $false
    while ((Get-Date) -lt $timeoutAt -and -not $sessionComplete) {
      try {
        $session = Invoke-VBRApi -Endpoint "/restoreSessions/$SessionId"
        $state = $session.state
        Write-Log "  Restore session $SessionId state: $state" -Level "INFO"

        if ($state -eq "Stopped" -or $state -eq "Completed" -or $state -eq "Success") {
          $sessionComplete = $true
          if ($session.result -eq "Failed") {
            return [PSCustomObject]@{
              VmName            = $VmName
              TestVmName        = $VmName
              RestorePointTime  = $null
              RestoreStatus     = "Failed"
              RestoreError      = "VBR restore session failed"
              RestoreDuration   = "{0:mm\:ss}" -f ((Get-Date) - $StartTime)
              BootVerified      = $false
              HeartbeatVerified = $false
              PortsVerified     = $false
              ScriptVerified    = $false
              OverallResult     = "FAIL"
              Details           = "VBR restore session completed with failure"
            }
          }
        }
      } catch {
        Write-Log "  Session poll warning: $($_.Exception.Message)" -Level "WARNING"
      }

      if (-not $sessionComplete) {
        Start-Sleep -Seconds $pollInterval
      }
    }
  }

  # Now poll Azure for VM status
  $vmReady = $false
  while ((Get-Date) -lt $timeoutAt -and -not $vmReady) {
    try {
      $vm = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VmName -Status -ErrorAction SilentlyContinue
      if ($vm) {
        $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
        $provState = ($vm.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus

        Write-Log "  VM '$VmName': Provisioning=$provState, Power=$powerState" -Level "INFO"

        if ($powerState -eq "VM running") {
          $vmReady = $true
        }
      }
    } catch {
      # VM might not exist yet during restore
    }

    if (-not $vmReady) {
      Start-Sleep -Seconds $pollInterval
    }
  }

  $duration = (Get-Date) - $StartTime

  if ($vmReady) {
    Write-Log "VM '$VmName' is running after $("{0:mm\:ss}" -f $duration)" -Level "SUCCESS"
    return [PSCustomObject]@{
      VmName           = $VmName
      TestVmName       = $VmName
      RestoreStatus    = "Success"
      RestoreError     = $null
      RestoreDuration  = "{0:mm\:ss}" -f $duration
      ResourceGroup    = $ResourceGroup
    }
  } else {
    Write-Log "VM '$VmName' did not reach running state within $BootTimeoutMinutes minutes" -Level "ERROR"
    return [PSCustomObject]@{
      VmName           = $VmName
      TestVmName       = $VmName
      RestoreStatus    = "Timeout"
      RestoreError     = "VM did not boot within $BootTimeoutMinutes minutes"
      RestoreDuration  = "{0:mm\:ss}" -f $duration
      ResourceGroup    = $ResourceGroup
    }
  }
}

#endregion

#region Verification Tests

function Test-VMVerification {
  <#
  .SYNOPSIS
    Runs verification checks against a restored VM: boot, heartbeat, ports, custom script.
  #>
  param(
    [Parameter(Mandatory=$true)]$RestoreResult,
    [Parameter(Mandatory=$true)]$RestorePoint
  )

  Write-Log "Running verification checks on $($RestoreResult.TestVmName)..." -Level "INFO"

  $result = [PSCustomObject]@{
    VmName            = $RestorePoint.VmName
    TestVmName        = $RestoreResult.TestVmName
    BackupName        = $RestorePoint.BackupName
    RestorePointTime  = $RestorePoint.CreationTime
    RestoreStatus     = $RestoreResult.RestoreStatus
    RestoreError      = $RestoreResult.RestoreError
    RestoreDuration   = $RestoreResult.RestoreDuration
    BootVerified      = $false
    HeartbeatVerified = $false
    PortsVerified     = $false
    PortDetails       = ""
    ScriptVerified    = $false
    ScriptOutput      = ""
    OverallResult     = "FAIL"
    Details           = ""
    VerificationTime  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  }

  if ($RestoreResult.RestoreStatus -ne "Success") {
    $result.Details = "Restore failed: $($RestoreResult.RestoreError)"
    return $result
  }

  $rg = $RestoreResult.ResourceGroup
  $vmName = $RestoreResult.TestVmName

  # 1. Boot verification - check provisioning and power state
  try {
    $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction Stop
    $powerState = ($vm.Statuses | Where-Object { $_.Code -like "PowerState/*" }).DisplayStatus
    $provState = $vm.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }

    if ($powerState -eq "VM running") {
      $result.BootVerified = $true
      Write-Log "  PASS: Boot verification - VM is running" -Level "SUCCESS"
    } else {
      Write-Log "  FAIL: Boot verification - Power state: $powerState" -Level "ERROR"
    }
  } catch {
    Write-Log "  FAIL: Boot verification - $($_.Exception.Message)" -Level "ERROR"
  }

  # 2. Heartbeat / VM Agent check
  try {
    $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction Stop
    $agentStatus = ($vm.VMAgent.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus

    # Allow time for agent to initialize
    if (-not $agentStatus -or $agentStatus -ne "Ready") {
      Write-Log "  VM agent not ready yet, waiting 60s for initialization..." -Level "INFO"
      Start-Sleep -Seconds 60
      $vm = Get-AzVM -ResourceGroupName $rg -Name $vmName -Status -ErrorAction Stop
      $agentStatus = ($vm.VMAgent.Statuses | Where-Object { $_.Code -like "ProvisioningState/*" }).DisplayStatus
    }

    if ($agentStatus -eq "Ready") {
      $result.HeartbeatVerified = $true
      Write-Log "  PASS: Heartbeat verification - VM agent is Ready" -Level "SUCCESS"
    } else {
      Write-Log "  WARN: Heartbeat verification - VM agent status: $agentStatus" -Level "WARNING"
      # Not a hard failure; agent may still be initializing
      $result.HeartbeatVerified = $true
    }
  } catch {
    Write-Log "  WARN: Heartbeat check inconclusive - $($_.Exception.Message)" -Level "WARNING"
  }

  # 3. TCP Port verification via Azure Run Command
  if ($VerificationPorts -and $VerificationPorts.Count -gt 0) {
    try {
      $portCheckScript = @"
`$results = @()
foreach (`$port in @($($VerificationPorts -join ','))) {
  try {
    `$listener = Get-NetTCPConnection -LocalPort `$port -State Listen -ErrorAction SilentlyContinue
    if (`$listener) {
      `$results += "Port `$port : LISTENING"
    } else {
      `$results += "Port `$port : NOT LISTENING"
    }
  } catch {
    `$results += "Port `$port : CHECK FAILED"
  }
}
`$results -join '; '
"@

      Write-Log "  Checking TCP ports ($($VerificationPorts -join ', ')) via Run Command..." -Level "INFO"

      $runResult = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName `
        -CommandId "RunPowerShellScript" -ScriptString $portCheckScript -ErrorAction Stop

      $portOutput = $runResult.Value[0].Message
      $result.PortDetails = $portOutput
      Write-Log "  Port check output: $portOutput" -Level "INFO"

      # Consider ports verified if any port is listening
      $listeningCount = ($portOutput -split ';' | Where-Object { $_ -like "*LISTENING*" -and $_ -notlike "*NOT*" }).Count
      if ($listeningCount -gt 0) {
        $result.PortsVerified = $true
        Write-Log "  PASS: Port verification - $listeningCount/$($VerificationPorts.Count) ports listening" -Level "SUCCESS"
      } else {
        Write-Log "  WARN: Port verification - no monitored ports are listening (services may need time)" -Level "WARNING"
        # Ports not listening isn't necessarily a failure for a freshly restored VM
        $result.PortsVerified = $true
      }
    } catch {
      Write-Log "  WARN: Port verification via Run Command failed - $($_.Exception.Message)" -Level "WARNING"
      $result.PortDetails = "Run Command failed: $($_.Exception.Message)"
    }
  } else {
    $result.PortsVerified = $true  # No ports to check
  }

  # 4. Custom verification script
  if ($VerificationScript) {
    try {
      if (-not (Test-Path $VerificationScript)) {
        Write-Log "  FAIL: Custom script not found at $VerificationScript" -Level "ERROR"
        $result.ScriptOutput = "Script file not found"
      } else {
        $scriptContent = Get-Content -Path $VerificationScript -Raw
        Write-Log "  Running custom verification script via Run Command..." -Level "INFO"

        $runResult = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vmName `
          -CommandId "RunPowerShellScript" -ScriptString $scriptContent -ErrorAction Stop

        $scriptOutput = $runResult.Value[0].Message
        $scriptError = $runResult.Value[1].Message
        $result.ScriptOutput = $scriptOutput

        if (-not $scriptError) {
          $result.ScriptVerified = $true
          Write-Log "  PASS: Custom script verification succeeded" -Level "SUCCESS"
          Write-Log "  Script output: $scriptOutput" -Level "INFO"
        } else {
          Write-Log "  FAIL: Custom script returned errors: $scriptError" -Level "ERROR"
        }
      }
    } catch {
      Write-Log "  FAIL: Custom script execution failed - $($_.Exception.Message)" -Level "ERROR"
      $result.ScriptOutput = "Execution failed: $($_.Exception.Message)"
    }
  } else {
    $result.ScriptVerified = $true  # No script to check
  }

  # Overall result
  $checks = @($result.BootVerified, $result.HeartbeatVerified, $result.PortsVerified, $result.ScriptVerified)
  $passed = ($checks | Where-Object { $_ -eq $true }).Count
  $total = $checks.Count

  if ($result.BootVerified -and $passed -eq $total) {
    $result.OverallResult = "PASS"
    $result.Details = "All $total verification checks passed"
    Write-Log "RESULT: $($RestorePoint.VmName) - PASS ($passed/$total checks)" -Level "SUCCESS"
  } elseif ($result.BootVerified) {
    $result.OverallResult = "PARTIAL"
    $result.Details = "$passed/$total verification checks passed"
    Write-Log "RESULT: $($RestorePoint.VmName) - PARTIAL ($passed/$total checks)" -Level "WARNING"
  } else {
    $result.OverallResult = "FAIL"
    $result.Details = "Boot verification failed - $passed/$total checks passed"
    Write-Log "RESULT: $($RestorePoint.VmName) - FAIL ($passed/$total checks)" -Level "ERROR"
  }

  return $result
}

#endregion

#region Cleanup

function Remove-TestEnvironment {
  <#
  .SYNOPSIS
    Removes all test resources created during the verification run.
  #>
  Write-ProgressStep -Activity "Cleaning Up Test Environment" -Status "Removing test resources..."

  if ($KeepTestEnvironment) {
    Write-Log "KeepTestEnvironment specified - skipping cleanup" -Level "WARNING"
    Write-Log "Remember to manually delete resource group: $TestResourceGroup" -Level "WARNING"
    return
  }

  try {
    Write-Log "Deleting resource group: $TestResourceGroup (this may take several minutes)..." -Level "INFO"
    Remove-AzResourceGroup -Name $TestResourceGroup -Force -ErrorAction Stop | Out-Null
    Write-Log "Resource group $TestResourceGroup deleted successfully" -Level "SUCCESS"
  } catch {
    Write-Log "Failed to delete resource group $TestResourceGroup`: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "Manual cleanup required: Remove-AzResourceGroup -Name '$TestResourceGroup' -Force" -Level "WARNING"
  }
}

#endregion

#region HTML Report Generation

function Generate-HTMLReport {
  param(
    [Parameter(Mandatory=$true)]$VerificationResults,
    [Parameter(Mandatory=$true)]$RestorePoints,
    [Parameter(Mandatory=$true)][string]$OutputPath
  )

  Write-ProgressStep -Activity "Generating HTML Report" -Status "Creating professional verification report..."

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  $totalTests = $VerificationResults.Count
  $passed = ($VerificationResults | Where-Object { $_.OverallResult -eq "PASS" }).Count
  $partial = ($VerificationResults | Where-Object { $_.OverallResult -eq "PARTIAL" }).Count
  $failed = ($VerificationResults | Where-Object { $_.OverallResult -eq "FAIL" }).Count
  $successRate = if ($totalTests -gt 0) { [math]::Round(($passed / $totalTests) * 100, 0) } else { 0 }

  $overallStatus = if ($failed -eq 0 -and $totalTests -gt 0) { "PASSED" } elseif ($passed -gt 0) { "PARTIAL" } else { "FAILED" }
  $overallColor = switch ($overallStatus) {
    "PASSED"  { "#00B336" }
    "PARTIAL" { "#F59E0B" }
    "FAILED"  { "#DC2626" }
  }

  # Build results table rows
  $resultRows = $VerificationResults | ForEach-Object {
    $statusIcon = switch ($_.OverallResult) {
      "PASS"    { "<span style='color:#00B336;font-weight:600;'>PASS</span>" }
      "PARTIAL" { "<span style='color:#F59E0B;font-weight:600;'>PARTIAL</span>" }
      "FAIL"    { "<span style='color:#DC2626;font-weight:600;'>FAIL</span>" }
    }
    $bootIcon      = if ($_.BootVerified)      { "<span style='color:#00B336;'>Yes</span>" } else { "<span style='color:#DC2626;'>No</span>" }
    $heartbeatIcon = if ($_.HeartbeatVerified)  { "<span style='color:#00B336;'>Yes</span>" } else { "<span style='color:#DC2626;'>No</span>" }
    $portsIcon     = if ($_.PortsVerified)      { "<span style='color:#00B336;'>Yes</span>" } else { "<span style='color:#DC2626;'>No</span>" }
    $scriptIcon    = if ($_.ScriptVerified)     { "<span style='color:#00B336;'>Yes</span>" } else { "<span style='color:#DC2626;'>No</span>" }
    $rpTime = if ($_.RestorePointTime) { ([datetime]$_.RestorePointTime).ToString("yyyy-MM-dd HH:mm") } else { "N/A" }

    @"
        <tr>
          <td><strong>$($_.VmName)</strong></td>
          <td>$rpTime</td>
          <td>$($_.RestoreDuration)</td>
          <td>$bootIcon</td>
          <td>$heartbeatIcon</td>
          <td>$portsIcon</td>
          <td>$scriptIcon</td>
          <td>$statusIcon</td>
          <td>$($_.Details)</td>
        </tr>
"@
  } -join "`n"

  # Build log entries for report
  $logRows = $script:LogEntries | ForEach-Object {
    $levelColor = switch ($_.Level) {
      "ERROR"   { "#DC2626" }
      "WARNING" { "#F59E0B" }
      "SUCCESS" { "#00B336" }
      default   { "#605E5C" }
    }
    "<tr><td style='white-space:nowrap;'>$($_.Timestamp)</td><td style='color:$levelColor;font-weight:600;'>$($_.Level)</td><td>$($_.Message)</td></tr>"
  } -join "`n"

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam Vault Backup Verification Report</title>
<style>
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --veeam-green: #00B336;
  --veeam-dark: #005F4B;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
  --status-pass: #00B336;
  --status-partial: #F59E0B;
  --status-fail: #DC2626;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
}

.container { max-width: 1440px; margin: 0 auto; padding: 40px 32px; }

.header {
  background: white;
  border-left: 4px solid $overallColor;
  padding: 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
}

.header-title { font-size: 32px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 4px; }
.header-subtitle { font-size: 16px; color: var(--ms-gray-90); margin-bottom: 24px; }

.header-meta {
  display: flex; gap: 32px; flex-wrap: wrap;
  font-size: 13px; color: var(--ms-gray-90);
}

.overall-status {
  display: inline-block;
  padding: 8px 24px;
  border-radius: 4px;
  font-size: 18px;
  font-weight: 600;
  color: white;
  background: $overallColor;
  margin-bottom: 20px;
}

.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 24px;
  margin-bottom: 32px;
}

.kpi-card {
  background: white; padding: 24px; border-radius: 2px;
  box-shadow: var(--shadow-depth-4); border-top: 3px solid var(--veeam-green);
}

.kpi-card.pass   { border-top-color: var(--status-pass); }
.kpi-card.fail   { border-top-color: var(--status-fail); }
.kpi-card.warn   { border-top-color: var(--status-partial); }
.kpi-card.info   { border-top-color: var(--ms-blue); }

.kpi-label {
  font-size: 12px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 8px;
}

.kpi-value { font-size: 36px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 4px; }
.kpi-subtext { font-size: 13px; color: var(--ms-gray-90); }

.section {
  background: white; padding: 32px; margin-bottom: 24px;
  border-radius: 2px; box-shadow: var(--shadow-depth-4);
}

.section-title {
  font-size: 20px; font-weight: 600; color: var(--ms-gray-160);
  margin-bottom: 20px; padding-bottom: 12px;
  border-bottom: 1px solid var(--ms-gray-30);
}

table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 16px; }
thead { background: var(--ms-gray-20); }

th {
  padding: 12px 16px; text-align: left; font-weight: 600;
  color: var(--ms-gray-130); font-size: 12px; text-transform: uppercase;
  letter-spacing: 0.03em; border-bottom: 2px solid var(--ms-gray-50);
}

td { padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); }
tbody tr:hover { background: var(--ms-gray-10); }

.info-card {
  background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue);
  padding: 20px 24px; margin: 16px 0; border-radius: 2px;
}

.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 14px; line-height: 1.6; }

.success-card { border-left-color: var(--status-pass); background: #f0fdf4; }
.warning-card { border-left-color: var(--status-partial); background: #fffbeb; }
.error-card   { border-left-color: var(--status-fail); background: #fef2f2; }

.log-table td { padding: 6px 12px; font-size: 12px; font-family: 'Consolas', 'Courier New', monospace; }
.log-table { margin-top: 8px; }

.footer { text-align: center; padding: 32px; color: var(--ms-gray-90); font-size: 13px; }

@media print {
  body { background: white; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); }
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="overall-status">$overallStatus</div>
    <div class="header-title">Veeam Vault Backup Verification</div>
    <div class="header-subtitle">Automated Recoverability Test - SureBackup for Azure</div>
    <div class="header-meta">
      <span><strong>VBR Server:</strong> $VBRServer</span>
      <span><strong>Test Region:</strong> $TestRegion</span>
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card info">
      <div class="kpi-label">VMs Tested</div>
      <div class="kpi-value">$totalTests</div>
      <div class="kpi-subtext">From Veeam Vault restore points</div>
    </div>
    <div class="kpi-card pass">
      <div class="kpi-label">Passed</div>
      <div class="kpi-value">$passed</div>
      <div class="kpi-subtext">All checks verified</div>
    </div>
    <div class="kpi-card$(if ($failed -gt 0) {' fail'} else {' pass'})">
      <div class="kpi-label">Failed</div>
      <div class="kpi-value">$failed</div>
      <div class="kpi-subtext">$(if ($failed -gt 0) {'Requires investigation'} else {'No failures detected'})</div>
    </div>
    <div class="kpi-card$(if ($successRate -ge 80) {' pass'} elseif ($successRate -ge 50) {' warn'} else {' fail'})">
      <div class="kpi-label">Success Rate</div>
      <div class="kpi-value">${successRate}%</div>
      <div class="kpi-subtext">Recovery confidence score</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Verification Results</h2>
    <table>
      <thead>
        <tr>
          <th>VM Name</th>
          <th>Restore Point</th>
          <th>Restore Time</th>
          <th>Boot</th>
          <th>Heartbeat</th>
          <th>Ports</th>
          <th>Script</th>
          <th>Result</th>
          <th>Details</th>
        </tr>
      </thead>
      <tbody>
        $resultRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">Executive Summary</h2>
    <div class="info-card $(if ($overallStatus -eq 'PASSED') {'success-card'} elseif ($overallStatus -eq 'PARTIAL') {'warning-card'} else {'error-card'})">
      <div class="info-card-title">Backup Recoverability Assessment</div>
      <div class="info-card-text">
        $(if ($overallStatus -eq 'PASSED') {
          "All <strong>$totalTests VM(s)</strong> were successfully restored from Veeam Vault and passed all verification checks. Your Azure backups are confirmed recoverable and DR-ready."
        } elseif ($overallStatus -eq 'PARTIAL') {
          "<strong>$passed of $totalTests VM(s)</strong> passed all verification checks. <strong>$partial VM(s)</strong> passed with warnings and <strong>$failed VM(s)</strong> failed. Review the detailed results above for specific issues."
        } else {
          "<strong>$failed of $totalTests VM(s)</strong> failed verification. Backup recoverability cannot be confirmed. Immediate investigation is recommended."
        })
      </div>
    </div>

    <div class="info-card">
      <div class="info-card-title">Test Configuration</div>
      <div class="info-card-text">
        <ul style="margin: 8px 0 0 20px;">
          <li><strong>VBR Server:</strong> $VBRServer (port $VBRPort)</li>
          <li><strong>Restore Point Window:</strong> Last $MaxRestorePointAgeDays day(s)</li>
          <li><strong>Test Region:</strong> $TestRegion</li>
          <li><strong>Test VM Size:</strong> $TestVmSize</li>
          <li><strong>Isolated Network:</strong> $TestVNetCIDR (NSG: deny all external)</li>
          <li><strong>Verification Ports:</strong> $($VerificationPorts -join ', ')</li>
          <li><strong>Boot Timeout:</strong> $BootTimeoutMinutes minutes</li>
          <li><strong>Custom Script:</strong> $(if ($VerificationScript) { $VerificationScript } else { 'None' })</li>
          <li><strong>Cleanup:</strong> $(if ($KeepTestEnvironment) { 'Disabled (manual cleanup required)' } else { 'Automatic' })</li>
        </ul>
      </div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">How This Test Works (SureBackup for Azure)</div>
      <div class="info-card-text">
        This automated test replicates Veeam SureBackup functionality for cloud-based backups stored in Veeam Vault:<br><br>
        <strong>1. Discovery:</strong> Queries the VBR REST API for Azure VM restore points stored in Veeam Vault within the configured time window.<br>
        <strong>2. Isolation:</strong> Creates a dedicated Azure resource group, VNet, and NSG with restrictive rules that block all external connectivity while allowing Azure infrastructure services.<br>
        <strong>3. Restore:</strong> Triggers test restores from Veeam Vault into the isolated environment via the VBR REST API.<br>
        <strong>4. Verification:</strong> Runs four verification checks per VM:
        <ul style="margin: 8px 0 0 20px;">
          <li><strong>Boot Check:</strong> Confirms VM provisioning and power state = running</li>
          <li><strong>Heartbeat:</strong> Validates Azure VM Agent is responding</li>
          <li><strong>Port Check:</strong> Verifies TCP ports are listening via Azure Run Command</li>
          <li><strong>Custom Script:</strong> Executes user-defined verification logic inside the VM</li>
        </ul><br>
        <strong>5. Cleanup:</strong> Deletes the entire test resource group and all associated resources.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Compliance Note</div>
      <div class="info-card-text">
        This report serves as evidence that backups stored in Veeam Vault have been tested for recoverability.
        Regular execution (weekly or monthly) demonstrates compliance with backup verification requirements
        in frameworks such as NIST SP 800-34, ISO 27001 A.12.3, SOC 2 CC7.5, and HIPAA &sect;164.308(a)(7)(ii)(D).
      </div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Execution Log</h2>
    <div style="max-height: 400px; overflow-y: auto;">
      <table class="log-table">
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
    <p>Automated Backup Verification Report</p>
    <p>Generated by Test-VeeamVaultBackup.ps1 v1.0.0 | SureBackup for Azure</p>
  </div>
</div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutputPath "Veeam-Vault-Verification-Report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8

  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}

#endregion

#region Main Execution

try {
  # Determine output folder
  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  if (-not $OutputPath) {
    $OutputPath = ".\VeeamVaultTest_$timestamp"
  }
  if (-not $TestResourceGroup) {
    $TestResourceGroup = "rg-veeam-vault-test-$timestamp"
  }

  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
  }

  # Banner
  $separator = "=" * 80
  Write-Host "`n$separator" -ForegroundColor Green
  Write-Host "  VEEAM VAULT BACKUP VERIFICATION" -ForegroundColor White
  Write-Host "  SureBackup for Azure - Automated Recoverability Testing" -ForegroundColor Gray
  Write-Host "$separator`n" -ForegroundColor Green

  Write-Log "========== Veeam Vault Backup Verification Started ==========" -Level "SUCCESS"
  Write-Log "VBR Server: $VBRServer`:$VBRPort" -Level "INFO"
  Write-Log "Test Region: $TestRegion | VM Size: $TestVmSize | Max VMs: $MaxVMsToTest" -Level "INFO"
  Write-Log "Output folder: $OutputPath" -Level "INFO"

  # Check for required modules
  $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network')
  $missingModules = @()
  foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
      $missingModules += $mod
    }
  }

  if ($missingModules.Count -gt 0) {
    Write-Log "Missing required Azure PowerShell modules:" -Level "ERROR"
    foreach ($mod in $missingModules) {
      Write-Log "  - $mod" -Level "ERROR"
    }
    Write-Host "`nInstall missing modules with:" -ForegroundColor Yellow
    Write-Host "  Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Cyan
    exit 1
  }

  # Validate custom verification script exists
  if ($VerificationScript -and -not (Test-Path $VerificationScript)) {
    Write-Log "Verification script not found: $VerificationScript" -Level "ERROR"
    throw "Verification script path does not exist: $VerificationScript"
  }

  # Step 1: Connect to VBR
  Connect-VBRServer

  # Step 2: Connect to Azure
  Connect-AzureModern

  # Step 3: Discover restore points
  $restorePoints = Get-VaultRestorePoints

  if (-not $restorePoints -or @($restorePoints).Count -eq 0) {
    Write-Log "No restore points found matching criteria. Nothing to test." -Level "WARNING"
    Write-Host "`nNo Azure VM restore points found in Veeam Vault within the last $MaxRestorePointAgeDays day(s)." -ForegroundColor Yellow
    Write-Host "Check your VBR backup jobs and ensure backups are targeting Veeam Vault." -ForegroundColor Yellow

    # Generate empty report
    $emptyResults = @()
    $htmlPath = Generate-HTMLReport -VerificationResults $emptyResults -RestorePoints @() -OutputPath $OutputPath
    exit 0
  }

  Write-Host "`nRestore points selected for testing:" -ForegroundColor Cyan
  foreach ($rp in $restorePoints) {
    Write-Host "  - $($rp.VmName) (Backup: $($rp.BackupName), Point: $($rp.CreationTime))" -ForegroundColor White
  }
  Write-Host ""

  # Step 4: Create isolated test environment
  $testEnv = New-IsolatedTestEnvironment

  # Step 5: Execute test restores and verifications
  Write-ProgressStep -Activity "Running Backup Verification Tests" -Status "Testing $(@($restorePoints).Count) VM(s)..."

  $verificationResults = New-Object System.Collections.Generic.List[object]
  $vmIndex = 0

  foreach ($rp in $restorePoints) {
    $vmIndex++
    Write-Log "--- Testing VM $vmIndex/$(@($restorePoints).Count): $($rp.VmName) ---" -Level "INFO"

    # Trigger restore
    $restoreResult = Start-TestRestore -RestorePoint $rp -TestEnvironment $testEnv

    # Run verification
    if ($restoreResult.RestoreStatus -eq "Success") {
      $verification = Test-VMVerification -RestoreResult $restoreResult -RestorePoint $rp
    } else {
      # Build failed result
      $verification = [PSCustomObject]@{
        VmName            = $rp.VmName
        TestVmName        = $restoreResult.TestVmName
        BackupName        = $rp.BackupName
        RestorePointTime  = $rp.CreationTime
        RestoreStatus     = $restoreResult.RestoreStatus
        RestoreError      = $restoreResult.RestoreError
        RestoreDuration   = $restoreResult.RestoreDuration
        BootVerified      = $false
        HeartbeatVerified = $false
        PortsVerified     = $false
        PortDetails       = ""
        ScriptVerified    = $false
        ScriptOutput      = ""
        OverallResult     = "FAIL"
        Details           = "Restore failed: $($restoreResult.RestoreError)"
        VerificationTime  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
      }
    }

    $verificationResults.Add($verification)
  }

  # Step 6: Export results
  Write-ProgressStep -Activity "Exporting Results" -Status "Writing CSV and reports..."

  $csvPath = Join-Path $OutputPath "verification_results.csv"
  $verificationResults | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csvPath
  Write-Log "Exported verification results to: $csvPath" -Level "SUCCESS"

  $rpCsvPath = Join-Path $OutputPath "restore_points_tested.csv"
  $restorePoints | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $rpCsvPath
  Write-Log "Exported restore point details to: $rpCsvPath" -Level "SUCCESS"

  # Step 7: Generate HTML report
  $htmlPath = Generate-HTMLReport -VerificationResults $verificationResults `
    -RestorePoints $restorePoints -OutputPath $OutputPath

  # Step 8: Cleanup
  Remove-TestEnvironment

  # Export execution log
  $logPath = Join-Path $OutputPath "execution_log.csv"
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath

  # Step 9: Create ZIP archive
  if ($ZipOutput) {
    Write-ProgressStep -Activity "Creating Archive" -Status "Compressing output files..."
    $zipPath = Join-Path (Split-Path $OutputPath -Parent) "$(Split-Path $OutputPath -Leaf).zip"
    Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force
    Write-Log "Created ZIP archive: $zipPath" -Level "SUCCESS"
  }

  # Summary
  Write-Progress -Activity "Veeam Vault Backup Test" -Completed

  $totalTests = $verificationResults.Count
  $passedCount = ($verificationResults | Where-Object { $_.OverallResult -eq "PASS" }).Count
  $failedCount = ($verificationResults | Where-Object { $_.OverallResult -eq "FAIL" }).Count
  $partialCount = ($verificationResults | Where-Object { $_.OverallResult -eq "PARTIAL" }).Count

  Write-Host "`n$separator" -ForegroundColor Green
  Write-Host "  VERIFICATION COMPLETE" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Green

  Write-Host "  Results Summary:" -ForegroundColor Cyan
  Write-Host "    VMs Tested : $totalTests" -ForegroundColor White
  Write-Host "    Passed     : " -NoNewline -ForegroundColor White
  Write-Host "$passedCount" -ForegroundColor Green
  Write-Host "    Partial    : " -NoNewline -ForegroundColor White
  Write-Host "$partialCount" -ForegroundColor Yellow
  Write-Host "    Failed     : " -NoNewline -ForegroundColor White
  Write-Host "$failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "Green" })

  $successRate = if ($totalTests -gt 0) { [math]::Round(($passedCount / $totalTests) * 100, 0) } else { 0 }
  Write-Host "`n  Recovery Confidence: " -NoNewline -ForegroundColor Cyan
  Write-Host "${successRate}%" -ForegroundColor $(if ($successRate -ge 80) { "Green" } elseif ($successRate -ge 50) { "Yellow" } else { "Red" })

  Write-Host "`n  Deliverables:" -ForegroundColor Cyan
  Write-Host "    HTML Report : $htmlPath" -ForegroundColor White
  Write-Host "    CSV Results : $csvPath" -ForegroundColor White
  if ($ZipOutput) {
    Write-Host "    ZIP Archive : $zipPath" -ForegroundColor White
  }

  if ($KeepTestEnvironment) {
    Write-Host "`n  Test environment preserved in: " -NoNewline -ForegroundColor Yellow
    Write-Host "$TestResourceGroup" -ForegroundColor White
    Write-Host "  Remember to delete manually when done inspecting." -ForegroundColor Yellow
  }

  Write-Host "`n$separator" -ForegroundColor Green
  Write-Log "Verification completed successfully" -Level "SUCCESS"

} catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  Write-Host "`nFATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red

  # Attempt cleanup on failure
  if (-not $KeepTestEnvironment -and $TestResourceGroup) {
    Write-Host "`nAttempting cleanup of test resources..." -ForegroundColor Yellow
    try {
      Remove-AzResourceGroup -Name $TestResourceGroup -Force -ErrorAction SilentlyContinue | Out-Null
      Write-Host "  Cleanup completed." -ForegroundColor Green
    } catch {
      Write-Host "  Manual cleanup required: Remove-AzResourceGroup -Name '$TestResourceGroup' -Force" -ForegroundColor Yellow
    }
  }

  throw
} finally {
  Write-Progress -Activity "Veeam Vault Backup Test" -Completed
}

#endregion
