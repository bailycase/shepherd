import AppKit
import Foundation
import GhosttyTerminal

func terminalOpenURL(_ value: String) -> URL? {
    guard let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          ["http", "https", "mailto"].contains(scheme) else { return nil }
    return url
}

func terminalLinkModifiers(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
    flags.contains(.command) ? flags.union(.shift) : flags
}

extension TerminalViewState: @retroactive TerminalSurfaceOpenURLDelegate {
    public func terminalDidRequestOpenURL(_ value: String, kind _: TerminalOpenURLKind) {
        guard let url = terminalOpenURL(value) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Ghostty-facing colors for a surface. Hex strings, with or without "#".
public struct TerminalAppearance: Sendable {
    public var background: String
    public var foreground: String
    public var cursorColor: String
    public var selectionBackground: String?
    public var selectionForeground: String?
    /// Up to 16 ANSI palette entries; empty keeps ghostty defaults.
    public var palette: [String]

    public init(
        background: String = "08080A",
        foreground: String = "C9CCC9",
        cursorColor: String = "3F3F46",
        selectionBackground: String? = nil,
        selectionForeground: String? = nil,
        palette: [String] = []
    ) {
        self.background = background
        self.foreground = foreground
        self.cursorColor = cursorColor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }
}

/// Tracks SwiftUI terminal-view generations independently of
/// `TerminalViewState.surface`. Ghostty's state object is shared across view
/// replacements, so a late detach from the old view can otherwise clear the
/// new view's weak surface pointer.
struct SurfaceAttachmentTracker {
    enum ReadinessAction: Equatable {
        case detached
        case ready
        case replacement(generation: UInt64)
        case waitingForReplay
    }

    private(set) var isReady = false
    private var activeViewID: UUID?
    private var generation: UInt64 = 0
    private var hasBeenReady = false
    private var replacementPending = false
    private var replayGeneration: UInt64?

    mutating func appeared(_ id: UUID) {
        guard activeViewID != id else { return }
        generation &+= 1
        activeViewID = id
        isReady = false
        replayGeneration = nil
        replacementPending = hasBeenReady
    }

    mutating func disappeared(_ id: UUID) {
        guard activeViewID == id else { return }
        activeViewID = nil
        isReady = false
        replacementPending = false
        replayGeneration = nil
    }

    func isActive(_ id: UUID) -> Bool {
        activeViewID == id
    }

    mutating func becameReady(_ expectedViewID: UUID? = nil) -> ReadinessAction {
        if let expectedViewID, activeViewID != expectedViewID { return .detached }
        guard activeViewID != nil else { return .detached }
        if replayGeneration != nil { return .waitingForReplay }
        if replacementPending {
            replacementPending = false
            replayGeneration = generation
            return .replacement(generation: generation)
        }
        isReady = true
        hasBeenReady = true
        return .ready
    }

    mutating func finishReplacement(generation expected: UInt64) -> Bool {
        guard activeViewID != nil, replayGeneration == expected, generation == expected else { return false }
        replayGeneration = nil
        isReady = true
        hasBeenReady = true
        return true
    }
}

@MainActor
public final class TerminalSurfaceModel: ObservableObject {
    public var onInput: ((Data) -> Void)?
    public var onResize: ((_ cols: Int, _ rows: Int) -> Void)?
    /// Fired when a NEW ghostty surface becomes ready after the first one.
    /// The generation identifies that exact replacement so a stale async
    /// replay cannot land in a newer surface.
    public var onSurfaceReplaced: ((_ generation: UInt64) -> Void)?

    let viewState: TerminalViewState
    private let session: InMemoryTerminalSession
    private var pendingOutput = Data()
    private var attachment = SurfaceAttachmentTracker()
    /// Whether this pane should be drawing. Hidden panes stay mounted but must
    /// not run a render loop. Also read by the drop delegate: a hidden pane
    /// must not accept drops.
    private(set) var renderingActive = true
    let acceptsFileDrops: Bool

    public init(
        fontSize: CGFloat = 12.5,
        fontFamily: String = "SF Mono",
        appearance: TerminalAppearance = TerminalAppearance(),
        extraUnbinds: [String] = [],
        acceptsFileDrops: Bool = true
    ) {
        _ = Self.linkClickMonitor
        self.acceptsFileDrops = acceptsFileDrops
        let bridge = SessionCallbackBridge()
        session = InMemoryTerminalSession(
            write: { data in
                bridge.deliverInput(data)
            },
            resize: { viewport in
                bridge.deliverResize(cols: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )

        viewState = TerminalViewState(
            theme: .shepherd(appearance),
            terminalConfiguration: .shepherdSurface(
                fontSize: fontSize,
                fontFamily: fontFamily,
                extraUnbinds: extraUnbinds
            )
        )
        viewState.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        bridge.model = self
        Self.modelsByViewState.setObject(self, forKey: viewState)
    }

    /// Reconfigure the live Ghostty surface without replacing its view or
    /// replaying terminal contents. Theme changes are configuration changes,
    /// not session lifecycle events.
    @discardableResult
    public func updateAppearance(_ appearance: TerminalAppearance) -> Bool {
        viewState.setTheme(.shepherd(appearance))
    }

    /// Reconfigure font and keybind unbinds in place, like updateAppearance.
    /// Ghostty applies the new config to the live surface — no view
    /// replacement, no replay, no blank frame.
    @discardableResult
    public func updateConfiguration(
        fontSize: CGFloat,
        fontFamily: String,
        extraUnbinds: [String]
    ) -> Bool {
        viewState.setTerminalConfiguration(
            .shepherdSurface(
                fontSize: fontSize,
                fontFamily: fontFamily,
                extraUnbinds: extraUnbinds
            )
        )
    }

    /// Shift bypasses mouse capture in fullscreen TUIs. Ghostty already uses
    /// that path for links, so make plain Command-click take it too.
    private static let linkClickMonitor = NSEvent.addLocalMonitorForEvents(
        matching: [.leftMouseDown, .leftMouseUp, .mouseMoved, .leftMouseDragged]
    ) { event in
        guard event.modifierFlags.contains(.command),
              let contentView = event.window?.contentView,
              var view = contentView.hitTest(contentView.convert(event.locationInWindow, from: nil))
        else { return event }

        while !TerminalFirstResponder.isSurfaceView(view) {
            guard let parent = view.superview else { return event }
            view = parent
        }

        return NSEvent.mouseEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: terminalLinkModifiers(event.modifierFlags),
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            eventNumber: event.eventNumber,
            clickCount: event.clickCount,
            pressure: event.pressure
        ) ?? event
    }

    /// viewState → model, so the window drop overlay can go from the ghostty
    /// NSView it finds under the cursor (whose delegate is the viewState) to
    /// the owning model. Weak on both sides.
    private static let modelsByViewState = NSMapTable<AnyObject, TerminalSurfaceModel>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )

    /// The model owning a ghostty surface view, or nil for foreign views.
    static func model(for view: NSView) -> TerminalSurfaceModel? {
        guard let delegate = TerminalFirstResponder.delegate(of: view) else { return nil }
        return modelsByViewState.object(forKey: delegate)
    }

    /// Start or stop this pane's render loop.
    ///
    /// Every agent layout stays mounted so switching does not destroy
    /// surfaces, but a mounted surface keeps its display link running and
    /// renders forever. With several agents that is several render loops
    /// competing for the GPU each vsync, which showed up as the *visible*
    /// terminal dropping frames while typing. libghostty stops the display
    /// link when a surface is marked not visible.
    public func setRenderingActive(_ active: Bool) {
        guard renderingActive != active else { return }
        renderingActive = active
        applyRenderingActive(remainingAttempts: 8)
    }

    /// Applies the desired rendering state to the ghostty view, retrying
    /// briefly when the view is not in a window yet.
    ///
    /// A dropped apply is not cosmetic: a revealed pane whose surface stays
    /// occluded skips every draw and shows stale content until some later
    /// event forces a full repaint — the "switching agents repaints and bugs
    /// out" artifact. A hidden pane that misses its stop keeps a render loop
    /// running behind opacity(0). So the state is desired-state + retry,
    /// never a single fire-and-forget attempt.
    private func applyRenderingActive(remainingAttempts: Int = 0) {
        for window in NSApp.windows {
            guard let view = TerminalFirstResponder.view(ownedBy: viewState, in: window) else { continue }
            (view as? AppTerminalView)?.setSurfaceVisible(renderingActive)
            if renderingActive {
                // Reveal: rerun the view's layout on the next AppKit pass so
                // the surface reconciles its metrics and draws a fresh frame
                // (layout → fitToSize → synchronizeMetrics + immediate
                // tick). Deferred by nature — never a synchronous display
                // inside a SwiftUI update.
                view.needsLayout = true
            }
            return
        }
        guard remainingAttempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40)) { [weak self] in
            MainActor.assumeIsolated {
                self?.applyRenderingActive(remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    /// Make this pane's ghostty surface the window's first responder, so
    /// switching agents moves the keyboard without needing a click.
    ///
    /// Retries: on the update that reveals a pane, its terminal view may not
    /// be in the window yet, and AppKit ignores `makeFirstResponder` for a
    /// view with no window. A brand-new agent is the slow case — the process
    /// spawns, the surface is created, and the New Agent sheet is still
    /// dismissing — so the window has to cover roughly a second, not a frame.
    public func takeKeyboardFocus(remainingAttempts: Int = 40) {
        let windows = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.windows
        for window in windows.compactMap({ $0 }) {
            guard let view = TerminalFirstResponder.view(ownedBy: viewState, in: window) else { continue }
            if window.firstResponder === view {
                return // Already ours; nothing to do and nothing to retry.
            }
            window.makeFirstResponder(view)
            // Verify rather than assume: a sheet dismissing (New Agent) can
            // take first responder back on a later turn, which is exactly the
            // case where a fresh agent came up unfocused. Keep asserting until
            // it sticks or the budget runs out.
            if window.firstResponder !== view {
                retryFocus(remainingAttempts: remainingAttempts)
            }
            return
        }
        retryFocus(remainingAttempts: remainingAttempts)
    }

    private func retryFocus(remainingAttempts: Int) {
        guard remainingAttempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(25)) { [weak self] in
            MainActor.assumeIsolated {
                self?.takeKeyboardFocus(remainingAttempts: remainingAttempts - 1)
            }
        }
    }

    /// Give up the keyboard if this pane's surface currently holds it. Only
    /// ever releases its own surface, never another pane's.
    public func releaseKeyboardFocus() {
        for window in NSApp.windows {
            guard let view = TerminalFirstResponder.view(ownedBy: viewState, in: window),
                  window.firstResponder === view else { continue }
            window.makeFirstResponder(nil)
            return
        }
    }

    /// Complete an asynchronous replacement replay only if its target surface
    /// is still current. Output received while the view was absent is already
    /// represented by the replay, so it is discarded before the snapshot is
    /// fed into Ghostty.
    @discardableResult
    public func replaceWithReplay(_ data: Data, generation: UInt64) -> Bool {
        guard attachment.finishReplacement(generation: generation) else { return false }
        pendingOutput.removeAll()
        if !data.isEmpty {
            session.receive(data)
        }
        return true
    }

    public func feed(_ data: Data) {
        // Trust our SwiftUI-view generation rather than TerminalViewState's
        // weak surface pointer. During split collapse, an old Ghostty view can
        // detach after its replacement attached and incorrectly clear that
        // shared pointer even though the in-memory session owns a live surface.
        guard attachment.isReady else {
            pendingOutput.append(data)
            return
        }
        flushPendingOutput()
        session.receive(data)
    }

    func surfaceViewAppeared(_ id: UUID) {
        attachment.appeared(id)
        // A replacement ghostty view starts visible, so a hidden pane would
        // silently resume rendering. Re-assert once it is in the window —
        // with retries, because "the next main-queue turn" is not always
        // enough for SwiftUI to finish inserting the view.
        if !renderingActive {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyRenderingActive(remainingAttempts: 8) }
            }
        }
        // Ghostty deduplicates same-grid resize callbacks across replacement
        // surfaces, so resize alone cannot prove readiness. Confirm the actual
        // in-memory surface on a later run-loop turn instead.
        confirmSurfaceReady(id, remainingAttempts: 50)
    }

    func surfaceViewDisappeared(_ id: UUID) {
        attachment.disappeared(id)
    }

    private func confirmSurfaceReady(_ id: UUID, remainingAttempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.attachment.isActive(id) else { return }
                if self.session.readViewportText() != nil {
                    self.handleSurfaceReadiness(self.attachment.becameReady(id))
                } else if remainingAttempts > 1 {
                    self.confirmSurfaceReady(id, remainingAttempts: remainingAttempts - 1)
                }
            }
        }
    }

    /// Insert Finder-dropped files using Ghostty's native macOS convention:
    /// absolute paths, shell-escaped and separated by spaces.
    func sendDroppedFiles(_ urls: [URL]) -> Bool {
        guard let text = TerminalFileDrop.text(for: urls) else { return false }
        return viewState.send(text)
    }

    fileprivate func handleInput(_ data: Data) {
        onInput?(data)
    }

    fileprivate func handleResize(cols: Int, rows: Int) {
        let readiness = attachment.becameReady()
        // Resize is enqueued before a replacement snapshot, so the replay is
        // generated at the new surface's exact grid.
        onResize?(cols, rows)
        handleSurfaceReadiness(readiness)
    }

    private func handleSurfaceReadiness(_ readiness: SurfaceAttachmentTracker.ReadinessAction) {
        switch readiness {
        case .detached, .waitingForReplay:
            break
        case .ready:
            flushPendingOutput()
        case .replacement(let generation):
            // Keep live output buffered until the owner's atomic replay catches
            // the replacement up.
            if let onSurfaceReplaced {
                onSurfaceReplaced(generation)
            } else if attachment.finishReplacement(generation: generation) {
                flushPendingOutput()
            }
        }
    }

    private func flushPendingOutput() {
        guard !pendingOutput.isEmpty else { return }
        session.receive(pendingOutput)
        pendingOutput.removeAll()
    }
}

