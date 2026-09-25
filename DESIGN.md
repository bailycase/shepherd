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
- **Terminals** exist only as panes of an agent's layout, shown in the terminal panel under its
  thread: the user opens one with ⌘D or the panel's +, or an agent opens one with its `pane_*`
  tools. There are no global shells, no space shell workspaces, no agent rendered as a terminal,
  and no Terminal/Native switch.

## Principles

In priority order:

1. **Readable measure.** The thread column is at most 820pt, and agent prose is capped at 640pt.
2. **Shape, not labels.** There are no speaker labels or avatars. A user turn is a trailing
   bubble; agent output is unboxed prose.
3. **One quiet line per stretch of work.** The tool work between two pieces of prose reads as
   one line ("Worked for 6m 40s · explored 13 files · edited 15 files · ran 22 commands"). Its
   lines, one per burst of same-kind calls, are one click away; raw arguments are behind ⌥-click.
4. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats what the thread and the sidebar row already say, no working directory under the composer, no footers in menus.

And the rules that follow from them:

- **Flat surfaces separated by 1px lines.** Surfaces step from `bgBase` (chrome) to `bgWindow`
  (the thread) to `bgRaised` (cards, the composer, menus), with `bgSunken` for code and headers.
  Separation is a hairline, never a shadow.
