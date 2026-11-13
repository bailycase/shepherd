import Foundation
import Testing
import ShepherdCore

/// The dispatch record (`dispatches.json`) and the thread's `dispatchedFrom` keep decoding from older
/// files, and say what counts against the cap.
@Suite("Fleet dispatch record")
struct FleetDispatchRecordTests {
    static func record(_ state: FleetDispatchState = .running) -> FleetDispatchRecord {
        FleetDispatchRecord(id: UUID(), parentAgentID: AgentID(), parentHostID: UUID(), parentHostName: "MacBook Pro", parentTitle: "Ship it",
                            targetHostID: UUID(), targetHostName: "Mac mini", state: state, title: "Fix flaky test", task: "Fix it.",
                            repoKey: "github.com/acme/web", commitSHA: String(repeating: "a", count: 40), branch: "fleet/fix-flaky-test",
                            reasonCodes: [FleetPlacementReason(.mostRoom, ratio: 3.4)], createdAt: 1_000)
    }

    @Test func aRecordRoundTripsWithEveryField() throws {
        var record = Self.record(.delivering)
        record.resultText = "Done."
        record.resultBranchFacts = FleetBranchFacts(branch: "fleet/fix-flaky-test", head: "abc", ahead: 2, pushed: true, filesChanged: 3, insertions: 10, deletions: 2)
        record.failure = FleetDispatchCode.refused
        record.failureDetail = "newer_build"
        record.activity = "working"
        record.subdir = "apps/web"
        record.start = FleetThreadStart(place: .existingBranch, base: "origin/main", branch: "feat/orders")
        record.without = ["bearcli"]
        let decoded = try JSONDecoder().decode(FleetDispatchRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }

    @Test func aThreadStartDecodesWithDefaultsAndIsWrittenOnlyWhenSet() throws {
        let plain = Self.record(.running)
        let written = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(plain.start == nil && !written.contains("\"start\""))
        let start = try JSONDecoder().decode(FleetThreadStart.self, from: Data("{}".utf8))
        #expect(start == FleetThreadStart(place: .newWorktree), "nothing said is a new worktree from the base")
        let unknown = try JSONDecoder().decode(FleetThreadStart.self, from: Data(#"{"place":"a-place-from-a-newer-build","base":"origin/main"}"#.utf8))
        #expect(unknown.place == .newWorktree && unknown.base == "origin/main")
    }

    @Test func anOlderOrBareFileDecodesWithDefaults() throws {
        let id = UUID(), host = UUID()
        let json = #"{"id":"\#(id.uuidString)","parentHostID":"\#(host.uuidString)","state":"a-state-from-a-newer-build"}"#
        let record = try JSONDecoder().decode(FleetDispatchRecord.self, from: Data(json.utf8))
        #expect(record.id == id && record.kind == .agentDispatch && record.reasonCodes.isEmpty && record.title.isEmpty)
        #expect(record.state == .failed, "a state this build doesn't know is never resumed")
        #expect(record.without.isEmpty, "a record from before a Mac could start a thread without an MCP server names none")
        #expect(!String(decoding: try JSONEncoder().encode(Self.record()), as: UTF8.self).contains("\"without\""), "written only when set")
    }

    @Test func onlyWorkInTheAirOrOnAMacCountsAgainstTheCap() {
        let counted = FleetDispatchState.allCases.filter(\.countsAgainstCap)
        #expect(Set(counted) == [.placing, .waitingRoom, .waitingWake, .preparing, .running])
        #expect(Set(FleetDispatchState.allCases.filter { !$0.isLive }) == [.done, .failed, .cancelled])
    }

    @Test func theLogDropsTheTextOfTheTaskAndTheResult() {
        var record = Self.record()
        record.resultText = "secret-looking text"
        #expect(record.summary.task.isEmpty && record.summary.resultText == nil && record.summary.title == record.title)
    }

    @Test func dispatchedFromIsWrittenOnlyWhenSetAndDecodesWithoutIt() throws {
        var agent = Agent(name: "Fix flaky test", spaceID: SpaceID(), tabID: TabID())
        let plain = String(decoding: try JSONEncoder().encode(agent), as: UTF8.self)
        #expect(!plain.contains("dispatchedFrom"))
        #expect(try JSONDecoder().decode(Agent.self, from: Data(plain.utf8)).dispatchedFrom == nil)
        let from = DispatchedFrom(hostID: UUID(), hostName: "MacBook Pro", agentID: AgentID(), agentTitle: "Ship it", dispatchID: UUID(), at: 5)
        agent.dispatchedFrom = from
        #expect(try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent)).dispatchedFrom == from)
    }
}
