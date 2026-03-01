# Veeam VBR v13 MCP - Quick Reference Card

## 🚀 Quick Start

```powershell
# Navigate to MCP directory
cd /path/to/veeam-powershell/MCP

# Run health check
.\veeam-mcp.ps1 -Action Health

# Full assessment
.\veeam-mcp.ps1 -Action All -OutputFormat Both
```

## 📋 Common Commands

### Health Check
```powershell
.\veeam-mcp.ps1 -Action Health
```

### Server Information
```powershell
.\veeam-mcp.ps1 -Action ServerInfo
```

### Job Analysis
```powershell
# All jobs
.\veeam-mcp.ps1 -Action Jobs

# Specific job
.\veeam-mcp.ps1 -Action Jobs -JobName "Production VMs"
```

### Repository Status
```powershell
.\veeam-mcp.ps1 -Action Repositories
```

### Restore Points
```powershell
# All VMs
.\veeam-mcp.ps1 -Action RestorePoints

# Specific VM
.\veeam-mcp.ps1 -Action RestorePoints -VMName "SQL-01"
```

### Recent Sessions
```powershell
.\veeam-mcp.ps1 -Action Sessions
```

### Infrastructure Inventory
```powershell
.\veeam-mcp.ps1 -Action Infrastructure
```

### Capacity Planning
```powershell
.\veeam-mcp.ps1 -Action Capacity
```

### Complete Assessment
```powershell
.\veeam-mcp.ps1 -Action All
```

## 🌐 Remote Server

```powershell
# Get credentials
$cred = Get-Credential

# Connect to remote VBR
.\veeam-mcp.ps1 -VBRServer "vbr-remote.domain.com" `
                -Credential $cred `
                -Action Health
```

## 📊 Output Formats

### JSON Only (Default)
```powershell
.\veeam-mcp.ps1 -Action Health -OutputFormat JSON
```

### CSV Only
```powershell
.\veeam-mcp.ps1 -Action Jobs -OutputFormat CSV
```

### Both JSON and CSV
```powershell
.\veeam-mcp.ps1 -Action All -OutputFormat Both
```

### Custom Output Path
```powershell
.\veeam-mcp.ps1 -Action Health `
                -ExportPath "C:\VeeamReports" `
                -OutputFormat Both
```

## 🧪 Testing

```powershell
# Run test suite
.\tests\test-mcp.ps1

# Skip VBR connection tests
.\tests\test-mcp.ps1 -SkipVBRConnection

# Verbose output
.\tests\test-mcp.ps1 -Verbose
```

## 📖 Examples

```powershell
# Quick start examples
.\examples\quick-start.ps1

# AI integration examples
.\examples\ai-integration.ps1
```

## 🔍 Viewing Results

### Latest Run
```powershell
# Find latest output
$latest = Get-ChildItem ./VeeamMCPOutput -Directory | 
          Sort-Object Name -Descending | 
          Select-Object -First 1

# View health status
Get-Content "$($latest.FullName)\VBR-Health.json" | ConvertFrom-Json

# View jobs
Get-Content "$($latest.FullName)\VBR-Jobs.json" | ConvertFrom-Json

# View CSV in Excel
Invoke-Item "$($latest.FullName)\VBR-Jobs.csv"
```

### Parse JSON
```powershell
$health = Get-Content ./VeeamMCPOutput/Run-*/VBR-Health.json | ConvertFrom-Json
Write-Host "Status: $($health.OverallStatus)"
```

## 📅 Scheduling

### Daily Health Check
```powershell
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-File C:\Scripts\veeam-mcp.ps1 -Action Health"

$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM

Register-ScheduledTask `
    -TaskName "Veeam MCP Health Check" `
    -Action $action `
    -Trigger $trigger
```

### Weekly Full Report
```powershell
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-File C:\Scripts\veeam-mcp.ps1 -Action All -OutputFormat Both"

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 6:00AM

Register-ScheduledTask `
    -TaskName "Veeam MCP Weekly Report" `
    -Action $action `
    -Trigger $trigger
```

## 🎯 Action Reference

| Action | Description | Output Files |
|--------|-------------|--------------|
| `ServerInfo` | VBR server details | VBR-ServerInfo.json |
| `Jobs` | Job inventory | VBR-Jobs.json/csv |
| `Repositories` | Repository status | VBR-Repositories.json/csv |
| `RestorePoints` | Restore points | VBR-RestorePoints.json/csv |
| `Sessions` | Recent sessions | VBR-Sessions.json/csv |
| `Infrastructure` | Infrastructure | VBR-Infrastructure-*.json |
| `Capacity` | Capacity metrics | VBR-Capacity-*.json |
| `Health` | Health analysis | VBR-Health.json |
| `All` | Complete run | All files |

## 📊 Understanding Output

### Health Status Values
- **Healthy** - All systems operational
- **Warning** - Non-critical issues detected
- **Critical** - Immediate attention required

### Job LastResult Values
- **Success** - Completed successfully
- **Warning** - Completed with warnings
- **Failed** - Job failed

### Job Types
- **Backup** - VM/Agent backup job
- **BackupCopy** - Backup copy job
- **Replication** - Replication job
- **BackupSync** - Backup sync job

