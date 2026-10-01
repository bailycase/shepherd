import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@MainActor
@Suite("Goal store controls")
struct GoalStoreTests {
    @Test func pauseCanRunDuringWorkAndCarriesTheDisplayedGoalFence() async {
        let goal = NativeGoal(id: "00000000-0000-0000-0000-000000000001", revision: 4, text: "Tests pass", state: .checking)
        let value = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: true,
                                         supportedActions: ["goal"], dialogsSupported: false, dialogs: [], messages: [],
                                         provisional: [], clipped: false, runtime: "rpc", goal: goal)
        let host = FakeHost(value)
        host.action = { request in
            guard case .goal(_, _, let id, _, _, _) = request else { return .failure(code: "invalid", message: "wrong action") }
            host.snapshot.goal?.state = .paused
            return .accepted(operationID: id)
        }
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        #expect(store.goal == goal)
        #expect(await store.goalAction(.pause))
        guard case .goal(let session, let generation, _, let action, let id, let revision) = host.actions.last else {
            Issue.record("No goal command reached the host"); return
        }
        #expect(session == "s" && generation == "g")
        #expect(action == .pause && id == goal.id && revision == 4)
        #expect(store.goal?.state == .paused)
    }

    @Test func aRejectedEditKeepsTheDraftOpen() async {
        let value = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false,
                                         supportedActions: ["goal"], dialogsSupported: false, dialogs: [], messages: [],
                                         provisional: [], clipped: false,
                                         goal: NativeGoal(id: "00000000-0000-0000-0000-000000000001", revision: 1, text: "Tests pass", state: .paused))
        let host = FakeHost(value)
        host.action = { _ in .failure(code: "goal_rejected", message: "Goal changed; refresh it.") }
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        #expect(!(await store.goalAction(.edit(text: "Tests and lint pass"))))
        #expect(store.goal?.text == "Tests pass")
        #expect(store.notice != nil)
    }

    @Test func goalRecordsAreDividersNotWorkerProse() {
        let message = NativeThreadMessage(entryID: "check", role: "custom", blocks: [.init(kind: .text, text: "Goal check: working. Run tests.")], customType: "shepherd.goal.check")
        let presentation = nativeTurnPresentation([message], live: false)
        guard case .goalRecord(_, let text) = presentation.items.first else { Issue.record("Missing goal divider"); return }
        #expect(text == "Goal check: working. Run tests.")
        #expect(presentation.copyText.isEmpty)
    }

    @Test func oldHostsHideGoalsAndRefuseTheirControls() {
        let request = NativeThreadRequest.goal(expectedSessionID: "s", generation: "g", operationID: UUID(), action: .resume)
        #expect(RemoteHostClient.missingCapability(request, capabilities: []) != nil)
        #expect(RemoteHostClient.missingCapability(request, capabilities: [RemoteProtocol.nativeGoalCapability]) == nil)
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false,
                                            supportedActions: ["send", "goal"], dialogsSupported: false, dialogs: [], messages: [],
                                            provisional: [], clipped: false)
        guard case .snapshot(let masked) = RemoteHostClient.incoming(.snapshot(value: snapshot), capabilities: []) else { return }
        #expect(!masked.supportedActions.contains("goal"))
    }
}
