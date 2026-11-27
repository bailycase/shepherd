import ShepherdSessions
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

    /// A group on a parent or child space's page (ProjectParentMCP, ProjectChildMCP,
    /// ProjectChildMCPOverride): one inherited server or one override, each with its own actions,
    /// or this space's other servers together in one table.
    struct Block: Equatable, Identifiable {
        var rows: [MCPServerRowModel]
        var inherited: Bool
        var overrides: Bool
        var row: MCPServerRowModel { rows[0] }
        var id: String { inherited ? "inherited:" + row.name : overrides ? "override:" + row.name : "own" }
    }

    /// The line back to the space, the page's files row, a prompt above the list and its bar: the page around the servers (nil in a bare preview).
    var up: (label: String, action: () -> Void)?
    var files: AnyView?
    var notice: AnyView?
    var bar: AnyView?

    init(model: ProjectsModel, up: (label: String, action: () -> Void)? = nil, files: AnyView? = nil, notice: AnyView? = nil, bar: AnyView? = nil,
         initiallyExpanded: String? = nil, initialQuery: String = "", copyJSON: @escaping (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }) {
        self.model = model
        self.up = up
        self.files = files
        self.notice = notice
        self.bar = bar
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
        SpacePageFrame {
            SpacePageHeader(up: up, title: "MCP servers", subtitle: space, intro: explanation, disabled: model.saving) {
                Button("Add server") { sheet = .add(.remote) }.buttonStyle(SpaceLinkStyle()).disabled(!model.mcpEditable)
            }
            if let files { files }
            if let notice { notice }
            if let parent {
                SpaceInheritanceBanner(title: "Inherited from \(parent)", message: SpaceInheritanceBanner.childMessage(space),
                                       open: model.inheritanceParent == nil ? nil : ("Open \(parent)", { Task { await model.openInheritanceParent() } }),
                                       disabled: model.saving)
            } else if children > 0 {
                SpaceInheritanceBanner(title: "Shared with child spaces", message: "Saved MCP servers flow down to child spaces that have not overridden them.")
            }
            if let problem = model.mcpTrustError {
                SHInlineProblem(problem).accessibilityLabel(problem)
            }
            if let problem = model.mcp.problem {
                SHInlineProblem(problem)
            } else if sourced {
                sourcedPage
            } else {
                SpaceSection(title: "", footnote: footnote) { EmptyView() } content: {
                    filterRow
                    if visible.isEmpty {
                        SpaceEmpty(query.isEmpty ? "No servers in this file yet. Add a server to get started." : "No servers match your search.")
                    }
                    SpaceMCPList(rows: visible, details: model.mcp.details, editable: model.mcpEditable, expanded: expanded,
                                 rowActions: rowActions, detailActions: detailActions)
                }
            }
        } bar: {
            if let bar { bar }
        }
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
                if let mine = own[row.name] { result.append(Block(rows: [mine], inherited: false, overrides: true)) }
                continue
            }
            guard trimmed.isEmpty || "\(row.name) \(row.endpoint)".localizedCaseInsensitiveContains(trimmed) else { continue }
            if model.isExcluded(mcp: row.name) { row.enabled = false; row.status = .off }
            result.append(Block(rows: [row], inherited: true, overrides: false))
        }
        let parentNames = Set(model.parentMCP?.rows.map(\.name) ?? [])
        let others = visible.filter { !parentNames.contains($0.name) }
        if !others.isEmpty { result.append(Block(rows: others, inherited: false, overrides: false)) }
        return result.filter { scope == .all || (scope == .inherited) == $0.inherited }
    }

    private var footnote: String {
        sourced
            ? "Credentials stay on \(model.selected?.host.name ?? "this host"). Parent configuration is inherited without copying sign-in sessions or secret values."
            : model.mcp.native
            ? "Added spaces are trusted automatically. Sign-in credentials stay on the space's host; live status belongs to its threads."
            : "This file is used when Also use a repo’s .mcp.json is on in MCP settings. Its tools use Search. Sign-in credentials stay on the space's host."
    }

    /// The filter row inside the card (`gspc-filter`): search, then Reload.
    private var filterRow: some View {
        HStack(spacing: SH.Space.l) {
            SpaceSearchField(prompt: "Filter servers", text: $query)
            Spacer(minLength: 0)
            Button("Reload") {
                guard let file = model.selectedFile else { return }
                Task { await model.navigate(.file(file)) }
            }.buttonStyle(SpaceLinkStyle(tone: .strong)).disabled(model.fileLoading || model.saving)
        }.padding(.horizontal, AppLayout.spaceRowSides).padding(.vertical, SH.Space.m).frame(minHeight: AppLayout.spaceFilterHeight)
    }

    /// A parent or child space's servers by where each comes from: this space's own and its overrides, then the parent's.
    private var sourcedPage: some View {
        let all = blocks
        let defined = all.filter { !$0.inherited }.flatMap(\.rows)
        let supplied = all.filter(\.inherited).map(\.row)
        let excludedRows = supplied
        return VStack(alignment: .leading, spacing: AppLayout.spacePageGap) {
            HStack(spacing: SH.Space.l) {
                SpaceSearchField(prompt: "Filter servers", text: $query)
                SpaceFilterTabs(label: "Server source", selection: $scope, options: [(Scope.all, "All"), (.here, "Defined here"), (.inherited, "Inherited")])
                Spacer(minLength: 0)
                if model.mcp.problem == nil {
                    let count = defined.count + supplied.count
                    Text("\(count) \(count == 1 ? "server" : "servers")").font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
                }
            }.padding(.horizontal, SH.Space.xs)
            if defined.isEmpty && supplied.isEmpty {
                SpaceSection("") {
                    SpaceEmpty(query.isEmpty ? "No servers here yet. Add a server to get started." : "No servers match your search.")
                }
            }
            if !defined.isEmpty {
                SpaceSection("Defined in \(space)") {
                    SpaceMCPList(rows: defined, details: model.mcp.details, editable: model.mcpEditable, expanded: expanded,
                                 rowActions: rowActions, detailActions: detailActions, overrides: { name in
                        guard let parent, model.parentMCP?.rows.contains(where: { $0.name == name }) == true else { return nil }
                        return (parent, { Task { await remove(name) } }, model.mcpEditable)
                    })
                }
            }
            if !supplied.isEmpty, let parent {
                SpaceSection(title: "Inherited from \(parent)", trailing: {
                    if model.inheritanceParent != nil {
                        Button("Manage in \(parent)") { Task { await model.openInheritanceParent() } }.buttonStyle(SpaceLinkStyle()).disabled(model.saving)
                    }
                }, content: {
                    SpaceMCPList(rows: excludedRows, details: [:], editable: false, expanded: nil, rowActions: rowActions,
                                 detailActions: detailActions, inherited: { row in
                        let excluded = model.isExcluded(mcp: row.name)
                        return SpaceMCPRow.Inherited(
                            overrideHere: { Task { await model.overrideMCP(row.name); if model.mcp.entries.contains(where: { $0.name == row.name }) { sheet = .edit(row.name) } } },
                            overrideEnabled: model.mcpEditable && model.mcp.native,
                            toggleTitle: excluded ? "Enable in \(space)" : "Disable in \(space)",
                            toggle: { Task { await model.setInherited(mcp: row.name, on: excluded) } },
                            toggleEnabled: model.canExcludeInherited,
                            toggleHelp: model.selected?.host.supportsInheritance == false ? "Update Shepherd on \(model.selected?.host.name ?? "the host") to turn off inherited servers." : "")
                    })
                })
            }
            Text(footnote).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).padding(.horizontal, SH.Space.xs)
                .fixedSize(horizontal: false, vertical: true)
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
