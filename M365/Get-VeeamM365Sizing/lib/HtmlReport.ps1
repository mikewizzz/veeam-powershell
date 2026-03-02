# =========================================================================
# HtmlReport.ps1 - Executive-grade HTML report generation
# =========================================================================

<#
.SYNOPSIS
  Builds the complete HTML report with all sections.
.DESCRIPTION
  Generates a professional executive-grade HTML report with inline SVG charts,
  dark gradient header, numbered sections, and glassmorphism KPI cards.
  Quick mode: tenant info, KPIs, capacity forecast, workload analysis, methodology, sizing params, artifacts.
  Full mode adds: executive summary with gauge, license overview with bar chart,
  data protection landscape, identity & access with risk matrix, and grouped recommendations.
.NOTES
  CSS-only visuals, no JavaScript, no external dependencies.
  Works as a static file, prints correctly to PDF, responsive on mobile.
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
  --header-dark: #1B1B2F;
  --header-mid: #1F4068;
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
  counter-reset: section-counter;
}

.container { max-width: 1440px; margin: 0 auto; padding: 0 32px 40px; }

/* ===== Executive Dark Header ===== */
.exec-header {
  background: linear-gradient(135deg, var(--header-dark) 0%, var(--header-mid) 100%);
  padding: 48px 32px 40px;
  margin-bottom: 32px;
  position: relative;
  overflow: hidden;
}
.exec-header::before {
  content: '';
  position: absolute;
  top: -50%;
  right: -10%;
  width: 400px;
  height: 400px;
  background: radial-gradient(circle, rgba(255,255,255,0.04) 0%, transparent 70%);
  border-radius: 50%;
}
.exec-header-inner { max-width: 1440px; margin: 0 auto; position: relative; z-index: 1; }
.exec-header-org {
  font-size: 36px; font-weight: 700; color: #FFFFFF;
  letter-spacing: -0.02em; margin-bottom: 6px;
}
.exec-header-title {
  font-size: 16px; font-weight: 400; color: rgba(255,255,255,0.75);
  margin-bottom: 20px;
}
.exec-header-meta {
  display: flex; flex-wrap: wrap; gap: 24px; align-items: center;
}
.exec-header-meta-item {
  font-size: 13px; color: rgba(255,255,255,0.6);
}
.exec-header-meta-item strong {
  color: rgba(255,255,255,0.9); font-weight: 600;
}
.exec-badge {
  display: inline-block; padding: 4px 14px;
  background: rgba(255,255,255,0.15); color: #FFFFFF;
  border: 1px solid rgba(255,255,255,0.25);
  border-radius: 14px; font-size: 11px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.08em;
  backdrop-filter: blur(4px);
}

/* ===== Section Numbering & Dividers ===== */
.section {
  background: white; padding: 32px; margin-bottom: 24px;
  border-radius: 4px; box-shadow: var(--shadow-depth-4);
}

/* ===== Collapsible Sections ===== */
details.section {
  counter-increment: section-counter;
}
details.section > summary {
  font-size: 20px; font-weight: 600; color: var(--ms-gray-160);
  margin-bottom: 20px; padding-bottom: 12px;
  border-bottom: 3px solid transparent;
  border-image: linear-gradient(90deg, var(--ms-blue), var(--veeam-green), transparent) 1;
  display: flex; align-items: baseline; gap: 12px;
  cursor: pointer; list-style: none; user-select: none;
}
details.section > summary::-webkit-details-marker { display: none; }
details.section > summary::before {
  content: counter(section-counter, decimal-leading-zero);
  font-size: 14px; font-weight: 700; color: var(--ms-blue);
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  min-width: 28px;
}
details.section > summary::after {
  content: '\25B6'; font-size: 12px; color: var(--ms-gray-90);
  margin-left: auto; transition: transform 0.2s ease;
}
details[open].section > summary::after {
  transform: rotate(90deg);
}
details.section > summary:hover {
  color: var(--ms-blue-dark);
}

/* ===== Glassmorphism KPI Cards ===== */
.kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
  gap: 20px; margin-bottom: 24px;
}
.kpi-card {
  background: rgba(255,255,255,0.85);
  backdrop-filter: blur(12px);
  padding: 24px; border-radius: 8px;
  box-shadow: var(--shadow-depth-4);
  border: 1px solid rgba(255,255,255,0.6);
  transition: all 0.2s ease;
  display: flex; gap: 16px; align-items: flex-start;
}
.kpi-card:hover { box-shadow: var(--shadow-depth-8); transform: translateY(-2px); }
.kpi-card-content { flex: 1; }
.kpi-label {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--ms-gray-90); margin-bottom: 8px;
}
.kpi-value {
  font-size: 32px; font-weight: 700; color: var(--ms-gray-160);
  line-height: 1.1; margin-bottom: 6px;
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  font-variant-numeric: tabular-nums;
}
.kpi-subtext { font-size: 12px; color: var(--ms-gray-90); font-weight: 400; }

/* ===== Tenant Info ===== */
.tenant-info {
  background: white; padding: 24px 32px; margin-bottom: 24px;
  border-radius: 4px; box-shadow: var(--shadow-depth-4);
}
.tenant-info-title {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--ms-gray-90); margin-bottom: 12px;
}
.tenant-info-row {
  display: flex; flex-wrap: wrap; gap: 24px; padding: 8px 0;
  border-bottom: 1px solid var(--ms-gray-30);
}
.tenant-info-row:last-child { border-bottom: none; }
.tenant-info-item { display: flex; gap: 8px; }
.tenant-info-label { color: var(--ms-gray-90); font-weight: 400; }
.tenant-info-value { color: var(--ms-gray-160); font-weight: 600; }

