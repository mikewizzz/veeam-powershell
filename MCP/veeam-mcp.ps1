<#
.SYNOPSIS
    Veeam Backup & Replication v13 MCP (Model Context Protocol) Demo Script
    
.DESCRIPTION
    Comprehensive PowerShell script demonstrating MCP functionality with Veeam VBR v13.
    This script provides tools and resources for AI assistants to interact with Veeam infrastructure,
    enabling intelligent automation, monitoring, and management capabilities.
    
.PARAMETER VBRServer
    The Veeam Backup & Replication server name or IP address
    
.PARAMETER Credential
    PSCredential object for authentication. If not provided, current user context is used
    
.PARAMETER Action
    The action to perform. Options: All, ServerInfo, Jobs, Repositories, RestorePoints, 
    Sessions, Infrastructure, Capacity, Health, Backup, Restore
    
.PARAMETER JobName
    Specific job name for job-related operations
    
.PARAMETER VMName
    Virtual machine name for backup/restore operations
    
.PARAMETER ExportPath
    Path to export results (default: ./VeeamMCPOutput)
    
.PARAMETER OutputFormat
    Output format: JSON, CSV, or Both (default: JSON)
    
.EXAMPLE
    .\veeam-mcp.ps1 -VBRServer "veeam-server.domain.com" -Action All
    
.EXAMPLE
    .\veeam-mcp.ps1 -Action Jobs -JobName "Production VMs"
    
.EXAMPLE
    .\veeam-mcp.ps1 -Action Health -ExportPath "C:\Reports" -OutputFormat Both
    
.NOTES
    Author: Veeam Solutions Architect
    Version: 1.0
    Date: January 2026
    Requires: Veeam Backup & Replication v13 PowerShell Snap-in
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$VBRServer = "localhost",
    
    [Parameter(Mandatory=$false)]
    [PSCredential]$Credential,
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("All", "ServerInfo", "Jobs", "Repositories", "RestorePoints", 
                 "Sessions", "Infrastructure", "Capacity", "Health", "Backup", "Restore")]
    [string]$Action = "All",
    
    [Parameter(Mandatory=$false)]
    [string]$JobName,
    
    [Parameter(Mandatory=$false)]
    [string]$VMName,
    
    [Parameter(Mandatory=$false)]
    [string]$ExportPath = "./VeeamMCPOutput",
    
    [Parameter(Mandatory=$false)]
    [ValidateSet("JSON", "CSV", "Both")]
    [string]$OutputFormat = "JSON"
)

#region Initialization

# Set error handling
$ErrorActionPreference = "Stop"
$WarningPreference = "Continue"

# Create timestamp for this run
$timestamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$runPath = Join-Path $ExportPath "Run-$timestamp"

# Create output directory
if (-not (Test-Path $runPath)) {
    New-Item -ItemType Directory -Path $runPath -Force | Out-Null
    Write-Host "✓ Created output directory: $runPath" -ForegroundColor Green
}

# Initialize results object
$mcpResults = @{
    Timestamp = $timestamp
    VBRServer = $VBRServer
    Action = $Action
    Results = @{}
}

#endregion

#region Helper Functions

function Write-MCPLog {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Warning", "Error")]
        [string]$Level = "Info"
    )
    
    $colors = @{
        Info = "Cyan"
        Success = "Green"
        Warning = "Yellow"
        Error = "Red"
    }
    
    $prefix = switch ($Level) {
        "Info" { "ℹ️" }
        "Success" { "✓" }
        "Warning" { "⚠️" }
        "Error" { "✗" }
    }
    
    Write-Host "$prefix $Message" -ForegroundColor $colors[$Level]
}

