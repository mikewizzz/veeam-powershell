# SPDX-License-Identifier: MIT
# =========================================================================
# ComplianceReport.ps1 - Unified Cross-Platform Compliance Report Generator
# =========================================================================
#
# Generates professional HTML compliance reports from recovery validation
# results. Supports multiple compliance frameworks (NIS2, SOC2, ISO 27001,
# DORA) and provides auditor-ready attestation evidence.
#
# Dependencies:
#   . "$PSScriptRoot\RecoveryValidationSchema.ps1"  (must be loaded first)
#
# Usage:
#   . "$PSScriptRoot\ComplianceReport.ps1"
#   $report = New-UnifiedComplianceReport -Summary $validationSummary -OutputPath "C:\Reports"
#
# =========================================================================

#region HTML Helpers

function _EscapeHtml {
  <#
  .SYNOPSIS
    HTML-encodes a string to prevent XSS in report output.
  #>
  param([string]$Text)
  if ([string]::IsNullOrWhiteSpace($Text)) { return "" }
  return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&#39;'
}

#endregion

#region Compliance Framework Mappings

function Get-RecoveryComplianceMappings {
  <#
  .SYNOPSIS
    Returns compliance framework mappings for recovery validation testing.
  .DESCRIPTION
    Provides a structured mapping of recovery validation activities to specific
    compliance framework controls. Each mapping includes the framework name,
    control ID, control title, description, and what evidence recovery testing
    provides toward satisfying that control.
  .EXAMPLE
    $mappings = Get-RecoveryComplianceMappings
    $mappings | Where-Object { $_.Framework -eq "NIS2" }
  #>
  [CmdletBinding()]
  param()

  @(
    [PSCustomObject]@{
      Framework   = "NIS2"
      ControlId   = "Art 21(2)(c)"
      ControlName = "Business Continuity and Disaster Recovery"
      Description = "Measures for business continuity, such as backup management and disaster recovery, and crisis management."
      Evidence    = "Automated recovery testing validates that backups are recoverable and business continuity plans are functional. Scheduled testing demonstrates ongoing compliance with continuity requirements."
    },
    [PSCustomObject]@{
      Framework   = "SOC2"
      ControlId   = "A1.2"
      ControlName = "Recovery from Disruptions"
      Description = "The entity authorizes, designs, develops or acquires, implements, operates, approves, maintains, and monitors environmental protections, software, data back-up processes, and recovery infrastructure to meet its objectives."
      Evidence    = "Recovery validation testing proves that backup infrastructure can restore protected workloads to operational state. Pass/fail results and RTO measurements provide quantitative evidence of recovery capability."
    },
    [PSCustomObject]@{
      Framework   = "SOC2"
      ControlId   = "A1.3"
      ControlName = "Recovery Plan Testing"
      Description = "The entity tests recovery plan procedures supporting system recovery to meet its objectives."
      Evidence    = "Automated cross-platform recovery testing constitutes systematic execution of recovery plan procedures. Test reports with timestamps, pass rates, and RTO compliance serve as testing evidence."
    },
    [PSCustomObject]@{
      Framework   = "ISO 27001"
      ControlId   = "A.8.13"
      ControlName = "Information Backup"
      Description = "Backup copies of information, software and systems shall be maintained and regularly tested in accordance with the agreed topic-specific policy on backup."
      Evidence    = "Recovery validation verifies backup integrity by performing actual restore operations and verifying VM boot, network connectivity, and application responsiveness. Results demonstrate regular testing per backup policy."
    },
    [PSCustomObject]@{
      Framework   = "ISO 27001"
      ControlId   = "A.5.30"
      ControlName = "ICT Readiness for Business Continuity"
      Description = "ICT readiness shall be planned, implemented, maintained and tested based on business continuity objectives and ICT continuity requirements."
      Evidence    = "Cross-platform recovery testing (AHV, Azure, AWS) validates ICT readiness across the infrastructure estate. RTO compliance metrics demonstrate alignment with business continuity objectives."
    },
    [PSCustomObject]@{
      Framework   = "DORA"
      ControlId   = "Art 11"
      ControlName = "ICT Business Continuity Testing"
      Description = "Financial entities shall test the ICT business continuity policy and the ICT response and recovery plans at least yearly, including scenarios of severe business disruptions."
      Evidence    = "Automated recovery validation provides evidence of ICT business continuity testing. Multi-platform coverage and RTO tracking demonstrate comprehensive testing of recovery capabilities against business disruption scenarios."
    }
  )
}

#endregion

#region Compliance Scoring

