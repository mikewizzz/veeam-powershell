<#
.SYNOPSIS
  Get-VeeamRecoverabilityPosture.ps1 - Cross-platform recoverability posture assessment
  with compliance evidence generation, trend analysis, and advisory findings.

.DESCRIPTION
  Aggregates recovery validation results from any source (Veeam SureBackup, VRO,
  custom scripts, manual CSV imports) and produces:
    1) A recoverability posture score (0-100) with per-platform breakdown
    2) Compliance evidence packages mapped to NIS2, SOC2, ISO 27001, and DORA
    3) Advisory findings identifying coverage gaps, SLA violations, and stale tests
    4) Delta reports showing posture trends over time
    5) Auditor-ready HTML reports with attestation statements

  This tool does NOT execute recovery tests. It consumes results from tools that do.
  The moat is the compliance evidence layer — no recovery vendor builds this.

INGEST FROM FILES (JSON results from prior script runs)
  .\Get-VeeamRecoverabilityPosture.ps1 -ResultFiles ".\ahv-results.json",".\azure-results.json"

INGEST FROM DIRECTORY (scan for all result files)
  .\Get-VeeamRecoverabilityPosture.ps1 -ResultDirectory ".\recovery-results\"

INGEST FROM CSV (manual import from spreadsheet)
  .\Get-VeeamRecoverabilityPosture.ps1 -CsvImport ".\manual-results.csv"

COMPLIANCE EVIDENCE PACKAGE
  .\Get-VeeamRecoverabilityPosture.ps1 -ResultDirectory ".\results\" -Frameworks "NIS2","SOC2"

TREND ANALYSIS (compare against prior posture)
  .\Get-VeeamRecoverabilityPosture.ps1 -ResultDirectory ".\results\" -PostureStore ".\posture-history\"

.NOTES
  Community-maintained tool. Not an official Veeam product.
  Requires PowerShell 5.1+.
#>

[CmdletBinding()]
param(
  # ===== Input Sources =====
  [string[]]$ResultFiles,                    # Paths to JSON result files from recovery scripts
  [string]$ResultDirectory,                  # Directory to scan for *RecoveryValidation*.json files
  [string]$CsvImport,                       # Path to CSV with manual recovery test results

  # ===== Organization Context =====
  [string]$OrganizationName = "",            # Organization name for report header
  [string]$OrganizationId = "",              # Unique org identifier for multi-tenant tracking

  # ===== Compliance =====
  [string[]]$Frameworks = @("NIS2", "SOC2", "ISO27001", "DORA"),  # Frameworks to map
  [int]$RTOTargetMinutes = 0,                # Default RTO target (overrides per-result if set)
  [int]$StaleDays = 30,                      # Results older than this are flagged as stale

  # ===== Posture Persistence =====
  [string]$PostureStore,                     # Directory for posture history (enables trend analysis)

  # ===== Advisory =====
  [string[]]$SLAPlatforms,                   # Platforms that MUST have recent test results
                                             # e.g., "NutanixAHV","Azure" — missing = finding

  # ===== Notification =====
  [string]$WebhookUrl,                       # Teams/Slack webhook for posture notifications
  [string]$SmtpServer,                       # SMTP server for email notifications
  [string[]]$NotifyTo,                       # Email recipients
  [string]$NotifyFrom = "recoverability@assessment.local",

  # ===== Output =====
  [string]$OutFolder = ".\RecoverabilityPosture",
  [switch]$ExportJson,
  [switch]$ZipBundle = $true
)

# =============================
# Guardrails
# =============================
$ErrorActionPreference = "Stop"
$ProgressPreference = 'SilentlyContinue'

# =============================
# Output folder
# =============================
$stamp = Get-Date -Format "yyyy-MM-dd_HHmm"
$runFolder = Join-Path $OutFolder "Run-$stamp"
New-Item -ItemType Directory -Path $runFolder -Force | Out-Null

# =============================
# Load shared libraries
# =============================
$sharedLib = Join-Path $PSScriptRoot "lib"
. (Join-Path $sharedLib "RecoveryValidationSchema.ps1")
. (Join-Path $sharedLib "ComplianceReport.ps1")

