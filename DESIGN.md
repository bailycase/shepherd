# Shepherd design: the rules

Every UI change on the Mac, iPhone and iPad follows these rules. Each surface's spec, and every
board with how much of it is built, lives in [docs/design/](docs/design/README.md). Print only the
part you need with `python3 scripts/design_section.py "<board or heading>"` (find a board with
`--boards | grep -i <word>`). [AGENTS.md](AGENTS.md) has the step-by-step procedure.

## Precedence

The first of these that speaks wins:

1. **The design the user gives you in this thread**: an image, a board, a design reference, or
   words describing the change.
2. The design canvas's board, saved in `docs/design/boards/` and listed in the board index.
3. The surface's spec in `docs/design/`.
4. The rules in this file.

- This file and the specs never override a design the user just gave. If they disagree, build
  the design and update the spec in the same commit.
- A departure from a design is the user's call, never yours. Name each one in your final
  message with the reason. Departures the user accepted live in
  [docs/design/departures.md](docs/design/departures.md).
- A spec marked **Not built yet.** is a design for later. Build it when asked.
- Every value lives in code. Tokens and shared components are in `Packages/ShepherdUI`. The
  Mac's own surface dimensions are in `Sources/ShepherdApp/AppLayout+<Domain>.swift`.

## What the app is for

Shepherd supervises agents. It is not a chat app: each thread is a live `pi` process you watch.
Every decision has to pass one test: does this help one person supervise ten working agents?

- An agent has a short task title it gave itself (`Fix plan mode`), a workplace, and a
  lifecycle: working, needs you, done, failed, idle. It renders only as a native thread.
- Terminals are tabs under a thread, one terminal per tab. No splits, no global shells.
- Copy says "the agent", never "pi". The exception is where the user's own pi is the subject
  (Settings ▸ Pi, Sign-in).
- Missions and the Artifacts and Files tabs are not built. Nothing shows or links to them.
- Goals are an experiment, off by default (Settings ▸ Experiments). They have no time or token
  budgets. Turning them off pauses active goals and never clears them. Turning them back on
  never resumes work by itself.

## Principles, in priority order

1. **Readable measure.** The thread column is at most 820pt wide and agent prose 640pt.
2. **Shape, not labels.** No speaker labels or avatars. A user turn is a trailing bubble; agent
   output is unboxed prose.
3. **One quiet line per burst.** Consecutive calls of one kind merge into one activity line.
4. **Nothing in the thread spins.** One thing moves at a time, and it is text (live text shimmers).
5. **Nothing in the default view that isn't useful.** No key-hint rows, no repeated status text,
   no footers in menus, nothing under the composer but its controls.

What follows from them:

- **Flat surfaces, 1px lines.** Surfaces step `bgBase` (chrome), `bgWindow` (thread),
  `bgRaised` (cards, composer, menus), `bgSunken` (code, headers). A hairline separates them,
  never a shadow.
- **One shadow**, `.nwPopover()`, for menus, palette, popovers and toasts. The sidebar and side
  pane borrow it (`.nwFloatShadow`) only while they float. No vibrancy, translucency or gradients.
- **Honest affordances.** Never draw a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Hide what is unsupported, or say why.
- **Keep the reader's position.** Growth and completion follow the tail only while the reader
  follows it. A live reply shrinking does not move a detached reader to the tail.
- **No permission model.** Agent tool calls open no approval UI, including cross-thread calls and
  deletion. Questions retain the answers the asker offered. There is no agent-to-agent permission
  row in Settings, and legacy permission choices have no effect.
- **Status is a dot or glyph plus a word.** `AgentState` colors every status surface. Color is
  never the only signal.
- **Lantern means you.** Amber marks the primary action and what needs you. Running blue marks
  work in progress, links and keyboard focus.
- **The sidebar is the primary navigation.** The command palette is a second way to jump.
- **One primary action per surface.** A destructive action is never the ⏎ default.
- **Native controls, Night Watch styles.** A control is a Night Watch style on a native
  `Button`, `Toggle`, `Picker` or `TextField`. Context menus are native `.contextMenu`. Shared
  views are `NW`-prefixed.

## Matching a design

- Draw what the design draws: every element in its order, with its copy, its glyph, its size,
  spacing, radius and color as tokens.
- Draw every state it shows (rest, hover, pressed, focused, disabled, selected, loading, error,
  empty) in both appearances.
