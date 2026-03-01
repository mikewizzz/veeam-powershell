# =========================================================================
# HtmlReport.ps1 - Full HTML report generation (CSS + markup)
# =========================================================================

<#
.SYNOPSIS
  Builds the complete HTML report with all sections.
.DESCRIPTION
  Generates a professional Microsoft Fluent Design System HTML report.
  Quick mode: tenant info, KPIs, workload analysis, methodology, sizing params, artifacts.
  Full mode adds: executive summary, license overview, data protection landscape,
  identity & access security, and recommendations.
.NOTES
  CSS-only visuals, no JavaScript, no external dependencies.
  Works as a static file and prints correctly.
#>
function Build-HtmlReport {
  # =============================
  # CSS
  # =============================
  $css = @"
:root {
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --ms-blue-light: #50E6FF;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --veeam-green: #00B336;
  --color-success: #107C10;
  --color-warning: #F7630C;
  --color-danger: #D13438;
  --color-info: #0078D4;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
  --shadow-depth-16: 0 6.4px 14.4px 0 rgba(0,0,0,.132), 0 1.2px 3.6px 0 rgba(0,0,0,.108);
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: 'Segoe UI', -apple-system, BlinkMacSystemFont, 'Roboto', 'Helvetica Neue', sans-serif;
  background: var(--ms-gray-10);
  color: var(--ms-gray-160);
  line-height: 1.6;
  font-size: 14px;
  -webkit-font-smoothing: antialiased;
}

.container { max-width: 1440px; margin: 0 auto; padding: 40px 32px; }

/* Header */
.header {
  background: white;
  border-left: 4px solid var(--ms-blue);
  padding: 32px;
  margin-bottom: 32px;
  box-shadow: var(--shadow-depth-4);
  border-radius: 2px;
}
.header-title {
  font-size: 28px; font-weight: 600; color: var(--ms-gray-160);
  margin-bottom: 8px; letter-spacing: -0.02em;
}
.header-subtitle { font-size: 16px; color: var(--ms-gray-90); font-weight: 400; }
.badge {
  display: inline-block; padding: 4px 12px; background: var(--ms-blue); color: white;
  border-radius: 12px; font-size: 12px; font-weight: 600; margin-left: 12px;
  text-transform: uppercase; letter-spacing: 0.05em;
}

/* Tenant Info */
.tenant-info {
  background: white; padding: 24px 32px; margin-bottom: 24px;
  border-radius: 2px; box-shadow: var(--shadow-depth-4);
}
.tenant-info-title {
  font-size: 12px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 12px;
}
.tenant-info-row {
  display: flex; flex-wrap: wrap; gap: 24px; padding: 8px 0;
  border-bottom: 1px solid var(--ms-gray-30);
}
.tenant-info-row:last-child { border-bottom: none; }
.tenant-info-item { display: flex; gap: 8px; }
.tenant-info-label { color: var(--ms-gray-90); font-weight: 400; }
.tenant-info-value { color: var(--ms-gray-160); font-weight: 600; }

/* KPI Cards */
.kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 24px; margin-bottom: 32px;
}
.kpi-card {
  background: white; padding: 24px; border-radius: 2px;
  box-shadow: var(--shadow-depth-4); transition: all 0.2s ease;
  border-top: 3px solid var(--ms-blue);
}
.kpi-card:hover { box-shadow: var(--shadow-depth-8); transform: translateY(-2px); }
.kpi-card:nth-child(4) { border-top-color: var(--veeam-green); }
.kpi-label {
  font-size: 12px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.05em; color: var(--ms-gray-90); margin-bottom: 12px;
}
.kpi-value {
  font-size: 36px; font-weight: 600; color: var(--ms-gray-160);
  line-height: 1.2; margin-bottom: 8px;
}
.kpi-subtext { font-size: 13px; color: var(--ms-gray-90); font-weight: 400; }

/* Section */
.section {
  background: white; padding: 32px; margin-bottom: 24px;
  border-radius: 2px; box-shadow: var(--shadow-depth-4);
}
.section-title {
  font-size: 20px; font-weight: 600; color: var(--ms-gray-160);
  margin-bottom: 20px; padding-bottom: 12px; border-bottom: 2px solid var(--ms-gray-30);
}

