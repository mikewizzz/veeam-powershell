# Veeam Optimization & Recommendation Tool

## Overview

The Veeam Optimization Tool is a comprehensive PowerShell script designed for Veeam Solutions Architects to analyze Veeam Backup & Replication environments and provide actionable recommendations for optimizing:

- **Data Movers (Proxies)** - Performance, concurrency, and resource utilization
- **Gateways** - Repository gateway sizing and throughput optimization  
- **Storage Consumption** - Capacity planning, growth forecasting, and efficiency

## Features

### 📊 Comprehensive Analysis
- **Proxy Performance Monitoring** - Analyze throughput, concurrent tasks, transport modes
- **Repository Health** - Track storage usage, growth trends, and capacity forecasting
- **Job Performance** - Success rates, bottleneck detection, duration analysis
- **Gateway Optimization** - Throughput analysis and resource recommendations

### 🎯 Smart Recommendations
- Priority-based recommendations (Critical, High, Warning, Info)
- Threshold-driven alerts for CPU, memory, storage, and throughput
- Storage growth forecasting (30/90 day projections)
- Bottleneck identification and resolution guidance

### 📈 Multiple Report Formats
- **HTML Report** - Professional, color-coded dashboard with charts
- **CSV Export** - Detailed data exports for further analysis
- **JSON Export** - Structured data for integration with other tools
- **Console Summary** - Quick overview with actionable insights

## Prerequisites

- **Veeam Backup & Replication** 11.0 or later
- **PowerShell** 5.1 or later
- **Veeam PowerShell Snapin** (installed with VBR console)
- **Access Rights** - VBR administrator or equivalent permissions

## Installation

1. Clone or download this repository to your local system
2. Ensure Veeam Backup & Replication console is installed (includes PowerShell snapin)
3. No additional installation required - script is standalone

## Usage

### Basic Usage

```powershell
# Run with default settings (30 days, localhost)
.\Get-VeeamOptimizationReport.ps1 -ExportHTML

# Analyze remote VBR server
.\Get-VeeamOptimizationReport.ps1 -VBRServer "veeam-server.domain.com" -ExportHTML -ExportCSV

# Custom thresholds and extended analysis period
.\Get-VeeamOptimizationReport.ps1 -Days 90 -ThresholdCPU 75 -ThresholdStorage 85 -ExportHTML
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `VBRServer` | String | localhost | Veeam Backup & Replication server name or IP |
| `Port` | Int | 9392 | VBR server port |
| `Days` | Int | 30 | Number of days to analyze (1-365) |
| `ThresholdCPU` | Int | 80 | CPU utilization threshold % for recommendations |
| `ThresholdMemory` | Int | 85 | Memory utilization threshold % |
| `ThresholdStorage` | Int | 80 | Storage capacity threshold % |
| `ThresholdThroughput` | Int | 100 | Minimum acceptable throughput (MB/s) |
| `OutputPath` | String | .\VeeamOptimizationOutput | Report output directory |
| `ExportHTML` | Switch | - | Generate HTML report |
| `ExportCSV` | Switch | - | Export data to CSV files |
| `ExportJSON` | Switch | - | Export data to JSON |
| `Verbose` | Switch | - | Enable verbose logging |

### Advanced Examples

```powershell
# Comprehensive analysis with all export formats
.\Get-VeeamOptimizationReport.ps1 `
    -VBRServer "veeam-prod.company.com" `
    -Days 60 `
    -ThresholdCPU 70 `
    -ThresholdMemory 80 `
    -ThresholdStorage 75 `
    -ThresholdThroughput 150 `
    -ExportHTML `
    -ExportCSV `
    -ExportJSON `
    -Verbose

# Quick health check with aggressive thresholds
.\Get-VeeamOptimizationReport.ps1 -Days 7 -ThresholdStorage 90 -ExportHTML

# Storage capacity planning focus
.\Get-VeeamOptimizationReport.ps1 -Days 180 -ThresholdStorage 70 -ExportCSV
```

## Output Structure

The tool creates a timestamped output folder with the following structure:

```
VeeamOptimizationOutput/
└── VeeamOptimization_2026-01-16_1430/
    ├── VeeamOptimizationReport.html    # Main HTML dashboard
    ├── proxies.csv                      # Proxy performance data
    ├── repositories.csv                 # Repository health data
    ├── jobs.csv                         # Job performance metrics
    ├── storage-growth.csv               # Growth forecast data
    ├── recommendations.csv              # All recommendations
    ├── report.json                      # Complete JSON export
    └── execution.log                    # Verbose execution log
