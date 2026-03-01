# Example: Running a Weekly Optimization Analysis

# This example script shows how to run automated weekly analysis
# and email results to your team

# Set your environment variables
$VBRServer = "veeam-prod.company.com"
$EmailTo = @("backup-team@company.com", "sa@company.com")
$EmailFrom = "veeam-reports@company.com"
$SMTPServer = "smtp.company.com"

# Run the optimization analysis
Write-Host "Starting Veeam Optimization Analysis..." -ForegroundColor Green

.\Get-VeeamOptimizationReport.ps1 `
    -VBRServer $VBRServer `
    -Days 30 `
    -ThresholdCPU 80 `
    -ThresholdMemory 85 `
    -ThresholdStorage 75 `
    -ThresholdThroughput 100 `
    -ExportHTML `
    -ExportCSV `
    -Verbose

# Find the latest report
$latestReport = Get-ChildItem -Path ".\VeeamOptimizationOutput" -Recurse -Filter "*.html" | 
    Sort-Object LastWriteTime -Descending | 
    Select-Object -First 1

if ($latestReport) {
    Write-Host "Report generated: $($latestReport.FullName)" -ForegroundColor Green
    
    # Email the report
    $emailBody = @"
<html>
<body>
<h2>Weekly Veeam Optimization Report</h2>
<p>Please find attached the latest Veeam optimization analysis and recommendations.</p>
<p><strong>Analysis Period:</strong> Last 30 days</p>
<p><strong>Generated:</strong> $(Get-Date -Format "yyyy-MM-dd HH:mm")</p>
<p>Review the attached HTML report for detailed findings and recommendations.</p>
<br>
<p>Key areas analyzed:</p>
<ul>
<li>Data Mover (Proxy) Performance</li>
<li>Repository & Gateway Optimization</li>
<li>Storage Capacity & Growth Forecasting</li>
<li>Job Performance & Success Rates</li>
</ul>
<br>
<p><em>This is an automated report. For questions, contact your Veeam Solutions Architect.</em></p>
</body>
</html>
"@

    try {
        Send-MailMessage `
            -From $EmailFrom `
            -To $EmailTo `
            -Subject "Veeam Weekly Optimization Report - $(Get-Date -Format 'yyyy-MM-dd')" `
            -Body $emailBody `
            -BodyAsHtml `
            -Attachments $latestReport.FullName `
            -SmtpServer $SMTPServer
        
        Write-Host "Report emailed successfully to $($EmailTo -join ', ')" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to email report: $($_.Exception.Message)" -ForegroundColor Red
    }
}
else {
    Write-Host "No report found to email" -ForegroundColor Yellow
}

Write-Host "`nAnalysis complete!" -ForegroundColor Green
