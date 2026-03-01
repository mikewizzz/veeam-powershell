<#
.SYNOPSIS
    Analyzes Veeam log data across all systems and provides optimization recommendations.

.DESCRIPTION
    This script collects and analyzes Veeam Backup & Replication log data to provide
    recommendations for:
    - Data Mover optimization (proxy resources)
    - Gateway optimization (repository gateway sizing)
    - Storage consumption analysis and forecasting
    
    The tool connects to Veeam Backup & Replication server, analyzes job logs,
    session performance, and resource utilization to identify bottlenecks and
    optimization opportunities.

.PARAMETER VBRServer
    Veeam Backup & Replication server name or IP address.
    Default: localhost

.PARAMETER Port
    Veeam Backup & Replication server port.
    Default: 9392

.PARAMETER Days
    Number of days to analyze historical data.
    Default: 30

.PARAMETER ThresholdCPU
    CPU utilization threshold percentage for recommendations.
    Default: 80

.PARAMETER ThresholdMemory
    Memory utilization threshold percentage for recommendations.
    Default: 85

.PARAMETER ThresholdStorage
    Storage capacity threshold percentage for recommendations.
    Default: 80

.PARAMETER ThresholdThroughput
    Minimum acceptable throughput in MB/s for data movers.
    Default: 100

.PARAMETER OutputPath
    Path where reports will be saved.
    Default: .\VeeamOptimizationOutput

.PARAMETER ExportHTML
    Generate HTML report.

.PARAMETER ExportCSV
    Export detailed data to CSV files.

.PARAMETER ExportJSON
    Export data in JSON format.

.PARAMETER Verbose
    Enable verbose logging.

.EXAMPLE
    .\Get-VeeamOptimizationReport.ps1 -VBRServer "veeam-server.local" -Days 30 -ExportHTML

.EXAMPLE
    .\Get-VeeamOptimizationReport.ps1 -ThresholdCPU 75 -ThresholdStorage 85 -ExportCSV -ExportHTML

.NOTES
    Author: Veeam Solutions Architect
    Version: 1.0.0
    Date: January 2026
    Requires: Veeam Backup & Replication PowerShell Module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$VBRServer = "localhost",
    
    [Parameter(Mandatory = $false)]
    [int]$Port = 9392,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 365)]
    [int]$Days = 30,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$ThresholdCPU = 80,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$ThresholdMemory = 85,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 100)]
    [int]$ThresholdStorage = 80,
    
    [Parameter(Mandatory = $false)]
    [int]$ThresholdThroughput = 100,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\VeeamOptimizationOutput",
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportHTML,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportCSV,
    
    [Parameter(Mandatory = $false)]
    [switch]$ExportJSON
)

#region Global Variables
$script:StartTime = Get-Date
$script:RunTimestamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$script:OutputFolder = Join-Path $OutputPath "VeeamOptimization_$script:RunTimestamp"
$script:Recommendations = @()
$script:Findings = @()
#endregion

