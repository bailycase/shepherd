import SwiftUI
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The agent actions a client sends its host: rename, move within its group, and delete
/// (keeping any worktree). Deleting a worktree agent with its checkout is `DeleteAgentSheet`'s,
/// through the host's worktree operation.
@MainActor
enum AgentActions {
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func client(_ ref: AgentRef, hosts: MobileHosts) throws -> RemoteHostClient {
        guard let host = hosts.host(ref.host) else { throw Failure("This host was forgotten.") }
        guard let client = host.connectedClient else { throw Failure("\(host.name) is offline. Try again once it reconnects.") }
        return client
    }

    static func rename(_ ref: AgentRef, to name: String, hosts: MobileHosts) async throws {
        try await perform(ref, .rename(name: name), hosts: hosts)
    }

    /// One place up or down within the agent's group; a move past the last agent is two
    /// requests, as on the Mac.
    static func move(_ ref: AgentRef, _ direction: AgentReorder.Direction, hosts: MobileHosts) async throws {
        guard let host = hosts.host(ref.host) else { throw Failure("This host was forgotten.") }
        let client = try client(ref, hosts: hosts)
        for move in AgentReorder.moves(host.state.agents, moving: ref.agent, direction) {
            try await send(client, agent: move.agent, .reorder(target: move.before))
        }
    }

    /// Retires the agent only; a worktree checkout and its branch stay on the host.
    static func delete(_ ref: AgentRef, hosts: MobileHosts) async throws {
        try await perform(ref, .deleteKeepingWorktree, hosts: hosts)
    }

    private static func perform(_ ref: AgentRef, _ action: RemoteAgentAction, hosts: MobileHosts) async throws {
        try await send(try client(ref, hosts: hosts), agent: ref.agent, action)
    }

    private static func send(_ client: RemoteHostClient, agent: AgentID, _ action: RemoteAgentAction) async throws {
        do {
            try await client.agentAction(agentID: agent, action: action)
        } catch RemoteHostClientError.rejected(_, let message) {
            throw Failure(message)
        } catch let error as RemoteHostClientError {
            throw Failure("The host didn’t answer (\(error.description)). Check the thread before trying again.")
        }
    }

    /// Runs `action` from a menu or the palette, where nothing is on screen to show an error:
    /// a failure is presented on its own.
    static func run(_ title: String, navigator: MobileNavigator, _ action: @escaping @MainActor () async throws -> Void) {
        Task { @MainActor in
            do { try await action() } catch {
                navigator.present(.search(.problem(title: title, message: String(describing: error))))
            }
        }
    }
}

/// Worktree deletions started from this device, by agent, kept until their sheet says Done: a
/// sheet closed while one runs shows its progress again when reopened, and never starts a
/// second one.
@MainActor
@Observable
final class WorktreeOperations {
    static let shared = WorktreeOperations()

    private(set) var running: [AgentRef: UUID] = [:]

    func start(_ ref: AgentRef) -> UUID {
        let id = UUID()
        running[ref] = id
        return id
    }

    func finish(_ ref: AgentRef) {
        running[ref] = nil
    }
}

extension MobileNavigator {
    /// Closes every screen of a thread that no longer exists: its detail on iPad, and the
    /// thread and anything pushed for it on either stack.
    func close(thread ref: AgentRef) {
        func belongs(_ route: MobileRoute) -> Bool {
            switch route {
            case .thread(let other): other == ref
            case .subagents(let route): route.thread == ref
            case .review(let route): route.thread == ref
            default: false
            }
        }
        homePath.removeAll(where: belongs)
        settingsPath.removeAll(where: belongs)
        padPath.removeAll(where: belongs)
        if padSelection == ref {
            padSelection = nil
            padColumns = .all
        }
    }
}