function Export-MCPData {
    param(
        [Parameter(Mandatory=$true)]
        [object]$Data,
        
        [Parameter(Mandatory=$true)]
        [string]$Name,
        
        [Parameter(Mandatory=$false)]
        [string]$Path = $runPath
    )
    
    $basePath = Join-Path $Path $Name
    
    try {
        if ($OutputFormat -eq "JSON" -or $OutputFormat -eq "Both") {
            $jsonPath = "$basePath.json"
            $Data | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
            Write-MCPLog "Exported JSON: $jsonPath" -Level Success
        }
        
        if ($OutputFormat -eq "CSV" -or $OutputFormat -eq "Both") {
            $csvPath = "$basePath.csv"
            if ($Data -is [Array] -and $Data.Count -gt 0) {
                $Data | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
                Write-MCPLog "Exported CSV: $csvPath" -Level Success
            }
        }
    }
    catch {
        Write-MCPLog "Failed to export $Name: $_" -Level Error
    }
}

function Connect-VBRServerMCP {
    Write-MCPLog "Connecting to Veeam Backup & Replication server: $VBRServer" -Level Info
    
    try {
        # Load Veeam PSSnapin
        if (-not (Get-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue)) {
            Add-PSSnapin VeeamPSSnapin -ErrorAction Stop
            Write-MCPLog "Loaded VeeamPSSnapin" -Level Success
        }
        
        # Connect to VBR server
        if ($Credential) {
            Connect-VBRServer -Server $VBRServer -Credential $Credential -ErrorAction Stop
        }
        else {
            Connect-VBRServer -Server $VBRServer -ErrorAction Stop
        }
        
        Write-MCPLog "Successfully connected to VBR server" -Level Success
        return $true
    }
    catch {
        Write-MCPLog "Failed to connect to VBR server: $_" -Level Error
        return $false
    }
}

function Disconnect-VBRServerMCP {
    try {
        Disconnect-VBRServer
        Write-MCPLog "Disconnected from VBR server" -Level Info
    }
    catch {
        Write-MCPLog "Error disconnecting: $_" -Level Warning
    }
}

#endregion

#region MCP Action Functions

function Get-VBRServerInfoMCP {
    Write-MCPLog "Retrieving VBR Server Information..." -Level Info
    
    try {
        $serverInfo = @{
            ServerName = $VBRServer
            ServerVersion = (Get-VBRServerSession).ServerVersion
            ServerEdition = (Get-VBRServerSession).ProductEdition
            BuildNumber = (Get-VBRServerSession).Build
            DatabaseName = (Get-VBRServerSession).DatabaseName
            DatabaseServer = (Get-VBRServerSession).DatabaseServer
            Connected = (Get-VBRServerSession).IsConnected
            UserName = (Get-VBRServerSession).User
        }
        
        $mcpResults.Results.ServerInfo = $serverInfo
        Export-MCPData -Data $serverInfo -Name "VBR-ServerInfo"
        
        Write-Host "`n=== VBR Server Information ===" -ForegroundColor Magenta
        $serverInfo.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Host "  $($_.Key): $($_.Value)" -ForegroundColor White
        }
        
        return $serverInfo
    }
    catch {
        Write-MCPLog "Error retrieving server info: $_" -Level Error
        return $null
    }
}

function Get-VBRJobsMCP {
    Write-MCPLog "Retrieving VBR Jobs..." -Level Info
    
    try {
        $jobs = Get-VBRJob
        
        if ($JobName) {
            $jobs = $jobs | Where-Object { $_.Name -eq $JobName }
        }
        
        $jobDetails = $jobs | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Type = $_.JobType
                Description = $_.Description
                IsEnabled = $_.IsScheduleEnabled
                IsRunning = $_.IsRunning
                LastResult = $_.GetLastResult()
                LastRun = $_.ScheduleOptions.LatestRunLocal
                NextRun = $_.ScheduleOptions.NextRun
                TargetRepo = $_.GetTargetRepository().Name
                SourceSize = [math]::Round($_.Info.IncludedSize / 1GB, 2)
                BackupSize = [math]::Round($_.Info.BackupSize / 1GB, 2)
                TargetType = $_.BackupPlatform.Platform
                RetentionPolicy = $_.Options.BackupStorageOptions.RetainCycles
                CompressionLevel = $_.Options.BackupStorageOptions.CompressionLevel
                EncryptionEnabled = $_.Options.BackupStorageOptions.StorageEncryptionEnabled
            }
        }
        
        $mcpResults.Results.Jobs = $jobDetails
        Export-MCPData -Data $jobDetails -Name "VBR-Jobs"
        
        Write-Host "`n=== VBR Jobs Summary ===" -ForegroundColor Magenta
        Write-Host "  Total Jobs: $($jobDetails.Count)" -ForegroundColor White
        Write-Host "  Enabled: $(($jobDetails | Where-Object IsEnabled).Count)" -ForegroundColor Green
        Write-Host "  Running: $(($jobDetails | Where-Object IsRunning).Count)" -ForegroundColor Yellow
        
        return $jobDetails
    }
    catch {
        Write-MCPLog "Error retrieving jobs: $_" -Level Error
        return $null
    }
}