/* Tables */
.table-container { overflow-x: auto; margin-top: 16px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th {
  padding: 12px 16px; text-align: left; font-weight: 600; color: var(--ms-gray-130);
  font-size: 12px; text-transform: uppercase; letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}
td { padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30); color: var(--ms-gray-160); }
tbody tr:hover { background: var(--ms-gray-10); }
tbody tr:last-child td { border-bottom: none; }

/* Info Cards */
.info-card {
  background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue);
  padding: 20px 24px; margin: 16px 0; border-radius: 2px;
}
.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 13px; line-height: 1.6; margin-bottom: 8px; }
.info-card-text:last-child { margin-bottom: 0; }

/* Code Block */
.code-block {
  background: var(--ms-gray-160); color: var(--ms-blue-light);
  padding: 20px 24px; border-radius: 2px;
  font-family: 'Consolas', 'Monaco', 'Courier New', monospace;
  font-size: 13px; line-height: 1.8; overflow-x: auto; margin-top: 16px;
}
.code-line { display: block; white-space: nowrap; }

/* Progress Bar */
.progress-bar {
  width: 100%; height: 24px; background: var(--ms-gray-30); border-radius: 12px;
  overflow: hidden; margin: 8px 0;
}
.progress-fill {
  height: 100%; border-radius: 12px; transition: width 0.3s ease;
  display: flex; align-items: center; justify-content: center;
  font-size: 12px; font-weight: 600; color: white; min-width: 40px;
}
.progress-fill.green { background: var(--color-success); }
.progress-fill.yellow { background: var(--color-warning); }
.progress-fill.red { background: var(--color-danger); }
.progress-fill.blue { background: var(--color-info); }

/* Status Dot */
.status-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  margin-right: 8px; vertical-align: middle;
}
.status-dot.green { background: var(--color-success); }
.status-dot.yellow { background: var(--color-warning); }
.status-dot.red { background: var(--color-danger); }
.status-dot.gray { background: var(--ms-gray-50); }

/* Score Circle */
.score-circle {
  width: 120px; height: 120px; border-radius: 50%;
  display: flex; align-items: center; justify-content: center; flex-direction: column;
  font-size: 36px; font-weight: 700; color: white; margin: 0 auto 16px;
}
.score-circle.green { background: var(--color-success); }
.score-circle.yellow { background: var(--color-warning); }
.score-circle.red { background: var(--color-danger); }
.score-circle-label { font-size: 11px; font-weight: 400; opacity: 0.9; }

