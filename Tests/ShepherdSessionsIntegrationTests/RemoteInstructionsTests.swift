import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings ▸ Instructions over the listener: a client reads the host's root instructions, saves
/// and restores them into the files the instructions extension reads, and the host's GUI hears
/// about every change a client makes.
@Suite("Remote instructions", .integrationTimeLimit)
struct RemoteInstructionsTests {
    @Test func aClientReadsSavesAndRestoresTheHostsFiles() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let heard = Locked<[InstructionsSnapshot]>([])
        host.server.onInstructionsChanged = { snapshot in heard.withValue { $0.append(snapshot) } }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.instructionsCapability))

        let empty = try await client.instructions()
        #expect(empty.agents.isEmpty && empty.appendSystem.isEmpty && empty.history.isEmpty)

        let synced = try await client.instructions(.save(file: .appendSystem, content: "Never force-push.\n", origin: "studio", sync: true))
        #expect(synced.appendSystem == "Never force-push.\n")
        #expect(synced.history.first?.summary == "Synced from studio")
        let onDisk = try String(contentsOf: host.host.dir.appendingPathComponent("instructions/APPEND_SYSTEM.md"), encoding: .utf8)
        #expect(onDisk == "Never force-push.\n")

        let edited = try await client.instructions(.save(file: .appendSystem, content: "Never force-push.\nAsk before migrating.\n",
                                                         origin: "iPhone", sync: false))
        #expect(edited.history.first?.summary == "Added “Ask before migrating.”")
        #expect(edited.history.first?.origin == "iPhone")

        let restored = try await client.instructions(.restore(revisionID: try #require(synced.history.first?.id), origin: "iPhone"))
        #expect(restored.appendSystem == "Never force-push.\n")
        #expect(restored.history.count == 3)
        try await eventually("the GUI to hear all three changes") { heard.current.count == 3 }
        #expect(heard.current.last == restored)
    }

    @Test func aFetchChangesNothingAndTellsTheGUINothing() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let heard = Locked<Int>(0)
        host.server.onInstructionsChanged = { _ in heard.withValue { $0 += 1 } }
        try host.server.instructions.save(.agents, content: "- Tests first.\n")
        let client = try await host.typed()
        defer { client.disconnect() }

        let snapshot = try await client.instructions(.fetch)
        #expect(snapshot.agents == "- Tests first.\n")
        #expect(snapshot.history.count == 1)
        #expect(heard.current == 0)
    }

    @Test func restoringAVersionTheHostNoLongerHasIsRefused() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let raw = try await host.raw()

        try raw.send(.instructions(id: 5, request: .restore(revisionID: UUID(), origin: "studio")))

        guard case .error(5, let code, _) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(code == "no_such_revision")
    }
}
