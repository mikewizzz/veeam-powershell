# /review — Multi-Agent Code Review

Perform a comprehensive code review of the current project by launching 4 parallel review agents. Each agent focuses on a different quality dimension.

## Trigger

User types `/review` or `/review <path>`. If no path is given, review all `.ps1` files in the current working directory and its subdirectories.

## Instructions

Launch 4 agents in parallel using the Agent tool. Each agent should review all `.ps1` files in scope.

### Agent 1: Security Review
- **subagent_type:** `general-purpose`
- **model:** `sonnet`
- Check for XSS vulnerabilities in HTML report generation (missing `Escape-Html` calls)
- Check for PII exposure in ZIP exports or CSV outputs
- Check for hardcoded credentials, secrets, or tokens
- Check for path traversal vulnerabilities
- Report findings as: `[SECURITY] severity | file:line | description`

### Agent 2: PowerShell 5.1 Compatibility
- **subagent_type:** `general-purpose`
- **model:** `haiku`
- Check for PS 7+ only syntax: `??`, `??=`, ternary `? :`, pipeline chain `&&`/`||`, null-conditional `?.`
- Check for `[Type]::new()` instead of `New-Object`
- Check for single-element array unwrapping risks (missing comma operator)
- Report findings as: `[COMPAT] severity | file:line | description`

### Agent 3: UX & Report Quality
- **subagent_type:** `general-purpose`
- **model:** `haiku`
- Check HTML reports for accessibility (alt text, semantic headings, color contrast)
- Check that Write-Log is used consistently (not bare Write-Host)
- Check that Write-Progress tracks step counts
- Check parameter validation attributes are present
- Report findings as: `[UX] severity | file:line | description`

### Agent 4: Accuracy & Determinism
- **subagent_type:** `general-purpose`
- **model:** `sonnet`
- Check that all findings are algorithmically derived from data (no hardcoded conclusions)
- Check that MBS estimates are labeled as estimates
- Check that Graph API uses v1.0 endpoints (not beta)
- Check that permission failures degrade gracefully
- Report findings as: `[ACCURACY] severity | file:line | description`

## Output

After all 4 agents complete, consolidate their findings into a single markdown table:

```
| # | Category | Severity | Location | Finding |
|---|----------|----------|----------|---------|
```

Sort by severity (Critical > Warning > Info), then by category. Include a summary count at the bottom.