/* ===== Executive Summary 3-Column ===== */
.exec-summary-grid {
  display: grid; grid-template-columns: auto 1fr 1fr;
  gap: 32px; align-items: flex-start;
}
.exec-summary-gauge { text-align: center; min-width: 220px; }
.exec-summary-risks, .exec-summary-actions { min-width: 0; }
.exec-summary-subtitle {
  font-weight: 700; font-size: 13px; text-transform: uppercase;
  letter-spacing: 0.04em; color: var(--ms-gray-90); margin-bottom: 12px;
  padding-bottom: 8px; border-bottom: 2px solid var(--ms-gray-30);
}
.exec-risk-item {
  display: flex; align-items: flex-start; gap: 10px;
  padding: 8px 0; border-bottom: 1px solid var(--ms-gray-20);
}
.exec-risk-item:last-child { border-bottom: none; }
.severity-dot {
  width: 8px; height: 8px; border-radius: 50%;
  flex-shrink: 0; margin-top: 6px;
}
.severity-dot.high { background: var(--color-danger); }
.severity-dot.medium { background: var(--color-warning); }
.severity-dot.low { background: var(--color-info); }
.severity-dot.info { background: var(--color-success); }
.exec-risk-text { font-size: 13px; color: var(--ms-gray-130); line-height: 1.4; }
.exec-action-item {
  display: flex; align-items: flex-start; gap: 10px;
  padding: 8px 0; border-bottom: 1px solid var(--ms-gray-20);
}
.exec-action-item:last-child { border-bottom: none; }
.tier-dot {
  display: inline-block; padding: 2px 8px; border-radius: 3px;
  font-size: 10px; font-weight: 700; text-transform: uppercase;
  letter-spacing: 0.04em; color: white; flex-shrink: 0; margin-top: 3px;
}
.tier-dot.immediate { background: var(--color-danger); }
.tier-dot.short-term { background: var(--color-warning); }
.tier-dot.strategic { background: var(--color-info); }
.exec-action-text { font-size: 13px; color: var(--ms-gray-130); line-height: 1.4; }

/* ===== Key Takeaway Bar ===== */
.takeaway-bar {
  background: var(--ms-gray-20); border-radius: 6px;
  padding: 14px 24px; margin-top: 24px;
  font-size: 14px; color: var(--ms-gray-130); text-align: center;
}
.takeaway-bar strong { color: var(--ms-gray-160); }

/* ===== Capacity Forecast ===== */
.capacity-forecast {
  background: white; padding: 24px 32px; margin-bottom: 24px;
  border-radius: 4px; box-shadow: var(--shadow-depth-4);
}
.capacity-forecast-title {
  font-size: 14px; font-weight: 600; color: var(--ms-gray-130);
  margin-bottom: 16px; text-transform: uppercase; letter-spacing: 0.04em;
}

/* ===== Tables ===== */
.table-container { overflow-x: auto; margin-top: 16px; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th {
  padding: 12px 16px; text-align: left; font-weight: 600; color: var(--ms-gray-130);
  font-size: 12px; text-transform: uppercase; letter-spacing: 0.03em;
  border-bottom: 2px solid var(--ms-gray-50);
}
td {
  padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
  font-variant-numeric: tabular-nums;
}
tbody tr:hover { background: var(--ms-gray-10); }
tbody tr:last-child td { border-bottom: none; }

/* ===== Info Cards ===== */
.info-card {
  background: var(--ms-gray-10); border-left: 4px solid var(--ms-blue);
  padding: 20px 24px; margin: 16px 0; border-radius: 2px;
}
.info-card-title { font-weight: 600; color: var(--ms-gray-130); margin-bottom: 8px; font-size: 14px; }
.info-card-text { color: var(--ms-gray-90); font-size: 13px; line-height: 1.6; margin-bottom: 8px; }
.info-card-text:last-child { margin-bottom: 0; }

/* ===== Code Block ===== */
.code-block {
  background: var(--ms-gray-160); color: var(--ms-blue-light);
  padding: 20px 24px; border-radius: 4px;
  font-family: 'Cascadia Code', 'Consolas', 'Monaco', 'Courier New', monospace;
  font-size: 13px; line-height: 1.8; overflow-x: auto; margin-top: 16px;
}
.code-line { display: block; white-space: nowrap; }

/* ===== Progress Bar ===== */
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

/* ===== Status Dot ===== */
.status-dot {
  display: inline-block; width: 10px; height: 10px; border-radius: 50%;
  margin-right: 8px; vertical-align: middle;
}
.status-dot.green { background: var(--color-success); }
.status-dot.yellow { background: var(--color-warning); }
.status-dot.red { background: var(--color-danger); }
.status-dot.gray { background: var(--ms-gray-50); }

/* ===== Finding Cards ===== */
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

/* ===== Recommendation Cards (Grouped) ===== */
.rec-phase-header {
  font-size: 15px; font-weight: 700; color: var(--ms-gray-160);
  margin: 24px 0 12px; padding-bottom: 8px;
  border-bottom: 2px solid var(--ms-gray-30);
}
.rec-phase-header:first-child { margin-top: 0; }
.recommendation-card {
  background: white; padding: 20px 24px; margin: 12px 0;
  border-radius: 4px; box-shadow: var(--shadow-depth-4); border-left: 4px solid var(--ms-gray-50);
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

/* ===== Workload Flex (Donut + Table) ===== */
.workload-flex {
  display: flex; gap: 32px; align-items: flex-start; flex-wrap: wrap;
}
.workload-chart { flex-shrink: 0; }
.workload-table { flex: 1; min-width: 0; }

/* ===== Coverage Grid ===== */
.coverage-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 16px; margin-top: 16px;
}
.coverage-item {
  background: var(--ms-gray-10); border-radius: 4px; padding: 20px;
  border-top: 3px solid var(--ms-blue);
}
.coverage-item-title { font-weight: 600; font-size: 15px; margin-bottom: 8px; }
.coverage-item-stat {
  font-size: 24px; font-weight: 600; color: var(--ms-gray-160); margin-bottom: 4px;
  font-family: 'Cascadia Code', 'Consolas', monospace;
  font-variant-numeric: tabular-nums;
}
.coverage-item-detail { font-size: 12px; color: var(--ms-gray-90); margin-bottom: 4px; }

/* ===== Callout Card ===== */
.callout-card {
  background: var(--ms-gray-10); border: 1px solid var(--ms-gray-30);
  border-radius: 4px; padding: 24px; margin: 16px 0;
}
.callout-card-title {
  font-weight: 600; font-size: 16px; margin-bottom: 16px;
  color: var(--ms-gray-160); text-align: center;
}
.callout-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
.callout-column-title {
  font-weight: 600; font-size: 13px; text-transform: uppercase;
  letter-spacing: 0.03em; margin-bottom: 12px; padding-bottom: 8px;
  border-bottom: 2px solid var(--ms-gray-50);
}
.callout-column-title.provider { color: var(--ms-blue); border-bottom-color: var(--ms-blue); }
.callout-column-title.customer { color: var(--veeam-green); border-bottom-color: var(--veeam-green); }
.callout-item { font-size: 13px; color: var(--ms-gray-130); padding: 4px 0; }

/* ===== Identity KPI Grid ===== */
.identity-kpi-grid {
  display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 16px; margin: 16px 0;
}
.identity-kpi {
  background: var(--ms-gray-10); padding: 16px; border-radius: 4px; text-align: center;
}
.identity-kpi-value {
  font-size: 28px; font-weight: 600; color: var(--ms-gray-160);
  font-family: 'Cascadia Code', 'Consolas', monospace;
  font-variant-numeric: tabular-nums;
}
.identity-kpi-label { font-size: 12px; color: var(--ms-gray-90); margin-top: 4px; }

/* ===== File List ===== */
.file-list { list-style: none; padding: 0; margin: 16px 0 0 0; }
.file-item {
  padding: 10px 16px; border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-130); font-size: 13px;
  font-family: 'Cascadia Code', 'Consolas', monospace;
}
.file-item:last-child { border-bottom: none; }

