<#
.SYNOPSIS
  Veeam Azure DR Landing Zone - Estimation & Deployment Tool

.DESCRIPTION
  Helps Veeam customers who use Veeam Vault Advanced backups plan and create the Azure
  infrastructure scaffolding needed for disaster recovery (DR) to Azure VMs.

  Many customers have never set up an Azure DR subscription. This tool simplifies the
  journey by operating in two modes:

  MODE 1 - ESTIMATE (default, no Azure login required):
    Takes your VM count, storage capacity, and target region to produce a complete
    bill of materials showing every Azure component needed, with estimated monthly costs.
    Generates a professional HTML report and CSV you can share with stakeholders.

  MODE 2 - DEPLOY (requires Azure login):
    Actually creates the landing zone resources in your Azure subscription:
    - Resource Group with DR-specific tags
    - Virtual Network with recovery and management subnets
    - Network Security Groups with Veeam-optimized rules
    - Storage Account for Veeam staging and restore data
    - (Optional) VRO service principal role assignment

  After deployment, customers use Veeam Recovery Orchestrator (VRO) to run recovery
  plans that restore VMs into this landing zone.

  QUICK START (Estimate only):
    .\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2"

  QUICK START (Deploy):
    .\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2" -Deploy

.PARAMETER VMCount
  Number of VMs to plan DR capacity for. Used for VNet/subnet sizing, NSG rules,
  and compute cost estimation.

.PARAMETER SourceDataTB
  Total source data in terabytes across all VMs. Used for storage account sizing
  and Veeam repository capacity planning.

.PARAMETER Region
  Azure region for DR landing zone (e.g., "eastus2", "westus2", "westeurope").
  Should be different from your production region for geographic redundancy.

.PARAMETER VNetAddressSpace
  Virtual network address space in CIDR notation (default: "10.200.0.0/16").
  Must be large enough for recovery and management subnets.

.PARAMETER RecoverySubnetCIDR
  Subnet for recovered VMs (default: "10.200.1.0/24"). Supports up to 251 VMs.
  Increase to /22 for larger environments (1,019 VMs).

.PARAMETER ManagementSubnetCIDR
  Subnet for Veeam management components like VRO and proxy VMs
  (default: "10.200.0.0/24").

.PARAMETER NamingPrefix
  Prefix for all Azure resource names (default: "veeam-dr"). Resources will be
  named like "veeam-dr-rg", "veeam-dr-vnet", etc.

.PARAMETER TargetVMSize
  Default Azure VM size for cost estimation (default: "Standard_D4s_v5").
  4 vCPU / 16 GB RAM is a common DR target size.

.PARAMETER Deploy
  Switch to actually create Azure resources. Without this flag, the tool only
  generates an estimate report. Requires Azure authentication.

.PARAMETER SubscriptionId
  Target Azure subscription for deployment. Required when -Deploy is used.

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

.PARAMETER VROServicePrincipalId
  Application ID of the VRO service principal to grant Contributor access
  on the DR resource group. Optional - can be configured later in VRO.

.PARAMETER OutputPath
  Output folder for reports and CSVs (default: ./VeeamDRLandingZone_[timestamp]).

.PARAMETER GenerateHTML
  Generate professional HTML report (default: true).

.PARAMETER ZipOutput
  Create ZIP archive of all outputs (default: true).

.EXAMPLE
  .\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2"
  # Estimate mode - generates bill of materials and cost report

.EXAMPLE
  .\New-VeeamDRLandingZone.ps1 -VMCount 100 -SourceDataTB 50 -Region "westeurope" -TargetVMSize "Standard_D8s_v5"
  # Larger environment estimate with bigger target VM size

.EXAMPLE
  .\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2" -Deploy -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  # Deploy landing zone resources to Azure

.EXAMPLE
  .\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2" -Deploy -SubscriptionId "xxx" -VROServicePrincipalId "yyy"
  # Deploy and configure VRO service principal access

.NOTES
  Version: 1.0.0
  Author: Veeam Sales Engineering
  Date: 2026-02-15
  Requires: PowerShell 7.x (recommended) or 5.1
  Modules (Deploy mode only): Az.Accounts, Az.Resources, Az.Network, Az.Storage
#>

[CmdletBinding()]
param(
  # Workload sizing
  [Parameter(Mandatory=$true)]
  [ValidateRange(1, 5000)]
  [int]$VMCount,

  [Parameter(Mandatory=$true)]
  [ValidateRange(0.1, 10000)]
  [double]$SourceDataTB,

  [Parameter(Mandatory=$true)]
  [string]$Region = "eastus2",

  # Network configuration
  [string]$VNetAddressSpace = "10.200.0.0/16",
  [string]$RecoverySubnetCIDR = "10.200.1.0/24",
  [string]$ManagementSubnetCIDR = "10.200.0.0/24",

  # Naming
  [ValidatePattern('^[a-z][a-z0-9\-]{1,12}$')]
  [string]$NamingPrefix = "veeam-dr",

  # Compute estimation
  [string]$TargetVMSize = "Standard_D4s_v5",

  # Deploy mode
  [switch]$Deploy,
  [string]$SubscriptionId,
  [string]$TenantId,

  # Authentication (Deploy mode)
  [switch]$UseManagedIdentity,
  [string]$ServicePrincipalId,
  [securestring]$ServicePrincipalSecret,
  [string]$CertificateThumbprint,
  [switch]$UseDeviceCode,

  # VRO integration
  [string]$VROServicePrincipalId,

  # Output
  [string]$OutputPath,
  [switch]$GenerateHTML = $true,
  [switch]$ZipOutput = $true
)

#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Script-level variables
$script:StartTime = Get-Date
$script:LogEntries = New-Object System.Collections.Generic.List[object]
$script:TotalSteps = 0
$script:CurrentStep = 0

# Determine output folder
if (-not $OutputPath) {
  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutputPath = ".\VeeamDRLandingZone_$timestamp"
}

if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$LogFile = Join-Path $OutputPath "execution_log.csv"

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
  Write-Progress -Activity "Veeam DR Landing Zone" -Status "$Activity - $Status" -PercentComplete $percentComplete
  Write-Log "STEP $script:CurrentStep/$script:TotalSteps`: $Activity" -Level "INFO"
}

#endregion

#region Azure VM Pricing (Retail Prices API)

function Get-AzureVMPricing {
  param(
    [string]$VMSize,
    [string]$TargetRegion
  )

  try {
    $filter = "armRegionName eq '$TargetRegion' and armSkuName eq '$VMSize' and priceType eq 'Consumption'"
    $apiUrl = "https://prices.azure.com/api/retail/prices?`$filter=$filter"

    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop

    $linuxPrice = $response.Items | Where-Object {
      $_.productName -notlike "*Windows*" -and
      $_.meterName -like "*" -and
      $_.type -eq "Consumption" -and
      $_.unitOfMeasure -eq "1 Hour"
    } | Select-Object -First 1

    $windowsPrice = $response.Items | Where-Object {
      $_.productName -like "*Windows*" -and
      $_.type -eq "Consumption" -and
      $_.unitOfMeasure -eq "1 Hour"
    } | Select-Object -First 1

    return @{
      LinuxHourly = if ($linuxPrice) { $linuxPrice.retailPrice } else { 0.192 }
      WindowsHourly = if ($windowsPrice) { $windowsPrice.retailPrice } else { 0.384 }
      Currency = if ($linuxPrice) { $linuxPrice.currencyCode } else { "USD" }
    }

  } catch {
    Write-Log "Failed to query VM pricing API: $($_.Exception.Message)" -Level "WARNING"
    Write-Log "Using fallback pricing for $VMSize" -Level "WARNING"

    # Fallback pricing for Standard_D4s_v5 (approximate)
    return @{
      LinuxHourly = 0.192
      WindowsHourly = 0.384
      Currency = "USD"
    }
  }
}