```

## Report Sections

### 1. Executive Summary
- Total recommendations count
- Critical issues requiring immediate attention
- Analysis period and thresholds used

### 2. Recommendations (Priority Ordered)
- **Priority 1** - Critical issues requiring immediate action
- **Priority 2** - High impact optimizations
- **Priority 3** - Information and best practice suggestions

Each recommendation includes:
- Category (Data Mover, Gateway, Storage, etc.)
- Resource name
- Severity level
- Current status vs. threshold
- Specific remediation steps

### 3. Data Movers (Proxies)
- Task processing statistics
- Average throughput per proxy
- Concurrent task utilization
- Transport mode analysis
- Active vs. idle resources

### 4. Repositories & Gateways
- Storage capacity and utilization
- Gateway throughput performance
- Deduplication status
- Free space warnings
- Per-repository job counts

### 5. Storage Growth Forecast
- Current consumption
- Daily/monthly growth rates
- 30-day and 90-day projections
- Days until capacity exhaustion
- Trend analysis

### 6. Job Performance Summary
- Success rate tracking
- Average job duration
- Backup throughput
- Bottleneck identification
- Recent job status

## Recommendation Categories

### Data Mover Optimization
- Low throughput alerts
- Proxy task limit warnings
- Idle resource identification
- Transport mode suggestions
- Concurrent task tuning

### Gateway Optimization
- Repository write throughput analysis
- Linux gateway resource recommendations
- Network connectivity checks
- Parallel processing suggestions

### Storage Optimization
- Capacity threshold alerts
- Growth-based forecasting
- Deduplication recommendations
- Archive tier offload suggestions
- GFS retention policy guidance

### Job Health
- Success rate monitoring
- Bottleneck detection and resolution
- Long-running job optimization
- Retention policy conflicts

## Thresholds Explained

| Metric | Default | Purpose | Recommendation Trigger |
|--------|---------|---------|----------------------|
| **CPU** | 80% | Data mover resource utilization | When avg CPU > threshold |
| **Memory** | 85% | Gateway and proxy memory pressure | When avg memory > threshold |
| **Storage** | 80% | Repository capacity planning | When used % > threshold |
| **Throughput** | 100 MB/s | Backup performance baseline | When avg speed < threshold |

### Customizing Thresholds

Adjust thresholds based on your environment:

- **Conservative** (early warnings): CPU 70%, Storage 75%, Throughput 150 MB/s
- **Standard** (default): CPU 80%, Storage 80%, Throughput 100 MB/s
- **Aggressive** (urgent only): CPU 90%, Storage 90%, Throughput 50 MB/s

## Integration Examples

### Schedule as Automated Task

```powershell
# Create Windows Task Scheduler job
$action = New-ScheduledTaskAction -Execute 'PowerShell.exe' `
    -Argument '-File "C:\Scripts\Get-VeeamOptimizationReport.ps1" -ExportHTML -ExportCSV'

$trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 6:00AM

Register-ScheduledTask -TaskName "VeeamWeeklyOptimization" `
    -Action $action -Trigger $trigger -RunLevel Highest
```

### Email Report Automatically

```powershell
# Run script and email HTML report
.\Get-VeeamOptimizationReport.ps1 -ExportHTML

# Email the report
$reportPath = Get-ChildItem -Path .\VeeamOptimizationOutput -Recurse -Filter "*.html" | 
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

Send-MailMessage -From "veeam@company.com" -To "team@company.com" `
    -Subject "Weekly Veeam Optimization Report" `
    -Body "Please find attached the latest optimization recommendations." `
    -Attachments $reportPath.FullName -SmtpServer "smtp.company.com"
```

### Import into ServiceNow/Monitoring Tools

