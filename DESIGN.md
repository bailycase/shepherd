# Shepherd design: the rules

The rules every UI change obeys, on the Mac and in the iPhone and iPad client. The spec of each
surface (and every board, with how much of it is built) is in [docs/design/](docs/design/README.md):
read only the part you need with `python3 scripts/design_section.py "<board or heading>"` (find a
board with `--boards | grep -i <word>`). [AGENTS.md](AGENTS.md) has the step-by-step procedure for
implementing a design.

## Precedence

The first of these that speaks wins:

1. **The design the user gives you in this thread**: an image, a board, a design reference, or
   words describing the change.
2. The design canvas's board, and its entry in the board index.
3. The surface's spec in `docs/design/`.
4. The rules in this file.

- This file and the specs never override a design the user just gave. If they disagree, build
  the design and update the spec in the same change, in the same commit. A UI decision changes
  the spec and the canvas together.
- If you build something that departs from a design, whether you could not match it or the code
  forces another shape, say so in your final message: each place, and why. A departure from a
  design is the user's call, never yours. Decided departures live in
  [docs/design/departures.md](docs/design/departures.md).
- A spec marked **Not built yet.** is a design for later: build it when asked, skip it otherwise.
- Every value lives in code. Tokens and shared components are in `Packages/ShepherdUI`; the
  Mac's own surface dimensions are in `Sources/ShepherdApp/AppLayout+<Domain>.swift`.

## What the app is for

Shepherd supervises agents, not chats: live `pi` processes you watch. Every decision has to
survive "does this help a person supervise ten working agents at once?"

- An agent has a short task title it gave itself (`Fix plan mode`), a workplace and a lifecycle
  (working, needs you, done, failed, idle). It renders only as a native thread.
- Terminals are tabs under a thread, one terminal per tab. No splits, no global shells.
- Copy says "the agent", never "pi", except where the user's own pi is the subject (Settings ▸ Pi).
- Missions and the Artifacts and Files tabs are not built: nothing shows or links to them.

## Principles, in priority order

1. **Readable measure.** The thread column is at most 820pt and agent prose 640pt.
2. **Shape, not labels.** No speaker labels or avatars: a user turn is a trailing bubble, agent
   output is unboxed prose.
3. **One quiet line per burst.** Consecutive calls of one kind merge into one activity line.
4. **Nothing in the thread spins.** One thing moves at a time, and it is text (live text shimmers).
5. **Nothing in the default view that isn't useful.** No key-hint rows, no repeated status text,
   no footers in menus, nothing under the composer but its controls.

The rules that follow:

- **Flat surfaces, 1px lines.** Surfaces step `bgBase` (chrome), `bgWindow` (thread), `bgRaised`
  (cards, composer, menus), `bgSunken` (code, headers). Separation is a hairline, never a shadow.
- **One shadow**, `.nwPopover()`: menus, palette, popovers, toasts. The sidebar and side pane
  borrow it (`.nwFloatShadow`) only while they float. No vibrancy, translucency or gradients.
- **Honest affordances.** Never draw a control that does nothing, a shortcut that isn't wired, or
  sample data in place of real data. Hide what is unsupported, or say why.
- **No permission model.** Never invent approval UI. A question from pi or an extension is a
  question, with the answers the asker offered.
- **Status is a dot or glyph plus a word.** `AgentState` colors every status surface; color is
  never the only signal.
- **Lantern means you.** Amber marks the primary action and what needs you. Running blue marks
  work in progress, links and keyboard focus.
- **The sidebar is the primary navigation**; the command palette is a secondary way to jump.
- **One primary action per surface.** A destructive action is never the ⏎ default.
- **Native controls, Night Watch styles.** A control is a Night Watch style on a native `Button`,
  `Toggle`, `Picker` or `TextField`; context menus are native `.contextMenu`. Shared views are
  `NW`-prefixed.

## Matching a design

- Draw what the design draws: every element in its order, with its copy, its glyph (symbol name
  and fill variant), and its size, spacing, radius and color as tokens.
- Draw every state it shows: rest, hover, pressed, focused, disabled, selected, loading, error,
  empty, in both appearances.
- Do not add an element the design lacks (a chip, a hint, a label), and do not drop one it has.
- Every control it draws does something. If the code cannot do it yet, say so in your final
  message instead of shipping a dead control.
- If a value has no token, use the nearest and list the difference; a new color is a theme role.
- Copy is the design's: sentence case in drawn UI, Title Case in native menus, "the agent" not
  "pi".

## Night Watch

