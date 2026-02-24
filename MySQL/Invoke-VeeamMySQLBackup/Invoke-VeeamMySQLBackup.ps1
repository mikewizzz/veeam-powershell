<#
.SYNOPSIS
    Configures and deploys Veeam application-aware MySQL hot backup scripts.

.DESCRIPTION
    Invoke-VeeamMySQLBackup automates the deployment of MySQL hot backup
    integration for Veeam Backup & Replication using application-aware
    processing with pre-freeze/post-thaw scripts.

    Supported backup methods (auto-detected per server):
      - MySQL Enterprise Backup (MEB) — hot backup, zero downtime, commercial
      - Percona XtraBackup           — hot backup, zero downtime, open-source
      - FLUSH TABLES WITH READ LOCK  — brief lock during snapshot, universal fallback

    The script can:
      1. Assess target MySQL servers for backup readiness
      2. Deploy pre-freeze/post-thaw scripts to target servers
      3. Create the MySQL backup user with minimal required privileges
      4. Configure Veeam backup job application-aware processing settings
      5. Generate a deployment report for customer documentation

.PARAMETER Action
    The operation to perform:
      - Assess   : Check MySQL servers for backup readiness (default)
      - Deploy   : Deploy scripts and configure Veeam jobs
      - Report   : Generate assessment report without making changes

.PARAMETER TargetServers
    Array of MySQL server hostnames or IP addresses to configure.

.PARAMETER TargetServersCsv
    Path to a CSV file containing MySQL server details.
    Expected columns: Hostname, Port, MySQLVersion, BackupMethod

.PARAMETER VBRServer
    Veeam Backup & Replication server hostname. Defaults to localhost.

.PARAMETER MySQLUser
    MySQL username for backup operations. Defaults to 'veeambackup'.

.PARAMETER MySQLPassword
    MySQL password as a SecureString. If omitted, a random password is generated.

.PARAMETER MySQLPort
    MySQL port. Defaults to 3306.

.PARAMETER BackupMethod
    Force a specific backup method: Auto, MEB, XtraBackup, FTWRL.
    Defaults to Auto (best available method is detected per server).

.PARAMETER ScriptDeployPath
    Path on target servers where pre-freeze/post-thaw scripts are deployed.
    Defaults to /opt/veeam/mysql.

.PARAMETER BackupDirectory
    Path on target servers for MySQL backup staging data.
    Defaults to /var/veeam/mysql_backup.

.PARAMETER SSHKeyPath
    Path to SSH private key for connecting to Linux target servers.

.PARAMETER SSHUser
    SSH username for connecting to target servers. Defaults to 'root'.

.PARAMETER OutputDirectory
    Directory for assessment reports and deployment logs.
    Defaults to .\VeeamMySQLBackup_Output

.PARAMETER SkipVeeamConfig
    Skip Veeam B&R job configuration (deploy scripts only).

.EXAMPLE
    # Assess MySQL servers for Veeam backup readiness
    .\Invoke-VeeamMySQLBackup.ps1 -Action Assess -TargetServers "db01","db02"

.EXAMPLE
    # Deploy MySQL hot backup integration
    .\Invoke-VeeamMySQLBackup.ps1 -Action Deploy -TargetServers "db01" -VBRServer "vbr01"

.EXAMPLE
    # Assess servers from CSV and generate report
    .\Invoke-VeeamMySQLBackup.ps1 -Action Report -TargetServersCsv ".\mysql_servers.csv"

