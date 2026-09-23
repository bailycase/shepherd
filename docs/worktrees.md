# Worktrees

Shepherd runs agents in a space's checkout. When you want an agent isolated from that checkout,
Shepherd can create a git worktree for it, then later finalize it (commit, push, open a PR, clean
up) or delete it. These flows, plus the review pane's per-file Revert, are the only places
Shepherd changes a repository. It never prunes worktrees and never deletes a remote branch.

Code: `Sources/ShepherdApp/GitWorktree.swift` (create, resolve base, inspect, remove),
`NewWorktreeSheet.swift`, `NewAgentSheet.swift` (worktree option), `WorktreeFinalize.swift`
(setup checks and the finalize pipeline), `FinalizeWorktreeSheet.swift`,
`SettingsWorktrees.swift`, and `ShepherdViewModel+RemoteWorktrees.swift` (host side for remote
clients).

## Creating a worktree agent

There are two entry points:

- **New Worktree…** in a local space's context menu. It appears only when the space is a git
  repository. The sheet has three rows:
  - **Branch:** generated as `worktree/<adjective>-<noun>-<1000–9999>`, for example
    `worktree/calm-stone-3831`.
  - **Base:** an editable ref, pre-filled from the resolved base (below), with a note
    describing where it came from.
  - **Checkout:** a sibling of the repository, `<parent>/<repo>-<branch with / replaced by ->`.

  "Create and open" is disabled until the base resolves. The agent is named after the branch
  leaf (`calm-stone-3831`) until the namer gives it a real title. It is selected immediately.
- **The New Agent sheet's Worktree option.** It is available for a repository or a remote
  target. It adds a Base field, a "Fetch origin before creating" toggle, and a "Resolve base…"
  link. It uses the same base resolution.

**Import Existing Worktree…** (same context menu) adopts a worktree you already have. You pick
its directory, Shepherd checks that it belongs to the space's repository, and it creates an
agent there. No git command changes anything.

### Base resolution

A branch created with no start point starts at the checkout's `HEAD`. If the space's checkout
is on another agent's feature branch, that branch's commits leak into the new work and later
into its PR. Shepherd therefore resolves an explicit base (`GitWorktree.resolveBase`) according
to Settings ▸ Worktrees ▸ Base branch:

- **Remote default** (`fresh`, the default):
  1. Find the default branch with `git symbolic-ref --short refs/remotes/origin/HEAD`.
  2. If that fails and fetching is on, run `git remote set-head origin --auto` and try again.
     With fetching off (or if that still fails), use a local `origin/main` or `origin/master`.
     Fetching off never touches the network.
  3. With **Fetch before creating** on (the default), run `git fetch --quiet origin <default>`.
     The note reads "fetched just now". If the fetch fails, the cached `origin/<default>` is used
     and the note reads "cached — fetch failed". A failed fetch does not stop creation.
  4. With fetching off, the note reads "cached — fetch disabled in settings".
  5. With no `origin`, Shepherd falls back to the current branch and says so: "no origin —
     using the current branch".
- **Current branch** (`head`): the base is the checkout's current branch, for deliberately
  stacking on in-progress work.

The network commands (`fetch`, `set-head`) stop after 20 seconds (`GitWorktree.networkTimeout`),
and a timed-out fetch falls back to the cached ref like any failed fetch. `GIT_TERMINAL_PROMPT=0`
stops git from waiting on a credential prompt.

### The create command

```sh
git -C <repo> worktree add --no-track -b <branch> <checkout> <base>
```

- `--no-track` matters. Branching from `origin/main` would otherwise make `origin/main` the
  new branch's upstream, so an agent's bare `git push` would target `main`. Finalize publishes
  with `git push -u origin <branch>` instead.
- If you clear the Base field, the command has no start point and git uses `HEAD`.
- `-b` refuses to reuse an existing branch, and an existing checkout directory is an error.
  Shepherd never force-resets a branch.
- Every `GitWorktree` call runs `/usr/bin/git` by absolute path.

The base is stored on the agent as `Agent.worktreeBase` (`ShepherdCore`), alongside
`worktreeBranch` and, for imported worktrees, `worktreePath`. All three decode as nil from older
state files. The sidebar marks worktree agents with `⎇`.

## Finalizing

**Finalize Worktree…** is in a worktree agent's context menu. The sheet goes through these
phases: checking → setup (only if a check fails) → input → running → done or failed.

### Setup checks

`WorktreeSetupModel` runs its probes in a login shell (`/bin/zsh -l -c`, 20 s timeout,
`GIT_TERMINAL_PROMPT=0`, `GH_PROMPT_DISABLED=1`). They see the same `PATH` your terminal does.

| Row | Fails with | Remedy in the sheet |
| --- | --- | --- |
| Git installed | "git not found on PATH", or "Apple's Command Line Tools are not installed" | "Install command line tools…" (runs `xcode-select --install`) |
| Git identity | "git user.name / user.email are not set" | Name and email fields, then Apply (`git config --global`) |
| Origin reachable | the last line of `git ls-remote` stderr, or "origin remote missing or unreachable" when stderr is empty | Add an `origin` you can push to |
| GitHub CLI | "GitHub CLI not installed" | `brew install gh`, with a Copy button |
| GitHub CLI signed in | "not authenticated — run gh auth login" | "Open a terminal for gh login…" |