function Get-VBRRepositoriesMCP {
    Write-MCPLog "Retrieving VBR Repositories..." -Level Info
    
    try {
        $repos = Get-VBRBackupRepository
        $scaleOut = Get-VBRBackupRepository -ScaleOut
        
        $repoDetails = $repos | ForEach-Object {
            $repo = $_
            $totalSpace = 0
            $freeSpace = 0
            
            try {
                $totalSpace = [math]::Round($repo.GetContainer().CachedTotalSpace / 1GB, 2)
                $freeSpace = [math]::Round($repo.GetContainer().CachedFreeSpace / 1GB, 2)
            }
            catch {
                # Some repository types may not support this
            }
            
            [PSCustomObject]@{
                Name = $repo.Name
                Type = $repo.Type
                Host = $repo.Host.Name
                Path = $repo.Path
                TotalSpaceGB = $totalSpace
                FreeSpaceGB = $freeSpace
                UsedSpaceGB = $totalSpace - $freeSpace
                UsedPercent = if ($totalSpace -gt 0) { [math]::Round((($totalSpace - $freeSpace) / $totalSpace) * 100, 2) } else { 0 }
                IsUnavailable = $repo.IsUnavailable
                HasBackups = $repo.HasBackup
            }
        }
        
        $mcpResults.Results.Repositories = $repoDetails
        Export-MCPData -Data $repoDetails -Name "VBR-Repositories"
        
        Write-Host "`n=== VBR Repositories Summary ===" -ForegroundColor Magenta
        Write-Host "  Total Repositories: $($repoDetails.Count)" -ForegroundColor White
        Write-Host "  Total Capacity: $([math]::Round(($repoDetails | Measure-Object TotalSpaceGB -Sum).Sum, 2)) GB" -ForegroundColor Cyan
        Write-Host "  Free Space: $([math]::Round(($repoDetails | Measure-Object FreeSpaceGB -Sum).Sum, 2)) GB" -ForegroundColor Green
        
        return $repoDetails
    }
    catch {
        Write-MCPLog "Error retrieving repositories: $_" -Level Error
        return $null
    }
}

function Get-VBRRestorePointsMCP {
    Write-MCPLog "Retrieving VBR Restore Points..." -Level Info
    
    try {
        $restorePoints = Get-VBRRestorePoint
        
        if ($VMName) {
            $restorePoints = $restorePoints | Where-Object { $_.VmName -eq $VMName }
        }
        
        $rpDetails = $restorePoints | ForEach-Object {
            [PSCustomObject]@{
                VMName = $_.VmName
                CreationTime = $_.CreationTime
                Type = $_.Type
                Algorithm = $_.Algorithm
                IsConsistent = $_.IsConsistent
                PlatformName = $_.PlatformName
                JobName = $_.GetJob().Name
                BackupSize = [math]::Round($_.ApproxSize / 1GB, 2)
            }
        } | Sort-Object VMName, CreationTime -Descending
        
        $mcpResults.Results.RestorePoints = $rpDetails
        Export-MCPData -Data $rpDetails -Name "VBR-RestorePoints"
        
        Write-Host "`n=== VBR Restore Points Summary ===" -ForegroundColor Magenta
        Write-Host "  Total Restore Points: $($rpDetails.Count)" -ForegroundColor White
        Write-Host "  Unique VMs: $(($rpDetails | Select-Object -Unique VMName).Count)" -ForegroundColor Cyan
        Write-Host "  Total Backup Size: $([math]::Round(($rpDetails | Measure-Object BackupSize -Sum).Sum, 2)) GB" -ForegroundColor Yellow
        
        return $rpDetails
    }
    catch {
        Write-MCPLog "Error retrieving restore points: $_" -Level Error
        return $null
    }
}

