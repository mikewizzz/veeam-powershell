<#
.SYNOPSIS
  Veeam Vault vs Azure Blob Storage Cost Comparison Tool

.DESCRIPTION
  Helps Veeam Sales Engineers compare Veeam Vault Foundation pricing against DIY Azure Blob 
  storage options. Provides factual cost analysis for presales conversations.
  
  Common Sales Scenarios:
  1. Net New Customer - Existing backup solutions needing offsite cloud storage
  2. Existing Veeam Customer - Using Azure Blob today, evaluating Veeam Vault cost-effectiveness
  
  Pricing Sources:
  - Veeam Vault Foundation: $14/TB/month (factual as of 2026)
  - Azure Blob Storage: Real-time pricing from Azure Retail Prices API
  - Includes storage tiers: Hot, Cool, Archive
  - Includes egress costs and operations pricing
  - Shows 1-year and 3-year reservation discounts

.PARAMETER CapacityTB
  Total backup storage capacity in terabytes

.PARAMETER Region
  Azure region for pricing comparison (e.g., "eastus", "westeurope")

.PARAMETER MonthlyChangeRatePercent
  Estimated monthly data change rate (default: 10%)

.PARAMETER AnnualGrowthPercent
  Estimated annual data growth rate (default: 20%)

.PARAMETER YearsToProject
  Number of years to project TCO (default: 3)

.PARAMETER EgressGB
  Expected monthly data egress in GB (default: 0)

.PARAMETER ApiOperationsPerTBMonth
  Estimated Azure API operations per TB per month for Veeam backups with immutability.
  Default: 500,000 operations/TB/month (realistic for incremental backups + immutability validation)
  High churn environments: 1,000,000+ operations/TB/month
  
  Why this matters:
  - Veeam v13 with Azure Blob requires frequent API calls for immutability (30-day requirement)
  - Daily incrementals: Block uploads, commits, metadata updates
  - Immutability validation: Regular reads and lists
  - Veeam Vault Foundation: ALL operations included at $14/TB/month (no extra charges)

.PARAMETER OutputPath
  Custom output folder for reports

.EXAMPLE
  .\Get-VeeamVaultPricing.ps1 -CapacityTB 10 -Region "eastus"

.EXAMPLE
  .\Get-VeeamVaultPricing.ps1 -CapacityTB 50 -Region "westeurope" -YearsToProject 5

.EXAMPLE
  .\Get-VeeamVaultPricing.ps1 -CapacityTB 100 -Region "eastus" -EgressGB 1000 -AnnualGrowthPercent 30

.EXAMPLE
  .\Get-VeeamVaultPricing.ps1 -CapacityTB 100 -Region "eastus" -ApiOperationsPerTBMonth 1000000

.NOTES
  Author: Veeam Sales Engineering
  Version: 1.0.0
  Date: 2026-01-06
  Requires: PowerShell 7.x or 5.1
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [ValidateRange(0.1, 10000)]
  [double]$CapacityTB,
  
  [Parameter(Mandatory=$true)]
  [string]$Region = "eastus",
  
  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 100)]
  [double]$MonthlyChangeRatePercent = 10,
  
  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 200)]
  [double]$AnnualGrowthPercent = 20,
  
  [Parameter(Mandatory=$false)]
  [ValidateRange(1, 10)]
  [int]$YearsToProject = 3,
  
  [Parameter(Mandatory=$false)]
  [double]$EgressGB = 0,
  
  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 10000000)]
  [int]$ApiOperationsPerTBMonth = 500000,
  
  [Parameter(Mandatory=$false)]
  [string]$OutputPath = ".\VeeamVaultPricing_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

#Requires -Version 5.1

# Veeam Vault Pricing (Factual as of 2026)
$VeeamVaultFoundationPricePerTBMonth = 14.00

