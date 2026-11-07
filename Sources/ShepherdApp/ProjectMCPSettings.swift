import AppKit
import SwiftUI
import ShepherdUI

/// The same MCP cards and editor as Settings, scoped to the selected project's file API.
struct ProjectMCPSettings: View {
    let model: ProjectsModel
    private let copyJSON: (String) -> Void
    @State private var query = ""
    @State private var visible: [MCPServerRowModel] = []
    @State private var expanded: String?
    @State private var sheet: MCPSheet?
    @State private var removing: String?
    @State private var removeError: String?
    @State private var scope = Scope.all

    enum Scope: Hashable { case all, here, inherited }

    /// One server on a parent or child space's page (ProjectParentMCP, ProjectChildMCP,
    /// ProjectChildMCPOverride): the parent's, inherited, or this space's own, which may override one.
    struct Block: Equatable, Identifiable {
        var row: MCPServerRowModel
        var inherited: Bool
        var overrides: Bool
        var id: String { (inherited ? "inherited:" : "own:") + row.name }
    }

    init(model: ProjectsModel, initiallyExpanded: String? = nil, initialQuery: String = "", copyJSON: @escaping (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }) {
        self.model = model
        self.copyJSON = copyJSON
        _expanded = State(initialValue: initiallyExpanded)
        _query = State(initialValue: initialQuery)
    }

    private var space: String { model.selected?.project.name ?? "this space" }
    private var parent: String? { model.parentMCP == nil ? nil : model.inheritanceParentName }
    private var children: Int { model.inheritingChildCount }
    /// A parent or child space draws its servers by where each comes from.
    private var sourced: Bool { parent != nil || children > 0 }

    private var explanation: String {
        if parent != nil { return "Parent servers stay shared. Additions and overrides here apply only to \(space)." }
        if children > 0 { return "Servers defined here apply to \(space) and its \(children) child \(children == 1 ? "space" : "spaces"), unless overridden." }
        return "Configure servers for this space. Changes apply to new threads on \(model.selected?.host.name ?? "this host")."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            HStack(alignment: .top, spacing: SH.Space.l) {
                SettingsHeader(title: "MCP servers", explanation: explanation)
                    .frame(maxWidth: AppLayout.mcpExplanationWidth, alignment: .leading)
                Spacer(minLength: SH.Space.m)
                MCPAddServerButton(editable: model.mcpEditable) { sheet = .add(.remote) }
            }
            if let parent {
                SpaceInheritanceBanner(title: "Inherited from \(parent)", message: SpaceInheritanceBanner.childMessage(space),
                                       open: model.inheritanceParent == nil ? nil : ("Open \(parent)", { Task { await model.openInheritanceParent() } }),
                                       disabled: model.saving)
            } else if children > 0 {
                SpaceInheritanceBanner(title: "Shared with child spaces", message: "Saved MCP servers flow down to child spaces that have not overridden them.")
            }
            HStack(spacing: SH.Space.m) {
                SHSearchField("Filter servers", text: $query).frame(width: AppLayout.mcpFilterWidth)
                if sourced {
                    SHSegmentedPicker("Server source", selection: $scope, options: [(Scope.all, "All"), (.here, "Defined here"), (.inherited, "Inherited")])
                        .shControlScale(.settings).fixedSize()
                }
                Spacer(minLength: SH.Space.m)
                if sourced && model.mcp.problem == nil {
                    Text("\(blocks.count) \(blocks.count == 1 ? "server" : "servers")").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                } else {
                    Button("Reload") {
                        guard let file = model.selectedFile else { return }
                        Task { await model.navigate(.file(file)) }
                    }.buttonStyle(.sh(.secondary)).disabled(model.fileLoading || model.saving)
                }
            }
            if let problem = model.mcpTrustError {
                SHInlineProblem(problem).accessibilityLabel(problem)
            }
            if let problem = model.mcp.problem {
                SHInlineProblem(problem)
            } else if sourced {
                ScrollView {
                    VStack(alignment: .leading, spacing: SH.Space.l) {
                        if blocks.isEmpty {
                            MCPServerList(rows: [], details: [:], editable: false, expanded: nil,
                                          empty: query.isEmpty ? "No servers here yet. Add a server to get started." : "No servers match your search.",
                                          rowActions: rowActions, detailActions: detailActions)
                        }
                        ForEach(blocks) { block in self.block(block) }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    MCPServerList(rows: visible, details: model.mcp.details, editable: model.mcpEditable,
                                  expanded: expanded, empty: query.isEmpty ? "No servers in this file yet. Add a server to get started." : "No servers match your search.",
                                  rowActions: rowActions, detailActions: detailActions)
                }
                .scrollIndicators(.hidden)
            }
            Text(sourced
                 ? "Credentials stay on \(model.selected?.host.name ?? "this host"). Parent configuration is inherited without copying sign-in sessions or secret values."
                 : model.mcp.native
                 ? "Added spaces are trusted automatically. Sign-in credentials stay on the space's host; live status belongs to its threads."
                 : "This file is used when Also use a repo’s .mcp.json is on in MCP settings. Its tools use Search. Sign-in credentials stay on the space's host.")
                .font(.shSans(AppLayout.mcpNoteSize)).foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: filter)
        .onChange(of: model.mcp.rows) { _, _ in filter() }
        .onChange(of: query) { _, _ in filter() }
        .onDisappear { model.closeMCPSignIn() }
        .sheet(item: Binding(get: { model.mcpSignIn }, set: { if $0 == nil { model.closeMCPSignIn() } })) { flow in
            MCPSignInSheetHost(flow: flow) { model.closeMCPSignIn() }
        }
        .sheet(item: $sheet) { selection in
            switch selection {
            case .add(let kind): AddMCPServerSheet(project: model, initialKind: kind, editing: nil) { sheet = nil }
            case .edit(let name): AddMCPServerSheet(project: model, initialKind: nil, editing: model.mcp.entries.first { $0.name == name }) { sheet = nil }
            case .paste: AddMCPServerSheet(project: model, initialKind: .json, editing: nil) { sheet = nil }
            case .tools: EmptyView()
            }
        }
        .sheet(isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            DialogSheet(title: "Remove \(removing ?? "server")?",
                        subtitle: "Removes this server from \(model.selectedFile?.path ?? "this file") on \(model.selected?.host.name ?? "this host"). Global servers and credentials are unchanged.",
                        actions: [
                            DialogAction("Cancel", kind: .cancel) { removing = nil },
                            DialogAction("Remove", kind: .destructive) {
                                guard let name = removing else { return }
                                Task { await remove(name) }
                            },
                        ], dontAskAgain: .removeSpaceMCPServer) { if let removeError { SHInlineProblem(removeError) } }
                .disabled(model.saving)
                .interactiveDismissDisabled(model.saving)
        }
    }