function Get-RecoveryComplianceScore {
  <#
  .SYNOPSIS
    Calculates a 0-100 compliance score from recovery validation results.
  .DESCRIPTION
    Produces a weighted compliance score based on five dimensions:
    - Test coverage (25%): How many platforms were tested vs. known platforms
    - Pass rate (30%): Percentage of tests that passed
    - RTO compliance (20%): Percentage of VMs meeting RTO targets
    - Recency (15%): How recently the last test was run
    - Automation (10%): Whether tests were automated vs. manual
  .PARAMETER Summary
    A RecoveryValidationSummary object from New-RecoveryValidationSummary.
  .PARAMETER KnownPlatformCount
    Total number of platforms in the environment. Default: 4 (AHV, Azure, AWS, VMware).
  .PARAMETER IsAutomated
    Whether the test run was automated (scheduled) vs. manual. Default: $true.
  .EXAMPLE
    $score = Get-RecoveryComplianceScore -Summary $summary -KnownPlatformCount 3
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary,

    [ValidateRange(1, 20)]
    [int]$KnownPlatformCount = 4,

    [bool]$IsAutomated = $true
  )

  # Weights
  $wCoverage    = 0.25
  $wPassRate    = 0.30
  $wRTO         = 0.20
  $wRecency     = 0.15
  $wAutomation  = 0.10

  # 1. Coverage score: platforms tested / known platforms
  $platformsTested = @($Summary.Platforms).Count
  $coverageScore = [Math]::Min(($platformsTested / $KnownPlatformCount) * 100, 100)

  # 2. Pass rate (direct from summary)
  $passRateScore = $Summary.PassRate

  # 3. RTO compliance
  $rtoScore = $Summary.RTOComplianceRate
  # If no RTO data exists, give partial credit (50) rather than zero
  $rtoResults = @($Summary.Results | Where-Object { $null -ne $_.RTOMet })
  if ($rtoResults.Count -eq 0) {
    $rtoScore = 50.0
  }

  # 4. Recency: tests within 24h = 100, within 7d = 80, within 30d = 50, older = 20
  $hoursSinceTest = ((Get-Date) - $Summary.Timestamp).TotalHours
  if ($hoursSinceTest -le 24) {
    $recencyScore = 100.0
  }
  elseif ($hoursSinceTest -le 168) {
    $recencyScore = 80.0
  }
  elseif ($hoursSinceTest -le 720) {
    $recencyScore = 50.0
  }
  else {
    $recencyScore = 20.0
  }

  # 5. Automation score
  $automationScore = if ($IsAutomated) { 100.0 } else { 60.0 }

  # Weighted total
  $totalScore = [Math]::Round(
    ($coverageScore * $wCoverage) +
    ($passRateScore * $wPassRate) +
    ($rtoScore * $wRTO) +
    ($recencyScore * $wRecency) +
    ($automationScore * $wAutomation),
    0
  )

  [PSCustomObject]@{
    OverallScore     = [int]$totalScore
    CoverageScore    = [Math]::Round($coverageScore, 1)
    PassRateScore    = [Math]::Round($passRateScore, 1)
    RTOScore         = [Math]::Round($rtoScore, 1)
    RecencyScore     = [Math]::Round($recencyScore, 1)
    AutomationScore  = [Math]::Round($automationScore, 1)
    Grade            = if ($totalScore -ge 90) { "A" } elseif ($totalScore -ge 75) { "B" } elseif ($totalScore -ge 60) { "C" } elseif ($totalScore -ge 40) { "D" } else { "F" }
  }
}

#endregion

#region HTML Report Generation

