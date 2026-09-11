import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
@testable import ShepherdApp

@Suite("Peer deletion confirmation", .serialized)
@MainActor
struct AgentPeerDeletionTests {
    @Test func nativeCancelKeepsTargetAndConfirmationUsesNormalDeletion() async throws {
        let dir = URL(fileURLWithPath: "/tmp/sh-peer-delete-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.appendingPathComponent("repo").path
        let checkout = dir.appendingPathComponent("checkout").path
        let setup = await LoginShell.run("mkdir \(shellQuoted(repo)) && git -C \(shellQuoted(repo)) init -q && git -C \(shellQuoted(repo)) -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial && git -C \(shellQuoted(repo)) worktree add -qb keep-this-branch \(shellQuoted(checkout))", timeout: 10)
        #expect(setup.status == 0)
        let socketPath = dir.appendingPathComponent("s").path
        let server = SessionServer(socketPath: socketPath, stateURL: dir.appendingPathComponent("state.json"))
        try server.start()
        defer { server.stop(); try? FileManager.default.removeItem(at: dir) }
        let primary = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: ["/bin/sh", "-c", "sleep 60"]))
        let auxiliary = try await server.createSession(params: CreateSessionParams(cwd: dir.path, command: ["/bin/sh", "-c", "sleep 60"]))
        let space = Space(name: "test", path: repo)
        let callerPane = LeafPane(cwd: dir.path)
        let callerTab = Tab(spaceID: space.id, order: 0, layout: .leaf(callerPane))
        let caller = Agent(name: "requesting agent", spaceID: space.id, tabID: callerTab.id, paneID: callerPane.id)
        let targetID = AgentID()
        let primaryPane = LeafPane(sessionID: primary.id, cwd: dir.path, agentID: targetID)
        let targetTab = Tab(spaceID: space.id, order: 1, layout: .split(axis: .vertical, ratio: 0.5,
            first: .leaf(primaryPane), second: .leaf(LeafPane(sessionID: auxiliary.id, cwd: dir.path))))
        var target = Agent(id: targetID, name: "target agent", spaceID: space.id, tabID: targetTab.id, paneID: primaryPane.id)
        target.worktreeBranch = "keep-this-branch"
        target.worktreePath = checkout
        let marker = URL(fileURLWithPath: checkout).appendingPathComponent("uncommitted.txt")
        try "keep work".write(to: marker, atomically: true, encoding: .utf8)
        try await server.putState(.init(spaces: [space], tabs: [callerTab, targetTab], agents: [caller, target]))
        let vm = ShepherdViewModel(server: server)
        try await waitUntil { vm.state.agents.count == 2 }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = try SessionServer.socketAddress(for: socketPath)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        func send(_ message: ExtensionMessage) throws {
            let data = try NDJSON.encode(message)
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            #expect(written == data.count)
        }
        var readBuffer = Data()
        func reply() async throws -> ExtensionReply {
            let deadline = ContinuousClock.now + .seconds(5)
            var buffer = [UInt8](repeating: 0, count: 4096)
            while ContinuousClock.now < deadline {
                if let nl = readBuffer.firstIndex(of: 10) {
                    let line = Data(readBuffer[..<nl])
                    readBuffer.removeSubrange(...nl)
                    return try NDJSON.decode(ExtensionReply.self, from: line)
                }
                let n = read(fd, &buffer, buffer.count)
                if n > 0 { readBuffer.append(contentsOf: buffer[..<n]) }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "test reply timeout", code: 1)
        }
        try send(.helloAgent(agentID: caller.id))
        try send(.coordinateAgent(id: 1, agentID: caller.id, targetAgentID: target.id, request: .init(operation: .delete)))
        try await waitUntil { vm.peerDeleteConfirmation != nil }
        #expect(vm.peerDeleteConfirmation?.agent.name == "target agent")
        #expect(vm.peerDeleteConfirmation?.senderName == "requesting agent")
        #expect(server.state.agents.count == 2)
        #expect(await server.sessionInfo(sessionID: primary.id)?.isAlive == true)
        #expect(await server.sessionInfo(sessionID: auxiliary.id)?.isAlive == true)
        vm.cancelPeerDeletion(requestID: try #require(vm.peerDeleteConfirmation?.requestID))
        #expect(try await reply() == .agentResult(id: 1, result: .init(text: "user cancelled deletion; agent kept", code: "cancelled")))
        #expect(server.state.agents.count == 2)

        // Cancelling the tool also revokes the native confirmation token.
        try send(.coordinateAgent(id: 2, agentID: caller.id, targetAgentID: target.id, request: .init(operation: .delete)))
        try await waitUntil { vm.peerDeleteConfirmation != nil }
        let revokedToken = try #require(vm.peerDeleteConfirmation?.requestID)
        let staleConfirm = { await vm.confirmPeerDeletion(requestID: revokedToken) }
        let staleCancel = { vm.cancelPeerDeletion(requestID: revokedToken) }
        try send(.cancelAgentRequest(id: 2, agentID: caller.id))
        _ = try await reply()
        try await waitUntil { vm.peerDeleteConfirmation == nil }
        #expect(await server.claimAgentDeletion(revokedToken) == false)
        #expect(server.state.agents.count == 2)

        try send(.coordinateAgent(id: 3, agentID: caller.id, targetAgentID: target.id, request: .init(operation: .delete)))
        try await waitUntil { vm.peerDeleteConfirmation != nil }
        let currentToken = try #require(vm.peerDeleteConfirmation?.requestID)
        #expect(currentToken != revokedToken)
        // Actions captured by the old sheet must not delete or dismiss its replacement.
        await staleConfirm()
        #expect(vm.peerDeleteConfirmation?.requestID == currentToken)
        #expect(server.state.agents.count == 2)
        #expect(await server.sessionInfo(sessionID: primary.id)?.isAlive == true)
        #expect(await server.sessionInfo(sessionID: auxiliary.id)?.isAlive == true)
        staleCancel()
        #expect(vm.peerDeleteConfirmation?.requestID == currentToken)
        #expect(server.state.agents.count == 2)
        // This is the same action as the native destructive button, never an extension boolean.
        await vm.confirmPeerDeletion(requestID: currentToken)
        guard case .agentResult(3, let result) = try await reply() else { Issue.record("missing deletion reply"); return }
        #expect(result.code == nil)
        #expect(server.state.agents.map(\.id) == [caller.id])
        #expect(!server.state.tabs.contains { $0.id == targetTab.id })
        for session in [primary, auxiliary] {
            let deadline = ContinuousClock.now + .seconds(5)
            while await server.sessionInfo(sessionID: session.id)?.isAlive == true, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(await server.sessionInfo(sessionID: session.id)?.isAlive != true)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep work")
        let preserved = await LoginShell.run("git -C \(shellQuoted(repo)) show-ref --verify refs/heads/keep-this-branch && git -C \(shellQuoted(checkout)) rev-parse --is-inside-work-tree", timeout: 10)
        #expect(preserved.status == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