#region Helper Functions

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $color = switch ($Level) {
        'Info' { 'White' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        'Success' { 'Green' }
    }
    
    $logMessage = "[$timestamp] [$Level] $Message"
    Write-Host $logMessage -ForegroundColor $color
    
    if ($VerbosePreference -eq 'Continue') {
        $logFile = Join-Path $script:OutputFolder "execution.log"
        $logMessage | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

function Initialize-OutputFolder {
    Write-Log "Initializing output folder: $script:OutputFolder" -Level Info
    
    if (-not (Test-Path $script:OutputFolder)) {
        New-Item -Path $script:OutputFolder -ItemType Directory -Force | Out-Null
        Write-Log "Created output folder successfully" -Level Success
    }
}

function Test-VeeamConnection {
    Write-Log "Testing Veeam Backup & Replication connection to $VBRServer" -Level Info
    
    try {
        # Check if Veeam PSSnapin is available
        if (-not (Get-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue)) {
            if (Get-PSSnapin -Name VeeamPSSnapin -Registered -ErrorAction SilentlyContinue) {
                Add-PSSnapin VeeamPSSnapin
                Write-Log "Loaded Veeam PowerShell snapin" -Level Success
            } else {
                throw "Veeam PowerShell snapin not found. Please ensure Veeam Backup & Replication console is installed."
            }
        }
        
        # Connect to VBR server if not localhost
        if ($VBRServer -ne "localhost" -and $VBRServer -ne $env:COMPUTERNAME) {
            Disconnect-VBRServer -ErrorAction SilentlyContinue
            Connect-VBRServer -Server $VBRServer -Port $Port
            Write-Log "Connected to Veeam server: $VBRServer" -Level Success
        }
        
        # Test connection
        $server = Get-VBRServer -Name $VBRServer -ErrorAction Stop
        Write-Log "Successfully connected to Veeam Backup & Replication" -Level Success
        return $true
    }
    catch {
        Write-Log "Failed to connect to Veeam: $($_.Exception.Message)" -Level Error
        return $false
    }
}

#endregion

#region Data Collection Functions

function Get-ProxyPerformanceData {
    Write-Log "Collecting proxy (data mover) performance data..." -Level Info
    
    $proxyData = @()
    $dateFrom = (Get-Date).AddDays(-$Days)
    
    try {
        # Get all backup proxies
        $proxies = Get-VBRViProxy
        $proxies += Get-VBRHvProxy
        
        foreach ($proxy in $proxies) {
            Write-Verbose "Analyzing proxy: $($proxy.Name)"
            
            # Get tasks processed by this proxy
            $tasks = Get-VBRTaskSession -Name "*" | Where-Object {
                $_.CreationTime -gt $dateFrom -and
                $_.Info.WorkDetails.ProxyName -eq $proxy.Name
            }
            
            if ($tasks.Count -eq 0) {
                Write-Verbose "No tasks found for proxy $($proxy.Name)"
                continue
            }
            
            # Calculate performance metrics
            $avgSpeed = ($tasks | Measure-Object -Property "Info.Progress.AvgSpeed" -Average).Average
            $totalProcessed = ($tasks | Measure-Object -Property "Info.Progress.ProcessedSize" -Sum).Sum
            $avgDuration = ($tasks | Measure-Object -Property "Info.Progress.Duration.TotalMinutes" -Average).Average
            $taskCount = $tasks.Count
            
            # Get concurrent task count
            $maxConcurrent = 0
            $tasks | Group-Object { $_.CreationTime.Date } | ForEach-Object {
                $dayTasks = $_.Group
                $concurrent = ($dayTasks | Group-Object { $_.CreationTime.ToString("HH") } | 
                    Measure-Object -Property Count -Maximum).Maximum
                if ($concurrent -gt $maxConcurrent) {
                    $maxConcurrent = $concurrent
                }
            }
            
            $proxyInfo = [PSCustomObject]@{
                Name = $proxy.Name
                Type = $proxy.Type
                Host = $proxy.Host.Name
                TaskCount = $taskCount
                TotalProcessedGB = [math]::Round($totalProcessed / 1GB, 2)
                AvgSpeedMBps = [math]::Round($avgSpeed / 1MB, 2)
                AvgDurationMin = [math]::Round($avgDuration, 2)
                MaxConcurrentTasks = $maxConcurrent
                MaxTasks = $proxy.Options.MaxTasksCount
                TransportMode = $proxy.Options.TransportMode
                Status = if ($avgSpeed -gt 0) { "Active" } else { "Idle" }
            }
            
            $proxyData += $proxyInfo
        }
        
        Write-Log "Collected data from $($proxyData.Count) proxies" -Level Success
        return $proxyData
    }
    catch {
        Write-Log "Error collecting proxy data: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-RepositoryPerformanceData {
    Write-Log "Collecting repository and gateway performance data..." -Level Info
    
    $repoData = @()
    $dateFrom = (Get-Date).AddDays(-$Days)
    
    try {
        # Get all backup repositories
        $repositories = Get-VBRBackupRepository
        $repositories += Get-VBRBackupRepository -ScaleOut
        
        foreach ($repo in $repositories) {
            Write-Verbose "Analyzing repository: $($repo.Name)"
            
            # Get repository usage
            $usage = $repo | Get-VBRRepositoryUsage
            $capacityGB = [math]::Round($repo.Info.CachedTotalSpace / 1GB, 2)
            $freeSpaceGB = [math]::Round($repo.Info.CachedFreeSpace / 1GB, 2)
            $usedSpaceGB = $capacityGB - $freeSpaceGB
            $usedPercent = if ($capacityGB -gt 0) { 
                [math]::Round(($usedSpaceGB / $capacityGB) * 100, 2) 
            } else { 0 }
            
            # Get jobs using this repository
            $jobs = Get-VBRJob | Where-Object { $_.TargetRepositoryId -eq $repo.Id }
            
            # Get recent sessions for throughput analysis
            $sessions = Get-VBRBackupSession | Where-Object {
                $_.CreationTime -gt $dateFrom -and
                $_.JobId -in $jobs.Id
            } | Select-Object -First 100
            
            $avgThroughput = if ($sessions) {
                ($sessions | Where-Object { $_.Info.Progress.AvgSpeed -gt 0 } | 
                    Measure-Object -Property "Info.Progress.AvgSpeed" -Average).Average
            } else { 0 }
            
            # Check for gateway
            $gateway = $null
            $gatewayName = "N/A"
            if ($repo.Type -eq "LinuxLocal" -or $repo.Type -eq "SanSnapshotOnly") {
                $gateway = $repo.Host
                $gatewayName = $gateway.Name
            }
            
            $repoInfo = [PSCustomObject]@{
                Name = $repo.Name
                Type = $repo.Type
                Path = $repo.Path
                CapacityGB = $capacityGB
                UsedSpaceGB = $usedSpaceGB
                FreeSpaceGB = $freeSpaceGB
                UsedPercent = $usedPercent
                AvgThroughputMBps = [math]::Round($avgThroughput / 1MB, 2)
                JobCount = $jobs.Count
                Gateway = $gatewayName
                DeduplicationEnabled = $repo.DeduplicationEnabled
                Status = if ($usedPercent -lt $ThresholdStorage) { "Healthy" } else { "Warning" }
            }
            
            $repoData += $repoInfo
        }
        
        Write-Log "Collected data from $($repoData.Count) repositories" -Level Success
        return $repoData
    }
    catch {
        Write-Log "Error collecting repository data: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-JobPerformanceData {
    Write-Log "Collecting job performance data..." -Level Info
    
    $jobData = @()
    $dateFrom = (Get-Date).AddDays(-$Days)
    
    try {
        $jobs = Get-VBRJob
        
        foreach ($job in $jobs) {
            Write-Verbose "Analyzing job: $($job.Name)"
            
            # Get recent sessions
            $sessions = Get-VBRBackupSession | Where-Object {
                $_.JobId -eq $job.Id -and
                $_.CreationTime -gt $dateFrom
            } | Sort-Object CreationTime -Descending
            
            if ($sessions.Count -eq 0) { continue }
            
            # Calculate metrics
            $successRate = ($sessions | Where-Object { $_.Result -eq "Success" }).Count / $sessions.Count * 100
            $avgDuration = ($sessions | Measure-Object -Property "Info.Progress.Duration.TotalMinutes" -Average).Average
            $avgSize = ($sessions | Measure-Object -Property "Info.Progress.ProcessedSize" -Average).Average
            $avgSpeed = ($sessions | Measure-Object -Property "Info.Progress.AvgSpeed" -Average).Average
            
            # Get bottleneck information from latest session
            $latestSession = $sessions | Select-Object -First 1
            $bottleneck = "None"
            if ($latestSession.Info.Progress.BottleneckInfo) {
                $bottleneck = $latestSession.Info.Progress.BottleneckInfo
            }
            
            $jobInfo = [PSCustomObject]@{
                Name = $job.Name
                Type = $job.JobType
                SessionCount = $sessions.Count
                SuccessRate = [math]::Round($successRate, 2)
                AvgDurationMin = [math]::Round($avgDuration, 2)
                AvgSizeGB = [math]::Round($avgSize / 1GB, 2)
                AvgSpeedMBps = [math]::Round($avgSpeed / 1MB, 2)
                LastResult = $latestSession.Result
                Bottleneck = $bottleneck
                Status = if ($successRate -gt 90) { "Healthy" } else { "Warning" }
            }
            
            $jobData += $jobInfo
        }
        
        Write-Log "Collected data from $($jobData.Count) jobs" -Level Success
        return $jobData
    }
    catch {
        Write-Log "Error collecting job data: $($_.Exception.Message)" -Level Error
        return @()
    }
}

function Get-StorageGrowthTrend {
    Write-Log "Analyzing storage growth trends..." -Level Info
    
    $growthData = @()
    $dateFrom = (Get-Date).AddDays(-$Days)
    
    try {
        $repositories = Get-VBRBackupRepository
        
        foreach ($repo in $repositories) {
            # Get backup size history
            $backups = Get-VBRBackup | Where-Object { $_.RepositoryId -eq $repo.Id }
            
            $totalSizeNow = ($backups | Measure-Object -Property DataSize -Sum).Sum
            
            # Estimate daily growth (simplified - in production, you'd query actual historical data)
            $dailyGrowthGB = 0
            if ($Days -gt 7) {
                $recentBackups = $backups | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-7) }
                $oldBackups = $backups | Where-Object { 
                    $_.CreationTime -gt (Get-Date).AddDays(-14) -and 
                    $_.CreationTime -le (Get-Date).AddDays(-7) 
                }
                
                $recentSize = ($recentBackups | Measure-Object -Property DataSize -Sum).Sum
                $oldSize = ($oldBackups | Measure-Object -Property DataSize -Sum).Sum
                
                $weeklyGrowth = $recentSize - $oldSize
                $dailyGrowthGB = [math]::Round(($weeklyGrowth / 7) / 1GB, 2)
            }
            
            # Calculate days until full
            $freeSpaceGB = [math]::Round($repo.Info.CachedFreeSpace / 1GB, 2)
            $daysUntilFull = if ($dailyGrowthGB -gt 0) {
                [math]::Round($freeSpaceGB / $dailyGrowthGB, 0)
            } else {
                999
            }
            
            $growthInfo = [PSCustomObject]@{
                Repository = $repo.Name
                CurrentSizeGB = [math]::Round($totalSizeNow / 1GB, 2)
                DailyGrowthGB = $dailyGrowthGB
                MonthlyGrowthGB = [math]::Round($dailyGrowthGB * 30, 2)
                FreeSpaceGB = $freeSpaceGB
                DaysUntilFull = $daysUntilFull
                Forecast30Days = [math]::Round($totalSizeNow / 1GB + ($dailyGrowthGB * 30), 2)
                Forecast90Days = [math]::Round($totalSizeNow / 1GB + ($dailyGrowthGB * 90), 2)
            }
            
            $growthData += $growthInfo
        }
        
        Write-Log "Analyzed storage growth for $($growthData.Count) repositories" -Level Success
        return $growthData
    }
    catch {
        Write-Log "Error analyzing storage growth: $($_.Exception.Message)" -Level Error
        return @()
    }
}

#endregion

#region Analysis and Recommendations

function Get-ProxyRecommendations {
    param([array]$ProxyData)
    
    Write-Log "Generating proxy recommendations..." -Level Info
    
    foreach ($proxy in $ProxyData) {
        # Check if proxy is underutilized
        if ($proxy.AvgSpeedMBps -lt $ThresholdThroughput -and $proxy.TaskCount -gt 10) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Data Mover (Proxy)"
                Resource = $proxy.Name
                Severity = "Warning"
                Issue = "Low throughput performance"
                Current = "$($proxy.AvgSpeedMBps) MB/s average"
                Threshold = "$ThresholdThroughput MB/s"
                Recommendation = "Review proxy host resources (CPU, memory, network). Consider enabling backup acceleration or changing transport mode. Current mode: $($proxy.TransportMode)"
                Priority = 2
            }
        }
        
        # Check if proxy is maxing out concurrent tasks
        if ($proxy.MaxConcurrentTasks -ge ($proxy.MaxTasks * 0.9)) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Data Mover (Proxy)"
                Resource = $proxy.Name
                Severity = "High"
                Issue = "Proxy task limit reached"
                Current = "$($proxy.MaxConcurrentTasks) concurrent tasks"
                Threshold = "$($proxy.MaxTasks) maximum tasks"
                Recommendation = "Increase MaxTasksCount in proxy settings or add additional proxy servers to distribute load. Consider deploying proxies closer to data sources."
                Priority = 1
            }
        }
        
        # Check for idle proxies
        if ($proxy.Status -eq "Idle" -and $proxy.TaskCount -eq 0) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Data Mover (Proxy)"
                Resource = $proxy.Name
                Severity = "Info"
                Issue = "Unused proxy resource"
                Current = "0 tasks in last $Days days"
                Threshold = "N/A"
                Recommendation = "This proxy is not being utilized. Consider removing it or assigning jobs to use this resource."
                Priority = 3
            }
        }
    }
}

