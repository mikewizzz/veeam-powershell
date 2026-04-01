# /compat-check — PowerShell 5.1 Compatibility Scan

Scan changed PowerShell files for PS 7+ syntax that breaks on 5.1.

## Trigger

User types `/compat-check` or `/compat-check <path>`. Default: scan all .ps1 files changed vs main.

Arguments: `$ARGUMENTS` is an optional file path or directory.

## Instructions

### Step 1: Identify Files to Scan

If `$ARGUMENTS` specifies a path, scan that file or directory.

Otherwise, get changed files vs main:
```bash
git diff --name-only main...HEAD -- '*.ps1'
```

If no branch changes, scan all staged + modified files:
```bash
git diff --name-only --cached -- '*.ps1' && git diff --name-only -- '*.ps1'
```

If still nothing, scan all .ps1 files in the repo.

### Step 2: Run Compatibility Checks

For each .ps1 file, search for these prohibited patterns using Grep:

| Pattern | Regex | PS Version | Fix |
|---------|-------|-----------|-----|
| Null-coalescing | `\?\?[^?]` | 7.0+ | `if ($null -eq $x) { $default } else { $x }` |
| Null-coalescing assignment | `\?\?=` | 7.0+ | `if ($null -eq $x) { $x = $default }` |
| Ternary operator | `\?\s+.+\s+:\s+` (in expression context) | 7.0+ | `if ($x) { $a } else { $b }` |
| Pipeline chain AND | `\&\&` (outside strings) | 7.0+ | Separate statements with `;` and `$LASTEXITCODE` check |
| Pipeline chain OR | `\|\|` (outside strings) | 7.0+ | Separate statements with `;` and `$LASTEXITCODE` check |
| Static new() | `\]::new\(` | 7.0+ | `New-Object TypeName` |
| Null-conditional | `\?\.\w` | 7.0+ | `if ($null -ne $x) { $x.Property }` |
| Clean block | `\bclean\s*\{` (in function context) | 7.4+ | Move to finally block |

Also check for:
- **Single-element array unwrapping** — `@()` missing around pipeline results assigned to variables that may return 0 or 1 items
- **`[System.Collections.Generic.List[object]]::new()`** vs `New-Object` usage

### Step 3: Run PSScriptAnalyzer

```powershell
Invoke-ScriptAnalyzer -Path $file -Severity Error,Warning -ExcludeRule PSUseSingularNouns,PSUseShouldProcessForStateChangingFunctions,PSUseBOMForUnicodeEncodedFile
```

### Step 4: Report

Output a summary:

```
PS 5.1 Compatibility Check
===========================

Scanned: 4 files

FINDINGS:
  [COMPAT] lib/Auth.ps1:42 — Null-coalescing (??) operator. Use: if ($null -eq $x) { $default } else { $x }
  [COMPAT] lib/Sizing.ps1:187 — [List[object]]::new() usage. Use: New-Object System.Collections.Generic.List[object]
  [LINT]   Script.ps1:305 — [PSAvoidUsingCmdletAliases] 'select' is an alias for Select-Object

Summary: 2 compat issues, 1 linter warning
Status: NEEDS FIX
```

If no issues found:
```
PS 5.1 Compatibility Check
===========================
Scanned: 4 files
Status: ALL CLEAR
```

## Rules

- Focus on actionable findings with exact file:line references
- Always provide the PS 5.1 compatible alternative
- Distinguish between compat issues ([COMPAT]) and linter issues ([LINT])
- Do not flag patterns inside comments or strings
