<#
.SYNOPSIS
  Azure Blob to Veeam Vault Migration - Pre-Flight Assessment & Guided Migration Tool

.DESCRIPTION
  Guides Veeam customers through migrating backup data from Azure Blob Storage to Veeam Vault.

  This tool simplifies what is traditionally a complex, manual process by:
  1. Validating all prerequisites (VBR version, PowerShell modules, connectivity)
  2. Discovering existing Azure Blob SOBR extents and backup data
  3. Assessing data volume and estimating migration time
  4. Guiding gateway server deployment (Linux proxy in Azure)
  5. Validating network connectivity between all components
  6. Preparing and optionally executing the evacuate (data move) operation
  7. Generating a professional HTML migration plan report

  WHY MIGRATE TO VEEAM VAULT:
  - Predictable pricing: $14/TB/month all-inclusive (zero egress, zero API ops)
  - Built-in immutability for ransomware protection
  - No Azure reservation lock-in (month-to-month flexibility)
  - Native VBR integration with no gateway management overhead
  - Multi-cloud flexibility (AWS, Azure, GCP)

  MIGRATION WORKFLOW:
  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
  │  1. Pre-Flight   │───▶│  2. Gateway      │───▶│  3. Evacuate     │
  │  Assessment      │    │  Deployment      │    │  (Data Move)     │
  └─────────────────┘    └─────────────────┘    └─────────────────┘

  Run with -AssessOnly for a read-only assessment report (no changes made).

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP. Default: localhost.

.PARAMETER VBRPort
  VBR REST API or console port. Default: 9392.

.PARAMETER VBRCredential
  PSCredential for VBR authentication. If omitted, uses current Windows identity.

.PARAMETER AssessOnly
  Run pre-flight assessment only. No changes are made to the environment.
  Generates a migration readiness report with all findings.

.PARAMETER TargetVaultName
  Name of the Veeam Vault repository to migrate data to.
  Required when not using -AssessOnly.

.PARAMETER GatewayVmSize
  Azure VM size for the Linux gateway server. Default: Standard_D4s_v5.

.PARAMETER GatewayRegion
  Azure region for the gateway VM. Should match your Azure Blob storage region.

.PARAMETER GatewayResourceGroup
  Azure resource group for the gateway VM. Created if it doesn't exist.

.PARAMETER GatewayVNetName
  Existing Azure VNet name for the gateway VM. Required for gateway deployment.

.PARAMETER GatewaySubnetName
  Subnet within the VNet for the gateway VM. Default: default.

.PARAMETER SkipGatewayDeploy
  Skip automatic gateway deployment. Use if you already have a gateway or want to deploy manually.

.PARAMETER ExecuteEvacuate
  Execute the evacuate (data move) operation after all validations pass.
  Without this flag, the script generates the migration plan but does not move data.

.PARAMETER MaxConcurrentTasks
  Maximum concurrent data transfer tasks during evacuation. Default: 4.

.PARAMETER OutputPath
  Custom output folder for reports and logs.

.EXAMPLE
  .\Start-AzureBlobToVaultMigration.ps1 -AssessOnly
  # Read-only assessment of current environment and migration readiness

.EXAMPLE
  .\Start-AzureBlobToVaultMigration.ps1 -AssessOnly -VBRServer "vbr01.contoso.com"
  # Assess a remote VBR server

.EXAMPLE
  .\Start-AzureBlobToVaultMigration.ps1 -TargetVaultName "VeeamVault-01" -GatewayRegion "eastus" -GatewayResourceGroup "rg-veeam-migration" -GatewayVNetName "vnet-backup"
  # Full guided migration with gateway deployment

.EXAMPLE
  .\Start-AzureBlobToVaultMigration.ps1 -TargetVaultName "VeeamVault-01" -SkipGatewayDeploy -ExecuteEvacuate
  # Execute migration using an existing gateway (skip deployment)

.NOTES
  Author: Veeam Sales Engineering
  Version: 1.0.0
  Date: 2026-02-15
  Requires: PowerShell 5.1+, Veeam Backup & Replication v12.3+
  Modules: Veeam.Backup.PowerShell (VBR snap-in), Az.Accounts, Az.Compute, Az.Network, Az.Storage
#>

[CmdletBinding(DefaultParameterSetName = "Assess")]
param(
  # VBR Connection
  [Parameter(Mandatory=$false)]
  [string]$VBRServer = "localhost",

  [Parameter(Mandatory=$false)]
  [int]$VBRPort = 9392,

  [Parameter(Mandatory=$false)]
  [PSCredential]$VBRCredential,

  # Mode
  [Parameter(ParameterSetName="Assess")]
  [switch]$AssessOnly,

  # Migration Target
  [Parameter(ParameterSetName="Migrate", Mandatory=$true)]
  [string]$TargetVaultName,

  # Gateway Configuration
  [Parameter(Mandatory=$false)]
  [string]$GatewayVmSize = "Standard_D4s_v5",

  [Parameter(ParameterSetName="Migrate", Mandatory=$false)]
  [string]$GatewayRegion,

  [Parameter(ParameterSetName="Migrate", Mandatory=$false)]
  [string]$GatewayResourceGroup,

  [Parameter(ParameterSetName="Migrate", Mandatory=$false)]
  [string]$GatewayVNetName,

  [Parameter(ParameterSetName="Migrate", Mandatory=$false)]
  [string]$GatewaySubnetName = "default",

  [Parameter(Mandatory=$false)]
  [switch]$SkipGatewayDeploy,

  # Execution
  [Parameter(ParameterSetName="Migrate", Mandatory=$false)]
  [switch]$ExecuteEvacuate,

  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 16)]
  [int]$MaxConcurrentTasks = 4,

  # Output
  [Parameter(Mandatory=$false)]
  [string]$OutputPath = ".\VaultMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:CheckResults = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 8
$script:CurrentStep = 0

# ===== Constants =====
$MIN_VBR_VERSION = [version]"12.3.0"
$VEEAM_VAULT_PRICE_PER_TB = 14.00
$GATEWAY_MIN_CPU = 4
$GATEWAY_MIN_RAM_GB = 8
$GATEWAY_MIN_DISK_GB = 100
$ESTIMATED_THROUGHPUT_GBPS = 0.5  # Conservative estimate: 500 Mbps per task

# Create output directory
$parentDirectory = Split-Path -Path $OutputPath -Parent
if (-not $parentDirectory) {
  $parentDirectory = (Get-Location).ProviderPath
}

if (-not (Test-Path -LiteralPath $parentDirectory)) {
  throw "The output path '$OutputPath' is invalid because the parent directory '$parentDirectory' does not exist. Please specify a valid, existing directory or run the script from a writable location."
}

