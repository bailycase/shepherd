import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Apps on iPhone and iPad (SettingsApps, AppsSettings boards): every app on each host with
// its run, and one app's output, over `apps.v2`. Run, Stop and Restart go to the host; the apps
// themselves are read-only here (`ClientApps` keeps every rule; these views only draw).

/// Settings ▸ Apps: each connected host's own apps, then its spaces', each with what it is doing and a
/// button for what it does next. A row opens the app's output.
struct AppsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        let store = SettingsStore.of(hosts)
        let apps = store.apps
        SettingsPageScaffold(SettingsPage.apps.title, lead: "Things you run while you work, such as a dev server or Storybook, and what each is doing on its Mac. Add and edit them in Settings ▸ Apps on the Mac.", store: nil) {
                if store.hosts.isEmpty {
                    SettingsFootnote("Add a Mac in Settings ▸ Fleet to see its apps.")
                }
                ForEach(store.hosts) { host in
                    AppsHostSections(host: host, apps: apps, named: store.hosts.count > 1) { row in
                        navigator.open(.settings(.app(host: host.id, id: row.id)))
                    }
                }
        }
        .refreshable { await store.loadApps() }
        .task(id: store.appsInput) { await store.watchApps() }
    }
}

/// One host's apps: why they can't be shown, or its groups.
private struct AppsHostSections: View {
    let host: SettingsHost
    let apps: ClientApps
    /// Several Macs: each space's name says which one it is on.
    let named: Bool
    let open: (AppRowValue) -> Void

    var body: some View {
        switch apps.state(of: host) {
        case .offline:
            SettingsFootnote("\(host.name) is offline. Its apps show here once it's back.")
        case .unsupported:
            SettingsFootnote("\(host.name)'s Shepherd is too old to share its apps. Update it to see them here.")
        case .loading:
            SHBusyLabel("Reading the apps…").frame(maxWidth: .infinity)
        case .failed(let reason):
            SettingsFootnote(reason, tone: .failed)
        case .loaded(let page):
            if let problem = apps.problems[host.id] {
                SHBanner(.failed, title: problem) {
                    Button("OK") { apps.dismissProblem(host) }.buttonStyle(.settingsPill)
                }
            }
            ForEach(page.groups) { group in
                VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                    SettingsCaption(group.title) { if named && group.id != "mac" { SHHostBadge(host.name) } }
                    if group.rows.isEmpty {
                        SettingsCard {
                            Text("No apps yet")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SH.Space.l)
                                .frame(maxWidth: .infinity, minHeight: SHListMetrics.rowHeight, alignment: .leading)
                        }
                    } else {
                        SettingsLazyCard(group.rows) { row in
                            AppRow(row: row, busy: apps.isBusy(row, on: host)) { open(row) } act: {
                                Task { await apps.perform(row, on: host) }
                            }
                        }
                    }
                    SettingsFootnote(group.footnote)
                }
            }
        }
    }
}

/// One app: its name (with Quick action), where it opens and what it runs, what it is doing as a dot
/// and words, and the button for what it does next. The row opens its output.
private struct AppRow: View {
    let row: AppRowValue
    let busy: Bool
    let open: () -> Void
    let act: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.m) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    HStack(spacing: SH.Space.s) {
                        Text(row.name).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                        if row.quickAction { AppTag("Quick action") }
                    }
                    Text(row.subtitle).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                    if let status = row.status, let tone = row.tone { AppStatus(status, tone: tone) }
                    if let command = row.restartCommand { AppNote("Restart runs \(command)", mono: true) }
                    if let blocked = row.actionBlocked { AppNote(blocked) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, SH.Space.m)
                .contentShape(Rectangle())
            }
            .buttonStyle(.shRow(radius: 0))
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityHint("Shows its output")
            AppActionButton(row: row, busy: busy, act: act)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SHListMetrics.rowHeight)
    }
}

/// Run, Stop or Restart: waits while its request is on the way, and while a stop is.
private struct AppActionButton: View {
    let row: AppRowValue
    let busy: Bool
    let act: () -> Void

    var body: some View {
        Button(row.actionTitle, action: act)
            .buttonStyle(.settingsPill)
            .disabled(busy || row.stopping || row.actionBlocked != nil)
            .accessibilityLabel("\(row.actionTitle) \(row.name)")
            .accessibilityHint(row.actionBlocked ?? "")
    }
}

/// A state's dot and its words.
private struct AppStatus: View {
    let words: String
    let state: AgentState

    init(_ words: String, tone: AppsPresentation.Tone) {
        self.words = words
        state = AgentState(rawValue: tone.rawValue) ?? .idle
    }

    var body: some View {
        HStack(spacing: SH.Space.s) {
            SHStatusDot(state)
            Text(words).font(.sh(.caption)).foregroundStyle(state.textColor).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A line under an app's state: what its button will run, or why it does nothing.
private struct AppNote: View {
    let text: String
    let mono: Bool

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        Text(text)
            .font(mono ? .sh(.mono) : .sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(mono ? 1 : 2)
            .truncationMode(.middle)
    }
}

/// The small tag beside an app's name.
private struct AppTag: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.sh(.micro))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.s)
            .padding(.vertical, SH.Space.xxs)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .fixedSize()
    }
}

