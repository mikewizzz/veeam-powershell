# SPDX-License-Identifier: MIT
# =============================
# Output & Cleanup
# =============================

function Export-Results {
  <#
  .SYNOPSIS
    Export all SureBackup results to files (HTML, CSV, log)
  .PARAMETER SLASummary
    Optional SLA compliance summary for report and JSON export
  .PARAMETER VMTimings
    Optional per-VM timing data for RPO/RTO columns in HTML report
  #>
  param(
    [Parameter(Mandatory = $true)]$TestResults,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$IsolatedNetwork,
    $SLASummary,
    $VMTimings
  )

  # Create output directory
  if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
  }

  Write-Log "Exporting results to: $OutputPath" -Level "INFO"

  # CSV: Test Results
  $csvPath = Join-Path $OutputPath "SureBackup_TestResults.csv"
  $TestResults | Select-Object VMName, TestName, Passed, Details, Duration, Timestamp |
    Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
  Write-Log "  CSV report: $csvPath" -Level "INFO"

  # CSV: Restore Points
  $rpCsvPath = Join-Path $OutputPath "SureBackup_RestorePoints.csv"
  $RestorePoints | Select-Object VMName, JobName, CreationTime, IsConsistent |
    Export-Csv -Path $rpCsvPath -NoTypeInformation -Encoding UTF8

  # HTML Report
  if ($GenerateHTML) {
    $htmlPath = Join-Path $OutputPath "SureBackup_Report.html"
    $reportParams = @{
      TestResults     = $TestResults
      RestorePoints   = $RestorePoints
      IsolatedNetwork = $IsolatedNetwork
    }
    if ($SLASummary) { $reportParams.SLASummary = $SLASummary }
    if ($VMTimings) { $reportParams.VMTimings = $VMTimings }
    $htmlContent = New-HTMLReport @reportParams
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "  HTML report: $htmlPath" -Level "SUCCESS"
  }

  # Execution log
  $logPath = Join-Path $OutputPath "SureBackup_ExecutionLog.csv"
  $script:LogEntries | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

  # Summary JSON — convert Generic.List to plain array for PS 5.1 ConvertTo-Json compatibility
  $summaryPath = Join-Path $OutputPath "SureBackup_Summary.json"
  $safeResults = @($TestResults | Where-Object { $null -ne $_ })
  $summaryProps = [ordered]@{
    Timestamp        = Get-Date -Format "o"
    VBRServer        = $VBRServer
    PrismCentral     = $PrismCentral
    IsolatedNetwork  = $IsolatedNetwork.Name
    DryRun           = [bool]$DryRun
    TotalVMs         = @($safeResults | Select-Object -ExpandProperty VMName -Unique).Count
    TotalTests       = $safeResults.Count
    PassedTests      = @($safeResults | Where-Object { $_.Passed }).Count
    FailedTests      = @($safeResults | Where-Object { -not $_.Passed }).Count
    Duration         = ((Get-Date) - $script:StartTime).ToString()
    Results          = $safeResults
  }
  if ($SLASummary) {
    $summaryProps.SLA = [PSCustomObject]@{
      RTOTarget       = $SLASummary.RTOTarget
      RTORate         = $SLASummary.RTORate
      RPOTarget       = $SLASummary.RPOTarget
      RPORate         = $SLASummary.RPORate
      AvgRTOMinutes   = $SLASummary.AvgRTOMinutes
      AvgRPOHours     = $SLASummary.AvgRPOHours
      WorstRTOMinutes = $SLASummary.WorstRTOMinutes
      WorstRPOHours   = $SLASummary.WorstRPOHours
      VMDetails       = @($SLASummary.VMDetails | ForEach-Object {
        [PSCustomObject]@{
          VMName        = $_.VMName
          RTOMinutes    = $_.RTOMinutes
          RPOHours      = $_.RPOHours
          RecoveryStart = $_.RecoveryStart.ToString("o")
          TestsComplete = $_.TestsComplete.ToString("o")
        }
      })
    }
  }
  $summary = [PSCustomObject]$summaryProps
  $summary | ConvertTo-Json -Depth 10 | Out-File -FilePath $summaryPath -Encoding UTF8

  # ZIP archive
  if ($ZipOutput) {
    $zipPath = "$OutputPath.zip"
    try {
      Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $zipPath -Force
      Write-Log "  ZIP archive: $zipPath" -Level "SUCCESS"
    }
    catch {
      Write-Log "  ZIP creation failed: $($_.Exception.Message)" -Level "WARNING"
    }
  }
}

function Invoke-Cleanup {
  <#
  .SYNOPSIS
    Clean up all restored VMs and temporary resources
  .DESCRIPTION
    Iterates over all tracked recovery sessions and stops any that are still
    running, failed, or previously failed cleanup. Each session is cleaned up
    independently so a failure in one does not block cleanup of others.
    All sessions use Stop-AHVFullRestore (power off + delete via Prism API
    with built-in retry logic).
  #>
  Write-Log "Starting cleanup of $($script:RecoverySessions.Count) recovery session(s)..." -Level "INFO"

  $cleanedCount = 0
  foreach ($session in $script:RecoverySessions) {
    if ($session.Status -eq "Running" -or $session.Status -eq "Failed" -or $session.Status -eq "CleanupFailed") {
      try {
        Stop-AHVFullRestore -RecoveryInfo $session
        if ($session.Status -eq "CleanedUp") { $cleanedCount++ }
      }
      catch {
        Write-Log "  Cleanup failed for '$($session.OriginalVMName)': $($_.Exception.Message)" -Level "ERROR"
      }
    }
    elseif ($session.Status -eq "CleanedUp") {
      $cleanedCount++
    }
  }

  $orphanCount = @($script:RecoverySessions | Where-Object { $_.Status -eq "CleanupFailed" }).Count
  if ($orphanCount -gt 0) {
    Write-Log "WARNING: $orphanCount VM(s) could not be cleaned up — check SureBackup_OrphanVMs.txt for manual cleanup" -Level "ERROR"
  }

  Write-Log "Cleanup complete: $cleanedCount / $($script:RecoverySessions.Count) session(s) cleaned up" -Level "SUCCESS"
}
