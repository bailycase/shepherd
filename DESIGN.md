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

- **Sidebar**: flat `sidebarBg`. Traffic lights on the sidebar surface · waiting summary ·
  the machine/space tree (agents nested under collapsible spaces, status dot + title per row) ·
  AUTOMATIONS and SHELLS sections. No tabs, no scope switching — the tree is the only
  persistent navigation.
- **Header**: `space / agent` breadcrumb, working directory in metadata color, trailing
  `status ⟨age⟩` in the status color.
- **Pane frame**: the workspace's single framed region, inset ~2pt, 1px border (`paneBorder`
  normally, the agent's status color when blocked). Terminals fill it edge-to-edge.
- **Status line**: leading queue segment (`1 of 3 waiting` in the attention color), `+ new
  space`, the fleet dot-count strip, trailing key hints.
- **Settings**: its own window, shaped like the main one — category list on `sidebarBg`,
  grouped rows over `workspaceBg`.

**Metrics** (`DesignTokens.swift` → `Metrics`): sidebar 230 default (190–340) · traffic lights
38 · header 42 · status line 28 · row height 23 · pane inset 2 · row radius 0 · min window
1040×640. Spacing scale 2/5/8/12/14/20. Chrome scales with the density setting (0.8–1.5).

**Typography** (`Fonts`): SF Mono for everything — chrome, rows, headers, hints, terminals.
There is no proportional text in the app. Rows 12, child rows 11.5, section headings 10.5
semibold uppercase with +0.07em tracking, hints 11. Chrome fonts scale with the UI text scale
setting; terminal font size is its own setting.

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
