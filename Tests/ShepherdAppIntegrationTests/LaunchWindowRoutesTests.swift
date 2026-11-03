import AppKit
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// While the workspace is still opening, the window shows the launch surface, and the Dock can
/// already bring a closed window back: its route is installed by whatever the window shows first.
@Suite("Launch window routes", .mainActorExclusive)
@MainActor
struct LaunchWindowRoutesTests {
    @Test func theLaunchSurfaceInstallsTheReopenRouteBeforeTheWorkspaceIsReady() async throws {
        let previous = MainWindow.open
        defer { MainWindow.open = previous }
        MainWindow.open = nil
        // The workspace is not open yet: only the launch surface shows.
        let window = OffscreenWindow(size: CGSize(width: 600, height: 400), LaunchSurface().modifier(MainWindowRoutes()))
        defer { window.close() }
        try await eventuallyOnMain("the Dock's route is installed by the launch surface") { MainWindow.open != nil }
        // Closed during startup and reopened: the route is still there (the app delegate calls it; nothing is posted here).
        window.close()
        #expect(MainWindow.open != nil)
    }
}
