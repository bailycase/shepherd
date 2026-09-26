import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// A remote host's designs on this Mac (`designs.v1`, served while the host's Design tool is on):
// the Designs page lists them under the host's name, and opening one shows its canvas beside its
// agent's chat, the same screen as a local design's. The boards render here, from files fetched
// by hash; every change goes to the host, through its own mutations and checks.

/// A design on a remote host.
struct RemoteDesignRef: Hashable {
    var hostID: UUID
    var designID: DesignID
}

extension ShepherdViewModel {
    // MARK: Lookups

    /// The design a remote agent draws, while its host serves designs.
    func remoteDesign(drawnBy ref: RemoteAgentRef) -> (connection: RemoteHostStore.Connection, design: Design)? {
        guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }), connection.supportsDesigns,
              let agent = connection.state.agents.first(where: { $0.id == ref.agentID }), let id = agent.designID,
              let design = connection.state.designs.first(where: { $0.id == id }), !design.buildsSystem else { return nil }
        return (connection, design)
    }

    /// A host's design renderers, sharing this Mac's rasterizer.
    func remoteDesignRendering(_ hostID: UUID) -> DesignRendering? {
        if let rendering = remoteDesignRenderings[hostID] { return rendering }
        guard let connection = remoteHosts.connections.first(where: { $0.id == hostID }) else { return nil }
        let library = connection.designs
        let rendering = DesignRendering(remote: { [weak library] id in
            MainActor.assumeIsolated { library?.source(id) }
        }, network: designNetwork, liveCap: designLiveCap, rasterizer: designRendering.rasterizer)
        remoteDesignRenderings[hostID] = rendering
        return rendering
    }

    // MARK: Opening

    /// A host's design card: its agent's layout on that host, which draws as the design's screen.
    /// A design whose agent is gone there says so: only its host starts a fresh one.
    func openRemoteDesign(_ ref: RemoteDesignRef) {
        guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }),
              let design = connection.state.designs.first(where: { $0.id == ref.designID }) else { return }
        let agent = connection.state.agents.first { $0.id == design.agentID } ?? connection.state.agents.first { $0.designID == ref.designID }
        guard let agent else {
            remoteActionError = "\(design.name) has no design agent on \(connection.config.name). Open it there to start one."
            return
        }
        selectRemoteAgent(hostID: ref.hostID, agentID: agent.id)
    }

    // MARK: Screens

    /// The canvas of a remote design, made the first time it is shown: its files synced from the
    /// host by hash, its writes and comments sent to the host.
    func remoteDesignScreen(_ ref: RemoteDesignRef) -> DesignScreenModel? {
        if let screen = remoteDesignScreens[ref] { return screen }
        guard let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }),
              let rendering = remoteDesignRendering(ref.hostID) else { return nil }
        let library = connection.designs
        let source = library.source(ref.designID)
        let id = ref.designID
        let snapshot: DesignScreenModel.Snapshot = { _ in try await source.sync().snapshot }
        let tweak = DesignTweakIO(
            snapshot: { try await source.sync().snapshot },
            board: { path in
                let text = try await source.source(path)
                let index = source.index
                return DesignBoardSource(path: path, source: text, sha256: index?.snapshot.boards[path] ?? "",
                                         revision: index?.snapshot.revision ?? 0)
            },
            writeBoards: { sources, base in
                let raw = Dictionary(uniqueKeysWithValues: sources.map { ($0.key.rawValue, $0.value) })
                guard case .boardsWritten(let write) = try await Self.remoteDesign(library, .writeBoards(designID: id, sources: raw, baseRevision: base)) else {
                    throw RemoteDesignReply.unexpected
                }
                return write.write
            },
            updateIndex: { patch, base in try await Self.remoteIndexUpdate(library, id, patch, base) },
            restore: { versions, current in
                let raw = Dictionary(uniqueKeysWithValues: versions.map { ($0.key.rawValue, $0.value) })
                let ifCurrent = current.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.rawValue, $0.value) }) }
                guard case .boardsWritten(let write) = try await Self.remoteDesign(library, .restoreVersions(designID: id, versions: raw,
                                                                                                             ifCurrent: ifCurrent)) else {
                    throw RemoteDesignReply.unexpected
                }
                return write.write
            },
            // The project's stylesheets are on the host: Tweak snaps to the board's own tokens.
            projectTokens: { DesignTokens() })
        let agentRef = connection.state.designs.first { $0.id == id }?.agentID.map { RemoteAgentRef(hostID: ref.hostID, agentID: $0) }
        let screen = DesignScreenModel(designID: id, host: rendering.host(for: id), snapshot: snapshot,
                                       source: { _, path in try await source.source(path) },
                                       comments: remoteDesignCommentActions(library), tweak: tweak,
                                       actions: remoteDesignCanvasActions(library, agent: agentRef))
        if let design = connection.state.designs.first(where: { $0.id == id }) {
            screen.tweak?.systemName = design.systemNamespace ?? connection.state.spaces.first { $0.id == design.spaceID }?.name ?? "design"
        }
        remoteDesignScreens[ref] = screen
        return screen
    }

    /// Duplicate and moves through the host, and messages to its design agent over the native
    /// thread, the view record riding the send where the host takes one.
    private func remoteDesignCanvasActions(_ library: RemoteDesignLibrary, agent: RemoteAgentRef?) -> DesignCanvasActions {
        DesignCanvasActions(
            snapshot: { id in try await library.source(id).sync().snapshot },
            duplicate: { id, path, base in
                guard case .duplicated(let path, let result) = try await Self.remoteDesign(library, .duplicateBoard(designID: id, path: path.rawValue,
                                                                                                                    baseRevision: base)) else {
                    throw RemoteDesignReply.unexpected
                }
                return DesignDuplicate(path: path, result: result)
            },
            updateIndex: { id, patch, base in try await Self.remoteIndexUpdate(library, id, patch, base) },
            ask: { [weak self] _, text, record in
                guard let self, let agent, self.remoteHosts.connections.first(where: { $0.id == agent.hostID })?
                    .state.agents.contains(where: { $0.id == agent.agentID }) == true else { return false }
                await self.remoteThreadStores.store(for: agent).send(text: text, designContext: record)
                return true
            },
            report: { [weak self] in self?.remoteActionError = $0 })
    }

    /// Comments through the host: pinned, answered and resolved there, handed to its design agent
    /// fenced as data. A change based on comments that moved on is read again and goes once more.
    private func remoteDesignCommentActions(_ library: RemoteDesignLibrary) -> DesignCommentActions {
        func list(_ id: DesignID) async throws -> DesignComments {
            guard case .comments(let comments) = try await Self.remoteDesign(library, .comments(designID: id)) else { throw RemoteDesignReply.unexpected }
            return comments
        }
        func again(_ id: DesignID, _ base: UInt64?, _ body: (UInt64?) -> RemoteDesignRequest) async throws -> (DesignComment, String?) {
            let result: RemoteDesignResult
            do {
                result = try await Self.remoteDesign(library, body(base))
            } catch DesignStoreError.stale {
                result = try await Self.remoteDesign(library, body(try await list(id).revision))
            }
            guard case .comment(let comment, let undelivered) = result else { throw RemoteDesignReply.unexpected }
            return (comment, undelivered)
        }
        return DesignCommentActions(
            list: { try await list($0) },
            add: { id, draft, base in try await again(id, base) { .addComment(designID: id, draft: draft, baseRevision: $0) } },
            reply: { id, comment, text, base in
                try await again(id, base) { .replyToComment(designID: id, commentID: comment, text: text, baseRevision: $0) }
            },
            resolve: { id, comment, base in
                try await again(id, base) { .resolveComment(designID: id, commentID: comment, resolved: true, baseRevision: $0) }.0
            },
            report: { [weak self] in self?.remoteActionError = $0 })
    }

    private static func remoteIndexUpdate(_ library: RemoteDesignLibrary, _ id: DesignID, _ patch: JSONValue,
                                          _ base: UInt64?) async throws -> DesignWriteResult {
        guard case .written(let result) = try await remoteDesign(library, .updateIndex(designID: id, patch: patch, baseRevision: base)) else {
            throw RemoteDesignReply.unexpected
        }
        return result
    }

    /// A design request to the host, a stale revision read as the local store's (so the canvas
    /// reads the design again and redoes the change once, as it does here).
    static func remoteDesign(_ library: RemoteDesignLibrary, _ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        do {
            return try await library.request(request)
        } catch RemoteHostClientError.rejected(let code, _) where code == DesignStoreError.stale(base: 0, current: 0).code {
            throw DesignStoreError.stale(base: 0, current: 0)
        }
    }

    /// A remote design's layout came on screen or left it: only designs on screen take live
    /// views, and their hosts push changes for them alone.
    func remoteDesignVisibility(_ ref: RemoteDesignRef, visible: Bool) {
        remoteDesignScreen(ref)?.setActive(visible)
        let changed = visible ? visibleRemoteDesigns.insert(ref).inserted : visibleRemoteDesigns.remove(ref) != nil
        guard changed, let connection = remoteHosts.connections.first(where: { $0.id == ref.hostID }) else { return }
        connection.designs.watch(Set(visibleRemoteDesigns.filter { $0.hostID == ref.hostID }.map(\.designID)))
    }

    /// A host pushed a change to a design on screen: its canvas pulls what changed.
    func remoteDesignChanged(_ ref: RemoteDesignRef, revision: UInt64?, comments: UInt64?) {
        guard let screen = remoteDesignScreens[ref] else { return }
        Task {
            if revision == nil, comments != nil { await screen.refreshComments() } else { await screen.refresh() }
        }
    }

    /// Designs gone from their hosts (or hosts removed) give up their canvases and renderers.
    func pruneRemoteDesigns() {
        let live = Set(remoteHosts.connections.flatMap { connection in
            connection.state.designs.map { RemoteDesignRef(hostID: connection.id, designID: $0.id) }
        })
        for ref in Set(remoteDesignScreens.keys).subtracting(live) {
            remoteDesignScreens.removeValue(forKey: ref)?.setActive(false)
            visibleRemoteDesigns.remove(ref)
        }
        let hosts = Set(remoteHosts.connections.map(\.id))
        for host in Set(remoteDesignRenderings.keys) {
            guard hosts.contains(host) else {
                remoteDesignRenderings.removeValue(forKey: host)?.prune(keeping: [])
                continue
            }
            remoteDesignRenderings[host]?.prune(keeping: Set(live.filter { $0.hostID == host }.map(\.designID)))
        }
    }

    // MARK: The Designs page

    /// Changes whenever a host's designs may have: the page lists them again then.
    var remoteDesignsSignature: [String] {
        remoteHosts.connections.filter(\.supportsDesigns).map { connection in
            connection.id.uuidString + ":" + connection.state.designs.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)" }
                .joined(separator: ",")
        }
    }

    /// Lists each host's designs again and reads their first boards for the cards.
    func loadRemoteDesigns() async {
        for connection in remoteHosts.connections where connection.supportsDesigns {
            await connection.designs.refresh()
            guard let listing = connection.designs.listing, let rendering = remoteDesignRendering(connection.id) else { continue }
            for summary in listing.designs {
                guard let first = summary.firstBoard else { continue }
                // The card needs the first board alone; its files come from the host as it draws.
                let index = DesignIndex(title: summary.design.name,
                                        boards: [first.path: DesignIndex.Board(x: 0, y: 0, w: first.width, h: first.height)],
                                        order: [first.path])
                rendering.thumbnails.update(summary.id, snapshot: DesignSnapshot(designID: summary.id, revision: summary.revision,
                                                                                 index: index, boards: [first.path: first.sha256]))
            }
        }
    }

    /// Each host that serves designs, as the Designs page lists it under its name.
    var remoteDesignSections: [DesignsPageModel.HostSection] {
        let now = Date()
        return remoteHosts.connections.filter(\.supportsDesigns).compactMap { connection in
            guard let listing = connection.designs.listing, !listing.designs.isEmpty else { return nil }
            let thumbnails = remoteDesignRenderings[connection.id]?.thumbnails
            let spaces = Dictionary(connection.state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let query = designsPageFilter.trimmingCharacters(in: .whitespacesAndNewlines)
            let cards = listing.designs.compactMap { summary -> DesignsPageModel.Card? in
                let design = summary.design
                let system = design.systemNamespace ?? spaces[design.spaceID]
                guard query.isEmpty || design.name.localizedCaseInsensitiveContains(query)
                        || system?.localizedCaseInsensitiveContains(query) == true else { return nil }
                let entry = thumbnails?.entries[summary.id]
                return DesignsPageModel.Card(
                    id: design.id, name: design.name, system: system, detail: DesignsPageModel.boardsText(summary.boardCount),
                    edited: "edited \(SuggestionsPresentation.when(design.lastActiveAt / 1000, now: now))",
                    board: NWDesignCardBoard(size: summary.firstBoard.map { CGSize(width: $0.width, height: $0.height) }),
                    thumbnail: entry?.version ?? 0, selected: false)
            }
            guard !cards.isEmpty else { return nil }
            return DesignsPageModel.HostSection(id: connection.id, name: connection.config.name, cards: cards)
        }
    }
}