# =============================
# Logging
# =============================
$logPath = Join-Path $runFolder "Posture-Log-$stamp.txt"

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $ts = Get-Date -Format "HH:mm:ss"
  $line = "[$ts] [$Level] $Message"
  $color = switch ($Level) {
    "ERROR"   { "Red" }
    "WARNING" { "Yellow" }
    "SUCCESS" { "Green" }
    default   { "Gray" }
  }
  Write-Host $line -ForegroundColor $color
  $line | Out-File -Append -FilePath $logPath -Encoding UTF8
}

# =============================
# Step 1: Ingest Results
# =============================
Write-Log "Starting recoverability posture assessment"

$allResults = New-Object System.Collections.Generic.List[object]
$ingestionSources = New-Object System.Collections.Generic.List[object]

# --- From individual JSON files ---
if ($ResultFiles) {
  foreach ($file in $ResultFiles) {
    if (-not (Test-Path $file)) {
      Write-Log "Result file not found: $file" -Level "WARNING"
      continue
    }
    try {
      $content = Get-Content -Path $file -Raw -Encoding UTF8
      $data = $content | ConvertFrom-Json

      # Detect format: our normalized schema vs raw platform output
      if ($data.results) {
        # Our export format (from Export-RecoveryValidationResults)
        foreach ($r in $data.results) {
          $allResults.Add((New-RecoveryValidationResult `
            -Platform $r.platform `
            -VMName $r.vmName `
            -BackupJobName $r.backupJobName `
            -TestName $r.testName `
            -Passed ([bool]$r.passed) `
            -Details $r.details `
            -DurationSeconds ([double]$r.durationSeconds) `
            -RTOTargetMinutes $(if ($RTOTargetMinutes -gt 0) { $RTOTargetMinutes } elseif ($r.rtoTargetMinutes) { [int]$r.rtoTargetMinutes } else { 0 }) `
            -RTOActualMinutes $(if ($r.rtoActualMinutes) { [double]$r.rtoActualMinutes } else { 0 }) `
          ))
        }
        $ingestionSources.Add([PSCustomObject]@{ Source = $file; Format = "Normalized"; Count = @($data.results).Count })
      } elseif ($data.success -ne $null -and $data.vmName) {
        # AWS Restore-VRO-AWS-EC2 format
        $converted = ConvertFrom-AWSResult -AWSResultBundle $data
        foreach ($r in $converted) { $allResults.Add($r) }
        $ingestionSources.Add([PSCustomObject]@{ Source = $file; Format = "AWS"; Count = @($converted).Count })
      } else {
        Write-Log "Unknown JSON format in $file — skipping" -Level "WARNING"
      }
    } catch {
      Write-Log "Failed to parse $file : $($_.Exception.Message)" -Level "ERROR"
    }
  }
}

# --- From directory scan ---
if ($ResultDirectory) {
  if (-not (Test-Path $ResultDirectory)) {
    Write-Log "Result directory not found: $ResultDirectory" -Level "WARNING"
  } else {
    $jsonFiles = Get-ChildItem -Path $ResultDirectory -Filter "*.json" -Recurse -File
    foreach ($jf in $jsonFiles) {
      try {
        $content = Get-Content -Path $jf.FullName -Raw -Encoding UTF8
        $data = $content | ConvertFrom-Json
        if ($data.results) {
          foreach ($r in $data.results) {
            $allResults.Add((New-RecoveryValidationResult `
              -Platform $r.platform `
              -VMName $r.vmName `
              -BackupJobName $r.backupJobName `
              -TestName $r.testName `
              -Passed ([bool]$r.passed) `
              -Details $r.details `
              -DurationSeconds ([double]$r.durationSeconds) `
              -RTOTargetMinutes $(if ($RTOTargetMinutes -gt 0) { $RTOTargetMinutes } elseif ($r.rtoTargetMinutes) { [int]$r.rtoTargetMinutes } else { 0 }) `
              -RTOActualMinutes $(if ($r.rtoActualMinutes) { [double]$r.rtoActualMinutes } else { 0 }) `
            ))
          }
          $ingestionSources.Add([PSCustomObject]@{ Source = $jf.Name; Format = "Normalized"; Count = @($data.results).Count })
        }
      } catch {
        Write-Log "Failed to parse $($jf.Name): $($_.Exception.Message)" -Level "WARNING"
      }
    }
  }
}

