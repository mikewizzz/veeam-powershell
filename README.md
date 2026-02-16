# Veeam PowerShell Tools

Community-maintained PowerShell tools for Veeam backup solutions across Microsoft 365, Azure, AWS, Active Directory, and on-premises environments. These tools help IT professionals, architects, and administrators perform capacity planning, cost analysis, infrastructure management, and disaster recovery orchestration.

## Tools

### Microsoft 365

| Tool | Description |
|------|-------------|
| [Get-VeeamM365Sizing](M365/Get-VeeamM365Sizing/) | Assess M365 tenant backup requirements and estimate MBS capacity for Veeam Backup for Microsoft 365 |

### Azure

| Tool | Description |
|------|-------------|
| [Get-VeeamAzureSizing](AZURE/Get-VeeamAzureSizing/) | Assess Azure infrastructure for Veeam backup sizing |
| [Get-VeeamVaultPricing](AZURE/Get-VeeamVaultPricing/) | Compare Veeam Vault vs Azure Blob storage costs |
| [Get-VBAHealthCheck](AZURE/Get-VBAHealthCheck/) | Health check and compliance assessment for Veeam Backup for Azure |
| [New-VeeamDRLandingZone](AZURE/New-VeeamDRLandingZone/) | Provision DR landing zones in Azure |
| [Start-AzureBlobToVaultMigration](AZURE/Start-AzureBlobToVaultMigration/) | Migrate Azure Blob repositories to Veeam Vault |
| [Test-VeeamVaultBackup](AZURE/Test-VeeamVaultBackup/) | Automated backup verification (SureBackup) for Azure |
| [Start-VROAzureRecovery](AZURE/Start-VRO-Azure-Recovery/) | Trigger Azure recovery plans from VRO *(stub)* |

### AWS

| Tool | Description |
|------|-------------|
| [Find-CleanEC2-RestorePoint](AWS/Find-CleanEC2-RestorePoint/) | VRO pre-step: find the latest malware-free Veeam restore point |
| [Restore-VRO-AWS-EC2](AWS/Restore-VRO-AWS-EC2/) | VRO plan step: restore Veeam backups to Amazon EC2 |

### Active Directory

| Tool | Description |
|------|-------------|
| [Get-ADIdentityAssessment](ActiveDirectory/Get-ADIdentityAssessment/) | On-premises AD identity structure assessment |

### Veeam Backup & Replication

| Tool | Description |
|------|-------------|
| [Get-VeeamDiagram](VBR/Get-VeeamDiagram/) | Generate infrastructure diagrams from VBR v13 REST API |

### On-Premises

| Tool | Description |
|------|-------------|
| [New-VeeamSureBackupSetup](ONPREM/New-VeeamSureBackupSetup/) | Automated SureBackup environment setup |

### MySQL

| Tool | Description |
|------|-------------|
| [Invoke-VeeamMySQLBackup](MySQL/Invoke-VeeamMySQLBackup/) | MySQL backup integration with Veeam agents |

### Nutanix AHV

| Tool | Description |
|------|-------------|
| [Start-VeeamAHVSureBackup](NutanixAHV/Start-VeeamAHVSureBackup/) | SureBackup verification for Nutanix AHV |

### Pure Storage

| Tool | Description |
|------|-------------|
| [Restore-VRO-PureStorage-VMware](PURE-STORAGE/Restore-VRO-PureStorage-VMware/) | VRO restore for Pure Storage VMware environments |

## Requirements

- PowerShell 5.1+ (7.x recommended)
- Module dependencies vary per script — see each tool's README for details

## Contributing

Contributions welcome. See [M365/CONTRIBUTING.md](M365/CONTRIBUTING.md) for coding standards.

## License

[MIT](M365/LICENSE)
