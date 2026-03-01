# =============================
# HTML Report Generation
# =============================

function _EscapeHTML {
  <#
  .SYNOPSIS
    Escape HTML special characters to prevent XSS in generated reports
  #>
  param([string]$Text)
  if (-not $Text) { return "" }
  return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

function New-HTMLReport {
  <#
  .SYNOPSIS
    Generate a professional HTML report with SureBackup test results
  #>
  param(
    [Parameter(Mandatory = $true)]$TestResults,
    [Parameter(Mandatory = $true)]$RestorePoints,
    [Parameter(Mandatory = $true)]$IsolatedNetwork
  )

  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  $duration = (Get-Date) - $script:StartTime
  $durationStr = "{0:hh\:mm\:ss}" -f $duration

  # Calculate summary stats
  $summary = _GetTestSummary -TestResults $TestResults
  $totalTests = $summary.TotalTests
  $passedTests = $summary.PassedTests
  $failedTests = $summary.FailedTests
  $passRate = $summary.PassRate

  $uniqueVMs = ($TestResults | Select-Object -ExpandProperty VMName -Unique)
  $totalVMs = $uniqueVMs.Count
  $fullyPassedVMs = 0
  foreach ($vm in $uniqueVMs) {
    $vmTests = $TestResults | Where-Object { $_.VMName -eq $vm }
    if (($vmTests | Where-Object { -not $_.Passed }).Count -eq 0) {
      $fullyPassedVMs++
    }
  }
  $vmPassRate = if ($totalVMs -gt 0) { [math]::Round(($fullyPassedVMs / $totalVMs) * 100, 1) } else { 0 }

  $overallStatus = if ($failedTests -eq 0) { "ALL TESTS PASSED" } else { "$failedTests TEST(S) FAILED" }
  $statusColor = if ($failedTests -eq 0) { "#00B336" } else { "#D13438" }

  # Build VM detail rows
  $vmDetailRows = ""
  foreach ($vm in $uniqueVMs) {
    $vmTests = $TestResults | Where-Object { $_.VMName -eq $vm }
    $vmPassed = ($vmTests | Where-Object { $_.Passed }).Count
    $vmTotal = $vmTests.Count
    $vmStatus = if ($vmPassed -eq $vmTotal) { "PASS" } else { "FAIL" }
    $vmStatusClass = if ($vmPassed -eq $vmTotal) { "status-pass" } else { "status-fail" }

    # Get restore point info
    $rpInfo = $RestorePoints | Where-Object { $_.VMName -eq $vm }
    $rpDate = if ($rpInfo) { $rpInfo.CreationTime.ToString("yyyy-MM-dd HH:mm") } else { "N/A" }
    $rpJob = if ($rpInfo) { $rpInfo.JobName } else { "N/A" }

    $safeVM = _EscapeHTML $vm
    $safeJob = _EscapeHTML $rpJob
    $safeDate = _EscapeHTML $rpDate

    $vmDetailRows += @"
    <tr>
      <td><strong>$safeVM</strong></td>
      <td>$safeJob</td>
      <td>$safeDate</td>
      <td>$vmPassed / $vmTotal</td>
      <td><span class="$vmStatusClass">$vmStatus</span></td>
    </tr>
"@
  }

  # Build individual test result rows
  $testDetailRows = ""
  foreach ($result in $TestResults) {
    $statusClass = if ($result.Passed) { "status-pass" } else { "status-fail" }
    $statusText = if ($result.Passed) { "PASS" } else { "FAIL" }
    $durationText = "$([math]::Round($result.Duration, 1))s"

    $safeVMName = _EscapeHTML $result.VMName
    $safeTestName = _EscapeHTML $result.TestName
    $safeDetails = _EscapeHTML $result.Details

    $testDetailRows += @"
    <tr>
      <td>$safeVMName</td>
      <td>$safeTestName</td>
      <td><span class="$statusClass">$statusText</span></td>
      <td>$safeDetails</td>
      <td>$durationText</td>
    </tr>
"@
  }

  # Build log rows
  $logRows = ""
  foreach ($log in $script:LogEntries) {
    $logClass = switch ($log.Level) {
      "ERROR"     { "log-error" }
      "WARNING"   { "log-warning" }
      "SUCCESS"   { "log-success" }
      "TEST-PASS" { "log-success" }
      "TEST-FAIL" { "log-error" }
      default     { "log-info" }
    }
    $safeMessage = _EscapeHTML $log.Message
    $logRows += "    <tr class=`"$logClass`"><td>$($log.Timestamp)</td><td>$($log.Level)</td><td>$safeMessage</td></tr>`n"
  }

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Veeam SureBackup for Nutanix AHV - Verification Report</title>
<style>
:root {
  --veeam-green: #00B336;
  --veeam-dark: #005F28;
  --nutanix-blue: #024DA1;
  --nutanix-dark: #1A1F36;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --ms-red: #D13438;
  --ms-blue: #0078D4;
  --shadow-depth-4: 0 1.6px 3.6px rgba(0,0,0,.132), 0 0.3px 0.9px rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px rgba(0,0,0,.132), 0 0.6px 1.8px rgba(0,0,0,.108);
}

* { margin: 0; padding: 0; box-sizing: border-box; }

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.5;
}

.container {
  max-width: 1200px;
  margin: 0 auto;
  padding: 40px 32px;
}

.header {
  background: white;
  border-left: 4px solid var(--veeam-green);
  padding: 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
}

.header-title {
  font-size: 32px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 4px;
}

.header-subtitle {
  font-size: 16px;
  color: var(--ms-gray-90);
  margin-bottom: 4px;
}

.header-platform {
  font-size: 14px;
  color: var(--nutanix-blue);
  font-weight: 600;
  margin-bottom: 24px;
}

.header-meta {
  display: flex;
  gap: 32px;
  flex-wrap: wrap;
  font-size: 13px;
  color: var(--ms-gray-90);
}

.overall-status {
  background: white;
  padding: 24px 32px;
  margin-bottom: 32px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-8);
  border-left: 6px solid ${statusColor};
  display: flex;
  align-items: center;
  justify-content: space-between;
}

