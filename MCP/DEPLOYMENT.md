# Veeam VBR v13 MCP - Deployment Guide

## Table of Contents
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Testing](#testing)
- [Production Deployment](#production-deployment)
- [Automation & Scheduling](#automation--scheduling)
- [Monitoring & Maintenance](#monitoring--maintenance)
- [Troubleshooting](#troubleshooting)

## Prerequisites

### System Requirements
- **Operating System**: Windows Server 2016+ or Windows 10/11
- **PowerShell**: Version 5.1 or later
- **Veeam B&R**: Version 13 or later
- **Memory**: 4 GB RAM minimum (8 GB recommended)
- **Disk Space**: 1 GB for scripts and outputs

### Software Requirements
1. **Veeam Backup & Replication v13**
   - VeeamPSSnapin installed
   - Access to VBR server (local or remote)

2. **PowerShell Components**
   ```powershell
   # Verify PowerShell version
   $PSVersionTable.PSVersion
   # Should be 5.1 or higher
   ```

3. **Network Access**
   - Port 9392 (VBR PowerShell remoting)
   - Port 9393 (VBR SOAP web services)
   - DNS resolution to VBR server

### Permissions Required
- **Veeam Administrator** role or higher
- **Windows**: Local administrator (for VBR server operations)
- **File System**: Read/write access to output directories

## Installation

### Step 1: Download Scripts

```powershell
# Clone or download to desired location
cd C:\Scripts
git clone <repository-url> veeam-powershell

# Or download and extract ZIP
# Extract to C:\Scripts\veeam-powershell
```

### Step 2: Verify Directory Structure

```powershell
# Check structure
tree C:\Scripts\veeam-powershell\MCP /F

# Expected structure:
# MCP/
# ├── veeam-mcp.ps1
# ├── README.md
# ├── DEPLOYMENT.md
# ├── config/
# │   └── veeam-mcp-config.template.json
# ├── examples/
# │   ├── quick-start.ps1
# │   └── ai-integration.ps1
# └── tests/
#     └── test-mcp.ps1
```

### Step 3: Set Execution Policy

```powershell
# Allow script execution (run as Administrator)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine

# Verify
Get-ExecutionPolicy
```

### Step 4: Test Veeam PSSnapin

```powershell
# Check if VeeamPSSnapin is available
Get-PSSnapin -Registered | Where-Object {$_.Name -eq "VeeamPSSnapin"}

# Load the snapin
Add-PSSnapin VeeamPSSnapin

# Verify Veeam cmdlets are available
Get-Command -Module VeeamPSSnapin | Select-Object -First 5
```

## Configuration

### Basic Configuration

1. **Copy Configuration Template**
   ```powershell
   cd C:\Scripts\veeam-powershell\MCP\config
   Copy-Item veeam-mcp-config.template.json veeam-mcp-config.json
   ```

2. **Edit Configuration** (optional - script works with defaults)
   ```powershell
   notepad veeam-mcp-config.json
   ```

3. **Key Settings to Review**
   - `VBRServer.HostName`: Your VBR server name
   - `Output.BasePath`: Where to store reports
   - `Monitoring.Thresholds`: Alert thresholds
   - `Integrations`: Email, webhooks, SIEM

### Environment-Specific Setup

#### Local VBR Server
```powershell
# No additional configuration needed
# Script defaults to localhost
```

#### Remote VBR Server
```powershell
# Update config or use parameter
$cred = Get-Credential
.\veeam-mcp.ps1 -VBRServer "vbr-prod.domain.com" -Credential $cred -Action Health
```

#### Multi-Server Environment
```powershell
# Create separate config files
Copy-Item veeam-mcp-config.json veeam-mcp-prod.json
Copy-Item veeam-mcp-config.json veeam-mcp-dr.json

# Edit each for respective servers
```

## Testing

### Run Test Suite

```powershell
cd C:\Scripts\veeam-powershell\MCP\tests

# Run all tests
.\test-mcp.ps1

# Run tests without VBR connection (syntax/structure only)
.\test-mcp.ps1 -SkipVBRConnection

# Verbose output
.\test-mcp.ps1 -Verbose
```

### Manual Testing

#### Test 1: Basic Connectivity
```powershell
cd C:\Scripts\veeam-powershell\MCP

# Test server connection
.\veeam-mcp.ps1 -Action ServerInfo
```

#### Test 2: Job Retrieval
```powershell
# Get all jobs
.\veeam-mcp.ps1 -Action Jobs

# Verify output
Get-ChildItem .\VeeamMCPOutput\Run-* -Recurse | Select-Object Name
```

#### Test 3: Health Check
```powershell
# Run health analysis
.\veeam-mcp.ps1 -Action Health

# Review results
$result = Get-Content .\VeeamMCPOutput\Run-*\VBR-Health.json | ConvertFrom-Json
$result.OverallStatus
```

#### Test 4: Full Run
```powershell
# Execute all checks
.\veeam-mcp.ps1 -Action All -OutputFormat Both
```

### Validation Checklist

- [ ] Script executes without errors
- [ ] Output directory created
- [ ] JSON files generated
- [ ] Data appears accurate
- [ ] No PowerShell warnings
- [ ] Performance is acceptable (< 5 minutes for All)

## Production Deployment

### Step 1: Create Production Directory Structure

```powershell
# Create production folders
$prodPath = "C:\VeeamMCP"
New-Item -ItemType Directory -Path "$prodPath\Scripts" -Force
New-Item -ItemType Directory -Path "$prodPath\Output" -Force
New-Item -ItemType Directory -Path "$prodPath\Logs" -Force
New-Item -ItemType Directory -Path "$prodPath\Config" -Force

# Copy scripts
Copy-Item "C:\Scripts\veeam-powershell\MCP\*.ps1" "$prodPath\Scripts\" -Force
Copy-Item "C:\Scripts\veeam-powershell\MCP\config\*" "$prodPath\Config\" -Force
```

### Step 2: Configure Production Settings

```powershell
# Edit production config
notepad "$prodPath\Config\veeam-mcp-config.json"

# Update paths
# "Output.BasePath": "C:\\VeeamMCP\\Output"
# "Logging.FilePath": "C:\\VeeamMCP\\Logs\\veeam-mcp.log"
```

### Step 3: Set Up Service Account (Recommended)

```powershell
# Create dedicated service account
# - Domain: DOMAIN\svc_veeam_mcp
# - Add to Veeam Administrators group
# - Grant "Log on as a batch job" right

# Test with service account
$cred = Get-Credential DOMAIN\svc_veeam_mcp
C:\VeeamMCP\Scripts\veeam-mcp.ps1 -Credential $cred -Action Health
```

### Step 4: Security Hardening

```powershell
# Restrict folder permissions
$acl = Get-Acl "C:\VeeamMCP"
# Remove inheritance
$acl.SetAccessRuleProtection($true, $false)
# Add specific permissions
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "DOMAIN\svc_veeam_mcp", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.AddAccessRule($rule)
Set-Acl "C:\VeeamMCP" $acl
```

## Automation & Scheduling

### Option 1: Scheduled Task (Recommended)

```powershell
# Create daily health check task
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\VeeamMCP\Scripts\veeam-mcp.ps1 -Action Health -ExportPath C:\VeeamMCP\Output"

$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM

$principal = New-ScheduledTaskPrincipal `
    -UserId "DOMAIN\svc_veeam_mcp" `
    -LogonType Password `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable

Register-ScheduledTask `
    -TaskName "Veeam MCP - Daily Health Check" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Daily Veeam infrastructure health monitoring via MCP"
```

### Option 2: Weekly Full Report

```powershell
# Create weekly comprehensive report
$action = New-ScheduledTaskAction `
    -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File C:\VeeamMCP\Scripts\veeam-mcp.ps1 -Action All -OutputFormat Both -ExportPath C:\VeeamMCP\Output"

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 6:00AM

Register-ScheduledTask `
    -TaskName "Veeam MCP - Weekly Full Report" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings
```

### Option 3: Multiple Schedules

```powershell
# Hourly capacity checks
$triggerHourly = New-ScheduledTaskTrigger -Once -At 12:00AM -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Days 365)

# Daily health checks
$triggerDaily = New-ScheduledTaskTrigger -Daily -At 6:00AM

# Weekly full reports
$triggerWeekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 8:00AM
```

### Monitoring Scheduled Tasks

```powershell
# View task status
Get-ScheduledTask -TaskName "Veeam MCP*" | Get-ScheduledTaskInfo

# Check last run result
Get-ScheduledTask -TaskName "Veeam MCP - Daily Health Check" | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult

# View task history
Get-WinEvent -LogName "Microsoft-Windows-TaskScheduler/Operational" | 
    Where-Object {$_.Message -like "*Veeam MCP*"} | 
    Select-Object -First 10
```

## Monitoring & Maintenance

### Daily Operations

1. **Review Health Status**
   ```powershell
   # Check latest health report
   $latest = Get-ChildItem C:\VeeamMCP\Output -Directory | Sort-Object Name -Descending | Select-Object -First 1
   $health = Get-Content "$($latest.FullName)\VBR-Health.json" | ConvertFrom-Json
   Write-Host "Status: $($health.OverallStatus)" -ForegroundColor $(if ($health.OverallStatus -eq "Healthy") {"Green"} else {"Red"})
   ```

2. **Check for Alerts**
   ```powershell
   # Review log for issues
   Get-Content C:\VeeamMCP\Logs\veeam-mcp.log -Tail 50 | Where-Object {$_ -match "Error|Critical|Failed"}
   ```

### Weekly Maintenance

1. **Review Capacity Trends**
   ```powershell
   # Analyze repository growth
   $reports = Get-ChildItem C:\VeeamMCP\Output -Directory | Sort-Object Name | Select-Object -Last 7
   foreach ($report in $reports) {
       $capacity = Get-Content "$($report.FullName)\VBR-Capacity-Summary.json" | ConvertFrom-Json
       [PSCustomObject]@{
           Date = $report.Name
           UsedGB = $capacity.UsedCapacity
           FreeGB = $capacity.FreeCapacity
       }
   }
   ```

2. **Archive Old Reports**
   ```powershell
   # Archive reports older than 30 days
   $archivePath = "C:\VeeamMCP\Archive"
   $threshold = (Get-Date).AddDays(-30)
   
   Get-ChildItem C:\VeeamMCP\Output -Directory | 
       Where-Object {$_.CreationTime -lt $threshold} | 
       ForEach-Object {
           Move-Item $_.FullName "$archivePath\$($_.Name)" -Force
       }
   ```

### Monthly Maintenance

1. **Clean Up Logs**
   ```powershell
   # Rotate logs older than 30 days
   Get-ChildItem C:\VeeamMCP\Logs -Filter "*.log" | 
       Where-Object {$_.LastWriteTime -lt (Get-Date).AddDays(-30)} | 
       Remove-Item -Force
   ```

2. **Performance Review**
   ```powershell
   # Analyze script execution times
   # Review scheduled task history for performance trends
   ```

## Troubleshooting

### Common Issues

#### Issue 1: VeeamPSSnapin Not Found

**Symptoms**: Error loading Veeam cmdlets

**Solution**:
```powershell
# Install Veeam console on the machine running the script
# Or run script directly on VBR server

# Verify installation
Get-PSSnapin -Registered | Where-Object {$_.Name -eq "VeeamPSSnapin"}
```

#### Issue 2: Access Denied

**Symptoms**: Permission errors when querying VBR

**Solution**:
```powershell
# Verify account is in Veeam Administrators group
# Check VBR server security settings

# Test connection
Connect-VBRServer -Server "vbr-server" -Credential (Get-Credential)
Get-VBRServerSession
```

#### Issue 3: Output Not Generated

**Symptoms**: Script runs but no files created

**Solution**:
```powershell
# Check output path permissions
Test-Path C:\VeeamMCP\Output -PathType Container

# Verify write access
New-Item -ItemType File -Path "C:\VeeamMCP\Output\test.txt" -Force

# Check disk space
Get-PSDrive C | Select-Object Used,Free
```

#### Issue 4: Slow Performance

**Symptoms**: Script takes too long to execute

**Solutions**:
```powershell
# 1. Limit scope
.\veeam-mcp.ps1 -Action Health  # Instead of All

# 2. Filter data
# Edit script to exclude unnecessary VMs/jobs

# 3. Run on VBR server (avoid network latency)

# 4. Schedule during off-hours
```

#### Issue 5: JSON Parse Errors

**Symptoms**: Cannot read JSON output

**Solution**:
```powershell
# Verify file encoding
Get-Content file.json -Encoding UTF8 | ConvertFrom-Json

# Check for corruption
Test-Json -Path file.json

# Regenerate if needed
.\veeam-mcp.ps1 -Action Health -OutputFormat JSON
```

### Debug Mode

Enable verbose logging for troubleshooting:

```powershell
# Run with verbose output
.\veeam-mcp.ps1 -Action All -Verbose

# Enable PowerShell transcript
Start-Transcript -Path "C:\VeeamMCP\Logs\debug-transcript.log"
.\veeam-mcp.ps1 -Action All
Stop-Transcript
```

### Getting Help

1. **Check Documentation**
   - README.md for usage
   - Script comments for function details
   - Examples folder for patterns

2. **Run Tests**
   ```powershell
   .\tests\test-mcp.ps1
   ```

3. **Veeam Support**
   - Forums: https://forums.veeam.com
   - Support: Open case if licensed

4. **Community**
   - GitHub Issues
   - Veeam Community Slack

## Best Practices

### Security
- ✅ Use dedicated service account
- ✅ Encrypt credentials (don't hardcode)
- ✅ Restrict file system permissions
- ✅ Enable audit logging
- ✅ Regular security reviews

### Performance
- ✅ Schedule during off-peak hours
- ✅ Use targeted actions vs. "All"
- ✅ Limit retention of output files
- ✅ Monitor execution times
- ✅ Run on VBR server when possible

### Reliability
- ✅ Monitor scheduled task execution
- ✅ Set up alerting for failures
- ✅ Test after VBR upgrades
- ✅ Keep scripts version controlled
- ✅ Document customizations

### Compliance
- ✅ Retain reports per policy
- ✅ Secure sensitive data
- ✅ Audit access to outputs
- ✅ Review data classification
- ✅ Document processes

## Upgrade Path

### Upgrading Scripts

1. **Backup Current Version**
   ```powershell
   Copy-Item C:\VeeamMCP C:\VeeamMCP.backup.$(Get-Date -Format 'yyyyMMdd') -Recurse
   ```

2. **Download New Version**
   ```powershell
   # Download/clone updated scripts
   ```

3. **Merge Configurations**
   ```powershell
   # Compare configs and merge custom settings
   ```

4. **Test New Version**
   ```powershell
   .\tests\test-mcp.ps1
   ```

5. **Deploy to Production**
   ```powershell
   # Replace scripts after successful testing
   ```

### After Veeam Upgrade

1. Verify VeeamPSSnapin compatibility
2. Run test suite
3. Check for API changes
4. Update scripts if needed
5. Monitor first few runs

---

**Document Version**: 1.0  
**Last Updated**: January 16, 2026  
**Maintained By**: Veeam Solutions Architects