function Get-RepositoryRecommendations {
    param(
        [array]$RepositoryData,
        [array]$GrowthData
    )
    
    Write-Log "Generating repository and gateway recommendations..." -Level Info
    
    foreach ($repo in $RepositoryData) {
        # Storage capacity warnings
        if ($repo.UsedPercent -ge $ThresholdStorage) {
            $severity = if ($repo.UsedPercent -ge 90) { "Critical" } else { "High" }
            
            $growth = $GrowthData | Where-Object { $_.Repository -eq $repo.Name }
            $additionalInfo = if ($growth) {
                "Estimated full in $($growth.DaysUntilFull) days at current growth rate."
            } else {
                ""
            }
            
            $script:Recommendations += [PSCustomObject]@{
                Category = "Storage"
                Resource = $repo.Name
                Severity = $severity
                Issue = "High storage utilization"
                Current = "$($repo.UsedPercent)% used ($($repo.UsedSpaceGB) GB / $($repo.CapacityGB) GB)"
                Threshold = "$ThresholdStorage%"
                Recommendation = "Add capacity to this repository or enable storage optimization features (deduplication, compression). $additionalInfo Consider implementing lifecycle policies to move data to archive tiers."
                Priority = if ($severity -eq "Critical") { 1 } else { 2 }
            }
        }
        
        # Low throughput to repository
        if ($repo.AvgThroughputMBps -lt $ThresholdThroughput -and $repo.AvgThroughputMBps -gt 0) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Gateway"
                Resource = "$($repo.Name) - Gateway: $($repo.Gateway)"
                Severity = "Warning"
                Issue = "Low repository write throughput"
                Current = "$($repo.AvgThroughputMBps) MB/s average"
                Threshold = "$ThresholdThroughput MB/s"
                Recommendation = "Review gateway server resources and network connectivity. For Linux repositories, ensure gateway has sufficient CPU and memory. Consider using multiple mount points or enabling parallel processing."
                Priority = 2
            }
        }
        
        # Deduplication recommendation
        if (-not $repo.DeduplicationEnabled -and $repo.UsedSpaceGB -gt 500) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Storage"
                Resource = $repo.Name
                Severity = "Info"
                Issue = "Deduplication not enabled"
                Current = "Disabled"
                Threshold = "N/A"
                Recommendation = "Consider enabling deduplication to reduce storage consumption. Estimated savings: 20-50% depending on workload type. Note: This requires repository migration."
                Priority = 3
            }
        }
    }
    
    # Storage growth warnings
    foreach ($growth in $GrowthData) {
        if ($growth.DaysUntilFull -lt 30 -and $growth.DaysUntilFull -gt 0) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Storage Capacity Planning"
                Resource = $growth.Repository
                Severity = "High"
                Issue = "Repository approaching capacity"
                Current = "~$($growth.DaysUntilFull) days until full"
                Threshold = "30 days"
                Recommendation = "Plan for capacity expansion. Daily growth: $($growth.DailyGrowthGB) GB/day. Projected need in 90 days: $($growth.Forecast90Days) GB total. Consider implementing GFS retention or archive tier offload."
                Priority = 1
            }
        }
    }
}

