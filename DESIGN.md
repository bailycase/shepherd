# Shepherd design

This document is the authority on how Shepherd looks and behaves on macOS. Where anything
disagrees with it, this document wins. It condenses the design handoff,
[`docs/design-spec/handoff.md`](docs/design-spec/handoff.md) (boards in
[`docs/design-spec/boards/`](docs/design-spec/boards/)), and records where Shepherd deliberately
departs from it. All values live in the `ShepherdDesign` target, and the code is cited by type
name so you can check it.

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
| IBM Plex Sans and JetBrains Mono | System faces, SF Pro and SF Mono, at the handoff's sizes, weights, and line heights | No bundled fonts; the system faces render better at small sizes on macOS |
| Mock palette from `tokens.json` | The same *roles*, filled by Basalt (light and dark) | Basalt is the product's palette; the roles are the contract |
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

All design values live in `Sources/ShepherdDesign`. It is SwiftUI only and holds no app state.
Views read colors from `Tokens`, fonts from `Fonts`, and sizes from `Metrics` and `Radius`.
**Never hardcode a color, font size, or dimension in a view.**

A theme is pure data (`ThemeDefinition`: hex strings, `Codable`), so built-in themes and future
user themes go through the same model:

```text
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors:   ThemeColors     // the UI roles below
                  syntax:   SyntaxColors    // code blocks and diffs
                  terminal: TerminalColors  // Ghostty: background, foreground, cursor, selection, 16-color ANSI
                  pi:       PiColors }      // pi's TUI theme schema, for pi run by hand in a terminal pane
```

- **`ThemeStore.shared`** holds the selected theme, text scale, and density.
- **Colors are dynamic:** every `Tokens` color resolves against the appearance of the view
  drawing it, so light and dark are never stored and never need a re-render.
- **`ThemeManager`** (app) owns only the appearance mode: System, Light, or Dark, set in
  Settings ▸ Appearance or the Appearance menu. `SHEPHERD_THEME=basalt-dark|basalt-light` forces
  one at launch.
- **What `ThemeManager` pushes:** the resolved variant goes to what cannot follow appearance on
  its own. That is Ghostty surfaces (a live `setTheme`, never a remount or replay) and the pi
  theme file plus the `shepherd-active-theme` variant marker, which pi and editors run in a
  terminal pane watch.

### Roles (`ThemeColors`)

| Group | Role | Use |
| --- | --- | --- |
| Background | `bgCanvas` | Window and sidebar |
| | `bgSurface` | Thread, tool groups, settings cards, terminal panes |
| | `bgRaised` | Composer, popovers, menus, the palette |
| | `bgMuted` | Expanded tool output, sticky file headers, ledger header |
| | `bgBubble` | User turns |
| | `bgSelected` | Active sidebar row, selected chip |
| | `bgHover` | Row hover on `bgSurface`; inline code; hunk headers |
| | `bgHoverStrong` | Row hover on `bgCanvas` (sidebar) |
| | `bgTrack` | Segmented control and slider track |
| Border | `borderSubtle` | Between rows inside a group |
| | `border` | Panels, groups, the header rule, pane dividers |
| | `borderStrong` | Buttons, fields, the composer, menus |
| Text | `text` | Prose, paths, labels |
| | `textSecondary` | Tool output, inactive segments |
| | `textTertiary` | Tool names, section headings, thinking |
| | `textMuted` | Timestamps, counts, hints. The lightest text allowed on `bgSurface`/`bgCanvas` |
| | `textDisabled` | Separators and disabled controls only |
| Semantic | `accent` / `accentText` / `accentBg` | Current agent, running, links, focus |
| | `success` / `successText` / `successBg` | Done, passed, alive, additions |
| | `warning` / `warningText` / `warningBg` | Needs you, questions, warnings |
| | `danger` / `dangerText` / `dangerBg` | Failed, exit ≠ 0, unreachable, removals, Stop |
| Status | `dotIdle` | Status dot of an idle agent that is not the open thread |

**Pairing rule.** A semantic fill (`…Bg`) only ever carries its own `…Text`, and `…Text` only
sits on its `…Bg` or on `bgSurface`. The base semantic color is for dots, glyphs, spinners, bars,
and fills, never body text. Never put white text on a semantic color.

**Derived tokens** are computed in `Tokens`, not stored in the theme:

- `primaryFill` / `primaryLabel`: a primary button is the text color, labeled in the surface
  color.
- `focusRing`: accent at 18%, the 3pt ring around a focused field or selected card.
- `scrim`: behind the palette.
- `composerShadow`, `thumbShadow`, `menuShadow`.
- `syntax(_:)` and `statusDot(_:isCurrent:)`.

### Basalt

