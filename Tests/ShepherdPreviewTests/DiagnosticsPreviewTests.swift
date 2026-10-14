import Foundation
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Diagnostics previews", .mainActorExclusive)
@MainActor
struct DiagnosticsPreviewTests {
    @Test(arguments: ["off", "pending", "active", "unconfigured"])
    func consentStates(_ state: String) async throws {
        let settings = AppSettings(store: ScratchDefaults())
        settings.shareDiagnostics = state == "pending" || state == "active"
        try await Preview.renderMatrix("diagnostics-\(state)", size: CGSize(width: 800, height: 440)) {
            SettingsPage(title: "Advanced", explanation: "Files, resets and app updates. Quitting Shepherd stops every agent.") {
                DiagnosticsSettings(settings: settings, configured: state != "unconfigured", active: state == "active")
            }
            .padding(AppLayout.settingsWideSides)
            .frame(width: 800, height: 440, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }
}
