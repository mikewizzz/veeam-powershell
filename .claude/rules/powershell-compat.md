# PowerShell 5.1 Compatibility Rules

All scripts must run on PowerShell 5.1. Do NOT use PS 7+ syntax.

## Prohibited Syntax

| Operator | PS Version | Use Instead |
|----------|-----------|-------------|
| `$x ?? $default` | 7.0+ | `if ($null -eq $x) { $default } else { $x }` |
| `$x ??= $default` | 7.0+ | `if ($null -eq $x) { $x = $default }` |
| `$x ? $a : $b` | 7.0+ | `if ($x) { $a } else { $b }` |
| `cmd1 && cmd2` | 7.0+ | `cmd1; if ($LASTEXITCODE -eq 0) { cmd2 }` |
| `cmd1 \|\| cmd2` | 7.0+ | `cmd1; if ($LASTEXITCODE -ne 0) { cmd2 }` |
| `[List[object]]::new()` | 7.0+ | `New-Object System.Collections.Generic.List[object]` |
| `$x?.Property` | 7.0+ | `if ($null -ne $x) { $x.Property }` |

## Collection Gotchas

- **Single-element array unwrapping** — PowerShell unwraps single-element arrays in the pipeline. Use the comma operator to force array context:
  ```powershell
  $results = ,@($collection | Where-Object { $_.Status -eq 'Active' })
  ```
- **Generic Lists** — Always use `New-Object System.Collections.Generic.List[object]` for building collections.
- **Array addition** — Prefer `[System.Collections.Generic.List[object]]` with `.Add()` over `$array += $item` for performance in loops.

## String Handling

- Use `-f` format operator or `$()` subexpressions in double-quoted strings
- Avoid here-strings with complex interpolation on PS 5.1 (escaping differences)
