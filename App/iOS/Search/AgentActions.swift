import Foundation
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
        guard let client = host.connectedClient else { throw offline(host.name) }
        return client
    }

    private static func offline(_ hostName: String) -> Failure {
        Failure("\(hostName) is offline. Try again once it reconnects.")
    }

    /// Optimistic: the thread shows `name` at once (`MobileHost.agent`, `threadState`) and the host takes it in the
    /// background, the latest name last. Throws only when it cannot be tried now (host forgotten or offline); a
    /// refusal later restores the host's name and goes to `failed`.
    static func rename(_ ref: AgentRef, to name: String, hosts: MobileHosts, failed: @escaping @MainActor (Failure) -> Void) throws {
        _ = try client(ref, hosts: hosts)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let host = hosts.host(ref.host), host.submitRename(ref.agent, to: name) else { return }
        sendRename(ref, host: host, hosts: hosts, failed: failed)
    }

    private static func sendRename(_ ref: AgentRef, host: MobileHost, hosts: MobileHosts, failed: @escaping @MainActor (Failure) -> Void) {
        guard let name = host.beginRename(ref.agent) else { return }
        sendRename(ref, name: name, host: host, hosts: hosts, failed: failed)
    }

    private static func sendRename(_ ref: AgentRef, name: String, host: MobileHost, hosts: MobileHosts,
                                   failed: @escaping @MainActor (Failure) -> Void) {
        Task { @MainActor in
            var failure: Failure?
            do { try await perform(ref, .rename(name: name), hosts: hosts) }
            catch let error as Failure { failure = error }
            catch { failure = Failure(String(describing: error)) }
            switch host.endRename(ref.agent, sent: name, failed: failure != nil) {
            case .resend(let next): sendRename(ref, name: next, host: host, hosts: hosts, failed: failed)
            case .reverted: if let failure { failed(failure) }
            case .settled, .ignored: break
            }
        }
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

    /// Move to Space: one of the thread's own host's spaces. The host refuses a worktree, an active thread or a hidden
    /// space, and the reason is shown.
    static func move(_ ref: AgentRef, to space: SpaceID, hosts: MobileHosts) async throws {
        try await perform(ref, .move(spaceID: space), hosts: hosts)
    }

    /// Mute or Unmute Notifications: the thread's host keeps it, so every phone agrees.
    static func mutePushes(_ ref: AgentRef, _ muted: Bool, hosts: MobileHosts) async throws {
        try await perform(ref, .mutePushes(muted), hosts: hosts)
    }

    /// Move to Mac: the thread's host stops the turn (now, or when it ends), sends the conversation and the worktree and starts it on `host`.
    static func moveToMac(_ ref: AgentRef, _ request: FleetMoveRequest, hosts: MobileHosts) async throws {
        try await perform(ref, .moveToMac(request), hosts: hosts)
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

}

// The app's half: presenting a failure and the worktree operations. The macOS checks (Tests/ShepherdIOSChecks/run.sh) build
// the transport above against real TCP hosts without the app's screens.
#if canImport(UIKit)
import UIKit

extension AgentActions {
    /// Like the Mac's menu item, copy the saved conversation only once all its pages arrive.
    static func copyTranscript(_ ref: AgentRef, hosts: MobileHosts, navigator: MobileNavigator) {
        run("Couldn’t copy the transcript", navigator: navigator) {
            let client = try client(ref, hosts: hosts)
            let host = hosts.host(ref.host)
            do {
                let copied = try await ShepherdRemote.ThreadTranscript.copy(fetch: { request in
                    try await client.nativeThread(agentID: ref.agent, request: request)
                }, to: { UIPasteboard.general.string = $0 })
                guard copied else {
                    let name = host?.agent(ref.agent).map { "“\($0.name)”" } ?? "This thread"
                    throw Failure("\(name) has no transcript yet. Nothing was copied.")
                }
            } catch RemoteHostClientError.disconnected {
                throw offline(host?.name ?? "The host")
            } catch RemoteHostClientError.rejected(_, let message) {
                throw Failure(message)
            }
            navigator.present(.search(.problem(title: "Transcript copied", message: "The transcript is on the clipboard.")))
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

    func forget(host: UUID) { running = running.filter { $0.key.host != host } }
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
        for tab in Tab.allCases { self[path: tab].removeAll(where: belongs) }
        padPath.removeAll(where: belongs)
        if padSelection == ref {
            padSelection = nil
            padColumns = .all
        }
    }
}
#endif
