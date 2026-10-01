# Motion

> Read when something animates, appears, or must not move.

Shepherd moves the way a native Mac app does: things come from somewhere, go somewhere, and
never jump, and nothing moves for decoration. `NW.Motion` (`Tokens/Motion.swift`) holds every
motion (`NW.Motion.glow`, `.spin`, `.hover`, `.pane`, …). The Foundations board's durations are
the anchors (hover 120ms, panes 180ms, sheets 240ms; the glow 1.6s ease-in-out, attention only;
the shimmer 1.8s linear, live text only; and the spinner 1s and a placeholder's pulse 1.4s), and
every one-shot motion runs on a SwiftUI spring at its anchor. Nothing in the thread spins: while
pi works, its live text shimmers (LiveText).

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
| `pane` | 180ms | `.smooth` | the side pane, the sidebar (docked or overlaid) | sliding from its edge, opaque | a 120ms cross-fade in place |
| `overlay` | 180ms | `.snappy` | the palette, composer menus, popovers | growing from 96% at its anchor, fading | a 120ms cross-fade |
| `sheet` | 240ms | `.smooth` | in-window sheets, a whole-window swap (Settings), toasts | rising from its edge, fading | a 120ms cross-fade |
| `emphasis` | 240ms | `.bouncy` | a small confirmation pop (viewed, copied, sent) | popping from 85% | nothing |
| `scroll` | 240ms | `.smooth` | turn jumps, revealing a row | — | instant |
| `glow` | 1.6s | ease-in-out, repeating | attention only: the dot's opacity 1 → 0.35 → 1 | — | static |
| `spin` | 1s | linear, repeating | work outside the thread (a sheet's step, a host connecting, "Starting pi…"): one turn a second | — | static |
| `shimmer` | 1.8s | linear, repeating | live text only (the running tool's line, "Thinking…"): a highlight, `textTertiary` → `textPrimary` → `textTertiary`, moving left to right across the text | — | plain `textSecondary` text |
| `pulse` | 1.4s | ease-in-out, repeating | loading placeholders (`.nwShimmer()`): opacity 0.55 → 1 → 0.55 | — | static |

The glow, the spinner, the shimmer, and the pulse are clock-driven (`NWPhase`), so Reduce Motion
can change while they are on screen. The spinner, the glow, and the shimmer are render-server
animations: Core Animation turns the arc, pulses the dot, and slides the shimmer's band on their
own layers (`NWLayerSpinner`, `NWLayerGlowDot`, `NWLayerShimmer`), started at the clock's phase so
every one moves in step, and one on screen costs the app no frames (drawn by a SwiftUI timeline,
a single spinner redrew its window on every display frame; in an off-screen test window, whose
host also relaid out tens of thousands of times a second, that was most of a core in a debug
build). The shimmer's band is masked by the text it lights, which SwiftUI draws once in
`textTertiary` beneath it (`.nwShimmer(active:)`). The pulse stays a timeline. None of them
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
  or menu highlight, J/K and N/P in the Changes pane) lands at once.
- **Terminal surfaces** never change size frame by frame. SwiftUI resizes a hosted NSView on every
  frame of an animated layout change (about 70 times for one 180ms pane), and for Ghostty each is
  a PTY resize. With `.nwInstant()` on the terminal view it takes its new size once while
  everything around it moves; `MotionProbeTests` pins both.
- **Streaming text** appends without motion; a finished part may fade in once. Clock text
  (elapsed times) ticks without rolling.
- **Long lists** animate what changed, never the whole list: a thread's `LazyVStack` must not
  animate every row when one turn arrives.
- **Columns take their new width at once** while a pane or the sidebar slides beside them: the
  thread beside a docked side pane, the main column beside the docked sidebar, and split
  panes. A long thread relaid out on every frame of a slide drops frames (measured in a debug
  build: gaps up to 55ms beside one thread and 171ms with five mounted layouts, against under
  9ms for plain content), so the column snaps as the motion starts and the pane slides into or
  out of the room. Window resizes, divider drags, and docked ⇄ overlaid flips never animate.
- **Selection** changes no row, so it lands at once; only rows arriving, leaving, reordering,
  or disclosing animate a list. Each agent's toolbar has its own identity, so switching never
  animates one agent's status or branch chip into another's.
