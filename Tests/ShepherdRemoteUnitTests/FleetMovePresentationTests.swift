import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// What the host chip's menu, a move's card and the chip say, from the fleet snapshot and the move's record.
@Suite("Fleet move presentation")
struct FleetMovePresentationTests {
    typealias P = FleetPagePresentationTests
    static let key = FleetDispatchPresentationTests.orders

    static func menu(_ snapshot: FleetSnapshot = FleetDispatchPresentationTests.withOrders(), from: UUID = P.here, repoKey: String? = key) -> FleetMoveMenu? {
        FleetMoveMenu.make(snapshot: snapshot, currentHostID: from, repoKey: repoKey, repoName: "orders-svc", weight: { _ in .normal }, locale: P.en, calendar: P.utc)
    }

    // MARK: The menu

    @Test func theMenuSaysWhereItRunsAndRanksTheOtherMacsByRoomWithAsleepOnesLastAndDisabled() throws {
        let menu = try #require(Self.menu())
        #expect(menu.here.name == "This Mac" && menu.here.detail == "72% CPU · on battery", "\(menu.here)")
        #expect(menu.targets.map(\.name) == ["Mac mini", "Mac Studio"])
        let mini = menu.targets[0], studio = menu.targets[1]
        #expect(mini.enabled && mini.note == "Most room · has orders-svc · 3 working" && mini.room == 1)
        #expect(!studio.enabled && studio.note == "Asleep since 22:42" && studio.room == 0 && studio.tone == .tertiary, "\(studio)")
    }

    @Test func aMacWithoutTheRepositoryIsStillATargetAndSaysItWillClone() throws {
        var snapshot = FleetDispatchPresentationTests.withOrders()
        for index in snapshot.macs.indices where snapshot.macs[index].hostID == P.mini { snapshot.macs[index].readiness?.repoKeys = [] }
        let mini = try #require(Self.menu(snapshot)?.targets.first { $0.name == "Mac mini" })
        #expect(mini.enabled && mini.note == "Most room · will clone orders-svc · 3 working")
    }

    @Test func aMacThatIsNotReadyOrOlderOrUnheardFromCannotBePicked() throws {
        var snapshot = FleetDispatchPresentationTests.withOrders()
        let index = try #require(snapshot.macs.firstIndex { $0.hostID == P.mini })
        snapshot.macs[index].readiness?.missing = [FleetMissingTool(kind: .git)]
        let notReady = try #require(Self.menu(snapshot)?.targets.first { $0.name == "Mac mini" })
        #expect(!notReady.enabled && notReady.note == "Not ready · git isn't installed")

        snapshot = FleetDispatchPresentationTests.withOrders()
        snapshot.peers[0].takesThreads = false
        let old = try #require(Self.menu(snapshot)?.targets.first { $0.name == "Mac mini" })
        #expect(!old.enabled && old.note == "Needs a newer Shepherd")

        snapshot = FleetDispatchPresentationTests.withOrders()
        snapshot.macs[index].readiness = nil
        let unheard = try #require(Self.menu(snapshot)?.targets.first { $0.name == "Mac mini" })
        #expect(!unheard.enabled && unheard.note == "Waiting for a reading")
    }

    @Test func aThreadWithNoRepositoryHasNowhereToGo() throws {
        let menu = try #require(Self.menu(repoKey: nil))
        #expect(menu.targets.allSatisfy { !$0.enabled } && menu.targets[0].note == "orders-svc isn't a repository another Mac can find")
    }

    @Test func aThreadOnAnotherMacCanMoveBackHere() throws {
        let menu = try #require(Self.menu(from: P.mini))
        #expect(menu.here.name == "Mac mini" && menu.targets.map(\.name) == ["This Mac", "Mac Studio"])
        #expect(menu.targets[0].enabled && menu.targets[0].note.hasPrefix("Little room · has orders-svc"))
    }

    @Test func aFleetOfOneHasNoMenu() {
        #expect(Self.menu(FleetSnapshot(enabled: true, hostID: P.here, name: "MacBook Pro")) == nil)
        #expect(Self.menu(FleetSnapshot()) == nil)
    }

    // MARK: The card

    static func move(_ state: FleetDispatchState, _ stage: FleetMoveStage, failure: String? = nil, detail: String? = nil) -> FleetDispatchRecord {
        var record = FleetDispatchRecord(kind: .move, parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: P.mini, targetHostName: "Mac mini",
                                         state: state, failure: failure, failureDetail: detail, title: "Speed up checkout CI", task: "", repoKey: key,
                                         move: FleetMoveInfo(agentID: AgentID(rawValue: "a1"), stage: stage, sessionID: "s1", messages: 412, transcriptBytes: 1_800_000,
                                                             uncommittedFiles: 3, unpushedCommits: 1), createdAt: 100)
        record.snapshotBytes = 46_000
        return record
    }

    @Test func aMoveInTheWorktreeStepReadsAsTheBoardDrawsIt() throws {
        let card = try #require(FleetMoveCard.make(Self.move(.preparing, .worktree)))
        #expect(card.phase == .moving && card.title == "Moving to Mac mini")
        #expect(card.steps.map(\.mark) == [.done, .done, .current, .later])
        #expect(card.steps.map(\.text) == ["Stopped the turn", "Sent the conversation", "Sending the worktree", "Starting on Mac mini"])
        #expect(card.steps[1].meta.hasPrefix("412 messages · ") && card.steps[2].meta.hasPrefix("3 uncommitted files, 1 unpushed commit · "))
    }

