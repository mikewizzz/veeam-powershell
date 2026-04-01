# Veeam VBR MCP - AI Assistant Integration Example
# This script demonstrates how AI assistants can interact with Veeam data

<#
.SYNOPSIS
    AI-powered Veeam monitoring and analysis automation
    
.DESCRIPTION
    This example shows how to build AI-driven workflows using the MCP output data.
    It includes decision trees, automated remediation, and intelligent alerting.
#>

#region Configuration

$config = @{
    # VBR Server settings
    VBRServer = "localhost"
    
    # Alert thresholds
    Thresholds = @{
        RepositorySpaceWarning = 80  # %
        RepositorySpaceCritical = 90 # %
        BackupAgeWarning = 7         # days
        BackupAgeCritical = 30       # days
        JobFailureWindow = 24        # hours
    }
    
    # Output settings
    OutputPath = "./VeeamMCPOutput"
    LogPath = "./VeeamMCP-AI.log"
    
    # Integration endpoints (examples)
    Webhooks = @{
        Slack = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
        Teams = "https://company.webhook.office.com/webhookb2/YOUR/WEBHOOK/URL"
        SIEM = "https://siem.company.com/api/events"
    }
}

#endregion

#region Helper Functions

function Write-AILog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Warning", "Error", "Success", "Decision")]
        [string]$Level = "Info"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Console output
    $color = switch ($Level) {
        "Info" { "Cyan" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        "Success" { "Green" }
        "Decision" { "Magenta" }
    }
    Write-Host $logEntry -ForegroundColor $color
    
    # File logging
    Add-Content -Path $config.LogPath -Value $logEntry
}

function Get-LatestMCPData {
    param([string]$DataType)
    
    try {
        $latestRun = Get-ChildItem $config.OutputPath -Directory | 
                     Sort-Object Name -Descending | 
                     Select-Object -First 1
        
        if (-not $latestRun) {
            Write-AILog "No MCP data found. Running data collection..." -Level Warning
            
            # Run MCP script
            & "$PSScriptRoot\..\veeam-mcp.ps1" -Action All -ExportPath $config.OutputPath
            
            $latestRun = Get-ChildItem $config.OutputPath -Directory | 
                         Sort-Object Name -Descending | 
                         Select-Object -First 1
        }
        
        $dataFile = Get-ChildItem $latestRun.FullName -Filter "VBR-$DataType.json" | 
                    Select-Object -First 1
        
        if ($dataFile) {
            return Get-Content $dataFile.FullName | ConvertFrom-Json
        }
        else {
            Write-AILog "Data file not found: VBR-$DataType.json" -Level Error
            return $null
        }
    }
    catch {
        Write-AILog "Error loading MCP data: $_" -Level Error
        return $null
    }
}

function Send-AIAlert {
    param(
        [string]$Title,
        [string]$Message,
        [ValidateSet("Info", "Warning", "Critical")]
        [string]$Severity = "Info",
        [string[]]$Channels = @("Log")
    )
    
    $alert = @{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Title = $Title
        Message = $Message
        Severity = $Severity
        Source = "Veeam MCP AI"
    }
    
    Write-AILog "ALERT [$Severity]: $Title - $Message" -Level $Severity
    
    foreach ($channel in $Channels) {
        switch ($channel) {
            "Slack" {
                # Example Slack integration
                <#
                $slackPayload = @{
                    text = "🔔 *$($alert.Title)* [$($alert.Severity)]"
                    attachments = @(
                        @{
                            color = if ($Severity -eq "Critical") { "danger" } 
                                   elseif ($Severity -eq "Warning") { "warning" } 
                                   else { "good" }
                            text = $alert.Message
                            footer = "Veeam MCP AI - $($alert.Timestamp)"
                        }
                    )
                } | ConvertTo-Json -Depth 10
                
                Invoke-RestMethod -Uri $config.Webhooks.Slack `
                                  -Method Post `
                                  -Body $slackPayload `
                                  -ContentType "application/json"
                #>
            }
            "Teams" {
                # Example Teams integration
                <#
                $teamsPayload = @{
                    "@type" = "MessageCard"
                    "@context" = "https://schema.org/extensions"
                    title = $alert.Title
                    text = $alert.Message
                    themeColor = if ($Severity -eq "Critical") { "FF0000" } 
                                elseif ($Severity -eq "Warning") { "FFA500" } 
                                else { "00FF00" }
                } | ConvertTo-Json -Depth 10
                
                Invoke-RestMethod -Uri $config.Webhooks.Teams `
                                  -Method Post `
                                  -Body $teamsPayload `
                                  -ContentType "application/json"
                #>
            }
            "Email" {
                # Example email integration
                <#
                Send-MailMessage -To "veeam-admins@company.com" `
                                 -From "veeam-ai@company.com" `
                                 -Subject "[$Severity] $($alert.Title)" `
                                 -Body $alert.Message `
                                 -SmtpServer "smtp.company.com"
                #>
            }
        }
    }
}

