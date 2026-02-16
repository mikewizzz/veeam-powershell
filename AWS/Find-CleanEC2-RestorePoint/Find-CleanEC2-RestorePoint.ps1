<#
.SYNOPSIS
  VRO Pre-Step: Find the Latest Clean (Malware-Free) Veeam Restore Point

.DESCRIPTION
  Scans Veeam restore points from newest to oldest and identifies the most recent
  one that is verified clean by Veeam's security stack. Designed as a VRO plan
  pre-step that feeds the selected restore point ID into the downstream restore step.

  WHAT THIS SCRIPT DOES:
  1. Connects to Veeam Backup & Replication server
  2. Locates the specified backup (including S3/SOBR-backed repositories)
  3. Enumerates all restore points, sorted newest-first
  4. Checks each point against multiple verification sources:
     a. Veeam Inline Malware Detection results (VBR 12.1+)
     b. SureBackup verification session results
     c. Secure Restore antivirus scan results
     d. Backup session success status (fallback)
  5. Returns the most recent clean restore point ID and metadata
  6. Outputs VRO-compatible JSON for downstream step consumption

  USE CASES:
  - Ransomware recovery: find the last known-good restore point
  - Compliance: ensure only verified backups are used in DR plans
  - VRO orchestration: chain with Restore-VRO-AWS-EC2.ps1 as pre-step

  SECURITY VERIFICATION HIERARCHY:
  1. Inline Malware Detection (highest confidence - real-time scan during backup)
  2. SureBackup Sessions (high confidence - automated verification lab)
  3. Secure Restore Scan (medium confidence - on-demand antivirus scan)
  4. Backup Session Success (low confidence - no malware scan, just job success)

  The script stops at the first verified-clean point and returns it. If no clean
  point is found after checking all available points, the script fails with exit
  code 1 so VRO can halt the recovery plan.

.PARAMETER VBRServer
  Veeam Backup & Replication server hostname or IP. Default: localhost.

.PARAMETER VBRCredential
  PSCredential for VBR authentication. Omit to use integrated Windows auth.

.PARAMETER VBRPort
  VBR server connection port. Default: 9392.

.PARAMETER BackupName
  Name of the Veeam backup job to search for clean restore points.

.PARAMETER VMName
  Specific VM name within the backup. Required for multi-VM backup jobs.

.PARAMETER MaxPointsToScan
  Maximum number of restore points to check before giving up. Default: 14
  (covers two weeks of daily backups). Increase for longer scan windows.

.PARAMETER RequireMalwareScan
  Require a positive malware scan result (inline detection or SureBackup).
  If set, backup session success alone is not sufficient. Use this for
  high-security environments where only scanned points are acceptable.

.PARAMETER MinAge
  Minimum age of restore point in hours. Use to skip very recent points that
  may not yet have completed malware scanning. Default: 0 (no minimum).

.PARAMETER OutputPath
  Output folder for logs. Default: ./CleanPointOutput_<timestamp>.

.PARAMETER VROPlanName
  VRO recovery plan name (passed by VRO for logging context).

.PARAMETER VROStepName
  VRO plan step name (passed by VRO for logging context).

.PARAMETER MaxRetries
  Maximum retry attempts for transient failures. Default: 3.

.PARAMETER RetryBaseDelaySeconds
  Base delay for exponential backoff retries. Default: 2 seconds.

.EXAMPLE
  .\Find-CleanEC2-RestorePoint.ps1 -BackupName "Daily-FileServer"
  # Find latest clean point for the Daily-FileServer backup

