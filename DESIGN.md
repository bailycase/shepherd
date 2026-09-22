# Shepherd Design Language

Shepherd is a native macOS app for supervising many `pi` coding agents. This document is the
authority on how the app looks and behaves visually. Where anything disagrees with it, this
document wins.

## Mental model: agents, not threads

Chat products organize around threads — transcripts you open and read. Shepherd organizes
around **agents**: live workers. An agent is a running `pi` process with a title, a workplace
(a space's checkout), and a lifecycle (`working → blocked → done / idle`). The UI's job is
supervision: which of my workers needs me right now? The sidebar leads with status dots, the
waiting queue gets the app's only persistent attention affordances, and selecting an agent
drops you into its live terminal, not a summary. Every UI decision should survive the question
"does this help a person supervise ten working agents at once?"

Agents name themselves — a short task title (`Fix plan mode`), never a persona name, never a
sentence. A hand-typed rename is final. Machines are the same species: a remote host is a
machine root in the same tree, marked `⌁`, with the same rows, dots, and terminal treatment.

## Identity and principles

**The terminal is the product, and the chrome speaks its language.** Every piece of UI text is
monospace, lowercase (headings uppercase-tracked), set on flat near-black surfaces. The GUI is
navigation, state, and layout persistence around real terminal surfaces rendered by libghostty:

- Pi's output renders inside the terminal as Pi's own output — never lifted into GUI cards,
  banners, chat bubbles, or parsed widgets. When an agent asks for approval, keyboard focus
  moves *into the terminal*. Even the subagent inspector is a terminal program, not a GUI panel.
- Chrome is quiet and flat: no vibrancy materials, no gradients, no shadows in the workspace.
  The one saturated element is the **attention frame** — the 1px status-colored border around
  the focused agent's pane when it is blocked.
- Density over decoration: 1px hairlines, one framed pane region, small mono metadata. Motion
  is minimal (≤120ms transitions; the working-dot pulse is the one ambient animation and
  honors Reduce Motion).

**Hard constraints** (violating any of these in the main window's workspace is a design
regression): no three-column dashboard · no permanent inspector panel · no analytics cards ·
no progress bars or context meters · no wide labeled toolbar · no large accent-colored buttons
except the single sheet default button · no chat bubbles · no IDE-clone layouts · no
glass/rounded card stacks in the workspace · no vibrancy/translucency · no proportional type
anywhere in the chrome · no status text that merely repeats the sidebar.

**Overlay exceptions.** Three surfaces may have rounded corners because they float above the
chrome: the command palette (9pt, with a shadow — it must read as an overlay), Settings'
grouped blocks (7pt), and sheet controls (5pt). Nothing in the sidebar, header, workspace, or
status line is rounded; row radius is 0.

## Structure

One window, two columns. Everything is flat color — the sidebar is the darkest surface, the
workspace sits slightly lighter, and the framed pane floats on it.

```
┌──────────────┬──────────────────────────────────────────────┐
│ traffic      │ header: space / agent  ~/path      status 4m │
│ lights       │ ┌──────────────────────────────────────────┐ │
│ waiting      │ │                                          │ │
│ summary      │ │   framed pane region (terminal)          │ │
│──────────────│ │   1px border, status-colored when the    │ │
│ machine tree │ │   agent is blocked                       │ │
│  ▸ SPACE   n │ │                                          │ │
│    agent     │ │                                          │ │
│    agent     │ └──────────────────────────────────────────┘ │
│ AUTOMATIONS  │ status line: queue position ·· key hints     │
│ SHELLS       │                                              │
└──────────────┴──────────────────────────────────────────────┘
```

- **Sidebar**: flat `bg.canvas` from the chat spec (`NativeTokens`). Traffic lights on the
  sidebar surface · waiting summary · the machine/space tree (agents nested under collapsible
  spaces, 7pt status dot + title per 23pt density-scaled row, 12pt indent per level,
  `bg.selected` for the active row, `bg.hoverStrong` on hover) · AUTOMATIONS and SHELLS
  sections with 10.5pt mono uppercase headings. The spec's 32pt rows and 22pt indent were
  tried and rejected: a real fleet lost a third of the tree. Rows are hover/click views carrying button traits and accessibility
  actions; the hover-only "+" glyphs are real buttons with labels. No tabs, no scope
  switching — the tree is the only persistent navigation.
- **Header**: `space / agent` breadcrumb, working directory in metadata color, trailing
  `status ⟨age⟩` in the status color.
- **Pane frame**: the workspace's single framed region, inset ~2pt, 1px border (`paneBorder`
  normally, the agent's status color when blocked). Terminals fill it edge-to-edge.
- **Status line**: leading queue segment (`1 of 3 waiting` in the attention color), `+ new
  space`, the fleet dot-count strip, trailing key hints.
- **Settings**: its own window, shaped like the main one — category list on `sidebarBg`,
  grouped rows over `workspaceBg`.

**Metrics** (`DesignTokens.swift` → `Metrics` for terminal chrome, `NativeMetrics` for the
sidebar and native thread): sidebar 230 default (190–340; the spec's fixed 256 and ⌘⇧S collapse
are not implemented) · traffic lights 38 · terminal header 42, native header 52 · status line
28 · sidebar row 23 (density-scaled) · pane inset 2 · min window 1040×640. Spacing scale 2/5/8/12/14/20.
Terminal chrome scales with the density setting (0.8–1.5).

**Typography**: terminal chrome (`Fonts`) is SF Mono — status line, pane frame, hints,
terminals. The sidebar and native thread (`NativeFonts`) use the spec's ramp with system
faces: breadcrumb label 13/500, prose body 15/1.6, code 12.5 mono, metadata micro 11 mono.
The sidebar keeps the compact mono ramp (rows 12, meta 10.5, headings 10.5 semibold caps). Chrome fonts scale with the UI
text scale setting; terminal font size is its own setting.

## Mobile exception: native iOS client

The iOS 27 app is a remote-only companion for iPhone and iPad. The Mac app remains
terminal-first. Mobile uses a native transcript for live text and tool output, with native
send/cancel controls and standard questions through the native thread bridge. It does not
parse terminal output into a transcript. Unsupported host or pi capabilities are stated explicitly;
the app never substitutes sample output or nonfunctional controls.

A `NavigationStack` moves from a host's agent list to one thread. Connection settings use a
native sheet. This replaces the desktop sidebar/workspace split on mobile; there are no desktop
minimum dimensions. Lists and thread content fill the available width and respect safe areas,
Dynamic Type, VoiceOver, and 44pt touch targets. Mobile follows the native chat spec
(`docs/design-spec/`): prose is the system sans face at 16/1.5, code, tool rows, and metadata
are system mono. The Agents list uses 56pt rows (title plus a one-line mono status), a host
section header with a connection pill, and a dimmed Unreachable card with Retry. A thread's
header is the title with a dot-and-word status line beneath. User turns are trailing bubbles on
`bg.bubble` (radius 14 with a 4pt bottom-trailing corner); assistant prose stays unboxed;
consecutive tool calls collapse into one 44pt summary row ("6 tool calls · read 1 · edit 3 ·
bash 2") that expands to 40pt rows, and bash output pushes a full-screen view. Standard
questions are a bottom sheet with a grabber and stacked 50pt actions (`Allow once` primary,
`Deny` in danger text, `Cancel` ghost), answerable one-handed. The composer is a pill field
(radius 22, grows to five lines) with the Send circle inside it; Send becomes Stop while the
agent runs and a "Waiting for you" slot appears while a question is pending. These mobile-only
exceptions do not change the desktop's flat terminal chrome.

Mobile's local `MobileTokens` mirrors the spec palette (same hex as the desktop `NativeTokens`)
without importing the Mac theme module. Status remains a dot plus a word. Host configuration, connection status, errors, and reconnect
controls live in the Settings sheet, reached through the fleet's gear button. The main screen
contains only agents and brief empty-state guidance; cached rows are labeled last known and
cannot open while disconnected. Setup explicitly requires a trusted LAN
or VPN because the bearer-token transport has no TLS. Backgrounding disconnects the client;
foregrounding reconnects and fetches current state without stopping the host's agents.

## Desktop exception: optional native conversation

Terminal is the shipped default; Settings ▸ Agents ▸ Default View switches it to Native for
every agent on this Mac. A local agent's primary pane can still be flipped the other way
through the header's Terminal/Native segmented control or the Agent menu; that override is
per-agent and device-local, and changing the default later leaves overrides alone. Both presentations use the same running pi process. The terminal
stays mounted, with drawing, focus, drops, interaction, and accessibility suppressed while
native content is visible. Switching sends nothing and cancels nothing. Normal cold parking
still applies when a layout is hidden.

Native content follows the chat spec in `docs/design-spec/` through `NativeTokens`,
`NativeFonts`, `NativeMetrics`, and `Radius`, not the terminal `Tokens`: a 52pt header
(breadcrumb · status pill · turn count · Terminal/Native switch · options), a content
column capped at 1200pt with 24pt gutters and prose capped at 1100pt, system sans at 15/1.6 for prose and system mono for
code and agent-touched text (the spec's IBM Plex Sans and JetBrains Mono are not bundled).
User turns are trailing bubbles on `bg.bubble` with a 12pt radius and one 4pt corner; there are
no speaker labels. Tool calls are 36pt rows (14pt status glyph · tool name · command or path
· result · duration · chevron) that expand only when there is saved output; failed rows expand
on `dangerBg`. Semantic `.text` colors sit only on their matching `.bg` or on `bgSurface`.
The composer is a raised 12pt-radius card: the field on top, one stable row beneath (attach for
RPC agents, model and thinking chips, a delivery chip only while a turn runs) and a single
28pt primary circle on the right that is Send, Stop (`dangerBg`) while running with an empty
draft, or a spinner while pi accepts. Typing `/` at line start opens an inline command menu
fed by pi's `get_commands` (RPC agents); there is no commands chip and no key-hint or working
directory text. A 22pt status line above the card carries "Waiting for you · elapsed" while a question
is pending; the working row in the thread carries the running state and elapsed time. Standard select, confirm, input, and editor questions replace the
field inside the card (never in the scrolling thread, so a blocked agent is always answerable)
with `Allow once` / `Deny` (Y/N while the panel holds focus) and exact bridge values. The
thread echoes a sent message immediately, ends in one persistent shimmering working row while
the agent runs, follows the tail until the user scrolls (a "↓ Jump to latest" pill returns),
and sending re-attaches to the tail. The composer is a bottom safe-area inset on the scroll view, never padding inside the content, so the thread always ends at its last turn. Unsupported pi versions, external editors, custom TUI extensions, images, and clipped
output have explicit Terminal fallback. Native prompts are literal text, not slash commands.
Shepherd-aware extensions may explicitly publish keyed, display-only status captions and
plain-text panels through the versioned native UI event bus. Both native clients use the same
bounded items. The app chooses all fonts and layout; panels are plain text above the composer.
No arbitrary extension widgets, buttons, callbacks, colors, or layout trees are supported. Shells, auxiliary panes, review, inspectors,
remote agents, and terminal chrome keep their existing behavior. The new presentation actions
have menu entries but no default keyboard shortcut or advertised chord.

## Status language

Status is a **colored dot + word**; the four status colors are the only saturated colors in
the chrome.

| Status | Semantics |
| --- | --- |
| working | green, slow pulse (static under Reduce Motion) — agent mid-turn |
| blocked | orange — waiting on the user |
| idle | dim gray — session attached, no active turn |
| done | slate blue — turn completed, nothing pending |

Blocked bleeds outward deliberately — it is the supervision signal: the waiting summary, space
and machine counts, the selected row's edge stripe, the header's `blocked 4m`, the pane frame,
and the status line's queue segment. Nothing else gets that treatment. A colored dot is never
the sole signal — status color is always paired with a word where it is actionable.

## Palette

Shepherd uses [Basalt Standard](https://github.com/bailycase/basalt-standard) exclusively —
dark and light. Every solid color comes from the resolved `ShepherdTheme`; views read
`Tokens.*` and never hardcode colors. Chrome, Ghostty, and every running pi TUI use the same
resolved variant, and theme changes update live surfaces in place — never a remount or replay.

- Both variants fill every `ShepherdTheme` field — the compiler enforces completeness.
- Preserve Basalt's surface ordering: sidebar distinct from workspace; raised/selected fills
  move farther from the base surface.
- Hairlines and hover fills derive from `textPrimary` opacity so they hold in both modes.
- Contrast: the smallest metadata text stays ≥4.5:1 against `sidebarBg`; the four status
  colors stay distinguishable from each other and from the text ramp.
- `SHEPHERD_THEME=basalt-dark|basalt-light` forces a variant at launch for screenshots.

## Interaction rules

- **The sidebar tree is the primary navigation.** The command palette (⌘K) is a secondary jump
  surface and must never become the only way to reach something, or show status the sidebar
  doesn't.
- **The waiting queue is a first-class object.** Summary block, status-line segment, and dot
  counts all derive from the same live status data.
- **Keyboard is first-class, and the fast path never requires a dialog.** ⌘1–9 agents, ⌃1–9
  shells, ⌃⇧1–9 machines (local is always ⌃⇧1) are fixed; everything else is rebindable
  through `KeybindingsStore` — menus, hints, and the ghostty unbind list all resolve through
  it, and hardcoding a chord in a view is a bug. Never advertise a hint for a shortcut that
  isn't wired.
- **Hints are bare mono text**, mid-dot separated — no bordered keycap chips in the main
  window chrome.
- **Empty states are one quiet mono line**, never a card or a big button.
- **Focus is the frame.** The pane border is the focus indication; no inset focus rings on rows.
- **Process exit closes its pane; sessions live and die with the app.** No daemon. Closing a
  pane detaches the view; Delete Agent is the explicit destructive action; quitting the app
  stops everything and relaunch restores the workspace with fresh processes. Shepherd never
  touches your Git state.
- **Remote is the same UI, honestly labeled.** Connection state lives on the machine root row,
  never as a banner; a disconnected host's rows dim rather than pretending to be supervisable.

## Accessibility

- Status color is always paired with words for actionable states.
- Sidebar metadata contrast ≥4.5:1; do not go dimmer than `textMetadata`.
- Reduce Motion kills the pulse; Increase Contrast raises separator/frame alphas.
- Every pane and session action exists in the menu bar with a shortcut.
- VoiceOver: agent rows read "title, status, pi"; child rows "label, subagent, state"; shell
  rows "label, shell".