# --- From CSV import ---
if ($CsvImport) {
  if (-not (Test-Path $CsvImport)) {
    throw "CSV import file not found: $CsvImport"
  }
  $csvData = Import-Csv $CsvImport
  foreach ($row in $csvData) {
    $platform = if ($row.Platform) { $row.Platform } else { "VMware" }
    $passed = if ($row.Passed -eq "True" -or $row.Passed -eq "1" -or $row.Passed -eq "Yes") { $true } else { $false }
    $rtoTarget = if ($RTOTargetMinutes -gt 0) { $RTOTargetMinutes } elseif ($row.RTOTargetMinutes) { [int]$row.RTOTargetMinutes } else { 0 }
    $rtoActual = if ($row.RTOActualMinutes) { [double]$row.RTOActualMinutes } else { 0 }

    $allResults.Add((New-RecoveryValidationResult `
      -Platform $platform `
      -VMName $(if ($row.VMName) { $row.VMName } else { "" }) `
      -BackupJobName $(if ($row.BackupJobName) { $row.BackupJobName } else { "" }) `
      -TestName $(if ($row.TestName) { $row.TestName } else { "Manual Test" }) `
      -Passed $passed `
      -Details $(if ($row.Details) { $row.Details } else { "" }) `
      -DurationSeconds $(if ($row.DurationSeconds) { [double]$row.DurationSeconds } else { 0 }) `
      -RTOTargetMinutes $rtoTarget `
      -RTOActualMinutes $rtoActual `
    ))
  }
  $ingestionSources.Add([PSCustomObject]@{ Source = $CsvImport; Format = "CSV"; Count = @($csvData).Count })
}

# Validate we have data
if ($allResults.Count -eq 0) {
  throw "No recovery validation results ingested. Provide -ResultFiles, -ResultDirectory, or -CsvImport."
}

Write-Log "Ingested $($allResults.Count) results from $($ingestionSources.Count) source(s)"
foreach ($src in $ingestionSources) {
  Write-Log "  $($src.Source): $($src.Count) results ($($src.Format) format)"
}

# =============================
# Step 2: Build Summary
# =============================
$startTime = Get-Date
$summary = New-RecoveryValidationSummary -Results $allResults.ToArray() -StartTime $startTime

Write-Log "Summary: $($summary.TotalVMs) VMs, $($summary.TotalTests) tests, $($summary.PassRate)% pass rate"

# =============================
# Step 3: Compliance Scoring
# =============================
Write-Log "Calculating compliance readiness scores..."
$complianceScore = Get-RecoveryComplianceScore -Summary $summary

Write-Log "Compliance score: $($complianceScore.OverallScore)/100 (Grade: $($complianceScore.Grade))"

# =============================
# Step 4: Advisory Findings
# =============================
Write-Log "Generating advisory findings..."
$findings = New-Object System.Collections.Generic.List[object]

# --- Coverage gaps ---
$platformsCovered = @($allResults | Select-Object -ExpandProperty Platform -Unique)
$expectedPlatforms = if ($SLAPlatforms) { $SLAPlatforms } else { @() }
foreach ($expected in $expectedPlatforms) {
  if ($platformsCovered -notcontains $expected) {
    $findings.Add([PSCustomObject]@{
      Severity    = "High"
      Category    = "Coverage Gap"
      Title       = "$expected Recovery Validation Missing"
      Detail      = "Platform '$expected' is listed in SLA requirements but has no recovery validation results. This represents a compliance gap — auditors will note the absence of recovery testing evidence for this platform."
      Recommendation = "Execute recovery validation tests for $expected workloads and include results in the next posture assessment."
      Framework   = "SOC2 A1.3, NIS2 Art 21(2)(c)"
    })
  }
}

