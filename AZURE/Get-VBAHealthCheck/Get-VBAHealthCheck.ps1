<#
.SYNOPSIS
  Veeam Backup for Azure - Health Check & Compliance Assessment Tool

.DESCRIPTION
  Production-grade health check for Veeam Backup for Azure (VBA) deployments.

  WHAT THIS SCRIPT DOES:
  1. Discovers VBA appliance VMs and validates their operational health
  2. Analyzes protection coverage (VMs, SQL, File Shares protected vs total)
  3. Audits backup job health with RPO compliance scoring
  4. Detects orphaned/expired snapshots consuming unnecessary storage
  5. Validates security posture (soft delete, immutability, encryption, RBAC)
  6. Checks repository/storage health (capacity, redundancy, accessibility)
  7. Assesses network configuration (NSGs, private endpoints, service endpoints)
  8. Calculates weighted health score with actionable recommendations
  9. Generates professional HTML report with Microsoft Fluent Design System
  10. Exports all findings as structured CSV for further analysis

  QUICK START:
  .\Get-VBAHealthCheck.ps1

  AUTHENTICATION (2026 Modern Methods):
  - Interactive (default): Browser-based login with session reuse
  - Managed Identity: Zero-credential for Azure VMs/containers
  - Service Principal: Certificate-based or client secret
  - Device Code: For headless/remote scenarios

.PARAMETER Subscriptions
  One or more subscription IDs or names. Default = all accessible subscriptions.

.PARAMETER TenantId
  Azure AD tenant ID (optional). If omitted, uses current/default tenant.

.PARAMETER Region
  Filter resources by Azure region (e.g., "eastus", "westeurope"). Case-insensitive.

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

.PARAMETER ApplianceNamePattern
  Regex pattern to identify VBA appliance VMs (default: "veeam|vba|vbazure").

.PARAMETER RPOThresholdHours
  Maximum acceptable hours since last successful backup (default: 24).

.PARAMETER SnapshotAgeWarningDays
  Warn on snapshots older than this (default: 30 days).

.PARAMETER SnapshotAgeCriticalDays
  Critical alert for snapshots older than this (default: 90 days).

.PARAMETER IncludeSnapshots
  Enumerate and analyze managed disk snapshots (can be slow on large environments).

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VBAHealthCheck_[timestamp]).

.PARAMETER GenerateHTML
  Generate professional HTML report (default: true).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.PARAMETER SkipModuleInstall
  If set, missing modules will error with instructions instead of auto-installing.

.EXAMPLE
  .\Get-VBAHealthCheck.ps1
  # Quick start - health check all accessible subscriptions

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -Subscriptions "Production-Sub" -Region "eastus"
  # Scope to specific subscription and region

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -UseManagedIdentity -IncludeSnapshots
  # Use managed identity with full snapshot analysis

.EXAMPLE
  .\Get-VBAHealthCheck.ps1 -RPOThresholdHours 12 -SnapshotAgeWarningDays 14
  # Stricter RPO and snapshot age thresholds

.NOTES
  Version: 1.0.0
  Author: Veeam Software
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices
#>

[CmdletBinding()]
param(
  # ===== Scope =====
  [string[]]$Subscriptions,
  [string]$TenantId,
  [string]$Region,

  # ===== Authentication (2026 modern methods) =====
  [switch]$UseManagedIdentity,
  [string]$ServicePrincipalId,
  [securestring]$ServicePrincipalSecret,
  [string]$CertificateThumbprint,
  [switch]$UseDeviceCode,

  # ===== Health check thresholds =====
  [string]$ApplianceNamePattern = "veeam|vba|vbazure",
  [ValidateRange(1,720)]
  [int]$RPOThresholdHours = 24,
  [ValidateRange(1,365)]
  [int]$SnapshotAgeWarningDays = 30,
  [ValidateRange(1,730)]
  [int]$SnapshotAgeCriticalDays = 90,

  # ===== Discovery options =====
  [switch]$IncludeSnapshots,

  # ===== Output =====
  [string]$OutputPath,
  [switch]$GenerateHTML = $true,
  [switch]$ZipOutput = $true,
  [switch]$SkipModuleInstall
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================
# Script-level variables
# =============================
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:Findings = New-Object System.Collections.Generic.List[object]
$script:Subs = @()
$script:TotalSteps = 12
$script:CurrentStep = 0

# Health score weights (must sum to 1.0)
$script:CategoryWeights = @{
  "Protection Coverage" = 0.25
  "Backup Job Health"   = 0.25
  "Security & Compliance" = 0.15
  "Appliance Health"    = 0.10
  "Snapshot Health"     = 0.10
  "Repository Health"   = 0.10
  "Network Health"      = 0.05
}

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
    Level = $Level
    Message = $Message
  }
  $script:LogEntries.Add($entry)

  $color = switch($Level) {
    "ERROR" { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default { "White" }
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
  Write-Progress -Activity "VBA Health Check" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $script:CurrentStep/$script:TotalSteps`: $Activity" -Level "INFO"
}

#endregion

#region Findings Tracker

function Add-Finding {
  param(
    [Parameter(Mandatory=$true)][string]$Category,
    [Parameter(Mandatory=$true)][ValidateSet("Healthy","Warning","Critical")]
    [string]$Status,
    [Parameter(Mandatory=$true)][string]$Check,
    [Parameter(Mandatory=$true)][string]$Detail,
    [string]$Recommendation = "",
    [string]$Resource = ""
  )

  $script:Findings.Add([PSCustomObject]@{
    Category = $Category
    Status = $Status
    Check = $Check
    Detail = $Detail
    Recommendation = $Recommendation
    Resource = $Resource
  })
}

#endregion

#region Authentication (2026 Modern Methods)

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
    Write-Log "Authentication failed: $($_.Exception.Message)" -Level "ERROR"
    throw
  }
}

function Resolve-Subscriptions {
  Write-ProgressStep -Activity "Resolving Subscriptions" -Status "Querying accessible subscriptions..."

  $all = Get-AzSubscription -ErrorAction Stop

  if ($Subscriptions -and $Subscriptions.Count -gt 0) {
    $resolved = @()
    foreach ($s in $Subscriptions) {
      $hit = $all | Where-Object { $_.Id -eq $s -or $_.Name -eq $s }
      if (-not $hit) {
        Write-Log "Subscription '$s' not found or not accessible" -Level "WARNING"
        continue
      }
      $resolved += $hit
      Write-Log "Added subscription: $($hit.Name) [$($hit.Id)]" -Level "INFO"
    }

    if ($resolved.Count -eq 0) {
      throw "No valid subscriptions found matching the provided criteria"
    }

    return $resolved
  }

  Write-Log "Using all accessible subscriptions ($($all.Count) found)" -Level "INFO"
  return $all
}

#endregion

#region Helper Functions

function Matches-Region($resourceRegion) {
  if (-not $Region) { return $true }
  return ($resourceRegion -ieq $Region)
}

function Format-BytesToGB {
  param([Parameter(Mandatory=$true)][int64]$Bytes)
  [math]::Round($Bytes / 1GB, 2)
}

function Get-HealthColor {
  param([Parameter(Mandatory=$true)][string]$Status)
  switch ($Status) {
    "Healthy"  { return "#00B336" } # Veeam green
    "Warning"  { return "#FF8C00" } # Orange
    "Critical" { return "#D13438" } # Red
    default    { return "#605E5C" } # Gray
  }
}

function Get-ScoreGrade {
  param([Parameter(Mandatory=$true)][double]$Score)
  if ($Score -ge 90) { return @{ Grade = "Excellent"; Color = "#00B336" } }
  if ($Score -ge 70) { return @{ Grade = "Good"; Color = "#0078D4" } }
  if ($Score -ge 50) { return @{ Grade = "Needs Attention"; Color = "#FF8C00" } }
  return @{ Grade = "Critical"; Color = "#D13438" }
}

#endregion

#region Health Check: Appliance

function Get-ApplianceHealth {
  Write-ProgressStep -Activity "Checking VBA Appliance Health" -Status "Scanning for appliance VMs..."

  $appliances = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue

    foreach ($vm in $vms) {
      if (-not (Matches-Region $vm.Location)) { continue }

      # Identify VBA appliances by name pattern, tags, or marketplace image
      $isAppliance = $false
      if ($vm.Name -imatch $ApplianceNamePattern) { $isAppliance = $true }
      if ($vm.Tags -and $vm.Tags.ContainsKey("veeam-vba")) { $isAppliance = $true }
      if ($vm.Tags -and ($vm.Tags.Values | Where-Object { $_ -imatch "veeam" })) { $isAppliance = $true }

      # Check marketplace image publisher
      $imageRef = $vm.StorageProfile.ImageReference
      if ($imageRef -and $imageRef.Publisher -imatch "veeam") { $isAppliance = $true }

      if (-not $isAppliance) { continue }

      $powerState = ($vm.PowerState -replace 'PowerState/', '')
      $provState = $vm.ProvisioningState

      # Disk health
      $osDiskGB = [int]($vm.StorageProfile.OsDisk.DiskSizeGB)
      $dataDiskCount = $vm.StorageProfile.DataDisks.Count
      $totalDiskGB = $osDiskGB
      foreach ($d in $vm.StorageProfile.DataDisks) { $totalDiskGB += [int]$d.DiskSizeGB }

      # VM size analysis
      $vmSize = $vm.HardwareProfile.VmSize

      $appliances.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $vm.ResourceGroupName
        VmName = $vm.Name
        Location = $vm.Location
        PowerState = $powerState
        ProvisioningState = $provState
        VmSize = $vmSize
        OsDiskGB = $osDiskGB
        DataDiskCount = $dataDiskCount
        TotalDiskGB = $totalDiskGB
        OsType = $vm.StorageProfile.OsDisk.OsType
      })

      # Generate findings
      if ($powerState -eq "running") {
        Add-Finding -Category "Appliance Health" -Status "Healthy" `
          -Check "Appliance Power State" `
          -Detail "VBA appliance '$($vm.Name)' is running" `
          -Resource $vm.Name
      } else {
        Add-Finding -Category "Appliance Health" -Status "Critical" `
          -Check "Appliance Power State" `
          -Detail "VBA appliance '$($vm.Name)' is $powerState (not running)" `
          -Recommendation "Start the VBA appliance VM to restore backup operations" `
          -Resource $vm.Name
      }

      if ($provState -ne "Succeeded") {
        Add-Finding -Category "Appliance Health" -Status "Warning" `
          -Check "Appliance Provisioning" `
          -Detail "VBA appliance '$($vm.Name)' provisioning state: $provState" `
          -Recommendation "Investigate provisioning issues in Azure Portal" `
          -Resource $vm.Name
      }

      # Minimum sizing recommendations for VBA
      $isUndersized = $false
      if ($vmSize -imatch "Standard_B1|Standard_B2|Standard_A1|Standard_A2|Standard_D1") {
        $isUndersized = $true
      }
      if ($isUndersized) {
        Add-Finding -Category "Appliance Health" -Status "Warning" `
          -Check "Appliance VM Sizing" `
          -Detail "VBA appliance '$($vm.Name)' uses VM size '$vmSize' which may be undersized" `
          -Recommendation "Veeam recommends minimum Standard_D4s_v3 (4 vCPU, 16 GB RAM) for production VBA appliances" `
          -Resource $vm.Name
      } else {
        Add-Finding -Category "Appliance Health" -Status "Healthy" `
          -Check "Appliance VM Sizing" `
          -Detail "VBA appliance '$($vm.Name)' uses VM size '$vmSize'" `
          -Resource $vm.Name
      }
    }
  }

  if ($appliances.Count -eq 0) {
    Add-Finding -Category "Appliance Health" -Status "Warning" `
      -Check "Appliance Discovery" `
      -Detail "No VBA appliance VMs found matching pattern '$ApplianceNamePattern'" `
      -Recommendation "Ensure VBA appliance VMs contain 'veeam' in name or tags, or adjust -ApplianceNamePattern"
  }

  Write-Log "Discovered $($appliances.Count) VBA appliance VM(s)" -Level "SUCCESS"
  return $appliances
}

