import ShepherdSessions
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol

/// Settings ▸ MCP servers (SettingsMCP, MCPStates): the servers every agent on this Mac can use,
/// kept in ~/.config/mcp/mcp.json, in Settings ▸ Tools: the servers (a filter, All / Connected /
/// Needs you; a row opens in place, one at a time), then the rail (how the agent uses them, what
/// they cost in every prompt, the options, and the hosts), then whatever else Tools holds
/// (`extras`). Add server and Import… open sheets.
struct MCPSettings<Extras: View>: View {
    var vm: ShepherdViewModel
    var store: MCPStore
    /// A row open when the page appears (a search hit, a preview).
    var initiallyExpanded: String?
    var title = "MCP servers"
    @ViewBuilder var extras: Extras
    @Bindable private var projectSettings = AppSettings.shared
    private var projectConfig: Binding<Bool> { $projectSettings.mcpProjectConfig }
    private var expanded: String? {
        get { vm.mcpOpenServer }
        nonmutating set { vm.mcpOpenServer = newValue }
    }
    @State private var sheet: MCPSheet?
    @State private var removing: String?
    @State private var importing: [MCPServerEntry]?
    @State private var toast: SHToast?

    var body: some View {
        let rows = store.rows(filter: .all, query: "")
        Group {
            if let name = expanded, let row = store.rows(filter: .all, query: "").first(where: { $0.id == name }) {
                SettingsPage(title: row.name) { serverPage(row) }
            } else {
                SettingsPage(title: title) {
                    SettingsGroup(title: "MCP servers", links: [
                        SettingsLink("Import…", menu: [
                            SettingsLink("From a JSON file…") { importFile() },
                            SettingsLink("Paste JSON…") { sheet = .paste },
                        ]),
                        SettingsLink("Add server", enabled: store.isEditable) { sheet = .add(.remote) },
                    ], lazy: true) {
                        if let invalid = store.invalidMessage {
                            SettingsRow(title: "mcp.json can’t be read", problem: "\(invalid). Fix it to edit servers here.") {
                                Button("Open mcp.json") { NSWorkspace.shared.open(store.dependencies.file.url) }
                                    .buttonStyle(.sh(.secondary, size: .s))
                            }
                        } else if let problem = store.problem {
                            SettingsRow(title: "", problem: problem) {
                                Button("Dismiss") { store.problem = nil }.buttonStyle(.sh(.secondary, size: .s))
                            }
                        }
                        if rows.isEmpty {
                            SettingsRow(title: emptyMessage) { EmptyView() }
                        }
                        ForEach(rows) { row in
                            MCPListRow(row: row, hint: hint(row), dot: dot(row), actions: rowActions(row.name)).equatable()
                        }
                    }
                    SettingsGroup(title: "How the agent uses them", trailing: store.configPath) {
                        SettingsRow(title: "In every prompt", subtitle: store.budget.note) {
                            SettingsValue(text: store.budget.tokens)
                        }
                        SettingsRow(title: "Also use a repo’s .mcp.json", subtitle: "Off: only these servers, in every repo") {
                            SettingsSwitch(label: "Also use a repo’s .mcp.json", isOn: projectConfig)
                        }
                    }
                    extras
                }
            }
        }
        .shAnimation(.disclosure, value: expanded)
        .shAnimation(.list, value: rows.map(\.id))
        .shAnimation(.disclosure, value: store.problem)
        .onAppear {
            store.reload()
            store.refreshIfStale()
            if expanded == nil { expanded = initiallyExpanded }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let kind):
                AddMCPServerSheet(store: store, initialKind: kind, editing: nil) { self.sheet = nil }
            case .edit(let name):
                AddMCPServerSheet(store: store, initialKind: nil, editing: store.entry(name)) { self.sheet = nil }
            case .tools(let name):
                MCPChooseToolsSheet(store: store, name: name) { self.sheet = nil }
            case .paste:
                MCPPasteImportSheet { entries in
                    self.sheet = nil
                    begin(importing: entries)
                } close: { self.sheet = nil }
            }
        }
        .sheet(item: Binding(get: { store.signIn }, set: { if $0 == nil { store.closeSignIn() } })) { flow in
            MCPSignInSheetHost(flow: flow) { store.closeSignIn() }
        }
        .sheet(item: Binding(get: { removing.map(MCPName.init) }, set: { removing = $0?.name })) { item in
            DialogSheet(title: "Remove \(item.name)?",
                        subtitle: "It comes out of mcp.json for every tool that reads it, and its Keychain secrets and sign-in are deleted.",
                        actions: [
                            DialogAction("Cancel", kind: .cancel) { removing = nil },
                            DialogAction("Remove", kind: .destructive) {
                                remove(item.name)
                                removing = nil
                            },
                        ], dontAskAgain: .removeMCPServer) { EmptyView() }
        }
        .sheet(item: Binding(get: { importing.map(MCPImportBatch.init) }, set: { importing = $0?.entries })) { batch in
            let clashes = store.clashes(batch.entries)
            DialogSheet(title: clashes.count == 1 ? "\(clashes[0]) is already here" : "\(clashes.count) servers are already here",
                        subtitle: "\(clashes.formatted(.list(type: .and))): replace them with the imported ones, or keep yours "
                            + "and import the rest.",
                        actions: [
                            DialogAction("Cancel", kind: .cancel) { importing = nil },
                            DialogAction("Skip them") { finishImport(batch.entries, replace: false) },
                            DialogAction("Replace them", kind: .prominent) { finishImport(batch.entries, replace: true) },
                        ]) { EmptyView() }
        }
        .shToast(item: $toast)
    }

    private func dot(_ row: MCPServerRowModel) -> SHRowDot {
        guard row.enabled else { return .off }
        switch row.status {
        case .connected: return .on
        case .needsYou, .starting: return .warn
        case .error: return .bad
        case .idle, .off: return .off
        }
    }

    /// "23 tools · remote", or what it is doing.
    private func hint(_ row: MCPServerRowModel) -> String {
        if let note = row.note {
            switch note {
            case .starting(let text), .error(let text): return text
            }
        }
        var parts: [String] = []
        if let tools = row.tools { parts.append("\(tools) tools") }
        parts.append(row.kind == .remote ? "remote" : "local process")
        return parts.joined(separator: " · ")
    }

    /// A server's page: on, kind, sign-in, tool exposure, its config, and Remove.
    @ViewBuilder private func serverPage(_ row: MCPServerRowModel) -> some View {
        let detail = store.details[row.name]
        let actions = detailActions(row.name)
        let rowActions = rowActions(row.name)
        SettingsGroup(title: "") {
            SettingsRow(title: "On") {
                SettingsSwitch(label: "On", isOn: Binding(get: { row.enabled }, set: { rowActions.toggle($0) }))
            }
            SettingsRow(title: "Kind") {
                SettingsValue(text: (row.kind == .remote ? "Remote · " : "Local · ") + row.endpoint, mono: true)
            }
            if let detail {
                signInRow(detail, actions: actions)
                if let direct = detail.direct {
                    SettingsRow(title: "Tools", subtitle: direct ? detail.directCost : detail.searchCost) {
                        HStack(spacing: SH.Space.s) {
                            SHSegmentedPicker("Tools", selection: Binding(get: { direct }, set: { actions.setDirect?($0) }),
                                              options: [(false, "Search"), (true, "Direct")])
                            if let choose = actions.chooseTools {
                                Button("Choose…", action: choose).buttonStyle(.sh(.secondary, size: .s)).accessibilityLabel("Choose which tools…")
                            }
                        }
                    }
                }
            }
        }
        SettingsGroup(title: "Config") {
            SettingsRow(title: "\(row.name).json", subtitle: detail?.message, mono: true) {
                HStack(spacing: SH.Space.s) {
                    if let reconnect = actions.reconnect {
                        Button("Reconnect", action: reconnect).buttonStyle(.sh(.secondary, size: .s))
                    }
                    Button("Copy JSON", action: actions.copyJSON).buttonStyle(.sh(.secondary, size: .s))
                    Button("Edit", action: actions.edit).buttonStyle(.sh(.secondary, size: .s)).accessibilityLabel("Edit…")
                }
            }
        }
        SettingsGroup(title: "") {
            SettingsRow(title: "Remove server") {
                Button("Remove…", action: actions.remove).buttonStyle(.sh(.danger, size: .s)).accessibilityLabel("Remove")
            }
        }
    }

    @ViewBuilder private func signInRow(_ detail: MCPServerDetailModel, actions: MCPServerDetail.Actions) -> some View {
        switch detail.signIn {
        case .signedIn(let account, _, let note, let title):
            SettingsRow(title: "Sign-in", subtitle: [title, account, note].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), dot: .on) {
                Button("Sign out", action: actions.signOut).buttonStyle(.sh(.secondary, size: .s))
            }
        case .needsSignIn(let title, let note, let again):
            SettingsRow(title: "Sign-in", subtitle: [title, note].filter { !$0.isEmpty }.joined(separator: " · "), dot: .warn) {
                Button(again ? "Sign in again" : "Sign in", action: actions.signIn).buttonStyle(.sh(.primary, size: .s))
            }
        case .header(let name, let variable):
            SettingsRow(title: "Sign-in", subtitle: name) { SettingsValue(text: "$" + variable, mono: true) }
        case .secrets(let names, let missing):
            SettingsRow(title: "Sign-in", subtitle: missing.isEmpty ? nil : "Missing: " + missing.joined(separator: ", ")) {
                SettingsValue(text: names.joined(separator: ", "), mono: true)
            }
        case .unverified(let text):
            SettingsRow(title: "Sign-in", subtitle: text) { EmptyView() }
        case .none:
            EmptyView()
        }
    }

    private var emptyMessage: String {
        "No MCP servers yet. Add one, or import them from Claude Desktop, Cursor or VS Code."
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Pick an mcp.json, claude_desktop_config.json, .cursor/mcp.json or .vscode/mcp.json."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        switch MCPImport.parse(text) {
        case .success(let entries): begin(importing: entries)
        case .failure(let failure): store.problem = "\(url.lastPathComponent): \(failure.description)"
        }
    }

    private func rowActions(_ name: String) -> MCPServerRow.Actions {
        .init(toggle: { store.setEnabled(name, $0) },
              open: { expanded = expanded == name ? nil : name }, signIn: { store.beginSignIn(name) })
    }

    private func detailActions(_ name: String) -> MCPServerDetail.Actions {
        .init(signIn: { store.beginSignIn(name) }, signOut: { store.signOut(name) },
              setDirect: { store.setExposure(name, $0 ? .direct : .proxy) }, chooseTools: { sheet = .tools(name) },
              edit: { sheet = .edit(name) }, reconnect: { store.refresh() },
              copyJSON: { store.copyJSON(name); toast = SHToast(.done, message: "Copied \(name)’s JSON") },
              remove: { if AppSettings.shared.skipped(.removeMCPServer) != nil { remove(name) } else { removing = name } })
    }

    private func remove(_ name: String) {
        store.remove(name)
        if expanded == name { expanded = nil }
    }

    private func begin(importing entries: [MCPServerEntry]) {
        if store.clashes(entries).isEmpty {
            finishImport(entries, replace: false)
        } else {
            importing = entries
        }
    }

    private func finishImport(_ entries: [MCPServerEntry], replace: Bool) {
        importing = nil
        do {
            let added = try store.importEntries(entries, replace: replace)
            toast = SHToast(.done, message: added == 0 ? "Nothing new to import" : "Imported \(added) server\(added == 1 ? "" : "s")")
        } catch {
            store.problem = "\(error)"
        }
    }
}

