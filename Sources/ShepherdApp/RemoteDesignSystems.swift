import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A connected host's design systems on this Mac (`designs.v1`, changed with `design.systems.v1`):
// listed under the host on the Designs page, each opening the Design systems page drawn from the
// host's read, its specimens rendered here from its files. Rename, Duplicate, Delete and Re-sync
// go to the host; nothing is kept on this Mac.

extension ShepherdViewModel {
    /// The Design systems page for a host's system; its files are read from the host.
    func openRemoteDesignSystem(_ ref: RemoteSystemRef) {
        guard designToolEnabled else { return }
        if shownRemoteSystem != ref {
            shownRemoteSystem = ref
            shownRemoteSystemRead = nil
        }
        openDestination(.designSystem)
    }

    /// Reads the shown host system (again after its host said its systems changed) and draws its
    /// specimens from its files where the host serves them.
    func loadRemoteDesignSystem(_ ref: RemoteSystemRef) async {
        guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }) else { return }
        let library = connection.designs
        do {
            let read = try await library.system(ref.namespace)
            guard shownRemoteSystem == ref else { return }
            if shownRemoteSystemRead != read { shownRemoteSystemRead = read }
            guard connection.supportsDesignCapability(RemoteProtocol.designSystemsCapability),
                  let specimens = remoteDesignRendering(ref.hostID)?.specimens else { return }
            let revision = "\(read.summary.info.revision)/\(read.summary.builtIn)"
            guard !specimens.has(ref.namespace, revision: revision) else { return }
            let files = try await library.systemFiles(ref.namespace)
            let tokens = read.tokens
            specimens.update(ref.namespace, revision: revision, files: files,
                             boards: DesignSpecimenBoard.boards(tokens, files: files, background: DesignSystemPresentation.background(tokens)?.light))
        } catch {
            if shownRemoteSystem == ref, shownRemoteSystemRead == nil { remoteActionError = "Couldn't read \(ref.namespace): \(Self.words(error))." }
        }
    }

    /// The page of a host's system, from its read and the host's designs drawn in it.
    func remoteDesignSystemPage(_ ref: RemoteSystemRef) -> DesignSystemPageModel {
        let connection = remoteHosts.connections.first { $0.id == ref.hostID }
        let read = shownRemoteSystem == ref ? shownRemoteSystemRead : nil
        let summary = read?.summary ?? connection?.designs.listing?.systems.first { $0.namespace == ref.namespace }
        guard let summary else { return DesignSystemPageModel() }
        return DesignSystemPageModel.make(summary: summary, read: read, build: nil, spaces: connection?.state.spaces ?? [],
                                          designs: connection?.state.designs.filter { $0.systemNamespace == ref.namespace } ?? [],
                                          syncing: false, now: Date())
    }

    /// A host system's menu: what its host does for other devices, else Open alone.
    func remoteDesignSystemMenu(_ ref: RemoteSystemRef) -> DesignMenu {
        let connection = remoteHosts.connections.first { $0.id == ref.hostID }
        let summary = connection?.designs.listing?.systems.first { $0.namespace == ref.namespace }
        guard let connection, connection.supportsDesignCapability(RemoteProtocol.designSystemsCapability) else {
            return DesignMenu(sections: [[DesignMenuItem(action: .open, title: "Open", symbol: "arrow.up.forward.app")]])
        }
        let repo = summary?.info.spaceID.flatMap { id in connection.state.spaces.first { $0.id == id }?.name }
        let resyncs = repo != nil && summary?.info.sources.isEmpty == false
        return DesignMenu.system(name: summary?.info.title ?? ref.namespace, builtIn: summary?.builtIn == true,
                                 repo: resyncs ? repo : nil, building: false)
    }

    func performRemoteDesignSystemMenu(_ action: DesignMenuAction, on ref: RemoteSystemRef) {
        switch action {
        case .open: openRemoteDesignSystem(ref)
        case .rename:
            let title = remoteHosts.connections.first { $0.id == ref.hostID }?.designs.listing?.systems
                .first { $0.namespace == ref.namespace }?.info.title ?? ref.namespace
            designRename = DesignRenameRequest(subject: .remoteSystem(ref), name: title)
        case .resync, .duplicateSystem:
            Task {
                do {
                    if action == .resync {
                        try await changeRemoteSystem(ref, .resyncSystem(namespace: ref.namespace))
                    } else if let copy = try await changeRemoteSystem(ref, .duplicateSystem(namespace: ref.namespace)) {
                        openRemoteDesignSystem(RemoteSystemRef(hostID: ref.hostID, namespace: copy.namespace))
                    }
                } catch {
                    remoteActionError = "Couldn't change \(ref.namespace): \(Self.words(error))."
                }
            }
        default: break
        }
    }

    /// A host's "Build one from a repo" in one of its spaces (`buildSystem`): the host starts the
    /// build, and its agent's thread there opens here as it reads the space.
    func buildRemoteSystem(host hostID: UUID, in spaceID: SpaceID) {
        guard let library = remoteHosts.connections.first(where: { $0.id == hostID })?.designs else { return }
        Task {
            do {
                guard case .created(let build, let agent) = try await Self.remoteDesign(library, .buildSystem(spaceID: spaceID)) else {
                    throw RemoteDesignReply.unexpected
                }
                if let agent { selectRemoteAgent(hostID: hostID, agentID: agent) } else { openRemoteSystemBuild(RemoteDesignRef(hostID: hostID, designID: build)) }
            } catch {
                remoteActionError = "Couldn't build a design system there: \(Self.words(error))."
            }
        }
    }

    /// A host's build still reading its space: its agent's thread on the host.
    func openRemoteSystemBuild(_ ref: RemoteDesignRef) {
        guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }),
              let build = connection.state.designs.first(where: { $0.id == ref.designID }) else { return }
        let agent = connection.state.agents.first { $0.id == build.agentID } ?? connection.state.agents.first { $0.designID == build.id }
        guard let agent else {
            remoteActionError = "\(build.name)'s build has no agent on \(connection.config.name). Open it there to start one."
            return
        }
        selectRemoteAgent(hostID: ref.hostID, agentID: agent.id)
    }

    /// A change to a host's system; the host's systems are read again after it. Answers the
    /// system it left (a copy, a rename), if one.
    @discardableResult
    func changeRemoteSystem(_ ref: RemoteSystemRef, _ request: RemoteDesignRequest) async throws -> DesignSystemSummary? {
        guard let library = remoteHosts.connections.first(where: { $0.id == ref.hostID })?.designs else {
            throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
        }
        let result = try await Self.remoteDesign(library, request)
        library.systemsChanged()
        if shownRemoteSystem == ref { await loadRemoteDesignSystem(ref) }
        switch result {
        case .systemChanged(let summary): return summary
        case .systemSynced(let synced): return synced.summary
        default: return nil
        }
    }
}

