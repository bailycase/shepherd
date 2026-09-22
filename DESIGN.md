# Shepherd Design Language

Shepherd is a native macOS app for supervising many `pi` coding agents. This document is the
authority on how the app looks and behaves. Where anything disagrees with it, this document
wins. It condenses the design handoff in [`docs/design-spec/handoff.md`](docs/design-spec/handoff.md)
(boards in [`docs/design-spec/boards/`](docs/design-spec/boards/)) and records where Shepherd
deliberately departs from it.

## Mental model: agents, not chats

Shepherd organizes around **agents**: live workers. An agent is a `pi --mode rpc` process with a
title, a workplace (a space's checkout), and a lifecycle (`working → blocked → done / idle`).
Shepherd is pi's only UI: every agent renders as a native SwiftUI **thread** (transcript,
composer, questions, subagents). The UI's job is supervision — which of my workers needs me
right now, and what did it just do? The sidebar leads with status, and selecting an agent opens
its thread. Every UI decision should survive the question "does this help a person supervise
ten working agents at once?"

Agents name themselves — a short task title (`Fix plan mode`), never a persona name, never a
sentence. A hand-typed rename is final. A remote host is a section in the same sidebar with the
same rows and the same thread.

Terminals exist only as panes beside a thread: ones the user opens with ⌘D or an agent opens
with its `shepherd-panes` tools. They are real PTYs rendered by libghostty. There are no global
shells and no space shell workspaces; no agent renders as a terminal, and there is no
Terminal/Native switch.

## Principles

In priority order (handoff §1):

1. **Readable measure.** A 760pt thread column, agent prose capped at 680pt (~85 characters).
2. **Shape, not labels.** No speaker labels anywhere. A user turn is a trailing bubble; agent
   output is unboxed prose.
3. **One line per tool call.** Tool activity is scannable at a glance; detail is one click away,
   raw arguments are two.
4. **Nothing in the default view that isn't useful.** No key-hint rows, no status text that
   repeats the header pill, no working directory under the composer, no footers in menus.

And the rules that follow from them:

- **Flat surfaces separated by borders.** Three background layers (canvas, surface, raised) and
  three border strengths do the work. Exactly two shadows exist — the composer's and the
  segmented-control thumb's — plus one larger shadow shared by floating menus and the palette.
  No vibrancy, no translucency, no gradients except the composer's fade.
- **Honest affordances.** Never show a control that does nothing, a shortcut that isn't wired,
  or sample data in place of real data. Unsupported capabilities are hidden or explained.
- **No permission model.** Shepherd never invents approval UI. When pi or an extension asks a
  question, it is shown as a question with the answers the asker offered.
- **Status is a dot (or glyph) plus a word.** Color is never the only signal for an actionable
  state.
- **The sidebar tree is the primary navigation.** The command palette is a secondary jump
  surface; it never becomes the only way to reach something.

## Where Shepherd departs from the handoff

| Handoff | Shepherd | Why |
| --- | --- | --- |
| IBM Plex Sans / JetBrains Mono | System faces: SF Pro (`.default`) and SF Mono (`.monospaced`) at the spec's sizes, weights, and line heights | No bundled fonts; the system faces render better at small sizes on macOS |
| Mock palette from `tokens.json` | The same *roles*, filled by Basalt (light and dark) | Basalt is the product's palette; the roles are the contract |
| Sidebar rows 32pt, indent 22pt; compact 26pt, indent 16pt | Rows **26pt**, indent 16pt (density-scaled); no compact form | A real fleet lost a third of the tree at 32pt |
| Sidebar fixed 256pt; 184pt compact form while a right pane is open | Resizable (190–340pt, persisted) as on the Appearance board, and it keeps its width when a right pane opens | Shrinking the sidebar on every pane toggle made the whole window jump |
| ⌘M opens the model picker | **⇧⌘M** | ⌘M is the system Minimize chord |
| Runtime (Terminal vs Native RPC) as a creation-time choice | Gone: every agent is RPC | Terminal agents were removed |
| "Width persists per window" | The right-pane width persists app-wide | One main window |
| iOS in the same pass | macOS first; iOS adopts the system later | Scope |

The composer also carries a **delivery chip** (Follow-up / Steer) while a turn runs with a draft
in the field; the handoff has no equivalent, and pi supports both deliveries.

## Theme model