/// A server's row: its dot, name, one hint line, then its state or Sign in, and a chevron. Compares by what it draws.
private struct MCPListRow: View, Equatable {
    let row: MCPServerRowModel
    let hint: String
    let dot: SHRowDot
    let actions: MCPServerRow.Actions

    nonisolated static func == (a: Self, b: Self) -> Bool { a.row == b.row && a.hint == b.hint && a.dot == b.dot }

    var body: some View {
        let _ = SHRenderProbe.tick("mcp.row")
        let needsSignIn: Bool = switch row.signIn { case .signIn, .expired, .moreAccess: true; default: false }
        SettingsDrillRow(title: row.name, subtitle: hint, dot: dot, mono: true, action: actions.open) {
            if needsSignIn {
                Button("Sign in", action: actions.signIn).buttonStyle(.sh(.secondary, size: .s))
            } else {
                SettingsValue(text: row.enabled ? row.status.label : "Off")
            }
        }
    }
}

/// The sheets Settings ▸ MCP servers opens.
enum MCPSheet: Identifiable, Hashable {
    case add(AddMCPServerSheet.Kind)
    case edit(String)
    case tools(String)
    case paste

    var id: String {
        switch self {
        case .add(let kind): "add:\(kind)"
        case .edit(let name): "edit:\(name)"
        case .tools(let name): "tools:\(name)"
        case .paste: "paste"
        }
    }
}