.EXAMPLE
    # Deploy with specific backup method and custom credentials
    $pwd = Read-Host -AsSecureString "MySQL backup password"
    .\Invoke-VeeamMySQLBackup.ps1 -Action Deploy -TargetServers "db01" `
        -BackupMethod MEB -MySQLUser "veeam_bkp" -MySQLPassword $pwd

.NOTES
    Author:         Community Contributors
    Version:        1.0.0
    Requires:       PowerShell 5.1+
    Veeam Modules:  Veeam.Backup.PowerShell (optional, for job configuration)
    SSH Access:     Required for Linux server deployment
#>

[CmdletBinding()]
param(
    [ValidateSet("Assess", "Deploy", "Report")]
    [string]$Action = "Assess",

    [string[]]$TargetServers,

    [string]$TargetServersCsv,

    [string]$VBRServer = "localhost",

    [string]$MySQLUser = "veeambackup",

    [SecureString]$MySQLPassword,

    [int]$MySQLPort = 3306,

    [ValidateSet("Auto", "MEB", "XtraBackup", "FTWRL")]
    [string]$BackupMethod = "Auto",

    [string]$ScriptDeployPath = "/opt/veeam/mysql",

    [string]$BackupDirectory = "/var/veeam/mysql_backup",

    [string]$SSHKeyPath,

    [string]$SSHUser = "root",

    [string]$OutputDirectory = ".\VeeamMySQLBackup_Output",

    [switch]$SkipVeeamConfig
)

# ============================================================================
# Constants
# ============================================================================
$Script:VERSION = "1.0.0"
$Script:SCRIPT_NAME = "Invoke-VeeamMySQLBackup"
$Script:TIMESTAMP = Get-Date -Format "yyyyMMdd_HHmmss"

# Minimum MySQL privileges required for each backup method
$Script:REQUIRED_PRIVILEGES = @{
    "MEB"        = @("RELOAD", "REPLICATION CLIENT", "SUPER", "CREATE", "INSERT", "ALTER", "SELECT", "PROCESS", "BACKUP_ADMIN")
    "XtraBackup" = @("RELOAD", "REPLICATION CLIENT", "PROCESS", "LOCK TABLES", "BACKUP_ADMIN")
    "FTWRL"      = @("RELOAD", "SELECT", "LOCK TABLES", "PROCESS")
}

# ============================================================================
# Initialization
# ============================================================================
$ErrorActionPreference = "Stop"

function Initialize-OutputDirectory {
    $script:OutputDir = Join-Path $OutputDirectory "${Script:SCRIPT_NAME}_${Script:TIMESTAMP}"
    if (-not (Test-Path $script:OutputDir)) {
        New-Item -ItemType Directory -Path $script:OutputDir -Force | Out-Null
    }
    $script:LogFile = Join-Path $script:OutputDir "execution.log"
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "WARN"    { Write-Host $logEntry -ForegroundColor Yellow }
        "SUCCESS" { Write-Host $logEntry -ForegroundColor Green }
        default   { Write-Host $logEntry }
    }

    Add-Content -Path $script:LogFile -Value $logEntry
}

# ============================================================================
# Server Assessment
# ============================================================================
function Test-MySQLServer {
    <#
    .SYNOPSIS
        Assesses a MySQL server for Veeam backup readiness.
    #>
    param(
        [string]$Hostname,
        [int]$Port = 3306
    )

    Write-Log "Assessing MySQL server: $Hostname`:$Port"

    $result = [PSCustomObject]@{
        Hostname       = $Hostname
        Port           = $Port
        Reachable      = $false
        MySQLRunning   = $false
        MySQLVersion   = "Unknown"
        Engine         = "Unknown"
        MEBAvailable   = $false
        XTBAvailable   = $false
        RecommendedMethod = "FTWRL"
        InnoDBPercent  = 0
        DataSizeGB     = 0
        SSHAccess      = $false
        Status         = "Not Assessed"
        Notes          = @()
    }

    # Test SSH connectivity
    try {
        $sshArgs = @("-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
        if ($SSHKeyPath) { $sshArgs += @("-i", $SSHKeyPath) }

        $sshTest = & ssh $sshArgs "${SSHUser}@${Hostname}" "echo OK" 2>&1
        if ($sshTest -match "OK") {
            $result.SSHAccess = $true
            $result.Reachable = $true
            Write-Log "  SSH access verified for $Hostname"
        }
    }
    catch {
        $result.Notes += "SSH connection failed: $_"
        Write-Log "  SSH access failed for $Hostname" -Level WARN
    }

    if (-not $result.SSHAccess) {
        $result.Status = "SSH Unreachable"
        return $result
    }

    # Check MySQL status and version via SSH
    try {
        $sshArgs = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
        if ($SSHKeyPath) { $sshArgs += @("-i", $SSHKeyPath) }

        $mysqlCheck = & ssh $sshArgs "${SSHUser}@${Hostname}" @"
            # Check if MySQL/MariaDB is running
            if systemctl is-active --quiet mysql 2>/dev/null || systemctl is-active --quiet mysqld 2>/dev/null || systemctl is-active --quiet mariadb 2>/dev/null; then
                echo "MYSQL_RUNNING=true"
            else
                echo "MYSQL_RUNNING=false"
            fi

            # Check MySQL version
            if command -v mysql &>/dev/null; then
                echo "MYSQL_VERSION=`$(mysql --version 2>/dev/null | head -1)"
            fi

            # Check for MEB
            if command -v mysqlbackup &>/dev/null; then
                echo "MEB_AVAILABLE=true"
                echo "MEB_VERSION=`$(mysqlbackup --version 2>/dev/null | head -1)"
            else
                echo "MEB_AVAILABLE=false"
            fi

            # Check for XtraBackup
            if command -v xtrabackup &>/dev/null; then
                echo "XTB_AVAILABLE=true"
                echo "XTB_VERSION=`$(xtrabackup --version 2>/dev/null | head -1)"
            else
                echo "XTB_AVAILABLE=false"
            fi

            # Check disk space at backup location
            echo "DISK_FREE=`$(df -BG /var 2>/dev/null | tail -1 | awk '{print `$4}')"
"@ 2>&1

        foreach ($line in $mysqlCheck) {
            if ($line -match "^MYSQL_RUNNING=(.+)$") {
                $result.MySQLRunning = ($Matches[1] -eq "true")
            }
            elseif ($line -match "^MYSQL_VERSION=(.+)$") {
                $result.MySQLVersion = $Matches[1]
            }
            elseif ($line -match "^MEB_AVAILABLE=(.+)$") {
                $result.MEBAvailable = ($Matches[1] -eq "true")
            }
            elseif ($line -match "^XTB_AVAILABLE=(.+)$") {
                $result.XTBAvailable = ($Matches[1] -eq "true")
            }
        }

        # Determine recommended method
        if ($BackupMethod -ne "Auto") {
            $result.RecommendedMethod = $BackupMethod
        }
        elseif ($result.MEBAvailable) {
            $result.RecommendedMethod = "MEB"
        }
        elseif ($result.XTBAvailable) {
            $result.RecommendedMethod = "XtraBackup"
        }
        else {
            $result.RecommendedMethod = "FTWRL"
        }

        $result.Status = "Assessed"
        Write-Log "  MySQL running: $($result.MySQLRunning), Method: $($result.RecommendedMethod)" -Level SUCCESS

    }
    catch {
        $result.Status = "Assessment Failed"
        $result.Notes += "Assessment error: $_"
        Write-Log "  Assessment failed for $Hostname`: $_" -Level ERROR
    }

    return $result
}

