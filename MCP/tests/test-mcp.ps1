# Veeam VBR MCP - Test & Validation Script
# Tests MCP functionality and validates outputs

<#
.SYNOPSIS
    Test and validate Veeam MCP script functionality
    
.DESCRIPTION
    This script runs comprehensive tests to validate the MCP script works correctly
    and produces expected outputs. Use this before deploying to production.
#>

[CmdletBinding()]
param(
    [switch]$SkipVBRConnection,
    [switch]$Verbose
)

$ErrorActionPreference = "Continue"
$testResults = @{
    Passed = 0
    Failed = 0
    Skipped = 0
    Tests = @()
}

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )
    
    $result = if ($Passed) { "✓ PASS" } else { "✗ FAIL" }
    $color = if ($Passed) { "Green" } else { "Red" }
    
    Write-Host "  $result - $TestName" -ForegroundColor $color
    if ($Message) {
        Write-Host "         $Message" -ForegroundColor Gray
    }
    
    $testResults.Tests += [PSCustomObject]@{
        Name = $TestName
        Passed = $Passed
        Message = $Message
    }
    
    if ($Passed) { $testResults.Passed++ } else { $testResults.Failed++ }
}

Write-Host "`n" + ("="*80) -ForegroundColor Cyan
Write-Host "  VEEAM VBR MCP - TEST & VALIDATION SUITE" -ForegroundColor Cyan
Write-Host ("="*80) + "`n" -ForegroundColor Cyan

#region Test 1: Script File Exists
Write-Host "[Test 1] Checking script file existence..." -ForegroundColor Yellow

$scriptPath = Join-Path $PSScriptRoot "..\veeam-mcp.ps1"
$scriptExists = Test-Path $scriptPath

Write-TestResult -TestName "veeam-mcp.ps1 exists" `
                 -Passed $scriptExists `
                 -Message "Path: $scriptPath"

#endregion

#region Test 2: PowerShell Version
Write-Host "`n[Test 2] Checking PowerShell version..." -ForegroundColor Yellow

$psVersion = $PSVersionTable.PSVersion
$psVersionOK = $psVersion.Major -ge 5

Write-TestResult -TestName "PowerShell version >= 5.1" `
                 -Passed $psVersionOK `
                 -Message "Current version: $($psVersion.ToString())"

#endregion

#region Test 3: Veeam PSSnapin Availability
Write-Host "`n[Test 3] Checking Veeam PowerShell Snapin..." -ForegroundColor Yellow

if (-not $SkipVBRConnection) {
    $veeamSnapin = Get-PSSnapin -Registered | Where-Object { $_.Name -eq "VeeamPSSnapin" }
    $snapinAvailable = $veeamSnapin -ne $null
    
    Write-TestResult -TestName "VeeamPSSnapin is registered" `
                     -Passed $snapinAvailable `
                     -Message $(if ($snapinAvailable) { "Version: $($veeamSnapin.Version)" } else { "Install Veeam B&R" })
    
    if ($snapinAvailable) {
        try {
            if (-not (Get-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue)) {
                Add-PSSnapin VeeamPSSnapin -ErrorAction Stop
            }
            
            Write-TestResult -TestName "VeeamPSSnapin can be loaded" `
                             -Passed $true `
                             -Message "Successfully loaded"
        }
        catch {
            Write-TestResult -TestName "VeeamPSSnapin can be loaded" `
                             -Passed $false `
                             -Message "Error: $_"
        }
    }
}
else {
    Write-Host "  ⊘ SKIP - VBR connection tests (SkipVBRConnection flag)" -ForegroundColor Gray
    $testResults.Skipped++
}

#endregion

#region Test 4: Script Syntax Validation
Write-Host "`n[Test 4] Validating script syntax..." -ForegroundColor Yellow

try {
    $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content $scriptPath -Raw), [ref]$null)
    Write-TestResult -TestName "Script syntax is valid" `
                     -Passed $true `
                     -Message "No syntax errors found"
}
catch {
    Write-TestResult -TestName "Script syntax is valid" `
                     -Passed $false `
                     -Message "Syntax error: $_"
}

#endregion

#region Test 5: Script Parameters
Write-Host "`n[Test 5] Checking script parameters..." -ForegroundColor Yellow