/// Hops InMemoryTerminalSession callbacks (arbitrary threads) onto the main
/// actor. Always dispatches async so the serial main queue preserves byte order.
private final class SessionCallbackBridge: @unchecked Sendable {
    @MainActor weak var model: TerminalSurfaceModel?

    func deliverInput(_ data: Data) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.model?.handleInput(data)
            }
        }
    }

    func deliverResize(cols: Int, rows: Int) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.model?.handleResize(cols: cols, rows: rows)
            }
        }
    }
}

// MARK: - Appearance

extension TerminalTheme {
    /// Dark-only: identical configs for both schemes so OS appearance flips are inert.
    static func shepherd(_ appearance: TerminalAppearance) -> TerminalTheme {
        let config = TerminalConfiguration { builder in
            builder.withBackground(appearance.background)
            builder.withForeground(appearance.foreground)
            builder.withCursorColor(appearance.cursorColor)
            if let selection = appearance.selectionBackground {
                builder.withSelectionBackground(selection)
            }
            if let selection = appearance.selectionForeground {
                builder.withSelectionForeground(selection)
            }
            for (index, color) in appearance.palette.prefix(16).enumerated() {
                builder.withPalette(index, color: color)
            }
        }
        return TerminalTheme(light: config, dark: config)
    }
}