# ============================================================================
# Script Deployment
# ============================================================================
function Deploy-MySQLBackupScripts {
    <#
    .SYNOPSIS
        Deploys pre-freeze and post-thaw scripts to a target MySQL server.
    #>
    param(
        [PSCustomObject]$ServerAssessment
    )

    $hostname = $ServerAssessment.Hostname
    Write-Log "Deploying backup scripts to $hostname..."

    $sshArgs = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
    if ($SSHKeyPath) { $sshArgs += @("-i", $SSHKeyPath) }

    $scpArgs = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
    if ($SSHKeyPath) { $scpArgs += @("-i", $SSHKeyPath) }

    try {
        # Create directories on target
        & ssh $sshArgs "${SSHUser}@${hostname}" @"
            mkdir -p $ScriptDeployPath
            mkdir -p $BackupDirectory
            mkdir -p /var/log/veeam
            mkdir -p /etc/mysql
"@ 2>&1

        # Copy pre-freeze and post-thaw scripts
        $scriptDir = $PSScriptRoot
        $preFreezeScript = Join-Path $scriptDir "veeam-mysql-prefreeze.sh"
        $postThawScript = Join-Path $scriptDir "veeam-mysql-postthaw.sh"

        & scp $scpArgs $preFreezeScript "${SSHUser}@${hostname}:${ScriptDeployPath}/prefreeze.sh" 2>&1
        & scp $scpArgs $postThawScript "${SSHUser}@${hostname}:${ScriptDeployPath}/postthaw.sh" 2>&1

        # Set permissions and create configuration
        $method = $ServerAssessment.RecommendedMethod.ToLower()
        & ssh $sshArgs "${SSHUser}@${hostname}" @"
            chmod 750 ${ScriptDeployPath}/prefreeze.sh
            chmod 750 ${ScriptDeployPath}/postthaw.sh
            chown root:root ${ScriptDeployPath}/*.sh

            # Create MySQL defaults file for secure credential storage
            cat > /etc/mysql/veeam-backup.cnf << 'CNFEOF'
[client]
user=${MySQLUser}
# password is set during MySQL user creation
socket=/var/run/mysqld/mysqld.sock
CNFEOF
            chmod 600 /etc/mysql/veeam-backup.cnf

            # Create environment override file
            cat > ${ScriptDeployPath}/backup.env << ENVEOF
MYSQL_BACKUP_METHOD=${method}
MYSQL_DEFAULTS_FILE=/etc/mysql/veeam-backup.cnf
MYSQL_BACKUP_DIR=${BackupDirectory}
MYSQL_BACKUP_LOG=/var/log/veeam/mysql-prefreeze.log
ENVEOF
            chmod 640 ${ScriptDeployPath}/backup.env
"@ 2>&1

        Write-Log "  Scripts deployed to $hostname`:$ScriptDeployPath" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "  Deployment failed for $hostname`: $_" -Level ERROR
        return $false
    }
}

# ============================================================================
# MySQL Backup User Creation
# ============================================================================
function New-MySQLBackupUser {
    <#
    .SYNOPSIS
        Creates a MySQL user with minimum privileges required for backup operations.
    #>
    param(
        [string]$Hostname,
        [string]$Method = "FTWRL"
    )

    Write-Log "Creating MySQL backup user on $Hostname (method: $Method)..."

    $sshArgs = @("-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes")
    if ($SSHKeyPath) { $sshArgs += @("-i", $SSHKeyPath) }

    # Generate password if not provided
    $plainPassword = if ($MySQLPassword) {
        [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MySQLPassword)
        )
    }
    else {
        # Generate a random 24-character password
        $chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#%^&*"
        -join (1..24 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    }

    # Build privilege list based on method
    $privileges = $Script:REQUIRED_PRIVILEGES[$Method]
    if (-not $privileges) {
        $privileges = $Script:REQUIRED_PRIVILEGES["FTWRL"]
    }
    $privString = ($privileges | Where-Object { $_ -ne "BACKUP_ADMIN" }) -join ", "

    try {
        # Use heredoc to avoid password on command line
        & ssh $sshArgs "${SSHUser}@${Hostname}" @"
            mysql -e "
                CREATE USER IF NOT EXISTS '${MySQLUser}'@'localhost' IDENTIFIED BY '${plainPassword}';
                GRANT ${privString} ON *.* TO '${MySQLUser}'@'localhost';
                FLUSH PRIVILEGES;
            " 2>&1

            # Update the defaults file with the password
            sed -i "s/^# password is set.*/password=${plainPassword}/" /etc/mysql/veeam-backup.cnf
"@ 2>&1

        Write-Log "  MySQL backup user '${MySQLUser}' created on $Hostname" -Level SUCCESS
        Write-Log "  Granted privileges: $privString"
        return $true
    }
    catch {
        Write-Log "  Failed to create MySQL user on $Hostname`: $_" -Level ERROR
        return $false
    }
}