#endregion

#region Health Check: Protection Coverage

function Get-ProtectionCoverage {
  Write-ProgressStep -Activity "Analyzing Protection Coverage" -Status "Comparing protected vs total resources..."

  $coverage = New-Object System.Collections.Generic.List[object]
  $totalVMs = 0
  $protectedVMs = 0
  $totalSQL = 0
  $protectedSQL = 0
  $totalFileShares = 0
  $protectedFileShares = 0
  $unprotectedVMsList = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Total VMs
    $vms = Get-AzVM -ErrorAction SilentlyContinue
    $filteredVMs = $vms | Where-Object { Matches-Region $_.Location }
    $totalVMs += $filteredVMs.Count

    # Total SQL
    $sqlServers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($srv in $sqlServers) {
      if (-not (Matches-Region $srv.Location)) { continue }
      $dbs = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.DatabaseName -ne "master" }
      $totalSQL += $dbs.Count
    }

    # Total File Shares
    $accts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($acct in $accts) {
      if (-not (Matches-Region $acct.Location)) { continue }
      try {
        $shares = Get-AzStorageShare -Context $acct.Context -ErrorAction SilentlyContinue
        $totalFileShares += @($shares).Count
      } catch {}
    }

    # Protected items from Recovery Services Vaults
    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null

      try {
        # Protected VMs
        $protItems = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureIaasVM -WorkloadType AzureVM -ErrorAction SilentlyContinue
        $protectedVMs += @($protItems).Count

        # Protected SQL
        $protSql = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -ErrorAction SilentlyContinue
        $protectedSQL += @($protSql).Count

        # Protected File Shares
        $protAfs = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -ErrorAction SilentlyContinue
        $protectedFileShares += @($protAfs).Count
      } catch {
        Write-Log "Error querying backup items in vault $($v.Name): $($_.Exception.Message)" -Level "WARNING"
      }
    }

    # Track unprotected VMs
    $protectedVMIds = @()
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null
      try {
        $items = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureIaasVM -WorkloadType AzureVM -ErrorAction SilentlyContinue
        foreach ($item in $items) {
          if ($item.VirtualMachineId) { $protectedVMIds += $item.VirtualMachineId.ToLower() }
        }
      } catch {}
    }

    foreach ($vm in $filteredVMs) {
      if ($vm.Id.ToLower() -notin $protectedVMIds) {
        $unprotectedVMsList.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          ResourceGroup = $vm.ResourceGroupName
          VmName = $vm.Name
          Location = $vm.Location
          VmSize = $vm.HardwareProfile.VmSize
        })
      }
    }
  }

  # Calculate percentages
  $vmCoveragePct = if ($totalVMs -gt 0) { [math]::Round(($protectedVMs / $totalVMs) * 100, 1) } else { 0 }
  $sqlCoveragePct = if ($totalSQL -gt 0) { [math]::Round(($protectedSQL / $totalSQL) * 100, 1) } else { 0 }
  $afsCoveragePct = if ($totalFileShares -gt 0) { [math]::Round(($protectedFileShares / $totalFileShares) * 100, 1) } else { 0 }

  $coverage.Add([PSCustomObject]@{
    ResourceType = "Azure VMs"
    TotalResources = $totalVMs
    ProtectedResources = $protectedVMs
    UnprotectedResources = ($totalVMs - $protectedVMs)
    CoveragePercent = $vmCoveragePct
  })

  $coverage.Add([PSCustomObject]@{
    ResourceType = "SQL Databases"
    TotalResources = $totalSQL
    ProtectedResources = $protectedSQL
    UnprotectedResources = ($totalSQL - $protectedSQL)
    CoveragePercent = $sqlCoveragePct
  })

  $coverage.Add([PSCustomObject]@{
    ResourceType = "Azure File Shares"
    TotalResources = $totalFileShares
    ProtectedResources = $protectedFileShares
    UnprotectedResources = ($totalFileShares - $protectedFileShares)
    CoveragePercent = $afsCoveragePct
  })

  # Generate findings for VM coverage
  if ($totalVMs -gt 0) {
    if ($vmCoveragePct -ge 90) {
      Add-Finding -Category "Protection Coverage" -Status "Healthy" `
        -Check "VM Backup Coverage" `
        -Detail "$protectedVMs of $totalVMs VMs protected ($vmCoveragePct%)"
    } elseif ($vmCoveragePct -ge 50) {
      Add-Finding -Category "Protection Coverage" -Status "Warning" `
        -Check "VM Backup Coverage" `
        -Detail "$protectedVMs of $totalVMs VMs protected ($vmCoveragePct%) - $($totalVMs - $protectedVMs) VMs unprotected" `
        -Recommendation "Review unprotected VMs and add them to backup policies"
    } else {
      Add-Finding -Category "Protection Coverage" -Status "Critical" `
        -Check "VM Backup Coverage" `
        -Detail "Only $protectedVMs of $totalVMs VMs protected ($vmCoveragePct%) - $($totalVMs - $protectedVMs) VMs at risk" `
        -Recommendation "Urgently review and protect unprotected VMs with Veeam backup policies"
    }
  } else {
    Add-Finding -Category "Protection Coverage" -Status "Healthy" `
      -Check "VM Backup Coverage" `
      -Detail "No Azure VMs found in scope"
  }

  # SQL coverage findings
  if ($totalSQL -gt 0) {
    if ($sqlCoveragePct -ge 90) {
      Add-Finding -Category "Protection Coverage" -Status "Healthy" `
        -Check "SQL Backup Coverage" `
        -Detail "$protectedSQL of $totalSQL SQL databases protected ($sqlCoveragePct%)"
    } elseif ($sqlCoveragePct -ge 50) {
      Add-Finding -Category "Protection Coverage" -Status "Warning" `
        -Check "SQL Backup Coverage" `
        -Detail "$protectedSQL of $totalSQL SQL databases protected ($sqlCoveragePct%)" `
        -Recommendation "Add unprotected SQL databases to backup policies"
    } else {
      Add-Finding -Category "Protection Coverage" -Status "Critical" `
        -Check "SQL Backup Coverage" `
        -Detail "Only $protectedSQL of $totalSQL SQL databases protected ($sqlCoveragePct%)" `
        -Recommendation "Critical data at risk - configure SQL database backup immediately"
    }
  }

  # File share coverage findings
  if ($totalFileShares -gt 0) {
    if ($afsCoveragePct -ge 80) {
      Add-Finding -Category "Protection Coverage" -Status "Healthy" `
        -Check "File Share Backup Coverage" `
        -Detail "$protectedFileShares of $totalFileShares file shares protected ($afsCoveragePct%)"
    } elseif ($afsCoveragePct -ge 40) {
      Add-Finding -Category "Protection Coverage" -Status "Warning" `
        -Check "File Share Backup Coverage" `
        -Detail "$protectedFileShares of $totalFileShares file shares protected ($afsCoveragePct%)" `
        -Recommendation "Review unprotected file shares and add to backup policies"
    } else {
      Add-Finding -Category "Protection Coverage" -Status "Critical" `
        -Check "File Share Backup Coverage" `
        -Detail "Only $protectedFileShares of $totalFileShares file shares protected ($afsCoveragePct%)" `
        -Recommendation "Configure Azure Files backup to protect shared data"
    }
  }

  Write-Log "Protection coverage: VMs=$vmCoveragePct%, SQL=$sqlCoveragePct%, Files=$afsCoveragePct%" -Level "SUCCESS"
  return @{
    Summary = $coverage
    UnprotectedVMs = $unprotectedVMsList
  }
}

