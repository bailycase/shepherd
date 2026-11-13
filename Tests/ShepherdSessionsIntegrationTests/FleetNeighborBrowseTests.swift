import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import dnssd

/// Add a Mac where `_shepherd._tcp` does not arrive: a scratch Mac that announces only a fake
/// `_ssh._tcp` record (the way a router's mDNS reflector passes Apple's own types) is found by
/// the browser, through the real mDNS responder on this machine.
@Suite("Fleet: find a Mac by its _ssh record", .integrationTimeLimit)
struct FleetNeighborBrowseTests {
    /// Registers `_ssh._tcp` (and nothing else) for this machine: its address is what the browser resolves.
    final class FakeSSH: @unchecked Sendable {
        private var ref: DNSServiceRef?

        init(port: UInt16) throws {
            var created: DNSServiceRef?
            let status = DNSServiceRegister(&created, 0, 0, "acme-ssh-\(UUID().uuidString.prefix(8))", "_ssh._tcp", nil, nil,
                                            port.bigEndian, 0, nil, nil, nil)
            guard status == kDNSServiceErr_NoError, let created else { throw Failed(status: status) }
            ref = created
            // Processing the registration's replies is not needed: the responder announces it regardless.
            DNSServiceSetDispatchQueue(created, DispatchQueue(label: "test.fake-ssh"))
        }

        struct Failed: Error { let status: Int32 }

        func stop() {
            if let ref { DNSServiceRefDeallocate(ref) }
            ref = nil
        }
    }

    /// A port nothing listens on.
    static func closedPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                  sin_addr: in_addr(s_addr: UInt32(INADDR_LOOPBACK).bigEndian), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        try #require(bound == 0)
        return UInt16(bigEndian: address.sin_port)
    }

    @Test @MainActor func aMacThatAnnouncesOnlyAnSSHRecordIsFoundAndListedLikeAnyOther() async throws {
        let mini = try await FleetPairingTests.Mac("Mac mini")
        defer { mini.stop() }
        let id = try #require(try await mini.read().hostID)
        let ssh = try FakeSSH(port: mini.port)
        defer { ssh.stop() }

        let browser = FleetBrowser(shepherdType: nil, neighborTypes: ["_ssh._tcp"], probePorts: [mini.port])
        let list = Locked<[FoundMac]>([])
        browser.start { macs in list.withValue { $0 = macs } }
        defer { browser.stop() }
        try await eventuallyOnMain("the Mac behind the _ssh record to be listed") {
            list.current.contains { $0.idHash == FleetProtocol.advertisedIDHash(id) }
        }
        let found = try #require(list.current.first { $0.idHash == FleetProtocol.advertisedIDHash(id) })
        #expect(found.name == "Mac mini" && found.port == mini.port)
        #expect(found.address.map { inet_addr($0) != INADDR_NONE } == true, "an IPv4 address the host can dial")
        #expect(list.current.filter { $0.idHash == FleetProtocol.advertisedIDHash(id) }.count == 1, "once, however many records resolve to it")
    }

    @Test @MainActor func aDeviceNothingAnswersOnIsNeverListed() async throws {
        let ssh = try FakeSSH(port: 22)
        defer { ssh.stop() }
        let closed = try Self.closedPort()
        let probed = Locked<[String]>([])
        let browser = FleetBrowser(shepherdType: nil, neighborTypes: ["_ssh._tcp"], probePorts: [closed], probe: { host, port in
            let answer = await RemoteHostClient.fleetProbe(host: host, port: port)
            probed.withValue { $0.append(host) }
            return answer
        })
        let list = Locked<[FoundMac]>([])
        browser.start { macs in list.withValue { $0 = macs } }
        defer { browser.stop() }
        try await eventuallyOnMain("this machine's _ssh record to be probed") { !probed.current.isEmpty }
        #expect(list.current.isEmpty, "a device that does not answer never shows")
    }
}
