import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The New thread page's slash menu, in a real window over the real model, pressed the way
/// VoiceOver presses (each scenario in its own process): "/" lists the commands this Mac's pi has
/// listed, less those Settings switched off, and a row pressed starts the thread with "/name".
/// Nothing is posted to the window.
@Suite("New thread slash menu", .integrationTimeLimit)
struct NewThreadSlashMenuTests {
    @Test func slashListsThisMacsCommandsAndARowStartsTheThread() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.listingAndChoosing() }
        }
    }

    @MainActor
    static func listingAndChoosing() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let app = try AppHarness()
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        defer { app.stop() }
        vm.slashCommands.catalog = [
            NativeCommand(name: "review", description: "Review the diff", source: "prompt"),
            NativeCommand(name: "release-notes", description: "Draft release notes", source: "prompt"),
        ]
        app.settings.hiddenSlashCommands = ["release-notes"]
        vm.openNewThread()
        let draft = vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults && draft.place?.host == nil }
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 800), dark: true, NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        defer { window.close() }
        var found: NSTextView?
        try await eventuallyOnMain("the field to take the keyboard") {
            window.layout()
            found = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
            return found != nil
        }
        let editor = try #require(found)
        editor.insertText("/re", replacementRange: NSRange(location: 0, length: 0))

        func row(_ prefix: String) -> String? {
            window.layout()
            return window.elements().compactMap { $0.label }.first { $0.hasPrefix(prefix) }
        }
        try await eventuallyOnMain("the slash menu to list the command") { row("/review") != nil }
        #expect(row("/release-notes") == nil, "a command switched off in Settings stays out")

        try window.press(try #require(row("/review")))
        try await eventuallyOnMain("the new agent to be selected", timeout: .seconds(60)) { vm.selectedAgentID != nil && !draft.starting }
        #expect(draft.prompt.isEmpty)
        let id = try #require(vm.selectedAgentID)
        let server = app.server
        try await eventuallyAsync("pi to be sent the command as the opening message", timeout: .seconds(60)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "/review" } }
        }
    }
}