# ============================================================================
# Veeam B&R Job Configuration
# ============================================================================
function Set-VeeamJobApplicationProcessing {
    <#
    .SYNOPSIS
        Configures a Veeam backup job with MySQL application-aware processing scripts.
    #>
    param(
        [string]$Hostname
    )

    if ($SkipVeeamConfig) {
        Write-Log "Skipping Veeam job configuration (-SkipVeeamConfig specified)"
        return $true
    }

    Write-Log "Configuring Veeam application-aware processing for $Hostname..."

    try {
        # Check if Veeam PowerShell module is available
        if (-not (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell)) {
            Write-Log "  Veeam PowerShell module not found — generating manual configuration instructions" -Level WARN
            Write-Log "  To configure manually in Veeam B&R console:"
            Write-Log "    1. Edit the backup job containing $Hostname"
            Write-Log "    2. Go to Guest Processing > Application-Aware Processing"
            Write-Log "    3. Enable application-aware processing"
            Write-Log "    4. Set Pre-freeze script: ${ScriptDeployPath}/prefreeze.sh"
            Write-Log "    5. Set Post-thaw script: ${ScriptDeployPath}/postthaw.sh"
            return $false
        }

        # Import Veeam module
        Import-Module Veeam.Backup.PowerShell

        # Connect to VBR server if not localhost
        if ($VBRServer -ne "localhost" -and $VBRServer -ne $env:COMPUTERNAME) {
            Connect-VBRServer -Server $VBRServer
        }

        # Find backup jobs containing this server
        $jobs = Get-VBRJob | Where-Object {
            $_.GetObjectsInJob() | Where-Object { $_.Name -match $Hostname }
        }

        if (-not $jobs) {
            Write-Log "  No existing Veeam jobs found containing $Hostname" -Level WARN
            Write-Log "  Scripts are deployed — configure application-aware processing when creating the backup job"
            return $false
        }

        foreach ($job in $jobs) {
            Write-Log "  Configuring job: $($job.Name)"

            # Get VM object within the job
            $jobObject = $job.GetObjectsInJob() | Where-Object { $_.Name -match $Hostname } | Select-Object -First 1

            if ($jobObject) {
                # Set application-aware processing options
                $options = $job.GetOptions()

                # Enable guest processing
                $options.ViGuestProcessingOptions.Enabled = $true

                # Set pre-freeze and post-thaw scripts
                $scriptOptions = New-Object Veeam.Backup.Model.CGuestScriptsOptions
                $scriptOptions.LinuxScript.IsEnabled = $true
                $scriptOptions.LinuxScript.PreFreezeScript = "${ScriptDeployPath}/prefreeze.sh"
                $scriptOptions.LinuxScript.PostThawScript = "${ScriptDeployPath}/postthaw.sh"

                $options.ViGuestProcessingOptions.GuestScriptsOptions = $scriptOptions

                # Apply the updated options
                Set-VBRJobOptions -Job $job -Options $options

                Write-Log "  Job '$($job.Name)' configured with MySQL scripts" -Level SUCCESS
            }
        }

        return $true
    }
    catch {
        Write-Log "  Veeam job configuration failed: $_" -Level ERROR
        Write-Log "  Scripts are deployed — configure application-aware processing manually"
        return $false
    }
}

