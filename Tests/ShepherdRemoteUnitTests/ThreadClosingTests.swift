import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Closing a thread from a client before the host answers.
@Suite("Thread closing")
struct ThreadClosingTests {
    static func agent(_ id: String) -> Agent {
        Agent(id: AgentID(rawValue: id), name: id, spaceID: SpaceID(rawValue: "s"), tabID: TabID(rawValue: "t-" + id))
    }

    @Test func closingThreadsLeaveTheListsButNothingElse() {
        let state = ShepherdState(spaces: [Space(id: SpaceID(rawValue: "s"), name: "S", path: "/s")], agents: [Self.agent("a"), Self.agent("b")])
        let hidden = state.hiding([AgentID(rawValue: "a")])
        #expect(hidden.agents.map(\.id.rawValue) == ["b"])
        #expect(hidden.spaces == state.spaces)
        #expect(state.hiding([]) == state)
        #expect(state.hiding([AgentID(rawValue: "other")]) == state)
    }

    @Test func aHostRefusalIsDefiniteAndAnythingElseIsUnknown() {
        #expect(ThreadClosing.outcome(of: RemoteHostClientError.rejected(code: "x", message: "Not now")) == .refused("Not now"))
        #expect(ThreadClosing.outcome(of: ThreadClosing.Refusal("Checkout changed")) == .refused("Checkout changed"))
        #expect(ThreadClosing.outcome(of: ThreadClosing.Unanswered("Don’t delete again")) == .unknown("Don’t delete again"))
        for error in [RemoteHostClientError.timeout, .disconnected, .outcomeUnknown(message: "m")] {
            guard case .unknown(let message) = ThreadClosing.outcome(of: error) else {
                Issue.record("\(error) is not a refusal")
                continue
            }
            #expect(message.contains("Check the thread"))
        }
    }

    @Test func aRefusalRestoresOnlyAPlaceNobodyHasLeft() {
        let rollback = ThreadClosing.Rollback(before: ["home", "thread"], after: ["home"])
        #expect(rollback.restoring(from: ["home"]) == ["home", "thread"])
        #expect(rollback.restoring(from: ["home", "other"]) == nil, "later navigation is kept")
        #expect(rollback.restoring(from: []) == nil)
    }
}