function New-UnifiedComplianceReport {
  <#
  .SYNOPSIS
    Generates a unified cross-platform compliance report in HTML format.
  .DESCRIPTION
    Produces a professional HTML report (Microsoft Fluent Design System styling)
    from a RecoveryValidationSummary. The report includes:
    - Executive summary with compliance score gauge
    - Cross-platform recovery verification status
    - Per-platform breakdown table
    - RTO compliance metrics
    - Compliance evidence section (SOC2, ISO 27001, NIS2, DORA mappings)
    - Attestation statement suitable for auditor review

    The report is fully self-contained (inline CSS, no JavaScript, no external
    resources) and renders correctly in all modern browsers and when printed to PDF.
  .PARAMETER Summary
    A RecoveryValidationSummary object from New-RecoveryValidationSummary.
  .PARAMETER OutputPath
    Directory to write the HTML report. Created if it does not exist.
  .PARAMETER KnownPlatformCount
    Total platforms in environment for compliance scoring. Default: 4.
  .PARAMETER IsAutomated
    Whether the test was automated. Default: $true.
  .PARAMETER OrganizationName
    Organization name for the report header. Default: "Organization".
  .PARAMETER FilePrefix
    File name prefix. Default: "ComplianceReport".
  .EXAMPLE
    $report = New-UnifiedComplianceReport -Summary $summary -OutputPath "C:\Reports" -OrganizationName "Contoso"
  .OUTPUTS
    PSCustomObject with HtmlPath property.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [ValidateRange(1, 20)]
    [int]$KnownPlatformCount = 4,

    [bool]$IsAutomated = $true,

    [string]$OrganizationName = "Organization",

    [string]$FilePrefix = "ComplianceReport"
  )

  if (-not (Test-Path $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
  }

  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $htmlPath = Join-Path $OutputPath "${FilePrefix}_${timestamp}.html"

  # Calculate compliance score
  $complianceScore = Get-RecoveryComplianceScore -Summary $Summary -KnownPlatformCount $KnownPlatformCount -IsAutomated $IsAutomated

  # Get compliance mappings
  $mappings = Get-RecoveryComplianceMappings

  # Safe values
  $safeOrg = _EscapeHtml $OrganizationName
  $reportDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

  # Overall status
  $overallStatusText = if ($Summary.OverallSuccess) { "ALL TESTS PASSED" } else { "TESTS FAILED" }
  $statusColor = if ($Summary.OverallSuccess) { "#00B336" } else { "#D13438" }

  # Compliance score color
  $scoreColor = if ($complianceScore.OverallScore -ge 90) { "#00B336" }
    elseif ($complianceScore.OverallScore -ge 75) { "#0078D4" }
    elseif ($complianceScore.OverallScore -ge 60) { "#F7630C" }
    else { "#D13438" }

  # Build per-platform breakdown rows
  $platformRows = ""
  foreach ($platform in $Summary.Platforms) {
    $platformResults = @($Summary.Results | Where-Object { $_.Platform -eq $platform })
    $pTotal = $platformResults.Count
    $pPassed = @($platformResults | Where-Object { $_.Passed -eq $true }).Count
    $pFailed = $pTotal - $pPassed
    $pRate = if ($pTotal -gt 0) { [Math]::Round(($pPassed / $pTotal) * 100, 1) } else { 0.0 }
    $pVMs = @($platformResults | Select-Object -ExpandProperty VMName -Unique).Count

    $pRtoResults = @($platformResults | Where-Object { $null -ne $_.RTOMet })
    $pAvgRTO = "N/A"
    $pRTOCompliance = "N/A"
    if ($pRtoResults.Count -gt 0) {
      $pAvgRTO = "$([Math]::Round(($pRtoResults | Measure-Object -Property RTOActualMinutes -Average).Average, 1)) min"
      $pRTOMetCount = @($pRtoResults | Where-Object { $_.RTOMet -eq $true }).Count
      $pRTOCompliance = "$([Math]::Round(($pRTOMetCount / $pRtoResults.Count) * 100, 0))%"
    }

    $safePlatform = _EscapeHtml $platform
    $pStatusClass = if ($pFailed -eq 0) { "status-pass" } else { "status-fail" }
    $pStatusText = if ($pFailed -eq 0) { "PASS" } else { "FAIL" }

    $platformRows += @"
    <tr>
      <td><strong>$safePlatform</strong></td>
      <td>$pVMs</td>
      <td>$pTotal</td>
      <td>$pPassed</td>
      <td>$pFailed</td>
      <td>$pRate%</td>
      <td>$(_EscapeHtml $pAvgRTO)</td>
      <td>$(_EscapeHtml $pRTOCompliance)</td>
      <td><span class="$pStatusClass">$pStatusText</span></td>
    </tr>
"@
  }

  # Build detailed test result rows
  $testDetailRows = ""
  foreach ($result in $Summary.Results) {
    $statusClass = if ($result.Passed) { "status-pass" } else { "status-fail" }
    $statusText = if ($result.Passed) { "PASS" } else { "FAIL" }
    $durText = "$([Math]::Round($result.DurationSeconds, 1))s"
    $rpText = if ($result.RestorePointTime -ne [datetime]::MinValue) { $result.RestorePointTime.ToString("yyyy-MM-dd HH:mm") } else { "N/A" }

    $testDetailRows += @"
    <tr>
      <td>$(_EscapeHtml $result.Platform)</td>
      <td>$(_EscapeHtml $result.VMName)</td>
      <td>$(_EscapeHtml $result.TestCategory)</td>
      <td>$(_EscapeHtml $result.TestName)</td>
      <td><span class="$statusClass">$statusText</span></td>
      <td>$(_EscapeHtml $result.Details)</td>
      <td>$durText</td>
      <td>$(_EscapeHtml $rpText)</td>
    </tr>
"@
  }

  # Build compliance evidence rows
  $complianceRows = ""
  foreach ($m in $mappings) {
    $safeFramework = _EscapeHtml $m.Framework
    $safeControlId = _EscapeHtml $m.ControlId
    $safeControlName = _EscapeHtml $m.ControlName
    $safeDescription = _EscapeHtml $m.Description
    $safeEvidence = _EscapeHtml $m.Evidence

    $complianceRows += @"
    <tr>
      <td><strong>$safeFramework</strong></td>
      <td>$safeControlId</td>
      <td>$safeControlName</td>
      <td>$safeDescription</td>
      <td class="evidence-cell">$safeEvidence</td>
    </tr>
"@
  }

  # Build SVG gauge for compliance score
  $scoreAngle = [Math]::Round(($complianceScore.OverallScore / 100) * 180, 0)
  $scoreRad = $scoreAngle * [Math]::PI / 180
  $gaugeX = [Math]::Round(100 + 70 * [Math]::Cos([Math]::PI - $scoreRad), 1)
  $gaugeY = [Math]::Round(100 - 70 * [Math]::Sin([Math]::PI - $scoreRad), 1)
  $largeArc = if ($scoreAngle -gt 180) { 1 } else { 0 }

  $scoreDimRows = @"
    <div class="score-dim"><span class="score-dim-label">Coverage</span><span class="score-dim-value">$($complianceScore.CoverageScore)%</span></div>
    <div class="score-dim"><span class="score-dim-label">Pass Rate</span><span class="score-dim-value">$($complianceScore.PassRateScore)%</span></div>
    <div class="score-dim"><span class="score-dim-label">RTO Compliance</span><span class="score-dim-value">$($complianceScore.RTOScore)%</span></div>
    <div class="score-dim"><span class="score-dim-label">Recency</span><span class="score-dim-value">$($complianceScore.RecencyScore)%</span></div>
    <div class="score-dim"><span class="score-dim-label">Automation</span><span class="score-dim-value">$($complianceScore.AutomationScore)%</span></div>
"@

  # RTO summary
  $rtoResults = @($Summary.Results | Where-Object { $null -ne $_.RTOMet })
  $rtoSectionHtml = ""
  if ($rtoResults.Count -gt 0) {
    $rtoMetCount = @($rtoResults | Where-Object { $_.RTOMet -eq $true }).Count
    $rtoBreachedCount = $rtoResults.Count - $rtoMetCount

    $rtoRows = ""
    $rtoVMs = @($rtoResults | Select-Object -Property VMName, Platform, RTOTargetMinutes, RTOActualMinutes, RTOMet -Unique)
    # Deduplicate by VM + Platform
    $seenRtoVMs = @{}
    foreach ($rv in $rtoResults) {
      $rtoKey = "$($rv.Platform)|$($rv.VMName)"
      if (-not $seenRtoVMs.ContainsKey($rtoKey)) {
        $seenRtoVMs[$rtoKey] = $rv
      }
    }
    foreach ($rtoKey in $seenRtoVMs.Keys) {
      $rv = $seenRtoVMs[$rtoKey]
      $rtoStatusClass = if ($rv.RTOMet) { "status-pass" } else { "status-fail" }
      $rtoStatusText = if ($rv.RTOMet) { "MET" } else { "BREACHED" }
      $delta = [Math]::Round($rv.RTOTargetMinutes - $rv.RTOActualMinutes, 1)
      $deltaText = if ($delta -ge 0) { "+$delta min" } else { "$delta min" }

      $rtoRows += @"
      <tr>
        <td>$(_EscapeHtml $rv.Platform)</td>
        <td>$(_EscapeHtml $rv.VMName)</td>
        <td>$($rv.RTOTargetMinutes) min</td>
        <td>$($rv.RTOActualMinutes) min</td>
        <td>$deltaText</td>
        <td><span class="$rtoStatusClass">$rtoStatusText</span></td>
      </tr>
"@
    }

    $rtoSectionHtml = @"
  <div class="section">
    <div class="section-title">RTO Compliance</div>
    <div class="kpi-grid">
      <div class="kpi-card">
        <div class="kpi-label">Avg Recovery Time</div>
        <div class="kpi-value">$($Summary.AvgRTOMinutes)m</div>
        <div class="kpi-subtext">across all tested VMs</div>
      </div>
      <div class="kpi-card$(if($rtoBreachedCount -gt 0){' fail'})">
        <div class="kpi-label">RTO Compliance</div>
        <div class="kpi-value">$($Summary.RTOComplianceRate)%</div>
        <div class="kpi-subtext">$rtoMetCount met / $rtoBreachedCount breached</div>
      </div>
    </div>
    <table>
      <thead>
        <tr>
          <th>Platform</th>
          <th>VM Name</th>
          <th>RTO Target</th>
          <th>RTO Actual</th>
          <th>Delta</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
$rtoRows
      </tbody>
    </table>
  </div>
"@
  }

  # Attestation statement
  $attestationDate = Get-Date -Format "MMMM d, yyyy"
  $platformList = ($Summary.Platforms | ForEach-Object { _EscapeHtml $_ }) -join ", "

  # Build HTML
  $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Recovery Validation Compliance Report</title>
<style>
:root {
  --veeam-green: #00B336;
  --veeam-dark: #005F28;
  --ms-gray-10: #FAF9F8;
  --ms-gray-20: #F3F2F1;
  --ms-gray-30: #EDEBE9;
  --ms-gray-50: #D2D0CE;
  --ms-gray-90: #605E5C;
  --ms-gray-130: #323130;
  --ms-gray-160: #201F1E;
  --ms-red: #D13438;
  --ms-blue: #0078D4;
  --ms-blue-dark: #106EBE;
  --color-success: #107C10;
  --color-warning: #F7630C;
  --color-danger: #D13438;
  --header-dark: #1B1B2F;
  --header-mid: #1F4068;
  --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
  --shadow-depth-8: 0 3.2px 7.2px 0 rgba(0,0,0,.132), 0 0.6px 1.8px 0 rgba(0,0,0,.108);
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

/* ===== Overall Status Banner ===== */
.overall-status {
  background: white;
  padding: 24px 32px;
  margin-bottom: 32px;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-8);
  border-left: 6px solid ${statusColor};
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.overall-status-text {
  font-size: 24px; font-weight: 600; color: ${statusColor};
}
.overall-status-detail {
  font-size: 14px; color: var(--ms-gray-90);
}

/* ===== KPI Cards ===== */
.kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
  gap: 20px;
  margin-bottom: 24px;
}
.kpi-card {
  background: white;
  padding: 24px;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-4);
  border-top: 3px solid var(--veeam-green);
}
.kpi-card.fail { border-top-color: var(--ms-red); }
.kpi-card.blue { border-top-color: var(--ms-blue); }
.kpi-label {
  font-size: 11px; font-weight: 600; text-transform: uppercase;
  letter-spacing: 0.06em; color: var(--ms-gray-90); margin-bottom: 8px;
}
.kpi-value {
  font-size: 36px; font-weight: 300; color: var(--ms-gray-160);
  margin-bottom: 4px;
  font-family: 'Cascadia Code', 'Consolas', 'Courier New', monospace;
  font-variant-numeric: tabular-nums;
}
.kpi-subtext { font-size: 12px; color: var(--ms-gray-90); font-weight: 400; }

