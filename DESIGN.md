# Shepherd design

This document is the authority on how Shepherd looks and behaves on macOS. Where anything
disagrees with it, this document wins. It condenses the design handoff,
[`docs/design-spec/handoff.md`](docs/design-spec/handoff.md) (boards in
[`docs/design-spec/boards/`](docs/design-spec/boards/)), and the Night Watch design system that
supersedes its visual foundations, and records where Shepherd deliberately departs from them. All
values live in the ShepherdUI package (`Packages/ShepherdUI`), and the code is cited by type name
so you can check it.

## Mental model: agents, not chats

Shepherd organizes work around **agents**, not chats: live workers you supervise. An agent is a
`pi --mode rpc` process with:

- a title it gives itself
- a workplace (a space's checkout, or a worktree of it)
- a lifecycle: working, blocked, done, idle

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

1. **Readable measure.** The thread column is 760pt, and agent prose is capped at 680pt (about 85
   characters).
2. **Shape, not labels.** There are no speaker labels. A user turn is a trailing bubble; agent
   output is unboxed prose.
3. **One line per tool call.** Tool activity scans at a glance. Detail is one click away; raw
   arguments are two.
4. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats the header pill, no working directory under the composer, no footers in menus.

And the rules that follow from them:

- **Flat surfaces separated by borders.** Three background layers (canvas, surface, raised) and
  three border strengths do the work. The shadows are the composer's, the segmented-control
  thumb's, and one larger shadow shared by floating menus and the palette. No vibrancy, no
  translucency, and no gradients except the fade above the composer.
- **Honest affordances.** Never show a control that does nothing, a shortcut that isn't wired, or
  sample data in place of real data. Hide unsupported capabilities, or explain them.
- **No permission model.** Shepherd never invents approval UI. When pi or an extension asks a
  question, show it as a question with the answers the asker offered.
- **Status is a dot (or glyph) plus a word.** Color is never the only signal for an actionable
  state.
- **The sidebar tree is the primary navigation.** The command palette is a secondary jump
  surface and never the only way to reach something.
- **One primary action per surface.** A destructive action is never the ⏎ default.

## Where Shepherd departs from the handoff

| Handoff | Shepherd | Why |
| --- | --- | --- |
| IBM Plex Sans and JetBrains Mono | Geist and Geist Mono, bundled (SIL OFL), on Night Watch's ramp | Night Watch's faces |
| Mock palette from `tokens.json` | Night Watch's roles and values (light and dark) | Night Watch is the product's palette; the roles are the contract |
| Sidebar rows 32pt with a 22pt indent, plus a 26pt "compact form" while a right pane is open | Rows **26pt** (density-scaled) with a 16pt indent, always. No compact form | A real fleet lost a third of the tree at 32pt |
| Sidebar fixed at 256pt, shrinking to 184pt while a right pane is open | Resizable (190–340pt, default 256, persisted), and it **keeps its width** when a right pane opens | Shrinking on every pane toggle made the whole window jump |
| A SHELLS section, and Shells tabs | Removed. Terminals exist only as panes beside a thread | Global shells and space shell workspaces were removed |
| ⌘M opens the model picker | **⇧⌘M** | ⌘M is the system Minimize chord |
| Runtime (Terminal vs Native RPC) as a creation-time choice | Gone: every agent is RPC | Terminal agents were removed |
| Right-pane width persists per window | It persists app-wide | One main window |
| Review segmented control "Local \| PR #n" | "Local \| PR", or "PR · <ref>" once the PR base is known | The ref, not a PR number, is what the diff is against |
| Palette sections: Commands, This thread, Subagents (+ Agents when searching) | Also **Spaces** and **Found in conversations** (transcript search) when searching | Every destination is reachable from the palette |
| iOS in the same pass | macOS first; iOS adopts the system later ([docs/ios](docs/ios/README.md)) | Scope |

Additions the handoff doesn't have:

- The composer's **delivery chip** (Follow-up / Steer), shown while a turn runs with a draft,
  because pi supports both.
- The header's **subagent rollup** ("n subagents · tokens").
- A **quit confirmation** while agents are working.

## Theme model

All design values live in the **ShepherdUI** package (`Packages/ShepherdUI`, module `ShepherdUI`),
which implements **Night Watch**, the design system on the Night Watch boards (Foundations,
Controls, Status, Swift). It is SwiftUI only and holds no app state. Views read colors from
`Color.nw`, fonts from `Font.nw(_:)`, and sizes from `NW.Space`, `NW.Radius`, and `NW.Height`
(plus the app's own surface dimensions in `AppLayout`). **Never hardcode a color, font size, or
dimension in a view.**

A theme is pure data (`ThemeDefinition`: hex strings, `Codable`), so the built-in theme and future
user themes go through the same model:

```text
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors:   ThemeColors     // the Night Watch roles below (#RRGGBB or #RRGGBBAA)
                  syntax:   SyntaxColors    // code blocks and diffs
                  terminal: TerminalColors  // Ghostty: background, foreground, cursor, selection, 16-color ANSI
                  pi:       PiColors }      // pi's TUI theme schema, for pi run by hand in a terminal pane
```

- **`ThemeStore.shared`** holds the selected theme, text scale, and density. It resolves each theme
  once into an immutable `NWPalette` (every `Color` built when the theme changes) and each text
  scale into an `NWTypeRamp`, so a token read is a stored-property load.
- **Colors are dynamic:** every palette color resolves against the appearance of the view drawing
  it, so light and dark are never stored and never need a re-render.
- **`ThemeManager`** (app) owns only the appearance mode: System, Light, or Dark, set in
  Settings ▸ Appearance or the Appearance menu. `SHEPHERD_THEME=night-watch-dark|night-watch-light`
  forces one at launch.
- **What `ThemeManager` pushes:** the resolved variant goes to what cannot follow appearance on
  its own. That is Ghostty surfaces (a live `setTheme`, never a remount or replay) and the pi
  theme file plus the `shepherd-active-theme` variant marker (`night-watch-dark|light`), which pi
  and editors run in a terminal pane watch.
- **Fonts:** Geist and Geist Mono (SIL OFL, `Resources/Fonts/OFL.txt`) ship in the package bundle
  and are registered for the process at launch (`NWFonts.register()`); no Info.plist entry.
  Terminal panes keep their own font setting.

### Roles (`ThemeColors`, read as `Color.nw.<role>`)

| Group | Role | Use |
| --- | --- | --- |
| Surfaces | `bgBase` | Sidebar, window chrome |
| | `bgWindow` | Thread, panes, terminal panes |
| | `bgRaised` | Cards, composer, menus, fields |
| | `bgSunken` | Code, tool output, headers, segmented track |
| | `bgBubble` | User messages |
| | `bgHover` | Row hover (translucent) |
| | `bgSelected` | Selected row (translucent) |
| Lines | `lineSubtle` | Dividers, row separators, card borders |
| | `lineStrong` | Control borders, popovers |
| Text | `textPrimary` | Body, titles |
| | `textSecondary` | Labels, previews, descriptions |
| | `textTertiary` | Meta, timestamps, counts, section labels |
| | `textOnLantern` | Text on a lantern fill |
| Brand and state | `lantern` / `lanternText` / `lanternTint` | Brand, the primary action, needs you |
| | `running` / `runningTint` | Running, links, focus |
| | `done` / `doneTint` | Success, additions |
| | `failed` / `failedTint` | Failure, deletions, destructive |
| Syntax | `synKeyword`, `synType`, `synString`, `synNumber`, `synFunction`, `synComment` (+ `synVariable`, `synOperator`, `synPunctuation`) | Code |

**Derived colors** live on `NWPalette`, not in the theme: `focusRing` (running at 60% dark /
50% light), `popoverShadow` (the only shadow), `scrim`, `textOnFailed`, and the switch knob colors.

**Status is one enum.** `AgentState` (`running`, `attention`, `done`, `failed`, `stuck`, `queued`,
`idle`) gives every status surface its color, tint, word, and glyph. The app maps its lifecycles
onto it (`AgentStateMapping.swift`: agent status, subagent runs, tool calls). Only `attention`
animates (a 1.6s glow).

### Night Watch

`ThemeDefinition.nightWatch` (`NightWatch.swift`) is the only shipped theme. The UI and syntax
roles are the Foundations board's values. The terminal and pi palettes are derived from the roles:
the terminal sits on `bgWindow` with `textPrimary` text and a lantern cursor, and pi uses the same
brand, state, and syntax colors, with translucent tints flattened onto `bgWindow`.

- **Dark:** near-black (`bgBase #0a0b0c`, `bgWindow #0d0e10`, `bgRaised #15171a`), lantern amber
  `#f2a93b`, running blue `#7aa7ff`.
- **Light:** paper white (`bgBase #f2f2f0`, `bgWindow #fbfbfa`, `bgRaised #ffffff`), lantern
  `#e39a26`, running `#2f6fe0`.

### Contrast rules

`ShepherdUIUnitTests` checks every built-in variant (translucent fills are painted over the
surface they sit on):

- `textPrimary` and `textSecondary` reach 4.5:1 on `bgBase`, `bgWindow`, and `bgRaised`, and
  `textPrimary` on `bgSelected`.
- `lanternText` on `lanternTint`, and `textOnLantern` on `lantern`, reach 4.5:1.
- State colors reach 3:1 on `bgWindow` as dots and glyphs, and stay distinguishable.
- **Documented exceptions** (the board's colors, kept; the test pins their measured ratios):
  `textTertiary` meta text (dark 3.06–3.35, light 2.40–2.69), the light state pills' words on their
  own tints (running 3.98, done 3.01, failed 3.71 over the window), the light lantern as a mark
  (2.27), and white on `failed` (dark 3.18, light 4.33).
- Every role parses, UI roles alone may be translucent, the ANSI palette has 16 entries, the
  theme round-trips through JSON, and the terminal background equals `bgWindow`.

### Adding a theme or a role

- **A theme:** write a `ThemeDefinition` that fills every field of `ThemeColors`,
  `SyntaxColors`, `TerminalColors`, and `PiColors` for both variants (the memberwise initializers
  make the compiler enforce completeness). Add it to the list the ShepherdUI unit tests iterate and
  fix values until they pass. Then teach `ThemeManager` and the app's `ShepherdTheme` to resolve it
  for Ghostty and the pi theme file; today they resolve Night Watch only. The variant marker's
  `<theme>-dark|light` spelling is an external contract.
- **A role:** add a field to `ThemeColors`, a value in every theme's light and dark variant, a
  property on `NWPalette`, and a contrast rule if it carries text.

## Typography

Geist for prose and chrome, Geist Mono for anything the agent touched (paths, commands, code,
output, counts, times). Every size scales with Settings ▸ Appearance ▸ Text size
(`ThemeStore.textScale`, 0.85–1.3). `.nwText(_:)` applies a style with its line height (extra
leading from the face's real metrics); `.font(.nw(_:))` alone suits single lines.

| Style | Spec | Use |
| --- | --- | --- |
| `display` | Geist 28/600/1.15 | Empty states, onboarding, settings page titles |
| `title` | Geist 15/600/1.3 | Thread and pane titles, sheet and dialog titles |
| `headline` | Geist 13.5/600/1.35 | Card titles, section heads |
| `body` | Geist 13.5/400/1.6 | Agent prose, bubbles |
| `ui` | Geist 12.5/500/1.3 | Rows, buttons, controls |
| `caption` | Geist 11.5/400/1.35 | Secondary info, descriptions |
| `code` | Geist Mono 12/400/1.55 | Code blocks, output |
| `mono` | Geist Mono 11.5/400/1.3 | Paths, commands, tool rows |
| `micro` | Geist Mono 10.5/500/1.2 | Section labels (`.nwSectionLabel()`: uppercase, tracked, tertiary), counts, times |

`Font.nw(_:weight:)` takes a weight for the rare emphasis the ramp lacks; `Font.nwSans(_:_:)` and
`Font.nwMono(_:_:)` exist for the few one-off sizes (the empty-state title, the palette search).
Prefer a ramp style. The terminal font (family and size) is its own setting in Settings ▸
Terminal and never follows the chrome's text scale.

## Metrics, spacing, radii

- **Space** (`NW.Space`, 4pt grid): `xxs 2`, `xs 4`, `s 6`, `m 8`, `l 12`, `xl 16`, `xxl 24`,
  `xxxl 32`.
- **Radius** (`NW.Radius`): `xs 4` pills, keycaps, chips · `s 6` buttons, fields, rows · `m 8`
  cards, the composer, tool groups · `l 12` popovers, the palette, sheets.
- **Height** (`NW.Height`): rows `rowCompact 22`, `row 28`, `rowComfortable 36` (scaled by
  Settings ▸ Appearance ▸ Density, 0.8–1.5); controls `controlS 24`, `controlM 28`,
  `controlL 32`; `touch 44` on iOS.
- **Hairlines** are 1px, not 1pt: `NWHairline` and `.nwBorder(_:radius:)` use `1 / displayScale`.
- **Elevation:** `.nwCard()` is flat (raised fill, 1px line); `.nwPopover()` carries the system's
  only shadow; `.nwFocusRing()` is running blue, 2pt wide, 2pt outside, for keyboard focus only
  (`.nwFocusRing(_ visible:)` for a field or card whose focus the caller tracks).
- **Motion** (`NW.Motion`): glow 1.6s, spin 1s, hover 120ms, panes 180ms, sheets 240ms. Under
  Reduce Motion the glow and spinner are static (they are clock-driven, so toggling Reduce Motion
  on screen is safe) and panes cross-fade.
- **Surface dimensions** are the app's (`AppLayout`): window minimum 1040×640 (default 1440×900),
  main column at least 720, thread column 760, prose 680, user bubble 600, header 52 with 20
  padding, sidebar 190–340 (default 256) with 26pt rows × density and a 16pt indent, right pane
  600 (min 480, at most half the window).
- **Icons:** SF Symbols (medium weight, 13–16pt), monochrome. Never filled glyphs for status,
  never emoji.

## Components

`Packages/ShepherdUI/Sources/ShepherdUI/Components` is the shared library, by domain (Controls,
Status, Containers, Thread, Composer, Agents), with `#Preview`s of every component in both
appearances in `Previews/`. Use a component before composing chrome by hand. Debug builds have a
**Component Gallery** (command palette), which shows the components in their states.

| Component | Use |
| --- | --- |
| `.buttonStyle(.nw(_:size:))` (primary, secondary, ghost, danger, dangerFill; s 24, m 28, l 32) | Every text button, on a native `Button`. Primary (lantern) at most once per view; a destructive action is never the ⏎ default. |
| `.buttonStyle(.nwIcon)` | Icon-only buttons: a 28pt circle (44 on iOS); bordered, or "on" (lantern tint) for a pane toggle while its pane is open. Always with an accessibility label. |
| `.nwLink`, `.nwRow(selected:)`, `.nwRowBackground(selected:hovering:)` | Inline running-blue actions; hover and selection fills for rows. |
| `.toggleStyle(.nwSwitch)`, `.toggleStyle(.nwCheckbox)` | Booleans that apply immediately; checks in lists. Native `Toggle`s. |
| `NWSegmentedPicker`, `NWPopupMenu` | 2–4 exclusive options; longer lists (a native `Menu`). The segmented picker represents itself to accessibility as a native segmented `Picker`. |
| `.textFieldStyle(.nw)`, `.nwField(focused:error:mono:)`, `NWSearchField` | Text entry (raised, strong line, focus ring, failed line in error). |
| `NWStepper`, `NWValueSlider` | Integer steppers (accessible as a native `Stepper`); a lantern slider with a mono value (double-click resets). |
| `NWKeycap`, `NWCountBadge`, `NWTag`, `.nwHelp(_:shortcut:)` | A real, wired shortcut; counts (neutral, needs you, failed); roles, models, kinds; help with its shortcut. |
| `NWStatusPill`, `NWStatusDot`, `NWStateGlyph`, `NWBranchGlyph` | State as a pill (headers, cards), a 6pt dot (rows), a 14pt glyph (tool rows, runs), a subagent glyph. |
| `.progressViewStyle(.nwSpinner)`, `.progressViewStyle(.nwBar)`, `NWStepStrip`, `NWSparkline` | Running work, progress, one segment per step or run, activity. |
| `NWBanner`, `.nwToast(item:)`, `NWEmptyState`, `.nwShimmer()` | Inline banners (never modal alerts for agent events), transient toasts, empty states, loading placeholders. |
| `NWSectionHeader`, `NWGroupCard`, `NWCardRow`, `NWHairline` | Section labels, grouped cards with 1px rules, the settings row. |
| `NWDiffStat`, `NWInlineCode`, `NWAttachmentChip`, `NWComposerChipStyle`, `NWComposerActionButton`, `NWChipChevron` | Thread and composer parts (their domains' later phases own their final form). |
| `NWWordmark`, `NWCrook` | The mark. |

App-level building blocks sit on top of these:

- `SettingsPage`, `SettingsGroup`, `SettingsRow`, `SettingsSwitch`, `PathRow`
  (`SettingsComponents.swift`)
- `DialogSheet`, `SheetRow`, `DialogAction`, `DialogWarning`, `RenameDialog` (`DialogSheet.swift`)
- `CodeBlockView` for fenced code

**Reading the surface sections below.** They predate Night Watch and still name the old roles.
Read them through the mapping the migration applied: `bgCanvas`→`bgBase`, `bgSurface`→`bgWindow`,
`bgMuted`/`bgTrack`→`bgSunken`, `bgHoverStrong`→`bgHover`, `borderSubtle`/`border`→`lineSubtle`,
`borderStrong`→`lineStrong`, `text`→`textPrimary`, `textTertiary`→`textSecondary`,
`textMuted`/`textDisabled`/`dotIdle`→`textTertiary`, `accent`/`accentText`→`running` (links,
focus, running) or `lantern` (the primary action), `accentBg`→`runningTint`,
`success…`→`done`/`doneTint`, `warning…`→`lantern`/`lanternText`/`lanternTint`,
`danger…`→`failed`/`failedTint`, the old type ramp onto the nearest Night Watch style. The domain
phases rewrite each surface section as they restyle it.

## Window structure

```text
┌────────────────┬───────────────────────────────────────────┬──────────────────────┐
│ traffic lights │ header 52: space / title · pill · · 18 turns · 46k ctx · ▯ ⋯ │
│                ├───────────────────────────────────────────┼──────────────────────┤
│ THIS MAC    19 │        760pt thread column                │ right pane (optional)│
│ › Space      8 │               ┌───────────────┐           │ review or subagent   │
│   ● agent      │               │  user bubble  │           │ inspector, 600pt     │
│   ● agent      │   agent prose (680pt measure) │           │ (min 480, ≤ 50%)     │
│     ↳ subagent │   ┌ tool group ─────────────┐ │           │                      │
│ HOST  Unreach. │   └─────────────────────────┘ │           │                      │
│────────────────│   ┌ composer card ──────────┐ │           │                      │
│ AUTOMATIONS  1 │   └─────────────────────────┘ │           │                      │
└────────────────┴───────────────────────────────────────────┴──────────────────────┘
```

There is one window. The sidebar sits on `bgCanvas`, running behind the traffic lights, and the
main column sits on `bgSurface`. There is no tab bar and no status line. An agent's layout is its
thread plus any terminal panes split beside it. Pane dividers are 1pt `border`, tinted accent
where they border the focused pane.

Switching agents flips visibility; it never remounts. Every mounted layout stays in the view
tree, and hidden ones are `opacity(0)`. This is what makes switching instant.

**With no agent on screen**, the workspace shows one of three empty states:

- A selected space with no agents: "No agents in <space>", "Start one to work in <path>.", a
  primary **New agent** button, and its keycaps.
- No spaces at all: "No spaces yet", "A space is a project folder your agents work in.", and a
  primary **New space…** button.
- Otherwise: "No agent selected", "Pick one in the sidebar, or start a new one.", and the New
  agent keycaps.

## Surfaces

### Sidebar

- **Sections**, 8pt padding:
  1. **This Mac**, with its agent count and a hover `+` for New Space.
  2. One section per remote host, with a count, "n need you", "Connecting…", "Unreachable" (in
     `dangerText`), or "Off".
  3. Behind a 1pt `border`: **Automations** (hidden while empty).

  Section headers use `.sectionStyle()` with a trailing count, and clicking one toggles the
  section. With remote hosts configured, hovering a header shows its machine chord (⌃⇧n).
- **Spaces** are disclosure rows: chevron, name, and agent count, plus a `⎇n` worktree count and
  a blocked count in `warningText`. Clicking toggles the space; it has no view of its own. A
  hover `+` starts a new agent in the space. Nested projects indent by path containment, and
  agents nest beneath their space.
- **Rows:** 26pt, radius 6, 16pt indent per level. Hover is `bgHoverStrong`; selected is
  `bgSelected`, with the title in medium weight. A 7pt status dot leads, `⎇` marks a worktree
  agent, and the title truncates at the tail with the full title in a tooltip.
- **Trailing slot**, in priority order:
  1. the ⌘-digit badge while ⌘ is held
  2. "needs you" (`warningText`)
  3. "n sub" for a folded subagent group
  4. elapsed time while working
  5. "done"
- **Status dot:** working is `success` (green, "alive"), blocked is `warning`, and idle or done is
  `dotIdle`, or `accent` for the open thread.
- **Subagents** nest under their parent on a 1pt tree line, with a `BranchGlyph` in the state
  color instead of a dot. The trailing slot shows elapsed time (in `accentText`), "needs you",
  "failed", or a duration.
  - While any run is live, the group is expanded.
  - Once every run has finished, the group gets a disclosure header ("n subagents · done h:mm").
    It is expanded for the selected thread and folded for the others.
  - Selecting a subagent row opens it in the inspector.
- **Width:** resizable by dragging its edge (190–340pt) or in Settings ▸ Appearance. It keeps its
  width while a right pane is open. ⇧⌘S hides it, and the header then runs under the traffic
  lights.
- **Interaction:** rows are tap views with button traits and accessibility actions, so they can
  also be dragged to reorder (with a 2pt accent drop line). Hover `+` glyphs are real labeled
  buttons. Spaces, agents, hosts, and automations have context menus.
- **Disconnected hosts:** their rows dim, and connection state lives on the section header,
  never in a banner.

### Header

The header is 52pt on `bgSurface` with a 1pt `border` rule beneath and 20pt padding. From left to
right:

- the `space / title` breadcrumb, with the space in tertiary and the title in `title`, truncating
- the `StatusPill`, in priority order: error, needs you, running, idle
- a spacer
- counters in `micro`/`textMuted`: "18 turns · 46k ctx", plus a subagent rollup when there are
  subagents. The turn count appears once the whole history is loaded, and the context tooltip
  has the details.
- the right-pane toggle, accent-tinted while open
- the options menu: Refresh Thread, Load Older Messages (while older history exists), Rename…

With no thread on screen, the header shows the breadcrumb only ("<space> / No agent selected").

### Thread and turns

- **Layout:** a scroll view with the 760pt column centered, 28pt top padding, 28pt between turns,
  and nothing else between them.
- **User turn:** a trailing bubble on `bgBubble`, at most 600pt wide, with 12×16 padding and
  radius 12 (the bottom-trailing corner is 4), in `bodySmall`. Its time sits beneath in
  `micro`/`textMuted`.
- **Agent turn:** consecutive assistant messages render as one turn. Prose (`body`, at most
  680pt) renders Markdown:
  - headings
  - lists with one nested level
  - quotes on a 2pt rule
  - inline code on `bgHover`
  - fenced code in a `CodeBlockView`: a 28pt `bgMuted` header with the language and Copy, then
    syntax-colored code

  Blocks are 10pt apart. Errors and notes render as their own rows on a 2pt rule.
- **Thinking** comes before the first prose. Collapsed, it reads "Thought for Ns" in italics (or
  "Thought" when shorter than half a second or unknown). While streaming, it reads "Thinking…"
  with a spinner. Expanded, it shows tertiary italic prose on a 2pt `border` rule.
- **Turn footer**, after a finished turn: copy and retry as 28pt ghost icon buttons, then "time ·
  duration · N tool calls · n subagents". The subagent count links to the run. The footer is
  hidden while the turn runs.
- **Working row:** while the agent runs, the thread ends in one row with a spinner and the current
  activity in tertiary italic: "Running <tool>…", "Thinking…", or "Working…".
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom.
  A live scroll gesture detaches it, and "↓ Jump to latest" returns. Sending re-attaches.
  Streaming text appends in place and never re-lays out earlier blocks. The composer is the scroll
  view's bottom inset, so the thread always ends at its last turn.
- **Empty thread:** "Starting pi…" with a spinner while connecting. Then a framed `EmptyState`,
  "New agent in <path>" (the path in mono), with "Describe the task. Drop or paste images to
  attach them, or type / for commands."
- **Notices** above the thread explain degraded states, for example "Last known thread ·
  refreshing before enabling actions" or "Some earlier output is clipped".

### Tool rows

Consecutive tool calls form one `ToolGroup`: border `border`, radius 10, `bgSurface`, with rows
divided by `borderSubtle`. Prose between calls splits the group. Each call is one 36pt row:

- **Status glyph** (14pt).
- **Tool name**, in code face and tertiary, in a 40–76pt column.
- **Preview**, in code face, tail-truncated:
  - read/write: the path, plus `:start–end` when a range was given
  - edit: the path
  - bash: the first command line
  - grep: the quoted pattern and its scope
  - anything else: the first output line, up to 120 characters
- **Result:**
  - edit: `DiffStat` and "k blocks"
  - read: "n lines"
  - bash: `BUILD SUCCEEDED` or "n passed" in `successText`, or "exit n" in `dangerText`
  - grep: "n matches"
- **Duration** in `micro`, live while running ("running" in `accentText` until the first tick).
- **Chevron**, when the row has output.

Expanding a row gives it `bgMuted` (`dangerBg` if the call failed) and shows up to 12 lines of
output: a running call streams its tail, a finished one shows its head. Then "… n more lines"
opens the full output in a sheet with Copy. Edit and write rows add a trailing "review ›" link
into the review pane. Raw arguments stay behind ⌥-click or the context menu → "Show Call" (a
popover); the menu also has Open Output and Copy Output. Hover is `bgHover`.

### Composer, questions, and menus

**The card:**

- It is pinned to the bottom of the main column, in the same 760pt column, with a fade from
  transparent to `bgSurface` above it.
- It is `bgRaised`, with `borderStrong`, radius 12, and the composer shadow.
- While focused, while a menu is open, or while a drop hovers, the border turns `accent` with the
  3pt `focusRing`.

**Layout:** the field is on top (`bodySmall`; it grows to 8 rows, then scrolls). One action row
sits beneath:

- attach (only when the agent accepts images)
- "/ commands" (only when pi reports commands)
- the model chip
- the thinking chip
- the delivery chip (Follow-up / Steer, only while a turn runs with a draft)
- a spacer
- the single `ComposerActionButton`

**States:**

- **Idle:** Send. The placeholder is "Follow up, or / for commands…" ("Follow up…" when pi
  reports no commands), or "Describe the task, or / for commands…" on a fresh agent.
- **Running:** Stop (`danger`) while the field is empty. The field stays editable with "Queue a
  follow-up — sent when the turn ends".
- **Accepting:** a spinner ("Waiting for pi") takes the button's place.
- **Error:** Send, plus an `InlineError` above the card ("Lost connection to the agent process.")
  with Reconnect.

With more than one live subagent, Stop asks once whether to stop everything. There is no status
text, key hint, or working directory in or under the composer.

**Images** attach by drop, paste, or the paperclip. They are resized on the way in (longest edge
2000px), up to four per message, and shown as `AttachmentChip`s.

**Questions** from pi or an extension (select, confirm, input, editor) replace the field *inside
the card*, never in the scrolling thread, so a blocked agent is always answerable. The panel
shows:

- the title, then the message in a `bgMuted` box (at most 140pt tall)
- the asker's options (the first one primary), Yes/No, or a field with Submit
- Dismiss
- "1 / N" when several are queued

**Extension widgets** (an extension's `setWidget` text, with ANSI stripped) appear as small titled
text rows above the card. Machine payloads, `setStatus`, and `notify` are not shown. Widgets are
display-only, and the app chooses every font and color.

**Menus** open above the card, left-aligned, with an 8pt gap, on `.menuSurface()`. Only one is
open at a time, and Esc returns focus to the field.

- **SlashMenu** opens when the draft is "/…" (or from the chip). Its header reads "Commands · n
  of m". Rows are 36pt: the command in mono (with the typed prefix in bold) in a 150pt column,
  its description, a source tag for prompt templates, and ⏎ on the highlighted row. The
  highlight is `accentBg`, and it shows at most 8 rows. ↑↓ select, ⏎ runs, ⇥ completes with a
  space, and Esc closes. The list is pi's command registry, never hard-coded.
- **ModelPicker** opens from the model chip or ⇧⌘M. It is 380pt wide with search on top, then
  Recent (up to 4), then one group per provider. Rows are 32pt, or 40pt with a note ("Current ·
  this thread", "Used 5m ago in …"), and show a check, the ID in mono, and the context size. It
  picks the model only.
- **Thinking chip:** a bulb, "Thinking", and Off / Low / Medium / High. A small menu, independent
  of the model, hidden when the model has no reasoning control.

### Subagents

A subagent is a turn inside a turn. Its spawn call renders as a card where the call was, and raw
wait or status dumps never appear. Behavior is specified in
[native-subagents.md](docs/native-subagents.md).

- **SubagentCard:** a 40pt header with the branch glyph, name (`labelStrong`), "mode · model ·
  thinking" in `micro`/tertiary, and a trailing state (Running + elapsed, Paused, Needs you, Done
  + duration, Failed). The rest depends on the state:
  - **Running:** step n/m and the 4pt `ProgressBar` when steps are reported, "turns · tools ·
    tokens", and **one** live activity line in tool-row form. The card never grows while it runs.
  - **Needs you:** the header is on `warningBg`. The question is shown as prose, its choices as
    buttons (the recommended one primary), and Reply… for free text.
  - **Done:** summary, stats, and Open transcript. It folds to its header while siblings still
    run.
  - **Failed:** one row on `dangerBg`, with Retry and Transcript.

  Its actions are Inspect (⌘I), Steer…, Pause/Continue, and Stop (`dangerText`, trailing). The
  inspected card gets the accent border and ring.
- **RunsStrip:** more than three sibling runs fold into one row: count, one 8pt cell per run,
  "7 done · 3 running · 1 needs you · 1 failed", and totals. Needs-you runs keep their own card.
- **RunLedger:** once every run in the group has finished, the cards are replaced in place by a
  permanent ledger.
  - A 36pt `bgMuted` header: glyph, "n subagents", state cells, "all done · wall · tokens", and
    the combined DiffStat and files.
  - One 44pt row per run in spawn order: glyph, name in a 72pt column, a one-line summary,
    "files · tools · duration", and a chevron.
  - Rows open the read-only inspector. The open row is `accentBg` with a 3pt accent rule on the
    pane side.

### Right pane: subagent inspector and review

One docked slot to the right of the thread (`RightPaneSplit`) is shared by the subagent inspector
and the review. When both exist, the inspector wins.

- **Size:** default 600pt, minimum 480pt, at most half the window. The left edge is the drag
  handle, and the width persists.
- **Toggling:** ⇧⌘B or the header button toggles it, closing whatever is open or otherwise
  opening the review.
- **Layout:** the thread keeps running beside it. A pane never replaces the thread and never
  changes the persisted layout. The sidebar keeps its width.

**Subagent inspector:**

- A header with the name, "k of n", a state word, and "mode · model · turns · tools · tokens".
  Live runs also get Pause/Continue and Stop, plus a ⋯ menu.
- A Goal strip.
- The run's own transcript, drawn with the thread's components one step smaller (34pt tool rows,
  14pt prose). It follows live, with "n earlier turns · Show all" above.
- A Steer composer whose placeholder and "to: worker · not the parent" line name the recipient.
- **A finished run is read-only:**
  - ‹ › step through siblings.
  - A Result block shows the summary and touched files.
  - Messages from the parent are captioned "from parent".
  - The bottom bar has Re-run · Fork as new agent · Copy transcript · "kept with the thread"
    instead of the composer.

**Review** (`ReviewPane`, `DiffReviewView.swift`):

- **Header (52pt):** "Review" in `title`, with the scope beneath ("working tree vs HEAD" or
  "branch vs <ref>" · n files · +a −r). It also holds a Local | PR segmented control, an options
  menu (Expand All Files, Collapse All Files, Copy Review as Text), and close.
- **File strip (34pt, on `bgCanvas`):** 24pt chips, each with a status letter (M `warningText`,
  A `successText`, D `dangerText`, R `accentText`), the filename, and a DiffStat. The selected
  chip is `bgSelected`, and viewed files dim. A pulsing 6pt accent dot shows while the running
  agent touches the file.
- **File headers (sticky, 36pt, on `bgMuted`):** chevron, the path with the filename bold, the
  hunk count and comment count, then Open in Xcode (or the default editor), Revert (`dangerText`,
  confirmed, local working-tree reviews only), and Viewed.
- **Diff lines:** 21pt, 12 mono, with old and new number columns, a sign column, and
  syntax-colored code. Removals are on `dangerBg`, additions on `successBg`, and hunk headers on
  `bgHover`. Lines are tail-truncated with the full line on hover, never wrapped.
- **Folding:** a run of more than 8 like lines folds to a 24pt strip ("13 more removed lines ·
  20–32"). ⌥-click expands the whole file.
- **Comments:** hovering a line shows an accent `+`, and double-clicking a line also starts a
  comment card.
- **Review composer:** at the bottom. Request changes sends the overall and inline comments as the
  next user turn (queued if the agent is mid-turn). Commit asks the agent to commit. The review
  closes only once the send succeeds.
- **Keys:** j/k move between hunks, n/p between files. c comments, v marks viewed, ⌘⏎ sends, and
  Esc returns to the thread composer.
- **Repository changes:** per-file Revert is the only repository mutation outside the worktree
  flows. Tracked files return to HEAD; new files move to the Trash.

A review an agent opens (`review_diff`) is the host's view state; remote viewers open their own
with ⇧⌘B.

### Terminal panes

Terminal panes render through libghostty on the theme's terminal colors, with a `bgSurface`
background. An agent's layout may hold terminal panes beside its thread; the thread pane itself
never has a terminal. A pane whose process died shows a quiet placeholder ("session exited (n)").
The chrome never parses or restyles terminal output.

### Command palette

⌘K opens a 640pt card, 120pt from the top of the window over the `scrim`: radius 14, `bgRaised`,
a strong border, and the menu shadow.

- **Search row (56pt):** 16pt text and a search glyph, with scope pills All · Commands · Agents
  (⇥ cycles them). The placeholder is "Search commands, agents, subagents…".
- **Sections:** results are grouped under `sectionSmall` headers: Commands, This thread, and
  Subagents, and, when searching, Agents, Spaces, and Found in conversations. Conversation search
  needs at least 3 characters and reads the recent part of each agent's pi session. The Agents
  scope lists destinations even with no query.
- **Rows (38pt):** a stroke icon, the label (14pt sans), optional context in `textMuted`, and the
  real shortcut as `Keycaps`. The highlight is `accentBg` with an accent icon. Subagent rows use
  the branch glyph in their state color.
- **What it never shows:** footer hints, ⌘1–9 numbering, or any status the sidebar doesn't show.

### Settings

Settings replaces the window content in place. ⌘, toggles it, and "Back to Shepherd" or Esc
returns.

- **Navigation:** a 232pt nav on `bgCanvas`. It holds Back to Shepherd, a search field (⌘F), then
  Appearance · Terminal · Agents · Worktrees · Pi · Remote · Keyboard · Advanced, with
  "Shepherd x.y.z · pi x.y.z" pinned at the bottom in `micro`. Searching lists matching rows by
  section.
- **Content:** a 720pt column with 44pt top padding. Each page has a title in `display` and a
  one-line explanation, then small section headings over `GroupCard`s of rows. A row is at least
  52pt: title in `rowTitle`, description in `description`/tertiary, control trailing.
- **Controls:**
  - `SegmentedControl` for 2–4 options
  - the accent switch for booleans
  - `PopupMenu` for longer lists
  - `ShepherdStepper`
  - `ValueSlider`
  - `Keycaps` for shortcuts (click to record, with a "Reset" link when changed)
  - secondary buttons (danger text when destructive)
- **Footnotes and problems:** footnotes are 12pt sans `textMuted`. Inline problems (like the
  listener's bind error) sit in the row in `dangerText` under the description.

| Page | Contents |
| --- | --- |
| **Appearance** | Theme (Night Watch), mode (System/Light/Dark), density, text size, sidebar width |
| **Terminal** | Pane font family and size, a live preview, the shell |
| **Agents** | Default model, default thinking level |
| **Worktrees** | Base branch (Remote default / Current branch), fetch before creating, and finalize: commit remaining work, generate PR descriptions, delete local branch, merge automatically (+ method) |
| **Pi** | Bundled extensions (name agents automatically, sync pi theme, panes and agent tools, diff review tool, native subagents, subagent display), native subagent defaults, and pi and extension updates |
| **Remote** | Hosts (edit, reconnect, remove), add host (name, address, port, token), Serve this Mac (listener, token file) |
| **Keyboard** | Rebindable shortcuts by group, plus the fixed chords and Reset all |
| **Advanced** | Files (state, socket), updates and channel, reset |

### Dialogs and sheets

Creation sheets (New Agent, New Worktree, Finalize Worktree, remote directory and worktree sheets)
and confirmations (`DialogSheet`) share one anatomy on `bgSurface`:

- a title in `title`, and optional labeled rows (`SheetRow`)
- a footer of `ShepherdButtonStyle` buttons
- exactly one primary action as the ⏎ default. A destructive action is never the default:
  destroying things takes a click.
- anything a destructive action would destroy is called out in a `DialogWarning` strip
  (`warningBg`/`warningText`)

## Status language

| State | Sidebar | Header pill | Composer |
| --- | --- | --- | --- |
| idle / done | `dotIdle` dot (`accent` for the open thread); "done" trailing | Idle: `successBg`/`successText`, `success` dot | Send |
| working | `success` dot; elapsed trailing | Running · elapsed: `accentBg`/`accentText`, spinner | Stop; the field queues a follow-up |
| blocked / subagent needs you | `warning` dot; "needs you" trailing | Needs you ("n subagents need you"): `warningBg`/`warningText` | Question panel in place of the field |
| error (connection lost) | — | Error: `dangerBg`/`dangerText` | Send + `InlineError` with Reconnect |
| stopped (component state; the header never shows it) | `dotIdle` | Stopped: `bgBubble`/`textSecondary` | Send |

Subagent runs use the same colors on their branch glyph: running `accent`, needs you `warning`,
done `success`, failed `danger`.

## Keyboard

Keyboard is first-class, and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (defaults in `ShortcutAction.defaultChord`, overrides in UserDefaults under
`shepherd.keybindings`).

- **One source:** menus, palette keycaps, Settings ▸ Keyboard, and the Ghostty unbind list all
  read the store. Hardcoding a chord in a view is a bug, and a hint is never shown for a chord
  that isn't wired.
- **Rules for a rebound chord:** it must include ⌘, and must not be ⌘1–9, ⌘, or a plain ⌘ system
  or terminal chord (⌘Q, ⌘H, ⌘M, ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z).

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
- ⌘, opens Settings.
- In the composer, ⏎ sends and ⇧⏎ inserts a newline. `/` at the start opens the command list, and
  Esc closes a menu.

Review-pane and menu keys are listed with their surfaces.

## Accessibility and motion

- **Controls:** every control is a real `Button`, `Toggle`, or text field, or carries button
  traits and actions. Icon-only buttons carry an `accessibilityLabel`.
- **Rows read as one element:**
  - agent rows: "title, [worktree,] status word"
  - subagent rows: "name, subagent, state"
  - automation rows: "name, automation, state"
  - tool rows: "read, ThreadView.swift, 160 lines, done", with "Show call" as a named action
- **Color:** status color is always paired with a word or a glyph shape. Contrast follows the
  theme rules above, and no text is lighter than `textMuted`.
- **Reduce Motion:** spinners become a pulsing dot, and expand/collapse and scroll animations are
  dropped. Otherwise transitions are short (150ms or less) and ease out.
- **Menu bar:** every pane and agent action exists in the menu bar with its shortcut.

## Known gaps

These places in the code break this document and should be fixed toward it:

- **System dialogs:** the Stop-all and per-file Revert confirmations use `confirmationDialog`. A
  failed agent action shows a system alert, and quitting with working agents shows an `NSAlert`.
- **Hardcoded chords:** two hints hardcode a rebindable chord. The model picker's search row shows
  "⇧⌘M", and the subagent card shows "Inspect ⌘I".

## iOS

The iOS client (`App/iOS`, [docs/ios](docs/ios/README.md)) is deferred. It predates this system
and keeps its own `MobileTokens`. It will adopt ShepherdUI (which already builds for iOS 27) and
the handoff's §8 rules later:
navigation instead of the sidebar, 56pt agent rows, collapsed tool groups, the pill composer, and
touch targets of at least 44pt.

## Verifying visuals

Build and run the `Shepherd (Dev)` scheme and compare against the boards in both appearances.

- **Previews:** `ShepherdPreviewTests` render every surface offscreen, in light and dark:
  - thread states
  - review
  - palette
  - settings
  - sheets
  - sidebar
  - empty states

  They write `<surface>-<light|dark>.png` into `$SHEPHERD_PREVIEW_DIR` (the tests are skipped when
  it is unset), so you, or an agent, can look at them:

  ```sh
  SHEPHERD_PREVIEW_DIR=/tmp/shepherd-previews swift test --filter PreviewTests
  ```

- **Windows:** preview windows sit off-screen and never take focus.
- **Component Gallery:** in Debug builds, the View menu has a Component Gallery.
