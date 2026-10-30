import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import SwiftUI

/// Recognizes bounded thread-ID payloads, not file paths or ordinary dropped text.
struct ThreadMoveDrag: Codable, Equatable {
    let agentID: AgentID
    let hostID: UUID?

    init?(_ row: SidebarRowID) {
        switch row {
        case .local(let id): agentID = id; hostID = nil
        case .remote(let ref): agentID = ref.agentID; hostID = ref.hostID
        case .design, .remoteDesign: return nil
        }
    }

    var text: String? {
        (try? JSONEncoder().encode(self)).map { "shepherd-thread:" + String(decoding: $0, as: UTF8.self) }
    }

    static func parse(_ text: String) -> Self? {
        guard text.utf8.count <= 1024, text.hasPrefix("shepherd-thread:") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: Data(text.dropFirst("shepherd-thread:".count).utf8))
    }

    var row: SidebarRowID { hostID.map { .remote(RemoteAgentRef(hostID: $0, agentID: agentID)) } ?? .local(agentID) }
}

@MainActor extension ShepherdViewModel {
    func moveThread(_ agentID: AgentID, to spaceID: SpaceID) async throws {
        let before = server.state
        let sessionID = before.agents.first { $0.id == agentID }.flatMap { agent in
            before.tabs.first { $0.id == agent.tabID }?.layout.leaf(withID: agent.paneID ?? PaneID())?.sessionID
        }
        let wasAlive = if let sessionID { await server.sessionInfo(sessionID: sessionID)?.isAlive == true } else { false }
        do {
            guard try await server.moveThread(agentID, to: spaceID) else { return }
        } catch {
            // A filesystem failure after shutdown leaves the original workspace intact.
            let code = (error as? ProjectFileError)?.code
            if wasAlive, code != "thread_active", code != "thread_moving" {
                sessions.stateDidChange(server.state)
                sessions.retryStart(agentID)
            }
            throw error
        }
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
        threadStores.store(for: agentID).restarting()
        sessions.retryStart(agentID)
        openProjectHoldingSelection()
    }

    func threadMoveSpaces(_ row: SidebarRowID) -> [Space] {
        switch row {
        case .local: state.spaces.filter { !$0.hidden }
        case .remote(let ref): remoteHosts.connections.first { $0.id == ref.hostID }?.state.spaces.filter { !$0.hidden } ?? []
        case .design, .remoteDesign: []
        }
    }

    func requestThreadMove(_ row: SidebarRowID, to space: SpaceID) {
        Task { @MainActor in
            do {
                switch row {
                case .local(let id): try await moveThread(id, to: space)
                case .remote(let ref): try await remoteHosts.agentAction(ref, action: .move(spaceID: space))
                case .design, .remoteDesign: return
                }
            } catch { fail("Couldn’t move the thread", error) }
        }
    }

    /// Source and destination must share an owner, including a merged local/remote space row.
    @discardableResult func dropThread(_ payloads: [String], on projectID: SidebarProjectID) -> Bool {
        guard payloads.count == 1, let drag = ThreadMoveDrag.parse(payloads[0]),
              let project = sidebarTree.projects.first(where: { $0.id == projectID }),
              let space = project.places[drag.hostID],
              threadMoveSpaces(drag.row).contains(where: { $0.id == space }) else { return false }
        requestThreadMove(drag.row, to: space)
        return true
    }
}

extension View {
    @ViewBuilder func threadDraggable(_ row: SidebarRowID) -> some View {
        if let text = ThreadMoveDrag(row)?.text { self.draggable(text) } else { self }
    }
}

struct ThreadMoveMenu: View {
    let vm: ShepherdViewModel
    let row: SidebarRowID

    var body: some View {
        Menu("Move to Space") { items }
    }

    var items: some View {
        ForEach(vm.threadMoveSpaces(row)) { space in
            Button(space.name) { vm.requestThreadMove(row, to: space.id) }
                .help(space.path)
        }
    }
}
