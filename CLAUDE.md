# CLAUDE.md

Guide for AI assistants working with the veeam-powershell repository.

## Repository Overview

Collection of standalone PowerShell presales assessment tools for Veeam backup solutions across Microsoft 365, Azure, and AWS. Target audience: Veeam Sales Engineers, Architects, and IT Professionals performing capacity planning and cost analysis.

## Repository Structure

```
veeam-powershell/
├── M365/
│   ├── Get-VeeamM365Sizing.ps1          # M365 tenant sizing (1700+ lines, production)
│   ├── test-minimal.ps1                  # Basic integration tests
│   ├── README.md
│   ├── CONTRIBUTING.md                   # Detailed coding standards
│   ├── LICENSE                           # MIT
│   └── .gitignore
├── AZURE/
│   ├── Get-VeeamAzureSizing/
│   │   ├── Get-VeeamAzureSizing.ps1      # Azure infrastructure sizing (1250+ lines, production)
│   │   └── README.md
│   ├── Get-VeeamVaultPricing/
│   │   ├── Get-VeeamVaultPricing.ps1     # Vault vs Azure Blob cost comparison (980+ lines, production)
│   │   └── README.md
│   └── Start-VRO-Azure-Recovery/
│       └── Start-VROAzureRecovery.ps1    # Stub/placeholder
├── AWS/
│   ├── Find-CleanEC2-RestorePoint/
│   │   └── Find-CleanEC2-RestorePoint.ps1  # Stub/placeholder
│   └── Restore-VRO-AWS-EC2/
│       └── Restore-VRO-AWS-EC2.ps1         # Stub/placeholder
└── CLAUDE.md
```

**Three production scripts** (M365 sizing, Azure sizing, Vault pricing). AWS and Azure Recovery scripts are stubs for future development.

## Architecture

- **Standalone scripts** — no `.psm1`/`.psd1` module manifests. Each `.ps1` is self-contained and directly executable.
- **No build system or CI/CD** — no GitHub Actions, no pipelines, no Makefile.
- **No formal test framework** — one manual integration test (`M365/test-minimal.ps1`), no Pester.
- **Dependencies documented inline** — in `.NOTES` comment blocks and READMEs, not in manifest files.

## Coding Conventions

All conventions are defined in `M365/CONTRIBUTING.md`. Key rules:

### Naming

- **Functions:** `Verb-Noun` using PowerShell approved verbs (e.g., `Get-GroupUPNs`, `Invoke-Graph`, `Test-AzSession`)
- **Variables:** `$camelCase` (local), `$PascalCase` (script-level)
- **Constants:** `$UPPER_CASE` (e.g., `$GB`, `$TiB`)
- **Private functions:** `_FunctionName` prefix

### Script Structure

Every production script follows this layout:

1. Comment-based help block (`.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, `.EXAMPLE`, `.NOTES`)
2. `[CmdletBinding()]` param block with validation attributes and grouped sections
3. `$ErrorActionPreference = "Stop"` and `$ProgressPreference = 'SilentlyContinue'`
4. Output folder setup (timestamped)
5. Helper/utility functions (unit conversion, string escaping, formatting)
6. API interaction functions (with retry logic and exponential backoff)
7. Authentication (multi-method hierarchy: Managed Identity > Certificate > Token > Secret > Interactive)
8. Data retrieval and processing
9. Report generation (HTML with Microsoft Fluent Design System, CSV, JSON)
10. Cleanup (ZIP archive, session disconnect, console summary)

### Parameters

- Always use `[CmdletBinding()]`
- Type-annotate all parameters
- Use `[ValidateRange()]`, `[ValidateSet()]`, `[Parameter(Mandatory=$true)]`
- Group related parameters with section comments (e.g., `# Authentication`, `# Scope`, `# Output`)
- Provide sensible defaults for optional parameters

### Error Handling

- `$ErrorActionPreference = "Stop"` at script level
- Try/catch around risky operations (API calls, auth, file I/O)
- Exponential backoff retry for network/API calls (max 30s between retries)
- Actionable error messages with `$_.Exception.Message`
- Log errors via centralized `Write-Log` function

### Logging

Each script defines a `Write-Log` function with levels: `INFO`, `WARNING`, `ERROR`, `SUCCESS`. Output is color-coded on console and persisted to a log file. Progress tracking uses `Write-Progress` with step counting.

### Comments

- Comment-based help (`.SYNOPSIS`, `.PARAMETER`, `.NOTES`) for all functions
- Section separators with `#region`/`#endregion` or `# ========` blocks
- Explain **why**, not **what**

### Output Files

All production scripts generate multi-format deliverables:
- **HTML** — Professional reports using Microsoft Fluent Design System
- **CSV** — Tabular data with timestamped filenames, UTF-8
- **TXT** — Methodology notes
- **JSON** — Machine-readable bundle (optional)
- **ZIP** — Compressed archive of all outputs

## Key Patterns to Follow

### Hashtable splatting for parameters
```powershell
$connectParams = @{ ErrorAction = "Stop" }
Connect-AzAccount @connectParams | Out-Null
```

### Generic List for collections
```powershell
$results = New-Object System.Collections.Generic.List[object]
$results.Add([PSCustomObject]@{ Name = $vm.Name })
```

### Hashtable caching for API results
```powershell
$cache = @{}
if (-not $cache.ContainsKey($id)) {
    $cache[$id] = Get-AzResource -Id $id
}
```

### Retry with exponential backoff
```powershell
$attempt = 0
do {
    try { return Invoke-MgGraphRequest -Uri $Uri }
    catch {
        $attempt++
        $sleep = [Math]::Min([int]([Math]::Pow(2, $attempt)), 30)
        Start-Sleep -Seconds $sleep
    }
} while ($attempt -le $MaxRetries)
```

## Dependencies

| Script | Required Modules |
|--------|-----------------|
| Get-VeeamM365Sizing.ps1 | Microsoft.Graph.Authentication, Microsoft.Graph.Reports, Microsoft.Graph.Identity.DirectoryManagement |
| Get-VeeamAzureSizing.ps1 | Az.Accounts, Az.Resources, Az.Compute, Az.Network, Az.Sql, Az.Storage, Az.RecoveryServices |
| Get-VeeamVaultPricing.ps1 | None (uses REST API directly) |

PowerShell 7.x recommended; 5.1 supported.

## Git Conventions

Conventional commits format:
```
type(scope): subject
```
Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

Examples:
```
feat(auth): add certificate-based authentication
fix(reports): correct growth rate calculation for empty datasets
docs(readme): add troubleshooting section
```

## Testing

Before submitting changes, manually test:
1. Quick mode: `.\Get-VeeamM365Sizing.ps1`
2. Full mode: `.\Get-VeeamM365Sizing.ps1 -Full`
3. Group filtering: `.\Get-VeeamM365Sizing.ps1 -ADGroup "TestGroup"`
4. Error conditions (missing permissions, invalid inputs)
5. HTML report rendering in browser

No automated test runner exists. The only test file is `M365/test-minimal.ps1` which validates module imports and Graph API connectivity.

## Common Pitfalls

- **SharePoint cannot be group-filtered** — Graph API limitation; always tenant-wide.
- **Archive/RIF sizing is slow** — Sequential per-mailbox queries; can take 30+ minutes for large tenants.
- **Report masking breaks group filtering** — If M365 Admin Center has "concealed names" enabled, UPN-based filtering fails.
- **MBS estimates are models, not measurements** — Actual consumption depends on backup configuration.
- **AWS scripts are stubs** — Do not reference them as working implementations.