.EXAMPLE
  .\Find-CleanEC2-RestorePoint.ps1 -BackupName "SAP-Production" -VMName "SAP-APP01" `
    -RequireMalwareScan -MaxPointsToScan 30
  # Strict mode: require actual malware scan, check up to 30 points

.EXAMPLE
  .\Find-CleanEC2-RestorePoint.ps1 -BackupName "DC-Backup" -MinAge 4
  # Skip points newer than 4 hours (allow time for scan completion)

.NOTES
  Version: 1.0.0
  Author: Community Contributors
  Requires: PowerShell 5.1+ (7.x recommended)
  Modules: Veeam.Backup.PowerShell (VBR 12+)
  VRO Compatibility: Veeam Recovery Orchestrator 7.0+
  VBR Compatibility: Veeam Backup & Replication 12.0+ (12.1+ for inline malware detection)
#>

[CmdletBinding()]
param(
  # ===== VBR Server Connection =====
  [string]$VBRServer = "localhost",
  [PSCredential]$VBRCredential,
  [ValidateRange(1,65535)]
  [int]$VBRPort = 9392,

  # ===== Backup Selection =====
  [Parameter(Mandatory)]
  [string]$BackupName,
  [string]$VMName,

  # ===== Scan Configuration =====
  [ValidateRange(1,365)]
  [int]$MaxPointsToScan = 14,
  [switch]$RequireMalwareScan,
  [ValidateRange(0,720)]
  [int]$MinAge = 0,

  # ===== Output =====
  [string]$OutputPath,

  # ===== VRO Integration =====
  [string]$VROPlanName,
  [string]$VROStepName,

  # ===== Retries =====
  [ValidateRange(1,10)]
  [int]$MaxRetries = 3,
  [ValidateRange(1,30)]
  [int]$RetryBaseDelaySeconds = 2
)

# =============================
# Guardrails & Initialization
# =============================
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$script:StartTime = Get-Date
$script:LogEntries = [System.Collections.Generic.List[object]]::new()
$script:ExitCode = 0
$script:VBRConnected = $false

$stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
if (-not $OutputPath) {
  $OutputPath = Join-Path "." "CleanPointOutput_$stamp"
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

$logFile = Join-Path $OutputPath "CleanPoint-Log-$stamp.txt"
$jsonFile = Join-Path $OutputPath "CleanPoint-Result-$stamp.json"

# =============================
# Logging
# =============================

<#
.SYNOPSIS
  Writes a timestamped, leveled log entry to console and log file.
#>
function Write-Log {
  param(
    [Parameter(Mandatory)][string]$Message,
    [ValidateSet("INFO","WARNING","ERROR","SUCCESS")]
    [string]$Level = "INFO"
  )

  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $entry = [PSCustomObject]@{ Timestamp = $ts; Level = $Level; Message = $Message }
  $script:LogEntries.Add($entry)

  $color = switch ($Level) {
    "INFO"    { "Cyan" }
    "WARNING" { "Yellow" }
    "ERROR"   { "Red" }
    "SUCCESS" { "Green" }
  }

  $line = "[$ts] [$Level] $Message"
  Write-Host $line -ForegroundColor $color
  $line | Add-Content -Path $logFile -Encoding UTF8
}

<#
.SYNOPSIS
  Outputs structured data for VRO plan step variable capture.
#>
function Write-VROOutput {
  param([Parameter(Mandatory)][hashtable]$Data)

  $Data["_vroTimestamp"] = (Get-Date -Format "o")
  $Data["_vroPlan"] = $VROPlanName
  $Data["_vroStep"] = $VROStepName
  $json = $Data | ConvertTo-Json -Compress -Depth 5
  Write-Output "VRO_OUTPUT:$json"
}

# =============================
# Retry Logic
# =============================

<#
.SYNOPSIS
  Executes a script block with exponential backoff retry.
#>
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory)][scriptblock]$ScriptBlock,
    [string]$OperationName = "Operation",
    [int]$MaxAttempts = $MaxRetries,
    [int]$BaseDelay = $RetryBaseDelaySeconds
  )

  $attempt = 0
  while ($true) {
    $attempt++
    try {
      return & $ScriptBlock
    }
    catch {
      if ($attempt -ge $MaxAttempts) {
        Write-Log "$OperationName failed after $MaxAttempts attempts: $_" -Level ERROR
        throw
      }
      $delay = $BaseDelay * [Math]::Pow(2, $attempt - 1)
      Write-Log "$OperationName attempt $attempt/$MaxAttempts failed: $_. Retrying in ${delay}s..." -Level WARNING
      Start-Sleep -Seconds $delay
    }
  }
}

# =============================
# Prerequisites & Connection
# =============================

<#
.SYNOPSIS
  Loads the Veeam PowerShell module or snap-in.
#>
function Test-Prerequisites {
  Write-Log "Validating prerequisites..."

  $veeamLoaded = $false
  try {
    if (Get-Module -ListAvailable -Name "Veeam.Backup.PowerShell") {
      Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
      $veeamLoaded = $true
      Write-Log "Loaded Veeam.Backup.PowerShell module"
    }
  }
  catch {
    Write-Log "Module import failed, trying PSSnapin..." -Level WARNING
  }

  if (-not $veeamLoaded) {
    try {
      if (Get-PSSnapin -Registered -Name "VeeamPSSnapin" -ErrorAction SilentlyContinue) {
        Add-PSSnapin VeeamPSSnapin -ErrorAction Stop
        $veeamLoaded = $true
        Write-Log "Loaded VeeamPSSnapin snap-in"
      }
    }
    catch {
      Write-Log "PSSnapin load failed: $_" -Level WARNING
    }
  }

  if (-not $veeamLoaded) {
    throw "Veeam PowerShell module not found. Install VBR Console or Veeam.Backup.PowerShell module."
  }

  Write-Log "Prerequisites validated" -Level SUCCESS
}

<#
.SYNOPSIS
  Establishes connection to VBR server with session reuse.
#>
function Connect-VBRSession {
  Write-Log "Connecting to VBR server: $VBRServer`:$VBRPort"

  try {
    $existing = Get-VBRServerSession -ErrorAction SilentlyContinue
    if ($existing -and $existing.Server -eq $VBRServer -and $existing.Port -eq $VBRPort) {
      Write-Log "Reusing existing VBR session" -Level SUCCESS
      $script:VBRConnected = $true
      return
    }
  }
  catch { }

  $connectParams = @{ Server = $VBRServer; Port = $VBRPort }
  if ($VBRCredential) { $connectParams["Credential"] = $VBRCredential }

  Invoke-WithRetry -OperationName "VBR Connection" -ScriptBlock {
    Connect-VBRServer @connectParams
  }

  $script:VBRConnected = $true
  Write-Log "Connected to VBR server" -Level SUCCESS
}

