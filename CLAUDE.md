# CLAUDE.md

Guide for AI assistants working with the veeam-powershell repository.

## Repository Overview

Collection of open-source, community-maintained PowerShell tools for Veeam backup solutions across Microsoft 365, Azure, and AWS. These tools help IT professionals, architects, and administrators perform capacity planning, cost analysis, and infrastructure management.

## Repository Structure

```
veeam-powershell/
├── README.md
├── CLAUDE.md
├── ActiveDirectory/
│   └── Get-ADIdentityAssessment/
│       ├── Get-ADIdentityAssessment.ps1    # On-prem AD identity assessment (production)
│       └── README.md
├── AWS/
│   ├── Find-CleanEC2-RestorePoint/
│   │   ├── Find-CleanEC2-RestorePoint.ps1  # VRO pre-step: find clean restore point (production)
│   │   └── README.md
│   └── Restore-VRO-AWS-EC2/
│       ├── Restore-VRO-AWS-EC2.ps1         # VRO step: restore backups to EC2 (production)
│       └── README.md
├── AZURE/
│   ├── Get-VBAHealthCheck/
│   │   ├── Get-VBAHealthCheck.ps1          # VBA health check & compliance (production)
│   │   └── README.md
│   ├── Get-VeeamAzureSizing/
│   │   ├── Get-VeeamAzureSizing.ps1        # Azure infrastructure sizing (production)
│   │   └── README.md
│   ├── Get-VeeamVaultPricing/
│   │   ├── Get-VeeamVaultPricing.ps1       # Vault vs Azure Blob cost comparison (production)
│   │   └── README.md
│   ├── New-VeeamDRLandingZone/
│   │   ├── New-VeeamDRLandingZone.ps1      # DR landing zone provisioning (production)
│   │   └── README.md
│   ├── Start-AzureBlobToVaultMigration/
│   │   ├── Start-AzureBlobToVaultMigration.ps1 # Blob to Vault migration (production)
│   │   └── README.md
│   ├── Start-VRO-Azure-Recovery/
│   │   ├── Start-VROAzureRecovery.ps1      # Azure recovery plan trigger (stub/placeholder)
│   │   └── README.md
│   └── Test-VeeamVaultBackup/
│       ├── Test-VeeamVaultBackup.ps1        # Automated backup verification (production)
│       └── README.md
├── M365/
│   ├── Get-VeeamM365Sizing/
│   │   ├── Get-VeeamM365Sizing.ps1         # M365 data footprint assessment for VDC (production)
│   │   ├── test-minimal.ps1                # Basic integration tests
│   │   └── README.md
│   ├── CONTRIBUTING.md                     # Detailed coding standards
│   ├── LICENSE                             # MIT
│   └── .gitignore
├── MySQL/
│   └── Invoke-VeeamMySQLBackup/
│       ├── Invoke-VeeamMySQLBackup.ps1     # MySQL backup with Veeam agents (production)
│       ├── veeam-mysql-prefreeze.sh
│       ├── veeam-mysql-postthaw.sh
│       └── README.md
├── NutanixAHV/
│   └── Start-VeeamAHVSureBackup/
│       ├── Start-VeeamAHVSureBackup.ps1    # SureBackup for Nutanix AHV (production)
│       └── README.md
├── ONPREM/
│   └── New-VeeamSureBackupSetup/
│       ├── New-VeeamSureBackupSetup.ps1    # SureBackup environment setup (production)
│       └── README.md
├── PURE-STORAGE/
│   └── Restore-VRO-PureStorage-VMware/
│       ├── Restore-VRO-PureStorage-VMware.ps1 # VRO Pure Storage VMware restore (production)
│       └── README.md
└── VBR/
    └── Get-VeeamDiagram/
        ├── Get-VeeamDiagram.ps1            # VBR v13 REST API diagram generator (production)
        └── README.md
```

Every script lives in its own folder with a dedicated README.md. The `Start-VRO-Azure-Recovery` script is a stub for future development; all others are production scripts.

## Architecture

- **Standalone scripts** — no `.psm1`/`.psd1` module manifests. Each `.ps1` is self-contained and directly executable.
- **No build system or CI/CD** — no GitHub Actions, no pipelines, no Makefile.
- **No formal test framework** — one manual integration test (`M365/Get-VeeamM365Sizing/test-minimal.ps1`), no Pester.
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
| Test-VeeamVaultBackup.ps1 | Az.Accounts, Az.Resources, Az.Compute, Az.Network |
| Get-ADIdentityAssessment.ps1 | ActiveDirectory (RSAT) |
| Find-CleanEC2-RestorePoint.ps1 | Veeam.Backup.PowerShell |
| Restore-VRO-AWS-EC2.ps1 | Veeam.Backup.PowerShell, AWS.Tools.Common, AWS.Tools.EC2 |

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

No automated test runner exists. The only test file is `M365/Get-VeeamM365Sizing/test-minimal.ps1` which validates module imports and Graph API connectivity.

## Common Pitfalls

- **SharePoint cannot be group-filtered** — Graph API limitation; always tenant-wide.
- **Archive/RIF sizing is slow** — Sequential per-mailbox queries; can take 30+ minutes for large tenants.
- **Report masking breaks group filtering** — If M365 Admin Center has "concealed names" enabled, UPN-based filtering fails.
- **Teams files stored in SharePoint** — Teams file storage is included in SharePoint totals; no separate Teams storage metric exists.
- **Azure Recovery script is a stub** — `Start-VROAzureRecovery.ps1` is a placeholder for future development.
