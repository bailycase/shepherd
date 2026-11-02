import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Remote host update UI in every phase, rendered through the real `HostUpdateContent` view
/// (the same component `RemoteHostUpdateRow` uses in production). No network, no client.
@Suite("Remote host update previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct HostUpdatePreviewTests {
    /// Every update phase as `HostUpdateContent` — the real production component.
    @Test func remoteHostUpdatePhases() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        _ = try await host.server.createSession(params: CreateSessionParams(cwd: host.dir.path, command: ["/bin/cat"]))
        let blockReason = await host.server.hostUpdateBlockReason()
        let phases: [(String, HostUpdateStatus?, Bool, String?)] = [
            ("up-to-date",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .upToDate),
             false, nil),
            ("checking",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .checking),
             true, nil),
            ("available",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .available,
                               offerID: UUID(), offeredVersion: "1.5.0", canInstall: true),
             false, nil),
            ("available-busy",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .available,
                               offerID: UUID(), offeredVersion: "1.5.0",
                               error: blockReason, canInstall: false),
             false, nil),
            ("downloading",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .downloading),
             true, nil),
            ("installing",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .installing),
             true, nil),
            ("failed",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .failed,
                               error: "Signature verification failed."),
             false, nil),
            ("unsupported",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .unsupported,
                               error: "This is a development build."),
             false, nil),
            ("nightly-available",
             HostUpdateStatus(version: "1.5.0-beta.3", build: "503", channel: "nightly", phase: .available,
                               offerID: UUID(), offeredVersion: "1.5.0-beta.4", canInstall: true),
             false, nil),
            ("status-unavailable", nil, false, nil),
            ("status-loading", nil, true, nil),
            ("connection-lost",
             HostUpdateStatus(version: "1.4.2", build: "142", channel: "main", phase: .available,
                               offerID: UUID(), offeredVersion: "1.5.0", canInstall: true),
             false, "Connection lost during update. Reconnect to verify whether it succeeded."),
        ]
        let size = CGSize(width: 1440, height: CGFloat(phases.count) * 100 + 40)
        try await Preview.renderMatrix("settings-remote-host-update-phases", size: size) {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                ForEach(phases, id: \.0) { label, status, polling, error in
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(label).font(.sh(.caption, weight: .semibold)).foregroundStyle(Color.sh.textTertiary)
                        HostUpdateContent(
                            hostName: "horizon",
                            status: status,
                            polling: polling,
                            error: error
                        )
                    }
                    .padding(.horizontal, SH.Space.xl)
                }
            }
            .padding(AppLayout.settingsWideSides)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}
