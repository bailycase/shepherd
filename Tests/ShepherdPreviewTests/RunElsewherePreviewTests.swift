import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdUI
@testable import ShepherdApp

/// Run on another host (ProjectRunElsewhere): the dialog over the rows its own producer derives from an owner's host list. The
/// hosts and the task are fixtures.
@Suite("Run on another host previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct RunElsewherePreviewTests {
    @Test func theDialogOverFourHosts() async throws {
        let web = Space(name: "demo-web", path: "/demo-web")
        let build = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let studio = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let options = [ProjectHostOption(reference: .local, name: "demo-mac", spaces: [web]),
                       ProjectHostOption(reference: build, name: "build-01", spaces: [web]),
                       ProjectHostOption(reference: studio, name: "studio", spaces: [web])]
        let rows = RunElsewhereHosts.rows(options: options, settings: .init(hostPolicy: .anyConnected), from: build, spaceName: "demo-web",
                                          ownerName: "This Mac", running: { [.local: 2, build: 1, studio: 0][$0] ?? nil },
                                          offline: [.init(id: UUID(), name: "horizon", lastSeen: Date().addingTimeInterval(-3 * 3_600))])
        try await Preview.renderMatrix("run-elsewhere", size: CGSize(width: SHLeadMetrics.runElsewhereWidth, height: 640)) {
            RunElsewhereDialog(subtitle: "Reading widget mockup · now on build-01 in demo-web", rows: rows, chosen: rows.first?.id,
                               spaceName: "demo-web", status: nil, moving: false, canMove: true, pick: { _ in }, cancel: {}, move: {})
                .background(Color.sh.bgWindow)
        }
    }
}
