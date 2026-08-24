---
name: create-pr
description: Turn uncommitted changes in a working tree into a pull request - review the diff for bugs, write a clear commit, push the branch, and open a GitHub PR with a well-structured body and the good-fellow marker. Use when the user asks to create a PR, commit and open a pull request, or when another good-fellow skill has a finished fix to ship.
---

# Create PR

Helper skill: takes a working tree (usually a good-fellow worktree) with changes and
ships them as a PR. Read `docs/conventions.md` (repo root of this skill) and
`~/.good-fellow/instruction.md` first.

Inputs: the working tree path (default: current directory), and optionally the issue
number the change fixes.

## 1. Pre-flight

```bash
git status --porcelain
git branch --show-current
```

- Refuse to run on the repo's default branch or on a branch the user checked out in
  their own working tree — this skill only ships branches created per conventions §3
  (`good-fellow/*`) or the user's explicit current branch when invoked manually.
- Refuse only when there are neither working-tree changes nor local commits ahead of
  the target base. A resumed `fix-assigned-issues` worktree may be clean because its
  bounded handoff is stored as one or more unpublished logical checkpoint commits.

## 2. Self-review the diff

Read the full branch diff against the target base, plus working-tree and untracked
changes. Do not review only the last checkpoint commit. Check for: debug leftovers,
accidental file inclusions (lockfiles, secrets, editor junk), broken imports, logic
errors. Fix what you find. If a secret is committed or staged, stop and report — never
push it.

## 3. Commit

Group uncommitted changes into one commit (or a few logical ones) with a message in the
repository's existing style (`git log --oneline -15` to sample). Subject line explains
*why*, not just *what*. Preserve existing logical issue-checkpoint commits; if they are
WIP-quality rather than reviewable commits, stop instead of publishing them. Commit
only files related to the task.

This skill runs unattended, so satisfy the commit preconditions in conventions §6
first (identity resolvable, credential helper present) and **never invoke an editor** —
pass the message on the command line or from a file:

```bash
git -C <worktree> add <specific paths>
git -C <worktree> -c user.name="$GF_NAME" -c user.email="$GF_MAIL" commit -F <message-file>
```

Never a bare `git commit` (opens an editor) and never `git config` inside a worktree
(it rewrites the user's shared `.git/config`) — see conventions §6.

## 4. Push and open the PR

```bash
git push -u origin <branch>
gh pr create --title "<title>" --body-file <tmpfile> --base <default-branch>
```

Body structure (language per gist / repo norms):

- What & why — one short paragraph.
- Key changes — brief bullet list.
- How it was verified — tests run, or honest "not tested" note.
- `Fixes #<n>` when an issue number was given.
- The marker line: `<!-- good-fellow:v1 -->`.

No boilerplate beyond that; do not enable auto-merge; do not request reviewers unless
the gist says to.

## 5. Report

Return the PR URL and the commit SHA(s).
