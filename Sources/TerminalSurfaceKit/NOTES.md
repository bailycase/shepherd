# TerminalSurfaceKit: GhosttyTerminal integration notes

TerminalSurfaceKit adapts `GhosttyTerminal` (the vendored `Vendor/libghostty-spm`, libghostty
1.3.x) behind a small, stable API: `TerminalSurfaceModel` and `TerminalSurfaceView`. Shepherd uses
it for one thing: the terminal panes beside an agent's thread, which the user opens with ⌘D or an
agent opens with its `pane_*` tools. Agents themselves render as native threads and never get a
surface.

The kit spawns no process. `ShepherdSessions` owns every PTY, and the host-managed I/O backend
carries those bytes to and from the surface. Only `Sources/ShepherdApp/TerminalHost.swift` imports
this module; it wraps it as `AppTerminalModel` and `AppTerminalView`.

## GhosttyTerminal API used

### Host-managed I/O: `InMemoryTerminalSession`

```swift
InMemoryTerminalSession(
    write:  @Sendable (Data) -> Void,                     // terminal → host: encoded keystrokes/paste
    resize: @Sendable (InMemoryTerminalViewport) -> Void  // grid changes (columns/rows + pixel metrics)
)
session.receive(_ data: Data)   // host → terminal (PTY output), serialized on an internal queue
```

Choosing this session as the surface backend
(`viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))`) is what switches
Ghostty to its host-managed I/O mode. No process or exec is needed. `readViewportText()` is used
to confirm a surface is ready (below).

### Hosting: `TerminalViewState` + `GhosttyTerminal.TerminalSurfaceView`

`TerminalViewState(theme:terminalConfiguration:)` is an `@MainActor` `ObservableObject`, and
`GhosttyTerminal.TerminalSurfaceView(context:)` is the SwiftUI view. The representable sets the
NSView's delegate to the view state, which receives title, resize, focus, and lifecycle callbacks.
On macOS it wraps an NSView whose `layout()` calls `fitToSize()`: a view resize becomes a surface
resize, then the session's `resize` closure.

`viewState.surface` is a weak pointer. It is not safe as the adapter's lifecycle authority: during
a SwiftUI structural replacement, the old view can detach after the new one attaches and clear it.
The in-memory session still keeps the new surface, because its detach checks identity.

### Appearance and configuration

`TerminalConfiguration` renders to a ghostty.conf. Keys apply in order: base defaults, then
`terminalConfiguration`, then the theme, and the last key wins.

- **`shepherdSurface(fontSize:fontFamily:extraUnbinds:)`:** the font family and size from
  Settings ▸ Terminal (default SF Mono 12.5), `font-thicken`, 10×8pt window padding, and the
  keybind unbinds (below).
- **The theme** (`TerminalAppearance`): background, foreground, cursor, selection, and the
  16-color ANSI palette. `TerminalHost.swift` fills it from the resolved theme variant's
  `TerminalColors` (ShepherdUI). The background equals the theme's `bgWindow`, so panes sit on
  the thread surface. Shepherd has already resolved light or dark, so both of Ghostty's nested
  schemes get the same values.

`updateAppearance` (a live `setTheme`) and `updateConfiguration` (a live
`setTerminalConfiguration`) mutate the existing surface. The NSView, grid, scrollback, and
attachment all survive. Never rebuild or replay a surface just to recolor it, change its font, or
rebind a key. A TUI in the shell (pi run by hand, an editor) repaints at the same moment, and
replaying that transition can leave stale per-cell colors or a duplicated prompt.

### App-owned chords

A focused Ghostty surface consumes any key equivalent that matches one of its bindings.
`appOwnedChords` lists every chord the app chrome uses, and each is written as `keybind = <chord>=unbind`:

- new agent, options, and new space
- close pane, delete agent, and rename
- splits and pane focus
- ⇧⌘[ and ⇧⌘], which the app does not bind but Ghostty would swallow as no-op tab switches
- agent navigation and turn jumps
- sidebar, right pane, model picker, stop, and inspect
- ⌘1–9 and ⌃⇧1–9, in both logical and physical spellings
- ⌘, (both spellings), ⌘Q, and ⌘K

`extraUnbinds` carries the user's rebound chords from `KeybindingsStore`. Leave Ghostty's
copy and paste bindings alone.

## Adapter design decisions

