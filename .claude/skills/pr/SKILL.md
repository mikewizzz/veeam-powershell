# /pr — Create a Pull Request

Create a well-documented pull request from the current branch's changes.

## Trigger

User types `/pr` or `/pr <base-branch>`. Default base branch is `main`.

## Instructions

1. **Gather context** — Run these in parallel:
   - `git status` to see all changes
   - `git diff` for staged/unstaged changes
   - `git log main..HEAD --oneline` for all commits on this branch
   - `git diff main...HEAD` for the full diff against base

2. **Analyze all commits** — Look at EVERY commit in the branch, not just the latest. Understand the full scope of changes.

3. **Draft PR content:**
   - **Title:** Under 70 characters, conventional commit format (`type(scope): subject`)
   - **Summary:** 1-3 bullet points covering what changed and why
   - **Test plan:** Checklist of manual verification steps relevant to the changes

4. **Create the PR:**
   - Push the current branch to remote with `-u` flag if not already tracking
   - Use `gh pr create` with the following format:

```
gh pr create --title "the pr title" --body "$(cat <<'EOF'
## Summary
- bullet points here

## Test plan
- [ ] verification step 1
- [ ] verification step 2
EOF
)"
```

5. **Return the PR URL** to the user.

## Rules

- Follow conventional commit format for the title
- No sensitive information in PR title or body (no tenant IDs, no internal tool names)
- No competitor mentions in PR description
- No AI attribution — no "Generated with Claude Code", no Co-Authored-By AI lines, no mentions of AI tooling
