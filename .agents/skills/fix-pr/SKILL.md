---
name: fix-pr
description: "Fix issues on the current PR: address Claude Code review comments and fix failing CI checks. Use when asked to fix PR, fix review comments, fix CI, or fix checks. Triggers on: fix pr, fix review, fix ci, fix checks, fix failing checks."
user-invocable: true
---

# Fix PR

Fixes the current PR by addressing Claude Code review comments and fixing failing CI status checks.

---

## Prerequisites

- You must be on a branch that has an open PR
- The repo remote is on GitHub (uses `gh` CLI)

---

## Step 1: Identify the PR

Run:
```
gh pr view --json number,headRefName,url
```

If no PR is found for the current branch, tell the user and stop.

---

## Step 2: Fix Claude Code Review Comments

### 2a. Fetch review comments

Get the latest Claude Code review comments on the PR:

```
gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews --jq '.[] | select(.user.login == "github-actions[bot]" or .user.login == "claude-code-review[bot]" or (.body | test("claude|Claude|code review"; "i"))) | {id: .id, body: .body, state: .state}'
```

Also fetch inline review comments:
```
gh api repos/{owner}/{repo}/pulls/{pr_number}/comments --jq '.[] | select(.user.login == "github-actions[bot]" or .user.login == "claude-code-review[bot]" or (.body | test("claude|Claude"; "i"))) | {path: .path, line: .line, body: .body}'
```

If there are no review comments, skip to Step 3.

### 2b. Parse bugs and issues

From the review comments, identify actionable bugs and issues. Ignore:
- Style nitpicks and suggestions that are not bugs
- Comments that are purely informational
- Comments on code that is not part of this PR's changes

Focus on:
- Actual bugs flagged
- Security issues
- Logic errors
- Missing error handling that could cause crashes

### 2c. Check user exclusions

The user may specify bugs NOT to fix when invoking this skill (e.g. `/fix-pr skip US-033 skeleton issue`). If the user specified exclusions, match them against the identified issues and skip those.

Present the list of issues you plan to fix to the user before proceeding. Format:
```
Found N issues from Claude Code review:
1. [file:line] Description of issue
2. [file:line] Description of issue
   (skipped - user excluded)
3. [file:line] Description of issue

Fixing N issues...
```

### 2d. Fix the issues

Read each affected file, understand the context, and apply fixes. Follow the project's existing patterns and conventions (check CLAUDE.md).

---

## Step 3: Fix Failing CI Checks

### 3a. Fetch check status

```
gh pr checks {pr_number} --json name,state,conclusion
```

If all checks pass, skip to Step 4.

### 3b. Identify failures

For each failing check, determine the type from the CI workflow (`.github/workflows/ci.yml`):
- **lint**: `bunx biome ci .` — fix lint/format issues
- **typecheck**: `bunx tsc --noEmit` — fix type errors
- **test**: `bun run test` — fix failing tests
- **build**: `bun run build` — fix build errors
- **validate-i18n**: `bun run validate:i18n` — fix missing i18n keys

### 3c. Reproduce and fix locally

For each failing check, run the corresponding command locally to reproduce the error, then fix it:

1. **lint** failures: Run `bunx biome ci .` to see errors, then `bunx biome check --write .` to auto-fix what's possible. Manually fix the rest.
2. **typecheck** failures: Run the failing tsc command, read the errors, fix the type issues.
3. **test** failures: Run `bun run test` to see which tests fail, read the test files and source code, fix the issues.
4. **build** failures: Run `bun run build`, read the errors, fix them.
5. **validate-i18n** failures: Run `bun run validate:i18n`, add missing translation keys.

After fixing, re-run the same command to verify it passes before moving on.

---

## Step 4: Commit and Push

After all fixes are applied:

1. Stage the changed files (use specific file names, not `git add -A`)
2. Commit with a descriptive message following the repo's commit style:
   ```
   fix: address PR review feedback + fix CI failures

   - [describe each fix briefly]
   ```
3. Push to the current branch

---

## Important Notes

- Do NOT fix issues the user explicitly excluded
- Do NOT make unrelated changes or refactors while fixing
- If a review comment is ambiguous or you're unsure how to fix it, ask the user
- If a CI check failure is unrelated to this PR's changes (e.g. flaky test, pre-existing issue), tell the user rather than attempting a fix
- Always verify fixes locally before committing (re-run the failing command)
- If the Claude Code review hasn't posted yet (PR was just created), tell the user to wait and retry
