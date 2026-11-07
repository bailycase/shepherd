import SwiftUI
import ShepherdUI

/// The thread header's Run button (AppsQuickAction, AppsRunning boards): the space's first quick
/// action, or the app running now with its port and Stop, and ▾ listing every quick action in
/// the space, then Add or edit apps….
struct ThreadAppsButton: View {
    let apps: QuickApps
    let run: (AppKey) -> Void
    let stop: (AppKey) -> Void
    let edit: () -> Void

    var body: some View {
        let primary = apps.primary
        HStack(spacing: 0) {
            if primary.running {
                HStack(spacing: SH.Space.s) {
                    SHStatusDot(.done)
                    Text(primary.app.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                    if let port = primary.port { Text(port).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary) }
                }
                .padding(.horizontal, SH.Space.m)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(primary.app.name), running")
                divider
                Button { stop(primary.key) } label: {
                    Image(systemName: "stop.fill").font(.sh(.micro)).frame(width: SH.Height.controlS, height: SH.Height.controlS)
                }
                .buttonStyle(.shRow())
                .help("Stop \(primary.app.name)")
                .accessibilityLabel("Stop \(primary.app.name)")
            } else {
                Button { run(primary.key) } label: {
                    Label(primary.app.name, systemImage: "play.fill")
                        .font(.sh(.ui))
                        .labelStyle(AppRunLabelStyle())
                        .padding(.horizontal, SH.Space.m)
                        .frame(height: SH.Height.controlS)
                }
                .buttonStyle(.shRow())
                .help("Run \(primary.app.name)")
                .accessibilityLabel("Run \(primary.app.name)")
            }
            divider
            Menu {
                Section("Apps in \(apps.space)") {
                    ForEach(apps.items) { item in
                        Button {
                            item.running ? stop(item.key) : run(item.key)
                        } label: {
                            Label {
                                Text(item.app.name)
                                Text(item.running ? "Running · Stop" : item.place)
                            } icon: {
                                Image(systemName: item.running ? "stop.fill" : "play.fill")
                            }
                        }
                    }
                }
                Divider()
                Button("Add or edit apps…", action: edit)
            } label: {
                Image(systemName: "chevron.down").font(.sh(.micro)).frame(width: SH.Height.controlS, height: SH.Height.controlS)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.shRow())
            .fixedSize()
            .accessibilityLabel("Apps in \(apps.space)")
        }
        .padding(SH.Space.xxs)
        .frame(height: SH.Height.controlM)
        .shBorder(Color.sh.lineStrong, radius: SH.Radius.s)
        .fixedSize()
    }

    private var divider: some View {
        SHHairline(.vertical).frame(height: SH.Height.controlS - SH.Space.m)
    }
}

/// ▶ and the app's name, 6pt apart, the glyph small.
struct AppRunLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.s) {
            configuration.icon.font(.sh(.micro))
            configuration.title
        }
        .foregroundStyle(Color.sh.textPrimary)
    }
}
