import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

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

    @Test(arguments: ["stop", "restart", "revoke", "disk"])
    func invalidatedOrFailedAdmissionNeverPublishesOrReachesPi(boundary: String) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let ready = try await pi.ready()
        try await eventually("initial recovery jobs settled") { try await h.server.enqueue { h.server.recoveryWritesInFlight == 0 } }
        let gate = DispatchSemaphore(value: 0)
        h.server.logicalProjectFiles.async { gate.wait() }
        defer { gate.signal() }
        let authorized = Locked(true), id = UUID()
        let request: NativeThreadRequest = .send(expectedSessionID: ready.piSessionID, generation: ready.generation,
            operationID: id, text: "must never reach pi", delivery: .followUp, images: images(1 << 20))
        let sending = Task {
            await withCheckedContinuation { continuation in
                h.server.queue.async {
                    h.server.rpcThread(forAgent: pi.agent.id)!.handle(request, inputAuthorization: { authorized.current }) {
                        continuation.resume(returning: $0)
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
        default:
            let url = AgentRecoveryStore(directory: h.dir.appendingPathComponent("agent-recovery")).file(for: pi.agent.id)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
    }
}