try {
    $scriptContent = Get-Content $scriptPath -Raw
    
    $hasVBRServerParam = $scriptContent -match '\$VBRServer'
    $hasActionParam = $scriptContent -match '\$Action'
    $hasExportPathParam = $scriptContent -match '\$ExportPath'
    
    Write-TestResult -TestName "Required parameters defined" `
                     -Passed ($hasVBRServerParam -and $hasActionParam -and $hasExportPathParam) `
                     -Message "VBRServer: $hasVBRServerParam, Action: $hasActionParam, ExportPath: $hasExportPathParam"
}
catch {
    Write-TestResult -TestName "Required parameters defined" `
                     -Passed $false `
                     -Message "Error: $_"
}

#endregion

#region Test 6: Function Definitions
Write-Host "`n[Test 6] Checking function definitions..." -ForegroundColor Yellow

$requiredFunctions = @(
    "Get-VBRServerInfoMCP",
    "Get-VBRJobsMCP",
    "Get-VBRRepositoriesMCP",
    "Get-VBRRestorePointsMCP",
    "Get-VBRSessionsMCP",
    "Get-VBRHealthMCP"
)

foreach ($funcName in $requiredFunctions) {
    $funcExists = $scriptContent -match "function $funcName"
    Write-TestResult -TestName "Function '$funcName' defined" `
                     -Passed $funcExists
}

#endregion

#region Test 7: Output Directory Creation
Write-Host "`n[Test 7] Testing output directory creation..." -ForegroundColor Yellow

$testOutputPath = Join-Path $env:TEMP "VeeamMCPTest-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

try {
    New-Item -ItemType Directory -Path $testOutputPath -Force | Out-Null
    $dirCreated = Test-Path $testOutputPath
    
    Write-TestResult -TestName "Can create output directory" `
                     -Passed $dirCreated `
                     -Message "Test path: $testOutputPath"
    
    # Cleanup
    if ($dirCreated) {
        Remove-Item $testOutputPath -Force -ErrorAction SilentlyContinue
    }
}
catch {
    Write-TestResult -TestName "Can create output directory" `
                     -Passed $false `
                     -Message "Error: $_"
}

#endregion

#region Test 8: JSON Export Functionality
Write-Host "`n[Test 8] Testing JSON export capability..." -ForegroundColor Yellow

try {
    $testData = @{
        Test = "Value"
        Number = 123
        Array = @(1, 2, 3)
    }
    
    $testJsonPath = Join-Path $env:TEMP "veeam-mcp-test.json"
    $testData | ConvertTo-Json | Out-File -FilePath $testJsonPath -Encoding UTF8
    
    $jsonExists = Test-Path $testJsonPath
    
    if ($jsonExists) {
        $importedData = Get-Content $testJsonPath | ConvertFrom-Json
        $jsonValid = $importedData.Test -eq "Value"
        
        Write-TestResult -TestName "JSON export/import works" `
                         -Passed $jsonValid `
                         -Message "Test file: $testJsonPath"
        
        # Cleanup
        Remove-Item $testJsonPath -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-TestResult -TestName "JSON export/import works" `
                         -Passed $false `
                         -Message "Failed to create test file"
    }
}
catch {
    Write-TestResult -TestName "JSON export/import works" `
                     -Passed $false `
                     -Message "Error: $_"
}

#endregion

#region Test 9: Help Documentation
Write-Host "`n[Test 9] Checking help documentation..." -ForegroundColor Yellow

$hasCommentBasedHelp = $scriptContent -match '\.SYNOPSIS' -and $scriptContent -match '\.DESCRIPTION'
$hasExamples = $scriptContent -match '\.EXAMPLE'

Write-TestResult -TestName "Comment-based help exists" `
                 -Passed $hasCommentBasedHelp `
                 -Message "Synopsis and Description present"

Write-TestResult -TestName "Usage examples provided" `
                 -Passed $hasExamples `
                 -Message "Example sections found"

#endregion

#region Test 10: Error Handling
Write-Host "`n[Test 10] Checking error handling..." -ForegroundColor Yellow

$hasTryCatch = $scriptContent -match 'try\s*{' -and $scriptContent -match 'catch\s*{'
$hasErrorAction = $scriptContent -match '\$ErrorActionPreference'

Write-TestResult -TestName "Error handling implemented" `
                 -Passed $hasTryCatch `
                 -Message "Try-catch blocks present"

Write-TestResult -TestName "Error action preference set" `
                 -Passed $hasErrorAction `
                 -Message "ErrorActionPreference configured"

#endregion

#region Test 11: Dry Run (if not skipping VBR)
Write-Host "`n[Test 11] Attempting dry run..." -ForegroundColor Yellow

if (-not $SkipVBRConnection) {
    try {
        # Try to get VBR server connection status
        $vbrConnected = $false
        
        if (Get-PSSnapin -Name VeeamPSSnapin -ErrorAction SilentlyContinue) {
            try {
                $session = Get-VBRServerSession -ErrorAction SilentlyContinue
                $vbrConnected = $session -ne $null -and $session.IsConnected
            }
            catch {
                $vbrConnected = $false
            }
        }
        
        if ($vbrConnected) {
            Write-Host "  ℹ Running actual MCP script test (connected to VBR)..." -ForegroundColor Cyan
            
            # Run the actual script with ServerInfo action
            $testOutput = Join-Path $env:TEMP "VeeamMCPDryRun"
            
            & $scriptPath -Action ServerInfo -ExportPath $testOutput -OutputFormat JSON
            
            # Check if output was created
            $outputCreated = Test-Path "$testOutput\Run-*\VBR-ServerInfo.json"
            
            Write-TestResult -TestName "Script executes successfully" `
                             -Passed $outputCreated `
                             -Message "Output created in $testOutput"
            
            # Cleanup
            if (Test-Path $testOutput) {
                Remove-Item $testOutput -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        else {
            Write-Host "  ⊘ SKIP - Not connected to VBR server" -ForegroundColor Gray
            $testResults.Skipped++
        }
    }
    catch {
        Write-TestResult -TestName "Script executes successfully" `
                         -Passed $false `
                         -Message "Error: $_"
    }
}
else {
    Write-Host "  ⊘ SKIP - Dry run (SkipVBRConnection flag)" -ForegroundColor Gray
    $testResults.Skipped++
}

#endregion

#region Test 12: README Documentation
Write-Host "`n[Test 12] Checking documentation..." -ForegroundColor Yellow

$readmePath = Join-Path $PSScriptRoot "..\README.md"
$readmeExists = Test-Path $readmePath

Write-TestResult -TestName "README.md exists" `
                 -Passed $readmeExists `
                 -Message "Path: $readmePath"

if ($readmeExists) {
    $readmeContent = Get-Content $readmePath -Raw
    $hasUsageSection = $readmeContent -match '## Usage' -or $readmeContent -match '## Examples'
    
    Write-TestResult -TestName "README has usage documentation" `
                     -Passed $hasUsageSection
}

#endregion

#region Test Summary
Write-Host "`n" + ("="*80) -ForegroundColor Cyan
Write-Host "  TEST SUMMARY" -ForegroundColor Cyan
Write-Host ("="*80) -ForegroundColor Cyan

$totalTests = $testResults.Passed + $testResults.Failed
$passRate = if ($totalTests -gt 0) { 
    [math]::Round(($testResults.Passed / $totalTests) * 100, 2) 
} else { 0 }

Write-Host "`n  Total Tests Run: $totalTests" -ForegroundColor White
Write-Host "  Passed: $($testResults.Passed)" -ForegroundColor Green
Write-Host "  Failed: $($testResults.Failed)" -ForegroundColor Red
Write-Host "  Skipped: $($testResults.Skipped)" -ForegroundColor Gray
Write-Host "  Pass Rate: $passRate%" -ForegroundColor $(if ($passRate -ge 90) { "Green" } elseif ($passRate -ge 70) { "Yellow" } else { "Red" })

if ($testResults.Failed -gt 0) {
    Write-Host "`n  ⚠ Failed Tests:" -ForegroundColor Red
    $testResults.Tests | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "    - $($_.Name)" -ForegroundColor Red
        if ($_.Message) {
            Write-Host "      $($_.Message)" -ForegroundColor Gray
        }
    }
}

Write-Host "`n" + ("="*80) -ForegroundColor Cyan

if ($passRate -eq 100) {
    Write-Host "  ✓ ALL TESTS PASSED - Ready for production!" -ForegroundColor Green
}
elseif ($passRate -ge 90) {
    Write-Host "  ⚠ MOSTLY PASSED - Review failed tests" -ForegroundColor Yellow
}
else {
    Write-Host "  ✗ TESTS FAILED - Fix issues before deployment" -ForegroundColor Red
}

Write-Host ("="*80) + "`n" -ForegroundColor Cyan

# Export test results
$testResultsPath = Join-Path $PSScriptRoot "test-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$testResults | ConvertTo-Json -Depth 10 | Out-File -FilePath $testResultsPath -Encoding UTF8
Write-Host "Test results exported to: $testResultsPath`n" -ForegroundColor Cyan

#endregion

# Return test results
return $testResults