# --- Failed tests ---
$failedTests = @($allResults | Where-Object { $_.Passed -eq $false })
if ($failedTests.Count -gt 0) {
  $failedVMs = @($failedTests | Select-Object -ExpandProperty VMName -Unique)
  $failedPlatforms = @($failedTests | Select-Object -ExpandProperty Platform -Unique)
  $findings.Add([PSCustomObject]@{
    Severity    = "High"
    Category    = "Recovery Failure"
    Title       = "$($failedTests.Count) Recovery Tests Failed Across $($failedVMs.Count) VM(s)"
    Detail      = "Failed tests detected on platforms: $($failedPlatforms -join ', '). Affected VMs: $($failedVMs -join ', '). Failed recovery tests indicate that backup data may not be recoverable when needed."
    Recommendation = "Investigate root causes for each failed test. Common issues: network isolation misconfiguration, outdated restore points, VM boot dependencies not met."
    Framework   = "ISO 27001 A.8.13, SOC2 A1.2"
  })
}

# --- RTO violations ---
$rtoResults = @($allResults | Where-Object { $null -ne $_.RTOMet })
$rtoViolations = @($rtoResults | Where-Object { $_.RTOMet -eq $false })
if ($rtoViolations.Count -gt 0) {
  $violatingVMs = @($rtoViolations | Select-Object -ExpandProperty VMName -Unique)
  $avgActual = [math]::Round(($rtoViolations | Measure-Object -Property RTOActualMinutes -Average).Average, 1)
  $avgTarget = [math]::Round(($rtoViolations | Measure-Object -Property RTOTargetMinutes -Average).Average, 1)
  $findings.Add([PSCustomObject]@{
    Severity    = "High"
    Category    = "SLA Violation"
    Title       = "RTO Target Exceeded for $($violatingVMs.Count) VM(s)"
    Detail      = "Average actual RTO ($avgActual min) exceeds average target ($avgTarget min). Affected VMs: $($violatingVMs -join ', '). SLA commitments for recovery time are not being met."
    Recommendation = "Review backup infrastructure capacity, network bandwidth to recovery targets, and VM boot dependencies. Consider pre-staging recovery resources or reducing restore point granularity."
    Framework   = "ISO 27001 A.5.30, DORA Art 11"
  })
}

# --- Stale results ---
$cutoffDate = (Get-Date).AddDays(-$StaleDays)
$staleResults = @($allResults | Where-Object { $_.Timestamp -lt $cutoffDate })
if ($staleResults.Count -gt 0) {
  $stalePlatforms = @($staleResults | Select-Object -ExpandProperty Platform -Unique)
  $oldestDate = ($staleResults | Sort-Object Timestamp | Select-Object -First 1).Timestamp
  $daysSinceOldest = [int]((Get-Date) - $oldestDate).TotalDays
  $findings.Add([PSCustomObject]@{
    Severity    = "Medium"
    Category    = "Stale Evidence"
    Title       = "Recovery Test Results Older Than $StaleDays Days"
    Detail      = "$($staleResults.Count) results from platforms ($($stalePlatforms -join ', ')) are older than $StaleDays days. Oldest result is $daysSinceOldest days old. Auditors expect recent evidence of recovery testing — stale results may not satisfy compliance requirements."
    Recommendation = "Schedule recurring recovery validation tests (weekly or monthly) to maintain current evidence. Use the scheduling helpers in this tool to automate execution."
    Framework   = "SOC2 A1.3, NIS2 Art 21(2)(c)"
  })
}

# --- No RTO tracking ---
$noRtoResults = @($allResults | Where-Object { $null -eq $_.RTOMet -and $_.RTOTargetMinutes -eq 0 })
if ($noRtoResults.Count -gt 0 -and $noRtoResults.Count -eq $allResults.Count) {
  $findings.Add([PSCustomObject]@{
    Severity    = "Medium"
    Category    = "Measurement Gap"
    Title       = "No RTO Targets Defined"
    Detail      = "None of the $($allResults.Count) recovery tests have RTO targets defined. Without recovery time objectives, there is no way to measure whether recovery meets business requirements."
    Recommendation = "Define RTO targets per workload/platform using the -RTOTargetMinutes parameter or per-result RTOTargetMinutes in CSV imports. Typical targets: critical systems 15-60 min, standard systems 2-4 hours."
    Framework   = "ISO 27001 A.5.30, DORA Art 11"
  })
}