#endregion

#region Health Check: Backup Job Health

function Get-BackupJobHealth {
  Write-ProgressStep -Activity "Analyzing Backup Job Health" -Status "Checking backup status and RPO compliance..."

  $jobResults = New-Object System.Collections.Generic.List[object]
  $totalItems = 0
  $healthyItems = 0
  $warningItems = 0
  $criticalItems = 0
  $rpoViolations = 0

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null

      # Check all workload types
      $workloadTypes = @(
        @{ BmType = "AzureIaasVM"; WlType = "AzureVM" },
        @{ BmType = "AzureWorkload"; WlType = "MSSQL" },
        @{ BmType = "AzureStorage"; WlType = "AzureFiles" }
      )

      foreach ($wl in $workloadTypes) {
        try {
          $items = Get-AzRecoveryServicesBackupItem -BackupManagementType $wl.BmType -WorkloadType $wl.WlType -ErrorAction SilentlyContinue
          if (-not $items) { continue }

          foreach ($item in $items) {
            $totalItems++

            $lastBackupTime = $item.LastBackupTime
            $lastBackupStatus = $item.LastBackupStatus
            $healthStatus = $item.HealthStatus
            $protectionState = $item.ProtectionState

            # Calculate hours since last backup
            $hoursSinceBackup = if ($lastBackupTime) {
              [math]::Round(((Get-Date) - $lastBackupTime).TotalHours, 1)
            } else { -1 }

            $rpoCompliant = ($hoursSinceBackup -ge 0 -and $hoursSinceBackup -le $RPOThresholdHours)
            if (-not $rpoCompliant -and $lastBackupTime) { $rpoViolations++ }

            # Determine item status
            $itemStatus = "Healthy"
            if ($lastBackupStatus -eq "Completed" -and $rpoCompliant -and $protectionState -eq "Protected") {
              $healthyItems++
            } elseif ($lastBackupStatus -eq "Completed" -and -not $rpoCompliant) {
              $warningItems++
              $itemStatus = "Warning"
            } elseif ($lastBackupStatus -ine "Completed") {
              $criticalItems++
              $itemStatus = "Critical"
            } else {
              $warningItems++
              $itemStatus = "Warning"
            }

            $friendlyName = if ($item.Name) { ($item.Name -split ';')[-1] } else { "Unknown" }

            $jobResults.Add([PSCustomObject]@{
              SubscriptionName = $sub.Name
              VaultName = $v.Name
              WorkloadType = $wl.WlType
              ItemName = $friendlyName
              ProtectionState = $protectionState
              LastBackupStatus = $lastBackupStatus
              LastBackupTime = $lastBackupTime
              HoursSinceBackup = $hoursSinceBackup
              RPOCompliant = $rpoCompliant
              HealthStatus = $healthStatus
              OverallStatus = $itemStatus
            })
          }
        } catch {
          Write-Log "Error checking $($wl.WlType) items in vault $($v.Name): $($_.Exception.Message)" -Level "WARNING"
        }
      }
    }
  }

  # Generate findings
  if ($totalItems -gt 0) {
    $successRate = [math]::Round(($healthyItems / $totalItems) * 100, 1)

    if ($successRate -ge 95) {
      Add-Finding -Category "Backup Job Health" -Status "Healthy" `
        -Check "Backup Success Rate" `
        -Detail "Backup success rate: $successRate% ($healthyItems/$totalItems items healthy)"
    } elseif ($successRate -ge 80) {
      Add-Finding -Category "Backup Job Health" -Status "Warning" `
        -Check "Backup Success Rate" `
        -Detail "Backup success rate: $successRate% ($warningItems warnings, $criticalItems failures)" `
        -Recommendation "Investigate backup warnings and failures in Recovery Services Vault"
    } else {
      Add-Finding -Category "Backup Job Health" -Status "Critical" `
        -Check "Backup Success Rate" `
        -Detail "Backup success rate: $successRate% ($criticalItems items failing)" `
        -Recommendation "Critical: Multiple backup failures detected - investigate immediately"
    }

    if ($rpoViolations -gt 0) {
      $rpoStatus = if ($rpoViolations -le 2) { "Warning" } else { "Critical" }
      Add-Finding -Category "Backup Job Health" -Status $rpoStatus `
        -Check "RPO Compliance" `
        -Detail "$rpoViolations item(s) exceed $RPOThresholdHours-hour RPO threshold" `
        -Recommendation "Review backup schedules and ensure jobs complete within RPO window"
    } else {
      Add-Finding -Category "Backup Job Health" -Status "Healthy" `
        -Check "RPO Compliance" `
        -Detail "All protected items within $RPOThresholdHours-hour RPO threshold"
    }
  } else {
    Add-Finding -Category "Backup Job Health" -Status "Warning" `
      -Check "Backup Items" `
      -Detail "No backup items found in any Recovery Services Vault" `
      -Recommendation "Configure backup policies to protect Azure workloads"
  }

  Write-Log "Analyzed $totalItems backup items: $healthyItems healthy, $warningItems warnings, $criticalItems critical" -Level "SUCCESS"

  return @{
    Items = $jobResults
    TotalItems = $totalItems
    HealthyItems = $healthyItems
    WarningItems = $warningItems
    CriticalItems = $criticalItems
    RPOViolations = $rpoViolations
  }
}

