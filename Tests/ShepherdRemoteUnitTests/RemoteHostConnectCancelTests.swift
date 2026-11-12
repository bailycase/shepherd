import Darwin
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Cancelling `connect` while the client queue is delivering a reply to the same task. The cancel
/// handler runs inside the cancelling thread's task lock, so it must never wait on the client queue,
/// which resumes the task's continuation and needs that lock. The host is one end of a `socketpair`
/// handed over by the injected opener; no network is involved.
@Suite("Remote host client (cancelling a connect)")
struct RemoteHostConnectCancelTests {
    private static let rounds = 400

    @Test func cancellingAConnectWhileItsHelloReplyIsDeliveredNeverBlocks() async {
        let finished = await Self.within(seconds: 60) {
            for round in 0..<Self.rounds {
                Self.cancelAConnectAsTheHelloReplyArrives(spin: round % 40)
            }
        }
        #expect(finished, "a connect's cancel handler blocked on the client queue while it resumed the same task")
    }

    /// Runs `work` on its own thread so a deadlock fails this test instead of hanging the run.
    private static func within(seconds: Int, _ work: @escaping @Sendable () -> Void) async -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { work(); done.signal() }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: done.wait(timeout: .now() + .seconds(seconds)) == .success)
            }
        }
    }

    /// One connect whose hello is answered by a fake host while another thread cancels it.
    /// `spin` shifts the cancel against the reply so the two meet at different points.
    private static func cancelAConnectAsTheHelloReplyArrives(spin: Int) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { return }
        let (clientEnd, hostEnd) = (pair[0], pair[1])
        // The client reads its end from a dispatch source, as it does a real socket, and must never block on it.
        _ = fcntl(clientEnd, F_SETFL, fcntl(clientEnd, F_GETFL) | O_NONBLOCK)
        let client = RemoteHostClient { _, _ in clientEnd }
        let connect = Task {
            try await client.connect(host: "acme-host.invalid", port: 7433, token: "t", clientName: "c")
        }
        let hello = readLine(from: hostEnd)
        guard let hello, case .hello(let id, _, _, _, _)? = try? NDJSON.decode(RemoteRequest.self, from: hello),
              let reply = try? NDJSON.encode(RemoteReply.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: []))
        else { connect.cancel(); close(hostEnd); return }
        let go = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            go.wait()
            for _ in 0..<spin { sched_yield() }
            connect.cancel()
            cancelled.signal()
        }
        go.signal()
        reply.withUnsafeBytes { _ = write(hostEnd, $0.baseAddress, $0.count) }
        cancelled.wait()
        // The cancelled connect ends one way or another; wait for it so each round is independent.
        let ended = DispatchSemaphore(value: 0)
        Task { _ = await connect.result; ended.signal() }
        ended.wait()
        client.disconnect()
        close(hostEnd)
    }

    private static func readLine(from fd: Int32) -> Data? {
        var line = Data()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A { return line }
            line.append(byte)
        }
        return nil
    }
}
