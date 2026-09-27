import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import UniformTypeIdentifiers

// Deleting, renaming, duplicating and importing designs and design systems (DesignLifecycleStates,
// docs/designs.md › Deleting and importing). Delete asks first, then the design leaves every
// surface at once and the toast offers Undo while its host holds it; import checks a ZIP or folder
// before anything lands and asks when it must.

/// A design this Mac shows: its own, or one saved on a connected host.
enum DesignTarget: Hashable {
    case local(DesignID)
    case remote(RemoteDesignRef)
}

/// Delete design while it asks (DeleteDesignDialog).
struct DesignDeleteRequest: Identifiable {
    let id = UUID()
    let target: DesignTarget
    let name: String
    let words: DeleteDesignWords
}

/// Delete design system while it asks (DeleteSystemDialog).
struct DesignSystemDeleteRequest: Identifiable {
    let id = UUID()
    let target: DesignSystemTarget
    let name: String
    let words: DeleteSystemWords
}

/// Rename… of a design or a design system.
struct DesignRenameRequest: Identifiable {
    enum Subject: Hashable {
        case design(DesignTarget)
        case system(String)
    }

    let id = UUID()
    let subject: Subject
    let name: String
}

extension ShepherdViewModel {
    // MARK: Menus

    /// A design's menu where it opens (DesignMenu).
    func designMenu(_ target: DesignTarget, context: DesignMenuContext) -> DesignMenu {
        switch target {
        case .local(let id):
            return DesignMenu.design(context, hasSystem: design(id)?.systemNamespace != nil)
        case .remote(let ref):
            let connection = remoteHosts.connections.first { $0.id == ref.hostID }
            return DesignMenu.design(context, hasSystem: false, remote: connection?.config.name ?? "The host",
                                     hostDeletes: connection?.supportsDesignDelete == true)
        }
    }

    /// What a design's menu item does.
    func performDesignMenu(_ action: DesignMenuAction, on target: DesignTarget) {
        switch (action, target) {
        case (.open, .local(let id)): openDesign(id)
        case (.open, .remote(let ref)): openRemoteDesign(ref)
        case (.rename, _): requestDesignRename(target)
        case (.duplicate, .local(let id)): duplicateDesign(id)
        case (.export, .local(let id)): openDesignExport(id)
        case (.showSystem, .local(let id)): if let system = design(id)?.systemNamespace { openDesignSystem(system) }
        case (.removeFromRecents, .local(let id)): removeDesignFromRecents(id)
        case (.delete, _): requestDesignDelete(target)
        default: break
        }
    }

    /// A design system's menu (SystemMenu), for its card or its page.
    func designSystemMenu(_ target: DesignSystemTarget) -> DesignMenu {
        switch target {
        case .build(let id):
            return DesignMenu.system(name: design(id)?.name ?? "It", builtIn: false, repo: nil, building: true)
        case .system(let namespace):
            let summary = designSystems.summary(namespace)
            let repo = summary?.info.spaceID.flatMap { id in state.spaces.first { $0.id == id }?.name }
            let resyncs = repo != nil && summary?.info.sources.isEmpty == false
            return DesignMenu.system(name: summary?.info.title ?? namespace, builtIn: summary?.builtIn == true,
                                     repo: resyncs ? repo : nil, building: systemIsBuilding(namespace))
        }
    }

    /// A build's system, once its agent wrote one; the build itself before.
    func systemTarget(ofBuild id: DesignID) -> DesignSystemTarget {
        designSystems.summaries.first { $0.info.ownerDesignID == id }.map { .system($0.namespace) } ?? .build(id)
    }