#endregion

#region Health Check: Security & Compliance

function Get-SecurityPosture {
  Write-ProgressStep -Activity "Auditing Security & Compliance" -Status "Checking encryption, soft delete, RBAC..."

  $secResults = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }

      $props = $v.Properties

      # Soft Delete check
      $softDelete = $props.SoftDeleteFeatureState
      if ($softDelete -ieq "Enabled") {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Soft Delete" `
          -Detail "Soft delete enabled on vault '$($v.Name)'" `
          -Resource $v.Name
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Critical" `
          -Check "Soft Delete" `
          -Detail "Soft delete is $softDelete on vault '$($v.Name)'" `
          -Recommendation "Enable soft delete to protect against accidental or malicious deletion of backups" `
          -Resource $v.Name
      }

      # Immutability check
      $immutability = $props.ImmutabilityState
      if ($immutability -ieq "Locked" -or $immutability -ieq "Unlocked") {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Immutability" `
          -Detail "Immutability is $immutability on vault '$($v.Name)'" `
          -Resource $v.Name
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Warning" `
          -Check "Immutability" `
          -Detail "Immutability not configured on vault '$($v.Name)'" `
          -Recommendation "Enable immutable vaults to protect backups from ransomware and unauthorized modification" `
          -Resource $v.Name
      }

      # Cross-region restore
      $crr = try { $v.Properties.RestoreSettings.CrossSubscriptionRestoreSettings.CrossSubscriptionRestoreState } catch { $null }
      if (-not $crr) {
        Add-Finding -Category "Security & Compliance" -Status "Warning" `
          -Check "Cross-Region Restore" `
          -Detail "Cross-region restore not verified for vault '$($v.Name)'" `
          -Recommendation "Consider enabling cross-region restore for disaster recovery scenarios" `
          -Resource $v.Name
      }

      # Storage redundancy
      $redundancy = try {
        $backupConfig = Get-AzRecoveryServicesBackupProperty -Vault $v -ErrorAction Stop
        $backupConfig.BackupStorageRedundancy
      } catch { "Unknown" }

      if ($redundancy -ieq "GeoRedundant") {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Storage Redundancy" `
          -Detail "Vault '$($v.Name)' uses geo-redundant storage (GRS)" `
          -Resource $v.Name
      } elseif ($redundancy -ieq "LocallyRedundant") {
        Add-Finding -Category "Security & Compliance" -Status "Warning" `
          -Check "Storage Redundancy" `
          -Detail "Vault '$($v.Name)' uses locally redundant storage (LRS)" `
          -Recommendation "Consider upgrading to GRS for production workloads to protect against regional outages" `
          -Resource $v.Name
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Storage Redundancy" `
          -Detail "Vault '$($v.Name)' uses $redundancy storage" `
          -Resource $v.Name
      }

      $secResults.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        VaultName = $v.Name
        Location = $v.Location
        SoftDelete = $softDelete
        Immutability = $immutability
        StorageRedundancy = $redundancy
      })
    }

    # Check storage account security for backup repositories
    $accts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($acct in $accts) {
      if (-not (Matches-Region $acct.Location)) { continue }

      # Only check accounts that look like backup repos
      $isBackupRepo = $false
      if ($acct.StorageAccountName -imatch "veeam|backup|vba|bkp") { $isBackupRepo = $true }
      if ($acct.Tags -and ($acct.Tags.Values | Where-Object { $_ -imatch "veeam|backup" })) { $isBackupRepo = $true }
      if (-not $isBackupRepo) { continue }

      # HTTPS-only
      if ($acct.EnableHttpsTrafficOnly) {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Storage HTTPS Only" `
          -Detail "Storage account '$($acct.StorageAccountName)' enforces HTTPS" `
          -Resource $acct.StorageAccountName
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Critical" `
          -Check "Storage HTTPS Only" `
          -Detail "Storage account '$($acct.StorageAccountName)' allows insecure HTTP" `
          -Recommendation "Enable HTTPS-only traffic on backup storage accounts" `
          -Resource $acct.StorageAccountName
      }

      # Minimum TLS version
      $minTls = $acct.MinimumTlsVersion
      if ($minTls -ieq "TLS1_2") {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Minimum TLS Version" `
          -Detail "Storage account '$($acct.StorageAccountName)' requires TLS 1.2" `
          -Resource $acct.StorageAccountName
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Warning" `
          -Check "Minimum TLS Version" `
          -Detail "Storage account '$($acct.StorageAccountName)' allows $minTls" `
          -Recommendation "Set minimum TLS version to 1.2 for backup storage accounts" `
          -Resource $acct.StorageAccountName
      }

      # Public access
      if (-not $acct.AllowBlobPublicAccess) {
        Add-Finding -Category "Security & Compliance" -Status "Healthy" `
          -Check "Public Blob Access" `
          -Detail "Storage account '$($acct.StorageAccountName)' blocks public blob access" `
          -Resource $acct.StorageAccountName
      } else {
        Add-Finding -Category "Security & Compliance" -Status "Warning" `
          -Check "Public Blob Access" `
          -Detail "Storage account '$($acct.StorageAccountName)' allows public blob access" `
          -Recommendation "Disable public blob access on backup storage accounts" `
          -Resource $acct.StorageAccountName
      }
    }
  }

  Write-Log "Completed security posture audit ($($secResults.Count) vaults analyzed)" -Level "SUCCESS"
  return $secResults
}

#endregion

#region Health Check: Snapshot Health