function Get-AzureStoragePricing {
  param([string]$TargetRegion)

  try {
    $filter = "serviceName eq 'Storage' and priceType eq 'Consumption' and armRegionName eq '$TargetRegion'"
    $apiUrl = "https://prices.azure.com/api/retail/prices?`$filter=$filter"

    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop

    $lrsHot = $response.Items | Where-Object {
      $_.productName -like "*Block Blob*" -and
      $_.skuName -like "*LRS*" -and
      $_.meterName -like "*Hot*Data Stored*"
    } | Select-Object -First 1

    $managedDisk = $response.Items | Where-Object {
      $_.productName -like "*Managed Disks*" -and
      $_.meterName -like "*P30*"
    } | Select-Object -First 1

    return @{
      BlobHotPerGBMonth = if ($lrsHot) { $lrsHot.retailPrice } else { 0.0184 }
      ManagedDiskP30Monthly = if ($managedDisk) { $managedDisk.retailPrice } else { 122.88 }
      Currency = "USD"
    }

  } catch {
    Write-Log "Failed to query storage pricing API: $($_.Exception.Message)" -Level "WARNING"
    return @{
      BlobHotPerGBMonth = 0.0184
      ManagedDiskP30Monthly = 122.88
      Currency = "USD"
    }
  }
}

#endregion

#region Estimate & Bill of Materials

function Get-SubnetCapacity {
  param([string]$CIDR)

  $prefix = [int]($CIDR -split '/')[-1]
  # Azure reserves 5 addresses per subnet
  $totalAddresses = [math]::Pow(2, 32 - $prefix)
  $usableAddresses = $totalAddresses - 5
  return [math]::Max(0, [int]$usableAddresses)
}

function Build-BillOfMaterials {
  param(
    [int]$VMs,
    [double]$DataTB,
    [string]$TargetRegion,
    [string]$VMSize,
    [string]$Prefix
  )

  Write-ProgressStep -Activity "Building Bill of Materials" -Status "Calculating component requirements..."

  $dataGB = $DataTB * 1024
  $recoverySubnetCapacity = Get-SubnetCapacity -CIDR $RecoverySubnetCIDR
  $mgmtSubnetCapacity = Get-SubnetCapacity -CIDR $ManagementSubnetCIDR

  # Subnet capacity warning
  if ($VMs -gt $recoverySubnetCapacity) {
    Write-Log "WARNING: $VMs VMs exceed recovery subnet capacity of $recoverySubnetCapacity. Consider using a larger subnet (e.g., /22 for 1,019 hosts)." -Level "WARNING"
  }

  # Storage sizing: Veeam staging + restored VM managed disks
  # Staging area = source data * 1.2 (overhead for restore staging)
  $stagingStorageGB = [math]::Ceiling($dataGB * 1.2)
  # Managed disk estimate: average disk per VM
  $avgDiskPerVM_GB = [math]::Ceiling($dataGB / [math]::Max($VMs, 1))
  # Number of P30 (1 TB) managed disks needed (rough estimate)
  $managedDiskCount = [math]::Ceiling($dataGB / 1024)

  # VRO management components (proxy + orchestrator)
  $mgmtVMCount = if ($VMs -le 50) { 2 } elseif ($VMs -le 200) { 3 } else { 4 }

  # Build the BOM
  $bom = @(
    [PSCustomObject]@{
      Category = "Identity & Access"
      Component = "Resource Group"
      ResourceName = "$Prefix-rg"
      Specification = "DR workload container"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "Free - logical container for all DR resources"
    },
    [PSCustomObject]@{
      Category = "Networking"
      Component = "Virtual Network"
      ResourceName = "$Prefix-vnet"
      Specification = "$VNetAddressSpace"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "Free - address space for DR workloads"
    },
    [PSCustomObject]@{
      Category = "Networking"
      Component = "Recovery Subnet"
      ResourceName = "$Prefix-snet-recovery"
      Specification = "$RecoverySubnetCIDR ($recoverySubnetCapacity usable IPs)"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "For recovered VMs - capacity: $recoverySubnetCapacity VMs"
    },
    [PSCustomObject]@{
      Category = "Networking"
      Component = "Management Subnet"
      ResourceName = "$Prefix-snet-mgmt"
      Specification = "$ManagementSubnetCIDR ($mgmtSubnetCapacity usable IPs)"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "For VRO, Veeam proxies, and management VMs"
    },
    [PSCustomObject]@{
      Category = "Security"
      Component = "NSG - Recovery"
      ResourceName = "$Prefix-nsg-recovery"
      Specification = "Inbound: RDP/SSH (restricted), HTTPS; Outbound: Internet"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "Applied to recovery subnet - restrict source IPs post-deploy"
    },
    [PSCustomObject]@{
      Category = "Security"
      Component = "NSG - Management"
      ResourceName = "$Prefix-nsg-mgmt"
      Specification = "Inbound: HTTPS (443), Veeam (9392-9401); Outbound: Internet"
      Quantity = 1
      EstMonthlyUSD = 0
      Notes = "Applied to management subnet for VRO access"
    },
    [PSCustomObject]@{
      Category = "Storage"
      Component = "Storage Account"
      ResourceName = "$($Prefix -replace '-','')sa"
      Specification = "StorageV2, LRS, Hot tier, $stagingStorageGB GB"
      Quantity = 1
      EstMonthlyUSD = [math]::Round($stagingStorageGB * 0.0184, 2)
      Notes = "Staging area for Veeam restores and VRO data"
    },
    [PSCustomObject]@{
      Category = "Compute (DR Active)"
      Component = "Recovered VMs"
      ResourceName = "Restored workloads"
      Specification = "$VMSize ($VMs VMs)"
      Quantity = $VMs
      EstMonthlyUSD = 0
      Notes = "Cost only during DR event - not provisioned at setup"
    },
    [PSCustomObject]@{
      Category = "Compute (DR Active)"
      Component = "Managed Disks (P30)"
      ResourceName = "VM OS + Data disks"
      Specification = "1 TB Premium SSD per disk ($managedDiskCount disks)"
      Quantity = $managedDiskCount
      EstMonthlyUSD = 0
      Notes = "Cost only during DR event - not provisioned at setup"
    },
    [PSCustomObject]@{
      Category = "Management"
      Component = "VRO / Proxy VMs"
      ResourceName = "$Prefix-vro-*"
      Specification = "Standard_D2s_v5 ($mgmtVMCount VMs)"
      Quantity = $mgmtVMCount
      EstMonthlyUSD = [math]::Round($mgmtVMCount * 0.096 * 730, 2)
      Notes = "Always-on management VMs for VRO orchestration"
    }
  )

  return $bom
}

