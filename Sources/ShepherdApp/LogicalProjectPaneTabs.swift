import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Project pane's Files and Automations tabs (ProjectLead-Started header), and the New thread sheet over a Project.

// MARK: Files

/// The Project's private folder on its OWNER, read-only (`files.v1`): one directory at a time, a folder opens the next, and a file
/// is previewed as data (text, PNG or JPEG) beneath the list. Nothing is opened, launched or revealed on this Mac: a path on the
/// owner means nothing here. Each entry is the owner's own, with no provenance claimed (the owner has no publication producer yet).
struct LogicalProjectFiles: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    @State private var files = LogicalProjectFilesModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    switch files.listing {
                    case .loading:
                        Text("Loading files…").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                    case .failed(let message):
                        Text(message).font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { reload() }.buttonStyle(NWLeadSecondaryButton())
                    case .listed(let listing):
                        listed(listing)
                    }
                }
                .padding(NWLeadMetrics.paneHeaderInset)
            }
            .scrollBounceBehavior(.basedOnSize)
            if let preview = files.preview { previewCard(preview) }
        }
        .task(id: ref) {
            await files.open(ref, via: vm.logicalProjects)
            await previewRequested()
        }
        // A chip pressed while this tab is already up. (A chip pressed from the conversation mounts the tab: the task above reads it.)
        .onChange(of: vm.logicalProjectPaneFile?.file) { Task { await previewRequested() } }
    }

    /// The published file a task card's chip asked for, previewed as data through the owner.
    private func previewRequested() async {
        guard let (owner, file) = vm.logicalProjectPaneFile, owner == ref else { return }
        vm.logicalProjectPaneFile = nil
        await files.read(.init(name: file.name, relativePath: file.relativePath, kind: .file, size: file.size, modifiedAt: 0),
                         in: ref, via: vm.logicalProjects)
    }

    private func reload() {
        Task { await files.open(ref, path: files.path, via: vm.logicalProjects) }
    }

    @ViewBuilder private func listed(_ listing: LogicalProjectFileListing) -> some View {
        if let parent = files.parent {
            row(symbol: "chevron.left", name: "Back", detail: parent.isEmpty ? "Project folder" : parent, trailing: nil) {
                Task { await files.open(ref, path: parent, via: vm.logicalProjects) }
            }
        }
        if listing.entries.isEmpty {
            Text("No files yet.").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
        }
        ForEach(listing.entries, id: \.relativePath) { entry in
            row(symbol: entry.kind == .folder ? "folder" : NWGlyph.document.symbolName, name: entry.name, detail: nil,
                trailing: entry.kind == .folder ? nil : LogicalProjectFilesModel.sizeText(entry.size)) {
                switch entry.kind {
                case .folder: Task { await files.open(ref, path: entry.relativePath, via: vm.logicalProjects) }
                case .file: Task { await files.read(entry, via: vm.logicalProjects) }
                }
            }
        }
        if listing.truncated {
            // The owner capped the list: this is not the whole folder, and it says so.
            Text("Showing the first \(listing.entries.count) items. This folder has more.")
                .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
        }
    }

    private func row(symbol: String, name: String, detail: String?, trailing: String?, action: @escaping () -> Void) -> some View {
        NWLeadFileRow(symbol: symbol, name: name, detail: detail, trailing: trailing, action: action)
    }

    /// The previewed file as inert data: text is selectable plain text, an image is a picture. Never active content.
    private func previewCard(_ preview: LogicalProjectFilesModel.Preview) -> some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                Text(preview.name).font(.nwMono(NWLeadMetrics.chipText)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { files.closePreview() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.nwIcon(size: NWLeadMetrics.paneHeaderButton))
                    .nwHelp("Close preview")
                    .accessibilityLabel("Close preview")
            }
            switch preview {
            case .loading: Text("Loading…").font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            case .failed(_, let message): Text(message).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            case .text(_, let text):
                ScrollView { Text(text).font(.nwMono(NWLeadMetrics.chipText)).foregroundStyle(Color.nw.textSecondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: NWLeadMetrics.filePreviewHeight)
            case .image(let name, let data):
                if let image = NSImage(data: data) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: NWLeadMetrics.filePreviewHeight)
                        .accessibilityLabel(name)
                }
            }
        }
        .padding(NWLeadMetrics.paneHeaderInset)
        .background(Color.nw.bgRaised)
        .overlay(alignment: .top) { NWHairline() }
    }
}

