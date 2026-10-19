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
    private static var probed: Bool?

    /// Whether a drag sent this way reaches a plain SwiftUI `DragGesture` in this process at all. CI's headless runner has not
    /// delivered synthetic clicks to SwiftUI in a never-key window (ThreadImagesControlTests); a test that needs real mouse
    /// delivery is enabled by this probe, never by `CI`, so it is skipped by name only where delivery itself is missing.
    static func reachesSwiftUIGestures() async -> Bool {
        if let probed { return probed }
        final class Ended { var value = false }
        let ended = Ended()
        let window = OffscreenWindow(size: CGSize(width: 200, height: 100), dark: false,
                                     Color.clear.contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 1).onEnded { _ in ended.value = true }))
        defer { window.close() }
        let mouse = SyntheticMouse(window: window.window, y: 50)
        try? mouse.press(at: 150)
        for x in [130.0, 110, 90] { try? mouse.move(to: x) }
        try? mouse.release(at: 90)
        let reached = (try? await eventuallyOnMain("a probe drag", timeout: .seconds(2)) { ended.value }) != nil
        probed = reached
        return reached
    }
}