# =============================
# Restore Point Analysis
# =============================

<#
.SYNOPSIS
  Checks a single restore point against all available verification sources.
.PARAMETER RestorePoint
  The Veeam restore point object to check.
.OUTPUTS
  Hashtable with: Clean (bool), Method (string), Details (string).
  Returns $null if no verification data is available.
#>
function Test-RestorePointSecurity {
  param([Parameter(Mandatory)][object]$RestorePoint)

  # Priority 1: Inline Malware Detection (VBR 12.1+)
  try {
    $malwareResult = Get-VBRMalwareDetectionResult -RestorePoint $RestorePoint -ErrorAction SilentlyContinue
    if ($malwareResult) {
      return @{
        Clean   = ($malwareResult.Status -eq "Clean")
        Method  = "InlineMalwareDetection"
        Details = "Status: $($malwareResult.Status)"
      }
    }
  }
  catch { }

  # Priority 2: SureBackup Verification Sessions
  try {
    $sbSession = Get-VSBSession -ErrorAction SilentlyContinue |
      Where-Object { $_.RestorePointId -eq $RestorePoint.Id } |
      Sort-Object EndTime -Descending |
      Select-Object -First 1

    if ($sbSession) {
      return @{
        Clean   = ($sbSession.Result -eq "Success")
        Method  = "SureBackup"
        Details = "Result: $($sbSession.Result), End: $($sbSession.EndTime)"
      }
    }
  }
  catch { }

  # Priority 3: Secure Restore scan log (if available)
  try {
    $secureRestore = Get-VBRSecureRestoreResult -RestorePoint $RestorePoint -ErrorAction SilentlyContinue
    if ($secureRestore) {
      return @{
        Clean   = ($secureRestore.IsClean -eq $true)
        Method  = "SecureRestore"
        Details = "IsClean: $($secureRestore.IsClean), Engine: $($secureRestore.AntivirusName)"
      }
    }
  }
  catch { }

  # Priority 4: Backup session success (lowest confidence)
  if (-not $RequireMalwareScan) {
    try {
      $backupSession = Get-VBRBackupSession -ErrorAction SilentlyContinue |
        Where-Object {
          $_.CreationTime.ToString("o") -eq $RestorePoint.CreationTime.ToString("o") -and
          $_.Result -eq "Success"
        } |
        Select-Object -First 1

      if ($backupSession) {
        return @{
          Clean   = $true
          Method  = "BackupSessionSuccess"
          Details = "No malware scan data; backup session succeeded (low confidence)"
        }
      }
    }
    catch { }
  }

  return $null
}