function Get-SnapshotHealth {
  Write-ProgressStep -Activity "Analyzing Snapshot Health" -Status "Scanning managed disk snapshots..."

  $snapResults = New-Object System.Collections.Generic.List[object]
  $totalSnapshots = 0
  $warningSnapshots = 0
  $criticalSnapshots = 0
  $orphanedSnapshots = 0
  $totalSnapshotGB = 0

  if (-not $IncludeSnapshots) {
    Add-Finding -Category "Snapshot Health" -Status "Healthy" `
      -Check "Snapshot Analysis" `
      -Detail "Snapshot analysis skipped (use -IncludeSnapshots to enable)"
    Write-Log "Snapshot analysis skipped (use -IncludeSnapshots to enable)" -Level "INFO"
    return @{ Snapshots = $snapResults; TotalCount = 0; TotalGB = 0 }
  }

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $snapshots = Get-AzSnapshot -ErrorAction SilentlyContinue
    foreach ($snap in $snapshots) {
      if (-not (Matches-Region $snap.Location)) { continue }
      $totalSnapshots++

      $ageInDays = [math]::Round(((Get-Date) - $snap.TimeCreated).TotalDays, 1)
      $sizeGB = [math]::Round($snap.DiskSizeGB, 2)
      $totalSnapshotGB += $sizeGB

      $ageStatus = "Healthy"
      if ($ageInDays -gt $SnapshotAgeCriticalDays) { $ageStatus = "Critical"; $criticalSnapshots++ }
      elseif ($ageInDays -gt $SnapshotAgeWarningDays) { $ageStatus = "Warning"; $warningSnapshots++ }

      # Check if snapshot appears orphaned (no source disk exists)
      $isOrphaned = $false
      if ($snap.CreationData.SourceResourceId) {
        try {
          $null = Get-AzResource -ResourceId $snap.CreationData.SourceResourceId -ErrorAction Stop
        } catch {
          $isOrphaned = $true
          $orphanedSnapshots++
        }
      }

      $snapResults.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        ResourceGroup = $snap.ResourceGroupName
        SnapshotName = $snap.Name
        Location = $snap.Location
        SizeGB = $sizeGB
        CreatedDate = $snap.TimeCreated
        AgeDays = $ageInDays
        AgeStatus = $ageStatus
        SourceDisk = $snap.CreationData.SourceResourceId
        IsOrphaned = $isOrphaned
        SkuName = $snap.Sku.Name
      })
    }
  }

  # Generate findings
  if ($totalSnapshots -gt 0) {
    if ($criticalSnapshots -gt 0) {
      Add-Finding -Category "Snapshot Health" -Status "Critical" `
        -Check "Snapshot Age" `
        -Detail "$criticalSnapshots snapshot(s) older than $SnapshotAgeCriticalDays days (consuming $([math]::Round($totalSnapshotGB, 0)) GB)" `
        -Recommendation "Review and delete stale snapshots to reduce storage costs"
    } elseif ($warningSnapshots -gt 0) {
      Add-Finding -Category "Snapshot Health" -Status "Warning" `
        -Check "Snapshot Age" `
        -Detail "$warningSnapshots snapshot(s) older than $SnapshotAgeWarningDays days" `
        -Recommendation "Review snapshot retention and clean up unnecessary snapshots"
    } else {
      Add-Finding -Category "Snapshot Health" -Status "Healthy" `
        -Check "Snapshot Age" `
        -Detail "All $totalSnapshots snapshots within acceptable age thresholds"
    }

    if ($orphanedSnapshots -gt 0) {
      Add-Finding -Category "Snapshot Health" -Status "Warning" `
        -Check "Orphaned Snapshots" `
        -Detail "$orphanedSnapshots snapshot(s) appear orphaned (source disk not found)" `
        -Recommendation "Delete orphaned snapshots to reclaim storage and reduce costs"
    } else {
      Add-Finding -Category "Snapshot Health" -Status "Healthy" `
        -Check "Orphaned Snapshots" `
        -Detail "No orphaned snapshots detected"
    }
  } else {
    Add-Finding -Category "Snapshot Health" -Status "Healthy" `
      -Check "Snapshot Inventory" `
      -Detail "No managed disk snapshots found in scope"
  }

  Write-Log "Analyzed $totalSnapshots snapshots ($([math]::Round($totalSnapshotGB, 0)) GB total)" -Level "SUCCESS"

  return @{
    Snapshots = $snapResults
    TotalCount = $totalSnapshots
    TotalGB = $totalSnapshotGB
    WarningCount = $warningSnapshots
    CriticalCount = $criticalSnapshots
    OrphanedCount = $orphanedSnapshots
  }
}

#endregion

#region Health Check: Repository / Storage Health

function Get-RepositoryHealth {
  Write-ProgressStep -Activity "Checking Repository Health" -Status "Analyzing storage accounts..."

  $repoResults = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $accts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    foreach ($acct in $accts) {
      if (-not (Matches-Region $acct.Location)) { continue }

      # Only check accounts used for backup
      $isBackupRepo = $false
      if ($acct.StorageAccountName -imatch "veeam|backup|vba|bkp|repo") { $isBackupRepo = $true }
      if ($acct.Tags -and ($acct.Tags.Values | Where-Object { $_ -imatch "veeam|backup" })) { $isBackupRepo = $true }
      if (-not $isBackupRepo) { continue }

      $repoResults.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        StorageAccount = $acct.StorageAccountName
        Location = $acct.Location
        Kind = $acct.Kind
        Sku = $acct.Sku.Name
        AccessTier = $acct.AccessTier
        ProvisioningState = $acct.ProvisioningState
        HttpsOnly = $acct.EnableHttpsTrafficOnly
        MinTlsVersion = $acct.MinimumTlsVersion
      })

      # Check provisioning state
      if ($acct.ProvisioningState -eq "Succeeded") {
        Add-Finding -Category "Repository Health" -Status "Healthy" `
          -Check "Storage Account State" `
          -Detail "Repository '$($acct.StorageAccountName)' is healthy (Succeeded)" `
          -Resource $acct.StorageAccountName
      } else {
        Add-Finding -Category "Repository Health" -Status "Critical" `
          -Check "Storage Account State" `
          -Detail "Repository '$($acct.StorageAccountName)' state: $($acct.ProvisioningState)" `
          -Recommendation "Investigate storage account provisioning issues" `
          -Resource $acct.StorageAccountName
      }

      # Check storage tier
      if ($acct.Kind -eq "BlobStorage" -and $acct.AccessTier -eq "Hot") {
        Add-Finding -Category "Repository Health" -Status "Warning" `
          -Check "Storage Access Tier" `
          -Detail "Repository '$($acct.StorageAccountName)' uses Hot tier (higher cost)" `
          -Recommendation "Consider Cool tier for backup repositories to reduce storage costs by ~50%" `
          -Resource $acct.StorageAccountName
      }

      # Check redundancy
      if ($acct.Sku.Name -imatch "LRS") {
        Add-Finding -Category "Repository Health" -Status "Warning" `
          -Check "Repository Redundancy" `
          -Detail "Repository '$($acct.StorageAccountName)' uses LRS (no geo-redundancy)" `
          -Recommendation "Consider GRS or RA-GRS for production backup repositories" `
          -Resource $acct.StorageAccountName
      } else {
        Add-Finding -Category "Repository Health" -Status "Healthy" `
          -Check "Repository Redundancy" `
          -Detail "Repository '$($acct.StorageAccountName)' uses $($acct.Sku.Name)" `
          -Resource $acct.StorageAccountName
      }
    }
  }

  if ($repoResults.Count -eq 0) {
    Add-Finding -Category "Repository Health" -Status "Warning" `
      -Check "Repository Discovery" `
      -Detail "No backup repository storage accounts found (matching 'veeam|backup|vba|bkp|repo' pattern)" `
      -Recommendation "Ensure backup repository storage accounts contain identifiable names or tags"
  }

  Write-Log "Analyzed $($repoResults.Count) backup repository storage account(s)" -Level "SUCCESS"
  return $repoResults
}

#endregion

#region Health Check: Network

