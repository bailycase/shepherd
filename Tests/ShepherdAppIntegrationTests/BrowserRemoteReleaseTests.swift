import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A remote page on the Mac that is closed and made again at once must get its port back: nothing
/// there retries a claim, so closing the page has to wait for the old listening socket to close.
@Suite("Remote browser release", .mainActorExclusive)
@MainActor
struct BrowserRemoteReleaseTests {
    @Test func aPageMadeAgainAtOnceGetsItsPortBackWhileTheForwardingQueueRunsLate() async throws {
        let queue = DispatchQueue(label: "test.browser.forward")
        let forwarder = BrowserPortForwarder(queue: queue)
        let ref = RemoteAgentRef(hostID: UUID(), agentID: AgentID(rawValue: "agent"))
        let page = BrowserRemote(ref: ref, hosts: nil, ports: forwarder)
        let server = try LoopbackServer { _ in }
        let port = Int(server.port)
        server.stop()
        let url = try #require(URL(string: "http://localhost:\(port)/"))
        #expect(page.forward(url) == nil)

        // Hold the socket's close until the page's release is waiting for it; the gate opens when the
        // waiter shows, or when the test cancels it because release did not wait.
        queue.suspend()
        let gate = Task.detached {
            while forwarder.closeWaiterCount(of: port) == 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
            queue.resume()
        }
        page.release()
        let again = BrowserRemote(ref: ref, hosts: nil, ports: forwarder)
        let refusal = again.forward(url)
        gate.cancel()
        await gate.value
        #expect(refusal == nil, "the old socket was closed by the time the page was gone")
        again.release()
    }
}
