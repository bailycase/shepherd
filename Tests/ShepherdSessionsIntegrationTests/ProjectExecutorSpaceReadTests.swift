import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Exact executor Space read grants", .serialized, .integrationTimeLimit)
struct ProjectExecutorSpaceReadTests {
    @Test(arguments: ["history", "page"],
          ["add", "removeOther", "updateOther", "addRemoveOther", "noop", "rename", "sidebar", "reorder",
           "remove", "restore", "path", "pathRestore", "hidden", "hiddenRestore", "reservedRestore", "disable", "disableRestore", "restart"])
    func executorMutationPreservesOnlyUnaffectedGrants(boundary: String, change: String) async throws {
        let remote = try RemoteHost(); defer { remote.stop() }
        remote.server.onProjectExecutionLaunch = { _, done in Issue.record("Read must not launch work"); done(.failure(WireError("Read must not launch work"))) }
        remote.server.setProjectsEnabled(true)
        let space = Space(name: "Exact executor", path: remote.host.dir.path)
        let other = Space(name: "Other executor", path: remote.host.dir.appendingPathComponent("other").path)
        try await remote.server.addSpace(space)
        if ["removeOther", "updateOther", "reorder"].contains(change) { try await remote.server.addSpace(other) }
        let key = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID())
        var receipt = ProjectExecutionReceipt(key: key, phase: .settled)
        receipt.sessionID = "fixture-session"; receipt.generation = "fixture-generation"; receipt.matchedUserEntryID = "persisted-user"
        receipt.assignment = .init(key: key, taskID: ProjectTaskID(), reservedWorkerID: AgentID(), executorSpaceID: space.id, title: "Read", prompt: "Read")
        let exact = receipt
        let text = String(repeating: "é🙂", count: 5000)
        try ProjectHistoryStore(beside: remote.server.store.url).retainExecutionResult(receipt, result: .init(text: text, complete: true, stopReason: "stop"))
        try await remote.server.enqueue { try remote.server.store.update { $0.projectExecutions.append(exact) } }
        let client = try await remote.typed(); defer { client.disconnect() }
        let first = try await client.projectExecution(.result(key: key, offset: 0, sha256: nil))
        let firstPage = try #require(first.resultPage), offset = try #require(firstPage.nextOffset)
        let continuation = ProjectExecutionRequest.result(key: key, offset: offset, sha256: firstPage.sha256)
        let expected = try #require(try await client.projectExecution(continuation).resultPage)
        #expect(expected.availability == .complete && expected.sha256 == firstPage.sha256 && expected.identity == firstPage.identity)
        #expect(expected.data == Data(text.utf8).subdata(in: Int(offset)..<(Int(offset) + expected.data.count)))
        if boundary == "history" { try await remote.server.enqueue { try remote.server.store.update { $0.projectExecutions.removeAll() } } }
        let raw = try await remote.raw(authenticated: false); defer { raw.closeConnection() }
        _ = try await raw.hello(token: remote.token, capabilities: RemoteProtocol.clientCapabilities)
        let gate = DispatchSemaphore(value: 0), entered = Locked(false)
        defer { gate.signal() }
        let queue = boundary == "history" ? remote.server.projectHistoryReads : remote.server.logicalProjectFiles
        queue.async { entered.withValue { $0 = true }; _ = gate.wait(timeout: .now() + 30) }
        try await eventually("executor I/O gated") { entered.current }
        try raw.send(.projectExecution(id: 70, request: continuation))
        try raw.send(.stateFetch(id: 71))
        _ = try await raw.frames(until: { if case .state(71, _) = $0 { return true }; return false })
        // The following same-socket response proves the exact typed request crossed the dispatcher before the public mutation.
        switch change {
        case "add": try await remote.server.addSpace(other)
        case "removeOther": try await remote.server.deleteSpace(other.id)
        case "updateOther": var edited = other; edited.path += "/changed"; try await remote.server.updateSpace(edited)
        case "addRemoveOther": try await remote.server.addSpace(other); try await remote.server.deleteSpace(other.id)
        case "noop": try await remote.server.updateSpace(space)
        case "rename": var edited = space; edited.name = "Renamed"; try await remote.server.updateSpace(edited)
        case "sidebar": var edited = space; edited.sidebarHidden = true; try await remote.server.updateSpace(edited)
        case "reorder": try await remote.server.moveSpace(other.id, before: space.id)
        case "remove", "restore":
            try await remote.server.deleteSpace(space.id)
            if change == "restore" { try await remote.server.addSpace(space) }
        case "path", "pathRestore":
            var edited = space; edited.path += "/replacement"; try await remote.server.updateSpace(edited)
            if change == "pathRestore" { try await remote.server.updateSpace(space) }
        case "hidden", "hiddenRestore":
            var edited = space; edited.hidden = true; try await remote.server.updateSpace(edited)
            if change == "hiddenRestore" { try await remote.server.updateSpace(space) }
        case "reservedRestore":
            var edited = space; edited.holdsProjects = true; try await remote.server.updateSpace(edited)
            try await remote.server.updateSpace(space)
        case "disable", "disableRestore":
            remote.server.setProjectsEnabled(false)
            if change == "disableRestore" { remote.server.setProjectsEnabled(true) }
        case "restart": remote.server.stop(); try remote.server.start()
        default: Issue.record("Unknown mutation")
        }
        // Queue barrier also lets the experiment transitions finish before either blocked I/O boundary resumes.
        try await remote.server.enqueue {
            let eligible = Set(remote.server.store.state.spaces.filter { !$0.hidden && !$0.holdsProjects && !$0.holdsDesigns }.map(\.id))
            #expect(Set(remote.server.executionSpaceAuthority.keys) == eligible, "Only current eligible routes keep tokens; no removed-route tombstones accumulate")
        }
        gate.signal()
        if change == "restart" {
            await #expect(throws: Error.self) { try await raw.frames(until: { if case .projectExecution(70, _) = $0 { return true }; return false }) }
            let port = try remote.server.startRemoteListener(port: 0, tokenURL: remote.host.dir.appendingPathComponent("remote-token"))
            let fresh = RemoteHostClient(); defer { fresh.disconnect() }
            _ = try await fresh.connect(host: "127.0.0.1", port: port, token: remote.token, clientName: "result restart fixture")
            #expect(try await fresh.projectExecution(continuation).resultPage == expected)
            return
        }
        let frames = try await raw.frames(until: { if case .error(70, _, _) = $0 { return true }; if case .projectExecution(70, _) = $0 { return true }; return false })
        let last = try #require(frames.last)
        let unaffected = ["add", "removeOther", "updateOther", "addRemoveOther", "noop", "rename", "sidebar", "reorder"].contains(change)
        if unaffected {
            guard case .projectExecution(70, let result) = last else { Issue.record("Unrelated/no-op executor mutation refused the original grant: \(last)"); return }
            #expect(result.resultPage == expected, "Exact bytes, digest, completeness, identity and offset must survive")
        } else {
            guard case .error(70, let code, _) = last else { Issue.record("Revoked executor grant released content: \(last)"); return }
            #expect(code == "project_scope")
        }
        if ["remove", "hidden", "disable"].contains(change) {
            await #expect(throws: Error.self) { try await client.projectExecution(continuation) }
        } else {
            #expect(try await client.projectExecution(continuation).resultPage == expected, "A new grant after valid restoration works; it must not revive the old one")
        }
    }
}
