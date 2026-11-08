import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread's Files (DuoSidePaneTabs, Files card; iPadPaneFiles): the thread's folder on its host over `files.v1`. Wide enough
/// (the iPad's pane), the tree sits beside open files that edit and save over `files.write.v1` (`ThreadFilesSplit`); narrower, a
/// filter over the expanded folders, a lazy tree, and a tapped file read in place of the tree with a back to it. A host without
/// `files.v1` keeps the tab and says it needs a newer Shepherd. The side pane mounts this; `ThreadFilesScreen` pushes it on compact width.
struct ThreadFilesPane: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts
    @Environment(ThreadStores.self) private var threads
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let host = hosts.host(thread.host)
        let name = host?.name ?? "the host"
        if host == nil || (host?.phase == .connected && host?.agent(thread.agent) == nil) {
            ThreadFilesMessage(text: "This thread or host is no longer available.")
        } else if let host, host.phase == .connected, !host.supports(RemoteProtocol.filesCapability) {
            ThreadFilesMessage(text: "Files needs a newer Shepherd on \(name).")
        } else {
            let agent = host?.agent(thread.agent)
            let model = ThreadFilesStores.shared.model(for: thread, hosts: hosts)
            let agentPath = Self.relative(threads.store(for: thread).editingPath, folder: host.flatMap { Self.folder(agent, in: $0.state) })
            let saves = host?.supports(RemoteProtocol.filesWriteCapability) == true
            GeometryReader { proxy in
                if proxy.size.width >= MobileLayout.filesSplitMinWidth {
                    ThreadFilesSplit(model: model, place: place(agent, host: host, name: name), editable: saves, agentPath: agentPath)
                } else {
                    // A narrow iPad pane (the sidebar beside it) still edits, a file in place of the tree; the phone reads.
                    let edits = saves && navigator.layout == .pad
                    let folder = agent?.worktreeBranch != nil ? "worktree" : "folder"
                    ThreadFilesContent(model: model, editable: edits,
                                       footer: edits ? "The thread’s \(folder) on \(name). Tap a file to edit it here."
                                           : "Read-only. The thread’s \(folder) on \(name). Tap a file to read it here.")
                }
            }
            .onAppear { ThreadFilesStores.shared.appeared(thread, model: model) }
            .onDisappear { ThreadFilesStores.shared.disappeared(thread, model: model) }
            // A new connection retries failures. A request is shared: one disappearing
            // window must not cancel the load another window is still waiting for.
            .task(id: host?.session) {
                await model.loadIfNeeded()
            }
            // The agent's edit ended (or moved to another file): the open file takes what it wrote.
            .onChange(of: agentPath) { Task { await model.checkDisk() } }
            .id(thread)
        }
    }

    private func place(_ agent: Agent?, host: MobileHost?, name: String) -> ThreadFilesPlace {
        let space = host?.state.spaces.first { $0.id == agent?.spaceID }?.name
        return ThreadFilesPlace(space: space ?? "Files", branch: agent?.worktreeBranch, host: name)
    }

    /// The folder the host serves the thread's files from: its layout's cwd, else its space's.
    static func folder(_ agent: Agent?, in state: ShepherdState) -> String? {
        guard let agent else { return nil }
        return state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd ?? state.spaces.first { $0.id == agent.spaceID }?.path
    }

    /// The agent's edit path as the tree names it: relative to `folder`, as the call names it when it already is.
    static func relative(_ path: String?, folder: String?) -> String? {
        guard let path else { return nil }
        guard path.hasPrefix("/") else { return (path as NSString).standardizingPath }
        guard let folder else { return nil }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }
}

/// Files pushed on its own on compact width: the pane under the system's bars.
struct ThreadFilesScreen: View {
    let thread: AgentRef

    var body: some View {
        ThreadFilesPane(thread: thread)
            .background(Color.sh.bgWindow)
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The tree, or the file open in its place.
struct ThreadFilesContent: View {
    @Bindable var model: ThreadFilesModel
    var editable = false
    let footer: String
    @FocusState private var filtering: Bool

    var body: some View {
        if let path = model.openPath {
            ThreadFileView(path: path, content: model.content, back: { model.close() }, retry: { Task { await model.open(path) } },
                           editing: editable ? model : nil)
        } else {
            VStack(spacing: 0) {
                SHTouchSearchField("Filter files", text: $model.filter, focus: $filtering)
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.s)
                tree
                    .frame(maxHeight: .infinity)
                Text(footer)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MobileLayout.gutter)
                    .padding(.vertical, SH.Space.l)
                    .overlay(alignment: .top) { SHHairline() }
            }
            .background(Color.sh.bgWindow)
        }
    }

