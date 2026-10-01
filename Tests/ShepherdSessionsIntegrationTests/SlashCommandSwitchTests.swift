import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Pi ▸ Slash commands: a command the user turns off leaves the `/` menu of every thread
/// on the host, in every client, because the host's projection of pi's `get_commands` leaves it
/// out. It is left out of that and nothing else: typing it still runs it, and the host still lists
/// it (`slashCommandCatalog`) so the page can switch it back on. The stub pi lists
/// `/session-name` (an extension command) and `/fix-tests` (a prompt template).
@Suite("Slash command switches", .integrationTimeLimit)
struct SlashCommandSwitchTests {
    typealias Thread = ThreadEventTests.Thread

    private func names(_ snapshot: NativeThreadSnapshot) -> [String]? { snapshot.commands?.map(\.name) }

    @Test func aHiddenCommandLeavesTheSnapshotAndComesBackInPisOrder() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        let listed = try await t.settle("pi's commands") { $0.commands != nil }
        #expect(names(listed) == ["session-name", "fix-tests"])

        t.queue.async { t.state.hiddenCommands = ["fix-tests"] }
        let hidden = try await t.settle("the menu without it") { names($0) == ["session-name"] }
        #expect(hidden.revision > listed.revision, "clients pull the change like any other")

        t.queue.async { t.state.hiddenCommands = [] }
        let back = try await t.settle("the menu with it again") { names($0)?.count == 2 }
        #expect(names(back) == ["session-name", "fix-tests"], "back where pi listed it")
    }

    @Test func aHiddenCommandStillRunsWhenItIsTyped() async throws {
        let t = try Thread()
        defer { t.stop() }
        _ = try await t.ready()
        _ = try await t.settle("pi's commands") { $0.commands != nil }
        t.queue.async { t.state.hiddenCommands = ["session-name"] }
        _ = try await t.settle("the menu without it") { names($0) == ["fix-tests"] }

        await t.sendAsUser("/session-name info Session named")
        let s = try await t.settle("the command's answer") { snapshot in
            (snapshot.messages + snapshot.provisional).contains { $0.entryID.hasPrefix("n:") }
        }
        let row = try #require((s.messages + s.provisional).first { $0.entryID.hasPrefix("n:") })
        #expect(row.blocks == [NativeThreadBlock(kind: .text, text: "Session named")], "it ran as an extension command, hidden or not")
    }

    @Test func theServerHidesACommandInEveryThreadAndStillListsItInItsCatalog() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let catalogs = Locked<[[String]]>([])
        h.server.onSlashCommandCatalogChanged = { catalog in
            dispatchPrecondition(condition: .onQueue(.main))
            catalogs.withValue { $0.append(catalog.map(\.name)) }
        }
        let first = try await PiAgent.launch(on: h)
        let second = try await PiAgent.launch(on: h)
        for agent in [first, second] {
            let listed = try await agent.snapshot("pi's commands") { $0.commands != nil }
            #expect(names(listed) == ["session-name", "fix-tests"])
        }
        #expect(h.server.slashCommandCatalog.map(\.name) == ["fix-tests", "session-name"], "the catalog lists each once, by name")
        try await eventually("the catalog to be announced") { catalogs.current.last == ["fix-tests", "session-name"] }

        h.server.setHiddenSlashCommands(["fix-tests"])
        for agent in [first, second] {
            let hidden = try await agent.snapshot("the menu without it") { names($0) == ["session-name"] }
            #expect(hidden.commands?.first?.description == "Set or clear session name")
        }
        #expect(h.server.slashCommandCatalog.map(\.name) == ["fix-tests", "session-name"], "hiding it does not take it off the page")

        // A thread started after the switch starts with it.
        let third = try await PiAgent.launch(on: h)
        _ = try await third.snapshot("the new thread's menu") { names($0) == ["session-name"] }

        h.server.setHiddenSlashCommands([])
        for agent in [first, second, third] {
            _ = try await agent.snapshot("the menu with it again") { names($0)?.count == 2 }
        }
    }
}