    /// What a system's menu item does.
    func performDesignSystemMenu(_ action: DesignMenuAction, on target: DesignSystemTarget) {
        switch (action, target) {
        case (.open, .system(let namespace)): openDesignSystem(namespace)
        case (.open, .build(let id)): openSystemBuild(id)
        case (.resync, .system(let namespace)):
            Task {
                do { _ = try await server.resyncDesignSystem(namespace) } catch { remoteActionError = "Couldn't re-sync \(namespace): \(error)" }
            }
        case (.rename, .system(let namespace)):
            designRename = DesignRenameRequest(subject: .system(namespace), name: designSystems.summary(namespace)?.info.title ?? namespace)
        case (.duplicateSystem, .system(let namespace)):
            Task {
                do {
                    let copy = try await server.duplicateDesignSystem(namespace)
                    await loadDesignSystems()
                    openDesignSystem(copy.info.namespace)
                } catch {
                    remoteActionError = "Couldn't duplicate \(namespace): \(error)"
                }
            }
        case (.deleteSystem, _): requestDesignSystemDelete(target)
        default: break
        }
    }

    // MARK: Rename and duplicate

    func requestDesignRename(_ target: DesignTarget) {
        switch target {
        case .local(let id):
            guard let design = design(id) else { return }
            designRename = DesignRenameRequest(subject: .design(target), name: design.name)
        case .remote(let ref):
            guard let design = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.state.designs.first(where: { $0.id == ref.designID })
            else { return }
            designRename = DesignRenameRequest(subject: .design(target), name: design.name)
        }
    }

    /// Rename's sheet confirmed: a design's name and canvas title (a host's through its canvas
    /// update), or a system's title.
    func commitDesignRename(_ request: DesignRenameRequest, to name: String) {
        designRename = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != request.name else { return }
        Task {
            do {
                switch request.subject {
                case .design(.local(let id)):
                    try await server.renameDesign(id, to: trimmed)
                    adopt(server.state)
                case .design(.remote(let ref)):
                    guard let library = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.designs else { return }
                    _ = try await Self.remoteDesign(library, .updateIndex(designID: ref.designID, patch: .object(["title": .string(trimmed)]),
                                                                          baseRevision: nil))
                case .system(let namespace):
                    try await server.renameDesignSystem(namespace, to: trimmed)
                    await loadDesignSystems()
                }
            } catch {
                remoteActionError = "Couldn't rename \(request.name): \(error)"
            }
        }
    }

    /// Duplicate: a copy of the design under a new name, selected on Designs.
    func duplicateDesign(_ id: DesignID) {
        Task {
            do {
                let copy = try await server.duplicateDesign(id)
                adopt(server.state)
                designsPageSelection = copy.id
            } catch {
                remoteActionError = "Couldn't duplicate \(design(id)?.name ?? "the design"): \(error)"
            }
        }
    }

    /// Remove from Recents: the design's row leaves the sidebar until it next changes.
    func removeDesignFromRecents(_ id: DesignID) {
        Task {
            do {
                try await server.removeDesignFromRecents(id)
                adopt(server.state)
            } catch {
                remoteActionError = "Couldn't remove \(design(id)?.name ?? "the design") from Recents: \(error)"
            }
        }
    }

    // MARK: Delete a design

