import Darwin
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Remote's Listener row: the host binds Serve this Mac, and the row says the port it
/// serves on, or why it couldn't.
@Suite("Remote listener row", .mainActorExclusive)
@MainActor
struct RemoteListenerRowTests {
    @Test(arguments: [false, true])
    func theRowShowsTheHostsPortOrWhyItCouldNotBind(busy: Bool) async throws {
        let (fd, port) = try Self.listeningSocket()
        // A free port: one the system just handed out and nothing holds now.
        if !busy { close(fd) }
        defer { if busy { close(fd) } }
        let app = try AppHarness()
        defer { app.stop() }
        app.settings.remoteListenerEnabled = true
        app.settings.remoteListenerPort = Int(port)
        let vm = try await app.start()

        await vm.refreshRemoteListener()

        if busy {
            #expect(vm.remoteListenerBoundPort == nil)
            #expect(vm.remoteListenerProblem == "Couldn't start: port \(port) is already in use.")
            #expect(vm.remoteListenerProblemDetail?.isEmpty == false)
        } else {
            #expect(vm.remoteListenerBoundPort == port && vm.remoteListenerProblem == nil)
            #expect(vm.remoteListenerStatus.contains("port \(port)"))
        }
    }

    /// A TCP socket listening on all interfaces at a port the system chose.
    private static func listeningSocket() throws -> (Int32, UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return (fd, UInt16(bigEndian: addr.sin_port))
    }
}