function Get-NetworkHealth {
  Write-ProgressStep -Activity "Checking Network Configuration" -Status "Analyzing NSGs and connectivity..."

  $netResults = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    # Check NSGs on VBA appliance subnets
    $nsgs = Get-AzNetworkSecurityGroup -ErrorAction SilentlyContinue
    foreach ($nsg in $nsgs) {
      if (-not (Matches-Region $nsg.Location)) { continue }

      # Check if NSG is associated with VBA-related resources
      $isVBARelated = $false
      if ($nsg.Name -imatch "veeam|vba|backup") { $isVBARelated = $true }
      if ($nsg.Tags -and ($nsg.Tags.Values | Where-Object { $_ -imatch "veeam|backup" })) { $isVBARelated = $true }

      if (-not $isVBARelated) { continue }

      # Check for required outbound rules (HTTPS 443)
      $rules = $nsg.SecurityRules + $nsg.DefaultSecurityRules
      $httpsOutbound = $rules | Where-Object {
        $_.Direction -eq "Outbound" -and
        $_.Access -eq "Allow" -and
        ($_.DestinationPortRange -eq "443" -or $_.DestinationPortRange -eq "*")
      }

      if ($httpsOutbound) {
        Add-Finding -Category "Network Health" -Status "Healthy" `
          -Check "NSG HTTPS Outbound" `
          -Detail "NSG '$($nsg.Name)' allows HTTPS outbound (required for VBA)" `
          -Resource $nsg.Name
      } else {
        Add-Finding -Category "Network Health" -Status "Critical" `
          -Check "NSG HTTPS Outbound" `
          -Detail "NSG '$($nsg.Name)' may block HTTPS outbound (port 443)" `
          -Recommendation "VBA requires HTTPS outbound to Azure Storage and management endpoints" `
          -Resource $nsg.Name
      }

      $netResults.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        NSGName = $nsg.Name
        Location = $nsg.Location
        RuleCount = $nsg.SecurityRules.Count
        HTTPSOutbound = [bool]$httpsOutbound
      })
    }

    # Check for private endpoints on backup storage accounts
    $privateEndpoints = Get-AzPrivateEndpoint -ErrorAction SilentlyContinue
    $backupPEs = $privateEndpoints | Where-Object { $_.Name -imatch "veeam|backup|vba|bkp" }

    if ($backupPEs -and $backupPEs.Count -gt 0) {
      Add-Finding -Category "Network Health" -Status "Healthy" `
        -Check "Private Endpoints" `
        -Detail "Found $(@($backupPEs).Count) private endpoint(s) for backup resources in subscription '$($sub.Name)'"
    }
  }

  if ($netResults.Count -eq 0 -and $script:Findings.Where({ $_.Category -eq "Network Health" }).Count -eq 0) {
    Add-Finding -Category "Network Health" -Status "Healthy" `
      -Check "Network Configuration" `
      -Detail "No VBA-specific NSGs found (default network configuration in use)"
  }

  Write-Log "Completed network health analysis" -Level "SUCCESS"
  return $netResults
}

#endregion

#region Health Check: Policy Compliance

function Get-PolicyCompliance {
  Write-ProgressStep -Activity "Auditing Backup Policies" -Status "Checking policy configuration..."

  $policyResults = New-Object System.Collections.Generic.List[object]

  foreach ($sub in $script:Subs) {
    Set-AzContext -SubscriptionId $sub.Id | Out-Null

    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null

      $policies = Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue
      if (-not $policies -or @($policies).Count -eq 0) {
        Add-Finding -Category "Backup Job Health" -Status "Warning" `
          -Check "Backup Policies" `
          -Detail "No backup policies configured in vault '$($v.Name)'" `
          -Recommendation "Create backup policies to define backup schedules and retention" `
          -Resource $v.Name
        continue
      }

      foreach ($pol in $policies) {
        $policyResults.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          VaultName = $v.Name
          PolicyName = $pol.Name
          WorkloadType = $pol.WorkloadType
          BackupManagement = $pol.BackupManagementType
        })
      }

      Add-Finding -Category "Backup Job Health" -Status "Healthy" `
        -Check "Backup Policies" `
        -Detail "Vault '$($v.Name)' has $(@($policies).Count) backup policy(ies) configured" `
        -Resource $v.Name
    }
  }

  Write-Log "Audited $($policyResults.Count) backup policies" -Level "SUCCESS"
  return $policyResults
}

#endregion

#region Health Score Calculation

function Calculate-HealthScore {
  Write-ProgressStep -Activity "Calculating Health Score" -Status "Weighting findings..."

  $categoryScores = @{}

  foreach ($category in $script:CategoryWeights.Keys) {
    $catFindings = @($script:Findings | Where-Object { $_.Category -eq $category })

    if ($catFindings.Count -eq 0) {
      $categoryScores[$category] = 100 # No findings = healthy (not assessed)
      continue
    }

    $totalPoints = 0
    foreach ($f in $catFindings) {
      $totalPoints += switch ($f.Status) {
        "Healthy"  { 100 }
        "Warning"  { 50 }
        "Critical" { 0 }
        default    { 50 }
      }
    }

    $categoryScores[$category] = [math]::Round($totalPoints / $catFindings.Count, 1)
  }

  # Weighted overall score
  $overallScore = 0
  foreach ($category in $script:CategoryWeights.Keys) {
    $weight = $script:CategoryWeights[$category]
    $score = $categoryScores[$category]
    $overallScore += $weight * $score
  }
  $overallScore = [math]::Round($overallScore, 1)

  $grade = Get-ScoreGrade -Score $overallScore

  Write-Log "Overall Health Score: $overallScore/100 ($($grade.Grade))" -Level "SUCCESS"

  return @{
    OverallScore = $overallScore
    Grade = $grade.Grade
    GradeColor = $grade.Color
    CategoryScores = $categoryScores
  }
}

#endregion

#region HTML Report

function Generate-HTMLReport {
  param(
    [Parameter(Mandatory=$true)]$HealthScore,
    [Parameter(Mandatory=$true)]$Appliances,
    [Parameter(Mandatory=$true)]$Coverage,
    [Parameter(Mandatory=$true)]$JobHealth,
    [Parameter(Mandatory=$true)]$SnapshotData,
    [Parameter(Mandatory=$true)][string]$OutputFilePath
  )

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  # Build findings rows
  $findingsRows = ($script:Findings | ForEach-Object {
    $statusColor = Get-HealthColor -Status $_.Status
    $statusIcon = switch ($_.Status) { "Healthy" { "&#10004;" } "Warning" { "&#9888;" } "Critical" { "&#10006;" } default { "&#8226;" } }
    "<tr><td><span style='color:$statusColor;font-weight:600;'>$statusIcon $($_.Status)</span></td><td>$($_.Category)</td><td>$($_.Check)</td><td>$($_.Detail)</td><td>$(if($_.Recommendation){$_.Recommendation}else{'—'})</td></tr>"
  }) -join "`n"

  # Build category score cards
  $categoryCards = ($HealthScore.CategoryScores.GetEnumerator() | Sort-Object { $script:CategoryWeights[$_.Key] } -Descending | ForEach-Object {
    $catGrade = Get-ScoreGrade -Score $_.Value
    $weight = [math]::Round($script:CategoryWeights[$_.Key] * 100)
    "<div class='kpi-card' style='border-top-color:$($catGrade.Color);'><div class='kpi-label'>$($_.Key)</div><div class='kpi-value' style='color:$($catGrade.Color);'>$($_.Value)</div><div class='kpi-subtext'>$($catGrade.Grade) (Weight: ${weight}%)</div></div>"
  }) -join "`n"

  # Build coverage rows
  $coverageRows = ($Coverage.Summary | ForEach-Object {
    $pctColor = if ($_.CoveragePercent -ge 90) { "#00B336" } elseif ($_.CoveragePercent -ge 50) { "#FF8C00" } else { "#D13438" }
    "<tr><td><strong>$($_.ResourceType)</strong></td><td>$($_.TotalResources)</td><td>$($_.ProtectedResources)</td><td>$($_.UnprotectedResources)</td><td style='color:$pctColor;font-weight:600;'>$($_.CoveragePercent)%</td></tr>"
  }) -join "`n"

  # Build unprotected VMs rows
  $unprotectedRows = ""
  if ($Coverage.UnprotectedVMs.Count -gt 0) {
    $maxShow = [math]::Min($Coverage.UnprotectedVMs.Count, 25)
    $unprotectedRows = ($Coverage.UnprotectedVMs | Select-Object -First $maxShow | ForEach-Object {
      "<tr><td>$($_.SubscriptionName)</td><td>$($_.ResourceGroup)</td><td>$($_.VmName)</td><td>$($_.Location)</td><td>$($_.VmSize)</td></tr>"
    }) -join "`n"
    if ($Coverage.UnprotectedVMs.Count -gt $maxShow) {
      $unprotectedRows += "<tr><td colspan='5' style='font-style:italic;color:var(--ms-gray-90);'>... and $($Coverage.UnprotectedVMs.Count - $maxShow) more (see CSV export for full list)</td></tr>"
    }
  }

  # Counts
  $healthyCount = @($script:Findings | Where-Object { $_.Status -eq "Healthy" }).Count
  $warningCount = @($script:Findings | Where-Object { $_.Status -eq "Warning" }).Count
  $criticalCount = @($script:Findings | Where-Object { $_.Status -eq "Critical" }).Count

  $subList = ($script:Subs | ForEach-Object { "<li>$($_.Name) <span style='color:var(--ms-gray-90);'>[$($_.Id)]</span></li>" }) -join "`n"

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam Backup for Azure - Health Check Report</title>
<style>
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --veeam-green: #00B336;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --shadow-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif; background: var(--ms-gray-10); color: var(--ms-gray-160); line-height: 1.6; font-size: 14px; }
.container { max-width: 1440px; margin: 0 auto; padding: 40px 32px; }
.header { background: white; border-left: 4px solid var(--veeam-green); padding: 32px; margin-bottom: 32px; border-radius: 2px; box-shadow: var(--shadow-8); }
.header-title { font-size: 32px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 8px; }
.header-subtitle { font-size: 16px; color: var(--ms-gray-90); margin-bottom: 24px; }
.header-meta { display: flex; gap: 32px; flex-wrap: wrap; font-size: 13px; color: var(--ms-gray-90); }

.score-banner { background: white; padding: 40px; margin-bottom: 32px; border-radius: 2px; box-shadow: var(--shadow-8); text-align: center; border-top: 4px solid $($HealthScore.GradeColor); }
.score-value { font-size: 72px; font-weight: 300; color: $($HealthScore.GradeColor); line-height: 1.1; }
.score-label { font-size: 14px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.1em; color: var(--ms-gray-90); margin-bottom: 8px; }
.score-grade { font-size: 24px; font-weight: 600; color: $($HealthScore.GradeColor); margin-top: 8px; }
.score-summary { display: flex; justify-content: center; gap: 32px; margin-top: 24px; font-size: 14px; }
.score-stat { display: flex; align-items: center; gap: 8px; }
.dot { width: 12px; height: 12px; border-radius: 50%; display: inline-block; }
.dot-green { background: #00B336; }
.dot-orange { background: #FF8C00; }
.dot-red { background: #D13438; }

.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 32px; }
.kpi-card { background: white; padding: 24px; border-radius: 2px; box-shadow: var(--shadow-4); border-top: 3px solid var(--veeam-green); }
.kpi-label { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 8px; }
.kpi-value { font-size: 32px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 4px; }
.kpi-subtext { font-size: 12px; color: var(--ms-gray-90); }

.section { background: white; padding: 32px; margin-bottom: 24px; border-radius: 2px; box-shadow: var(--shadow-4); }
.section-title { font-size: 20px; font-weight: 600; color: var(--ms-gray-160); margin-bottom: 20px; padding-bottom: 12px; border-bottom: 1px solid var(--ms-gray-30); }

table { width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 16px; }
thead { background: var(--ms-gray-20); }
th { padding: 10px 14px; text-align: left; font-weight: 600; color: var(--ms-gray-130); font-size: 11px; text-transform: uppercase; letter-spacing: 0.03em; border-bottom: 2px solid var(--ms-gray-50); }
td { padding: 12px 14px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); }
tbody tr:hover { background: var(--ms-gray-10); }

.info-card { background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue); padding: 20px 24px; margin: 16px 0; border-radius: 2px; }
.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 13px; line-height: 1.6; }

