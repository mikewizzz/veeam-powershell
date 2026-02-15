# Veeam Azure DR Landing Zone Tool

PowerShell tool that helps Veeam customers plan and create the Azure infrastructure scaffolding needed for disaster recovery (DR) to Azure VMs using Veeam Vault Advanced backups and Veeam Recovery Orchestrator (VRO).

## Problem

Many Veeam customers using Vault Advanced for offsite backup storage want to take the next step and use those backups for DR to Azure VMs. The blocker is often that they have never set up an Azure DR subscription or don't know what components are needed. This tool removes that friction.

## How It Works

The tool operates in two modes:

### Mode 1: Estimate (Default)
No Azure login required. Takes your VM count, storage capacity, and target region to produce:
- A complete **bill of materials** listing every Azure component needed
- **Cost estimates** with real-time pricing from Azure Retail Prices API
- **Always-on vs DR-active cost breakdown** so stakeholders understand the pay-as-you-go model
- Professional **HTML report** to share with decision makers

### Mode 2: Deploy
Authenticates to Azure and creates the entire landing zone:
- Resource Group with DR-specific tags
- Virtual Network with recovery and management subnets
- Network Security Groups with Veeam-optimized rules
- Storage Account for Veeam staging and restore data
- (Optional) VRO service principal role assignment

After deployment, customers use **Veeam Recovery Orchestrator (VRO)** to run recovery plans that restore VMs into this landing zone.

## Quick Start

**Estimate only (no Azure login):**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2"
```

**Deploy to Azure:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 25 -SourceDataTB 10 -Region "eastus2" -Deploy -SubscriptionId "your-sub-id"
```

## Parameters

### Required
- `-VMCount <int>` - Number of VMs to plan DR capacity for (1 - 5,000)
- `-SourceDataTB <double>` - Total source data in terabytes (0.1 - 10,000)
- `-Region <string>` - Azure region for DR (e.g., "eastus2", "westeurope")

### Network Configuration
- `-VNetAddressSpace <string>` - VNet CIDR (default: "10.200.0.0/16")
- `-RecoverySubnetCIDR <string>` - Recovery subnet (default: "10.200.1.0/24", 251 VMs)
- `-ManagementSubnetCIDR <string>` - Management subnet (default: "10.200.0.0/24")

### Sizing & Naming
- `-NamingPrefix <string>` - Resource name prefix (default: "veeam-dr")
- `-TargetVMSize <string>` - VM size for cost estimation (default: "Standard_D4s_v5")

### Deploy Mode
- `-Deploy` - Actually create Azure resources (without this, estimate only)
- `-SubscriptionId <string>` - Target Azure subscription (required with -Deploy)
- `-VROServicePrincipalId <string>` - Grant VRO Contributor access on the resource group

### Authentication (Deploy mode only)
- `-TenantId <string>` - Azure AD tenant (optional)
- `-UseManagedIdentity` - Use Managed Identity
- `-ServicePrincipalId <string>` - App ID for service principal
- `-CertificateThumbprint <string>` - Certificate auth (recommended)
- `-ServicePrincipalSecret <securestring>` - Client secret (legacy)
- `-UseDeviceCode` - Device code flow for headless scenarios

### Output
- `-OutputPath <string>` - Custom output folder
- `-GenerateHTML` - Generate HTML report (default: true)
- `-ZipOutput` - Create ZIP archive (default: true)

## Examples

**Small environment estimate:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 10 -SourceDataTB 5 -Region "eastus2"
```

**Large environment with custom VM size:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 200 -SourceDataTB 100 -Region "westeurope" -TargetVMSize "Standard_D8s_v5"
```

**Deploy with VRO service principal:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 50 -SourceDataTB 25 -Region "eastus2" `
  -Deploy -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
  -VROServicePrincipalId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy"
```

**Deploy with service principal auth:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 50 -SourceDataTB 25 -Region "centralus" `
  -Deploy -SubscriptionId "xxx" `
  -ServicePrincipalId "app-id" -CertificateThumbprint "cert-thumb" -TenantId "tenant-id"
```

**Custom network ranges for large environments:**
```powershell
.\New-VeeamDRLandingZone.ps1 -VMCount 500 -SourceDataTB 200 -Region "eastus2" `
  -VNetAddressSpace "10.100.0.0/16" `
  -RecoverySubnetCIDR "10.100.0.0/22" `
  -ManagementSubnetCIDR "10.100.4.0/24"
```

## Output Files

**Primary deliverable:**
- `Veeam-DR-LandingZone-Report.html` - Professional report with architecture diagram, BOM, and cost breakdown

**Detailed data:**
- `dr_bill_of_materials.csv` - Every Azure component with specifications and costs
- `dr_cost_estimate.csv` - Always-on and DR-active cost breakdown
- `deployed_resources.csv` - Created Azure resources (Deploy mode only)
- `execution_log.csv` - Operation log

**Archive:**
- `VeeamDRLandingZone_[timestamp].zip` - All files bundled

## What Gets Created (Deploy Mode)

