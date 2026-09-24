import Darwin
import Foundation
import Testing
import ShepherdCore
@testable import ShepherdSessions
import ShepherdTestSupport

/// A terminal pane's shell must not inherit the app's other descriptors: a pipe it held open
/// kept an unrelated reader (git, a login-shell probe) waiting for EOF until the shell exited.
@Suite("PTY descriptors", .integrationTimeLimit)
struct PTYDescriptorTests {
    @Test func aShellDoesNotHoldAnotherProcesssPipeOpen() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0) // no CLOEXEC: exactly what a leaked descriptor looks like
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { close(readEnd) }

        let session = try await h.shell("sleep 30")
        defer { h.server.killSession(session.id) }
        close(writeEnd)

        // With the write end closed here, the reader sees EOF at once unless the shell kept a copy.
        let flags = fcntl(readEnd, F_GETFL)
        _ = fcntl(readEnd, F_SETFL, flags | O_NONBLOCK)
        var byte: UInt8 = 0
        try await eventually("EOF on the pipe", timeout: .seconds(3)) { read(readEnd, &byte, 1) == 0 }
    }
}
