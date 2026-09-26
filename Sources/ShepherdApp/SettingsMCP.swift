import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShepherdUI
import ShepherdProtocol

/// Settings ▸ MCP servers (SettingsMCP, MCPStates): the servers every agent on this Mac can use,
/// kept in ~/.config/mcp/mcp.json. A wide page: the servers (a filter, All / Connected / Needs
/// you; a row opens in place, one at a time) beside a 280pt rail (how the agent uses them, what
/// they cost in every prompt, the options, and the hosts). Add server and Import… open sheets.
struct MCPSettings: View {
    var vm: ShepherdViewModel
    var store: MCPStore
    /// A row open when the page appears (a search hit, a preview).
    var initiallyExpanded: String?
    @State private var filter: MCPStore.Filter = .all
    @State private var query = ""
    @State private var expanded: String?
    @State private var sheet: MCPSheet?
    @State private var removing: String?
    @State private var importing: [MCPServerEntry]?
    @State private var toast: NWToast?

    var body: some View {
        let rows = store.rows(filter: filter, query: query)
        VStack(alignment: .leading, spacing: AppLayout.mcpBlockSpacing) {
            header
            HStack(alignment: .top, spacing: AppLayout.mcpColumnSpacing) {
                VStack(alignment: .leading, spacing: NW.Space.l) {
                    toolbar
                    if let invalid = store.invalidMessage {
                        HStack(spacing: NW.Space.m) {
                            NWInlineProblem("\(invalid). Fix it to edit servers here.")
                            Button("Open mcp.json") { NSWorkspace.shared.open(store.dependencies.file.url) }.buttonStyle(.nwLink)
                        }
                        .nwTransition(.disclosure)
                    } else if let problem = store.problem {
                        HStack(spacing: NW.Space.m) {
                            NWInlineProblem(problem)
                            Button("Dismiss") { store.problem = nil }.buttonStyle(.nwLink)
                        }
                        .nwTransition(.disclosure)
                    }
                    ScrollView(.vertical) {
                        MCPServerList(store: store, rows: rows, expanded: $expanded, empty: emptyMessage,
                                      edit: { sheet = .edit($0) }, chooseTools: { sheet = .tools($0) },
                                      remove: { removing = $0 }, copied: { toast = NWToast(.done, message: "Copied \($0)’s JSON") })
                    }
                    .scrollIndicators(.hidden)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.vertical) {
                    MCPRail(store: store).frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(width: AppLayout.mcpRailWidth)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .nwAnimation(.disclosure, value: expanded)
        .nwAnimation(.list, value: rows.map(\.id))
        .nwAnimation(.disclosure, value: store.problem)
        .onAppear {
            store.reload()
            store.probeUnknown()
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
                                store.remove(item.name)
                                if expanded == item.name { expanded = nil }
                                removing = nil
                            },
                        ]) { EmptyView() }
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
        .nwToast(item: $toast)
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: NW.Space.xl) {
            SettingsHeader(title: "MCP servers",
                           explanation: "Tools from other services the agent can call: your issue tracker, error tracker, database, "
                               + "browser. Global: every thread and automation gets the same servers.")
                .frame(maxWidth: AppLayout.mcpExplanationWidth, alignment: .leading)
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.m) {
                Menu {
                    Button("From a JSON file…") { importFile() }
                    Button("Paste JSON…") { sheet = .paste }
                } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.nw(.secondary))
                .fixedSize()
                .disabled(!store.isEditable)
                Button { sheet = .add(.remote) } label: { Label("Add server", systemImage: "plus") }
                    .buttonStyle(.nw(.primary))
                    .disabled(!store.isEditable)
            }
            .fixedSize()
        }
    }

    private var toolbar: some View {
        HStack(spacing: NW.Space.m + NW.Space.xxs) {
            NWSearchField("Filter servers", text: $query)
                .frame(width: AppLayout.mcpFilterWidth)
            NWSegmentedPicker("Show", selection: $filter, options: [
                (.all, "All \(store.count(.all))"),
                (.connected, "Connected \(store.count(.connected))"),
                (.needsYou, "Needs you \(store.count(.needsYou))"),
            ])
            Spacer(minLength: 0)
        }
    }

    private var emptyMessage: String {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return "No server matches “\(query)”." }
        switch filter {
        case .connected: return "No server is connected right now. Servers connect when an agent uses them."
        case .needsYou: return "Nothing needs you."
        case .all: return "No MCP servers yet. Add one, or import them from Claude Desktop, Cursor or VS Code."
        }
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
            toast = NWToast(.done, message: added == 0 ? "Nothing new to import" : "Imported \(added) server\(added == 1 ? "" : "s")")
        } catch {
            store.problem = "\(error)"
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

// MARK: The list

/// The servers: a header, then a row per server; the open one shows its detail below it. The
/// lazy stack is the scroll view's own content, so the page builds only the rows in view.
private struct MCPServerList: View {
    var store: MCPStore
    let rows: [MCPServerRowModel]
    @Binding var expanded: String?
    let empty: String
    let edit: (String) -> Void
    let chooseTools: (String) -> Void
    let remove: (String) -> Void
    let copied: (String) -> Void

    var body: some View {
        let nw = Color.nw
        LazyVStack(spacing: 0) {
            MCPServerListHeader()
            if rows.isEmpty {
                Text(empty)
                    .font(.nwSans(AppLayout.mcpNoteSize))
                    .foregroundStyle(nw.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: NWMCPMetrics.rowMinHeight)
                    .nwTransition(.disclosure)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                let open = expanded == row.id
                VStack(spacing: 0) {
                    MCPServerRow(row, open: open, first: index == 0, actions: actions(for: row.name))
                        .equatable()
                        .disabled(!store.isEditable)
                    if open, let detail = store.details[row.name] {
                        MCPServerDetail(detail, actions: detailActions(for: row.name))
                            .disabled(!store.isEditable)
                            .nwTransition(.disclosure)
                    }
                }
            }
        }
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: AppLayout.mcpCardRadius))
        .nwBorder(nw.lineSubtle, radius: AppLayout.mcpCardRadius)
    }

    private func actions(for name: String) -> MCPServerRow.Actions {
        MCPServerRow.Actions(
            toggle: { store.setEnabled(name, $0) },
            open: { expanded = expanded == name ? nil : name },
            signIn: { store.beginSignIn(name) })
    }

    private func detailActions(for name: String) -> MCPServerDetail.Actions {
        MCPServerDetail.Actions(
            signIn: { store.beginSignIn(name) },
            signOut: { store.signOut(name) },
            setDirect: { store.setExposure(name, $0 ? .direct : .proxy) },
            chooseTools: { chooseTools(name) },
            setStart: { store.setStart(name, MCPStartMode.allCases[$0]) },
            edit: { edit(name) },
            reconnect: { store.probe(name) },
            copyJSON: {
                store.copyJSON(name)
                copied(name)
            },
            remove: { remove(name) })
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: AppLayout.mcpRailSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                NWSectionHeader("How the agent uses them", style: .settings).padding(.horizontal, NW.Space.xxs)
                Text("Servers start when the agent first needs one and stop when idle. Remote servers that use OAuth need you to "
                    + "sign in once; Shepherd keeps the token fresh.")
                    .nwText(size: AppLayout.mcpRailTextSize, lineHeight: AppLayout.mcpRailLineHeight)
                    .foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xxs)
                MCPBudget(tokens: store.budget.tokens, fraction: store.budget.fraction, note: store.budget.note)
                    .help("The context meter counts this as part of the system prompt.")
            }
            VStack(alignment: .leading, spacing: 0) {
                NWSectionHeader("Options", style: .settings).padding(.horizontal, NW.Space.xxs).padding(.bottom, NW.Space.m)
                option("Same servers on every host", note: "Adds, edits and removals go to all hosts. For now, only this Mac.",
                       isOn: $settings.mcpSameEverywhere)
                option("Open sign-in pages by itself",
                       note: "Off: when an agent reaches a server that needs sign-in, its row here asks you to sign in.",
                       isOn: $settings.mcpOpenSignInPages)
                option("Also use a repo’s .mcp.json", note: "Off: only the servers on this page, in every repo.",
                       isOn: $settings.mcpProjectConfig)
            }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                NWSectionHeader("Hosts", style: .settings) {
                    Text(store.configPath)
                        .font(.nwMono(AppLayout.mcpPathSize))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.dependencies.file.url.path)
                }
                .padding(.horizontal, NW.Space.xxs)
                NWHostStateRow("This Mac", detail: "\(store.connectedCount) connected", mark: .done)
                    .padding(.horizontal, NW.Space.xxs)
            }
        }
    }

    private func option(_ title: String, note: String, isOn: Binding<Bool>) -> some View {
        let nw = Color.nw
        return HStack(alignment: .top, spacing: NW.Space.l + NW.Space.xxs) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(.nwSans(AppLayout.mcpOptionTitleSize, .medium))
                    .foregroundStyle(nw.textPrimary)
                Text(note)
                    .nwText(size: AppLayout.mcpNoteSize, lineHeight: AppLayout.mcpNoteLineHeight)
                    .foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn).toggleStyle(.nwSwitch).labelsHidden()
        }
        .padding(.vertical, NW.Space.m + NW.Space.xxs)
        .overlay(alignment: .top) { NWHairline() }
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
        let tools = entry.flatMap(store.tools(of:)) ?? []
        DialogSheet(title: "Choose \(name)’s tools",
                    subtitle: "The agent sees and calls only the tools you tick, through the mcp tool or on their own.",
                    width: AppLayout.mcpToolsSheetWidth,
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: close),
                        DialogAction("Save", kind: .prominent, isEnabled: all || !chosen.isEmpty) {
                            store.setTools(name, all ? nil : tools.map(\.name).filter(chosen.contains))
                            close()
                        },
                    ]) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Toggle("All tools, including ones it adds later", isOn: $all).toggleStyle(.nwCheckbox)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: NW.Space.s) {
                        ForEach(tools, id: \.name) { tool in
                            Toggle(isOn: Binding(get: { all || chosen.contains(tool.name) }, set: { on in
                                all = false
                                if on { chosen.insert(tool.name) } else { chosen.remove(tool.name) }
                            })) {
                                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                    Text(tool.name).font(.nwMono(AppLayout.mcpNoteSize)).foregroundStyle(Color.nw.textPrimary)
                                    if !tool.description.isEmpty {
                                        Text(tool.description).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(2)
                                    }
                                }
                            }
                            .toggleStyle(.nwCheckbox)
                        }
                    }
                }
                .frame(maxHeight: AppLayout.mcpToolsSheetHeight)
            }
        }
        .onAppear {
            let current = entry?.settings.tools
            all = current == nil
            chosen = Set(current ?? tools.map(\.name))
        }
    }
}