/* ===== Professional Footer ===== */
.exec-footer {
  text-align: center; padding: 32px 0 16px;
  border-top: 1px solid var(--ms-gray-30);
  margin-top: 16px;
}
.exec-footer-org {
  font-size: 13px; font-weight: 600; color: var(--ms-gray-130); margin-bottom: 4px;
}
.exec-footer-conf {
  font-size: 11px; color: var(--ms-gray-90); margin-bottom: 4px;
  font-style: italic;
}
.exec-footer-stamp {
  font-size: 11px; color: var(--ms-gray-50);
  font-family: 'Cascadia Code', 'Consolas', monospace;
}

/* ===== SVG Containers ===== */
.svg-container { margin: 16px 0; }
.svg-container svg { max-width: 100%; height: auto; }

/* ===== Responsive ===== */
@media (max-width: 768px) {
  .container { padding: 0 16px 20px; }
  .exec-header { padding: 32px 16px 28px; }
  .exec-header-org { font-size: 24px; }
  .exec-summary-grid { grid-template-columns: 1fr; }
  .kpi-grid { grid-template-columns: 1fr; }
  .section { padding: 20px; }
  .tenant-info-row { flex-direction: column; gap: 12px; }
  .callout-grid { grid-template-columns: 1fr; }
  .coverage-grid { grid-template-columns: 1fr; }
  .identity-kpi-grid { grid-template-columns: repeat(2, 1fr); }
  .workload-flex { flex-direction: column; }
}