    /// The parent's servers in its order, each inherited or replaced by this space's override, then
    /// this space's own others, filtered by source and search.
    private var blocks: [Block] {
        let own = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [Block] = []
        for var row in model.parentMCP?.rows ?? [] {
            if model.mcp.entries.contains(where: { $0.name == row.name }) {
                if let mine = own[row.name] { result.append(Block(row: mine, inherited: false, overrides: true)) }
                continue
            }
            guard trimmed.isEmpty || "\(row.name) \(row.endpoint)".localizedCaseInsensitiveContains(trimmed) else { continue }
            if model.isExcluded(mcp: row.name) { row.enabled = false; row.status = .off }
            result.append(Block(row: row, inherited: true, overrides: false))
        }
        let parentNames = Set(model.parentMCP?.rows.map(\.name) ?? [])
        result += visible.filter { !parentNames.contains($0.name) }.map { Block(row: $0, inherited: false, overrides: false) }
        return result.filter { scope == .all || (scope == .inherited) == $0.inherited }
    }

    @ViewBuilder private func block(_ block: Block) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                Text(block.inherited ? "Inherited from \(parent ?? "parent")" : "Defined in \(space)")
                    .font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary)
                if block.overrides, let parent {
                    Text("Overrides \(parent)").font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                }
                Spacer(minLength: SH.Space.m)
                if block.inherited, let parent {
                    let excluded = model.isExcluded(mcp: block.row.name)
                    if model.inheritanceParent != nil {
                        Button("Manage in \(parent)") { Task { await model.openInheritanceParent() } }
                            .buttonStyle(.sh(.ghost, size: .s)).disabled(model.saving)
                    }
                    Button("Override here") {
                        Task { await model.overrideMCP(block.row.name); if model.mcp.entries.contains(where: { $0.name == block.row.name }) { sheet = .edit(block.row.name) } }
                    }.buttonStyle(.sh(.ghost)).disabled(!model.mcpEditable || !model.mcp.native)
                    Button(excluded ? "Enable in \(space)" : "Disable in \(space)") {
                        Task { await model.setInherited(mcp: block.row.name, on: excluded) }
                    }.buttonStyle(.sh(.ghost)).disabled(!model.canExcludeInherited)
                        .help(model.selected?.host.supportsInheritance == false ? "Update Shepherd on \(model.selected?.host.name ?? "the host") to turn off inherited servers." : "")
                } else if block.overrides {
                    Button("Reset to inherited") { Task { await remove(block.row.name) } }
                        .buttonStyle(.sh(.ghost)).disabled(!model.mcpEditable)
                }
            }.accessibilityElement(children: .contain)
            MCPServerList(rows: [block.row], details: block.inherited ? [:] : model.mcp.details,
                          editable: !block.inherited && model.mcpEditable, expanded: block.inherited ? nil : expanded, empty: "",
                          rowActions: rowActions, detailActions: detailActions)
        }
    }

    private func filter() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = model.mcp.rows.filter { trimmed.isEmpty || "\($0.name) \($0.endpoint)".localizedCaseInsensitiveContains(trimmed) }
    }

    private func rowActions(_ name: String) -> MCPServerRow.Actions {
        .init(toggle: { enabled in Task { await model.setMCPEnabled(name, enabled) } },
              open: { expanded = expanded == name ? nil : name }, signIn: { model.beginMCPSignIn(name) })
    }

    private func detailActions(_ name: String) -> MCPServerDetail.Actions {
        .init(signIn: { model.beginMCPSignIn(name) }, signOut: { model.signOutMCP(name) },
              setDirect: model.mcp.native ? { direct in Task { await model.setMCPDirect(name, direct) } } : nil,
              chooseTools: nil, edit: { sheet = .edit(name) }, reconnect: nil,
              copyJSON: {
                  guard let entry = model.mcp.entries.first(where: { $0.name == name }) else { return }
                  copyJSON(MCPJSON.write(.object(["mcpServers": .object([name: .object(entry.json)])])))
              }, remove: {
                  removeError = nil
                  // After "Don't ask again" it goes at once; a failure opens the dialog with the error.
                  if AppSettings.shared.skipped(.removeSpaceMCPServer) != nil { Task { await remove(name) } } else { removing = name }
              })
    }

    private func remove(_ name: String) async {
        do {
            try await model.removeMCP(name)
            if expanded == name { expanded = nil }
            removing = nil
        } catch {
            removeError = String(describing: error)
            removing = name
        }
    }
}