Never hardcode a color, font size, dimension, duration or curve in a view. Use a shared ShepherdUI
component before hand-rolling chrome; a reusable part goes in `Packages/ShepherdUI` with a
`#Preview` in both appearances. Full detail: [theme](docs/design/theme.md),
[foundations](docs/design/foundations.md), [motion](docs/design/motion.md).

**Color** is `Color.nw.<role>`, dynamic per appearance (values in `NightWatch.swift`):

| Group | Roles and use |
| --- | --- |
| Surfaces | `bgBase` sidebar and chrome · `bgWindow` thread, toolbar, panes, dialogs · `bgRaised` cards, composer, menus, fields · `bgSunken` code, tool output, card headers · `bgBubble` user messages · `bgHover`, `bgSelected` |
| Lines | `lineSubtle` dividers and card borders · `lineStrong` control borders, popovers, composer |
| Text | `textPrimary` · `textSecondary` labels and previews · `textTertiary` meta, times, counts · `textOnLantern` |
| Brand and state | `lantern` (+`lanternText`, `lanternTint`) primary action, needs you · `running` (+Tint) work, links, focus · `done` (+Tint) · `failed` (+Tint) destructive |
| Syntax | `syn*` for code blocks and diffs |

- Views never branch on `colorScheme` for a color. A new color is a role on `ThemeColors`, filled
  in both variants of every theme, with a `NWPalette` property and a contrast rule if it has text.
- Borders and hovers are theme roles, never ad-hoc alphas. Status colors come from `AgentState`
  (`running`, `attention`, `done`, `failed`, `stuck`, `queued`, `idle`), never picked per view.
  Draw state with `NWStatusDot`, `NWStateGlyph` or `NWStatusPill`.

**Type**: Geist for prose and chrome, Geist Mono for anything the agent touched. `Font.nw(_:)` or
`.nwText(_:)` only (they follow Settings ▸ Appearance ▸ Text size on the Mac, Dynamic Type on iOS);
`Font.nwSans`/`nwMono` only for a size a board gives outside the ramp.

| Style | Mac | Use |
| --- | --- | --- |
| `display` · `title` · `headline` | 28/600 · 15/600 · 13.5/600 | onboarding (unused on the Mac) · dialog titles · card titles, headings |
| `body` · `ui` · `caption` | 13.5/400 · 12.5/500 · 11.5/400 | prose, bubbles, composer · rows, buttons · secondary info |
| `code` · `mono` · `micro` | Mono 12 · 11.5 · 10.5/500 | code, output · paths, commands · section labels, counts |

**Space** (`NW.Space`, 4pt grid): 2, 4, 6, 8, 12, 16, 24, 32; padding and gaps use only these.
**Radius** (`NW.Radius`): 4 pills, keycaps · 6 buttons, fields, rows, composer chips · 8 cards,
composer, code · 12 popovers, palette, drawn sheets. **Height** (`NW.Height`): rows 22 · 28 · 36 (scaled by
Density), controls 24 · 28 · 32 (never scaled), touch 44. Hairlines are 1px (`NWHairline`,
`.nwBorder`).

**Elevation**: `.nwCard()` flat (raised fill, 1px `lineSubtle`, radius 8); `.nwPopover()` (1px
`lineStrong`, radius 12, the only shadow). **Focus**: `.nwFocusRing()`, a 2pt `running` ring for
keyboard focus only; every custom control draws it after `.focusEffectDisabled()`.