- **One shadow.** `.nwPopover()` (menus, the palette, popovers) carries the system's only
  shadow. The sidebar and the right pane borrow it (`.nwFloatShadow(_:)`) only while they float
  over the window, and the switch and slider knobs have a small knob shadow. No vibrancy, no
  translucency, no gradients except the fade above the composer.
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
| Colors as asset-catalog colorsets | A runtime theme model: `ThemeDefinition` is data (hex, `Codable`), resolved into `Color.nw` | User themes later; the roles are the contract |
| Fonts through `ATSApplicationFontsPath` / `UIAppFonts` | Registered from the package bundle at launch (`NWFonts.register()`), no Info.plist entry | ShepherdUI is a package, not an app target |
| A `ShepherdDesign` package | `Packages/ShepherdUI` | Name |
| `NavigationSplitView` with `.inspector` for the right pane | Shepherd lays the window out itself (`RootView`, `RightPaneSplit`) | Its own adaptive rules (`ShellLayout`) decide what docks and what overlays |
| Running sidebar rows draw a sparkline | Running rows show elapsed time; `NWSparkline` exists but nothing uses it | Nothing records an agent's tool calls per minute |
| Queue & steer: Steer "lands after the tool call pi is running now; the rest of that step is skipped", and "Skipped the rest of that step · N planned edits" in the thread | "Lands once pi's current tool calls finish, before its next step", and no Skipped line | pi 0.87.1 runs every call in a batch before it reads a steer: nothing is skipped, so nothing may say so (honest affordances) |
| Queue & steer: the stack and composer at radius 10, rows and fields at 7, chips at 5, the Send menu at 10 | 8 (the composer's), 6, 4, and the popover's 12 | The radius scale |
| Queue & steer: 5px gaps (the Steering pill, "Steered", "From the queue", a compact chip); 1px lines outside each 40px row, the 32px header and the card | 6 in the pill, 4 elsewhere; lines drawn inside, so three rows make a 152pt stack (the board's 157) | The space scale's 4pt steps; every card and list in the app draws its lines inside (`nwBorder`, `NWHairline` overlays) |
| Queue & steer: a custom 280pt QueueOptions popover; tooltips with keycaps | The native ••• menu (`NWOptionsMenu`); system tooltips (`.nwHelp`) | As every other ••• and tooltip in the app |
| Queue & steer: the Send menu beside the card, highlighted in `bgSelected` | Beside the card where the thread has room for it; in a narrower thread above Send, trailing edges aligned, over the trailing end of Up next while it is open; the composer menus' `runningTint` highlight | The app's column is 820pt (the boards' 620), so the room beside it runs out; the menus' one anatomy |
| Queue & steer: a row's actions take room only while it is hovered | An 82pt slot is always laid out, empty at rest | Details on hover: hovering never re-truncates the text |
| Queue & steer: message times at rest | On hover (Details on hover) | The thread's rule |
| Queue & steer: "Pi" | "pi" | The app's spelling, until the rest of that redesign lands |
| Background events as in-app toasts (`.nwToast`) | A system notification when an agent finishes a turn, fails one, or asks a question, or one of its subagents asks, while you aren't watching it (`AgentNotifications`; see Status language) | Reaches you outside the app |
| Missions, the mission graph, the attention inbox, evidence review (Lab boards) | Not built | Out of scope for this pass |
| NavAutomations: an Automations page with a table (When, Starts, Host, Last run, Next), filters, and New automation | The sidebar's Automations footer for this Mac; a remote host's Automations disclosure and its Details and Runs sheet | Shepherd's automations have no schedule or trigger: one is on (it starts a run when Shepherd launches) or run by hand, and nothing on the Mac creates one yet but an agent's `automation_*` tools |
| ⌘M opens the model picker (earlier handoff) | **⇧⌘M** | ⌘M is the system Minimize chord |
| Terminal: ⌃\` shows the panel, ⌃⇧\` opens a tab, ⌘K clears, ⇧⌘[ ] switch tabs | **⌘J** shows or hides it; + or ⌘D opens a tab; no clear or tab-switch chord | Every rebindable chord needs ⌘, ⌘K is the palette, and a tab is one click away |
| Terminal: the panel's terminal on `bgBase` | On `bgWindow`, the theme's terminal background | Terminal panes keep one surface everywhere |
| Terminal: rename a tab, Kill process, New terminal on This Mac, Run in terminal, send output to pi | Not built | Out of scope for this pass |
| A compose button beside the window controls and a "Jump to…" field above the sidebar tree | Neither: the tree starts under the window controls | The sidebar is navigation only; ⌘K opens the palette and ⌘N (or a space's hover `+`) starts an agent |

Additions the boards don't have:

- **A paused queue** (Up next): after Stop, or a turn that failed, the queue waits: "Paused" in
  its header (why, in the tooltip), and each row's Steer now reads **Send now** (the ••• menu's
  Send all now) while pi is idle.
- **Undo for Clear the queue**, as for a single delete.
- **Transcript search** in the palette ("Found in conversations").
- A **quit confirmation** while agents are working.
- A **one-time notice** under the toolbar after an update moved a copy of Shepherd off the
  retired nightly channel (`NightlyMovedNotice`): an idle `NWBanner` capped at the thread's
  820pt, with Get Shepherd Nightly and Dismiss. It blocks nothing and stays until dismissed, and
  it leaves at once rather than easing the column's height, which would relay out every mounted
  layout on each frame.
- **Shepherd Nightly's icon** (`App/AppIconNightly.icon`): the crook in lantern under a
  `textPrimary` crescent moon, on the same black, so the two apps tell apart in the Dock and ⌘Tab.

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
- `focusDivider`: running at 34% in both appearances, for a pane divider beside the focused pane
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

## Space, radius, height, elevation

- **Space** (`NW.Space`, 4pt grid): `xxs 2`, `xs 4`, `s 6`, `m 8`, `l 12`, `xl 16`, `xxl 24`,
  `xxxl 32`. Padding and gaps use only these steps.
- **Radius** (`NW.Radius`): `xs 4` pills, keycaps, chips · `s 6` buttons, fields, rows · `m 8`
  cards, the composer, code blocks · `l 12` popovers, the palette.
- **Height** (`NW.Height`): rows `rowCompact 22` (diff lines), `row 28` (sidebar, menus),
  `rowComfortable 36` (ledgers), all scaled by Density and rounded to whole points
  (`NW.Height.scaled(_:)` for other row heights); controls `controlS 24`, `controlM 28`,
  `controlL 32`, which never scale; `touch 44` on iOS.
- **Hairlines** are 1px, not 1pt: `NWHairline`, `.nwBorder(_:radius:)`, and
  `.nwBorder(_:in:dash:)` (any shape, optionally dashed) use `NW.hairline(displayScale)`. Every
  border of a control, field, pill, keycap, banner, card, or bubble draws through them. Three
  kinds of line stay in points: the layout's dividers (pane splits and the edges of the docked
  sidebar and right pane, 1pt, because the window's arithmetic counts them), the checkbox's
  1.5pt border (the Controls board draws it heavier than its 1px lines), and the strokes of
  status dots and glyphs.
- **Elevation:**
  - `.nwCard()`: flat, a raised fill and a 1px line (`lineSubtle` unless given).
  - `.nwPopover()`: a raised fill, a 1px `lineStrong` line, radius 12, and the only shadow.
  - `.nwFloatShadow(_:)`: the popover's shadow on the sidebar or right pane while it overlays
    the window, and nothing while docked.
  - `.nwFocusRing()`: running blue at `focusRing`, 2pt wide, drawn outside the control, for
    keyboard focus only (`.nwFocusRing(_ visible:)` for a field or card whose focus the caller
    tracks; `.nwFocusRingCircle()` for icon buttons).
- **Icons:** SF Symbols, monochrome, medium weight: 14pt in icon buttons, smaller inline. Status
  glyphs come from `AgentState` (`NWStateGlyph`); never emoji. The Foundations board names the
  symbols to use
  (`sidebar.left`, `square.and.pencil`, `arrow.up`, `stop.fill`, `paperclip`, `lightbulb`,
  `arrow.triangle.branch`, `plus.forwardslash.minus`, `ellipsis`, `magnifyingglass`, `bolt`,
  `desktopcomputer`, …).

## Motion

Shepherd moves the way a native Mac app does: things come from somewhere, go somewhere, and
never jump, and nothing moves for decoration. `NW.Motion` (`Tokens/Motion.swift`) holds every
motion. The Foundations board's durations are the anchors (hover 120ms, panes 180ms, sheets
240ms, the glow 1.6s, the spinner 1s, the skeleton 1.4s), and every one-shot motion runs on a
SwiftUI spring at its anchor.

**Why springs.** A spring keeps its velocity when a change is interrupted, so a hover flicked in
and out, or a pane toggled twice, retargets from where it is instead of restarting. A spring's
duration is perceptual: at its anchor a change reads as done (98.6% of the way for `.smooth`), and
the last fraction of a point settles by about 1.7× the anchor. Anything that moves layout or
slides from an edge is critically damped (`.smooth`, no overshoot), so a pane never pulls away
from the window's edge and a row never overshoots its slot. Only overlays (`.snappy`, 0.6%
overshoot as they grow from their anchor) and the confirmation pop (`.bouncy`, 4.6%) bounce.
`MotionTests` (ShepherdUI) pins all of this.

| Motion | Anchor | Curve | For | Comes and goes by | Under Reduce Motion |
| --- | --- | --- | --- | --- | --- |
| `hover` | 120ms | `.smooth` | hover and press fills, focus rings, a control's color, details shown on hover (a message's time, a turn's footer) | fading | unchanged |
| `content` | 120ms | `.smooth` | a value or label changing in place: counts, status words, an icon | cross-fading (`nwContentTransition`) | unchanged; rolling digits and symbol swaps cross-fade |
| `disclosure` | 180ms | `.smooth` | expanding and collapsing in place, the chevron turning | a 6pt nudge from the top, fading | a 120ms cross-fade |
| `list` | 180ms | `.smooth` | rows arriving, leaving, reordering | a 6pt nudge, fading | a 120ms cross-fade |
| `pane` | 180ms | `.smooth` | the right pane, the sidebar (docked or overlaid) | sliding from its edge, opaque | a 120ms cross-fade in place |
| `overlay` | 180ms | `.snappy` | the palette, composer menus, popovers | growing from 96% at its anchor, fading | a 120ms cross-fade |
| `sheet` | 240ms | `.smooth` | in-window sheets, a whole-window swap (Settings), toasts | rising from its edge, fading | a 120ms cross-fade |
| `emphasis` | 240ms | `.bouncy` | a small confirmation pop (viewed, copied, sent) | popping from 85% | nothing |
| `scroll` | 240ms | `.smooth` | turn jumps, revealing a row | — | instant |
| `glow` | 1.6s | ease-in-out, repeating | attention only | — | static |
| `spin` | 1s | linear, repeating | running work | — | static |
| `shimmer` | 1.4s | ease-in-out, repeating | loading placeholders | — | static |

The glow, the spinner, and the shimmer are clock-driven (`NWPhase`), so Reduce Motion can change
while they are on screen. The spinner and the glow are render-server animations: Core Animation
turns the arc and pulses the dot on their own layers (`NWLayerSpinner`, `NWLayerGlowDot`),
started at the clock's phase so every one moves in step, and one on screen costs the app no
frames (drawn by a SwiftUI timeline, a single spinner redrew its window on every display frame;
in an off-screen test window, whose host also relaid out tens of thousands of times a second,
that was most of a core in a debug build). The shimmer stays a timeline. None of them
moves under `nwMotionPaused` (see Performance). A Reduce Motion cross-fade still eases the
layout a change moves (the rows under an opening disclosure, a column a pane narrows) over its
120ms; only what arrives or leaves stops travelling.

**Applying motion.** Never write a duration or a curve in a view: an ad-hoc
`withAnimation(.easeOut(duration: 0.15))` is a bug, like a hardcoded color.

- **State a view model or store changes** (a pane opened from a menu, the palette from ⌘K, a row
  a server broadcast adds): the view attaches the motion, `.nwAnimation(_:value:)` on the
  container and `.nwTransition(_:edge:)` on what comes and goes, so every path that changes the
  value animates the same way.
- **State an action changes** (a click, a key): `withNWAnimation(_:_:)`, which reads Reduce Motion
  from the system; its `completion:` form fires once the motion has finished.
- **Content changing in place:** `.nwContentTransition(_:)` (`.numeric`, `.interpolate`,
  `.symbol`, `.crossFade`) with `.nwAnimation(.content, value:)`.
- **A confirmation:** `.nwPop(trigger:)`, or `.symbolEffect(.bounce, value:)` on an SF Symbol.
- An overlay grows from its anchor: `.nwTransition(.overlay, anchor: .bottomLeading)` for the
  composer's menus, `.top` for the palette.

**What never moves.** `.nwInstant()` drops the animation a change arrives with (an ancestor's
`nwAnimation`, a `withNWAnimation`) for its subtree; motion attached inside the subtree still
runs. Put it on what must not move, as close to it as possible.

- **Switching agents** is a visibility flip, and **keyboard navigation** (⌘1–9, ⌘↑/↓, a palette
  or menu highlight, j/k in the review) lands at once.
- **Terminal surfaces** never change size frame by frame. SwiftUI resizes a hosted NSView on every
  frame of an animated layout change (about 70 times for one 180ms pane), and for Ghostty each is
  a PTY resize. With `.nwInstant()` on the terminal view it takes its new size once while
  everything around it moves; `MotionProbeTests` pins both.
- **Streaming text** appends without motion; a finished part may fade in once. Clock text
  (elapsed times) ticks without rolling.
- **Long lists** animate what changed, never the whole list: a thread's `LazyVStack` must not
  animate every row when one turn arrives.
- **Columns take their new width at once** while a pane or the sidebar slides beside them: the
  thread beside a docked right pane, the main column beside the docked sidebar, and split
  panes. A long thread relaid out on every frame of a slide drops frames (measured in a debug
  build: gaps up to 55ms beside one thread and 171ms with five mounted layouts, against under
  9ms for plain content), so the column snaps as the motion starts and the pane slides into or
  out of the room. Window resizes, divider drags, and docked ⇄ overlaid flips never animate.
- **Selection** changes no row, so it lands at once; only rows arriving, leaving, reordering,
  or disclosing animate a list. Each agent's toolbar has its own identity, so switching never
  animates one agent's status or counters into another's.

## Performance

A list is as fast with three hundred rows as with thirty: it builds the rows on screen, and a
change redraws the rows it changed. `ListPerformanceTests` pins each rule below with a count of
row bodies (`NWRenderProbe`), which a slower machine doesn't change, and
`SHEPHERD_PERF_REPORT=1 swift test --filter ListPerformanceReport` prints each list's timings
against a large fixture (300 agents in 40 spaces, 1,000 palette results, a 2,000-line diff and a
300-file review, a 500-turn thread, 200 subagent runs, 2,000 folders).

- **Anything that can outgrow a screen is lazy.** The sidebar tree, the palette's results, the
  thread and the inspector's transcript, the review's diff and file strip, the run ledger, and
  the directory and model lists are `LazyVStack`s or `LazyHStack`s with stable ids. Eager stacks
  are for lists bounded by design (Settings rows, a dialog's checklist, a composer menu). A lazy
  stack in a height-capped, fixed-size scroll view still hugs a short list (the palette does).
  A list inside one of the thread's own rows is measured before it is nested: the run ledger
  builds lazily (about 6 ms a scroll step, against one 150 ms build for 200 runs), while a
  300-file changes card cost 20 ms a step nested and stays eager (one 250 ms build).
- **One view per row.** In a lazy `ForEach`, each element makes exactly one view: wrap an `if` or
  a `switch` in a container. A row that could be nothing (`if … else if …` with no `else`) makes
  SwiftUI build every row to count them, on every update: a 500-turn thread built 1,000 rows per
  streamed chunk until its rows were wrapped.
- **Rows are plain `Equatable` values.** Closures stay out of `==`. The highlight or the
  selection reaches a row as a `Bool`, so moving it redraws the row it leaves and the row it
  lands on; hover lives in the row itself. A store or the view model derives the rows once per
  change (`SidebarTree`, `PaletteResults`, `DirectoryFilter`, the review's row cache): no
  filtering, sorting, or formatting in `body`.
- **A derivation is one pass over its inputs.** Group a collection once
  (`sidebarAgentsBySpace`) rather than filtering all of it for each group, and read what is
  memoized (the space forest) rather than building it again for a selection. At 1,500 agents in
  200 spaces a status report took 59 ms and a selection 57 ms until both were.
- **Rows are cheap to build**, since scrolling builds them. Platform-backed modifiers cost most:
  one drop target covers the sidebar (`SidebarDropZone`, fed the frames the rows on screen
  register) instead of one per row, and a control that shows only on hover (a diff line's `+`)
  is built only while hovered, in a slot that is always laid out.
- **Motion never scales with the list.** A list's motion watches a small key (a layout count, the
  rows' ids), never the rows themselves, and rows scrolled back into a lazy stack are simply
  there: an entrance plays only for what arrives while the list is on screen (`nwArrival`,
  `nwRunArrival`).
- **Motion no one sees costs nothing.** A layout the workspace keeps mounted behind the visible
  one sets `nwMotionPaused`, and a continuous motion pauses while its view is off screen
  (between `onDisappear` and `onAppear`: a lazy stack keeps a row it let go of for a while). A
  restored workspace of twelve agents drew about 6,000 spinner frames every 4 s idle until they
  did (about 4 s of main-thread CPU in an off-screen test window); `IdleCostTests` counts the
  frames.
- **Motion on screen runs on the render server.** A spinner or a glow is a Core Animation
  animation on a layer (see Motion), never a view redrawn per frame: one spinner drawn by a
  timeline cost 2.8 s of main-thread CPU every 3 s in an off-screen test window, and now costs
  what an empty window does.
  `IdleCostTests` checks that one turning and one glowing draw no frames and never lay the
  window out.

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
│ ● ● ●            │ Title                       42k ctx  ⎇ ± ⋯   │ Review      ⋯  ×     │
│ THIS MAC     19  ├──────────────────────────────────────────────┼──────────────────────┤
│ ⌄ Shepherd    8  │         820pt thread column                  │ right pane:          │
│   ● agent   ASK  │                       ┌──────────────┐       │ review or subagent   │
│   ● agent    4m  │                       │ user bubble  │       │ inspector, 600pt     │
│   ○ agent        │                       └──────────────┘       │ (min 480, ≤ half)    │
│ HORIZON          │   agent prose, 640pt measure                 │                      │
│   ● Unreachable  │   ✎ Edited 4 files  +149 −63  ›              │                      │
│                  │   ┌ composer ──────────────────────────┐     │                      │
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
  with its terminal panel under it (Terminal panel, below). Pane dividers are 1pt `lineSubtle`, tinted
  `focusDivider` where they border the focused pane; dragging one keeps each side at least
  160pt, between 15% and 85%.
- **Switching agents flips visibility; it never remounts.** Every mounted layout stays in the
  view tree, and hidden ones are `opacity(0)`. This is what makes switching instant.

**Adaptive rules** (`ShellLayout`, pure and unit-tested in `ShellLayoutTests`):

- **Sidebar.** It docks while the main column keeps 720pt beside it, narrowing to fit (to no
  less than 190pt). In a window narrower than that allows (190 + 1 + 720 = 911pt), it hides on
  its own, and ⇧⌘S or the toolbar's sidebar button shows it as an overlay: its width, at most the
  window width minus 48pt, over the workspace with the popover shadow. Picking a row or clicking
  outside closes the overlay. ⇧⌘S in a wide window hides and shows the docked sidebar. Either
  way it slides from the leading edge (`.pane`); a window resize that hides or docks it is
  instant.
- **Toolbar inset.** While the sidebar is not docked, the toolbar's content moves a further 70pt
  in to clear the window controls (none in full screen) and leads with a sidebar button.
- **Right pane** (review or subagent inspector, `RightPaneSplit`). It docks while the main
  column is at least 881pt (layout 400 + 1 + pane 480): 600pt by default, at least 480, at most
  half the column, and the agent's layout (its thread and any terminal panes) always keeps 400.
  Narrower, the pane overlays the layout from the trailing edge with the popover shadow. Its leading edge is the drag handle (9pt hit area,
  adjustable with VoiceOver in 40pt steps), and the width persists app-wide
  (`shepherd.rightPaneWidth`). No width is ever negative. It slides in from the trailing edge
  (`.pane`), and its content cross-fades when the review and the inspector swap.
- **Palette:** 620pt wide, or the window minus 16pt margins, and never taller than the window
  leaves room for (`NWPaletteMetrics.placement`).
- **Composer:** in a narrow thread the chips drop their words ("/" alone, the thinking level
  alone) instead of truncating mid-word (`ViewThatFits`).

## Surfaces

### Sidebar

`SidebarView` (`SidebarView.swift`, remote sections in `RemoteSidebarSection.swift`) on
`NWSidebar`.

- **Top bar (44pt):** room for the window controls, as tall as the toolbar beside it, and
  nothing else: it drags the window, and the tree starts beneath it with the first section's
  12pt top padding. There is no compose button and no search field above the tree. ⌘K (and the
  menus) open the command palette; ⌘N, a space's hover `+`, the palette, and the menus start an
  agent.
- **Sections** (`NWSidebarSection`): a micro caps label with a trailing count; clicking it folds
  the section. With remote hosts configured, hovering a header shows its machine chord (⌃⇧n).
  1. **This Mac**, with its agent count and a hover `+` for New Space….
  2. One section per remote host. Connected: its agent count, or "n need you" in `lanternText`
     (blocked agents plus subagents asking), and a hover `+` for a new space on the host.
     Otherwise one status row (`NWSidebarNoticeRow`) stands in for its spaces: "Connecting…",
     "Unreachable" with Retry, or "Off" with Connect. A connected host with automations ends
     with an **Automations** disclosure under its spaces (a space's row: its count, or how many
     runs wait on you), closed by default and remembered per host.
  3. **Automations** as the footer (`NWSidebarFooter`), behind a hairline and hidden while
     empty: a bolt, "Automations", and a count badge that turns `attention` while an
     automation's agent needs you. Clicking it discloses the automation rows.
- **Spaces** (`NWSidebarDisclosureRow`): chevron, name in medium weight, then a `⎇n` worktree
  count and, in `lanternText`, how many questions wait on you (blocked agents plus subagents
  asking; `SidebarAttention`), else the agent count. Clicking toggles the space; it has no view
  of its own. A hover `+` starts a new agent in the space. Nested projects indent by path
  containment, and agents nest beneath their space.
- **Rows** (`NWSidebarRow`): the density's height, radius 6, 8pt leading padding plus 14pt per
  nesting level, and a 9pt gap after the dot.
  - A 6pt dot: `running` blue, `done` green, a hollow `textTertiary` ring while idle, and
    `lantern` glowing while it, or one of its subagents, needs you.
  - `⎇` marks a worktree agent. The title truncates at the tail, with the full title (and the
    worktree branch) in a tooltip.
  - Hover is `bgHover`; selected is `bgSelected` with the title in semibold.
- **Trailing slot** of an agent row, in priority order (`SidebarAgentRowModel.accessory`):
  1. the ⌘-digit badge while ⌘ is held
  2. "ASK" in `lanternText` while it, or one of its subagents, needs you
  3. elapsed time while working ("4m", counting live in mono 10)
- **Subagents have no rows.** They live in their agent's thread (cards, the runs strip, the
  ledger, and the inspector; see Subagents below) and in the palette. A subagent waiting on you
  surfaces through its agent's row, which takes the needs-you dot and "ASK", and counts toward
  its space's and host's needs-you counts, so the row to click is always marked. Live and
  finished subagents leave the agent's row as it is.
- **Automation rows:** the automation's name, and its run's state: "running", "ASK", "done", or
  "stopped" (a hollow dot, not selectable). The context menu has Run Now or Stop, and Delete
  Automation.
- **A remote host's automation rows** (`RemoteSidebarSection.swift`) nest one level under its
  Automations disclosure with the same dots and words, plus "off" for one that does not start
  with Shepherd. Clicking a row opens its run's thread, or its details while it has none. The
  context menu has Run Now or Stop, a Starts with Shepherd check, Details and Runs…, and Delete
  Automation; on a host from before automations over the remote protocol the menu says why it
  is read-only and disables them. Details and Runs… is a sheet (`RemoteAutomationSheet`,
  NavAutomations' detail pane): the On switch with what it means, Status, Host and Folder rows
  (`NWFactRow`), the prompt (`NWAutomationPrompt`), the latest fourteen runs as bars as tall as
  each took (`NWRunBars`: done green, asked lantern, interrupted failed, stopped tertiary), and
  every run the host kept (`NWRunRow`), a run opening its thread while that thread exists.
  Its footer is Close and Run Now, or Open Run and Stop while one runs.
- **Width:** 232pt by default, 190–340, by dragging the trailing edge (a 9pt handle, adjustable
  with VoiceOver in 16pt steps) or in Settings ▸ Appearance. It never narrows the main column
  below 720 and keeps its width while a right pane is open.
- **Interaction:** rows are tap views with button traits and accessibility actions, so they can
  also be dragged to reorder (with a 2pt running drop line, `NWDropIndicator`, at the row's top
  or bottom edge). Only drags that started in this sidebar qualify. Hover `+` glyphs are real
  labeled buttons (and always present for VoiceOver). Hovering never moves or resizes anything:
  the machine chord and the `+` are always laid out and only fade in, and the `+` takes the
  count's slot (a header's floats over it, since it is taller than the label). Keyboard
  selection (⌘1–9, ⌘↑/↓, ⌃⇧digits) scrolls the row into view.
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

- **Layout:** a scroll view with the column centered, at most 820pt wide with 32pt gutters (16pt
  in a thread narrower than the column and both gutters, 884pt; `AppLayout.threadGutter`). 28pt
  top margin, 28pt between turns, 14pt between a turn's parts, and 6pt between consecutive
  activity lines.
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom
  (`NativeScrollFollower`). Only a live scroll gesture or a wheel tick detaches it; content
  growth, the composer resizing, and history swaps never do. While a gesture is live, layout
  changes never move the view either: a drag up measures the rows it reveals, and landing on
  the tail then would pull the thread out from under the finger. "↓ Jump to latest"
  (`NWJumpToLatest`, a `bgRaised` capsule above the composer) appears while detached if the
  agent runs or unseen output arrived. The composer draws it over the fade it lays on the thread
  and under its card and menus, so the fade never washes it out and it never covers an open
  menu. Sending re-attaches. The composer floats over the scroll view, which is inset by the
  composer's measured height, so the thread always ends at its last turn.
- **Turn jumps:** ⌥⌘↑ and ⌥⌘↓ move between user turns (the target lands at the top); stepping
  past the last returns to the tail.
- **History:** "Load older messages" (a small ghost button) heads a thread that has older pages.
- **Notices** above the thread explain degraded states in caption tertiary: "Last known thread ·
  refreshing before enabling actions", "This host's pi cannot answer questions here · update
  Shepherd on the host", "Some earlier output is clipped".
- **Starting:** while pi boots (a new agent, or one resuming after a relaunch) the thread is
  ready to use and quiet, never an error: it draws what it knows at once (a new agent's empty
  state, a resuming agent's history), and a message sent meanwhile waits for pi. Nothing says
  pi is starting unless pi is slow: past two seconds (`AppLayout.startingIndicatorDelay`), well
  beyond a normal start (pi answers about 0.8 s after ⌘N, about 1 s after a relaunch), or past
  half a second (`AppLayout.blankStartingIndicatorDelay`) while the thread has nothing to show
  (a remote agent's, or one whose session file cannot be read). Then the composer's control row
  says so (see Composer › States). There is no spinner in the thread and no starting row at its
  tail. A pi that has not started after a minute gets the error banner.
- **Resuming:** an agent resuming after a relaunch shows its history at once, read from pi's
  session file (`PiSessionPreview`): the newest page, the model, and the thinking level, drawn
  exactly as pi's history is. Nothing in it acts yet (retry, load older, subagent actions)
  until pi answers, and pi's first snapshot then lands on the same rows, so nothing moves or
  flashes. Only what pi alone knows arrives with that snapshot: the "/ commands" chip (and the
  placeholder's "or / for commands"), and the toolbar's context counters. An agent whose file
  cannot be read stays blank until pi sends its history.
- **Empty thread:** a framed `NWEmptyState` (a dashed `lineStrong` border, no crook): "New
  agent in `~/path`" (the path in Geist Mono 15 medium within the 17pt title), with "Describe
  the task. Drop or paste images to attach them, or type / for commands." A new agent is known
  to be empty, so it shows from the first frame, with the composer ready, while pi boots behind
  it. While a thread's history is not known yet (a resuming agent without a readable session
  file) the thread stays blank until pi sends it; an empty history then fades the state in.

**User turn** (`UserTurn` in `Thread/ThreadTurns.swift`, on `NWUserBubble`):

- Right-aligned, at most 600pt, `bgBubble` with a 1px `lineStrong` line, radius 8, 10×14
  padding, body text. No avatar and no name.
- The time sits beneath in mono 10.5 tertiary, only while the turn is hovered (see **Details on
  hover** below). Sent images show as attachment chips.
- A message sent while pi is idle shows at once, at 70% opacity until pi reads it. One sent
  while pi works never enters the thread early: it waits in the composer's **Up next** (see
  Composer) and joins the thread only when pi reads it, where pi read it.
- **From the queue:** messages the queue delivered together (one turn for pi) open with
  `NWQueueDivider`, "From the queue · 2" (just "From the queue" for one) in caption tertiary
  with the queue glyph between two hairlines, then one bubble per message, 6pt apart, each with
  the time it was sent (on hover, like any bubble's).
- **Steered:** a message steered into a running turn stands inside that turn where pi read it
  (after the tool calls it waited on, at the turn's 14pt item spacing), so the turn keeps one
  footer and one changes card. Its bubble wears "Steered" above it (`arrow.turn.down.right` 11
  and caption medium, both `running`) and a `running` line instead of `lineStrong`; its time
  shows on hover. After a relaunch a steer pi read after its final message reads as an ordinary
  new turn.

**Agent turn** (`AgentTurn`): consecutive assistant messages render as one turn. Its parts are
thinking, prose, activity lines, subagent cards where their spawn calls were, notes, and errors,
in the order they happened (each stretch of work between prose opens with its thinking). Once
the turn has finished, the changes card and the footer end it. A running turn has no footer.

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
  run. The whole row, link included, shows only while the turn is hovered.

**Details on hover.** A message's time and a finished turn's footer are hidden at rest, so a
thread reads as the conversation alone; the pointer over the message (anywhere in the turn's
row) shows them.

- **Nothing moves.** Hidden, they keep their place and draw nothing; they only fade (`.hover`,
  unchanged under Reduce Motion). A turn measures the same hovered or not.
- **Also shown** while one of the footer's controls has keyboard focus, for the moment a copy
  confirms, and whenever VoiceOver runs, so Copy response, Retry turn, the subagents link, and
  the time are always reachable (`NWMessageDetails`).
- **Per message.** Each turn owns its pointer state (`MessageHover` in `ThreadTurns.swift`), and
  its whole row counts, gaps and the hidden details' place included. Only what shows the
  details reads it (an agent turn's footer; a user turn, which is just its bubbles), so the
  pointer crossing a thread never re-renders an agent turn's parts, other turns, or the thread.
- The subagent inspector's transcript follows the same rule; there "from parent" always shows
  under a message from the parent, and its time fades in beside it.

**Work groups** (`WorkGroupView` in `Thread/ThreadTools.swift`, `nativeWorkGroup`). A stretch's
activity lines (between prose, notes, errors and subagent cards) form one group, so a long turn
never reads as a wall of lines.

- **Folded:** two or more finished lines fold into one summary line, `NWActivityLine` with the
  `work` glyph (`rectangle.stack`): "Worked for 6m 40s" (wall time over its calls; "Worked"
  untimed) · "explored 13 files · edited 15 files · ran 22 commands · 17 tests passed · 5
  failed". Kinds always read in that order (explored, edited, ran, started, used); the lines
  keep the order the work took.
- **Expanded:** the lines, as below, on the same `lineStrong` rail as a line's calls
  (`NWActivityRail`).
- **One line** stays itself: it already is one line.
- **Running calls** stand below the summary as live lines, and join it when they finish.
- **Failures are counted, not shouted.** A failed call adds "n failed" to the meta and is red
  only inside the expanded lines. The summary turns `failed` only when the group's last call
  failed and nothing runs after it: the work ended on a failure.

**Activity lines** (`ActivityLineView` in `Thread/ThreadTools.swift`, on `NWActivityLine` and
`NWActivityCalls`). Within a group, a turn's tool calls merge into one quiet line per burst of
same-kind work (`nativeActivityBursts`). A failed call and the running call each stand alone;
other tools merge only with the same tool.

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

`Composer` (`Thread/Composer.swift`) on `NWComposer`, `NWSlashMenu`, `NWModelPicker`,
`NWThinkingMenu`, and `NWSendMenu`, with Up next above the card (below). Sizes are
`NWComposerMetrics`.

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
- a spacer, then "Starting pi…" only while a slow pi keeps the thread waiting (see States),
  then the action, a 28pt circle: **Send** (an arrow on `lantern`, at 35% until there is
  something to send) or **Stop** (a square on `failed`). While pi works with a draft, Stop steps
  aside **outlined** (a `lineStrong` hairline, no fill, `bgHover` under the pointer, the square
  in `failed`) and Send takes the corner, 6pt apart; filled Stop ⇄ outlined Stop + Send
  cross-fades (`content`).

Chips are 26pt ghost buttons in 12pt `textSecondary`, filled with `bgHover` on hover or while
their menu is open.

**States:**

- **Idle:** Send. The placeholder is "Follow up, or / for commands…" ("Follow up…" when pi
  reports no commands), or "Describe the task, or / for commands…" on a fresh agent.
- **Running:** Stop while the field is empty; with a draft, Stop outlined and Send. The field
  keeps the idle placeholder. Send's tooltip names both ways, the Return setting's first:
  "Queue (↩) · Steer now (⌘↩)".
- **Accepting:** a spinner ("Waiting for pi") takes the button's place.
- **Starting:** Send is offered from the first frame, before pi has answered anything. A
  message sent while pi boots waits behind the spinner, still in the field, and goes once pi
  answers, as the field has it then (edited, or not at all once cleared). Once pi has kept the
  thread waiting for two seconds (`AppLayout.startingIndicatorDelay`; half a second over a thread
  with nothing to show, `AppLayout.blankStartingIndicatorDelay`), "Starting pi…" in
  caption `textTertiary` with a 10pt `textTertiary` spinner sits in the control row just before
  the action (its spinner gives way to the action's own while a message waits). It lives in a
  row that is always there, so it never changes the composer's height or moves the thread; it
  drops its words before the chips drop theirs, and fades out the moment pi answers. A normal
  start is over before it would show.
- **Error:** Send, plus a `failed` banner above the card, "Lost connection to the agent
  process.", with the error and Reconnect: only for a pi that was serving and went away, one
  that failed, or one that never started.

With more than one live subagent, Stop asks first (`StopAllDialog`): Stop only the agent, or
Stop all. Stop (the button, ⌘., or Esc in the composer) takes back what pi was about to read
before it aborts, so a steering message returns to the queue, and the queue then waits
(paused) until a new message, Send now, or a steer. There is no status text, key hint, or
working directory in or under the composer.

**Sending while pi works.** ↩ does what Settings ▸ Agents ▸ Return while pi is working says:
**Queue** (the default; the message waits in Up next and goes when pi settles) or **Steer**
(pi reads it once its current tool calls finish, before its next step). ⌘↩
(`alternateSend`, rebindable) always does the other one, ahead of any key equivalent in the
window (the review pane's ⌘⏎), and only while the composer or one of its queued messages has
focus. ⇧↩ inserts a newline; while pi is idle ↩ and ⌘↩ both send. Attachments ride along with a
queued or steered message.

**Send menu** (`NWSendMenu`): right-clicking Send, or holding it for
`AppLayout.sendHoldDelay` (500ms), while pi works with a draft, opens the choice at send time
(`.overlay`): beside the card, 8pt after its trailing edge and bottom-aligned with it, where
the thread has room for it and its margin (`Composer.sendMenuBeside`), so it covers none of Up
next; otherwise 8pt above the card with its trailing edge on the card's. It grows from the
corner nearest Send. Nothing about the choice is written under the composer.

- 268pt on the menus' popover, 6pt padding, rows 2pt apart; each row top-aligned with 8×10
  padding and the `runningTint` highlight: a 14pt glyph in `textSecondary`, the title in Geist
  13 medium with its description in caption tertiary beneath, and its keys as `NWKeycap`s.
- **Queue** (the queue glyph): "Goes when pi finishes this turn." **Steer now**
  (`arrow.turn.down.right`): "Lands once pi's current tool calls finish, before its next step."
- ↩'s cap sits on the Return setting's row, which is highlighted when the menu opens, and ⌘↩'s
  on the other. ↑↓ move, ↩ chooses, Esc closes, and a click outside closes it. While it is open
  Send wears a 3pt `lanternTint` ring (`hover`).

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

**Menus** float over the thread above the card, one at a time: left-aligned with it (the Send
menu beside the card, or at its trailing corner), 8pt above it, and growing from that corner (`.overlay`). They take no room in the composer, so opening one never
changes the composer's height, the thread's inset or scroll position, or any of the thread outside
the menu (`ComposerMenuTests`). A menu is never taller than the room above the card (it keeps 8pt
from the thread's top, and its list scrolls inside), and beside a docked pane it narrows to the
card. They share one anatomy: `.nwPopover()` at radius 12 with 6pt padding, 24pt mono caps
section headers, and 28pt rows with a `runningTint` highlight. ↑↓ move, ⏎ chooses, Esc closes
and returns focus to the field, and a click anywhere outside the menu and the card closes it (the
click still lands where it was aimed).

- **Slash menu** (`NWSlashMenu`, 448pt): opens when the draft is "/…" (or from the chip).
  "Commands · n of m"; rows show the command in mono 12 with the typed prefix in semibold
  `textPrimary` (a 150pt column), its description, and its source as a tag for prompt templates
  and skills (none for extension commands). At most 8 rows show. ⇥ completes with a space. The
  list is pi's command registry, never hard-coded. Its rows are lazy, a highlight moving redraws
  only the two rows it moves between, and only ↑↓ scroll the highlight into view (the pointer's
  is already under the pointer).
- **Model picker** (`ModelPicker` on `NWModelPicker`, 260pt, at most 360pt tall): from the
  model chip or ⇧⌘M. A search field, then Recent (up to four, from any thread), then one section
  per provider. Rows show the model in mono 12 and a running check on the current one, or its
  context size. It picks the model only. A catalog runs to hundreds of models, so the list is
  lazy (only the rows on screen exist), derived once per catalog and query rather than while
  drawing (`ModelCatalog`, `ModelPickerState`; this Mac's catalog is asked once per process, off
  the main actor), and a hover moves the highlight without redrawing the list or scrolling it
  (`ComposerMenuPerformanceTests`).
- **Thinking menu** (`NWThinkingMenu`, 220pt): Off, Low ("quick"), Medium ("default"), High
  ("slower, deeper"), with a check on the current level.

### Up next (the queue)

Messages sent while pi works stack in **Up next** (`QueueStackView` in
`Thread/QueueStack.swift`, on ShepherdUI's `NWQueueStack` and `NWQueueRow`; sizes are
`NWQueueMetrics`): a card directly above the composer card, in the same column, 8pt above it,
under any widgets and banners. The host holds the queue ([native-thread.md](docs/native-thread.md)
› The queue), so every Mac viewing the agent sees and edits the same one. Nothing in it has
reached pi, except a Steering row.

- **Placement:** it shows while the queue has a row. The card never moves: the stack grows
  upward, and the thread's inset follows the composer's measured height, so the thread keeps its
  last turn in view (`QueueStackIntegrationTests`).
- **The card:** `bgRaised`, a 1px `lineStrong` line, radius 8. A 32pt header (12pt leading, 6pt
  trailing, a hairline beneath): the queue glyph (`NWQueueGlyph`, 12pt, `textTertiary`), "Up
  next" in Geist 12 semibold `textSecondary`, the count in mono 11 tertiary (every message,
  steering ones included; it rolls), "Paused" in caption tertiary while the queue waits (its
  reason in the tooltip), then the ••• options and Collapse (24pt icon buttons; the chevron
  turns up while collapsed, and a collapsed stack is its header alone). Rows follow, a hairline
  above each but the first.
- **A queued row** (`NWQueueRow`, 40pt, not scaled by Density; 8pt leading, 6pt trailing, 8pt
  apart): the grip (`NWGripGlyph`, six dots in an 8×14 slot, shown on hover or focus: the only
  drag handle), its number (mono 10.5 `textSecondary` in an 18pt `lineStrong` ring: the order
  it goes, not a count, never counting Steering or Deleted rows), the text in Geist 13 on one
  line (a click edits it), its images as compact chips (22pt, a 16pt thumbnail or a `photo`
  glyph where the bytes stayed on another Mac), and an 82pt slot that always keeps room for its
  actions, so hovering never re-truncates the text. The actions are built only while the row is
  hovered or focused: Steer now (Send now while pi is idle), Edit, Delete, 26pt icon buttons
  2pt apart with system tooltips naming their keys. Hovered it is `bgHover`; with keyboard focus
  `bgSelected` with the running focus ring drawn inside it.
- **A Steering row:** always first, on `runningTint`: a bare 14pt running spinner where a
  queued row has its number (so its text starts 4pt further left), the text, `NWStatusPill(.running, label: "Steering", symbol: "arrow.turn.down.right")`,
  and Back to the queue (`arrow.uturn.backward`), which returns it to the queue as #1 until pi
  reads it. It has no grip, Edit, or Delete.
- **Editing** (`NWQueueEditor`): the text or the pencil (or ↑ in an empty composer, for the last
  queued message) opens the row in place: `bgWindow`, 8pt padding (24pt leading, so the number
  keeps its column), the number top-aligned beside a field of up to six lines (Geist 13 at 1.5,
  `bgRaised`, radius 6, a `lantern` line inside a 3pt `lanternTint` ring, the caret after the
  text), and Cancel (ghost) and Save (secondary; disabled while empty). ↩ saves, ⇧↩ adds a line,
  Esc cancels. The message keeps its place, and the host holds the queue while the editor is
  open (renewed every minute; a hold lapses after two).
- **Deleted** (`NWQueueDeletedRow`): the delete goes to the host at once, and an Undo row takes
  the message's place, cross-fading in the same 40pt (34pt leading): a trash glyph, "Deleted" and
  the struck-through text in `ui` regular tertiary, and Undo as a link. It closes after
  `AppLayout.queueUndoWindow` (5s), counting only while the pointer is off it. Clearing the queue
  leaves one such row, "Cleared 3 messages", that puts them all back.
- **Long stack:** up to three rows all show; past three, the first two and "Show N more" (a 32pt
  link row, 34pt leading), which expands the stack in place ("Show fewer"). Expanded past six
  rows it scrolls inside. An editor opened below the fold expands it.
- **Reordering:** dragging the grip lifts the row out of the stack onto a floating card
  (`bgRaised` under `bgHover`, radius 8, a `lineStrong` line, the popover's shadow, a 1° lean),
  22pt right of its slot and 14pt past the stack's trailing edge (`NWQueueMetrics.liftInset`),
  over its neighbours, the drop line and the composer card. It follows the pointer at once, up
  to half a row past the first and last rows; its neighbours step aside (`list`), and a 2pt
  `lantern` drop line (`NWDropIndicator(color:)`) tops the gap. Nothing drops above a Steering
  row. ⌥↑ ⌥↓ move a focused row.
- **The ••• menu** (native): Steer all now (Send all now while pi is idle), "When the turn ends,
  send" with One message per turn and Everything at once (this agent's choice; Settings sets the
  host's default), and Clear the queue (destructive, with its Undo row).
- **Keys on a focused row** (with keyboard navigation on, ⇥ reaches the rows): ↑ ↓ move between
  rows, ↩ edits, ⌘↩ steers (sends now while pi is idle), ⌥↑ ⌥↓ move it, ⌫ deletes it, and Esc
  or ⇥ return to the field.
- **Motion:** the stack comes and goes with `list` from the bottom (the card stays anchored); a
  queued row rises from the bottom, and a row pi takes leaves toward the thread (`list`) while the
  numbers roll (`content`); hover fills, the grip, and the actions fade (`hover`) in slots that
  are always laid out; Steer now and Back to the queue move the row (`list`) while its number and
  spinner, and its actions and pill, cross-fade (`content`); Show more and Collapse disclose
  (`disclosure`). No bubble flies from the stack into the thread.

### Subagents

A subagent is a turn inside a turn. Its spawn call renders as a card where the call was, and raw
wait or status dumps never appear. Subagents live in their agent's thread and the palette; they
have no sidebar rows, and one waiting on you marks its agent's row instead (see Sidebar).
Behavior is specified in [native-subagents.md](docs/native-subagents.md).

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

One slot beside the agent's layout (`RightPaneSplit` around the whole layout, in
`AgentLayoutView`) is shared by the subagent inspector and the review; when both exist, the
inspector wins. It sits at the workspace's trailing edge beside the thread and its terminal
panel, at its full height, and the dock rule measures the main column, never the thread's own
pane. Its sizes and adaptive rule are in "Window and adaptive
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
  (`NWOptionsMenu`: Refresh Transcript while live; Copy Transcript and Show Session File in
  Finder once finished), and close.
- **`NWRunBrief`** on `bgSunken`: GOAL, with "step n / m · 62%" while live, and once finished
  RESULT (inline Markdown) with its label in the state's color. Under it, up to five touched
  files as `running` links (with their diff stat) that open the review pane at the file, then
  "n more files".
- **The run's own transcript**, drawn with the thread's components one step smaller
  (`nwProseSize` `.small`), times and footers on hover as in the thread. It follows live, with
  "n earlier turns · Show all" and "Following live" (or "Reading earlier output") beneath.
  Scrolling up stops following.
- **A Steer composer** while the run is live: the composer card's anatomy, "Steer <name> —
  delivered before its next turn", "to: <name> · not the parent", and a primary Steer button.
  A failed send keeps the draft.
- **A finished run is read-only:** messages from the parent are captioned "from parent" ("10:58 ·
  from parent" while hovered), and `NWRunActions` (Re-run · Fork · Copy transcript) replaces the
  composer. Remote agents have no Fork.

**Review** (`ReviewPane` in `DiffReviewView.swift`, state in `DiffReview.swift`):

- **Header** (`NWPaneHeader`, 44pt like the toolbar beside it): "Review" in Geist 13 semibold,
  with "4 files · +67 −58" beneath (led by the reference when an agent asked for one, and
  before that by the directory's name when an agent's `review_diff` points it outside the
  agent's own directory; "loading…" while loading). Then a small `Local | PR` segmented control ("PR · <ref>" once the
  PR base is known), an options menu (`NWOptionsMenu`: Expand All Files, Collapse All Files,
  Copy Review as Text), and close.
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
  review closes only once the send succeeds. Where the host commits from review (a local review,
  or a remote host with `review.commit.v1`), Commit becomes **Ask agent to commit** (ghost) beside
  **Commit…** (secondary), which opens the commit sheet.
- **Commit… sheet** (`ReviewCommitSheet`, 520pt, derived from the iPadCommit board; parts in
  `Components/Review/CommitForm.swift`): "Commit n files" over "On <branch> in <repository>."
  - The message card (`NWCommitMessageEditor`, a raised card with a strong line): the summary in
    semibold over the description, both editable, and a note: "Drafted from the diff · edit
    anything" (a sparkle), "Written from the file list · edit anything", or a spinner with
    "Drafting from the diff…". The plain message shows at once; the drafted one replaces it only
    if nothing was typed meanwhile. Drafting follows Settings ▸ Worktrees ▸ Generate PR
    descriptions and its model.
  - "Files" with "n of m" and Select All/None, then a card of `NWCommitFileRow`s (a row-high
    checkbox row: lantern checkbox, the name in mono, its directory in tertiary, the diff stat;
    the whole row toggles). Every file starts ticked; the list scrolls past 232pt.
  - A card of two `NWCommitOptionRow`s: **Push after commit** over the upstream in mono
    ("origin/main", or "origin/feat · sets upstream"), and **Open a pull request instead** over
    what it does ("pushes feat, opens a PR into main", or "creates shepherd/<slug>, opens a PR
    into main" on the default branch). The PR option turns the push on and disables its switch;
    an option with nowhere to go is disabled.
  - An agent still working puts an attention banner above the message and a "Commit while it
    works" checkbox that Commit waits for. A checkout the host refuses (detached HEAD, a merge or
    rebase in progress, unmerged paths) is a failed banner over the disabled form; a refused
    commit comes back as a failed "Nothing was committed" banner.
  - Footer: why Commit waits (caption), then Ask Agent to Commit (ghost), Cancel (⎋), and the
    primary: **Commit**, **Commit & push** or **Commit & open PR** (⏎).
  - Running, the body becomes the host's steps as `NWChecklistRow`s (check the checkout, create
    branch, commit n files, push to …, open a pull request into …) with each one's detail, a
    failed "Stopped" banner saying what was kept, then Open Pull Request and Done. Close while it
    runs leaves it running; Commit… shows it again. A finished commit reloads the review.
- **Empty and error states:** "Loading the diff…"; "No changes" with "The working tree matches
  HEAD." (or "This branch matches its PR base."); a `failed` banner for an error.
- **Keys:** j/k move between hunks, n/p between files, c comments, v marks viewed, ⌘⏎ sends, and
  Esc returns to the thread's composer.
- **Repository changes:** per-file Revert is the only repository mutation outside the worktree
  flows (`RevertFileDialog`: "Discard changes", with a Repository row naming the directory the
  diff came from). Tracked files return to HEAD; new files move to the Trash. It acts on the
  directory the confirmed diff came from, even if the review has since moved.

A review an agent opens (`review_diff`) is the host's view state; remote viewers open their own
with ⇧⌘B. An agent may point its review at another repository or worktree (`cwd`); a new target
starts the review over (comments, summary, viewed marks, folds), and asking again brings the
review back in front of an inspected subagent.

### Terminal panes

Terminal panes render through libghostty on the theme's terminal colors, on `bgWindow`, with
10×8pt padding and the Settings ▸ Terminal font. The thread pane itself never has a terminal.
Pane states are quiet placeholders in mono 10.5 tertiary ("starting session…", "session exited
(n)", "session unavailable · reason"). The chrome never parses or restyles terminal output.

### Terminal panel

An agent's terminal panes live in a panel under its thread and composer, across the layout's
width (TerminalSplit, TerminalStates boards; `TerminalPanelGeometry`, `TerminalPanels`,
`TerminalPanelViews.swift`). The panel is a view of the agent's layout, which stays the one
`PaneNode` tree the server persists and agents drive: each largest subtree without the thread is
a tab, oldest first (`TerminalPanel.tabs`), drawn with its own splits.

- **Strip** (`NWTerminalTabBar`, 38pt on `bgWindow`, a `lineStrong` hairline above): the tabs
  (26pt, radius 6, mono title, the selected one on `bgSelected` with its close), + for a new
  tab, then Split right, Maximize or Restore, and Hide (24pt icon buttons).
- **Tab states** (`NWTerminalTab.Activity`): at rest the program at its prompt ("zsh"); a
  running command names the tab ("make dev") with a running spinner; output printed while the
  tab was off screen adds a running-blue dot; an exited session is tertiary (failed if it failed).
  The selected tab of a remote agent names its host. What each terminal runs comes from
  `SessionServer.terminalActivity` (a remote agent's host answers `RemoteAgentQuery.terminals`),
  polled every 2 s while the layout is on screen; an older host leaves plain tabs named for the
  folder.
- **Actions:** + splits the thread (a new tab); Split right (⌘D in a terminal) splits the tab's
  focused pane; ⌘D or ⇧⌘D on the thread opens a new tab; closing a tab closes its panes (as ⌘W
  does), never the thread's. A terminal that appears (from any of these, or an agent's
  `pane_open`) opens the panel on its tab.
- **Show and hide:** ⌘J or the toolbar's terminal toggle (`NWPaneToggle`, lantern while open).
  Hidden, a running-blue dot on the toggle (`NWToggleBadge`) says a tab printed. Showing gives the
  keyboard to the selected tab; hiding gives it back to the thread. A layout seen for the first
  time with terminals shows its panel.
- **Height:** 330pt by default, persisted app-wide (`shepherd.terminalPanelHeight`). Drag the
  panel's top edge (9pt hit area, row-resize pointer): it snaps at a third, half and two-thirds
  of the layout within 12pt, keeps the panel at least 120pt and the thread at least 160pt;
  double-click resets it. VoiceOver adjusts it in 40pt steps.
- **Maximized** (⇧⌘↩): the panel takes the layout and the thread folds away at its size, still
  mounted; Restore brings it back.
- **Nothing remounts:** every pane is placed whether it shows or not (a hidden tab or panel keeps
  its size, so its grid never changes), hidden ones are `opacity(0)` and stop rendering. ⌥⌘←/→
  move only among the panes on screen. A remote agent's panel mounts only its shown panes, so a
  hidden remote terminal is detached and never counts toward the host's smallest-viewer size.
- **A layout with no thread** (a host's utility terminal) keeps the plain split tree.

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
- **What it never shows:** footer hints, ⌘1–9 numbering, or any status the sidebar or the thread
  doesn't show.

### Settings

Settings replaces the window content in place (`SettingsView.swift`). ⌘, toggles it, and "Back
to Shepherd" or Esc returns.

- **Navigation:** a 232pt nav on `bgBase`: a draggable strip for the window controls, Back to
  Shepherd, the search field (`NWSearchField`, ⌘F), then Appearance · Terminal · Agents ·
  Worktrees · Pi · Remote · Keyboard · Advanced (`NWSettingsNavRow`: 28pt × density, a medium
  icon, the name in `ui`, `bgSelected` and semibold when selected), with "Shepherd x.y.z · pi
  x.y.z" (the app's own name, so "Shepherd Nightly …" there) pinned at the bottom in micro.
  Searching lists matching rows, as buttons, under their page.
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
| **Agents** | Default model, default thinking level; while pi is working: what Return does (Queue / Steer; ⌘↩ does the other) and how the queue goes when a turn ends (One per turn / All at once, the host's default for its agents) |
| **Worktrees** | Base branch (Remote default / Current branch), fetch before creating, and finalize: commit remaining work, generate PR descriptions, delete local branch, merge automatically (+ method) |
| **Pi** | Bundled extensions (name agents automatically, sync pi theme, panes and agent tools, diff review tool, native subagents, subagent display), native subagent defaults, pi and extension updates |
| **Remote** | Hosts (edit, reconnect, remove), add or edit a host (name, address, port, token), Serve this Mac (listener, token file) |
| **Keyboard** | Rebindable shortcuts by group; While pi is working (the Queue & steer boards' Keyboard card, in its order: ↩ and ⌘↩ named for what they do under the Return setting, the queue's keys, Stop pi); the fixed chords, and Reset all |
| **Advanced** | Files (workspace state, extension socket), updates and channel (Shepherd: Stable or Beta in a segmented picker; Shepherd Nightly names its one channel, Nightly), reset settings |

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
- An agent asking to delete another (`PeerDeleteDialog`, "Delete agent"): rows for the agent,
  its worktree branch (else its directory, so agents sharing a name can be told apart), its
  space, and who asked, an attention banner (its pi session and everything it started stop; a
  worktree agent's worktree and branch are kept), Cancel (⎋) and a destructive Delete agent. Only that button
  approves. The dialog closes by itself when the request lapses (cancelled, the asking agent
  gone, or two minutes without an answer).
- Stop all (`StopAllDialog`), the review's Revert (`RevertFileDialog`) and Commit…
  (`ReviewCommitSheet`, described with the review pane), and a failed agent action
  (`ActionErrorDialog`)
- Reset settings (`ResetSettingsDialog`)
- Quitting while agents are working or waiting on you (`QuitDialog`), because quitting stops
  them mid-turn. It lists the busy agents (five named, each with its status dot and "working" or
  "needs you", the rest counted), with Cancel (⎋) and a destructive Quit, so ⏎ never quits.
  `QuitConfirmation` puts it on the main window as a critical sheet, so it shows even over
  another sheet. A closed window is reopened first; if it is not back within a second, the
  dialog opens in a window of its own. While it asks, AppKit disables Quit, so a second ⌘Q does
  nothing. A log out, restart, or shut down quits without asking, and one that begins while the
  dialog is up answers it with Quit.

Git probes and directory listings run off the main thread; the Delete Worktree Agent dialog
keeps its destructive action disabled until the unreconciled-work check is in.

## Status language

| Lifecycle | `AgentState` | Sidebar | Composer |
| --- | --- | --- | --- |
| Agent working | `running` | blue dot; elapsed trailing | Stop (outlined beside Send with a draft); ↩ queues in Up next or steers |
| Agent blocked on a question | `attention` | lantern dot, glowing; "ASK" | the question panel in place of the field |
| A subagent needs you | `attention` | its agent's row: lantern dot, glowing; "ASK" | the card's answers and Reply… |
| Agent done | `done` | green dot | Send |
| Agent done, its turn failed | `failed` | red dot | Send |
| Agent idle | `idle` | hollow ring | Send |
| pi starting | `idle` | hollow ring | Send, which waits for pi; only when pi is slow (two seconds, half a second over a blank thread), "Starting pi…" beside it |
| Connection lost | `failed` | — | Send, plus a `failed` banner with Reconnect |

Subagent runs use the same states on their dots, glyphs, pills, and steps: running, needs you,
done, failed, and queued (queued or paused, hollow). Tool calls use running, done, and failed.

A turn fails when pi's last reply is a provider error (not a Stop). The thread shows the error
(`NWTurnError`), and the agent's row (an automation's too) and its palette subtitle read failed
until its next turn starts.

**System notifications** (`AgentNotifications`, worded by `AgentBanners`) follow the same
language, and post only while you aren't watching that agent (it isn't selected, or Shepherd
isn't frontmost):

| Moment | Title | Body | Sound |
| --- | --- | --- | --- |
| A turn finished | the agent | "Agent finished" | no |
| A turn failed | the agent | "Turn failed", then the error's first line | yes |
| The agent asks a question | the agent | "Agent needs your input" | yes |
| A subagent asks a question | the agent | "Subagent *label* needs your input", then the question's first line | yes |

An agent's own banners replace each other; each subagent's question has its own. A subagent
posts once per question, however often its extension republishes. Clicking a banner selects
the agent.

## Components

`Packages/ShepherdUI/Sources/ShepherdUI/Components` is the shared library, by domain, with
`#Preview`s of every component in both appearances in `Previews/`. Use a component before
composing chrome by hand. Debug builds have a **Component Gallery** (View menu,
`ComponentGallery.swift`) that shows the base components in their states.

| Domain | Components | Owned in the app by |
| --- | --- | --- |
| Controls | `.buttonStyle(.nw(_:size:))` (primary, secondary, ghost, danger, dangerFill; s 24 · m 28 · l 32), `.nwIcon` (a circle, 28pt; "on" is lantern tint), `.nwLink`, `.nwRow(selected:)`, `.nwRowBackground(selected:hovering:)`; `.toggleStyle(.nwSwitch)` (30×18) and `.nwCheckbox` (14pt); `NWSegmentedPicker` (m 24, s 20), `NWPopupMenu`, `NWValueSlider`, `NWStepper`; `.textFieldStyle(.nw)` (28pt, radius 6), `.nwField(focused:error:mono:)`, `NWSearchField`; `NWKeycap`, `NWCountBadge`, `NWTag`, `.nwHelp(_:shortcut:)` | across the app |
| Status | `NWStatusPill` (20pt, radius 4; a glyph in place of its dot), `NWStatusDot` (6pt), `NWStateGlyph` (14pt), `.progressViewStyle(.nwSpinner)` and `.nwBar` (4pt), `NWStepStrip`, `NWSparkline`, `NWBanner`, `.nwToast(item:)`, `NWEmptyState`, `.nwShimmer()`, `NWWordmark`, `NWCrook` | across the app; `NWSparkline`, `.nwToast(item:)`, and `.nwShimmer()` have no app use yet |
| Containers | `NWSectionHeader`, `NWGroupCard`, `NWCardRow`, `NWHairline` | `SettingsComponents.swift`; hairlines everywhere |
| Navigation | `NWSidebar`, `NWSidebarSection`, `NWSidebarRow`, `NWSidebarDisclosureRow`, `NWSidebarNoticeRow`, `NWSidebarFooter`, `NWDropIndicator`, `NWDensity`; `NWThreadToolbar`, `NWPaneToggle`, `NWOptionsMenu`, `NWPaneHeader`; `.nwCommandPalette(isPresented:)`, `NWPaletteCard`, `NWPaletteSearchRow`, `NWPaletteSectionHeader`, `NWPaletteRow` | `SidebarView.swift`, `RemoteSidebarSection.swift`, `ThreadHeader.swift`, `RootView.swift`, `CommandPaletteView.swift`; the review's header (`DiffReviewView.swift`) and the inspector's ⋯ menu (`Thread/SubagentInspector.swift`) |
| Thread | `NWUserBubble` (its time shown while `revealed`; `origin: .steered`), `NWQueueDivider`, `NWAgentProse`, `NWCodeBlock`, `NWThinking`, `NWActivityLine`, `NWActivityCalls`, `NWChangesCard`, `NWDiffStat`, `NWInlineCode`, `NWAttachmentChip`, `NWTurnFooter` (shown while `revealed`), `NWTurnError`, `NWWorkingRow`, `NWJumpToLatest` | `Thread/ThreadView.swift`, `ThreadTurns.swift` (with each turn's `MessageHover`), `ThreadTools.swift`, `ThreadMarkdown.swift` |
| Composer | `NWComposer`, `.nwComposerChip(active:)`, `NWChipChevron`, `NWComposerActionButton` (outlined Stop, Send's ring), `NWMenuHeader`, `NWSlashMenu`, `NWModelPicker`, `NWThinkingMenu`, `NWSendMenu`; the queue: `NWQueueStack`, `NWQueueRow`, `NWQueueEditor`, `NWQueueDeletedRow`, `NWQueueMoreRow`, `NWQueueNumber`, `NWQueueGlyph`, `NWGripGlyph`, `NWQueueMetrics` | `Thread/Composer.swift`, `Thread/QueueStack.swift` |
| Agents | `NWSubagentCard`, `NWRunsStrip`, `NWRunLedger`, `NWInspectorHeader`, `NWRunBrief`, `NWRunActions`, `NWBranchGlyph`, `NWElapsedText`, `NWDuration`, `NWInlineMarkup` | `Thread/Subagents.swift`, `Thread/SubagentInspector.swift`, `Thread/SubagentPresentation.swift` |
| Review | `NWFileStrip`, `NWFileHeader`, `NWDiffView`, `NWDiffLine`, `NWHunkHeader`, `NWFoldRow`, `NWInlineComment`, `NWCommentEditor`, `NWReviewComposer` | `DiffReviewView.swift` |
| Dialogs | `NWDialog`, `NWDialogStatus`, `NWSheetRow`, `NWChecklistRow`, `NWSettingsNavRow` | `DialogSheet.swift`, `AppDialogs.swift`, the sheets, `SettingsView.swift` |
| Automations | `NWAutomationRow` (a row with its switch), `NWAutomationSwitch`, `NWFactRow` and `NWFactText`, `NWAutomationPrompt`, `NWRunBars`, `NWRunRow`, `NWAutomationMetrics` | `RemoteAutomationSheet.swift`; the iOS client's `Automations/` |

Rules for the controls:

- **Buttons** are styles on a native `Button`. Primary (lantern) appears at most once per view;
  disabled is 40%. Icon-only buttons always carry an accessibility label.
- **Toggles, text fields, and pickers** are styles on native controls. `NWSegmentedPicker`,
  `NWValueSlider`, and `NWStepper` draw their own control and represent themselves to
  accessibility as a native segmented `Picker`, `Slider`, and `Stepper`.
- **Keycaps** show only a real, wired shortcut, and only in menus, the palette, Settings, and
  empty states; never under the composer.
- **Banners** sit inside the pane they concern. Never a modal alert for an agent event.

## Keyboard

Keyboard is first-class, and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (`Keybindings.swift`; defaults in `ShortcutAction.defaultChord`, overrides
in UserDefaults under `shepherd.keybindings`).

- **One source:** menus, palette keycaps, Settings ▸ Keyboard, copy that names a chord
  (Settings ▸ Agents and Terminal), and the Ghostty unbind list all read the store. Hardcoding a
  chord in a view is a bug, and a hint is never shown for a chord that isn't wired.
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
| ⌘J · ⇧⌘↩ | Show or hide the terminal panel · maximize or restore it |
| ⇧⌘S · ⇧⌘B | Show or hide the sidebar · the right pane |
| ⇧⌘M | Model picker |
| ⌘. | Stop the agent |
| ⌥⌘↑ · ⌥⌘↓ | Previous · next turn |
| ⌘I | Inspect subagent |
| ⌘↩ | Send the other way while pi works (steer ⇄ queue), and steer a focused queued message; composer only, no menu item |

Fixed chords:

- ⌘1–9 select agents in sidebar order (hold ⌘ to see the badges).
- ⌃⇧1–9 jump to machines (this Mac is always ⌃⇧1).
- ⌘, opens Settings, and ⌘F searches it.
- ⏎ confirms and ⎋ cancels in sheets.
- In the composer, ↩ sends (while pi works, it queues or steers per Settings) and ⇧↩ inserts a
  newline. `/` at the start opens the command list, and Esc closes a menu, then the command list,
  then stops pi while it works.
- The queue's keys (`FixedChord`, listed with the send keys under Settings ▸ Keyboard ▸ While pi
  is working, `WhileWorkingKey`): ↑ in an empty composer edits the last queued message; ⌥↑ ⌥↓
  move the focused message and ⌫ deletes it.

Review-pane and menu keys are listed with their surfaces.

## Accessibility and motion

- **Controls:** every control is a real `Button`, `Toggle`, or text field, or carries button
  traits and actions (sidebar rows are tap views so they can also be dragged). Icon-only buttons
  carry an `accessibilityLabel`, and hover-only affordances (the sidebar's `+`, a message's time
  and a turn's footer, a comment's Edit and Delete, a diff line's `+`) are always reachable as
  buttons or named actions for VoiceOver.
- **Rows read as one element:**
  - agent rows: "title, [worktree,] running / needs you / idle / done" (needs you also while one
    of its subagents asks); automation rows: "name, automation, state"
  - activity lines: "Explored 7 files, read 5, search 2, 0.9s, done", with Expanded / Collapsed
    and the hint "Shows the calls"; a folded stretch: "Worked for 6m 40s, explored 13 files, …,
    5 failed, done" and the hint "Shows the steps"; call rows: "edit, Sources/A.swift, +58 −41"
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
- **Reduce Motion:** nothing moves (see Motion). The glow, spinners, and shimmer are static;
  panes, sheets, overlays, and expanding or arriving rows cross-fade in place (120ms); rolling
  digits and symbol swaps cross-fade; pops, turn jumps, and scroll-to animations are dropped.
  Hover and content fades are unchanged.
- **Menu bar:** every pane and agent action exists in the menu bar with its shortcut (File,
  View, Pane, Space, Agent, Machines, Appearance).

## Known gaps

When a change leaves code breaking this document, list the place here until it is fixed toward
it.

None open.

Deliberate exceptions stay with their rules rather than here: the layout's 1pt dividers, the
checkbox's 1.5pt border, and the strokes of status glyphs (see Hairlines), and one-off type
sizes outside the ramp, set with `Font.nwSans`/`Font.nwMono` (the boards' in Typography, and
the empty thread's path).

## iOS

The iOS client (`App/iOS`, [docs/ios](docs/ios/README.md)) is built on Night Watch, with the
phone and iPad boards as its authority. The same rules hold as on the Mac (tokens only, shared
components first), with these differences for touch:

- **Type:** the phone and iPad boards' ramp (rows at 15, prose at 16 with 1.5 line height, meta
  at 12), following Dynamic Type through `relativeTo:`.
- **Touch targets:** 44pt (`NW.Height.touch`). Controls keep their drawn size and grow their hit
  area (`.nwTouchTarget(height:)`); rows people tap are at least 44pt tall. One deliberate
  exception: diff lines (`NWTouchDiffLine`) keep the boards' dense `NW.Height.rowCompact`, so a
  file reads as code. A tap only selects the line to comment on (a miss selects its neighbor,
  and nothing is sent until the comment is written), and VoiceOver reaches each line as its own
  button.
- **No hover:** `NWPlatform.showsHoverDetails` shows at rest what the Mac reveals on hover (a
  message's time, a turn's footer, a code block's Copy, a comment's actions); a pressed row
  shows the hover fill.
- **Navigation:** iPhone has two tabs, Home and Settings, each a stack; iPad a split view with
  the sidebar beside the thread in landscape and over it in portrait.
- **Following** (the boards draw only a thread at its tail): the Mac's rule (Thread ›
  Following), with a finger's drag as the only intent. "↓ Jump to latest" (`NWJumpToLatest`)
  sits 8pt above the composer, drawn as on the Mac with a 44pt hit area.
- **A paused queue** has no hover to reveal a row's Send now or the header's tooltip: its header
  shows Send now (secondary, small; the ••• menu's Send all now) between "Paused" and the •••,
  and the reason is its VoiceOver hint. At accessibility text sizes Send now takes a row of its
  own under the title, and "Jump to latest" grows with its text.
- **Windows (iPad; iPadSplitView, iPadPalette boards):** each window is a whole Shepherd, with
  its own sidebar and thread, over the same hosts and drafts. "Open in new window"
  (`macwindow.badge.plus`) sits in a thread's options menu and in the sidebar's and the palette's
  row menus, and beside Open in the palette's preview as a secondary button. A turn's long-press
  menu has Copy and "Send to", a submenu of the threads other windows show (the thread's name
  over its host), which puts the text in that thread's composer after a blank line and brings
  its window forward; a turn also drags out as text. A composer with text over it wears the
  focus ring. iPhone shows none of this: it has one window.
- **App measures** come from `MobileLayout` (`App/iOS/Support`), as the Mac's come from
  `AppLayout`.
- **Terminal** (iPadTerminal board; `App/iOS/Terminal`): on iPad the Mac's panel under the thread
  and composer (46pt strip, 32pt tabs, 34pt icon buttons hit at 44, 340pt tall), with a
  grabber on its top edge for the divider (snapping as on the Mac) in place of a pointer
  handle, and the terminal toggle in the thread's header. While a terminal has the keyboard, a
  key row sits under it, over the software keyboard: esc, tab, ctrl, ⌥ (latched in lantern
  until the next key), the arrows, `|`, `~`, `/`, `-` as 34pt keycaps at least 44 wide on
  `bgRaised`. On iPhone the thread's options open the panes full screen with the same strip and
  key row. The terminal is SwiftTerm's view on Night Watch's terminal palette in Geist Mono at
  the code size, following Dynamic Type to 20pt; the strip and key row stop growing at
  xxxLarge. Closing a tab asks first ("Its shell on <host> stops.").
- **Commit from review** (MobileCommit, iPadCommit boards): the same parts as the Mac's sheet. On
  iPhone the changes' bar reads Request changes and **Commit…** (primary), which presents a sheet
  (Cancel, "Commit n files"; Message, Files "n of m", the options card; a full-width Commit &
  push, with Ask agent to commit as a link under it and in the review's ••• menu). File rows are
  44pt and show the name alone. On iPad, Commit… (the docked composer's, or the full-screen
  toolbar's) opens a 400pt popover: the title, the message card on `bgWindow`, the files, the
  options between hairlines, and Ask agent, Cancel and Commit & push. A host without
  `review.commit.v1` keeps the single Commit that asks the agent.

### iOS: Automations

`App/iOS/Automations` (MobileAutomations, iPadAutomations boards), from Home's Automations row
or the iPad sidebar's.

- **What an automation is here:** the Mac's fields and nothing else. It has a name, a prompt,
  a folder on its host (one of the host's spaces), and a switch: **On** starts a run each time
  Shepherd launches on the host; Run now starts one any time. The boards' schedules, triggers,
  models and repo lists are not built, because the host has none of them.
- **List:** Running now (a spinner, "Running · 4m"; "Asked you" in lantern), then All with the
  count. Each row (`NWAutomationRow`) is its name, "When Shepherd starts · folder" (or "By
  hand"; the host's name instead of the folder when there are several hosts), how the last run
  went with its time ("Finished · 12h ago", "Interrupted · 3d ago", "Not run yet"; "On" or
  "Off" until its runs are read), and its switch, which flips at once and waits for the host.
  An offline host's rows read "Host offline", dimmed, with the switch disabled; a host from
  before automations over the remote protocol keeps its rows and says under the list why they
  are read-only. `+` opens the form when a host can take one.
- **iPhone** pushes one automation; **iPad** lists them in a 340pt column beside the chosen
  one's detail, whose header is the name, an On or Off pill and the ••• menu.
- **Detail:** the On switch with what it means, Status, Runs on ("build-01 · a new thread each
  run"), Folder, the prompt, the latest fourteen runs as bars (bar height = duration), the last
  run, and every run the host kept (`NWRunRow`), each opening its thread while it exists. The
  footer is Edit and Run now, or Stop (confirmed: it deletes the run's thread) and Open run.
  The ••• menu has Open Run, Edit and Delete Automation (confirmed).
- **Form:** Name, Prompt, Where it runs (Host when adding and more than one can take it, then
  Folder from the host's spaces), and Starts with Shepherd. Save waits for the host. A new
  automation keeps one id for the life of the form, so saving again after an answer that never
  came back can never save it twice.
- **Switches** (`NWAutomationSwitch`) flip from their whole 44pt target, caption included, and
  read as toggles to VoiceOver.
- **When a change does not come back ok:** a refusal shows a banner with the host's reason
  ("Couldn't start the run: …"). A timeout or a dropped connection says the change may have
  happened and to check before trying again; nothing is ever resent on its own. Delete closes
  the iPhone's detail only once the host has removed the automation.

## Verifying visuals

- **Previews:** `ShepherdPreviewTests` render every surface offscreen, in light and dark:
  - thread states (idle, running, thinking, queued, failed, prose, question, empty, starting
    before and after the delay, restoring from disk, a hovered turn, "Jump to latest" over the
    fade, a long stretch folded into one line) and the activity-line states
  - the composer and its menus
  - the queue (the Queue & steer boards): Up next over a running thread with a hovered row and
    a draft (Stop outlined beside Send), a Steering row under a steered message, the editor with
    a Deleted row and the Send menu, every row and stack state, and "From the queue" and
    "Steered" in the thread
  - subagent cards, the ledger, and the inspector
  - the review pane, and its Commit… sheet in every state
  - the palette, the toolbar, the sidebar at each row density, and the window at its minimum
  - the terminal panel: two tabs under the thread, the first split, and maximized
  - every Settings page, sheet, and dialog
  - the empty states

  They write `<surface>-<light|dark>.png` into `$SHEPHERD_PREVIEW_DIR` (the suites are skipped
  when it is unset), so you, or an agent, can look at them:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
  ```

- **Windows:** preview windows sit off-screen and never take focus.
- **Motion:** SwiftUI keeps animating in an off-screen window, so `MotionProbe`
  (`Tests/ShepherdAppIntegrationTests/Support`) records a thin strip of one every few milliseconds
  while a change settles. Compare the frames with the start and end states (`inBetween`,
  `firstColumn(differingFrom:)`, `lastRow(differingFrom:)`) to show that a surface slides, that it
  only fades under Reduce Motion (`.environment(\._accessibilityReduceMotion, true)`), or that it
  stays instant. `MotionProbeTests` is the example. An off-screen window completes removal
  transitions at once (even an explicit `withAnimation`'s completion fires within a frame), so
  record what arrives; what leaves runs the same transition in reverse.
- **Component Gallery:** in Debug builds, the View menu has a Component Gallery.
- **The running app:** build and run the `Shepherd (Dev)` scheme and check the change in both
  appearances.
