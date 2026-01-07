<#
.SYNOPSIS
  Veeam Backup for Azure - Presales Discovery & Sizing Tool

.DESCRIPTION
  Professional assessment tool for Veeam Backup for Azure deployments.
  
  WHAT THIS SCRIPT DOES:
  1. Inventories Azure VMs, SQL Databases, Managed Instances, Storage Accounts
  2. Analyzes current Azure Backup configuration (vaults, policies, protected items)
  3. Calculates Veeam sizing recommendations (snapshot storage, repository capacity)
  4. Generates professional HTML report with Microsoft Fluent Design System
  5. Provides executive summary with actionable recommendations
  
  QUICK START:
  .\Get-VeeamAzureSizing.ps1
  
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

.PARAMETER TagFilter
  Filter VMs by tags. Example: @{ "Environment"="Production"; "Owner"="IT" }
  Only VMs matching ALL tag pairs will be included.

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

.PARAMETER CalculateBlobSizes
  Enumerate all blobs to calculate container sizes. Warning: Can be slow on large storage accounts.

.PARAMETER IncludeAzureBackupPricing
  Query Azure Retail Prices API for Azure Backup cost estimates.

.PARAMETER SnapshotRetentionDays
  Snapshot retention for Veeam sizing (default: 14 days).

.PARAMETER RepositoryOverhead
  Repository overhead multiplier for Veeam sizing (default: 1.2 = 20% overhead).

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VeeamAzureSizing_[timestamp]).

.PARAMETER GenerateHTML
  Generate professional HTML report (default: true).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1
  # Quick start - analyzes all accessible subscriptions

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -Subscriptions "Production-Sub" -Region "eastus"
  # Filter by subscription and region

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -UseManagedIdentity
  # Use managed identity (Azure VM/container)

.EXAMPLE
  .\Get-VeeamAzureSizing.ps1 -TagFilter @{"Environment"="Prod"} -SnapshotRetentionDays 30
  # Filter by tags and customize Veeam sizing parameters

.NOTES
  Version: 2.0.0
  Author: Veeam Software
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules: Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices
#>

