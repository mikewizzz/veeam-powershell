# Veeam Vault Pricing Comparison Tool

PowerShell tool to compare Veeam Vault Foundation pricing against DIY Azure Blob storage options for capacity planning and cost analysis.

## Purpose

Addresses common scenarios:
1. **Net New Customers** - Evaluating offsite cloud storage options
2. **Existing Veeam Customers** - Using Azure Blob today, considering Veeam Vault

Provides factual, data-driven cost comparison using real-time Azure pricing.

## Features

- **Real-time Azure pricing** - Queries Azure Retail Prices API
- **Multiple storage tiers** - Hot, Cool, Archive comparison
- **Reservation discounts** - 1-year (18%) and 3-year (38%) Azure reserved pricing
- **TCO analysis** - Multi-year projections with growth rates
- **Professional reports** - HTML with executive summary
- **Factual pricing** - Veeam Vault Foundation at $14/TB/month

## Quick Start

```powershell
.\Get-VeeamVaultPricing.ps1 -CapacityTB 10 -Region "eastus"
```

## Parameters

### Required
- `-CapacityTB <double>` - Total backup storage capacity in terabytes (0.1 - 10,000)
- `-Region <string>` - Azure region for pricing (e.g., "eastus", "westeurope")

### Optional
- `-MonthlyChangeRatePercent <double>` - Monthly data change rate (default: 10%)
- `-AnnualGrowthPercent <double>` - Annual data growth rate (default: 20%)
- `-YearsToProject <int>` - Number of years for TCO (default: 3, max: 10)
- `-EgressGB <double>` - Expected monthly data egress in GB (default: 0)
- `-OutputPath <string>` - Custom output folder

## Examples

**Basic comparison:**
```powershell
.\Get-VeeamVaultPricing.ps1 -CapacityTB 50 -Region "eastus"
```

**5-year TCO with growth:**
```powershell
.\Get-VeeamVaultPricing.ps1 -CapacityTB 100 -Region "westeurope" -YearsToProject 5 -AnnualGrowthPercent 30
```

**Include egress costs:**
```powershell
.\Get-VeeamVaultPricing.ps1 -CapacityTB 25 -Region "eastus" -EgressGB 500
```

**Conservative sizing (higher growth):**
```powershell
.\Get-VeeamVaultPricing.ps1 -CapacityTB 75 -Region "westus2" -AnnualGrowthPercent 40 -YearsToProject 5
```

## Output Files

**Primary deliverable:**
- `veeam_vault_pricing_report.html` - Executive summary with side-by-side comparison

**Detailed data:**
- `cost_comparison.csv` - Year-by-year breakdown
- `execution_log.csv` - Operation log

## Pricing Details

### Veeam Vault Foundation
- **$14/TB/month** (all-inclusive)
- No egress fees
- No operations charges
- No long-term commitment
- Immutability built-in
- Veeam support included

### Azure Blob Storage
- **Hot tier** - Frequent access, higher storage cost
- **Cool tier** - Infrequent access, lower storage cost, 30-day minimum
- **Archive tier** - Rare access, lowest storage cost, 180-day minimum
- **Egress charges** - Data transfer out costs apply
- **Operations charges** - Not included in this analysis (typically minimal)

### Azure Reserved Storage
- **1-year reservation** - 18% discount (approximate)
- **3-year reservation** - 38% discount (approximate)
- Requires upfront capacity commitment
- Limited flexibility for growth

## Analysis Methodology

**Year-over-year capacity:**
```
Year N Capacity = Initial Capacity × (1 + Annual Growth %)^(N-1)
```

**Veeam Vault cost:**
```
Annual Cost = Capacity (TB) × $14 × 12 months
```

**Azure Blob cost:**
```
Storage Cost = Capacity (GB) × Price per GB/month × 12 months
Egress Cost = Monthly Egress (GB) × Price per GB × 12 months
Total = Storage Cost + Egress Cost
```

**Azure Reserved cost:**
```
Reserved Cost = Base Cost × (1 - Discount %)
```

## Prerequisites

- PowerShell 7.x or 5.1
- Internet connectivity for Azure Pricing API
- No Azure authentication required

## Use Cases

### Net New Customer
Customer has existing backup solution (Commvault, Veritas, etc.) and needs offsite cloud storage.

```powershell
# Simple comparison for 50TB environment
.\Get-VeeamVaultPricing.ps1 -CapacityTB 50 -Region "eastus" -YearsToProject 3
```

**Key considerations:**
- Veeam Vault provides predictable, all-inclusive pricing
- No surprise egress or operations charges
- Built-in immutability for ransomware protection
- Month-to-month flexibility

### Existing Veeam Customer
Customer using Azure Blob today for offsite copies, considering Veeam Vault.

```powershell
# Compare current 100TB environment with 25% annual growth
.\Get-VeeamVaultPricing.ps1 -CapacityTB 100 -Region "eastus" -AnnualGrowthPercent 25 -EgressGB 1000
```

**Key considerations:**
- Compare against Azure Cool tier with 3-year reservation
- Veeam Vault eliminates egress fees (important for DR testing)
- Native integration with Veeam Backup & Replication
- No need to manage Azure storage accounts, lifecycle policies

### Large Enterprise
Multi-year TCO analysis for capacity planning.

```powershell
# 5-year projection with aggressive growth
.\Get-VeeamVaultPricing.ps1 -CapacityTB 500 -Region "westeurope" -YearsToProject 5 -AnnualGrowthPercent 35
```

**Key considerations:**
- TCO with realistic growth projections
- Veeam Vault scales seamlessly without reservation commitments
- Azure reservations lock in capacity, limiting flexibility
- Multi-cloud strategy (Veeam Vault works with AWS, Azure, GCP)

## Troubleshooting

**Azure Pricing API unavailable:**
- Script uses fallback pricing (approximate US pricing)
- Warning logged in execution_log.csv

**Invalid region:**
- Use standard Azure region names: eastus, westeurope, centralus
- Check [Azure regions](https://azure.microsoft.com/en-us/explore/global-infrastructure/geographies/)

**Negative savings:**
- Azure Cool with 3-year reservation may be cheaper in some scenarios
- Highlight Veeam Vault benefits: flexibility, no commitment, immutability, support

## Best Practices

**Before running:**
1. Use actual capacity and target Azure region
2. Adjust growth rate based on your environment
3. Include egress if you frequently restore or test DR
4. Use HTML report for stakeholder presentations

**For detailed analysis:**
1. Generate 3-year and 5-year projections
2. Include both optimistic (20%) and conservative (40%) growth scenarios
3. Export CSV for spreadsheet analysis
4. Attach HTML report to planning documents

## Important Notes

- **Pricing accuracy** - Azure prices vary by region and change over time
- **Operations costs** - Not included (typically minimal for backup use cases)
- **Egress fees** - Azure charges for data transfer out; Veeam Vault does not
- **Reservations** - Azure reserved pricing requires upfront commitment
- **Support** - Veeam Vault includes Veeam support; Azure Blob requires separate Azure support plan

## Support

- **Issues** - Open an issue on GitHub
- **Pricing questions** - Verify current Veeam Vault pricing on the Veeam website
- **Azure pricing** - [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)
