import AppKit
import Testing
@testable import TerminalSurfaceKit

/// Pane focus is driven through AppKit rather than SwiftUI focus modifiers.
/// Both SwiftUI approaches (a per-pane `FocusState<Bool>`, and one shared
/// `FocusState<Tag?>` keyed by pane) were implemented and tested against the
/// running app; both left the terminal unfocused until it was clicked, because
/// every agent layout stays mounted and SwiftUI will not hand programmatic
/// focus to a view in an inactive part of the hierarchy.
@Suite("Terminal first responder")
@MainActor
struct TerminalFirstResponderTests {
    /// The class name must match libghostty's surface view. Confirmed against a
    /// running app, where the window's first responder logged as
    /// `AppTerminalView`. A rename upstream shows up as focus quietly not
    /// working, so pin it here.
    @Test func matchesLibghosttySurfaceClassName() {
        #expect(TerminalFirstResponder.surfaceClassName == "AppTerminalView")
    }

    /// Surface views are collected from the whole window, because SwiftUI hosts
    /// every mounted layout as siblings: a pane's terminal is a cousin of its
    /// background bridge, not a descendant.
    @Test func findsSurfaceViewsAnywhereInTheTree() {
        final class AppTerminalView: NSView {}

        let root = NSView(frame: .zero)
        let branch = NSView(frame: .zero)
        let nested = NSView(frame: .zero)
        let surface = AppTerminalView(frame: .zero)

        nested.addSubview(surface)
        branch.addSubview(nested)
        root.addSubview(branch)
        root.addSubview(NSView(frame: .zero))

        let found = TerminalFirstResponder.surfaceViews(in: root)
        #expect(found.count == 1)
        #expect(found.first === surface)
        #expect(TerminalFirstResponder.isSurfaceView(surface))
        #expect(!TerminalFirstResponder.isSurfaceView(branch))
    }

    /// Focus is applied by making the surface first responder, so a caller
    /// must be able to tell whether it actually took. A sheet dismissing (New
    /// Agent) can take it back on a later run-loop turn, which is why the
    /// model verifies instead of assuming.
    @Test func firstResponderCanBeVerifiedAfterAssignment() {
        final class AppTerminalView: NSView {
            override var acceptsFirstResponder: Bool { true }
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let root = NSView(frame: window.contentLayoutRect)
        window.contentView = root
        let surface = AppTerminalView(frame: .zero)
        root.addSubview(surface)

        #expect(window.firstResponder !== surface)
        window.makeFirstResponder(surface)
        #expect(window.firstResponder === surface)

        // Something else takes it (the sheet case).
        window.makeFirstResponder(nil)
        #expect(window.firstResponder !== surface)
    }

    /// Panes are told apart by their delegate (libghostty assigns the model's
    /// view state), never by tree position.
    @Test func ignoresViewsThatAreNotSurfaces() {
        let plain = NSView(frame: .zero)
        #expect(TerminalFirstResponder.delegate(of: plain) == nil)
        #expect(TerminalFirstResponder.view(ownedBy: plain, in: nil) == nil)
    }
}