function Get-JobRecommendations {
    param([array]$JobData)
    
    Write-Log "Generating job performance recommendations..." -Level Info
    
    foreach ($job in $JobData) {
        # Low success rate
        if ($job.SuccessRate -lt 90) {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Job Health"
                Resource = $job.Name
                Severity = "High"
                Issue = "Low job success rate"
                Current = "$($job.SuccessRate)% success"
                Threshold = "90%"
                Recommendation = "Review job logs to identify failure causes. Common issues: source connectivity, repository space, retention policy conflicts. Last result: $($job.LastResult)"
                Priority = 1
            }
        }
        
        # Bottleneck identification
        if ($job.Bottleneck -ne "None" -and $job.Bottleneck -ne "") {
            $script:Recommendations += [PSCustomObject]@{
                Category = "Performance"
                Resource = $job.Name
                Severity = "Warning"
                Issue = "Job bottleneck detected"
                Current = "Bottleneck: $($job.Bottleneck)"
                Threshold = "N/A"
                Recommendation = "Address identified bottleneck. Common solutions: Add proxy resources, optimize storage, enable parallel processing, adjust concurrent tasks."
                Priority = 2
            }
        }
        
        # Very long running jobs
        if ($job.AvgDurationMin -gt 360) {  # 6 hours
            $script:Recommendations += [PSCustomObject]@{
                Category = "Performance"
                Resource = $job.Name
                Severity = "Info"
                Issue = "Long running job"
                Current = "$($job.AvgDurationMin) minutes average"
                Threshold = "360 minutes"
                Recommendation = "Consider splitting this job into smaller jobs, enabling backup from storage snapshots, or optimizing backup window. Job processes $($job.AvgSizeGB) GB at $($job.AvgSpeedMBps) MB/s."
                Priority = 3
            }
        }
    }
}