[Basalt Standard](https://github.com/bailycase/basalt-standard) (`Basalt.swift`) is the only
shipped theme. Its surfaces, accents, and terminal and pi palettes are Basalt's own values. Role
steps Basalt does not name (raised, bubble, the semantic `…Text`/`…Bg` pairs) are derived from
them to satisfy the contrast rules.

- **Dark:** near-black cool grey (`bgCanvas #0D0E10`, `bgSurface #111215`) with a muted slate
  accent (`#8892B5`).
- **Light:** warm paper (`bgCanvas #E7E4DE`, `bgSurface #F3F1ED`) with a deeper slate accent
  (`#526184`).

A terminal pane's background is the theme's `bgSurface`, so panes sit on the thread surface.

### Contrast rules

`ShepherdDesignUnitTests` checks every built-in variant:

- `text`, `textSecondary`, `textTertiary`, and `textMuted` reach 4.5:1 on `bgSurface`,
  `bgCanvas`, and `bgRaised`.
- `text` reaches 4.5:1 on `bgSelected`.
- Each `…Text` reaches 4.5:1 on its `…Bg` and on `bgSurface`.
- The four base semantic colors reach 3:1 on `bgSurface` and stay distinguishable from each
  other.
- Surfaces and border strengths stay ordered.
- Every color parses, the ANSI palette has 16 entries, the theme round-trips through JSON, and
  the terminal background equals `bgSurface`.

### Adding a theme or a role

- **A theme:** write a `ThemeDefinition` that fills every field of `ThemeColors`,
  `SyntaxColors`, `TerminalColors`, and `PiColors` for both variants. The memberwise initializers
  make the compiler enforce completeness. Add it to the list the design unit tests iterate and fix
  values until they pass. Then teach `ThemeManager` and the app's `ShepherdTheme` to resolve it
  for Ghostty and the pi theme file; today they resolve Basalt only. The variant marker's
  `<theme>-dark|light` spelling is an external contract.
- **A role:** add a field to `ThemeColors`, a value in every theme's light and dark variant, an
  accessor in `Tokens`, and a contrast rule if it carries text.

## Typography

System faces only: sans for prose and chrome, and monospace for anything the agent touched
(paths, commands, code, output, counts, times). Every size scales with Settings ▸ Appearance ▸
Text size (`ThemeStore.textScale`, 0.85–1.3). Line heights are applied as extra leading
(`Fonts.bodyLeading` and so on).

| Token | Spec | Use |
| --- | --- | --- |
| `display` | 22/600 | Settings page titles |
| `title` | 15/600 | Header thread title, sheet and dialog titles, the review header |
| `body` | 15, ×1.6 | Agent prose |
| `bodySmall` | 14, ×1.5 | User turns, the composer |
| `rowTitle` | 13.5/500 | Settings row titles |
| `label` (`labelRegular`, `labelStrong`) | 13/500 | Sidebar rows, breadcrumb, buttons |
| `description` | 12.5 | Settings row descriptions |
| `caption` (`captionMedium`) | 12 | Status pill, chips, captions |
| `section` | 11/600 caps | Section headings. Apply with `.sectionStyle()` (uppercase, tracked, tertiary) |
| `sectionSmall` | 10.5/600 caps | Palette group headers, settings group headings, hunk headers |
| `code` (`codeMedium`) | 12.5 mono | Paths, commands, code |
| `output` | 12 mono, ×1.55 | Tool output, diff lines |
| `micro` (`microMedium`) | 11 mono | Timestamps, counts, durations |

`Fonts.sans(_:_:)` and `Fonts.mono(_:_:)` exist for the few one-off sizes the boards call for:
empty-state titles (15/600), Markdown headings (17/600 at levels 1–2), and inline code
(13 mono). Prefer a named token. The terminal font (family and size) is its own setting in
Settings ▸ Terminal and never follows the chrome's text scale.

## Metrics, spacing, radii

`Metrics` holds every size. Settings ▸ Appearance ▸ Density (`ThemeStore.density`, 0.8–1.5)
scales the sidebar row and the settings row minimum; everything else is fixed.

- **Spacing** (2pt base): `space2` through `space32`.
  - Inside a row: 8–12. Between rows: 2. Between turns: 28.
  - Panel padding: 12–16.
  - Thread gutter: 32, or 16 when the window is too narrow for the column.
- **Window:** minimum 1040×640, default 1440×900. The main column is never narrower than 720.
- **Column widths:** thread 760, prose 680, user bubble 600, header 52 with 20 padding.
- **Sidebar:** width 190–340 (default 256), rows 26 × density, indent 16, padding 8, dot 7.
- **Right pane:** default 600, minimum 480, at most half the window.
- **Radius** (`Radius`):

  | Name | Value | Use |
  | --- | --- | --- |
  | `xs` | 4 | Inline code, keycaps |
  | `sm` | 6 | Rows |
  | `button` | 7 | Small and medium buttons |
  | `md` | 8 | Large buttons, inline cards |
  | `lg` | 10 | Tool groups, settings cards |
  | `xl` | 12 | Composer, menus, bubbles |
  | `xxl` | 14 | Palette |
  | `bubbleTail` | 4 | |
  | `pill` | | |

- **Icons:** SF Symbols at 12, 14, or 16pt, regular or medium weight. Never filled glyphs for
  status, never emoji.

## Components

`Sources/ShepherdDesign/Components` is the shared library. Use a component before composing
chrome by hand; if a board shows a variant the library lacks, add it there. Debug builds have a
**Component Gallery** (View menu), which shows the shared components in their states in the
current appearance.

| Component | Use |
| --- | --- |
| `ShepherdButtonStyle` (primary, secondary, ghost, destructive; small 28, medium 30, large 32) | Every text button. One primary per surface. Destructive is danger text on a bordered button, never the ⏎ default. |
| `IconButtonStyle` | Icon-only buttons, bordered or ghost. Always with an accessibility label. |
| `ComposerActionButton` | The composer's single 32pt action: Send (arrow on the primary fill) or Stop (square on danger). |
| `LinkButtonStyle` | Inline accent-text actions ("Show all", "review ›", "Reset"). |
| `SegmentedControl` (regular 26, small 22) | 2–4 exclusive options. |
| `ShepherdSwitchStyle` (`.shepherdSwitch`) | The 38×22 accent switch for booleans. |
| `PopupMenu` / `PopupButtonLabel` | Longer option lists (raised, strong border, up/down chevrons). |
| `ShepherdStepper`, `ValueSlider` | Integer steppers; sliders with a mono value (double-click resets). |
| `SearchField`, `.shepherdField(focused:mono:)` | Text entry: raised fill and strong border, with an accent border and ring while focused. |
| `Keycaps` | A real, wired shortcut ("⇧⌘N" as caps). Never for an unwired chord. |
| `StatusPill` (`AgentPillState`: idle, running, needsYou, error, stopped) | The header's agent state: a dot or spinner, plus a word, on the state's tint. |
| `StatusDot` (7pt) | Sidebar agent state. |
| `Spinner` | Running. A pulsing dot under Reduce Motion. |
| `RunStateGlyph` (`RunState`: queued, running, done, failed, needsYou) | Tool-call and run state at 14pt: hollow circle, spinner, check, cross, warning mark. |
| `BranchGlyph` | A subagent, in its run's state color. |
| `DiffStat` | "+58 −41" in success/danger micro mono (with a true minus sign). |
| `RunCells`, `ProgressBar` | 8pt per-run state cells, and the 4pt progress bar on running subagent cards. |
| `ComposerChipStyle`, `ChipChevron` | 32pt ghost chips in the composer's action row. |
| `AttachmentChip` | An image queued with the next message, removable. |
| `Tag` | A small bordered tag (a file status letter, a command source). |
| `InlineCode` | Code in prose: mono on `bgHover`. |
| `SectionHeader` | A caps heading with an optional trailing count or accessory (`small:` for 10.5pt). |
| `GroupCard`, `CardRow` | Grouped cards (settings, tool groups) and the settings row (title, description, inline problem, trailing control). |
| `InlineError` | A `dangerBg` banner with `dangerText` and an optional action (Reconnect). |
| `EmptyState` | A title (optionally with a mono part) and one line of guidance, optionally in a dashed frame. |
| `.menuSurface(radius:)` | Floating surfaces: raised fill, strong border, menu shadow. |
| `.rowBackground(selected:hovering:)`, `RowButtonStyle` | Hover and selection fills for list rows. |

App-level building blocks sit on top of these:

- `SettingsPage`, `SettingsGroup`, `SettingsRow`, `SettingsSwitch`, `PathRow`
  (`SettingsComponents.swift`)
- `DialogSheet`, `SheetRow`, `DialogAction`, `DialogWarning`, `RenameDialog` (`DialogSheet.swift`)
- `CodeBlockView` for fenced code

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
| **Appearance** | Theme (Basalt), mode (System/Light/Dark), density, text size, sidebar width |
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
- **White on a semantic color:** the review's comment `+` and comment avatar are white on
  `accent`.
- **Component Gallery coverage:** it does not yet show `ValueSlider` or `ShepherdStepper`.

## iOS

The iOS client (`App/iOS`, [docs/ios](docs/ios/README.md)) is deferred. It predates this system
and keeps its own `MobileTokens`. It will adopt `ShepherdDesign` and the handoff's §8 rules later:
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
