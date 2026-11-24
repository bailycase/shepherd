import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A thread running on another Mac (GXRemote board), in light and dark: the title with "on mini ⌄" and the menu behind it, built from the
/// same move targets and sender the app derives. The popover itself can't open off-screen, so the menu is drawn under the title.
@Suite("Remote thread previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct RemoteThreadPreviewTests {
    typealias P = FleetPagePreviewTests

    @Test func theTitleNamesTheMacAndItsMenuMovesAndLinksBack() async throws {
        let header = FleetMovePreviewTests.header(host: P.mini)
        let from = DispatchedFrom(hostID: P.here, hostName: "MacBook Pro", agentID: FleetDispatchPreviewTests.sender,
                                  agentTitle: FleetDispatchPreviewTests.senderTitle, dispatchID: UUID(), at: 1_758_830_040_000)
        let sentBy = FleetSentBy(from, host: "mini", viewer: P.mini)
        #expect(header.menu.targets.map(\.enabled) == [true, false])
        let fixture = ThreadFixture(FleetDispatchPreviewTests.dispatchedSnapshot(sentBy: FleetDispatchPreviewTests.senderTitle))
        defer { fixture.store.stop() }
        try await Preview.render("remote-thread", size: CGSize(width: 1000, height: 420), ready: { fixture.store.ready }) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ThreadHeader(store: fixture.store, project: "payments-api", title: "Fix flaky payment test", move: header, moveTo: { _ in },
                                 sentBy: sentBy, openSender: {}, remoteHost: "mini")
                    ThreadView(store: fixture.store, active: true, isFocused: false, request: fixture.request, commandKey: "preview",
                               agentName: "Fix flaky payment test", workingDirectory: "~/Developer/payments-api", inspectSubagent: nil, review: { _ in })
                }
                RemoteThreadMenu(host: "mini", targets: header.menu.targets, sender: sentBy.sender, openSender: {}, moveTo: { _ in }, close: {})
                    .offset(x: 300, y: 42)
            }
            .background(Color.sh.bgWindow)
            .environment(\.threadCommands, fixture.commands)
        }
    }

    /// The card of a thread on another Mac: its branch, "Runs on mini", and the other branches there; no numbers or actions that need
    /// the checkout.
    @Test func theCardNamesTheMacItRunsOn() async throws {
        let card = BranchCardModel(space: "payments-api", branch: "agent/flaky-payment-test", worktree: false, directory: nil, others: [
            BranchCardOther(id: AgentID(), branch: "agent/webhook-retries", state: .attention, detail: "asked you"),
            BranchCardOther(id: AgentID(), branch: "baily/ledger-refactor", state: .idle, detail: "3d")])
        let store = BranchCardStore(handle: BranchCardHandle(agentID: AgentID(), card: { card }, load: { _ in BranchCardStatus(git: BranchCardGit()) },
                                                             perform: { _ in }))
        await store.refresh()
        try await Preview.render("remote-card", size: CGSize(width: 420, height: 240)) {
            BranchCardOverlay(store: store, branch: card.branch, active: true, wide: true, runsOn: "mini")
                .frame(width: 420, height: 240, alignment: .topTrailing)
                .background(Color.sh.bgWindow)
        }
    }
}
