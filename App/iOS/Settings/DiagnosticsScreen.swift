import SwiftUI
import ShepherdUI

/// Settings ▸ Advanced: this device's switch for Sentry reports (`MobileDiagnostics`). On by
/// default; off stops at once, on again waits for the next launch.
struct DiagnosticsScreen: View {
    @AppStorage(MobileDiagnostics.shareKey) private var share = true

    var body: some View {
        SettingsPageScaffold("Advanced") {
            SettingsCard {
                SettingsControlRow("Share diagnostics",
                                   note: "Sends crashes, hangs, slow screens and performance profiles to Shepherd's Sentry, with a replay of the moments before an error where every text and image is masked. Never your prompts, code or replies.") {
                    Toggle("Share diagnostics", isOn: Binding(get: { share }, set: { on in
                        share = on
                        if !on { MobileDiagnostics.stop() }
                    }))
                    .toggleStyle(.settingsSwitch)
                    .labelsHidden()
                    .disabled(!MobileDiagnostics.configured)
                }
            }
            SettingsFootnote(MobileDiagnostics.configured
                ? "Turning it off stops reports now and deletes any not yet sent. Turning it on takes effect the next time Shepherd opens."
                : "This build has no diagnostics endpoint, so nothing is sent.")
        }
    }
}
