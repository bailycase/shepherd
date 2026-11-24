import SwiftUI
import ShepherdSessions
import ShepherdUI

/// The thread header's app chip (GXAppsRun, GXAppsRunning boards), in the toolbar's trailing capsule: ▶ and
/// the space's first quick action, or while an app runs its name, port and ■ (a click stops it); with ▾
/// listing every quick action in the space, each app's output while it runs, then Add or edit apps….
/// A rule separates it from the capsule's buttons.
struct ThreadAppsButton: View {
    let apps: QuickApps
    let run: (AppKey) -> Void
    let stop: (AppKey) -> Void
    let restart: (AppKey) -> Void
    let output: (AppKey) -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        let primary = apps.primary
        HStack(spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.s) {
                if primary.running {
                    Button { stop(primary.key) } label: {
                        HStack(spacing: SH.Space.s) {
                            Text(primary.app.name).foregroundStyle(Color.sh.textPrimary)
                            if let port = primary.portLabel { Text(port).foregroundStyle(Color.sh.textTertiary) }
                            Image(systemName: "stop.fill").font(.sh(.micro)).foregroundStyle(Color.sh.textPrimary)
                                .accessibilityHidden(true)
                        }
                        .font(.sh(.ui, weight: .regular))
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Stop \(primary.app.name)")
                    .accessibilityLabel("Stop \(primary.app.name)")
                    .accessibilityValue(primary.status == .starting ? "starting" : "running")
                } else {
                    Button { run(primary.key) } label: {
                        Label(primary.app.name, systemImage: "play.fill")
                            .font(.sh(.ui, weight: .regular))
                            .labelStyle(AppRunLabelStyle())
                            .frame(maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Run \(primary.app.name)")
                    .accessibilityLabel("Run \(primary.app.name)")
                }
                menu
            }
            .padding(.leading, AppLayout.appsChipLeading)
            .padding(.trailing, SH.Space.m)
            .frame(height: SH.Height.controlM)
            .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            SHHairline(.vertical).frame(height: AppLayout.appsChipRule).padding(.horizontal, SH.Space.xxs)
        }
    }

    private var menu: some View {
        Menu {
            Section("Apps in \(apps.space)") {
                ForEach(apps.items) { item in
                    Button {
                        switch item.status {
                        case .starting?, .running?: stop(item.key)
                        case .exited?: restart(item.key)
                        default: run(item.key)
                        }
                    } label: {
                        Label {
                            Text(item.app.name)
                            Text(item.menuDetail)
                        } icon: {
                            Image(systemName: item.running ? "stop.fill" : "play.fill")
                        }
                    }
                }
            }
            let running = apps.items.filter { $0.status != nil }
            if !running.isEmpty {
                Section("Output") {
                    ForEach(running) { item in
                        Button("Show \(item.app.name)’s Output") { output(item.key) }
                    }
                }
            }
            Divider()
            Button("Add or edit apps…", action: edit)
        } label: {
            Image(systemName: "chevron.down").font(.sh(.micro)).foregroundStyle(Color.sh.textTertiary)
                .padding(.horizontal, SH.Space.xs)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Apps in \(apps.space)")
    }
}

extension QuickApps.Item {
    /// The menu row's second line: where it opens, or what it is doing.
    var menuDetail: String {
        switch status {
        case .starting?: "Starting… · Stop"
        case .running?: ["Running", portLabel].compactMap { $0 }.joined(separator: " · ") + " · Stop"
        case .exited(let code)?: "Exited (code \(code)) · Restart"
        case .failed?, nil: place
        }
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

/// An app's output in the terminal panel (AppsRunning): a read-only log of what it printed, last
/// line at the bottom, following the tail. Closing its tab closes this view; the app runs on.
/// After the app ends, its exit and Restart sit under the log.
struct AppLogView: View {
    var vm: ShepherdViewModel
    let app: AppKey
    @State private var lines: [String] = []

    var body: some View {
        let process = vm.apps.process(app)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let process {
                            Text("$ " + process.command).foregroundStyle(Color.sh.textPrimary)
                                .padding(.bottom, SH.Space.m)
                        }
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index].isEmpty ? " " : lines[index]).foregroundStyle(Color.sh.textSecondary)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .font(.sh(.code))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SHTerminalMetrics.contentPadding.leading)
                    .padding(.vertical, SHTerminalMetrics.contentPadding.top)
                }
                .onChange(of: lines.count) { proxy.scrollTo("tail", anchor: .bottom) }
            }
            if let process, !process.status.isLive {
                SHHairline()
                HStack(spacing: SH.Space.m) {
                    AppStatusLabel(process: process)
                    Spacer(minLength: 0)
                    if case .exited = process.status {
                        Button { vm.restartApp(app) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                            .buttonStyle(.sh(.secondary, size: .s))
                            .accessibilityLabel("Restart \(app.name)")
                    }
                }
                .padding(.horizontal, SH.Space.l)
                .frame(height: SH.Height.controlL + SH.Space.m)
            }
        }
        // On the panel's card, as the terminals beside it are.
        .background(Color.sh.bgRaised)
        .task(id: process?.revision) {
            // ponytail: the whole tail again per revision (the host's pushes are at most 10/s); ask
            // for the lines after the last one read if a chatty app's output costs too much.
            lines = await vm.appOutput(app, tail: AppProcesses.maxLines)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name) output")
    }
}
