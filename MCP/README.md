# Veeam Backup & Replication v13 - MCP Demo Script

## Overview

This comprehensive PowerShell script demonstrates Model Context Protocol (MCP) functionality with Veeam Backup & Replication v13. It provides AI assistants and automation tools with structured access to Veeam infrastructure data, enabling intelligent monitoring, management, and decision-making capabilities.

## Features

### 🔍 **Discovery & Monitoring**
- **Server Information**: VBR version, edition, build, database details
- **Job Management**: Comprehensive job details, schedules, and configurations
- **Repository Analysis**: Capacity tracking, performance metrics, health status
- **Restore Points**: VM recovery points with metadata and availability
- **Session History**: Recent backup sessions with success/failure tracking
- **Infrastructure**: Proxies, managed servers, WAN accelerators

### 📊 **Analytics & Reporting**
- **Capacity Planning**: Storage utilization, compression ratios, growth trends
- **Health Monitoring**: Automated health checks with issue detection
- **Performance Metrics**: Job duration, throughput, success rates
- **Compliance Tracking**: Backup age, retention policy adherence

### 🤖 **MCP Integration**
- **Structured JSON Output**: AI-friendly data formats
- **CSV Exports**: Spreadsheet-compatible reporting
- **Contextual Data**: Rich metadata for intelligent decision-making
- **Error Handling**: Comprehensive logging and exception management

## Requirements

- **Veeam Backup & Replication**: v13 or later
- **PowerShell**: 5.1 or later
- **VeeamPSSnapin**: Installed with Veeam B&R
- **Permissions**: Veeam Administrator or higher
- **OS**: Windows Server 2016+ or Windows 10/11

## Installation

1. Clone or download this repository
2. Ensure Veeam B&R v13 is installed
3. Verify VeeamPSSnapin is available:
   ```powershell
   Get-PSSnapin -Registered | Where-Object {$_.Name -eq "VeeamPSSnapin"}
   ```

## Usage

### Basic Examples

#### Run All Checks
```powershell
.\veeam-mcp.ps1 -VBRServer "veeam-server.domain.com" -Action All
```

#### Check Server Information Only
```powershell
.\veeam-mcp.ps1 -Action ServerInfo
```

#### Analyze Job Status
```powershell
.\veeam-mcp.ps1 -Action Jobs
```

#### Monitor Repository Capacity
```powershell
.\veeam-mcp.ps1 -Action Repositories
```

#### Health Status Check
```powershell
.\veeam-mcp.ps1 -Action Health
```

#### Specific Job Analysis
```powershell
.\veeam-mcp.ps1 -Action Jobs -JobName "Production VMs"
```

#### VM Restore Points
```powershell
.\veeam-mcp.ps1 -Action RestorePoints -VMName "SQL-Server-01"
```

### Advanced Usage

#### Custom Output Location
```powershell
.\veeam-mcp.ps1 -Action All -ExportPath "C:\VeeamReports" -OutputFormat Both
```

#### Remote Server with Credentials
```powershell
$cred = Get-Credential
.\veeam-mcp.ps1 -VBRServer "remote-vbr.domain.com" -Credential $cred -Action All
```

#### JSON Only Output
```powershell
.\veeam-mcp.ps1 -Action Capacity -OutputFormat JSON
```

#### CSV Export for Excel
```powershell
.\veeam-mcp.ps1 -Action Sessions -OutputFormat CSV
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `VBRServer` | String | No | localhost | VBR server name or IP |
| `Credential` | PSCredential | No | Current user | Authentication credentials |
| `Action` | String | No | All | Operation to perform |
| `JobName` | String | No | - | Specific job name filter |
| `VMName` | String | No | - | VM name for restore point queries |
| `ExportPath` | String | No | ./VeeamMCPOutput | Output directory |
| `OutputFormat` | String | No | JSON | Output format (JSON/CSV/Both) |

## Action Types

| Action | Description | Output Files |
|--------|-------------|--------------|
| `All` | Execute all checks | Multiple files |
| `ServerInfo` | VBR server details | VBR-ServerInfo.json |
| `Jobs` | Backup job information | VBR-Jobs.json/csv |
| `Repositories` | Repository capacity & health | VBR-Repositories.json/csv |
| `RestorePoints` | Available restore points | VBR-RestorePoints.json/csv |
| `Sessions` | Recent backup sessions | VBR-Sessions.json/csv |
| `Infrastructure` | Infrastructure components | VBR-Infrastructure-*.json/csv |
| `Capacity` | Capacity metrics & planning | VBR-Capacity-*.json |
| `Health` | Health status analysis | VBR-Health.json |

## Output Structure

### Directory Layout
```
VeeamMCPOutput/
└── Run-2026-01-16_143022/
    ├── VBR-ServerInfo.json
    ├── VBR-Jobs.json
    ├── VBR-Jobs.csv
    ├── VBR-Repositories.json
    ├── VBR-RestorePoints.json
    ├── VBR-Sessions.json
    ├── VBR-Infrastructure-ManagedServers.json
    ├── VBR-Infrastructure-Proxies.json
    ├── VBR-Capacity-Summary.json
    ├── VBR-Health.json
    └── VBR-MCP-Summary.json
