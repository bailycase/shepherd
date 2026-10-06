import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// A long, edit-heavy thread's snapshot: its non-message lists (twenty finished subagent cards that
/// each name the thirty-two files they edited, ten recorded turns of twenty files, sixty-one slash
/// commands, widgets, a queue) weigh as much as the whole snapshot may, and its history used to get
/// what was left: nothing, a thread with no turns and the composer beside it.
@Suite("Snapshot budget beside a heavy base")
struct SnapshotBudgetTests {
    static let worktree = "/Users/someone/Developer/Project/.claude/worktrees/agent-a17a1eed02e8595ae"

    static func run(_ i: Int, state: String = "complete", files: Int = 32) -> ChildRun {
        var run = ChildRun(runID: "run-\(i)", label: "worker: " + String(repeating: "do part ", count: 12), state: state,
                           startedAt: 1_790_000_000_000 + Double(i), endedAt: state == "running" ? nil : 1_790_000_100_000 + Double(i),
                           asyncDir: "/Users/someone/Library/Application Support/Shepherd/children/01a0f9d8-3707-7488-9757-a71636b2238a/run-\(i)",
                           role: "worker", model: "anthropic/claude-sonnet-5-5", thinking: "medium", context: "background",
                           step: ChildStep(index: 2, total: 5), turns: 40, toolCalls: 120, tokens: 400_000, contextPercent: 43,
                           lastActivity: ChildActivity(tool: "edit", preview: String(repeating: "p", count: 160), diff: ChildDiff(added: 12, removed: 3), at: 1_790_000_000_000),
                           toolCallID: "call-\(i)", task: String(repeating: "t", count: 600),
                           sessionFile: "/Users/someone/Library/Application Support/Shepherd/pi/sessions/--Users-someone-Developer-Project-.claude-worktrees-agent-a17a1eed02e8595ae--/2026-10-01T12-00-00-000Z_01a0f9d8-3707-7488-9757-a71636b2238a.jsonl",
                           cwd: worktree)
        run.files = (0..<files).map { ChildFileChange(path: "\(worktree)/Sources/ShepherdApp/Module\($0)/Feature\(i)/Thing\($0).swift", added: 20, removed: 5) }
        if state == "complete" {
            run.result = ChildResultSummary(files: files, added: 1200, removed: 300, tools: 120, tokens: 400_000)
            run.output = String(repeating: "o", count: 600)
            run.summary = String(repeating: "s", count: 240)
            run.sessionID = "01a0f9d8-3707-7488-9757-a71636b2238a"
        }
        return run
    }

    static func turn(_ i: Int, files: Int = 20) -> ChangesTurn {
        ChangesTurn(messageTimestamp: 1_790_000_000_000 + Double(i), prompt: String(repeating: "p", count: 120),
                    startedAt: 1_790_000_000_000 + Double(i), endedAt: 1_790_000_100_000 + Double(i), state: .ready,
                    files: (0..<files).map { ChangesFile(path: "Sources/ShepherdApp/Module\($0)/Feature\(i)/Thing\($0).swift", status: .modified, added: 20, removed: 5) },
                    fileCount: 40, added: 800, removed: 200)
    }

    static func commands() -> [NativeCommand] {
        (0..<61).map { NativeCommand(name: "skill:" + String(repeating: "n", count: 20) + "\($0)", description: String(repeating: "d", count: 250), source: "skill", arguments: "[args]") }
    }

