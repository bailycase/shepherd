# The Changes engine

The Changes pane (DESIGN.md › Review — the Changes pane; boards ChangesSplit, ChangesScope,
ChangesBase, ChangesUnified, ChangesLastTurn, ChangesWide, and the iPad and iPhone review boards)
draws what the host's engine computes. The engine is `ChangesService`
(`Sources/ShepherdSessions/Changes/`), owned by `SessionServer` as `server.changes`. The Mac calls
it directly; remote clients reach the same functions through `RemoteAgentQuery.changes*`, which
the server answers itself (no GUI hop), behind the `changes.v1` capability.

## Scopes

Every scope (`ChangesScope`) resolves to two git objects and a diff between them
(`ChangesRevision`, object ids only):

| Scope | Old | New | Title |
| --- | --- | --- | --- |
| Last turn / a turn | the working tree when pi started the run | the working tree when it settled (now, while it runs) | Last turn |
| Uncommitted | HEAD (the empty tree before the first commit) | the working tree | Uncommitted |
| Unstaged | the index | the working tree | Unstaged |
| Staged | HEAD | the index | Staged |
| Commits | `first`'s parent (the empty tree for a root) | `last` | Commit · a1c9f2e, Commits · 5d11a07–a1c9f2e |
| Branch | merge base of HEAD and the base | the working tree | Branch · vs main |
| Pull request | merge base of HEAD and the PR's base | HEAD | Pull request · vs main |

- **The working tree** is a tree object: `git add -A` then `git write-tree` against Shepherd's own
  index file for that working tree (`<support>/changes/index/<hash>`), seeded once from a copy of
  the user's index, so tracked-but-ignored files stay and git's stat cache makes the next snapshot
  re-read only what changed. Untracked files are included and ignored ones are not. Untracked files
  over 16 MiB stay out (`ChangesList.skipped`) so a stray dump never lands in `.git/objects`.
- **The index** is `git write-tree` on a throwaway copy of the user's index (write-tree writes the
  index file it reads). An index with unresolved conflicts has no tree: Staged and Unstaged say so.
- **The default base** is the agent's `worktreeBase`, else `origin/HEAD`, else
  origin/main, origin/master, main or master. A base picked in the picker joins the repository's
  recents (`<support>/changes/bases.json`).
- **The pull request** comes from `gh pr view` through a login shell, reused for 60 s. Without gh,
  a GitHub remote or a PR, the scope says so.
- **The default scope** (`ChangesOverview.defaultScope`) is Branch for a worktree agent (or a linked
  worktree) with a base, else Uncommitted. Opening on Last turn after the agent replies to a review
  is the pane's rule, not the engine's.

## Requests

| Local (`server.changes`) | Remote (`RemoteAgentQuery`) | Answer |
| --- | --- | --- |
| `overview(agentID:cwd:)` | `.changesOverview` | `ChangesOverview`: each scope's diffstat, the branch's commits (newest first, against `commitsBase`), the PR, the last turn, the default scope and base |
| `list(agentID:scope:options:cwd:)` | `.changesList(scope:options:)` | `ChangesList`: files with status letters and counts, totals, the compare row (`ChangesComparison`: head → base, the merge base, a turn's times and prompt), the revision, the title |
| `file(agentID:revision:path:oldPath:options:cwd:)` | `.changesFile(revision:path:oldPath:options:)` | `ChangesFileDiff`: the file's `DiffFile` from exactly that revision, cut at 20,000 lines (and, remotely, under the frame cap) with `truncated` |
| `diffs(agentID:revision:options:cwd:)` | — | every file's `DiffFile` at once (the Mac, which has no frame cap) |
| `branches(agentID:cwd:)` | `.changesBranches` | `ChangesBranches`: the default base, the PR's base, recents, every branch by last commit with worktrees tagged |
| `patch(agentID:revision:options:cwd:)` | `.changesPatch(revision:options:)` | a patch `git apply` takes, binary files included (Copy as patch, Copy git apply command) |
| `undoTurn` / `redoTurn(agentID:turnID:)` | `.changesUndoTurn` / `.changesRedoTurn(turnID:)` | the `ChangesTurn` after it |
| `turns(agentID:)` | `NativeThreadSnapshot.turnChanges` | the agent's recent turns, oldest first |

`cwd` reviews another directory than the agent's own (an agent's `review_diff` with a cwd); remote
clients cannot name one. Revisions must be object ids and bases plain names
(`ChangesService.isSafeName`), so nothing a client sends reaches git as an option.

