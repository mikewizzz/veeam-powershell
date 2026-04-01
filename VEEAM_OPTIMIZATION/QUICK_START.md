# Quick Start Guide - Veeam Optimization Tool

## 5-Minute Setup

### Step 1: Prerequisites Check
```powershell
# Verify Veeam PowerShell is available
Get-PSSnapin -Registered | Where-Object {$_.Name -eq 'VeeamPSSnapin'}

# If not found, install Veeam B&R Console from your VBR server
```

### Step 2: Run Your First Analysis
```powershell
# Navigate to the tool directory
cd C:\Path\To\VEEAM_OPTIMIZATION

# Run basic analysis with HTML report
.\Get-VeeamOptimizationReport.ps1 -ExportHTML

# For remote VBR server
.\Get-VeeamOptimizationReport.ps1 -VBRServer "veeam-server.domain.com" -ExportHTML
```

### Step 3: Review Results
The HTML report will open automatically. Look for:
- 🔴 **Critical** - Fix immediately
- 🟠 **High** - Address within days
- 🟡 **Warning** - Plan for optimization
- 🔵 **Info** - Best practice suggestions

## Common Use Cases

### Weekly Health Check
```powershell
.\Get-VeeamOptimizationReport.ps1 -Days 7 -ExportHTML
```

### Monthly Capacity Planning
```powershell
.\Get-VeeamOptimizationReport.ps1 -Days 90 -ExportHTML -ExportCSV
```

### Performance Troubleshooting
```powershell
.\Get-VeeamOptimizationReport.ps1 -Days 30 -ThresholdThroughput 150 -Verbose
```

### Storage Growth Analysis
```powershell
.\Get-VeeamOptimizationReport.ps1 -Days 180 -ThresholdStorage 70 -ExportCSV
```

## Understanding Your First Report

### Recommendation Priorities
- **Priority 1**: Immediate action required (system at risk)
- **Priority 2**: Address soon (performance/efficiency impact)
- **Priority 3**: Optimization opportunities

### Key Metrics to Watch
- **Proxy Throughput**: Should be > 100 MB/s per task
- **Storage Used %**: Keep below 80% for best performance
- **Job Success Rate**: Should be > 90%
- **Days Until Full**: Should be > 30 days

## Next Steps

1. ✅ Review top 5 recommendations in the report
2. ✅ Address any Critical or High priority items
3. ✅ Schedule regular analysis (weekly recommended)
4. ✅ Keep reports for trend analysis
5. ✅ Re-run after making changes to measure impact

## Getting Help

- Check [README.md](README.md) for detailed documentation
- Use `-Verbose` flag for troubleshooting
- Review execution.log in output folder
- Contact your Veeam Solutions Architect

## Example: Interpreting Results

```
Recommendation: Proxy task limit reached
Resource: Proxy-01
Current: 8 concurrent tasks
Threshold: 8 maximum tasks
Action: Increase MaxTasksCount to 12 or add another proxy
```

**What this means**: Your proxy is maxed out. Backups may be queuing. Either increase the task limit on this proxy or add more proxies to handle the load.

---

**Ready to optimize your Veeam environment? Run the script now!** 🚀