# Create output directory
if (-not (Test-Path $OutputPath)) {
  New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$LogFile = Join-Path $OutputPath "execution_log.csv"

#region Helper Functions

function Write-Log {
  param(
    [string]$Message,
    [ValidateSet("INFO", "WARNING", "ERROR", "SUCCESS")]
    [string]$Level = "INFO"
  )
  
  $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $logEntry = [PSCustomObject]@{
    Timestamp = $timestamp
    Level = $Level
    Message = $Message
  }
  
  $logEntry | Export-Csv -Path $LogFile -Append -NoTypeInformation
  
  $color = switch ($Level) {
    "ERROR" { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default { "White" }
  }
  
  Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Get-AzureBlobPricing {
  param(
    [string]$Region,
    [string]$Tier
  )
  
  Write-Log "Querying Azure Retail Prices API for $Tier tier in $Region"
  
  try {
    # Azure Retail Prices API
    $filter = "serviceName eq 'Storage' and priceType eq 'Consumption' and armRegionName eq '$Region'"
    $apiUrl = "https://prices.azure.com/api/retail/prices?`$filter=$filter"
    
    $response = Invoke-RestMethod -Uri $apiUrl -Method Get -ErrorAction Stop
    
    # Find pricing for Block Blob storage
    $tierFilter = switch ($Tier) {
      "Hot" { "General Block Blob" }
      "Cool" { "Cool" }
      "Archive" { "Archive" }
    }
    
    $storagePricing = $response.Items | Where-Object {
      $_.productName -like "*Block Blob*" -and
      $_.meterName -like "*Data Stored*" -and
      $_.meterName -like "*$tierFilter*"
    } | Select-Object -First 1
    
    $egressPricing = $response.Items | Where-Object {
      $_.productName -like "*Bandwidth*" -and
      $_.meterName -like "*Data Transfer Out*"
    } | Select-Object -First 1
    
    # API Operations pricing
    $writePricing = $response.Items | Where-Object {
      $_.productName -like "*Block Blob*" -and
      $_.meterName -like "*Write Operations*"
    } | Select-Object -First 1
    
    $listPricing = $response.Items | Where-Object {
      $_.productName -like "*Block Blob*" -and
      $_.meterName -like "*List*"
    } | Select-Object -First 1
    
    $readPricing = $response.Items | Where-Object {
      $_.productName -like "*Block Blob*" -and
      $_.meterName -like "*Read Operations*"
    } | Select-Object -First 1
    
    # Average operations cost (weighted: 60% writes, 30% reads, 10% lists for typical Veeam backup)
    $avgOpsCostPer10k = if ($writePricing -and $readPricing) {
      ($writePricing.retailPrice * 0.6) + ($readPricing.retailPrice * 0.3) + 
      (if ($listPricing) { $listPricing.retailPrice * 0.1 } else { $writePricing.retailPrice * 0.1 })
    } else {
      # Fallback based on tier
      if ($Tier -eq "Hot") { 0.05 } else { 0.10 }
    }
    
    return @{
      StoragePricePerGBMonth = $storagePricing.retailPrice
      EgressPricePerGB = if ($egressPricing) { $egressPricing.retailPrice } else { 0.087 }
      ApiOpsPricePer10k = $avgOpsCostPer10k
      Currency = $storagePricing.currencyCode
    }
    
  } catch {
    Write-Log "Failed to query Azure Pricing API: $($_.Exception.Message)" -Level "WARNING"
    Write-Log "Using fallback pricing estimates" -Level "WARNING"
    
    # Fallback pricing (approximate US pricing)
    switch ($Tier) {
      "Hot" { 
        return @{
          StoragePricePerGBMonth = 0.0184
          EgressPricePerGB = 0.087
          ApiOpsPricePer10k = 0.05
          Currency = "USD"
        }
      }
      "Cool" { 
        return @{
          StoragePricePerGBMonth = 0.0115
          EgressPricePerGB = 0.087
          ApiOpsPricePer10k = 0.10
          Currency = "USD"
        }
      }
      "Archive" { 
        return @{
          StoragePricePerGBMonth = 0.00099
          EgressPricePerGB = 0.087
          ApiOpsPricePer10k = 0.50
          Currency = "USD"
        }
      }
    }
  }
}

function Calculate-VeeamVaultCost {
  param(
    [double]$CapacityTB,
    [int]$Months
  )
  
  return $CapacityTB * $VeeamVaultFoundationPricePerTBMonth * $Months
}

function Calculate-AzureBlobCost {
  param(
    [double]$CapacityGB,
    [double]$StoragePricePerGBMonth,
    [double]$EgressGB,
    [double]$EgressPricePerGB,
    [double]$ApiOpsPricePer10k,
    [int]$ApiOpsPerTBMonth,
    [int]$Months
  )
  
  $capacityTB = $CapacityGB / 1024
  $storageCost = $CapacityGB * $StoragePricePerGBMonth * $Months
  $egressCost = $EgressGB * $EgressPricePerGB * $Months
  
  # Calculate API operations cost
  # Total operations = Capacity (TB) × Operations per TB per month × Months
  # Cost = (Total operations / 10,000) × Price per 10k operations
  $totalOperations = $capacityTB * $ApiOpsPerTBMonth * $Months
  $apiOpsCost = ($totalOperations / 10000) * $ApiOpsPricePer10k
  
  return @{
    StorageCost = $storageCost
    EgressCost = $egressCost
    ApiOperationsCost = $apiOpsCost
    TotalCost = $storageCost + $egressCost + $apiOpsCost
  }
}

function Calculate-ReservationDiscount {
  param(
    [double]$BasePrice,
    [int]$Years
  )
  
  # Azure Reserved Storage discounts (approximate)
  $discount = switch ($Years) {
    1 { 0.18 }  # 18% discount for 1-year
    3 { 0.38 }  # 38% discount for 3-year
    default { 0 }
  }
  
  return $BasePrice * (1 - $discount)
}

function Generate-CostComparison {
  param(
    [double]$CapacityTB,
    [string]$Region,
    [double]$MonthlyChangeRate,
    [double]$AnnualGrowth,
    [int]$Years,
    [double]$EgressGB,
    [int]$ApiOpsPerTBMonth
  )
  
  Write-Log "Starting cost comparison analysis" -Level "SUCCESS"
  
  # Get Azure pricing for different tiers
  $hotPricing = Get-AzureBlobPricing -Region $Region -Tier "Hot"
  $coolPricing = Get-AzureBlobPricing -Region $Region -Tier "Cool"
  $archivePricing = Get-AzureBlobPricing -Region $Region -Tier "Archive"
  
  $capacityGB = $CapacityTB * 1024
  $results = @()
  
  # Calculate costs for each year
  for ($year = 1; $year -le $Years; $year++) {
    $yearlyCapacityGB = $capacityGB * [Math]::Pow((1 + $AnnualGrowth/100), $year - 1)
    $yearlyCapacityTB = $yearlyCapacityGB / 1024
    $months = 12
    
    # Veeam Vault
    $veeamVaultCost = Calculate-VeeamVaultCost -CapacityTB $yearlyCapacityTB -Months $months
    
    # Azure Hot
    $azureHot = Calculate-AzureBlobCost -CapacityGB $yearlyCapacityGB `
      -StoragePricePerGBMonth $hotPricing.StoragePricePerGBMonth `
      -EgressGB $EgressGB -EgressPricePerGB $hotPricing.EgressPricePerGB `
      -ApiOpsPricePer10k $hotPricing.ApiOpsPricePer10k `
      -ApiOpsPerTBMonth $ApiOpsPerTBMonth -Months $months
    
    # Azure Cool
    $azureCool = Calculate-AzureBlobCost -CapacityGB $yearlyCapacityGB `
      -StoragePricePerGBMonth $coolPricing.StoragePricePerGBMonth `
      -EgressGB $EgressGB -EgressPricePerGB $coolPricing.EgressPricePerGB `
      -ApiOpsPricePer10k $coolPricing.ApiOpsPricePer10k `
      -ApiOpsPerTBMonth $ApiOpsPerTBMonth -Months $months
    
    # Azure Archive
    $azureArchive = Calculate-AzureBlobCost -CapacityGB $yearlyCapacityGB `
      -StoragePricePerGBMonth $archivePricing.StoragePricePerGBMonth `
      -EgressGB $EgressGB -EgressPricePerGB $archivePricing.EgressPricePerGB `
      -ApiOpsPricePer10k $archivePricing.ApiOpsPricePer10k `
      -ApiOpsPerTBMonth $ApiOpsPerTBMonth -Months $months
    
    # Azure Reserved (Cool tier with 1-year and 3-year discounts)
    $azureCoolReserved1Y = Calculate-ReservationDiscount -BasePrice $azureCool.TotalCost -Years 1
    $azureCoolReserved3Y = Calculate-ReservationDiscount -BasePrice $azureCool.TotalCost -Years 3
    
    $results += [PSCustomObject]@{
      Year = $year
      CapacityTB = [Math]::Round($yearlyCapacityTB, 2)
      VeeamVault = [Math]::Round($veeamVaultCost, 2)
      AzureHot = [Math]::Round($azureHot.TotalCost, 2)
      AzureHotStorage = [Math]::Round($azureHot.StorageCost, 2)
      AzureHotApiOps = [Math]::Round($azureHot.ApiOperationsCost, 2)
      AzureCool = [Math]::Round($azureCool.TotalCost, 2)
      AzureCoolStorage = [Math]::Round($azureCool.StorageCost, 2)
      AzureCoolApiOps = [Math]::Round($azureCool.ApiOperationsCost, 2)
      AzureCoolReserved1Y = [Math]::Round($azureCoolReserved1Y, 2)
      AzureCoolReserved3Y = [Math]::Round($azureCoolReserved3Y, 2)
      AzureArchive = [Math]::Round($azureArchive.TotalCost, 2)
      VeeamSavingsVsHot = [Math]::Round($azureHot.TotalCost - $veeamVaultCost, 2)
      VeeamSavingsVsCool = [Math]::Round($azureCool.TotalCost - $veeamVaultCost, 2)
    }
  }
  
  return $results
}

function Generate-HTMLReport {
  param(
    [array]$Results,
    [double]$CapacityTB,
    [string]$Region,
    [double]$MonthlyChangeRate,
    [double]$AnnualGrowth,
    [double]$EgressGB
  )
  
  $totalVeeamVault = ($Results | Measure-Object -Property VeeamVault -Sum).Sum
  $totalAzureHot = ($Results | Measure-Object -Property AzureHot -Sum).Sum
  $totalAzureCool = ($Results | Measure-Object -Property AzureCool -Sum).Sum
  $totalAzureCoolReserved3Y = ($Results | Measure-Object -Property AzureCoolReserved3Y -Sum).Sum
  
  $totalAzureCoolStorage = ($Results | Measure-Object -Property AzureCoolStorage -Sum).Sum
  $totalAzureCoolApiOps = ($Results | Measure-Object -Property AzureCoolApiOps -Sum).Sum
  $totalAzureHotApiOps = ($Results | Measure-Object -Property AzureHotApiOps -Sum).Sum
  
  $totalSavingsVsHot = $totalAzureHot - $totalVeeamVault
  $totalSavingsVsCool = $totalAzureCool - $totalVeeamVault
  $totalSavingsVsCoolReserved = $totalAzureCoolReserved3Y - $totalVeeamVault
  
  $recommendedOption = if ($totalVeeamVault -lt $totalAzureCool) {
    "Veeam Vault Foundation"
  } elseif ($totalSavingsVsCoolReserved -gt 0) {
    "Veeam Vault Foundation"
  } else {
    "Azure Cool with 3-Year Reservation"
  }
  
  $yearlyRows = $Results | ForEach-Object {
    @"
        <tr>
          <td>Year $($_.Year)</td>
          <td>$($_.CapacityTB) TB</td>
          <td class="price">`$$($_.VeeamVault)</td>
          <td class="price">`$$($_.AzureHot)</td>
          <td class="price">`$$($_.AzureCool)</td>
          <td class="price">`$$($_.AzureCoolReserved3Y)</td>
          <td class="savings">$(if($_.VeeamSavingsVsHot -gt 0){"✓ `$$($_.VeeamSavingsVsHot)"}else{"❌ -`$$([Math]::Abs($_.VeeamSavingsVsHot))"})</td>
        </tr>
"@
  } -join "`n"
  
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Veeam Vault vs Azure Blob Storage - Cost Comparison</title>
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
    }
    
    * {
      margin: 0;
      padding: 0;
      box-sizing: border-box;
    }
    
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background-color: var(--background);
      color: var(--text-primary);
      line-height: 1.6;
      padding: 20px;
    }
    
    .container {
      max-width: 1400px;
      margin: 0 auto;
    }
    
    header {
      background: linear-gradient(135deg, var(--veeam-green) 0%, var(--veeam-dark) 100%);
      color: white;
      padding: 40px;
      border-radius: 8px;
      margin-bottom: 30px;
      box-shadow: 0 4px 6px rgba(0,0,0,0.1);
    }
    
    header h1 {
      font-size: 32px;
      margin-bottom: 10px;
    }
    
    header p {
      font-size: 16px;
      opacity: 0.95;
    }
    
    .summary-cards {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
      gap: 20px;
      margin-bottom: 30px;
    }
    
    .card {
      background: var(--card-bg);
      padding: 25px;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      border-left: 4px solid var(--veeam-green);
    }
    
    .card.azure {
      border-left-color: var(--azure-blue);
    }
    
    .card.recommended {
      border-left-color: #FFD700;
      background: linear-gradient(135deg, #fffef7 0%, #ffffff 100%);
    }
    
    .card-title {
      font-size: 14px;
      color: var(--text-secondary);
      text-transform: uppercase;
      letter-spacing: 0.5px;
      margin-bottom: 10px;
    }
    
    .card-value {
      font-size: 32px;
      font-weight: 600;
      color: var(--text-primary);
      margin-bottom: 5px;
    }
    
    .card-subtitle {
      font-size: 13px;
      color: var(--text-secondary);
    }
    
    .section {
      background: var(--card-bg);
      padding: 30px;
      border-radius: 8px;
      box-shadow: 0 2px 4px rgba(0,0,0,0.1);
      margin-bottom: 30px;
    }
    
    .section h2 {
      font-size: 24px;
      margin-bottom: 20px;
      color: var(--text-primary);
      border-bottom: 2px solid var(--border);
      padding-bottom: 10px;
    }
    
    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 20px;
    }
    
    th, td {
      padding: 12px;
      text-align: left;
      border-bottom: 1px solid var(--border);
    }
    
    th {
      background-color: var(--background);
      font-weight: 600;
      color: var(--text-primary);
      text-transform: uppercase;
      font-size: 12px;
      letter-spacing: 0.5px;
    }
    
    td.price {
      font-weight: 600;
      color: var(--text-primary);
    }
    
    td.savings {
      font-weight: 600;
    }
    
    .assumptions {
      background: #f0f9ff;
      border-left: 4px solid var(--azure-blue);
      padding: 20px;
      border-radius: 4px;
      margin-top: 20px;
    }
    
    .assumptions h3 {
      color: var(--azure-blue);
      margin-bottom: 10px;
      font-size: 18px;
    }
    
    .assumptions ul {
      margin-left: 20px;
    }
    
    .assumptions li {
      margin-bottom: 8px;
      color: var(--text-secondary);
    }
    
    .recommendation {
      background: linear-gradient(135deg, #fffef7 0%, #ffffff 100%);
      border: 2px solid #FFD700;
      padding: 25px;
      border-radius: 8px;
      margin-top: 20px;
    }
    
    .recommendation h3 {
      color: #f59e0b;
      margin-bottom: 15px;
      font-size: 20px;
    }
    
    .footer {
      text-align: center;
      margin-top: 40px;
      padding: 20px;
      color: var(--text-secondary);
      font-size: 14px;
    }
    
    @media print {
      body {
        background: white;
      }
      
      .section, .card {
        box-shadow: none;
        border: 1px solid var(--border);
      }
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <h1>Veeam Vault vs Azure Blob Storage</h1>
      <p>Cost Comparison Analysis - Generated $(Get-Date -Format "MMMM d, yyyy 'at' h:mm tt")</p>
    </header>
    
    <div class="summary-cards">
      <div class="card">
        <div class="card-title">Initial Capacity</div>
        <div class="card-value">$CapacityTB TB</div>
        <div class="card-subtitle">Region: $Region</div>
      </div>
      
      <div class="card">
        <div class="card-title">Veeam Vault Foundation</div>
        <div class="card-value">`$$([Math]::Round($totalVeeamVault, 2))</div>
        <div class="card-subtitle">$($Results.Count)-Year Total Cost</div>
      </div>
      
      <div class="card azure">
        <div class="card-title">Azure Cool (Pay-as-you-go)</div>
        <div class="card-value">`$$([Math]::Round($totalAzureCool, 2))</div>
        <div class="card-subtitle">$($Results.Count)-Year Total Cost</div>
      </div>
      
      <div class="card azure">
        <div class="card-title">Azure Cool (3-Year Reserved)</div>
        <div class="card-value">`$$([Math]::Round($totalAzureCoolReserved3Y, 2))</div>
        <div class="card-subtitle">$($Results.Count)-Year Total Cost with 38% discount</div>
      </div>
      
      <div class="card recommended">
        <div class="card-title">Recommended Option</div>
        <div class="card-value" style="font-size: 20px;">$recommendedOption</div>
        <div class="card-subtitle">Most cost-effective solution</div>
      </div>
    </div>
    
    <div class="section" style="background: #fff9e6; border-left: 4px solid #f59e0b;">
      <h2 style="border-bottom: none; margin-bottom: 15px;">🔍 Azure Cool Tier Cost Breakdown</h2>
      <div style="display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-top: 15px;">
        <div>
          <div style="font-size: 12px; color: var(--text-secondary); text-transform: uppercase; margin-bottom: 5px;">Storage Cost</div>
          <div style="font-size: 24px; font-weight: 600; color: var(--azure-blue);">`$$([Math]::Round($totalAzureCoolStorage, 2))</div>
          <div style="font-size: 12px; color: var(--text-secondary);">$([Math]::Round(($totalAzureCoolStorage/$totalAzureCool)*100, 1))% of total</div>
        </div>
        <div>
          <div style="font-size: 12px; color: var(--text-secondary); text-transform: uppercase; margin-bottom: 5px;">API Operations</div>
          <div style="font-size: 24px; font-weight: 600; color: #d97706;">`$$([Math]::Round($totalAzureCoolApiOps, 2))</div>
          <div style="font-size: 12px; color: var(--text-secondary);">$([Math]::Round(($totalAzureCoolApiOps/$totalAzureCool)*100, 1))% of total</div>
        </div>
        <div>
          <div style="font-size: 12px; color: var(--text-secondary); text-transform: uppercase; margin-bottom: 5px;">Egress Cost</div>
          <div style="font-size: 24px; font-weight: 600; color: #dc2626;">`$$([Math]::Round(($totalAzureCool - $totalAzureCoolStorage - $totalAzureCoolApiOps), 2))</div>
          <div style="font-size: 12px; color: var(--text-secondary);">$([Math]::Round((($totalAzureCool - $totalAzureCoolStorage - $totalAzureCoolApiOps)/$totalAzureCool)*100, 1))% of total</div>
        </div>
      </div>
      <div style="margin-top: 20px; padding: 15px; background: white; border-radius: 4px;">
        <p style="margin: 0; color: var(--text-secondary); font-size: 14px;">
          <strong style="color: var(--veeam-green);">💡 Veeam Vault Foundation:</strong> All operations included at `$14/TB/month with <strong>zero API charges</strong>. 
          No surprise costs for daily incremental backups, immutability validation, or metadata operations required by Veeam v13.
        </p>
      </div>
    </div>
    
    <div class="section">
      <h2>Year-by-Year Comparison</h2>
      <table>
        <thead>
          <tr>
            <th>Period</th>
            <th>Capacity</th>
            <th>Veeam Vault</th>
            <th>Azure Hot</th>
            <th>Azure Cool</th>
            <th>Azure Cool (3Y Reserved)</th>
            <th>Veeam Savings vs Hot</th>
          </tr>
        </thead>
        <tbody>
          $yearlyRows
          <tr style="background-color: #f0f9ff; font-weight: 600;">
            <td colspan="2">TOTAL ($($Results.Count) Years)</td>
            <td class="price">`$$([Math]::Round($totalVeeamVault, 2))</td>
            <td class="price">`$$([Math]::Round($totalAzureHot, 2))</td>
            <td class="price">`$$([Math]::Round($totalAzureCool, 2))</td>
            <td class="price">`$$([Math]::Round($totalAzureCoolReserved3Y, 2))</td>
            <td class="savings">$(if($totalSavingsVsHot -gt 0){"✓ `$$([Math]::Round($totalSavingsVsHot, 2))"}else{"❌"})</td>
          </tr>
        </tbody>
      </table>
    </div>
    
    <div class="section">
      <h2>Analysis Summary</h2>
      
      <div class="recommendation">
        <h3>💰 Cost Analysis</h3>
        <p><strong>Veeam Vault Foundation ($([Math]::Round($totalVeeamVault, 2)))</strong> vs Azure Cool 3Y Reserved ($([Math]::Round($totalAzureCoolReserved3Y, 2)))</p>
        <p style="margin-top: 10px;">
          $(if ($totalVeeamVault -lt $totalAzureCoolReserved3Y) {
            "Veeam Vault saves <strong>`$$([Math]::Round($totalAzureCoolReserved3Y - $totalVeeamVault, 2))</strong> over $($Results.Count) years compared to Azure Cool with 3-year reservations."
          } else {
            "Azure Cool with 3-year reservations saves <strong>`$$([Math]::Round($totalVeeamVault - $totalAzureCoolReserved3Y, 2))</strong> over $($Results.Count) years, but requires upfront commitment."
          })
        </p>
      </div>
      
      <div class="assumptions">
        <h3>📋 Analysis Assumptions</h3>
        <ul>
          <li><strong>Veeam Vault Foundation:</strong> `$14/TB/month (all-inclusive pricing)</li>
          <li><strong>Initial Capacity:</strong> $CapacityTB TB</li>
          <li><strong>Annual Growth Rate:</strong> $AnnualGrowthPercent%</li>
          <li><strong>Monthly Change Rate:</strong> $MonthlyChangeRatePercent%</li>
          <li><strong>Monthly Egress:</strong> $EgressGB GB</li>
          <li><strong>Azure Region:</strong> $Region</li>
          <li><strong>Azure Reserved Discounts:</strong> 18% (1-year), 38% (3-year)</li>
          <li><strong>API Operations:</strong> $([Math]::Round($ApiOpsPerTBMonth/1000, 0))k operations per TB per month</li>
          <li><strong>Operations Pattern:</strong> 60% writes, 30% reads, 10% lists (typical Veeam incremental + immutability)</li>
          <li><strong>Pricing Source:</strong> Azure Retail Prices API (real-time)</li>
        </ul>
        <div style="margin-top: 15px; padding: 15px; background: white; border-left: 3px solid #f59e0b; border-radius: 4px;">
          <p style="margin: 0; font-size: 13px; color: #92400e;">
            <strong>⚠️ Critical for Veeam v13:</strong> Azure Blob immutability (required for 30-day ransomware protection) generates significant API operations. 
            These costs are often overlooked but can represent <strong>$([Math]::Round(($totalAzureCoolApiOps/$totalAzureCool)*100, 0))% of total Azure costs</strong>. 
            Reserved storage pricing does NOT include operations charges.
          </p>
        </div>
      </div>
      
      <div style="margin-top: 30px; padding: 20px; background: #f0fdf4; border-left: 4px solid var(--veeam-green); border-radius: 4px;">
        <h3 style="color: var(--veeam-green); margin-bottom: 10px;">✅ Veeam Vault Foundation Benefits</h3>
        <ul style="margin-left: 20px;">
          <li><strong>Predictable Pricing:</strong> Fixed `$14/TB/month - <strong>zero egress fees, zero API operations charges</strong></li>
          <li><strong>No Hidden Costs:</strong> Veeam v13 immutability operations included (Azure: +`$$([Math]::Round($totalAzureCoolApiOps, 2)) over $($Results.Count) years)</li>
          <li><strong>No Long-Term Commitment:</strong> Month-to-month flexibility vs 1-3 year Azure reservations</li>
          <li><strong>Immutability Built-In:</strong> Ransomware protection with no additional API charges</li>
          <li><strong>Integrated Management:</strong> Native Veeam Backup & Replication integration</li>
          <li><strong>Enterprise Support:</strong> Veeam support included in pricing</li>
          <li><strong>Multi-Cloud Flexibility:</strong> Works across AWS, Azure, Google Cloud</li>
        </ul>
      </div>
    </div>
    
    <div class="footer">
      <p><strong>© 2026 Veeam Software</strong> | Presales Assessment Tool</p>
      <p>Pricing is based on publicly available information and may vary. Contact Veeam Sales for custom quotes.</p>
    </div>
  </div>
</body>
</html>
"@
  
  return $html
}

#endregion

#region Main Execution

try {
  # Header
  $headerWidth = 80
  $separator = "=" * $headerWidth
  
  Write-Host "`n$separator" -ForegroundColor Cyan
  Write-Host "  VEEAM VAULT PRICING COMPARISON TOOL" -ForegroundColor White
  Write-Host "  Veeam Software - Sales Engineering" -ForegroundColor Gray
  Write-Host "$separator`n" -ForegroundColor Cyan
  
  # Configuration summary
  Write-Host "Analysis Configuration:" -ForegroundColor White
  Write-Host "  Initial Capacity       : " -NoNewline -ForegroundColor Gray
  Write-Host "$CapacityTB TB" -ForegroundColor White
  Write-Host "  Azure Region           : " -NoNewline -ForegroundColor Gray
  Write-Host "$Region" -ForegroundColor White
  Write-Host "  Projection Period      : " -NoNewline -ForegroundColor Gray
  Write-Host "$YearsToProject years" -ForegroundColor White
  Write-Host "  Annual Growth          : " -NoNewline -ForegroundColor Gray
  Write-Host "$AnnualGrowthPercent%" -ForegroundColor White
  Write-Host "  API Operations/TB/Month: " -NoNewline -ForegroundColor Gray
  Write-Host "$([Math]::Round($ApiOperationsPerTBMonth/1000, 0))k" -ForegroundColor White
  Write-Host "  Monthly Egress         : " -NoNewline -ForegroundColor Gray
  Write-Host "$EgressGB GB`n" -ForegroundColor White
  
  Write-Host "Output Directory: " -NoNewline -ForegroundColor Gray
  Write-Host "$OutputPath`n" -ForegroundColor White
  
  # Progress: Pricing data
  Write-Host "[1/4] " -NoNewline -ForegroundColor Cyan
  Write-Host "Querying Azure pricing data..." -ForegroundColor White
  
  $comparisonResults = Generate-CostComparison `
    -CapacityTB $CapacityTB `
    -Region $Region `
    -MonthlyChangeRate $MonthlyChangeRatePercent `
    -AnnualGrowth $AnnualGrowthPercent `
    -Years $YearsToProject `
    -EgressGB $EgressGB `
    -ApiOpsPerTBMonth $ApiOperationsPerTBMonth
  
  Write-Host "      " -NoNewline
  Write-Host "✓" -NoNewline -ForegroundColor Green
  Write-Host " Retrieved pricing for Hot, Cool, and Archive tiers`n" -ForegroundColor Gray
  
  # Progress: CSV export
  Write-Host "[2/4] " -NoNewline -ForegroundColor Cyan
  Write-Host "Generating detailed CSV report..." -ForegroundColor White
  
  $csvPath = Join-Path $OutputPath "cost_comparison.csv"
  $comparisonResults | Export-Csv -Path $csvPath -NoTypeInformation
  
  Write-Host "      " -NoNewline
  Write-Host "✓" -NoNewline -ForegroundColor Green
  Write-Host " Created: " -NoNewline -ForegroundColor Gray
  Write-Host "cost_comparison.csv`n" -ForegroundColor White
  
  # Progress: HTML report
  Write-Host "[3/4] " -NoNewline -ForegroundColor Cyan
  Write-Host "Generating professional HTML report..." -ForegroundColor White
  
  $html = Generate-HTMLReport `
    -Results $comparisonResults `
    -CapacityTB $CapacityTB `
    -Region $Region `
    -MonthlyChangeRate $MonthlyChangeRatePercent `
    -AnnualGrowth $AnnualGrowthPercent `
    -EgressGB $EgressGB
  
  $htmlPath = Join-Path $OutputPath "veeam_vault_pricing_report.html"
  $html | Out-File -FilePath $htmlPath -Encoding UTF8
  
  Write-Host "      " -NoNewline
  Write-Host "✓" -NoNewline -ForegroundColor Green
  Write-Host " Created: " -NoNewline -ForegroundColor Gray
  Write-Host "veeam_vault_pricing_report.html`n" -ForegroundColor White
  
  # Progress: Summary
  Write-Host "[4/4] " -NoNewline -ForegroundColor Cyan
  Write-Host "Calculating cost summary...`n" -ForegroundColor White
  
  # Calculate totals
  $totalVeeam = ($comparisonResults | Measure-Object -Property VeeamVault -Sum).Sum
  $totalAzureHot = ($comparisonResults | Measure-Object -Property AzureHot -Sum).Sum
  $totalAzureCool = ($comparisonResults | Measure-Object -Property AzureCool -Sum).Sum
  $totalAzureCoolReserved3Y = ($comparisonResults | Measure-Object -Property AzureCoolReserved3Y -Sum).Sum
  $totalAzureCoolApiOps = ($comparisonResults | Measure-Object -Property AzureCoolApiOps -Sum).Sum
  
  # Results section
  Write-Host "$separator" -ForegroundColor Cyan
  Write-Host "  COST COMPARISON RESULTS ($YearsToProject-Year TCO)" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Cyan
  
  # Pricing table
  $veeamFormatted = "`${0:N2}" -f $totalVeeam
  $azureHotFormatted = "`${0:N2}" -f $totalAzureHot
  $azureCoolFormatted = "`${0:N2}" -f $totalAzureCool
  $azureCoolReservedFormatted = "`${0:N2}" -f $totalAzureCoolReserved3Y
  $apiOpsFormatted = "`${0:N2}" -f $totalAzureCoolApiOps
  
  Write-Host "  Solution                          Total Cost      " -ForegroundColor Gray
  Write-Host "  ──────────────────────────────────────────────────" -ForegroundColor Gray
  Write-Host "  Veeam Vault Foundation            " -NoNewline -ForegroundColor White
  Write-Host $veeamFormatted.PadLeft(15) -ForegroundColor Green
  Write-Host "  Azure Hot (PAYG)                  " -NoNewline -ForegroundColor White
  Write-Host $azureHotFormatted.PadLeft(15) -ForegroundColor Yellow
  Write-Host "  Azure Cool (PAYG)                 " -NoNewline -ForegroundColor White
  Write-Host $azureCoolFormatted.PadLeft(15) -ForegroundColor Yellow
  Write-Host "  Azure Cool (3-Year Reserved)      " -NoNewline -ForegroundColor White
  Write-Host $azureCoolReservedFormatted.PadLeft(15) -ForegroundColor Yellow
  Write-Host ""
  
  # Cost breakdown
  $apiOpsPercent = [Math]::Round(($totalAzureCoolApiOps/$totalAzureCool)*100, 1)
  Write-Host "  Azure Cool Cost Breakdown:" -ForegroundColor Gray
  Write-Host "    Storage + Egress: " -NoNewline -ForegroundColor Gray
  Write-Host "`${0:N2}" -f ($totalAzureCool - $totalAzureCoolApiOps) -ForegroundColor White
  Write-Host "    API Operations  : " -NoNewline -ForegroundColor Gray
  Write-Host "`${0:N2} " -f $totalAzureCoolApiOps -NoNewline -ForegroundColor White
  Write-Host "($apiOpsPercent% of total)" -ForegroundColor DarkYellow
  Write-Host ""
  
  # Savings analysis
  $savingsVsCool = $totalAzureCool - $totalVeeam
  $savingsVsCoolReserved = $totalAzureCoolReserved3Y - $totalVeeam
  
  if ($savingsVsCool -gt 0) {
    Write-Host "  Veeam Vault Savings vs Azure Cool (PAYG):" -ForegroundColor White
    Write-Host "    " -NoNewline
    Write-Host "✓ " -NoNewline -ForegroundColor Green
    Write-Host "`${0:N2}" -f $savingsVsCool -NoNewline -ForegroundColor Green
    Write-Host " ($([Math]::Round(($savingsVsCool/$totalAzureCool)*100, 1))% reduction)" -ForegroundColor Green
  } else {
    Write-Host "  Azure Cool (PAYG) is less expensive by:" -ForegroundColor White
    Write-Host "    ⚠ " -NoNewline -ForegroundColor Yellow
    Write-Host "`${0:N2}" -f [Math]::Abs($savingsVsCool) -ForegroundColor Yellow
  }
  
  Write-Host ""
  
  if ($savingsVsCoolReserved -gt 0) {
    Write-Host "  Veeam Vault Savings vs Azure Cool (3Y Reserved):" -ForegroundColor White
    Write-Host "    " -NoNewline
    Write-Host "✓ " -NoNewline -ForegroundColor Green
    Write-Host "`${0:N2}" -f $savingsVsCoolReserved -NoNewline -ForegroundColor Green
    Write-Host " even with 38% Azure discount" -ForegroundColor Green
  } else {
    Write-Host "  Azure Cool (3Y Reserved) is less expensive by:" -ForegroundColor White
    Write-Host "    ⚠ " -NoNewline -ForegroundColor Yellow
    Write-Host "`${0:N2}" -f [Math]::Abs($savingsVsCoolReserved) -NoNewline -ForegroundColor Yellow
    Write-Host " (requires 3-year commitment)" -ForegroundColor Yellow
  }
  
  Write-Host ""
  
  # Key differentiators
  Write-Host "  Veeam Vault Foundation Advantages:" -ForegroundColor Cyan
  Write-Host "    • All-inclusive pricing (no API operations charges)" -ForegroundColor Gray
  Write-Host "    • Zero egress fees for DR testing and data recovery" -ForegroundColor Gray
  Write-Host "    • Month-to-month flexibility (no long-term commitment)" -ForegroundColor Gray
  Write-Host "    • Built-in immutability for ransomware protection" -ForegroundColor Gray
  Write-Host "    • Native Veeam Backup & Replication integration" -ForegroundColor Gray
  Write-Host ""
  
  # Output files
  Write-Host "$separator" -ForegroundColor Cyan
  Write-Host "  DELIVERABLES" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Cyan
  Write-Host "  HTML Report (Primary):" -ForegroundColor White
  Write-Host "    $htmlPath" -ForegroundColor Gray
  Write-Host ""
  Write-Host "  Detailed Data (CSV):" -ForegroundColor White
  Write-Host "    $csvPath" -ForegroundColor Gray
  Write-Host ""
  Write-Host "  Execution Log:" -ForegroundColor White
  Write-Host "    $LogFile" -ForegroundColor Gray
  Write-Host ""
  
  # Success message
  Write-Host "$separator" -ForegroundColor Green
  Write-Host "  " -NoNewline
  Write-Host "✓" -NoNewline -ForegroundColor Green
  Write-Host " ANALYSIS COMPLETE" -ForegroundColor White
  Write-Host "$separator`n" -ForegroundColor Green
  
  Write-Log "Analysis completed successfully" -Level "SUCCESS"
  
} catch {
  Write-Host "`n" -NoNewline
  Write-Host "✗ ERROR: " -NoNewline -ForegroundColor Red
  Write-Host "$($_.Exception.Message)`n" -ForegroundColor White
  Write-Log "Fatal error: $($_.Exception.Message)" -Level "ERROR"
  Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level "ERROR"
  exit 1
}

#endregion
