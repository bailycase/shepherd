import AppKit
import Foundation
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// A composer menu opened under the pointer comes to rest. As the menu grows from its corner,
/// its scale leaves AppKit's clip view a fraction of a point off the list's top. Putting the list
/// back from inside the report of that offset landed it on another fraction, which reported
/// again: the two chased each other within one display pass, and with the pointer over the
/// window, AppKit's cursor hit-testing kept the chase running until it threw ("more Update
/// Constraints in Window passes than there are views in the window") and the app aborted as the
/// model picker opened. The list is put back a few times while the menu grows, never thousands.
///
/// Scroll bars follow the Mac's setting (a mouse attached, or "Show scroll bars: Always", gives
/// legacy scrollers), which is process-wide, so each case runs in its own process.
@Suite("Composer menus under the pointer", .integrationTimeLimit)
struct ComposerMenuScrollerTests {
    /// Enough for every real drift of a growth (two or three on a Mac); the chase made thousands.
    static let returnsBudget = 10

    @Test(arguments: ["Always", "WhenScrolling"], ["models", "slash"])
    func aMenuOpenedUnderThePointerComesToRest(scrollBars: String, menu: String) async {
        await #expect(processExitsWith: .success) { [scrollBars = scrollBars as String, menu = menu as String] in
            await recordingErrors {
                var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                arguments["AppleShowScrollBars"] = scrollBars
                UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
                try await Self.open(menu, legacy: scrollBars == "Always")
            }
        }
    }

    /// Opens `menu` over a long thread with a full catalog and hit-tests the points over it on
    /// every poll while it grows, as AppKit's cursor update does after each layout, until the
    /// window draws the same picture a few polls running.
    @MainActor
    static func open(_ menu: String, legacy: Bool) async throws {
        #expect(NSScroller.preferredScrollerStyle == (legacy ? .legacy : .overlay))
        let thread = ComposerThread()
        defer { thread.close() }
        try await thread.waitUntilReady()
        let top = thread.cardTop - AppLayout.menuGap - ComposerMenuTests.Menu.models.height
        let points = stride(from: top + 10, to: thread.cardTop - AppLayout.menuGap, by: 60).flatMap { y in
            stride(from: thread.columnLeading + 10, to: thread.columnLeading + NWComposerMetrics.modelPickerWidth, by: 90)
                .map { CGPoint(x: $0, y: y) }
        }
        NWMenuDiagnostics.listReturns = 0
        if menu == "models" { thread.openModelPicker() } else { thread.openSlashMenu() }

        let all = CGRect(origin: .zero, size: thread.size)
        var last = FrameTimer.capture(thread.window, all), still = 0
        try await eventuallyOnMain("the menu to come to rest", timeout: .seconds(10), poll: .milliseconds(5)) {
            for point in points { _ = thread.hit(point) }
            let now = FrameTimer.capture(thread.window, all)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 5
        }
        let scroll = try #require(thread.menuScroll, "the menu opened")
        #expect(scroll.scrollerStyle == (legacy ? .legacy : .overlay))
        #expect(NWMenuDiagnostics.listReturns <= returnsBudget,
                "the list was put back at its top \(NWMenuDiagnostics.listReturns) times while the menu grew")
    }
}
