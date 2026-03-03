# /ship — Branch, Commit, Push, PR, Merge

Ship the current changes through the full git cycle in one pass.

## Trigger

User types `/ship` or `/ship <message>`. If a message is provided, use it as the commit subject. Otherwise, derive one from the changes.

## Instructions

### Step 1: Assess State

Run in parallel:
- `git status` — untracked and modified files
- `git diff` + `git diff --cached` — all changes
- `git log --oneline -5` — recent commit style
- `git branch --show-current` — current branch

### Step 2: Stage and Branch

If on `main`:
1. Derive a branch name from the changes: `feat/`, `fix/`, `docs/`, `refactor/` + short kebab-case descriptor
2. Create and switch to the branch: `git checkout -b <branch>`

Stage only the relevant changed files by explicit name. NEVER use `git add .` or `git add -A`.

### Step 3: Commit

Write a conventional commit message: `type(scope): subject`

- Imperative mood, lowercase, no trailing period
- Keep subject under 72 characters
- Add body only if the change is non-obvious

Commit using a HEREDOC:
```bash
git commit -m "$(cat <<'EOF'
type(scope): subject

Optional body explaining why.
EOF
)"
```

### Step 4: Push

```bash
git push -u origin $(git branch --show-current)
```

### Step 5: Create PR

Use `gh pr create`:
```bash
gh pr create --title "type(scope): subject" --body "$(cat <<'EOF'
## Summary
- bullet points

## Test plan
- [ ] verification steps
EOF
)"
```

### Step 6: Offer Merge

Return the PR URL and ask:

> PR created: <url>
> Want me to merge it?

If the user confirms, squash-merge and delete the branch:
```bash
gh pr merge --squash --delete-branch
```

Then switch back to main and pull:
```bash
git checkout main && git pull
```

## Rules

- No AI attribution anywhere — no Co-Authored-By, no "Generated with Claude Code"
- No sensitive info in commits or PR body
- No `git add .` or `git add -A` — always explicit file names
- No force pushes unless explicitly asked
- If there are no changes to ship, say so and stop