All design values live in the `ShepherdDesign` SwiftPM target (SwiftUI only, no app state).
Views read colors from `Tokens`, fonts from `Fonts`, sizes from `Metrics` and `Radius`. **Never
hardcode a color, font size, or dimension in a view.**

A theme is pure data (`ThemeDefinition`, hex strings, `Codable`) so built-in themes and future
user themes go through the same model:

```
ThemeDefinition { id, name, light: ThemeVariant, dark: ThemeVariant }
ThemeVariant    { colors: ThemeColors,     // the UI roles below
                  syntax: SyntaxColors,    // code blocks and diffs
                  terminal: TerminalColors,// Ghostty: bg, fg, cursor, selection, 16-color ANSI palette
                  pi: PiColors }           // pi's full TUI theme schema, for pi run by hand in a shell
```

`ThemeStore.shared` holds the selected theme plus the user's text scale and density. Every
`Tokens` color is dynamic — it resolves against the appearance of the view drawing it — so
light/dark is never stored and never needs a re-render. The app-side `ThemeManager` owns only
the appearance mode (System / Light / Dark, Settings ▸ Appearance; `SHEPHERD_THEME=basalt-dark|basalt-light`
forces one at launch) and pushes the resolved variant to what cannot follow appearance on its
own: Ghostty surfaces (a live `setTheme`, never a remount or replay) and the pi theme file plus
the `shepherd-active-theme` variant marker that shell-launched pi and Neovim watch.

### Roles (`ThemeColors`)

| Group | Role | Use |
| --- | --- | --- |
| Background | `bgCanvas` | Window and sidebar |
| | `bgSurface` | Thread area, tool groups, settings cards, terminal panes |
| | `bgRaised` | Composer, popovers, menus, the palette |
| | `bgMuted` | Expanded tool output, sticky file headers, ledger header |
| | `bgBubble` | User turns |
| | `bgSelected` | Active sidebar row, selected chip |
| | `bgHover` | Row hover on `bgSurface`; inline code |
| | `bgHoverStrong` | Row hover on `bgCanvas` (sidebar) |
| | `bgTrack` | Segmented control and slider track |
| Border | `borderSubtle` | Between rows inside a group |
| | `border` | Panels, groups, the header rule, pane dividers |
| | `borderStrong` | Buttons, fields, the composer, menus |
| Text | `text` | Prose, paths, labels |
| | `textSecondary` | Tool output, inactive segments |
| | `textTertiary` | Tool names, section headings, thinking |
| | `textMuted` | Timestamps, counts, hints — the lightest text allowed on `bgSurface`/`bgCanvas` |
| | `textDisabled` | Separators and disabled controls only |
| Semantic | `accent` / `accentText` / `accentBg` | Current agent, running, links, focus |
| | `success` / `successText` / `successBg` | Done, passed, alive, additions |
| | `warning` / `warningText` / `warningBg` | Needs you, questions, warnings |
| | `danger` / `dangerText` / `dangerBg` | Failed, exit ≠ 0, unreachable, removals, Stop |
| Status | `dotIdle` | Status dot of an idle agent that is not the open thread |

**Pairing rule.** A semantic fill (`…Bg`) only ever carries its own `…Text`; `…Text` only sits
on its `…Bg` or on `bgSurface`. The base semantic color is for dots, glyphs, spinners, bars,
and fills — never body text. Never put white text on a semantic color.

**Derived tokens** (in `Tokens`, not theme fields): `primaryFill`/`primaryLabel` (primary
buttons are the text color with the surface as their label), `focusRing` (accent at 18%, the
3pt ring around a focused field or selected card), `scrim` (behind the palette),
`composerShadow`, `thumbShadow`, `menuShadow`, `syntax(_:)`, and `statusDot(_:isCurrent:)`.

### Basalt

