# Mental model and principles

> Read when you weigh a UI decision: what the app is for, and the principles in priority order.

## Mental model: agents, not chats

Shepherd organizes work around **agents**, not chats: live workers you supervise. An agent is a
`pi --mode rpc` process with:

- a title it gives itself
- a workplace (a space's checkout, or a worktree of it)
- a lifecycle: working, blocked on you, done (or failed, when its last turn ended in an error),
  idle

Every agent renders as a native **thread** (Main, Running): the toolbar over it, the transcript
with its subagent cards, and the composer pinned under it, with questions inside the composer
and Up next above it. The UI's job is supervision: *which of my workers needs me right now, and
what did it just do?* The sidebar leads with status, and selecting an agent opens its thread.
Every UI decision should survive the question "does this help a person supervise ten working
agents at once?"

- **Names:** agents name themselves with a short task title (`Fix plan mode`), never a persona or
  a sentence. A hand-typed rename is final.
- **Spaces** are projects: the folders threads start in, listed by the New thread page's
  workplace chip. A space has no view of its own, and the sidebar does not group by it.
- **Remote hosts:** another Mac serving its agents joins the same sidebar lists (its threads
  wear its name as a tag), with the same rows and the same thread.
- **Terminals** exist only as tabs of an agent's terminal panel, one terminal per tab, shown under
  its thread: the user opens one with ⌘D, ⌘J (when the thread has none) or the panel's +, or an
  agent opens one with its `terminal_*` tools. There are no splits, no global shells, no space
  shell workspaces, no agent rendered as a terminal, and no Terminal/Native switch.
- **Words:** an agent's conversation is its *thread*, made of *turns* (yours and the agent's)
  and *messages* (Main, Running: "Copy response", "Retry turn").
- **The agent, not pi:** copy calls the process it supervises "the agent" or "Agent" ("Agent is
  asking", "Goes when the agent finishes this turn", "the agent's session file"), and a version
  shown to people reads "agent 0.87.1". pi appears where the user's own pi is the subject:
  the Settings ▸ Pi pages (with the Settings footer's "pi 0.87.1" while one is open) and their
  items in the settings navigation, the real `~/.pi/…` paths on Settings ▸ Instructions, the
  first launch's sheet (Dialogs and sheets › Bringing over your pi) and the sign-in sheet, which
  have to tell the user that the pi in their terminal is untouched, and the two lines a restored
  agent shows about it ("It picks up once your pi is brought over", "…skipped when your pi came
  over"). Code, logs, command lines, extension prompts, and these docs still name pi, the
  program.
- **Not built yet, hidden until built.** The boards give the sidebar two more destinations,
  **Missions** (one map from a goal to merged pull requests, across every repository it touches)
  and **Designs** (HTML mockups on a canvas, drawn and refined with a design agent). The Missions
  and Design tool boards specify them; until they exist, nothing shows or links to them (the
  user's decision, 2026-09-25: "Hide them (Recommended)").

## Principles

In priority order:

1. **Readable measure.** The thread column is at most 820pt, and agent prose is capped at 640pt.
2. **Shape, not labels.** There are no speaker labels or avatars. A user turn is a trailing
   bubble; agent output is unboxed prose.
3. **One quiet line per burst of work.** Consecutive calls of one kind merge into one line
   ("Explored 7 files · read 5 · search 2", "Edited 3 files · +67 −46", "Ran tests · swift test ·
   3 failed"), instead of a card per call; a line expands to its calls, and raw arguments are
   behind ⌥-click (ToolRows).
4. **Nothing in the thread spins.** While pi works, one thing moves at a time, and it is text:
   the running tool's own line, or "Thinking…" between tools, shimmers; a reply being written is
   its own indicator (LiveText).
5. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats what the thread and the sidebar row already say, no footers in menus, and nothing
   under the composer but its controls: no working directory, no hints (NWSwift).

And the rules that follow from them:

- **Flat surfaces separated by 1px lines.** Surfaces step from `bgBase` (chrome) to `bgWindow`
  (the thread) to `bgRaised` (cards, the composer, menus), with `bgSunken` for code and headers.
  Separation is a hairline, never a shadow.
- **One shadow.** `.nwPopover()` (menus, the palette, popovers) carries the system's only
  shadow. The sidebar and the side pane borrow it (`.nwFloatShadow(_:)`) only while they float
  over the window, and the switch and slider knobs have a small knob shadow. No vibrancy, no
  translucency, no gradients except the fade above the composer.
- **Honest affordances.** Never show a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Hide unsupported capabilities, or explain them.
- **No permission model.** Shepherd never invents approval UI for what an agent runs, and
  ShepherdUI has no permission or approval component (NWSwift). When pi or an extension asks a
  question, show it as a question with the answers the asker offered. The one approval Shepherd
  asks is for an agent acting on another thread, which the user decided (2026-10-01): the app
  composes `PeerApprovalDialog` and `PeerDeleteDialog` from the shared dialog components
  (Dialogs and sheets, Departures).
- **Status is a dot or glyph plus a word.** One enum, `AgentState`, colors every status surface,
  and color is never the only signal for an actionable state.
- **Lantern means you.** The brand amber marks the primary action and anything that needs you.
  Running blue marks work in progress, links, and keyboard focus.
- **The sidebar is the primary navigation.** The command palette is a secondary jump
  surface and never the only way to reach something.
- **One primary action per surface.** A destructive action is never the ⏎ default.
- **Native controls, Night Watch styles.** A control is a Night Watch style on a native
  `Button`, `Toggle`, `Picker`, or `TextField`, so accessibility and keyboard behavior come for
  free. Where SwiftUI has no custom style (segmented, popup, slider, stepper), it is a view that
  presents itself to accessibility as the native control. Context menus are native
  `.contextMenu`. Every shared view is `NW`-prefixed, so it never collides with a system view
  (NWSwift; see Building on ShepherdUI).