function Get-VBRSessionsMCP {
    Write-MCPLog "Retrieving VBR Job Sessions (Last 24 hours)..." -Level Info
    
    try {
        $sessions = Get-VBRBackupSession | Where-Object { $_.CreationTime -gt (Get-Date).AddHours(-24) }
        
        $sessionDetails = $sessions | ForEach-Object {
            $session = $_
            $taskSessions = $session.GetTaskSessions()
            
            [PSCustomObject]@{
                JobName = $session.JobName
                JobType = $session.JobType
                State = $session.State
                Result = $session.Result
                CreationTime = $session.CreationTime
                EndTime = $session.EndTime
                Duration = if ($session.EndTime) { 
                    New-TimeSpan -Start $session.CreationTime -End $session.EndTime | 
                    ForEach-Object { "$($_.Hours)h $($_.Minutes)m $($_.Seconds)s" }
                } else { "Running" }
                ProcessedObjects = $taskSessions.Count
                SuccessfulObjects = ($taskSessions | Where-Object { $_.Status -eq "Success" }).Count
                WarningObjects = ($taskSessions | Where-Object { $_.Status -eq "Warning" }).Count
                FailedObjects = ($taskSessions | Where-Object { $_.Status -eq "Failed" }).Count
                ProcessedSize = [math]::Round(($session.Info.Progress.ProcessedSize / 1GB), 2)
                TransferredSize = [math]::Round(($session.Info.Progress.TransferedSize / 1GB), 2)
            }
        } | Sort-Object CreationTime -Descending
        
        $mcpResults.Results.Sessions = $sessionDetails
        Export-MCPData -Data $sessionDetails -Name "VBR-Sessions"
        
        Write-Host "`n=== VBR Sessions Summary (Last 24h) ===" -ForegroundColor Magenta
        Write-Host "  Total Sessions: $($sessionDetails.Count)" -ForegroundColor White
        Write-Host "  Success: $(($sessionDetails | Where-Object Result -eq 'Success').Count)" -ForegroundColor Green
        Write-Host "  Warning: $(($sessionDetails | Where-Object Result -eq 'Warning').Count)" -ForegroundColor Yellow
        Write-Host "  Failed: $(($sessionDetails | Where-Object Result -eq 'Failed').Count)" -ForegroundColor Red
        
        return $sessionDetails
    }
    catch {
        Write-MCPLog "Error retrieving sessions: $_" -Level Error
        return $null
    }
}

function Get-VBRInfrastructureMCP {
    Write-MCPLog "Retrieving VBR Infrastructure..." -Level Info
    
    try {
        $infrastructure = @{
            ManagedServers = @()
            ProxyServers = @()
            RepositoryServers = @()
            WANAccelerators = @()
        }
        
        # Managed Servers
        $managedServers = Get-VBRServer
        $infrastructure.ManagedServers = $managedServers | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Type = $_.Type
                Description = $_.Description
                IsUnavailable = $_.IsUnavailable
                ApiVersion = $_.Info.ApiVersion
            }
        }
        
        # Proxy Servers
        $proxies = Get-VBRViProxy
        $infrastructure.ProxyServers = $proxies | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Host = $_.Host.Name
                Type = $_.Type
                IsDisabled = $_.IsDisabled
                MaxTasks = $_.Options.MaxTasksCount
                TransportMode = $_.Options.TransportMode
            }
        }
        
        # Repository Servers
        $repoServers = Get-VBRServer | Where-Object { $_.Type -eq "RepositoryServer" }
        $infrastructure.RepositoryServers = $repoServers | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Description = $_.Description
                IsUnavailable = $_.IsUnavailable
            }
        }
        
        # WAN Accelerators
        $wanAccels = Get-VBRWANAccelerator
        $infrastructure.WANAccelerators = $wanAccels | ForEach-Object {
            [PSCustomObject]@{
                Name = $_.Name
                Host = $_.GetHost().Name
                IsDisabled = $_.IsDisabled
                CachePathLocation = $_.CachePath
            }
        }
        
        $mcpResults.Results.Infrastructure = $infrastructure
        Export-MCPData -Data $infrastructure.ManagedServers -Name "VBR-Infrastructure-ManagedServers"
        Export-MCPData -Data $infrastructure.ProxyServers -Name "VBR-Infrastructure-Proxies"
        
        Write-Host "`n=== VBR Infrastructure Summary ===" -ForegroundColor Magenta
        Write-Host "  Managed Servers: $($infrastructure.ManagedServers.Count)" -ForegroundColor White
        Write-Host "  Proxy Servers: $($infrastructure.ProxyServers.Count)" -ForegroundColor Cyan
        Write-Host "  Repository Servers: $($infrastructure.RepositoryServers.Count)" -ForegroundColor Green
        Write-Host "  WAN Accelerators: $($infrastructure.WANAccelerators.Count)" -ForegroundColor Yellow
        
        return $infrastructure
    }
    catch {
        Write-MCPLog "Error retrieving infrastructure: $_" -Level Error
        return $null
    }
}