/* Finding Cards */
.finding-card {
  background: white; border-left: 4px solid var(--ms-gray-50);
  padding: 16px 20px; margin: 12px 0; border-radius: 2px;
  box-shadow: var(--shadow-depth-4);
}
.finding-card.severity-high { border-left-color: var(--color-danger); }
.finding-card.severity-medium { border-left-color: var(--color-warning); }
.finding-card.severity-low { border-left-color: var(--color-info); }
.finding-card.severity-info { border-left-color: var(--color-success); }
.finding-card-title { font-weight: 600; font-size: 14px; margin-bottom: 6px; }
.finding-card-detail { font-size: 13px; color: var(--ms-gray-90); line-height: 1.5; }
.finding-card-badge {
  display: inline-block; padding: 2px 8px; border-radius: 4px;
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.03em; margin-left: 8px; vertical-align: middle;
}
.finding-card-badge.strong { background: #DFF6DD; color: var(--color-success); }
.finding-card-badge.opportunity { background: #FFF4CE; color: #8A6914; }
.finding-card-badge.informational { background: #F0F6FF; color: var(--color-info); }

/* Recommendation Cards */
.recommendation-card {
  background: white; padding: 20px 24px; margin: 12px 0;
  border-radius: 2px; box-shadow: var(--shadow-depth-4); border-left: 4px solid var(--ms-gray-50);
}
.recommendation-card.tier-immediate { border-left-color: var(--color-danger); }
.recommendation-card.tier-short-term { border-left-color: var(--color-warning); }
.recommendation-card.tier-strategic { border-left-color: var(--color-info); }
.priority-badge {
  display: inline-block; padding: 3px 10px; border-radius: 4px;
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.03em; color: white; margin-bottom: 8px;
}
.priority-badge.immediate { background: var(--color-danger); }
.priority-badge.short-term { background: var(--color-warning); }
.priority-badge.strategic { background: var(--color-info); }
.rec-title { font-weight: 600; font-size: 15px; margin-bottom: 6px; }
.rec-detail { font-size: 13px; color: var(--ms-gray-130); line-height: 1.5; margin-bottom: 6px; }
.rec-rationale { font-size: 12px; color: var(--ms-gray-90); font-style: italic; }

/* Coverage Grid */
.coverage-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 16px; margin-top: 16px;
}
.coverage-item {
  background: var(--ms-gray-10); border-radius: 2px; padding: 20px;
  border-top: 3px solid var(--ms-blue);
}
.coverage-item-title { font-weight: 600; font-size: 15px; margin-bottom: 8px; }
.coverage-item-stat {
  font-size: 24px; font-weight: 600; color: var(--ms-gray-160); margin-bottom: 4px;
}
.coverage-item-detail { font-size: 12px; color: var(--ms-gray-90); margin-bottom: 4px; }

/* Callout Card */
.callout-card {
  background: var(--ms-gray-10); border: 1px solid var(--ms-gray-30);
  border-radius: 2px; padding: 24px; margin: 16px 0;
}
.callout-card-title {
  font-weight: 600; font-size: 16px; margin-bottom: 16px;
  color: var(--ms-gray-160); text-align: center;
}
.callout-grid {
  display: grid; grid-template-columns: 1fr 1fr; gap: 24px;
}
.callout-column-title {
  font-weight: 600; font-size: 13px; text-transform: uppercase;
  letter-spacing: 0.03em; margin-bottom: 12px; padding-bottom: 8px;
  border-bottom: 2px solid var(--ms-gray-50);
}
.callout-column-title.provider { color: var(--ms-blue); border-bottom-color: var(--ms-blue); }
.callout-column-title.customer { color: var(--veeam-green); border-bottom-color: var(--veeam-green); }
.callout-item { font-size: 13px; color: var(--ms-gray-130); padding: 4px 0; }

/* Identity KPI Grid */
.identity-kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 16px; margin: 16px 0;
}
.identity-kpi {
  background: var(--ms-gray-10); padding: 16px; border-radius: 2px; text-align: center;
}
.identity-kpi-value { font-size: 28px; font-weight: 600; color: var(--ms-gray-160); }
.identity-kpi-label { font-size: 12px; color: var(--ms-gray-90); margin-top: 4px; }

/* File List */
.file-list { list-style: none; padding: 0; margin: 16px 0 0 0; }
.file-item {
  padding: 10px 16px; border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-130); font-size: 13px;
}
.file-item:last-child { border-bottom: none; }

/* Footer */
.footer { text-align: center; padding: 32px 0; color: var(--ms-gray-90); font-size: 12px; }

/* Responsive */
@media (max-width: 768px) {
  .container { padding: 20px 16px; }
  .header { padding: 20px; }
  .header-title { font-size: 22px; }
  .kpi-grid { grid-template-columns: 1fr; }
  .section { padding: 20px; }
  .tenant-info-row { flex-direction: column; gap: 12px; }
  .callout-grid { grid-template-columns: 1fr; }
  .coverage-grid { grid-template-columns: 1fr; }
  .identity-kpi-grid { grid-template-columns: repeat(2, 1fr); }
}

