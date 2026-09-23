# Shepherd design

This document is the authority on how Shepherd looks and behaves on macOS. Where anything
disagrees with it, this document wins. It describes **Night Watch**, Shepherd's design system,
as the app implements it: the design boards (Foundations, Controls, Status & feedback,
Navigation, Thread, Composer & menus, Agents & orchestration, Review, and Swift implementation)
condensed, plus the places Shepherd deliberately departs from them.

Every value lives in code, and this document names the code so you can check it:

- **Tokens and shared components:** the ShepherdUI package (`Packages/ShepherdUI`, module
  `ShepherdUI`).
- **The Mac app's own surface dimensions:** `AppLayout`, split by domain into
  `Sources/ShepherdApp/AppLayout+<Domain>.swift`.

The older design handoff in [`docs/design-spec/`](docs/design-spec/handoff.md) is superseded by
this document and kept only as history.

## Mental model: agents, not chats

Shepherd organizes work around **agents**, not chats: live workers you supervise. An agent is a
`pi --mode rpc` process with:

- a title it gives itself
- a workplace (a space's checkout, or a worktree of it)
- a lifecycle: working, blocked on you, done, idle

Every agent renders as a native **thread**: transcript, composer, questions, subagents. The UI's
job is supervision: *which of my workers needs me right now, and what did it just do?* The
sidebar leads with status, and selecting an agent opens its thread. Every UI decision should
survive the question "does this help a person supervise ten working agents at once?"

- **Names:** agents name themselves with a short task title (`Fix plan mode`), never a persona or
  a sentence. A hand-typed rename is final.
- **Spaces** are project folders that group agents in the sidebar. A space has no view of its
  own.
- **Remote hosts:** another Mac serving its agents is a section of the same sidebar, with the
  same rows and the same thread.
- **Terminals** exist only as panes beside a thread: the user opens one with ⌘D, or an agent
  opens one with its `pane_*` tools. There are no global shells, no space shell workspaces, no
  agent rendered as a terminal, and no Terminal/Native switch.

## Principles

In priority order:

1. **Readable measure.** The thread column is at most 760pt, and agent prose is capped at 640pt.
2. **Shape, not labels.** There are no speaker labels or avatars. A user turn is a trailing
   bubble; agent output is unboxed prose.
3. **One quiet line per burst of work.** Consecutive tool calls of one kind merge into one
   activity line ("Explored 7 files · read 5 · search 2 · 0.9s"). Detail is one click away; raw
   arguments are behind ⌥-click.
4. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats the toolbar pill, no working directory under the composer, no footers in menus.

And the rules that follow from them:

- **Flat surfaces separated by 1px lines.** Surfaces step from `bgBase` (chrome) to `bgWindow`
  (the thread) to `bgRaised` (cards, the composer, menus), with `bgSunken` for code and headers.
  Separation is a hairline, never a shadow.
- **One shadow.** `.nwPopover()` (menus, the palette, popovers) carries the system's only
  shadow. The sidebar and the right pane borrow it only while they float over the window, and
  the switch and slider knobs have a small knob shadow. No vibrancy, no translucency, no
  gradients except the fade above the composer.
- **Honest affordances.** Never show a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Hide unsupported capabilities, or explain them.
- **No permission model.** Shepherd never invents approval UI. When pi or an extension asks a
  question, show it as a question with the answers the asker offered.
- **Status is a dot or glyph plus a word.** One enum, `AgentState`, colors every status surface,
  and color is never the only signal for an actionable state.
- **Lantern means you.** The brand amber marks the primary action and anything that needs you.
  Running blue marks work in progress, links, and keyboard focus.
- **The sidebar tree is the primary navigation.** The command palette is a secondary jump
  surface and never the only way to reach something.
- **One primary action per surface.** A destructive action is never the ⏎ default.

## Where Shepherd departs from the boards

| Board | Shepherd | Why |
| --- | --- | --- |
| Minimum window 1100×700 | **720×600**, with adaptive rules (the sidebar and the right pane overlay below their fit points) | Decided with the resizability review |
| Sidebar 232pt with 28pt rows, shrinking to a 184pt compact form with 24pt rows while a right pane is open | 232pt by default, resizable (190–340, persisted), and it **keeps its width** when a right pane opens. Rows follow Settings ▸ Appearance ▸ Sidebar rows (22 · 28 · 36) and Density | Shrinking on every pane toggle made the window jump; the row height is configurable by decision |
| Thread column at most 820pt | **760pt**, with the board's 640pt prose measure | The column kept from the earlier handoff |
| Colors as asset-catalog colorsets | A runtime theme model: `ThemeDefinition` is data (hex, `Codable`), resolved into `Color.nw` | User themes later; the roles are the contract |
| Fonts through `ATSApplicationFontsPath` / `UIAppFonts` | Registered from the package bundle at launch (`NWFonts.register()`), no Info.plist entry | ShepherdUI is a package, not an app target |
| A `ShepherdDesign` package | `Packages/ShepherdUI` | Name |
| `NavigationSplitView` with `.inspector` for the right pane | Shepherd lays the window out itself (`RootView`, `RightPaneSplit`) | Its own adaptive rules (`ShellLayout`) decide what docks and what overlays |
| Running sidebar rows draw a sparkline | Running rows show elapsed time; `NWSparkline` exists but nothing uses it | Nothing records an agent's tool calls per minute |
| A queued follow-up has Edit and Send now | The queued bubble shows no actions | Honest affordances |
| Background events as in-app toasts (`.nwToast`) | A system notification when an agent finishes a turn or asks a question while you aren't watching it (`AgentNotifications`) | Reaches you outside the app |
| Missions, the mission graph, the attention inbox, evidence review (Lab boards) | Not built | Out of scope for this pass |
| ⌘M opens the model picker (earlier handoff) | **⇧⌘M** | ⌘M is the system Minimize chord |

Additions the boards don't have:

- The composer's **delivery chip** (Follow-up / Steer), shown while a turn runs with a draft,
  because pi supports both.
- **Transcript search** in the palette ("Found in conversations").
- A **quit confirmation** while agents are working.

## Theme model

All design values live in **ShepherdUI**. It is SwiftUI only and holds no app state. Views
read colors from `Color.nw`, fonts from `Font.nw(_:)`, and sizes from `NW.Space`, `NW.Radius`,
and `NW.Height`, plus the app's own surface dimensions in `AppLayout`. **Never hardcode a color,
font size, or dimension in a view.**

A theme is pure data (`ThemeDefinition`: hex strings, `Codable`), so the built-in theme and
future user themes go through the same model:

```text
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors:   ThemeColors     // the Night Watch roles below (#RRGGBB or #RRGGBBAA)
                  syntax:   SyntaxColors    // code blocks and diffs
                  terminal: TerminalColors  // Ghostty: background, foreground, cursor, selection, 16-color ANSI
                  pi:       PiColors }      // pi's TUI theme schema, for pi run by hand in a terminal pane
```

- **`ThemeStore.shared`** (`@Observable`) holds the selected theme, the text scale, and the
  density. It resolves each theme once into an immutable `NWPalette` (every `Color` built when
  the theme changes) and each text scale into an `NWTypeRamp`, so a token read is a
  stored-property load.
- **Colors are dynamic:** every palette color resolves against the appearance of the view
  drawing it, so light and dark are never stored and never need a re-render.
- **`ThemeManager`** (app) owns only the appearance mode: System, Light, or Dark, set in
  Settings ▸ Appearance or the Appearance menu. `SHEPHERD_THEME=night-watch-dark` or
  `night-watch-light` forces one at launch (the older `shepherd-dark` still means dark), and
  Reset returns to it.
- **What `ThemeManager` pushes:** the resolved variant goes to what cannot follow appearance on
  its own. That is Ghostty surfaces (a live `setTheme`, never a remount or replay) and the pi
  theme file plus the `shepherd-active-theme` variant marker (`night-watch-dark|light`), which pi
  and editors run in a terminal pane watch. The marker's spelling is an external contract.
- **Fonts:** Geist and Geist Mono (SIL OFL, `Resources/Fonts/OFL.txt`) ship in the package
  bundle and are registered for the process at launch (`NWFonts.register()`). Terminal panes keep
  their own font setting.

### Roles (`ThemeColors`, read as `Color.nw.<role>`)

Values are `NightWatch.swift`'s, dark · light. Translucent roles are `#RRGGBBAA`.

| Group | Role | Dark | Light | Use |
| --- | --- | --- | --- | --- |
| Surfaces | `bgBase` | `#0a0b0c` | `#f2f2f0` | Sidebar, window chrome, Settings nav, the review's file strip |
| | `bgWindow` | `#0d0e10` | `#fbfbfa` | Thread, toolbar, panes, terminal panes, dialogs |
| | `bgRaised` | `#15171a` | `#ffffff` | Cards, the composer, menus, fields |
| | `bgSunken` | `#111316` | `#f5f5f3` | Code, tool output, card headers, the segmented track |
| | `bgBubble` | `#1a1d21` | `#efefec` | User messages |
| | `bgHover` | `#ffffff0b` | `#0000000a` | Row hover |
| | `bgSelected` | `#ffffff14` | `#00000011` | Selected row, the composer's focus ring |
| Lines | `lineSubtle` | `#1f2226` | `#e7e7e3` | Dividers, row separators, card borders |
| | `lineStrong` | `#2c3035` | `#d6d6d1` | Control borders, popovers, the composer |
| Text | `textPrimary` | `#e8e9ec` | `#151618` | Body, titles |
| | `textSecondary` | `#9aa0a9` | `#5f636b` | Labels, previews, descriptions |
| | `textTertiary` | `#5f656e` | `#9a9ea5` | Meta, timestamps, counts, section labels |
| | `textOnLantern` | `#17120a` | `#1a1206` | Text on a lantern fill |
| Brand and state | `lantern` | `#f2a93b` | `#e39a26` | Brand, the primary action, needs you |
| | `lanternText` | `#f7c16e` | `#945b00` | Lantern words on a tint ("ASK", "Needs you") |
| | `lanternTint` | `#f2a93b21` | `#d98a1221` | Needs-you backgrounds |
| | `running` | `#7aa7ff` | `#2f6fe0` | Running, links, focus |
| | `runningTint` | `#7aa7ff21` | `#2f6fe01a` | Running pills, menu and palette highlight |
| | `done` | `#46c37b` | `#1f9d5b` | Success, additions |
| | `doneTint` | `#46c37b1f` | `#1f9d5b1a` | Done pills, added lines |
| | `failed` | `#f0625e` | `#d9443f` | Failure, deletions, destructive |
| | `failedTint` | `#f0625e1f` | `#d9443f17` | Failed pills, removed lines, turn errors |
| Syntax (`SyntaxColors`) | `synKeyword` | `#d7a6ff` | `#8a3fb5` | Keywords |
| | `synType` | `#7ee0b5` | `#1a7f55` | Types |
| | `synString` | `#e8c07a` | `#9a6400` | Strings |
| | `synNumber` | `#9ec2ff` | `#2f6fe0` | Numbers |
| | `synFunction` | `#8fc1ff` | `#2a62c9` | Calls |
| | `synComment` | `#5f656e` | `#9a9ea5` | Comments |
| | `synVariable`, `synOperator`, `synPunctuation` | `#e8e9ec`, `#9aa0a9`, `#9aa0a9` | `#151618`, `#5f636b`, `#5f636b` | Names and punctuation (the text colors) |

**Derived colors** live on `NWPalette`, not in the theme:

- `focusRing`: running at 60% (dark) / 50% (light)
- `popoverShadow`: `.nwPopover()`'s shadow
- `scrim`: black at 30% in both appearances, behind the command palette
- `textOnFailed`: white, for labels on a `failed` fill
- `knobOn`, `knobOff`, `knobShadow`: the switch and slider knobs

**The terminal and pi palettes are derived from the roles.** Terminal panes sit on `bgWindow`
with `textPrimary` text, a lantern cursor, and a running-blue selection; each variant carries
its own 16-color ANSI palette (the light one darkened to stay readable). pi uses the same brand,
state, and syntax colors, with translucent tints flattened onto `bgWindow`, because Ghostty and
pi want opaque colors.

### One status enum

`AgentState` gives every status surface its color, tint, word, and glyph. The app maps its
lifecycles onto it in `AgentStateMapping.swift` (agent status, subagent runs, tool calls). Only
`attention` animates: a 1.6s glow.

| `AgentState` | Word | Color | Pill fill | Glyph (`NWStateGlyph`) | App meaning |
| --- | --- | --- | --- | --- | --- |
| `running` | Running | `running` | `runningTint` | spinner | agent working, a live run or call |
| `attention` | Needs you | `lantern` (words `lanternText`) | `lanternTint` | `exclamationmark.circle` | agent blocked on a question, a run asking |
| `done` | Done | `done` | `doneTint` | `checkmark` | a finished agent, run, or call |
| `failed` | Failed | `failed` | `failedTint` | `xmark` | a failed run or call, a lost connection |
| `stuck` | Stuck | `failed` | `failedTint` | `exclamationmark.triangle` | (unused by the app today) |
| `queued` | Queued | `textTertiary` (words `textSecondary`) | none, outlined; hollow dot | `circle` | a queued or paused run |
| `idle` | Idle | `textTertiary` (words `textSecondary`) | none, outlined | `circle.fill` | an idle agent |

### Contrast rules

`ShepherdUIUnitTests` checks every built-in variant (translucent fills are painted over the
surface they sit on):

- `textPrimary`, `textSecondary`, and `textTertiary` reach 4.5:1 on `bgBase`, `bgWindow`, and
  `bgRaised`, and `textPrimary` on `bgSelected`.
- `lanternText` on `lanternTint`, each state color on its own tint (over `bgWindow` and over
  `bgRaised`), and `textOnLantern` on `lantern` reach 4.5:1.
- `lantern`, `running`, `done`, and `failed` reach 3:1 on `bgWindow` as dots and glyphs, and stay
  distinguishable from each other.
- **Documented exceptions** (the board's colors, kept; the test pins their measured ratios):
  `textTertiary` meta text (dark 3.06–3.35, light 2.40–2.69), the light state pills' words on
  their own tints (running 3.98, done 3.01, failed 3.71 over the window), the light lantern as a
  mark (2.27), and white on `failed` (dark 3.18, light 4.33).
- Every role parses, only hover, selection, and the state tints may be translucent, surfaces
  and lines stay distinct, the ANSI palette has 16 entries, the terminal background equals
  `bgWindow`, and the theme round-trips through JSON.

### Adding a theme or a role

- **A theme:** write a `ThemeDefinition` that fills every field of `ThemeColors`,
  `SyntaxColors`, `TerminalColors`, and `PiColors` for both variants (the memberwise
  initializers make the compiler enforce completeness). Add it to the list the ShepherdUI unit
  tests iterate and fix values until they pass. Then teach `ThemeManager` and the app's
  `ShepherdTheme` to resolve it for Ghostty and the pi theme file; today they resolve Night Watch
  only. Keep the variant marker's `<theme>-dark|light` spelling.
- **A role:** add a field to `ThemeColors`, a value in every theme's light and dark variant, a
  property on `NWPalette`, and a contrast rule if it carries text.

## Typography

Geist for prose and chrome, Geist Mono for anything the agent touched (paths, commands, code,
output, counts, times). Every size scales with Settings ▸ Appearance ▸ Text size
(`ThemeStore.textScale`, 85–130%). `.nwText(_:)` applies a style with its line height (extra
leading from the face's real metrics); `.font(.nw(_:))` alone suits single lines.

| Style (`NWTextStyle`) | Spec | Use |
| --- | --- | --- |
| `display` | Geist 28/600/1.15 | Settings page titles, onboarding |
| `title` | Geist 15/600/1.3 | Dialog and sheet titles |
| `headline` | Geist 13.5/600/1.35 | Card titles, Markdown headings |
| `body` | Geist 13.5/400/1.6 | Agent prose, bubbles, the composer field |
| `ui` | Geist 12.5/500/1.3 | Rows, buttons, controls |
| `caption` | Geist 11.5/400/1.35 | Secondary info, descriptions, footnotes |
| `code` | Geist Mono 12/400/1.55 | Code blocks, output, the review's file headers |
| `mono` | Geist Mono 11.5/400/1.3 | Paths, commands, diff lines |
| `micro` | Geist Mono 10.5/500/1.2 | Section labels (`.nwSectionLabel()`: uppercase, tracked 5%, tertiary), counts, times |

- `Font.nw(_:weight:)` takes a weight for the rare emphasis the ramp lacks. `Font.nwSans(_:_:)`
  and `Font.nwMono(_:_:)` exist for the one-off sizes the boards specify (the toolbar title at
  13, row meta at 10–11, the palette field at 15). Prefer a ramp style.
- **Two prose sizes:** `NWProseSize` (the `nwProseSize` environment value) sets thread prose and
  bubbles at the ramp (`regular`) or one step smaller (`small`: body at the `ui` size). The
  subagent inspector's transcript uses `small`.
- The terminal font (family and size, default SF Mono 12.5) is its own setting in Settings ▸
  Terminal and never follows the chrome's text scale.

## Space, radius, height, elevation, motion

- **Space** (`NW.Space`, 4pt grid): `xxs 2`, `xs 4`, `s 6`, `m 8`, `l 12`, `xl 16`, `xxl 24`,
  `xxxl 32`. Padding and gaps use only these steps.
- **Radius** (`NW.Radius`): `xs 4` pills, keycaps, chips · `s 6` buttons, fields, rows · `m 8`
  cards, the composer, code blocks · `l 12` popovers, the palette.
- **Height** (`NW.Height`): rows `rowCompact 22` (diff lines), `row 28` (sidebar, menus),
  `rowComfortable 36` (ledgers), all scaled by Density and rounded to whole points
  (`NW.Height.scaled(_:)` for other row heights); controls `controlS 24`, `controlM 28`,
  `controlL 32`, which never scale; `touch 44` on iOS.
- **Hairlines** are 1px, not 1pt: `NWHairline` and `.nwBorder(_:radius:)` use
  `NW.hairline(displayScale)`.
- **Elevation:**
  - `.nwCard()`: flat, a raised fill and a 1px line (`lineSubtle` unless given).
  - `.nwPopover()`: a raised fill, a 1px `lineStrong` line, radius 12, and the only shadow.
  - `.nwFocusRing()`: running blue at `focusRing`, 2pt wide, drawn outside the control, for
    keyboard focus only (`.nwFocusRing(_ visible:)` for a field or card whose focus the caller
    tracks; `.nwFocusRingCircle()` for icon buttons).
- **Motion** (`NW.Motion`): `glow` 1.6s ease-in-out (attention only), `spin` 1s linear (running
  work), `hover` 120ms, `pane` 180ms, `sheet` 240ms. Apply them with `.nwAnimation(_:value:)`.
  - The glow and the spinner are clock-driven (`NWPhase`), so toggling Reduce Motion while they
    are on screen is safe.
  - Under Reduce Motion both are static, and panes and sheets cross-fade (120ms) instead of
    moving.
- **Icons:** SF Symbols, monochrome, medium weight: 14pt in icon buttons, smaller inline. Status
  glyphs come from `AgentState` (`NWStateGlyph`); never emoji. The Foundations board names the
  symbols to use
  (`sidebar.left`, `square.and.pencil`, `arrow.up`, `stop.fill`, `paperclip`, `lightbulb`,
  `arrow.triangle.branch`, `plus.forwardslash.minus`, `ellipsis`, `magnifyingglass`, `bolt`,
  `desktopcomputer`, …).

## Density and row settings

Settings ▸ Appearance has two independent row controls:

- **Sidebar rows** (`AppSettings.sidebarRowDensity`, an `NWDensity`): Compact 22 · Standard 28 ·
  Comfortable 36, default Standard. `RootView` sets it on the environment (`.nwDensity(_:)`).
  The sidebar's rows and the command palette's rows and placement read it, and use it as a
  minimum height, so larger text still fits. Compact rows set titles at 12pt instead of 12.5.
- **Density** (`AppSettings.uiDensity`, 80–150%, default 100%): multiplies every row height
  (`NW.Height.row…`, so the sidebar and palette rows above too), the Settings rows and nav, the
  ledger rows, and the diff's lines and fold rows. Control heights never scale.

A sidebar row is therefore its density's base height × Density. `NavigationTokenTests` and
`TokenTests` (ShepherdUI) pin the heights, and `SidebarRowSettingTests` the setting.

## Window and adaptive layout

```text
┌──────────────────┬──────────────────────────────────────────────┬──────────────────────┐
│ ● ● ●          ✎ │ Title  ● Running · 1m 03s   42k ctx  ⎇ ± ⋯   │ Review      ⋯  ×     │
│ ⌕ Jump to…   ⌘K  ├──────────────────────────────────────────────┼──────────────────────┤
│ THIS MAC     19  │         760pt thread column                  │ right pane:          │
│ ⌄ Shepherd    8  │                       ┌──────────────┐       │ review or subagent   │
│   ● agent   ASK  │                       │ user bubble  │       │ inspector, 600pt     │
│   ● agent    4m  │                       └──────────────┘       │ (min 480, ≤ half)    │
│     ● worker 37m │   agent prose, 640pt measure                 │                      │
│ HORIZON          │   ✎ Edited 4 files  +149 −63  ›              │                      │
│   ● Unreachable  │   ┌ composer ──────────────────────────┐     │                      │
├──────────────────┤   └────────────────────────────────────┘     │                      │
│ Automations    1 │                                              │                      │
└──────────────────┴──────────────────────────────────────────────┴──────────────────────┘
```

- **One window.** `ShepherdMacApp` declares a single `Window` scene ("Shepherd") with a hidden
  title bar, window tabbing is off, and closing the window leaves the app and every agent
  running; the Dock icon brings it back. The window controls stay at macOS's default position.
  The window has no title other than the toolbar's.
- **Size** (`AppLayout+Navigation.swift`): minimum 720×600, default 1440×900.
- **Layout:** the sidebar sits on `bgBase` and runs behind the window controls; the main column
  sits on `bgWindow`. There is no tab bar and no status line. An agent's layout is its thread
  plus any terminal panes split beside it. Pane dividers are 1pt `lineSubtle`, tinted running
  where they border the focused pane; dragging one keeps each side at least 160pt, between 15%
  and 85%.
- **Switching agents flips visibility; it never remounts.** Every mounted layout stays in the
  view tree, and hidden ones are `opacity(0)`. This is what makes switching instant.

**Adaptive rules** (`ShellLayout`, pure and unit-tested in `ShellLayoutTests`):

- **Sidebar.** It docks while the main column keeps 720pt beside it, narrowing to fit (to no
  less than 190pt). In a window narrower than that allows (190 + 1 + 720 = 911pt), it hides on
  its own, and ⇧⌘S or the toolbar's sidebar button shows it as an overlay: its width, at most the
  window width minus 48pt, over the workspace with the popover shadow. Picking a row or clicking
  outside closes the overlay. ⇧⌘S in a wide window hides and shows the docked sidebar.
- **Toolbar inset.** While the sidebar is not docked, the toolbar's content moves a further 70pt
  in to clear the window controls (none in full screen) and leads with a sidebar button.
- **Right pane** (review or subagent inspector, `RightPaneSplit`). It docks while the main
  column is at least 881pt (thread 400 + 1 + pane 480): 600pt by default, at least 480, at most
  half the column, and the thread always keeps 400. Narrower, the pane overlays the thread from
  the trailing edge with the popover shadow. Its leading edge is the drag handle (9pt hit area,
  adjustable with VoiceOver in 40pt steps), and the width persists app-wide
  (`shepherd.rightPaneWidth`). No width is ever negative.
- **Palette:** 620pt wide, or the window minus 16pt margins, and never taller than the window
  leaves room for (`NWPaletteMetrics.placement`).
- **Composer:** in a narrow thread the chips drop their words ("/" alone, the thinking level
  alone) instead of truncating mid-word (`ViewThatFits`).

## Surfaces

### Sidebar

`SidebarView` (`SidebarView.swift`, remote sections in `RemoteSidebarSection.swift`) on
`NWSidebar`.

- **Top bar (44pt):** empty space that drags the window, and the compose button
  (`square.and.pencil`, "New agent", ⌘N) at the trailing edge. Below it, **Jump to…**
  (`NWSidebarJumpButton`): a quiet search-shaped button with the palette's keycaps that opens
  the command palette.
- **Sections** (`NWSidebarSection`): a micro caps label with a trailing count; clicking it folds
  the section. With remote hosts configured, hovering a header shows its machine chord (⌃⇧n).
  1. **This Mac**, with its agent count and a hover `+` for New Space….
  2. One section per remote host. Connected: its agent count, or "n need you" in `lanternText`,
     and a hover `+` for a new space on the host. Otherwise one status row
     (`NWSidebarNoticeRow`) stands in for its spaces: "Connecting…", "Unreachable" with Retry, or
     "Off" with Connect.
  3. **Automations** as the footer (`NWSidebarFooter`), behind a hairline and hidden while
     empty: a bolt, "Automations", and a count badge that turns `attention` while an
     automation's agent needs you. Clicking it discloses the automation rows.
- **Spaces** (`NWSidebarDisclosureRow`): chevron, name in medium weight, then a `⎇n` worktree
  count and the blocked count in `lanternText` (else the agent count). Clicking toggles the
  space; it has no view of its own. A hover `+` starts a new agent in the space. Nested projects
  indent by path containment, and agents nest beneath their space.
- **Rows** (`NWSidebarRow`): the density's height, radius 6, 8pt leading padding plus 14pt per
  nesting level, and a 9pt gap after the dot.
  - A 6pt dot: `running` blue, `done` green, a hollow `textTertiary` ring while idle, and
    `lantern` glowing while it needs you.
  - `⎇` marks a worktree agent. The title truncates at the tail, with the full title (and the
    worktree branch) in a tooltip.
  - Hover is `bgHover`; selected is `bgSelected` with the title in semibold.
- **Trailing slot** of an agent row, in priority order (`SidebarAgentRowModel.accessory`):
  1. the ⌘-digit badge while ⌘ is held
  2. "ASK" in `lanternText` while it needs you
  3. "n sub" for a folded subagent group
  4. elapsed time while working ("4m", counting live in mono 10)
- **Subagents** nest under their agent with their run's state dot and name (the role). Trailing:
  "ASK", elapsed time while running, or how long a finished run took (in `failed` when it
  failed).
  - While any run is live, the group is expanded.
  - Once every run has finished, the group gets a disclosure row ("3 subagents · done 9:56"). It
    is expanded for the selected thread and folded for the others, whose agent row then shows
    "n sub".
  - Selecting a subagent row selects its agent and opens the run in the inspector.
- **Automation rows:** the automation's name, and its run's state: "running", "ASK", "done", or
  "stopped" (a hollow dot, not selectable). The context menu has Run Now or Stop, and Delete
  Automation.
- **Width:** 232pt by default, 190–340, by dragging the trailing edge (a 9pt handle, adjustable
  with VoiceOver in 16pt steps) or in Settings ▸ Appearance. It never narrows the main column
  below 720 and keeps its width while a right pane is open.
- **Interaction:** rows are tap views with button traits and accessibility actions, so they can
  also be dragged to reorder (with a 2pt running drop line, `NWDropIndicator`, at the row's top
  or bottom edge). Only drags that started in this sidebar qualify. Hover `+` glyphs are real
  labeled buttons (and always present for VoiceOver). Keyboard selection (⌘1–9, ⌘↑/↓, ⌃⇧digits)
  scrolls the row into view.
- **Context menus:**
  - Spaces: New Agent, Rename…, New Worktree… and Import Existing Worktree… (git repositories
    only), Remove Space….
  - Agents: Rename…, Review Changes, then Finalize Worktree… and Delete Worktree Agent… for a
    worktree agent, or Delete Agent.
  - Remote agents: Rename…, Finalize Worktree… (worktree agents), Review Uncommitted Changes,
    Review PR Changes, and Delete Agent or Delete Worktree Agent….
  - Host headers: New Space…, Reconnect, and Check Worktree Operation… while one is pending.

### Toolbar

`ThreadHeader` (`ThreadHeader.swift`) on `NWThreadToolbar`, placed by `WorkspaceHeaderView`
(`RootView.swift`).

- **44pt** on `bgWindow` with a hairline beneath, 14pt leading and 8pt trailing padding, unified
  with the title bar (it drags the window).
- **From left to right:**
  - the sidebar button (`sidebar.left`) while the sidebar is not docked
  - the agent's title in Geist 13 semibold, truncating, with "space / title" in its tooltip (a
    remote agent's space reads "⌁ host")
  - the status pill (`ThreadStatusPill`), in priority order: Error (a lost connection, drawn as
    `failed`), Needs you (or "n subagents need you"), Running · elapsed (counting from the prompt
    that opened the turn), Idle
  - a spacer
  - counters in micro tertiary: "18 turns · 46k ctx · 3 subagents · 1.6m tok". The turn count
    appears once the whole history is loaded, and the tooltip has the context window, session
    tokens, and cost.
  - the pane toggles, lantern-tinted while their pane is open: subagents
    (`arrow.triangle.branch`, ⌘I, only when the thread has subagents) and review
    (`plus.forwardslash.minus`, ⇧⌘B)
  - the options menu (`NWOptionsMenu`): Refresh Thread, Load Older Messages (while older history
    exists), Rename…
- **With no thread on screen**, the toolbar shows the title only: the selected space's name, or
  "Shepherd". Over a remote host's utility terminal it reads "<agent> · terminal".

### Empty workspace

With no agent on screen, `EmptyWorkspace` (`WorkspaceView.swift`) shows an `NWEmptyState` (the
crook, a title, one sentence, actions):

- A space with no agents: "No agents in <space>", "Start one to work in <path>.", a primary
  **New agent** button, and its keycaps.
- A selected space that has agents, with none on screen: "No agent selected", "Pick one in the
  sidebar, or start another in <space>.", and the same actions.
- No spaces at all: "No spaces yet", "A space is a project folder your agents work in.", and a
  primary **New space…** button.
- Otherwise: "No agent selected", "Pick one in the sidebar, or start a new one.", and the New
  agent keycaps.

### Thread

`ThreadView` (`Thread/ThreadView.swift`) lays out the rows `NativeThreadStore` derives once per
change (`NativeTurnPresentation`, `NativeActivity` in ShepherdRemote); the views only draw them.
Dimensions are in `AppLayout+Thread.swift` and ShepherdUI's `NWThreadMetrics`.

- **Layout:** a scroll view with the column centered, at most 760pt wide with 32pt gutters (16pt
  when the thread is too narrow for both). 28pt top margin, 28pt between turns, 14pt between a
  turn's parts, and 6pt between consecutive activity lines.
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom
  (`NativeScrollFollower`). Only a live scroll gesture or a wheel tick detaches it; content
  growth, the composer resizing, and history swaps never do. "↓ Jump to latest" (a
  `bgRaised` capsule above the composer) appears while detached if the agent runs or unseen
  output arrived. Sending re-attaches. The composer floats over the scroll view, which is inset
  by the composer's measured height, so the thread always ends at its last turn.
- **Turn jumps:** ⌥⌘↑ and ⌥⌘↓ move between user turns (the target lands at the top); stepping
  past the last returns to the tail.
- **History:** "Load older messages" (a small ghost button) heads a thread that has older pages.
- **Notices** above the thread explain degraded states in caption tertiary: "Last known thread ·
  refreshing before enabling actions", "This host's pi cannot answer questions here · update
  Shepherd on the host", "Some earlier output is clipped".
- **Empty thread:** "Starting pi…" with a spinner while connecting. Then a framed
  `NWEmptyState` (a dashed `lineStrong` border, no crook): "New agent in `~/path`" (the path in
  mono), with "Describe the task. Drop or paste images to attach them, or type / for commands."

**User turn** (`UserTurn` in `Thread/ThreadTurns.swift`, on `NWUserBubble`):

- Right-aligned, at most 600pt, `bgBubble` with a 1px `lineStrong` line, radius 8, 10×14
  padding, body text. No avatar and no name.
- The time sits beneath in mono 10.5 tertiary. Sent images show as attachment chips.
- A sent message shows at once, at 70% opacity until pi saves it. A follow-up sent while a turn
  runs is **queued**: a dashed outline with no fill, secondary text, and "queued · sends when the
  turn ends" beneath.

**Agent turn** (`AgentTurn`): consecutive assistant messages render as one turn. Its parts are
thinking, prose, activity lines, subagent cards where their spawn calls were, notes, and errors,
in the order they happened (each stretch of work between prose opens with its thinking). Once
the turn has finished, the changes card and the footer end it.

- **Prose** (`Prose` in `Thread/ThreadMarkdown.swift`, on `NWAgentProse`): body 13.5/1.6 in
  `textPrimary` at the 640pt measure, blocks 12pt apart. Markdown is parsed once per turn:
  - headings at `headline`
  - lists indented 20pt, with one nested level
  - quotes in italic `textSecondary` on a 2pt `lineStrong` rule
  - inline code in mono 12 on `lineSubtle` (a text run cannot carry a border), links in
    `running`
  - rules as hairlines
- **Code blocks** (`HighlightedCodeBlock` on `NWCodeBlock`): `bgSunken`, a 1px `lineSubtle`
  line, radius 8. A 28pt header with the language (or "code") in mono 10.5 tertiary and a copy
  button that appears on hover or keyboard focus. Code in mono 12, scrolling sideways, never
  wrapped. Tree-sitter colors it off the main actor in the block's task (Swift, Python, Go, Rust,
  JavaScript, TypeScript/TSX, C, C++, shell, Ruby, JSON); the first frame is plain, results are
  cached, and a block that grows while streaming keeps its last colors until the new ones are
  ready.
- **Thinking** (`NWThinking`): the thinking in one stretch of work (between prose blocks) folds
  into one block at the start of that stretch, so per-call reasoning never splits the activity
  lines. Collapsed: a chevron and "Thought for 4s" in italic 12 `textSecondary` ("Thought" when
  shorter than half a second or untimed). Expanded: the text in italic 12.5 on a 2pt
  `lineStrong` rule. Live: a spinner, "Thinking…", and its seconds counting; it collapses when
  thinking ends.
- **Notes** ("Image attached", "Output truncated", extension messages) render as caption
  tertiary text on a 2pt rule (three lines, full text on hover).
- **Errors** (`NWTurnError`): a failed provider request, on `failedTint` with radius 6: a
  triangle, the message ("Model overloaded — the turn stopped after 6 tool calls."), "×n" when
  repeated, and Retry when it ended the turn. Tool failures stay in their activity lines.
- **Working row** (`NWWorkingRow`): while the agent runs, the thread ends in one row with a
  spinner and what it is doing in italic 12: "Working…" under a live activity line, "Running
  <tool>…", or "Thinking…". Live thinking carries its own spinner instead, and a pending
  question replaces it with the composer's question panel.
- **Footer** (`NWTurnFooter`), after a finished turn: copy (the turn's prose) and retry (resend
  the prompt that opened it, only while the agent is idle) as 24pt icon buttons, then "2:44 PM
  · 3m 12s · 23 tool calls" in mono 10.5 tertiary, and "· 3 subagents" as a link to the first
  run.

**Activity lines** (`ActivityLineView` in `Thread/ThreadTools.swift`, on `NWActivityLine` and
`NWActivityCalls`). A turn's tool calls merge into one quiet line per burst of same-kind work
(`nativeActivityBursts`). A failed call and the running call each stand alone; other tools merge
only with the same tool.

- **The line:** 26pt, a 13pt glyph, the label in 12.5 `textSecondary`, the meta in mono 11
  tertiary, and a chevron when it expands. It is a real button with a hover fill.

  | Kind | Glyph | Done | Running |
  | --- | --- | --- | --- |
  | Explore (read, grep, find, glob, ls) | `magnifyingglass` | "Explored 7 files" · "read 5 · search 2 · 0.9s" | "Reading", "Searching", "Listing" |
  | Edit (edit, write) | `pencil` | "Edited 4 files" · "+149 −63" | "Editing", "Writing" |
  | Run (bash) | `apple.terminal` | "Ran tests and a build" · "17 passed · build ok · 1m 02s"; "Committed and pushed"; "Ran 2 commands" | "Running tests", "Building", "Committing", "Pushing", "Running" |
  | Subagents (spawns without a card) | `arrow.triangle.branch` | "Started 2 subagents" · "reviewer · tests" | "Starting a subagent" |
  | Other | `wrench.adjustable` | "Used <tool>" or "Used <tool> n times" | "Running <tool>" |

  Shell commands are classified by what they run (`nativeCommandClasses`: tests, build, commit,
  push), with setup and pipes (`cd`, `| tail`) ignored and test counts parsed from the output
  (Swift Testing, XCTest, and "N passed" in general).
- **Failed:** the line turns `failed` with a triangle and stays visible: "Ran tests" · "swift
  test · 3 failed", "Edit failed" · the file · the error. A piped test run that exits 0 with
  failures still fails.
- **Live:** only the current call is live: a running spinner, the progressive verb in
  `textPrimary`, the command or path, its elapsed time in running blue, and its last three
  output lines indented beneath. It then collapses into a finished line.
- **Calls** (expanded): an indented list on a `lineStrong` hairline rail, 22pt rows in mono 11:
  the kind ("read", "edit", "bash"), the path (truncated at the head) or command (at the tail),
  and a stat ("+58 −41", "160 lines", "3 matches", "17 passed", "exit 1").
  - Clicking an edit or write opens the review pane at its file. Clicking any other call with
    output expands its first 12 lines on `bgSunken`, then "… n more lines" (or "Output truncated
    · open" for output the host clipped) opens the whole output in a sheet with Copy.
  - ⌥-click or the context menu's Show Call opens the raw arguments; the menu also has
    Review <file>, Open Output, and Copy Output.

**Changes card** (`NWChangesCard`): every finished turn that edited files ends with one.

- A card on `bgWindow`, radius 8, 1px `lineSubtle`. A 32pt `bgSunken` header: pencil, "4 files
  changed" in `ui` semibold, the diff stat, and a ghost **Review** button that opens the review
  pane at the first file.
- One 28pt row per file: the status letter (M `lantern`, A `done` for a file the turn wrote
  new), the directory in tertiary and the filename in `textPrimary` (mono 12, truncated at the
  head), and its diff stat. A row opens the review pane at that file.

### Composer, questions, and menus

`Composer` (`Thread/Composer.swift`) on `NWComposer`, `NWSlashMenu`, `NWModelPicker`, and
`NWThinkingMenu`. Sizes are `NWComposerMetrics`.

**The card:**

- It is pinned under the thread in the same column, 16pt above the bottom, with a 48pt fade
  from transparent to `bgWindow` above it.
- It is `bgRaised`, with a 1px `lineStrong` line and radius 8. While the field has focus, a menu
  is open, or a drop hovers, the line turns `textTertiary` inside a 3pt `bgSelected` ring.
- Attachments sit on top, the field beneath (body text; it grows to 8 lines, then scrolls), and
  one row of controls under it. Nothing else lives under the field.

**The control row:**

- attach (`paperclip`, only when the agent accepts images)
- "/ commands" (only when pi reports commands)
- the model chip (the model in mono 12, with a chevron when it can change)
- the thinking chip (`lightbulb`, "Thinking", the level; hidden when the model has no reasoning
  control)
- the delivery chip (Follow-up · after the turn ends / Steer · after the current tools), only
  while a turn runs with a draft
- a spacer, then the single action: a 28pt circle, **Send** (an arrow on `lantern`, at 35% until
  there is something to send) or **Stop** (a square on `failed`)

Chips are 26pt ghost buttons in 12pt `textSecondary`, filled with `bgHover` on hover or while
their menu is open.

**States:**

- **Idle:** Send. The placeholder is "Follow up, or / for commands…" ("Follow up…" when pi
  reports no commands), or "Describe the task, or / for commands…" on a fresh agent.
- **Running:** Stop while the field is empty. The field stays editable with "Queue a follow-up —
  sent when the turn ends".
- **Accepting:** a spinner ("Waiting for pi") takes the button's place.
- **Error:** Send, plus a `failed` banner above the card, "Lost connection to the agent
  process.", with the error and Reconnect.

With more than one live subagent, Stop asks first (`StopAllDialog`): Stop only the agent, or
Stop all. There is no status text, key hint, or working directory in or under the composer.

**Images** attach by drop, paste, or the paperclip (a file importer). They are resized on the
way in (longest edge 2000px), at most four per message and 2 MiB each, and shown as
`NWAttachmentChip`s (26pt, a 20pt thumbnail, a remove button). Problems show as a `failed`
banner above the card.

**Questions** from pi or an extension (select, confirm, input, editor) replace the field *inside
the card* (`QuestionPanel`), never in the scrolling thread, so a blocked agent is always
answerable:

- the attention glyph and the title, "1 / N" when several are queued
- the message in mono on `bgSunken` (scrolling past 140pt)
- the asker's options as buttons (the first primary), Yes / No (and y/n while the panel has
  focus), or a field with Submit; always Dismiss
- "pi may stop waiting for this answer" when the question has a timeout

**Extension widgets** (an extension's `setWidget` text, ANSI stripped) appear above the card as a
micro caps title and its text. Machine payloads, `setStatus`, and `notify` are not shown.
Widgets are display-only, and the app chooses every font and color.

**Menus** open above the card, left-aligned, 8pt above it, one at a time. They share one anatomy:
`.nwPopover()` at radius 12 with 6pt padding, 24pt mono caps section headers, and 28pt rows with
a `runningTint` highlight. ↑↓ move, ⏎ chooses, Esc closes and returns focus to the field.

- **Slash menu** (`NWSlashMenu`, 448pt): opens when the draft is "/…" (or from the chip).
  "Commands · n of m"; rows show the command in mono 12 with the typed prefix in semibold
  `textPrimary` (a 150pt column), its description, and its source as a tag for prompt templates
  and skills (none for extension commands). At most 8 rows show. ⇥ completes with a space. The
  list is pi's command registry, never hard-coded.
- **Model picker** (`ModelPicker` on `NWModelPicker`, 260pt, at most 360pt tall): from the
  model chip or ⇧⌘M. A search field, then Recent (up to four, from any thread), then one section
  per provider. Rows show the model in mono 12 and a running check on the current one, or its
  context size. It picks the model only.
- **Thinking menu** (`NWThinkingMenu`, 220pt): Off, Low ("quick"), Medium ("default"), High
  ("slower, deeper"), with a check on the current level.

### Subagents

A subagent is a turn inside a turn. Its spawn call renders as a card where the call was, and raw
wait or status dumps never appear. Behavior is specified in
[native-subagents.md](docs/native-subagents.md).

The components are ShepherdUI's Agents set (`Components/Agents`); `SubagentPresentation`
(`Thread/SubagentPresentation.swift`) maps a `ChildRun` onto their values, `Thread/Subagents.swift`
lays them out, and state always comes from `AgentState` (a queued run and a run paused before its
next model request both draw as `queued`).

- **Layout per turn** (`SubagentPresentation.layout`): cards for up to three sibling runs; a runs
  strip plus the cards that need you for more; a ledger once every run in the group has finished
  and none still asks. Once cards stand for a turn's children, the parent's
  `shepherd_child_wait` and `shepherd_child_result` calls no longer show as activity.
- **`NWSubagentCard`:** `bgRaised`, padding 10×12, radius 8, a 1px `lineSubtle` line (`lantern`
  while it needs you). Clicking the card opens the run in the inspector; the inspected card
  wears a `running` line and a 3pt `runningTint` ring.
  - **Header:** the 13pt branch glyph, the name in `ui` semibold, a role tag when it differs from
    the name, a mono model tag, and the state pill. In a narrow thread the tags give way (the
    model first) before the name truncates.
  - **One mono 11 `textSecondary` line**, then per state:
    - **Running:** the last call ("edit ThreadView.swift"), and a 4pt bar with its percent for
      the context window used. The card never grows while it runs.
    - **Queued / Paused:** an outlined pill ("Queued" or "Paused") and "waiting to start" or
      "paused before its next model request".
    - **Needs you:** "waiting on your answer · 2m" (the wait counts from the child's
      `shepherd_parent_message` call, or shows no figure), then the question as inline Markdown
      on `lanternTint` with its answers as buttons (the first primary) and Reply… for free text.
    - **Done:** what it did · "26 tools · 12m".
    - **Failed:** the reason, then Open replay (the inspector) and Re-run.
  - Pause/Continue, Stop, and Re-run live in the card's context menu and accessibility actions;
    the inspector shows them. Only elapsed text re-renders on a clock (`NWElapsedText`, ticking
    exactly when its text changes, anchored to when it counts from, static once finished).
- **`NWRunsStrip`:** more than three sibling runs fold into one row in the ledger header's form:
  a 32pt `bgSunken` row, radius 8, with the glyph (needs you, else running, else queued, else
  failed, else done), "12 subagents", one 8pt step per run in spawn order, the tally ("7 done ·
  3 running · 1 queued · 1 needs you", each run counted as its step draws it), tokens and the
  group's elapsed time, and a chevron.
  - Each step is its own button: clicking it opens that run in the inspector, as its card does.
    Its target is the step plus half the gap on each side, the row's full height, so steps tile
    with no dead gap. Its tooltip names the run and its state ("worker, running"), and a hovered
    step thickens; at rest the strip is unchanged. A click anywhere else on the row shows or
    hides every card.
  - When the row runs out of room the totals give way (tokens first) before the tally truncates.
  - Runs that need you keep their own card under the strip.
- **`NWRunLedger`:** once every run in the group has finished, the cards are replaced in place by
  a permanent ledger on `bgWindow`, radius 8.
  - A 32pt `bgSunken` header: glyph, "3 subagents", one 14pt step per run, "all done · 45m" (or
    "2 done · 1 failed · 45m"), and the combined diff stat when there is one.
  - One row per run in spawn order (`rowComfortable`, 36pt × density): state dot, name in a 70pt
    column, a one-line summary (the exit reason in `failed` for a failed run), "5 files · 41m",
    and a chevron.
  - A row opens the run in the inspector (again closes it). The open row is `runningTint` with a
    2pt `running` rule on the pane side.

### Right pane: subagent inspector and review

One slot beside the thread (`RightPaneSplit`) is shared by the subagent inspector and the review;
when both exist, the inspector wins. Its sizes and adaptive rule are in "Window and adaptive
layout" above.

- **Toggling:** ⇧⌘B (or the toolbar's review toggle) closes the inspector if it is open,
  otherwise it opens or closes the review. ⌘I (or the subagents toggle) inspects the thread's
  first live run (else its last), or closes the inspector.
- **Layout:** the thread keeps running beside the pane. A pane never replaces the thread and
  never changes the persisted layout. The sidebar keeps its width.

**Subagent inspector** (`Thread/SubagentInspector.swift`):

- **`NWInspectorHeader`**, 44pt to line up with the toolbar: the branch glyph in the run's state
  color, "name · k of n", and a mono line: "model · thinking high · 78 turns · 922k tok" while
  live, "model · 11 turns · done 11:02" once finished, the last part in the state's color.
  Trailing: Pause/Continue and Stop for a live run, ‹ › to step through siblings, a ⋯ menu
  (Refresh Transcript while live; Copy Transcript and Show Session File in Finder once
  finished), and close.
- **`NWRunBrief`** on `bgSunken`: GOAL, with "step n / m · 62%" while live, and once finished
  RESULT (inline Markdown) with its label in the state's color. Under it, up to five touched
  files as `running` links (with their diff stat) that open the review pane at the file, then
  "n more files".
- **The run's own transcript**, drawn with the thread's components one step smaller
  (`nwProseSize` `.small`). It follows live, with "n earlier turns · Show all" and "Following
  live" (or "Reading earlier output") beneath. Scrolling up stops following.
- **A Steer composer** while the run is live: the composer card's anatomy, "Steer <name> —
  delivered before its next turn", "to: <name> · not the parent", and a primary Steer button.
  A failed send keeps the draft.
- **A finished run is read-only:** messages from the parent are captioned "10:58 · from parent",
  and `NWRunActions` (Re-run · Fork · Copy transcript) replaces the composer. Remote agents have
  no Fork.

**Review** (`ReviewPane` in `DiffReviewView.swift`, state in `DiffReview.swift`):

- **Header (44pt):** "Review" in Geist 13 semibold, with "4 files · +67 −58" beneath (led by the
  reference when an agent asked for one, "loading…" while loading). Then a small `Local | PR`
  segmented control ("PR · <ref>" once the PR base is known), an options menu (Expand All Files,
  Collapse All Files, Copy Review as Text), and close.
- **File strip** (`NWFileStrip`, on `bgBase`): 24pt chips that scroll sideways, each with its
  status letter (M `lantern`, A `done`, D `failed`, R `running`; mono 11 bold), the filename, and
  for a modified or renamed file its diff stat. The selected chip is `bgSelected`, viewed files
  dim to 50%, and a running dot marks a file the agent is editing right now.
- **File headers** (`NWFileHeader`, sticky, at least 32pt on `bgSunken`): a fold chevron, the
  path in mono with its directory in tertiary and the filename in semibold, "n hunks", "n
  comments" in `running`, then 24pt icon actions: Open in Xcode (the default editor when Xcode is
  absent; local reviews only), Revert (confirmed, local working-tree reviews only), and Viewed
  (`done` once viewed).
- **Diff lines** (`NWDiffView`, `NWDiffLine`): 22pt (`rowCompact`, × density), two 36pt
  line-number gutters, a 16pt sign column, and syntax-colored code in mono 11.5. Removals sit on
  `failedTint`, additions on `doneTint`, and hunk headers are 22pt `bgSunken` rows aligned to the
  code column. Lines are tail-truncated with the full line on hover, never wrapped. Highlighting
  runs off the main actor, once per file.
- **Folding:** a run of more than 8 like lines (`AppLayout.diffCollapseThreshold`) keeps a few
  lines at each end and folds the middle to a 24pt `bgSunken` strip between hairlines ("+ 13 more
  removed lines · 20–32"). Clicking shows the lines; ⌥-click shows the whole file.
- **Comments:** hovering a line shows an 18pt lantern `+`, and double-clicking the line also
  starts a comment. The editor (`NWCommentEditor`) is a card with a `running` line: ⏎ saves, ⇧⏎
  adds a line, Esc cancels, and saving an empty comment removes it. A saved comment
  (`NWInlineComment`) is a raised card with a 16pt lantern avatar, "You", "line 33 · just now",
  and Edit / Delete on hover.
- **Review composer** (`NWReviewComposer`, at the foot): "Overall comment", "n inline",
  **Commit** (asks the agent to commit; not in PR mode) and **Request changes** (primary, ⌘⏎;
  sends the overall and inline comments as the agent's next turn, queued if it is mid-turn). The
  review closes only once the send succeeds.
- **Empty and error states:** "Loading the diff…"; "No changes" with "The working tree matches
  HEAD." (or "This branch matches its PR base."); a `failed` banner for an error.
- **Keys:** j/k move between hunks, n/p between files, c comments, v marks viewed, ⌘⏎ sends, and
  Esc returns to the thread's composer.
- **Repository changes:** per-file Revert is the only repository mutation outside the worktree
  flows (`RevertFileDialog`: "Discard changes"). Tracked files return to HEAD; new files move to
  the Trash.

A review an agent opens (`review_diff`) is the host's view state; remote viewers open their own
with ⇧⌘B.

### Terminal panes

Terminal panes render through libghostty on the theme's terminal colors, on `bgWindow`, with
10×8pt padding and the Settings ▸ Terminal font. An agent's layout may hold terminal panes beside
its thread; the thread pane itself never has a terminal. Pane states are quiet placeholders in
mono 10.5 tertiary ("starting session…", "session exited (n)", "session unavailable · reason").
The chrome never parses or restyles terminal output.

### Command palette

⌘K opens `CommandPaletteView` (`CommandPaletteView.swift`, items in
`ShepherdViewModel+Palette.swift`) through `.nwCommandPalette(isPresented:)`.

- **Placement:** a 620pt `NWPaletteCard` (`.nwPopover()`, radius 12) 18% down the window, over
  the 30% `scrim`, and capped to the window (at most 14 rows before the list scrolls). Clicking
  the scrim or Esc closes it; VoiceOver stays inside it.
- **Search row (44pt):** a glass, the field in Geist 15 ("Search commands, agents, subagents…"),
  and the scope control All · Commands · Agents (⇥ cycles it).
- **Sections** (mono caps headers): Commands, This thread, Subagents, and, once there is a query
  (or in the Agents scope), Agents, Spaces, and Found in conversations. Conversation search
  needs at least 3 characters, runs off the main actor after a short pause, and reads the last
  512 KB of each agent's pi session; its rows show a snippet with the match in bold.
- **Rows** (`NWPaletteRow`, the sidebar's row height): a stroke icon, the label, dim context, and
  the real shortcut as keycaps. The highlight is `runningTint` with a running icon. Subagent rows
  wear their run's state color.
- **What it never shows:** footer hints, ⌘1–9 numbering, or any status the sidebar doesn't show.

### Settings

Settings replaces the window content in place (`SettingsView.swift`). ⌘, toggles it, and "Back
to Shepherd" or Esc returns.

- **Navigation:** a 232pt nav on `bgBase`: a draggable strip for the window controls, Back to
  Shepherd, the search field (`NWSearchField`, ⌘F), then Appearance · Terminal · Agents ·
  Worktrees · Pi · Remote · Keyboard · Advanced (`NWSettingsNavRow`: 28pt × density, a medium
  icon, the name in `ui`, `bgSelected` and semibold when selected), with "Shepherd x.y.z · pi
  x.y.z" pinned at the bottom in micro. Searching lists matching rows, as buttons, under their
  page.
- **Content:** a 720pt column with 44pt top padding and a 32pt gutter. Each page has a title in
  `display` and a one-line explanation in `body`/`textSecondary`, then groups 28pt apart: a
  section label (`NWSectionHeader`) over an `NWGroupCard` of `NWCardRow`s. A row is at least
  52pt (× density): title in `ui`, description in `caption`/`textSecondary`, the control
  trailing. Rows without a title (a form's Save, pi's update buttons) are `SettingsActionRow`s.
  The building blocks are in `SettingsComponents.swift`: `SettingsPage`, `SettingsGroup`,
  `SettingsRow`, `SettingsActionRow`, `SettingsSwitch`, `SettingsTextField`, `PathRow`.
- **Controls** are the Controls board's, nothing hand-drawn per page:
  - `NWSegmentedPicker` for 2–4 options, `NWPopupMenu` (200pt) for longer lists
  - the lantern switch for booleans (`SettingsSwitch`)
  - `NWStepper`, and `NWValueSlider`: 200pt, a 3pt `lineStrong` track filled with lantern to a
    14pt knob, with its value in mono (double-clicking the value resets it)
  - `SettingsTextField`: 220pt fields labelled for VoiceOver, with the example as the prompt
  - `NWKeycap`s for shortcuts (click to record, with a Reset link when changed)
  - small secondary buttons (danger when destructive)
- **Footnotes and problems:** footnotes are `caption` in `textTertiary`. Inline problems (like
  the listener's bind error) sit in the row in `failed` under the description. A remote host's
  status is a state dot plus its word.
- **Never in `body`:** the installed font families are enumerated once per launch
  (`TerminalFontCatalog`), and pi's config and model catalog load in a task.

| Page | Contents |
| --- | --- |
| **Appearance** | Theme (Night Watch, shown as a name), Mode (System / Light / Dark), Sidebar rows, Density, Text size, Sidebar width |
| **Terminal** | Pane font family and size, a live preview, the shell |
| **Agents** | Default model, default thinking level |
| **Worktrees** | Base branch (Remote default / Current branch), fetch before creating, and finalize: commit remaining work, generate PR descriptions, delete local branch, merge automatically (+ method) |
| **Pi** | Bundled extensions (name agents automatically, sync pi theme, panes and agent tools, diff review tool, native subagents, subagent display), native subagent defaults, pi and extension updates |
| **Remote** | Hosts (edit, reconnect, remove), add or edit a host (name, address, port, token), Serve this Mac (listener, token file) |
| **Keyboard** | Rebindable shortcuts by group, the fixed chords, and Reset all |
| **Advanced** | Files (workspace state, extension socket), updates and channel, reset settings |

### Dialogs and sheets

Creation sheets (New Agent, New Worktree, Finalize Worktree, the directory picker, the remote
worktree sheet) and every confirmation share one anatomy, `NWDialog` (460pt by default), flat on
`bgWindow`:

- a 24pt inset; the title in `title`, an optional explanation in `body`/`textSecondary`
- labeled rows (`NWSheetRow`, aliased `SheetRow`): a 96pt `ui`/`textSecondary` label column,
  the control, a hairline; at least 44pt
- lists of steps or checks (`NWChecklistRow`): the state glyph (spinner, check, cross, ring),
  the label in `ui`, a trailing `caption` detail, and a failed check's remedy underneath
- a footer: an optional status on the leading edge (`NWDialogStatus`, `failed` for an error),
  and the actions trailing. Actions never truncate.
- exactly one primary action as the ⏎ default, ⎋ on Cancel. A destructive action is the
  `dangerFill` button and never the default: destroying things takes a click.
- anything a destructive action would destroy is called out in an attention banner
  (`DialogBanner`); an error is a `failed` banner. Never a system alert.

`DialogSheet` and `DialogAction` (`DialogSheet.swift`) build a confirmation from that anatomy.
`AppDialogs` (`AppDialogs.swift`) presents the view model's sheets (creation, rename, delete,
Finalize, the directory picker, a failed action), mostly with `sheet(item:)`, so a sheet keeps
the value it opened with while it animates away. The composer presents Stop all, the review
pane its Revert, and Settings ▸ Advanced its reset. There is no `.alert`, `confirmationDialog`,
or `NSAlert` in the app:

- Rename agent and Rename space (`RenameDialog`)
- Delete Worktree Agent (`WorktreeDeleteDialog`) and Remove Space (`SpaceDeleteDialog`)
- Stop all (`StopAllDialog`), the review's Revert (`RevertFileDialog`), and a failed agent action
  (`ActionErrorDialog`)
- Reset settings (`ResetSettingsDialog`)
- Quitting while agents are working or waiting on you (`QuitDialog`), because quitting stops
  them mid-turn. It lists the busy agents (five named, each with its status dot and "working" or
  "needs you", the rest counted), with Cancel (⎋) and a destructive Quit, so ⏎ never quits. It
  opens on the main window as a sheet, even over another sheet, and reopens a closed window
  first. A second ⌘Q brings it back rather than asking twice, and a log out, restart, or shut
  down quits without asking.

Git probes and directory listings run off the main thread; the Delete Worktree Agent dialog
keeps its destructive action disabled until the unreconciled-work check is in.

## Status language

| Lifecycle | `AgentState` | Sidebar | Toolbar pill | Composer |
| --- | --- | --- | --- | --- |
| Agent working | `running` | blue dot; elapsed trailing | Running · elapsed | Stop; the field queues a follow-up |
| Agent blocked on a question | `attention` | lantern dot, glowing; "ASK" | Needs you | the question panel in place of the field |
| A subagent needs you | `attention` | the run's row: "ASK" | "n subagents need you" | the card's answers and Reply… |
| Agent done | `done` | green dot | Idle (outlined) | Send |
| Agent idle | `idle` | hollow ring | Idle (outlined) | Send |
| Connection lost | `failed` | — | Error | Send, plus a `failed` banner with Reconnect |

Subagent runs use the same states on their dots, glyphs, pills, and steps: running, needs you,
done, failed, and queued (queued or paused, hollow). Tool calls use running, done, and failed.

## Components

`Packages/ShepherdUI/Sources/ShepherdUI/Components` is the shared library, by domain, with
`#Preview`s of every component in both appearances in `Previews/`. Use a component before
composing chrome by hand. Debug builds have a **Component Gallery** (View menu,
`ComponentGallery.swift`) that shows the base components in their states.

| Domain | Components | Owned in the app by |
| --- | --- | --- |
| Controls | `.buttonStyle(.nw(_:size:))` (primary, secondary, ghost, danger, dangerFill; s 24 · m 28 · l 32), `.nwIcon` (a circle, 28pt; "on" is lantern tint), `.nwLink`, `.nwRow(selected:)`, `.nwRowBackground(selected:hovering:)`; `.toggleStyle(.nwSwitch)` (30×18) and `.nwCheckbox` (14pt); `NWSegmentedPicker` (m 24, s 20), `NWPopupMenu`, `NWValueSlider`, `NWStepper`; `.textFieldStyle(.nw)` (28pt, radius 6), `.nwField(focused:error:mono:)`, `NWSearchField`; `NWKeycap`, `NWCountBadge`, `NWTag`, `.nwHelp(_:shortcut:)` | across the app |
| Status | `NWStatusPill` (20pt, radius 4), `NWStatusDot` (6pt), `NWStateGlyph` (14pt), `.progressViewStyle(.nwSpinner)` and `.nwBar` (4pt), `NWStepStrip`, `NWSparkline`, `NWBanner`, `.nwToast(item:)`, `NWEmptyState`, `.nwShimmer()`, `NWWordmark`, `NWCrook` | across the app; `NWSparkline`, `.nwToast(item:)`, and `.nwShimmer()` have no app use yet |
| Containers | `NWSectionHeader`, `NWGroupCard`, `NWCardRow`, `NWHairline` | `SettingsComponents.swift`; hairlines everywhere |
| Navigation | `NWSidebar`, `NWSidebarJumpButton`, `NWSidebarSection`, `NWSidebarRow`, `NWSidebarDisclosureRow`, `NWSidebarNoticeRow`, `NWSidebarFooter`, `NWDropIndicator`, `NWDensity`; `NWThreadToolbar`, `NWPaneToggle`, `NWOptionsMenu`, `NWPaneHeader`; `.nwCommandPalette(isPresented:)`, `NWPaletteCard`, `NWPaletteSearchRow`, `NWPaletteSectionHeader`, `NWPaletteRow` | `SidebarView.swift`, `RemoteSidebarSection.swift`, `ThreadHeader.swift`, `RootView.swift`, `CommandPaletteView.swift` |
| Thread | `NWUserBubble`, `NWAgentProse`, `NWCodeBlock`, `NWThinking`, `NWActivityLine`, `NWActivityCalls`, `NWChangesCard`, `NWDiffStat`, `NWInlineCode`, `NWAttachmentChip`, `NWTurnFooter`, `NWTurnError`, `NWWorkingRow` | `Thread/ThreadView.swift`, `ThreadTurns.swift`, `ThreadTools.swift`, `ThreadMarkdown.swift` |
| Composer | `NWComposer`, `.nwComposerChip(active:)`, `NWChipChevron`, `NWComposerActionButton`, `NWMenuHeader`, `NWSlashMenu`, `NWModelPicker`, `NWThinkingMenu` | `Thread/Composer.swift` |
| Agents | `NWSubagentCard`, `NWRunsStrip`, `NWRunLedger`, `NWInspectorHeader`, `NWRunBrief`, `NWRunActions`, `NWBranchGlyph`, `NWElapsedText`, `NWDuration`, `NWInlineMarkup` | `Thread/Subagents.swift`, `Thread/SubagentInspector.swift`, `Thread/SubagentPresentation.swift` |
| Review | `NWFileStrip`, `NWFileHeader`, `NWDiffView`, `NWDiffLine`, `NWHunkHeader`, `NWFoldRow`, `NWInlineComment`, `NWCommentEditor`, `NWReviewComposer` | `DiffReviewView.swift` |
| Dialogs | `NWDialog`, `NWDialogStatus`, `NWSheetRow`, `NWChecklistRow`, `NWSettingsNavRow` | `DialogSheet.swift`, `AppDialogs.swift`, the sheets, `SettingsView.swift` |

Rules for the controls:

- **Buttons** are styles on a native `Button`. Primary (lantern) appears at most once per view;
  disabled is 40%. Icon-only buttons always carry an accessibility label.
- **Toggles, text fields, and pickers** are styles on native controls. `NWSegmentedPicker`,
  `NWValueSlider`, and `NWStepper` draw their own control and represent themselves to
  accessibility as a native segmented `Picker`, `Slider`, and `Stepper`.
- **Keycaps** show only a real, wired shortcut, and only in menus, the palette, Settings, the
  sidebar's Jump to…, and empty states; never under the composer.
- **Banners** sit inside the pane they concern. Never a modal alert for an agent event.

## Keyboard

Keyboard is first-class, and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (`Keybindings.swift`; defaults in `ShortcutAction.defaultChord`, overrides
in UserDefaults under `shepherd.keybindings`).

- **One source:** menus, palette keycaps, Settings ▸ Keyboard, and the Ghostty unbind list all
  read the store. Hardcoding a chord in a view is a bug, and a hint is never shown for a chord
  that isn't wired.
- **Rules for a rebound chord:** it must include ⌘, must not use a digit (⌘1–9, ⌃⇧1–9), must not
  be ⌘, or a plain ⌘ system or terminal chord (⌘Q, ⌘H, ⌘M, ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z), and must not be
  another action's chord.

| Default | Action |
| --- | --- |
| ⌘N · ⇧⌘T · ⇧⌘N | New agent in current checkout · with options… · new space… |
| ⌘R · ⇧⌘W | Rename agent · delete agent |
| ⌘K | Command palette |
| ⌘↓ · ⌘↑ | Next · previous agent |
| ⌘D · ⇧⌘D · ⌘W | Split vertically · horizontally · close pane |
| ⌥⌘→ · ⌥⌘← | Focus next · previous pane |
| ⇧⌘S · ⇧⌘B | Show or hide the sidebar · the right pane |
| ⇧⌘M | Model picker |
| ⌘. | Stop the agent |
| ⌥⌘↑ · ⌥⌘↓ | Previous · next turn |
| ⌘I | Inspect subagent |

Fixed chords:

- ⌘1–9 select agents in sidebar order (hold ⌘ to see the badges).
- ⌃⇧1–9 jump to machines (this Mac is always ⌃⇧1).
- ⌘, opens Settings, and ⌘F searches it.
- ⏎ confirms and ⎋ cancels in sheets.
- In the composer, ⏎ sends and ⇧⏎ inserts a newline. `/` at the start opens the command list, and
  Esc closes a menu.

Review-pane and menu keys are listed with their surfaces.

## Accessibility and motion

- **Controls:** every control is a real `Button`, `Toggle`, or text field, or carries button
  traits and actions (sidebar rows are tap views so they can also be dragged). Icon-only buttons
  carry an `accessibilityLabel`, and hover-only affordances (the sidebar's `+`, a comment's Edit
  and Delete, a diff line's `+`) are always reachable as buttons or named actions for VoiceOver.
- **Rows read as one element:**
  - agent rows: "title, [worktree,] running / needs you / idle / done"
  - subagent rows: "name, subagent, state"; automation rows: "name, automation, state"
  - activity lines: "Explored 7 files, read 5, search 2, 0.9s, done", with Expanded / Collapsed
    and the hint "Shows the calls"; call rows: "edit, Sources/A.swift, +58 −41"
  - subagent cards: "name, role, state, detail", with the context bar as the value; ledger rows:
    "name, state, summary"; runs strip steps: "name, state — open"
  - diff lines: "Removed line 16: …", with Comment as a named action; file chips: "FleetView.swift,
    modified, 10 added, 54 removed, viewed"
- **Resizing:** the sidebar edge and the right pane's handle are adjustable elements that read
  their width.
- **Modality:** the palette is modal for VoiceOver while it is up.
- **Color:** status color is always paired with a word or a glyph shape, and contrast follows the
  rules above.
- **Focus:** keyboard focus shows the running focus ring; a click never does.
- **Reduce Motion:** the glow and spinners are static; panes, sheets, and expanding rows
  cross-fade briefly (120ms) instead of moving; turn jumps and scroll-to animations are dropped.
  Otherwise motion uses the `NW.Motion` durations.
- **Menu bar:** every pane and agent action exists in the menu bar with its shortcut (File,
  View, Pane, Space, Agent, Machines, Appearance).

## Known gaps

These places in the code break this document and should be fixed toward it:

- **Literal dimensions in app views:** the tool-output sheet's size and padding
  (`ToolOutputSheet`), the question panel's 140pt message cap, the empty thread's top offsets,
  the empty workspace's 420pt measure, and `PanePlaceholder`'s padding should move into
  `AppLayout+Thread.swift` and `AppLayout+Navigation.swift`.
- **An ad-hoc alpha:** the pane divider beside the focused pane is `running` at 34% opacity, not
  a theme role.
- **Hand-built chrome:** the review header and its ⋯ menu, and the inspector's ⋯ menu, repeat
  `NWPaneHeader` and `NWOptionsMenu` by hand.
- **1pt strokes:** several control borders (secondary and danger buttons, fields, pickers and
  popups, keycaps, pills, banners, the sheets' text editors, the "Jump to latest" capsule) stroke
  1pt rather than a 1px hairline.
- **Chords in copy:** Settings ▸ Agents' explanation names ⌘N and Settings ▸ Terminal's shell
  row names ⌘D in plain text, so a rebound chord leaves them wrong. They should read from
  `KeybindingsStore` or not name the chord.

## iOS

The iOS client (`App/iOS`, [docs/ios](docs/ios/README.md)) is deferred. It predates Night Watch,
does not link ShepherdUI, and keeps its own `MobileTokens`. It will adopt ShepherdUI (which
already builds for iOS 27: fonts follow Dynamic Type through `relativeTo:`, and icon buttons grow
to `NW.Height.touch`, 44pt) later, with navigation instead of the sidebar.

## Verifying visuals

- **Previews:** `ShepherdPreviewTests` render every surface offscreen, in light and dark:
  - thread states (idle, running, thinking, queued, failed, prose, question, empty) and the
    activity-line states
  - the composer and its menus
  - subagent cards, the ledger, and the inspector
  - the review pane
  - the palette, the toolbar, the sidebar at each row density, and the window at its minimum
  - every Settings page, sheet, and dialog
  - the empty states

  They write `<surface>-<light|dark>.png` into `$SHEPHERD_PREVIEW_DIR` (the suites are skipped
  when it is unset), so you, or an agent, can look at them:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
  ```

- **Windows:** preview windows sit off-screen and never take focus.
- **Component Gallery:** in Debug builds, the View menu has a Component Gallery.
- **The running app:** build and run the `Shepherd (Dev)` scheme and check the change in both
  appearances.
