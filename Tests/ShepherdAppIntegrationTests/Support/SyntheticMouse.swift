import AppKit
import ShepherdTestSupport
import SwiftUI

/// A left-button drag sent to an off-screen window through `NSWindow.sendEvent`, as AppKit routes a click: never posted, so the
/// user's pointer and focus are never involved. Locations are window coordinates.
@MainActor
struct SyntheticMouse {
    let window: NSWindow
    let y: CGFloat
    /// Each event carries its own, later time, as a real drag does: a gesture can read a run of zero timestamps as no movement.
    private let clock = Clock()
    private final class Clock { var time = ProcessInfo.processInfo.systemUptime }

    func press(at x: CGFloat) throws { try send(.leftMouseDown, x) }
    func move(to x: CGFloat) throws { try send(.leftMouseDragged, x) }
    func release(at x: CGFloat) throws { try send(.leftMouseUp, x) }

    private func send(_ type: NSEvent.EventType, _ x: CGFloat) throws {
        clock.time += 0.016
        guard let event = NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: clock.time,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: 1) else { throw NoEvent() }
        window.sendEvent(event)
    }

    private struct NoEvent: Error {}

    /// What a scenario prints when its own process does not deliver these events to SwiftUI, so its test is cancelled by name.
    static let undeliveredLine = "SHEPHERD-MOUSE-UNDELIVERED\n"

    /// Whether a drag sent this way reaches a plain SwiftUI `DragGesture`, its changes and its end, in a window of its own. Run in
    /// the scenario's own process, beside the window under test and never on the gesture under test, so a broken gesture there
    /// fails its test instead of skipping it. A parent test process delivered such a drag on CI's runner while the scenario's
    /// exit-test process did not deliver one to the divider, so only this process's answer counts.
    static func reachesSwiftUIGestures() async -> Bool {
        final class Seen { var changed = false, ended = false }
        let seen = Seen()
        let window = OffscreenWindow(size: CGSize(width: 200, height: 100), dark: false,
                                     Color.clear.contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 1)
                                            .onChanged { _ in seen.changed = true }
                                            .onEnded { _ in seen.ended = true }))
        defer { window.close() }
        let mouse = SyntheticMouse(window: window.window, y: 50)
        try? mouse.press(at: 150)
        for x in [130.0, 110, 90] { try? mouse.move(to: x) }
        try? mouse.release(at: 90)
        return (try? await eventuallyOnMain("a probe drag", timeout: .seconds(2)) { seen.changed && seen.ended }) != nil
    }
}