[CmdletBinding()]
param(
  # Scope
  [string[]]$Subscriptions,
  [string]$TenantId,
  [string]$Region,
  [hashtable]$TagFilter,
  
  # Authentication (2026 modern methods)
  [switch]$UseManagedIdentity,
  [string]$ServicePrincipalId,
  [securestring]$ServicePrincipalSecret,
  [string]$CertificateThumbprint,
  [switch]$UseDeviceCode,
  
  # Discovery options
  [switch]$CalculateBlobSizes,
  [switch]$IncludeAzureBackupPricing,
  
  # Veeam sizing parameters
  [ValidateRange(1,365)]
  [int]$SnapshotRetentionDays = 14,
  [ValidateRange(1.0,3.0)]
  [double]$RepositoryOverhead = 1.2,
  
  # Output
  [string]$OutputPath,
  [switch]$GenerateHTML = $true,
  [switch]$ZipOutput = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script-level variables
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:Subs = @()
$script:TotalSteps = 10
$script:CurrentStep = 0

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
  Write-Progress -Activity "Veeam Azure Sizing" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $script:CurrentStep/$script:TotalSteps`: $Activity" -Level "INFO"
}

#endregion

#region Authentication (2026 Modern Methods)

function Test-AzSession {
  try {
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) { return $false }
    
    # Verify context is usable
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
  
  # Check for existing valid session
  if (Test-AzSession) {
    return
  }
  
  # Modern authentication hierarchy
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

function Matches-Tags($tags) {
  if (-not $TagFilter -or $TagFilter.Keys.Count -eq 0) { return $true }
  if (-not $tags) { return $false }
  
  foreach ($k in $TagFilter.Keys) {
    if (-not $tags.ContainsKey($k)) { return $false }
    if ($TagFilter[$k] -ne $null -and ($tags[$k] -ne $TagFilter[$k])) { return $false }
  }
  return $true
}

function Flatten-Tags($tags) {
  if (-not $tags) { return "" }
  ($tags.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';'
}

function Get-PublicIpFromId {
  param([string]$ResourceId)
  if (-not $ResourceId) { return $null }
  
  try {
    $r = Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction Stop
    return $r.Properties.ipAddress
  } catch {
    return $null
  }
}

function Get-ResourceById {
  param([string]$ResourceId)
  if (-not $ResourceId) { return $null }
  
  try {
    return Get-AzResource -ResourceId $ResourceId -ExpandProperties -ErrorAction Stop
  } catch {
    return $null
  }
}

function Format-BytesToGB {
  param([Parameter(Mandatory=$true)][int64]$Bytes)
  [math]::Round($Bytes / 1GB, 2)
}

function Format-BytesToTB {
  param([Parameter(Mandatory=$true)][int64]$Bytes)
  [math]::Round($Bytes / 1TB, 3)
}

#endregion

#region VM Inventory

function Get-VM-Inventory {
  Write-ProgressStep -Activity "Discovering Azure VMs" -Status "Scanning subscriptions..."
  
  $results = New-Object System.Collections.Generic.List[object]
  $nicsCache = @{}
  $pipsCache = @{}
  $vmCount = 0
  
  foreach ($sub in $script:Subs) {
    Write-Log "Scanning VMs in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    $vms = Get-AzVM -Status -ErrorAction SilentlyContinue
    
    foreach ($vm in $vms) {
      if (-not (Matches-Region $vm.Location)) { continue }
      if (-not (Matches-Tags $vm.Tags)) { continue }
      
      $vmCount++
      if ($vmCount % 10 -eq 0) {
        Write-Progress -Activity "Veeam Azure Sizing" -Status "Processed $vmCount VMs..." -PercentComplete (($script:CurrentStep / $script:TotalSteps) * 100)
      }
      
      # Network details
      $nicIds = @()
      $privateIps = @()
      $publicIps = @()
      
      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        $nicId = $nicRef.Id
        $nicIds += $nicId
        
        if (-not $nicsCache.ContainsKey($nicId)) {
          try {
            $nicsCache[$nicId] = Get-AzNetworkInterface -ResourceId $nicId -ErrorAction Stop
          } catch {
            Write-Log "Failed to retrieve NIC for VM $($vm.Name): $($_.Exception.Message)" -Level "WARNING"
            continue
          }
        }
        
        $nic = $nicsCache[$nicId]
        if (-not $nic) { continue }
        
        foreach ($ipc in $nic.IpConfigurations) {
          if ($ipc.PrivateIpAddress) { $privateIps += $ipc.PrivateIpAddress }
          
          if ($ipc.PublicIpAddress -and $ipc.PublicIpAddress.Id) {
            $pipId = $ipc.PublicIpAddress.Id
            if (-not $pipsCache.ContainsKey($pipId)) {
              $pipsCache[$pipId] = Get-PublicIpFromId -ResourceId $pipId
            }
            if ($pipsCache[$pipId]) { $publicIps += $pipsCache[$pipId] }
          }
        }
      }
      
      # Disk analysis
      $osDiskGB = [int]($vm.StorageProfile.OsDisk.DiskSizeGB)
      $osDiskType = $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType
      
      $dataDisks = @()
      $dataSizeGB = 0
      foreach ($d in $vm.StorageProfile.DataDisks) {
        $size = [int]$d.DiskSizeGB
        $dataSizeGB += $size
        $dataDisks += "LUN$($d.Lun):$($size)GB:$($d.ManagedDisk.StorageAccountType)"
      }
      
      $totalProvGB = $osDiskGB + $dataSizeGB
      
      # Veeam Sizing Calculations
      $snapshotStorageGB = [math]::Ceiling($totalProvGB * ($SnapshotRetentionDays / 30.0) * 0.1) # Assume 10% daily change
      $repositoryGB = [math]::Ceiling($totalProvGB * $RepositoryOverhead)
      
      $results.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $vm.ResourceGroupName
        VmName = $vm.Name
        VmId = $vm.Id
        Location = $vm.Location
        Zone = ($vm.Zones -join ',')
        PowerState = ($vm.PowerState -replace 'PowerState/', '')
        OsType = $vm.StorageProfile.OsDisk.OsType
        VmSize = $vm.HardwareProfile.VmSize
        PrivateIPs = ($privateIps -join ', ')
        PublicIPs = ($publicIps -join ', ')
        Tags = (Flatten-Tags $vm.Tags)
        OsDiskType = $osDiskType
        OsDiskSizeGB = $osDiskGB
        DataDiskCount = $vm.StorageProfile.DataDisks.Count
        DataDiskSummary = ($dataDisks -join '; ')
        DataDiskTotalGB = $dataSizeGB
        TotalProvisionedGB = $totalProvGB
        VeeamSnapshotStorageGB = $snapshotStorageGB
        VeeamRepositoryGB = $repositoryGB
      })
    }
  }
  
  Write-Log "Discovered $vmCount Azure VMs" -Level "SUCCESS"
  return $results
}

#endregion

#region SQL Inventory

function Get-Sql-Inventory {
  Write-ProgressStep -Activity "Discovering Azure SQL" -Status "Scanning databases and managed instances..."
  
  $dbs = New-Object System.Collections.Generic.List[object]
  $mis = New-Object System.Collections.Generic.List[object]
  
  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Azure SQL in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    # SQL Databases
    $servers = Get-AzSqlServer -ErrorAction SilentlyContinue
    foreach ($srv in $servers) {
      if (-not (Matches-Region $srv.Location)) { continue }
      
      $databases = Get-AzSqlDatabase -ServerName $srv.ServerName -ResourceGroupName $srv.ResourceGroupName -ErrorAction SilentlyContinue |
        Where-Object { $_.DatabaseName -ne "master" }
      
      foreach ($db in $databases) {
        $maxSizeGB = [math]::Round($db.MaxSizeBytes / 1GB, 2)
        
        # Veeam sizing for SQL (assume 20% daily change)
        $veeamRepoGB = [math]::Ceiling($maxSizeGB * 1.3) # 30% overhead for compression/retention
        
        $dbs.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          ResourceGroup = $srv.ResourceGroupName
          ServerName = $srv.ServerName
          DatabaseName = $db.DatabaseName
          Location = $db.Location
          Edition = $db.Edition
          ServiceObjective = $db.CurrentServiceObjectiveName
          MaxSizeGB = $maxSizeGB
          ZoneRedundant = $db.ZoneRedundant
          BackupStorageRedundancy = $db.BackupStorageRedundancy
          VeeamRepositoryGB = $veeamRepoGB
        })
      }
    }
    
    # Managed Instances
    $managed = Get-AzSqlInstance -ErrorAction SilentlyContinue
    foreach ($mi in $managed) {
      if (-not (Matches-Region $mi.Location)) { continue }
      
      $storageGB = $mi.StorageSizeInGB
      $veeamRepoGB = [math]::Ceiling($storageGB * 1.3)
      
      $mis.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $mi.ResourceGroupName
        ManagedInstance = $mi.Name
        Location = $mi.Location
        VCores = $mi.VCores
        StorageSizeGB = $storageGB
        LicenseType = $mi.LicenseType
        VeeamRepositoryGB = $veeamRepoGB
      })
    }
  }
  
  Write-Log "Discovered $($dbs.Count) SQL Databases and $($mis.Count) Managed Instances" -Level "SUCCESS"
  
  return @{
    Databases = $dbs
    ManagedInstances = $mis
  }
}

#endregion

#region Storage Inventory

function Get-Storage-Inventory {
  Write-ProgressStep -Activity "Discovering Azure Storage" -Status "Scanning Files and Blob containers..."
  
  $files = New-Object System.Collections.Generic.List[object]
  $blobs = New-Object System.Collections.Generic.List[object]
  
  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Storage in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    $accts = Get-AzStorageAccount -ErrorAction SilentlyContinue
    
    foreach ($acct in $accts) {
      if (-not (Matches-Region $acct.Location)) { continue }
      
      $ctx = $acct.Context
      
      # Azure Files
      try {
        $shares = Get-AzStorageShare -Context $ctx -ErrorAction SilentlyContinue
        foreach ($sh in $shares) {
          $usageBytes = $null
          try {
            $rmShare = Get-AzRmStorageShare -ResourceGroupName $acct.ResourceGroupName -StorageAccountName $acct.StorageAccountName -Name $sh.Name -Expand "stats" -ErrorAction Stop
            $usageBytes = $rmShare.ShareUsageBytes
          } catch {}
          
          $usageGiB = if ($usageBytes) { [math]::Round($usageBytes / 1GB, 2) } else { $null }
          
          $files.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId = $sub.Id
            ResourceGroup = $acct.ResourceGroupName
            StorageAccount = $acct.StorageAccountName
            Location = $acct.Location
            ShareName = $sh.Name
            QuotaGiB = $sh.Quota
            UsageGiB = $usageGiB
          })
        }
      } catch {
        Write-Log "Failed to enumerate Azure Files in $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
      }
      
      # Azure Blob
      try {
        $containers = Get-AzStorageContainer -Context $ctx -ErrorAction SilentlyContinue
        foreach ($c in $containers) {
          $sizeBytes = $null
          
          if ($CalculateBlobSizes) {
            $sizeBytes = 0
            $token = $null
            do {
              $page = Get-AzStorageBlob -Container $c.Name -Context $ctx -MaxCount 5000 -ContinuationToken $token -ErrorAction SilentlyContinue
              foreach ($b in $page) {
                $sizeBytes += [int64]($b.Length)
              }
              $token = $page.ContinuationToken
            } while ($token)
          }
          
          $sizeGiB = if ($sizeBytes) { [math]::Round($sizeBytes / 1GB, 2) } else { $null }
          
          $blobs.Add([PSCustomObject]@{
            SubscriptionName = $sub.Name
            SubscriptionId = $sub.Id
            ResourceGroup = $acct.ResourceGroupName
            StorageAccount = $acct.StorageAccountName
            Location = $acct.Location
            Container = $c.Name
            PublicAccess = $c.PublicAccess
            EstimatedGiB = $sizeGiB
          })
        }
      } catch {
        Write-Log "Failed to enumerate Blob containers in $($acct.StorageAccountName): $($_.Exception.Message)" -Level "WARNING"
      }
    }
  }
  
  Write-Log "Discovered $($files.Count) Azure File Shares and $($blobs.Count) Blob containers" -Level "SUCCESS"
  
  return @{
    Files = $files
    Blobs = $blobs
  }
}

#endregion

#region Azure Backup Inventory

function Get-AzureBackup-Inventory {
  Write-ProgressStep -Activity "Analyzing Azure Backup" -Status "Scanning Recovery Services Vaults..."
  
  $vaultsOut = New-Object System.Collections.Generic.List[object]
  $policiesOut = New-Object System.Collections.Generic.List[object]
  
  foreach ($sub in $script:Subs) {
    Write-Log "Scanning Azure Backup in subscription: $($sub.Name)" -Level "INFO"
    Set-AzContext -SubscriptionId $sub.Id | Out-Null
    
    $vaults = Get-AzRecoveryServicesVault -ErrorAction SilentlyContinue
    
    foreach ($v in $vaults) {
      if (-not (Matches-Region $v.Location)) { continue }
      
      Set-AzRecoveryServicesVaultContext -Vault $v | Out-Null
      
      # Count protected items
      $items = Get-AzRecoveryServicesBackupItem -ErrorAction SilentlyContinue
      $vmCount = ($items | Where-Object { $_.WorkloadType -eq "AzureVM" }).Count
      $sqlCount = ($items | Where-Object { $_.WorkloadType -like "SQL*" }).Count
      $afsCount = ($items | Where-Object { $_.WorkloadType -like "*AzureFileShare*" }).Count
      
      $vaultsOut.Add([PSCustomObject]@{
        SubscriptionName = $sub.Name
        SubscriptionId = $sub.Id
        ResourceGroup = $v.ResourceGroupName
        VaultName = $v.Name
        Location = $v.Location
        SoftDeleteState = $v.Properties.SoftDeleteFeatureState
        Immutability = $v.Properties.ImmutabilityState
        ProtectedVMs = $vmCount
        ProtectedSQL = $sqlCount
        ProtectedFileShares = $afsCount
      })
      
      # Policies
      $pols = Get-AzRecoveryServicesBackupProtectionPolicy -ErrorAction SilentlyContinue
      foreach ($p in $pols) {
        $policiesOut.Add([PSCustomObject]@{
          SubscriptionName = $sub.Name
          SubscriptionId = $sub.Id
          VaultName = $v.Name
          PolicyName = $p.Name
          WorkloadType = $p.WorkloadType
          BackupManagement = $p.BackupManagementType
        })
      }
    }
  }
  
  Write-Log "Discovered $($vaultsOut.Count) Recovery Services Vaults with $($policiesOut.Count) policies" -Level "SUCCESS"
  
  return @{
    Vaults = $vaultsOut
    Policies = $policiesOut
  }
}

#endregion

#region Veeam Sizing Calculations

function Calculate-VeeamSizing {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory
  )
  
  Write-ProgressStep -Activity "Calculating Veeam Sizing" -Status "Analyzing capacity requirements..."
  
  # VM totals
  $totalVMs = $VmInventory.Count
  $totalVMStorage = ($VmInventory | Measure-Object -Property TotalProvisionedGB -Sum).Sum
  $totalSnapshotStorage = ($VmInventory | Measure-Object -Property VeeamSnapshotStorageGB -Sum).Sum
  $totalVMRepoStorage = ($VmInventory | Measure-Object -Property VeeamRepositoryGB -Sum).Sum
  
  # SQL totals
  $totalSQLDatabases = $SqlInventory.Databases.Count
  $totalSQLMIs = $SqlInventory.ManagedInstances.Count
  $totalSQLStorage = ($SqlInventory.Databases | Measure-Object -Property MaxSizeGB -Sum).Sum +
                     ($SqlInventory.ManagedInstances | Measure-Object -Property StorageSizeGB -Sum).Sum
  $totalSQLRepoStorage = ($SqlInventory.Databases | Measure-Object -Property VeeamRepositoryGB -Sum).Sum +
                         ($SqlInventory.ManagedInstances | Measure-Object -Property VeeamRepositoryGB -Sum).Sum
  
  # Combined totals
  $totalSourceStorage = $totalVMStorage + $totalSQLStorage
  $totalRepoStorage = $totalVMRepoStorage + $totalSQLRepoStorage
  
  # Recommendations
  $recommendations = @()
  
  if ($totalVMs -gt 0) {
    $recommendations += "Deploy Veeam Backup for Azure to protect $totalVMs Azure VMs"
    $recommendations += "Estimated snapshot storage required: $([math]::Ceiling($totalSnapshotStorage)) GB"
    $recommendations += "Estimated repository capacity required: $([math]::Ceiling($totalRepoStorage)) GB"
  }
  
  if ($totalSQLDatabases -gt 0 -or $totalSQLMIs -gt 0) {
    $recommendations += "Consider Veeam Backup for Azure SQL for $totalSQLDatabases databases and $totalSQLMIs managed instances"
  }
  
  return [PSCustomObject]@{
    TotalVMs = $totalVMs
    TotalVMStorageGB = [math]::Round($totalVMStorage, 2)
    TotalSnapshotStorageGB = [math]::Ceiling($totalSnapshotStorage)
    TotalVMRepositoryGB = [math]::Ceiling($totalVMRepoStorage)
    TotalSQLDatabases = $totalSQLDatabases
    TotalSQLManagedInstances = $totalSQLMIs
    TotalSQLStorageGB = [math]::Round($totalSQLStorage, 2)
    TotalSQLRepositoryGB = [math]::Ceiling($totalSQLRepoStorage)
    TotalSourceStorageGB = [math]::Round($totalSourceStorage, 2)
    TotalRepositoryGB = [math]::Ceiling($totalRepoStorage)
    Recommendations = $recommendations
  }
}

#endregion

#region HTML Report Generation

function Generate-HTMLReport {
  param(
    [Parameter(Mandatory=$true)]$VmInventory,
    [Parameter(Mandatory=$true)]$SqlInventory,
    [Parameter(Mandatory=$true)]$StorageInventory,
    [Parameter(Mandatory=$true)]$AzureBackupInventory,
    [Parameter(Mandatory=$true)]$VeeamSizing,
    [Parameter(Mandatory=$true)][string]$OutputPath
  )
  
  Write-ProgressStep -Activity "Generating HTML Report" -Status "Creating professional report..."
  
  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"
  
  # Build subscription summary
  $subList = ($script:Subs | ForEach-Object { "<li>$($_.Name) [$($_.Id)]</li>" }) -join "`n"
  
  # Build VM summary by location
  $vmsByLocation = $VmInventory | Group-Object Location | Sort-Object Count -Descending
  $locationRows = ($vmsByLocation | ForEach-Object {
    "<tr><td>$($_.Name)</td><td>$($_.Count)</td><td>$([math]::Round(($_.Group | Measure-Object -Property TotalProvisionedGB -Sum).Sum, 0)) GB</td></tr>"
  }) -join "`n"
  
  # Build recommendations
  $recommendationItems = ($VeeamSizing.Recommendations | ForEach-Object { "<li class='recommendation-item'>$_</li>" }) -join "`n"
  
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam Backup for Azure - Sizing Assessment</title>
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
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
}