function Calculate-CostEstimate {
  param(
    [int]$VMs,
    [double]$DataTB,
    [string]$TargetRegion,
    [string]$VMSize,
    [object[]]$BOM
  )

  Write-ProgressStep -Activity "Calculating Cost Estimates" -Status "Querying Azure pricing APIs..."

  # Get real-time pricing
  $vmPricing = Get-AzureVMPricing -VMSize $VMSize -TargetRegion $TargetRegion
  $storagePricing = Get-AzureStoragePricing -TargetRegion $TargetRegion

  $dataGB = $DataTB * 1024
  $stagingStorageGB = [math]::Ceiling($dataGB * 1.2)
  $managedDiskCount = [math]::Ceiling($dataGB / 1024)
  $mgmtVMCount = if ($VMs -le 50) { 2 } elseif ($VMs -le 200) { 3 } else { 4 }

  # Always-on costs (monthly)
  $mgmtVMCostMonthly = [math]::Round($mgmtVMCount * $vmPricing.LinuxHourly * 730, 2)
  $storageCostMonthly = [math]::Round($stagingStorageGB * $storagePricing.BlobHotPerGBMonth, 2)
  $alwaysOnMonthly = $mgmtVMCostMonthly + $storageCostMonthly

  # DR-active costs (per day of failover)
  $computePerDayLinux = [math]::Round($VMs * $vmPricing.LinuxHourly * 24, 2)
  $computePerDayWindows = [math]::Round($VMs * $vmPricing.WindowsHourly * 24, 2)
  $diskPerDay = [math]::Round($managedDiskCount * ($storagePricing.ManagedDiskP30Monthly / 30), 2)
  $drActivePerDayLinux = $computePerDayLinux + $diskPerDay
  $drActivePerDayWindows = $computePerDayWindows + $diskPerDay

  # Example: 7-day failover scenario
  $failover7DayLinux = [math]::Round($drActivePerDayLinux * 7, 2)
  $failover7DayWindows = [math]::Round($drActivePerDayWindows * 7, 2)

  return [PSCustomObject]@{
    # Pricing inputs
    VMSizeUsed = $VMSize
    LinuxHourlyRate = $vmPricing.LinuxHourly
    WindowsHourlyRate = $vmPricing.WindowsHourly
    BlobPricePerGBMonth = $storagePricing.BlobHotPerGBMonth
    ManagedDiskP30Monthly = $storagePricing.ManagedDiskP30Monthly
    Currency = $vmPricing.Currency

    # Always-on costs
    MgmtVMCount = $mgmtVMCount
    MgmtVMCostMonthly = $mgmtVMCostMonthly
    StorageStagingGB = $stagingStorageGB
    StorageCostMonthly = $storageCostMonthly
    AlwaysOnMonthly = $alwaysOnMonthly
    AlwaysOnAnnual = [math]::Round($alwaysOnMonthly * 12, 2)

    # DR-active costs
    VMCount = $VMs
    ManagedDiskCount = $managedDiskCount
    ComputePerDayLinux = $computePerDayLinux
    ComputePerDayWindows = $computePerDayWindows
    DiskPerDay = $diskPerDay
    DRActivePerDayLinux = $drActivePerDayLinux
    DRActivePerDayWindows = $drActivePerDayWindows

    # Scenario: 7-day failover
    Failover7DayLinux = $failover7DayLinux
    Failover7DayWindows = $failover7DayWindows
    Failover7DayTotalLinux = [math]::Round($alwaysOnMonthly + $failover7DayLinux, 2)
    Failover7DayTotalWindows = [math]::Round($alwaysOnMonthly + $failover7DayWindows, 2)
  }
}

#endregion

#region Authentication (Deploy Mode)

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

  if (Test-AzSession) {
    return
  }

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

#endregion

#region Deploy Landing Zone

