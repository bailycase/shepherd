import SwiftUI
import ShepherdUI

/// The one-time note over the workspace after an update moved this copy of Shepherd off the
/// retired nightly channel (`UpdateChannelStore`). Nothing is blocked while it shows; it stays
/// until dismissed or the download link is followed.
struct NightlyMovedNotice: View {
    let download: () -> Void
    let dismiss: () -> Void

    var body: some View {
        SHBanner(.idle, title: "Nightly builds are a separate app now",
                 message: "This copy of Shepherd moved to the Beta channel. Nightly builds ship as Shepherd Nightly, which runs beside it with its own agents and settings.",
                 systemImage: "moon") {
            Button("Get Shepherd Nightly", action: download)
                .buttonStyle(.sh(.secondary, size: .s))
            Button("Dismiss", action: dismiss)
                .buttonStyle(.sh(.ghost, size: .s))
        }
        .frame(maxWidth: AppLayout.threadMaxWidth)
        .padding(.horizontal, AppLayout.gutter)
        .padding(.top, SH.Space.l)
        .frame(maxWidth: .infinity)
    }
}