.container {
  max-width: 1440px;
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
  margin-bottom: 8px;
}

.header-subtitle {
  font-size: 16px;
  color: var(--ms-gray-90);
  margin-bottom: 24px;
}

.header-meta {
  display: flex;
  gap: 32px;
  flex-wrap: wrap;
  font-size: 13px;
  color: var(--ms-gray-90);
}

.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
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

thead {
  background: var(--ms-gray-20);
}

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

tbody tr:hover {
  background: var(--ms-gray-10);
}

.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--ms-blue);
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

.recommendation-item {
  padding: 12px 0;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

.recommendation-item:last-child {
  border-bottom: none;
}

.highlight {
  color: var(--veeam-green);
  font-weight: 600;
}

.footer {
  text-align: center;
  padding: 32px;
  color: var(--ms-gray-90);
  font-size: 13px;
}

@media print {
  body { background: white; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); }
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="header-title">Veeam Backup for Azure</div>
    <div class="header-subtitle">Professional Sizing Assessment</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>Subscriptions:</strong> $($script:Subs.Count)</span>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">Azure VMs</div>
      <div class="kpi-value">$($VeeamSizing.TotalVMs)</div>
      <div class="kpi-subtext">$([math]::Round($VeeamSizing.TotalVMStorageGB, 0)) GB provisioned</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">SQL Databases</div>
      <div class="kpi-value">$($VeeamSizing.TotalSQLDatabases)</div>
      <div class="kpi-subtext">$([math]::Round($VeeamSizing.TotalSQLStorageGB, 0)) GB total</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Total Source Data</div>
      <div class="kpi-value">$([math]::Round($VeeamSizing.TotalSourceStorageGB / 1024, 2)) TB</div>
      <div class="kpi-subtext">Across all workloads</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Veeam Repository</div>
      <div class="kpi-value">$([math]::Round($VeeamSizing.TotalRepositoryGB / 1024, 2)) TB</div>
      <div class="kpi-subtext">Recommended capacity</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">📊 Executive Summary</h2>
    <div class="info-card">
      <div class="info-card-title">Assessment Scope</div>
      <div class="info-card-text">
        This assessment analyzed <strong>$($script:Subs.Count) Azure subscription(s)</strong> and discovered:
        <ul style="margin: 12px 0 0 20px;">
          <li><strong>$($VeeamSizing.TotalVMs) Azure VMs</strong> with $([math]::Round($VeeamSizing.TotalVMStorageGB, 0)) GB provisioned storage</li>
          <li><strong>$($VeeamSizing.TotalSQLDatabases) SQL Databases</strong> and <strong>$($VeeamSizing.TotalSQLManagedInstances) Managed Instances</strong></li>
          <li><strong>$($StorageInventory.Files.Count) Azure File Shares</strong> and <strong>$($StorageInventory.Blobs.Count) Blob containers</strong></li>
          <li><strong>$($AzureBackupInventory.Vaults.Count) Recovery Services Vaults</strong> with $($AzureBackupInventory.Policies.Count) backup policies</li>
        </ul>
      </div>
    </div>
    
    <div class="info-card">
      <div class="info-card-title">🎯 Veeam Sizing Recommendations</div>
      <div class="info-card-text">
        <ul style="margin: 12px 0 0 20px;">
          $recommendationItems
        </ul>
      </div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">💻 Virtual Machines by Region</h2>
    <table>
      <thead>
        <tr>
          <th>Region</th>
          <th>VM Count</th>
          <th>Total Storage</th>
        </tr>
      </thead>
      <tbody>
        $locationRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">🔧 Veeam Backup for Azure Sizing</h2>
    <table>
      <thead>
        <tr>
          <th>Component</th>
          <th>Value</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td><strong>Snapshot Storage</strong></td>
          <td class="highlight">$([math]::Ceiling($VeeamSizing.TotalSnapshotStorageGB)) GB</td>
          <td>Based on $SnapshotRetentionDays days retention with 10% daily change</td>
        </tr>
        <tr>
          <td><strong>Repository Capacity</strong></td>
          <td class="highlight">$([math]::Ceiling($VeeamSizing.TotalRepositoryGB)) GB</td>
          <td>Includes $([math]::Round(($RepositoryOverhead - 1) * 100, 0))% overhead for compression and retention</td>
        </tr>
        <tr>
          <td><strong>Snapshot Storage (TB)</strong></td>
          <td class="highlight">$([math]::Round($VeeamSizing.TotalSnapshotStorageGB / 1024, 2)) TB</td>
          <td>Recommended Azure Managed Disk capacity</td>
        </tr>
        <tr>
          <td><strong>Repository Storage (TB)</strong></td>
          <td class="highlight">$([math]::Round($VeeamSizing.TotalRepositoryGB / 1024, 2)) TB</td>
          <td>Recommended Azure Blob Storage capacity</td>
        </tr>
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">📋 Subscriptions Analyzed</h2>
    <ul style="margin: 16px 0 0 20px; color: var(--ms-gray-160);">
      $subList
    </ul>
  </div>

  <div class="section">
    <h2 class="section-title">ℹ️ Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">Data Collection</div>
      <div class="info-card-text">
        This assessment uses Azure Resource Manager APIs to inventory VMs, SQL databases, storage accounts, and existing Azure Backup configuration. All data is read-only and no changes are made to your environment.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">Veeam Sizing Calculations</div>
      <div class="info-card-text">
        <strong>Snapshot Storage:</strong> Calculated based on provisioned VM disk capacity × (retention days / 30) × 10% daily change rate.<br><br>
        <strong>Repository Capacity:</strong> Calculated as source data × $RepositoryOverhead overhead multiplier to account for compression efficiency and retention requirements.<br><br>
        <strong>Note:</strong> These are sizing recommendations for planning purposes. Actual storage consumption will vary based on your backup policies, data change rates, and compression ratios.
      </div>
    </div>
  </div>

  <div class="footer">
    <p>© 2026 Veeam Software | Professional Services Sizing Assessment</p>
    <p>For questions or assistance, contact your Veeam Solutions Architect</p>
  </div>
</div>
</body>
</html>
"@
  
  $htmlPath = Join-Path $OutputPath "Veeam-Azure-Sizing-Report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8
  
  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}

