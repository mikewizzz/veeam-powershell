#!/bin/bash
# PostToolUse hook: run PSScriptAnalyzer on edited .ps1 files
# Excludes rules that conflict with project conventions (plural nouns, ShouldProcess, BOM)

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only lint PowerShell files
if [ -z "$FILE_PATH" ] || [[ "$FILE_PATH" != *.ps1 ]]; then
  exit 0
fi

# Skip if file doesn't exist (was deleted)
if [ ! -f "$FILE_PATH" ]; then
  exit 0
fi

RESULT=$(pwsh -NoProfile -c "
  \$findings = Invoke-ScriptAnalyzer -Path '$FILE_PATH' -Severity Error,Warning \
    -ExcludeRule PSUseSingularNouns,PSUseShouldProcessForStateChangingFunctions,PSUseBOMForUnicodeEncodedFile
  if (\$findings) {
    \$findings | ForEach-Object {
      '{0}:{1} [{2}] {3}' -f \$_.ScriptName, \$_.Line, \$_.RuleName, \$_.Message
    }
  }
" 2>&1)

if [ -n "$RESULT" ]; then
  echo "PSScriptAnalyzer warnings:"
  echo "$RESULT"
fi

exit 0