@media print {
  body { background: white; }
  .container { max-width: 100%; }
  .kpi-card, .section, .tenant-info { box-shadow: none; border: 1px solid var(--ms-gray-30); }
  .kpi-card:hover { transform: none; }
  .finding-card, .recommendation-card { box-shadow: none; border: 1px solid var(--ms-gray-30); }
  .score-circle { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
  .progress-fill { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
  .priority-badge { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
}
"@

  # =============================
  # Helper: progress bar color
  # =============================
  function _Get-ProgressColor([double]$pct) {
    if ($pct -ge 80) { return "green" }
    elseif ($pct -ge 50) { return "yellow" }
    else { return "red" }
  }

  function _Get-ScoreColor([int]$score) {
    if ($score -ge 70) { return "green" }
    elseif ($score -ge 40) { return "yellow" }
    else { return "red" }
  }

  # =============================
  # Build HTML sections
  # =============================
  $htmlParts = New-Object System.Collections.Generic.List[string]

  # DOCTYPE + head
  $htmlParts.Add(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Microsoft 365 Backup Sizing Assessment</title>
<style>
$css
</style>
</head>
<body>
<div class="container">
"@)

  # Header
  $htmlParts.Add(@"
  <div class="header">
    <h1 class="header-title">
      Microsoft 365 Backup Sizing Assessment
      <span class="badge">$(if($Full){"Full"}else{"Quick"})</span>
    </h1>
    <div class="header-subtitle">Generated: $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm") UTC</div>
  </div>
"@)

  # Tenant Info
  $htmlParts.Add(@"
  <div class="tenant-info">
    <div class="tenant-info-title">Tenant Information</div>
    <div class="tenant-info-row">
      $(if($script:OrgName){"<div class='tenant-info-item'><span class='tenant-info-label'>Organization:</span><span class='tenant-info-value'>$(Escape-Html $script:OrgName)</span></div>"}else{""})
      $(if($script:OrgId){"<div class='tenant-info-item'><span class='tenant-info-label'>Tenant ID:</span><span class='tenant-info-value'>$(Escape-Html $script:OrgId)</span></div>"}else{""})
    </div>
    <div class="tenant-info-row">
      $(if($script:DefaultDomain){"<div class='tenant-info-item'><span class='tenant-info-label'>Default Domain:</span><span class='tenant-info-value'>$(Escape-Html $script:DefaultDomain)</span></div>"}else{""})
      <div class="tenant-info-item">
        <span class="tenant-info-label">Environment:</span>
        <span class="tenant-info-value">$(Escape-Html $script:envName)</span>
      </div>
      $(if($script:TenantCategory){"<div class='tenant-info-item'><span class='tenant-info-label'>Category:</span><span class='tenant-info-value'>$(Escape-Html $script:TenantCategory)</span></div>"}else{""})
    </div>
  </div>
"@)

  # =============================
  # FULL MODE: Executive Summary
  # =============================
  if ($Full -and $script:readinessScore -ne $null) {
    $scoreColor = _Get-ScoreColor $script:readinessScore
    $topFindings = @($script:findings | Select-Object -First 5)

    $findingsHtml = ""
    foreach ($f in $topFindings) {
      $severityClass = "severity-$($f.Severity.ToLower())"
      $toneClass = $f.Tone.ToLower()
      $findingsHtml += @"
      <div class="finding-card $severityClass">
        <div class="finding-card-title">$(Escape-Html $f.Title)<span class="finding-card-badge $toneClass">$(Escape-Html $f.Tone)</span></div>
        <div class="finding-card-detail">$(Escape-Html $f.Detail)</div>
      </div>
"@
    }

    $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Executive Summary</h2>
    <div style="display: flex; align-items: flex-start; gap: 32px; flex-wrap: wrap;">
      <div style="text-align: center; min-width: 160px;">
        <div class="score-circle $scoreColor">
          $($script:readinessScore)
          <span class="score-circle-label">/ 100</span>
        </div>
        <div style="font-weight: 600; font-size: 14px; color: var(--ms-gray-130);">Protection Readiness</div>
        <div style="font-size: 12px; color: var(--ms-gray-90); margin-top: 4px;">Composite score from identity &amp; security signals</div>
      </div>
      <div style="flex: 1; min-width: 300px;">
        <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Key Findings</div>
        $findingsHtml
      </div>
    </div>
  </div>
"@)
  }

  # KPI Grid
  $htmlParts.Add(@"
  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">Users to Protect</div>
      <div class="kpi-value">$($script:UsersToProtect)</div>
      <div class="kpi-subtext">Active user accounts</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Total Dataset</div>
      <div class="kpi-value">$($script:totalTB) TB</div>
      <div class="kpi-subtext">$($script:totalGB) GB | $($script:totalTiB) TiB (binary)</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Projected Growth</div>
      <div class="kpi-value">$(Format-Pct $AnnualGrowthPct)</div>
      <div class="kpi-subtext">Annual growth rate (modeled)</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Recommended MBS Capacity</div>
      <div class="kpi-value">$($script:suggestedStartGB) GB</div>
      <div class="kpi-subtext">Modeled estimate: $($script:mbsEstimateGB) GB + $(Format-Pct $BufferPct) buffer</div>
    </div>
  </div>
"@)

  # =============================
  # FULL MODE: License Overview
  # =============================
  if ($Full -and $script:licenseData -and $script:licenseData -isnot [string] -and @($script:licenseData).Count -gt 0) {
    $licRows = ""
    foreach ($lic in $script:licenseData) {
      $barColor = _Get-ProgressColor $lic.UtilizationPct
      $barWidth = [math]::Min($lic.UtilizationPct, 100)
      $licRows += @"
          <tr>
            <td><strong>$(Escape-Html $lic.DisplayName)</strong></td>
            <td>$(Escape-Html $lic.SkuPartNumber)</td>
            <td style="text-align:right">$('{0:N0}' -f $lic.Purchased)</td>
            <td style="text-align:right">$('{0:N0}' -f $lic.Assigned)</td>
            <td style="text-align:right">$('{0:N0}' -f $lic.Available)</td>
            <td style="min-width:120px">
              <div class="progress-bar" style="height:18px">
                <div class="progress-fill $barColor" style="width:${barWidth}%">$($lic.UtilizationPct)%</div>
              </div>
            </td>
          </tr>
"@
    }

    $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">License Overview</h2>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>License</th>
            <th>SKU</th>
            <th style="text-align:right">Purchased</th>
            <th style="text-align:right">Assigned</th>
            <th style="text-align:right">Available</th>
            <th>Utilization</th>
          </tr>
        </thead>
        <tbody>
$licRows
        </tbody>
      </table>
    </div>
  </div>
"@)
  }

  # Workload Analysis
  $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Workload Analysis</h2>
    <div class="table-container">
      <table>
        <thead>
          <tr>
            <th>Workload</th>
            <th>Objects</th>
            <th>Secondary</th>
            <th>Source (GB)</th>
            <th>Source (GiB)</th>
            <th>Annual Growth</th>
            <th>Notes</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>Exchange Online</strong></td>
            <td>$($script:exUsers.Count)</td>
            <td>$($script:exShared.Count) shared</td>
            <td>$($script:exGB)</td>
            <td>$($script:exGiB)</td>
            <td>$(Format-Pct $script:exGrowth)</td>
            <td>Archive/RIF included only if enabled</td>
          </tr>
          <tr>
            <td><strong>OneDrive for Business</strong></td>
            <td>$($script:odActive.Count)</td>
            <td>&mdash;</td>
            <td>$($script:odGB)</td>
            <td>$($script:odGiB)</td>
            <td>$(Format-Pct $script:odGrowth)</td>
            <td>Filtered by AD group (if specified)</td>
          </tr>
          <tr>
            <td><strong>SharePoint Online</strong></td>
            <td>$($script:spActive.Count)</td>
            <td>$($script:spFiles) files</td>
            <td>$($script:spGB)</td>
            <td>$($script:spGiB)</td>
            <td>$(Format-Pct $script:spGrowth)</td>
            <td>Tenant-wide (no group filtering)</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
"@)

  # =============================
  # FULL MODE: Data Protection Landscape
  # =============================
  if ($Full) {
    $teamsDisplay = if ($script:teamsCount -is [int]) { "$($script:teamsCount) Teams" } else { Format-CountValue $script:teamsCount }

    $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Data Protection Landscape</h2>

    <div class="callout-card">
      <div class="callout-card-title">Microsoft Shared Responsibility Model</div>
      <div class="callout-grid">
        <div>
          <div class="callout-column-title provider">Microsoft Manages</div>
          <div class="callout-item">Infrastructure availability &amp; uptime</div>
          <div class="callout-item">Physical data center security</div>
          <div class="callout-item">Network &amp; compute redundancy</div>
          <div class="callout-item">Service-level patch management</div>
          <div class="callout-item">Basic data replication (geo-redundancy)</div>
        </div>
        <div>
          <div class="callout-column-title customer">Customer Manages</div>
          <div class="callout-item">Data backup &amp; long-term retention</div>
          <div class="callout-item">Recovery from accidental or malicious deletion</div>
          <div class="callout-item">Entra ID configuration protection (CA, Intune, roles)</div>
          <div class="callout-item">Regulatory &amp; compliance retention requirements</div>
          <div class="callout-item">Business continuity &amp; disaster recovery</div>
        </div>
      </div>
    </div>

    <div class="coverage-grid">
      <div class="coverage-item">
        <div class="coverage-item-title">Exchange Online</div>
        <div class="coverage-item-stat">$('{0:N2}' -f $script:exGB) GB</div>
        <div class="coverage-item-detail">$($script:exUsers.Count) mailboxes + $($script:exShared.Count) shared</div>
        <div class="coverage-item-detail">Conversations, calendars, contacts</div>
      </div>
      <div class="coverage-item">
        <div class="coverage-item-title">OneDrive for Business</div>
        <div class="coverage-item-stat">$('{0:N2}' -f $script:odGB) GB</div>
        <div class="coverage-item-detail">$($script:odActive.Count) accounts</div>
        <div class="coverage-item-detail">User files, documents, media</div>
      </div>
      <div class="coverage-item">
        <div class="coverage-item-title">SharePoint Online</div>
        <div class="coverage-item-stat">$('{0:N2}' -f $script:spGB) GB</div>
        <div class="coverage-item-detail">$($script:spActive.Count) sites, $($script:spFiles) files</div>
        <div class="coverage-item-detail">Team sites, document libraries, lists</div>
      </div>
      <div class="coverage-item" style="border-top-color: var(--veeam-green);">
        <div class="coverage-item-title">Entra ID Configuration</div>
        <div class="coverage-item-stat">$(Format-CountValue $script:caPolicyCount) CA Policies</div>
        <div class="coverage-item-detail">$(Format-CountValue $script:intuneManagedDevices) managed devices</div>
        <div class="coverage-item-detail">Conditional Access, Intune policies, directory roles</div>
      </div>
    </div>
  </div>
"@)
  }

  # =============================
  # FULL MODE: Identity & Access Security
  # =============================
  if ($Full) {
    $globalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $null }
    $adminDot = if ($globalAdminCount -ne $null -and $globalAdminCount -le $ADMIN_THRESHOLD) { "green" } elseif ($globalAdminCount -ne $null) { "yellow" } else { "gray" }

    $riskyTotal = if ($script:riskyUsers -is [hashtable]) { $script:riskyUsers.Total } else { $null }
    $riskyDot = if ($riskyTotal -ne $null -and $riskyTotal -eq 0) { "green" } elseif ($riskyTotal -ne $null -and $script:riskyUsers.High -eq 0) { "yellow" } elseif ($riskyTotal -ne $null) { "red" } else { "gray" }

    # MFA progress bar
    $mfaBarHtml = ""
    if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
      $mfaPctVal = [math]::Round(($script:mfaCount / $script:userCount) * 100, 1)
      $mfaColor = _Get-ProgressColor $mfaPctVal
      $mfaBarHtml = @"
      <div style="margin: 16px 0;">
        <div style="font-weight: 600; font-size: 13px; margin-bottom: 4px;">MFA Adoption: ${mfaPctVal}% ($($script:mfaCount) of $($script:userCount) users)</div>
        <div class="progress-bar"><div class="progress-fill $mfaColor" style="width:${mfaPctVal}%">${mfaPctVal}%</div></div>
      </div>
"@
    } elseif ($script:mfaCount -eq "access_denied") {
      $mfaBarHtml = '<div style="margin: 16px 0; font-size: 13px; color: var(--ms-gray-90);">MFA data requires AuditLog.Read.All permission</div>'
    }

    # Secure Score progress bar
    $secScoreBarHtml = ""
    if ($script:secureScore -is [hashtable] -and $script:secureScore.MaxScore -gt 0) {
      $secPct = $script:secureScore.Percentage
      $secColor = _Get-ProgressColor $secPct
      $secScoreBarHtml = @"
      <div style="margin: 16px 0;">
        <div style="font-weight: 600; font-size: 13px; margin-bottom: 4px;">Microsoft Secure Score: ${secPct}% ($($script:secureScore.CurrentScore) of $($script:secureScore.MaxScore))</div>
        <div class="progress-bar"><div class="progress-fill $secColor" style="width:${secPct}%">${secPct}%</div></div>
      </div>
"@
    } elseif ($script:secureScore -eq "access_denied") {
      $secScoreBarHtml = '<div style="margin: 16px 0; font-size: 13px; color: var(--ms-gray-90);">Secure Score requires SecurityEvents.Read.All permission</div>'
    }

    $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Identity &amp; Access Security</h2>

    <div class="identity-kpi-grid">
      <div class="identity-kpi">
        <div class="identity-kpi-value"><span class="status-dot $adminDot"></span>$(if($globalAdminCount -ne $null){$globalAdminCount}else{Format-CountValue $script:globalAdmins})</div>
        <div class="identity-kpi-label">Global Admins</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:guestUserCount)</div>
        <div class="identity-kpi-label">Guest Users</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value">$(Format-CountValue $script:staleAccounts)</div>
        <div class="identity-kpi-label">Stale Accounts (${STALE_DAYS}d+)</div>
      </div>
      <div class="identity-kpi">
        <div class="identity-kpi-value"><span class="status-dot $riskyDot"></span>$(if($riskyTotal -ne $null){$riskyTotal}else{Format-CountValue $script:riskyUsers})</div>
        <div class="identity-kpi-label">Risky Users</div>
      </div>
    </div>

$mfaBarHtml
$secScoreBarHtml

    <div style="margin-top: 20px;">
      <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Environment Details</div>
      <div class="table-container">
        <table>
          <thead>
            <tr><th>Category</th><th>Metric</th><th>Value</th></tr>
          </thead>
          <tbody>
            <tr><td><strong>Directory</strong></td><td>Users</td><td>$(Format-CountValue $script:userCount)</td></tr>
            <tr><td><strong>Directory</strong></td><td>Groups</td><td>$(Format-CountValue $script:groupCount)</td></tr>
            <tr><td><strong>Directory</strong></td><td>App Registrations</td><td>$(Format-CountValue $script:appRegCount)</td></tr>
            <tr><td><strong>Directory</strong></td><td>Service Principals</td><td>$(Format-CountValue $script:spnCount)</td></tr>
            <tr><td><strong>Conditional Access</strong></td><td>Policies</td><td>$(Format-CountValue $script:caPolicyCount)</td></tr>
            <tr><td><strong>Conditional Access</strong></td><td>Named Locations</td><td>$(Format-CountValue $script:caNamedLocCount)</td></tr>
            <tr><td><strong>Intune</strong></td><td>Managed Devices</td><td>$(Format-CountValue $script:intuneManagedDevices)</td></tr>
            <tr><td><strong>Intune</strong></td><td>Compliance Policies</td><td>$(Format-CountValue $script:intuneCompliancePolicies)</td></tr>
            <tr><td><strong>Intune</strong></td><td>Device Configurations</td><td>$(Format-CountValue $script:intuneDeviceConfigurations)</td></tr>
            <tr><td><strong>Intune</strong></td><td>Configuration Policies</td><td>$(Format-CountValue $script:intuneConfigurationPolicies)</td></tr>
            <tr><td><strong>Collaboration</strong></td><td>Teams</td><td>$(Format-CountValue $script:teamsCount)</td></tr>
          </tbody>
        </table>
      </div>
    </div>
  </div>
"@)
  }

  # Methodology
  $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Methodology</h2>
    <div class="info-card">
      <div class="info-card-title">Measured Data</div>
      <div class="info-card-text">
        Dataset totals are sourced from Microsoft Graph usage reports ($Period-day period). Exchange Archive and Recoverable Items are measured directly from Exchange Online when enabled, as they are not included in standard Graph reports.
      </div>
    </div>
    <div class="info-card">
      <div class="info-card-title">MBS Capacity Estimation (Modeled)</div>
      <div class="info-card-text">
        <strong>Microsoft Backup Storage (MBS)</strong> capacity is estimated using a model that incorporates projected data growth, retention multipliers, daily change rates, and a safety buffer. This helps organizations plan Azure storage allocation for backup workloads.
      </div>
    </div>
    <div class="code-block">
      <span class="code-line">ProjectedDatasetGB = TotalSourceGB x (1 + AnnualGrowthPct)</span>
      <span class="code-line">MonthlyChangeGB = 30 x (ExGB x ChangeRateExchange + OdGB x ChangeRateOneDrive + SpGB x ChangeRateSharePoint)</span>
      <span class="code-line">MbsEstimateGB = (ProjectedDatasetGB x RetentionMultiplier) + MonthlyChangeGB</span>
      <span class="code-line">RecommendedMBS = MbsEstimateGB x (1 + BufferPct)</span>
    </div>
  </div>
"@)

  # Sizing Parameters
  $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Sizing Parameters</h2>
    <div class="table-container">
      <table>
        <thead><tr><th>Parameter</th><th>Value</th></tr></thead>
        <tbody>
          <tr><td>Annual Growth Rate (Modeled)</td><td>$(Format-Pct $AnnualGrowthPct)</td></tr>
          <tr><td>Retention Multiplier (Modeled)</td><td>$RetentionMultiplier</td></tr>
          <tr><td>Exchange Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateExchange)</td></tr>
          <tr><td>OneDrive Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateOneDrive)</td></tr>
          <tr><td>SharePoint Daily Change Rate (Modeled)</td><td>$(Format-Pct $ChangeRateSharePoint)</td></tr>
          <tr><td>Capacity Buffer (Heuristic)</td><td>$(Format-Pct $BufferPct)</td></tr>
          <tr><td>Report Period</td><td>$Period days</td></tr>
          <tr><td>Include AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ADGroup)){"None"}else{[System.Net.WebUtility]::HtmlEncode($ADGroup)})</td></tr>
          <tr><td>Exclude AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ExcludeADGroup)){"None"}else{[System.Net.WebUtility]::HtmlEncode($ExcludeADGroup)})</td></tr>
          <tr><td>Archive Mailboxes</td><td>$(if($IncludeArchive){"Included"}else{"Not included"})</td></tr>
          <tr><td>Recoverable Items</td><td>$(if($IncludeRecoverableItems){"Included"}else{"Not included"})</td></tr>
        </tbody>
      </table>
    </div>
  </div>