#endregion

#region Reporting Functions

function Export-ReportData {
    param(
        [array]$ProxyData,
        [array]$RepositoryData,
        [array]$JobData,
        [array]$GrowthData
    )
    
    Write-Log "Exporting report data..." -Level Info
    
    if ($ExportCSV) {
        $ProxyData | Export-Csv -Path (Join-Path $script:OutputFolder "proxies.csv") -NoTypeInformation
        $RepositoryData | Export-Csv -Path (Join-Path $script:OutputFolder "repositories.csv") -NoTypeInformation
        $JobData | Export-Csv -Path (Join-Path $script:OutputFolder "jobs.csv") -NoTypeInformation
        $GrowthData | Export-Csv -Path (Join-Path $script:OutputFolder "storage-growth.csv") -NoTypeInformation
        $script:Recommendations | Export-Csv -Path (Join-Path $script:OutputFolder "recommendations.csv") -NoTypeInformation
        Write-Log "CSV files exported successfully" -Level Success
    }
    
    if ($ExportJSON) {
        $jsonData = @{
            Timestamp = $script:StartTime
            AnalysisPeriodDays = $Days
            Thresholds = @{
                CPU = $ThresholdCPU
                Memory = $ThresholdMemory
                Storage = $ThresholdStorage
                Throughput = $ThresholdThroughput
            }
            Proxies = $ProxyData
            Repositories = $RepositoryData
            Jobs = $JobData
            StorageGrowth = $GrowthData
            Recommendations = $script:Recommendations
        }
        
        $jsonData | ConvertTo-Json -Depth 10 | Out-File -FilePath (Join-Path $script:OutputFolder "report.json") -Encoding UTF8
        Write-Log "JSON file exported successfully" -Level Success
    }
}