private struct MCPName: Identifiable {
    let name: String
    var id: String { name }
}

private struct MCPImportBatch: Identifiable {
    let entries: [MCPServerEntry]
    var id: String { entries.map(\.name).joined(separator: ",") }
}

extension MCPSettings where Extras == EmptyView {
    init(vm: ShepherdViewModel, store: MCPStore, initiallyExpanded: String? = nil) {
        self.init(vm: vm, store: store, initiallyExpanded: initiallyExpanded, extras: { EmptyView() })
    }
}

struct MCPAddServerButton: View {
    let editable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label("Add server", systemImage: "plus") }
            .buttonStyle(.sh(.primary))
            .disabled(!editable)
    }
}

// MARK: The list

/// The servers: a header, then a row per server; the open one shows its detail below it. The
/// lazy stack is the scroll view's own content, so the page builds only the rows in view.
struct MCPServerList: View {
    let rows: [MCPServerRowModel]
    let details: [String: MCPServerDetailModel]
    let editable: Bool
    let expanded: String?
    let empty: String
    let rowActions: (String) -> MCPServerRow.Actions
    let detailActions: (String) -> MCPServerDetail.Actions

    var body: some View {
        let sh = Color.sh
        LazyVStack(spacing: 0) {
            MCPServerListHeader()
            if rows.isEmpty {
                Text(empty)
                    .font(.shSans(AppLayout.mcpNoteSize))
                    .foregroundStyle(sh.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: SHMCPMetrics.rowMinHeight)
                    .shTransition(.disclosure)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let open = expanded == row.id
                VStack(spacing: 0) {
                    MCPServerRow(row, open: open, first: index == 0, actions: rowActions(row.name))
                        .equatable()
                        .disabled(!editable)
                    if open, let detail = details[row.name] {
                        MCPServerDetail(detail, actions: detailActions(row.name))
                            .disabled(!editable)
                            .shTransition(.disclosure)
                    }
                }
            }
        }
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.mcpCardRadius))
        .shBorder(sh.lineSubtle, radius: AppLayout.mcpCardRadius)
    }

}

