import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Sending while pi works, as chosen on 2026-09-30: ↩ steers at pi's next step, waiting for the
/// turn to end is the other setting, and ⌘↩ steers now. The Send menu with its three rows, the
/// Settings ▸ Agents row in each mode, and Up next in each mode, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    @Test func steerChoices() async throws {
        // Steering is the default: a message handed to pi sits above the queue with its pill.
        let steering = QueueStackFixture(["Don’t touch the migrations in this PR.", "Also cover partial refunds in the tests.",
                                          "Then open a draft PR."], steering: 1)
        // Waiting: the messages hold for the turn's end, numbered in the order they go.
        let waiting = QueueStackFixture(["Also cover partial refunds in the tests.", "Then open a draft PR."])
        // Steer now, while pi stops: the message is first, still queued, until the host has sent it.
        let stopping = QueueStackFixture(["Stop, and use the ledger fixtures instead.", "Also cover partial refunds in the tests.",
                                          "Then open a draft PR."])
        let all = [steering, waiting, stopping]
        defer { all.forEach { $0.store.stop() } }
        let size = CGSize(width: 1180, height: 1040)
        try await Preview.render("steer-choices", size: size, ready: {
            all.allSatisfy { $0.store.ready && !$0.state.rows.isEmpty }
        }) {
            SteerChoicesBoard(steering: steering, waiting: waiting, stopping: stopping)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }
}

private struct SteerChoicesBoard: View {
    let steering, waiting, stopping: QueueStackFixture
    private let keys = KeybindingsStore(store: ScratchDefaults())

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    label("SendMenu · Return steers at the next step (the default)")
                    NWSendMenu(options: Composer.sendOptions(.steer, send: keys.sendDisplay, alternate: keys.display(.alternateSend)),
                               highlighted: 1, onChoose: { _ in }, onClose: {})
                }
                VStack(alignment: .leading, spacing: 10) {
                    label("SendMenu · Return waits for the turn to end")
                    NWSendMenu(options: Composer.sendOptions(.queue, send: keys.sendDisplay, alternate: keys.display(.alternateSend)),
                               highlighted: 0, onChoose: { _ in }, onClose: {})
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                label("Settings ▸ Agents · While the agent is working · steering (default)")
                SettingsGroup(title: "While the agent is working") {
                    ReturnWhileWorkingRow(selection: .constant(.steer), keys: keys)
                }
                label("Settings ▸ Agents · waiting")
                SettingsGroup(title: "While the agent is working") {
                    ReturnWhileWorkingRow(selection: .constant(.queue), keys: keys)
                }
            }
            .frame(width: 900, alignment: .leading)
            HStack(alignment: .top, spacing: 16) {
                cell("Up next · steering (Return steers): Steering row, then the queue", steering)
                cell("Up next · waiting (Return waits)", waiting)
                cell("Up next · Steer now under way: first, until the host sends it", stopping)
            }
        }
        .padding(32)
    }

    private func cell(_ title: String, _ fixture: QueueStackFixture) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            label(title)
            fixture.fixture.stack().frame(width: 340)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.nwMono(11)).foregroundStyle(Color.nw.textSecondary)
    }
}