    @Test func theStepsAdvanceWithTheStage() throws {
        func marks(_ stage: FleetMoveStage) throws -> [FleetMoveCard.Mark] { try #require(FleetMoveCard.make(Self.move(.preparing, stage))).steps.map(\.mark) }
        #expect(try marks(.stopping) == [.current, .later, .later, .later])
        #expect(try marks(.conversation) == [.done, .current, .later, .later])
        #expect(try marks(.staged) == [.done, .done, .done, .current])
        #expect(try marks(.starting) == [.done, .done, .done, .current])
    }

    @Test func aMoveWaitingForTheTurnIsAQueuedLineThatCanBeCancelled() throws {
        let card = try #require(FleetMoveCard.make(Self.move(.waitingTurn, .waitingTurn)))
        #expect(card.phase == .queued && card.title == "Moves to Mac mini when this turn ends." && card.canCancel && card.steps.isEmpty)
    }

    @Test func aMoveThatFailedSaysWhyAndThatTheThreadIsStillHere() throws {
        let card = try #require(FleetMoveCard.make(Self.move(.failed, .worktree, failure: FleetDispatchCode.restarted)))
        #expect(card.phase == .failed && card.title == "Couldn’t move to Mac mini" && card.detail?.hasSuffix("It is still here, as it was.") == true)
    }

    @Test func aFinishedOrCancelledMoveAndAnOrdinaryDispatchDrawNoCard() {
        #expect(FleetMoveCard.make(Self.move(.done, .moved)) == nil && FleetMoveCard.make(Self.move(.cancelled, .stopping)) == nil)
        #expect(FleetMoveCard.make(FleetDispatchPresentationTests.record(.running)) == nil)
    }

    // MARK: The chip and the divider

    @Test func theChipSaysWhereItCameFromAfterAMove() {
        let from = MovedFrom(hostID: P.here, hostName: "MacBook Pro", at: 1_789_999_320_000, moveID: UUID())
        let chip = FleetMoveChip.make(host: "Mac mini", tone: .good, movedFrom: from, thisFleetID: P.here, locale: P.en, calendar: P.utc)
        #expect(chip.text == "Mac mini" && chip.movedFrom == "moved from This Mac · 14:02" && chip.accessibilityLabel == "Runs on Mac mini. Move to another Mac", "\(chip)")
        #expect(FleetMoveChip.make(host: "This Mac", tone: .primary, movedFrom: nil, thisFleetID: P.here).movedFrom == nil)
    }

    @Test func theMoveNoteIsADividerInTheConversation() {
        let note = "Moved to Mac mini · 14:02 · branch perf/checkout-ci, 3 uncommitted files"
        let message = NativeThreadMessage(entryID: "m", role: "custom", blocks: [.init(kind: .text, text: note)], customType: "shepherd.move")
        guard case .goalRecord(_, let text) = nativeTurnPresentation([message], live: false).items.first else { Issue.record("no divider"); return }
        #expect(text == note && NativeGoalRecord(text).line == note && NativeGoalRecord(text).evidence == nil)
    }

    @Test func movingWhileACommandRunsNamesItAndHowLongItHasRun() {
        let message = NativeThreadMessage(entryID: "e", role: "toolResult", blocks: [], toolName: "bash", toolCallID: "c",
                                          argumentsText: #"{"command":"swift test --filter CheckoutIntegration"}"#, status: "running")
        var call = NativeActivityCall(message)
        call.startedAt = 1_000_000
        let confirm = FleetMoveConfirm.make(running: call, host: "Mac mini", now: Date(timeIntervalSince1970: 1_000 + 120))
        #expect(confirm.title == "It’s running a command")
        #expect(confirm.message.hasSuffix("has been running for 2 minutes. Moving now stops it; the thread picks up on Mac mini and can run it again there."))
        #expect(FleetMoveConfirm.make(running: nil, host: "Mac mini").title == "It’s working")
    }

    // MARK: The phone's menu

    @Test func moveToMacIsOfferedOnlyWhereTheHostWouldTakeIt() {
        let space = Space(name: "orders-svc", path: "/Users/dev/orders-svc")
        let agent = Agent(name: "Speed up checkout CI", spaceID: space.id, tabID: TabID())
        let state = ShepherdState(spaces: [space], agents: [agent])
        let caps: Set<String> = [RemoteProtocol.agentActionsCapability, RemoteProtocol.fleetMoveViewCapability]
        func offered(_ agent: Agent = agent, state: ShepherdState = state, connected: Bool = true, _ capabilities: Set<String> = caps) -> Bool {
            FleetThreadAbilities(agent: agent, state: state, connected: connected, capabilities: capabilities).moveToMac
        }
        #expect(offered())
        #expect(!offered(connected: false) && !offered([RemoteProtocol.agentActionsCapability]), "an offline or older host")
        var moved = agent
        moved.movedTo = MovedTo(hostID: P.mini, hostName: "Mac mini", at: 1, moveID: UUID())
        #expect(!offered(moved))
        var run = state
        run.automations = [Automation(id: AutomationID(rawValue: "a1"), name: "Nightly", prompt: "p", cwd: "/src", agentID: agent.id)]
        #expect(!offered(state: run), "an automation's run stays where it runs")
    }
}