<#
.SYNOPSIS
  Scans restore points from newest to oldest and returns the first clean one.
.PARAMETER Backup
  The Veeam backup object.
.OUTPUTS
  Hashtable with RestorePoint, VerificationMethod, and scan summary.
#>
function Find-CleanPoint {
  param([Parameter(Mandatory)][object]$Backup)

  # Get restore points
  $rpParams = @{ Backup = $Backup }
  if ($VMName) { $rpParams["Name"] = $VMName }

  $allPoints = Get-VBRRestorePoint @rpParams | Sort-Object CreationTime -Descending

  if (-not $allPoints -or $allPoints.Count -eq 0) {
    throw "No restore points found for backup '$BackupName'$(if($VMName){" / VM '$VMName'"})."
  }

  Write-Log "Found $($allPoints.Count) restore point(s). Scanning up to $MaxPointsToScan..."

  # Apply minimum age filter
  $cutoff = (Get-Date).AddHours(-$MinAge)
  $eligiblePoints = if ($MinAge -gt 0) {
    $filtered = $allPoints | Where-Object { $_.CreationTime -lt $cutoff }
    Write-Log "After MinAge filter ($MinAge hours): $($filtered.Count) eligible points"
    $filtered
  }
  else {
    $allPoints
  }

  if (-not $eligiblePoints -or @($eligiblePoints).Count -eq 0) {
    throw "No restore points older than $MinAge hours. Latest point: $($allPoints[0].CreationTime)"
  }

  # Scan points
  $scanned = 0
  $scanResults = [System.Collections.Generic.List[object]]::new()

  foreach ($rp in $eligiblePoints) {
    if ($scanned -ge $MaxPointsToScan) {
      Write-Log "Reached scan limit ($MaxPointsToScan points). Stopping." -Level WARNING
      break
    }
    $scanned++

    $rpAge = ((Get-Date) - $rp.CreationTime)
    Write-Log "  [$scanned/$MaxPointsToScan] Checking: $($rp.CreationTime) (Age: $([int]$rpAge.TotalHours)h, ID: $($rp.Id))"

    $result = Test-RestorePointSecurity -RestorePoint $rp
    $scanEntry = [PSCustomObject]@{
      RestorePointId = $rp.Id
      CreationTime   = $rp.CreationTime
      Clean          = $null
      Method         = "NoData"
      Details        = "No verification data available"
    }

    if ($result) {
      $scanEntry.Clean = $result.Clean
      $scanEntry.Method = $result.Method
      $scanEntry.Details = $result.Details

      if ($result.Clean) {
        Write-Log "    CLEAN via $($result.Method): $($result.Details)" -Level SUCCESS
        $scanResults.Add($scanEntry)

        return @{
          RestorePoint = $rp
          Method       = $result.Method
          Details      = $result.Details
          ScanSummary  = $scanResults
          PointsScanned = $scanned
        }
      }
      else {
        Write-Log "    INFECTED via $($result.Method): $($result.Details)" -Level WARNING
      }
    }
    else {
      if ($RequireMalwareScan) {
        Write-Log "    SKIPPED: No malware scan data (RequireMalwareScan is set)" -Level WARNING
      }
      else {
        Write-Log "    NO DATA: No verification data for this point" -Level WARNING
      }
    }

    $scanResults.Add($scanEntry)
  }

  # No clean point found
  $infectedCount = @($scanResults | Where-Object { $_.Clean -eq $false }).Count
  $noDataCount = @($scanResults | Where-Object { $_.Clean -eq $null }).Count

  throw "No clean restore point found. Scanned: $scanned, Infected: $infectedCount, No data: $noDataCount. Manual investigation required."
}

# =============================
# Main Execution
# =============================

$cleanResult = $null
$success = $false
$errorMsg = $null

