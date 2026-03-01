# Git Workflow Rules

## Branching

- **Never commit directly to main** — All changes go through feature branches and pull requests.
- **Branch naming** — Use descriptive branch names: `feat/description`, `fix/description`, `docs/description`, `refactor/description`.
- **One feature per PR** — Keep PRs focused on a single change. Separate features, fixes, and refactors into their own PRs.

## Commits

- **Conventional commits format** — `type(scope): subject`
  - Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`
  - Scope: the project or component (e.g., `m365-sizing`, `ahv-surebackup`, `azure-sizing`)
  - Subject: imperative mood, lowercase, no period
- **No sensitive info in commits** — Commit messages must not contain tenant IDs, credentials, internal tool names (Veeam Insights), or competitive strategy details.
- **No AI attribution** — Never add `Co-Authored-By` lines referencing Claude, Anthropic, or any AI. No "Generated with Claude Code" footers. No mentions of AI tooling in commits, PR descriptions, or code comments. All output should appear human-authored.
- **Atomic commits** — Each commit should represent a single logical change that compiles and runs.

## Pull Requests

- **Descriptive title** — Under 70 characters, follows conventional commit format.
- **Summary section** — 1-3 bullet points describing what changed and why.
- **Test plan** — Checklist of manual verification steps.

## Code Review

- **PSScriptAnalyzer clean** — All PS1 files must pass the PostToolUse linting hook before commit.
- **No force pushes to main** — Never force-push to the main branch.
