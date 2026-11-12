import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The main window's visibility, read from the window the reader sits in: reported once it is
/// mounted, never during the update that mounted it, and again each time AppKit changes it.
@Suite("Window presence", .mainActorExclusive)
@MainActor
struct WindowPresenceTests {
    @MainActor private final class Reports {
        var values: [Bool] = []
    }

    @Test func aReaderReportsItsWindowsVisibilityAfterMountingAndWhenItChanges() async throws {
        let reports = Reports()
        let window = OffscreenWindow(size: CGSize(width: 100, height: 100), WindowOcclusionReader { reports.values.append($0) })
        defer { window.close() }
        #expect(reports.values.isEmpty, "the report waits for the update that mounted the reader to finish")

        try await eventuallyOnMain("the reader to report its window") { reports.values.count == 1 }
        #expect(reports.values == [window.window.occlusionState.contains(.visible)])

        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window.window)
        try await eventuallyOnMain("the reader to report the change") { reports.values.count == 2 }
        #expect(reports.values.last == window.window.occlusionState.contains(.visible))
    }
}
