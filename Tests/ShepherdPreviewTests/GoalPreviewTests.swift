import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

@Suite("Goal previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct GoalPreviewTests {
    /// Generated and checked by goal.test.mjs from the extension's published widgets/messages.
    private struct Runtime: Decodable {
        struct Record: Decodable {
            let customType: String
            let content: String
            let details: JSONValue?
        }
        var goals: [NativeGoal]
        let confirmationGoal: NativeGoal
        let confirmedGoal: NativeGoal
        let editorGoal: NativeGoal
        let records: [Record]
    }

    private static func runtime() throws -> Runtime {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/goal-runtime-fixtures.json")
        var runtime = try JSONDecoder().decode(Runtime.self, from: Data(contentsOf: path))
        // Runtime fixtures use a fake epoch. Keep their accrued time, not decades of wall time.
        let now = Date().timeIntervalSince1970 * 1000
        for index in runtime.goals.indices where runtime.goals[index].isActive && runtime.goals[index].runningSince != nil {
            runtime.goals[index].runningSince = now
        }
        return runtime
    }

    @Test(arguments: [NWGoalSize.desktop, .touch])
    func everyPublishedGoalStateRendersInBothAppearances(_ size: NWGoalSize) async throws {
        let goals = try Self.runtime().goals
        let touch = size == .touch
        try await Preview.renderMatrix(touch ? "goal-states-touch" : "goal-states-desktop",
                                       size: CGSize(width: touch ? 398 : 720, height: touch ? 1000 : 850)) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                ForEach(goals, id: \.state) { goal in
                    NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text,
                               size: size, confirmationRequired: goal.confirmationRequired == true,
                               checkedBy: goal.checkedBy, confirmedByUser: goal.confirmedByUser == true,
                               pause: {}, resume: {}, edit: {}, clear: {})
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .frame(width: touch ? 398 : 720, height: touch ? 1000 : 850, alignment: .top)
            .background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: [NWGoalSize.desktop, .touch])
    func confirmationCheckerAndUserAttestationGrowTheCard(_ size: NWGoalSize) async throws {
        let runtime = try Self.runtime()
        let touch = size == .touch
        try await Preview.renderMatrix(touch ? "goal-confirmation-touch" : "goal-confirmation-desktop",
                                       size: CGSize(width: touch ? 398 : 720, height: touch ? 650 : 550)) {
            VStack(spacing: NW.Space.l) {
                ForEach([true, false], id: \.self) { enabled in
                    let goal = runtime.confirmationGoal
                    NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel,
                               text: goal.text, size: size, resumeEnabled: enabled,
                               confirmationRequired: goal.confirmationRequired == true, checkedBy: goal.checkedBy,
                               pause: {}, resume: {}, edit: {}, clear: {})
                }
                let met = runtime.confirmedGoal
                NWGoalCard(state: met.cardState, time: met.timeLabel, meta: met.metaLabel, text: met.text,
                           size: size, checkedBy: met.checkedBy, confirmedByUser: met.confirmedByUser == true,
                           pause: {}, resume: {}, edit: {}, clear: {})
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .frame(width: touch ? 398 : 720, height: touch ? 650 : 550, alignment: .top)
            .background(Color.nw.bgWindow)
        }
    }

    @Test func theObjectiveOnlyEditorShowsUnchangedAndChangedSaveStates() async throws {
        let goal = try Self.runtime().editorGoal
        try await Preview.renderMatrix("goal-edit", size: CGSize(width: 720, height: 440)) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                ForEach([false, true], id: \.self) { changed in
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        NWGoalCard(state: goal.cardState, time: goal.timeLabel, meta: goal.metaLabel, text: goal.text,
                                   framed: false, checkedBy: goal.checkedBy, pause: {}, resume: {}, edit: {}, clear: {})
                        VStack(alignment: .leading, spacing: NW.Space.s) {
                            TextField("Goal condition", text: .constant(changed ? goal.text + " Run the race checks too." : goal.text), axis: .vertical)
                                .textFieldStyle(.plain).font(.nw(.body))
                                .foregroundStyle(Color.nw.textPrimary)
                                .lineLimit(1...NWComposerMetrics.fieldMaxLines)
                            HStack(spacing: NW.Space.s) {
                                Spacer()
                                Button("Cancel") {}.buttonStyle(.nw(.ghost, size: .s))
                                Button("Save") {}.buttonStyle(.nw(.secondary, size: .s)).disabled(!changed)
                            }
                        }
                        .padding(NW.Space.l)
                        .overlay(alignment: .top) { NWHairline() }
                    }
                    .background(Color.nw.bgRaised)
                    .nwBorder(Color.nw.lineStrong, radius: NWGoalSize.desktop.radius)
                }
                Spacer(minLength: 0)
            }
            .padding(NW.Space.l)
            .frame(width: 720, height: 440, alignment: .top)
            .background(Color.nw.bgWindow)
        }
    }

    @Test func publishedRecordsKeepTheirEvidenceBehindDisclosure() async throws {
        let records = try Self.runtime().records
        let messages = records.enumerated().map { index, record in
            RPCThreadState.project(entryID: "record-\(index)", message: RPCMessage(
                role: "custom", content: [.text(record.content)], customType: record.customType,
                display: true, details: record.details))
        }
        let presentation = nativeTurnPresentation(messages, live: false)
        for (record, message) in zip(records, messages) where record.customType == "shepherd.goal.check" {
            let shown = NativeGoalRecord(message.blocks.map(\.text).joined(separator: "\n"))
            if let model = record.details?["checkedBy"]?.stringValue {
                #expect(shown.line.contains("Checked by " + model), "native projection exposes the fixture's actual checker")
            }
            if let feedback = record.details?["verdict"]?["reason"]?.stringValue {
                #expect(shown.evidence?.contains(feedback) == true, "full fixture feedback remains under Details")
            }
            if let error = record.details?["error"]?.stringValue {
                #expect(shown.evidence?.contains(error) == true, "fixture diagnostics remain under Details")
            }
        }
        try await Preview.renderMatrix("goal-thread-records", size: CGSize(width: 720, height: 720)) {
            AgentTurn(presentation: presentation, live: false, footer: false)
                .padding(NW.Space.xl)
                .frame(width: 720, height: 720, alignment: .top)
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

    @Test func aConversationWithoutAGoalShowsNoGoalChrome() async throws {
        var snapshot = Threads.question
        snapshot.goal = nil
        snapshot.dialogs = []
        snapshot.running = false
        snapshot.supportedActions.append("goal")
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.renderMatrix("goal-empty", size: CGSize(width: 1000, height: 620), ready: {
            fixture.store.ready && !fixture.store.hasGoal
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