/// The Design systems page for a host's system: its header (with the host's menu) and content,
/// the specimens drawn by this Mac's renderer for that host.
struct RemoteDesignSystemDestination: View {
    var vm: ShepherdViewModel
    let ref: RemoteSystemRef
    var chrome = PageHeaderChrome()

    var body: some View {
        let model = vm.remoteDesignSystemPage(ref)
        let revision = vm.remoteHosts.connections.first { $0.id == ref.hostID }?.designs.systemsRevision ?? 0
        let target = DesignSystemTarget.remote(ref)
        VStack(spacing: 0) {
            DesignSystemHeader(model: model, toolbar: false, leadingInset: chrome.leadingInset, showSidebar: chrome.showSidebar,
                               designs: { vm.openDestination(.designs) }, menu: vm.designSystemMenu(target),
                               perform: { vm.performDesignSystemMenu($0, on: target) })
                .equatable()
            if let specimens = vm.remoteDesignRendering(ref.hostID)?.specimens {
                DesignSystemContent(model: model, specimens: specimens,
                                    resync: { _ in vm.performDesignSystemMenu(.resync, on: target) },
                                    openDesign: { vm.openRemoteDesign(RemoteDesignRef(hostID: ref.hostID, designID: $0)) })
                    .equatable()
            }
        }
        .background(Color.sh.bgWindow)
        .task(id: "\(ref.hostID)/\(ref.namespace)/\(revision)") { await vm.loadRemoteDesignSystem(ref) }
    }
}
