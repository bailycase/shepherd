import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Cancelling a `connect` while the host's reply is being delivered. Cancellation runs the handler with the
/// task's status lock held, and the client's queue takes that lock to resume the awaiting task, so a handler
/// that waits on the queue deadlocks the two (a host removed in the middle of connecting hung the app).
@Suite("Remote host client cancellation")
struct RemoteHostClientCancelTests {
    /// A host on a socket pair that answers `hello` and `stateFetch` at once, so replies are always in flight.
    private final class Echo: @unchecked Sendable {
        let client: Int32
        private let host: Int32

        init() {
            var pair: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            client = pair[0]
            host = pair[1]
            // The client reads without blocking, as the real opener's sockets do.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
            // A cancelled client closes its end mid-write: an error to read, not a signal.
            var on: Int32 = 1
            for fd in pair { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
            let host = host
            Thread.detachNewThread {
                var lines = LineBuffer()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = Darwin.read(host, &chunk, chunk.count)
                    guard count > 0, let found = try? lines.append(Data(chunk[0..<count])) else { break }
                    for line in found {
                        let reply: RemoteReply
                        switch try? NDJSON.decode(RemoteRequest.self, from: line) {
                        case .hello(let id, _, _, _, _)?:
                            reply = .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [])
                        case .stateFetch(let id)?:
                            reply = .state(id: id, state: ShepherdState())
                        default: continue
                        }
                        guard let data = try? NDJSON.encode(reply) else { continue }
                        _ = data.withUnsafeBytes { Darwin.write(host, $0.baseAddress, data.count) }
                    }
                }
                close(host)
            }
        }
    }

    @Test(.timeLimit(.minutes(2))) func cancellingAConnectWhileItsRepliesArriveNeverBlocks() async {
        for round in 0..<300 {
            let echo = Echo()
            let opened = echo.client
            let client = RemoteHostClient(socketOpen: { _, _ in opened })
            let task = Task.detached { try await client.connect(host: "fixture", port: 1, token: "t", clientName: "check") }
            // From before the socket opens to after the handshake: each round cancels a little later.
            try? await Task.sleep(for: .microseconds(round % 30 * 25))
            let cancelled = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { task.cancel(); cancelled.signal() }
            let returned = await withCheckedContinuation { continuation in
                DispatchQueue.global().async { continuation.resume(returning: cancelled.wait(timeout: .now() + 10) == .success) }
            }
            guard returned else {
                Issue.record("cancel blocked in round \(round): the handler waited on the client queue")
                return
            }
            // Whichever won, the connect ends and the client is left closed.
            _ = await task.result
            client.disconnect()
        }
    }
}