# --- Single platform only ---
if ($platformsCovered.Count -eq 1 -and -not $SLAPlatforms) {
  $findings.Add([PSCustomObject]@{
    Severity    = "Low"
    Category    = "Coverage"
    Title       = "Single Platform Coverage"
    Detail      = "Recovery validation results cover only $($platformsCovered[0]). If your organization has workloads on multiple platforms, consider expanding validation to cover all backup-protected infrastructure."
    Recommendation = "Include results from all platforms where backup data exists. Use -SLAPlatforms to enforce coverage requirements."
    Framework   = "NIS2 Art 21(2)(c)"
  })
}

# --- Positive findings ---
if ($summary.PassRate -ge 95) {
  $findings.Add([PSCustomObject]@{
    Severity    = "Info"
    Category    = "Strong Posture"
    Title       = "Excellent Recovery Pass Rate ($($summary.PassRate)%)"
    Detail      = "$($summary.PassedTests) of $($summary.TotalTests) recovery tests passed across $($platformsCovered.Count) platform(s). This demonstrates strong backup recoverability posture."
    Recommendation = "Maintain current testing cadence. Consider expanding test scope to include application-level validation."
    Framework   = "SOC2 A1.2, ISO 27001 A.8.13"
  })
}
if ($rtoResults.Count -gt 0 -and $rtoViolations.Count -eq 0) {
  $avgRTO = [math]::Round(($rtoResults | Measure-Object -Property RTOActualMinutes -Average).Average, 1)
  $findings.Add([PSCustomObject]@{
    Severity    = "Info"
    Category    = "Strong Posture"
    Title       = "All RTO Targets Met (Avg: $avgRTO min)"
    Detail      = "All $($rtoResults.Count) recovery tests with RTO targets met their objectives. Average recovery time: $avgRTO minutes."
    Recommendation = "Document RTO performance as part of business continuity evidence."
    Framework   = "DORA Art 11, ISO 27001 A.5.30"
  })
}

Write-Log "Generated $($findings.Count) advisory findings"

# =============================
# Step 5: Posture Persistence + Delta
# =============================
$priorPosture = $null
$postureDelta = $null

if ($PostureStore) {
  if (-not (Test-Path $PostureStore)) {
    New-Item -ItemType Directory -Path $PostureStore -Force | Out-Null
  }

  # Load prior posture
  $orgSlug = if ($OrganizationId) { $OrganizationId -replace '[^a-zA-Z0-9\-]', '' } else { "default" }
  $priorFiles = Get-ChildItem -Path $PostureStore -Filter "${orgSlug}_*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
  $cutoff = (Get-Date).AddSeconds(-60)
  $priorFiles = @($priorFiles | Where-Object { $_.LastWriteTime -lt $cutoff })

  if ($priorFiles.Count -gt 0) {
    try {
      $priorContent = Get-Content -Path $priorFiles[0].FullName -Raw -Encoding UTF8
      $priorPosture = $priorContent | ConvertFrom-Json

      # Calculate delta
      $postureDelta = [ordered]@{
        PriorDate  = $priorPosture.Timestamp
        DaysBetween = [int]((Get-Date) - [datetime]$priorPosture.Timestamp).TotalDays
        Score      = [ordered]@{
          Prior   = $priorPosture.ComplianceScore.OverallScore
          Current = $complianceScore.OverallScore
          Delta   = $complianceScore.OverallScore - $priorPosture.ComplianceScore.OverallScore
        }
        PassRate   = [ordered]@{
          Prior   = $priorPosture.Summary.PassRate
          Current = $summary.PassRate
          Delta   = [math]::Round($summary.PassRate - $priorPosture.Summary.PassRate, 1)
        }
        TotalVMs   = [ordered]@{
          Prior   = $priorPosture.Summary.TotalVMs
          Current = $summary.TotalVMs
          Delta   = $summary.TotalVMs - $priorPosture.Summary.TotalVMs
        }
        Findings   = [ordered]@{
          Prior   = if ($priorPosture.Findings) { @($priorPosture.Findings).Count } else { 0 }
          Current = $findings.Count
          Delta   = $findings.Count - $(if ($priorPosture.Findings) { @($priorPosture.Findings).Count } else { 0 })
        }
      }

      $scoreDir = if ($postureDelta.Score.Delta -gt 0) { "+" } else { "" }
      Write-Log "Delta vs prior ($($postureDelta.DaysBetween) days ago): score ${scoreDir}$($postureDelta.Score.Delta), pass rate ${scoreDir}$($postureDelta.PassRate.Delta)%"
    } catch {
      Write-Log "Failed to load prior posture: $($_.Exception.Message)" -Level "WARNING"
    }
  } else {
    Write-Log "No prior posture found. This run establishes the baseline."
  }

  # Save current posture
  $snapshot = [ordered]@{
    SchemaVersion    = 1
    Timestamp        = (Get-Date).ToString("o")
    OrganizationName = $OrganizationName
    OrganizationId   = $OrganizationId
    Summary          = [ordered]@{
      TotalVMs      = $summary.TotalVMs
      TotalTests    = $summary.TotalTests
      PassedTests   = $summary.PassedTests
      FailedTests   = $summary.FailedTests
      PassRate      = $summary.PassRate
      AvgRTOMinutes = $summary.AvgRTOMinutes
      RTOComplianceRate = $summary.RTOComplianceRate
      Platforms     = $summary.Platforms
      Duration      = $summary.Duration
    }
    ComplianceScore  = [ordered]@{
      OverallScore = $complianceScore.OverallScore
      Grade        = $complianceScore.Grade
      CoverageScore = $complianceScore.CoverageScore
      PassRateScore = $complianceScore.PassRateScore
      RTOScore      = $complianceScore.RTOScore
      RecencyScore  = $complianceScore.RecencyScore
      AutomationScore = $complianceScore.AutomationScore
    }
    Findings         = @($findings)
    Sources          = @($ingestionSources)
    Frameworks       = $Frameworks
  }

  $snapshotPath = Join-Path $PostureStore "${orgSlug}_${stamp}.json"
  ($snapshot | ConvertTo-Json -Depth 8) | Set-Content -Path $snapshotPath -Encoding UTF8
  Write-Log "Posture snapshot saved: $snapshotPath"
}

