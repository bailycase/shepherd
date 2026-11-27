import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The workspace column of the thread boards (GXThread and its states): the 1440pt window less the sidebar's 256, 900pt tall, drawn as the
/// shell composes it, so a render lays beside the board's own column (its x from 256pt on) and differs only where the app does.
///
///     SHEPHERD_PREVIEW_DIR=/tmp/p SHEPHERD_PREVIEW_SCALE=2 scripts/check.py ShepherdPreviewTests GXBoardPreviewTests
@Suite("GX board previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct GXBoardPreviewTests {
    static let column = CGSize(width: 1184, height: 900)

    /// The card the boards draw: `agent/swiftui-previews`, +129 −59, pull request #412 with its checks passed, three new commits on main.
    static func branchStore(_ id: AgentID = AgentID()) -> (BranchCardStore, BranchCardModel) {
        let card = BranchCardModel(space: "Shepherd", branch: "agent/swiftui-previews", worktree: true, directory: nil, others: [
            BranchCardOther(id: AgentID(), branch: "agent/plan-extension", state: .running, detail: "running"),
            BranchCardOther(id: AgentID(), branch: "agent/refund-events", state: .idle, detail: "3d"),
        ])
        let pull = PullRequestSummary(ref: ForgeItemRef(kind: .pullRequest, repo: "shepherd-app/shepherd", number: 412), title: "Live previews",
                                      author: "baily", updatedAt: Date(), state: .open, checks: .passed, headRef: card.branch, baseRef: "main")
        let status = BranchCardStatus(git: BranchCardGit(additions: 129, deletions: 59, base: "main", behind: 3), pull: pull)
        return (BranchCardStore(handle: BranchCardHandle(agentID: id, card: { card }, load: { _ in status }, perform: { _ in })), card)
    }

    /// GXThread: the thread with its branch card docked at the right of the transcript.
    @Test func thread() async throws {
        let fixture = ThreadFixture(ActivityThreads.idle)
        defer { fixture.store.stop() }
        let (store, card) = Self.branchStore()
        try await Preview.render("gxb-thread", size: Self.column, ready: { fixture.store.ready && !fixture.store.rows.isEmpty && store.status != nil }) {
            fixture.thread(title: "Investigate SwiftUI live preview capabilities")
                .modifier(BranchCardDock(store: store, branch: card.branch, active: true))
                .background(Color.sh.bgWindow)
        }
    }

    /// GXSidePane: Changes, the branch card at its top, the thread beside it with no card of its own.
    @Test func sidePane() async throws {
        let fixture = ThreadFixture(ActivityThreads.idle)
        defer { fixture.store.stop() }
        let session = ChangesBoard.session(comment: false)
        let (store, _) = Self.branchStore()
        try await Preview.render("gxb-side-pane", size: SidePanePreviewTests.column, ready: { fixture.store.ready && store.status != nil }) {
            SidePanePreviewTests.PaneWindow(fixture: fixture) {
                VStack(spacing: 0) {
                    SHSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 7, browser: false, subagents: (5, .done), pullRequest: 412),
                                   selection: SidePaneTab.changes.rawValue, select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {
                        Button("Reset Width") {}
                    }
                    BranchCardPaneHost(store: store)
                    ReviewPane(session: session, actions: Reviews.actions)
                }
            }
            .task { await store.refresh() }
            .task { await fixture.store.run(request: fixture.request) }
        }
    }

    // MARK: Live states: what a person sees on a fresh Mac, through the real view model

    /// Fleet with only This Mac (FleetEmpty): the page invites the others; no list, no Auto line, no log.
    @Test func fleetWithOneMac() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        try await workspace.seed(ShepherdState())
        workspace.vm.fleet.onSnapshot = nil
        workspace.vm.fleetPage.update(FleetSnapshot(
            enabled: true, hostID: FleetPagePreviewTests.here, name: "MacBook Pro", addresses: ["192.168.1.40"], port: 7434, advertising: true, peers: [],
            macs: [FleetMacState(hostID: FleetPagePreviewTests.here, sample: FleetPressureSample(cpuUtilization: 0.81, cpuCount: 12, totalMemoryBytes: 48 << 30,
                                                                                                  availableMemoryBytes: 14 << 30, thermal: .nominal, activeAgents: 0),
                                 sampleAge: 1, readiness: FleetReadinessReport(model: "MacBook Pro", chip: "M4 Max", repos: ["Shepherd"]))]))
        workspace.vm.openDestination(.fleet)
        #expect(workspace.vm.fleetPage.page.cards.count == 1)
        try await Preview.render("gxb-fleet-one-mac", size: CGSize(width: 1440, height: 900)) { RootView(vm: workspace.vm) }
    }

    /// Designs with no designs (NavDesigns, SystemBuiltIn): the built-in Shepherd UI system is still there.
    @Test func designsWithNone() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        workspace.settings.designToolEnabled = true
        try await workspace.seed(ShepherdState())
        workspace.vm.openDestination(.designs)
        // The host registers Shepherd UI as it starts (`ShepherdHost.Services.configure`); the page reads it with the others.
        await workspace.vm.loadDesignSystems()
        try await eventuallyOnMain("the built-in system to load") {
            workspace.vm.designSystems.summaries.contains { $0.namespace == "shepherd-design" }
        }
        try await Preview.render("gxb-designs-none", size: CGSize(width: 1440, height: 900)) { RootView(vm: workspace.vm) }
    }
}
