import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A thread's Files (DuoSidePaneTabs, Files card): the thread's folder on its host, read-only, over `files.v1`. A filter over the
/// expanded folders, a lazy tree, and a tapped file read in place of the tree with a back to it. A host without `files.v1` keeps the
/// tab and says it needs a newer Shepherd. The side pane mounts this; `ThreadFilesScreen` pushes it on compact width.
struct ThreadFilesPane: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let host = hosts.host(thread.host)
        let name = host?.name ?? "the host"
        if let host, host.phase == .connected, !host.supports(RemoteProtocol.filesCapability) {
            ThreadFilesMessage(text: "Files needs a newer Shepherd on \(name).")
        } else {
            let worktree = host?.agent(thread.agent)?.worktreeBranch != nil
            ThreadFilesContent(model: ThreadFilesStores.shared.model(for: thread, hosts: hosts),
                               footer: "Read-only. The thread’s \(worktree ? "worktree" : "folder") on \(name). Tap a file to read it here.")
                // A new connection reads again what failed while the host was away.
                .task(id: host?.session) {
                    await ThreadFilesStores.shared.model(for: thread, hosts: hosts).loadIfNeeded()
                }
        }
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

/// One tree per thread, kept while the app runs, so leaving Files and coming back (or folding the phone) keeps the open folders.
@MainActor
final class ThreadFilesStores {
    static let shared = ThreadFilesStores()
    private var models: [AgentRef: ThreadFilesModel] = [:]

    func model(for ref: AgentRef, hosts: MobileHosts) -> ThreadFilesModel {
        if let model = models[ref] { return model }
        let model = ThreadFilesModel(list: { [weak hosts] path, hidden in
            try await Self.client(ref, hosts).listFiles(agentID: ref.agent, path: path, showHidden: hidden)
        }, read: { [weak hosts] path in
            try await Self.client(ref, hosts).readFile(agentID: ref.agent, path: path)
        })
        models[ref] = model
        return model
    }

    func forget(host: UUID) {
        models = models.filter { $0.key.host != host }
    }

    private static func client(_ ref: AgentRef, _ hosts: MobileHosts?) throws -> RemoteHostClient {
        let host = hosts?.host(ref.host)
        guard let client = host?.connectedClient else {
            throw RemoteHostClientError.rejected(code: "offline", message: host.map { "\($0.name) is offline." } ?? "This host was forgotten.")
        }
        return client
    }
}

/// The tree, or the file open in its place.
struct ThreadFilesContent: View {
    @Bindable var model: ThreadFilesModel
    let footer: String
    @FocusState private var filtering: Bool

    var body: some View {
        if let path = model.openPath {
            ThreadFileView(path: path, content: model.content, back: { model.close() }, retry: { Task { await model.open(path) } })
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
            SHArtifactNotice(.failed(message)) { Task { await model.loadIfNeeded() } }
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
            switch content {
            case .loading: SHArtifactNotice(.loading)
            case .text(let text): SHArtifactSource(text)
            case .failed(let message): SHArtifactNotice(.failed(message), retry: retry)
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
