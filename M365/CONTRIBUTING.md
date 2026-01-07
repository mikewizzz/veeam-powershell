# Contributing to Veeam M365 Sizing Tool

Thank you for your interest in contributing! This document provides guidelines for contributing to this project.

## Code of Conduct

- Be respectful and constructive
- Focus on the issue, not the person
- Welcome newcomers and help them learn

## How to Contribute

### Reporting Issues

1. Check existing issues first to avoid duplicates
2. Use the issue template (if available)
3. Provide clear reproduction steps
4. Include:
   - PowerShell version (`$PSVersionTable.PSVersion`)
   - Operating system
   - Relevant error messages
   - Expected vs actual behavior

### Submitting Changes

1. **Fork the repository**
2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes**
4. **Test thoroughly**
   - Run with both `-Quick` and `-Full` modes
   - Test error conditions
   - Verify HTML report renders correctly
5. **Commit with clear messages**
   ```bash
   git commit -m "Add feature: clear description"
   ```
6. **Push and create a Pull Request**

## Coding Standards

### PowerShell Style Guide

#### KISS Principles
- **Keep It Simple, Stupid** - Favor clarity over cleverness
- One function should do one thing well
- Avoid deep nesting (max 3 levels)
- Use descriptive variable names
- Break complex logic into smaller functions

#### Naming Conventions
- **Functions:** `Verb-Noun` (e.g., `Get-GroupUPNs`, `Invoke-Graph`)
- **Variables:** `$camelCase` for local, `$PascalCase` for script-level
- **Constants:** `$UPPER_CASE` (e.g., `$GB`, `$TiB`)
- **Private functions:** Prefix with `_` (e.g., `_InternalHelper`)

#### Comments
- Add comment-based help for all functions:
  ```powershell
  <#
  .SYNOPSIS
    Brief description
  .PARAMETER name
    Parameter description
  .NOTES
    Additional notes
  #>
  ```
- Use section separators for major code blocks:
  ```powershell
  # =============================
  # Section Name
  # =============================
  ```
- Explain **why**, not **what** (code shows what)
- Comment complex logic, not obvious operations

#### Error Handling
- Use `$ErrorActionPreference = "Stop"` at script level
- Wrap risky operations in try/catch
- Provide actionable error messages
- Include retry logic for network operations

#### Parameters
- Use `[ValidateRange]`, `[ValidateSet]`, etc.
- Provide sensible defaults
- Add inline comments for non-obvious parameters
- Group related parameters with section comments

### Testing Requirements

Before submitting a PR, test:

1. **Quick mode**
   ```powershell
   .\Get-VeeamM365Sizing.ps1
   ```

2. **Full mode**
   ```powershell
   .\Get-VeeamM365Sizing.ps1 -Full
   ```

3. **Group filtering**
   ```powershell
   .\Get-VeeamM365Sizing.ps1 -ADGroup "TestGroup"
   ```

4. **Error conditions**
   - Missing permissions
   - Invalid group names
   - Network interruptions

5. **HTML report**
   - Open generated HTML in browser
   - Verify styling renders correctly
   - Test responsive design (mobile view)
   - Check print preview

### Documentation

- Update README.md for new parameters
- Add examples for new features
- Update changelog with version number
- Document breaking changes prominently

### Git Commit Messages

Follow conventional commits format:

```
type(scope): subject

body (optional)

footer (optional)
```

**Types:**
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Code style (formatting, no logic change)
- `refactor`: Code restructure (no behavior change)
- `test`: Adding tests
- `chore`: Maintenance tasks

**Examples:**
```
feat(auth): add certificate-based authentication

fix(reports): correct growth rate calculation for empty datasets

docs(readme): add troubleshooting section for masked reports

refactor(graph): simplify retry logic with exponential backoff
```

## Project Structure

```
veeam-powershell/
├── Get-VeeamM365Sizing.ps1    # Main script
├── README.md                   # User documentation
├── CONTRIBUTING.md             # This file
├── LICENSE                     # MIT License
├── .gitignore                  # Git exclusions
└── VeeamM365SizingOutput/      # Generated outputs (gitignored)
```

## Development Workflow

1. **Pull latest changes**
   ```bash
   git checkout main
   git pull origin main
   ```

2. **Create feature branch**
   ```bash
   git checkout -b feature/my-feature
   ```

3. **Make changes and test**
   - Edit code
   - Test locally
   - Update documentation

4. **Commit changes**
   ```bash
   git add .
   git commit -m "feat: add new feature"
   ```

5. **Push and create PR**
   ```bash
   git push origin feature/my-feature
   ```

6. **Respond to review feedback**
   - Make requested changes
   - Push additional commits
   - Request re-review

## Release Process

1. Update version in script header comment
2. Update CHANGELOG in README.md
3. Tag release: `git tag -a v2.0 -m "Version 2.0"`
4. Push tag: `git push origin v2.0`

## Questions?

Open an issue with the `question` label, or contact the maintainers directly.

## Thank You!

Your contributions make this project better for everyone. We appreciate your time and effort! 🎉
