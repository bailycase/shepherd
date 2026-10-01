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
    /// Generated and checked by goal.test.mjs from the extension's published widgets/messages.
    private struct Runtime: Decodable {
        struct Record: Decodable { let content: String }
        let goals: [NativeGoal]
        let records: [Record]
    }

    private static func runtime() throws -> Runtime {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/goal-runtime-fixtures.json")
        return try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: path))
    }

    @Test(arguments: [NWGoalSize.desktop, .touch])
    func everyPublishedGoalStateRendersInBothAppearances(_ size: NWGoalSize) async throws {
        let goals = try Self.runtime().goals
        let touch = size == .touch
        try await Preview.render(touch ? "goal-states-touch" : "goal-states-desktop",
                                 size: CGSize(width: touch ? 398 : 720, height: touch ? 660 : 560)) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                ForEach(goals, id: \.state) { goal in
                    NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text,
                               size: size, pause: {}, resume: {}, edit: {}, clear: {})
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .background(Color.nw.bgWindow)
        }
    }

    @Test func publishedRecordsKeepTheirEvidenceBehindDisclosure() async throws {
        let records = try Self.runtime().records
        let presentation = NativeTurnPresentation(items: records.enumerated().map { index, record in
            .goalRecord(id: "record-\(index)", text: record.content)
        }, changes: nil, toolCalls: 0, copyText: "", endedAt: nil)
        try await Preview.render("goal-thread-records", size: CGSize(width: 720, height: 440)) {
            AgentTurn(presentation: presentation, live: false, footer: false)
                .padding(NW.Space.xl)
                .frame(width: 720, height: 440, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: [NWGoalSize.desktop, .touch])
    func aLongConditionHasPaddingAndGrowsAtTextScaleOnePointFive(_ size: NWGoalSize) async throws {
        let goal = try #require(Self.runtime().goals.first)
        let saved = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = saved }
        ThemeStore.shared.textScale = 1.5
        let touch = size == .touch
        try await Preview.render(touch ? "goal-long-scale15-touch" : "goal-long-scale15-desktop",
                                 size: CGSize(width: touch ? 398 : 1000, height: touch ? 320 : 200)) {
            NWDockStack(size: touch ? .phone : .pointer, showsTray: true, showsQueue: false) {
                NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel,
                           text: goal.text + " Preserve the public API, keep the fixtures intact, and check every consumer before changing the contract.",
                           size: size, framed: false, pause: {}, resume: {}, edit: {}, clear: {})
            } queue: { EmptyView() }
                .padding(NW.Space.l)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    @Test func sidebarGoalsKeepTheirNormalAccessories() async throws {
        let goals = try Self.runtime().goals
        try await Preview.render("goal-sidebar", size: CGSize(width: 320, height: 240)) {
            VStack(spacing: 0) {
                ForEach(goals, id: \.state) { goal in
                    NWSidebarRow(goal.state == .needsYou ? "Fix the ledger" : "Ledger checks", state: goal.isActive ? .running : goal.state == .needsYou ? .attention : .done,
                                 accessory: goal.state == .needsYou ? .reason("retention?") : goal.isActive ? .elapsed(since: Date().addingTimeInterval(-goal.elapsedSeconds)) : .none,
                                 hasGoal: true)
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.s)
            .background(Color.nw.bgBase)
        }
    }

    @Test(arguments: [NativeGoalState.paused, .needsYou, .met])
    func inactiveGoalsHaveNoThreadHeaderPill(_ state: NativeGoalState) async throws {
        var snapshot = Threads.question
        snapshot.dialogs = []
        snapshot.goal = try #require(Self.runtime().goals.first { $0.state == state })
        snapshot.running = false
        snapshot.supportedActions.append("goal")
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render("goal-header-\(state.rawValue)", size: CGSize(width: 1000, height: 620), ready: {
            fixture.store.ready && fixture.store.goal?.state == state
        }) {
            fixture.thread(title: "Fix the ledger")
        }
    }

    @Test func theGoalStaysVisibleWhileAQuestionReplacesTheComposer() async throws {
        var snapshot = Threads.question
        snapshot.goal = try #require(Self.runtime().goals.first { $0.state == .needsYou })
        snapshot.supportedActions.append("goal")
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render("goal-question-dock", size: CGSize(width: 1000, height: 760), ready: {
            fixture.store.ready && fixture.store.goal != nil && !fixture.store.dialogs.isEmpty
        }) {
            fixture.thread(title: "Fix the ledger")
        }
    }

    @Test func aGoalSharesTheComposerDockWithSubagentsAndQueuedMessages() async throws {
        var snapshot = Threads.subagents(Threads.liveRuns, running: true)
        snapshot.goal = try #require(Self.runtime().goals.first { $0.state == .working })
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

    @Test func slashMenuIncludesTheGoalConditionRow() async throws {
        var cache = SlashMatchCache()
        cache.update(query: "goal", commands: [NativeCommand(name: "goal", description: "Work toward a condition", source: "extension", arguments: "<condition>")])
        #expect(cache.rows.map(\.name) == ["goal"])
        try await Preview.render("goal-slash-menu", size: CGSize(width: 500, height: 140)) {
            NWSlashMenu(commands: cache.rows, total: 1, query: "goal", selection: .constant(0), maxHeight: nil) { _ in }
                .padding(NW.Space.l)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }
}