[Basalt Standard](https://github.com/bailycase/basalt-standard) (`Basalt.swift`) is the only
shipped theme. Surfaces, accents, and the terminal/pi palettes are Basalt's own values; the
role steps Basalt does not name (raised, bubble, the semantic `.text`/`.bg` pairs) are derived
from them to satisfy the contrast rules. Dark is near-black cool grey (`bgCanvas #0D0E10`,
`bgSurface #111215`) with a muted slate accent; light is warm paper (`bgCanvas #E7E4DE`,
`bgSurface #F3F1ED`) with a deeper slate accent. A terminal pane's background is the theme's
`bgSurface`, so terminal panes sit on the thread surface.

### Contrast rules (enforced by `Tests/ShepherdDesignTests`)

For every built-in variant: `text`, `textSecondary`, `textTertiary`, and `textMuted` reach
4.5:1 on `bgSurface`, `bgCanvas`, and `bgRaised`; `text` reaches 4.5:1 on `bgSelected`
(`textMuted` 4:1); each `…Text` reaches 4.5:1 on its `…Bg` and on `bgSurface`; the four base
semantic colors reach 3:1 on `bgSurface` and stay distinguishable from each other; surfaces and
border strengths stay ordered. Every color parses, the ANSI palette has 16 entries, the theme
round-trips through JSON, and the terminal background equals `bgSurface`.

### Adding a theme

1. Write a `ThemeDefinition` (a static like `.basalt`, or JSON once user themes land) filling
   every field of `ThemeColors`, `SyntaxColors`, `TerminalColors`, and `PiColors` for both
   variants — the memberwise initializers make the compiler enforce completeness.
2. Add it to `ThemeDefinitionTests.builtIns` so the parse, round-trip, and contrast suites run
   against it; fix values until they pass.
3. Select it with `ThemeStore.shared.select(_:)` and teach the app's `ShepherdTheme`/
   `ThemeManager` to resolve it for Ghostty and the pi theme file (today they resolve Basalt
   only). The variant marker's `<theme>-dark|light` spelling is an external contract.

Adding a *role* means a field on `ThemeColors`, a value in every theme's light and dark
variant, an accessor in `Tokens`, and a contrast rule if it carries text.

## Typography

System faces only: sans for prose and chrome, monospaced for anything the agent touched
(paths, commands, code, output, counts and times). Every size scales with Settings ▸ Appearance
▸ Text size (`ThemeStore.textScale`). Line heights are applied as extra leading
(`Fonts.bodyLeading` etc.).

| Token | Spec | Use |
| --- | --- | --- |
| `display` | 22/600 | Settings page titles, sheet titles, empty states |
| `title` | 15/600 | Header thread title |
| `body` | 15 ×1.6 | Agent prose |
| `bodySmall` | 14 ×1.5 | User turns, the composer |
| `rowTitle` | 13.5/500 | Settings row titles |
| `label` (`labelRegular`, `labelStrong`) | 13/500 | Sidebar rows, breadcrumb, buttons |
| `description` | 12.5 | Settings row descriptions |
| `caption` (`captionMedium`) | 12 | Status pill, chips, captions |
| `section` | 11/600 caps | Section headings — apply with `.sectionStyle()` (uppercase, tracked, tertiary) |
| `sectionSmall` | 10.5/600 caps | Palette group headers, hunk headers |
| `code` (`codeMedium`) | 12.5 mono | Paths, commands, code |
| `output` | 12 mono ×1.55 | Tool output, diff lines |
| `micro` (`microMedium`) | 11 mono | Timestamps, counts, durations |

`Fonts.sans(_:_:)` and `Fonts.mono(_:_:)` exist for the few one-off sizes the boards call for;
prefer a named token. The terminal font (family and size) is its own setting under Settings ▸
Terminal and never follows the chrome's text scale.

## Metrics, spacing, radii

`Metrics` holds every size from the handoff; row heights scale with Settings ▸ Appearance ▸
Density (`ThemeStore.density`, 0.8–1.5), everything else is fixed.

- **Spacing** (2pt base): `space2 … space32`. Inside a row 8–12, between rows 2, between turns
  28, panel padding 12–16, thread gutter 32 (16 when the window is too narrow for the column).
- **Window:** minimum 1040×640, default 1440×900; the main column never narrower than 720.
- **Radius:** `xs` 4 (inline code, keycaps) · `sm` 6 (rows) · `button` 7 (small/medium
  buttons) · `md` 8 (large buttons, inline cards) · `lg` 10 (tool groups, settings cards) ·
  `xl` 12 (composer, menus, bubbles) · `xxl` 14 (palette) · `bubbleTail` 4 · `pill`.
- **Icons:** SF Symbols at 12/14/16pt, regular or medium weight. Never filled glyphs for status;
  never emoji.

## Components

`Sources/ShepherdDesign/Components` is the shared library. Use a component before composing
chrome by hand; if a board shows a variant the library lacks, add it there. The Debug menu's
**Component Gallery** (`ComponentGallery.swift`) shows every component in every state;
`ComponentGalleryTests` renders it in both appearances.

| Component | Use |
| --- | --- |
| `ShepherdButtonStyle` (primary · secondary · ghost · destructive; small 28 / medium 30 / large 32) | Every text button. One primary per surface. Destructive is danger text on a bordered button — never the ⏎ default. |
| `IconButtonStyle` | Icon-only buttons (bordered 28/30, or ghost 28 for footers). Always with an accessibility label. |
| `ComposerActionButton` | The composer's single 32pt action: Send (arrow on the primary fill) or Stop (square on danger). |
| `LinkButtonStyle` | Inline accent-text actions ("Show all", "review ›", "Reset"). |
| `SegmentedControl` (regular 26 / small 22) | 2–4 exclusive options. |
| `ShepherdSwitchStyle` (`.shepherdSwitch`) | The 38×22 accent switch for booleans. |
| `PopupMenu` / `PopupButtonLabel` | Longer option lists (raised, strong border, up/down chevrons). |
| `SearchField`, `.shepherdField(focused:mono:)` | Text entry: raised fill, strong border, accent border + ring while focused. |
| `Keycaps` | A real, wired shortcut ("⇧⌘N" → caps). Never for an unwired chord. |
| `StatusPill` (`AgentPillState`: idle · running · needsYou · error · stopped) | The header's agent state; dot or spinner + word on the state's tint. |
| `StatusDot` (7pt) | Sidebar agent state. |
| `Spinner` | Running. A pulsing dot under Reduce Motion. |
| `RunStateGlyph` | Tool-call and run state at 14pt: spinner, check, cross, warning. |
| `BranchGlyph` | A subagent, in its run's state color. |
| `DiffStat` | "+58 −41" in success/danger micro mono (a true minus sign). |
| `RunCells`, `ProgressBar` | 8pt per-run state cells; the 4pt progress bar on running subagent cards. |
| `ComposerChipStyle`, `ChipChevron` | 32pt ghost chips in the composer's action row. |
| `AttachmentChip` | An image or file queued with the next message, removable. |
| `Tag` | Small bordered tag ("prompt", a file status letter). |
| `InlineCode` | Code in prose: code face on `bgHover`. |
| `SectionHeader` | 11/600 caps heading with an optional trailing count or accessory. |
| `GroupCard`, `CardRow` | Grouped cards (settings, tool groups) and the settings row (title, description, inline problem, trailing control). |
| `InlineError` | `dangerBg` banner with `dangerText` and an optional action (Reconnect). |
| `EmptyState` | A title (optionally with a mono part) and one line of guidance, optionally in a dashed frame. |
| `.menuSurface(radius:)` | Floating surfaces: raised fill, strong border, menu shadow. |
| `.rowBackground(selected:hovering:)`, `RowButtonStyle` | Hover and selection fills for list rows. |

## Window structure

```
┌────────────────┬───────────────────────────────────────────┬──────────────────────┐
│ traffic lights │ header 52: project / title · pill · · n turns · 42k ctx · ▯ ⋯ │
│                ├───────────────────────────────────────────┼──────────────────────┤
│ THIS MAC    19 │        760pt thread column                │ right pane (optional)│
│ › Space      8 │               ┌───────────────┐           │ review or subagent   │
│   ● agent      │               │  user bubble  │           │ inspector, 600pt     │
│   ● agent      │   agent prose (680pt measure) │           │ (min 480, ≤50%)      │
│     ↳ subagent │   ┌ tool group ─────────────┐ │           │                      │
│ HOST  Unreach. │   └─────────────────────────┘ │           │                      │
│────────────────│   ┌ composer card ──────────┐ │           │                      │
│ AUTOMATIONS  1 │   └─────────────────────────┘ │           │                      │
└────────────────┴───────────────────────────────────────────┴──────────────────────┘
```

One window. The sidebar sits on `bgCanvas` (running behind the traffic lights), the main column
on `bgSurface`. There is no tab bar and no status line. An agent's layout is its thread plus any
terminal panes split beside it; panes are separated by 1pt `border` dividers.

## Surfaces

### Sidebar

- 8pt padding. Sections: **THIS MAC** (agent count, hover `+` for New Space), then one section
  per remote host (count, "n need you", or "Unreachable" in `dangerText`), then — behind a 1pt
  `border` — **AUTOMATIONS** (hidden while empty). Section headers are
  `.sectionStyle()` with a trailing count; clicking toggles the section.
- Spaces are disclosure rows (chevron, name, agent count): clicking one expands or collapses
  it, and a space has no view of its own. Nested projects indent by path containment. Agents
  nest beneath their space. With no agent selected the workspace shows an empty state with
  New agent.
- **Rows:** 26pt, radius 6, 16pt indent per level.
  Hover `bgHoverStrong`; selected `bgSelected`. A 7pt status dot leads, `⎇` marks
  a worktree agent, the title truncates at the tail with the full title as a tooltip.
- **Trailing slot**, in priority order: the ⌘-digit badge while ⌘ is held · "needs you"
  (`warningText`) · "n sub" for a folded subagent group · elapsed time while working · "done".
- **Status dot:** working `success` (green, "alive") · blocked `warning` · idle/done `dotIdle`,
  or `accent` for the open thread.
- **Subagents** nest under their parent with the `BranchGlyph` in the state color instead of a
  dot; trailing elapsed / "needs you" / duration. While any run is live the group is expanded.
  Once every run has finished the group gets a disclosure header, expanded for the selected
  thread and folded for others. Selecting a subagent row opens it in the inspector.
- The sidebar keeps its width while a right pane is open.
- Hidden with ⇧⌘S; the header then runs under the traffic lights. Rows are tap views with button
  traits and accessibility actions (so they can also be dragged to reorder); hover `+` glyphs are
  real labeled buttons. A disconnected host's rows dim; connection state lives on the section
  header, never in a banner.

### Header

52pt on `bgSurface` with a 1pt `border` rule beneath, 20pt padding: `project / title` (label in
tertiary, title in `title`, truncating) · `StatusPill` · spacer · "18 turns · 46k ctx"
(`micro`, `textMuted`; the turn count appears once the whole history is loaded, the context
tooltip carries details) · the right-pane toggle (accent-tinted while open) · the options menu
(Refresh, Load Older, Rename…). With no thread on screen the strip shows the breadcrumb only. There is no Terminal/Native switch and no other window title.

### Thread and turns

- A scroll view with the 760pt column centered, 28pt top padding, 28pt between turns and
  nothing else between them.
- **User turn:** trailing bubble on `bgBubble`, max 600pt, 12×16 padding, radius 12 with a 4pt
  bottom-trailing corner, `bodySmall`; its time beneath in `micro`/`textMuted`.
- **Agent turn:** consecutive assistant messages render as one turn. Prose (`body`, ≤680pt)
  renders Markdown — headings 15/600, lists with one nested level, quotes on a 2pt rule, inline
  code on `bgHover`, fenced code in a `CodeBlockView` (28pt `bgMuted` header with language and
  Copy, syntax-colored code). Blocks are 10pt apart.
- **Thinking** precedes the first prose: a collapsed italic "Thought for Ns"; "Thinking…" with a
  spinner while streaming; expanded, tertiary italic prose on a 2pt `border` rule.
- **Turn footer** after a finished turn: copy and retry (28pt ghost icon buttons) and "time ·
  duration · N tool calls · n subagents" (the subagent count links to the run). Hidden while
  the turn runs.
- **Working row:** while the agent runs the thread ends in one row (spinner + current activity in
  tertiary italic).
- **Following:** the thread follows the tail only while the reader is within 80pt of the bottom;
  a live scroll gesture detaches it and "↓ Jump to latest" returns. Sending re-attaches.
  Streaming text appends in place and never re-lays out earlier blocks. The composer is the
  scroll view's bottom inset, so the thread always ends at its last turn.
- **Empty thread:** an `EmptyState` naming the agent and its folder.

### Tool rows

Consecutive tool calls form one `ToolGroup` (border `border`, radius 10, `bgSurface`, rows
divided by `borderSubtle`); prose between calls splits the group. Each call is one 36pt row:
status glyph (14pt) · tool name (code, tertiary, ≥40pt column) · preview (code, tail-truncated:
path with `:start–end` for read/write, path for edit, first command line for bash, quoted
pattern + scope for grep, else the first output line up to 120 chars) · result (edit: DiffStat +
"k blocks"; read: "n lines"; bash: `BUILD SUCCEEDED`/"n passed" in `successText` or "exit n" in
`dangerText`; grep: "n matches") · duration (`micro`, live while running) · chevron when the row
has output. Expanded rows take `bgMuted` (`dangerBg` when failed) and show 12 lines of output —
a running call streams its tail, a finished one its head — then "… n more lines", which opens the
full output in a sheet. Edit/write rows add a trailing "review ›" link into the review pane. Raw
arguments stay behind ⌥-click → "Show call". Hover `bgHover`.

### Composer, questions, and menus

- Pinned to the bottom of the main column in the same 760pt column, with a fade from
  transparent to `bgSurface` above it. The card is `bgRaised`, `borderStrong`, radius 12, the
  composer shadow; while focused, a menu is open, or a drop hovers, the border turns `accent`
  with the 3pt `focusRing`.
- Field on top (`bodySmall`, grows to 8 rows then scrolls); one action row beneath: attach
  (when the agent accepts images) · "/ commands" (when pi reports commands) · model chip ·
  thinking chip · delivery chip (Follow-up / Steer, only while a turn runs with a draft) ·
  spacer · the single `ComposerActionButton`.
- **States:** idle — Send, placeholder "Follow up, or / for commands…" ("Describe the task…" on
  a fresh agent); running — Stop (`danger`) while the field is empty, and the field stays
  editable with "Queue a follow-up — sent when the turn ends"; accepting — a spinner in the
  button's place; error — Send plus an `InlineError` with Reconnect above the card. With more
  than one live subagent, Stop asks once whether to stop everything. No status text, key hints,
  or working directory in or under the composer.
- **Images** attach by drop, paste, or the paperclip; they are resized on the way in (longest
  edge 2000px) and shown as `AttachmentChip`s.
- **Questions** from pi or an extension (select, confirm, input, editor) replace the field
  inside the card — never in the scrolling thread — so a blocked agent is always answerable:
  title, message, then the asker's options (the first as primary), Yes/No, or a field with
  Submit, plus Dismiss; "1 / N" when several are queued.
- **Extension widgets** (an extension's `setWidget` text, ANSI stripped; machine payloads,
  `setStatus` footer text, and `notify` toasts are not shown) appear as small titled text rows
  above the card. Display-only; the app chooses every font and color.
- **Menus** open above the card, left-aligned, 8pt gap, via `.menuSurface()`; only one at a
  time. **SlashMenu** opens on "/" at line start (or the chip): header "Commands · n of m", 36pt
  rows (command in mono with the typed prefix bold, description, source tag, ⏎ on the
  highlighted row), highlight `accentBg`, max 8 rows; ↑↓ select, ⏎ runs, ⇥ completes with a
  space, esc closes. The list is pi's command registry, never hard-coded. **ModelPicker**
  (model chip or ⇧⌘M): 380pt, search on top, Recent then one group per provider, 40pt rows
  (check · id in mono + note · context size); model only. The **thinking chip** (bulb ·
  "Thinking" · Off/Low/Medium/High) is a small menu independent of the model, hidden when the
  model has no reasoning control. Esc returns focus to the field.

### Subagents

A subagent is a turn inside a turn: its spawn call renders as a card where the call was; raw
wait/status dumps never appear.

- **SubagentCard:** 40pt header (branch glyph · name `labelStrong` · "mode · model · thinking"
  in `micro`/tertiary · trailing Running + elapsed / Needs you / Done + duration / Failed).
  Running body: step n/m, the 4pt `ProgressBar` when steps are reported, "turns · tools ·
  tokens", and **one** live activity line in tool-row form — the card never grows while
  running. Needs-you: header on `warningBg`, the question as prose, its choices as buttons
  (recommended = primary), Reply… for free text. Done: summary, stats, Open transcript; folds
  to its header while siblings still run. Failed: one row on `dangerBg` with Retry and
  Transcript. Actions: Inspect (⌘I), Steer…, Pause/Continue, Stop (`dangerText`, trailing). The
  inspected card gets the accent border and ring.
- **RunsStrip:** more than three sibling runs fold into one row — count, one 8pt cell per run,
  "7 done · 3 running · 1 needs you · 1 failed", totals. Needs-you runs keep their own card.
- **RunLedger:** once every run in the group has finished, the cards are replaced in place by
  a permanent ledger — a 36pt `bgMuted` header (glyph, "n subagents", state cells, "all done ·
  wall · tokens", combined DiffStat and files) and one 44pt row per run in spawn order (glyph ·
  name in a 72pt column · one-line summary · "files · tools · duration" · chevron). Rows open
  the read-only inspector; the open one is `accentBg` with a 3pt accent rule on the pane side.

### Right pane: subagent inspector and review

One docked slot to the right of the thread (`RightPaneSplit`), shared by the subagent
inspector and the review. Default 600pt, min 480pt, at most half the window; the left edge is
the drag handle and the width persists. The sidebar keeps its width.
⇧⌘B or the header button toggles it (closing whatever is open, otherwise opening the review).
The thread keeps running beside it; a pane never replaces or splits the thread's layout.

- **Subagent inspector:** header with name, "mode · model · turns · tools · tokens", Pause/Stop;
  a Goal strip; the run's own transcript in the thread's components one step smaller (34pt tool
  rows, 14pt prose), following live with "n earlier turns · Show all"; a Steer composer whose
  placeholder and "to: worker · not the parent" line name the recipient. A finished run is
  read-only: "k of n" with ‹ › to step siblings, a Result block (summary + touched files as
  links into the review), parent messages captioned "from parent", and Re-run · Fork as new
  agent · Copy transcript · "kept with the thread" instead of the composer.
- **Review** (`ReviewPane`): 52pt header "Review" with "working tree vs HEAD · 4 files · +67
  −58" and a Local | PR #n segmented control; a 34pt file strip on `bgCanvas` (chips: status
  letter M `warning` / A `success` / D `danger` / R `accent`, filename, DiffStat; a pulsing
  accent dot while the running agent touches the file); sticky 36pt file headers on `bgMuted`
  (chevron, path with the filename bold, hunk count, Open in Xcode · Revert (`dangerText`,
  confirmed) · Viewed); 21pt diff lines in 12 mono (old/new number columns, sign column,
  syntax-colored code; removals on `dangerBg`, additions on `successBg`, hunk headers on
  `bgHover`), tail-truncated with the full line on hover, never wrapped; runs of more than 8
  like lines fold to a 24pt strip. Hovering a line shows an accent `+` for an inline comment
  card. The review composer at the bottom sends overall + inline comments as the next user turn
  (queued if the agent is mid-turn) or asks the agent to commit. Keys: j/k hunks, n/p files, c
  comment, v viewed, ⌘⏎ send, esc back to the thread composer. Per-file Revert is the only
  repository mutation outside the worktree flows.

