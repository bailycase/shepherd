import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// What the thread surfaces and the Fleet page say about dispatches: each card from its record, where a dispatched thread came from, the
/// result a parent reads, and the Where it runs picker New thread ranks Macs with.
@Suite("Fleet dispatch presentation")
struct FleetDispatchPresentationTests {
    typealias P = FleetPagePresentationTests
    static let parent = AgentID(rawValue: "a1")

    static func record(_ state: FleetDispatchState, title: String = "Fix flaky payment test", target: UUID? = P.mini, host: String? = "Mac mini",
                       reasons: [FleetPlacementReason] = [FleetPlacementReason(.mostRoom, ratio: 3.4)], failure: String? = nil,
                       kind: FleetDispatchRecord.Kind = .agentDispatch, parent: AgentID? = FleetDispatchPresentationTests.parent, at: Double = 100) -> FleetDispatchRecord {
        FleetDispatchRecord(kind: kind, parentAgentID: parent, parentHostID: P.here, parentHostName: "MacBook Pro", parentTitle: "Speed up checkout CI",
                            targetHostID: target, targetHostName: host, state: state, failure: failure, title: title, task: "Fix the flaky test.",
                            repoKey: "github.com/acme/payments-api", commitSHA: "4e1c9a2" + String(repeating: "0", count: 33),
                            branch: "fleet/fix-flaky-payment", reasonCodes: reasons, remoteAgentID: state == .running ? AgentID(rawValue: "a9") : nil,
                            createdAt: at)
    }

    static func cards(_ records: [FleetDispatchRecord], cap: Int = 3) -> [FleetDispatchCard] {
        FleetDispatchPresentation.cards(records, in: FleetCardContext(snapshot: P.snapshot(), cap: cap, locale: P.en, calendar: P.utc))
    }

    // MARK: Cards

    @Test func aRunningDispatchIsARowWithWhereWhyOpenAndStop() throws {
        let card = try #require(Self.cards([Self.record(.running)]).first)
        #expect(card.layout == .row && card.pill == "Working" && card.host == "Mac mini")
        #expect(card.detail == "Auto: Mac mini had 3.4× the room · payments-api @ 4e1c9a2 · new worktree fleet/fix-flaky-payment")
        #expect(card.actions == [.open, .stop])
    }

    @Test func whyReadsFromTheReasonCodesTheSendersHostRecorded() {
        func why(_ reasons: [FleetPlacementReason], kind: FleetDispatchRecord.Kind = .agentDispatch) -> String {
            FleetDispatchPresentation.whyWords(Self.record(.running, reasons: reasons, kind: kind))
        }
        #expect(why([FleetPlacementReason(.named)]) == "Picked Mac mini")
        #expect(why([FleetPlacementReason(.named)], kind: .userThread) == "You picked Mac mini")
        #expect(why([FleetPlacementReason(.onlyChoice)]) == "Auto: Mac mini was the only Mac with room")
        #expect(why([FleetPlacementReason(.localIneligible, skip: "cpu"), FleetPlacementReason(.mostRoom)]) == "Auto: This Mac is busy, so Mac mini")
        #expect(why([FleetPlacementReason(.mostRoom)]) == "Auto: Mac mini had the most room")
        #expect(why([]) == "")
    }

    @Test func aSleepingTargetWaitsAndOffersAnotherMac() throws {
        let card = try #require(Self.cards([Self.record(.waitingWake, target: P.studio, host: "Mac Studio", reasons: [FleetPlacementReason(.named)])]).first)
        #expect(card.pill == "Waiting" && card.layout == .state)
        #expect(card.detail.hasPrefix("Mac Studio has been asleep since ") && card.detail.hasSuffix("It never moves on its own."))
        #expect(card.actions == [.sendTo(P.mini, "Mac mini"), .cancel], "it never moves on its own; the person can send it to a Mac that is up")
    }

    @Test func aHeldDispatchSaysHowManyOthersRunAndOpensThem() throws {
        let running = (0..<2).map { Self.record(.running, title: "Task \($0)", at: Double($0)) }
        let held = Self.record(.heldLimit, title: "Third task", at: 10)
        let card = try #require(Self.cards(running + [held]).first { $0.id == held.id })
        #expect(card.pill == "Held" && card.tone == .warn)
        #expect(card.detail == "Speed up checkout CI already has 2 threads running on other Macs. This one goes when one of them finishes.")
        #expect(card.actions == [.openOthers(2)])
    }

    @Test func aWaitingDispatchSaysWhatKeepsItAndWhereItIsInLine() throws {
        let first = Self.record(.waitingRoom, title: "First", at: 1), second = Self.record(.waitingRoom, title: "Second", at: 2)
        let cards = Self.cards([first, second])
        let one = try #require(cards.first { $0.id == first.id }), two = try #require(cards.first { $0.id == second.id })
        #expect(one.detail.hasPrefix("This Mac is at 72% CPU and the mini has 3 agents working.") && one.detail.hasSuffix("it's first in line."))
        #expect(two.detail.hasSuffix("1 thread is ahead of it."))
        #expect(one.actions == [.runHereNow, .cancel])
    }

