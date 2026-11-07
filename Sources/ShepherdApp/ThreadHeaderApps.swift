import SwiftUI
import ShepherdSessions
import ShepherdUI

/// The thread header's Run button (AppsQuickAction, AppsRunning boards): the space's first quick
/// action, or the app running now with its port and Stop (its name shows its output), and ▾
/// listing every quick action in the space, then Add or edit apps….
struct ThreadAppsButton: View {
    let apps: QuickApps
    let run: (AppKey) -> Void
    let stop: (AppKey) -> Void
    let restart: (AppKey) -> Void
    let output: (AppKey) -> Void
    let edit: () -> Void

    var body: some View {
        let primary = apps.primary
        HStack(spacing: 0) {
            if primary.running {
                Button { output(primary.key) } label: {
                    HStack(spacing: SH.Space.s) {
                        SHStatusDot(primary.status == .starting ? .running : .done)
                        Text(primary.app.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                        if let port = primary.portLabel { Text(port).font(.sh(.mono)).foregroundStyle(Color.sh.textSecondary) }
                    }
                    .padding(.horizontal, SH.Space.m)
                    .frame(height: SH.Height.controlS)
                }
                .buttonStyle(.shRow())
                .help("Show \(primary.app.name)’s output")
                .accessibilityLabel("\(primary.app.name), running. Show output")
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
                            Text("$ " + process.command).foregroundStyle(Color.sh.textTertiary)
                                .padding(.bottom, SH.Space.m)
                        }
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index].isEmpty ? " " : lines[index]).foregroundStyle(Color.sh.textPrimary)
                        }
                        Color.clear.frame(height: 1).id("tail")
                    }
                    .font(.sh(.code))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SH.Space.l)
                    .padding(.vertical, SH.Space.m)
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
        .background(Color.sh.bgWindow)
        .task(id: process?.revision) {
            lines = await vm.server.apps.lines(app, tail: AppProcesses.maxLines)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name) output")
    }
}