"@)

  # =============================
  # FULL MODE: Recommendations
  # =============================
  if ($Full -and $script:recommendations -and $script:recommendations.Count -gt 0) {
    $recsHtml = ""
    $tierOrder = @("Immediate", "Short-Term", "Strategic")
    foreach ($tier in $tierOrder) {
      $tierRecs = @($script:recommendations | Where-Object { $_.Tier -eq $tier })
      if ($tierRecs.Count -eq 0) { continue }
      $tierClass = $tier.ToLower() -replace ' ', '-'
      foreach ($r in $tierRecs) {
        $recsHtml += @"
      <div class="recommendation-card tier-$tierClass">
        <div class="priority-badge $tierClass">$(Escape-Html $r.Tier)</div>
        <div class="rec-title">$(Escape-Html $r.Title)</div>
        <div class="rec-detail">$(Escape-Html $r.Detail)</div>
        $(if($r.Rationale){"<div class='rec-rationale'>$(Escape-Html $r.Rationale)</div>"}else{""})
      </div>
"@
      }
    }

    $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Opportunities to Strengthen Protection</h2>
$recsHtml
  </div>
"@)
  }

  # Generated Artifacts
  $artifactItems = @"
      <div class="file-item">Summary CSV: $(Split-Path $outSummary -Leaf)</div>
      <div class="file-item">Workloads CSV: $(Split-Path $outWorkload -Leaf)</div>
      <div class="file-item">Security CSV: $(Split-Path $outSecurity -Leaf)</div>
      <div class="file-item">Inputs CSV: $(Split-Path $outInputs -Leaf)</div>
      <div class="file-item">Notes TXT: $(Split-Path $outNotes -Leaf)</div>