## 🔧 Troubleshooting

### VeeamPSSnapin Not Found
```powershell
# Check if registered
Get-PSSnapin -Registered | Where-Object {$_.Name -eq "VeeamPSSnapin"}

# Add manually
Add-PSSnapin VeeamPSSnapin
```

### Connection Failed
```powershell
# Test connectivity
Test-NetConnection -ComputerName "vbr-server" -Port 9392

# Manual connection
Connect-VBRServer -Server "vbr-server"
```

### Permission Denied
```powershell
# Check VBR session
Get-VBRServerSession | Select-Object User, ServerVersion, IsConnected
```

### View Script Help
```powershell
Get-Help .\veeam-mcp.ps1 -Full
Get-Help .\veeam-mcp.ps1 -Examples
```

## 📁 Directory Structure

```
MCP/
├── veeam-mcp.ps1              # Main script
├── README.md                   # Full documentation
├── DEPLOYMENT.md              # Deployment guide
├── ARCHITECTURE.md            # Architecture docs
├── PROJECT_SUMMARY.md         # Project overview
├── CHANGELOG.md               # Version history
├── QUICK_REFERENCE.md         # This file
│
├── config/
│   └── veeam-mcp-config.template.json
│
├── examples/
│   ├── quick-start.ps1
│   └── ai-integration.ps1
│
├── tests/
│   └── test-mcp.ps1
│
└── VeeamMCPOutput/           # Auto-created
    └── Run-YYYY-MM-DD_HHMMSS/
```

## 🔐 Security Best Practices

1. **Use Service Account**
   - Create dedicated account
   - Minimum required permissions
   - No interactive logon

2. **Secure Credentials**
   ```powershell
   # Never hardcode passwords
   $cred = Get-Credential
   ```

3. **Restrict Output Access**
   ```powershell
   # Set NTFS permissions on output folder
   icacls C:\VeeamMCP /grant "DOMAIN\VeeamAdmins:(OI)(CI)F" /inheritance:r
   ```

4. **Enable Logging**
   - Monitor script execution
   - Review for anomalies
   - Audit access to outputs

## 💡 Tips & Tricks

### Speed Up Execution
```powershell
# Use specific actions instead of "All"
.\veeam-mcp.ps1 -Action Health  # Faster

# Run on VBR server (no network latency)
```

### Automate Analysis
```powershell
# Parse and alert
$health = .\veeam-mcp.ps1 -Action Health | Out-Null
$result = Get-Content ./VeeamMCPOutput/Run-*/VBR-Health.json | ConvertFrom-Json

if ($result.OverallStatus -eq "Critical") {
    Send-MailMessage -To "admin@company.com" `
                     -Subject "Veeam Critical Alert" `
                     -Body "Issues: $($result.Issues -join ', ')"
}
```

### Export to Excel
```powershell
# CSV files open directly in Excel
.\veeam-mcp.ps1 -Action Jobs -OutputFormat CSV
Invoke-Item ./VeeamMCPOutput/Run-*/VBR-Jobs.csv
```

### Multi-Server Monitoring
```powershell
$servers = @("vbr1", "vbr2", "vbr3")
foreach ($server in $servers) {
    .\veeam-mcp.ps1 -VBRServer $server -Action Health
}
```

## 📞 Getting Help

### Documentation
- **Full Guide**: README.md
- **Deployment**: DEPLOYMENT.md
- **Architecture**: ARCHITECTURE.md
- **Examples**: examples/ folder

### Command Help
```powershell
Get-Help .\veeam-mcp.ps1 -Detailed
```

### Veeam Resources
- **Help Center**: https://helpcenter.veeam.com
- **Forums**: https://forums.veeam.com
- **PowerShell**: Get-Command -Module VeeamPSSnapin

## 🎓 Learning Path

1. **Start Simple**: Run `-Action Health`
2. **Explore Data**: View JSON outputs
3. **Try Examples**: Run quick-start.ps1
4. **Customize**: Modify for your needs
5. **Automate**: Set up scheduling
6. **Integrate**: Connect to other systems

## ⚡ Performance Tips

| Scenario | Recommendation |
|----------|----------------|
| Large environment | Use specific actions, not "All" |
| Many VMs | Filter by VM name |
| Remote VBR | Run on VBR server if possible |
| Frequent runs | Cache results, reduce frequency |
| Slow network | Increase timeout values |

## 📈 Monitoring Checklist

Daily:
- [ ] Review health status
- [ ] Check failed jobs
- [ ] Monitor repository space

Weekly:
- [ ] Full report generation
- [ ] Capacity trend review
- [ ] Performance analysis

Monthly:
- [ ] Archive old reports
- [ ] Clean up logs
- [ ] Update documentation

## 🏆 Success Metrics

Track these KPIs:
- ✅ Backup success rate (target: >95%)
- ✅ Repository utilization (target: <80%)
- ✅ RPO compliance (target: 100%)
- ✅ Failed job detection (target: <24h)
- ✅ Script execution time (target: <5min)

---

**Quick Reference Version**: 1.0  
**Last Updated**: January 16, 2026  
**Print This**: For desk reference

**Pro Tip**: Bookmark this file in your terminal for quick access!