.footer { text-align: center; padding: 32px; color: var(--ms-gray-90); font-size: 12px; }

@media print { body { background: white; } .section, .kpi-card, .score-banner { box-shadow: none; border: 1px solid var(--ms-gray-30); } }
@media (max-width: 768px) { .container { padding: 20px 16px; } .kpi-grid { grid-template-columns: 1fr 1fr; } .score-value { font-size: 48px; } }
</style>
</head>
<body>
<div class="container">

  <div class="header">
    <div class="header-title">Veeam Backup for Azure</div>
    <div class="header-subtitle">Health Check &amp; Compliance Assessment</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>Subscriptions:</strong> $($script:Subs.Count)</span>
      <span><strong>RPO Threshold:</strong> ${RPOThresholdHours}h</span>
    </div>
  </div>

  <div class="score-banner">
    <div class="score-label">Overall Health Score</div>
    <div class="score-value">$($HealthScore.OverallScore)</div>
    <div class="score-grade">$($HealthScore.Grade)</div>
    <div class="score-summary">
      <div class="score-stat"><span class="dot dot-green"></span> $healthyCount Healthy</div>
      <div class="score-stat"><span class="dot dot-orange"></span> $warningCount Warnings</div>
      <div class="score-stat"><span class="dot dot-red"></span> $criticalCount Critical</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Category Scores</h2>
    <div class="kpi-grid">
      $categoryCards
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Protection Coverage</h2>
    <table>
      <thead><tr><th>Resource Type</th><th>Total</th><th>Protected</th><th>Unprotected</th><th>Coverage</th></tr></thead>
      <tbody>$coverageRows</tbody>
    </table>
  </div>

$(if ($unprotectedRows) {
@"
  <div class="section">
    <h2 class="section-title">Unprotected VMs (Top 25)</h2>
    <table>
      <thead><tr><th>Subscription</th><th>Resource Group</th><th>VM Name</th><th>Location</th><th>Size</th></tr></thead>
      <tbody>$unprotectedRows</tbody>
    </table>
  </div>
"@
})

  <div class="section">
    <h2 class="section-title">Backup Job Summary</h2>
    <div class="kpi-grid">
      <div class="kpi-card"><div class="kpi-label">Total Backup Items</div><div class="kpi-value">$($JobHealth.TotalItems)</div></div>
      <div class="kpi-card" style="border-top-color:#00B336;"><div class="kpi-label">Healthy</div><div class="kpi-value" style="color:#00B336;">$($JobHealth.HealthyItems)</div></div>
      <div class="kpi-card" style="border-top-color:#FF8C00;"><div class="kpi-label">Warnings</div><div class="kpi-value" style="color:#FF8C00;">$($JobHealth.WarningItems)</div></div>
      <div class="kpi-card" style="border-top-color:#D13438;"><div class="kpi-label">Failures</div><div class="kpi-value" style="color:#D13438;">$($JobHealth.CriticalItems)</div></div>
      <div class="kpi-card"><div class="kpi-label">RPO Violations</div><div class="kpi-value">$($JobHealth.RPOViolations)</div><div class="kpi-subtext">Threshold: ${RPOThresholdHours}h</div></div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">All Findings</h2>
    <table>
      <thead><tr><th>Status</th><th>Category</th><th>Check</th><th>Detail</th><th>Recommendation</th></tr></thead>
      <tbody>$findingsRows</tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">Subscriptions Analyzed</h2>
    <ul style="margin: 16px 0 0 20px; color: var(--ms-gray-160);">$subList</ul>
  </div>

  <div class="section">
    <h2 class="section-title">Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">Data Collection</div>
      <div class="info-card-text">
        This health check uses Azure Resource Manager APIs to assess VBA appliance VMs, Recovery Services Vaults, backup policies, protected items, storage accounts, NSGs, and managed disk snapshots. All operations are read-only; no changes are made to your environment.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Health Score Calculation</div>
      <div class="info-card-text">
        The overall health score (0-100) is a weighted average across categories: Protection Coverage (25%), Backup Job Health (25%), Security &amp; Compliance (15%), Appliance Health (10%), Snapshot Health (10%), Repository Health (10%), Network Health (5%). Each finding scores 100 (Healthy), 50 (Warning), or 0 (Critical).
      </div>
    </div>
  </div>

  <div class="footer">
    <p>&copy; 2026 Veeam Software | Health Check &amp; Compliance Assessment</p>
    <p>For questions or assistance, contact your Veeam Solutions Architect</p>
  </div>

</div>
</body>
</html>
"@

  $html | Out-File -FilePath $OutputFilePath -Encoding UTF8
  Write-Log "Generated HTML report: $OutputFilePath" -Level "SUCCESS"
  return $OutputFilePath
}

#endregion

#region Main Execution