# =============================
# Step 6: Export Results
# =============================
Write-Log "Exporting results..."

# Results CSV + JSON
$exportPaths = Export-RecoveryValidationResults -Results $allResults.ToArray() -OutputPath $runFolder -FilePrefix "PostureResults"

# Findings CSV
$findingsPath = Join-Path $runFolder "Posture-Findings-$stamp.csv"
$findings | Export-Csv -Path $findingsPath -NoTypeInformation -Encoding UTF8

# Delta CSV
if ($postureDelta) {
  $deltaPath = Join-Path $runFolder "Posture-Delta-$stamp.csv"
  $deltaRows = @(
    [PSCustomObject]@{ Metric = "ComplianceScore"; Prior = $postureDelta.Score.Prior; Current = $postureDelta.Score.Current; Delta = $postureDelta.Score.Delta },
    [PSCustomObject]@{ Metric = "PassRate"; Prior = $postureDelta.PassRate.Prior; Current = $postureDelta.PassRate.Current; Delta = $postureDelta.PassRate.Delta },
    [PSCustomObject]@{ Metric = "TotalVMs"; Prior = $postureDelta.TotalVMs.Prior; Current = $postureDelta.TotalVMs.Current; Delta = $postureDelta.TotalVMs.Delta },
    [PSCustomObject]@{ Metric = "Findings"; Prior = $postureDelta.Findings.Prior; Current = $postureDelta.Findings.Current; Delta = $postureDelta.Findings.Delta }
  )
  $deltaRows | Export-Csv -Path $deltaPath -NoTypeInformation -Encoding UTF8
}

# JSON bundle
if ($ExportJson) {
  $bundle = [ordered]@{
    Timestamp         = (Get-Date).ToString("o")
    Organization      = $OrganizationName
    Summary           = $summary
    ComplianceScore   = $complianceScore
    Findings          = @($findings)
    Sources           = @($ingestionSources)
    Frameworks        = $Frameworks
    PlatformsCovered  = @($platformsCovered)
  }
  if ($postureDelta) { $bundle["Delta"] = $postureDelta }
  $jsonPath = Join-Path $runFolder "Posture-Bundle-$stamp.json"
  ($bundle | ConvertTo-Json -Depth 8) | Set-Content -Path $jsonPath -Encoding UTF8
}