/* ===== Sections ===== */
.section {
  background: white;
  padding: 32px;
  margin-bottom: 24px;
  border-radius: 4px;
  box-shadow: var(--shadow-depth-4);
}
.section-title {
  font-size: 20px; font-weight: 600; color: var(--ms-gray-160);
  margin-bottom: 20px; padding-bottom: 12px;
  border-bottom: 3px solid transparent;
  border-image: linear-gradient(90deg, var(--ms-blue), var(--veeam-green), transparent) 1;
}

/* ===== Tables ===== */
table { width: 100%; border-collapse: collapse; font-size: 14px; margin-top: 16px; }
thead { background: var(--ms-gray-20); }
th {
  padding: 12px 16px; text-align: left; font-weight: 600;
  color: var(--ms-gray-130); font-size: 12px; text-transform: uppercase;
  letter-spacing: 0.03em; border-bottom: 2px solid var(--ms-gray-50);
}
td {
  padding: 14px 16px; border-bottom: 1px solid var(--ms-gray-30);
  color: var(--ms-gray-160);
}
tbody tr:hover { background: var(--ms-gray-10); }

.evidence-cell { font-size: 13px; color: var(--ms-gray-90); line-height: 1.5; }

/* ===== Status Badges ===== */
.status-pass {
  background: #DFF6DD; color: #0E700E;
  padding: 4px 12px; border-radius: 12px;
  font-weight: 600; font-size: 12px;
}
.status-fail {
  background: #FDE7E9; color: #D13438;
  padding: 4px 12px; border-radius: 12px;
  font-weight: 600; font-size: 12px;
}

/* ===== Compliance Score ===== */
.score-container {
  display: flex; gap: 32px; align-items: flex-start; flex-wrap: wrap;
}
.score-gauge { text-align: center; min-width: 220px; }
.score-breakdown { flex: 1; min-width: 280px; }
.score-dim {
  display: flex; justify-content: space-between; align-items: center;
  padding: 10px 0; border-bottom: 1px solid var(--ms-gray-30);
}
.score-dim:last-child { border-bottom: none; }
.score-dim-label { font-size: 13px; color: var(--ms-gray-90); font-weight: 500; }
.score-dim-value { font-size: 14px; font-weight: 600; color: var(--ms-gray-160); }

/* ===== Attestation ===== */
.attestation {
  background: var(--ms-gray-10);
  border-left: 4px solid var(--ms-blue);
  padding: 24px 28px;
  margin: 16px 0;
  border-radius: 2px;
}
.attestation-title {
  font-weight: 700; font-size: 15px; color: var(--ms-gray-130);
  margin-bottom: 12px;
}
.attestation-text {
  color: var(--ms-gray-90); font-size: 14px; line-height: 1.7;
}
.attestation-sig {
  margin-top: 24px; padding-top: 16px;
  border-top: 1px solid var(--ms-gray-50);
  display: grid; grid-template-columns: 1fr 1fr; gap: 24px;
}
.attestation-field { }
.attestation-field-label {
  font-size: 11px; text-transform: uppercase; letter-spacing: 0.05em;
  color: var(--ms-gray-90); font-weight: 600; margin-bottom: 4px;
}
.attestation-field-value {
  font-size: 14px; color: var(--ms-gray-160); font-weight: 500;
  border-bottom: 1px solid var(--ms-gray-50); padding-bottom: 4px;
  min-height: 24px;
}

/* ===== Footer ===== */
.footer {
  text-align: center; padding: 32px;
  color: var(--ms-gray-90); font-size: 13px;
}

