import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

private extension NativeThreadResult {
    var wasAccepted: Bool { if case .accepted = self { return true }; return false }
}

@Suite("Recovery checkpoint staging", .integrationTimeLimit)
struct RecoveryStagingTests {
    private func images(_ bytes: Int) -> [NativeImage] {
        var remaining = bytes
        var result: [NativeImage] = []
        while remaining > 0 {
            let size = min(remaining, NativeImage.maxBytes)
            result.append(.init(mimeType: "image/png", data: Data(repeating: 137, count: size)))
            remaining -= size
        }
        return result
    }

    @Test(arguments: [0, 1 << 20, 5 << 20])
    func queuedAdmissionWaitsForFileWorkWithoutBlockingAnotherThread(bytes: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        let other = try await PiAgent.launch(on: h)
        _ = try await other.ready()
        try await eventually("initial recovery save settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let replied = Locked(false)
        let id = UUID(), payload = images(bytes)
        let request = Task {
            let value = try await pi.send("held image queue", images: payload, operationID: id, from: working)
            replied.withValue { $0 = true }
            return value
        }
        try await eventually("image checkpoint staged behind gate") { try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 } }
        #expect(!replied.current)
        _ = try await other.snapshot()
        let checkpoint = try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id)
        #expect(checkpoint?.items.contains { $0.entry.id == id } != true)
        let visible = try await pi.snapshot()
        #expect(visible.queue?.items.contains { $0.id == id } != true)
        gate.signal()
        #expect(try await request.value.wasAccepted)
        let store = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery"))
        let saved = try #require(try store.checkpoint(for: pi.agent.id))
        #expect(saved.items.first { $0.entry.id == id }?.images == payload)
        // The old decoder still reads the exact same inline JSON representation.
        let legacy = try JSONDecoder().decode(AgentRecoveryStore.Checkpoint.self, from: Data(contentsOf: store.file(for: pi.agent.id)))
        #expect(legacy == saved)
    }

    @Test func overlappingCandidatesCannotOverwriteAnAcceptedSend() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let first = Task { try await pi.send("slow", images: images(1 << 20), from: ready) }
        try await eventually("first candidate held") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 1 } }
        let second = Task { try await pi.send("slow second", images: images(1 << 20), from: ready) }
        try await eventually("second candidate held") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 2 } }
        gate.signal()
        let results = try await [first.value, second.value]
        #expect(results.filter(\.wasAccepted).count == 1)
        _ = try await pi.snapshot { $0.running }
        #expect(pi.stdin("prompt").count == 1)
        let checkpoint = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(checkpoint.items.isEmpty)
        #expect(checkpoint.active)
    }

    @Test func failedQueueEditRenameKeepsTheOriginalImagesAndTextUnpublished() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }, id = UUID()
        #expect(try await pi.send("original", images: images(1 << 20), operationID: id, from: working).wasAccepted)
        let store = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery"))
        let original = try #require(try store.checkpoint(for: pi.agent.id))
        let url = store.file(for: pi.agent.id), backup = url.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: url, to: backup)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(!(try await pi.queue(.edit(id: id, text: "unwritten"), from: working)).wasAccepted)
        let visible = try await pi.snapshot()
        #expect(visible.queue?.items.first?.text == "original")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: backup, to: url)
        #expect(try JSONDecoder().decode(AgentRecoveryStore.Checkpoint.self, from: Data(contentsOf: url)) == original)
    }

    @Test(arguments: [1 << 20, 5 << 20])
    func recoveryReservationsStayBoundedUntilCancelledWorkersDrain(bytes: Int) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let limit = min(8, (32 << 20) / (bytes + "held 0".utf8.count))
        let requests = (0..<limit).map { index in Task { try await pi.send("held \(index)", images: images(bytes), from: ready) } }
        try await eventually("recovery reservation limit") { try await h.server.enqueue { h.server.recoveryWritesInFlight == limit } }
        #expect(!(try await pi.send("overflow", images: images(bytes), from: ready)).wasAccepted)
        _ = try await pi.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID()))
        for request in requests { #expect(!(try await request.value).wasAccepted) }
        #expect(try await h.server.enqueue { h.server.recoveryWritesInFlight == limit && h.server.recoveryWriteBytes == limit * bytes + (0..<limit).reduce(0) { $0 + "held \($1)".utf8.count } })
        gate.signal()
        try await eventually("all reservations released") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 && h.server.recoveryWriteBytes == 0 } }
        #expect(pi.stdin("prompt").isEmpty)
    }

    @Test func imageBytesCountAgainstTheWholeQueueBudget() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running }
        #expect(try await pi.send("first", images: images(5 << 20), from: working).wasAccepted)
        #expect(!(try await pi.send("overflow", images: images(5 << 20), from: working)).wasAccepted)
        let saved = try #require(try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id))
        #expect(saved.items.map(\.entry.text) == ["first"])
    }

    @Test(arguments: [false, true])
    func sessionSwitchAnswersEveryDuplicateStagedSendExactlyOnce(evicted: Bool) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h), ready = try await pi.ready()
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let request: NativeThreadRequest = .send(expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: UUID(), text: "must never reach pi", delivery: .followUp, images: images(1 << 20))
        let replies = Locked([[NativeThreadResult]](repeating: [], count: 2))
        try await h.server.enqueue {
            let thread = try #require(h.server.rpcThread(forAgent: pi.agent.id))
            for index in 0..<2 { thread.handle(request) { result in replies.withValue { $0[index].append(result) } } }
            if evicted {
                for _ in 0..<RPCThreadState.operationTableSize {
                    thread.handle(.queue(expectedSessionID: ready.piSessionID, generation: ready.generation,
                        operationID: UUID(), action: .delete(id: UUID()))) { #expect(!$0.wasAccepted) }
                }
            }
        }
        try await eventually("one shared recovery preparation") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 1 } }
        try await h.server.enqueue { h.server.rpcThread(forAgent: pi.agent.id)?.session.send(.newSession) }
        _ = try await pi.snapshot { $0.generation != ready.generation }
        try await eventually("both callers answered before worker release") { replies.current.allSatisfy { $0.count == 1 } }
        #expect(replies.current.allSatisfy { $0.first == .failure(code: "stale_session", message: "Refresh the thread before acting.") })
        #expect(pi.stdin("prompt").isEmpty)
        gate.signal()
        try await eventually("cancelled stage drained") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        #expect(replies.current.allSatisfy { $0.count == 1 })
        #expect(pi.stdin("prompt").isEmpty)
    }

    @Test(arguments: ["stop", "restart", "revoke", "disk", "exit", "retire"])
    func invalidatedOrFailedAdmissionNeverPublishesOrReachesPi(boundary: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        try await eventually("initial recovery jobs settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let authorized = Locked(true), replies = Locked<[NativeThreadResult]>([]), id = UUID()
        let request: NativeThreadRequest = .send(expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: id, text: "must never reach pi", delivery: .followUp, images: images(1 << 20))
        let sending = Task {
            await withCheckedContinuation { continuation in
                h.server.queue.async {
                    h.server.rpcThread(forAgent: pi.agent.id)!.handle(request, inputAuthorization: { authorized.current }) { result in
                        replies.withValue { $0.append(result) }
                        continuation.resume(returning: result)
                    }
                }
            }
        }
        try await eventually("admission file work gated") { try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 } }
        switch boundary {
        case "stop":
            _ = try await pi.request(.abort(expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: UUID()))
        case "restart":
            h.server.stop()
            try h.server.start()
        case "revoke": authorized.withValue { $0 = false }
        case "exit", "retire":
            h.server.killSession(pi.sessionID)
            try await eventually("exited staging reply") { !replies.current.isEmpty }
            if boundary == "retire" { await h.server.retireSession(sessionID: pi.sessionID) }
        default:
            let url = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).file(for: pi.agent.id)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if ["stop", "restart", "exit", "retire"].contains(boundary) {
            try await eventually("cancelled reply before worker release") { replies.current.count == 1 }
            #expect(try await h.server.enqueue { h.server.recoveryWritesInFlight > 0 }, "reservations stay held until the worker drains")
        }
        gate.signal()
        #expect(!(await sending.value).wasAccepted)
        #expect(pi.stdin("prompt").isEmpty)
        if boundary != "disk" {
            let saved = try AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).checkpoint(for: pi.agent.id)
            #expect(saved?.pending.contains { $0.entry.id == id } != true)
        }
        try await eventually("staging jobs released") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: h.dir.appendingPathComponent("agent-recovery").path)) ?? []
        #expect(!files.contains { $0.hasPrefix(".recovery-stage-") })
        #expect(replies.current.count == 1)
    }
}