"Open a terminal for gh login…" closes the sheet. It then opens a terminal pane beside the
agent's thread, in the agent's directory, with `gh auth login` typed in. When everything
passes, the sheet shows "All set — ready to finalize" and enables Continue. "Re-run checks"
runs the probes again.

A separate "Recommended GitHub repo settings" section suggests auto-deleting merged branches and
allowing auto-merge. It is informational only and never blocks Continue.
[clean-mac-simulation.md](clean-mac-simulation.md) explains how to exercise every failing row.

### Input

- **PR base:** defaults to the recorded `worktreeBase` with `origin/` removed. Without one, it
  uses the default branch from `origin/HEAD`, or else `main`. This keeps a worktree based on a
  feature branch from opening a PR against the default branch.
- **Commit count:** the sheet shows "Will include N commit(s)", from
  `git rev-list --count origin/<base>..HEAD` (falling back to `<base>..HEAD`). The count turns
  warning-colored above 20, because an inflated count usually means the base is wrong.
- **Title and body:** with "Generate PR descriptions" on, pi drafts the body.
  `SHEPHERD_PR_DESCRIPTION_MODEL` overrides the model it uses.

### The pipeline

`WorktreeFinalize.swift` runs these steps in a login shell. Each step must succeed before the
next one starts.

1. **Commit:** skipped if the worktree is clean. If it is dirty and "Commit remaining work" is
   off, finalize stops and asks you to commit yourself. Otherwise it runs
   `git add -A && git commit`.
2. **Push:** `git push -u origin <branch>`.
3. **PR:** `gh pr create --head <branch> --base <base> --title … [--body …]`. The PR URL is
   recorded.
4. **Merge** (only with "Merge PR automatically" on, which is off by default): runs
   `gh pr merge --<method> --auto` first, then a direct merge as a fallback. The method is
   squash, merge, or rebase. If merging fails, the PR stays open and cleanup still runs.
5. **Clean gate:** `GitWorktree.unreconciledWork` must find nothing left. Otherwise finalize
   stops before any cleanup.
6. **Remove:** Shepherd first checks the checkout is not in use by anything other than this
   agent. Then it runs `git worktree remove <path>`, without `--force`.
7. **Delete local branch:** `git branch -D <branch>`, unless "Delete local branch" is off.

Nothing destructive happens before the clean gate. The remote branch is never deleted, because
deleting it would close the PR you just opened. GitHub's auto-delete-on-merge cleans it up
instead. A local finalize retires the agent when you press Done.

## Deleting a worktree agent

**Delete Worktree Agent…** opens a dialog showing the worktree and branch. Before it opens,
`GitWorktree.unreconciledWork` counts uncommitted changes and commits that exist on no other
branch or remote. Any such work is called out ("N uncommitted changes and M commits only on this
branch will be lost with the worktree"). You can choose:

- **Delete Agent, Keep Worktree:** retires the agent and leaves the checkout and branch alone.
- **Delete Agent & Worktree** (destructive, never the default):
  1. Checks the checkout is not in use elsewhere.
  2. Fingerprints its contents.
  3. Retires the agent and waits up to 10 s for its processes to exit.
  4. Checks the fingerprint again.
  5. Runs `git worktree remove --force <path>` and `git branch -D <branch>`.

## Remote clients

A remote Mac can create, finalize, and delete worktree agents on a host that advertises the
`agent.worktree.v1` and `agent.worktree.setup.v1` capabilities. Everything runs on the host with
the host's settings. The client sends `createAgent` (with `worktreeBranch`, `worktreeBase`,
`worktreeFetchFirst`), `creationOptions`, and `agentQuery` requests: `worktreeInfo`,
`worktreeSetup`, `worktreeCommitCount`, `worktreeDescription`, `finalizeWorktree`,
`deleteWorktree`, and `worktreeStatus`.

The host path differs from the local one in a few ways:

- **Stricter clean gate:** it fails closed and treats only commits missing from every remote as
  unreconciled.
- **Earlier retirement:** a remote finalize retires the agent before removing the worktree.
- **Explicit delete confirmation:** a remote delete with a warning requires an "I understand
  this work will be lost" toggle. The host re-verifies the warning and fingerprint.
- **gh login:** "Open a terminal for gh login…" opens a host-side utility terminal (a tab with
  `inspectorFor`, purged at the next startup) that the client views.

## Tests

Worktree behavior is covered by integration tests against `makeScratchRepo()` repositories
(`Tests/ShepherdTestSupport`). They cover branching from an explicit base with `--no-track`, base
resolution in both modes, finalize ordering and gating, and the remote setup actions. The
offline default-branch fallback is covered (`WorktreeBaseOfflineTests`); the fetch-failure
fallback is worth covering too. For the manual
setup-wizard pass, see [clean-mac-simulation.md](clean-mac-simulation.md).
