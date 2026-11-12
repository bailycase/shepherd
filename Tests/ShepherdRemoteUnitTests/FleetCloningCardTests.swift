import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The "Cloning" card (FleetStates), the Mac card's repo chip while a clone runs, and the words for a clone that failed, from the
/// dispatch record alone.
@Suite("Fleet cloning card")
struct FleetCloningCardTests {
    typealias P = FleetPagePresentationTests

    static func record(clone: FleetCloneProgress? = FleetCloneProgress(name: "orders-svc", source: "github.com/acme/orders-svc", phase: "receiving objects", fraction: 0.37),
                       state: FleetDispatchState = .preparing, target: UUID? = P.studio, host: String? = "Mac Studio") -> FleetDispatchRecord {
        FleetDispatchRecord(parentAgentID: AgentID(rawValue: "a1"), parentHostID: P.here, parentHostName: "MacBook Pro", targetHostID: target, targetHostName: host,
                            state: state, title: "Profile the orders import", task: "", repoKey: "github.com/acme/orders-svc", clone: clone, createdAt: 1)
    }

    @Test func theCardSaysWhatIsClonedFromWhereWithWhoseSignInAndHowFarGitIs() throws {
        let card = try #require(FleetCloningCard.make(Self.record()))
        #expect(card.host == "Mac Studio" && card.state == "Cloning" && card.progress == "receiving objects" && card.fraction == 0.37)
        #expect(card.summary == "Cloning orders-svc from github.com/acme/orders-svc with Mac Studio's git sign-in. The thread starts when it finishes.")
    }

    @Test func aCloneFromABundleSaysOriginWasOutOfReachAndShowsTheTransferUntilGitBegins() throws {
        var record = Self.record(clone: FleetCloneProgress(name: "orders-svc", source: "MacBook Pro", viaBundle: true))
        record.snapshotBytes = 4_000_000
        record.snapshotProgress = 1_000_000
        let card = try #require(FleetCloningCard.make(record))
        #expect(card.summary.hasPrefix("Mac Studio couldn't reach github.com/acme/orders-svc's origin, so MacBook Pro sent it the repository itself"))
        #expect(card.progress == "receiving the repository" && card.fraction == 0.25)
        record.clone?.phase = "resolving deltas"
        record.clone?.fraction = 0.9
        #expect(FleetCloningCard.make(record)?.progress == "resolving deltas" && FleetCloningCard.make(record)?.fraction == 0.9)
    }

    @Test func onlyAPreparingRecordThatIsCloningDrawsTheCard() {
        #expect(FleetCloningCard.make(Self.record(clone: nil)) == nil)
        #expect(FleetCloningCard.make(Self.record(state: .running)) == nil)
    }

    @Test func aCloningDispatchIsACloningStateCardThatCanBeStopped() throws {
        let context = FleetCardContext(snapshot: P.snapshot(), locale: P.en, calendar: P.utc)
        let card = FleetDispatchPresentation.card(Self.record(), among: [], in: context)
        #expect(card.pill == "Cloning" && card.layout == .state && card.actions == [.cancel] && card.sending == nil)
        #expect(card.cloning?.progress == "receiving objects" && card.detail.hasPrefix("Cloning orders-svc from github.com/acme/orders-svc"))
    }

    @Test func theMacCardNamesTheRepositoriesBeingClonedThereAndTheLogSaysCloning() throws {
        var snapshot = P.snapshot()
        snapshot.dispatches = [Self.record()]
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, locale: P.en, calendar: P.utc, now: Date(timeIntervalSince1970: 100))
        #expect(page.cards.first { $0.id == P.studio }?.cloning == ["orders-svc"])
        #expect(page.cards.filter { $0.id != P.studio }.allSatisfy { $0.cloning.isEmpty })
        #expect(page.dispatches.first?.state == "Cloning")
    }

    @Test func aDispatchThatCouldNotCloneSaysGitsWordsAndTheLogSaysTheMacCouldNot() throws {
        var record = Self.record(clone: nil, state: .failed)
        record.failure = FleetDispatchCode.repoMissing
        record.failureDetail = "fatal: repository 'https://example.test/acme/orders-svc.git/' not found"
        let context = FleetCardContext(snapshot: P.snapshot(), locale: P.en, calendar: P.utc)
        let card = FleetDispatchPresentation.card(record, among: [], in: context)
        #expect(card.detail == "The studio doesn't have orders-svc and couldn't clone it: fatal: repository 'https://example.test/acme/orders-svc.git/' not found. Run this here, or try again once it can.")
        #expect(FleetPagePresentation.dispatchRow(record, now: Date(timeIntervalSince1970: 100)).reason.hasPrefix("That Mac doesn't have this repository and couldn't clone it: fatal:"))
    }

    @Test func aMacWithoutTheRepoIsStillAPlaceInTheNewThreadPicker() throws {
        var snapshot = FleetDispatchPresentationTests.withOrders()
        let picker = FleetWherePicker.make(snapshot: snapshot, pick: .mac(P.studio), repoKey: FleetDispatchPresentationTests.orders, repoName: "orders-svc",
                                           autoDispatch: true, weight: { _ in .normal }, locale: P.en, calendar: P.utc)
        let studio = try #require(picker.options.first { $0.name == "Mac Studio" })
        #expect(studio.selectable, "a Mac without the repo is chosen, never greyed out")
        // An awake Mac without it says it will clone, once.
        for index in snapshot.macs.indices where snapshot.macs[index].hostID == P.mini { snapshot.macs[index].readiness?.repoKeys = [] }
        let awake = FleetWherePicker.make(snapshot: snapshot, pick: .mac(P.mini), repoKey: FleetDispatchPresentationTests.orders, repoName: "orders-svc",
                                          autoDispatch: true, weight: { _ in .normal }, locale: P.en, calendar: P.utc)
        let mini = try #require(awake.options.first { $0.name == "Mac mini" })
        #expect(mini.selectable && mini.detail.hasSuffix("Will clone (first time)"))
        #expect(awake.note == "Mac mini clones orders-svc first, then runs in a new worktree from its base branch.")
    }
}