# =============================
# Step 7: HTML Compliance Report
# =============================
Write-Log "Generating compliance evidence report..."

$reportParams = @{
  Summary        = $summary
  OutputPath     = $runFolder
  ReportFileName = "Posture-Report-$stamp.html"
}
if ($OrganizationName) { $reportParams["OrganizationName"] = $OrganizationName }

$reportResult = New-UnifiedComplianceReport @reportParams
$htmlPath = $reportResult.ReportPath

# =============================
# Step 8: Advisory Findings Addendum (append to HTML)
# =============================
if ($findings.Count -gt 0) {
  $existingHtml = Get-Content -Path $htmlPath -Raw -Encoding UTF8

  $advisoryHtml = @"
  <div style="max-width: 1440px; margin: 0 auto; padding: 0 32px;">
  <details style="background: #FFFFFF; border-radius: 8px; box-shadow: 0 1.6px 3.6px 0 rgba(0,0,0,.132); margin-bottom: 24px; overflow: hidden;" open>
    <summary style="padding: 20px 24px; font-size: 18px; font-weight: 600; cursor: pointer; border-bottom: 1px solid #EDEBE9;">Advisory Findings</summary>
    <div style="padding: 24px;">
"@

  $severityOrder = @("High", "Medium", "Low", "Info")
  foreach ($sev in $severityOrder) {
    $sevFindings = @($findings | Where-Object { $_.Severity -eq $sev })
    if ($sevFindings.Count -eq 0) { continue }

    $sevColor = switch ($sev) { "High" { "#D13438" } "Medium" { "#F7630C" } "Low" { "#0078D4" } default { "#107C10" } }
    $advisoryHtml += "      <div style='margin-bottom: 16px; font-size: 14px; font-weight: 600; color: $sevColor;'>$sev Severity ($($sevFindings.Count))</div>`n"

    foreach ($f in $sevFindings) {
      $escapedTitle = $f.Title -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
      $escapedDetail = $f.Detail -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
      $escapedRec = $f.Recommendation -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
      $escapedFw = $f.Framework -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'

      $advisoryHtml += @"
      <div style="border-left: 4px solid $sevColor; padding: 12px 16px; margin-bottom: 12px; background: #FAF9F8; border-radius: 0 4px 4px 0;">
        <div style="font-weight: 600; font-size: 14px; margin-bottom: 4px;">$escapedTitle</div>
        <div style="font-size: 13px; color: #605E5C; margin-bottom: 8px;">$escapedDetail</div>
        <div style="font-size: 12px; color: #323130;"><strong>Recommendation:</strong> $escapedRec</div>
        <div style="font-size: 11px; color: #605E5C; margin-top: 4px;">Frameworks: $escapedFw</div>
      </div>
"@
    }
  }

  # Delta section in advisory
  if ($postureDelta) {
    $scoreDir = if ($postureDelta.Score.Delta -gt 0) { "+" } else { "" }
    $scoreColor = if ($postureDelta.Score.Delta -ge 0) { "#107C10" } else { "#D13438" }
    $prDir = if ($postureDelta.PassRate.Delta -gt 0) { "+" } else { "" }
    $prColor = if ($postureDelta.PassRate.Delta -ge 0) { "#107C10" } else { "#D13438" }

    $advisoryHtml += @"
      <div style="margin-top: 24px; padding: 20px; background: linear-gradient(135deg, #1B1B2F 0%, #1F4068 100%); border-radius: 8px; color: #FFFFFF;">
        <div style="font-size: 16px; font-weight: 600; margin-bottom: 12px;">Trend: vs. $($postureDelta.DaysBetween) days ago</div>
        <div style="display: flex; gap: 32px; flex-wrap: wrap;">
          <div><span style="font-size: 24px; font-weight: 700; color: $scoreColor;">${scoreDir}$($postureDelta.Score.Delta)</span><div style="font-size: 12px; color: rgba(255,255,255,0.7);">Compliance Score</div></div>
          <div><span style="font-size: 24px; font-weight: 700; color: $prColor;">${prDir}$($postureDelta.PassRate.Delta)%</span><div style="font-size: 12px; color: rgba(255,255,255,0.7);">Pass Rate</div></div>
          <div><span style="font-size: 24px; font-weight: 700;">$($postureDelta.TotalVMs.Current)</span><div style="font-size: 12px; color: rgba(255,255,255,0.7);">VMs Tested (was $($postureDelta.TotalVMs.Prior))</div></div>
        </div>
      </div>
"@
  }

  $advisoryHtml += @"
    </div>
  </details>
  </div>
"@

  # Insert before closing </body>
  $existingHtml = $existingHtml -replace '</body>', "$advisoryHtml`n</body>"
  $existingHtml | Set-Content -Path $htmlPath -Encoding UTF8
}

