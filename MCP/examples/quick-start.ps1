# Veeam VBR v13 MCP - Quick Start Examples
# This file contains ready-to-use examples for common scenarios

#region Example 1: Quick Health Check
Write-Host "`n=== Example 1: Quick Health Check ===" -ForegroundColor Cyan
Write-Host "Check overall Veeam infrastructure health" -ForegroundColor White

# Run health check on local server
# ..\veeam-mcp.ps1 -Action Health

#endregion

#region Example 2: Daily Monitoring Report
Write-Host "`n=== Example 2: Daily Monitoring Report ===" -ForegroundColor Cyan
Write-Host "Generate comprehensive daily report" -ForegroundColor White

# Run all checks and export to dated folder
# ..\veeam-mcp.ps1 -Action All -OutputFormat Both -ExportPath "C:\VeeamReports"

#endregion

#region Example 3: Job Status Review
Write-Host "`n=== Example 3: Job Status Review ===" -ForegroundColor Cyan
Write-Host "Review all backup jobs and their status" -ForegroundColor White

# Get all jobs
# ..\veeam-mcp.ps1 -Action Jobs -OutputFormat CSV

# Filter specific job
# ..\veeam-mcp.ps1 -Action Jobs -JobName "Production VMs" -OutputFormat JSON

#endregion

#region Example 4: Capacity Planning
Write-Host "`n=== Example 4: Capacity Planning ===" -ForegroundColor Cyan
Write-Host "Analyze storage capacity and trends" -ForegroundColor White

# Get capacity metrics
# ..\veeam-mcp.ps1 -Action Capacity

# Combine with repository details
# ..\veeam-mcp.ps1 -Action Repositories -OutputFormat Both

#endregion

#region Example 5: Restore Point Verification
Write-Host "`n=== Example 5: Restore Point Verification ===" -ForegroundColor Cyan
Write-Host "Verify restore points for critical VMs" -ForegroundColor White

# Check all restore points
# ..\veeam-mcp.ps1 -Action RestorePoints

# Check specific VM
# ..\veeam-mcp.ps1 -Action RestorePoints -VMName "SQL-PROD-01"

#endregion

#region Example 6: Session Analysis
Write-Host "`n=== Example 6: Session Analysis ===" -ForegroundColor Cyan
Write-Host "Review recent backup sessions (last 24 hours)" -ForegroundColor White

# Get session details
# ..\veeam-mcp.ps1 -Action Sessions -OutputFormat CSV

#endregion

#region Example 7: Infrastructure Inventory
Write-Host "`n=== Example 7: Infrastructure Inventory ===" -ForegroundColor Cyan
Write-Host "Document infrastructure components" -ForegroundColor White

# Get infrastructure details
# ..\veeam-mcp.ps1 -Action Infrastructure -OutputFormat Both

#endregion

#region Example 8: Remote Server Monitoring
Write-Host "`n=== Example 8: Remote Server Monitoring ===" -ForegroundColor Cyan
Write-Host "Monitor remote VBR server" -ForegroundColor White

# Connect to remote server
# $cred = Get-Credential -Message "Enter VBR Admin Credentials"
# ..\veeam-mcp.ps1 -VBRServer "vbr-remote.domain.com" -Credential $cred -Action Health

#endregion

#region Example 9: Automated Daily Check
Write-Host "`n=== Example 9: Automated Daily Check ===" -ForegroundColor Cyan
Write-Host "Setup for scheduled daily execution" -ForegroundColor White

<#
# Create scheduled task
$scriptPath = "C:\Scripts\veeam-powershell\MCP\veeam-mcp.ps1"
$reportPath = "C:\VeeamReports"

$action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
          -Argument "-ExecutionPolicy Bypass -File `"$scriptPath`" -Action All -ExportPath `"$reportPath`" -OutputFormat Both"

$trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM

$principal = New-ScheduledTaskPrincipal -UserId "DOMAIN\VeeamAdmin" `
             -LogonType Password -RunLevel Highest

Register-ScheduledTask -Action $action `
                      -Trigger $trigger `
                      -Principal $principal `
                      -TaskName "Veeam Daily Health Report" `
                      -Description "Daily Veeam infrastructure monitoring via MCP"
#>

#endregion

#region Example 10: AI Integration Pattern
Write-Host "`n=== Example 10: AI Integration Pattern ===" -ForegroundColor Cyan
Write-Host "Process results for AI/automation systems" -ForegroundColor White

