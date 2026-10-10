# Thread controls and worktree base

The user's words are the spec (no image): choose a new worktree's base branch, make the model
and thinking picker close when you click away, and make Send become Stop when the composer has
no input while the thread works. No new screens; each change is on the surface that exists.

## Checklist

**New worktree base** (New thread page, workplace menu `NWPlaceMenu`; New Worktree sheet)
- With New worktree on, for a project on this Mac, a **Base** row follows the switch: "Base" in
  `.ui` `textPrimary`, the branch in mono 11 `textTertiary` ("Default" until one is picked,
  truncating in the middle), a 10pt `chevron.right`. A host's project has no row; the host
  resolves its base.
- The row opens `WorktreeBasePicker`, the Changes pane's base picker (`NWChangesMenu`, 316pt):
  a "Search branches" field, "Branch from", then every branch (`arrow.triangle.branch`, mono,
  "default" and "worktree" tags, a check on the pick). The checked-out branch is listed.
  Reading: "Reading branches…". Esc returns to the workplace menu; choosing closes the menu.
- The switch's caption names the pick ("Keeps release clean. Merge it from Review.").
- Send branches from the pick, records it as the agent's base, and clears it. A pick of
  `origin/<branch>` follows Settings ▸ Worktrees ▸ Fetch before creating (a failed fetch leaves the
  cached ref); a local branch has nothing to fetch. The pick is kept whatever the fetch does. Changing the project clears it.
- New Worktree sheet: a "Choose…" link beside the Base field opens the same picker in a popover.

**Model settings and picker click-away** (thread, New thread, New design)
- A click anywhere outside the popover or its chip closes it, including in the field. A click on
  the chip toggles it; Attach, blank space in the control row and the field are outside. Esc and
  choosing behave as before. The slash and @ menus stay open for
  clicks in the field.

**Send and Stop** (Mac thread composer; iPhone and iPad thread composer)
- Working and nothing to send (no words, files, images, references or elements): the corner is
  Stop, a 28pt `failed` circle with `stop.fill`, "Stop". Working with input: Send, with the
  outlined Stop beside it on the Mac. Idle: Send, 35% until there is input.
- The iPhone and iPad header keeps its Stop (not redrawn).

States not drawn: a remote host's base chooser, Stop on the New thread page (no thread yet).

## Evidence

Renders from the real producers (`ThreadControlsPreviewTests`), in `docs/design/evidence/thread-controls/`:
Stop (`controls-working-empty-*`), Send beside outlined Stop (`controls-working-typed-*`), idle
(`controls-idle-light`), a long draft at text 1.3 (`controls-working-long-x1.3-dark`), the workplace
menu with a long picked branch (`worktree-place-picked-*`), the branch picker
(`worktree-base-picker-*`, the real picker over a scratch repository, a worktree-tagged branch picked), its
empty search (`worktree-base-picker-empty-x1.3-dark`) and the engine's refusal for a folder that is not a
repository (`worktree-base-picker-failed-x1.3-dark`).

## Remote hosts (not built)

`changesBranches` is an agent query: the host rejects it with `no_such_agent` for anything that
is not an existing agent (`SessionServer`, `agentQuery … where query.isChanges`), and a new thread
has none. `creationOptions(spaceID:cwd:fetchFirst:)` is space-scoped but answers one resolved base,
not a list. A base chooser for a host's project needs a new space-scoped, capability-gated query
(for example `changesBranches` by `spaceID`) answered by `ChangesService.branches(agentID: nil, cwd:)`,
which already runs without an agent. `createAgent` already carries `worktreeBase`, so creation needs
no change. This is a protocol change, so it waits for a decision.

## Mac Stop

The Mac composer swapped Stop and Send already. `ComposerActionAndDismissTests` drives the real
composer and store through a turn starting and ending, whitespace, words, an attachment and each
removed again, and reads the corner after every step: no stale button and no whitespace or
attachment mismatch reproduced. The test moves the store's real `running` through `refresh`, so it
exercises the actual transition, not only the predicate. There is no Mac defect to fix here; the
Mac behaviour is unchanged and correct, and only iOS changed. `store.running` holds true for 400ms after the host's turn ends
(`settleRunning`), so Stop can outlast the turn by that long, and Send takes the corner after it.
