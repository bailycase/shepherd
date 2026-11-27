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
}
