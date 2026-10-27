import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A page's ports on a viewer that holds them only while it can use them (the iOS client): the
/// decisions that bind nothing. Claims that listen are in `BrowserPortForwarderTests`.
@Suite("Browser page ports")
struct BrowserPagePortsTests {
    private func make() -> (BrowserPagePorts, BrowserPortForwarder) {
        let forwarder = BrowserPortForwarder()
        let ports = BrowserPagePorts(forwarder: forwarder, owner: .init(id: "host/agent", hostName: "macbook"),
                                     agent: AgentID(rawValue: "agent"), slot: BrowserTunnelHubSlot())
        return (ports, forwarder)
    }

    @Test func aPageOnTheWebNeedsNoForwardEvenWhileSuspended() throws {
        let (ports, _) = make()
        #expect(ports.forward(try #require(URL(string: "https://example.com/docs"))) == nil)
        #expect(ports.ports.isEmpty)
    }

    /// While suspended nothing listens, so a loopback page must not load: the device's own program
    /// on that port would answer in the host's place.
    @Test func aSuspendedPageRefusesTheHostsPortAndHoldsNothing() throws {
        let (ports, forwarder) = make()
        #expect(ports.forward(try #require(URL(string: "http://localhost:5173/"))) == .failed(port: 5173, errno: ENOTCONN))
        #expect(ports.ports.isEmpty)
        #expect(forwarder.ports(of: ports.owner).isEmpty)
    }

    @Test func aRefusedPortIsNotRememberedForResume() throws {
        let (ports, _) = make()
        ports.resume()
        #expect(ports.forward(try #require(URL(string: "http://localhost/"))) == .privileged(port: 80))
        #expect(ports.forward(try #require(URL(string: "http://127.0.0.1:0/"))) == .invalid(port: 0))
        #expect(ports.ports.isEmpty)
        ports.suspend()
        #expect(ports.resume().isEmpty)
    }

    @Test func aRefusalNamesTheDeviceThePageIsOn() {
        let refusal = BrowserPortForwarder.Refusal.inUse(port: 5173)
        #expect(refusal.message(hostName: "macbook", here: "this iPhone").contains("in use on this iPhone"))
        #expect(refusal.message(hostName: "macbook").contains("in use on this Mac"))
        #expect(BrowserPortForwarder.Refusal.privileged(port: 80).message(hostName: "macbook", here: "this iPad").contains("this iPad doesn’t"))
    }
}