| Resource | Name Pattern | Purpose |
|----------|-------------|---------|
| Resource Group | `veeam-dr-rg` | Container for all DR resources |
| Virtual Network | `veeam-dr-vnet` | Network for recovered VMs |
| Recovery Subnet | `veeam-dr-snet-recovery` | Subnet where VMs are restored |
| Management Subnet | `veeam-dr-snet-mgmt` | Subnet for VRO and proxies |
| NSG (Recovery) | `veeam-dr-nsg-recovery` | RDP/SSH restricted to VNet |
| NSG (Management) | `veeam-dr-nsg-mgmt` | HTTPS + Veeam ports (9392-9401) |
| Storage Account | `veeamdrsa[MMDD]` | Staging area for restores |

## Cost Model

### Always-On (Monthly)
These costs keep your DR landing zone ready:
- **Management VMs** - VRO and proxy servers (2-4 VMs depending on scale)
- **Staging Storage** - Blob storage for restore metadata and staging

### DR-Active (Per Day)
These costs only apply during an actual failover event:
- **Compute** - Recovered VMs running in Azure
- **Managed Disks** - OS and data disks for recovered VMs

This pay-as-you-go model means you only pay significant compute costs when you actually need DR.

## Architecture

```
Azure Subscription (DR Region)
+-- Resource Group: veeam-dr-rg
    |
    +-- Virtual Network: veeam-dr-vnet (10.200.0.0/16)
    |   |
    |   +-- Subnet: veeam-dr-snet-mgmt (10.200.0.0/24)
    |   |   +-- NSG: veeam-dr-nsg-mgmt
    |   |   +-- VRO Server
    |   |   +-- Veeam Proxy VM(s)
    |   |
    |   +-- Subnet: veeam-dr-snet-recovery (10.200.1.0/24)
    |       +-- NSG: veeam-dr-nsg-recovery
    |       +-- [Recovered VMs during DR]
    |
    +-- Storage Account: veeamdrsa
        +-- Restore staging data
```

## After Deployment: Next Steps

1. **Configure Network Connectivity** - Set up VNet Peering or VPN Gateway to connect the DR VNet to your on-premises network or production Azure VNet
2. **Deploy VRO** - Install Veeam Recovery Orchestrator in the management subnet
3. **Create Recovery Plans** - Define VRO recovery plans mapping production VMs to DR targets
4. **Restrict NSG Rules** - Update NSG source IPs from "VirtualNetwork" to specific admin IPs
5. **Test DR** - Run a VRO test failover to validate the landing zone

## Prerequisites

### Estimate Mode
- PowerShell 7.x or 5.1
- Internet connectivity for Azure Pricing API

### Deploy Mode
- PowerShell 7.x or 5.1
- Az PowerShell modules: `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.Storage`
- Azure subscription with Contributor permissions
- Internet connectivity

**Install Az modules:**
```powershell
Install-Module Az.Accounts, Az.Resources, Az.Network, Az.Storage -Scope CurrentUser
```

## Use Cases

### First-Time Azure DR Customer
Customer has Veeam Vault Advanced backups and wants to explore DR to Azure for the first time.

```powershell
# Generate estimate for stakeholder approval
.\New-VeeamDRLandingZone.ps1 -VMCount 30 -SourceDataTB 15 -Region "eastus2"
```

**Talking points:**
- "Here's exactly what we need to build in Azure for DR"
- "Your always-on cost is just management VMs and storage"
- "Compute costs only apply during an actual DR event"
- "VRO orchestrates the entire recovery automatically"

### Existing Azure Customer Adding DR
Customer already has Azure subscriptions but hasn't set up a dedicated DR landing zone.

```powershell
# Deploy to a dedicated DR subscription
.\New-VeeamDRLandingZone.ps1 -VMCount 100 -SourceDataTB 50 -Region "westus2" `
  -Deploy -SubscriptionId "dr-sub-id" -NamingPrefix "contoso-dr"
```

### Proof of Concept
SE needs to quickly stand up a DR environment for a customer demo.

```powershell
# Small footprint for POC
.\New-VeeamDRLandingZone.ps1 -VMCount 5 -SourceDataTB 1 -Region "eastus2" `
  -Deploy -SubscriptionId "poc-sub-id" -NamingPrefix "poc-dr"
```

## Important Notes

- **Idempotent (with exceptions)** - Deploy checks for and reuses existing resources where possible and avoids duplicating the landing zone. However, some resources (such as the storage account, which uses a date-based suffix in its name) may be recreated when you rerun Deploy on a different day.
- **No VMs created** - This tool creates infrastructure scaffolding only; VRO handles VM recovery
- **NSG defaults are permissive** - Tighten RDP/SSH source IPs after deployment
- **VPN/ExpressRoute not included** - Network connectivity must be configured separately
- **Pricing is estimated** - Based on Azure Retail Prices API; actual costs may vary

## Support

- **Sales Engineers** - Contact your Veeam Solutions Architect
- **VRO Documentation** - [Veeam Recovery Orchestrator Guide](https://helpcenter.veeam.com/docs/one/reporter/about.html)
- **Azure Pricing** - [Azure Retail Prices API](https://learn.microsoft.com/en-us/rest/api/cost-management/retail-prices/azure-retail-prices)

---

**© 2026 Veeam Software**
