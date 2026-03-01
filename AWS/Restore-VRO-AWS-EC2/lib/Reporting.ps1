# =============================
# HTML Report Generation
# =============================

<#
.SYNOPSIS
  Generates a professional HTML restore report.
.PARAMETER RestorePoint
  The Veeam restore point used.
.PARAMETER EC2Config
  The target EC2 configuration.
.PARAMETER Instance
  The restored EC2 instance (or $null on failure).
.PARAMETER Duration
  Total operation duration.
.PARAMETER Success
  Whether the restore succeeded.
.PARAMETER ErrorMessage
  Error message if the restore failed.
#>
function New-RestoreReport {
  param(
    [object]$RestorePoint,
    [hashtable]$EC2Config,
    [object]$Instance,
    [TimeSpan]$Duration,
    [bool]$Success,
    [string]$ErrorMessage
  )

  if (-not $GenerateReport) { return }

  Write-Log "Generating HTML restore report..."

  $statusColor = if ($Success) { "#00B336" } else { "#E74C3C" }
  $statusText = if ($Success) { "SUCCESS" } else { "FAILED" }
  $instanceId = if ($Instance) { $Instance.InstanceId } else { "N/A" }
  $privateIp = if ($Instance) { $Instance.PrivateIpAddress } else { "N/A" }
  $publicIp = if ($Instance -and $Instance.PublicIpAddress) { $Instance.PublicIpAddress } else { "N/A" }
  $rpTime = if ($RestorePoint) { $RestorePoint.CreationTime.ToString("yyyy-MM-dd HH:mm:ss UTC") } else { "N/A" }

  $logRows = ($script:LogEntries | ForEach-Object {
    $levelColor = switch ($_.Level) {
      "ERROR"   { "#E74C3C" }
      "WARNING" { "#F39C12" }
      "SUCCESS" { "#00B336" }
      default   { "#6C757D" }
    }
    "<tr><td style='white-space:nowrap'>$($_.Timestamp)</td><td><span style='color:$levelColor;font-weight:600'>$($_.Level)</span></td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Message))</td></tr>"
  }) -join "`n"

  # HTML-encode all user-controlled values for XSS prevention
  $safeBackupName = [System.Web.HttpUtility]::HtmlEncode($BackupName)
  $safeVMName = [System.Web.HttpUtility]::HtmlEncode($VMName)
  $safeRestoreMode = [System.Web.HttpUtility]::HtmlEncode($RestoreMode)
  $safeInstanceId = [System.Web.HttpUtility]::HtmlEncode($instanceId)
  $safeInstanceType = [System.Web.HttpUtility]::HtmlEncode($InstanceType)
  $safeAWSRegion = [System.Web.HttpUtility]::HtmlEncode($AWSRegion)
  $safePrivateIp = [System.Web.HttpUtility]::HtmlEncode($privateIp)
  $safePublicIp = [System.Web.HttpUtility]::HtmlEncode($publicIp)
  $safeDiskType = [System.Web.HttpUtility]::HtmlEncode($DiskType)
  $safeVpcId = [System.Web.HttpUtility]::HtmlEncode($(if($EC2Config){$EC2Config.VpcId}else{"N/A"}))
  $safeSubnetId = [System.Web.HttpUtility]::HtmlEncode($(if($EC2Config){$EC2Config.SubnetId}else{"N/A"}))
  $safeVROPlanName = [System.Web.HttpUtility]::HtmlEncode($(if($VROPlanName){$VROPlanName}else{"N/A"}))
  $safeVROStepName = [System.Web.HttpUtility]::HtmlEncode($(if($VROStepName){$VROStepName}else{"N/A"}))
  $safeVBRServer = [System.Web.HttpUtility]::HtmlEncode($VBRServer)

  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>VRO AWS EC2 Restore Report</title>
  <style>
    :root { --veeam-green: #00B336; --veeam-dark: #1A1A2E; }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: #F4F6F9; color: #2D3748; line-height: 1.6; }
    .container { max-width: 960px; margin: 0 auto; padding: 24px; }
    .header { background: linear-gradient(135deg, var(--veeam-dark) 0%, #16213E 100%); color: #fff; padding: 32px; border-radius: 12px 12px 0 0; }
    .header h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 4px; }
    .header .subtitle { opacity: 0.8; font-size: 0.9rem; }
    .status-banner { padding: 16px 32px; color: #fff; font-weight: 600; font-size: 1.1rem; background: $statusColor; }
    .card { background: #fff; border-radius: 0 0 12px 12px; box-shadow: 0 2px 8px rgba(0,0,0,0.08); margin-bottom: 24px; overflow: hidden; }
    .section { padding: 24px 32px; border-bottom: 1px solid #E2E8F0; }
    .section:last-child { border-bottom: none; }
    .section h2 { font-size: 1.1rem; color: var(--veeam-dark); margin-bottom: 16px; }
    .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
    .field { }
    .field .label { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; color: #718096; font-weight: 600; }
    .field .value { font-size: 0.95rem; font-weight: 500; color: #2D3748; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th { text-align: left; padding: 8px 12px; background: #F7FAFC; color: #4A5568; font-weight: 600; border-bottom: 2px solid #E2E8F0; }
    td { padding: 6px 12px; border-bottom: 1px solid #EDF2F7; vertical-align: top; }
    .footer { text-align: center; padding: 16px; font-size: 0.8rem; color: #A0AEC0; }
    @media print { body { background: #fff; } .container { max-width: 100%; padding: 0; } }
    @media (max-width: 640px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div class="container">
    <div class="card">
      <div class="header">
        <h1>VRO AWS EC2 Restore Report</h1>
        <div class="subtitle">Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss UTC")</div>
      </div>
      <div class="status-banner">Restore Status: $statusText$(if($ErrorMessage){ " - $([System.Web.HttpUtility]::HtmlEncode($ErrorMessage))" })</div>

      <div class="section">
        <h2>Restore Summary</h2>
        <div class="grid">
          <div class="field"><div class="label">Backup Name</div><div class="value">$safeBackupName</div></div>
          <div class="field"><div class="label">VM Name</div><div class="value">$(if($safeVMName){$safeVMName}else{"(all)"})</div></div>
          <div class="field"><div class="label">Restore Point</div><div class="value">$rpTime</div></div>
          <div class="field"><div class="label">Restore Mode</div><div class="value">$safeRestoreMode</div></div>
          <div class="field"><div class="label">Duration</div><div class="value">$($Duration.ToString('hh\:mm\:ss'))</div></div>
          <div class="field"><div class="label">Clean Point Scan</div><div class="value">$(if($UseLatestCleanPoint){"Enabled"}else{"Disabled"})</div></div>
        </div>
      </div>

      <div class="section">
        <h2>EC2 Instance Details</h2>
        <div class="grid">
          <div class="field"><div class="label">Instance ID</div><div class="value">$safeInstanceId</div></div>
          <div class="field"><div class="label">Instance Type</div><div class="value">$safeInstanceType</div></div>
          <div class="field"><div class="label">Region</div><div class="value">$safeAWSRegion</div></div>
          <div class="field"><div class="label">Private IP</div><div class="value">$safePrivateIp</div></div>
          <div class="field"><div class="label">Public IP</div><div class="value">$safePublicIp</div></div>
          <div class="field"><div class="label">Disk Type</div><div class="value">$safeDiskType$(if($EncryptVolumes){" (KMS Encrypted)"})</div></div>
          <div class="field"><div class="label">VPC</div><div class="value">$safeVpcId</div></div>
          <div class="field"><div class="label">Subnet</div><div class="value">$safeSubnetId</div></div>
        </div>
      </div>

      <div class="section">
        <h2>VRO Context</h2>
        <div class="grid">
          <div class="field"><div class="label">VRO Plan</div><div class="value">$safeVROPlanName</div></div>
          <div class="field"><div class="label">VRO Step</div><div class="value">$safeVROStepName</div></div>
          <div class="field"><div class="label">VBR Server</div><div class="value">$safeVBRServer</div></div>
          <div class="field"><div class="label">Dry Run</div><div class="value">$(if($DryRun){"Yes"}else{"No"})</div></div>
        </div>
      </div>

      $(if ($RTOTargetMinutes) {
        $rtoResult = Measure-RTOCompliance -ActualDuration $Duration
        $rtoColor = if ($rtoResult -and $rtoResult.Met) { "#00B336" } else { "#E74C3C" }
        $rtoStatus = if ($rtoResult -and $rtoResult.Met) { "MET" } else { "BREACHED" }
        $rtoActual = if ($rtoResult) { "$($rtoResult.RTOActual) min" } else { "N/A" }
        $rtoDelta = if ($rtoResult) { "$($rtoResult.Delta) min" } else { "N/A" }
@"
      <div class="section">
        <h2>SLA/RTO Compliance</h2>
        <div class="grid">
          <div class="field"><div class="label">RTO Target</div><div class="value">$RTOTargetMinutes min</div></div>
          <div class="field"><div class="label">RTO Actual</div><div class="value">$rtoActual</div></div>
          <div class="field"><div class="label">Status</div><div class="value" style="color:$rtoColor;font-weight:700">$rtoStatus</div></div>
          <div class="field"><div class="label">Delta</div><div class="value">$rtoDelta</div></div>
        </div>
      </div>
"@
      })

      $(if ($script:HealthCheckResults.Count -gt 0) {
        $hcRows = ($script:HealthCheckResults | ForEach-Object {
          $hcColor = if ($_.Passed) { "#00B336" } else { "#E74C3C" }
          $hcResult = if ($_.Passed) { "PASS" } else { "FAIL" }
          "<tr><td>$($_.TestName)</td><td style='color:$hcColor;font-weight:600'>$hcResult</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Details))</td><td>$([Math]::Round($_.Duration, 1))s</td></tr>"
        }) -join "`n"
@"
      <div class="section">
        <h2>Application Health Checks</h2>
        <table>
          <thead><tr><th>Test</th><th>Result</th><th>Details</th><th>Duration</th></tr></thead>
          <tbody>$hcRows</tbody>
        </table>
      </div>
"@
      })

      <div class="section">
        <h2>Execution Log</h2>
        <table>
          <thead><tr><th>Timestamp</th><th>Level</th><th>Message</th></tr></thead>
          <tbody>$logRows</tbody>
        </table>
      </div>
    </div>
    <div class="footer">Veeam Recovery Orchestrator &middot; AWS EC2 Restore Plugin v2.0.0</div>
  </div>
</body>
</html>
"@

  $html | Set-Content -Path $reportFile -Encoding UTF8
  Write-Log "Report saved: $reportFile" -Level SUCCESS
}
