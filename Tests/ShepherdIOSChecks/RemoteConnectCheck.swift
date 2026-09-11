import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@main
struct RemoteConnectCheck {
    static func main() async throws {
        for cancelTask in [true, false] {
            var pair: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
            let opened = pair[0]
            let peer = pair[1]
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let client = RemoteHostClient(socketOpen: { _, _ in
                started.signal()
                release.wait()
                return opened
            })
            let task = Task.detached {
                try await client.connect(host: "fixture", port: 1, token: "must-not-be-sent", clientName: "check")
            }
            precondition(started.wait(timeout: .now() + 3) == .success)
            if cancelTask { task.cancel() } else { client.disconnect() }
            release.signal()
            do {
                _ = try await task.value
                fatalError("cancelled connection succeeded")
            } catch {}
            var event = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            precondition(poll(&event, 1, 3000) == 1)
            var byte: UInt8 = 0
            precondition(Darwin.read(peer, &byte, 1) == 0, "stale hello transmitted")
            close(peer)
        }
        print("PASS: cancellation and disconnect during pending socket open close the returned descriptor without transmitting hello")
    }
}
