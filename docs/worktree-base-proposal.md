# Proposal: correct base selection for new worktrees

Status: **implemented** 2026-08-29 (plus Settings ▸ Worktrees pane: base mode fresh/head,
fetch toggle, finalize auto-commit toggle, delete-local-branch toggle) · research-backed
(3 research briefs + local reproduction)

## The incident

A worktree created from the `ms-mission-control-api` space produced a PR full of unrelated
files. Verified root cause, reproduced in a scratch repo:

- The space's primary checkout was sitting on `feat/mcp-oauth` (another agent's branch,
  2 commits ahead of `master`).
- `GitWorktree.add` runs `git worktree add -b <branch> <dest>` with **no start point**.
- git's documented default: *"If `<commit-ish>` is omitted, it defaults to `HEAD`"*
  ([git-worktree(1)](https://git-scm.com/docs/git-worktree)) — HEAD of the checkout the
  command runs in.
- So the worktree branch was born at `feat/mcp-oauth`'s tip; the PR against `master`
  contained all of mcp-oauth's commits plus the new work.

Scratch-repo reproduction: branch-from-HEAD → 2 unrelated commits ahead of `origin/master`;
branch-from-`origin/master` → 0. The bug is the base, not dirty files (`git worktree add`
never copies uncommitted changes).

## What the research found

**Herdr (the tool we mirrored) has this same bug, and its ecosystem treats it as one.**
Herdr hardcodes base `"HEAD"` in its create path (`src/app/worktrees.rs`,
`run_worktree_add_command(..., "HEAD", ...)`) and never fetches. Two third-party plugins
exist *solely* to fix it (`herdr-fresh-worktree`: "Start every new herdr worktree from the
latest `main` instead of a stale local base"; `herdr-worktree-seed`: "…since Herdr never
fetches on its own"), plus an open discussion complaining about base selection (#2755).
Copying Herdr's UX was right; copying its base semantics was copying a defect.

**The ecosystem converged on: fetch first, then branch from `origin/<default>`, degrade
gracefully.**

| Tool | Base | Fetch first |
| --- | --- | --- |
| Claude Code `--worktree` | `origin/<default>` ("fresh", the default) | Yes — if last fetch > 24h old, capped at 5s, falls back to cached ref |
| Conductor | `origin/<configured base>` | Yes, always ("a new workspace always starts from the latest remote commit, even if your local checkout is behind") |
| mvwi/wt | `origin/<base_branch>` | Yes, warn-and-continue on failure |
| leesangb/wt | per-repo base branch | Yes ("auto-fetch latest changes before creating") |
| Crystal, git-workers, Herdr | local refs / HEAD, no fetch | No — the bug-report generators |

**Claude Code's changelog is the cautionary tale for defaults**: it shipped
`origin/<default>` → users with unpushed local work complained (#39506, #54940) → flipped to
HEAD in v2.1.128 → fresh-base users complained → reverted in v2.1.133 and added a
`worktree.baseRef: fresh|head` setting. Both defaults are wrong for someone; the base must be
**visible and overridable** in the creation UI.

**Two more verified traps the fix must handle:**

1. **Tracking side effect** (reproduced locally; autowt shipped this bug as #106): branching
   from `origin/master` auto-sets *upstream = origin/master*
   (`branch.autoSetupMerge` default). An agent's bare `git push` inside the worktree then
   aims at master. Fix: `--no-track` ([git-worktree(1)]), and keep publishing with
   `push -u origin <branch>` as Finalize already does.
2. **`origin/HEAD` can be missing or stale** — it's optional, `remote add` doesn't create
   it, and only Git ≥ 2.48 creates it on fetch (never *updates* a stale one by default).
   Refresh with `git remote set-head origin --auto`
   ([git-remote(1)](https://git-scm.com/docs/git-remote), [Git 2.48 notes]).

**Downstream bug class to pre-empt** (Claude Code #48200, Crystal has it too): diff/PR views
that hardcode "compare against default branch" show unrelated commits when a worktree was
deliberately based on a feature branch. Antidote: **record the chosen base on the agent** and
default the Finalize PR base to it.

## Decision

Adopt the converged pattern, with Shepherd's own guardrails:

### 1. Base resolution (new worktree)

```
default branch  = git symbolic-ref refs/remotes/origin/HEAD
                  ?? git remote set-head origin --auto && retry   (network)
                  ?? current branch (last resort, disclosed in the UI)
fetch           = git fetch origin <default>       (time-capped; failure non-fatal →
                                                    cached origin/<default> + a note)
create          = git worktree add --no-track -b <branch> <dest> origin/<default>
```

### 2. The base is visible and overridable in the New Worktree sheet

A `base` row under `branch`/`checkout`, defaulting to `origin/<default>` and showing
freshness ("fetched just now" / "cached — fetch failed"). Options:

- `origin/<default>` — the default ("start clean from the remote")
- current branch (`feat/mcp-oauth`) — the Claude-Code-"head" constituency: stacking on
  in-progress work *deliberately*
- free-text ref — the `develop`-based-flow constituency (Claude Code #23622)

Had this row existed, the incident would have been visible before creation: the dialog would
have read `base: origin/master`, not silently inherited `feat/mcp-oauth`.

### 3. Record the base; Finalize uses it

- `Agent.worktreeBase: String?` (same decode-nil pattern as `worktreeBranch`).
- Finalize's PR `base` field defaults to the recorded base's branch name instead of
  re-guessing `origin/HEAD`.
- Finalize's input phase shows **what the PR will contain**:
  `git rev-list --count <base>..<branch>` + the first few subjects. An inflated count is the
  last-chance tripwire for a wrong base — the incident's PR would have announced "12 commits"
  instead of the expected 1–2.

### 4. New Agent sheet worktree option

Same resolution applies (it has the same bug today). The sheet's worktree row gains no new
UI; it silently uses fetch + `origin/<default>` + `--no-track`, since its branch field is
already user-authored.

## Non-goals

- No auto-rebase/fast-forward of existing worktrees (sandcastle's reuse pattern) — Shepherd
  creates fresh worktrees; reuse isn't a flow we have.
- No per-project base setting yet — the per-creation row covers it; add persistence only if
  the same override keeps being typed (YAGNI).
- Never `-B` / force-reset an existing branch; `-b` refusal stays a hard error.

## Test plan

- Scratch-repo tests (extend `GitWorktreeTests`): primary checkout on a feature branch →
  worktree created with resolved base is 0 ahead of `origin/<default>`; `--no-track` leaves
  no `branch.<name>.merge`; fetch-failure path falls back to cached ref and still creates.
- `origin/HEAD` missing → `set-head --auto` path resolves it (bare-remote fixture).
- Finalize commit-count preview shows `rev-list --count` of base..branch.
- Manual: recreate the incident (checkout on a feature branch, New Worktree with default
  base) → PR contains only the worktree's own commits.

## Sources

- git-worktree(1), git-branch(1), git-remote(1), git-ls-remote(1), Git 2.48 release notes —
  primary semantics (HEAD default, --no-track, set-head --auto, followRemoteHEAD)
- herdrdev/herdr source (`src/app/worktrees.rs`, `src/worktree.rs`), herdr.dev docs,
  discussions #2755, plugins herdr-fresh-worktree / herdr-worktree-seed — Herdr's HEAD base
  and its documented pain
- code.claude.com/docs/en/worktrees + anthropics/claude-code #23622 #39506 #45316 #48200
  #54940 #60588 — fetch policy, the fresh/head whiplash, diff-base bug class
- conductor.build docs (workspaces-and-branches), mvwi/wt source, autowt docs + changelog
  (#71, #106), stravu/crystal source — prior-art base/fetch/tracking behavior
- Local reproduction on this machine (scratch repos + the actual ms-mission-control-api
  state), 2026-08-29
