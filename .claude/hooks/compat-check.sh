#!/bin/bash
# PostToolUse hook: check for PS 7+ syntax in edited .ps1 files
# Catches null-coalescing, ternary, pipeline chains, ::new(), null-conditional

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only check PowerShell files
if [ -z "$FILE_PATH" ] || [[ "$FILE_PATH" != *.ps1 ]]; then
  exit 0
fi

# Skip if file doesn't exist (was deleted)
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

ISSUES=""

# Check for [Type]::new() — most reliable pattern
FOUND=$(grep -n ']::new(' "$FILE_PATH" | grep -v '^[0-9]*:\s*#')
if [ -n "$FOUND" ]; then
  while IFS= read -r line; do
    LINENUM=$(echo "$line" | cut -d: -f1)
    ISSUES="${ISSUES}
[COMPAT] ${FILE_PATH}:${LINENUM} — [Type]::new() is PS 7+ only. Use: New-Object TypeName"
  done <<< "$FOUND"
fi

# Check for null-coalescing ?? and ??=
# Use grep -P for perl regex if available, otherwise grep -E
FOUND=$(grep -nE '\?\?[=]?' "$FILE_PATH" 2>/dev/null | grep -v '^[0-9]*:\s*#' | grep -v '^[0-9]*:\s*\.') || true
if [ -n "$FOUND" ]; then
  while IFS= read -r line; do
    LINENUM=$(echo "$line" | cut -d: -f1)
    ISSUES="${ISSUES}
[COMPAT] ${FILE_PATH}:${LINENUM} — Null-coalescing (??) is PS 7+ only. Use: if (\$null -eq \$x) { \$default } else { \$x }"
  done <<< "$FOUND"
fi

# Check for null-conditional ?. on variables
FOUND=$(grep -nE '\$\w+\?\.' "$FILE_PATH" 2>/dev/null | grep -v '^[0-9]*:\s*#') || true
if [ -n "$FOUND" ]; then
  while IFS= read -r line; do
    LINENUM=$(echo "$line" | cut -d: -f1)
    ISSUES="${ISSUES}
[COMPAT] ${FILE_PATH}:${LINENUM} — Null-conditional (?.) is PS 7+ only. Use: if (\$null -ne \$x) { \$x.Property }"
  done <<< "$FOUND"
fi

# Check for pipeline chain operators && (outside comments)
FOUND=$(grep -nF '&&' "$FILE_PATH" 2>/dev/null | grep -v '^[0-9]*:\s*#' | grep -v '\-band') || true
if [ -n "$FOUND" ]; then
  while IFS= read -r line; do
    LINENUM=$(echo "$line" | cut -d: -f1)
    CONTENT=$(echo "$line" | cut -d: -f2-)
    # Skip if inside a string (rough heuristic: has quotes around it)
    case "$CONTENT" in
      *'"'*'&&'*'"'*) continue ;;
      *"'"*'&&'*"'"*) continue ;;
    esac
    ISSUES="${ISSUES}
[COMPAT] ${FILE_PATH}:${LINENUM} — Pipeline chain (&&) is PS 7+ only. Use separate statements."
  done <<< "$FOUND"
fi

if [ -n "$ISSUES" ]; then
  echo "PS 5.1 compatibility issues:${ISSUES}"
fi

exit 0
