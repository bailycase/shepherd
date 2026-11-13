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

/// Slice 4c's surfaces in light and dark: the "Sending with uncommitted changes" card (FleetStates) in its states, in the parent thread and on the Fleet page, and
/// Settings ▸ Fleet ▸ Code with its two rows (FleetSettings) and the per space list. Made up names throughout.
@Suite("Fleet snapshot previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL)"))
@MainActor
struct FleetSnapshotPreviewTests {
    static func record(_ title: String = "Fix flaky payment test", bytes: UInt64? = 2_800_000, sent: UInt64 = 1_800_000, files: Int = 3, warning: Bool = false) -> FleetDispatchRecord {
        FleetDispatchRecord(parentHostID: FleetPagePreviewTests.here, parentHostName: "MacBook Pro", parentTitle: "Speed up checkout CI", targetHostName: "Mac mini",
                            state: .preparing, title: title, task: "", repoKey: "github.com/acme/payments-api", commitSHA: "4e1c9a2ffffffffffffffffffffffffffffffff0",
                            snapshotBytes: bytes, snapshotProgress: sent, snapshotFiles: files, sendWarning: warning, createdAt: Date().timeIntervalSince1970 * 1000 - 5_000)
    }

    /// The card as FleetStates draws it, and its other states: nothing to send (warm), and above the warning size.
    @Test func sendingCard() async throws {
        let cards = [Self.record(), Self.record("Regenerate API client", bytes: 0, sent: 0, files: 1),
                     Self.record("Rebuild the search index", bytes: 1_400_000_000, sent: 410_000_000, files: 12, warning: true)]
            .map { FleetDispatchPresentation.card($0, among: [$0], in: FleetDispatchPreviewTests.context) }
        try await Preview.renderMatrix("4c-sending-card", size: CGSize(width: 960, height: 560)) {
            VStack(spacing: SH.Space.xl) { ForEach(cards) { FleetDispatchCardView(card: $0, actions: FleetThreadActions()).equatable() } }
                .padding(SH.Space.xxl).frame(width: 960, height: 560, alignment: .top).background(Color.sh.bgWindow)
        }
    }

    /// The thread that sent the work, while its dispatch's snapshot is on its way: the card sits where its `fleet_dispatch` call is.
    @Test func theParentThreadWhileTheSnapshotIsSending() async throws {
        let id = try #require(FleetDispatchID.forToolCall(FleetDispatchPreviewTests.toolCall, agent: FleetDispatchPreviewTests.sender))
        let fixture = ThreadFixture(FleetDispatchPreviewTests.parentSnapshot(done: false))
        defer { fixture.store.stop() }
        var record = Self.record()
        record.id = id
        record.parentAgentID = FleetDispatchPreviewTests.sender
        let surface = FleetDispatchPreviewTests.surface([record])
        try await Preview.renderMatrix("4c-parent-thread-sending", size: CGSize(width: 1000, height: 820), ready: { fixture.store.ready }) {
            fixture.thread(title: FleetDispatchPreviewTests.senderTitle).environment(\.fleetThread, surface)
        }
    }

    /// The Fleet page while one dispatch is sending: its card is the page's first, under the placement card.
    @Test func theFleetPageWhileADispatchIsSending() async throws {
        var snapshot = FleetPagePreviewTests.snapshot
        var sending = Self.record()
        sending.reasonCodes = [FleetPlacementReason(.localIneligible, skip: "cpu"), FleetPlacementReason(.mostRoom)]
        snapshot.dispatches = [sending]
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: { [FleetPagePreviewTests.mini: FleetSendWeight.prefer][$0] ?? .normal })
        try await Preview.renderMatrix("4c-page-dispatches-sending", size: CGSize(width: 1208, height: 1060)) {
            FleetPageContent(page: page, actions: FleetPagePreviewTests.noActions, cardActions: FleetThreadActions()).frame(width: 1208, height: 1060)
        }
    }

    /// Settings ▸ Fleet with its Code group, and the Ignored files sheet with a space's lists.
    @Test func settingsCode() async throws {
        let model = FleetPreviewTests.model(peers: FleetPreviewTests.peers)
        let spaces = [FleetExcludeSpace(id: SpaceID(rawValue: "acme-web"), name: "acme-web", excludes: FleetSnapshotExcludes(excluded: ["packages/web/dist", "secrets.local"], included: [".build"])),
                      FleetExcludeSpace(id: SpaceID(rawValue: "payments-api"), name: "payments-api", excludes: FleetSnapshotExcludes())]
        let code = FleetCodeSettings(uncommitted: .sendThem, setUncommitted: { _ in }, spaces: spaces, setExcludes: { _, _ in })
        try await Preview.renderMatrix("4c-settings-code", size: CGSize(width: 1000, height: 760)) {
            FleetSettings(model: model, serviceKeepsRunning: true, code: code).frame(width: 1000, height: 760).background(Color.sh.bgWindow)
        }
        try await Preview.renderMatrix("4c-settings-excludes", size: CGSize(width: 620, height: 520)) {
            FleetExcludesSheet(spaces: spaces, save: { _, _ in }, done: {}).frame(width: 620, height: 520).background(Color.sh.bgWindow)
        }
    }
}