// MARK: Automations

/// The Automations tab of the pane: the same real rows as Project settings, read only here (the switches live in settings).
struct LogicalProjectPaneAutomations: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project

    var body: some View {
        ScrollView(.vertical) {
            LogicalProjectAutomationsTab(vm: vm, ref: ref, project: project)
                .padding(NWLeadMetrics.paneHeaderInset)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: New thread

extension ShepherdViewModel {
    /// New thread over a Project: opens the sheet with the Project's first linked Space chosen.
    func beginAssigningProjectTask(_ ref: LogicalProjectRef) {
        guard let project = logicalProjects.project(ref) else { return }
        var draft = AssignProjectTaskDraft()
        draft.space = project.linkedSpaces.first?.spaceID
        assigningProjectTask = draft
    }
}

/// The task a person assigns: what to do and which of the Project's Spaces it works in. It goes through the same revisioned
/// `assign` the runtime already serves, with one operation identity per sheet, so a retry never starts it twice.
struct AssignProjectTaskSheet: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    @Binding var draft: AssignProjectTaskDraft
    let dismiss: () -> Void

    private var project: Project? { vm.logicalProjects.project(ref) }
    @State private var ownerHosts: [ProjectHostOption]?

    /// The hosts this Project may run a thread on: all the owner knows under "any connected host", else the ones it selected.
    private var hostChoices: [ProjectHostOption] {
        guard let project, let known = ownerHosts else { return [] }
        if project.settings.hostPolicy == .anyConnected { return known }
        return known.filter { project.settings.allowedHosts.contains($0.reference) }
    }
    private var spaces: [Space] {
        let known = vm.ownerSpaces(of: ref.home)
        return (project?.linkedSpaces ?? []).compactMap { link in known.first { $0.id == link.spaceID } }
    }

    var body: some View {
        DialogSheet(
            title: "New thread",
            subtitle: project.map { "A task for \($0.name), in one of its spaces." },
            status: draft.failure ?? (spaces.isEmpty ? "Add a space to this project in its settings first." : nil),
            actions: [
                DialogAction("Cancel", kind: .cancel) { if !draft.assigning { dismiss() } },
                DialogAction(draft.assigning ? "Starting…" : "Start thread", kind: .prominent, isEnabled: draft.canAssign) { assign() },
            ]
        ) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                TextField("Title", text: $draft.title).textFieldStyle(.nw).accessibilityLabel("Title")
                TextField("What should it do?", text: $draft.prompt, axis: .vertical).textFieldStyle(.nw)
                    .lineLimit(3...8).accessibilityLabel("What should it do?")
                NWPopupMenu(spaces.first { $0.id == draft.space }?.name ?? "Choose a space") {
                    ForEach(spaces) { space in Button(space.name) { draft.space = space.id } }
                }
                .disabled(spaces.isEmpty)
                .accessibilityLabel("Space")
                // Where it runs: only when the Project allows more than its owner, from the OWNER's own host list.
                if hostChoices.count > 1 {
                    NWPopupMenu(hostChoices.first { $0.reference == (draft.host ?? .local) }?.name ?? "Choose a host") {
                        ForEach(hostChoices, id: \.reference) { choice in
                            Button(choice.name) { draft.host = choice.reference == .local ? nil : choice.reference }
                        }
                    }
                    .nwHelp("Host")
                    .accessibilityLabel("Host")
                }
            }
            .padding(.horizontal, NWDialogMetrics.inset)
            .padding(.bottom, NW.Space.l)
        }
        .task(id: ref) { ownerHosts = await vm.logicalProjects.hostOptions(ref.home) }
    }

    private func assign() {
        guard draft.canAssign, let space = draft.space else { return }
        draft.assigning = true
        draft.failure = nil
        let operation = draft.id
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let ok = await vm.logicalProjects.run(ref, .assign(operationID: operation, spaceID: space, title: title, prompt: prompt, host: draft.host))
            draft.assigning = false
            if ok { dismiss() } else { draft.failure = vm.logicalProjects.failure?.message ?? "The thread was not started." }
        }
    }
}
