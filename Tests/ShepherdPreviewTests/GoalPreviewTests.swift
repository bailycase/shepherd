import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Goal previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct GoalPreviewTests {
    private static let condition = "Ledger tests pass and go vet is clean, without changing the consumer package."
    private static let states: [(NWGoalState, String)] = [
        (.working, "71k tokens"),
        (.checking, "running go test and go vet"),
        (.met, "104k tokens · 41 tests passed"),
        (.paused, "paused by you · the clock stops"),
        (.needsYou, "the same test failed 3 times in a row"),
    ]

    @Test(arguments: [NWGoalSize.desktop, .touch])
    func everyGoalStateRendersInBothAppearances(_ size: NWGoalSize) async throws {
        let touch = size == .touch
        try await Preview.render(touch ? "goal-states-touch" : "goal-states-desktop",
                                 size: CGSize(width: touch ? 398 : 720, height: touch ? 660 : 560)) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                NWGoalHeaderPill(time: "6m 40s")
                ForEach(Self.states.indices, id: \.self) { index in
                    let (state, meta) = Self.states[index]
                    NWGoalCard(state: state, time: state == .met ? "9m 12s" : "6m 40s", meta: meta,
                               text: Self.condition, size: size, pause: {}, resume: {}, edit: {}, clear: {})
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .background(Color.nw.bgWindow)
        }
    }

    @Test func goalRecordsReadAsQuietBreaksInTheConversation() async throws {
        let presentation = NativeTurnPresentation(items: [
            .goalRecord(id: "set", text: "Goal set · " + Self.condition),
            .prose(id: "work", text: "I fixed the ledger rounding and reran the checks.",
                   blocks: [.paragraph("I fixed the ledger rounding and reran the checks.")], openFence: false),
            .goalRecord(id: "check", text: "Goal check · Not yet: one ledger test still fails."),
            .prose(id: "retry", text: "The final case now passes.",
                   blocks: [.paragraph("The final case now passes.")], openFence: false),
            .goalRecord(id: "met", text: "Goal met · 41 tests passed and go vet is clean."),
        ], changes: nil, toolCalls: 0, copyText: "", endedAt: nil)
        try await Preview.render("goal-thread-records", size: CGSize(width: 720, height: 360)) {
            AgentTurn(presentation: presentation, live: false, footer: false)
                .padding(NW.Space.xl)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    @Test func theGoalStaysVisibleWhileAQuestionReplacesTheComposer() async throws {
        var snapshot = Threads.question
        snapshot.goal = NativeGoal(id: "00000000-0000-0000-0000-000000000001", revision: 1, text: Self.condition, state: .needsYou,
                                   elapsedSeconds: 400, tokensUsed: 71000, timeLimitSeconds: nil, tokenLimit: nil,
                                   reason: "Choose how to handle the failing test.", evidence: nil)
        snapshot.supportedActions.append("goal")
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render("goal-question-dock", size: CGSize(width: 1000, height: 760), ready: {
            fixture.store.ready && fixture.store.goal != nil && !fixture.store.dialogs.isEmpty
        }) {
            fixture.thread(title: "Fix the ledger")
        }
    }

    /// The actual app dock: goal first, the waiting subagent still visible, and the queue folded.
    @Test func aGoalSharesTheComposerDockWithSubagentsAndQueuedMessages() async throws {
        var snapshot = Threads.subagents(Threads.liveRuns, running: true)
        snapshot.goal = NativeGoal(id: "00000000-0000-0000-0000-000000000002", revision: 1, text: Self.condition, state: .working,
                                   elapsedSeconds: 400, tokensUsed: 71000, timeLimitSeconds: nil, tokenLimit: nil,
                                   reason: nil, evidence: nil)
        snapshot.supportedActions.append("goal")
        let fixture = QueueThreadFixture(snapshot, queue: QueueFixture.messages(["Then open a draft PR."]))
        defer { fixture.store.stop() }
        try await Preview.render("goal-composer-dock", size: CGSize(width: 1000, height: 760), ready: {
            fixture.store.ready && fixture.store.goal != nil && fixture.store.tray != nil
                && fixture.state.isVisible && fixture.state.collapsed
        }) {
            fixture.thread(title: "Fix the ledger", inspect: true)
        }
    }
}
