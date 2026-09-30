import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
@testable import ShepherdRemote

/// The hub's decisions over a connection that is only a list of frames: what it opens, what it
/// answers a probe with, what it does when the host refuses or the connection goes. No sockets:
/// the tunnels that carry bytes are in the integration tests.
@Suite("Browser tunnel hub")
struct BrowserTunnelHubTests {
    /// A link that hands over what the hub sends, in order, and says whether tunnels are available.
    final class FakeLink: BrowserTunnelLink, @unchecked Sendable {
        let available = Locked(true)
        private let stream: AsyncStream<BrowserTunnelFrame>
        private let continuation: AsyncStream<BrowserTunnelFrame>.Continuation
        private var iterator: AsyncStream<BrowserTunnelFrame>.Iterator
        /// Every frame sent, in order.
        let sent = Locked<[BrowserTunnelFrame]>([])

        init() {
            (stream, continuation) = AsyncStream.makeStream()
            iterator = stream.makeAsyncIterator()
        }

        func sendTunnel(_ frame: BrowserTunnelFrame) {
            sent.withValue { $0.append(frame) }
            continuation.yield(frame)
        }

        var tunnelBacklogBytes: Int { 0 }
        var tunnelsAvailable: Bool { available.current }

        /// The next frame the hub sends.
        func next() async -> BrowserTunnelFrame? { await iterator.next() }
    }

    let queue = DispatchQueue(label: "test.hub")
    let agent = AgentID(rawValue: "agent")

    private func make() -> (BrowserTunnelHub, FakeLink) {
        let link = FakeLink()
        let hub = BrowserTunnelHub(queue: queue)
        hub.link = link
        return (hub, link)
    }

    @Test func aProbeOpensATunnelForTheAgentAndPort() async {
        let (hub, link) = make()
        async let result = hub.probe(agentID: agent, port: 5173)
        #expect(await link.next() == .open(tunnel: 1, agentID: agent, port: 5173))
        queue.async { hub.receive(.opened(tunnel: 1)) }
        #expect(await result == .reachable)
        // It closes the tunnel it opened: a probe holds nothing.
        #expect(await link.next() == .close(tunnel: 1, code: nil))
    }

    @Test func aProbeReportsWhyAHostRefused() async {
        let (hub, link) = make()
        async let result = hub.probe(agentID: agent, port: 4000)
        _ = await link.next()
        queue.async { hub.receive(.close(tunnel: 1, code: BrowserTunnelCode.refused)) }
        #expect(await result == .failed(BrowserTunnelCode.refused))
    }

    @Test func aProbeWithNoConnectionIsUnavailableAndSendsNothing() async {
        let (hub, link) = make()
        link.available.withValue { $0 = false }
        #expect(await hub.probe(agentID: agent, port: 5173) == .unavailable)
        #expect(link.sent.current.isEmpty)
    }

    @Test func aProbeWithNoLinkIsUnavailable() async {
        let hub = BrowserTunnelHub(queue: queue)
        #expect(await hub.probe(agentID: agent, port: 5173) == .unavailable)
    }

    @Test func losingTheConnectionEndsAWaitingProbe() async {
        let (hub, link) = make()
        async let result = hub.probe(agentID: agent, port: 5173)
        _ = await link.next()
        queue.async { hub.connectionLost() }
        #expect(await result == .failed(BrowserTunnelCode.aborted))
    }

    @Test func eachTunnelGetsANewNumberAndNoNumberIsReused() async {
        let (hub, link) = make()
        var numbers: [Int] = []
        for port in [3000, 3001, 3002] {
            async let result = hub.probe(agentID: agent, port: port)
            if let frame = await link.next() {
                numbers.append(frame.tunnel)
                queue.async { hub.receive(.close(tunnel: frame.tunnel, code: BrowserTunnelCode.refused)) }
            }
            _ = await result
        }
        #expect(numbers == [1, 2, 3])
    }

    @Test func aFrameForATunnelTheHubDoesNotHaveIsIgnored() async {
        let (hub, link) = make()
        queue.async {
            hub.receive(.data(tunnel: 9, bytes: Data([1])))
            hub.receive(.credit(tunnel: 9, bytes: 100))
            hub.receive(.finish(tunnel: 9))
            hub.receive(.opened(tunnel: 9))
            hub.receive(.close(tunnel: 9, code: nil))
        }
        // A probe afterwards behaves as ever: numbering is untouched, and nothing was sent back.
        async let result = hub.probe(agentID: agent, port: 1)
        #expect(await link.next() == .open(tunnel: 1, agentID: agent, port: 1))
        queue.async { hub.connectionLost() }
        _ = await result
    }

    @Test func theHubKeepsAsManyTunnelsAsTheHostAllows() {
        #expect(BrowserTunnelHub.maxTunnels == BrowserTunnelLimits.perClient)
        #expect(BrowserTunnelHub.maxTunnels == 64)
    }
}
