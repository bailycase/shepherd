import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Slice 4f: work on any project from any Mac, in light and dark: the "Cloning" card (FleetStates), the Mac card's repo chip and the Dispatches
/// row while a clone runs, and the New thread popover offering a Mac that would clone the repo first. Fixture Macs and made-up names only.
@Suite("Fleet clone previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetClonePreviewTests {
    typealias P = FleetPagePreviewTests
    typealias D = FleetDispatchPreviewTests
    static let orders = "github.com/acme/orders-svc"

    /// A dispatch whose target is cloning `orders-svc`.
    static func cloning(_ clone: FleetCloneProgress, title: String = "Profile the orders import", at: Double = 100, bytes: UInt64? = nil, sent: UInt64? = nil) -> FleetDispatchRecord {
        var record = D.record(.preparing, title: title, target: P.studio, host: "Mac Studio", reasons: [FleetPlacementReason(.named), FleetPlacementReason(.willClone)], at: at)
        record.repoKey = Self.orders
        record.commitSHA = nil
        record.clone = clone
        record.snapshotBytes = bytes
        record.snapshotProgress = sent
        return record
    }

    // MARK: FleetStates: Cloning

    @Test func theCloningCardsAndTheOnesThatCouldNotClone() async throws {
        var failed = D.record(.failed, title: "Index the orders docs", target: P.studio, host: "Mac Studio", failure: FleetDispatchCode.repoMissing, at: 90)
        failed.repoKey = Self.orders
        failed.failureDetail = "fatal: unable to access 'https://github.com/acme/orders-svc.git/': Could not resolve host: github.com"
        let records = [
            Self.cloning(FleetCloneProgress(name: "orders-svc", source: Self.orders, phase: "receiving objects", fraction: 0.37), at: 100),
            Self.cloning(FleetCloneProgress(name: "orders-svc", source: "MacBook Pro", viaBundle: true), title: "Profile cold launch", at: 95, bytes: 48_000_000, sent: 19_000_000),
            failed,
        ]
        let cards = FleetDispatchPresentation.cards(records, in: D.context)
        #expect(cards.first { $0.title == "Profile the orders import" }?.cloning?.progress == "receiving objects")
        try await Preview.renderMatrix("fleet4f-states", size: CGSize(width: 760, height: 640)) {
            ScrollView {
                VStack(spacing: SH.Space.l) {
                    ForEach(cards) { FleetDispatchCardView(card: $0, actions: FleetThreadActions()).equatable() }
                }
                .padding(SH.Space.xxl)
            }
            .frame(width: 760, height: 640)
            .background(Color.sh.bgWindow)
        }
    }

    // MARK: The Fleet page

    @Test func theFleetPageShowsTheRepoBeingClonedAndTheDispatchesRow() async throws {
        var snapshot = P.snapshot
        // Mac Studio is up for this one.
        for index in snapshot.peers.indices where snapshot.peers[index].hostID == P.studio { snapshot.peers[index].link = .connected }
        snapshot.dispatches = [Self.cloning(FleetCloneProgress(name: "orders-svc", source: Self.orders, phase: "receiving objects", fraction: 0.37)), D.record(.running, at: 90)]
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: { _ in .normal }, autoDispatch: true)
        #expect(page.cards.first { $0.id == P.studio }?.cloning == ["orders-svc"] && page.dispatches.first?.state == "Cloning")
        try await Preview.renderMatrix("fleet4f-page", size: CGSize(width: 1208, height: 900)) {
            FleetPageContent(page: page, actions: P.noActions).frame(width: 1208, height: 900)
        }
    }

    // MARK: FleetNewThread

    /// orders-svc is checked out on This Mac and Mac mini, not on Mac Studio (asleep): the board's popover, now with its copy for a Mac
    /// that would clone first. `miniClones` has the awake Mac mini lack it too, so its row says it will clone (first time).
    @Test func newThreadOffersAMacThatWouldCloneTheRepoFirst() async throws {
        for (name, miniClones) in [("fleet4f-new-thread-popover", false), ("fleet4f-new-thread-popover-awake", true)] {
            let workspace = try PreviewWorkspace()
            defer { workspace.stop() }
            let vm = workspace.vm
            var space = Space(name: "orders-svc", path: workspace.dir.path)
            space.repoKey = Self.orders
            try await workspace.seed(ShepherdState(spaces: [space]))
            P.seedFleet(workspace)
            var snapshot = P.snapshot
            for index in snapshot.macs.indices where snapshot.macs[index].hostID != P.studio {
                let holds = !(miniClones && snapshot.macs[index].hostID == P.mini)
                snapshot.macs[index].readiness?.repoKeys = holds ? [Self.orders] : []
                snapshot.macs[index].readiness?.missing = []
            }
            vm.fleetPage.update(snapshot)
            vm.openNewThread()
            try await eventuallyOnMain("the New thread page's defaults") { !vm.newThread.loadingDefaults && vm.newThread.place != nil }
            vm.newThread.prompt = "Profile the orders import and cut its memory in half"
            if miniClones { vm.newThread.wherePick = .mac(P.mini) }
            let picker = vm.newThread.fleetPicker(vm)
            if miniClones {
                #expect(picker.options.first { $0.name == "Mac mini" }?.detail.hasSuffix("Will clone (first time)") == true)
                #expect(picker.options.first { $0.name == "Mac mini" }?.selectable == true)
                #expect(picker.note?.hasPrefix("Mac mini clones orders-svc first") == true)
            } else {
                #expect(picker.footnote == "orders-svc is checked out on This Mac and Mac mini. Mac Studio would clone it first.")
                #expect(picker.options.first { $0.name == "Mac Studio" }?.selectable == true, "a Mac without the repo is never greyed out")
            }
            try await Preview.renderMatrix(name, size: CGSize(width: 1280, height: 760)) {
                NewThreadPage(vm: vm, chrome: PageHeaderChrome(), whereOpen: true)
            }
        }
    }
}