#endregion

#region AI Decision Engines

function Invoke-HealthAnalysisAI {
    Write-AILog "🤖 Starting AI Health Analysis..." -Level Info
    
    $health = Get-LatestMCPData -DataType "Health"
    if (-not $health) { return }
    
    Write-AILog "Overall Health Status: $($health.OverallStatus)" -Level Decision
    
    # Critical issues handling
    if ($health.Metrics.FailedJobs -gt 0) {
        Write-AILog "AI Decision: Failed jobs detected - triggering investigation workflow" -Level Decision
        
        Send-AIAlert -Title "Failed Backup Jobs Detected" `
                     -Message "Found $($health.Metrics.FailedJobs) failed job(s). Immediate attention required." `
                     -Severity "Critical" `
                     -Channels @("Log")
        
        # AI could trigger automated remediation here
        # Examples:
        # - Restart failed jobs
        # - Check resource availability
        # - Escalate to on-call engineer
    }
    
    # Repository space warnings
    if ($health.Metrics.LowSpaceRepos -gt 0) {
        Write-AILog "AI Decision: Low repository space detected - analyzing capacity trends" -Level Decision
        
        Send-AIAlert -Title "Repository Capacity Warning" `
                     -Message "$($health.Metrics.LowSpaceRepos) repository(ies) running low on space." `
                     -Severity "Warning" `
                     -Channels @("Log")
        
        # AI recommendations:
        Invoke-CapacityPlanningAI
    }
    
    # Old backup detection
    if ($health.Metrics.OldRestorePoints -gt 0) {
        Write-AILog "AI Decision: Stale backups found - investigating job schedules" -Level Decision
        
        Send-AIAlert -Title "Stale Backup Warning" `
                     -Message "$($health.Metrics.OldRestorePoints) VM(s) haven't been backed up recently." `
                     -Severity "Warning" `
                     -Channels @("Log")
    }
    
    Write-AILog "✓ Health Analysis Complete" -Level Success
}

function Invoke-CapacityPlanningAI {
    Write-AILog "🤖 Starting AI Capacity Planning..." -Level Info
    
    $capacity = Get-LatestMCPData -DataType "Capacity-Summary"
    $repos = Get-LatestMCPData -DataType "Capacity-Repositories"
    
    if (-not $capacity -or -not $repos) { return }
    
    Write-AILog "Total Capacity: $($capacity.TotalCapacity) GB" -Level Info
    Write-AILog "Used: $($capacity.UsedCapacity) GB | Free: $($capacity.FreeCapacity) GB" -Level Info
    
    # Analyze each repository
    foreach ($repo in $repos) {
        $usedPercent = $repo.UsedPercent
        
        if ($usedPercent -ge $config.Thresholds.RepositorySpaceCritical) {
            Write-AILog "AI Decision: Repository '$($repo.Name)' at CRITICAL capacity ($usedPercent%)" -Level Decision
            
            # Calculate days until full (simplified projection)
            $daysUntilFull = if ($repo.UsedGB -gt 0) {
                $dailyGrowth = 10 # GB - This should be calculated from historical data
                [math]::Floor($repo.FreeGB / $dailyGrowth)
            } else { "N/A" }
            
            Send-AIAlert -Title "Repository Capacity CRITICAL" `
                         -Message "Repository '$($repo.Name)' is $usedPercent% full. Estimated $daysUntilFull days until full." `
                         -Severity "Critical" `
                         -Channels @("Log")
            
            # AI Recommendations
            Write-AILog "  📊 AI Recommendations for '$($repo.Name)':" -Level Decision
            Write-AILog "    1. Extend repository storage immediately" -Level Info
            Write-AILog "    2. Review retention policies to free space" -Level Info
            Write-AILog "    3. Enable synthetic full backups to reduce chain length" -Level Info
            Write-AILog "    4. Consider offloading to Scale-Out Repository" -Level Info
        }
        elseif ($usedPercent -ge $config.Thresholds.RepositorySpaceWarning) {
            Write-AILog "AI Decision: Repository '$($repo.Name)' reaching capacity threshold ($usedPercent%)" -Level Decision
            
            # Proactive recommendations
            Write-AILog "  📊 AI Recommendations:" -Level Decision
            Write-AILog "    - Monitor growth trend closely" -Level Info
            Write-AILog "    - Plan capacity expansion within 30 days" -Level Info
            Write-AILog "    - Review backup chains and compact if possible" -Level Info
        }
    }
    
    # Compression analysis
    if ($capacity.CompressionRatio -gt 0) {
        Write-AILog "Compression Ratio: $($capacity.CompressionRatio):1" -Level Info
        
        if ($capacity.CompressionRatio -lt 1.5) {
            Write-AILog "AI Decision: Low compression ratio detected" -Level Decision
            Write-AILog "  📊 Recommendation: Consider enabling compression optimization" -Level Info
        }
    }
    
    Write-AILog "✓ Capacity Planning Analysis Complete" -Level Success
}

