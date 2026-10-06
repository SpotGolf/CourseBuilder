---
name: complete-branch
description: Use when the user asks to complete, finish, land, or squash merge the current feature branch. Commits everything on the branch, squash merges it to main with a conventional commit, pushes main, and deletes the branch.
---

# Complete Branch

Land the current feature branch on `main` and remove it.

Run every git command from the project root, `/Users/bpontarelli/dev/SpotGolf/SpotGolf`.

## Flow

```
feature branch ──commit all──▶ main: squash merge ──▶ push ──▶ delete branch
```

## Steps

### 1. Preflight

```bash
git branch --show-current
git fetch origin
git log --oneline main..HEAD
git diff --stat main...HEAD
git status --porcelain
```

- Stop if the current branch is `main`.
- Remember the branch name; every later step uses it as `<branch>`.
- Stop if the fetch fails. Report the blocked host per the sandbox rule.

### 2. Commit all changes on the branch

Skip this step if `git status --porcelain` printed nothing.

```bash
git add -A
git status --short
git commit -m "<conventional message>"
```

- `git add -A` stages every modified, deleted, and untracked file that `.gitignore` does not exclude. Do not skip files by hand.
- Use a conventional commit message that describes the uncommitted work.

### 3. Squash merge to main

```bash
git checkout main
git pull --ff-only origin main
git merge --squash <branch>
git status --short
```

- If `git pull --ff-only` fails, stop and report. Do not rebase or force anything.
- If the squash merge reports conflicts, run `git merge --abort`, `git checkout <branch>`, and stop. Report the conflicting files.

Commit with a conventional message written from the branch's commits and diff. Match the style of earlier commits on `main`:

```bash
git commit -F - <<'MSG'
<type>: <Imperative subject, capitalised, no trailing period>

- <What changed, from the user's point of view.>
- <One bullet per notable change.>

<BREAKING CHANGE: <what older builds can't read>, only for a breaking change>

Co-Authored-By: <the attribution line this session requires>
MSG
```

- `<type>` is `feat` for a new feature, `fix` for a bug fix, otherwise `chore`, `refactor`, `docs`, or `test`.
- Keep the subject line at 72 characters or fewer. Body lines have no limit.

### 4. Push main

```bash
git push origin main
```

If the push fails, stop and report. Do not delete the branch.

### 5. Delete the branch

```bash
git branch -D <branch>
git ls-remote --heads origin <branch>
```

- `-D` is required: after a squash merge, git does not see the branch as merged.
- If `git ls-remote` lists the branch, also run `git push origin --delete <branch>`.

### 6. Report

State the squash commit hash and that the branch was deleted. Nothing else.