/// A reply of a kind the request never gets.
enum RemoteDesignReply {
    static let unexpected = RemoteHostClientError.rejected(code: "protocol", message: "unexpected design reply")
}

// MARK: - The screen

/// A remote design's screen (DZCanvas): the canvas beside the 420pt chat pane holding its agent's
/// thread on the host, as a local design's is. The boards render on this Mac from the files the
/// host served; hidden, the canvas gives up its live views and the host stops pushing changes.
struct RemoteDesignLayoutView: View {
    var vm: ShepherdViewModel
    let ref: RemoteDesignRef
    let agent: RemoteAgentRef
    let agentName: String
    let threadPaneID: PaneID?

    var body: some View {
        let _ = NWRenderProbe.tick("layout.design")
        HStack(spacing: 0) {
            if let screen = vm.remoteDesignScreen(ref) {
                DesignCanvasPane(screen: screen)
                RemoteDesignChatPane(vm: vm, screen: screen, agent: agent, agentName: agentName, threadPaneID: threadPaneID)
                    .frame(width: AppLayout.designChatWidth)
            }
        }
        .onAppear { [vm] in
            vm.remoteDesignVisibility(ref, visible: true)
            // The chat's messages carry what the canvas shows as they leave.
            let screen = vm.remoteDesignScreen(ref)
            vm.remoteThreadStores.store(for: agent).designContext = { [weak screen] in screen?.viewRecord }
        }
        .onDisappear { vm.remoteDesignVisibility(ref, visible: false) }
    }
}