extension TerminalConfiguration {
    /// ⌘-chords owned by the app chrome. Ghostty's defaults bind several of
    /// these (new_window, new_tab, new_split, close_surface, goto_tab…) and the
    /// surface consumes matching key equivalents while focused — unbinding them
    /// lets the events fall through to the app's main menu. Copy/paste and the
    /// rest of ghostty's bindings stay untouched.
    private static let appOwnedChords = [
        // ⌘N new agent · ⌘⇧T agent options · ⌘⇧N new space · ⌘W close
        // pane · ⌘⇧W delete agent · ⌘D/⌘⇧D split.
        "cmd+n", "cmd+t", "shift+cmd+t", "shift+cmd+n", "cmd+w", "shift+cmd+w",
        "cmd+d", "shift+cmd+d", "cmd+r",
        // ⇧⌘]/[ have no app binding, but ghostty's next_tab/previous_tab
        // defaults are no-ops in embedded libghostty — unbinding keeps them
        // from being silently swallowed.
        "shift+cmd+right_bracket", "shift+cmd+left_bracket",
        "alt+cmd+left", "alt+cmd+right",
        // ⌘↑/↓: previous/next agent in sidebar tree order.
        "cmd+up", "cmd+down",
        // ⌘1–9: agent selection in sidebar tree order.
        "cmd+one", "cmd+two", "cmd+three", "cmd+four", "cmd+five",
        "cmd+six", "cmd+seven", "cmd+eight", "cmd+nine",
        "cmd+physical:one", "cmd+physical:two", "cmd+physical:three",
        "cmd+physical:four", "cmd+physical:five", "cmd+physical:six",
        "cmd+physical:seven", "cmd+physical:eight", "cmd+physical:nine",
        // ⌃1–9: shell selection, mirroring the agent digits.
        "ctrl+one", "ctrl+two", "ctrl+three", "ctrl+four", "ctrl+five",
        "ctrl+six", "ctrl+seven", "ctrl+eight", "ctrl+nine",
        "ctrl+physical:one", "ctrl+physical:two", "ctrl+physical:three",
        "ctrl+physical:four", "ctrl+physical:five", "ctrl+physical:six",
        "ctrl+physical:seven", "ctrl+physical:eight", "ctrl+physical:nine",
        // ⌃⇧1–9: machine jump (local + remote hosts in sidebar order).
        "ctrl+shift+one", "ctrl+shift+two", "ctrl+shift+three",
        "ctrl+shift+four", "ctrl+shift+five", "ctrl+shift+six",
        "ctrl+shift+seven", "ctrl+shift+eight", "ctrl+shift+nine",
        "ctrl+shift+physical:one", "ctrl+shift+physical:two",
        "ctrl+shift+physical:three", "ctrl+shift+physical:four",
        "ctrl+shift+physical:five", "ctrl+shift+physical:six",
        "ctrl+shift+physical:seven", "ctrl+shift+physical:eight",
        "ctrl+shift+physical:nine",
        // ⌘, Settings. Ghostty's built-in open_config binding is stored as a
        // unicode trigger while "comma" parses as a physical key, so both
        // spellings must be unbound for the chord to reach the app menu.
        "cmd+comma", "cmd+,",
        // ⌘Q: ghostty's default super+q=quit is a no-op in embedded
        // libghostty, so a focused surface would swallow quit entirely.
        "cmd+q",
        // ⌘K command palette (ghostty binds cmd+k=clear_screen by default).
        "cmd+k",
    ]

    /// `extraUnbinds` carries the host's user-customized chords (ghostty
    /// chord syntax); the surface must let those key equivalents fall
    /// through to the app exactly like the built-in ones.
    static func shepherdSurface(
        fontSize: CGFloat,
        fontFamily: String = "SF Mono",
        extraUnbinds: [String] = []
    ) -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily(fontFamily)
            builder.withFontSize(Float(fontSize))
            builder.withFontThicken(true)
            builder.withWindowPaddingX(10)
            builder.withWindowPaddingY(8)
            for chord in appOwnedChords {
                builder.withCustom("keybind", "\(chord)=unbind")
            }
            for chord in extraUnbinds where !appOwnedChords.contains(chord) {
                builder.withCustom("keybind", "\(chord)=unbind")
            }
        }
    }
}

