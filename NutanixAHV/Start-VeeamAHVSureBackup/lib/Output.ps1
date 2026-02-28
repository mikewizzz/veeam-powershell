# =============================
# Output & Cleanup
# =============================

function Export-Results {
  <#
  .SYNOPSIS
    Export all SureBackup results to files (HTML, CSV, log)
  #>
  param(
    [Parameter(Mandatory = $true)]$TestResults,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
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
    $htmlContent = New-HTMLReport -TestResults $TestResults -RestorePoints $RestorePoints -IsolatedNetwork $IsolatedNetwork
    $htmlContent | Out-File -FilePath $htmlPath -Encoding UTF8
    Write-Log "  HTML report: $htmlPath" -Level "SUCCESS"
  }

  # Execution log
  $logPath = Join-Path $OutputPath "SureBackup_ExecutionLog.csv"
  $script:LogEntries | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8

  # Summary JSON
  $summaryPath = Join-Path $OutputPath "SureBackup_Summary.json"
  $summary = [PSCustomObject]@{
    Timestamp        = Get-Date -Format "o"
    VBRServer        = $VBRServer
    PrismCentral     = $PrismCentral
    IsolatedNetwork  = $IsolatedNetwork.Name
    DryRun           = [bool]$DryRun
    TotalVMs         = ($TestResults | Select-Object -ExpandProperty VMName -Unique).Count
    TotalTests       = $TestResults.Count
    PassedTests      = ($TestResults | Where-Object { $_.Passed }).Count
    FailedTests      = ($TestResults | Where-Object { -not $_.Passed }).Count
    Duration         = ((Get-Date) - $script:StartTime).ToString()
    Results          = $TestResults
  }
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
    running or in a failed state. Each session is cleaned up independently
    so a failure in one does not block cleanup of others.
    All sessions use Stop-AHVFullRestore (power off + delete via Prism API).
  #>
  Write-Log "Starting cleanup of $($script:RecoverySessions.Count) recovery session(s)..." -Level "INFO"

  $cleanedCount = 0
  foreach ($session in $script:RecoverySessions) {
    if ($session.Status -eq "Running" -or $session.Status -eq "Failed") {
      try {
        Stop-AHVFullRestore -RecoveryInfo $session
        $cleanedCount++
      }
      catch {
        Write-Log "  Cleanup failed for '$($session.OriginalVMName)': $($_.Exception.Message)" -Level "ERROR"
      }
    }
    elseif ($session.Status -eq "CleanedUp") {
      $cleanedCount++
    }
  }

  Write-Log "Cleanup complete: $cleanedCount / $($script:RecoverySessions.Count) session(s) cleaned up" -Level "SUCCESS"
}
