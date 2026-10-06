# Keyboard and accessibility

> Read when you add a shortcut, a focus behavior, a VoiceOver label, or a Reduce Motion path.

## Keyboard

Keyboard is first-class, and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (`Keybindings.swift`; defaults in `ShortcutAction.defaultChord`, overrides
in UserDefaults under `shepherd.keybindings`).

- **One source:** menus, palette keycaps, Settings ▸ Keyboard, copy that names a chord
  (Settings ▸ Agents and Terminal), and the Ghostty unbind list all read the store. Hardcoding a
  chord in a view is a bug, and a hint is never shown for a chord that isn't wired.
- **Rules for a rebound chord:** it must include ⌘, except ⇧⇥ for Cycle thinking level in a
  focused composer. It must not use a digit (⌘1–9), must not
  be ⌘,, an app-switching chord (⌘⇥ or ⇧⌘⇥), or a plain ⌘ system or terminal chord
  (⌘Q, ⌘H, ⌘M, ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z), and must not be
  another action's chord.
- **Keycaps** (`NWKeycap`; Controls, Composer & menus): one cap per key, modifiers first in
  Apple's order (⌃⌥⇧⌘), each at least 18pt, mono 10.5 `textSecondary` on `bgRaised` with a
  `lineStrong` line (heavier along the bottom), radius 4, 3pt apart. Arrows and ↩ draw as
  glyphs. Settings ▸ Keyboard draws the same caps (the SettingsKeyboard board's 22pt caps are a
  full-window size; see Composer, questions, and menus).
- **Recording** (Settings ▸ Keyboard): a rebindable row's keycap is a button ("Click, then press
  the new shortcut"). While it records ("Press the new shortcut — ⎋ cancels"), one row at a
  time, the window's own shortcuts stand down and a key the app cannot bind beeps.
- **A rejected chord** says why under its row, in `failed`, led by the chord: "shortcuts must
  include ⌘ — plain keys belong to the terminal", "that chord is reserved (⌘1–9, ⌘, and
  system/terminal chords like ⌘Q ⌘C ⌘V)", or "already used by “<action>”".

| Default | Action |
| --- | --- |
| ⌘N · ⇧⌘T · ⇧⌘N | New thread (the page) · new agent with options… · new space… |
| ⌘R · ⇧⌘W | Rename agent · delete agent |
| ⌘K | Command palette |
| ⌘↓ · ⌘↑ | Next · previous agent in the sidebar (Needs you, Pinned, then Recents; organized by project, the open projects' threads) |
| ⌘D · ⌘W | New terminal (a new tab) · close terminal |
| ⇧⌘] · ⇧⌘[ | Next · previous terminal (tab), wrapping while the panel shows |
| ⌘J · ⇧⌘↩ | Show or hide the terminal panel, opening a terminal when there is none · maximize or restore it |
| ⇧⌘S · ⇧⌘B | Show or hide the sidebar · the side pane |
| ⇧⌘M | Model picker |
| ⇧⇥ | Cycle thinking level through the focused composer's offered choices, wrapping at the end; rebindable in Settings > Keyboard > Thread, no menu item or terminal unbind |
| ⌘. | Stop the agent |
| ⌥⌘↑ · ⌥⌘↓ | Previous · next turn |
| ⌘I | Inspect subagent |
| ⌘↩ | Steer now while pi works (↩ queues), and steer a focused queued message now; composer only, no menu item |
| ⌘L · ⇧⌘C | The Browser's address field · Select an element; while a thread's Browser is on screen, no menu item |

Fixed chords:

- ⌘1–9 select the first nine rows of Pinned, then Recents, in the order they are drawn (organized
  by project, the first nine threads of the open projects; hold ⌘ to see them). Pin and Unpin
  have no chord: they are in the row and thread menus and ⌘K. With the project tree focused, ← closes a project and →
  opens it; ⌥-click opens or closes every project. ⌃⇧1–9 jumped between the tree's
  machine sections and went with them: a focused terminal keeps them now.
- ⌃1 shows the side pane's Changes tab (View › Changes) and ⌃2 its Browser (View › Browser); ⌃3–⌃4
  wait for its other tabs. Settings ▸ Keyboard lists them under Fixed, and Ghostty leaves them to
  the app (`appOwnedChords`).
- ⌘, opens Settings, and ⌘F searches it.
- ⏎ confirms and ⎋ cancels in sheets. A sheet that asks to allow an agent to act
  (`PeerApprovalDialog`) has no ⏎ default, so a Return typed as it opens allows nothing; ⎋ is its Deny.
- In the composer, ↩ sends (while pi works, it queues or steers per Settings) and ⇧↩ or ⌥↩ inserts a
  newline. `/` at the start opens the command list, and Esc closes a menu, then the command list,
  then stops pi while it works.
- The queue's keys (`FixedChord`, listed with the send keys under Settings ▸ Keyboard ▸ While pi
  is working, `WhileWorkingKey`): ↑ in an empty composer edits the last queued message; ⌥↑ ⌥↓
  move the focused message and ⌫ deletes it.