"@
  if ($ExportJson) { $artifactItems += "      <div class='file-item'>JSON Bundle: $(Split-Path $outJson -Leaf)</div>`n" }
  if ($Full -and $script:outLicenses) { $artifactItems += "      <div class='file-item'>Licenses CSV: $(Split-Path $script:outLicenses -Leaf)</div>`n" }
  if ($Full -and $script:outFindings) { $artifactItems += "      <div class='file-item'>Findings CSV: $(Split-Path $script:outFindings -Leaf)</div>`n" }
  if ($Full -and $script:outRecommendations) { $artifactItems += "      <div class='file-item'>Recommendations CSV: $(Split-Path $script:outRecommendations -Leaf)</div>`n" }

  $htmlParts.Add(@"
  <div class="section">
    <h2 class="section-title">Generated Artifacts</h2>
    <div class="file-list">
$artifactItems
    </div>
  </div>
"@)

  # Footer
  $htmlParts.Add(@"
  <footer class="footer">
    <div>Generated by Veeam M365 Sizing Tool | $(Get-Date -Format 'yyyy-MM-dd HH:mm')</div>
    <div>Microsoft 365 Backup Assessment Report</div>
  </footer>
</div>
</body>
</html>
"@)

  # Join and write
  $html = $htmlParts -join "`n"
  $html | Set-Content -Path $outHtml -Encoding UTF8
}