function Deploy-LandingZone {
  param(
    [string]$Prefix,
    [string]$TargetRegion,
    [string]$TargetSubscriptionId,
    [double]$DataTB,
    [int]$VMs
  )

  # Check for required modules
  $requiredModules = @('Az.Accounts', 'Az.Resources', 'Az.Network', 'Az.Storage')
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
    throw "Missing required Azure PowerShell modules: $($missingModules -join ', ')"
  }

  # Authenticate
  Connect-AzureModern

  # Set subscription context
  Write-ProgressStep -Activity "Setting Subscription Context" -Status "Switching to target subscription..."

  if ($TargetSubscriptionId) {
    Set-AzContext -SubscriptionId $TargetSubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Set context to subscription: $TargetSubscriptionId" -Level "SUCCESS"
  }

  $ctx = Get-AzContext
  Write-Log "Active subscription: $($ctx.Subscription.Name) [$($ctx.Subscription.Id)]" -Level "INFO"

  # Resource names
  $rgName = "$Prefix-rg"
  $vnetName = "$Prefix-vnet"
  $recoverySubnetName = "$Prefix-snet-recovery"
  $mgmtSubnetName = "$Prefix-snet-mgmt"
  $nsgRecoveryName = "$Prefix-nsg-recovery"
  $nsgMgmtName = "$Prefix-nsg-mgmt"
  $saName = ($Prefix -replace '-','') + "sa" + (Get-Date -Format "MMdd")
  # Storage account names must be 3-24 chars, lowercase alphanumeric
  $saName = ($saName -replace '[^a-z0-9]','').Substring(0, [math]::Min(24, $saName.Length))

  $tags = @{
    "Purpose"     = "Veeam-DR-LandingZone"
    "ManagedBy"   = "Veeam-Recovery-Orchestrator"
    "CreatedBy"   = "New-VeeamDRLandingZone"
    "CreatedDate" = (Get-Date -Format "yyyy-MM-dd")
    "VMCount"     = "$VMs"
    "SourceDataTB" = "$DataTB"
  }

  $deployedResources = @()

  # 1. Resource Group
  Write-ProgressStep -Activity "Creating Resource Group" -Status "$rgName in $TargetRegion..."

  $existingRG = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
  if ($existingRG) {
    Write-Log "Resource group '$rgName' already exists in $($existingRG.Location)" -Level "WARNING"
    $rg = $existingRG
  } else {
    $rg = New-AzResourceGroup -Name $rgName -Location $TargetRegion -Tag $tags -ErrorAction Stop
    Write-Log "Created resource group: $rgName" -Level "SUCCESS"
  }
  $deployedResources += [PSCustomObject]@{ Type = "Resource Group"; Name = $rgName; Status = "Created"; ResourceId = $rg.ResourceId }

  # 2. NSG - Recovery Subnet
  Write-ProgressStep -Activity "Creating NSG (Recovery)" -Status "$nsgRecoveryName..."

  $existingNSG1 = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $nsgRecoveryName -ErrorAction SilentlyContinue
  if ($existingNSG1) {
    Write-Log "NSG '$nsgRecoveryName' already exists" -Level "WARNING"
    $nsgRecovery = $existingNSG1
  } else {
    $rdpRule = New-AzNetworkSecurityRuleConfig -Name "Allow-RDP-Restricted" `
      -Description "RDP access - RESTRICT SOURCE IP POST-DEPLOYMENT" `
      -Access Allow -Protocol Tcp -Direction Inbound `
      -Priority 1000 -SourceAddressPrefix "VirtualNetwork" `
      -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "3389"

    $sshRule = New-AzNetworkSecurityRuleConfig -Name "Allow-SSH-Restricted" `
      -Description "SSH access - RESTRICT SOURCE IP POST-DEPLOYMENT" `
      -Access Allow -Protocol Tcp -Direction Inbound `
      -Priority 1010 -SourceAddressPrefix "VirtualNetwork" `
      -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "22"

    $httpsInRule = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS-Inbound" `
      -Description "HTTPS for application access" `
      -Access Allow -Protocol Tcp -Direction Inbound `
      -Priority 1020 -SourceAddressPrefix "VirtualNetwork" `
      -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "443"

    $nsgRecovery = New-AzNetworkSecurityGroup -ResourceGroupName $rgName -Location $TargetRegion `
      -Name $nsgRecoveryName -SecurityRules $rdpRule,$sshRule,$httpsInRule `
      -Tag $tags -ErrorAction Stop

    Write-Log "Created NSG: $nsgRecoveryName (RDP/SSH restricted to VNet, HTTPS)" -Level "SUCCESS"
  }
  $deployedResources += [PSCustomObject]@{ Type = "NSG"; Name = $nsgRecoveryName; Status = "Created"; ResourceId = $nsgRecovery.Id }

  # 3. NSG - Management Subnet
  Write-ProgressStep -Activity "Creating NSG (Management)" -Status "$nsgMgmtName..."

  $existingNSG2 = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $nsgMgmtName -ErrorAction SilentlyContinue
  if ($existingNSG2) {
    Write-Log "NSG '$nsgMgmtName' already exists" -Level "WARNING"
    $nsgMgmt = $existingNSG2
  } else {
    $httpsRule = New-AzNetworkSecurityRuleConfig -Name "Allow-HTTPS" `
      -Description "HTTPS for VRO console and API" `
      -Access Allow -Protocol Tcp -Direction Inbound `
      -Priority 1000 -SourceAddressPrefix "*" `
      -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "443"

    $veeamRule = New-AzNetworkSecurityRuleConfig -Name "Allow-Veeam-Ports" `
      -Description "Veeam backup infrastructure communication" `
      -Access Allow -Protocol Tcp -Direction Inbound `
      -Priority 1010 -SourceAddressPrefix "VirtualNetwork" `
      -SourcePortRange "*" -DestinationAddressPrefix "*" -DestinationPortRange "9392-9401"

    $nsgMgmt = New-AzNetworkSecurityGroup -ResourceGroupName $rgName -Location $TargetRegion `
      -Name $nsgMgmtName -SecurityRules $httpsRule,$veeamRule `
      -Tag $tags -ErrorAction Stop

    Write-Log "Created NSG: $nsgMgmtName (HTTPS + Veeam ports 9392-9401)" -Level "SUCCESS"
  }
  $deployedResources += [PSCustomObject]@{ Type = "NSG"; Name = $nsgMgmtName; Status = "Created"; ResourceId = $nsgMgmt.Id }

  # 4. Virtual Network with Subnets
  Write-ProgressStep -Activity "Creating Virtual Network" -Status "$vnetName with subnets..."

  $existingVNet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $vnetName -ErrorAction SilentlyContinue
  if ($existingVNet) {
    Write-Log "VNet '$vnetName' already exists" -Level "WARNING"
    $vnet = $existingVNet
  } else {
    $mgmtSubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $mgmtSubnetName `
      -AddressPrefix $ManagementSubnetCIDR -NetworkSecurityGroupId $nsgMgmt.Id

    $recoverySubnetConfig = New-AzVirtualNetworkSubnetConfig -Name $recoverySubnetName `
      -AddressPrefix $RecoverySubnetCIDR -NetworkSecurityGroupId $nsgRecovery.Id

    $vnet = New-AzVirtualNetwork -ResourceGroupName $rgName -Location $TargetRegion `
      -Name $vnetName -AddressPrefix $VNetAddressSpace `
      -Subnet $mgmtSubnetConfig,$recoverySubnetConfig `
      -Tag $tags -ErrorAction Stop

    Write-Log "Created VNet: $vnetName ($VNetAddressSpace) with 2 subnets" -Level "SUCCESS"
  }
  $deployedResources += [PSCustomObject]@{ Type = "Virtual Network"; Name = $vnetName; Status = "Created"; ResourceId = $vnet.Id }

  # 5. Storage Account
  Write-ProgressStep -Activity "Creating Storage Account" -Status "$saName..."

  $existingSA = Get-AzStorageAccount -ResourceGroupName $rgName -Name $saName -ErrorAction SilentlyContinue
  if ($existingSA) {
    Write-Log "Storage account '$saName' already exists" -Level "WARNING"
    $sa = $existingSA
  } else {
    $sa = New-AzStorageAccount -ResourceGroupName $rgName -Location $TargetRegion `
      -Name $saName -SkuName "Standard_LRS" -Kind "StorageV2" `
      -AccessTier "Hot" -MinimumTlsVersion "TLS1_2" `
      -AllowBlobPublicAccess $false `
      -Tag $tags -ErrorAction Stop

    Write-Log "Created storage account: $saName (StorageV2, LRS, Hot, TLS 1.2)" -Level "SUCCESS"
  }
  $deployedResources += [PSCustomObject]@{ Type = "Storage Account"; Name = $saName; Status = "Created"; ResourceId = $sa.Id }

  # 6. VRO Service Principal Role Assignment (optional)
  if ($VROServicePrincipalId) {
    Write-ProgressStep -Activity "Configuring VRO Access" -Status "Assigning Contributor role..."

    try {
      $existingAssignment = Get-AzRoleAssignment -ObjectId $VROServicePrincipalId `
        -ResourceGroupName $rgName -RoleDefinitionName "Contributor" -ErrorAction SilentlyContinue

      if ($existingAssignment) {
        Write-Log "VRO service principal already has Contributor on $rgName" -Level "WARNING"
      } else {
        New-AzRoleAssignment -ApplicationId $VROServicePrincipalId `
          -ResourceGroupName $rgName -RoleDefinitionName "Contributor" -ErrorAction Stop | Out-Null

        Write-Log "Granted Contributor role to VRO SP ($VROServicePrincipalId) on $rgName" -Level "SUCCESS"
      }
      $deployedResources += [PSCustomObject]@{ Type = "Role Assignment"; Name = "Contributor -> $VROServicePrincipalId"; Status = "Created"; ResourceId = $rgName }
    } catch {
      Write-Log "Failed to assign VRO role: $($_.Exception.Message)" -Level "WARNING"
      Write-Log "You can configure VRO access manually after deployment" -Level "INFO"
    }
  }

  return $deployedResources
}

#endregion

#region HTML Report Generation

