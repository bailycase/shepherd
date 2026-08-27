# TerminalSurfaceKit — GhosttyTerminal integration notes

Adapter over `GhosttyTerminal` (libghostty-spm 1.3.x) exposing the frozen
`TerminalSurfaceModel` / `TerminalSurfaceView` API. No PTY is spawned; the
host-managed I/O backend carries app-owned PTY bytes both ways.

## GhosttyTerminal API used (from .build/checkouts/libghostty-spm)

### Host-managed I/O: `InMemoryTerminalSession`

```swift
InMemoryTerminalSession(
    write:  @Sendable (Data) -> Void,                    // terminal -> host (user keystrokes/paste, already ghostty-encoded)
    resize: @Sendable (InMemoryTerminalViewport) -> Void // grid changes (columns/rows: UInt16, plus pixel metrics)
)
session.receive(_ data: Data)   // host -> terminal (PTY output); serialized on an internal queue
```

Selecting this session as the surface backend is what flips the C config to
`GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED` and wires
`ghostty_surface_write_buffer` + receive callbacks
(`TerminalController+Surface.swift → configureBackend`). Nothing else is
required — no process, no exec.

Also available but unused: `session.receive(String)`, `readViewportText()`,
`sendInput(Data)` (bypasses key translation), `finish(exitCode:runtimeMilliseconds:)`.

### SwiftUI hosting: `TerminalViewState` + `GhosttyTerminal.TerminalSurfaceView`

```swift
TerminalViewState(configSource: .none, theme: TerminalTheme, terminalConfiguration: TerminalConfiguration) // @MainActor ObservableObject
viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
GhosttyTerminal.TerminalSurfaceView(context: viewState)   // SwiftUI view
    .terminalFocused($someFocusState)                     // FocusState<Bool>.Binding -> makeFirstResponder
```

The representable sets `view.delegate = viewState` internally; `TerminalViewState`
absorbs title/resize/focus/lifecycle delegate callbacks. On macOS this wraps
`AppTerminalView` (NSView), which calls `fitToSize()` from `layout()` — view
resize → surface resize → session `resize` closure. `viewState.surface`
(`GhosttyTerminal.TerminalSurface`, weak) normally follows attachment, but is
not safe as the adapter's lifecycle authority: during a SwiftUI structural
replacement, the old view can detach after the new one attaches and clear the
shared weak pointer. The in-memory session still correctly retains the new
surface because its detach is identity-checked.

### Appearance: `TerminalConfiguration` / `TerminalTheme`

Config renders to a ghostty.conf; ordering is base(.default) → terminalConfiguration
→ theme, last key wins. Applied here:

- terminalConfiguration: configured font family/size, `font-thicken = true`, and
  Shepherd's pane padding.
- theme: the resolved Basalt background, foreground, cursor, selection, and ANSI palette.
  Shepherd has already resolved system/light/dark mode, so `TerminalTheme` receives the same
  config for both nested Ghostty schemes.

`TerminalSurfaceModel.updateAppearance` calls Ghostty's live `setTheme` mutation. Appearance
changes therefore keep the existing NSView, grid, scrollback, and attachment. Never rebuild or
replay a surface just to recolor it: Pi repaints at the same time, and replaying that transition
can preserve stale per-cell colors or duplicate the prompt layout.

## Adapter design decisions

- **Byte ordering**: session callbacks arrive on background threads.
  `SessionCallbackBridge` always hops via `DispatchQueue.main.async` (FIFO) —
  never a run-immediately fast path, which could reorder keystrokes.
- **Pre-attach buffering**: `InMemoryTerminalSession.receive` silently drops
  data while no surface is attached. `feed(_:)` therefore follows a per-SwiftUI-
  view generation tracker rather than `viewState.surface`, buffering until the
  actual in-memory surface is confirmed ready.
- **Replacement replay**: every new view generation after the first remains
  buffered until the host's screen snapshot is applied. Replays carry their
  generation, so a delayed snapshot cannot land in a newer surface. A late
  disappear from the old view is ignored by identity.
- **onResize source**: driven by the session's `resize` closure (deduped inside
  GhosttyTerminal), not the view delegate. Same-grid replacements may emit no
  resize, so `onAppear` also confirms readiness through `readViewportText()` on
  a deferred run-loop turn.
- **Focus**: `isFocused` (plain Bool per frozen API) is pushed into a private
  `@FocusState` via `onChange(of:initial:)`; GhosttyTerminal's focus binding
  handles `makeFirstResponder`. If the user clicks focus away while the app
  still passes `isFocused: true`, nothing re-asserts until the value changes.

## Name collisions (intentional, module-internal)

`GhosttyTerminal` also exports `TerminalSurfaceView` (SwiftUI view) and
`TerminalSurface` (surface class). Inside TerminalSurfaceKit the unqualified
names resolve to our declarations; the ghostty view is referenced as
`GhosttyTerminal.TerminalSurfaceView`. Downstream code that imports **both**
modules would need qualification; ShepherdApp should import TerminalSurfaceKit only.

## Hidden-pane rendering (`setRenderingActive`)

Every agent layout stays mounted; hidden panes are `opacity(0)` with their
surfaces alive. `TerminalSurfaceModel.setRenderingActive` drives
`AppTerminalView.setSurfaceVisible` → `core.setDisplayVisible` → ghostty
occlusion + display-link stop/immediate-tick.

Two rules, learned from our own switching artifacts:

- **Desired state + retry, never fire-and-forget.** The apply resolves the
  ghostty NSView through the window's view tree; during SwiftUI updates the
  view may not be in a window yet. A dropped *reveal* leaves the surface
  occluded — stale content until something else forces a repaint (the
  "switching repaints and bugs out" artifact). A dropped *hide* leaves a
  background render loop competing for the GPU. `applyRenderingActive`
  retries (8 × 40ms) until the view is reachable.
- **On reveal, request layout (`needsLayout = true`), deferred.** The
  engine's `layout()` → `fitToSize()` reconciles metrics and requests an
  immediate tick, so the first visible frame is current and correctly sized.
  Never synchronously from inside a SwiftUI update pass — Metal must not
  render against a still-open layout transaction, so the apply defers to the
  next main-queue turn.

## Caveats / skips

- "SF Mono" resolves via CoreText only if registered on the system (Terminal/Xcode
  ship it; it is not a public system family everywhere). Ghostty falls back to its
  bundled default font silently if lookup fails — no config diagnostic.
- No terminal selection color specified for panes in the design README; ghostty
  default selection rendering is kept. The 16-color ANSI palette is likewise left
  at ghostty defaults (README's "ANSI-ish" tokens are semantic hints, not a palette).
- Surface confirmation retries for 500 ms after a view appears. A surface that
  cannot attach in that interval keeps buffering rather than dropping bytes;
  normal layout and window attachment complete well inside this bound.

