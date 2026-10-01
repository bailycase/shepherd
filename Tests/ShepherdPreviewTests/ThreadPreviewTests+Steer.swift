import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Sending while pi works, as chosen on 2026-09-30: ↩ queues the message for the turn's end, and
/// Steer now (⌘↩, the Send menu's row, a queued row's Steer) stops pi and sends at once. Nothing
/// steers at the next step. The Send menu with its two rows, and Up next in the normal flow and
/// where Steer now falls back to a steer, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    @Test func steerChoices() async throws {
        // Return queued them: numbered in the order they go.
        let queued = QueueStackFixture(["Also cover partial refunds in the tests.", "Then open a draft PR."])
        // The pointer on a queued row: its Steer now, Edit and Delete.
        let hovered = QueueStackFixture(["Also cover partial refunds in the tests.", "Then open a draft PR."])
        // Steer now, while pi stops: the message is first, still queued, until the host has sent it.
        let stopping = QueueStackFixture(["Stop, and use the ledger fixtures instead.", "Also cover partial refunds in the tests.",
                                          "Then open a draft PR."])
        // Steer now on a host that can't stop pi (or during a compaction): a steer, until pi reads it.
        let fallback = QueueStackFixture(["Don’t touch the migrations in this PR.", "Also cover partial refunds in the tests.",
                                          "Then open a draft PR."], steering: 1)
        let all = [queued, hovered, stopping, fallback]
        defer { all.forEach { $0.store.stop() } }
        final class Once { var seeded = false }
        let once = Once()
        let size = CGSize(width: 1180, height: 760)
        try await Preview.render("steer-choices", size: size, ready: {
            guard all.allSatisfy({ $0.store.ready && !$0.state.rows.isEmpty }) else { return false }
            if !once.seeded {
                once.seeded = true
                hovered.state.hover(hovered.id(0).uuidString).hovering = true
            }
            return true
        }) {
            SteerChoicesBoard(queued: queued, hovered: hovered, stopping: stopping, fallback: fallback)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }
}

private struct SteerChoicesBoard: View {
    let queued, hovered, stopping, fallback: QueueStackFixture
    private let keys = KeybindingsStore(store: ScratchDefaults())

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 10) {
                label("SendMenu · Return waits for the turn to end, ⌘↩ steers now")
                NWSendMenu(options: Composer.sendOptions(send: keys.sendDisplay, alternate: keys.display(.alternateSend)),
                           onChoose: { _ in }, onClose: {})
                label(Composer.sendHelp(working: true, send: keys.sendDisplay, alternate: keys.display(.alternateSend)))
                    .padding(.top, 4)
            }
            HStack(alignment: .top, spacing: 16) {
                cell("Up next · Return queued them", queued)
                cell("Up next · hover: Steer now (tooltip: Stop the agent and send this now)", hovered)
            }
            HStack(alignment: .top, spacing: 16) {
                cell("Up next · Steer now under way: first, still queued, until the host sends it", stopping)
                cell("Up next · Steer now fell back to a steer (a host that can't stop pi, a compaction)", fallback)
            }
        }
        .padding(32)
    }

    private func cell(_ title: String, _ fixture: QueueStackFixture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label(title)
            fixture.fixture.stack().frame(width: 540)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.nwMono(11)).foregroundStyle(Color.nw.textSecondary)
    }
}
