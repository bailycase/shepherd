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

    init(model: ProjectsModel, initiallyExpanded: String? = nil, initialQuery: String = "", copyJSON: @escaping (String) -> Void = {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString($0, forType: .string)
    }) {
        self.model = model
        self.copyJSON = copyJSON
        _expanded = State(initialValue: initiallyExpanded)
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            HStack(alignment: .top, spacing: NW.Space.l) {
                SettingsHeader(title: "MCP servers", explanation: "Configure servers for this project. Changes apply to new threads on \(model.selected?.host.name ?? "this host").")
                    .frame(maxWidth: AppLayout.mcpExplanationWidth, alignment: .leading)
                Spacer(minLength: NW.Space.m)
                MCPAddServerButton(editable: model.mcpEditable) { sheet = .add(.remote) }
            }
            HStack(spacing: NW.Space.m) {
                NWSearchField("Filter servers", text: $query).frame(width: AppLayout.mcpFilterWidth)
                Spacer(minLength: NW.Space.m)
                Button("Reload") {
                    guard let file = model.selectedFile else { return }
                    Task { await model.navigate(.file(file)) }
                }.buttonStyle(.nw(.secondary)).disabled(model.fileLoading || model.saving)
            }
            if let problem = model.mcp.problem {
                NWInlineProblem(problem)
            } else {
                ScrollView {
                    MCPServerList(rows: visible, details: model.mcp.details, editable: model.mcpEditable,
                                  expanded: expanded, empty: query.isEmpty ? "No servers in this file yet. Add a server to get started." : "No servers match your search.",
                                  rowActions: rowActions, detailActions: detailActions)
                }
                .scrollIndicators(.hidden)
            }
            Text(model.mcp.native
                 ? "Only trusted projects load .pi/mcp.json. Sign-in credentials stay on the project's host; live status belongs to its threads."
                 : "This file is used when Also use a repo’s .mcp.json is on in MCP settings. Its tools use Search. Sign-in credentials stay on the project's host.")
                .font(.nwSans(AppLayout.mcpNoteSize)).foregroundStyle(Color.nw.textTertiary)
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
                                Task {
                                    do {
                                        try await model.removeMCP(name)
                                        if expanded == name { expanded = nil }
                                        removing = nil
                                    } catch { removeError = String(describing: error) }
                                }
                            },
                        ]) { if let removeError { NWInlineProblem(removeError) } }
                .disabled(model.saving)
                .interactiveDismissDisabled(model.saving)
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
              }, remove: { removeError = nil; removing = name })
    }
}