/// The chat pane of a remote design: Chat (its agent's thread on the host, whose composer has
/// attach and Send only), Comments, and Tweak, as a local design's. The thread stays mounted
/// under the other tabs.
struct RemoteDesignChatPane: View {
    var vm: ShepherdViewModel
    @Bindable var screen: DesignScreenModel
    let agent: RemoteAgentRef
    let agentName: String
    let threadPaneID: PaneID?

    var body: some View {
        let open = screen.openComments.count
        let tab = screen.paneTab == .tweak && screen.tweak == nil ? .chat : screen.paneTab
        let chat = tab == .chat
        VStack(spacing: 0) {
            NWDesignPaneTabs(DesignChatPane.tabs(open: open, tweak: screen.tweak != nil), selection: tab.rawValue) { id in
                screen.paneTab = DesignPaneTab(rawValue: id) ?? .chat
            }
            ZStack {
                RemoteAgentThreadPane(vm: vm, ref: agent, agentName: agentName,
                                      isFocused: chat && vm.remoteFocusedPaneID == threadPaneID, designChat: true)
                    .environment(\.designCommentCards, screen.commentCards)
                    .opacity(chat ? 1 : 0)
                    .allowsHitTesting(chat)
                    .accessibilityHidden(!chat)
                if tab == .comments {
                    DesignCommentsList(cards: screen.openCards) { screen.openThread($0.uuidString) }
                        .background(Color.nw.bgWindow)
                }
                if let tweak = screen.tweak, tab == .tweak {
                    DesignTweakPane(model: tweak, target: screen.tweakTarget) { [vm] in
                        screen.paneTab = .chat
                        vm.remoteFocusedPaneID = threadPaneID
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical) }
        .simultaneousGesture(TapGesture().onEnded { [vm] in if screen.paneTab == .chat { vm.remoteFocusedPaneID = threadPaneID } })
    }
}