function Generate-HTMLReport {
  param(
    [object[]]$BOM,
    [object]$CostEstimate,
    [object[]]$DeployedResources,
    [bool]$WasDeployed
  )

  Write-ProgressStep -Activity "Generating HTML Report" -Status "Creating professional report..."

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "$([math]::Floor($duration.TotalMinutes))m $($duration.Seconds)s"

  $mode = if ($WasDeployed) { "DEPLOYED" } else { "ESTIMATE" }
  $modeColor = if ($WasDeployed) { "#00B336" } else { "#0078D4" }
  $modeLabel = if ($WasDeployed) { "Resources Created in Azure" } else { "Planning Estimate - No Resources Created" }

  # Build BOM table rows
  $bomRows = $BOM | ForEach-Object {
    $costDisplay = if ($_.EstMonthlyUSD -gt 0) { "`$$([math]::Round($_.EstMonthlyUSD, 2))/mo" } else { "Free" }
    $costClass = if ($_.EstMonthlyUSD -gt 0) { "cost-value" } else { "cost-free" }
    @"
        <tr>
          <td><span class="category-badge">$($_.Category)</span></td>
          <td><strong>$($_.Component)</strong></td>
          <td class="mono">$($_.ResourceName)</td>
          <td>$($_.Specification)</td>
          <td class="$costClass">$costDisplay</td>
          <td class="notes">$($_.Notes)</td>
        </tr>
"@
  } | Out-String

  # Deployed resources table (only if deployed)
  $deployedSection = ""
  if ($WasDeployed -and $DeployedResources) {
    $deployedRows = $DeployedResources | ForEach-Object {
      @"
        <tr>
          <td><strong>$($_.Type)</strong></td>
          <td class="mono">$($_.Name)</td>
          <td><span class="status-badge">$($_.Status)</span></td>
        </tr>
"@
    } | Out-String

    $deployedSection = @"
    <div class="section">
      <h2 class="section-title">Deployed Resources</h2>
      <div class="info-card" style="border-left-color: #00B336;">
        <div class="info-card-title">All resources have been successfully created in Azure</div>
        <div class="info-card-text">The following resources are now available in your subscription.</div>
      </div>
      <table>
        <thead>
          <tr>
            <th>Resource Type</th>
            <th>Name</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          $deployedRows
        </tbody>
      </table>
    </div>
"@
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam Azure DR Landing Zone - $mode</title>
<style>
:root {
  --veeam-green: #00B336;
  --veeam-dark: #005f4b;
  --azure-blue: #0078D4;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --shadow-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
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
  border-left: 4px solid $modeColor;
  padding: 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-8);
}

.header-title { font-size: 32px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 8px; }
.header-subtitle { font-size: 16px; color: var(--ms-gray-90); margin-bottom: 8px; }

.header-mode {
  display: inline-block;
  padding: 4px 12px;
  background: $modeColor;
  color: white;
  border-radius: 4px;
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  margin-bottom: 16px;
}

.header-meta { display: flex; gap: 32px; flex-wrap: wrap; font-size: 13px; color: var(--ms-gray-90); }

.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 20px; margin-bottom: 32px; }

.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-4);
  border-top: 3px solid var(--veeam-green);
}

.kpi-card.azure { border-top-color: var(--azure-blue); }
.kpi-card.warning { border-top-color: #f59e0b; }

.kpi-label { font-size: 12px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 8px; }
.kpi-value { font-size: 32px; font-weight: 300; color: var(--ms-gray-160); margin-bottom: 4px; }
.kpi-subtext { font-size: 13px; color: var(--ms-gray-90); }

.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-4);
}

.section-title {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--ms-gray-30);
}

table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 16px; }
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

td { padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); }
tbody tr:hover { background: var(--ms-gray-10); }

.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--azure-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}

.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 14px; line-height: 1.6; }

.mono { font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 13px; }
.cost-value { font-weight: 600; color: var(--azure-blue); }
.cost-free { color: var(--veeam-green); font-weight: 600; }
.notes { font-size: 13px; color: var(--ms-gray-90); max-width: 280px; }

.category-badge {
  display: inline-block;
  padding: 2px 8px;
  background: var(--ms-gray-20);
  border-radius: 4px;
  font-size: 11px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  color: var(--ms-gray-90);
  white-space: nowrap;
}

.status-badge {
  display: inline-block;
  padding: 2px 10px;
  background: #dcfce7;
  color: #166534;
  border-radius: 4px;
  font-size: 12px;
  font-weight: 600;
}

.cost-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-top: 16px; }

.cost-card {
  padding: 20px;
  border-radius: 4px;
  border: 1px solid var(--ms-gray-30);
}

