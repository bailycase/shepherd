import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

// Settings › Apps (AppsSettings board): This Mac's apps, then each space's, with Run or Stop;
// Add app opens the sheet (AppsAdd board). Right-click an app to edit or remove it.

struct AppsSettings: View {
    let vm: ShepherdViewModel
    @Bindable var model: AppsModel

    static let explanation = "Things you run while you work, such as a dev server, Storybook or the Simulator. Add them to a space and they show up as quick actions in that space’s threads. Their output goes to the terminal panel, and web apps open in the browser pane."

    var body: some View {
        SettingsPage(title: "Apps", explanation: Self.explanation) {
            if let problem = model.problem { SHInlineProblem(problem) }
            ForEach(model.groups) { group in
                AppsGroupView(group: group, vm: vm, model: model)
            }
        }
        .task { model.reload() }
        .sheet(item: $model.editor) { editor in
            AppEditSheet(editor: editor) { model.editor = nil }
        }
    }
}

private struct AppsGroupView: View {
    let group: AppsModel.Group
    let vm: ShepherdViewModel
    let model: AppsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(alignment: .center) {
                Text(group.title).shSettingsLabel().lineLimit(1).accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.l)
                Button { model.add(scope: group.scope) } label: { Label("Add app", systemImage: "plus") }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(group.problem != nil)
                    .accessibilityLabel("Add app to \(group.title)")
            }
            .padding(.horizontal, SH.Space.xs)
            if let problem = group.problem {
                SHInlineProblem(problem)
            } else if !group.apps.isEmpty {
                SHGroupCard(fill: Color.sh.bgWindow, radius: SHCardRowMetrics.settingsCardRadius) {
                    ForEach(group.apps) { app in
                        let key = AppKey(scope: group.scope, name: app.name)
                        AppRow(app: app, process: model.process(key),
                               run: { vm.runApp(app, key: key) }, stop: { vm.stopApp(key) }, restart: { vm.restartApp(key) })
                            .contextMenu {
                                Button("Edit…") { model.edit(app, scope: group.scope) }
                                Button("Remove") { model.remove(key) }
                            }
                    }
                }
            } else {
                SHGroupCard(fill: Color.sh.bgWindow, radius: SHCardRowMetrics.settingsCardRadius) {
                    SettingsActionRow {
                        Text("No apps yet.").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                    } actions: { EmptyView() }
                }
            }
            if !group.suggestions.isEmpty {
                AppSuggestionRow(scripts: group.suggestions.map(\.script)) { model.addSuggestions(group) }
            }
            SettingsNote(text: footnote).padding(.horizontal, SH.Space.xs)
        }
    }

    private var footnote: String {
        guard group.root != nil else { return "Saved in ~/\(AppsFile.relativePath). These are in every space." }
        return "Saved in \(AppsFile.relativePath) in the space, so everyone who opens it gets them. Quick actions show in the thread header while you are in \(group.title)."
    }
}

/// One app: its kind's glyph in a tile, name (and Quick action), where it opens and what it runs,
/// then what it is doing (AppStatusLabel) and Run, Stop or Restart.
private struct AppRow: View {
    let app: AppDefinition
    let process: AppProcessSnapshot?
    let run: () -> Void
    let stop: () -> Void
    let restart: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.l) {
            Image(systemName: Self.symbol(app.opens))
                .font(.shSans(AppLayout.appsIconSize))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: AppLayout.appsIconTile, height: AppLayout.appsIconTile)
                .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .shBorder(Color.sh.lineSubtle, radius: SH.Radius.s)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: SH.Space.m) {
                    Text(app.name).font(.shSans(AppLayout.appsNameSize, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                    if app.quickAction { AppTag(text: "Quick action") }
                }
                (Text(Self.place(app) + " · ").font(.sh(.caption)) + Text(app.command).font(.sh(.mono)))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(app.command)
            }
            Spacer(minLength: SH.Space.xl)
            if let process { AppStatusLabel(process: process) }
            switch process?.status {
            case .starting?, .running?:
                Button(action: stop) { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .disabled(process?.stopping == true)
                    .accessibilityLabel("Stop \(app.name)")
            case .exited?:
                Button(action: restart) { Label("Restart", systemImage: "arrow.clockwise") }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Restart \(app.name)")
            default:
                Button(action: run) { Label("Run", systemImage: "play.fill") }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Run \(app.name)")
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: AppLayout.appsRowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(process.map { "\(app.name), \(AppStatusLabel.words($0))" } ?? app.name)
    }

    static func symbol(_ opens: AppDefinition.Opens) -> String {
        switch opens {
        case .browser: "globe"
        case .terminal: "apple.terminal"
        case .window: "macwindow"
        }
    }

    /// "Browser tab · localhost:3000", "Terminal", "Its own window".
    static func place(_ app: AppDefinition) -> String {
        switch app.opens {
        case .browser:
            guard let url = app.url, let host = url.host else { return "Browser tab" }
            return "Browser tab · " + host + (url.port.map { ":\($0)" } ?? "")
        case .terminal: return "Terminal"
        case .window: return "Its own window"
        }
    }

}

/// What an app is doing, as a dot and words: Starting…, Running · :3000, Stopping…,
/// Exited (code 1), or why it couldn't start.
struct AppStatusLabel: View {
    let process: AppProcessSnapshot

    var body: some View {
        HStack(spacing: SH.Space.s) {
            SHStatusDot(state)
            Text(Self.words(process))
                .font(.sh(.ui, weight: .regular)).foregroundStyle(state.textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(Self.words(process))
        .accessibilityElement(children: .combine)
    }

    private var state: AgentState {
        switch process.status {
        case .starting: .running
        case .running: process.stopping ? .running : .done
        case .exited(let code): code == 0 || process.stopping ? .idle : .failed
        case .failed: .failed
        }
    }

    static func words(_ process: AppProcessSnapshot) -> String {
        switch process.status {
        case .starting: return process.stopping ? "Stopping…" : "Starting…"
        case .running:
            if process.stopping { return "Stopping…" }
            return ["Running", process.port.map { ":\($0)" }].compactMap { $0 }.joined(separator: " · ")
        case .exited(let code): return "Exited (code \(code))"
        case .failed(let why): return why
        }
    }
}

/// The small Quick action tag beside an app's name.
private struct AppTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.shSans(AppLayout.appsTagSize, .medium))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.s)
            .frame(height: AppLayout.appsTagHeight)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
    }
}

