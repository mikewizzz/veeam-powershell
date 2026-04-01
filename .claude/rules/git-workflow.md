# Git Workflow Rules

## Flow

When the user says "commit" or "ship it", execute the full cycle: branch, commit, push, PR, and ask to merge. Don't stop at just the commit.

- **Branch from main** — `feat/`, `fix/`, `docs/`, `refactor/` prefixes.
- **One concern per PR** — Don't mix unrelated changes.
- **Conventional commits** — `type(scope): subject` (imperative, lowercase, no period).

## Hard Rules

- **No AI attribution** — No `Co-Authored-By` AI lines. No "Generated with Claude Code". No mentions of AI tooling anywhere. All output appears human-authored.
- **No sensitive info** — No tenant IDs, credentials, internal tool names, or competitive strategy in commits or PRs.
- **PSScriptAnalyzer clean** — All PS1 files must pass linting before commit.
- **No force pushes to main** — Unless explicitly asked.

## PR Format

Keep it tight — title under 70 chars, 1-3 bullet summary, test checklist. No essays.
