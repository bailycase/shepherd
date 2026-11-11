import Foundation
import ShepherdCore
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// Which of the threads shown from a paired host are pages of the remote deck, and which shows.
@Suite("Remote deck pages")
struct RemoteDeckPagesTests {
    private static let space = Fixture.space("acme-web")

    /// A host with `count` ordinary threads, and the refs to them.
    private struct Hosted {
        let hostID = UUID()
        var state: ShepherdState
        let refs: [RemoteAgentRef]

        init(_ count: Int = 3) {
            let made = (0..<count).map { Fixture.agent("thread \($0)", in: RemoteDeckPagesTests.space, order: $0) }
            state = ShepherdState(spaces: [RemoteDeckPagesTests.space], tabs: made.map(\.tab), agents: made.map(\.agent))
            let host = hostID
            refs = made.map { RemoteAgentRef(hostID: host, agentID: $0.agent.id) }
        }

        var states: [UUID: ShepherdState] { [hostID: state] }

        mutating func edit(_ ref: RemoteAgentRef, _ change: (inout Agent) -> Void) {
            if let index = state.agents.firstIndex(where: { $0.id == ref.agentID }) { change(&state.agents[index]) }
        }
    }

    @Test func anOrdinaryThreadShownOnceStaysAPage() {
        let host = Hosted()
        let (a, b) = (host.refs[0], host.refs[1])

        let first = RemoteDeckPages.pages(shown: [a], selected: a, inspecting: nil, states: host.states)
        #expect(first == .init(pages: [a], visible: a))

        // Another thread selected: the first is still a page, and no longer the visible one.
        let second = RemoteDeckPages.pages(shown: [a, b], selected: b, inspecting: nil, states: host.states)
        #expect(second == .init(pages: [a, b], visible: b))

        // Nothing remote selected (a local thread is): every page rests.
        let none = RemoteDeckPages.pages(shown: [a, b], selected: nil, inspecting: nil, states: host.states)
        #expect(none == .init(pages: [a, b], visible: nil))
    }

    @Test func theSelectedPageIsTheVisibleOneUnlessItsUtilityTabIsOpen() {
        let host = Hosted()
        let (a, b) = (host.refs[0], host.refs[1])
        func plan(inspecting: RemoteAgentRef?) -> RemoteDeckPages.Plan {
            RemoteDeckPages.pages(shown: [a, b], selected: a, inspecting: inspecting, states: host.states)
        }

        #expect(plan(inspecting: nil).visible == a)
        // The host's utility tab for the selected thread draws over the deck: its page stays, hidden.
        #expect(plan(inspecting: a) == .init(pages: [a, b], visible: nil))
        // A utility tab of another thread leaves the selected page on screen.
        #expect(plan(inspecting: b).visible == a)
    }

    @Test func aDesignAgentACoordinatorOrAProjectWorkerIsNeverAPage() {
        var host = Hosted(4)
        let (ordinary, design, coordinator, worker) = (host.refs[0], host.refs[1], host.refs[2], host.refs[3])
        let drawn = Design(name: "Landing hero", agentID: design.agentID, createdAt: 1)
        host.state.designs = [drawn]
        host.edit(design) { $0.designID = drawn.id }
        host.edit(coordinator) { $0.coordinatorFor = ProjectID() }
        host.edit(worker) { $0.executionFor = ProjectExecutionKey(ownerID: UUID(), projectID: ProjectID(), operationID: UUID()) }

        for ref in host.refs {
            let plan = RemoteDeckPages.pages(shown: host.refs, selected: ref, inspecting: nil, states: host.states)
            #expect(plan.pages == [ordinary])
            #expect(plan.visible == (ref == ordinary ? ordinary : nil), "selecting \(ref.agentID) shows a page only for the thread")
        }
    }

    @Test func anAgentTheHostNoLongerHasHasNoPage() {
        var host = Hosted()
        let (a, b) = (host.refs[0], host.refs[1])
        host.state.agents.removeAll { $0.id == a.agentID }
        #expect(RemoteDeckPages.pages(shown: [a, b], selected: a, inspecting: nil, states: host.states) == .init(pages: [b], visible: nil))

        // A thread whose layout the host dropped has nothing to draw.
        let tab = host.state.agents.first { $0.id == b.agentID }!.tabID
        host.state.tabs.removeAll { $0.id == tab }
        #expect(RemoteDeckPages.pages(shown: [a, b], selected: b, inspecting: nil, states: host.states) == .init())

        // A removed host has no state at all.
        #expect(RemoteDeckPages.pages(shown: [b], selected: b, inspecting: nil, states: [:]) == .init())
    }

    @Test func aRefNeverShownIsNoPage() {
        let host = Hosted()
        let (a, b) = (host.refs[0], host.refs[1])
        // Selected, yet not among the refs shown this session (the selection's own record is what
        // lists it): the overlay draws it.
        let plan = RemoteDeckPages.pages(shown: [a], selected: b, inspecting: nil, states: host.states)
        #expect(plan == .init(pages: [a], visible: nil))
        #expect(RemoteDeckPages.pages(shown: [], selected: a, inspecting: nil, states: host.states) == .init())
    }

    @Test(arguments: [[0, 1, 2], [2, 0, 1], [1, 2, 0]])
    func pagesKeepTheOrderTheyWereFirstShownIn(order: [Int]) {
        let host = Hosted()
        let shown = order.map { host.refs[$0] }
        let plan = RemoteDeckPages.pages(shown: shown, selected: shown.last, inspecting: nil, states: host.states)
        #expect(plan.pages == shown)
        #expect(plan.visible == shown.last)
    }
}