```

### JSON Schema Examples

#### Server Info
```json
{
  "ServerName": "veeam-server",
  "ServerVersion": "13.0.0.1234",
  "ServerEdition": "Enterprise Plus",
  "BuildNumber": "1234",
  "DatabaseName": "VeeamBackup",
  "Connected": true
}
```

#### Job Details
```json
[
  {
    "Name": "Production VMs",
    "Type": "Backup",
    "IsEnabled": true,
    "LastResult": "Success",
    "SourceSize": 500.25,
    "BackupSize": 125.50,
    "CompressionLevel": "Optimal"
  }
]
```

#### Health Status
```json
{
  "OverallStatus": "Warning",
  "Issues": [],
  "Warnings": [
    "Repository 'Backup-Repo-01' is 92% full"
  ],
  "Metrics": {
    "FailedJobs": 0,
    "WarningJobs": 2,
    "LowSpaceRepos": 1
  }
}
```

## Use Cases

### 1. **AI-Powered Monitoring**
Enable AI assistants to:
- Monitor backup health proactively
- Identify capacity issues before they occur
- Recommend optimization strategies
- Generate intelligent alerts

### 2. **Automated Reporting**
- Schedule daily/weekly health reports
- Track SLA compliance
- Monitor backup trends
- Capacity forecasting

### 3. **Troubleshooting Assistant**
- Quick health assessments
- Identify failed jobs and reasons
- Repository space warnings
- Session analysis

### 4. **Capacity Planning**
- Track storage growth trends
- Calculate compression ratios
- Project future capacity needs
- Optimize repository allocation

### 5. **Compliance & Auditing**
- Verify backup coverage
- Check retention policies
- Audit restore point availability
- Document infrastructure state

## MCP Integration Patterns

### Example: AI Health Check
```powershell
# AI assistant runs health check
$result = .\veeam-mcp.ps1 -Action Health -OutputFormat JSON

# Parse JSON for AI analysis
$health = Get-Content "./VeeamMCPOutput/Run-*/VBR-Health.json" | ConvertFrom-Json

# AI can now:
# - Analyze health.OverallStatus
# - Review health.Issues array
# - Recommend remediation actions
# - Create tickets for critical issues
```

### Example: Capacity Planning
```powershell
# Get capacity metrics
.\veeam-mcp.ps1 -Action Capacity

# AI analyzes trends and projects:
# - When repositories will be full
# - Which repos need expansion
# - Compression effectiveness
# - Deduplication opportunities
```

## Error Handling

The script includes comprehensive error handling:

- ✅ **Connection failures**: Graceful handling with clear messages
- ✅ **Permission issues**: Informative error reporting
- ✅ **Missing data**: Skips unavailable metrics without failing
- ✅ **API errors**: Catches and logs VBR API exceptions
- ✅ **Export errors**: Continues execution even if export fails

## Best Practices

1. **Schedule Regular Runs**: Daily health checks, weekly capacity reports
2. **Monitor Critical Metrics**: Failed jobs, low repository space, old backups
3. **Version Control**: Track configuration changes over time
4. **Retention**: Archive historical reports for trend analysis
5. **Access Control**: Restrict script execution to authorized personnel
6. **Logging**: Review script output for warnings and errors

## Troubleshooting

### VeeamPSSnapin Not Found
```powershell
# Verify Veeam installation
Get-PSSnapin -Registered | Where-Object {$_.Name -like "*Veeam*"}

# Add manually if needed
Add-PSSnapin VeeamPSSnapin
```

### Connection Failed
```powershell
# Test connectivity
Test-NetConnection -ComputerName "veeam-server" -Port 9392

# Verify credentials
$cred = Get-Credential
Connect-VBRServer -Server "veeam-server" -Credential $cred
```

### Permission Denied
- Ensure account has Veeam Administrator role
- Check Windows permissions on VBR server
- Verify firewall rules allow port 9392

### Export Path Issues
```powershell
# Use absolute paths
.\veeam-mcp.ps1 -ExportPath "C:\VeeamReports"

# Verify write permissions
New-Item -ItemType Directory -Path "C:\VeeamReports" -Force
```

## Advanced Scenarios

### Integration with Monitoring Systems
```powershell
# Export to SIEM/Monitoring platform
$health = .\veeam-mcp.ps1 -Action Health -OutputFormat JSON
$data = Get-Content "./VeeamMCPOutput/*/VBR-Health.json" | ConvertFrom-Json

# Send to monitoring API
Invoke-RestMethod -Uri "https://monitoring.company.com/api/veeam" `
                  -Method POST `
                  -Body ($data | ConvertTo-Json) `
                  -ContentType "application/json"
```

### Scheduled Task
```powershell
# Create scheduled task for daily health checks
$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
          -Argument "-File C:\Scripts\veeam-mcp.ps1 -Action Health"
$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM
Register-ScheduledTask -Action $action -Trigger $trigger `
                      -TaskName "Veeam Health Check" `
                      -Description "Daily Veeam backup health monitoring"
```

## Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test thoroughly with VBR v13
4. Submit a pull request

## Version History

- **v1.0** (January 2026)
  - Initial release
  - Complete MCP integration
  - All core monitoring features
  - JSON/CSV export capabilities
  - Health analysis engine

## Support

For issues or questions:
- Check Veeam documentation: https://helpcenter.veeam.com
- Review PowerShell module help: `Get-Help Get-VBR*`
- Veeam Community Forums: https://forums.veeam.com

## License

This script is provided as-is for demonstration and educational purposes.

## Author

**Veeam Solutions Architect**  
January 2026

---

*Built for Veeam Backup & Replication v13 with MCP (Model Context Protocol) integration*