- Don't add an element the design lacks, and don't drop one it has.
- Every control it draws does something. If the code can't do it yet, say so instead of
  shipping a dead control.
- A value with no token uses the nearest one, and you list the difference. A new color is a
  theme role.
- Copy is the design's: sentence case in drawn UI, Title Case in native menus.
- Render from the real data path. A preview built from the board's strings looks right and
  hides copy bugs.

## Settings

The macOS Settings board set (`docs/design/boards/Settings*.png`, `SignIn*.png`; page "macOS -
Settings", revision 1083) is the source of truth for every Settings page.

- **Navigation** is one flat list on `bgBase`, in the boards' order: Appearance, Terminal,
  Agents, Subagents, Worktrees, Projects, Sign-in, Pi, Instructions, Skills, Extensions, Slash
  commands, MCP servers, Remote, Keyboard, Advanced, Experiments. No nested rows. Sign-in
  carries a lantern dot while a sign-in needs the user. The footer reads
  "Shepherd x.y.z · agent x.y.z", and "· pi x.y.z" on Pi.
- **Pages** fill the width with 40pt side gutters. Each page has a Geist 22/600 title, one
  explanation line, then groups 28pt apart. A group has a caps label, a flat card (radius 10,
  1px `lineSubtle`), and an optional footnote.
- **Pi** is Shepherd's pi, then **From pi**: the source, what was brought over, the copies and
  the imported extensions.
- **Subagents** lists the definition files, then the native subagent switches and defaults.
- **Extensions** holds the bundled extension switches. Peer tools have no separate permission row.
- **Slash commands**: off disables a command entirely, in the menu and when typed.
- **Projects** reuses the shared MCP server cards, forms and OAuth sheet. Authentication runs on
  the selected host and opens the viewer's browser. Native MCP shows Pi's project approval apart
  from saved credentials, and asks for explicit confirmation of executable project resources
  before approving them on that host ([Project MCP](docs/design/project-mcp.md)).
- Local projects offer [Add child project](docs/design/child-projects.md) from Settings' existing
  Add subproject action and the sidebar project menu. The shared dialog creates an empty folder
  or registers an existing descendant. Child projects nest under their main project in the
  sidebar, with their threads indented again; parent collapse hides the whole group. Remove
  Project… confirms registration/session removal while preserving local folders and child projects.
  Rename Project… changes only the display name. Tool-driven parent edits change both project
  trees without changing folders or configuration inheritance; moving/copying data is explicit.
- Sliders show the bare number the board draws ("100", "232", "12.5"). VoiceOver reads the unit.

Detail: [settings.md](docs/design/settings.md) and its `settings-*` files.

## Night Watch

Never hardcode a color, font size, dimension, duration or curve in a view. Use a shared
ShepherdUI component before hand-rolling chrome. A reusable part goes in `Packages/ShepherdUI`
with a `#Preview` in both appearances. Full detail: [theme](docs/design/theme.md),
[foundations](docs/design/foundations.md), [motion](docs/design/motion.md).

**Color** is `Color.nw.<role>`, dynamic per appearance (values in `NightWatch.swift`):

| Group | Roles and use |
| --- | --- |
| Surfaces | `bgBase` sidebar and chrome · `bgWindow` thread, toolbar, panes, dialogs · `bgRaised` cards, composer, menus, fields · `bgSunken` code, tool output, card headers · `bgBubble` user messages · `bgHover`, `bgSelected` |
| Lines | `lineSubtle` dividers and card borders · `lineStrong` control borders, popovers, composer |
| Text | `textPrimary` · `textSecondary` labels and previews · `textTertiary` meta, times, counts · `textOnLantern` |
| Brand and state | `lantern` (+`lanternText`, `lanternTint`) primary action, needs you · `running` (+Tint) work, links, focus · `done` (+Tint) · `failed` (+Tint) destructive |
| Syntax | `syn*` for code blocks and diffs |

- Views never branch on `colorScheme` for a color. A new color is a role on `ThemeColors`,
  filled in both variants, with a `NWPalette` property and a contrast rule if it carries text.
- Borders and hovers are theme roles, never ad-hoc alphas. Status colors come from
  `AgentState`: `textColor` for the word, `color` for dots and glyphs, `tint` for the fill.
  Never apply `.opacity(…)` to a role. Draw state with `NWStatusDot`, `NWStateGlyph` or
  `NWStatusPill`.

**Type** is Geist for prose and chrome, and Geist Mono for anything the agent touched. Use only
`Font.nw(_:)` or `.nwText(_:)`, which follow Settings ▸ Appearance ▸ Text size on the Mac and
Dynamic Type on iOS. Use `Font.nwSans`/`nwMono` only for a size a board gives outside the ramp.

| Style | Mac | Use |
| --- | --- | --- |
| `display` · `title` · `headline` | 28/600 · 15/600 · 13.5/600 | onboarding · dialog titles · card titles, headings |
| `body` · `ui` · `caption` | 13.5/400 · 12.5/500 · 11.5/400 | prose, bubbles, composer · rows, buttons · secondary info |
| `code` · `mono` · `micro` | Mono 12 · 11.5 · 10.5/500 | code, output · paths, commands · section labels, counts |

**Space** (`NW.Space`, 4pt grid): 2, 4, 6, 8, 12, 16, 24, 32. **Radius** (`NW.Radius`): 4 pills
and keycaps · 6 buttons, fields, rows · 8 cards, composer, code · 12 popovers, palette, sheets.
**Height** (`NW.Height`): rows 22 · 28 · 36 (scaled by Density), controls 24 · 28 · 32 (never
scaled), touch 44. Hairlines are 1px (`NWHairline`, `.nwBorder`).

**Elevation**: `.nwCard()` is flat (raised fill, 1px `lineSubtle`, radius 8). `.nwPopover()` is
the only shadow. **Focus**: `.nwFocusRing()`, a 2pt `running` ring for keyboard focus only.

**Icons**: SF Symbols, monochrome, weight `.medium`, 13 to 16pt, never emoji. Use the exact
symbol and fill variant the design shows (`bolt` is not `bolt.fill`). Where a board draws its
own outline (Settings' nav), it ships as a vector in `NWGlyph.Settings`. A glyph more than one
view draws is an `NWGlyph` case. `DesignRulesTests` fails on a literal font size, a tinted
status color, a raw color, or a raw glyph name.

**Motion** uses `NW.Motion` anchors, never a literal duration or curve:

- `hover`, `content` 120ms · `disclosure`, `list`, `pane`, `overlay` 180ms · `sheet`,
  `emphasis`, `scroll` 240ms, all springs; `glow` 1.6s (attention only), `spin` 1s, `shimmer`
  1.8s (live text only), `pulse` 1.4s.
- A store-driven change uses `.nwAnimation(_:value:)` and `.nwTransition`. An action-driven
  change uses `withNWAnimation`. Never use an ad-hoc `withAnimation`.
- Switching agents, keyboard navigation, selection, streaming text and terminal resizes land at
  once (`.nwInstant()`). Under Reduce Motion nothing travels: cross-fade in 120ms or stand still.
- Spinners and glows are Core Animation layers, never a view redrawn every frame.

**Density**: Settings ▸ Appearance sets sidebar row height (22 · 28 · 36) and a Density of 80 to
150 that scales row heights, never controls. Text size scales type only.

## Interaction and keyboard

- The keyboard is first-class, and the fast path never needs a dialog. The workplace menu's ↑↓
  navigation includes its visible Base row, and Return opens the branch picker. Every action is a
  menu-bar item. A chord lives in `KeybindingsStore` and nowhere else. A hint is never shown
  for a chord that isn't wired.
- A rebound chord must include ⌘ and avoid ⌘1–9, ⌘, and the plain system chords. A chord the
  app chrome uses goes in `appOwnedChords`, so a focused Ghostty surface can't eat it.
- Keycaps (`NWKeycap`) put modifiers in Apple's order, ⌃⌥⇧⌘, one cap per key.
- In a sheet, ⏎ confirms and ⎋ cancels. Esc closes a menu, then the command list, then stops pi
  while it works. It never stops pi while a question waits.
- Status events are banners inside the pane they concern, never a modal alert.

## Accessibility

- Every control is a real `Button`, `Toggle` or field, or carries button traits and an action.
  Icon-only buttons have an `accessibilityLabel`. A hover-only affordance is also reachable as
  a button or a named action. Rows read as one element ("title, running").
- Color always comes with a word or a glyph shape. Contrast rules are in
  [theme](docs/design/theme.md#contrast-rules) and hold in both appearances.
- A value the design draws without its unit still reads with it ("100 percent").
- Mac type scales with Text size. iOS follows Dynamic Type and keeps 44pt touch targets.

## Performance

A list is as fast with three hundred rows as with thirty. Budgets in `ListPerformanceTests` pin
each rule. Add a budget with any new long list.

- Anything that can outgrow a screen is a lazy stack with stable ids.
- A lazy `ForEach` makes exactly one view per element. Wrap an `if` or `switch` in a container.
- Rows are plain `Equatable` values. Closures stay out of `==`, highlight and selection arrive as
  a `Bool`, and hover lives in the row. Stores derive rows once per change, never in `body`.
- Hidden agents stay out of the visible one's updates (switching is a visibility flip).
- Paging older thread rows completes pending native layout before measuring its viewport anchor.
- A cached visible bottom marker never overrides a following thread's measured gap from its tail.
  Cached current-row IDs require a live, nonhidden native row probe intersecting the Mac viewport;
  physical placement is not proof of compositor paint.
- Motion no one sees costs nothing (`nwMotionPaused`). Detail:
  [performance](docs/design/performance.md).

## Verifying visuals

1. Render the surface: `SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter <suite>`
   (`ThreadPreviewTests`, `NavigationPreviewTests`, `AgentsPreviewTests`, `ReviewPreviewTests`,
   `SettingsPreviewTests`, `DesignPreviewTests`, `PreviewTests`). It writes
   `<surface>-<light|dark>.png`. Drive it from the real producer, and cover each state, empty,
   long text and text scale 1.3 (`Preview.renderMatrix`).
2. Open the PNGs beside the design, both appearances, element by element. Fix every difference
   you can name.
3. Press each control the design draws with `ControlPress` (docs/testing.md › Pressing a
   control). Assert the request it sent, the state it left and its hit area.
4. Motion: record frames with `MotionProbe` and compare the start and end states.
5. Run the `Shepherd (Dev)` scheme and check the change in both appearances.

More: [docs/design/verifying.md](docs/design/verifying.md).

## Where the detail is

| You are changing | Read (`design_section.py "<name>"`) |
| --- | --- |
| Any surface | the board in [docs/design/README.md](docs/design/README.md) |
| Color, theme, AgentState, ShepherdUI tokens | [theme.md](docs/design/theme.md) |
| Type, space, radius, elevation, icons, density | [foundations.md](docs/design/foundations.md) |
| Animation, a transition, Reduce Motion | [motion.md](docs/design/motion.md) |
| A list, scroll or hot path | [performance.md](docs/design/performance.md) |
| Window, toolbar, sidebar, pages | [window-and-toolbar.md](docs/design/window-and-toolbar.md), [sidebar.md](docs/design/sidebar.md), [pages.md](docs/design/pages.md) |
| Conversation goals | [thread.md](docs/design/thread.md#goal-card), [goals.md](docs/goals.md) |
| Thread, composer, queue, subagents | [thread.md](docs/design/thread.md), [composer.md](docs/design/composer.md), [queue.md](docs/design/queue.md), [subagents.md](docs/design/subagents.md) |
| Side pane, terminal, palette, dialogs | [side-pane-changes.md](docs/design/side-pane-changes.md), [side-pane-browser.md](docs/design/side-pane-browser.md), [terminal.md](docs/design/terminal.md), [dialogs-and-palette.md](docs/design/dialogs-and-palette.md) |
| Settings | [settings.md](docs/design/settings.md), [settings-pi.md](docs/design/settings-pi.md), [settings-projects.md](docs/design/settings-projects.md), [settings-subagents.md](docs/design/settings-subagents.md), [codemode-settings.md](docs/design/codemode-settings.md) |
| Projects in Settings | [project-browser.md](docs/design/project-browser.md), [project-mcp.md](docs/design/project-mcp.md), [project-instructions.md](docs/design/project-instructions.md) |
| Controls, status pieces, keyboard, accessibility | [components.md](docs/design/components.md), [keyboard-and-accessibility.md](docs/design/keyboard-and-accessibility.md) |
| iPhone or iPad | `ios-*.md` in [docs/design/](docs/design/README.md), and [docs/ios](docs/ios/README.md) |
| Notifications, Live Activities | [notifications.md](docs/design/notifications.md) |
| The Design tool | `design-tool*.md` in [docs/design/](docs/design/README.md) |
| Where the app departs from a board, or falls short | [departures.md](docs/design/departures.md), [known-gaps.md](docs/design/known-gaps.md) |