// MARK: The rail

/// How the agent uses the servers, what they cost in every prompt, the options, and the hosts.
private struct MCPRail: View {
    var store: MCPStore
    @Bindable private var settings = AppSettings.shared

    init(store: MCPStore) {
        self.store = store
    }

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: AppLayout.mcpRailSpacing) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHSectionHeader("How the agent uses them", style: .settings).padding(.horizontal, SH.Space.xxs)
                Text("Servers start with each thread and stop with it, and a running thread keeps the ones it started with. Their tools "
                    + "wait behind a search until the agent needs one; a server set to Direct declares them all up front. Remote servers "
                    + "that use OAuth need you to sign in once; pi keeps the token fresh.")
                    .shText(size: AppLayout.mcpRailTextSize, lineHeight: AppLayout.mcpRailLineHeight)
                    .foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xxs)
                MCPBudget(tokens: store.budget.tokens, fraction: store.budget.fraction, note: store.budget.note)
                    .help("The context meter counts this as part of the system prompt.")
            }
            VStack(alignment: .leading, spacing: 0) {
                SHSectionHeader("Options", style: .settings).padding(.horizontal, SH.Space.xxs).padding(.bottom, SH.Space.m)
                option("Also use a repo’s .mcp.json", note: "Off: only the servers on this page, in every repo.",
                       isOn: $settings.mcpProjectConfig)
            }
            VStack(alignment: .leading, spacing: SH.Space.s) {
                SHSectionHeader("Where they live", style: .settings) {
                    Text(store.configPath)
                        .font(.shMono(AppLayout.mcpPathSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.dependencies.file.url.path)
                }
                .padding(.horizontal, SH.Space.xxs)
                // One file per Mac, kept the same on every Mac in the fleet: a change here is a change everywhere.
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "checkmark")
                        .font(.shSans(SHSkillMetrics.hostMarkSize - 2, .bold))
                        .foregroundStyle(sh.done)
                        .accessibilityHidden(true)
                    Text("\(store.connectedCount) connected · shared across the fleet")
                        .font(.shSans(SHSkillMetrics.hostTextSize))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                }
                .frame(minHeight: SHSkillMetrics.hostRowHeight)
                .accessibilityElement(children: .combine)
                .padding(.horizontal, SH.Space.xxs)
            }
        }
    }

    private func option(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        let sh = Color.sh
        return HStack(alignment: .top, spacing: SH.Space.l + SH.Space.xxs) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.shSans(AppLayout.mcpOptionTitleSize, .medium))
                    .foregroundStyle(sh.textPrimary)
                Text(note)
                    .shText(size: AppLayout.mcpNoteSize, lineHeight: AppLayout.mcpNoteLineHeight)
                    .foregroundStyle(sh.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn).toggleStyle(.shSwitch).labelsHidden()
        }
        .padding(.vertical, SH.Space.m + SH.Space.xxs)
        .overlay(alignment: .top) { SHHairline() }
    }
}