    @Test(arguments: [
        (FleetDispatchCode.repoMissing, "The mini doesn't have payments-api. Clone it there, or run this here."),
        (FleetDispatchCode.noSuchHost, "No Mac named that is in the fleet."),
        (FleetDispatchCode.peerGone, "The mini stopped answering and doesn't know this dispatch. Run it again, or run it here."),
        ("a_newer_code", "It wasn't sent."),
    ])
    func aFailureReadsFromItsCodeAndOffersRunHereOrTryAgain(code: String, words: String) throws {
        let card = try #require(Self.cards([Self.record(.failed, failure: code)]).first)
        #expect(card.pill == "Not sent" && card.tone == .bad && card.detail == words)
        #expect(card.actions == [.runHere, .tryAgain])
    }

    @Test func aPreparingDispatchIsThePlainStartingState() throws {
        let card = try #require(Self.cards([Self.record(.preparing)]).first)
        #expect(card.pill == "Starting" && card.layout == .state && card.actions == [.cancel])
        #expect(card.detail.contains("Nothing touches your checkout."))
    }

    @Test func aPreparingDispatchSendingChangesCarriesTheProgressOfItsSnapshot() throws {
        var record = Self.record(.preparing)
        record.snapshotBytes = 2_800_000
        record.snapshotProgress = 1_400_000
        record.snapshotFiles = 3
        let card = try #require(Self.cards([record]).first)
        #expect(card.pill == "Starting" && card.actions == [.cancel])
        let sending = try #require(card.sending)
        #expect(sending.progress == "1.4 of 2.8 MB" && sending.fraction == 0.5)
        #expect(card.detail == sending.summary && card.detail.contains("plus 3 uncommitted files"))
        #expect(Self.cards([Self.record(.running)]).first?.sending == nil)
    }

    @Test func aStoppedDispatchWithNoThreadOffersNoOpen() throws {
        let card = try #require(Self.cards([Self.record(.cancelled)]).first)
        #expect(card.pill == "Stopped" && card.actions.isEmpty)
    }

    @Test func aMacCatchingUpIsABehindCardAndOneThatIsInSyncIsNot() {
        var snapshot = P.snapshot()
        #expect(FleetDispatchPresentation.behind(snapshot).isEmpty)
        snapshot.sync = FleetSyncStatus(peers: [FleetSyncStatus.Peer(hostID: P.mini, name: "Mac mini", state: .catchingUp)])
        #expect(FleetDispatchPresentation.behind(snapshot).map(\.name) == ["Mac mini"])
    }

    // MARK: Where a dispatched thread came from

    static func from(_ agent: AgentID?, host: UUID = P.here) -> DispatchedFrom {
        DispatchedFrom(hostID: host, hostName: "MacBook Pro", agentID: agent, agentTitle: "Speed up checkout CI", dispatchID: UUID(), at: 1_790_000_000_000)
    }

    @Test func aThreadSentByAThreadNamesItAndSaysItsLastMessageGoesBack() {
        let here = FleetSentBy(Self.from(Self.parent), host: "Mac mini", viewer: P.here)
        #expect(here.fromLine == "From Speed up checkout CI on This Mac" && here.sentByLine == "sent by Speed up checkout CI")
        #expect(here.goesBackLine == "When this finishes, its last message goes back to Speed up checkout CI. You can still talk to it here.")
        // Seen from another Mac the sender's Mac is named.
        #expect(FleetSentBy(Self.from(Self.parent), host: "Mac mini", viewer: P.mini).fromLine == "From Speed up checkout CI on MacBook Pro")
    }

    @Test func aThreadYouStartedIsSentByYouAndNothingGoesBack() {
        let sent = FleetSentBy(Self.from(nil), host: "Mac mini", viewer: P.here)
        #expect(sent.sentByLine == "sent by you" && !sent.fromThread && sent.goesBackLine == nil)
    }

    @Test func theFromBoxDrawsTheTaskWithoutTheInstructionsTheHostAdded() {
        let sent = "Profile the orders import.\n\nKeep it small." + FleetDispatchProtocol.promptSeparator + "Speed up checkout CI on MacBook Pro to do the task above. Your branch is fleet/x."
        #expect(FleetSentBy.task(in: sent) == "Profile the orders import.\n\nKeep it small.")
        #expect(FleetSentBy.isDispatchMessage(sent) && !FleetSentBy.isDispatchMessage("Hello"))
        #expect(FleetSentBy.task(in: "No separator") == "No separator")
    }

