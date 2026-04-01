# /new-tool — Scaffold a New Veeam PowerShell Tool

Generate a complete tool skeleton following the repo's production patterns.

## Trigger

User types `/new-tool <ToolName>` where ToolName is the script name (e.g., `Get-VeeamNutanixSizing`, `Test-VeeamBackupCompliance`).

Arguments: `$ARGUMENTS` contains the tool name and optionally a platform folder and short description.

Examples:
- `/new-tool Get-VeeamNutanixSizing` — infers platform from name
- `/new-tool AZURE/Get-VeeamSnapshotAudit "Audit Azure VM snapshots"`

## Instructions

### Step 1: Parse Arguments

Extract from `$ARGUMENTS`:
- **ToolName** — the `Verb-Noun` script name (required)
- **Platform** — folder prefix: `AZURE`, `AWS`, `M365`, `NutanixAHV`, `ONPREM`, `VBR`, `PURE-STORAGE`, `ActiveDirectory`, `MySQL` (infer from name if not given)
- **Description** — one-line purpose (ask if not obvious from name)

### Step 2: Create Directory Structure

```
<Platform>/<ToolName>/
├── <ToolName>.ps1
└── README.md
```

### Step 3: Generate the Script

Create `<ToolName>.ps1` with this exact skeleton:

