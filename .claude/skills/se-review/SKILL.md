---
name: se-review
description: Run a 6-perspective SE code review on a Veeam PowerShell script
argument-hint: [script-path-or-directory]
user-invocable: true
---

Run a 6-perspective Solution Engineer code review on $ARGUMENTS.

If a directory is given, identify the main .ps1 script and its lib/ files. Read all of them before reviewing.

## Review Perspectives

Evaluate the code from each perspective. For each finding, assign a severity:
- **BLOCKING** — Must fix before production use. Security holes, data loss risk, broken functionality.
- **WARNING** — Should fix. Incorrect docs, missing error handling, silent failures.
- **INFO** — Nice to have. Style, optimization, minor improvements.

### 1. Security
- Credential handling (PSCredential, no plaintext, memory cleanup)
- Injection risks (command injection, XSS in HTML reports)
- TLS/certificate validation (SkipCertificateCheck only in labs)
- OWASP top 10 where applicable

### 2. Factual Accuracy
- API versions match actual endpoint availability
- Product version requirements are correct
- Veeam feature descriptions match real product capabilities
- Parameter defaults match documented behavior

### 3. Operational Reliability
- Error handling (try/catch on all API calls, actionable messages)
- Retry logic with exponential backoff for network calls
- Token/session refresh for long-running operations
- Timeout handling and cleanup on failure
- Idempotent cleanup (no orphaned resources)

### 4. Naming & Compliance
- Trademark usage (Veeam, SureBackup, Nutanix — community disclaimers where needed)
- License headers present
- Community vs official product distinction is clear

### 5. DevOps Readiness
- Test coverage (Pester tests exist and pass)
- CI/CD compatibility (exit codes, structured output)
- Output formats (HTML, CSV, JSON, ZIP)
- Logging (Write-Log with levels, log file persistence)

### 6. Architecture & Patterns
- Follows repo conventions from CLAUDE.md and CONTRIBUTING.md
- Modular structure (lib/ decomposition for large scripts)
- Parameter validation (CmdletBinding, ValidateSet, ValidateRange)
- Caching, pagination, Generic List usage

## Output Format

Present findings as a markdown table grouped by perspective:

```
| # | Perspective | Severity | File:Line | Finding | Suggested Fix |
```

Then provide a summary:
- Total findings by severity
- Overall assessment (Ready / Needs Work / Blocking Issues)
- Recommended fix order (blocking first, then warnings)
