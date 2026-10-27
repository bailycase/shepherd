import SwiftUI
import ShepherdUI

/// Settings ▸ Diagnostics: this device's switch for Sentry reports (`MobileDiagnostics`). On by
/// default; off stops at once, on again waits for the next launch.
struct DiagnosticsScreen: View {
    @AppStorage(MobileDiagnostics.shareKey) private var share = true
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        let sh = Color.sh
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                HStack(alignment: .top, spacing: SH.Space.l) {
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        Text("Share diagnostics")
                            .font(.sh(.ui, weight: .semibold))
                            .foregroundStyle(sh.textPrimary)
                        Text("Sends crashes, hangs, slow screens and performance profiles to Shepherd's Sentry, with a replay of the moments before an error where every text and image is masked. Never your prompts, code or replies.")
                            .shText(size: MobileLayout.settingsNoteSize, lineHeight: MobileLayout.settingsNoteLineHeight)
                            .foregroundStyle(sh.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("Share diagnostics", isOn: Binding(get: { share }, set: { on in
                        share = on
                        if !on { MobileDiagnostics.stop() }
                    }))
                    .toggleStyle(.shSwitch)
                    .labelsHidden()
                    .disabled(!MobileDiagnostics.configured)
                }
                .padding(SH.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .shCard(radius: SHListMetrics.cardRadius)

                SettingsFootnote(MobileDiagnostics.configured
                    ? "Turning it off stops reports now and deletes any not yet sent. Turning it on takes effect the next time Shepherd opens."
                    : "This build has no diagnostics endpoint, so nothing is sent.")
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