/* ===== Print ===== */
@media print {
  body { background: white; font-size: 12px; }
  .container { max-width: 100%; padding: 0; }
  .exec-header {
    print-color-adjust: exact; -webkit-print-color-adjust: exact;
    padding: 32px 24px;
  }
  .kpi-card, .section, .tenant-info {
    box-shadow: none; border: 1px solid var(--ms-gray-30);
    page-break-inside: avoid;
  }
  .kpi-card:hover { transform: none; }
  .kpi-card { backdrop-filter: none; background: white; }
  .finding-card, .recommendation-card {
    box-shadow: none; border: 1px solid var(--ms-gray-30);
    page-break-inside: avoid;
  }
  .progress-fill, .priority-badge, .severity-dot, .tier-dot, .status-dot,
  .exec-badge, .coverage-item {
    print-color-adjust: exact; -webkit-print-color-adjust: exact;
  }
  svg { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
  .section { page-break-inside: avoid; }
  details.section { display: block; }
  details.section > summary::after { display: none; }
  details.section > .section-content { display: block !important; }
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
    if ($score -ge 70) { return "#107C10" }
    elseif ($score -ge 40) { return "#F7630C" }
    else { return "#D13438" }
  }

  function _Get-ScoreLabel([int]$score) {
    if ($score -ge 70) { return "STRONG" }
    elseif ($score -ge 40) { return "MODERATE" }
    else { return "AT RISK" }
  }

  # =============================
  # Build HTML sections
  # =============================
  $htmlParts = New-Object System.Collections.Generic.List[string]

  # Org display name
  $orgDisplay = "Microsoft 365 Tenant"
  if ($script:OrgName) { $orgDisplay = $script:OrgName }

  # DOCTYPE + head
  $htmlParts.Add(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Microsoft 365 Backup Sizing Assessment — $(Escape-Html $orgDisplay)</title>
<style>
$css
</style>
</head>
<body>
"@)

  # =============================
  # Executive Dark Header
  # =============================
  $modeLabel = if ($Full) { "FULL ASSESSMENT" } else { "QUICK SIZING" }
  $htmlParts.Add(@"
  <div class="exec-header">
    <div class="exec-header-inner">
      <div class="exec-header-org">$(Escape-Html $orgDisplay)</div>
      <div class="exec-header-title">Microsoft 365 Backup Sizing Assessment</div>
      <div class="exec-header-meta">
        <span class="exec-badge">$modeLabel</span>
        <span class="exec-header-meta-item"><strong>Generated:</strong> $(Get-Date -Format "MMMM dd, yyyy 'at' HH:mm") UTC</span>
        $(if($script:OrgId){"<span class='exec-header-meta-item'><strong>Tenant:</strong> $(Escape-Html $script:OrgId)</span>"}else{""})
        $(if($script:DefaultDomain){"<span class='exec-header-meta-item'><strong>Domain:</strong> $(Escape-Html $script:DefaultDomain)</span>"}else{""})
      </div>
    </div>
  </div>
  <div class="container">
"@)

  # Tenant Info
  $htmlParts.Add(@"
  <div class="tenant-info">
    <div class="tenant-info-title">Tenant Details</div>
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
  # FULL MODE: Executive Summary (3-Column)
  # =============================
  if ($Full -and $null -ne $script:readinessScore) {
    # Gauge chart
    $gaugeHtml = New-SvgGaugeChart -Score $script:readinessScore -Label "Protection Readiness"

    # Top 3 risks
    $topRisks = @($script:findings | Where-Object { $_.Tone -ne "Strong" } | Select-Object -First 3)
    $risksHtml = ""
    foreach ($f in $topRisks) {
      $sevClass = $f.Severity.ToLower()
      $risksHtml += @"
        <div class="exec-risk-item">
          <span class="severity-dot $sevClass"></span>
          <span class="exec-risk-text">$(Escape-Html $f.Title)</span>
        </div>
"@
    }
    if ($risksHtml -eq "") {
      $risksHtml = '<div class="exec-risk-item"><span class="severity-dot info"></span><span class="exec-risk-text">No significant risks identified</span></div>'
    }

    # Top 3 actions
    $topActions = @($script:recommendations | Select-Object -First 3)
    $actionsHtml = ""
    foreach ($r in $topActions) {
      $tierClass = $r.Tier.ToLower() -replace ' ', '-'
      $actionsHtml += @"
        <div class="exec-action-item">
          <span class="tier-dot $tierClass">$(Escape-Html $r.Tier)</span>
          <span class="exec-action-text">$(Escape-Html $r.Title)</span>
        </div>
"@
    }
    if ($actionsHtml -eq "") {
      $actionsHtml = '<div class="exec-action-item"><span class="tier-dot strategic">Info</span><span class="exec-action-text">No immediate actions required</span></div>'
    }

    # Takeaway
    $scoreLabel = _Get-ScoreLabel $script:readinessScore

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Executive Summary</summary>
    <div class="section-content">
    <div class="exec-summary-grid">
      <div class="exec-summary-gauge">
        <div class="svg-container">
$gaugeHtml
        </div>
      </div>
      <div class="exec-summary-risks">
        <div class="exec-summary-subtitle">Key Risks</div>
$risksHtml
      </div>
      <div class="exec-summary-actions">
        <div class="exec-summary-subtitle">Recommended Actions</div>
$actionsHtml
      </div>
    </div>
    <div class="takeaway-bar">
      This tenant's data protection posture is <strong>$scoreLabel</strong> (score: $($script:readinessScore)/100). $(if($script:readinessScore -lt 70){"Targeted improvements in identity security and backup coverage can significantly reduce organizational risk."}else{"Continue strengthening backup coverage and identity controls to maintain this position."})
    </div>
    </div>
  </details>
"@)
  }

  # =============================
  # KPI Grid with Mini Rings
  # =============================

  # Calculate percentages for mini rings
  $usersRingPct = 100  # Always 100% (these are the users to protect)
  $growthRingPct = [Math]::Min([Math]::Round($AnnualGrowthPct * 100 / 0.5 * 100, 0), 100)  # Scale: 50% growth = full ring
  $mbsRingPct = if ($script:totalGB -gt 0) { [Math]::Min([Math]::Round(($script:suggestedStartGB / ($script:totalGB * 3)) * 100, 0), 100) } else { 0 }

  $usersRing = New-SvgMiniRing -Percent $usersRingPct -Color "#0078D4"
  $datasetRing = New-SvgMiniRing -Percent 75 -Color "#106EBE"
  $growthRing = New-SvgMiniRing -Percent $growthRingPct -Color "#F7630C"
  $mbsRing = New-SvgMiniRing -Percent $mbsRingPct -Color "#00B336"

  $htmlParts.Add(@"
  <details class="section" open>
    <summary>Key Performance Indicators</summary>
    <div class="section-content">
    <div class="kpi-grid">
      <div class="kpi-card">
        $usersRing
        <div class="kpi-card-content">
          <div class="kpi-label">Users to Protect</div>
          <div class="kpi-value">$($script:UsersToProtect)</div>
          <div class="kpi-subtext">Active user accounts</div>
        </div>
      </div>
      <div class="kpi-card">
        $datasetRing
        <div class="kpi-card-content">
          <div class="kpi-label">Total Dataset</div>
          <div class="kpi-value">$(Format-Storage $script:totalGB)</div>
          <div class="kpi-subtext">$($script:totalGB) GB | $($script:totalTiB) TiB (binary)</div>
        </div>
      </div>
      <div class="kpi-card">
        $growthRing
        <div class="kpi-card-content">
          <div class="kpi-label">Projected Growth</div>
          <div class="kpi-value">$(Format-Pct $AnnualGrowthPct)</div>
          <div class="kpi-subtext">Annual growth rate (modeled)</div>
        </div>
      </div>
      <div class="kpi-card">
        $mbsRing
        <div class="kpi-card-content">
          <div class="kpi-label">Recommended MBS</div>
          <div class="kpi-value">$(Format-Storage $script:suggestedStartGB)</div>
          <div class="kpi-subtext">Estimate: $(Format-Storage $script:mbsEstimateGB) + $(Format-Pct $BufferPct) buffer</div>
        </div>
      </div>
    </div>
    </div>
  </details>
"@)

  # =============================
  # FULL MODE: Cyber Resilience Scorecard
  # =============================
  if ($Full -and $null -ne $script:readinessScore) {
    # Identity Protection ring
    $idProtectPct = 0
    if ($script:mfaCount -is [int] -and $script:userCount -is [int] -and $script:userCount -gt 0) {
      $idProtectPct = [int][math]::Round(($script:mfaCount / $script:userCount) * 100, 0)
    }
    $idProtectRing = New-SvgMiniRing -Percent $idProtectPct -Color $(if($idProtectPct -ge 80){"#107C10"}elseif($idProtectPct -ge 50){"#F7630C"}else{"#D13438"})

    # Data Recovery Readiness ring
    $readinessPct = $script:readinessScore
    $readinessRing = New-SvgMiniRing -Percent $readinessPct -Color $(_Get-ScoreColor $readinessPct)

    # Access Governance ring
    $accessPct = if ($script:ztScores -is [hashtable]) { $script:ztScores.Access } else { 0 }
    $accessRing = New-SvgMiniRing -Percent $accessPct -Color $(if($accessPct -ge 67){"#107C10"}elseif($accessPct -ge 34){"#F7630C"}else{"#D13438"})

    # Secure Score ring
    $secScorePct = 0
    if ($script:secureScore -is [hashtable] -and $script:secureScore.MaxScore -gt 0) {
      $secScorePct = [int]$script:secureScore.Percentage
    }
    $secScoreRing = New-SvgMiniRing -Percent $secScorePct -Color $(if($secScorePct -ge 70){"#107C10"}elseif($secScorePct -ge 40){"#F7630C"}else{"#D13438"})

    # Regulatory readiness context
    $regMet = New-Object System.Collections.Generic.List[string]
    if ($idProtectPct -ge 80) { $regMet.Add("MFA coverage meets common regulatory thresholds") }
    if ($script:caPolicyCount -is [int] -and $script:caPolicyCount -ge $CA_POLICY_THRESHOLD) { $regMet.Add("Conditional Access policies demonstrate access governance") }
    if ($readinessPct -ge 60) { $regMet.Add("Data protection readiness supports compliance posture") }

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Cyber Resilience Scorecard</summary>
    <div class="section-content">
    <div class="identity-kpi-grid" style="grid-template-columns: repeat(4, 1fr);">
      <div class="identity-kpi">
        $idProtectRing
        <div class="identity-kpi-value">${idProtectPct}%</div>
        <div class="identity-kpi-label">Identity Protection</div>
      </div>
      <div class="identity-kpi">
        $readinessRing
        <div class="identity-kpi-value">${readinessPct}%</div>
        <div class="identity-kpi-label">Data Recovery Readiness</div>
      </div>
      <div class="identity-kpi">
        $accessRing
        <div class="identity-kpi-value">${accessPct}%</div>
        <div class="identity-kpi-label">Access Governance</div>
      </div>
      <div class="identity-kpi">
        $secScoreRing
        <div class="identity-kpi-value">${secScorePct}%</div>
        <div class="identity-kpi-label">Microsoft Secure Score</div>
      </div>
    </div>
    <div class="callout-card" style="margin-top: 24px;">
      <div class="callout-card-title">Regulatory Readiness Context</div>
      <div style="font-size: 13px; color: var(--ms-gray-130); line-height: 1.6;">
        <div style="margin-bottom: 12px;">This assessment surfaces signals relevant to frameworks including <strong>NIS2</strong>, <strong>DORA</strong>, and <strong>SEC Cyber Disclosure Rules</strong>. These are data inputs for compliance evaluation, not compliance determinations.</div>
        $(if($regMet.Count -gt 0){
          $regItems = ""
          foreach ($r in $regMet) { $regItems += "<div style='padding: 4px 0;'>&#10003; $r</div>" }
          $regItems
        }else{
          "<div style='padding: 4px 0; color: var(--ms-gray-90);'>Insufficient data signals to evaluate regulatory readiness thresholds.</div>"
        })
      </div>
    </div>
    </div>
  </details>
"@)
  }

  # =============================
  # Capacity Forecast Bar Chart
  # =============================
  $projectedGB = [Math]::Round($script:totalGB * (1 + $AnnualGrowthPct), 2)
  $capacityChart = New-SvgCapacityForecast -CurrentGB $script:totalGB -ProjectedGB $projectedGB -RecommendedGB $script:suggestedStartGB

  if ($capacityChart) {
    $htmlParts.Add(@"
  <details class="section">
    <summary>Capacity Forecast</summary>
    <div class="section-content">
    <div class="svg-container">
$capacityChart
    </div>
    </div>
  </details>
"@)
  }

  # =============================
  # FULL MODE: License Overview with Bar Chart
  # =============================
  if ($Full -and $script:licenseData -and $script:licenseData -isnot [string] -and @($script:licenseData).Count -gt 0) {
    # Build bar chart items from license data
    $barItems = New-Object System.Collections.Generic.List[object]
    foreach ($lic in ($script:licenseData | Select-Object -First 8)) {
      $barColor = "#0078D4"
      if ($lic.UtilizationPct -ge 90) { $barColor = "#D13438" }
      elseif ($lic.UtilizationPct -ge 70) { $barColor = "#F7630C" }
      $barItems.Add(@{
        Label    = $lic.DisplayName
        Value    = $lic.UtilizationPct
        MaxValue = 100
        Color    = $barColor
      })
    }
    $licBarChart = New-SvgHorizontalBarChart -Items $barItems

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
  <details class="section">
    <summary>License Overview</summary>
    <div class="section-content">
    <div class="svg-container" style="margin-bottom: 24px;">
$licBarChart
    </div>
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
  </details>
"@)
  }

  # =============================
  # Workload Analysis with Donut Chart
  # =============================
  $donutSegments = New-Object System.Collections.Generic.List[object]
  if ($script:exGB -gt 0) {
    $donutSegments.Add(@{ Label = "Exchange Online"; Value = $script:exGB; Color = "#0078D4" })
  }
  if ($script:odGB -gt 0) {
    $donutSegments.Add(@{ Label = "OneDrive"; Value = $script:odGB; Color = "#106EBE" })
  }
  if ($script:spGB -gt 0) {
    $donutSegments.Add(@{ Label = "SharePoint"; Value = $script:spGB; Color = "#00B336" })
  }
  $donutChart = New-SvgDonutChart -Segments $donutSegments -CenterLabel (Format-Storage $script:totalGB) -CenterSubLabel "Total"

  $htmlParts.Add(@"
  <details class="section">
    <summary>Workload Analysis</summary>
    <div class="section-content">
    <div class="workload-flex">
      <div class="workload-chart svg-container">
$donutChart
      </div>
      <div class="workload-table">
        <div class="table-container">
          <table>
            <thead>
              <tr>
                <th>Workload</th>
                <th>Objects</th>
                <th>Secondary</th>
                <th>Source (GB)</th>
                <th>Source (GiB)</th>
                <th>Growth</th>
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
                <td>Archive/RIF if enabled</td>
              </tr>
              <tr>
                <td><strong>OneDrive for Business</strong></td>
                <td>$($script:odActive.Count)</td>
                <td>&mdash;</td>
                <td>$($script:odGB)</td>
                <td>$($script:odGiB)</td>
                <td>$(Format-Pct $script:odGrowth)</td>
                <td>AD group filtered</td>
              </tr>
              <tr>
                <td><strong>SharePoint Online</strong></td>
                <td>$($script:spActive.Count)</td>
                <td>$($script:spFiles) files</td>
                <td>$($script:spGB)</td>
                <td>$($script:spGiB)</td>
                <td>$(Format-Pct $script:spGrowth)</td>
                <td>Tenant-wide</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    </div>
  </details>
"@)

  # =============================
  # FULL MODE: Data Protection Landscape
  # =============================
  if ($Full) {
    $htmlParts.Add(@"
  <details class="section">
    <summary>Data Protection Landscape</summary>
    <div class="section-content">
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
        <div class="coverage-item-stat">$(Format-Storage $script:exGB)</div>
        <div class="coverage-item-detail">$($script:exUsers.Count) mailboxes + $($script:exShared.Count) shared</div>
        <div class="coverage-item-detail">Conversations, calendars, contacts</div>
      </div>
      <div class="coverage-item">
        <div class="coverage-item-title">OneDrive for Business</div>
        <div class="coverage-item-stat">$(Format-Storage $script:odGB)</div>
        <div class="coverage-item-detail">$($script:odActive.Count) accounts</div>
        <div class="coverage-item-detail">User files, documents, media</div>
      </div>
      <div class="coverage-item">
        <div class="coverage-item-title">SharePoint Online</div>
        <div class="coverage-item-stat">$(Format-Storage $script:spGB)</div>
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
  </details>
"@)
  }

  # =============================
  # FULL MODE: Identity & Access Security with Risk Matrix
  # =============================
  if ($Full) {
    $globalAdminCount = if ($script:globalAdmins -is [System.Collections.IEnumerable] -and $script:globalAdmins -isnot [string]) { @($script:globalAdmins).Count } else { $null }
    $adminDot = if ($null -ne $globalAdminCount -and $globalAdminCount -le $ADMIN_THRESHOLD) { "green" } elseif ($null -ne $globalAdminCount) { "yellow" } else { "gray" }

    $riskyTotal = if ($script:riskyUsers -is [hashtable]) { $script:riskyUsers.Total } else { $null }
    $riskyDot = if ($null -ne $riskyTotal -and $riskyTotal -eq 0) { "green" } elseif ($null -ne $riskyTotal -and $script:riskyUsers.High -eq 0) { "yellow" } elseif ($null -ne $riskyTotal) { "red" } else { "gray" }

    # Build risk matrix from findings
    $riskMatrixData = @{}
    $riskCategories = New-Object System.Collections.Generic.List[string]
    if ($script:findings -and $script:findings.Count -gt 0) {
      foreach ($f in $script:findings) {
        $cat = "General"
        if ($f.Title -match "MFA|Multi-Factor|Authentication") { $cat = "Identity" }
        elseif ($f.Title -match "Admin|Privilege|Role") { $cat = "Privilege" }
        elseif ($f.Title -match "Stale|Inactive|Guest") { $cat = "Hygiene" }
        elseif ($f.Title -match "Conditional|Access|Policy") { $cat = "Access" }
        elseif ($f.Title -match "Backup|Recovery|Data") { $cat = "Data" }
        elseif ($f.Title -match "Score|Secure|Security") { $cat = "Security" }

        if (-not $riskCategories.Contains($cat)) { $riskCategories.Add($cat) }
        $key = "$cat|$($f.Severity)"
        if ($riskMatrixData.ContainsKey($key)) {
          $riskMatrixData[$key] = $riskMatrixData[$key] + 1
        } else {
          $riskMatrixData[$key] = 1
        }
      }
    }

    $riskMatrixHtml = ""
    if ($riskCategories.Count -gt 0) {
      $riskMatrixHtml = New-SvgRiskMatrix -Categories $riskCategories -Severities @("High", "Medium", "Low") -Data $riskMatrixData
    }

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
  <details class="section">
    <summary>Identity &amp; Access Security</summary>
    <div class="section-content">
    $(if($riskMatrixHtml){"<div class='svg-container' style='margin-bottom: 24px;'>$riskMatrixHtml</div>"}else{""})

    <div class="identity-kpi-grid">
      <div class="identity-kpi">
        <div class="identity-kpi-value"><span class="status-dot $adminDot"></span>$(if($null -ne $globalAdminCount){$globalAdminCount}else{Format-CountValue $script:globalAdmins})</div>
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
        <div class="identity-kpi-value"><span class="status-dot $riskyDot"></span>$(if($null -ne $riskyTotal){$riskyTotal}else{Format-CountValue $script:riskyUsers})</div>
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
  </details>
"@)
  }

  # =============================
  # FULL MODE: Zero Trust Maturity Assessment
  # =============================
  if ($Full -and $script:ztScores -is [hashtable]) {
    # Build bar chart items for the 5 pillars
    $ztBarItems = New-Object System.Collections.Generic.List[object]
    $ztPillars = @(
      @{ Name = "Identity"; Score = $script:ztScores.Identity }
      @{ Name = "Devices";  Score = $script:ztScores.Devices }
      @{ Name = "Access";   Score = $script:ztScores.Access }
      @{ Name = "Data";     Score = $script:ztScores.Data }
      @{ Name = "Apps";     Score = $script:ztScores.Apps }
    )
    foreach ($p in $ztPillars) {
      $ztColor = if ($p.Score -ge $ZT_ADVANCED_THRESHOLD) { "#107C10" } elseif ($p.Score -ge $ZT_DEVELOPING_THRESHOLD) { "#F7630C" } else { "#D13438" }
      $ztBarItems.Add(@{ Label = $p.Name; Value = $p.Score; MaxValue = 100; Color = $ztColor })
    }
    $ztBarChart = New-SvgHorizontalBarChart -Items $ztBarItems

    # Find weakest pillar
    $weakest = $ztPillars[0]
    foreach ($p in $ztPillars) {
      if ($p.Score -lt $weakest.Score) { $weakest = $p }
    }
    $weakLabel = if ($weakest.Score -lt $ZT_DEVELOPING_THRESHOLD) { "Initial" } elseif ($weakest.Score -lt $ZT_ADVANCED_THRESHOLD) { "Developing" } else { "Advanced" }

    $htmlParts.Add(@"
  <details class="section">
    <summary>Zero Trust Maturity Assessment</summary>
    <div class="section-content">
    <div style="font-size: 13px; color: var(--ms-gray-90); margin-bottom: 16px;">
      Scores mapped from collected tenant data to Microsoft Zero Trust pillars. Maturity levels: <strong>Initial</strong> (0-33), <strong>Developing</strong> (34-66), <strong>Advanced</strong> (67-100).
    </div>
    <div class="svg-container">
$ztBarChart
    </div>
    <div class="takeaway-bar" style="margin-top: 20px;">
      Weakest pillar: <strong>$($weakest.Name)</strong> ($($weakest.Score)/100 &mdash; $weakLabel). $(if($weakest.Score -lt $ZT_DEVELOPING_THRESHOLD){"This pillar requires immediate attention to establish baseline Zero Trust maturity."}elseif($weakest.Score -lt $ZT_ADVANCED_THRESHOLD){"Targeted improvements in this area would advance overall Zero Trust posture."}else{"All pillars are at Advanced maturity. Maintain and continuously validate controls."})
    </div>
    </div>
  </details>
"@)
  }

  # =============================
  # FULL MODE: Business Impact Analysis
  # =============================
  if ($Full) {
    $totalDataGB = $script:exGB + $script:odGB + $script:spGB
    $monthChangeDisplay = if ($null -ne $script:monthChangeGB) { "{0:N2}" -f $script:monthChangeGB } else { "N/A" }
    $projectedYearGB = [Math]::Round($totalDataGB * (1 + $AnnualGrowthPct), 2)

    $htmlParts.Add(@"
  <details class="section">
    <summary>Business Impact Analysis</summary>
    <div class="section-content">
    <div style="font-size: 13px; color: var(--ms-gray-90); margin-bottom: 16px;">
      Translates technical data into business risk context. No dollar assumptions are made &mdash; use these data inputs for your organization's financial models.
    </div>

    <div style="font-weight: 600; font-size: 14px; margin-bottom: 12px;">Data at Risk by Workload</div>
    <div class="table-container">
      <table>
        <thead>
          <tr><th>Workload</th><th>Scope</th><th>Business Impact if Lost</th></tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>Exchange Online</strong></td>
            <td>$(Format-Storage $script:exGB) &mdash; $($script:exUsers.Count) mailboxes</td>
            <td>Business continuity disruption, legal discovery exposure, regulatory retention gaps</td>
          </tr>
          <tr>
            <td><strong>OneDrive for Business</strong></td>
            <td>$(Format-Storage $script:odGB) &mdash; $($script:odActive.Count) accounts</td>
            <td>Productivity loss, intellectual property exposure, individual work product unrecoverable</td>
          </tr>
          <tr>
            <td><strong>SharePoint Online</strong></td>
            <td>$(Format-Storage $script:spGB) &mdash; $($script:spActive.Count) sites</td>
            <td>Collaboration disruption, knowledge base loss, business process interruption</td>
          </tr>
          <tr>
            <td><strong>Microsoft Teams</strong></td>
            <td>$(Format-CountValue $script:teamsCount) teams</td>
            <td>Communication continuity, channel history loss, project context unrecoverable</td>
          </tr>
          <tr>
            <td><strong>Entra ID Configuration</strong></td>
            <td>$(Format-CountValue $script:caPolicyCount) CA policies, $(Format-CountValue $script:intuneManagedDevices) devices</td>
            <td>Security posture recreation cost, access control gaps during rebuild</td>
          </tr>
        </tbody>
      </table>
    </div>

    <div class="callout-card" style="margin-top: 24px;">
      <div class="callout-card-title">Recovery Planning Context</div>
      <div class="identity-kpi-grid" style="grid-template-columns: repeat(4, 1fr);">
        <div class="identity-kpi">
          <div class="identity-kpi-value">$(Format-Storage $totalDataGB)</div>
          <div class="identity-kpi-label">Total Dataset Scope</div>
        </div>
        <div class="identity-kpi">
          <div class="identity-kpi-value">$monthChangeDisplay GB</div>
          <div class="identity-kpi-label">Monthly Change Velocity</div>
        </div>
        <div class="identity-kpi">
          <div class="identity-kpi-value">$(Format-CountValue $script:userCount)</div>
          <div class="identity-kpi-label">Identity Surface</div>
        </div>
        <div class="identity-kpi">
          <div class="identity-kpi-value">$(Format-Storage $projectedYearGB)</div>
          <div class="identity-kpi-label">12-Month Projection</div>
        </div>
      </div>
    </div>
    </div>
  </details>
"@)
  }

  # Methodology
  $htmlParts.Add(@"
  <details class="section">
    <summary>Methodology</summary>
    <div class="section-content">
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
  </details>
"@)

  # Sizing Parameters
  $htmlParts.Add(@"
  <details class="section">
    <summary>Sizing Parameters</summary>
    <div class="section-content">
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
          <tr><td>Include AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ADGroup)){"None"}else{Escape-Html $ADGroup})</td></tr>
          <tr><td>Exclude AD Group</td><td>$(if([string]::IsNullOrWhiteSpace($ExcludeADGroup)){"None"}else{Escape-Html $ExcludeADGroup})</td></tr>
          <tr><td>Archive Mailboxes</td><td>$(if($IncludeArchive){"Included"}else{"Not included"})</td></tr>
          <tr><td>Recoverable Items</td><td>$(if($IncludeRecoverableItems){"Included"}else{"Not included"})</td></tr>
        </tbody>
      </table>
    </div>
    </div>
  </details>
"@)

  # =============================
  # FULL MODE: Recommendations (Grouped by Phase)
  # =============================
  if ($Full -and $script:recommendations -and $script:recommendations.Count -gt 0) {
    $recsHtml = ""
    $tierOrder = @(
      @{ Name = "Immediate"; Phase = "Phase 1: Immediate Actions" }
      @{ Name = "Short-Term"; Phase = "Phase 2: Short-Term Improvements" }
      @{ Name = "Strategic"; Phase = "Phase 3: Strategic Initiatives" }
    )
    foreach ($tierInfo in $tierOrder) {
      $tierRecs = @($script:recommendations | Where-Object { $_.Tier -eq $tierInfo.Name })
      if ($tierRecs.Count -eq 0) { continue }
      $tierClass = $tierInfo.Name.ToLower() -replace ' ', '-'
      $recsHtml += "    <div class=`"rec-phase-header`">$(Escape-Html $tierInfo.Phase)</div>`n"
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
  <details class="section" open>
    <summary>Opportunities to Strengthen Protection</summary>
    <div class="section-content">
$recsHtml
    </div>
  </details>
"@)
  }

  # =============================
  # COMPLIANCE MODE: Framework Readiness Section
  # =============================
  if ($Compliance -and $script:complianceScores) {
    $compHtml = ""

    # Framework score cards
    $compHtml += "    <div class='identity-kpi-grid' style='grid-template-columns: repeat(4, 1fr); margin-bottom: 24px;'>`n"
    foreach ($fw in @("NIS2", "SOC2", "ISO27001", "Overall")) {
      $cs = $script:complianceScores[$fw]
      $scoreVal = if ($cs) { $cs.Score } else { 0 }
      $maturity = if ($cs -and $cs.Maturity) { $cs.Maturity } else { "No Data" }
      $scoreColor = if ($scoreVal -ge 80) { "var(--color-success)" } elseif ($scoreVal -ge 50) { "var(--color-warning)" } else { "var(--color-danger)" }
      $fwLabel = if ($fw -eq "Overall") { "Overall Compliance" } elseif ($fw -eq "ISO27001") { "ISO 27001" } else { $fw }
      $compHtml += @"
      <div class='identity-kpi'>
        <div class='identity-kpi-value' style='color: $scoreColor;'>$scoreVal<span style='font-size: 14px; color: var(--ms-gray-90);'>/100</span></div>
        <div class='identity-kpi-label'>$fwLabel</div>
        <div style='font-size: 11px; color: var(--ms-gray-90); margin-top: 2px;'>$maturity</div>
      </div>
"@
    }
    $compHtml += "    </div>`n"

    # Compliance control mapping table
    $mappedFindings = @($script:findings | Where-Object {
      $_.PSObject.Properties.Name -contains "ComplianceControls" -and $_.ComplianceControls.Count -gt 0
    })

    if ($mappedFindings.Count -gt 0) {
      $compHtml += @"
    <div class='table-container'>
      <table>
        <thead><tr><th>Finding</th><th>Severity</th><th>NIS2</th><th>SOC2</th><th>ISO 27001</th></tr></thead>
        <tbody>
"@
      foreach ($f in $mappedFindings) {
        $nis2Ctrls = @($f.ComplianceControls | Where-Object { $_.Framework -eq "NIS2" } | ForEach-Object { $_.Control }) -join ", "
        $soc2Ctrls = @($f.ComplianceControls | Where-Object { $_.Framework -eq "SOC2" } | ForEach-Object { $_.Control }) -join ", "
        $isoCtrls  = @($f.ComplianceControls | Where-Object { $_.Framework -eq "ISO27001" } | ForEach-Object { $_.Control }) -join ", "
        $sevClass = $f.Severity.ToLower()
        $compHtml += "          <tr><td>$(Escape-Html $f.Title)</td><td><span class='severity-badge $sevClass'>$($f.Severity)</span></td><td>$(Escape-Html $nis2Ctrls)</td><td>$(Escape-Html $soc2Ctrls)</td><td>$(Escape-Html $isoCtrls)</td></tr>`n"
      }
      $compHtml += "        </tbody>`n      </table>`n    </div>`n"
    }

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Compliance Framework Readiness</summary>
    <div class="section-content">
$compHtml
    </div>
  </details>
"@)
  }

  # =============================
  # DELTA REPORT: Changes Since Last Assessment
  # =============================
  if ($script:assessmentDelta) {
    $deltaHtml = ""
    $d = $script:assessmentDelta
    $daysBetween = $d.DaysBetween

    $deltaHtml += "    <div class='info-card' style='margin-bottom: 24px;'>`n"
    $deltaHtml += "      <div class='info-card-title'>Comparing against assessment from $daysBetween days ago</div>`n"
    $deltaHtml += "      <div class='info-card-text'>Prior assessment date: $(Escape-Html $d.PriorDate)</div>`n"
    $deltaHtml += "    </div>`n"

    # Delta KPI cards
    $deltaHtml += "    <div class='identity-kpi-grid' style='grid-template-columns: repeat(4, 1fr); margin-bottom: 24px;'>`n"

    $deltaMetrics = @(
      @{ Label = "Dataset Change"; Data = $d.Sizing.TotalGB; Unit = "GB"; InvertColor = $false },
      @{ Label = "User Change"; Data = $d.Sizing.UsersToProtect; Unit = ""; InvertColor = $false },
      @{ Label = "MBS Estimate Change"; Data = $d.Sizing.MbsEstimateGB; Unit = "GB"; InvertColor = $false }
    )
    if ($d.Scores -and $d.Scores.ReadinessScore) {
      $deltaMetrics += @{ Label = "Readiness Change"; Data = $d.Scores.ReadinessScore; Unit = "pts"; InvertColor = $true }
    }

    foreach ($dm in $deltaMetrics) {
      $val = $dm.Data
      if ($val -and $null -ne $val.Delta) {
        $sign = if ($val.Delta -gt 0) { "+" } else { "" }
        $colorUp = if ($dm.InvertColor) { "var(--color-success)" } else { "var(--color-warning)" }
        $colorDown = if ($dm.InvertColor) { "var(--color-danger)" } else { "var(--color-success)" }
        $deltaColor = if ($val.Delta -gt 0) { $colorUp } elseif ($val.Delta -lt 0) { $colorDown } else { "var(--ms-gray-90)" }
        $pctDisplay = if ($null -ne $val.DeltaPct) { " ($('{0:N1}' -f $val.DeltaPct)%)" } else { "" }
        $deltaHtml += @"
      <div class='identity-kpi'>
        <div class='identity-kpi-value' style='color: $deltaColor;'>$sign$('{0:N1}' -f $val.Delta) $($dm.Unit)</div>
        <div class='identity-kpi-label'>$($dm.Label)$pctDisplay</div>
      </div>
"@
      }
    }
    $deltaHtml += "    </div>`n"

    # Delta details table
    if ($d.Sizing) {
      $deltaHtml += "    <div class='table-container'>`n      <table>`n"
      $deltaHtml += "        <thead><tr><th>Metric</th><th>Prior</th><th>Current</th><th>Change</th><th>Direction</th></tr></thead>`n"
      $deltaHtml += "        <tbody>`n"
      foreach ($key in $d.Sizing.Keys) {
        $v = $d.Sizing[$key]
        if ($null -eq $v.Delta) { continue }
        $sign = if ($v.Delta -gt 0) { "+" } else { "" }
        $dirIcon = if ($v.Direction -eq "Up") { "&#9650;" } elseif ($v.Direction -eq "Down") { "&#9660;" } else { "&#9679;" }
        $deltaHtml += "          <tr><td>$key</td><td>$('{0:N2}' -f $v.Prior)</td><td>$('{0:N2}' -f $v.Current)</td><td>$sign$('{0:N2}' -f $v.Delta)</td><td>$dirIcon $($v.Direction)</td></tr>`n"
      }
      $deltaHtml += "        </tbody>`n      </table>`n    </div>`n"
    }

    $htmlParts.Add(@"
  <details class="section" open>
    <summary>Changes Since Last Assessment</summary>
    <div class="section-content">
$deltaHtml
    </div>
  </details>
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
  if ($script:outCompliance) { $artifactItems += "      <div class='file-item'>Compliance CSV: $(Split-Path $script:outCompliance -Leaf)</div>`n" }
  if ($script:outDelta) { $artifactItems += "      <div class='file-item'>Delta CSV: $(Split-Path $script:outDelta -Leaf)</div>`n" }

  $htmlParts.Add(@"
  <details class="section">
    <summary>Generated Artifacts</summary>
    <div class="section-content">
    <div class="file-list">
$artifactItems
    </div>
    </div>
  </details>
"@)

  # =============================
  # Professional Footer
  # =============================
  $htmlParts.Add(@"
  <footer class="exec-footer">
    <div class="exec-footer-org">Prepared for $(Escape-Html $orgDisplay)</div>
    <div class="exec-footer-conf">This report contains confidential organizational data. Handle according to your data classification policy.</div>
    <div class="exec-footer-stamp">$(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC | Veeam M365 Sizing Tool | Community Edition</div>
  </footer>
</div>
</body>
</html>
"@)

  # Join and write
  $html = $htmlParts -join "`n"
  $html | Set-Content -Path $outHtml -Encoding UTF8
}