### Terminal panes

Terminal panes render through libghostty on `bgSurface` (the theme's terminal colors). An
agent's layout may hold terminal panes beside its thread; the thread pane itself has no terminal.
Pane dividers are 1pt `border`. A pane whose process died shows a quiet placeholder. The
chrome never parses or restyles terminal output.

### Command palette

⌘K. A 640pt card, 120pt from the top of the window over the `scrim`; radius 14, `bgRaised`,
the menu shadow. A 56pt search row (16pt text, search glyph) with scope pills All · Commands ·
Agents. Results are grouped under 10.5pt caps headers — Commands, This thread, Subagents (and
Agents when searching; transcript matches search each agent's recent pi session). Rows are
38pt: a 15pt stroke icon · label (14pt sans) · optional context in `textMuted` · the real
shortcut as `Keycaps`. Highlight `accentBg` with an accent icon; subagent rows use the branch
glyph in their state color. No footer hints and no ⌘1–9 numbering — only real shortcuts. The
palette never shows status the sidebar doesn't.

### Settings

Settings replaces the window content (⌘,; "Back to Shepherd" returns). A 232pt nav on
`bgCanvas`: Back to Shepherd, a search field (⌘F), then Appearance · Terminal · Agents ·
Worktrees · Pi · Remote · Keyboard · Advanced with 15pt icons, and "Shepherd x.y.z · pi x.y.z"
pinned at the bottom in `micro`. The content column is 720pt with 44pt top padding: a page title
in `display` and a one-line explanation, then `.sectionStyle()` headings over `GroupCard`s of
`CardRow`s (min 52pt, title `rowTitle`, description `description`/tertiary, control trailing).
Controls: `SegmentedControl` for 2–4 options, the accent switch for booleans, `PopupMenu` for
longer lists, a stepper, a slider with a mono value, `Keycaps` for shortcuts (click to record;
"Reset" link when changed), secondary buttons (danger text when destructive). Footnotes under a
group are 12pt sans `textMuted`. Inline problems (e.g. the listener's bind error) sit in the row
in `dangerText` under the description rather than replacing it.

Pages: **Appearance** (mode System/Light/Dark; density, text size, sidebar width) ·
**Terminal** (terminal pane font and size, shell) · **Agents** (default model, default thinking level) ·
**Worktrees** (base, fetch, finalize defaults) · **Pi** (bundled extensions, native subagent
defaults, pi updates) · **Remote** (hosts, add host, serve this Mac + token) · **Keyboard**
(rebindable shortcuts) · **Advanced** (files, updates and channel, reset).

### Dialogs and sheets

Creation sheets (New Agent, New Worktree, Finalize Worktree, directory pickers) and
confirmations (`DialogSheet`) share one anatomy on `bgSurface`: a title in `display` or
`title`, optional labeled rows, and a footer of `ShepherdButtonStyle` buttons. Exactly one
primary action is the ⏎ default; a destructive action is never the default — destroying things
takes a click. Work a destructive action would destroy is called out in a `warningBg` strip
with `warningText`. No system alerts.

## Status language

| State | Sidebar | Header pill | Composer |
| --- | --- | --- | --- |
| idle / done | `dotIdle` dot (`accent` for the open thread); "done" trailing | Idle — `successBg`/`successText`, dot `success` | Send |
| working | `success` dot; elapsed trailing | Running · elapsed — `accentBg`/`accentText`, spinner | Stop; field queues a follow-up |
| blocked / subagent needs you | `warning` dot; "needs you" trailing | Needs you ("n subagents need you") — `warningBg`/`warningText` | Question panel in place of the field |
| error (connection lost) | — | Error — `dangerBg`/`dangerText` | Send + `InlineError` with Reconnect |
| stopped (component state; pi RPC does not yet report it) | `dotIdle` | Stopped — `bgBubble`/`textSecondary` | Send |

Subagent runs use the same colors on their branch glyph: running `accent`, needs you `warning`,
done `success`, failed `danger`.

## Keyboard

Keyboard is first-class and the fast path never requires a dialog. Rebindable chords live in
`KeybindingsStore` (defaults in `ShortcutAction.defaultChord`); menus, palette keycaps, and the
Ghostty unbind list all read it — hardcoding a chord in a view is a bug, and a hint is never
shown for a chord that isn't wired. Rebindable chords must include ⌘.

| Default | Action |
| --- | --- |
| ⌘N · ⇧⌘T · ⇧⌘N | New agent in current checkout · with options… · new space… |
| ⌘R · ⇧⌘W | Rename agent · delete agent |
| ⌘K | Command palette |
| ⌘↓ · ⌘↑ | Next · previous agent |
| ⌘D · ⇧⌘D · ⌘W | Split vertically · horizontally · close pane |
| ⌥⌘→ · ⌥⌘← | Focus next · previous pane |
| ⇧⌘S · ⇧⌘B | Toggle sidebar · toggle right pane |
| ⇧⌘M | Model picker |
| ⌘. | Stop the agent |
| ⌥⌘↑ · ⌥⌘↓ | Previous · next turn |
| ⌘I | Inspect subagent |

Fixed: ⌘1–9 select agents (hold ⌘ to see badges), ⌃⇧1–9 jump to machines (this Mac is always
⌃⇧1), ⌘, Settings. In the composer ⏎ sends and ⇧⏎ inserts a newline; `/` at line start opens
the command list; esc closes a menu. Review-pane and menu keys are listed with their surfaces.

## Accessibility and motion

- Every control is a real `Button`, `Toggle`, or text field (or carries button traits and
  actions); icon-only buttons carry an `accessibilityLabel`.
- Rows read as one element: agent rows "title, [worktree,] status word"; subagent rows "name,
  subagent, state"; automation rows "name, automation, state"; tool
  rows "read, ThreadView.swift, 160 lines, done" with "Show call" as a named action.
- Status color is always paired with a word or glyph shape.
- Contrast follows the theme rules above; do not go lighter than `textMuted` for any text.
- **Reduce Motion:** spinners become a pulsing dot, expand/collapse and scroll-to animations are
  dropped. Otherwise transitions are short (≤150ms) and ease-out.
- Every pane and agent action exists in the menu bar with its shortcut.

## iOS

The iOS client (`App/iOS`, docs in `docs/ios/`) is a remote-only companion that predates this
system and keeps its own `MobileTokens`. The redesign ships on macOS first; iOS will adopt
`ShepherdDesign` and the handoff's §8 rules (navigation instead of the sidebar, 56pt agent
rows, collapsed tool groups, the pill composer, ≥44pt touch targets) later.

## Verifying visuals

UI is verified by building and running, plus offscreen renders: `renderScreenshot` in
`Tests/ShepherdAppTests/ScreenshotSupport.swift` draws a view in a real off-screen window with an
explicit appearance and writes a PNG when `SHEPHERD_NATIVE_SCREENSHOT_DIR` is set (a no-op
otherwise, so the tests still exercise layout). Compare against the boards in both appearances.
