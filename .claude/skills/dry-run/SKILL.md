# /dry-run — PowerShell Syntax Validation

Run syntax validation and basic smoke tests on all PowerShell files in the current project without connecting to any external services.

## Trigger

User types `/dry-run` or `/dry-run <path>`. If no path is given, validate all `.ps1` files in the current working directory and its subdirectories.

## Instructions

Run the following checks using `pwsh -NoProfile` via the Bash tool:

### Check 1: Syntax Validation
For each `.ps1` file, run PowerShell syntax parsing:
```powershell
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($filePath, [ref]$null, [ref]$errors)
if ($errors) { $errors | ForEach-Object { Write-Output "$filePath:$($_.Extent.StartLineNumber) $($_.Message)" } }
```

### Check 2: Lib File Integration
If a `lib/` directory exists, verify that dot-sourcing the lib files doesn't produce parse errors:
```powershell
Get-ChildItem -Path ./lib -Filter *.ps1 | ForEach-Object {
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errors)
    if ($errors) { Write-Output "FAIL: $($_.Name) - $($errors[0].Message)" }
    else { Write-Output "PASS: $($_.Name)" }
}
```

### Check 3: Key Function Existence
After parsing, verify that expected functions are defined (look for `function` keyword):
- Main script: should define `Write-Log` and at least one `Get-*` or `Invoke-*` function
- Lib files: each should define at least one function

### Check 4: PSScriptAnalyzer
Run PSScriptAnalyzer on all files with Error severity:
```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error -ExcludeRule PSUseSingularNouns,PSUseShouldProcessForStateChangingFunctions,PSUseBOMForUnicodeEncodedFile
```

## Output

Report a pass/fail summary:
```
Dry Run Results:
  Syntax:          ✓ 12/12 files passed
  Lib Integration: ✓ 4/4 libs parsed
  Key Functions:   ✓ Write-Log, Get-M365Data, Invoke-Graph found
  ScriptAnalyzer:  ✗ 2 errors found
    - file.ps1:42 [PSAvoidUsingCmdletAliases] ...

Overall: PASS (with 2 warnings)
```
