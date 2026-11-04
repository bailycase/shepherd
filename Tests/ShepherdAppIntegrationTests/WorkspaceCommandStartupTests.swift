import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The actual File creation items in a native menu, with no windows or posted keyboard input.
@Suite("Workspace command startup", .integrationTimeLimit)
@MainActor
struct WorkspaceCommandStartupTests {
    @Test func newThreadBecomesAvailableAfterLaunchAndHonorsRebinding() async throws {
        let app = try AppHarness()
        let vm = try await app.start()
        defer { app.stop() }
        let launch = ShepherdLaunch(start: {}, makeModel: { vm }, failed: { _ in Issue.record("launch failed") })
        let menu = NSHostingMenu(rootView: FileCreationMenuItems(launch: launch, keys: app.keybindings))

        func newThread() throws -> NSMenuItem {
            // AppKit validates menu content when it opens. Ask the real delegate directly,
            // without opening a menu on screen or posting keyboard input.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.delegate?.menuWillOpen?(menu)
            menu.update()
            defer { menu.delegate?.menuDidClose?(menu) }
            return try #require(menu.items.first { $0.title == "New Thread" })
        }
        #expect(try !newThread().isEnabled, "no workspace action runs before ownership is acquired")
        #expect(launch.model == nil)

        await launch.begin()?.value
        try await eventuallyOnMain("New Thread to become enabled after launch") { try newThread().isEnabled }
        vm.openDestination(.automations)
        let before = vm.newThread.focusRequest
        func press(_ chord: KeyChord, keyCode: UInt16) throws {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: chord.modifierFlags, timestamp: 1, windowNumber: 0, context: nil,
                characters: chord.key, charactersIgnoringModifiers: chord.key,
                isARepeat: false, keyCode: keyCode))
            #expect(menu.performKeyEquivalent(with: event))
        }
        try press(app.keybindings.chord(for: .newAgent), keyCode: 45)
        try await eventuallyOnMain("Command+N to open and focus the New thread page") {
            vm.shownDestination == .newThread && vm.newThread.focusRequest == before + 1
        }

        let rebound = KeyChord(key: "u", command: true, option: true)
        #expect(app.keybindings.assign(rebound, to: .newAgent) == nil)
        try await eventuallyOnMain("the menu to adopt the rebound shortcut") {
            let item = try newThread()
            return item.keyEquivalent == "u" && item.keyEquivalentModifierMask == rebound.modifierFlags
        }
        vm.openDestination(.automations)
        try press(rebound, keyCode: 32)
        try await eventuallyOnMain("the rebound chord to open New thread exactly once") {
            vm.shownDestination == .newThread && vm.newThread.focusRequest == before + 2
        }
    }
}