- The composer's menus: ↑↓ move, ⏎ chooses, Esc closes, and ⇥ completes a slash command. The
  palette: ↑↓, ↩ runs, ⇥ cycles its scope, Esc closes.
- The question dock (QuestionStates › Keyboard): 1–9 pick an option (a yes or a no answers at
  once), ↩ answers, and Esc hides or shows the question, while its thread has the keyboard; never
  with ⌘, ⌃ or ⌥ held. Esc never stops pi while a question waits; ⌘. (Stop) refuses the question
  and stops the turn.

The Changes pane's keys are listed with the pane (Side pane › Changes).

## Accessibility and motion

- **Controls:** every control is a real `Button`, `Toggle`, or text field, or carries button
  traits and actions (sidebar rows are tap views, so a long list builds no focus-ring view per
  row). Icon-only buttons carry an `accessibilityLabel`, and hover-only affordances (a message's time
  and a turn's footer, a comment's Edit and Delete, a diff line's `+`) are always reachable as
  buttons or named actions for VoiceOver.
- **Rows read as one element:**
  - agent rows: "title, [worktree,] running / needs you / idle / done" ; automation rows: "name, automation, state"
  - activity lines: "Explored 7 files, read 5, search 2, 0.9s, done", with Expanded / Collapsed
    and the hint "Shows the calls"; the live line: "Pushing, git push origin main, running"; live
    thinking: "Thinking"; call rows: "edit, Sources/A.swift, +58 −41"
  - the subagent tray's header: "3 subagents, 1 running, 1 waiting on parent, 1 done"; its rows: "name,
    state, what it is doing" ("worker, Running, Editing NativeThreadPresentation.swift"), with
    Open and the run's controls as actions; the thread's record lines: "Started 3
    subagents, worker · reviewer · tests"
  - diff lines: "Removed line 16: …", with Comment as a named action; file chips: "FleetView.swift,
    modified, 10 added, 54 removed, viewed"
- **Resizing:** the sidebar edge and the side pane's handle are adjustable elements that read
  their width.
- **Modality:** the palette is modal for VoiceOver while it is up.
- **Color:** status color is always paired with a word or a glyph shape, and contrast follows the
  rules above.
- **Focus:** keyboard focus shows the running focus ring (2pt, 2pt outside the control); a click
  never does. Every Night Watch control style and custom control turns off the system's effect
  (`.focusEffectDisabled()`) and draws `.nwFocusRing()`; a control left in its system style
  keeps the system's ring (NWSwift).
- **Reduce Motion:** nothing moves (see Motion). The glow, spinners, and pulse are static, and
  live text is plain `textSecondary`;
  panes, sheets, overlays, and expanding or arriving rows cross-fade in place (120ms); rolling
  digits and symbol swaps cross-fade; pops, turn jumps, and scroll-to animations are dropped.
  Hover and content fades are unchanged.
- **Menu bar:** every terminal and agent action exists in the menu bar, with its shortcut where
  it has one (File, View, Terminal, Space, Agent, Machines, Appearance), so every action is reachable
  from the keyboard (NWSwift).
- **Text size:** the Mac's type doesn't follow Dynamic Type; it scales with Settings ▸
  Appearance ▸ Text size (85–130%). On iOS every style follows Dynamic Type (`relativeTo:`), and
  controls keep a 44pt hit area (`NW.Height.touch`) (NWFoundations, NWSwift).
- **Both appearances:** every component is checked in light and dark (its preview and the
  preview renders), and the contrast rules hold in both.