function Invoke-JobPerformanceAI {
    Write-AILog "🤖 Starting AI Job Performance Analysis..." -Level Info
    
    $jobs = Get-LatestMCPData -DataType "Jobs"
    $sessions = Get-LatestMCPData -DataType "Sessions"
    
    if (-not $jobs -or -not $sessions) { return }
    
    # Analyze job success rates
    $jobStats = @{}
    foreach ($job in $jobs) {
        $jobSessions = $sessions | Where-Object { $_.JobName -eq $job.Name }
        
        if ($jobSessions) {
            $successRate = ($jobSessions | Where-Object { $_.Result -eq "Success" }).Count / $jobSessions.Count * 100
            
            $jobStats[$job.Name] = @{
                SuccessRate = [math]::Round($successRate, 2)
                TotalRuns = $jobSessions.Count
                LastResult = $job.LastResult
                IsEnabled = $job.IsEnabled
            }
            
            # Performance analysis
            if ($successRate -lt 80) {
                Write-AILog "AI Decision: Job '$($job.Name)' has low success rate ($successRate%)" -Level Decision
                
                Send-AIAlert -Title "Job Performance Issue" `
                             -Message "Job '$($job.Name)' success rate is only $successRate%. Investigation needed." `
                             -Severity "Warning" `
                             -Channels @("Log")
                
                Write-AILog "  📊 AI Troubleshooting Suggestions:" -Level Decision
                Write-AILog "    1. Review recent session logs for common errors" -Level Info
                Write-AILog "    2. Check resource availability (storage, network)" -Level Info
                Write-AILog "    3. Verify VM/host connectivity" -Level Info
                Write-AILog "    4. Consider adjusting retry settings" -Level Info
            }
        }
    }
    
    # Identify top performers and problem children
    $topPerformers = $jobStats.GetEnumerator() | 
                     Where-Object { $_.Value.SuccessRate -eq 100 } | 
                     Measure-Object
    
    $problemJobs = $jobStats.GetEnumerator() | 
                   Where-Object { $_.Value.SuccessRate -lt 90 } | 
                   Measure-Object
    
    Write-AILog "Job Performance Summary:" -Level Info
    Write-AILog "  Perfect (100%): $($topPerformers.Count) jobs" -Level Success
    Write-AILog "  Need Attention (<90%): $($problemJobs.Count) jobs" -Level Warning
    
    Write-AILog "✓ Job Performance Analysis Complete" -Level Success
}

function Invoke-RestorePointComplianceAI {
    Write-AILog "🤖 Starting AI Restore Point Compliance Check..." -Level Info
    
    $restorePoints = Get-LatestMCPData -DataType "RestorePoints"
    if (-not $restorePoints) { return }
    
    # Group by VM and check latest backup age
    $vmBackups = $restorePoints | Group-Object VMName
    
    $complianceReport = @{
        Compliant = 0
        Warning = 0
        Critical = 0
        VMs = @()
    }
    
    foreach ($vmGroup in $vmBackups) {
        $latestBackup = ($vmGroup.Group | Sort-Object CreationTime -Descending)[0]
        $backupAge = (Get-Date) - $latestBackup.CreationTime
        
        $status = if ($backupAge.TotalDays -lt $config.Thresholds.BackupAgeWarning) {
            "Compliant"
        }
        elseif ($backupAge.TotalDays -lt $config.Thresholds.BackupAgeCritical) {
            "Warning"
        }
        else {
            "Critical"
        }
        
        $complianceReport.VMs += [PSCustomObject]@{
            VMName = $vmGroup.Name
            LastBackup = $latestBackup.CreationTime
            AgeInDays = [math]::Round($backupAge.TotalDays, 1)
            Status = $status
            RestorePointCount = $vmGroup.Count
        }
        
        $complianceReport.$status++
        
        # Alert on compliance issues
        if ($status -eq "Critical") {
            Write-AILog "AI Decision: VM '$($vmGroup.Name)' backup is $([math]::Round($backupAge.TotalDays, 1)) days old - CRITICAL" -Level Decision
            
            Send-AIAlert -Title "Backup Compliance Critical" `
                         -Message "VM '$($vmGroup.Name)' last backup: $($latestBackup.CreationTime). Age: $([math]::Round($backupAge.TotalDays, 1)) days." `
                         -Severity "Critical" `
                         -Channels @("Log")
        }
    }
    
    Write-AILog "Compliance Summary:" -Level Info
    Write-AILog "  ✓ Compliant: $($complianceReport.Compliant)" -Level Success
    Write-AILog "  ⚠ Warning: $($complianceReport.Warning)" -Level Warning
    Write-AILog "  ✗ Critical: $($complianceReport.Critical)" -Level Error
    
    # Calculate compliance percentage
    $totalVMs = $vmBackups.Count
    $compliancePercent = [math]::Round(($complianceReport.Compliant / $totalVMs) * 100, 2)
    Write-AILog "Overall Compliance: $compliancePercent%" -Level Info
    
    Write-AILog "✓ Restore Point Compliance Check Complete" -Level Success
}

function Invoke-PredictiveMaintenanceAI {
    Write-AILog "🤖 Starting AI Predictive Maintenance Analysis..." -Level Info
    
    # This function would analyze trends over time
    # For demonstration, we'll outline the concept
    
    Write-AILog "📊 Predictive Maintenance Checks:" -Level Decision
    Write-AILog "  - Analyzing job duration trends..." -Level Info
    Write-AILog "  - Monitoring repository growth patterns..." -Level Info
    Write-AILog "  - Detecting anomalies in backup sizes..." -Level Info
    Write-AILog "  - Predicting infrastructure bottlenecks..." -Level Info
    
    # Example: Detect if job durations are increasing over time
    # This would require historical data collection
    
    Write-AILog "  📈 Predictions:" -Level Decision
    Write-AILog "    - Repository 'Backup-Repo-01' will reach capacity in ~45 days" -Level Warning
    Write-AILog "    - Job 'Production VMs' duration increasing by 5% weekly" -Level Info
    Write-AILog "    - Proxy 'VBR-Proxy-01' approaching max concurrent tasks" -Level Warning
    
    Write-AILog "✓ Predictive Maintenance Analysis Complete" -Level Success
}

#endregion

#region Main Execution

function Start-VeeamMCPAI {
    Write-Host "`n" + ("="*80) -ForegroundColor Cyan
    Write-Host "  VEEAM VBR MCP - AI ASSISTANT INTEGRATION" -ForegroundColor Cyan
    Write-Host ("="*80) + "`n" -ForegroundColor Cyan
    
    Write-AILog "Initializing AI-powered Veeam monitoring..." -Level Info
    
    try {
        # Run all AI analysis engines
        Invoke-HealthAnalysisAI
        Write-Host ""
        
        Invoke-CapacityPlanningAI
        Write-Host ""
        
        Invoke-JobPerformanceAI
        Write-Host ""
        
        Invoke-RestorePointComplianceAI
        Write-Host ""
        
        Invoke-PredictiveMaintenanceAI
        Write-Host ""
        
        Write-Host ("="*80) -ForegroundColor Cyan
        Write-Host "  AI ANALYSIS COMPLETE" -ForegroundColor Green
        Write-Host ("="*80) -ForegroundColor Cyan
        Write-Host "`n  Log file: $($config.LogPath)" -ForegroundColor White
        Write-Host ""
        
    }
    catch {
        Write-AILog "AI analysis failed: $_" -Level Error
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
}

# Execute AI analysis
Start-VeeamMCPAI

#endregion