# =============================
# Step 9: Notifications
# =============================
if ($WebhookUrl -or ($SmtpServer -and $NotifyTo)) {
  Write-Log "Sending posture notifications..."
  $notifyParams = @{ Summary = $summary }
  if ($WebhookUrl) { $notifyParams["WebhookUrl"] = $WebhookUrl }
  if ($SmtpServer) { $notifyParams["SmtpServer"] = $SmtpServer }
  if ($NotifyTo) { $notifyParams["To"] = $NotifyTo }
  if ($NotifyFrom) { $notifyParams["From"] = $NotifyFrom }
  try {
    Send-RecoveryNotification @notifyParams
    Write-Log "Notifications sent" -Level "SUCCESS"
  } catch {
    Write-Log "Notification failed: $($_.Exception.Message)" -Level "WARNING"
  }
}

# =============================
# Step 10: ZIP Bundle
# =============================
if ($ZipBundle) {
  $zipPath = Join-Path $OutFolder "RecoverabilityPosture-$stamp.zip"
  if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }
  Compress-Archive -Path (Join-Path $runFolder "*") -DestinationPath $zipPath -Force
}

# =============================
# Console Summary
# =============================
Write-Host ""
Write-Host "Recoverability Posture Assessment Complete" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Platforms      : $($platformsCovered -join ', ')"
Write-Host "VMs Tested     : $($summary.TotalVMs)"
Write-Host "Total Tests    : $($summary.TotalTests)"
Write-Host "Pass Rate      : $($summary.PassRate)%"

$gradeColor = switch ($complianceScore.Grade) { "A" { "Green" } "B" { "Green" } "C" { "Yellow" } "D" { "Red" } default { "Red" } }
Write-Host "Compliance     : $($complianceScore.OverallScore)/100 (Grade: $($complianceScore.Grade))" -ForegroundColor $gradeColor

if ($summary.AvgRTOMinutes -gt 0) {
  Write-Host "Avg RTO        : $($summary.AvgRTOMinutes) min"
  Write-Host "RTO Compliance : $($summary.RTOComplianceRate)%"
}

$highCount = @($findings | Where-Object { $_.Severity -eq "High" }).Count
$medCount = @($findings | Where-Object { $_.Severity -eq "Medium" }).Count
if ($highCount -gt 0) {
  Write-Host "Findings       : $highCount high, $medCount medium" -ForegroundColor Red
} elseif ($medCount -gt 0) {
  Write-Host "Findings       : $medCount medium" -ForegroundColor Yellow
} else {
  Write-Host "Findings       : No issues detected" -ForegroundColor Green
}

if ($postureDelta) {
  $scoreDir = if ($postureDelta.Score.Delta -gt 0) { "+" } else { "" }
  $trendColor = if ($postureDelta.Score.Delta -ge 0) { "Green" } else { "Red" }
  Write-Host "Trend          : ${scoreDir}$($postureDelta.Score.Delta) pts vs. $($postureDelta.DaysBetween) days ago" -ForegroundColor $trendColor
}

Write-Host ""
Write-Host "HTML Report    : $htmlPath"
Write-Host "Findings CSV   : $findingsPath"
Write-Host "Results CSV    : $($exportPaths.CsvPath)"
if ($ZipBundle) { Write-Host "ZIP Bundle     : $zipPath" }
if ($snapshotPath) { Write-Host "Posture Store  : $snapshotPath" }
Write-Host ""