function Get-VBRCapacityMCP {
    Write-MCPLog "Calculating VBR Capacity Metrics..." -Level Info
    
    try {
        $capacity = @{
            Repositories = @()
            TotalCapacity = 0
            UsedCapacity = 0
            FreeCapacity = 0
            BackupSize = 0
            SourceSize = 0
            CompressionRatio = 0
            DeduplicationRatio = 0
        }
        
        # Repository capacity
        $repos = Get-VBRBackupRepository
        foreach ($repo in $repos) {
            try {
                $totalSpace = $repo.GetContainer().CachedTotalSpace / 1GB
                $freeSpace = $repo.GetContainer().CachedFreeSpace / 1GB
                
                $capacity.TotalCapacity += $totalSpace
                $capacity.FreeCapacity += $freeSpace
                $capacity.UsedCapacity += ($totalSpace - $freeSpace)
                
                $capacity.Repositories += [PSCustomObject]@{
                    Name = $repo.Name
                    TotalGB = [math]::Round($totalSpace, 2)
                    FreeGB = [math]::Round($freeSpace, 2)
                    UsedGB = [math]::Round($totalSpace - $freeSpace, 2)
                    UsedPercent = [math]::Round((($totalSpace - $freeSpace) / $totalSpace) * 100, 2)
                }
            }
            catch {
                # Skip repositories that don't support capacity queries
            }
        }
        
        # Backup size calculations
        $jobs = Get-VBRJob
        foreach ($job in $jobs) {
            $capacity.SourceSize += $job.Info.IncludedSize
            $capacity.BackupSize += $job.Info.BackupSize
        }
        
        $capacity.SourceSize = [math]::Round($capacity.SourceSize / 1GB, 2)
        $capacity.BackupSize = [math]::Round($capacity.BackupSize / 1GB, 2)
        
        if ($capacity.SourceSize -gt 0) {
            $capacity.CompressionRatio = [math]::Round($capacity.SourceSize / $capacity.BackupSize, 2)
        }
        
        $capacity.TotalCapacity = [math]::Round($capacity.TotalCapacity, 2)
        $capacity.FreeCapacity = [math]::Round($capacity.FreeCapacity, 2)
        $capacity.UsedCapacity = [math]::Round($capacity.UsedCapacity, 2)
        
        $mcpResults.Results.Capacity = $capacity
        Export-MCPData -Data $capacity.Repositories -Name "VBR-Capacity-Repositories"
        Export-MCPData -Data $capacity -Name "VBR-Capacity-Summary"
        
        Write-Host "`n=== VBR Capacity Summary ===" -ForegroundColor Magenta
        Write-Host "  Total Repository Capacity: $($capacity.TotalCapacity) GB" -ForegroundColor White
        Write-Host "  Used Capacity: $($capacity.UsedCapacity) GB" -ForegroundColor Yellow
        Write-Host "  Free Capacity: $($capacity.FreeCapacity) GB" -ForegroundColor Green
        Write-Host "  Source Data Size: $($capacity.SourceSize) GB" -ForegroundColor Cyan
        Write-Host "  Backup Data Size: $($capacity.BackupSize) GB" -ForegroundColor Cyan
        Write-Host "  Compression Ratio: $($capacity.CompressionRatio):1" -ForegroundColor Magenta
        
        return $capacity
    }
    catch {
        Write-MCPLog "Error calculating capacity: $_" -Level Error
        return $null
    }
}