.cost-card.always-on { background: #f0fdf4; border-left: 4px solid var(--veeam-green); }
.cost-card.dr-active { background: #fff7ed; border-left: 4px solid #f59e0b; }
.cost-card.scenario { background: #eff6ff; border-left: 4px solid var(--azure-blue); }

.cost-card-title { font-size: 12px; font-weight: 600; text-transform: uppercase; color: var(--ms-gray-90); margin-bottom: 8px; }
.cost-card-value { font-size: 28px; font-weight: 300; margin-bottom: 4px; }
.cost-card-detail { font-size: 13px; color: var(--ms-gray-90); margin-top: 4px; }

.next-steps-list { list-style: none; padding: 0; }
.next-steps-list li {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  display: flex;
  align-items: flex-start;
  gap: 12px;
}
.next-steps-list li:last-child { border-bottom: none; }
.step-number {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 28px;
  height: 28px;
  background: var(--veeam-green);
  color: white;
  border-radius: 50%;
  font-size: 13px;
  font-weight: 600;
  flex-shrink: 0;
}

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
    <div class="header-mode">$mode</div>
    <div class="header-title">Veeam Azure DR Landing Zone</div>
    <div class="header-subtitle">$modeLabel</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>Region:</strong> $Region</span>
      <span><strong>VM Target Size:</strong> $TargetVMSize</span>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">VMs to Protect</div>
      <div class="kpi-value">$VMCount</div>
      <div class="kpi-subtext">DR-eligible virtual machines</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Source Data</div>
      <div class="kpi-value">$SourceDataTB TB</div>
      <div class="kpi-subtext">$([math]::Round($SourceDataTB * 1024, 0)) GB total capacity</div>
    </div>
    <div class="kpi-card azure">
      <div class="kpi-label">Always-On Cost</div>
      <div class="kpi-value">`$$($CostEstimate.AlwaysOnMonthly)/mo</div>
      <div class="kpi-subtext">Management VMs + staging storage</div>
    </div>
    <div class="kpi-card warning">
      <div class="kpi-label">7-Day Failover Cost</div>
      <div class="kpi-value">`$$($CostEstimate.Failover7DayTotalWindows)</div>
      <div class="kpi-subtext">Windows VMs (one-time DR event)</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Bill of Materials</h2>
    <div class="info-card">
      <div class="info-card-title">Azure Components Required for Veeam DR</div>
      <div class="info-card-text">
        These are the Azure infrastructure components needed to establish a DR landing zone
        for <strong>$VMCount VMs</strong> with <strong>$SourceDataTB TB</strong> of source data.
        Components marked "Free" have no Azure charges. DR-active costs only apply during an actual failover event.
      </div>
    </div>
    <table>
      <thead>
        <tr>
          <th>Category</th>
          <th>Component</th>
          <th>Resource Name</th>
          <th>Specification</th>
          <th>Est. Cost</th>
          <th>Notes</th>
        </tr>
      </thead>
      <tbody>
        $bomRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <h2 class="section-title">Cost Breakdown</h2>
    <div class="info-card">
      <div class="info-card-title">How DR Landing Zone Costs Work</div>
      <div class="info-card-text">
        Your DR landing zone has two cost categories: <strong>always-on costs</strong> for the management
        infrastructure that keeps your DR ready, and <strong>DR-active costs</strong> that only apply when
        you actually fail over during a disaster. This pay-as-you-go model keeps your DR readiness
        affordable while providing full capacity when needed.
      </div>
    </div>

    <div class="cost-grid">
      <div class="cost-card always-on">
        <div class="cost-card-title">Always-On Monthly</div>
        <div class="cost-card-value" style="color: var(--veeam-green);">`$$($CostEstimate.AlwaysOnMonthly)</div>
        <div class="cost-card-detail">Management VMs ($($CostEstimate.MgmtVMCount)x D2s_v5): `$$($CostEstimate.MgmtVMCostMonthly)/mo</div>
        <div class="cost-card-detail">Staging Storage ($($CostEstimate.StorageStagingGB) GB): `$$($CostEstimate.StorageCostMonthly)/mo</div>
        <div class="cost-card-detail"><strong>Annual:</strong> `$$($CostEstimate.AlwaysOnAnnual)</div>
      </div>

      <div class="cost-card dr-active">
        <div class="cost-card-title">DR-Active (Per Day)</div>
        <div class="cost-card-value" style="color: #f59e0b;">`$$($CostEstimate.DRActivePerDayWindows)</div>
        <div class="cost-card-detail">Compute ($VMCount VMs @ $TargetVMSize): `$$($CostEstimate.ComputePerDayWindows)/day</div>
        <div class="cost-card-detail">Managed Disks ($($CostEstimate.ManagedDiskCount) P30): `$$($CostEstimate.DiskPerDay)/day</div>
        <div class="cost-card-detail">Linux VMs alternative: `$$($CostEstimate.DRActivePerDayLinux)/day</div>
      </div>

      <div class="cost-card scenario">
        <div class="cost-card-title">Scenario: 7-Day Failover</div>
        <div class="cost-card-value" style="color: var(--azure-blue);">`$$($CostEstimate.Failover7DayTotalWindows)</div>
        <div class="cost-card-detail">Always-on (1 month): `$$($CostEstimate.AlwaysOnMonthly)</div>
        <div class="cost-card-detail">DR compute + disks (7 days): `$$($CostEstimate.Failover7DayWindows)</div>
        <div class="cost-card-detail">Linux VMs scenario: `$$($CostEstimate.Failover7DayTotalLinux)</div>
      </div>
    </div>

    <div class="info-card" style="margin-top: 24px; border-left-color: #f59e0b;">
      <div class="info-card-title">Pricing Notes</div>
      <div class="info-card-text">
        <ul style="margin: 8px 0 0 20px;">
          <li>VM pricing: $TargetVMSize at `$$($CostEstimate.LinuxHourlyRate)/hr (Linux) or `$$($CostEstimate.WindowsHourlyRate)/hr (Windows)</li>
          <li>Managed disks: P30 (1 TB Premium SSD) at `$$($CostEstimate.ManagedDiskP30Monthly)/month per disk</li>
          <li>Storage: Blob Hot tier at `$$($CostEstimate.BlobPricePerGBMonth)/GB/month (LRS)</li>
          <li>Pricing source: Azure Retail Prices API (real-time query)</li>
          <li>Actual costs will vary based on VM sizes, disk types, and runtime duration</li>
        </ul>
      </div>
    </div>
  </div>

  $deployedSection

  <div class="section">
    <h2 class="section-title">Architecture Overview</h2>
    <div class="info-card" style="border-left-color: var(--veeam-green);">
      <div class="info-card-title">Veeam DR Landing Zone Architecture</div>
      <div class="info-card-text" style="font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 13px; line-height: 1.8; white-space: pre;">
Azure Subscription ($Region)
+-- Resource Group: $NamingPrefix-rg
    |
    +-- Virtual Network: $NamingPrefix-vnet ($VNetAddressSpace)
    |   |
    |   +-- Subnet: $NamingPrefix-snet-mgmt ($ManagementSubnetCIDR)
    |   |   +-- NSG: $NamingPrefix-nsg-mgmt (HTTPS + Veeam ports)
    |   |   +-- VRO Server VM
    |   |   +-- Veeam Proxy VM(s)
    |   |
    |   +-- Subnet: $NamingPrefix-snet-recovery ($RecoverySubnetCIDR)
    |       +-- NSG: $NamingPrefix-nsg-recovery (RDP/SSH restricted)
    |       +-- [Recovered VMs appear here during DR]
    |
    +-- Storage Account: $($NamingPrefix -replace '-','')sa
        +-- Blob containers for Veeam staging data
        +-- Restore point metadata</div>
    </div>
  </div>

  <div class="section">
    <h2 class="section-title">Next Steps</h2>
    <ul class="next-steps-list">
      $(if (-not $WasDeployed) {
        '<li><span class="step-number">1</span><div><strong>Deploy the Landing Zone</strong><br>Run this tool again with the <code>-Deploy</code> flag to create all resources in Azure:<br><code style="display:block; margin-top:8px; padding:8px; background:var(--ms-gray-20); border-radius:4px;">.\New-VeeamDRLandingZone.ps1 -VMCount ' + $VMCount + ' -SourceDataTB ' + $SourceDataTB + ' -Region "' + $Region + '" -Deploy -SubscriptionId "your-sub-id"</code></div></li>'
      } else {
        '<li><span class="step-number">1</span><div><strong>Landing Zone Deployed</strong><br>All Azure resources have been created successfully.</div></li>'
      })
      <li><span class="step-number">$(if ($WasDeployed) { '2' } else { '2' })</span>
        <div><strong>Configure VNet Peering or VPN</strong><br>Connect the DR VNet to your on-premises network or production VNet via VPN Gateway or VNet Peering for Veeam data transfer.</div>
      </li>
      <li><span class="step-number">$(if ($WasDeployed) { '3' } else { '3' })</span>
        <div><strong>Set Up Veeam Recovery Orchestrator (VRO)</strong><br>Deploy VRO in the management subnet. Configure it to connect to your Veeam Backup & Replication server and Veeam Vault Advanced repository.</div>
      </li>
      <li><span class="step-number">$(if ($WasDeployed) { '4' } else { '4' })</span>
        <div><strong>Create Recovery Plans in VRO</strong><br>Define recovery plans that map your production VMs to DR targets in the recovery subnet. Configure VM sizing, networking, and boot order.</div>
      </li>
      <li><span class="step-number">$(if ($WasDeployed) { '5' } else { '5' })</span>
        <div><strong>Restrict NSG Rules</strong><br>Update NSG source IP ranges from "VirtualNetwork" to specific admin IPs for RDP/SSH access. Review and tighten security rules for your environment.</div>
      </li>
      <li><span class="step-number">$(if ($WasDeployed) { '6' } else { '6' })</span>
        <div><strong>Test DR Readiness</strong><br>Run a VRO test failover to validate that VMs can be restored into the landing zone. Verify network connectivity, application functionality, and failback procedures.</div>
      </li>
    </ul>
  </div>

  <div class="section">
    <h2 class="section-title">Methodology & Assumptions</h2>
    <div class="info-card">
      <div class="info-card-title">Sizing Assumptions</div>
      <div class="info-card-text">
        <ul style="margin: 8px 0 0 20px;">
          <li><strong>Staging Storage:</strong> Source data x 1.2 overhead for restore staging and metadata</li>
          <li><strong>Management VMs:</strong> 2 VMs for 1-50 source VMs, 3 for 51-200, 4 for 200+</li>
          <li><strong>Managed Disks:</strong> Estimated as source data / 1 TB per P30 disk (conservative)</li>
          <li><strong>Network Sizing:</strong> /24 subnet supports up to 251 VMs; use /22 for larger environments</li>
          <li><strong>DR-Active Costs:</strong> Only incurred during actual failover events; VMs are not pre-provisioned</li>
        </ul>
      </div>
    </div>
    <div class="info-card" style="border-left-color: var(--veeam-green);">
      <div class="info-card-title">What This Tool Does NOT Create</div>
      <div class="info-card-text">
        <ul style="margin: 8px 0 0 20px;">
          <li><strong>VPN Gateway / ExpressRoute:</strong> Network connectivity to on-premises must be configured separately</li>
          <li><strong>Veeam Recovery Orchestrator:</strong> VRO server deployment is handled through Veeam installation media</li>
          <li><strong>Recovery Plans:</strong> DR orchestration plans are configured within VRO console</li>
          <li><strong>DNS Configuration:</strong> Custom DNS settings depend on your domain architecture</li>
          <li><strong>Azure Active Directory:</strong> Identity and access policies are managed at the tenant level</li>
        </ul>
      </div>
    </div>
  </div>

  <div class="footer">
    <p>&copy; 2026 Veeam Software | DR Landing Zone Assessment Tool v1.0.0</p>
    <p>Pricing estimates based on Azure Retail Prices API. Actual costs may vary. Contact your Veeam Solutions Architect for detailed DR planning.</p>
  </div>
</div>
</body>
</html>
"@

  $htmlPath = Join-Path $OutputPath "Veeam-DR-LandingZone-Report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8

  Write-Log "Generated HTML report: $htmlPath" -Level "SUCCESS"
  return $htmlPath
}

#endregion

#region Main Execution

try {
  # Set step count based on mode
  if ($Deploy) {
    $script:TotalSteps = if ($VROServicePrincipalId) { 12 } else { 11 }
  } else {
    $script:TotalSteps = 5
  }

  # Validate Deploy mode requirements
  if ($Deploy -and -not $SubscriptionId) {
    throw "The -SubscriptionId parameter is required when using -Deploy. Specify the Azure subscription where the DR landing zone should be created."
  }

  # Header
  $headerWidth = 80
  $separator = "=" * $headerWidth

  Write-Host "`n$separator" -ForegroundColor Cyan
  Write-Host "  VEEAM AZURE DR LANDING ZONE TOOL" -ForegroundColor White
  Write-Host "  Veeam Software - Sales Engineering" -ForegroundColor Gray
  Write-Host "$separator`n" -ForegroundColor Cyan

  $modeDisplay = if ($Deploy) { "DEPLOY (creating Azure resources)" } else { "ESTIMATE (planning only)" }
  Write-Host "  Mode: " -NoNewline -ForegroundColor Gray
  if ($Deploy) {
    Write-Host $modeDisplay -ForegroundColor Green
  } else {
    Write-Host $modeDisplay -ForegroundColor Cyan
  }
  Write-Host ""

  Write-Host "  Configuration:" -ForegroundColor White
  Write-Host "    VMs to Protect        : " -NoNewline -ForegroundColor Gray
  Write-Host "$VMCount" -ForegroundColor White
  Write-Host "    Source Data            : " -NoNewline -ForegroundColor Gray
  Write-Host "$SourceDataTB TB ($([math]::Round($SourceDataTB * 1024, 0)) GB)" -ForegroundColor White
  Write-Host "    Target Region          : " -NoNewline -ForegroundColor Gray
  Write-Host "$Region" -ForegroundColor White
  Write-Host "    Target VM Size         : " -NoNewline -ForegroundColor Gray
  Write-Host "$TargetVMSize" -ForegroundColor White
  Write-Host "    VNet Address Space     : " -NoNewline -ForegroundColor Gray
  Write-Host "$VNetAddressSpace" -ForegroundColor White
  Write-Host "    Recovery Subnet        : " -NoNewline -ForegroundColor Gray
  Write-Host "$RecoverySubnetCIDR" -ForegroundColor White
  Write-Host "    Management Subnet      : " -NoNewline -ForegroundColor Gray
  Write-Host "$ManagementSubnetCIDR" -ForegroundColor White
  Write-Host "    Naming Prefix          : " -NoNewline -ForegroundColor Gray
  Write-Host "$NamingPrefix" -ForegroundColor White
  if ($Deploy) {
    Write-Host "    Subscription           : " -NoNewline -ForegroundColor Gray
    Write-Host "$SubscriptionId" -ForegroundColor White
  }
  Write-Host ""
  Write-Host "  Output Directory: " -NoNewline -ForegroundColor Gray
  Write-Host "$OutputPath`n" -ForegroundColor White

  # Step 1: Build Bill of Materials
  Write-Host "[1/$script:TotalSteps] " -NoNewline -ForegroundColor Cyan
  Write-Host "Building bill of materials..." -ForegroundColor White

  $bom = Build-BillOfMaterials -VMs $VMCount -DataTB $SourceDataTB `
    -TargetRegion $Region -VMSize $TargetVMSize -Prefix $NamingPrefix

  Write-Host "         " -NoNewline
  Write-Host "+" -NoNewline -ForegroundColor Green
  Write-Host " Identified $($bom.Count) Azure components`n" -ForegroundColor Gray

  # Step 2: Calculate Cost Estimates
  Write-Host "[2/$script:TotalSteps] " -NoNewline -ForegroundColor Cyan
  Write-Host "Calculating cost estimates (querying Azure pricing API)..." -ForegroundColor White

  $costEstimate = Calculate-CostEstimate -VMs $VMCount -DataTB $SourceDataTB `
    -TargetRegion $Region -VMSize $TargetVMSize -BOM $bom

  Write-Host "         " -NoNewline
  Write-Host "+" -NoNewline -ForegroundColor Green
  Write-Host " Retrieved real-time pricing for $Region`n" -ForegroundColor Gray

  # Step 3: Export BOM CSV
  Write-Host "[3/$script:TotalSteps] " -NoNewline -ForegroundColor Cyan
  Write-Host "Exporting bill of materials..." -ForegroundColor White

  $bomCsvPath = Join-Path $OutputPath "dr_bill_of_materials.csv"
  $bom | Export-Csv -Path $bomCsvPath -NoTypeInformation -Encoding UTF8

  $costCsvPath = Join-Path $OutputPath "dr_cost_estimate.csv"
  $costEstimate | Export-Csv -Path $costCsvPath -NoTypeInformation -Encoding UTF8

  Write-Host "         " -NoNewline
  Write-Host "+" -NoNewline -ForegroundColor Green
  Write-Host " Created: dr_bill_of_materials.csv, dr_cost_estimate.csv`n" -ForegroundColor Gray

  # Deploy mode: create Azure resources
  $deployedResources = @()
  if ($Deploy) {
    Write-Host ""
    Write-Host "  $separator" -ForegroundColor Green
    Write-Host "  DEPLOYING AZURE RESOURCES" -ForegroundColor White
    Write-Host "  $separator`n" -ForegroundColor Green

    $deployedResources = Deploy-LandingZone -Prefix $NamingPrefix -TargetRegion $Region `
      -TargetSubscriptionId $SubscriptionId -DataTB $SourceDataTB -VMs $VMCount

    $deployedCsvPath = Join-Path $OutputPath "deployed_resources.csv"
    $deployedResources | Export-Csv -Path $deployedCsvPath -NoTypeInformation -Encoding UTF8

    Write-Host ""
    Write-Host "         " -NoNewline
    Write-Host "+" -NoNewline -ForegroundColor Green
    Write-Host " Deployed $($deployedResources.Count) Azure resources`n" -ForegroundColor Gray
  }

  # Generate HTML Report
  $stepNum = if ($Deploy) { $script:TotalSteps - 1 } else { 4 }
  Write-Host "[$stepNum/$script:TotalSteps] " -NoNewline -ForegroundColor Cyan
  Write-Host "Generating professional HTML report..." -ForegroundColor White

  $htmlPath = Generate-HTMLReport -BOM $bom -CostEstimate $costEstimate `
    -DeployedResources $deployedResources -WasDeployed $Deploy.IsPresent

  Write-Host "         " -NoNewline
  Write-Host "+" -NoNewline -ForegroundColor Green
  Write-Host " Created: Veeam-DR-LandingZone-Report.html`n" -ForegroundColor Gray

  # Export log
  $logPath = Join-Path $OutputPath "execution_log.csv"
  $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath

  # Create ZIP archive
  if ($ZipOutput) {
    $lastStep = $script:TotalSteps
    Write-Host "[$lastStep/$lastStep] " -NoNewline -ForegroundColor Cyan
    Write-Host "Creating ZIP archive..." -ForegroundColor White

    $zipPath = Join-Path (Split-Path $OutputPath -Parent) "$(Split-Path $OutputPath -Leaf).zip"
    Compress-Archive -Path "$OutputPath\*" -DestinationPath $zipPath -Force

    Write-Host "         " -NoNewline
    Write-Host "+" -NoNewline -ForegroundColor Green
    Write-Host " Created: $(Split-Path $zipPath -Leaf)`n" -ForegroundColor Gray
  }

  # Summary
  Write-Progress -Activity "Veeam DR Landing Zone" -Completed

  Write-Host "$separator" -ForegroundColor Cyan
  Write-Host "  COST SUMMARY" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Cyan

  Write-Host "  Always-On Costs (monthly):" -ForegroundColor White
  Write-Host "    Management VMs ($($costEstimate.MgmtVMCount)x D2s_v5) : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.MgmtVMCostMonthly)/mo" -ForegroundColor Green
  Write-Host "    Staging Storage ($($costEstimate.StorageStagingGB) GB)  : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.StorageCostMonthly)/mo" -ForegroundColor Green
  Write-Host "    ────────────────────────────────────────" -ForegroundColor Gray
  Write-Host "    Total Always-On                : " -NoNewline -ForegroundColor White
  Write-Host "`$$($costEstimate.AlwaysOnMonthly)/mo (`$$($costEstimate.AlwaysOnAnnual)/yr)" -ForegroundColor Green

  Write-Host ""
  Write-Host "  DR-Active Costs (per day of failover):" -ForegroundColor White
  Write-Host "    $VMCount VMs (Windows @ $TargetVMSize)  : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.ComputePerDayWindows)/day" -ForegroundColor Yellow
  Write-Host "    $VMCount VMs (Linux @ $TargetVMSize)    : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.ComputePerDayLinux)/day" -ForegroundColor Yellow
  Write-Host "    Managed Disks ($($costEstimate.ManagedDiskCount) P30)        : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.DiskPerDay)/day" -ForegroundColor Yellow

  Write-Host ""
  Write-Host "  Example: 7-Day Failover Event:" -ForegroundColor White
  Write-Host "    Windows workloads              : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.Failover7DayTotalWindows)" -ForegroundColor Cyan
  Write-Host "    Linux workloads                : " -NoNewline -ForegroundColor Gray
  Write-Host "`$$($costEstimate.Failover7DayTotalLinux)" -ForegroundColor Cyan

  Write-Host ""
  Write-Host "$separator" -ForegroundColor Cyan
  Write-Host "  DELIVERABLES" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Cyan
  Write-Host "  HTML Report:" -ForegroundColor White
  Write-Host "    $htmlPath" -ForegroundColor Gray
  Write-Host "  Bill of Materials (CSV):" -ForegroundColor White
  Write-Host "    $bomCsvPath" -ForegroundColor Gray
  Write-Host "  Cost Estimate (CSV):" -ForegroundColor White
  Write-Host "    $costCsvPath" -ForegroundColor Gray
  if ($Deploy -and $deployedResources.Count -gt 0) {
    Write-Host "  Deployed Resources (CSV):" -ForegroundColor White
    Write-Host "    $deployedCsvPath" -ForegroundColor Gray
  }
  Write-Host "  Execution Log:" -ForegroundColor White
  Write-Host "    $logPath" -ForegroundColor Gray
  if ($ZipOutput) {
    Write-Host "  ZIP Archive:" -ForegroundColor White
    Write-Host "    $zipPath" -ForegroundColor Gray
  }
  Write-Host ""

  if ($Deploy) {
    Write-Host "$separator" -ForegroundColor Green
    Write-Host "  " -NoNewline
    Write-Host "+" -NoNewline -ForegroundColor Green
    Write-Host " LANDING ZONE DEPLOYED SUCCESSFULLY" -ForegroundColor White
    Write-Host "$separator`n" -ForegroundColor Green
    Write-Host "  Next: Configure VNet peering/VPN, deploy VRO, create recovery plans." -ForegroundColor Gray
  } else {
    Write-Host "$separator" -ForegroundColor Green
    Write-Host "  " -NoNewline
    Write-Host "+" -NoNewline -ForegroundColor Green
    Write-Host " ESTIMATE COMPLETE" -ForegroundColor White
    Write-Host "$separator`n" -ForegroundColor Green
    Write-Host "  Ready to deploy? Run:" -ForegroundColor Gray
    Write-Host "    .\New-VeeamDRLandingZone.ps1 -VMCount $VMCount -SourceDataTB $SourceDataTB -Region `"$Region`" -Deploy -SubscriptionId `"your-sub-id`"" -ForegroundColor Cyan
  }

  Write-Host ""
  Write-Log "Assessment completed successfully" -Level "SUCCESS"

} catch {
  Write-Host "`n" -NoNewline
  Write-Host "X ERROR: " -NoNewline -ForegroundColor Red
  Write-Host "$($_.Exception.Message)`n" -ForegroundColor White
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"

  # Export log even on failure
  if ($script:LogEntries.Count -gt 0 -and $OutputPath) {
    try {
      $logPath = Join-Path $OutputPath "execution_log.csv"
      $script:LogEntries | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $logPath
    } catch { }
  }

  exit 1
} finally {
  Write-Progress -Activity "Veeam DR Landing Zone" -Completed
}

#endregion
