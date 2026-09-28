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
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    _ = try await task.value
                    fatalError("cancelled connection succeeded")
                } catch {}
                completed.signal()
            }
            if cancelTask { task.cancel() } else { client.disconnect() }
            // Cancellation must finish without first releasing the blocked resolver/open seam.
            precondition(completed.wait(timeout: .now() + 3) == .success, "pending open ignored cancellation")
            release.signal()
            var event = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
            precondition(poll(&event, 1, 3000) == 1)
            var byte: UInt8 = 0
            precondition(Darwin.read(peer, &byte, 1) == 0, "stale hello transmitted")
            close(peer)
        }
        // A deadline owns the same waiter, even when an injected opener never answers.
        let opener = RemoteSocketOpen()
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let timed = Task.detached {
            try await opener.open(host: "fixture", port: 1, timeout: 0.05, override: { _, _ in
                began.signal()
                release.wait()
                throw RemoteHostClientError.disconnected
            })
        }
        precondition(began.wait(timeout: .now() + 3) == .success)
        do { _ = try await timed.value; fatalError("open exceeded its deadline") }
        catch RemoteHostClientError.timeout {} // The opener stays blocked until after the timeout.
        release.signal()
        // Exercise the production nonblocking fd handoff and native async resolver locally.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        precondition(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        precondition(withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0)
        precondition(listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        precondition(withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        } == 0)
        let port = UInt16(bigEndian: address.sin_port)
        for host in ["127.0.0.1", "localhost"] {
            let fd = try await RemoteSocketOpen().open(host: host, port: port, timeout: 3)
            precondition(fcntl(fd, F_GETFL, 0) & O_NONBLOCK != 0)
            precondition(fcntl(fd, F_GETFD, 0) & FD_CLOEXEC != 0)
            let accepted = accept(listener, nil, nil)
            precondition(accepted >= 0)
            close(accepted)
            close(fd)
        }
        print("PASS: pending-open cancellation/deadline, late fd disposal, numeric and async DNS loopback establishment")
    }
}