/// One app: what it is doing with its button, what it runs and where, then its output, the last lines
/// of it with the end in view while it is being written.
struct AppScreen: View {
    let hostID: UUID
    let rowID: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.settingsColumn) private var inColumn
    @State private var output: Output = .loading

    private enum Output: Equatable {
        case loading
        case lines([String])
        case failed(String)
    }

    /// What decides when the output is read again: the run's own revision, and whether it lives.
    private struct Reading: Equatable {
        var host: UUID
        var row: String
        var revision: Int?
        var live: Bool
    }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let apps = store.apps
        let host = store.hosts.first { $0.id == hostID }
        let state = host.map(apps.state)
        let row = state?.page?.row(rowID)
        VStack(spacing: 0) {
            if state == .loading {
                SHBusyLabel("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let host, let row {
                header(row, host: host, apps: apps)
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                        facts(row, host: host)
                        outputSection(row)
                    }
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.top, SH.Space.l)
                    .padding(.bottom, MobileLayout.sectionSpacing)
                    .frame(maxWidth: MobileLayout.homeMaxWidth)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
            } else {
                SettingsFootnote("This app isn't on \(host?.name ?? "the host") any more.")
                    .padding(MobileLayout.gutter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(Color.sh.bgWindow)
        .navigationTitle(row?.name ?? "App")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: Reading(host: hostID, row: rowID, revision: row?.run?.revision, live: row?.run?.isLive == true)) {
            guard let host = store.hosts.first(where: { $0.id == hostID }), let row, row.run != nil else { return }
            do { output = .lines(try await apps.output(of: row, on: host)) } catch { output = .failed(settingsProblem(error)) }
        }
        // Opened on its own (a restored window), it reads its host's apps itself, then follows the runs.
        .task(id: store.appsInput) {
            if let host = store.hosts.first(where: { $0.id == hostID }), apps.state(of: host).page == nil { await store.loadApps() }
            while !Task.isCancelled {
                try? await Task.sleep(for: ClientApps.refresh)
                if let host = store.hosts.first(where: { $0.id == hostID }) { await apps.poll(host) }
            }
        }
    }

    /// Its state and the button for what it does next, over the page.
    private func header(_ row: AppRowValue, host: SettingsHost, apps: ClientApps) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.l) {
                if let status = row.status, let tone = row.tone {
                    AppStatus(status, tone: tone)
                } else {
                    Text("Not running").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
                Spacer(minLength: SH.Space.m)
                AppActionButton(row: row, busy: apps.isBusy(row, on: host)) { Task { await apps.perform(row, on: host) } }
            }
            if let blocked = row.actionBlocked { SettingsFootnote(blocked) }
            if let problem = apps.problems[host.id] { SettingsFootnote(problem, tone: .failed) }
        }
        .padding(.horizontal, MobileLayout.gutter)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    /// Where it opens, what it runs and where, and who can start it: read-only.
    private func facts(_ row: AppRowValue, host: SettingsHost) -> some View {
        SettingsCard {
            AppFact("Opens", row.place)
            AppFact("Command", row.command.isEmpty ? "None" : row.command, mono: !row.command.isEmpty)
            if let command = row.restartCommand { AppFact("Restart runs", command, mono: true) }
            if let directory = row.run?.directory { AppFact("Folder", directory, mono: true) }
            AppFact("Quick action", row.quickAction ? "On" : "Off")
            AppFact("Agents can start it", row.agents ? "On" : "Off")
        }
    }

    @ViewBuilder private func outputSection(_ row: AppRowValue) -> some View {
        VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
            SettingsCaption("Output")
            if row.run == nil {
                SettingsFootnote("It hasn't run since \(SettingsStore.of(hosts).hosts.first { $0.id == hostID }?.name ?? "the host") started.")
            } else {
                switch output {
                case .loading:
                    SHBusyLabel("Reading the output…").frame(maxWidth: .infinity)
                case .failed(let reason):
                    SettingsFootnote(reason, tone: .failed)
                case .lines(let lines):
                    if lines.isEmpty {
                        SettingsFootnote("No output yet.")
                    } else {
                        Text(lines.joined(separator: "\n"))
                            .font(.sh(.code))
                            .foregroundStyle(Color.sh.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(SH.Space.l)
                            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
                            .shBorder(Color.sh.lineSubtle, radius: SHListMetrics.cardRadius)
                            .accessibilityLabel("Output")
                            .accessibilityValue(lines.suffix(3).joined(separator: ". "))
                    }
                }
            }
        }
    }
}

/// A label and its value, read-only.
private struct AppFact: View {
    let label: String
    let value: String
    let mono: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ label: String, _ value: String, mono: Bool = false) {
        self.label = label
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.l) {
            Text(label).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
            Spacer(minLength: SH.Space.m)
            Text(value)
                .font(mono ? .sh(.mono) : .sh(.ui))
                .foregroundStyle(Color.sh.textTertiary)
                .multilineTextAlignment(.trailing)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                .truncationMode(.middle)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SHListMetrics.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