.overall-status-text {
  font-size: 24px;
  font-weight: 600;
  color: ${statusColor};
}

.overall-status-detail {
  font-size: 14px;
  color: var(--ms-gray-90);
}

.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 24px;
  margin-bottom: 32px;
}

.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
  border-top: 3px solid var(--veeam-green);
}

.kpi-card.fail { border-top-color: var(--ms-red); }
.kpi-card.nutanix { border-top-color: var(--nutanix-blue); }

.kpi-label {
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  color: var(--ms-gray-90);
  margin-bottom: 8px;
}

.kpi-value {
  font-size: 36px;
  font-weight: 300;
  color: var(--ms-gray-160);
  margin-bottom: 4px;
}

.kpi-subtext {
  font-size: 13px;
  color: var(--ms-gray-90);
}

.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}

.section-title {
  font-size: 20px;
  font-weight: 600;
  color: var(--ms-gray-160);
  margin-bottom: 20px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--ms-gray-30);
}

table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
  margin-top: 16px;
}

thead { background: var(--ms-gray-20); }

th {
  padding: 12px 16px;
  text-align: left;
  font-weight: 600;
  color: var(--ms-gray-130);
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}

td {
  padding: 14px 16px;
  border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}

tbody tr:hover { background: var(--ms-gray-10); }

.status-pass {
  background: #DFF6DD;
  color: #0E700E;
  padding: 4px 12px;
  border-radius: 12px;
  font-weight: 600;
  font-size: 12px;
}

.status-fail {
  background: #FDE7E9;
  color: #D13438;
  padding: 4px 12px;
  border-radius: 12px;
  font-weight: 600;
  font-size: 12px;
}

.info-card {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--nutanix-blue);
  padding: 20px 24px;
  margin: 16px 0;
  border-radius: 2px;
}

.info-card-title {
  font-weight: 600;
  color: var(--ms-gray-130);
  margin-bottom: 8px;
  font-size: 14px;
}

.info-card-text {
  color: var(--ms-gray-90);
  font-size: 14px;
  line-height: 1.6;
}