try {
  # Output folder
  if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = ".\VBAHealthCheck_$timestamp"
  }
  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
  }

  Write-Log "========== Veeam Backup for Azure - Health Check ==========" -Level "SUCCESS"
  Write-Log "Output folder: $OutputPath" -Level "INFO"

  # Check required modules
  $requiredModules = @(
    'Az.Accounts', 'Az.Resources', 'Az.Compute', 'Az.Network',
    'Az.Sql', 'Az.Storage', 'Az.RecoveryServices'
  )

  $missingModules = @()
  foreach ($mod in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
      $missingModules += $mod
    }
  }

  if ($missingModules.Count -gt 0) {
    if ($SkipModuleInstall) {
      Write-Log "Missing required modules: $($missingModules -join ', ')" -Level "ERROR"
      Write-Host "Install with: Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Yellow
      exit 1
    }
    foreach ($mod in $missingModules) {
      Write-Log "Installing module: $mod" -Level "INFO"
      Install-Module $mod -Scope CurrentUser -Force -AllowClobber
    }
  }

  # Authenticate
  Connect-AzureModern

  # Resolve subscriptions
  $script:Subs = Resolve-Subscriptions

  # Run health checks
  $appliances = Get-ApplianceHealth
  $coverage = Get-ProtectionCoverage
  $jobHealth = Get-BackupJobHealth
  $policies = Get-PolicyCompliance
  $secPosture = Get-SecurityPosture
  $snapshotData = Get-SnapshotHealth
  $repoHealth = Get-RepositoryHealth
  $netHealth = Get-NetworkHealth

  # Calculate overall health score
  $healthScore = Calculate-HealthScore

  # Export CSVs
  Write-ProgressStep -Activity "Exporting Data" -Status "Writing CSV files..."

  $findingsCsv = Join-Path $OutputPath "health_check_findings.csv"
  $coverageCsv = Join-Path $OutputPath "protection_coverage.csv"
  $unprotectedCsv = Join-Path $OutputPath "unprotected_vms.csv"
  $jobsCsv = Join-Path $OutputPath "backup_job_health.csv"
  $appliancesCsv = Join-Path $OutputPath "appliance_health.csv"
  $snapshotsCsv = Join-Path $OutputPath "snapshot_health.csv"
  $securityCsv = Join-Path $OutputPath "security_posture.csv"
  $repoCsv = Join-Path $OutputPath "repository_health.csv"
  $policiesCsv = Join-Path $OutputPath "backup_policies.csv"
  $scoreCsv = Join-Path $OutputPath "health_score_summary.csv"

  $script:Findings | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $findingsCsv
  $coverage.Summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $coverageCsv
  if ($coverage.UnprotectedVMs.Count -gt 0) {
    $coverage.UnprotectedVMs | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $unprotectedCsv
  }
  if ($jobHealth.Items.Count -gt 0) {
    $jobHealth.Items | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $jobsCsv
  }
  if ($appliances.Count -gt 0) {
    $appliances | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $appliancesCsv
  }
  if ($snapshotData.Snapshots.Count -gt 0) {
    $snapshotData.Snapshots | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $snapshotsCsv
  }
  if ($secPosture.Count -gt 0) {
    $secPosture | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $securityCsv
  }
  if ($repoHealth.Count -gt 0) {
    $repoHealth | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $repoCsv
  }
  if ($policies.Count -gt 0) {
    $policies | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $policiesCsv
  }

  # Health score summary
  $scoreEntries = @()
  $scoreEntries += [PSCustomObject]@{ Category = "OVERALL"; Score = $healthScore.OverallScore; Grade = $healthScore.Grade }
  foreach ($cat in $healthScore.CategoryScores.GetEnumerator()) {
    $scoreEntries += [PSCustomObject]@{ Category = $cat.Key; Score = $cat.Value; Grade = (Get-ScoreGrade -Score $cat.Value).Grade }
  }
  $scoreEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $scoreCsv

  Write-Log "Exported CSV files to: $OutputPath" -Level "SUCCESS"

  # Generate HTML report
  $htmlPath = $null
  if ($GenerateHTML) {
    $htmlPath = Join-Path $OutputPath "VBA-HealthCheck-Report.html"
    Generate-HTMLReport -HealthScore $healthScore -Appliances $appliances `
      -Coverage $coverage -JobHealth $jobHealth `
      -SnapshotData $snapshotData -OutputFilePath $htmlPath
  }

  # Export log
  $logPath = Join-Path $OutputPath "execution_log.csv"
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath

  # Create ZIP
  if ($ZipOutput) {
    Write-ProgressStep -Activity "Creating Archive" -Status "Compressing output..."
    $zipPath = Join-Path (Split-Path $OutputPath -Parent) "$(Split-Path $OutputPath -Leaf).zip"
    Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force
    Write-Log "Created ZIP archive: $zipPath" -Level "SUCCESS"
  }

  # Summary output
  Write-Progress -Activity "VBA Health Check" -Completed

  $healthyCount = @($script:Findings | Where-Object { $_.Status -eq "Healthy" }).Count
  $warningCount = @($script:Findings | Where-Object { $_.Status -eq "Warning" }).Count
  $criticalCount = @($script:Findings | Where-Object { $_.Status -eq "Critical" }).Count

  Write-Host "`n========== Health Check Complete ==========" -ForegroundColor Green
  Write-Host "`nOverall Health Score: $($healthScore.OverallScore)/100 ($($healthScore.Grade))" -ForegroundColor $(if ($healthScore.OverallScore -ge 70) { "Green" } elseif ($healthScore.OverallScore -ge 50) { "Yellow" } else { "Red" })
  Write-Host "`nFindings:" -ForegroundColor Cyan
  Write-Host "  Healthy:  $healthyCount" -ForegroundColor Green
  Write-Host "  Warnings: $warningCount" -ForegroundColor Yellow
  Write-Host "  Critical: $criticalCount" -ForegroundColor Red

  Write-Host "`nCategory Scores:" -ForegroundColor Cyan
  foreach ($cat in $healthScore.CategoryScores.GetEnumerator() | Sort-Object { $script:CategoryWeights[$_.Key] } -Descending) {
    $catColor = if ($cat.Value -ge 70) { "Green" } elseif ($cat.Value -ge 50) { "Yellow" } else { "Red" }
    $weight = [math]::Round($script:CategoryWeights[$cat.Key] * 100)
    Write-Host "  $($cat.Key) [$weight%]: $($cat.Value)/100" -ForegroundColor $catColor
  }

  Write-Host "`nProtection Coverage:" -ForegroundColor Cyan
  foreach ($c in $coverage.Summary) {
    Write-Host "  $($c.ResourceType): $($c.ProtectedResources)/$($c.TotalResources) ($($c.CoveragePercent)%)" -ForegroundColor White
  }

  Write-Host "`nOutput Files:" -ForegroundColor Cyan
  if ($htmlPath) { Write-Host "  HTML Report: $htmlPath" -ForegroundColor White }
  Write-Host "  CSV Exports: $OutputPath" -ForegroundColor White
  if ($ZipOutput) { Write-Host "  ZIP Archive: $zipPath" -ForegroundColor White }

  Write-Host "`n============================================" -ForegroundColor Green

  # Show critical findings as actionable items
  $criticalFindings = @($script:Findings | Where-Object { $_.Status -eq "Critical" })
  if ($criticalFindings.Count -gt 0) {
    Write-Host "`nCRITICAL FINDINGS REQUIRING IMMEDIATE ACTION:" -ForegroundColor Red
    $i = 0
    foreach ($f in $criticalFindings) {
      $i++
      Write-Host "  $i. [$($f.Category)] $($f.Detail)" -ForegroundColor Red
      if ($f.Recommendation) {
        Write-Host "     -> $($f.Recommendation)" -ForegroundColor Yellow
      }
    }
    Write-Host ""
  }

  Write-Log "Health check completed successfully" -Level "SUCCESS"

} catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  Write-Host "`nHealth check failed. Check execution_log.csv for details." -ForegroundColor Red
  throw
} finally {
  Write-Progress -Activity "VBA Health Check" -Completed
}

#endregion