// MARK: Sign-in

/// The sign-in sheet over its flow: closes a moment after it succeeds.
struct MCPSignInSheetHost: View {
    var flow: MCPSignInFlow
    let close: () -> Void

    var body: some View {
        MCPSignInSheet(flow.model, actions: MCPSignInSheet.Actions(
            copyLink: { flow.copyLink() },
            openBrowser: { flow.openBrowserAgain() },
            cancel: close,
            done: close,
            tryAgain: { flow.tryAgain() }))
            .task(id: flow.succeeded) {
                guard flow.succeeded else { return }
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled { close() }
            }
    }
}

// MARK: Choose which tools

/// Which of a server's tools the agent sees: all of them, or the ones ticked.
struct MCPChooseToolsSheet: View {
    var store: MCPStore
    let name: String
    let close: () -> Void
    @State private var chosen: Set<String> = []
    @State private var all = true

    var body: some View {
        let entry = store.entry(name)
        let tools = entry.flatMap(store.toolNames(of:)) ?? []
        DialogSheet(title: "Choose \(name)’s tools",
                    subtitle: "The agent sees and calls only the tools you tick, searched or declared as the server’s tool exposure says.",
                    width: AppLayout.mcpToolsSheetWidth,
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: close),
                        DialogAction("Save", kind: .prominent, isEnabled: all || !chosen.isEmpty) {
                            store.setTools(name, all ? nil : tools.filter(chosen.contains))
                            close()
                        },
                    ]) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Toggle("All tools, including ones it adds later", isOn: $all).toggleStyle(.shCheckbox)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: SH.Space.s) {
                        ForEach(tools, id: \.self) { tool in
                            Toggle(isOn: Binding(get: { all || chosen.contains(tool) }, set: { on in
                                all = false
                                if on { chosen.insert(tool) } else { chosen.remove(tool) }
                            })) {
                                Text(tool).font(.shMono(AppLayout.mcpNoteSize)).foregroundStyle(Color.sh.textPrimary)
                            }
                            .toggleStyle(.shCheckbox)
                        }
                    }
                }
                .frame(maxHeight: AppLayout.mcpToolsSheetHeight)
            }
        }
        .onAppear {
            let current = entry?.settings.tools
            all = current == nil
            chosen = Set(current ?? tools)
        }
    }
}