```powershell
<#
.SYNOPSIS
  <ToolName>.ps1 - <Description>

.DESCRIPTION
  <Expanded description of what the tool does>

  QUICK START
    .\<ToolName>.ps1

.PARAMETER OutputPath
  Directory for output files. Default: script directory.

.EXAMPLE
  .\<ToolName>.ps1
  Run with default settings.

.NOTES
  Version:  0.1.0
  Author:   Community Contributors
  Requires: PowerShell 5.1+
#>

[CmdletBinding()]
param(
    # ===== Authentication =====

    # ===== Scope =====

    # ===== Options =====

    # ===== Output =====
    [string]$OutputPath = $PSScriptRoot
)

# ===== Preferences =====
$ErrorActionPreference = "Stop"
$ProgressPreference    = 'SilentlyContinue'

# ===== Output Setup =====
$stamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$OutFolder = Join-Path $OutputPath "<ToolName>_$stamp"
New-Item -ItemType Directory -Path $OutFolder -Force | Out-Null

$LogFile = Join-Path $OutFolder "<ToolName>-Log-$stamp.csv"

# ===== Logging =====
$script:LogEntries  = New-Object System.Collections.Generic.List[object]
$script:CurrentStep = 0
$script:TotalSteps  = 5

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet("INFO","WARNING","ERROR","SUCCESS")][string]$Level = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entry = [PSCustomObject]@{ Timestamp = $timestamp; Level = $Level; Message = $Message }
    $script:LogEntries.Add($entry)

    $color = switch ($Level) {
        "ERROR"   { "Red" }
        "WARNING" { "Yellow" }
        "SUCCESS" { "Green" }
        default   { "White" }
    }
    Write-Host "[$timestamp] ${Level}: $Message" -ForegroundColor $color
}

function Write-ProgressStep {
    param(
        [Parameter(Mandatory=$true)][string]$Activity,
        [string]$Status = "Processing..."
    )
    $script:CurrentStep++
    $pct = [math]::Round(($script:CurrentStep / $script:TotalSteps) * 100)
    Write-Progress -Activity "<ToolName>" -Status "$Activity - $Status" -PercentComplete $pct
    Write-Log "STEP $script:CurrentStep/$($script:TotalSteps): $Activity"
}

# ===== Helper Functions =====

function _EscapeHtml([string]$text) {
    return $text -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&#39;"
}

# ===== Authentication =====

# ===== Data Collection =====

# ===== Analysis =====

# ===== HTML Report =====

function Build-HtmlReport {
    param([string]$Path)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title><ToolName> Report</title>
<style>
:root {
    --ms-blue: #0078D4;
    --ms-gray-10: #FAF9F8;
    --ms-gray-20: #F3F2F1;
    --ms-gray-130: #323130;
    --veeam-green: #00B336;
    --color-success: #107C10;
    --color-warning: #F7630C;
    --color-danger: #D13438;
    --shadow-depth-4: 0 1.6px 3.6px 0 rgba(0,0,0,.132), 0 0.3px 0.9px 0 rgba(0,0,0,.108);
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', -apple-system, sans-serif; background: var(--ms-gray-10); color: var(--ms-gray-130); }
.exec-header { background: linear-gradient(135deg, #1B1B2F 0%, #1F4068 50%, #162447 100%); color: white; padding: 48px 40px; }
.exec-header h1 { font-size: 28px; font-weight: 600; }
.exec-header .subtitle { opacity: 0.8; margin-top: 8px; }
.section { background: white; margin: 24px 40px; padding: 32px; border-radius: 4px; box-shadow: var(--shadow-depth-4); }
.section h2 { font-size: 20px; margin-bottom: 16px; color: var(--ms-gray-130); }
.kpi-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; margin: 24px 40px; }
.kpi-card { background: white; padding: 24px; border-radius: 4px; box-shadow: var(--shadow-depth-4); }
.kpi-card .label { font-size: 13px; color: #605E5C; text-transform: uppercase; letter-spacing: 0.5px; }
.kpi-card .value { font-size: 32px; font-weight: 600; font-family: 'Consolas', monospace; margin: 8px 0; }
table { width: 100%; border-collapse: collapse; font-size: 14px; }
thead { background: var(--ms-gray-20); }
th, td { padding: 10px 14px; text-align: left; border-bottom: 1px solid var(--ms-gray-20); }
tr:hover { background: var(--ms-gray-10); }
.footer { text-align: center; padding: 24px; font-size: 12px; color: #605E5C; }
</style>
</head>
<body>
<div class="exec-header">
    <h1><ToolName></h1>
    <div class="subtitle">Generated $(Get-Date -Format 'MMMM d, yyyy h:mm tt')</div>
</div>

<div class="kpi-grid">
    <div class="kpi-card">
        <div class="label">Metric</div>
        <div class="value">0</div>
    </div>
</div>

<div class="section">
    <h2>Results</h2>
    <p>Data goes here.</p>
</div>

<div class="footer">
    Community-maintained tool &mdash; not an official Veeam product.
</div>
</body>
</html>
"@

    $html | Out-File -FilePath $Path -Encoding UTF8
    Write-Log "HTML report saved: $Path" -Level SUCCESS
}

# ===== Main Execution =====

Write-Log "<ToolName> starting"

# Step 1: Prerequisites
Write-ProgressStep "Checking prerequisites"

# Step 2: Authentication
Write-ProgressStep "Authenticating"

# Step 3: Data collection
Write-ProgressStep "Collecting data"

# Step 4: Analysis
Write-ProgressStep "Analyzing results"

# Step 5: Report generation
Write-ProgressStep "Generating reports"

$htmlPath = Join-Path $OutFolder "<ToolName>-Report-$stamp.html"
Build-HtmlReport -Path $htmlPath

# ===== Export Log =====
$script:LogEntries | Export-Csv -Path $LogFile -NoTypeInformation -Encoding UTF8

# ===== Console Summary =====
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  <ToolName> Complete" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Output: $OutFolder" -ForegroundColor White
Write-Host ""
```

Replace all `<ToolName>` placeholders with the actual tool name and `<Description>` with the description.

### Step 4: Generate README

Create a standard `README.md`:

```markdown
# <ToolName>

<Description>

## Quick Start

```powershell
.\<ToolName>.ps1
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| OutputPath | string | Script directory | Output folder |

## Output

| File | Format | Description |
|------|--------|-------------|
| Report | HTML | Professional report with findings |
| Log | CSV | Execution log with timestamps |

## Requirements

- PowerShell 5.1+

## Disclaimer

Community-maintained tool — not an official Veeam product.
```

### Step 5: Verify

Run a quick syntax parse on the generated script:
```powershell
pwsh -NoProfile -c "[System.Management.Automation.Language.Parser]::ParseFile('<path>', [ref]\$null, [ref]\$errors); if (\$errors) { \$errors }"
```

Report what was created and suggest next steps.

## Rules

- All generated code must be PS 5.1 compatible — no `??`, ternary, `::new()`, pipeline chains
- Use `New-Object System.Collections.Generic.List[object]` not `[List[object]]::new()`
- Include `_EscapeHtml` in every template
- Include community disclaimer in HTML report footer
- No AI attribution anywhere in generated files