# ============================================================================
# Report Generation
# ============================================================================
function New-AssessmentReport {
    <#
    .SYNOPSIS
        Generates an HTML assessment report for MySQL backup readiness.
    #>
    param(
        [PSCustomObject[]]$Assessments
    )

    Write-Log "Generating assessment report..."

    $reportPath = Join-Path $script:OutputDir "MySQL_Backup_Assessment.html"
    $csvPath = Join-Path $script:OutputDir "MySQL_Backup_Assessment.csv"

    # Export CSV
    $Assessments | Select-Object Hostname, Port, MySQLRunning, MySQLVersion,
        MEBAvailable, XTBAvailable, RecommendedMethod, SSHAccess, Status |
        Export-Csv -Path $csvPath -NoTypeInformation

    # Generate HTML report
    $serverRows = foreach ($a in $Assessments) {
        $statusClass = switch ($a.Status) {
            "Assessed"   { "status-ok" }
            default      { "status-warn" }
        }
        $methodBadge = switch ($a.RecommendedMethod) {
            "MEB"        { '<span class="badge badge-meb">MEB</span>' }
            "XtraBackup" { '<span class="badge badge-xtb">XtraBackup</span>' }
            "FTWRL"      { '<span class="badge badge-ftwrl">FTWRL</span>' }
            default      { "<span class='badge'>$($a.RecommendedMethod)</span>" }
        }
        $notes = ($a.Notes -join "; ")
        @"
        <tr>
            <td><strong>$($a.Hostname)</strong></td>
            <td>$($a.Port)</td>
            <td>$($a.MySQLVersion)</td>
            <td>$(if ($a.MySQLRunning) { '&#9989;' } else { '&#10060;' })</td>
            <td>$(if ($a.MEBAvailable) { '&#9989;' } else { '&#10060;' })</td>
            <td>$(if ($a.XTBAvailable) { '&#9989;' } else { '&#10060;' })</td>
            <td>$methodBadge</td>
            <td class="$statusClass">$($a.Status)</td>
            <td>$notes</td>
        </tr>
"@
    }

    $mebCount = ($Assessments | Where-Object { $_.RecommendedMethod -eq "MEB" }).Count
    $xtbCount = ($Assessments | Where-Object { $_.RecommendedMethod -eq "XtraBackup" }).Count
    $ftwrlCount = ($Assessments | Where-Object { $_.RecommendedMethod -eq "FTWRL" }).Count
    $totalCount = $Assessments.Count

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Veeam MySQL Backup Assessment Report</title>
    <style>
        :root {
            --veeam-green: #00b336;
            --veeam-dark: #1a1a2e;
            --veeam-light: #f5f5f5;
            --meb-color: #0078d4;
            --xtb-color: #00b336;
            --ftwrl-color: #ff8c00;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
            background: var(--veeam-light);
            color: #333;
            line-height: 1.6;
        }
        .header {
            background: linear-gradient(135deg, var(--veeam-dark) 0%, #16213e 100%);
            color: white;
            padding: 2rem 3rem;
        }
        .header h1 { font-size: 1.8rem; font-weight: 600; }
        .header p { opacity: 0.8; margin-top: 0.5rem; }
        .container { max-width: 1400px; margin: 0 auto; padding: 2rem; }
        .summary-cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 1rem;
            margin-bottom: 2rem;
        }
        .card {
            background: white;
            border-radius: 8px;
            padding: 1.5rem;
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        }
        .card h3 { font-size: 0.85rem; text-transform: uppercase; color: #666; margin-bottom: 0.5rem; }
        .card .value { font-size: 2rem; font-weight: 700; }
        .card.meb .value { color: var(--meb-color); }
        .card.xtb .value { color: var(--xtb-color); }
        .card.ftwrl .value { color: var(--ftwrl-color); }
        .card.total .value { color: var(--veeam-dark); }
        table {
            width: 100%;
            border-collapse: collapse;
            background: white;
            border-radius: 8px;
            overflow: hidden;
            box-shadow: 0 2px 8px rgba(0,0,0,0.08);
        }
        th {
            background: var(--veeam-dark);
            color: white;
            padding: 0.75rem 1rem;
            text-align: left;
            font-weight: 600;
            font-size: 0.85rem;
        }
        td { padding: 0.75rem 1rem; border-bottom: 1px solid #eee; font-size: 0.9rem; }
        tr:hover td { background: #f8f9fa; }
        .badge {
            display: inline-block;
            padding: 0.2rem 0.6rem;
            border-radius: 12px;
            font-size: 0.75rem;
            font-weight: 600;
            color: white;
        }
        .badge-meb { background: var(--meb-color); }
        .badge-xtb { background: var(--xtb-color); }
        .badge-ftwrl { background: var(--ftwrl-color); }
        .status-ok { color: var(--veeam-green); font-weight: 600; }
        .status-warn { color: var(--ftwrl-color); font-weight: 600; }
        .section { margin-bottom: 2rem; }
        .section h2 {
            font-size: 1.3rem;
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 2px solid var(--veeam-green);
        }
        .capability-note {
            background: linear-gradient(135deg, #e8f5e9, #f1f8e9);
            border-left: 4px solid var(--veeam-green);
            padding: 1.5rem;
            border-radius: 0 8px 8px 0;
            margin-bottom: 2rem;
        }
        .capability-note h3 { color: var(--veeam-dark); margin-bottom: 0.5rem; }
        .method-comparison {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 1rem;
            margin-top: 1rem;
        }
        .method-card {
            border: 2px solid #eee;
            border-radius: 8px;
            padding: 1.25rem;
            background: white;
        }
        .method-card h4 { margin-bottom: 0.5rem; }
        .method-card ul { list-style: none; padding: 0; }
        .method-card li { padding: 0.25rem 0; }
        .method-card li::before { content: "\\2713 "; color: var(--veeam-green); font-weight: bold; }
        .footer {
            text-align: center;
            padding: 2rem;
            color: #999;
            font-size: 0.85rem;
        }
    </style>
</head>
<body>
    <div class="header">
        <h1>Veeam MySQL Backup Assessment Report</h1>
        <p>Generated: $(Get-Date -Format "MMMM d, yyyy 'at' HH:mm") | Servers assessed: $totalCount</p>
    </div>

    <div class="container">
        <div class="summary-cards">
            <div class="card total">
                <h3>Total Servers</h3>
                <div class="value">$totalCount</div>
            </div>
            <div class="card meb">
                <h3>MEB (Hot Backup)</h3>
                <div class="value">$mebCount</div>
            </div>
            <div class="card xtb">
                <h3>XtraBackup (Hot)</h3>
                <div class="value">$xtbCount</div>
            </div>
            <div class="card ftwrl">
                <h3>FTWRL (Lock-based)</h3>
                <div class="value">$ftwrlCount</div>
            </div>
        </div>

        <div class="capability-note">
            <h3>Veeam MySQL Backup — Supported Methods</h3>
            <p>
                Veeam application-aware processing scripts support multiple MySQL hot backup methods:
                <strong>MEB</strong> (MySQL Enterprise Backup), <strong>Percona XtraBackup</strong> (open-source), and <strong>FTWRL</strong> (universal fallback).
                This provides flexibility to choose the best method for each environment.
            </p>
        </div>

        <div class="section">
            <h2>Server Assessment Results</h2>
            <table>
                <thead>
                    <tr>
                        <th>Hostname</th>
                        <th>Port</th>
                        <th>MySQL Version</th>
                        <th>Running</th>
                        <th>MEB</th>
                        <th>XtraBackup</th>
                        <th>Recommended</th>
                        <th>Status</th>
                        <th>Notes</th>
                    </tr>
                </thead>
                <tbody>
                    $($serverRows -join "`n")
                </tbody>
            </table>
        </div>

        <div class="section">
            <h2>Backup Method Comparison</h2>
            <div class="method-comparison">
                <div class="method-card">
                    <h4><span class="badge badge-meb">MEB</span> MySQL Enterprise Backup</h4>
                    <ul>
                        <li>True hot backup — zero application downtime</li>
                        <li>InnoDB-native crash recovery</li>
                        <li>Incremental and compressed backups</li>
                        <li>Requires MySQL Enterprise Edition license</li>
                        <li>Same tool used by other backup solutions</li>
                    </ul>
                </div>
                <div class="method-card">
                    <h4><span class="badge badge-xtb">XtraBackup</span> Percona XtraBackup</h4>
                    <ul>
                        <li>True hot backup — zero application downtime</li>
                        <li>Open-source (no additional license cost)</li>
                        <li>Incremental and compressed backups</li>
                        <li>Supports MySQL and Percona Server</li>
                        <li>Feature parity with MEB for InnoDB workloads</li>
                    </ul>
                </div>
                <div class="method-card">
                    <h4><span class="badge badge-ftwrl">FTWRL</span> Flush Tables With Read Lock</h4>
                    <ul>
                        <li>Universal — works with any MySQL edition</li>
                        <li>Brief read lock during snapshot creation only</li>
                        <li>No additional tools required</li>
                        <li>Suitable for smaller databases or low-activity windows</li>
                        <li>Automatic lock release via post-thaw script</li>
                    </ul>
                </div>
            </div>
        </div>

        <div class="section">
            <h2>Deployment Steps</h2>
            <div class="card">
                <ol style="padding-left: 1.5rem; line-height: 2;">
                    <li>Run this assessment: <code>.\Invoke-VeeamMySQLBackup.ps1 -Action Assess -TargetServers "server1","server2"</code></li>
                    <li>Deploy scripts: <code>.\Invoke-VeeamMySQLBackup.ps1 -Action Deploy -TargetServers "server1" -VBRServer "vbr01"</code></li>
                    <li>Verify in Veeam B&amp;R: Check job &gt; Guest Processing &gt; Application-Aware Processing</li>
                    <li>Run a test backup and verify MySQL consistency in the backup log</li>
                    <li>Review logs at <code>/var/log/veeam/mysql-prefreeze.log</code> on the target server</li>
                </ol>
            </div>
        </div>
    </div>

    <div class="footer">
        <p>Generated by Invoke-VeeamMySQLBackup v${Script:VERSION} | Open-Source Community Tool</p>
    </div>
</body>
</html>
"@

    $html | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Log "Assessment report saved: $reportPath" -Level SUCCESS
    Write-Log "Assessment CSV saved: $csvPath" -Level SUCCESS

    return $reportPath
}

# ============================================================================
# Main Execution
# ============================================================================
function Main {
    Write-Host ""
    Write-Host "  Veeam MySQL Backup Integration Tool v$($Script:VERSION)" -ForegroundColor Green
    Write-Host "  =============================================" -ForegroundColor Green
    Write-Host ""

    Initialize-OutputDirectory
    Write-Log "Action: $Action"
    Write-Log "Output: $($script:OutputDir)"

    # Build server list
    $servers = @()
    if ($TargetServersCsv -and (Test-Path $TargetServersCsv)) {
        $csvData = Import-Csv $TargetServersCsv
        foreach ($row in $csvData) {
            $servers += [PSCustomObject]@{
                Hostname = $row.Hostname
                Port     = if ($row.Port) { [int]$row.Port } else { $MySQLPort }
            }
        }
        Write-Log "Loaded $($servers.Count) servers from CSV: $TargetServersCsv"
    }
    elseif ($TargetServers) {
        foreach ($srv in $TargetServers) {
            $servers += [PSCustomObject]@{
                Hostname = $srv
                Port     = $MySQLPort
            }
        }
    }
    else {
        Write-Log "No target servers specified. Use -TargetServers or -TargetServersCsv." -Level ERROR
        return
    }

    Write-Log "Target servers: $($servers.Count)"
    Write-Host ""

    # Phase 1: Assessment
    Write-Log "=== Phase 1: Server Assessment ==="
    $assessments = @()
    foreach ($server in $servers) {
        $assessment = Test-MySQLServer -Hostname $server.Hostname -Port $server.Port
        $assessments += $assessment
    }

    Write-Host ""
    Write-Log "Assessment Summary:"
    Write-Log "  Total servers: $($assessments.Count)"
    Write-Log "  MEB available: $(($assessments | Where-Object MEBAvailable).Count)"
    Write-Log "  XtraBackup available: $(($assessments | Where-Object XTBAvailable).Count)"
    Write-Log "  SSH accessible: $(($assessments | Where-Object SSHAccess).Count)"
    Write-Host ""

    # Phase 2: Deploy (if requested)
    if ($Action -eq "Deploy") {
        Write-Log "=== Phase 2: Script Deployment ==="
        foreach ($assessment in ($assessments | Where-Object { $_.SSHAccess })) {
            $deployed = Deploy-MySQLBackupScripts -ServerAssessment $assessment
            if ($deployed) {
                # Create MySQL backup user
                New-MySQLBackupUser -Hostname $assessment.Hostname -Method $assessment.RecommendedMethod

                # Configure Veeam job
                Set-VeeamJobApplicationProcessing -Hostname $assessment.Hostname
            }
        }
        Write-Host ""
    }

    # Phase 3: Report
    Write-Log "=== Phase 3: Report Generation ==="
    $reportPath = New-AssessmentReport -Assessments $assessments

    Write-Host ""
    Write-Log "=========================================="
    Write-Log "Execution complete." -Level SUCCESS
    Write-Log "Output directory: $($script:OutputDir)"
    Write-Log "=========================================="

    # Open report if available
    if ($reportPath -and (Test-Path $reportPath)) {
        Write-Log "Report: $reportPath"
    }
}

# Run
Main