try {
  Write-Log "========================================="
  Write-Log "Find Clean EC2 Restore Point - Starting"
  Write-Log "========================================="
  Write-Log "Backup: $BackupName$(if($VMName){" / VM: $VMName"})"
  Write-Log "Max scan depth: $MaxPointsToScan | Min age: ${MinAge}h | Require scan: $RequireMalwareScan"
  if ($VROPlanName) { Write-Log "VRO Plan: $VROPlanName / Step: $VROStepName" }

  # Step 1: Prerequisites
  Write-Log "--- Step 1/3: Prerequisites ---"
  Test-Prerequisites

  # Step 2: Connect to VBR
  Write-Log "--- Step 2/3: VBR Connection ---"
  Connect-VBRSession

  # Step 3: Find clean restore point
  Write-Log "--- Step 3/3: Restore Point Analysis ---"

  $backup = Get-VBRBackup -Name $BackupName -ErrorAction SilentlyContinue
  if (-not $backup) {
    $backup = Get-VBRBackup | Where-Object { $_.Name -like "*$BackupName*" }
    if ($backup -is [array]) {
      throw "Multiple backups matched '$BackupName': $(($backup | ForEach-Object { $_.Name }) -join ', '). Provide the exact name."
    }
  }
  if (-not $backup) {
    throw "Backup '$BackupName' not found. Available: $((Get-VBRBackup | ForEach-Object { $_.Name }) -join ', ')"
  }

  Write-Log "Found backup: $($backup.Name) (ID: $($backup.Id))"

  $repo = $backup.GetRepository()
  if ($repo) {
    Write-Log "Repository: $($repo.Name) (Type: $($repo.Type))"
  }

  $cleanResult = Find-CleanPoint -Backup $backup
  $success = $true
}
catch {
  $errorMsg = $_.Exception.Message
  Write-Log "FATAL: $errorMsg" -Level ERROR
  Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR
  $script:ExitCode = 1
}
finally {
  $duration = (Get-Date) - $script:StartTime

  # Build result
  $resultData = [ordered]@{
    success            = $success
    backupName         = $BackupName
    vmName             = $VMName
    restorePointId     = if ($cleanResult) { $cleanResult.RestorePoint.Id.ToString() } else { $null }
    restorePointTime   = if ($cleanResult) { $cleanResult.RestorePoint.CreationTime.ToString("o") } else { $null }
    verificationMethod = if ($cleanResult) { $cleanResult.Method } else { $null }
    verificationDetail = if ($cleanResult) { $cleanResult.Details } else { $null }
    pointsScanned      = if ($cleanResult) { $cleanResult.PointsScanned } else { 0 }
    durationSeconds    = [int]$duration.TotalSeconds
    vroPlan            = $VROPlanName
    vroStep            = $VROStepName
    error              = $errorMsg
    timestamp          = (Get-Date -Format "o")
  }

  # Save JSON
  $resultData | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonFile -Encoding UTF8

  # Output for VRO downstream step consumption
  Write-VROOutput -Data @{
    status           = if ($success) { "Success" } else { "Failed" }
    restorePointId   = if ($cleanResult) { $cleanResult.RestorePoint.Id.ToString() } else { "" }
    restorePointTime = if ($cleanResult) { $cleanResult.RestorePoint.CreationTime.ToString("o") } else { "" }
    method           = if ($cleanResult) { $cleanResult.Method } else { "" }
    error            = if ($errorMsg) { $errorMsg } else { "" }
  }

  # Disconnect VBR
  if ($script:VBRConnected) {
    try { Disconnect-VBRServer -ErrorAction SilentlyContinue } catch {}
  }

  # Summary
  Write-Log "========================================="
  if ($success) {
    Write-Log "CLEAN RESTORE POINT FOUND" -Level SUCCESS
    Write-Log "  Point: $($cleanResult.RestorePoint.CreationTime) (ID: $($cleanResult.RestorePoint.Id))" -Level SUCCESS
    Write-Log "  Verified by: $($cleanResult.Method)" -Level SUCCESS
    Write-Log "  Points scanned: $($cleanResult.PointsScanned)" -Level SUCCESS
  }
  else {
    Write-Log "NO CLEAN RESTORE POINT FOUND" -Level ERROR
    Write-Log "  Error: $errorMsg" -Level ERROR
  }
  Write-Log "Duration: $($duration.ToString('hh\:mm\:ss'))"
  Write-Log "Output: $OutputPath"
  Write-Log "========================================="
}

exit $script:ExitCode