# Verify that the parent directory is writable by creating a temporary file
try {
  $testFile = Join-Path -Path $parentDirectory -ChildPath ([System.IO.Path]::GetRandomFileName())
  New-Item -ItemType File -Path $testFile -Force -ErrorAction Stop | Out-Null
  Remove-Item -Path $testFile -Force -ErrorAction Stop
} catch {
  throw "The parent directory '$parentDirectory' for output path '$OutputPath' is not writable. Please specify a writable directory (for example, `$env:TEMP) and try again."
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$LogFile = Join-Path $OutputPath "migration_log.csv"

# ===== Helper Functions =====
#region Helpers

function Write-Log {
  param(
    [string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
    [string]$Level = "INFO"
  )

  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level     = $Level
    Message   = $Message
  }

  $script:LogEntries.Add($entry)
  $entry | Export-Csv -Path $LogFile -Append -NoTypeInformation

  $color = switch ($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default   { "White" }
  }

  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-Step {
  param(
    [string]$Title,
    [string]$Status = "Checking..."
  )

  $script:CurrentStep++
  $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
  Write-Progress -Activity "Azure Blob to Veeam Vault Migration" -Status "$Title - $Status" -PercentComplete $pct
  Write-Log "STEP $($script:CurrentStep)/$($script:TotalSteps): $Title" -Level "INFO"
}

function Add-CheckResult {
  param(
    [string]$Category,
    [string]$Check,
    [ValidateSet("PASS", "FAIL", "WARNING", "INFO", "SKIP")]
    [string]$Status,
    [string]$Detail,
    [string]$Remediation = ""
  )

  $script:CheckResults.Add([PSCustomObject]@{
    Category    = $Category
    Check       = $Check
    Status      = $Status
    Detail      = $Detail
    Remediation = $Remediation
  })

  $color = switch ($Status) {
    "PASS"    { "Green" }
    "FAIL"    { "Red" }
    "WARNING" { "Yellow" }
    "SKIP"    { "DarkGray" }
    default   { "Cyan" }
  }

  $icon = switch ($Status) {
    "PASS"    { "[PASS]" }
    "FAIL"    { "[FAIL]" }
    "WARNING" { "[WARN]" }
    "SKIP"    { "[SKIP]" }
    default   { "[INFO]" }
  }

  Write-Host "  $icon " -NoNewline -ForegroundColor $color
  Write-Host "$Check" -NoNewline -ForegroundColor White
  Write-Host " - $Detail" -ForegroundColor Gray
}

function Format-SizeGB {
  param([double]$SizeBytes)
  [math]::Round($SizeBytes / 1GB, 2)
}

function Format-SizeTB {
  param([double]$SizeBytes)
  [math]::Round($SizeBytes / 1TB, 3)
}

function Format-Duration {
  param([double]$Hours)
  if ($Hours -lt 1) {
    return "$([math]::Round($Hours * 60, 0)) minutes"
  } elseif ($Hours -lt 24) {
    return "$([math]::Round($Hours, 1)) hours"
  } else {
    $days = [math]::Floor($Hours / 24)
    $remainingHours = [math]::Round($Hours % 24, 0)
    return "$days days, $remainingHours hours"
  }
}

#endregion

# ===== Pre-Flight Check Functions =====
#region Pre-Flight Checks

function Test-VBRPrerequisites {
  Write-Step -Title "VBR Prerequisites" -Status "Validating Veeam Backup & Replication..."

  Write-Host ""
  Write-Host "  Veeam Backup & Replication Checks:" -ForegroundColor Cyan
  Write-Host "  -----------------------------------" -ForegroundColor DarkGray

  # Check VBR PowerShell snap-in
  $snapinLoaded = $false
  try {
    if (-not (Get-PSSnapin -Name VeeamPSSnapIn -ErrorAction SilentlyContinue)) {
      Add-PSSnapin VeeamPSSnapIn -ErrorAction Stop
    }
    $snapinLoaded = $true
    Add-CheckResult -Category "VBR" -Check "PowerShell Snap-in" -Status "PASS" `
      -Detail "VeeamPSSnapIn loaded successfully"
  } catch {
    # Try the PowerShell module approach (VBR v12+)
    try {
      Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
      $snapinLoaded = $true
      Add-CheckResult -Category "VBR" -Check "PowerShell Module" -Status "PASS" `
        -Detail "Veeam.Backup.PowerShell module loaded"
    } catch {
      Add-CheckResult -Category "VBR" -Check "PowerShell Snap-in" -Status "FAIL" `
        -Detail "Cannot load Veeam PowerShell components" `
        -Remediation "Install VBR Console on this machine, or run from the VBR server directly"
      return $false
    }
  }

  # Connect to VBR
  try {
    $connectParams = @{ Server = $VBRServer; ErrorAction = "Stop" }
    if ($VBRCredential) { $connectParams.Credential = $VBRCredential }

    Connect-VBRServer @connectParams
    Add-CheckResult -Category "VBR" -Check "VBR Connection" -Status "PASS" `
      -Detail "Connected to VBR server: $VBRServer"
  } catch {
    Add-CheckResult -Category "VBR" -Check "VBR Connection" -Status "FAIL" `
      -Detail "Cannot connect to VBR at $VBRServer - $($_.Exception.Message)" `
      -Remediation "Verify VBR server is running and accessible. Check firewall rules for port $VBRPort."
    return $false
  }

  # Check VBR version
  try {
    $vbrVersion = [version](Get-VBRServerSession).ServerVersion
    if ($vbrVersion -ge $MIN_VBR_VERSION) {
      Add-CheckResult -Category "VBR" -Check "VBR Version" -Status "PASS" `
        -Detail "Version $vbrVersion (minimum: $MIN_VBR_VERSION)"
    } else {
      Add-CheckResult -Category "VBR" -Check "VBR Version" -Status "FAIL" `
        -Detail "Version $vbrVersion is below minimum $MIN_VBR_VERSION" `
        -Remediation "Upgrade VBR to v12.3 or later to support Veeam Vault integration"
      return $false
    }
  } catch {
    Add-CheckResult -Category "VBR" -Check "VBR Version" -Status "WARNING" `
      -Detail "Could not determine VBR version. Proceeding with caution."
  }

  # Check license
  try {
    $license = Get-VBRInstalledLicense
    $licenseType = $license.Type
    $licenseExpiry = $license.ExpirationDate

    if ($licenseExpiry -and $licenseExpiry -lt (Get-Date).AddDays(30)) {
      Add-CheckResult -Category "VBR" -Check "License Status" -Status "WARNING" `
        -Detail "License ($licenseType) expires $($licenseExpiry.ToString('yyyy-MM-dd'))" `
        -Remediation "Renew license before migration to avoid interruption"
    } else {
      Add-CheckResult -Category "VBR" -Check "License Status" -Status "PASS" `
        -Detail "License type: $licenseType"
    }
  } catch {
    Add-CheckResult -Category "VBR" -Check "License Status" -Status "WARNING" `
      -Detail "Could not verify license status"
  }

  return $true
}

function Get-AzureBlobRepositories {
  Write-Step -Title "Azure Blob Discovery" -Status "Scanning for Azure Blob SOBR extents..."

  Write-Host ""
  Write-Host "  Azure Blob Repository Discovery:" -ForegroundColor Cyan
  Write-Host "  ---------------------------------" -ForegroundColor DarkGray

  $blobExtents = @()

  try {
    # Get all Scale-Out Backup Repositories
    $sobrs = Get-VBRBackupRepository -ScaleOut -ErrorAction Stop

    if ($sobrs.Count -eq 0) {
      Add-CheckResult -Category "Discovery" -Check "SOBR Repositories" -Status "WARNING" `
        -Detail "No Scale-Out Backup Repositories found" `
        -Remediation "Azure Blob extents are configured as part of SOBRs. Verify your repository configuration."
      return $blobExtents
    }

    Add-CheckResult -Category "Discovery" -Check "SOBR Repositories" -Status "INFO" `
      -Detail "Found $($sobrs.Count) Scale-Out Backup Repository(ies)"

    foreach ($sobr in $sobrs) {
      # Check capacity tier (Azure Blob)
      $capacityExtent = $sobr.CapacityExtent

      if (-not $capacityExtent) { continue }

      $repo = $capacityExtent.Repository

      # Check if this is an Azure Blob extent
      if ($repo.Type -match "Azure|AzureBlob|AzureBlobStorage") {
        $extentInfo = [PSCustomObject]@{
          SOBRName         = $sobr.Name
          SOBRId           = $sobr.Id
          ExtentName       = $repo.Name
          ExtentId         = $repo.Id
          Type             = $repo.Type
          StorageAccount   = ""
          Container        = ""
          UsedSpaceGB      = 0
          UsedSpaceTB      = 0
          BackupCount      = 0
          ImmutabilityEnabled = $false
          EncryptionEnabled   = $false
        }

        # Try to get Azure-specific details
        try {
          $extentInfo.StorageAccount = $repo.AzureBlobFolder.StorageAccount
          $extentInfo.Container = $repo.AzureBlobFolder.Container
          $extentInfo.ImmutabilityEnabled = $repo.ImmutabilityEnabled
          $extentInfo.EncryptionEnabled = $repo.EncryptionEnabled
        } catch { }

        # Count backups and estimate size
        try {
          $backups = Get-VBRBackup | Where-Object {
            $_.BackupRepository -and $_.BackupRepository.Id -eq $sobr.Id
          }
          $extentInfo.BackupCount = $backups.Count

          $totalSize = 0
          foreach ($backup in $backups) {
            try {
              $storages = $backup.GetAllStorages()
              foreach ($storage in $storages) {
                $totalSize += $storage.Stats.BackupSize
              }
            } catch { }
          }

          $extentInfo.UsedSpaceGB = [math]::Round($totalSize / 1GB, 2)
          $extentInfo.UsedSpaceTB = [math]::Round($totalSize / 1TB, 3)
        } catch { }

        $blobExtents += $extentInfo

        Add-CheckResult -Category "Discovery" -Check "Azure Blob Extent: $($repo.Name)" -Status "INFO" `
          -Detail "SOBR: $($sobr.Name) | Size: $($extentInfo.UsedSpaceGB) GB | Backups: $($extentInfo.BackupCount)"
      }
    }

    # Also check standalone object storage repos
    $objRepos = Get-VBRBackupRepository | Where-Object { $_.Type -match "Azure|AzureBlob" }
    foreach ($repo in $objRepos) {
      $extentInfo = [PSCustomObject]@{
        SOBRName         = "(Standalone)"
        SOBRId           = ""
        ExtentName       = $repo.Name
        ExtentId         = $repo.Id
        Type             = $repo.Type
        StorageAccount   = ""
        Container        = ""
        UsedSpaceGB      = 0
        UsedSpaceTB      = 0
        BackupCount      = 0
        ImmutabilityEnabled = $false
        EncryptionEnabled   = $false
      }

      $blobExtents += $extentInfo

      Add-CheckResult -Category "Discovery" -Check "Standalone Blob Repo: $($repo.Name)" -Status "INFO" `
        -Detail "Type: $($repo.Type)"
    }

    if ($blobExtents.Count -eq 0) {
      Add-CheckResult -Category "Discovery" -Check "Azure Blob Extents" -Status "WARNING" `
        -Detail "No Azure Blob storage extents found in any SOBR" `
        -Remediation "Ensure Azure Blob is configured as a capacity tier in your SOBR"
    } else {
      $totalGB = ($blobExtents | Measure-Object -Property UsedSpaceGB -Sum).Sum
      Add-CheckResult -Category "Discovery" -Check "Total Azure Blob Data" -Status "PASS" `
        -Detail "Found $($blobExtents.Count) Azure Blob extent(s) with $([math]::Round($totalGB, 2)) GB total data"
    }

  } catch {
    Add-CheckResult -Category "Discovery" -Check "Repository Scan" -Status "FAIL" `
      -Detail "Failed to scan repositories: $($_.Exception.Message)" `
      -Remediation "Verify VBR connection and permissions"
  }

  return $blobExtents
}

function Test-AzurePrerequisites {
  Write-Step -Title "Azure Prerequisites" -Status "Validating Azure connectivity and modules..."

  Write-Host ""
  Write-Host "  Azure Environment Checks:" -ForegroundColor Cyan
  Write-Host "  -------------------------" -ForegroundColor DarkGray

  # Check Azure PowerShell modules
  $requiredModules = @('Az.Accounts', 'Az.Compute', 'Az.Network', 'Az.Storage')
  $missingModules = @()

  foreach ($mod in $requiredModules) {
    if (Get-Module -ListAvailable -Name $mod) {
      Add-CheckResult -Category "Azure" -Check "Module: $mod" -Status "PASS" `
        -Detail "Installed"
    } else {
      $missingModules += $mod
      Add-CheckResult -Category "Azure" -Check "Module: $mod" -Status "FAIL" `
        -Detail "Not installed" `
        -Remediation "Run: Install-Module $mod -Scope CurrentUser"
    }
  }

  if ($missingModules.Count -gt 0) {
    Write-Log "Missing Azure modules: $($missingModules -join ', ')" -Level "WARNING"
    return $false
  }

  # Check Azure authentication
  try {
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if ($azContext) {
      Add-CheckResult -Category "Azure" -Check "Azure Session" -Status "PASS" `
        -Detail "Authenticated as $($azContext.Account.Id) in tenant $($azContext.Tenant.Id)"
    } else {
      Add-CheckResult -Category "Azure" -Check "Azure Session" -Status "WARNING" `
        -Detail "No active Azure session" `
        -Remediation "Run Connect-AzAccount before gateway deployment"
    }
  } catch {
    Add-CheckResult -Category "Azure" -Check "Azure Session" -Status "WARNING" `
      -Detail "Could not check Azure session" `
      -Remediation "Run Connect-AzAccount before gateway deployment"
  }

  return $true
}

function Test-VeeamVaultTarget {
  Write-Step -Title "Veeam Vault Target" -Status "Validating Veeam Vault repository..."

  Write-Host ""
  Write-Host "  Veeam Vault Target Checks:" -ForegroundColor Cyan
  Write-Host "  --------------------------" -ForegroundColor DarkGray

  if ($AssessOnly) {
    # In assess-only mode, just check if any Vault repos exist
    try {
      $vaultRepos = Get-VBRBackupRepository | Where-Object { $_.Type -match "Vault|VeeamCloud" }
      if ($vaultRepos.Count -gt 0) {
        foreach ($vr in $vaultRepos) {
          Add-CheckResult -Category "Vault" -Check "Existing Vault Repo: $($vr.Name)" -Status "INFO" `
            -Detail "Type: $($vr.Type)"
        }
      } else {
        Add-CheckResult -Category "Vault" -Check "Veeam Vault Repositories" -Status "INFO" `
          -Detail "No Veeam Vault repositories configured yet" `
          -Remediation "Add a Veeam Vault repository in VBR before migration"
      }
    } catch {
      Add-CheckResult -Category "Vault" -Check "Veeam Vault Scan" -Status "WARNING" `
        -Detail "Could not scan for Vault repositories"
    }
    return $true
  }

  # In migrate mode, verify the target exists
  try {
    $targetRepo = Get-VBRBackupRepository | Where-Object { $_.Name -eq $TargetVaultName }
    if ($targetRepo) {
      Add-CheckResult -Category "Vault" -Check "Target Repository" -Status "PASS" `
        -Detail "Found: $TargetVaultName (Type: $($targetRepo.Type))"

      # Check free space
      try {
        $freeGB = [math]::Round($targetRepo.GetContainer().CachedFreeSpace.InGigabytes, 2)
        Add-CheckResult -Category "Vault" -Check "Target Free Space" -Status "INFO" `
          -Detail "$freeGB GB available"
      } catch { }
    } else {
      Add-CheckResult -Category "Vault" -Check "Target Repository" -Status "FAIL" `
        -Detail "Repository '$TargetVaultName' not found" `
        -Remediation "Create the Veeam Vault repository in VBR Console first, then re-run this script"
      return $false
    }
  } catch {
    Add-CheckResult -Category "Vault" -Check "Target Repository" -Status "FAIL" `
      -Detail "Error looking up target: $($_.Exception.Message)"
    return $false
  }

  return $true
}