- **Byte ordering.** Session callbacks arrive on background threads. `SessionCallbackBridge` always
  hops with `DispatchQueue.main.async`, which is FIFO. It never runs a callback immediately,
  because that could reorder keystrokes.
- **Buffering before attach.** `InMemoryTerminalSession.receive` silently drops data while no
  surface is attached. `feed(_:)` therefore tracks a per-view generation, not `viewState.surface`,
  and buffers until the in-memory surface is confirmed ready.
- **Replacement replay.** Every new view generation after the first stays buffered until the
  host's screen snapshot is applied (`replaceWithReplay(_:generation:)`). Replays carry their
  generation, so a delayed snapshot cannot land in a newer surface. A late disappear from the old
  view is ignored by identity.
- **Readiness and resize.** `onResize` comes from the session's `resize` closure (deduplicated
  inside GhosttyTerminal), not from the view delegate. A same-grid replacement may emit no resize
  at all. So after a view appears, the model also checks readiness with `readViewportText()` every
  10 ms for up to 500 ms. If a surface cannot attach in that time, the model keeps buffering
  rather than dropping bytes.
- **Focus.** Focus is applied through AppKit, not SwiftUI focus state. Every layout stays mounted,
  and SwiftUI discards programmatic focus for views in inactive parts of the hierarchy, so both
  `FocusState` approaches still needed a click. Instead, a zero-size `TerminalFocusBridge`
  (`NSViewRepresentable`) behind each pane calls `takeKeyboardFocus()` or
  `releaseKeyboardFocus()`. It acts only when the value changes, on the next run-loop turn, once
  the view has a window.
- **Model identity.** `TerminalSurfaceView` keys its subtree on the model's identity. libghostty
  assigns the NSView delegate only in `makeNSView`, so a reused NSView would otherwise stay wired
  to the previous pane.
- **Drops.** SwiftUI `.onDrop` cannot route drops correctly when hidden layouts stay mounted, so
  `TerminalDropOverlay` is one window-level overlay. It joins hit-testing only while a file drag
  is in flight, and delivers the drop to the visible pane under the cursor.
  - `TerminalFileDrop` inserts shell-escaped absolute paths.
  - `TerminalImageDrop` resizes images to a 2000 px longest edge before they are referenced. JPEG
    stays JPEG and everything else becomes PNG. The copies live in a drop directory and are
    pruned after 24 h.
  - Remote panes upload dropped files to the host, up to 32 MiB each.
- **Links.** A local event monitor makes a plain ⌘-click on a surface take Ghostty's link path.
  URLs open through the view state's `terminalDidRequestOpenURL`.

## Name collisions

`GhosttyTerminal` also exports `TerminalSurfaceView` (a SwiftUI view) and `TerminalSurface` (the
surface class). Inside this module the unqualified names mean ours, and Ghostty's view is written
`GhosttyTerminal.TerminalSurfaceView`. Code that imports both modules would need to qualify them,
which is one reason the app imports only TerminalSurfaceKit, and only in `TerminalHost.swift`.

## Hidden-pane rendering (`setRenderingActive`)

Every mounted layout stays in the view tree: a hidden agent's layout is a hidden hosting view
(`AgentLayoutDeck`), and a hidden pane inside a layout is `opacity(0)`. Their surfaces stay alive
until cold parking drops them. `setRenderingActive` drives Ghostty's display
visibility, which handles occlusion and stops or restarts the display link.

Two rules came out of real switching artifacts:

- **Desired state plus retry, never fire-and-forget.** Applying visibility means finding the
  Ghostty NSView through the window's view tree, and during a SwiftUI update the view may not be
  in a window yet.
  - A dropped *reveal* leaves the surface occluded, showing stale content until something forces
    a repaint.
  - A dropped *hide* leaves a background render loop competing for the GPU.

  `applyRenderingActive` retries up to 8 times, 40 ms apart, until the view is reachable.
- **On reveal, request layout (`needsLayout = true`), deferred.** The engine's `layout()` →
  `fitToSize()` reconciles metrics and requests an immediate tick, so the first visible frame is
  current and correctly sized. Never do this synchronously inside a SwiftUI update, because Metal
  must not render against an open layout transaction. The apply defers to the next main-queue
  turn.

## Caveats

- "SF Mono" resolves through CoreText only if it is registered on the system (Terminal and Xcode
  ship it). If the lookup fails, Ghostty silently falls back to its bundled font, with no config
  diagnostic.