<#
# Run health check
..\veeam-mcp.ps1 -Action Health -OutputFormat JSON

# Load and process results
$latestRun = Get-ChildItem "../VeeamMCPOutput" | Sort-Object Name -Descending | Select-Object -First 1
$healthData = Get-Content "$($latestRun.FullName)\VBR-Health.json" | ConvertFrom-Json

# AI Decision Logic
if ($healthData.OverallStatus -eq "Critical") {
    Write-Host "CRITICAL: Immediate action required!" -ForegroundColor Red
    
    # Send alert
    $alertData = @{
        Severity = "Critical"
        Source = "Veeam VBR"
        Issues = $healthData.Issues
        Timestamp = Get-Date
    }
    
    # Example: Send to API/webhook
    # Invoke-RestMethod -Uri "https://monitoring.company.com/api/alert" `
    #                   -Method POST `
    #                   -Body ($alertData | ConvertTo-Json) `
    #                   -ContentType "application/json"
    
    # Example: Send email
    # Send-MailMessage -To "veeam-admins@company.com" `
    #                  -From "veeam-monitor@company.com" `
    #                  -Subject "CRITICAL: Veeam Health Issue" `
    #                  -Body ($healthData.Issues -join "`n") `
    #                  -SmtpServer "smtp.company.com"
}
elseif ($healthData.OverallStatus -eq "Warning") {
    Write-Host "WARNING: Review recommended" -ForegroundColor Yellow
    # Log for review
}
else {
    Write-Host "HEALTHY: All systems operational" -ForegroundColor Green
}
#>

#endregion

#region Example 11: Compliance Reporting
Write-Host "`n=== Example 11: Compliance Reporting ===" -ForegroundColor Cyan
Write-Host "Generate compliance reports for audit" -ForegroundColor White

<#
# Run comprehensive check
..\veeam-mcp.ps1 -Action All -OutputFormat Both -ExportPath "C:\ComplianceReports"

# Load data
$latestRun = Get-ChildItem "C:\ComplianceReports" | Sort-Object Name -Descending | Select-Object -First 1
$summary = Get-Content "$($latestRun.FullName)\VBR-MCP-Summary.json" | ConvertFrom-Json

# Generate compliance report
$complianceReport = [PSCustomObject]@{
    ReportDate = Get-Date
    TotalVMs = $summary.Results.RestorePoints.Count
    BackupCoverage = "$(($summary.Results.Jobs | Where-Object IsEnabled).Count) of $($summary.Results.Jobs.Count) jobs enabled"
    HealthStatus = $summary.Results.Health.OverallStatus
    RepositoryStatus = "$($summary.Results.Repositories.Count) repositories, $($summary.Results.Health.Metrics.UnavailableRepos) unavailable"
    FailedJobs = $summary.Results.Health.Metrics.FailedJobs
    ComplianceStatus = if ($summary.Results.Health.OverallStatus -eq "Healthy") { "Compliant" } else { "Non-Compliant" }
}

# Export compliance report
# $complianceReport | Export-Csv "C:\ComplianceReports\Veeam-Compliance-$(Get-Date -Format 'yyyy-MM-dd').csv" -NoTypeInformation
#>

#endregion

#region Example 12: Multi-Server Monitoring
Write-Host "`n=== Example 12: Multi-Server Monitoring ===" -ForegroundColor Cyan
Write-Host "Monitor multiple VBR servers" -ForegroundColor White

<#
# Define VBR servers to monitor
$vbrServers = @(
    "vbr-prod-01.domain.com",
    "vbr-prod-02.domain.com",
    "vbr-dr.domain.com"
)

# Get credentials once
$cred = Get-Credential -Message "Enter VBR Admin credentials"

# Monitor each server
foreach ($server in $vbrServers) {
    Write-Host "`nMonitoring: $server" -ForegroundColor Cyan
    
    ..\veeam-mcp.ps1 -VBRServer $server `
                     -Credential $cred `
                     -Action Health `
                     -ExportPath "C:\VeeamReports\Multi-Server\$server"
}

# Consolidate results
# Process and aggregate health data from all servers
#>

#endregion

Write-Host "`n=== Quick Start Examples Complete ===" -ForegroundColor Green
Write-Host "Uncomment and modify examples as needed for your environment`n" -ForegroundColor White