.log-section { max-height: 400px; overflow-y: auto; }
.log-error td { color: var(--ms-red); }
.log-warning td { color: #986F0B; }
.log-success td { color: #0E700E; }
.log-info td { color: var(--ms-gray-90); }

.footer {
  text-align: center;
  padding: 32px;
  color: var(--ms-gray-90);
  font-size: 13px;
}

.dry-run-banner {
  background: #FFF4CE;
  border: 2px solid #986F0B;
  color: #986F0B;
  padding: 16px 24px;
  margin-bottom: 24px;
  border-radius: 4px;
  font-weight: 600;
  font-size: 16px;
  text-align: center;
}

@media print {
  body { background: white; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); }
  .log-section { max-height: none; }
}
</style>
</head>
<body>
<div class="container">
  <div class="header">
    <div class="header-title">Backup Verification Report (Community Tool)</div>
    <div class="header-subtitle">Automated Backup Recoverability Testing &mdash; Community Script</div>
    <div class="header-platform">Nutanix AHV Platform</div>
    <div class="header-meta">
      <span><strong>Generated:</strong> $reportDate</span>
      <span><strong>Duration:</strong> $durationStr</span>
      <span><strong>VBR Server:</strong> $VBRServer</span>
      <span><strong>Prism Central:</strong> $PrismCentral</span>
    </div>
  </div>

  $(if ($DryRun) { '<div class="dry-run-banner">DRY RUN - No VMs were recovered. Results below show connectivity validation only.</div>' })

  <div class="overall-status">
    <div>
      <div class="overall-status-text">$overallStatus</div>
      <div class="overall-status-detail">$passedTests of $totalTests tests passed across $totalVMs VM(s)</div>
    </div>
    <div style="text-align: right;">
      <div style="font-size: 48px; font-weight: 300; color: ${statusColor};">$passRate%</div>
      <div style="font-size: 13px; color: var(--ms-gray-90);">Test Pass Rate</div>
    </div>
  </div>

  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">VMs Tested</div>
      <div class="kpi-value">$totalVMs</div>
      <div class="kpi-subtext">$fullyPassedVMs fully passed</div>
    </div>
    <div class="kpi-card$(if($failedTests -gt 0){' fail'})">
      <div class="kpi-label">Total Tests</div>
      <div class="kpi-value">$totalTests</div>
      <div class="kpi-subtext">$passedTests passed, $failedTests failed</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">VM Pass Rate</div>
      <div class="kpi-value">$vmPassRate%</div>
      <div class="kpi-subtext">VMs with all tests passing</div>
    </div>
    <div class="kpi-card nutanix">
      <div class="kpi-label">Isolated Network</div>
      <div class="kpi-value" style="font-size: 20px;">$($IsolatedNetwork.Name)</div>
      <div class="kpi-subtext">VLAN $($IsolatedNetwork.VlanId)</div>
    </div>
  </div>

  <div class="section">
    <div class="section-title">VM Verification Summary</div>
    <table>
      <thead>
        <tr>
          <th>VM Name</th>
          <th>Backup Job</th>
          <th>Restore Point</th>
          <th>Tests (Pass/Total)</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
$vmDetailRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-title">Detailed Test Results</div>
    <table>
      <thead>
        <tr>
          <th>VM Name</th>
          <th>Test</th>
          <th>Result</th>
          <th>Details</th>
          <th>Duration</th>
        </tr>
      </thead>
      <tbody>
$testDetailRows
      </tbody>
    </table>
  </div>

  <div class="section">
    <div class="section-title">Test Configuration</div>
    <div class="info-card">
      <div class="info-card-title">SureBackup Parameters</div>
      <div class="info-card-text">
        <strong>VBR Server:</strong> $VBRServer |
        <strong>Prism Central:</strong> $PrismCentral<br>
        <strong>Isolated Network:</strong> $($IsolatedNetwork.Name) (VLAN $($IsolatedNetwork.VlanId))<br>
        <strong>Boot Timeout:</strong> ${TestBootTimeoutSec}s |
        <strong>Ping Test:</strong> $TestPing |
        <strong>Port Tests:</strong> $(if($TestPorts){"$($TestPorts -join ', ')"}else{"None"})<br>
        <strong>DNS Test:</strong> $TestDNS |
        <strong>HTTP Endpoints:</strong> $(if($TestHttpEndpoints){"$($TestHttpEndpoints -join ', ')"}else{"None"})<br>
        <strong>Custom Script:</strong> $(if($TestCustomScript){$TestCustomScript}else{"None"}) |
        <strong>Max Concurrent VMs:</strong> $MaxConcurrentVMs<br>
        <strong>Application Groups:</strong> $(if($ApplicationGroups){"$($ApplicationGroups.Count) group(s) defined"}else{"None (parallel recovery)"})
      </div>
    </div>
  </div>

  <div class="section">
    <div class="section-title">Execution Log</div>
    <div class="log-section">
      <table>
        <thead>
          <tr><th>Timestamp</th><th>Level</th><th>Message</th></tr>
        </thead>
        <tbody>
$logRows
        </tbody>
      </table>
    </div>
  </div>

  <div class="footer">
    <p>Backup Verification for Nutanix AHV v1.1.0 (Community Tool) | Report generated on $reportDate</p>
    <p>Uses Veeam Backup & Replication + Nutanix Prism Central REST API $PrismApiVersion | Not an official Veeam product</p>
  </div>
</div>
</body>
</html>
"@

  return $html
}