function Test-NetworkConnectivity {
  Write-Step -Title "Network Connectivity" -Status "Testing network paths..."

  Write-Host ""
  Write-Host "  Network Connectivity Checks:" -ForegroundColor Cyan
  Write-Host "  ----------------------------" -ForegroundColor DarkGray

  # Test VBR server connectivity
  if ($VBRServer -ne "localhost" -and $VBRServer -ne "127.0.0.1") {
    try {
      $tcpTest = Test-NetConnection -ComputerName $VBRServer -Port $VBRPort -WarningAction SilentlyContinue
      if ($tcpTest.TcpTestSucceeded) {
        Add-CheckResult -Category "Network" -Check "VBR Server ($VBRServer`:$VBRPort)" -Status "PASS" `
          -Detail "TCP connection successful"
      } else {
        Add-CheckResult -Category "Network" -Check "VBR Server ($VBRServer`:$VBRPort)" -Status "FAIL" `
          -Detail "TCP connection failed" `
          -Remediation "Check firewall rules and VBR service status"
      }
    } catch {
      Add-CheckResult -Category "Network" -Check "VBR Server Connectivity" -Status "WARNING" `
        -Detail "Could not test - Test-NetConnection not available"
    }
  } else {
    Add-CheckResult -Category "Network" -Check "VBR Server" -Status "PASS" `
      -Detail "Running locally on VBR server"
  }

  # Test Azure Blob endpoint reachability
  try {
    $blobTest = Invoke-WebRequest -Uri "https://management.azure.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Add-CheckResult -Category "Network" -Check "Azure Management API" -Status "PASS" `
      -Detail "HTTPS connectivity to Azure Management confirmed"
  } catch {
    if ($_.Exception.Response.StatusCode) {
      Add-CheckResult -Category "Network" -Check "Azure Management API" -Status "PASS" `
        -Detail "HTTPS connectivity confirmed (HTTP $($_.Exception.Response.StatusCode.value__))"
    } else {
      Add-CheckResult -Category "Network" -Check "Azure Management API" -Status "WARNING" `
        -Detail "Cannot reach Azure Management API" `
        -Remediation "Check outbound HTTPS (443) connectivity to management.azure.com"
    }
  }

  # Test Veeam Vault endpoint
  try {
    $vaultTest = Invoke-WebRequest -Uri "https://vault.veeam.com" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Add-CheckResult -Category "Network" -Check "Veeam Vault Endpoint" -Status "PASS" `
      -Detail "HTTPS connectivity to Veeam Vault confirmed"
  } catch {
    if ($_.Exception.Response.StatusCode) {
      Add-CheckResult -Category "Network" -Check "Veeam Vault Endpoint" -Status "PASS" `
        -Detail "HTTPS connectivity confirmed"
    } else {
      Add-CheckResult -Category "Network" -Check "Veeam Vault Endpoint" -Status "WARNING" `
        -Detail "Cannot reach Veeam Vault endpoint" `
        -Remediation "Check outbound HTTPS (443) connectivity to vault.veeam.com"
    }
  }

  return $true
}

function Get-MigrationEstimate {
  param(
    [Parameter(Mandatory=$true)]
    [array]$BlobExtents
  )

  Write-Step -Title "Migration Estimate" -Status "Calculating migration scope and timeline..."

  Write-Host ""
  Write-Host "  Migration Estimates:" -ForegroundColor Cyan
  Write-Host "  --------------------" -ForegroundColor DarkGray

  $totalGB = ($BlobExtents | Measure-Object -Property UsedSpaceGB -Sum).Sum
  $totalTB = [math]::Round($totalGB / 1024, 3)

  # Estimate transfer time based on concurrent tasks and throughput
  $effectiveThroughputGBps = $ESTIMATED_THROUGHPUT_GBPS * $MaxConcurrentTasks
  $transferHours = if ($effectiveThroughputGBps -gt 0) {
    ($totalGB * 8) / ($effectiveThroughputGBps * 3600) # Convert GB to Gb, then to hours
  } else { 0 }

  # Veeam Vault monthly cost
  $monthlyVaultCost = [math]::Round($totalTB * $VEEAM_VAULT_PRICE_PER_TB, 2)

  $estimate = [PSCustomObject]@{
    TotalDataGB          = [math]::Round($totalGB, 2)
    TotalDataTB          = $totalTB
    ExtentCount          = $BlobExtents.Count
    TotalBackups         = ($BlobExtents | Measure-Object -Property BackupCount -Sum).Sum
    ConcurrentTasks      = $MaxConcurrentTasks
    EstimatedHours       = [math]::Round($transferHours, 1)
    EstimatedDuration    = Format-Duration -Hours $transferHours
    MonthlyVaultCost     = $monthlyVaultCost
    AnnualVaultCost      = [math]::Round($monthlyVaultCost * 12, 2)
  }

  Add-CheckResult -Category "Estimate" -Check "Total Data to Migrate" -Status "INFO" `
    -Detail "$($estimate.TotalDataGB) GB ($($estimate.TotalDataTB) TB) across $($estimate.ExtentCount) extent(s)"

  Add-CheckResult -Category "Estimate" -Check "Estimated Transfer Time" -Status "INFO" `
    -Detail "$($estimate.EstimatedDuration) ($MaxConcurrentTasks concurrent tasks at ~$($ESTIMATED_THROUGHPUT_GBPS) Gbps each)"

  Add-CheckResult -Category "Estimate" -Check "Veeam Vault Monthly Cost" -Status "INFO" `
    -Detail "`$$($estimate.MonthlyVaultCost)/month (`$$VEEAM_VAULT_PRICE_PER_TB/TB all-inclusive)"

  Add-CheckResult -Category "Estimate" -Check "Veeam Vault Annual Cost" -Status "INFO" `
    -Detail "`$$($estimate.AnnualVaultCost)/year (zero egress, zero API ops, no reservations)"

  return $estimate
}

function Test-GatewayReadiness {
  Write-Step -Title "Gateway Readiness" -Status "Checking gateway server requirements..."

  Write-Host ""
  Write-Host "  Gateway Server Assessment:" -ForegroundColor Cyan
  Write-Host "  --------------------------" -ForegroundColor DarkGray

  if ($SkipGatewayDeploy) {
    Add-CheckResult -Category "Gateway" -Check "Gateway Deployment" -Status "SKIP" `
      -Detail "Skipped (using existing gateway per -SkipGatewayDeploy)"

    # Check for existing managed servers that could be gateways
    try {
      $linuxServers = Get-VBRServer | Where-Object { $_.Type -eq "Linux" }
      if ($linuxServers.Count -gt 0) {
        foreach ($srv in $linuxServers) {
          Add-CheckResult -Category "Gateway" -Check "Linux Server: $($srv.Name)" -Status "INFO" `
            -Detail "Available as potential gateway proxy"
        }
      } else {
        Add-CheckResult -Category "Gateway" -Check "Linux Servers" -Status "WARNING" `
          -Detail "No Linux managed servers found in VBR" `
          -Remediation "Add a Linux server in VBR to use as a gateway, or remove -SkipGatewayDeploy to auto-deploy"
      }
    } catch {
      Add-CheckResult -Category "Gateway" -Check "Managed Servers" -Status "WARNING" `
        -Detail "Could not enumerate managed servers"
    }

    return $true
  }

  # Validate gateway deployment parameters
  if (-not $GatewayRegion) {
    Add-CheckResult -Category "Gateway" -Check "Gateway Region" -Status "FAIL" `
      -Detail "No region specified for gateway deployment" `
      -Remediation "Provide -GatewayRegion matching your Azure Blob storage region"
    return $false
  }

  if (-not $GatewayResourceGroup) {
    Add-CheckResult -Category "Gateway" -Check "Resource Group" -Status "FAIL" `
      -Detail "No resource group specified" `
      -Remediation "Provide -GatewayResourceGroup for gateway VM placement"
    return $false
  }

  if (-not $GatewayVNetName) {
    Add-CheckResult -Category "Gateway" -Check "Virtual Network" -Status "FAIL" `
      -Detail "No VNet specified for gateway" `
      -Remediation "Provide -GatewayVNetName (must have connectivity to both Azure Blob and VBR)"
    return $false
  }

  Add-CheckResult -Category "Gateway" -Check "Gateway VM Size" -Status "INFO" `
    -Detail "$GatewayVmSize (min: $GATEWAY_MIN_CPU vCPU, $($GATEWAY_MIN_RAM_GB) GB RAM)"

  Add-CheckResult -Category "Gateway" -Check "Gateway Region" -Status "INFO" `
    -Detail "$GatewayRegion (should match Azure Blob region for best performance)"

  Add-CheckResult -Category "Gateway" -Check "Gateway Network" -Status "INFO" `
    -Detail "VNet: $GatewayVNetName / Subnet: $GatewaySubnetName"

  # Verify VNet exists
  try {
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if ($azContext) {
      $vnet = Get-AzVirtualNetwork -Name $GatewayVNetName -ResourceGroupName $GatewayResourceGroup -ErrorAction SilentlyContinue
      if ($vnet) {
        Add-CheckResult -Category "Gateway" -Check "VNet Validation" -Status "PASS" `
          -Detail "VNet '$GatewayVNetName' found in $GatewayResourceGroup"

        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $GatewaySubnetName }
        if ($subnet) {
          Add-CheckResult -Category "Gateway" -Check "Subnet Validation" -Status "PASS" `
            -Detail "Subnet '$GatewaySubnetName' found ($($subnet.AddressPrefix))"
        } else {
          Add-CheckResult -Category "Gateway" -Check "Subnet Validation" -Status "FAIL" `
            -Detail "Subnet '$GatewaySubnetName' not found in VNet" `
            -Remediation "Check subnet name or create it in the Azure portal"
        }
      } else {
        Add-CheckResult -Category "Gateway" -Check "VNet Validation" -Status "FAIL" `
          -Detail "VNet '$GatewayVNetName' not found in $GatewayResourceGroup" `
          -Remediation "Verify VNet name and resource group"
      }
    } else {
      Add-CheckResult -Category "Gateway" -Check "VNet Validation" -Status "SKIP" `
        -Detail "No Azure session - connect with Connect-AzAccount to validate"
    }
  } catch {
    Add-CheckResult -Category "Gateway" -Check "VNet Validation" -Status "WARNING" `
      -Detail "Could not validate VNet: $($_.Exception.Message)"
  }

  return $true
}

#endregion

# ===== Gateway Deployment =====
#region Gateway Deployment

function Deploy-GatewayServer {
  param(
    [Parameter(Mandatory=$true)]
    [string]$Region,
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroup,
    [Parameter(Mandatory=$true)]
    [string]$VNetName,
    [string]$SubnetName = "default",
    [string]$VmSize = "Standard_D4s_v5"
  )

  Write-Log "Starting gateway server deployment..." -Level "INFO"

  $gatewayVmName = "veeam-vault-gw-$(Get-Date -Format 'yyyyMMddHHmm')"

  # Ensure resource group exists
  try {
    $rg = Get-AzResourceGroup -Name $ResourceGroup -ErrorAction SilentlyContinue
    if (-not $rg) {
      Write-Log "Creating resource group: $ResourceGroup in $Region" -Level "INFO"
      New-AzResourceGroup -Name $ResourceGroup -Location $Region | Out-Null
    }
  } catch {
    Write-Log "Failed to create resource group: $($_.Exception.Message)" -Level "ERROR"
    throw
  }

  # Get subnet reference
  try {
    $vnet = Get-AzVirtualNetwork -Name $VNetName -ResourceGroupName $ResourceGroup -ErrorAction Stop
  } catch {
    Write-Log "Failed to retrieve virtual network '$VNetName' in resource group '$ResourceGroup': $($_.Exception.Message)" -Level "ERROR"
    throw
  }

  if (-not $vnet) {
    Write-Log "Virtual network '$VNetName' in resource group '$ResourceGroup' was not found." -Level "ERROR"
    throw "Virtual network '$VNetName' in resource group '$ResourceGroup' was not found."
  }

  $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $SubnetName }
  if (-not $subnet) {
    Write-Log "Subnet '$SubnetName' was not found in virtual network '$VNetName' (resource group '$ResourceGroup')." -Level "ERROR"
    throw "Subnet '$SubnetName' was not found in virtual network '$VNetName' (resource group '$ResourceGroup')."
  }

  # Create NIC
  Write-Log "Creating network interface..." -Level "INFO"
  $nicName = "$gatewayVmName-nic"
  $nic = New-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroup `
    -Location $Region -SubnetId $subnet.Id -ErrorAction Stop

  # Create VM config (Ubuntu 22.04 LTS)
  Write-Log "Deploying gateway VM: $gatewayVmName ($VmSize)..." -Level "INFO"

  $vmConfig = New-AzVMConfig -VMName $gatewayVmName -VMSize $VmSize

  # Use Ubuntu 22.04 LTS
  $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux -ComputerName $gatewayVmName `
    -Credential (Get-Credential -Message "Enter credentials for the gateway VM admin user")

  $vmConfig = Set-AzVMSourceImage -VM $vmConfig -PublisherName "Canonical" `
    -Offer "0001-com-ubuntu-server-jammy" -Skus "22_04-lts-gen2" -Version "latest"

  $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

  # Deploy
  New-AzVM -ResourceGroupName $ResourceGroup -Location $Region -VM $vmConfig -ErrorAction Stop | Out-Null

  Write-Log "Gateway VM '$gatewayVmName' deployed successfully" -Level "SUCCESS"

  # Get private IP
  $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $ResourceGroup
  $gatewayIp = $nic.IpConfigurations[0].PrivateIpAddress

  Write-Log "Gateway private IP: $gatewayIp" -Level "SUCCESS"

  return [PSCustomObject]@{
    VmName        = $gatewayVmName
    ResourceGroup = $ResourceGroup
    Region        = $Region
    PrivateIp     = $gatewayIp
    VmSize        = $VmSize
  }
}

#endregion

# ===== Evacuate Operation =====
#region Evacuate

function Start-EvacuateOperation {
  param(
    [Parameter(Mandatory=$true)]
    [array]$BlobExtents,
    [Parameter(Mandatory=$true)]
    [string]$TargetRepoName
  )

  Write-Log "Preparing evacuate operation..." -Level "INFO"

  $targetRepo = Get-VBRBackupRepository | Where-Object { $_.Name -eq $TargetRepoName }
  if (-not $targetRepo) {
    Write-Log "Target repository '$TargetRepoName' not found" -Level "ERROR"
    throw "Target repository not found"
  }

  foreach ($extent in $BlobExtents) {
    if (-not $extent.SOBRId) { continue }

    Write-Log "Starting evacuation for SOBR: $($extent.SOBRName)" -Level "INFO"
    Write-Log "  Source: $($extent.ExtentName) (Azure Blob)" -Level "INFO"
    Write-Log "  Target: $TargetRepoName (Veeam Vault)" -Level "INFO"
    Write-Log "  Data:   $($extent.UsedSpaceGB) GB" -Level "INFO"

    try {
      # The evacuate command moves data from one SOBR extent to another
      $sobr = Get-VBRBackupRepository -ScaleOut | Where-Object { $_.Id -eq $extent.SOBRId }

      # Start the data evacuation
      Start-VBRRepositoryEvacuate -Repository $sobr -ErrorAction Stop

      Write-Log "Evacuation started for $($extent.SOBRName). Monitor progress in VBR Console." -Level "SUCCESS"
    } catch {
      Write-Log "Evacuation failed for $($extent.SOBRName): $($_.Exception.Message)" -Level "ERROR"
    }
  }
}

#endregion

# ===== HTML Report Generation =====
#region Report

function Generate-MigrationReport {
  param(
    [array]$BlobExtents,
    [object]$Estimate,
    [string]$OutputPath
  )

  Write-Step -Title "Migration Report" -Status "Generating professional HTML report..."

  $reportDate = Get-Date -Format "MMMM d, yyyy 'at' h:mm tt"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"
  $mode = if ($AssessOnly) { "Assessment Only (Read-Only)" } else { "Migration Planning" }

  # Build check results table
  $passCount = ($script:CheckResults | Where-Object { $_.Status -eq "PASS" }).Count
  $failCount = ($script:CheckResults | Where-Object { $_.Status -eq "FAIL" }).Count
  $warnCount = ($script:CheckResults | Where-Object { $_.Status -eq "WARNING" }).Count
  $overallStatus = if ($failCount -gt 0) { "NOT READY" } elseif ($warnCount -gt 0) { "READY WITH WARNINGS" } else { "READY" }
  $statusColor = if ($failCount -gt 0) { "#dc2626" } elseif ($warnCount -gt 0) { "#f59e0b" } else { "#00b336" }

  $checkRows = $script:CheckResults | ForEach-Object {
    $statusIcon = switch ($_.Status) {
      "PASS"    { '<span style="color:#00b336;font-weight:600;">&#10003; PASS</span>' }
      "FAIL"    { '<span style="color:#dc2626;font-weight:600;">&#10007; FAIL</span>' }
      "WARNING" { '<span style="color:#f59e0b;font-weight:600;">&#9888; WARN</span>' }
      "SKIP"    { '<span style="color:#9ca3af;font-weight:600;">&#8212; SKIP</span>' }
      default   { '<span style="color:#0078d4;font-weight:600;">&#9432; INFO</span>' }
    }
    $remediationCell = if ($_.Remediation) { "<br><small style='color:#605e5c;'>Fix: $($_.Remediation)</small>" } else { "" }
    "<tr><td>$($_.Category)</td><td>$($_.Check)</td><td>$statusIcon</td><td>$($_.Detail)$remediationCell</td></tr>"
  } | Out-String

  # Build extents table
  $extentRows = if ($BlobExtents -and $BlobExtents.Count -gt 0) {
    $BlobExtents | ForEach-Object {
      "<tr><td>$($_.SOBRName)</td><td>$($_.ExtentName)</td><td>$($_.StorageAccount)</td><td>$($_.Container)</td><td style='font-weight:600;'>$($_.UsedSpaceGB) GB</td><td>$($_.BackupCount)</td></tr>"
    } | Out-String
  } else {
    "<tr><td colspan='6' style='text-align:center;color:#605e5c;'>No Azure Blob extents discovered</td></tr>"
  }

  # Estimate section
  $estimateSection = if ($Estimate) {
    @"
    <div class="section">
      <h2 class="section-title">Migration Estimate</h2>
      <div class="estimate-grid">
        <div class="estimate-card">
          <div class="estimate-label">Total Data</div>
          <div class="estimate-value">$($Estimate.TotalDataTB) TB</div>
          <div class="estimate-detail">$($Estimate.TotalDataGB) GB across $($Estimate.ExtentCount) extent(s)</div>
        </div>
        <div class="estimate-card">
          <div class="estimate-label">Estimated Transfer Time</div>
          <div class="estimate-value">$($Estimate.EstimatedDuration)</div>
          <div class="estimate-detail">$($Estimate.ConcurrentTasks) concurrent tasks at ~$($ESTIMATED_THROUGHPUT_GBPS) Gbps</div>
        </div>
        <div class="estimate-card highlight-green">
          <div class="estimate-label">Veeam Vault Monthly Cost</div>
          <div class="estimate-value">`$$($Estimate.MonthlyVaultCost)/mo</div>
          <div class="estimate-detail">`$14/TB all-inclusive (zero egress, zero API ops)</div>
        </div>
        <div class="estimate-card highlight-green">
          <div class="estimate-label">Veeam Vault Annual Cost</div>
          <div class="estimate-value">`$$($Estimate.AnnualVaultCost)/yr</div>
          <div class="estimate-detail">No reservations, no lock-in, month-to-month</div>
        </div>
      </div>
    </div>
"@
  } else { "" }

  # Migration steps guide
  $stepsSection = @"
    <div class="section">
      <h2 class="section-title">Migration Steps</h2>
      <p style="color:#605e5c;margin-bottom:20px;">Follow these steps to complete your Azure Blob to Veeam Vault migration:</p>
      <div class="step-list">
        <div class="step">
          <div class="step-number">1</div>
          <div class="step-content">
            <h3>Pre-Flight Assessment</h3>
            <p>Validate VBR version (v12.3+), licensing, Azure connectivity, and identify Azure Blob SOBR extents. This is the step you just completed.</p>
            <div class="step-status done">Completed</div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">2</div>
          <div class="step-content">
            <h3>Add Veeam Vault Repository</h3>
            <p>In VBR Console, go to <strong>Backup Infrastructure &gt; Backup Repositories &gt; Add Repository</strong> and select <strong>Veeam Vault</strong>. Provision sufficient capacity for your data ($($Estimate.TotalDataTB) TB).</p>
            <div class="step-code">
              <code># PowerShell: Verify Vault repository exists after adding<br>Get-VBRBackupRepository | Where-Object { `$_.Type -match "Vault" }</code>
            </div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">3</div>
          <div class="step-content">
            <h3>Deploy Gateway Server</h3>
            <p>Deploy a Linux VM in Azure (same region as your Blob storage) to act as a data mover. Recommended: <strong>Standard_D4s_v5</strong> (4 vCPU, 16 GB RAM) with Ubuntu 22.04 LTS.</p>
            <div class="step-code">
              <code># Deploy gateway via this script:<br>.\Start-AzureBlobToVaultMigration.ps1 \<br>&nbsp;&nbsp;-TargetVaultName "YourVaultRepo" \<br>&nbsp;&nbsp;-GatewayRegion "eastus" \<br>&nbsp;&nbsp;-GatewayResourceGroup "rg-veeam-migration" \<br>&nbsp;&nbsp;-GatewayVNetName "vnet-backup"</code>
            </div>
            <div class="step-note">
              <strong>Important:</strong> The gateway VM must have network connectivity to both your Azure Blob storage (private endpoint or service endpoint) and the Veeam Vault endpoint (outbound HTTPS 443).
            </div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">4</div>
          <div class="step-content">
            <h3>Register Gateway in VBR</h3>
            <p>Add the Linux gateway VM as a managed server in VBR Console: <strong>Backup Infrastructure &gt; Managed Servers &gt; Add Server &gt; Linux</strong>.</p>
            <div class="step-code">
              <code># PowerShell: Add Linux server to VBR<br>`$cred = Get-Credential -Message "Gateway SSH credentials"<br>Add-VBRLinux -Name "gateway-ip-address" -Credential `$cred -Description "Vault Migration Gateway"</code>
            </div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">5</div>
          <div class="step-content">
            <h3>Update SOBR Configuration</h3>
            <p>Replace the Azure Blob capacity tier with Veeam Vault in your SOBR configuration. In VBR Console, edit the SOBR and change the capacity tier to your new Veeam Vault repository.</p>
            <div class="step-note">
              <strong>Important:</strong> Assign the gateway server as the data transfer proxy for the capacity tier.
            </div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">6</div>
          <div class="step-content">
            <h3>Evacuate Data (Move from Blob to Vault)</h3>
            <p>Initiate the data evacuation to move all backup data from Azure Blob to Veeam Vault. This can run in the background while backups continue.</p>
            <div class="step-code">
              <code># PowerShell: Start evacuation<br>`$sobr = Get-VBRBackupRepository -ScaleOut | Where-Object { `$_.Name -eq "YourSOBR" }<br>Start-VBRRepositoryEvacuate -Repository `$sobr<br><br># Monitor progress in VBR Console under 'Backup Infrastructure &gt; SOBR &gt; Capacity Tier'</code>
            </div>
            <div class="step-code">
              <code># Or run the full migration via this script:<br>.\Start-AzureBlobToVaultMigration.ps1 \<br>&nbsp;&nbsp;-TargetVaultName "YourVaultRepo" \<br>&nbsp;&nbsp;-SkipGatewayDeploy -ExecuteEvacuate</code>
            </div>
          </div>
        </div>
        <div class="step">
          <div class="step-number">7</div>
          <div class="step-content">
            <h3>Validate & Clean Up</h3>
            <p>After evacuation completes, verify all backup data is accessible from Veeam Vault. Then decommission the Azure Blob storage and gateway VM.</p>
            <div class="step-code">
              <code># Verify backup chains are intact<br>Get-VBRBackup | ForEach-Object { `$_.GetAllStorages() | Select-Object FilePath, CreationTime }<br><br># Decommission gateway after migration<br>Remove-AzVM -Name "veeam-vault-gw-*" -ResourceGroupName "rg-veeam-migration" -Force</code>
            </div>
          </div>
        </div>
      </div>
    </div>
"@

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Azure Blob to Veeam Vault - Migration Assessment</title>
  <style>
    :root {
      --veeam-green: #00b336;
      --veeam-dark: #005f4b;
      --azure-blue: #0078d4;
      --background: #f5f5f5;
      --card-bg: #ffffff;
      --text-primary: #323130;
      --text-secondary: #605e5c;
      --border: #edebe9;
      --danger: #dc2626;
      --warning: #f59e0b;
    }

    * { margin: 0; padding: 0; box-sizing: border-box; }

    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background-color: var(--background);
      color: var(--text-primary);
      line-height: 1.6;
      padding: 20px;
    }

    .container { max-width: 1400px; margin: 0 auto; }

    header {
      background: linear-gradient(135deg, var(--veeam-green) 0%, var(--veeam-dark) 100%);
      color: white;
      padding: 40px;
      border-radius: 8px;
      margin-bottom: 30px;
      box-shadow: 0 4px 6px rgba(0,0,0,0.1);
    }

    header h1 { font-size: 32px; margin-bottom: 8px; }
    header p { font-size: 16px; opacity: 0.95; }

    .header-meta {
      display: flex; gap: 24px; flex-wrap: wrap;
      margin-top: 16px; font-size: 14px; opacity: 0.9;
    }

    .status-banner {
      padding: 20px 30px;
      border-radius: 8px;
      margin-bottom: 30px;
      display: flex;
      align-items: center;
      gap: 16px;
      font-size: 18px;
      font-weight: 600;
      color: white;
    }

    .summary-cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 16px;
      margin-bottom: 30px;
    }

    .summary-card {
      background: var(--card-bg);
      padding: 20px;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      text-align: center;
    }

    .summary-card .label {
      font-size: 12px; color: var(--text-secondary);
      text-transform: uppercase; letter-spacing: 0.5px;
      margin-bottom: 8px;
    }

    .summary-card .value {
      font-size: 28px; font-weight: 600;
    }

    .summary-card .value.green { color: var(--veeam-green); }
    .summary-card .value.red { color: var(--danger); }
    .summary-card .value.orange { color: var(--warning); }

    .section {
      background: var(--card-bg);
      padding: 30px;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      margin-bottom: 30px;
    }

    .section-title {
      font-size: 22px; margin-bottom: 20px;
      border-bottom: 2px solid var(--border);
      padding-bottom: 10px;
    }

    table {
      width: 100%; border-collapse: collapse; margin-top: 16px;
    }

    th, td {
      padding: 12px 14px; text-align: left;
      border-bottom: 1px solid var(--border);
    }

    th {
      background-color: var(--background);
      font-weight: 600; font-size: 12px;
      text-transform: uppercase; letter-spacing: 0.5px;
    }

    tbody tr:hover { background-color: #fafafa; }

    .estimate-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
      gap: 20px;
    }

    .estimate-card {
      background: var(--background);
      padding: 24px;
      border-radius: 8px;
      border-left: 4px solid var(--azure-blue);
    }

    .estimate-card.highlight-green {
      border-left-color: var(--veeam-green);
      background: #f0fdf4;
    }

    .estimate-label {
      font-size: 12px; color: var(--text-secondary);
      text-transform: uppercase; letter-spacing: 0.5px;
      margin-bottom: 8px;
    }

    .estimate-value {
      font-size: 28px; font-weight: 600; margin-bottom: 4px;
    }

    .estimate-detail { font-size: 13px; color: var(--text-secondary); }

    .step-list { margin-top: 10px; }

    .step {
      display: flex; gap: 20px; padding: 24px 0;
      border-bottom: 1px solid var(--border);
    }

    .step:last-child { border-bottom: none; }

    .step-number {
      flex-shrink: 0; width: 40px; height: 40px;
      background: var(--veeam-green); color: white;
      border-radius: 50%; display: flex;
      align-items: center; justify-content: center;
      font-size: 18px; font-weight: 600;
    }

    .step-content { flex-grow: 1; }
    .step-content h3 { margin-bottom: 8px; font-size: 18px; }
    .step-content p { color: var(--text-secondary); margin-bottom: 12px; }

    .step-code {
      background: #1e293b; color: #e2e8f0;
      padding: 16px; border-radius: 6px;
      margin: 12px 0; font-family: 'Cascadia Code', 'Consolas', monospace;
      font-size: 13px; overflow-x: auto;
    }

    .step-code code { color: #e2e8f0; }

    .step-note {
      background: #fffbeb; border-left: 4px solid var(--warning);
      padding: 12px 16px; border-radius: 4px;
      margin-top: 12px; font-size: 14px; color: #92400e;
    }

    .step-status {
      display: inline-block; padding: 4px 12px;
      border-radius: 12px; font-size: 12px; font-weight: 600;
    }

    .step-status.done {
      background: #dcfce7; color: #166534;
    }

    .footer {
      text-align: center; margin-top: 40px;
      padding: 20px; color: var(--text-secondary); font-size: 14px;
    }

    @media print {
      body { background: white; }
      .section, .summary-card { box-shadow: none; border: 1px solid var(--border); }
      .step-code { background: #f1f5f9; color: #1e293b; border: 1px solid var(--border); }
      .step-code code { color: #1e293b; }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Azure Blob to Veeam Vault Migration</h1>
      <p>$mode</p>
      <div class="header-meta">
        <span><strong>Generated:</strong> $reportDate</span>
        <span><strong>Duration:</strong> $durationStr</span>
        <span><strong>VBR Server:</strong> $VBRServer</span>
      </div>
    </header>

    <div class="status-banner" style="background-color: $statusColor;">
      <span style="font-size:28px;">$(if ($failCount -gt 0) { "&#10007;" } elseif ($warnCount -gt 0) { "&#9888;" } else { "&#10003;" })</span>
      <span>Migration Readiness: $overallStatus ($passCount passed, $failCount failed, $warnCount warnings)</span>
    </div>

    <div class="summary-cards">
      <div class="summary-card">
        <div class="label">Checks Passed</div>
        <div class="value green">$passCount</div>
      </div>
      <div class="summary-card">
        <div class="label">Checks Failed</div>
        <div class="value $(if ($failCount -gt 0) { 'red' } else { 'green' })">$failCount</div>
      </div>
      <div class="summary-card">
        <div class="label">Warnings</div>
        <div class="value $(if ($warnCount -gt 0) { 'orange' } else { 'green' })">$warnCount</div>
      </div>
      <div class="summary-card">
        <div class="label">Azure Blob Extents</div>
        <div class="value">$(if ($BlobExtents) { $BlobExtents.Count } else { 0 })</div>
      </div>
    </div>

    <div class="section">
      <h2 class="section-title">Pre-Flight Check Results</h2>
      <table>
        <thead>
          <tr>
            <th>Category</th>
            <th>Check</th>
            <th>Status</th>
            <th>Detail</th>
          </tr>
        </thead>
        <tbody>
          $checkRows
        </tbody>
      </table>
    </div>

    <div class="section">
      <h2 class="section-title">Azure Blob Extents Discovered</h2>
      <table>
        <thead>
          <tr>
            <th>SOBR Name</th>
            <th>Extent Name</th>
            <th>Storage Account</th>
            <th>Container</th>
            <th>Used Space</th>
            <th>Backups</th>
          </tr>
        </thead>
        <tbody>
          $extentRows
        </tbody>
      </table>
    </div>

    $estimateSection
    $stepsSection

    <div class="section" style="background: #f0fdf4; border-left: 4px solid var(--veeam-green);">
      <h2 class="section-title" style="border-bottom: none;">Why Veeam Vault?</h2>
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-top: 10px;">
        <div>
          <h4 style="margin-bottom:6px;">Predictable Pricing</h4>
          <p style="color:var(--text-secondary);font-size:14px;">`$14/TB/month all-inclusive. Zero egress fees. Zero API operations charges. No surprise bills.</p>
        </div>
        <div>
          <h4 style="margin-bottom:6px;">Built-In Immutability</h4>
          <p style="color:var(--text-secondary);font-size:14px;">Ransomware protection included at no extra cost. No API ops charges for immutability validation.</p>
        </div>
        <div>
          <h4 style="margin-bottom:6px;">No Lock-In</h4>
          <p style="color:var(--text-secondary);font-size:14px;">Month-to-month flexibility. No 1-year or 3-year reservation commitments required.</p>
        </div>
        <div>
          <h4 style="margin-bottom:6px;">Native Integration</h4>
          <p style="color:var(--text-secondary);font-size:14px;">Built into VBR Console. No separate management console. Enterprise support included.</p>
        </div>
      </div>
    </div>

    <div class="footer">
      <p><strong>&copy; 2026 Veeam Software</strong> | Sales Engineering Migration Tool</p>
      <p>For assistance, contact your Veeam Solutions Architect</p>
    </div>
  </div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutputPath "migration_assessment_report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8

  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}

#endregion

# ===== Main Execution =====
#region Main

try {
  # Banner
  $separator = "=" * 80
  Write-Host ""
  Write-Host $separator -ForegroundColor Cyan
  Write-Host "  AZURE BLOB TO VEEAM VAULT - MIGRATION TOOL" -ForegroundColor White
  Write-Host "  Veeam Software - Sales Engineering" -ForegroundColor Gray
  Write-Host $separator -ForegroundColor Cyan
  Write-Host ""

  if ($AssessOnly) {
    Write-Host "  Mode: " -NoNewline -ForegroundColor Gray
    Write-Host "ASSESSMENT ONLY (Read-Only - No Changes)" -ForegroundColor Green
  } else {
    Write-Host "  Mode: " -NoNewline -ForegroundColor Gray
    Write-Host "MIGRATION PLANNING" -ForegroundColor Yellow
    Write-Host "  Target: " -NoNewline -ForegroundColor Gray
    Write-Host "$TargetVaultName" -ForegroundColor White
  }

  Write-Host "  VBR Server: " -NoNewline -ForegroundColor Gray
  Write-Host "$VBRServer" -ForegroundColor White
  Write-Host "  Output: " -NoNewline -ForegroundColor Gray
  Write-Host "$OutputPath" -ForegroundColor White
  Write-Host ""

  # ===== STEP 1: VBR Prerequisites =====
  $vbrReady = Test-VBRPrerequisites
  Write-Host ""

  # ===== STEP 2: Discover Azure Blob Repositories =====
  $blobExtents = @()
  if ($vbrReady) {
    $blobExtents = Get-AzureBlobRepositories
  } else {
    Write-Log "Skipping repository discovery (VBR not connected)" -Level "WARNING"
    Add-CheckResult -Category "Discovery" -Check "Repository Scan" -Status "SKIP" `
      -Detail "Skipped due to VBR connection failure"
  }
  Write-Host ""

  # ===== STEP 3: Azure Prerequisites =====
  $azureReady = Test-AzurePrerequisites
  Write-Host ""

  # ===== STEP 4: Veeam Vault Target =====
  if ($vbrReady) {
    $vaultReady = Test-VeeamVaultTarget
  } else {
    Add-CheckResult -Category "Vault" -Check "Vault Validation" -Status "SKIP" `
      -Detail "Skipped due to VBR connection failure"
    $vaultReady = $false
  }
  Write-Host ""

  # ===== STEP 5: Network Connectivity =====
  Test-NetworkConnectivity
  Write-Host ""

  # ===== STEP 6: Migration Estimate =====
  $estimate = $null
  if ($blobExtents.Count -gt 0) {
    $estimate = Get-MigrationEstimate -BlobExtents $blobExtents
  } else {
    Write-Step -Title "Migration Estimate" -Status "No data to estimate"
    Add-CheckResult -Category "Estimate" -Check "Migration Estimate" -Status "SKIP" `
      -Detail "No Azure Blob extents found to estimate"
  }
  Write-Host ""

  # ===== STEP 7: Gateway Readiness =====
  $gatewayReady = Test-GatewayReadiness
  Write-Host ""

  # ===== STEP 8: Generate Report =====
  $htmlPath = Generate-MigrationReport -BlobExtents $blobExtents -Estimate $estimate -OutputPath $OutputPath

  # Export check results to CSV
  $csvPath = Join-Path $OutputPath "preflight_checks.csv"
  $script:CheckResults | Export-Csv -Path $csvPath -NoTypeInformation

  # Export extent data to CSV
  if ($blobExtents.Count -gt 0) {
    $extentCsvPath = Join-Path $OutputPath "azure_blob_extents.csv"
    $blobExtents | Export-Csv -Path $extentCsvPath -NoTypeInformation
  }

  # ===== Execute Migration (if requested) =====
  if (-not $AssessOnly -and $ExecuteEvacuate) {
    $failCount = ($script:CheckResults | Where-Object { $_.Status -eq "FAIL" }).Count

    if ($failCount -gt 0) {
      Write-Host ""
      Write-Host "  MIGRATION BLOCKED: $failCount pre-flight check(s) failed." -ForegroundColor Red
      Write-Host "  Resolve all failures before executing the migration." -ForegroundColor Red
      Write-Host "  Review the report for remediation steps: $htmlPath" -ForegroundColor Yellow
    } elseif ($blobExtents.Count -eq 0) {
      Write-Host ""
      Write-Host "  MIGRATION BLOCKED: No Azure Blob extents found to evacuate." -ForegroundColor Red
    } else {
      if (-not $SkipGatewayDeploy -and $GatewayRegion) {
        Write-Host ""
        Write-Host "  Deploying gateway server..." -ForegroundColor Cyan
        $gateway = Deploy-GatewayServer `
          -Region $GatewayRegion `
          -ResourceGroup $GatewayResourceGroup `
          -VNetName $GatewayVNetName `
          -SubnetName $GatewaySubnetName `
          -VmSize $GatewayVmSize

        Write-Host "  Gateway deployed: $($gateway.VmName) ($($gateway.PrivateIp))" -ForegroundColor Green
        Write-Host ""
        Write-Host "  NEXT STEPS:" -ForegroundColor Yellow
        Write-Host "    1. Add the gateway ($($gateway.PrivateIp)) as a managed Linux server in VBR" -ForegroundColor White
        Write-Host "    2. Once registration is complete, you can immediately continue with data evacuation." -ForegroundColor White
        Write-Host ""
        $userChoice = Read-Host "  Press Enter to start data evacuation after the gateway is registered in VBR, or type 'skip' to exit and run later"
        if ($userChoice -ne "skip") {
          Write-Host ""
          Write-Host "  Starting data evacuation..." -ForegroundColor Cyan
          Start-EvacuateOperation -BlobExtents $blobExtents -TargetRepoName $TargetVaultName
        } else {
          Write-Host ""
          Write-Host "  Evacuation skipped. You can re-run this script later with -SkipGatewayDeploy -ExecuteEvacuate after the gateway is fully registered." -ForegroundColor Yellow
        }
      } else {
        Write-Host ""
        Write-Host "  Starting data evacuation..." -ForegroundColor Cyan
        Start-EvacuateOperation -BlobExtents $blobExtents -TargetRepoName $TargetVaultName
      }
    }
  }

  # ===== Final Summary =====
  Write-Progress -Activity "Azure Blob to Veeam Vault Migration" -Completed
  Write-Host ""

  $passCount = ($script:CheckResults | Where-Object { $_.Status -eq "PASS" }).Count
  $failCount = ($script:CheckResults | Where-Object { $_.Status -eq "FAIL" }).Count
  $warnCount = ($script:CheckResults | Where-Object { $_.Status -eq "WARNING" }).Count

  Write-Host $separator -ForegroundColor Cyan
  Write-Host "  ASSESSMENT SUMMARY" -ForegroundColor White
  Write-Host $separator -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  Checks Passed:  " -NoNewline -ForegroundColor Gray
  Write-Host "$passCount" -ForegroundColor Green
  Write-Host "  Checks Failed:  " -NoNewline -ForegroundColor Gray
  Write-Host "$failCount" -ForegroundColor $(if ($failCount -gt 0) { "Red" } else { "Green" })
  Write-Host "  Warnings:       " -NoNewline -ForegroundColor Gray
  Write-Host "$warnCount" -ForegroundColor $(if ($warnCount -gt 0) { "Yellow" } else { "Green" })
  Write-Host ""

  if ($blobExtents.Count -gt 0 -and $estimate) {
    Write-Host "  Data to Migrate:    " -NoNewline -ForegroundColor Gray
    Write-Host "$($estimate.TotalDataGB) GB ($($estimate.TotalDataTB) TB)" -ForegroundColor White
    Write-Host "  Estimated Duration: " -NoNewline -ForegroundColor Gray
    Write-Host "$($estimate.EstimatedDuration)" -ForegroundColor White
    Write-Host "  Vault Monthly Cost: " -NoNewline -ForegroundColor Gray
    Write-Host "`$$($estimate.MonthlyVaultCost)/month" -ForegroundColor Green
    Write-Host ""
  }

  Write-Host $separator -ForegroundColor Cyan
  Write-Host "  DELIVERABLES" -ForegroundColor White
  Write-Host $separator -ForegroundColor Cyan
  Write-Host ""
  Write-Host "  HTML Report:" -ForegroundColor White
  Write-Host "    $htmlPath" -ForegroundColor Gray
  Write-Host "  Pre-Flight Checks (CSV):" -ForegroundColor White
  Write-Host "    $csvPath" -ForegroundColor Gray
  Write-Host "  Execution Log:" -ForegroundColor White
  Write-Host "    $LogFile" -ForegroundColor Gray
  Write-Host ""

  if ($failCount -gt 0) {
    Write-Host $separator -ForegroundColor Red
    Write-Host "  NOT READY FOR MIGRATION - Resolve $failCount failure(s) first" -ForegroundColor Red
    Write-Host $separator -ForegroundColor Red
  } elseif ($AssessOnly) {
    Write-Host $separator -ForegroundColor Green
    Write-Host "  ASSESSMENT COMPLETE - Review the report and proceed with migration" -ForegroundColor Green
    Write-Host $separator -ForegroundColor Green
  } else {
    Write-Host $separator -ForegroundColor Green
    Write-Host "  MIGRATION PLANNING COMPLETE" -ForegroundColor Green
    Write-Host $separator -ForegroundColor Green
  }

  Write-Host ""
  Write-Log "Assessment completed successfully" -Level "SUCCESS"

} catch {
  Write-Host ""
  Write-Host "  FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host ""
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  exit 1

} finally {
  Write-Progress -Activity "Azure Blob to Veeam Vault Migration" -Completed

  # Disconnect VBR if connected
  try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch { }

  # Export final log
  if ($script:LogEntries.Count -gt 0) {
    $script:LogEntries | Export-Csv -Path $LogFile -NoTypeInformation -Force
  }
}

#endregion
