import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// Which remote threads each host hints about: the on-screen ordinary threads, capped, sent on change.
@Suite("Remote thread hints")
struct RemoteThreadHintsTests {
    @Test func sendsOnlyChangedCappedOrdinarySetsAndAgainAfterAReconnect() {
        let host = UUID(), other = UUID()
        let coordinator = AgentID()
        let threads = (0..<70).map { _ in AgentID() }
        var hints = RemoteThreadHints()
        let ordinary: (RemoteAgentRef) -> Bool = { $0.agentID != coordinator }
        let live = Set(threads.map { RemoteAgentRef(hostID: host, agentID: $0) } + [RemoteAgentRef(hostID: host, agentID: coordinator)])

        let first = hints.plan(live: live, hosts: [host, other], ordinary: ordinary)
        #expect(first.keys.sorted() == [host], "a host with nothing on screen is not told an empty set")
        #expect(first[host]?.count == RemoteThreadHints.limit)
        #expect(first[host]?.contains(coordinator) == false)
        #expect(hints.plan(live: live, hosts: [host, other], ordinary: ordinary).isEmpty, "unchanged: nothing sent")

        // Every window's threads leaving the screen: the host is told none.
        #expect(hints.plan(live: [], hosts: [host, other], ordinary: ordinary) == [host: []])

        let one: Set = [RemoteAgentRef(hostID: host, agentID: threads[0])]
        #expect(hints.plan(live: one, hosts: [host], ordinary: ordinary) == [host: [threads[0]]])
        hints.forget(host)
        #expect(hints.plan(live: one, hosts: [host], ordinary: ordinary) == [host: [threads[0]]], "a reconnect is told again")
        // A host that is no longer connected is forgotten, and told afresh when it is back.
        #expect(hints.plan(live: one, hosts: [], ordinary: ordinary).isEmpty)
        #expect(hints.sent[host] == nil)
    }
}