**Icons**: SF Symbols only, monochrome, weight `.medium`, 13–16pt (14 in icon buttons), never
emoji. Use the exact symbol and fill variant the design shows (`bolt` is not `bolt.fill`,
`xmark` is not `xmark.circle`). The board's symbols are in
[foundations](docs/design/foundations.md#space-radius-height-elevation).

**Motion** is `NW.Motion` anchors, never a literal duration or curve in a view:

- `hover`, `content` 120ms · `disclosure`, `list`, `pane`, `overlay` 180ms · `sheet`, `emphasis`,
  `scroll` 240ms, all springs; `glow` 1.6s (attention only), `spin` 1s, `shimmer` 1.8s (live
  text only), `pulse` 1.4s.
- State a store changes: `.nwAnimation(_:value:)` and `.nwTransition` on the view. State an
  action changes: `withNWAnimation`. Never an ad-hoc `withAnimation`.
- Switching agents, keyboard navigation, selection, streaming text and terminal resizes land at
  once (`.nwInstant()`). Under Reduce Motion nothing travels: cross-fade in 120ms or stand still.
- Spinners and glows are Core Animation layers, never a view redrawn per frame.

**Density**: Settings ▸ Appearance sets sidebar row height (22 · 28 · 36) and a 80–150% Density
that scales row heights, not controls. Text size scales type only.

## Interaction and keyboard

- The keyboard is first-class and the fast path never needs a dialog. Every action is a menu-bar
  item; a chord lives in `KeybindingsStore` and nowhere else. Hardcoding a chord in a view is a
  bug, and a hint is never shown for a chord that isn't wired.
- A rebound chord must include ⌘ and avoid ⌘1–9, ⌘, and the plain system chords. A chord the app
  chrome uses must be in `appOwnedChords` so a focused Ghostty surface does not eat it.
- Keycaps (`NWKeycap`) put modifiers in Apple's order, ⌃⌥⇧⌘, one cap per key.
- ⏎ confirms and ⎋ cancels in a sheet; Esc closes a menu, then the command list, then stops pi
  while it works, and never stops pi while a question waits.
- Status events are banners inside the pane they concern, never a modal alert.

## Accessibility

- Every control is a real `Button`, `Toggle` or field, or carries button traits and an action.
  Icon-only buttons have an `accessibilityLabel`; a hover-only affordance is also reachable as a
  button or a named action. Rows read as one element ("title, running").
- Color is always paired with a word or a glyph shape; contrast rules are in
  [theme](docs/design/theme.md#contrast-rules) and hold in both appearances.
- Reduce Motion: see Motion. Mac type scales with Text size; iOS follows Dynamic Type and keeps
  44pt touch targets (`NW.Height.touch`).

## Performance

A list is as fast with three hundred rows as with thirty. Count budgets in
`ListPerformanceTests` pin each rule; add a budget with any new long list.

- Anything that can outgrow a screen is a lazy stack with stable ids.
- A lazy `ForEach` makes exactly one view per element: wrap an `if` or `switch` in a container.
- Rows are plain `Equatable` values; closures stay out of `==`; highlight and selection arrive
  as a `Bool`; hover lives in the row. Stores derive rows once per change, never in `body`.
- Hidden agents stay out of the visible one's updates (see AGENTS.md, switching is a flip).
- Motion no one sees costs nothing (`nwMotionPaused`); detail in
  [performance](docs/design/performance.md).

## Verifying visuals

1. Render the surface: `SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter <suite>`
   (`ThreadPreviewTests`, `NavigationPreviewTests`, `AgentsPreviewTests`, `ReviewPreviewTests`,
   `SettingsPreviewTests`, `DesignPreviewTests`, `PreviewTests`). It writes
   `<surface>-<light|dark>.png`. Add a new surface's render to its domain's suite.
2. Open the PNGs and look: both appearances, element by element against the design. List every
   difference and fix it.
3. Press each control the design draws, in a test, the way the app triggers it (its action or
   command), and check the state changes. A control that is not a real `Button` is a bug. Windows
   stay off-screen; never post mouse or keyboard events. Example: `ComposerMenuTests`, where
   `ComposerThread` opens each menu as the app does and reads the window's pixels.
4. Motion: record frames with `MotionProbe` and compare against the start and end states.
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
| Conversation goals | [thread.md](docs/design/thread.md#conversation-goal-card), [goals.md](docs/goals.md) |
| Thread, composer, queue, subagents | [thread.md](docs/design/thread.md), [composer.md](docs/design/composer.md), [queue.md](docs/design/queue.md), [subagents.md](docs/design/subagents.md) |
| Side pane, terminal, palette, dialogs | [side-pane-changes.md](docs/design/side-pane-changes.md), [side-pane-browser.md](docs/design/side-pane-browser.md), [terminal.md](docs/design/terminal.md), [dialogs-and-palette.md](docs/design/dialogs-and-palette.md) |
| Settings | [settings.md](docs/design/settings.md) and its `settings-*` files |
| Controls, status pieces, keyboard, accessibility | [components.md](docs/design/components.md), [keyboard-and-accessibility.md](docs/design/keyboard-and-accessibility.md) |
| iPhone or iPad | `ios-*.md` in [docs/design/](docs/design/README.md), and [docs/ios](docs/ios/README.md) |
| Notifications, Live Activities | [notifications.md](docs/design/notifications.md) |
| The Design tool | `design-tool*.md` in [docs/design/](docs/design/README.md) |
| Where the app departs from a board, or falls short | [departures.md](docs/design/departures.md), [known-gaps.md](docs/design/known-gaps.md) |
