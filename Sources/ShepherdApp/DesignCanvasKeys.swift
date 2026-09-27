import AppKit
import SwiftUI

/// The canvas's own chords (RefImplementMenu): Implement in a thread… (⌘↩ unless rebound) and
/// Copy reference (⇧⌘C), answered only while the design is on screen and nothing that takes text
/// has the keyboard with something in it, so the chat's composer keeps its own ⌘↩ (send the
/// other way) for a draft and a text field keeps ⇧⌘C. Clicking the canvas leaves the keyboard
/// where it was (the chat's composer, usually), so an empty field doesn't hold the chords back.
struct DesignCanvasKeys: NSViewRepresentable {
    let active: Bool
    /// The design chat holds a draft (words, files or references) its ⌘↩ would send.
    var chatHasDraft: () -> Bool = { false }
    let implement: () -> Void
    let copy: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.active = active
        view.chatHasDraft = chatHasDraft
        view.implement = implement
        view.copy = copy
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stop()
    }

    final class Watcher: NSView {
        var active = false
        var chatHasDraft: () -> Bool = { false }
        var implement: () -> Void = {}
        var copy: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) == true }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Takes `event` when it is one of the canvas's chords, in this window, while the design
        /// shows and nothing that takes text has the keyboard with something in it.
        func handle(_ event: NSEvent) -> Bool {
            guard active, event.window === window, window != nil, !isHiddenOrHasHiddenAncestor,
                  !Self.textHoldsKeyboard(window?.firstResponder, chatHasDraft: chatHasDraft) else { return false }
            let keys = KeybindingsStore.shared
            if keys.chord(for: .implementInThread).matches(event) {
                implement()
                return true
            }
            if keys.chord(for: .copyDesignReference).matches(event) {
                copy()
                return true
            }
            return false
        }

        /// Whether what has the keyboard keeps the chords: a board's page or a terminal always, a
        /// text field or view while it holds text or the chat holds a draft. An empty one (the
        /// chat's composer after a send) lets them through.
        static func textHoldsKeyboard(_ responder: NSResponder?, chatHasDraft: () -> Bool) -> Bool {
            guard textHasKeyboard(responder) else { return false }
            guard let text = responder as? NSText else { return true }
            return !text.string.isEmpty || chatHasDraft()
        }

        /// A text field, a text view, a terminal or a board's page has the keyboard.
        static func textHasKeyboard(_ responder: NSResponder?) -> Bool {
            guard let responder else { return false }
            if responder is NSTextInputClient || responder is NSText { return true }
            if let web = NSClassFromString("WKWebView"), responder.isKind(of: web) { return true }
            return false
        }
    }
}
