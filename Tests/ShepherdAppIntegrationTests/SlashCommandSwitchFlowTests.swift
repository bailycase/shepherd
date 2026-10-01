import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Settings ▸ Pi ▸ Slash commands through the real view model, server and launch path (the stub
/// pi lists `/session-name`, an extension command, and `/fix-tests`, a prompt template): a switch
/// changes the menu of the thread on screen, the page keeps listing what it hid, and a thread
/// started later, or after a relaunch, starts with the saved switches.
@Suite("Slash command switches in the app", .serialized, .mainActorExclusive)
@MainActor
struct SlashCommandSwitchFlowTests {
    private func names(_ store: NativeThreadStore) -> [String] { store.commands.map(\.name) }

    private func thread(_ vm: ShepherdViewModel, _ app: AppHarness, in space: Space) async throws -> (store: NativeThreadStore, stop: () -> Void) {
        let config = NewAgentConfig(spaceID: space.id, workingDirectory: app.dir.path, model: nil, thinking: .medium, initialPrompt: nil)
        let id = try await vm.startAgent(config, selectAfter: false)
        vm.selectAgent(id)
        let store = vm.threadStores.store(for: id)
        let server = app.server
        let polling = Task { await store.run(request: { try await server.nativeThread(agentID: id, request: $0) }) }
        try await eventuallyOnMain("pi's commands", timeout: .seconds(30)) { store.ready && !store.commands.isEmpty }
        return (store, { polling.cancel(); store.stop() })
    }

    @Test func aSwitchChangesTheMenuOfTheThreadOnScreenAndThePageKeepsTheCommand() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let (store, stop) = try await thread(vm, app, in: space)
        defer { stop() }
        #expect(names(store) == ["session-name", "fix-tests"])
        try await eventuallyOnMain("the page to list what pi reported") { vm.slashCommands.presentation.total == 2 }
        #expect(vm.slashCommands.presentation.groups.map(\.title) == ["Extensions", "Prompt templates"])

        app.settings.setSlashCommand("fix-tests", on: false)
        try await eventuallyOnMain("the menu without it") { names(store) == ["session-name"] }
        #expect(app.server.slashCommandCatalog.map(\.name) == ["fix-tests", "session-name"], "the host still lists it")
        let row = try #require(vm.slashCommands.presentation.groups.flatMap(\.rows).first { $0.name == "fix-tests" })
        #expect(!row.isOn && !row.unlisted, "so the page can switch it back on")
        #expect(vm.slashCommands.presentation.summary == "2 commands · 1 hidden")

        app.settings.setSlashCommand("fix-tests", on: true)
        try await eventuallyOnMain("the menu with it again") { names(store) == ["session-name", "fix-tests"] }
    }

    @Test func aRelaunchStartsEveryThreadWithTheSavedSwitches() async throws {
        try StubPi.installAsEngine()
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.hiddenSlashCommands = ["session-name"]
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let (store, stop) = try await thread(vm, app, in: space)
        defer { stop() }
        #expect(names(store) == ["fix-tests"], "a launch hands the server what Settings saved before any thread starts")
        let row = try #require(vm.slashCommands.presentation.groups.flatMap(\.rows).first { $0.name == "session-name" })
        #expect(!row.isOn, "and the page shows it off")
    }
}