/// The dashed row under a space's apps: its package.json scripts that aren't apps yet.
private struct AppSuggestionRow: View {
    let scripts: [String]
    let add: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.l) {
            message
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
                .lineLimit(2)
            Spacer(minLength: SH.Space.xl)
            Button(scripts.count == 1 ? "Add it" : scripts.count == 2 ? "Add both" : "Add all", action: add)
                .buttonStyle(.sh(.secondary, size: .s))
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: AppLayout.appsSuggestionHeight)
        .shBorder(Color.sh.lineStrong, in: RoundedRectangle(cornerRadius: SHCardRowMetrics.settingsCardRadius), dash: [SH.Space.xs, SH.Space.xs])
    }

    /// "package.json also has `test:e2e` and `docs`. Add them as apps?"
    private var message: Text {
        var text = Text("package.json also has ")
        for (index, script) in scripts.enumerated() {
            if index > 0 { text = text + Text(index == scripts.count - 1 ? " and " : ", ") }
            text = text + Text(script).font(.sh(.mono))
        }
        return text + Text(scripts.count == 1 ? ". Add it as an app?" : ". Add them as apps?")
    }
}

// MARK: Add app

/// The Add app and Edit app sheet (AppsAdd board).
struct AppEditSheet: View {
    @Bindable var editor: AppEditor
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.l) {
                Text(editor.title).shText(.title).foregroundStyle(Color.sh.textPrimary).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                HookSheetClose(action: close)
            }
            .padding(.leading, SH.Space.xxl)
            .padding(.trailing, SH.Space.l)
            .padding(.vertical, SH.Space.l)
            SHHairline()
            ScrollView {
                form
                    .padding(.horizontal, SH.Space.xxl)
                    .padding(.vertical, SH.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SHHairline()
            HStack(spacing: SH.Space.m) {
                if let problem = editor.problem {
                    Text(problem).font(.sh(.caption)).foregroundStyle(Color.sh.failed).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: close)
                    .buttonStyle(.sh(.secondary, size: .m))
                    .keyboardShortcut(.cancelAction)
                Button(editor.original == nil ? "Add app" : "Save") {
                    Task { if await editor.save() { close() } }
                }
                .buttonStyle(.sh(.primary, size: .m))
                .keyboardShortcut(.defaultAction)
                .disabled(editor.invalid != nil || editor.saving)
                .help(editor.invalid ?? "")
            }
            .padding(.horizontal, SH.Space.xxl)
            .padding(.vertical, SH.Space.l)
        }
        .frame(width: AppLayout.appsSheetWidth, height: AppLayout.appsSheetHeight)
        .background(Color.sh.bgRaised)
        .disabled(editor.saving)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: SH.Space.xl) {
            HookField("Name") {
                TextField("Name", text: $editor.name, prompt: Text("Web app").foregroundStyle(Color.sh.textTertiary))
                    .textFieldStyle(.sh())
            }
            HookField("Command") {
                TextField("Command", text: $editor.command, prompt: Text("npm run dev").foregroundStyle(Color.sh.textTertiary))
                    .textFieldStyle(.sh(mono: true))
            }
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                HookField("Folder") {
                    if editor.spaceName != nil {
                        Picker("Folder", selection: $editor.folder) {
                            ForEach(editor.folders, id: \.self) { Text(editor.folderLabel($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        TextField("Folder", text: $editor.folder, prompt: Text("~").foregroundStyle(Color.sh.textTertiary))
                            .textFieldStyle(.sh(mono: true))
                    }
                }
                HookField("Available in") {
                    Picker("Available in", selection: $editor.scope) {
                        ForEach(editor.scopes, id: \.scope) { Text($0.label).tag($0.scope) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HookField("Opens in", help: editor.opensHelp) {
                SHSegmentedPicker("Opens in", selection: $editor.opens,
                                  options: [(.browser, "Browser tab"), (.terminal, "Terminal"), (.window, "Its own window")])
                    .fixedSize()
            }
            if editor.opens == .browser {
                HookField("Address") {
                    TextField("Address", text: $editor.address, prompt: Text("http://localhost:3000").foregroundStyle(Color.sh.textTertiary))
                        .textFieldStyle(.sh(mono: true))
                }
            }
            HStack(alignment: .center, spacing: SH.Space.xl) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text("Show as a quick action").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                    HookHelp("A Run button in the thread header and on New thread while you are in this space.")
                }
                Spacer(minLength: 0)
                SettingsSwitch(label: "Show as a quick action", isOn: $editor.quickAction)
            }
            HStack(alignment: .center, spacing: SH.Space.xl) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text("Agents can start it and read its output").font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                    HookHelp(editor.spaceName == nil ? "An agent in any space can run it to check its work. It never edits the command."
                             : "An agent in this space can run it to check its work. It never edits the command.")
                }
                Spacer(minLength: 0)
                SettingsSwitch(label: "Agents can start it and read its output", isOn: $editor.agents)
            }
        }
    }
}