function Get-VBRHealthMCP {
    Write-MCPLog "Analyzing VBR Health Status..." -Level Info
    
    try {
        $health = @{
            OverallStatus = "Healthy"
            Issues = @()
            Warnings = @()
            Metrics = @{
                FailedJobs = 0
                WarningJobs = 0
                DisabledJobs = 0
                UnavailableRepos = 0
                LowSpaceRepos = 0
                OldRestorePoints = 0
            }
        }
        
        # Check job health
        $jobs = Get-VBRJob
        foreach ($job in $jobs) {
            $lastResult = $job.GetLastResult()
            
            if (-not $job.IsScheduleEnabled) {
                $health.Metrics.DisabledJobs++
                $health.Warnings += "Job '$($job.Name)' is disabled"
            }
            
            if ($lastResult -eq "Failed") {
                $health.Metrics.FailedJobs++
                $health.Issues += "Job '$($job.Name)' failed on last run"
                $health.OverallStatus = "Critical"
            }
            elseif ($lastResult -eq "Warning") {
                $health.Metrics.WarningJobs++
                $health.Warnings += "Job '$($job.Name)' completed with warnings"
                if ($health.OverallStatus -eq "Healthy") {
                    $health.OverallStatus = "Warning"
                }
            }
        }
        
        # Check repository health
        $repos = Get-VBRBackupRepository
        foreach ($repo in $repos) {
            if ($repo.IsUnavailable) {
                $health.Metrics.UnavailableRepos++
                $health.Issues += "Repository '$($repo.Name)' is unavailable"
                $health.OverallStatus = "Critical"
            }
            
            try {
                $totalSpace = $repo.GetContainer().CachedTotalSpace
                $freeSpace = $repo.GetContainer().CachedFreeSpace
                $usedPercent = (($totalSpace - $freeSpace) / $totalSpace) * 100
                
                if ($usedPercent -gt 90) {
                    $health.Metrics.LowSpaceRepos++
                    $health.Warnings += "Repository '$($repo.Name)' is $([math]::Round($usedPercent, 2))% full"
                    if ($health.OverallStatus -eq "Healthy") {
                        $health.OverallStatus = "Warning"
                    }
                }
            }
            catch {
                # Skip capacity check for unsupported repo types
            }
        }
        
        # Check for old restore points (>30 days since last backup)
        $restorePoints = Get-VBRRestorePoint
        $vmLastBackup = @{}
        
        foreach ($rp in $restorePoints) {
            if (-not $vmLastBackup.ContainsKey($rp.VmName) -or $rp.CreationTime -gt $vmLastBackup[$rp.VmName]) {
                $vmLastBackup[$rp.VmName] = $rp.CreationTime
            }
        }
        
        $threshold = (Get-Date).AddDays(-30)
        foreach ($vm in $vmLastBackup.Keys) {
            if ($vmLastBackup[$vm] -lt $threshold) {
                $health.Metrics.OldRestorePoints++
                $health.Warnings += "VM '$vm' has not been backed up in 30+ days"
                if ($health.OverallStatus -eq "Healthy") {
                    $health.OverallStatus = "Warning"
                }
            }
        }
        
        $mcpResults.Results.Health = $health
        Export-MCPData -Data $health -Name "VBR-Health"
        
        Write-Host "`n=== VBR Health Status ===" -ForegroundColor Magenta
        $statusColor = switch ($health.OverallStatus) {
            "Healthy" { "Green" }
            "Warning" { "Yellow" }
            "Critical" { "Red" }
        }
        Write-Host "  Overall Status: $($health.OverallStatus)" -ForegroundColor $statusColor
        Write-Host "`n  Issues Found: $($health.Issues.Count)" -ForegroundColor Red
        Write-Host "  Warnings Found: $($health.Warnings.Count)" -ForegroundColor Yellow
        Write-Host "`n  Failed Jobs: $($health.Metrics.FailedJobs)" -ForegroundColor Red
        Write-Host "  Warning Jobs: $($health.Metrics.WarningJobs)" -ForegroundColor Yellow
        Write-Host "  Disabled Jobs: $($health.Metrics.DisabledJobs)" -ForegroundColor Gray
        Write-Host "  Unavailable Repos: $($health.Metrics.UnavailableRepos)" -ForegroundColor Red
        Write-Host "  Low Space Repos: $($health.Metrics.LowSpaceRepos)" -ForegroundColor Yellow
        
        if ($health.Issues.Count -gt 0) {
            Write-Host "`n  Critical Issues:" -ForegroundColor Red
            $health.Issues | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        }
        
        if ($health.Warnings.Count -gt 0) {
            Write-Host "`n  Warnings:" -ForegroundColor Yellow
            $health.Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
        }
        
        return $health
    }
    catch {
        Write-MCPLog "Error analyzing health: $_" -Level Error
        return $null
    }
}

