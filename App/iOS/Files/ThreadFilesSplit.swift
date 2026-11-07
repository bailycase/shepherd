import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Where the Files tree's head says the thread runs: its space, branch and host.
struct ThreadFilesPlace: Equatable {
    var space: String
    var branch: String?
    var host: String
}

/// The iPad's Files pane at full width (iPadPaneFiles): the tree on the left with the space, branch and host over it;
/// on the right the open files as tabs over an editor that saves to the host (`files.write.v1`) only over the text it
/// was edited from, with the conflict banner when the file moved on, and the lines the person and the agent changed
/// marked. The file the agent is editing spins in the tree and its tab.
struct ThreadFilesSplit: View {
    @Bindable var model: ThreadFilesModel
    let place: ThreadFilesPlace
    /// The host saves (`files.write.v1`); else the editor reads only.
    let editable: Bool
    /// The file the agent is editing now, relative to the thread's folder.
    let agentPath: String?
    @State private var filtering = false
    @FocusState private var filterFocus: Bool
    /// A tab with unsaved edits the person asked to close: confirmed first.
    @State private var closing: String?

    var body: some View {
        HStack(spacing: 0) {
            tree
                .frame(width: MobileLayout.filesTreeColumn)
                .background(Color.sh.bgBase)
            SHHairline(.vertical)
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
        .confirmationDialog("Close \((closing.map { ($0 as NSString).lastPathComponent }) ?? "") without saving?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
                            titleVisibility: .visible, presenting: closing) { path in
            Button("Discard Changes", role: .destructive) { Task { await model.closeTab(path) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your unsaved edits will be lost.")
        }
    }

    // MARK: Tree

    private var tree: some View {
        let sh = Color.sh
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: SH.Space.s) {
                    Text(place.space)
                        .font(.sh(.mono, weight: .semibold))
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        filtering.toggle()
                        filterFocus = filtering
                        if !filtering { model.filter = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.shIcon(size: SH.Height.controlL))
                    .accessibilityLabel(filtering ? "Hide filter" : "Go to file")
                }
                HStack(spacing: SH.Space.s) {
                    if let branch = place.branch {
                        Image(systemName: SHGlyph.gitBranch.symbolName)
                        Text(branch).font(.sh(.mono)).lineLimit(1).truncationMode(.middle)
                        Text("·")
                    }
                    Image(systemName: "desktopcomputer")
                    Text(place.host).lineLimit(1)
                }
                .font(.sh(.micro))
                .foregroundStyle(sh.textTertiary)
                .accessibilityElement(children: .combine)
            }
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.m)
            .padding(.vertical, SH.Space.m)
            .overlay(alignment: .bottom) { SHHairline() }
            if filtering {
                SHTouchSearchField("Filter files", text: $model.filter, focus: $filterFocus)
                    .padding(SH.Space.s)
            }
            treeRows
                .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private var treeRows: some View {
        switch model.phase {
        case .loading:
            ThreadFilesMessage(text: "Loading files…").background(Color.sh.bgBase)
        case .failed(let message):
            SHFileNotice(.failed(message)) { Task { await model.loadIfNeeded() } }
        case .loaded where model.rows.isEmpty:
            ThreadFilesMessage(text: model.filter.isEmpty ? "This folder is empty." : "No files match in the open folders.")
                .background(Color.sh.bgBase)
        case .loaded:
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ThreadFilePadRow(row: row, selected: row.id == model.openPath, agentWorking: row.id == agentPath) {
                            Task {
                                if case .folder = row.kind { await model.toggle(row.id) } else if row.kind == .file { await model.open(row.id) }
                            }
                        }
                        .equatable()
                    }
                }
                .padding(SH.Space.s)
            }
        }
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        VStack(spacing: 0) {
            if !model.openTabs.isEmpty {
                tabs
            }
            if let path = model.openPath {
                ThreadFileEditor(model: model, path: path, editable: editable)
                    .id(path)
            } else {
                VStack(spacing: SH.Space.m) {
                    Image(systemName: SHGlyph.document.symbolName)
                        .font(.sh(.title, weight: .light))
                    Text("Select a file to view").font(.sh(.caption))
                }
                .foregroundStyle(Color.sh.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(model.openTabs, id: \.self) { path in
                    ThreadFileTab(name: (path as NSString).lastPathComponent, active: path == model.openPath,
                                  dirty: model.edits[path]?.isDirty == true, agentWorking: path == agentPath,
                                  select: { Task { await model.open(path) } },
                                  close: {
                                      if model.edits[path]?.isDirty == true { closing = path } else { Task { await model.closeTab(path) } }
                                  })
                }
            }
        }
        .frame(height: MobileLayout.filesTabHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.bgBase)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// One line of the split tree (iPadPaneFiles): a folder's chevron and folder, or a file's page past the chevron's
/// column, its name, and a spinner while the agent edits it.
struct ThreadFilePadRow: View, Equatable {
    let row: ThreadFilesModel.Row
    let selected: Bool
    let agentWorking: Bool
    let tap: () -> Void

    static func == (a: ThreadFilePadRow, b: ThreadFilePadRow) -> Bool {
        a.row == b.row && a.selected == b.selected && a.agentWorking == b.agentWorking
    }

    var body: some View {
        let sh = Color.sh
        Button(action: tap) {
            HStack(spacing: SH.Space.s) {
                Group {
                    if case .folder(let expanded, _) = row.kind {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    } else {
                        Color.clear
                    }
                }
                .font(.sh(.micro, weight: .semibold))
                .frame(width: MobileLayout.filesChevron)
                Image(systemName: icon)
                    .font(.sh(.caption))
                    .opacity(row.kind == .note ? 0 : 1)
                Text(row.name)
                    .font(row.kind == .note ? .sh(.micro) : .sh(.caption, weight: selected ? .semibold : .regular))
                    .foregroundStyle(row.kind == .note ? sh.textTertiary : sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if agentWorking || row.kind == .folder(expanded: true, loading: true) {
                    ProgressView().progressViewStyle(.shSpinner)
                        .accessibilityLabel(agentWorking ? "The agent is editing \(row.name)" : "Loading")
                }
            }
            .foregroundStyle(sh.textTertiary)
            .padding(.leading, SH.Space.m + CGFloat(row.depth) * MobileLayout.filesTreeLevel)
            .padding(.trailing, SH.Space.m)
            .frame(minHeight: SH.Height.controlL)
            .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row.kind == .note)
        .accessibilityLabel(accessibility)
    }

    private var icon: String {
        if case .folder = row.kind { return "folder" }
        return "doc"
    }

    private var accessibility: String {
        switch row.kind {
        case .folder(let expanded, _): "\(row.name), folder, \(expanded ? "open" : "closed")"
        case .file, .note: row.name
        }
    }
}

/// One open file's tab: its name in mono, then a lantern dot while it has unsaved edits, a spinner while the agent
/// edits it, else its close button. The active tab sits on the editor's background under a lantern rule.
struct ThreadFileTab: View {
    let name: String
    let active: Bool
    let dirty: Bool
    let agentWorking: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Button(action: select) {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "doc").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    Text(name).font(.sh(.mono)).foregroundStyle(active ? sh.textPrimary : sh.textSecondary).lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(name)
            .accessibilityAddTraits(active ? .isSelected : [])
            .accessibilityValue(dirty ? "Unsaved changes" : agentWorking ? "The agent is editing it" : "")
            .accessibilityAction(named: "Close") { close() }
            // The pointer brings the close button, as on the Mac; touch closes from the tab's menu.
            if hovering {
                Button(action: close) { Image(systemName: "xmark").font(.sh(.micro, weight: .semibold)) }
                    .buttonStyle(.shIcon(size: SH.Height.controlS))
                    .accessibilityHidden(true)
            } else if agentWorking {
                ProgressView().progressViewStyle(.shSpinner)
            } else if dirty {
                Circle().fill(sh.lantern).frame(width: MobileLayout.filesDirtyDot, height: MobileLayout.filesDirtyDot)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: MobileLayout.filesTabHeight)
        .background(active ? sh.bgWindow : sh.bgBase)
        .overlay(alignment: .top) {
            if active { sh.lantern.frame(height: MobileLayout.filesActiveTabRule) }
        }
        .overlay(alignment: .trailing) { SHHairline(.vertical) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Close", systemImage: "xmark", action: close)
        }
    }
}

/// The open file: its path with Revert and Save, the conflict banner or why a save failed, the editor, and the status
/// bar (the marks' legend, the caret, the language and the indentation).
struct ThreadFileEditor: View {
    @Bindable var model: ThreadFilesModel
    let path: String
    let editable: Bool
    @State private var cursor = FileCursor()

    var body: some View {
        let sh = Color.sh
        let edit = model.edits[path]
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Text(path.split(separator: "/").joined(separator: " › "))
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if editable, let edit {
                    Button("Revert") { model.revert() }
                        .buttonStyle(.sh(.ghost, size: .s))
                        .disabled(!edit.isDirty)
                    Button { Task { await model.save() } } label: { SHButtonTitle("Save", chord: "⌘S") }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!edit.isDirty || edit.conflict != nil || model.saving)
                        .accessibilityLabel("Save")
                }
            }
            .padding(.leading, SH.Space.l)
            .padding(.trailing, SH.Space.m)
            .frame(height: MobileLayout.filesPathBarHeight)
            .overlay(alignment: .bottom) { SHHairline() }
            if editable, let conflict = edit?.conflict {
                ThreadFileConflict(name: (path as NSString).lastPathComponent, saving: model.saving,
                                   revert: { model.revert() }, overwrite: { Task { await model.save(overwrite: true) } })
                    .id(conflict)
            } else if editable, let error = model.saveError {
                SHBanner(.failed, title: "Couldn’t save \((path as NSString).lastPathComponent)", message: error)
                    .padding(SH.Space.m)
            }
            switch model.content {
            case .loading where edit == nil:
                SHFileNotice(.loading)
            case .failed(let message):
                SHFileNotice(.failed(message)) { Task { await model.open(path) } }
            default:
                if let edit {
                    FileCodeEditor(path: path, text: edit.text, saved: edit.saved, before: edit.before, revision: model.textRevision,
                                   editable: editable, onEdit: { [model, path] in model.setText($0, for: path) },
                                   onCursor: { cursor = $0 })
                    statusBar(edit)
                }
            }
        }
        .background(sh.bgWindow)
    }

    private func statusBar(_ edit: FileEdit) -> some View {
        let ext = (path as NSString).pathExtension
        let status = Text([cursor.label, ext.isEmpty ? nil : ext.uppercased(), edit.indentation].compactMap { $0 }.joined(separator: " · "))
            .font(.sh(.mono))
            .lineLimit(1)
        // The legend goes first when the pane is too narrow for both.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: SH.Space.l) {
                legend("yours, unsaved", Color.sh.lantern)
                legend("changed by the agent", Color.sh.running)
                Spacer(minLength: 0)
                status
            }
            HStack { Spacer(minLength: 0); status }
        }
        .font(.sh(.caption))
        .foregroundStyle(Color.sh.textTertiary)
        .padding(.horizontal, SH.Space.l)
        .frame(height: MobileLayout.filesStatusBarHeight)
        .overlay(alignment: .top) { SHHairline() }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: SH.Space.xs) {
            color.frame(width: MobileLayout.fileMarkWidth, height: MobileLayout.filesLegendMarkHeight)
            Text(title).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The file changed on the host under unsaved edits: nothing is written until the person chooses.
struct ThreadFileConflict: View {
    let name: String
    let saving: Bool
    let revert: () -> Void
    let overwrite: () -> Void

    var body: some View {
        SHBanner(.attention, title: "\(name) changed on the host",
                 message: "Your edits aren’t saved. Overwrite writes yours over the new version; Revert takes it and drops yours.") {
            Button("Revert", action: revert).buttonStyle(.sh(.ghost, size: .s))
            Button("Overwrite", action: overwrite).buttonStyle(.sh(.secondary, size: .s)).disabled(saving)
        }
        .padding(SH.Space.m)
    }
}