    /// The snapshot's parts beside its messages for that thread, as the host holds them.
    static func heavyBase(runs: [ChildRun], turns: [ChangesTurn]) -> NativeThreadSnapshot {
        NativeThreadSnapshot(
            piSessionID: "s-1", generation: "g-1", revision: 42, running: false, model: "anthropic/claude", thinking: "medium",
            supportedActions: RPCThreadState.supportedActions, dialogsSupported: true, dialogs: [],
            widgets: (0..<3).map { NativeThreadWidget(namespace: "ext\($0)", key: "k", kind: .text, title: "Title", text: String(repeating: "w", count: 4000)) },
            messages: [], provisional: [], clipped: false, runtime: "rpc",
            stats: NativeThreadStats(contextTokens: 1, contextWindow: 2, contextPercent: 3, totalTokens: 4, cost: 0.5),
            commands: commands(), subagents: runs, queue: NativeQueue(items: (0..<3).map { _ in
                NativeQueuedMessage(id: UUID(), text: String(repeating: "q", count: 3000), sentAt: 1)
            }, mode: .all),
            turnChanges: turns)
    }

    static func message(_ i: Int, bytes: Int, role: String = "assistant") -> NativeThreadMessage {
        NativeThreadMessage(entryID: "m:\(i)", role: role, blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "x", count: bytes))],
                            status: role == "assistant" ? "stop" : nil, timestamp: 1_733_234_567_890 + Double(i))
    }

    static func sized<T: Encodable>(_ value: T) -> RPCThreadState.Sized<T> { RPCThreadState.Sized(value: value, bytes: RPCThreadState.bytes(value)) }

    static func budget(_ base: NativeThreadSnapshot, active: [NativeThreadMessage] = [], dialogs: [NativeThreadDialog] = [],
                       history: [NativeThreadMessage]) -> (snapshot: NativeThreadSnapshot, bytes: Int) {
        let history = history.map { sized($0) }
        return RPCThreadState.budget(base, baseBytes: RPCThreadState.bytes(base), active: active.map { sized($0) }, dialogs: dialogs.map { sized($0) },
                                     historyEnd: history.count, history: { history[$0] })
    }

    static let heavyRuns = (0..<20).map { run($0) }
    static let heavyTurns = (0..<10).map { turn($0) }

    // MARK: The thread that had no room

    @Test func theHeavyThreadsOtherListsWeighAsMuchAsTheWholeSnapshotMay() {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        let bytes = RPCThreadState.bytes(base)
        #expect(bytes > RPCThreadState.snapshotLimit - 16 * 1024, "\(bytes) bytes of \(RPCThreadState.snapshotLimit)")
    }

    @Test func historyKeepsItsReserveWhateverTheOtherListsWeigh() {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        let history = (0..<80).map { Self.message($0, bytes: 4000, role: $0 % 2 == 0 ? "user" : "assistant") }

        let (snapshot, bytes) = Self.budget(base, history: history)

        #expect(snapshot.messages.map(\.entryID) == history.suffix(snapshot.messages.count).map(\.entryID), "the newest messages, in order")
        #expect(snapshot.messages.count >= 20, "\(snapshot.messages.count) messages")
        #expect(snapshot.olderCursor == snapshot.messages.first?.entryID, "the older ones are a page away")
        #expect(!snapshot.clipped && snapshot.clips == nil, "older pages are not clipped")
        #expect(bytes == RPCThreadState.bytes(snapshot))
    }

    @Test func historyKeepsItsReserveEvenWhenOneMessageIsAsBigAsAMessageGets() {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        let history = (0..<30).map { Self.message($0, bytes: RPCThreadState.textLimit) }

        let (snapshot, _) = Self.budget(base, history: history)

        #expect(snapshot.messages.count >= RPCThreadState.historyReserve / (RPCThreadState.textLimit + 400) - 1)
        #expect(snapshot.messages.last?.entryID == "m:29")
    }

    @Test(arguments: [1, 128])
    func anEscapedNewestMessageDoesNotEraseHistory(blockCount: Int) {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        var reply = Self.message(1, bytes: 0)
        reply.blocks = (0..<blockCount).map { _ in
            .init(kind: .text, text: String(repeating: "\u{0000}", count: RPCThreadState.textLimit / blockCount))
        }
        #expect(RPCThreadState.bytes(reply) > RPCThreadState.historyReserve)
        let history = [Self.message(0, bytes: 100, role: "user"), reply]
        let (result, bytes) = Self.budget(base, history: history)
        #expect(result.messages.last == reply)
        #expect(result.olderCursor == reply.entryID)
        #expect(bytes == RPCThreadState.bytes(result))
        #expect(RPCThreadState.bytes(RemoteReply.nativeThread(id: 1, result: .snapshot(value: result))) < NDJSON.maxPayloadBytes)
        var preview = base
        RPCThreadState.fillPage(&preview, from: history, end: history.count)
        #expect(preview.messages.last == reply)
        #expect(preview.olderCursor == reply.entryID)
    }

    @Test(arguments: [500_000, NDJSON.maxPayloadBytes])
    func oversizedProducerIdentifiersDoNotBypassTheWireLimit(idLength: Int) {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        var entry = Self.message(0, bytes: 0)
        entry.entryID = String(repeating: "x", count: idLength)
        let result = Self.budget(base, history: [entry]).snapshot
        #expect(result.messages.isEmpty)
        #expect(RPCThreadState.bytes(RemoteReply.nativeThread(id: 1, result: .snapshot(value: result))) < NDJSON.maxPayloadBytes)
        var page = base
        RPCThreadState.fillPage(&page, from: [entry], end: 1)
        #expect(page.messages.isEmpty)
    }

    @Test func theLiveRunKeepsItsReserveBesideAHeavyBase() {
        let base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        let active = [Self.message(0, bytes: 100, role: "user")]
            + (1..<30).map { NativeThreadMessage(entryID: "provisional:tool:c\($0)", role: "toolResult",
                                                  blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "x", count: 10_000))],
                                                  toolName: "bash", toolCallID: "c\($0)", status: "running") }

        let (snapshot, bytes) = Self.budget(base, active: active, history: (0..<10).map { Self.message($0 + 100, bytes: 1000) })

        let live = snapshot.provisional
        #expect(live.first?.role == "user", "the user row that opens the turn stays")
        #expect(live.count(where: { $0.role != "user" }) >= RPCThreadState.activeReserve / 10_500 - 1, "\(live.count) live rows")
        #expect(live.last?.entryID == "provisional:tool:c29", "the newest rows stay")
        #expect(snapshot.messages.count == 10, "short history all fits beside them")
        #expect(snapshot.clips == NativeThreadClips(live: active.count - live.count) && snapshot.clipped, "the rows left out of the turn are counted, and nothing else is")
        #expect(bytes == RPCThreadState.bytes(snapshot))
    }

    /// The questions that would not fit are counted too, after the turn's rows, and they alone are not
    /// the history: its page is as full as it was.
    @Test func questionsThatDoNotFitAreCountedAndTheirThreadsHistoryStaysWhole() {
        var base = Self.heavyBase(runs: [], turns: [])
        base.commands = []
        let dialogs = (0..<6).map { NativeThreadDialog(id: "d\($0)", kind: .editor, title: "Edit", message: String(repeating: "q", count: 30_000)) }
        let history = (0..<80).map { Self.message($0, bytes: 3000) }

        let (snapshot, bytes) = Self.budget(base, dialogs: dialogs, history: history)

        let left = dialogs.count - snapshot.dialogs.count
        #expect(left > 0 && snapshot.dialogs.map(\.id) == dialogs.prefix(snapshot.dialogs.count).map(\.id), "the newest questions are the ones left out")
        #expect(snapshot.clips == NativeThreadClips(questions: left) && snapshot.clipped)
        #expect(snapshot.messages.count >= 20 && snapshot.messages.last?.entryID == "m:79")
        #expect(bytes == RPCThreadState.bytes(snapshot))
    }

    @Test func factsTheHostAlreadyHeldJoinTheOnesThisSnapshotAdds() {
        var base = Self.heavyBase(runs: Self.heavyRuns, turns: Self.heavyTurns)
        base.clips = NativeThreadClips(history: true, live: 2)
        base.clipped = true
        let active = [Self.message(0, bytes: 100, role: "user")]
            + (1..<30).map { NativeThreadMessage(entryID: "provisional:tool:c\($0)", role: "toolResult",
                                                  blocks: [NativeThreadBlock(kind: .text, text: String(repeating: "x", count: 10_000))],
                                                  toolName: "bash", toolCallID: "c\($0)", status: "running") }

        let (snapshot, bytes) = Self.budget(base, active: active, history: (0..<10).map { Self.message($0 + 100, bytes: 1000) })

        #expect(snapshot.clips == NativeThreadClips(history: true, live: 2 + active.count - snapshot.provisional.count) && snapshot.clipped)
        #expect(bytes == RPCThreadState.bytes(snapshot), "the clips are counted in the size, whichever fact they came from")
    }

    /// The Goal card's data is a field of the snapshot beside the cards and turns (not a widget, so
    /// not under the widgets' cap): a goal as big as one gets stays whole, and history keeps its
    /// reserve beside it.
    @Test func aGoalAsBigAsOneGetsSurvivesTheBudgetBesideAHeavyBase() {
        var base = Self.heavyBase(runs: RPCThreadState.fitting(Self.heavyRuns, limit: RPCThreadState.subagentsLimit), turns: Self.heavyTurns)
        let goal = NativeGoal(id: "goal-1", revision: 7, text: String(repeating: "g", count: 32768), state: .working, elapsedSeconds: 120,
                              tokensUsed: 40_000, reason: String(repeating: "r", count: 4096), evidence: String(repeating: "e", count: 8192),
                              summary: String(repeating: "s", count: 2000), checkedBy: "same-model evaluator", runningSince: 1_790_000_000_000, checkCount: 3)
        base.goal = goal
        let history = (0..<80).map { Self.message($0, bytes: 4000) }

        let (snapshot, bytes) = Self.budget(base, history: history)

        #expect(snapshot.goal == goal, "the goal card's data is carried whole")
        #expect(snapshot.messages.count >= 20, "\(snapshot.messages.count) messages")
        #expect(snapshot.messages.last?.entryID == "m:79")
        #expect(bytes == RPCThreadState.bytes(snapshot))
    }

    @Test func aBaseThatFitsLeavesTheBudgetsAsTheyWere() {
        var base = Self.heavyBase(runs: [], turns: [])
        base.commands = []
        base.widgets = []
        base.queue = nil
        let history = (0..<80).map { Self.message($0, bytes: 3000) }

        let (snapshot, bytes) = Self.budget(base, history: history)

        #expect(snapshot.messages.count == RPCThreadState.pageSize)
        #expect(bytes <= RPCThreadState.snapshotLimit)
    }

    // MARK: What a snapshot carries of each list

    @Test func theHeavyThreadsListsFitTheirBudgetsAndLeaveRoomForTwentyMessages() {
        let runs = RPCThreadState.fitting(Self.heavyRuns, limit: RPCThreadState.subagentsLimit)
        let turns = RPCThreadState.fitting(Self.heavyTurns, limit: RPCThreadState.turnChangesLimit)
        let base = Self.heavyBase(runs: runs, turns: turns)
        let history = (0..<80).map { Self.message($0, bytes: 4000) }

        let (snapshot, bytes) = Self.budget(base, history: history)

        #expect(RPCThreadState.bytes(runs) <= RPCThreadState.subagentsLimit)
        #expect(RPCThreadState.bytes(turns) <= RPCThreadState.turnChangesLimit)
        #expect(snapshot.messages.count >= 20, "\(snapshot.messages.count) messages")
        #expect(bytes <= RPCThreadState.snapshotLimit)
    }

    @Test func runsWithinTheirBudgetAreLeftAlone() {
        let runs = (0..<3).map { Self.run($0) }
        #expect(RPCThreadState.fitting(runs, limit: RPCThreadState.subagentsLimit) == runs)
    }

    @Test func finishedRunsGiveUpTheirFilesOldestFirstBeforeAnyRunGoes() {
        let runs = (0..<10).map { Self.run($0) }
        let one = RPCThreadState.bytes(runs[0])
        let withoutFiles = RPCThreadState.bytes({ var r = runs[0]; r.files = nil; return r }())
        // Room for every card, and the files of only the newest few.
        let limit = withoutFiles * 10 + (one - withoutFiles) * 3 + 100

        let fitted = RPCThreadState.fitting(runs, limit: limit)

        #expect(fitted.map(\.runID) == runs.map(\.runID), "no run left")
        #expect(fitted.prefix(7).allSatisfy { $0.files == nil && $0.result != nil }, "the older ones keep their counts")
        #expect(fitted.suffix(3).allSatisfy { $0.files?.count == 32 })
        #expect(RPCThreadState.bytes(fitted) <= limit)
    }

    @Test func overTheBudgetEvenWithoutFilesTheOldestFinishedRunsGoAndTheOnesStillGoingStay() {
        let finished = (0..<20).map { Self.run($0) }
        let going = Self.run(100, state: "running")
        let asking = { () -> ChildRun in var r = Self.run(101, state: "running"); r.needsAttention = true; return r }()
        let runs = finished + [going, asking]
        let limit = RPCThreadState.bytes(going) + RPCThreadState.bytes(asking) + 3 * 4_000

        let fitted = RPCThreadState.fitting(runs, limit: limit)

        #expect(fitted.contains { $0.runID == "run-100" } && fitted.contains { $0.runID == "run-101" })
        let left = fitted.filter { $0.state == "complete" }.map(\.runID)
        #expect(!left.isEmpty && left.count < finished.count)
        #expect(left == (20 - left.count..<20).map { "run-\($0)" }, "the newest finished runs are the ones that stay: \(left)")
        #expect(RPCThreadState.bytes(fitted) <= limit)
    }

    @Test func recordedTurnsGiveUpTheFilesOfTheOlderOnesThenGoOldestFirstAndTheNewestStays() {
        let turns = (0..<10).map { Self.turn($0) }
        let one = RPCThreadState.bytes(turns[0])
        let short = RPCThreadState.bytes(Self.turn(0, files: RPCThreadState.olderTurnFiles))

        let trimmed = RPCThreadState.fitting(turns, limit: short * 9 + one + 50)
        #expect(trimmed.map(\.id) == turns.map(\.id))
        #expect(trimmed.dropLast().allSatisfy { $0.files.count == RPCThreadState.olderTurnFiles && $0.fileCount == 40 }, "the count still says what it changed")
        #expect(trimmed.last?.files.count == 20)

        let fewer = RPCThreadState.fitting(turns, limit: short * 2 + one + 50)
        #expect(fewer.last?.id == turns.last?.id && fewer.last?.files.count == 20)
        #expect(fewer.count < turns.count && fewer.count >= 1)
        #expect(fewer.map(\.id) == turns.suffix(fewer.count).map(\.id), "the oldest went first")

        #expect(RPCThreadState.fitting([turns[0]], limit: 10).map(\.id) == [turns[0].id], "a lone turn is never cut")
    }

    @Test func widgetsPastTheirBudgetAreLeftOutAndTheFirstAlwaysStays() {
        let widgets = (0..<10).map { NativeThreadWidget(namespace: "ext", key: "w\($0)", kind: .text, text: String(repeating: "w", count: 4000)) }
        let one = RPCThreadState.bytes(widgets[0])

        #expect(RPCThreadState.fitting(widgets, limit: one * 3 + 10).map(\.key) == ["w0", "w1", "w2"])
        #expect(RPCThreadState.fitting(widgets, limit: 10).map(\.key) == ["w0"])
        #expect(RPCThreadState.fitting(widgets, limit: RPCThreadState.widgetsLimit) == widgets)
    }
}