A list is fetched first and a file's hunks when it is drawn, both against the list's revision:
what a file shows always belongs to the list on screen, however the working tree moved since.

**Options** (`ChangesOptions`): `ignoreWhitespace` (`git diff -w`; files whose only changes are
whitespace leave the list) and `fullFiles` (every unchanged line comes with the hunks, so folds
open without another request). Word diffs are no option to the engine: `DiffWords`
(`ShepherdProtocol`) computes them from the hunks — each run of removed lines pairs line for line
with the additions after it, the split view's pairing; a pair's tokens are diffed with Myers and
come back as UTF-16 ranges. Lines over 2,000 units or 500 tokens, pairs past 200 edits, and pairs
sharing under 30% of the shorter line get none. Whoever draws a file computes them once, off the
main thread; the wire never carries them.

## Turns

When pi starts a run (`agent_start`), the server records a turn and the engine snapshots the
agent's working tree; the first user message names it (pi's timestamp of that message, which the
thread's user message carries too, and its first line). When the run settles the engine snapshots
again and counts the files between the two trees. The records (`<support>/changes/turns.json`,
ten per agent, turns that changed nothing dropped unless newest) survive a relaunch; a turn still
running when Shepherd quit becomes unavailable. An agent outside a git repository records none.

The thread snapshot carries them (`turnChanges`, the first 20 files of each), so the "Edited N
files" card and its Undo arrive with the thread, locally and remotely. `changesTurn(forMessageAt:in:)`
finds a turn's record from its user message; `NativeTurnChanges(turn:)` makes the card.

A retry's second `agent_start` belongs to the same turn. A run the user steers into stays one turn.
Edits the user makes in their editor while the agent works are in the turn too: the snapshots
cannot tell who wrote a file.

### Undo and Redo

Undo (`undoTurn`) works on the last turn only, once it ended having changed something:

1. It diffs the turn's two trees without rename detection: each path added, modified or deleted.
2. It snapshots the working tree and compares those paths with the end of the turn. Any that
   changed since are named in a `changed_since` refusal, and nothing is touched.
3. Paths the start tree has are written back from it with `git restore --source=<start> --worktree`
   against a throwaway index (git's own filters and modes; the user's index is never used).
   Paths the turn created go to the Trash.

Nothing else moves: not the index, HEAD, refs, the stash, or any other file. Redo is the same
from the start tree to the end tree, until the next turn starts, and refuses when any of the
turn's files changed after the Undo. The card draws Undo without a dialog; Redo is what makes it
safe, and the refusal is what keeps it from overwriting anything the user wrote. The agent is not
told about an Undo or a Redo. (Both the user's call, 2026-09-25.)

## What it writes

- **In the repository:** loose objects in `.git/objects` (blobs and trees from snapshots), nothing
  else. They are unreachable, so `git gc` prunes them after its expiry (two weeks by default); a
  turn whose objects are gone becomes unavailable. Clean filters the repository configures (Git LFS)
  run as they do for `git add`, and may store their own objects.
- **In the working tree:** only Undo and Redo, as above.
- **In the support directory:** `changes/index/` (one index per working tree), `changes/turns.json`,
  `changes/bases.json`.

## Performance

git runs on the engine's own queues: never the server queue, never the main thread. Lists and
files are cached by the objects they ran between (an entry is never stale, only evicted), so a
repeated request while the working tree is unchanged costs one snapshot. A turn costs two
snapshots and one diff, on that agent's capture queue. The overview asks gh alongside the git work.

## Tests

- Unit: `DiffWordsTests`, `ChangesTests` (ShepherdProtocol), `ChangesParseTests` (git's output,
  names, Undo rules, truncation), `ChangesPresentationTests` (ShepherdRemote), and the round-trip
  tables and golden wire frame 20.
- Integration: `ChangesEngineTests` (every scope on scratch repositories, options, the base picker,
  a patch applied to a clone, and a proof that reading changes leaves the index, HEAD, refs, the
  stash, `.git` and every file alone) and `ChangesTurnTests` (the stub pi editing a repository: the
  turn, its card in the thread, Undo and Redo, the refusal, and the remote protocol).