/* ===== Print ===== */
@media print {
  body { background: white; }
  .exec-header { break-after: avoid; }
  .section { box-shadow: none; border: 1px solid var(--ms-gray-30); break-inside: avoid; }
  .kpi-card { box-shadow: none; border: 1px solid var(--ms-gray-30); }
}

@media (max-width: 768px) {
  .kpi-grid { grid-template-columns: 1fr; }
  .score-container { flex-direction: column; }
  .overall-status { flex-direction: column; gap: 16px; }
  .attestation-sig { grid-template-columns: 1fr; }
}
</style>
</head>
<body>

<!-- Executive Header -->
<div class="exec-header">
  <div class="exec-header-inner">
    <div class="exec-header-org">$safeOrg</div>
    <div class="exec-header-title">Recovery Validation Compliance Report (Community Tool)</div>
    <div class="exec-header-meta">
      <div class="exec-header-meta-item"><strong>Generated:</strong> $reportDate</div>
      <div class="exec-header-meta-item"><strong>Run ID:</strong> $(_EscapeHtml $Summary.RunId)</div>
      <div class="exec-header-meta-item"><strong>Duration:</strong> $(_EscapeHtml $Summary.Duration)</div>
      <div class="exec-header-meta-item"><strong>Platforms:</strong> $platformList</div>
      <span class="exec-badge">Grade $(_EscapeHtml $complianceScore.Grade)</span>
    </div>
  </div>
</div>

<div class="container">

  <!-- Overall Status -->
  <div class="overall-status">
    <div>
      <div class="overall-status-text">$overallStatusText</div>
      <div class="overall-status-detail">$($Summary.PassedTests) of $($Summary.TotalTests) tests passed across $($Summary.TotalVMs) VM(s) on $(@($Summary.Platforms).Count) platform(s)</div>
    </div>
    <div style="text-align: right;">
      <div style="font-size: 48px; font-weight: 300; color: ${statusColor};">$($Summary.PassRate)%</div>
      <div style="font-size: 13px; color: var(--ms-gray-90);">Test Pass Rate</div>
    </div>
  </div>

  <!-- KPI Cards -->
  <div class="kpi-grid">
    <div class="kpi-card">
      <div class="kpi-label">VMs Tested</div>
      <div class="kpi-value">$($Summary.TotalVMs)</div>
      <div class="kpi-subtext">across $(@($Summary.Platforms).Count) platform(s)</div>
    </div>
    <div class="kpi-card$(if($Summary.FailedTests -gt 0){' fail'})">
      <div class="kpi-label">Total Tests</div>
      <div class="kpi-value">$($Summary.TotalTests)</div>
      <div class="kpi-subtext">$($Summary.PassedTests) passed, $($Summary.FailedTests) failed</div>
    </div>
    <div class="kpi-card blue">
      <div class="kpi-label">Compliance Score</div>
      <div class="kpi-value" style="color: ${scoreColor};">$($complianceScore.OverallScore)</div>
      <div class="kpi-subtext">Grade $(_EscapeHtml $complianceScore.Grade) / 100</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-label">Execution Mode</div>
      <div class="kpi-value" style="font-size: 20px;">$(if($IsAutomated){"Automated"}else{"Manual"})</div>
      <div class="kpi-subtext">$(_EscapeHtml $Summary.Duration) total runtime</div>
    </div>
  </div>

  <!-- Compliance Score Breakdown -->
  <div class="section">
    <div class="section-title">Compliance Score Breakdown</div>
    <div class="score-container">
      <div class="score-gauge">
        <svg viewBox="0 0 200 120" width="220" height="132">
          <!-- Background arc -->
          <path d="M 30 100 A 70 70 0 0 1 170 100" fill="none" stroke="#EDEBE9" stroke-width="12" stroke-linecap="round"/>
          <!-- Score arc -->
          <path d="M 30 100 A 70 70 0 $largeArc 1 $gaugeX $gaugeY" fill="none" stroke="$scoreColor" stroke-width="12" stroke-linecap="round"/>
          <!-- Score text -->
          <text x="100" y="90" text-anchor="middle" font-family="'Cascadia Code','Consolas',monospace" font-size="36" font-weight="700" fill="$scoreColor">$($complianceScore.OverallScore)</text>
          <text x="100" y="112" text-anchor="middle" font-family="'Segoe UI',sans-serif" font-size="12" fill="#605E5C">out of 100</text>
        </svg>
      </div>
      <div class="score-breakdown">
        $scoreDimRows
      </div>
    </div>
  </div>

  <!-- Per-Platform Breakdown -->
  <div class="section">
    <div class="section-title">Platform Breakdown</div>
    <table>
      <thead>
        <tr>
          <th>Platform</th>
          <th>VMs</th>
          <th>Tests</th>
          <th>Passed</th>
          <th>Failed</th>
          <th>Pass Rate</th>
          <th>Avg RTO</th>
          <th>RTO Compliance</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
$platformRows
      </tbody>
    </table>
  </div>

  <!-- RTO Compliance (conditional) -->
$rtoSectionHtml

  <!-- Detailed Test Results -->
  <div class="section">
    <div class="section-title">Detailed Test Results</div>
    <table>
      <thead>
        <tr>
          <th>Platform</th>
          <th>VM Name</th>
          <th>Category</th>
          <th>Test</th>
          <th>Result</th>
          <th>Details</th>
          <th>Duration</th>
          <th>Restore Point</th>
        </tr>
      </thead>
      <tbody>
$testDetailRows
      </tbody>
    </table>
  </div>

  <!-- Compliance Evidence -->
  <div class="section">
    <div class="section-title">Compliance Framework Mappings</div>
    <table>
      <thead>
        <tr>
          <th>Framework</th>
          <th>Control</th>
          <th>Control Name</th>
          <th>Requirement</th>
          <th>Evidence Provided</th>
        </tr>
      </thead>
      <tbody>