function New-HTMLReport {
    param(
        [array]$ProxyData,
        [array]$RepositoryData,
        [array]$JobData,
        [array]$GrowthData
    )
    
    Write-Log "Generating HTML report..." -Level Info
    
    $html = @"
<!DOCTYPE html>
<html>
<head>
    <title>Veeam Optimization Report - $script:RunTimestamp</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; margin: 20px; background-color: #f5f5f5; }
        h1 { color: #00b336; border-bottom: 3px solid #00b336; padding-bottom: 10px; }
        h2 { color: #333; margin-top: 30px; border-bottom: 2px solid #ddd; padding-bottom: 5px; }
        h3 { color: #555; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        th { background-color: #00b336; color: white; padding: 12px; text-align: left; font-weight: bold; }
        td { padding: 10px; border-bottom: 1px solid #ddd; }
        tr:hover { background-color: #f9f9f9; }
        .summary { background-color: white; padding: 20px; margin: 20px 0; border-radius: 5px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .metric { display: inline-block; margin: 10px 20px 10px 0; }
        .metric-label { font-weight: bold; color: #666; }
        .metric-value { font-size: 24px; color: #00b336; }
        .critical { color: #d32f2f; font-weight: bold; }
        .high { color: #f57c00; font-weight: bold; }
        .warning { color: #fbc02d; font-weight: bold; }
        .info { color: #0288d1; }
        .success { color: #00b336; font-weight: bold; }
        .footer { margin-top: 40px; padding-top: 20px; border-top: 1px solid #ddd; color: #666; font-size: 12px; }
    </style>
</head>
<body>
    <h1>🔍 Veeam Optimization Report</h1>
    
    <div class="summary">
        <h3>Report Summary</h3>
        <div class="metric">
            <div class="metric-label">Generated</div>
            <div class="metric-value">$script:RunTimestamp</div>
        </div>
        <div class="metric">
            <div class="metric-label">Analysis Period</div>
            <div class="metric-value">$Days days</div>
        </div>
        <div class="metric">
            <div class="metric-label">Total Recommendations</div>
            <div class="metric-value">$($script:Recommendations.Count)</div>
        </div>
        <div class="metric">
            <div class="metric-label">Critical Issues</div>
            <div class="metric-value critical">$(($script:Recommendations | Where-Object { $_.Severity -eq 'Critical' }).Count)</div>
        </div>
    </div>
    
    <h2>🚨 Recommendations (Priority Order)</h2>
    <table>
        <tr>
            <th>Priority</th>
            <th>Category</th>
            <th>Resource</th>
            <th>Severity</th>
            <th>Issue</th>
            <th>Current Status</th>
            <th>Recommendation</th>
        </tr>
"@

    foreach ($rec in ($script:Recommendations | Sort-Object Priority, Severity)) {
        $severityClass = $rec.Severity.ToLower()
        $html += @"
        <tr>
            <td>$($rec.Priority)</td>
            <td>$($rec.Category)</td>
            <td>$($rec.Resource)</td>
            <td class="$severityClass">$($rec.Severity)</td>
            <td>$($rec.Issue)</td>
            <td>$($rec.Current)</td>
            <td>$($rec.Recommendation)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <h2>💾 Data Movers (Proxies)</h2>
    <table>
        <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Tasks Processed</th>
            <th>Avg Speed (MB/s)</th>
            <th>Max Concurrent</th>
            <th>Max Tasks Limit</th>
            <th>Status</th>
        </tr>
"@

    foreach ($proxy in $ProxyData) {
        $statusClass = if ($proxy.Status -eq "Active") { "success" } else { "info" }
        $html += @"
        <tr>
            <td>$($proxy.Name)</td>
            <td>$($proxy.Type)</td>
            <td>$($proxy.TaskCount)</td>
            <td>$($proxy.AvgSpeedMBps)</td>
            <td>$($proxy.MaxConcurrentTasks)</td>
            <td>$($proxy.MaxTasks)</td>
            <td class="$statusClass">$($proxy.Status)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <h2>🗄️ Repositories & Gateways</h2>
    <table>
        <tr>
            <th>Name</th>
            <th>Type</th>
            <th>Capacity (GB)</th>
            <th>Used (%)</th>
            <th>Free (GB)</th>
            <th>Avg Throughput (MB/s)</th>
            <th>Gateway</th>
            <th>Status</th>
        </tr>
"@

    foreach ($repo in $RepositoryData) {
        $statusClass = if ($repo.Status -eq "Healthy") { "success" } else { "warning" }
        $html += @"
        <tr>
            <td>$($repo.Name)</td>
            <td>$($repo.Type)</td>
            <td>$($repo.CapacityGB)</td>
            <td>$($repo.UsedPercent)%</td>
            <td>$($repo.FreeSpaceGB)</td>
            <td>$($repo.AvgThroughputMBps)</td>
            <td>$($repo.Gateway)</td>
            <td class="$statusClass">$($repo.Status)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <h2>📈 Storage Growth Forecast</h2>
    <table>
        <tr>
            <th>Repository</th>
            <th>Current Size (GB)</th>
            <th>Daily Growth (GB)</th>
            <th>30-Day Forecast (GB)</th>
            <th>90-Day Forecast (GB)</th>
            <th>Days Until Full</th>
        </tr>
"@

    foreach ($growth in $GrowthData) {
        $daysClass = if ($growth.DaysUntilFull -lt 30) { "critical" } elseif ($growth.DaysUntilFull -lt 60) { "warning" } else { "success" }
        $html += @"
        <tr>
            <td>$($growth.Repository)</td>
            <td>$($growth.CurrentSizeGB)</td>
            <td>$($growth.DailyGrowthGB)</td>
            <td>$($growth.Forecast30Days)</td>
            <td>$($growth.Forecast90Days)</td>
            <td class="$daysClass">$($growth.DaysUntilFull)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <h2>⚙️ Job Performance Summary</h2>
    <table>
        <tr>
            <th>Job Name</th>
            <th>Type</th>
            <th>Success Rate (%)</th>
            <th>Avg Duration (min)</th>
            <th>Avg Speed (MB/s)</th>
            <th>Last Result</th>
            <th>Status</th>
        </tr>
"@

    foreach ($job in $JobData) {
        $statusClass = if ($job.Status -eq "Healthy") { "success" } else { "warning" }
        $resultClass = if ($job.LastResult -eq "Success") { "success" } else { "high" }
        $html += @"
        <tr>
            <td>$($job.Name)</td>
            <td>$($job.Type)</td>
            <td>$($job.SuccessRate)%</td>
            <td>$($job.AvgDurationMin)</td>
            <td>$($job.AvgSpeedMBps)</td>
            <td class="$resultClass">$($job.LastResult)</td>
            <td class="$statusClass">$($job.Status)</td>
        </tr>
"@
    }

    $html += @"
    </table>
    
    <div class="footer">
        <p>Report generated by Veeam Optimization Tool | Analysis Period: $Days days | Thresholds: CPU $ThresholdCPU%, Memory $ThresholdMemory%, Storage $ThresholdStorage%, Throughput $ThresholdThroughput MB/s</p>
        <p>For questions or support, contact your Veeam Solutions Architect</p>
    </div>
</body>
</html>
"@

    $htmlPath = Join-Path $script:OutputFolder "VeeamOptimizationReport.html"
    $html | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "HTML report generated: $htmlPath" -Level Success
    
    return $htmlPath
}

function Show-ConsoleSummary {
    param(
        [array]$ProxyData,
        [array]$RepositoryData,
        [array]$JobData
    )
    
    Write-Host "`n" -NoNewline
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "    VEEAM OPTIMIZATION REPORT SUMMARY" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    
    Write-Host "`nData Movers (Proxies): " -NoNewline
    Write-Host $ProxyData.Count -ForegroundColor Green
    Write-Host "Repositories: " -NoNewline
    Write-Host $RepositoryData.Count -ForegroundColor Green
    Write-Host "Jobs Analyzed: " -NoNewline
    Write-Host $JobData.Count -ForegroundColor Green
    
    Write-Host "`nRecommendations by Severity:" -ForegroundColor Yellow
    $critical = ($script:Recommendations | Where-Object { $_.Severity -eq 'Critical' }).Count
    $high = ($script:Recommendations | Where-Object { $_.Severity -eq 'High' }).Count
    $warning = ($script:Recommendations | Where-Object { $_.Severity -eq 'Warning' }).Count
    $info = ($script:Recommendations | Where-Object { $_.Severity -eq 'Info' }).Count
    
    Write-Host "  Critical: " -NoNewline
    Write-Host $critical -ForegroundColor Red
    Write-Host "  High: " -NoNewline
    Write-Host $high -ForegroundColor Magenta
    Write-Host "  Warning: " -NoNewline
    Write-Host $warning -ForegroundColor Yellow
    Write-Host "  Info: " -NoNewline
    Write-Host $info -ForegroundColor Cyan
    
    if ($script:Recommendations.Count -gt 0) {
        Write-Host "`nTop 5 Recommendations:" -ForegroundColor Yellow
        $script:Recommendations | Sort-Object Priority | Select-Object -First 5 | ForEach-Object {
            Write-Host "  [$($_.Severity)] " -NoNewline -ForegroundColor (
                switch ($_.Severity) {
                    'Critical' { 'Red' }
                    'High' { 'Magenta' }
                    'Warning' { 'Yellow' }
                    default { 'Cyan' }
                }
            )
            Write-Host "$($_.Resource): $($_.Issue)"
        }
    }
    
    Write-Host "`n================================================" -ForegroundColor Cyan
    Write-Host "Output Location: " -NoNewline
    Write-Host $script:OutputFolder -ForegroundColor Green
    Write-Host "================================================`n" -ForegroundColor Cyan
}

#endregion

#region Main Execution

function Start-VeeamOptimizationAnalysis {
    Write-Host "`n"
    Write-Host "╔════════════════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "║   VEEAM OPTIMIZATION & RECOMMENDATION TOOL         ║" -ForegroundColor Green
    Write-Host "║   Log Analysis & Resource Planning                 ║" -ForegroundColor Green
    Write-Host "╚════════════════════════════════════════════════════╝" -ForegroundColor Green
    Write-Host "`n"
    
    # Initialize
    Initialize-OutputFolder
    
    # Test connection
    if (-not (Test-VeeamConnection)) {
        Write-Log "Cannot proceed without Veeam connection" -Level Error
        return
    }
    
    # Collect data
    $proxyData = Get-ProxyPerformanceData
    $repoData = Get-RepositoryPerformanceData
    $jobData = Get-JobPerformanceData
    $growthData = Get-StorageGrowthTrend
    
    # Generate recommendations
    Get-ProxyRecommendations -ProxyData $proxyData
    Get-RepositoryRecommendations -RepositoryData $repoData -GrowthData $growthData
    Get-JobRecommendations -JobData $jobData
    
    # Export reports
    Export-ReportData -ProxyData $proxyData -RepositoryData $repoData -JobData $jobData -GrowthData $growthData
    
    if ($ExportHTML) {
        $htmlPath = New-HTMLReport -ProxyData $proxyData -RepositoryData $repoData -JobData $jobData -GrowthData $growthData
        Write-Host "`nHTML Report: " -NoNewline
        Write-Host $htmlPath -ForegroundColor Cyan
    }
    
    # Show summary
    Show-ConsoleSummary -ProxyData $proxyData -RepositoryData $repoData -JobData $jobData
    
    # Calculate execution time
    $duration = (Get-Date) - $script:StartTime
    Write-Log "Analysis completed in $($duration.TotalSeconds) seconds" -Level Success
}

# Execute main function
try {
    Start-VeeamOptimizationAnalysis
}
catch {
    Write-Log "Fatal error: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
}
finally {
    # Cleanup if needed
    if ($VBRServer -ne "localhost" -and $VBRServer -ne $env:COMPUTERNAME) {
        Disconnect-VBRServer -ErrorAction SilentlyContinue
    }
}

#endregion
