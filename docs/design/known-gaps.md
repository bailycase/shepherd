# Known gaps

> Read when you finish a change that leaves the app short of its design: list the place here until it is fixed.

When a change leaves code breaking this document, list the place here until it is fixed toward
it. A sentence elsewhere that states a board's value and adds what the app does today ("the app
uses 6pt today"), or a paragraph marked **Not built yet**, is a gap in its own right; the list
below collects the rest, and the places those sentences point here.

- **Agents and review:**
  - A review from an older host (no `changes.v1`) keeps two scopes (Uncommitted and Pull request)
    and compares the working tree against HEAD, or the PR's merge base, the old way.
  - The Agents and Review components pad and space in 10pt where their boards do (the brief's
    vertical padding, the action bar, a comment's sides, the changes
    card's head, the toolbar's gaps, a file header's leading inset,
    `AppLayout.steerTopInset`), which is not a step on the space scale ("Padding and gaps use only
    these steps").
- **The Changes pane: open, waiting on the user's call** (not decided departures; each either
  gets built as its board draws it or becomes a departure once the user says so):
  - Mac: ⌘1–9 to jump
    to a file (ChangesStates), chords that select agents today; Rich preview (the engine sends no
    file contents).
  - iPad: the sidebar stays in landscape, so the docked pane is narrower than the board's 640pt;
    its toolbar drops "2/5 viewed", then the stat (`PadChangesToolbar`), and its head sits under
    the thread's bar rather than beside it.
  - iPhone and iPad, not built: a file head's Comment on the file and Open buttons; the base
    picker's "A commit…"; a commits range (touch has no ⇧); Rich preview and Open in your editor;
    a draft pull request from Commit… (`RemoteCommitOptions` has no draft).
  - A comment's author: the boards draw the initial "B"; the touch clients say "You".
- **Thread and terminal** (NWThread, TerminalSplit, TerminalPane, TerminalStates against the app):
  - The new terminal menu has no "New terminal on This Mac" for a remote thread (TerminalStates):
    a terminal of this Mac cannot join a layout its host owns. Waiting on the user's call.
  - Consecutive activity lines sit 6pt apart (`AppLayout.activitySpacing`), as NWThread draws
    them; ToolRows and Running draw 4pt.
  - The terminal font defaults to SF Mono 12.5 (`AppSettings`); the boards set Geist Mono 12 at
    1.6.
- **Sidebar and New thread** (NWNavigation, NavNewThread against `SidebarView.swift` and
  `NewThreadPage.swift`):
  - The New thread composer has no "/ commands" chip, and its placeholder drops ", or / for
    commands": no pi runs before the thread exists to list its commands. New design's composer
    (DZStart, NWDesignTool › Chat composer) leaves it out for the same reason.
- **iOS** (the phone and iPad boards against `App/iOS` and ShepherdUI's Fleet parts):
  - Row dots are 7pt (`NWListMetrics.dot`), the boards' 8 on iPhone.
  - iPhone user bubbles are the Mac's (`NWUserBubble`: at most 600pt, 10×14); the iPhone boards
    cap them at 300. The iPad thread spaces turns 24 and parts 12 (the space scale's steps)
    against the board's 26 and 14.
  - The iPad sidebar is the system split view's: its bar's Search and sidebar toggle are the
    system's glass buttons, and portrait's overlay, dimming and toggle are as the system draws
    them, not the board's rounded, shadowed panel. Its rows pad 12pt at radius 8 against the
    board's 10 and 10.
  - In landscape the sidebar stays beside the thread while the review docks, the subagent
    inspector opens, or the review goes full screen (`PadShell`); the boards hide it.
  - The iPad thread header's buttons are the system bar's glass buttons, in the app's lantern
    tint, where the boards draw plain `textPrimary` glyphs.

Deliberate exceptions stay with their rules rather than here: the layout's 1pt dividers, the
checkbox's 1.5pt border, and the strokes of status glyphs (see Hairlines), and one-off type
sizes outside the ramp, set with `Font.nwSans`/`Font.nwMono` (the boards' in Typography, and
the empty thread's path).
