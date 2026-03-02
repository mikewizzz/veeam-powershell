# SPDX-License-Identifier: MIT
# =========================================================================
# RecoveryValidationSchema.ps1 - Universal Recovery Validation Data Model
# =========================================================================
#
# Provides a normalized schema for recovery validation results across
# platforms (Nutanix AHV, Azure, AWS, VMware). Designed to be dot-sourced
# by any recovery validation script in this repository.
#
# Usage:
#   . "$PSScriptRoot\RecoveryValidationSchema.ps1"
#
# =========================================================================

#region Helper Functions

function _GetTestCategory {
  <#
  .SYNOPSIS
    Infers a test category from a test name string.
  #>
  param([string]$TestName)

  if ([string]::IsNullOrWhiteSpace($TestName)) { return "Custom" }

  $lower = $TestName.ToLower()
  if ($lower -match 'boot|heartbeat|power|start') { return "Boot" }
  if ($lower -match 'ping|icmp|network|tcp|port|dns|connectivity') { return "Network" }
  if ($lower -match 'http|https|url|endpoint|app|service|sql|web') { return "Application" }
  return "Custom"
}

#endregion

#region Schema Factory Functions

function New-RecoveryValidationResult {
  <#
  .SYNOPSIS
    Creates a normalized recovery validation result object.
  .DESCRIPTION
    Factory function that produces a standardized result object for a single
    recovery verification test. Platform-specific converters (ConvertFrom-AHVResult,
    ConvertFrom-AzureResult, ConvertFrom-AWSResult) call this internally.
  .PARAMETER Platform
    Source platform identifier: NutanixAHV, Azure, AWS, or VMware.
  .PARAMETER VMName
    Name of the VM that was tested.
  .PARAMETER BackupJobName
    Name of the backup job that produced the restore point.
  .PARAMETER RestorePointTime
    Timestamp of the restore point used for recovery.
  .PARAMETER TestCategory
    High-level category: Boot, Network, Application, or Custom.
  .PARAMETER TestName
    Specific test identifier (e.g., "Heartbeat", "ICMP Ping", "TCP:443").
  .PARAMETER Passed
    Whether the test passed.
  .PARAMETER Details
    Human-readable detail string describing the result.
  .PARAMETER DurationSeconds
    How long the test took to execute, in seconds.
  .PARAMETER Timestamp
    When the test was executed. Defaults to current time.
  .PARAMETER RTOTargetMinutes
    Optional Recovery Time Objective target in minutes.
  .PARAMETER RTOActualMinutes
    Optional actual recovery time in minutes.
  .PARAMETER RTOMet
    Optional flag indicating whether RTO target was met.
  .EXAMPLE
    $result = New-RecoveryValidationResult -Platform "NutanixAHV" -VMName "web01" `
      -TestName "ICMP Ping" -Passed $true -Details "Reply from 10.0.0.5" -DurationSeconds 2.3
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("NutanixAHV", "Azure", "AWS", "VMware")]
    [string]$Platform,

    [Parameter(Mandatory = $true)]
    [string]$VMName,

    [string]$BackupJobName = "",

    [datetime]$RestorePointTime = [datetime]::MinValue,

    [ValidateSet("Boot", "Network", "Application", "Custom")]
    [string]$TestCategory = "",

    [Parameter(Mandatory = $true)]
    [string]$TestName,

    [Parameter(Mandatory = $true)]
    [bool]$Passed,

    [string]$Details = "",

    [double]$DurationSeconds = 0.0,

    [datetime]$Timestamp = (Get-Date),

    [int]$RTOTargetMinutes = 0,

    [double]$RTOActualMinutes = 0.0,

    [System.Nullable[bool]]$RTOMet = $null
  )

  # Auto-detect category if not provided
  if ([string]::IsNullOrWhiteSpace($TestCategory)) {
    $TestCategory = _GetTestCategory -TestName $TestName
  }

  [PSCustomObject]@{
    Platform          = $Platform
    VMName            = $VMName
    BackupJobName     = $BackupJobName
    RestorePointTime  = $RestorePointTime
    TestCategory      = $TestCategory
    TestName          = $TestName
    Passed            = $Passed
    Details           = $Details
    DurationSeconds   = [Math]::Round($DurationSeconds, 2)
    Timestamp         = $Timestamp
    RTOTargetMinutes  = $RTOTargetMinutes
    RTOActualMinutes  = [Math]::Round($RTOActualMinutes, 2)
    RTOMet            = $RTOMet
  }
}

function New-RecoveryValidationSummary {
  <#
  .SYNOPSIS
    Aggregates an array of validation results into a summary object.
  .DESCRIPTION
    Takes an array of results from New-RecoveryValidationResult and produces
    a summary with pass rates, RTO compliance metrics, and platform breakdown.
    The summary is suitable for report generation and compliance evidence.
  .PARAMETER Results
    Array of PSCustomObject results from New-RecoveryValidationResult.
  .PARAMETER StartTime
    When the validation run started. Used to calculate total duration.
  .EXAMPLE
    $summary = New-RecoveryValidationSummary -Results $allResults -StartTime $runStart
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Results,

    [datetime]$StartTime = (Get-Date)
  )

  $endTime = Get-Date
  $duration = $endTime - $StartTime
  $durationStr = "{0:hh\:mm\:ss}" -f $duration

  $totalTests = @($Results).Count
  $passedTests = @($Results | Where-Object { $_.Passed -eq $true }).Count
  $failedTests = $totalTests - $passedTests
  $passRate = if ($totalTests -gt 0) { [Math]::Round(($passedTests / $totalTests) * 100, 1) } else { 0.0 }

  # Unique platforms
  $platforms = @($Results | Select-Object -ExpandProperty Platform -Unique)

  # Unique VMs
  $uniqueVMs = @($Results | Select-Object -ExpandProperty VMName -Unique)
  $totalVMs = $uniqueVMs.Count

  # RTO compliance: only count VMs that have RTO data
  $rtoResults = @($Results | Where-Object { $null -ne $_.RTOMet })
  $avgRTO = 0.0
  $rtoComplianceRate = 0.0
  if ($rtoResults.Count -gt 0) {
    $avgRTO = [Math]::Round(($rtoResults | Measure-Object -Property RTOActualMinutes -Average).Average, 1)
    $rtoMetCount = @($rtoResults | Where-Object { $_.RTOMet -eq $true }).Count
    $rtoComplianceRate = [Math]::Round(($rtoMetCount / $rtoResults.Count) * 100, 1)
  }

  $overallSuccess = ($failedTests -eq 0) -and ($totalTests -gt 0)

  [PSCustomObject]@{
    RunId              = [guid]::NewGuid().ToString()
    Timestamp          = $endTime
    Platforms          = $platforms
    TotalVMs           = $totalVMs
    TotalTests         = $totalTests
    PassedTests        = $passedTests
    FailedTests        = $failedTests
    PassRate           = $passRate
    AvgRTOMinutes      = $avgRTO
    RTOComplianceRate  = $rtoComplianceRate
    OverallSuccess     = $overallSuccess
    Duration           = $durationStr
    Results            = $Results
  }
}

#endregion

#region Platform Converters

function ConvertFrom-AHVResult {
  <#
  .SYNOPSIS
    Converts Nutanix AHV SureBackup test results to the normalized schema.
  .DESCRIPTION
    Transforms the result format produced by Start-VeeamAHVSureBackup.ps1
    (_NewTestResult objects with VMName, TestName, Passed, Details, Duration,
    Timestamp properties) into normalized RecoveryValidationResult objects.
  .PARAMETER AHVResults
    Array of AHV test result objects from Start-VeeamAHVSureBackup.
  .PARAMETER BackupJobName
    Name of the backup job. AHV results do not carry job context per-result,
    so this is applied uniformly. Leave empty if unknown.
  .PARAMETER RestorePointTime
    Timestamp of the restore point used. Applied uniformly to all results.
  .PARAMETER RTOTargetMinutes
    Optional RTO target. If provided, RTOActualMinutes is derived from the
    cumulative duration of all tests per VM.
  .EXAMPLE
    $normalized = ConvertFrom-AHVResult -AHVResults $script:TestResults -BackupJobName "AHV-Prod"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$AHVResults,

    [string]$BackupJobName = "",

    [datetime]$RestorePointTime = [datetime]::MinValue,

    [int]$RTOTargetMinutes = 0
  )

  $normalized = New-Object System.Collections.Generic.List[object]

  # Pre-compute per-VM total duration for RTO if target is set
  $vmDurations = @{}
  if ($RTOTargetMinutes -gt 0) {
    foreach ($r in $AHVResults) {
      $vmKey = if ($null -ne $r.VMName) { $r.VMName } else { "" }
      $dur = if ($null -ne $r.Duration) { [double]$r.Duration } else { 0.0 }
      if ($vmDurations.ContainsKey($vmKey)) {
        $vmDurations[$vmKey] = $vmDurations[$vmKey] + $dur
      }
      else {
        $vmDurations[$vmKey] = $dur
      }
    }
  }

  foreach ($result in $AHVResults) {
    $vmName = if ($null -ne $result.VMName) { $result.VMName } else { "" }
    $testName = if ($null -ne $result.TestName) { $result.TestName } else { "Unknown" }
    $passed = if ($null -ne $result.Passed) { [bool]$result.Passed } else { $false }
    $details = if ($null -ne $result.Details) { $result.Details } else { "" }
    $dur = if ($null -ne $result.Duration) { [double]$result.Duration } else { 0.0 }
    $ts = if ($null -ne $result.Timestamp) { [datetime]$result.Timestamp } else { Get-Date }

    $rtoActual = 0.0
    $rtoMet = $null
    if ($RTOTargetMinutes -gt 0 -and $vmDurations.ContainsKey($vmName)) {
      $rtoActual = [Math]::Round($vmDurations[$vmName] / 60.0, 1)
      $rtoMet = $rtoActual -le $RTOTargetMinutes
    }

    $params = @{
      Platform          = "NutanixAHV"
      VMName            = $vmName
      BackupJobName     = $BackupJobName
      RestorePointTime  = $RestorePointTime
      TestName          = $testName
      Passed            = $passed
      Details           = $details
      DurationSeconds   = $dur
      Timestamp         = $ts
      RTOTargetMinutes  = $RTOTargetMinutes
      RTOActualMinutes  = $rtoActual
    }
    if ($null -ne $rtoMet) {
      $params["RTOMet"] = $rtoMet
    }

    $normalized.Add((New-RecoveryValidationResult @params))
  }

  return ,$normalized.ToArray()
}

function ConvertFrom-AzureResult {
  <#
  .SYNOPSIS
    Converts Azure verification results to the normalized schema.
  .DESCRIPTION
    Transforms the result format produced by Test-VeeamVaultBackup.ps1
    (objects with VmName, OverallResult, RestoreDuration, BootVerified,
    PortsVerified, HeartbeatVerified, ScriptVerified, etc.) into normalized
    RecoveryValidationResult objects. Each Azure result expands into multiple
    normalized rows (one per verification check).
  .PARAMETER AzureResults
    Array of Azure verification result objects from Test-VeeamVaultBackup.
  .PARAMETER RTOTargetMinutes
    Optional RTO target in minutes.
  .EXAMPLE
    $normalized = ConvertFrom-AzureResult -AzureResults $verificationResults
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$AzureResults,

    [int]$RTOTargetMinutes = 0
  )

  $normalized = New-Object System.Collections.Generic.List[object]

  foreach ($result in $AzureResults) {
    $vmName = if ($null -ne $result.VmName) { $result.VmName } else { "" }
    $backupName = if ($null -ne $result.BackupName) { $result.BackupName } else { "" }
    $rpTime = [datetime]::MinValue
    if ($null -ne $result.RestorePointTime) {
      try { $rpTime = [datetime]$result.RestorePointTime } catch { }
    }
    $verifyTime = Get-Date
    if ($null -ne $result.VerificationTime) {
      try { $verifyTime = [datetime]$result.VerificationTime } catch { }
    }

    # Parse RestoreDuration string (format: "mm:ss") to seconds
    $restoreDurSec = 0.0
    if ($null -ne $result.RestoreDuration -and $result.RestoreDuration -ne "") {
      $durStr = "$($result.RestoreDuration)"
      if ($durStr -match '^(\d+):(\d+)$') {
        $restoreDurSec = ([int]$Matches[1] * 60) + [int]$Matches[2]
      }
    }

    # RTO from total restore duration
    $rtoActual = [Math]::Round($restoreDurSec / 60.0, 1)
    $rtoMet = $null
    if ($RTOTargetMinutes -gt 0) {
      $rtoMet = $rtoActual -le $RTOTargetMinutes
    }

    # Restore status as a Boot-category test
    $restoreOk = if ($null -ne $result.RestoreStatus) { $result.RestoreStatus -eq "Success" } else { $false }
    $restoreDetails = if ($null -ne $result.RestoreError -and $result.RestoreError -ne "") {
      $result.RestoreError
    } else {
      "Restore $($result.RestoreStatus)"
    }

    $baseParams = @{
      Platform          = "Azure"
      VMName            = $vmName
      BackupJobName     = $backupName
      RestorePointTime  = $rpTime
      Timestamp         = $verifyTime
      RTOTargetMinutes  = $RTOTargetMinutes
      RTOActualMinutes  = $rtoActual
    }
    if ($null -ne $rtoMet) {
      $baseParams["RTOMet"] = $rtoMet
    }

    # 1. Restore status
    $p = $baseParams.Clone()
    $p["TestCategory"] = "Boot"
    $p["TestName"] = "Restore"
    $p["Passed"] = $restoreOk
    $p["Details"] = $restoreDetails
    $p["DurationSeconds"] = $restoreDurSec
    $normalized.Add((New-RecoveryValidationResult @p))

    # 2. Boot verified
    $bootOk = if ($null -ne $result.BootVerified) { [bool]$result.BootVerified } else { $false }
    $p2 = $baseParams.Clone()
    $p2["TestCategory"] = "Boot"
    $p2["TestName"] = "Boot Verification"
    $p2["Passed"] = $bootOk
    $p2["Details"] = if ($bootOk) { "VM booted successfully" } else { "VM did not boot within timeout" }
    $p2["DurationSeconds"] = 0.0
    $normalized.Add((New-RecoveryValidationResult @p2))

    # 3. Heartbeat verified
    $hbOk = if ($null -ne $result.HeartbeatVerified) { [bool]$result.HeartbeatVerified } else { $false }
    $p3 = $baseParams.Clone()
    $p3["TestCategory"] = "Boot"
    $p3["TestName"] = "Heartbeat"
    $p3["Passed"] = $hbOk
    $p3["Details"] = if ($hbOk) { "Heartbeat detected" } else { "No heartbeat response" }
    $p3["DurationSeconds"] = 0.0
    $normalized.Add((New-RecoveryValidationResult @p3))

    # 4. Ports verified
    $portsOk = if ($null -ne $result.PortsVerified) { [bool]$result.PortsVerified } else { $false }
    $portDetails = if ($null -ne $result.PortDetails -and $result.PortDetails -ne "") { $result.PortDetails } else {
      if ($portsOk) { "All ports responding" } else { "Port verification failed" }
    }
    $p4 = $baseParams.Clone()
    $p4["TestCategory"] = "Network"
    $p4["TestName"] = "TCP Port Check"
    $p4["Passed"] = $portsOk
    $p4["Details"] = $portDetails
    $p4["DurationSeconds"] = 0.0
    $normalized.Add((New-RecoveryValidationResult @p4))

    # 5. Script verified (only if script was run)
    if ($null -ne $result.ScriptVerified) {
      $scriptOk = [bool]$result.ScriptVerified
      $scriptOutput = if ($null -ne $result.ScriptOutput -and $result.ScriptOutput -ne "") { $result.ScriptOutput } else {
        if ($scriptOk) { "Custom script passed" } else { "Custom script failed" }
      }
      $p5 = $baseParams.Clone()
      $p5["TestCategory"] = "Application"
      $p5["TestName"] = "Custom Script"
      $p5["Passed"] = $scriptOk
      $p5["Details"] = $scriptOutput
      $p5["DurationSeconds"] = 0.0
      $normalized.Add((New-RecoveryValidationResult @p5))
    }
  }

  return ,$normalized.ToArray()
}

function ConvertFrom-AWSResult {
  <#
  .SYNOPSIS
    Converts AWS health check results to the normalized schema.
  .DESCRIPTION
    Transforms the result format produced by Restore-VRO-AWS-EC2.ps1. The AWS
    script produces a JSON result bundle with health check sub-objects (TestName,
    Passed, Details, Duration) plus parent restore context (backupName, vmName,
    restorePoint, durationSeconds, rtoTargetMinutes, rtoActualMinutes, rtoMet).
  .PARAMETER AWSResultBundle
    The top-level result object or hashtable from Restore-VRO-AWS-EC2, containing
    at minimum: vmName, success, backupName, restorePoint, durationSeconds.
    Optionally: healthChecks (array), rtoTargetMinutes, rtoActualMinutes, rtoMet.
  .EXAMPLE
    $json = Get-Content "restore-result.json" | ConvertFrom-Json
    $normalized = ConvertFrom-AWSResult -AWSResultBundle $json
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object]$AWSResultBundle
  )

  $normalized = New-Object System.Collections.Generic.List[object]

  $vmName = if ($null -ne $AWSResultBundle.vmName) { $AWSResultBundle.vmName } else { "" }
  $backupName = if ($null -ne $AWSResultBundle.backupName) { $AWSResultBundle.backupName } else { "" }
  $rpTime = [datetime]::MinValue
  if ($null -ne $AWSResultBundle.restorePoint) {
    try { $rpTime = [datetime]$AWSResultBundle.restorePoint } catch { }
  }
  $totalDurSec = if ($null -ne $AWSResultBundle.durationSeconds) { [double]$AWSResultBundle.durationSeconds } else { 0.0 }
  $rtoTarget = if ($null -ne $AWSResultBundle.rtoTargetMinutes) { [int]$AWSResultBundle.rtoTargetMinutes } else { 0 }
  $rtoActual = if ($null -ne $AWSResultBundle.rtoActualMinutes) { [double]$AWSResultBundle.rtoActualMinutes } else { 0.0 }
  $rtoMet = $null
  if ($null -ne $AWSResultBundle.rtoMet) {
    $rtoMet = [bool]$AWSResultBundle.rtoMet
  }

  $baseParams = @{
    Platform          = "AWS"
    VMName            = $vmName
    BackupJobName     = $backupName
    RestorePointTime  = $rpTime
    Timestamp         = Get-Date
    RTOTargetMinutes  = $rtoTarget
    RTOActualMinutes  = $rtoActual
  }
  if ($null -ne $rtoMet) {
    $baseParams["RTOMet"] = $rtoMet
  }

  # Add the overall restore result as a Boot test
  $restoreOk = if ($null -ne $AWSResultBundle.success) { [bool]$AWSResultBundle.success } else { $false }
  $restoreError = if ($null -ne $AWSResultBundle.error -and $AWSResultBundle.error -ne "") { $AWSResultBundle.error } else {
    if ($restoreOk) { "EC2 restore completed successfully" } else { "EC2 restore failed" }
  }
  $p = $baseParams.Clone()
  $p["TestCategory"] = "Boot"
  $p["TestName"] = "EC2 Restore"
  $p["Passed"] = $restoreOk
  $p["Details"] = $restoreError
  $p["DurationSeconds"] = $totalDurSec
  $normalized.Add((New-RecoveryValidationResult @p))

  # Add individual health check results if present
  $healthChecks = $AWSResultBundle.healthChecks
  if ($null -ne $healthChecks) {
    foreach ($hc in $healthChecks) {
      $hcName = if ($null -ne $hc.test) { $hc.test } elseif ($null -ne $hc.TestName) { $hc.TestName } else { "Unknown" }
      $hcPassed = if ($null -ne $hc.passed) { [bool]$hc.passed } elseif ($null -ne $hc.Passed) { [bool]$hc.Passed } else { $false }
      $hcDetails = if ($null -ne $hc.details) { $hc.details } elseif ($null -ne $hc.Details) { $hc.Details } else { "" }
      $hcDur = if ($null -ne $hc.duration) { [double]$hc.duration } elseif ($null -ne $hc.Duration) { [double]$hc.Duration } else { 0.0 }

      $hp = $baseParams.Clone()
      $hp["TestName"] = $hcName
      $hp["Passed"] = $hcPassed
      $hp["Details"] = $hcDetails
      $hp["DurationSeconds"] = $hcDur
      $normalized.Add((New-RecoveryValidationResult @hp))
    }
  }

  return ,$normalized.ToArray()
}

#endregion

#region Export Functions

function Export-RecoveryValidationResults {
  <#
  .SYNOPSIS
    Exports recovery validation results to CSV and JSON files.
  .DESCRIPTION
    Writes the normalized results array to both CSV (tabular, UTF-8) and JSON
    (machine-readable) files in the specified output directory. File names are
    timestamped to prevent overwrites.
  .PARAMETER Results
    Array of normalized RecoveryValidationResult objects.
  .PARAMETER OutputPath
    Directory to write output files. Created if it does not exist.
  .PARAMETER FilePrefix
    Optional prefix for output file names. Default: "RecoveryValidation".
  .EXAMPLE
    Export-RecoveryValidationResults -Results $allResults -OutputPath "C:\Reports"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object[]]$Results,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$FilePrefix = "RecoveryValidation"
  )

  if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
  }

  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $csvPath = Join-Path $OutputPath "${FilePrefix}_${timestamp}.csv"
  $jsonPath = Join-Path $OutputPath "${FilePrefix}_${timestamp}.json"

  # CSV export - flatten nullable fields for compatibility
  $csvData = $Results | ForEach-Object {
    [PSCustomObject]@{
      Platform          = $_.Platform
      VMName            = $_.VMName
      BackupJobName     = $_.BackupJobName
      RestorePointTime  = if ($_.RestorePointTime -ne [datetime]::MinValue) { $_.RestorePointTime.ToString("o") } else { "" }
      TestCategory      = $_.TestCategory
      TestName          = $_.TestName
      Passed            = $_.Passed
      Details           = $_.Details
      DurationSeconds   = $_.DurationSeconds
      Timestamp         = $_.Timestamp.ToString("o")
      RTOTargetMinutes  = $_.RTOTargetMinutes
      RTOActualMinutes  = $_.RTOActualMinutes
      RTOMet            = if ($null -ne $_.RTOMet) { $_.RTOMet.ToString() } else { "" }
    }
  }

  $csvData | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Verbose "CSV exported to: $csvPath"

  # JSON export - include summary metadata
  $jsonBundle = [ordered]@{
    exportedAt = (Get-Date).ToString("o")
    totalResults = @($Results).Count
    results = @($Results | ForEach-Object {
      [ordered]@{
        platform          = $_.Platform
        vmName            = $_.VMName
        backupJobName     = $_.BackupJobName
        restorePointTime  = if ($_.RestorePointTime -ne [datetime]::MinValue) { $_.RestorePointTime.ToString("o") } else { $null }
        testCategory      = $_.TestCategory
        testName          = $_.TestName
        passed            = $_.Passed
        details           = $_.Details
        durationSeconds   = $_.DurationSeconds
        timestamp         = $_.Timestamp.ToString("o")
        rtoTargetMinutes  = $_.RTOTargetMinutes
        rtoActualMinutes  = $_.RTOActualMinutes
        rtoMet            = $_.RTOMet
      }
    })
  }

  $jsonBundle | ConvertTo-Json -Depth 10 | Out-File -FilePath $jsonPath -Encoding UTF8
  Write-Verbose "JSON exported to: $jsonPath"

  [PSCustomObject]@{
    CsvPath  = $csvPath
    JsonPath = $jsonPath
  }
}

#endregion