$complianceRows
      </tbody>
    </table>
  </div>

  <!-- Attestation Statement -->
  <div class="section">
    <div class="section-title">Attestation Statement</div>
    <div class="attestation">
      <div class="attestation-title">Recovery Validation Attestation</div>
      <div class="attestation-text">
        This report certifies that automated recovery validation testing was performed on
        <strong>$attestationDate</strong> covering <strong>$($Summary.TotalVMs) virtual machine(s)</strong>
        across <strong>$platformList</strong> platform(s).
        A total of <strong>$($Summary.TotalTests) verification tests</strong> were executed, of which
        <strong>$($Summary.PassedTests) passed</strong> and <strong>$($Summary.FailedTests) failed</strong>,
        yielding a pass rate of <strong>$($Summary.PassRate)%</strong>.
        The overall compliance score is <strong>$($complianceScore.OverallScore)/100 (Grade $(_EscapeHtml $complianceScore.Grade))</strong>.
        <br><br>
        This attestation is generated automatically by a community-maintained recovery validation tool.
        It is not an official product certification. Results should be reviewed by qualified personnel
        and validated against organizational recovery policies before submission to auditors.
      </div>
      <div class="attestation-sig">
        <div class="attestation-field">
          <div class="attestation-field-label">Reviewed By</div>
          <div class="attestation-field-value">&nbsp;</div>
        </div>
        <div class="attestation-field">
          <div class="attestation-field-label">Date</div>
          <div class="attestation-field-value">&nbsp;</div>
        </div>
        <div class="attestation-field">
          <div class="attestation-field-label">Title / Role</div>
          <div class="attestation-field-value">&nbsp;</div>
        </div>
        <div class="attestation-field">
          <div class="attestation-field-label">Signature</div>
          <div class="attestation-field-value">&nbsp;</div>
        </div>
      </div>
    </div>
  </div>

  <!-- Footer -->
  <div class="footer">
    <p>Recovery Validation Compliance Report v1.0.0 (Community Tool) | Generated on $reportDate</p>
    <p>Run ID: $(_EscapeHtml $Summary.RunId) | This is not an official product &mdash; community-maintained</p>
  </div>

</div>
</body>
</html>
"@

  $html | Out-File -FilePath $htmlPath -Encoding UTF8
  Write-Verbose "HTML report exported to: $htmlPath"

  [PSCustomObject]@{
    HtmlPath = $htmlPath
  }
}

#endregion

#region Scheduling Helpers

function New-RecoveryScheduleConfig {
  <#
  .SYNOPSIS
    Generates a Task Scheduler XML or cron job definition for recurring recovery validation.
  .DESCRIPTION
    Creates either a Windows Task Scheduler XML definition or a Unix cron entry
    for scheduling automated recovery validation runs. Detects the current OS
    and generates the appropriate format, or use -Force to specify.
  .PARAMETER Platform
    Target platform for recovery testing: AHV, Azure, AWS, or All.
  .PARAMETER Frequency
    Execution frequency: Daily, Weekly, or Monthly.
  .PARAMETER Time
    Execution time in HH:mm format (24-hour). Default: "02:00".
  .PARAMETER DayOfWeek
    Day of week for Weekly frequency (Monday-Sunday). Default: "Sunday".
  .PARAMETER DayOfMonth
    Day of month for Monthly frequency (1-28). Default: 1.
  .PARAMETER ScriptPath
    Full path to the recovery validation script to execute.
  .PARAMETER ScriptArgs
    Additional arguments to pass to the script.
  .PARAMETER TaskName
    Name for the scheduled task. Default: "VeeamRecoveryValidation".
  .PARAMETER OutputPath
    Directory to write the schedule config file. If not specified, outputs to console.
  .PARAMETER ForceFormat
    Force output format: "TaskScheduler" (Windows XML) or "Cron" (Unix).
    If omitted, auto-detects based on OS.
  .EXAMPLE
    New-RecoveryScheduleConfig -Platform "All" -Frequency "Weekly" -ScriptPath "C:\Scripts\Validate.ps1"
  .EXAMPLE
    New-RecoveryScheduleConfig -Platform "AHV" -Frequency "Monthly" -DayOfMonth 15 -ScriptPath "/opt/scripts/validate.ps1" -ForceFormat "Cron"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("AHV", "Azure", "AWS", "All")]
    [string]$Platform,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Daily", "Weekly", "Monthly")]
    [string]$Frequency,

    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$Time = "02:00",

    [ValidateSet("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")]
    [string]$DayOfWeek = "Sunday",

    [ValidateRange(1, 28)]
    [int]$DayOfMonth = 1,

    [Parameter(Mandatory = $true)]
    [string]$ScriptPath,

    [string]$ScriptArgs = "",

    [string]$TaskName = "VeeamRecoveryValidation",

    [string]$OutputPath = "",

    [ValidateSet("TaskScheduler", "Cron")]
    [string]$ForceFormat = ""
  )

  # Determine format
  $format = $ForceFormat
  if ([string]::IsNullOrWhiteSpace($format)) {
    if ($env:OS -match "Windows" -or [System.Environment]::OSVersion.Platform -eq "Win32NT") {
      $format = "TaskScheduler"
    }
    else {
      $format = "Cron"
    }
  }

  $result = $null

  if ($format -eq "TaskScheduler") {
    $startBoundary = "2026-01-01T${Time}:00"

    # Build trigger based on frequency
    $triggerXml = ""
    switch ($Frequency) {
      "Daily" {
        $triggerXml = @"
      <CalendarTrigger>
        <StartBoundary>$startBoundary</StartBoundary>
        <Enabled>true</Enabled>
        <ScheduleByDay>
          <DaysInterval>1</DaysInterval>
        </ScheduleByDay>
      </CalendarTrigger>
"@
      }
      "Weekly" {
        $triggerXml = @"
      <CalendarTrigger>
        <StartBoundary>$startBoundary</StartBoundary>
        <Enabled>true</Enabled>
        <ScheduleByWeek>
          <WeeksInterval>1</WeeksInterval>
          <DaysOfWeek>
            <$DayOfWeek />
          </DaysOfWeek>
        </ScheduleByWeek>
      </CalendarTrigger>
"@
      }
      "Monthly" {
        $triggerXml = @"
      <CalendarTrigger>
        <StartBoundary>$startBoundary</StartBoundary>
        <Enabled>true</Enabled>
        <ScheduleByMonth>
          <DaysOfMonth>
            <Day>$DayOfMonth</Day>
          </DaysOfMonth>
          <Months>
            <January /><February /><March /><April /><May /><June />
            <July /><August /><September /><October /><November /><December />
          </Months>
        </ScheduleByMonth>
      </CalendarTrigger>
"@
      }
    }

    $fullArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""
    if ($ScriptArgs -ne "") {
      $fullArgs += " $ScriptArgs"
    }

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Automated recovery validation testing ($Platform platform, $Frequency schedule)</Description>
    <URI>\$TaskName</URI>
  </RegistrationInfo>
  <Triggers>
$triggerXml
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>S4U</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>true</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT4H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$(_EscapeHtml $fullArgs)</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $result = [PSCustomObject]@{
      Format   = "TaskScheduler"
      Content  = $xml
      FileName = "${TaskName}.xml"
      ImportCommand = "Register-ScheduledTask -Xml (Get-Content '${TaskName}.xml' | Out-String) -TaskName '$TaskName'"
    }
  }
  else {
    # Cron format
    $timeParts = $Time -split ':'
    $cronMinute = [int]$timeParts[1]
    $cronHour = [int]$timeParts[0]

    $cronSchedule = ""
    switch ($Frequency) {
      "Daily"   { $cronSchedule = "$cronMinute $cronHour * * *" }
      "Weekly"  {
        $dayNum = switch ($DayOfWeek) {
          "Sunday"    { 0 }
          "Monday"    { 1 }
          "Tuesday"   { 2 }
          "Wednesday" { 3 }
          "Thursday"  { 4 }
          "Friday"    { 5 }
          "Saturday"  { 6 }
        }
        $cronSchedule = "$cronMinute $cronHour * * $dayNum"
      }
      "Monthly" { $cronSchedule = "$cronMinute $cronHour $DayOfMonth * *" }
    }

    $cronCommand = "pwsh -NoProfile -File '$ScriptPath'"
    if ($ScriptArgs -ne "") {
      $cronCommand += " $ScriptArgs"
    }

    $cronLine = "# Recovery validation ($Platform, $Frequency at $Time)`n$cronSchedule $cronCommand"

    $result = [PSCustomObject]@{
      Format   = "Cron"
      Content  = $cronLine
      FileName = "${TaskName}.cron"
      ImportCommand = "crontab -l 2>/dev/null; echo '$cronSchedule $cronCommand' | crontab -"
    }
  }

  # Write to file if OutputPath specified
  if ($OutputPath -ne "") {
    if (-not (Test-Path $OutputPath)) {
      New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }
    $filePath = Join-Path $OutputPath $result.FileName
    $result.Content | Out-File -FilePath $filePath -Encoding UTF8
    $result | Add-Member -NotePropertyName "FilePath" -NotePropertyValue $filePath
    Write-Verbose "Schedule config written to: $filePath"
  }

  return $result
}

