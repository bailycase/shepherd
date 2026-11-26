import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSidebar

/// A rename shows in the sidebar row and the header the moment it is submitted, the host stays the
/// only writer, and the outcome reconciles with whatever snapshots arrive.
@Suite("Optimistic thread rename", .mainActorExclusive)
@MainActor
struct ThreadRenameTests {
    @Test func seededThreadRenameSurvivesHostRestart() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.checkingSeededRename() }
        }
        expectScenarioCompleted(result)
    }

    private static func checkingSeededRename() async throws {
        try await ValidationGolden.check("seeded-thread-rename.json", from: #filePath,
                                         completion: "rename, restart and sidebar matched the golden") { golden in
            let seed = try #require(golden.seed as? [String: String])
            try await observeSeededRename(spaceName: try #require(seed["space"]), oldName: try #require(seed["name"]),
                                         newName: try #require(seed["renameTo"]), observe: golden.observe)
        }
    }

    /// Observe raw replies and stored JSON, so a Codable default can't hide a missing field.
    private static func observeSeededRename(spaceName: String, oldName: String, newName: String,
                                            observe: (String, [String: Any]) throws -> Void) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        let directory = app.dir
        defer { try? FileManager.default.removeItem(at: directory) }
        let space = Fixture.space(spaceName, path: directory.path)
        let agent = Fixture.agent(oldName, in: space)
        let id = agent.agent.id

        func threadFields(_ state: [String: Any]?) -> [String: Any] {
            let agent = (state?["agents"] as? [[String: Any]])?.first { ($0["id"] as? String) == id.rawValue }
            guard let agent else { return [:] }
            var fields: [String: Any] = ["agents[thread].id": "<thread>"]
            for field in ["name", "nameIsFinal"] { fields["agents[thread].\(field)"] = agent[field] }
            return fields
        }

        func exchange(_ socket: String, _ requests: [(String, RemoteRequest)]) async throws -> String? {
            let (frames, failure) = await Task.detached { () -> ([(String, Data, Data)], (any Error)?) in
                var frames: [(String, Data, Data)] = []
                do {
                    let client = try ExtensionClient(path: socket)
                    for (step, request) in requests {
                        let sent = try NDJSON.encode(request)
                        try client.sendRaw(sent)
                        while true {
                            let received = try client.readLine()
                            let reply = try ValidationGolden.object(received)
                            // Ignore pushes. Keep the actual reply ID so the golden can show broken correlation.
                            if reply["id"] != nil {
                                frames.append((step, sent, received))
                                break
                            }
                        }
                    }
                    return (frames, nil)
                } catch {
                    return (frames, error)
                }
            }.value
            var name: String?
            for (step, sent, received) in frames {
                let request = try ValidationGolden.object(sent), reply = try ValidationGolden.object(received)
                var fields: [String: Any] = [:]
                for key in ["id", "type", "protocolVersion"] {
                    fields["request.\(key)"] = request[key]
                    fields["reply.\(key)"] = reply[key]
                }
                fields["reply.code"] = reply["code"]
                if let target = request["agentID"] {
                    fields["request.agentID"] = ValidationGolden.normalize(target, ids: [id.rawValue: "<thread>"])
                }
                fields["request.action"] = request["action"]
                let thread = threadFields(reply["state"] as? [String: Any])
                for (key, value) in thread { fields["reply.state.\(key)"] = value }
                name = thread["agents[thread].name"] as? String
                try observe(step, fields)
            }
            // Compare replies already received before a later socket error can hide their field diff.
            if let failure { throw failure }
            return name
        }

        func hello(_ id: Int) -> RemoteRequest {
            .hello(id: id, token: "", clientName: "validation", protocolVersion: RemoteProtocol.version)
        }
        do {
            defer { app.stop(keepFiles: true) }
            try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
            _ = try await exchange(app.hostSocket, [
                ("hello", hello(1)),
                ("seeded", .stateFetch(id: 2)),
                ("rename", .agentAction(id: 3, agentID: id, action: .rename(name: newName))),
                ("renamed", .stateFetch(id: 4)),
            ])
            try observe("stored", threadFields(try ValidationGolden.object(Data(contentsOf: app.scratch.stateURL))))
        }

        let restarted = try AppHarness(directory: directory)
        defer { restarted.stop() }
        let vm = try await restarted.start()
        let name = try await exchange(restarted.hostSocket, [("restart-hello", hello(5)), ("reloaded", .stateFetch(id: 6))])
        let window = OffscreenWindow(size: CGSize(width: AppLayout.sidebarDefaultWidth, height: 650), dark: true, SidebarView(vm: vm))
        defer { window.close() }
        var label: String?, labels: [String] = []
        try? await eventuallyOnMain("the reloaded thread's accessibility label", timeout: .seconds(2)) {
            window.layout()
            labels = AccessibilityNode.all(under: window.host).compactMap(\.label)
            label = name.flatMap { name in labels.first { $0.hasPrefix(name + ", ") } }
            return label != nil
        }
        try observe("sidebar", ["accessibilityLabel": label.map { $0 as Any } ?? labels])
    }

    private func sidebarTitle(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? {
        vm.sidebarLists.all.first { $0.id == row }?.title
    }

    private func header(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? {
        hostName(vm, row).map { vm.presentedThreadName(row, hostName: $0) }
    }

    private func hostName(_ vm: ShepherdViewModel, _ row: SidebarRowID) -> String? { vm.hostThreadName(row) }

    @Test func thisMacsRenameShowsAtOnceKeepsTheSnapshotAndSettlesOnTheHost() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let original = Fixture.state(spaces: [space], agents: [agent])
        let vm = try await app.start(with: original)

        vm.renameAgent(id, to: "  New name \n")

        #expect(sidebarTitle(vm, .local(id)) == "New name")
        #expect(header(vm, .local(id)) == "New name")
        #expect(vm.state.agents.first?.name == "old name", "the host's snapshot is not edited")
        // A snapshot from before the rename lands while it is pending: the person's name stays.
        vm.adopt(original)
        #expect(sidebarTitle(vm, .local(id)) == "New name")

        try await eventuallyOnMain("the host's name to arrive and the overlay to leave") {
            vm.state.agents.first?.name == "New name" && !vm.pendingRenames.isPending(.local(id))
        }
        #expect(app.server.state.agents.first?.nameIsFinal == true)
        #expect(sidebarTitle(vm, .local(id)) == "New name")
    }

    @Test func thisMacsLatestRenameWinsAndTheHostEndsOnIt() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))

        vm.renameAgent(id, to: "First")
        vm.renameAgent(id, to: "Second")
        #expect(sidebarTitle(vm, .local(id)) == "Second")
        vm.renameAgent(id, to: "old name")
        #expect(sidebarTitle(vm, .local(id)) == "old name", "back to the original is a rename too")
        vm.renameAgent(id, to: "Third")

        try await eventuallyOnMain("the host to end on the last name") {
            app.server.state.agents.first?.name == "Third" && !vm.pendingRenames.isPending(.local(id))
        }
        #expect(sidebarTitle(vm, .local(id)) == "Third")
    }

    @Test func thisMacsRefusedRenameShowsTheHostNameAgainAndSaysWhy() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let id = agent.agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        // A directory where state.json belongs makes the host's write fail.
        try FileManager.default.removeItem(at: app.scratch.stateURL)
        try FileManager.default.createDirectory(at: app.scratch.stateURL, withIntermediateDirectories: true)

        vm.renameAgent(id, to: "Doomed")
        #expect(sidebarTitle(vm, .local(id)) == "Doomed")

        try await eventuallyOnMain("the refusal to restore the name") { vm.actionError != nil }
        #expect(vm.actionError?.title == "Couldn’t rename the agent")
        #expect(sidebarTitle(vm, .local(id)) == "old name" && header(vm, .local(id)) == "old name")
        #expect(app.server.state.agents.first?.name == "old name")
    }

    @Test func aPairedHostsRenameShowsAtOnceAndReconcilesWithItsSnapshots() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let vm = try await local.start()
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        let row = SidebarRowID.remote(ref)
        let before = connection.state

        vm.performRemoteAction(ref, action: .rename(name: "Paired name"))

        #expect(sidebarTitle(vm, row) == "Paired name" && header(vm, row) == "Paired name")
        #expect(connection.state == before, "the host's snapshot is not edited")

        try await eventuallyOnMain("the paired host to take the name and the overlay to leave") {
            remote.host.server.state.agents.first?.name == "Paired name" && connection.state == remote.host.server.state
                && !vm.pendingRenames.isPending(row)
        }
        #expect(sidebarTitle(vm, row) == "Paired name")
        #expect(vm.state.agents.isEmpty, "nothing of the host's thread leaked into This Mac's state")
    }

    @Test func aPairedHostsRefusedRenameRestoresItsNameWithTheReason() async throws {
        let local = try AppHarness(), remote = try RemoteHostHarness()
        defer { local.stop(); remote.stop() }
        let space = Fixture.space(path: remote.host.dir.path)
        let agent = Fixture.agent("old name", in: space)
        let vm = try await local.start()
        try await remote.host.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let connection = try await remote.connect(local.remoteHosts)
        let ref = RemoteAgentRef(hostID: connection.id, agentID: agent.agent.id)
        try FileManager.default.removeItem(at: remote.host.scratch.stateURL)
        try FileManager.default.createDirectory(at: remote.host.scratch.stateURL, withIntermediateDirectories: true)

        vm.renameThread(.remote(ref), to: "First")
        vm.renameThread(.remote(ref), to: "Doomed")
        #expect(sidebarTitle(vm, .remote(ref)) == "Doomed")

        try await eventuallyOnMain("the refusal to restore the name") { vm.actionError != nil }
        #expect(sidebarTitle(vm, .remote(ref)) == "old name")
        #expect(remote.host.server.state.agents.first?.name == "old name")
    }
}