```powershell
# Generate JSON for external consumption
.\Get-VeeamOptimizationReport.ps1 -ExportJSON

# Load and parse JSON
$jsonPath = Get-ChildItem -Path .\VeeamOptimizationOutput -Recurse -Filter "report.json" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$data = Get-Content $jsonPath | ConvertFrom-Json

# Send critical recommendations to ServiceNow
$criticalIssues = $data.Recommendations | Where-Object { $_.Severity -eq 'Critical' }
foreach ($issue in $criticalIssues) {
    # POST to ServiceNow API or other ITSM tool
    Invoke-RestMethod -Uri "https://servicenow.company.com/api/incident" `
        -Method POST -Body ($issue | ConvertTo-Json) -ContentType "application/json"
}
```

## Troubleshooting

### Common Issues

**1. "Veeam PowerShell snapin not found"**
- Install Veeam Backup & Replication console on the machine running the script
- Console installation includes the required PowerShell snapin

**2. "Failed to connect to Veeam"**
- Verify VBR server name/IP is correct
- Check network connectivity and firewall rules (port 9392)
- Ensure you have VBR administrator permissions
- Try connecting locally from the VBR server first

**3. "No data collected for proxies/repositories"**
- Verify that backups have run in the analysis period (Days parameter)
- Check that jobs are configured and have session history
- Increase the `-Days` parameter to capture more history

**4. "Permission denied" errors**
- Run PowerShell as Administrator
- Verify VBR user account has sufficient permissions
- Check NTFS permissions on output directory

### Debug Mode

Enable verbose logging for troubleshooting:

```powershell
.\Get-VeeamOptimizationReport.ps1 -Verbose -ExportHTML
```

Check the execution log:
```
VeeamOptimizationOutput\VeeamOptimization_TIMESTAMP\execution.log
```

## Best Practices

1. **Regular Analysis** - Run weekly or bi-weekly for trending
2. **Baseline First** - Establish baseline metrics before making changes
3. **Prioritize** - Address Priority 1 (Critical) recommendations first
4. **Document Changes** - Track which recommendations were implemented
5. **Re-analyze** - Run again after changes to measure improvement
6. **Archive Reports** - Keep historical reports for trend analysis
7. **Adjust Thresholds** - Fine-tune based on your SLAs and environment

## Roadmap / Future Enhancements

- [ ] WAN Accelerator analysis and recommendations
- [ ] Tape infrastructure optimization
- [ ] Cloud repository (AWS/Azure) cost analysis
- [ ] Direct integration with Veeam ONE for alerting
- [ ] Machine learning-based anomaly detection
- [ ] Multi-tenant environment support
- [ ] Automated remediation scripts
- [ ] Grafana/Power BI dashboard templates

## Contributing

Contributions are welcome! Please submit issues or pull requests with:
- Bug fixes
- New recommendation logic
- Additional metrics
- Report format improvements
- Integration examples

## Support

For issues or questions:
1. Check this README and troubleshooting section
2. Review execution logs with `-Verbose` enabled
3. Contact your Veeam Solutions Architect
4. Open an issue in this repository

## License

This tool is provided as-is for use by Veeam customers and partners. Not officially supported by Veeam Software.

## Author

Created by a Veeam Solutions Architect  
Version: 1.0.0  
Last Updated: January 2026

---

## Quick Start Checklist

- [ ] Veeam B&R console installed (PowerShell snapin available)
- [ ] VBR administrator credentials available
- [ ] Network access to VBR server (port 9392)
- [ ] Output directory writable
- [ ] 30+ days of backup history available
- [ ] Run initial analysis: `.\Get-VeeamOptimizationReport.ps1 -ExportHTML`
- [ ] Review HTML report for recommendations
- [ ] Prioritize and implement critical fixes
- [ ] Schedule recurring analysis

## Example Output

```
================================================
    VEEAM OPTIMIZATION REPORT SUMMARY
================================================

Data Movers (Proxies): 4
Repositories: 3
Jobs Analyzed: 12

Recommendations by Severity:
  Critical: 2
  High: 5
  Warning: 3
  Info: 4

Top 5 Recommendations:
  [Critical] Repo-Production: High storage utilization
  [Critical] Proxy-01: Proxy task limit reached
  [High] Job-SQL-Backup: Low job success rate
  [High] Repo-Archive: Repository approaching capacity
  [Warning] Proxy-02: Low throughput performance

================================================
Output Location: .\VeeamOptimizationOutput\VeeamOptimization_2026-01-16_1430
================================================
```