#endregion

#region Notification Functions

function Send-RecoveryNotification {
  <#
  .SYNOPSIS
    Sends notification on recovery validation completion or failure.
  .DESCRIPTION
    Dispatches a formatted notification via webhook (Teams/Slack) and/or SMTP
    email. The notification includes a summary of the validation run with
    pass/fail counts, compliance score, and RTO metrics.

    For webhooks, uses Invoke-RestMethod to POST an Adaptive Card (Teams) or
    Block Kit (Slack) payload. Auto-detects the webhook type from the URL.

    For email, uses Send-MailMessage with an HTML body.
  .PARAMETER Summary
    A RecoveryValidationSummary object from New-RecoveryValidationSummary.
  .PARAMETER WebhookUrl
    Teams or Slack incoming webhook URL. Auto-detected from URL pattern.
  .PARAMETER SmtpServer
    SMTP server hostname for email notifications.
  .PARAMETER SmtpPort
    SMTP port. Default: 25.
  .PARAMETER SmtpCredential
    Optional PSCredential for SMTP authentication.
  .PARAMETER UseSsl
    Use SSL/TLS for SMTP connection. Default: $false.
  .PARAMETER To
    Email recipient addresses.
  .PARAMETER From
    Email sender address.
  .PARAMETER Subject
    Email subject line. Default: auto-generated from results.
  .PARAMETER ComplianceScore
    Optional compliance score object from Get-RecoveryComplianceScore.
    If provided, included in the notification.
  .EXAMPLE
    Send-RecoveryNotification -Summary $summary -WebhookUrl "https://outlook.office.com/webhook/..."
  .EXAMPLE
    Send-RecoveryNotification -Summary $summary -SmtpServer "smtp.contoso.com" -To "ops@contoso.com" -From "veeam@contoso.com"
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [object]$Summary,

    [string]$WebhookUrl = "",

    [string]$SmtpServer = "",

    [int]$SmtpPort = 25,

    [System.Management.Automation.PSCredential]$SmtpCredential = $null,

    [switch]$UseSsl,

    [string[]]$To = @(),

    [string]$From = "",

    [string]$Subject = "",

    [object]$ComplianceScore = $null
  )

  # Build status text
  $statusEmoji = if ($Summary.OverallSuccess) { "PASSED" } else { "FAILED" }
  $statusText = "Recovery Validation $statusEmoji"

  if ([string]::IsNullOrWhiteSpace($Subject)) {
    $Subject = "$statusText - $($Summary.PassRate)% pass rate ($($Summary.TotalVMs) VMs)"
  }

  $platformText = ($Summary.Platforms -join ", ")
  $scoreText = ""
  if ($null -ne $ComplianceScore) {
    $scoreText = "Compliance Score: $($ComplianceScore.OverallScore)/100 (Grade $($ComplianceScore.Grade))"
  }

  # === Webhook notification ===
  if ($WebhookUrl -ne "") {
    try {
      $isTeams = $WebhookUrl -match 'office\.com|webhook\.office|microsoft'
      $isSlack = $WebhookUrl -match 'hooks\.slack\.com'

      if ($isTeams) {
        # Teams Adaptive Card via Office 365 connector
        $themeColor = if ($Summary.OverallSuccess) { "00B336" } else { "D13438" }
        $facts = @(
          @{ name = "Platforms"; value = $platformText },
          @{ name = "VMs Tested"; value = "$($Summary.TotalVMs)" },
          @{ name = "Tests"; value = "$($Summary.PassedTests)/$($Summary.TotalTests) passed" },
          @{ name = "Pass Rate"; value = "$($Summary.PassRate)%" },
          @{ name = "Duration"; value = $Summary.Duration }
        )
        if ($scoreText -ne "") {
          $facts += @{ name = "Compliance"; value = $scoreText }
        }
        if ($Summary.AvgRTOMinutes -gt 0) {
          $facts += @{ name = "Avg RTO"; value = "$($Summary.AvgRTOMinutes) min" }
        }

        $teamsPayload = @{
          "@type"      = "MessageCard"
          "@context"   = "http://schema.org/extensions"
          themeColor   = $themeColor
          summary      = $statusText
          sections     = @(
            @{
              activityTitle = $statusText
              activitySubtitle = "Run ID: $($Summary.RunId)"
              facts = $facts
              markdown = $true
            }
          )
        }

        $jsonBody = $teamsPayload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $jsonBody -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop | Out-Null
        Write-Verbose "Teams notification sent successfully"
      }
      elseif ($isSlack) {
        # Slack Block Kit
        $color = if ($Summary.OverallSuccess) { "#00B336" } else { "#D13438" }

        $fieldsText = "Platforms: $platformText`nVMs: $($Summary.TotalVMs) | Tests: $($Summary.PassedTests)/$($Summary.TotalTests)`nPass Rate: $($Summary.PassRate)% | Duration: $($Summary.Duration)"
        if ($scoreText -ne "") {
          $fieldsText += "`n$scoreText"
        }

        $slackPayload = @{
          attachments = @(
            @{
              color  = $color
              blocks = @(
                @{
                  type = "section"
                  text = @{
                    type = "mrkdwn"
                    text = "*$statusText*`nRun ID: ``$($Summary.RunId)``"
                  }
                },
                @{
                  type = "section"
                  text = @{
                    type = "mrkdwn"
                    text = $fieldsText
                  }
                }
              )
            }
          )
        }

        $jsonBody = $slackPayload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $jsonBody -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop | Out-Null
        Write-Verbose "Slack notification sent successfully"
      }
      else {
        # Generic webhook - simple JSON POST
        $genericPayload = @{
          status       = if ($Summary.OverallSuccess) { "PASSED" } else { "FAILED" }
          summary      = $statusText
          runId        = $Summary.RunId
          platforms    = $Summary.Platforms
          totalVMs     = $Summary.TotalVMs
          totalTests   = $Summary.TotalTests
          passedTests  = $Summary.PassedTests
          failedTests  = $Summary.FailedTests
          passRate     = $Summary.PassRate
          avgRTO       = $Summary.AvgRTOMinutes
          duration     = $Summary.Duration
          timestamp    = $Summary.Timestamp.ToString("o")
        }
        if ($null -ne $ComplianceScore) {
          $genericPayload["complianceScore"] = $ComplianceScore.OverallScore
          $genericPayload["complianceGrade"] = $ComplianceScore.Grade
        }

        $jsonBody = $genericPayload | ConvertTo-Json -Depth 10
        Invoke-RestMethod -Uri $WebhookUrl -Method Post -Body $jsonBody -ContentType "application/json" -TimeoutSec 30 -ErrorAction Stop | Out-Null
        Write-Verbose "Webhook notification sent successfully"
      }
    }
    catch {
      Write-Warning "Failed to send webhook notification: $($_.Exception.Message)"
    }
  }

  # === Email notification ===
  if ($SmtpServer -ne "" -and $To.Count -gt 0 -and $From -ne "") {
    try {
      $htmlBody = @"
<html>
<body style="font-family: 'Segoe UI', sans-serif; color: #201F1E; line-height: 1.6;">
<h2 style="color: $(if($Summary.OverallSuccess){'#00B336'}else{'#D13438'});">$(_EscapeHtml $statusText)</h2>
<table style="border-collapse: collapse; font-size: 14px;">
<tr><td style="padding: 6px 16px 6px 0; font-weight: 600;">Platforms</td><td>$(_EscapeHtml $platformText)</td></tr>
<tr><td style="padding: 6px 16px 6px 0; font-weight: 600;">VMs Tested</td><td>$($Summary.TotalVMs)</td></tr>
<tr><td style="padding: 6px 16px 6px 0; font-weight: 600;">Tests</td><td>$($Summary.PassedTests) / $($Summary.TotalTests) passed</td></tr>
<tr><td style="padding: 6px 16px 6px 0; font-weight: 600;">Pass Rate</td><td>$($Summary.PassRate)%</td></tr>
<tr><td style="padding: 6px 16px 6px 0; font-weight: 600;">Duration</td><td>$(_EscapeHtml $Summary.Duration)</td></tr>
$(if($scoreText -ne ""){"<tr><td style='padding: 6px 16px 6px 0; font-weight: 600;'>Compliance</td><td>$(_EscapeHtml $scoreText)</td></tr>"})
$(if($Summary.AvgRTOMinutes -gt 0){"<tr><td style='padding: 6px 16px 6px 0; font-weight: 600;'>Avg RTO</td><td>$($Summary.AvgRTOMinutes) min</td></tr>"})
</table>
<p style="font-size: 12px; color: #605E5C; margin-top: 24px;">Run ID: $(_EscapeHtml $Summary.RunId)<br>
Generated by a community-maintained recovery validation tool.</p>
</body>
</html>
"@

      $mailParams = @{
        From       = $From
        To         = $To
        Subject    = $Subject
        Body       = $htmlBody
        BodyAsHtml = $true
        SmtpServer = $SmtpServer
        Port       = $SmtpPort
        ErrorAction = "Stop"
      }

      if ($UseSsl) {
        $mailParams["UseSsl"] = $true
      }

      if ($null -ne $SmtpCredential) {
        $mailParams["Credential"] = $SmtpCredential
      }

      Send-MailMessage @mailParams
      Write-Verbose "Email notification sent to: $($To -join ', ')"
    }
    catch {
      Write-Warning "Failed to send email notification: $($_.Exception.Message)"
    }
  }
}

#endregion
