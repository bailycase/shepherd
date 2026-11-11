import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import UniformTypeIdentifiers

// Deleting, renaming, duplicating and importing designs and design systems
// (DesignLifecycleStates). Delete asks first, then the design leaves every
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
        case remoteSystem(RemoteSystemRef)
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
            // Its own toolbar names what the canvas has selected, for Implement and Copy reference.
            let reference = context == .toolbar && settings.designToolEnabled
                ? designScreens[id].map { $0.referenceSelection(designName: design(id)?.name ?? "").piece } : nil
            return DesignMenu.design(context, hasSystem: design(id)?.systemNamespace != nil, reference: reference)
        case .remote(let ref):
            let connection = remoteHosts.allConnections.first { $0.id == ref.hostID }
            // References to the host's design go to the host's threads, where it takes them.
            let references = context == .toolbar && connection?.supportsDesignCapability(RemoteProtocol.designReferencesCapability) == true
            let name = connection?.state.designs.first { $0.id == ref.designID }?.name ?? ""
            let reference = references ? remoteDesignScreens[ref].map { $0.referenceSelection(designName: name).piece } : nil
            return DesignMenu.design(context, hasSystem: false, remote: connection?.config.name ?? "The host",
                                     hostDeletes: connection?.supportsDesignDelete == true,
                                     hostLifecycle: connection?.supportsDesignCapability(RemoteProtocol.designLifecycleCapability) == true,
                                     reference: reference)
        }
    }

    /// What a design's menu item does.
    func performDesignMenu(_ action: DesignMenuAction, on target: DesignTarget) {
        // As the background host's client its designs change on the host, as a paired Mac's do;
        // they open, show their system and hand off pieces here, as this app's own.
        if case .local(let id) = target, let ref = hostDesign(id),
           [.rename, .duplicate, .export, .removeFromRecents, .delete].contains(action) {
            return performDesignMenu(action, on: .remote(ref))
        }
        switch (action, target) {
        case (.open, .local(let id)): openDesign(id)
        case (.open, .remote(let ref)): openRemoteDesign(ref)
        case (.rename, _): requestDesignRename(target)
        case (.export, .local(let id)): openDesignExport(id)
        case (.export, .remote(let ref)): openRemoteDesignExport(ref)
        case (.duplicate, .remote(let ref)): duplicateRemoteDesign(ref)
        case (.removeFromRecents, .remote(let ref)): removeRemoteDesignFromRecents(ref)
        case (.showSystem, .local(let id)): if let system = design(id)?.systemNamespace { openDesignSystem(system) }
        case (.delete, _): requestDesignDelete(target)
        case (.implement, .remote(let ref)), (.copyReference, .remote(let ref)):
            let name = remoteHosts.allConnections.first { $0.id == ref.hostID }?.state.designs.first { $0.id == ref.designID }?.name ?? ""
            if action == .implement { remoteDesignScreen(ref)?.implementSelection(designName: name) }
            else { remoteDesignScreen(ref)?.copySelectionReference(designName: name) }
        case (.implement, .local(let id)):
            if let design = design(id) { designScreen(id).implementSelection(designName: design.name) }
        case (.copyReference, .local(let id)):
            if let design = design(id) { designScreen(id).copySelectionReference(designName: design.name) }
        default: break
        }
    }

    /// The background host's handle on one of the app's designs, while the app is its client.
    func hostDesign(_ id: DesignID) -> RemoteDesignRef? {
        guard let host = localHost else { return nil }
        return RemoteDesignRef(hostID: host.id, designID: id)
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
        case .remote(let ref):
            return remoteDesignSystemMenu(ref)
        case .remoteBuild(let ref):
            let connection = remoteHosts.allConnections.first { $0.id == ref.hostID }
            guard let connection, connection.supportsDesignCapability(RemoteProtocol.designSystemsCapability) else {
                return DesignMenu(sections: [[DesignMenuItem(action: .open, title: "Open", symbol: "arrow.up.forward.app")]])
            }
            let name = connection.state.designs.first { $0.id == ref.designID }?.name ?? "It"
            return DesignMenu.system(name: name, builtIn: false, repo: nil, building: true)
        }
    }

    /// A build's system, once its agent wrote one; the build itself before.
    func systemTarget(ofBuild id: DesignID) -> DesignSystemTarget {
        designSystems.summaries.first { $0.info.ownerDesignID == id }.map { .system($0.namespace) } ?? .build(id)
    }

    /// What a system's menu item does.
    func performDesignSystemMenu(_ action: DesignMenuAction, on target: DesignSystemTarget) {
        // As the background host's client its systems change on the host, as a paired Mac's do.
        if let host = localHost, [.resync, .rename, .duplicateSystem, .deleteSystem].contains(action) {
            switch target {
            case .system(let namespace): return performDesignSystemMenu(action, on: .remote(RemoteSystemRef(hostID: host.id, namespace: namespace)))
            case .build(let id) where action == .deleteSystem:
                return performDesignSystemMenu(action, on: .remoteBuild(RemoteDesignRef(hostID: host.id, designID: id)))
            default: break
            }
        }
        switch (action, target) {
        case (.open, .system(let namespace)): openDesignSystem(namespace)
        case (.open, .build(let id)): openSystemBuild(id)
        case (.rename, .system(let namespace)):
            designRename = DesignRenameRequest(subject: .system(namespace), name: designSystems.summary(namespace)?.info.title ?? namespace)
        case (.deleteSystem, _): requestDesignSystemDelete(target)
        case (_, .remote(let ref)): performRemoteDesignSystemMenu(action, on: ref)
        case (.open, .remoteBuild(let ref)): openRemoteSystemBuild(ref)
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
            guard let design = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.state.designs.first(where: { $0.id == ref.designID })
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
                case .design(.local), .system:
                    // The background host's are renamed through it (`performDesignMenu`).
                    throw BackgroundHostClient.HostStarting()
                case .design(.remote(let ref)):
                    guard let library = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.designs else { return }
                    _ = try await Self.remoteDesign(library, .updateIndex(designID: ref.designID, patch: .object(["title": .string(trimmed)]),
                                                                          baseRevision: nil))
                case .remoteSystem(let ref):
                    try await changeRemoteSystem(ref, .renameSystem(namespace: ref.namespace, title: trimmed))
                }
            } catch {
                remoteActionError = "Couldn't rename \(request.name): \(error)"
            }
        }
    }

    /// Duplicate of a host's design: the host's own, its copy listed with the host's designs.
    func duplicateRemoteDesign(_ ref: RemoteDesignRef) {
        guard let library = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.designs else { return }
        Task {
            do {
                _ = try await Self.remoteDesign(library, .duplicate(designID: ref.designID))
                await library.refresh()
            } catch {
                remoteActionError = "Couldn't duplicate the design: \(Self.words(error))."
            }
        }
    }

    /// Remove from Recents of a host's design, on its host: its row leaves Recents there and here.
    func removeRemoteDesignFromRecents(_ ref: RemoteDesignRef) {
        guard let library = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.designs else { return }
        Task {
            do {
                _ = try await Self.remoteDesign(library, .removeFromRecents(designID: ref.designID))
            } catch {
                remoteActionError = "Couldn't remove the design from Recents: \(Self.words(error))."
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
                let snapshot = try? await ownerDesignSnapshot(id)
                // The host's versions aren't read over the connection: the dialog leaves them out, as for a paired Mac.
                let versions: Int? = nil
                let comments = try? await ownerDesignComments(id).comments.count
                let agent = state.agents.first { $0.id == design.agentID } ?? state.agents.first { $0.designID == id }
                let working = agent?.status == .working
                let drawing = agent.flatMap { threadStores.existing(for: $0.id)?.messages }.map(designBoardsDrawing) ?? 0
                let words = DeleteDesignWords(name: design.name, boards: snapshot?.index.boards.count ?? design.boardCount ?? 0,
                                              versions: versions, comments: comments, system: design.systemNamespace,
                                              agentWorking: working, drawing: drawing)
                presentDesignDelete(DesignDeleteRequest(target: target, name: design.name, words: words))
            case .remote(let ref):
                guard let connection = remoteHosts.allConnections.first(where: { $0.id == ref.hostID }),
                      let design = connection.state.designs.first(where: { $0.id == ref.designID }) else { return }
                let summary = connection.designs.listing?.designs.first { $0.id == ref.designID }
                let agent = connection.state.agents.first { $0.id == design.agentID }
                let working = agent?.status == .working
                let drawing = agent.flatMap { remoteThreadStores.existing(for: RemoteAgentRef(hostID: ref.hostID, agentID: $0.id))?.messages }
                    .map(designBoardsDrawing) ?? 0
                let words = DeleteDesignWords(name: design.name, boards: summary?.boardCount ?? design.boardCount ?? 0, versions: nil,
                                              comments: summary?.openComments, system: design.systemNamespace, agentWorking: working,
                                              drawing: drawing)
                presentDesignDelete(DesignDeleteRequest(target: target, name: design.name, words: words))
            }
        }
    }

    /// The dialog, or its Delete at once after "Don't ask again".
    private func presentDesignDelete(_ request: DesignDeleteRequest) {
        if settings.skipped(.deleteDesign) != nil { confirmDesignDelete(request) } else { designDeleteRequest = request }
    }

    private func presentDesignSystemDelete(_ request: DesignSystemDeleteRequest) {
        if settings.skipped(.deleteDesignSystem) != nil { confirmDesignSystemDelete(request) } else { designSystemDeleteRequest = request }
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
            case .local:
                // The background host's are deleted through it (`performDesignMenu`).
                throw BackgroundHostClient.HostStarting()
            case .remote(let ref):
                guard let library = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.designs else {
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
                let hostName = remoteHosts.allConnections.first { $0.id == ref.hostID }?.config.name ?? "Its host"
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
        case .remote(let ref) where ref.hostID == localHost?.id: return shownDesign?.id == ref.designID
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
                    guard let host, let library = remoteHosts.allConnections.first(where: { $0.id == host })?.designs else {
                        throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
                    }
                    _ = try await Self.remoteDesign(library, .undoDelete(designID: deletion.designID))
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
            presentDesignSystemDelete(DesignSystemDeleteRequest(
                target: target, name: build.name, words: DeleteSystemWords(name: build.name, components: 0, usedBy: [], repo: repo, building: true)))
        case .system(let namespace):
            guard let summary = designSystems.summary(namespace), !summary.builtIn else { return }
            let usedBy = state.designs.filter { !$0.buildsSystem && $0.systemNamespace == namespace }.map(\.name)
            let repo = summary.info.spaceID.flatMap { id in state.spaces.first { $0.id == id }?.name }
            let words = DeleteSystemWords(name: summary.info.title, components: summary.counts.components, usedBy: usedBy, repo: repo,
                                          building: systemIsBuilding(namespace))
            presentDesignSystemDelete(DesignSystemDeleteRequest(target: target, name: summary.info.title, words: words))
        case .remoteBuild(let ref):
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == ref.hostID }),
                  let build = connection.state.designs.first(where: { $0.id == ref.designID && $0.buildsSystem }) else { return }
            let repo = build.sourceSpaceID.flatMap { id in connection.state.spaces.first { $0.id == id }?.name }
            presentDesignSystemDelete(DesignSystemDeleteRequest(
                target: target, name: build.name, words: DeleteSystemWords(name: build.name, components: 0, usedBy: [], repo: repo, building: true)))
        case .remote(let ref):
            guard let connection = remoteHosts.allConnections.first(where: { $0.id == ref.hostID }),
                  let summary = connection.designs.listing?.systems.first(where: { $0.namespace == ref.namespace }), !summary.builtIn else { return }
            let usedBy = connection.state.designs.filter { !$0.buildsSystem && $0.systemNamespace == ref.namespace }.map(\.name)
            let repo = summary.info.spaceID.flatMap { id in connection.state.spaces.first { $0.id == id }?.name }
            let words = DeleteSystemWords(name: summary.info.title, components: summary.counts.components, usedBy: usedBy, repo: repo,
                                          building: false)
            presentDesignSystemDelete(DesignSystemDeleteRequest(target: target, name: summary.info.title, words: words))
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
        case .remote(let ref): shownDestination == .designSystem && shownRemoteSystem == ref
        case .remoteBuild(let ref): selectedRemoteAgent.flatMap { selected in
            remoteHosts.allConnections.first { $0.id == ref.hostID }?.state.agents.first { $0.id == selected.agentID }?.designID
        } == ref.designID
        }
        if shown { openDestination(.designs) }
        do {
            switch target {
            case .system, .build:
                // The background host's are deleted through it (`performDesignSystemMenu`).
                throw BackgroundHostClient.HostStarting()
            case .remote(let ref):
                try await changeRemoteSystem(ref, .deleteSystem(namespace: ref.namespace))
                return
            case .remoteBuild(let ref):
                guard let library = remoteHosts.allConnections.first(where: { $0.id == ref.hostID })?.designs else {
                    throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
                }
                _ = try await Self.remoteDesign(library, .deleteSystemBuild(designID: ref.designID))
            }
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
                let preview = try await prepareDesignImport(url)
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

    /// The background host imports from the same disk (`importPrepare`), with the same choices.
    private func prepareDesignImport(_ url: URL) async throws -> DesignImportPreview {
        switch try await Self.remoteDesign(localDesigns, .importPrepare(path: url.path)) {
        case .importPrepared(let preview): return preview
        case .importFailed(let failure): throw failure
        default: throw RemoteDesignReply.unexpected
        }
    }

    private func discardDesignImport(_ id: UUID) async {
        _ = try? await Self.remoteDesign(localDesigns, .importDiscard(previewID: id))
    }

    /// The import's own ending: the design recorded, opened, and its agent started on the brief
    /// that has it read the design and change nothing.
    func finishDesignImport(_ preview: DesignImportPreview, name: String? = nil, skippingUnreadable: Bool = false) async {
        designImporting?.apply(.opening(title: name ?? preview.title))
        // The host makes it and starts its agent, as a design made on it does (`createDesign`).
        do {
            switch try await Self.remoteDesign(localDesigns, .importConfirm(preview: preview, name: name, skippingUnreadable: skippingUnreadable)) {
            case .created(let designID, let agentID):
                // ponytail: polls for the host's push, as `createDesign` does.
                for _ in 0..<100 where design(designID) == nil { try await Task.sleep(for: .milliseconds(20)) }
                designImporting = nil
                designsPageSelection = designID
                await loadDesignSystems()
                if let agentID { selectAgent(agentID) } else { openDesign(designID) }
            case .importFailed(let failure):
                designImporting = nil
                designImportPrompt = .failed(file: preview.file, failure)
            default:
                throw RemoteDesignReply.unexpected
            }
        } catch {
            designImporting = nil
            remoteActionError = "Couldn't open \(preview.title): \(Self.words(error))"
        }
    }

    /// The import's dialog went away without an answer (Escape): the staged project goes.
    func designImportPromptDismissed() {
        guard let staged = stagedDesignImport else { return }
        stagedDesignImport = nil
        designImporting = nil
        Task { await discardDesignImport(staged) }
    }

    /// Cancel import, OK, or a dialog closed: nothing was imported.
    func cancelDesignImport(_ prompt: DesignImportPrompt) {
        stagedDesignImport = nil
        designImportPrompt = nil
        designImporting = nil
        switch prompt {
        case .unreadable(let preview), .again(let preview, _, _):
            Task { await discardDesignImport(preview.id) }
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
                Task { await discardDesignImport(preview.id) }
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