    @Test func theOfflineBannerSaysHowLongTheMacHasBeenGone() {
        let seen = 1_790_000_000_000.0
        let banner = FleetOfflineBanner(host: "Mac mini", lastSeen: seen)
        func at(_ seconds: Double) -> String { banner.message(now: Date(timeIntervalSince1970: seen / 1000 + seconds)) }
        #expect(at(10) == "Mac mini stopped answering a moment ago. Work there keeps running; this view catches up when it reconnects.")
        #expect(at(120).contains("2 minutes ago") && at(3600 * 3).contains("3 hours ago") && at(86_400).contains("1 day ago"))
    }

    // MARK: The result

    @Test func aResultMessageIsReadBackWithItsBranch() throws {
        let text = "[from: Fix flaky payment test on Mac mini, an agent, not the user. Reply with agent_send only if this asks for a reply.] Result from Fix flaky payment test on Mac mini:\nFixed: the test raced the clock.\n\nBranch fleet/fix-flaky-payment: 2 commits ahead of the start, pushed to origin, 3 files changed (+10 -2)."
        let result = try #require(FleetResultMessage.parse(text))
        #expect(result.title == "Fix flaky payment test" && result.host == "Mac mini" && result.text == "Fixed: the test raced the clock.")
        #expect(result.branch == "fleet/fix-flaky-payment" && result.pushed == true)
        #expect(FleetResultMessage.parse("[from: a, an agent, not the user.] Please look at this") == nil)
        #expect(FleetResultMessage.parse("Result from X on Y:\nhi") == nil, "only the host's framing counts")
    }

    @Test func aResultBelongsToTheDispatchOfItsTitleAndMac() throws {
        let done = Self.record(.done, at: 5), other = Self.record(.done, title: "Another", at: 6), running = Self.record(.running, at: 7)
        let result = FleetResultMessage(title: "Fix flaky payment test", host: "Mac mini", text: "ok")
        #expect(result.record(in: [done, other, running], parent: Self.parent)?.id == done.id)
        #expect(result.record(in: [done], parent: AgentID(rawValue: "someone else")) == nil)
    }

    /// The id the client derives for a `fleet_dispatch` call is the one the panes extension makes (shepherd-panes.ts `dispatchIDFor`).
    @Test func aToolCallsDispatchIDMatchesTheExtensions() {
        #expect(FleetDispatchID.forToolCall("call_1", agent: AgentID(rawValue: "a1"))?.uuidString.lowercased() == "71f39a5f-baa5-517f-97ca-db8c68194b7a")
    }

    // MARK: Where it runs

    static let orders = "github.com/acme/orders-svc"

    /// FleetNewThread's three Macs: orders-svc is checked out on This Mac and Mac mini, not on Mac Studio, and nothing is missing.
    static func withOrders() -> FleetSnapshot {
        var snapshot = P.snapshot()
        for index in snapshot.macs.indices where snapshot.macs[index].hostID != P.studio {
            snapshot.macs[index].readiness?.repoKeys = [orders]
            snapshot.macs[index].readiness?.missing = []
        }
        return snapshot
    }

    static func picker(_ pick: FleetPlacePick? = nil, snapshot: FleetSnapshot = FleetDispatchPresentationTests.withOrders(), auto: Bool = true,
                       repoKey: String? = FleetDispatchPresentationTests.orders) -> FleetWherePicker {
        FleetWherePicker.make(snapshot: snapshot, pick: pick, repoKey: repoKey, repoName: "orders-svc", autoDispatch: auto, weight: { _ in .normal },
                              locale: P.en, calendar: P.utc)
    }

    @Test func autoNamesTheMacWithTheMostRoomAndTheRepoLine() {
        let picker = Self.picker()
        #expect(picker.chip == "Auto · Mac mini" && picker.winner == "Mac mini" && picker.target == P.mini && picker.dispatches)
        #expect(picker.options.map(\.name) == ["Auto", "Mac mini", "This Mac", "Mac Studio"], "ranked by room, Auto first")
        #expect(picker.options.first?.chosen == true)
        #expect(picker.options.first { $0.name == "Mac Studio" }?.roomWord == "asleep")
        #expect(picker.note?.hasPrefix("Runs on Mac mini in a new worktree") == true)
        #expect(picker.footnote == "orders-svc is checked out on This Mac and Mac mini. Mac Studio doesn't have it.")
    }

    @Test func autoOffStartsOnThisMacAndASleepingMacWaits() {
        let off = Self.picker(auto: false)
        #expect(off.chip == "This Mac" && !off.dispatches && off.target == nil)
        let asleep = Self.picker(.mac(P.studio))
        #expect(asleep.chip == "Mac Studio" && asleep.dispatches && asleep.target == P.studio)
        #expect(asleep.note?.contains("starts when it wakes") == true)
        #expect(Self.picker(.mac(P.here)).dispatches == false)
    }

    @Test func noPeersOrNoOriginMeansNoPicker() {
        var alone = P.snapshot()
        alone.peers = []
        #expect(Self.picker(snapshot: alone).options.isEmpty && !Self.picker(snapshot: alone).dispatches)
        #expect(Self.picker(repoKey: nil).footnote == "orders-svc has no origin remote, so no other Mac can find it.")
    }
}