#endregion

#region Main Execution

try {
  # Determine output folder
  if (-not $OutputPath) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $OutputPath = ".\VeeamAzureSizing_$timestamp"
  }
  
  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
  }
  
  Write-Log "========== Veeam Backup for Azure - Sizing Assessment ==========" -Level "SUCCESS"
  Write-Log "Output folder: $OutputPath" -Level "INFO"
  
  # Check for required modules
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
    Write-Log "Missing required Azure PowerShell modules:" -Level "ERROR"
    foreach ($mod in $missingModules) {
      Write-Log "  - $mod" -Level "ERROR"
    }
    Write-Host ""
    Write-Host "Install all missing modules with:" -ForegroundColor Yellow
    Write-Host "  Install-Module $($missingModules -join ', ') -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host ""
    exit 1
  }
  
  # Authenticate
  Connect-AzureModern
  
  # Resolve subscriptions
  $script:Subs = Resolve-Subscriptions
  
  # Discovery
  $vmInv = Get-VM-Inventory
  $sqlInv = Get-Sql-Inventory
  $stInv = Get-Storage-Inventory
  $abInv = Get-AzureBackup-Inventory
  
  # Veeam sizing calculations
  $veeamSizing = Calculate-VeeamSizing -VmInventory $vmInv -SqlInventory $sqlInv
  
  # Export CSVs
  Write-ProgressStep -Activity "Exporting Data" -Status "Writing CSV files..."
  
  $vmCsv = Join-Path $OutputPath "azure_vms.csv"
  $sqlDbCsv = Join-Path $OutputPath "azure_sql_databases.csv"
  $sqlMiCsv = Join-Path $OutputPath "azure_sql_managed_instances.csv"
  $filesCsv = Join-Path $OutputPath "azure_files.csv"
  $blobCsv = Join-Path $OutputPath "azure_blob.csv"
  $vaultsCsv = Join-Path $OutputPath "azure_backup_vaults.csv"
  $polCsv = Join-Path $OutputPath "azure_backup_policies.csv"
  $sizingCsv = Join-Path $OutputPath "veeam_sizing_summary.csv"
  
  $vmInv | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $vmCsv
  $sqlInv.Databases | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sqlDbCsv
  $sqlInv.ManagedInstances | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sqlMiCsv
  $stInv.Files | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $filesCsv
  $stInv.Blobs | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $blobCsv
  $abInv.Vaults | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $vaultsCsv
  $abInv.Policies | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $polCsv
  $veeamSizing | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $sizingCsv
  
  Write-Log "Exported CSV files to: $OutputPath" -Level "SUCCESS"
  
  # Generate HTML report
  if ($GenerateHTML) {
    $htmlPath = Generate-HTMLReport -VmInventory $vmInv -SqlInventory $sqlInv `
      -StorageInventory $stInv -AzureBackupInventory $abInv `
      -VeeamSizing $veeamSizing -OutputPath $OutputPath
  }
  
  # Export log
  $logPath = Join-Path $OutputPath "execution_log.csv"
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath
  
  # Create ZIP archive
  if ($ZipOutput) {
    Write-ProgressStep -Activity "Creating Archive" -Status "Compressing output files..."
    $zipPath = Join-Path (Split-Path $OutputPath -Parent) "$(Split-Path $OutputPath -Leaf).zip"
    Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force
    Write-Log "Created ZIP archive: $zipPath" -Level "SUCCESS"
  }
  
  # Summary
  Write-Progress -Activity "Veeam Azure Sizing" -Completed
  
  Write-Host "`n========== Assessment Complete ==========" -ForegroundColor Green
  Write-Host "`nDiscovered Resources:" -ForegroundColor Cyan
  Write-Host "  • Azure VMs: $($veeamSizing.TotalVMs)" -ForegroundColor White
  Write-Host "  • SQL Databases: $($veeamSizing.TotalSQLDatabases)" -ForegroundColor White
  Write-Host "  • SQL Managed Instances: $($veeamSizing.TotalSQLManagedInstances)" -ForegroundColor White
  Write-Host "  • Azure File Shares: $($stInv.Files.Count)" -ForegroundColor White
  Write-Host "  • Blob Containers: $($stInv.Blobs.Count)" -ForegroundColor White
  Write-Host "  • Recovery Services Vaults: $($abInv.Vaults.Count)" -ForegroundColor White
  
  Write-Host "`nVeeam Sizing Recommendations:" -ForegroundColor Cyan
  Write-Host "  • Snapshot Storage: $([math]::Ceiling($veeamSizing.TotalSnapshotStorageGB)) GB ($([math]::Round($veeamSizing.TotalSnapshotStorageGB / 1024, 2)) TB)" -ForegroundColor Green
  Write-Host "  • Repository Capacity: $([math]::Ceiling($veeamSizing.TotalRepositoryGB)) GB ($([math]::Round($veeamSizing.TotalRepositoryGB / 1024, 2)) TB)" -ForegroundColor Green
  
  Write-Host "`nOutput Files:" -ForegroundColor Cyan
  Write-Host "  • HTML Report: $htmlPath" -ForegroundColor White
  Write-Host "  • CSV Exports: $OutputPath" -ForegroundColor White
  if ($ZipOutput) {
    Write-Host "  • ZIP Archive: $zipPath" -ForegroundColor White
  }
  
  Write-Host "`n=========================================" -ForegroundColor Green
  Write-Log "Assessment completed successfully" -Level "SUCCESS"
  
} catch {
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  Write-Host "`n❌ Assessment failed. Check execution_log.csv for details." -ForegroundColor Red
  throw
} finally {
  Write-Progress -Activity "Veeam Azure Sizing" -Completed
}

#endregion