    /// Delete design…: the dialog, naming what goes and what stays (DeleteDesignDialog); while
    /// the design agent draws, the warning and "Stop and delete".
    func requestDesignDelete(_ target: DesignTarget) {
        Task {
            switch target {
            case .local(let id):
                guard let design = design(id) else { return }
                let snapshot = try? await server.designSnapshot(id)
                let versions = try? await server.designs.versionCount(id)
                let comments = try? await server.designComments(id).comments.count
                let agent = state.agents.first { $0.id == design.agentID } ?? state.agents.first { $0.designID == id }
                let working = agent?.status == .working
                let drawing = agent.flatMap { threadStores.existing(for: $0.id)?.messages }.map(designBoardsDrawing) ?? 0
                let words = DeleteDesignWords(name: design.name, boards: snapshot?.index.boards.count ?? design.boardCount ?? 0,
                                              versions: versions, comments: comments, system: design.systemNamespace,
                                              agentWorking: working, drawing: drawing)
                designDeleteRequest = DesignDeleteRequest(target: target, name: design.name, words: words)
            case .remote(let ref):
                guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }),
                      let design = connection.state.designs.first(where: { $0.id == ref.designID }) else { return }
                let summary = connection.designs.listing?.designs.first { $0.id == ref.designID }
                let agent = connection.state.agents.first { $0.id == design.agentID }
                let working = agent?.status == .working
                let drawing = agent.flatMap { remoteThreadStores.existing(for: RemoteAgentRef(hostID: ref.hostID, agentID: $0.id))?.messages }
                    .map(designBoardsDrawing) ?? 0
                let words = DeleteDesignWords(name: design.name, boards: summary?.boardCount ?? design.boardCount ?? 0, versions: nil,
                                              comments: summary?.openComments, system: design.systemNamespace, agentWorking: working,
                                              drawing: drawing)
                designDeleteRequest = DesignDeleteRequest(target: target, name: design.name, words: words)
            }
        }
    }

    /// The dialog's Delete (or Stop and delete).
    func confirmDesignDelete(_ request: DesignDeleteRequest) {
        designDeleteRequest = nil
        Task { await deleteDesign(request.target, name: request.name) }
    }

    /// Deletes a design: a window showing it goes back to Designs, the design and its agent leave
    /// every surface at once (the agent's process stops), and the toast offers Undo while the
    /// host holds it. A failure brings it back where it was and says why, with Try again.
    func deleteDesign(_ target: DesignTarget, name: String) async {
        if designIsShown(target) { openDestination(.designs) }
        designToast = nil
        do {
            let deletion: DesignDeletion
            switch target {
            case .local(let id):
                deletion = try await server.deleteDesign(id)
                sessions.stateDidChange(server.state)
                adopt(server.state)
            case .remote(let ref):
                guard let library = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.designs else {
                    throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
                }
                guard case .deleted(let answer) = try await Self.remoteDesign(library, .delete(designID: ref.designID)) else {
                    throw RemoteDesignReply.unexpected
                }
                deletion = answer
            }
            let host: UUID? = if case .remote(let ref) = target { ref.hostID } else { nil }
            showDesignToast(DesignToast(kind: .deleted(deletion, host: host), name: name))
        } catch {
            let reason: String
            let host: UUID?
            switch target {
            case .local:
                reason = "\(Self.words(error)). It’s back where it was."
                host = nil
            case .remote(let ref):
                let hostName = remoteHosts.connections.first { $0.id == ref.hostID }?.config.name ?? "Its host"
                reason = DesignToast.remoteReason(host: hostName, error: error)
                host = ref.hostID
            }
            let id: DesignID = switch target { case .local(let id): id; case .remote(let ref): ref.designID }
            showDesignToast(DesignToast(kind: .designFailed(id, host: host), name: name, reason: reason))
        }
    }

    /// Whether the main column shows this design now.
    private func designIsShown(_ target: DesignTarget) -> Bool {
        switch target {
        case .local(let id): return shownDesign?.id == id
        case .remote(let ref):
            guard let remote = selectedRemoteAgent, remote.hostID == ref.hostID else { return false }
            return remoteDesign(drawnBy: remote)?.design.id == ref.designID
        }
    }

    // MARK: The toast

    /// Shows a toast; one that offers Undo goes when its host lets the design's files go.
    func showDesignToast(_ toast: DesignToast) {
        designToast = toast
        guard case .deleted(let deletion, let host) = toast.kind else { return }
        // A host's clock isn't this Mac's: its deletion was answered just now, so its window runs
        // from here.
        let seconds = host == nil ? max(0, deletion.undoUntil / 1000 - Date().timeIntervalSince1970) : DesignDeletion.undoWindow
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.designToast?.id == toast.id { self?.designToast = nil }
        }
    }

    /// The toast's button: Undo, or Try again.
    func performDesignToast(_ toast: DesignToast) {
        designToast = nil
        switch toast.kind {
        case .deleted(let deletion, let host):
            Task {
                do {
                    if let host {
                        guard let library = remoteHosts.connections.first(where: { $0.id == host })?.designs else {
                            throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
                        }
                        _ = try await Self.remoteDesign(library, .undoDelete(designID: deletion.designID))
                    } else {
                        try await server.undoDesignDeletion(deletion.designID)
                        let restored = server.state
                        sessions.stateDidChange(restored)
                        adopt(restored)
                        // Its agent comes back as it was: running, its pi resuming its session.
                        let agents = restored.agents.filter { $0.designID == deletion.designID }.map(\.id)
                        sessions.startRestoredAgents(agents, first: [], in: restored)
                    }
                } catch {
                    remoteActionError = "Couldn't bring back \(toast.name): \(Self.words(error))."
                }
            }
        case .designFailed(let id, let host):
            let target: DesignTarget = host.map { .remote(RemoteDesignRef(hostID: $0, designID: id)) } ?? .local(id)
            Task { await deleteDesign(target, name: toast.name) }
        case .systemFailed(let target):
            Task { await deleteDesignSystem(target, name: toast.name) }
        }
    }

    // MARK: Delete a design system

    /// Whether a system is still being built: its build's agent is at work.
    func systemIsBuilding(_ namespace: String) -> Bool {
        guard let owner = designSystems.summary(namespace)?.info.ownerDesignID, let build = design(owner), build.buildsSystem else {
            return false
        }
        let agent = state.agents.first { $0.id == build.agentID } ?? state.agents.first { $0.designID == owner }
        return agent?.status == .working
    }

    /// Delete design system…: the dialog, with how many designs use it (they keep their copy) and
    /// the repo it came from (never touched). A built-in is never deleted.
    func requestDesignSystemDelete(_ target: DesignSystemTarget) {
        switch target {
        case .build(let id):
            guard let build = design(id) else { return }
            let repo = build.sourceSpaceID.flatMap { id in state.spaces.first { $0.id == id }?.name }
            designSystemDeleteRequest = DesignSystemDeleteRequest(
                target: target, name: build.name, words: DeleteSystemWords(name: build.name, components: 0, usedBy: [], repo: repo, building: true))
        case .system(let namespace):
            guard let summary = designSystems.summary(namespace), !summary.builtIn else { return }
            let usedBy = state.designs.filter { !$0.buildsSystem && $0.systemNamespace == namespace }.map(\.name)
            let repo = summary.info.spaceID.flatMap { id in state.spaces.first { $0.id == id }?.name }
            let words = DeleteSystemWords(name: summary.info.title, components: summary.counts.components, usedBy: usedBy, repo: repo,
                                          building: systemIsBuilding(namespace))
            designSystemDeleteRequest = DesignSystemDeleteRequest(target: target, name: summary.info.title, words: words)
        }
    }

    func confirmDesignSystemDelete(_ request: DesignSystemDeleteRequest) {
        designSystemDeleteRequest = nil
        Task { await deleteDesignSystem(request.target, name: request.name) }
    }

    /// Deletes a design system (and stops its build): its page, if shown, goes back to Designs.
    /// A failure keeps it, and the toast names why, with Try again.
    func deleteDesignSystem(_ target: DesignSystemTarget, name: String) async {
        designToast = nil
        let shown: Bool = switch target {
        case .system(let namespace): shownDestination == .designSystem && designSystemShown == namespace
            || designSystems.summary(namespace)?.info.ownerDesignID.map { shownDesign?.id == $0 } == true
        case .build(let id): shownDesign?.id == id
        }
        if shown { openDestination(.designs) }
        do {
            switch target {
            case .system(let namespace): try await server.deleteDesignSystem(namespace)
            case .build(let id): try await server.deleteSystemBuild(id)
            }
            sessions.stateDidChange(server.state)
            adopt(server.state)
            if lastDesignSystem == target { lastDesignSystem = nil }
            await loadDesignSystems()
        } catch {
            showDesignToast(DesignToast(kind: .systemFailed(target), name: name, reason: Self.words(error)))
        }
    }

    // MARK: Import

    /// File ▸ Import Claude Design Project…, New design's Import a project: a picker that takes a
    /// .zip or a folder.
    func chooseDesignProject() {
        guard designToolEnabled else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Import"
        panel.message = "A Claude Design project you exported: a ZIP, or its folder."
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.importDesignProject(url)
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Imports a Claude Design project (a ZIP or a folder): Designs shows its card filling as its
    /// boards land; a failure says why and leaves nothing; boards that can't be read, or the same
    /// project already in Designs, ask first. A complete design opens and its agent reads it.
    func importDesignProject(_ url: URL) {
        guard designToolEnabled else { return }
        guard designImporting == nil else { NSSound.beep(); return }
        designImporting = DesignImporting(file: url.lastPathComponent)
        if shownDestination != .designs { openDestination(.designs) }
        Task {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let preview = try await server.prepareDesignImport(from: url) { [weak self] step in
                    Task { @MainActor in self?.designImporting?.apply(step) }
                }
                if !preview.unreadable.isEmpty {
                    stagedDesignImport = preview.id
                    designImportPrompt = .unreadable(preview)
                } else if let existing = state.designs.first(where: { $0.importedFrom.map(preview.origin.isSameProject) == true }) {
                    stagedDesignImport = preview.id
                    designImportPrompt = .again(preview, existing: existing,
                                                copyName: DesignNaming.importName(preview.title, taken: state.designs.map(\.name)))
                } else {
                    await finishDesignImport(preview)
                    return
                }
            } catch let failure as DesignImportFailure {
                designImporting = nil
                designImportPrompt = .failed(file: url.lastPathComponent, failure)
            } catch {
                designImporting = nil
                designImportPrompt = .failed(file: url.lastPathComponent, .refused("\(error)"))
            }
        }
    }

    /// The import's own ending: the design recorded, opened, and its agent started on the brief
    /// that has it read the design and change nothing.
    func finishDesignImport(_ preview: DesignImportPreview, name: String? = nil, skippingUnreadable: Bool = false) async {
        designImporting?.apply(.opening(title: name ?? preview.title))
        do {
            let design = try await server.finishDesignImport(preview, name: name, skippingUnreadable: skippingUnreadable)
            designImporting = nil
            adopt(server.state)
            designsPageSelection = design.id
            await loadDesignSystems()
            _ = try await startDesignAgent(design, brief: DesignImportBrief.text(file: preview.file), images: [])
        } catch let failure as DesignImportFailure {
            designImporting = nil
            await server.cancelDesignImport(preview.id)
            designImportPrompt = .failed(file: preview.file, failure)
        } catch {
            designImporting = nil
            await server.cancelDesignImport(preview.id)
            remoteActionError = "Couldn't open \(preview.title): \(error)"
        }
    }

    /// The import's dialog went away without an answer (Escape): the staged project goes.
    func designImportPromptDismissed() {
        guard let staged = stagedDesignImport else { return }
        stagedDesignImport = nil
        designImporting = nil
        Task { await server.cancelDesignImport(staged) }
    }

    /// Cancel import, OK, or a dialog closed: nothing was imported.
    func cancelDesignImport(_ prompt: DesignImportPrompt) {
        stagedDesignImport = nil
        designImportPrompt = nil
        designImporting = nil
        switch prompt {
        case .unreadable(let preview), .again(let preview, _, _):
            Task { await server.cancelDesignImport(preview.id) }
        case .failed:
            break
        }
    }

    /// Import the other 11 (unreadable boards left out on purpose), Import as a copy, or Open the
    /// one I have.
    func resolveDesignImport(_ prompt: DesignImportPrompt, openExisting: Bool = false) {
        stagedDesignImport = nil
        designImportPrompt = nil
        switch prompt {
        case .unreadable(let preview):
            // The same project already in Designs still comes in as a copy under the next number.
            let again = state.designs.contains { $0.importedFrom.map(preview.origin.isSameProject) == true }
            let name = again ? DesignNaming.importName(preview.title, taken: state.designs.map(\.name)) : nil
            Task { await finishDesignImport(preview, name: name, skippingUnreadable: true) }
        case .again(let preview, let existing, let copyName):
            if openExisting {
                designImporting = nil
                Task { await server.cancelDesignImport(preview.id) }
                openDesign(existing.id)
            } else {
                Task { await finishDesignImport(preview, name: copyName) }
            }
        case .failed:
            designImporting = nil
            chooseDesignProject()
        }
    }

    /// An error as a sentence's end.
    static func words(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }
}
