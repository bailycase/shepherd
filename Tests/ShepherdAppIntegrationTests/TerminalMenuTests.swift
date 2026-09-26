import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdUI

/// The new terminal menu opens from a right-click (or ⌃-click) on a tab (NewTerminalMenu), found
/// by an event monitor rather than a view over the tabs, so every other click still reaches them.
/// Events are built here and handed to the monitor, never posted.
@Suite("Terminal tab menu", .mainActorExclusive)
@MainActor
struct TerminalTabMenuTests {
    @Test func aSecondaryClickOnATabFindsItAndOtherClicksPassThrough() async throws {
        let window = OffscreenWindow(size: CGSize(width: 600, height: 60))
        defer { window.close() }
        let tabs = [NWTerminalTab(id: "zsh", title: "zsh"), NWTerminalTab(id: "logs", title: "tail -f logs")]
        window.show(NWTerminalTabBar(tabs, selection: "zsh", select: { _ in }, newTab: {}, menu: { _, _ in }) {}
            .frame(width: 600))

        func monitor(in view: NSView) -> NWSecondaryClickRegions.Monitor? {
            if let monitor = view as? NWSecondaryClickRegions.Monitor { return monitor }
            return view.subviews.lazy.compactMap(monitor).first
        }
        try await eventuallyOnMain("both tabs to be measured") {
            window.layout()
            return monitor(in: window.host)?.regions.count == 2
        }
        let regions = try #require(monitor(in: window.host))
        let logs = try #require(regions.regions.first { $0.0 == "logs" }?.1)
        let point = regions.convert(CGPoint(x: logs.midX, y: logs.midY), to: nil)
        func press(_ type: NSEvent.EventType, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: 0,
                               windowNumber: window.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        #expect(regions.region(for: press(.rightMouseDown)) == "logs")
        #expect(regions.region(for: press(.leftMouseDown, .control)) == "logs")
        #expect(regions.region(for: press(.leftMouseDown)) == nil, "a plain click selects the tab as before")
        let superview = try #require(window.host.superview)
        #expect(!(window.host.hitTest(superview.convert(point, from: nil)) is NWSecondaryClickRegions.Monitor),
                "nothing sits over the tabs")
    }
}