#endregion

#region Main Execution

try {
    Write-Host "`n" + ("="*80) -ForegroundColor Cyan
    Write-Host "  VEEAM BACKUP & REPLICATION v13 - MCP DEMO SCRIPT" -ForegroundColor Cyan
    Write-Host ("="*80) + "`n" -ForegroundColor Cyan
    
    # Connect to VBR Server
    if (-not (Connect-VBRServerMCP)) {
        throw "Failed to connect to VBR server. Exiting."
    }
    
    Write-Host "`n"
    
    # Execute requested actions
    switch ($Action) {
        "All" {
            Get-VBRServerInfoMCP
            Get-VBRJobsMCP
            Get-VBRRepositoriesMCP
            Get-VBRRestorePointsMCP
            Get-VBRSessionsMCP
            Get-VBRInfrastructureMCP
            Get-VBRCapacityMCP
            Get-VBRHealthMCP
        }
        "ServerInfo" { Get-VBRServerInfoMCP }
        "Jobs" { Get-VBRJobsMCP }
        "Repositories" { Get-VBRRepositoriesMCP }
        "RestorePoints" { Get-VBRRestorePointsMCP }
        "Sessions" { Get-VBRSessionsMCP }
        "Infrastructure" { Get-VBRInfrastructureMCP }
        "Capacity" { Get-VBRCapacityMCP }
        "Health" { Get-VBRHealthMCP }
        "Backup" {
            Write-MCPLog "Backup operation requires additional implementation for specific VM/workload" -Level Warning
        }
        "Restore" {
            Write-MCPLog "Restore operation requires additional implementation for specific restore scenario" -Level Warning
        }
    }
    
    # Export consolidated results
    $mcpResults.Results.Summary = @{
        TotalJobs = ($mcpResults.Results.Jobs | Measure-Object).Count
        TotalRepositories = ($mcpResults.Results.Repositories | Measure-Object).Count
        TotalRestorePoints = ($mcpResults.Results.RestorePoints | Measure-Object).Count
        OverallHealth = $mcpResults.Results.Health.OverallStatus
        ExecutionTime = (Get-Date) - [datetime]$timestamp
    }
    
    $summaryPath = Join-Path $runPath "VBR-MCP-Summary.json"
    $mcpResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding UTF8
    
    Write-Host "`n" + ("="*80) -ForegroundColor Cyan
    Write-Host "  MCP DEMO COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-Host ("="*80) -ForegroundColor Cyan
    Write-Host "`n  Output Location: $runPath" -ForegroundColor White
    Write-Host "`n"
}
catch {
    Write-MCPLog "Script execution failed: $_" -Level Error
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}
finally {
    # Cleanup
    Disconnect-VBRServerMCP
}

#endregion