    @ViewBuilder private var tree: some View {
        switch model.phase {
        case .loading:
            ThreadFilesMessage(text: "Loading files…")
        case .failed(let message):
            SHFileNotice(.failed(message)) { Task { await model.loadIfNeeded() } }
        case .loaded where model.rows.isEmpty:
            ThreadFilesMessage(text: model.filter.isEmpty ? "This folder is empty." : "No files match in the open folders.")
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ThreadFileRow(row: row, selected: row.id == model.selectedPath) {
                            Task {
                                if case .folder = row.kind { await model.toggle(row.id) } else if row.kind == .file { await model.open(row.id) }
                            }
                        }
                    }
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.xs)
            }
        }
    }
}

/// One line of the tree: a folder's chevron, or a file's page, indented by depth.
struct ThreadFileRow: View, Equatable {
    let row: ThreadFilesModel.Row
    let selected: Bool
    let tap: () -> Void

    static func == (a: ThreadFileRow, b: ThreadFileRow) -> Bool { a.row == b.row && a.selected == b.selected }

    var body: some View {
        let sh = Color.sh
        Button(action: tap) {
            HStack(spacing: SH.Space.m) {
                Image(systemName: symbol)
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .frame(width: MobileLayout.fileTreeIcon)
                    .opacity(row.kind == .note ? 0 : 1)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.name)
                        .font(row.kind == .note ? .sh(.caption) : .sh(.ui, weight: selected ? .semibold : .regular))
                        .foregroundStyle(row.kind == .note ? sh.textTertiary : sh.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error = row.error {
                        Text(error).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if case .folder(_, true) = row.kind { ProgressView().controlSize(.small) }
            }
            .padding(.leading, SH.Space.m + CGFloat(row.depth) * MobileLayout.fileTreeIndent)
            .padding(.trailing, SH.Space.m)
            .frame(minHeight: SH.Height.touch)
            .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.kind == .note)
        .accessibilityLabel(accessibility)
    }

    private var symbol: String {
        switch row.kind {
        case .folder(let expanded, _): expanded ? "chevron.down" : "chevron.right"
        case .file, .note: "doc"
        }
    }

    private var accessibility: String {
        switch row.kind {
        case .folder(let expanded, _): "\(row.name), folder, \(expanded ? "open" : "closed")"
        case .file: row.name
        case .note: row.name
        }
    }
}

/// A file read in place of the tree: back to the tree, its name and folder, then its text in the code style, read-only.
struct ThreadFileView: View {
    let path: String
    let content: ThreadFilesModel.Content
    let back: () -> Void
    let retry: () -> Void
    /// In place of the read-only text, the iPad's editor of this model, when the host saves.
    var editing: ThreadFilesModel? = nil

    var body: some View {
        let sh = Color.sh
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.s) {
                Button(action: back) { Image(systemName: "chevron.left") }
                    .buttonStyle(.shIcon(size: SH.Height.touch - SH.Space.xs))
                    .accessibilityLabel("All files")
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text((path as NSString).lastPathComponent)
                        .font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    let folder = (path as NSString).deletingLastPathComponent
                    if !folder.isEmpty {
                        Text(folder).font(.sh(.mono)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SH.Space.s)
            .padding(.vertical, SH.Space.xs)
            .overlay(alignment: .bottom) { SHHairline() }
            if let editing {
                ThreadFileEditor(model: editing, path: path, editable: true).id(path)
            } else {
                switch content {
                case .loading: SHFileNotice(.loading)
                case .text(let text): SHFileSource(text)
                case .failed(let message): SHFileNotice(.failed(message), retry: retry)
                }
            }
        }
        .background(sh.bgWindow)
    }
}

/// What the pane says in place of the tree.
struct ThreadFilesMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.sh(.ui))
            .foregroundStyle(Color.sh.textSecondary)
            .multilineTextAlignment(.center)
            .padding(SH.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.sh.bgWindow)
    }
}

#Preview("Files") {
    let listings: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [ThreadFileEntry(name: "Widgets", kind: .directory), ThreadFileEntry(name: "Sources", kind: .directory),
                                        ThreadFileEntry(name: "render.py", kind: .file, size: 1_204),
                                        ThreadFileEntry(name: "AGENTS.md", kind: .file, size: 3_310)]),
        "Widgets": ThreadFileListing(entries: [ThreadFileEntry(name: "NeedsYouWidget.swift", kind: .file, size: 2_048),
                                               ThreadFileEntry(name: "WorkingCountWidget.swift", kind: .file, size: 1_100)]),
    ]
    let model = ThreadFilesModel(list: { path, _ in listings[path] ?? ThreadFileListing(entries: []) },
                                 read: { _ in Data("import WidgetKit\n\nstruct NeedsYouWidget: Widget {}\n".utf8) })
    ThreadFilesContent(model: model, footer: "Read-only. The thread’s worktree on macbook. Tap a file to read it here.")
        .task {
            await model.loadIfNeeded()
            await model.toggle("Widgets")
        }
}
