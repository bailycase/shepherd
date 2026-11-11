import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// What Missions and Projects (`MissionController`, `ProjectCoordinatorController`,
/// `ProjectExecutionController`) need from whoever runs them: `Shepherd --host` (`headless`). They run where the agents run, so with the background service
/// on they keep acting after Quit; a restart still brings them back paused (the server's start).
@MainActor
struct RuntimeHosting {
    let server: SessionServer
    let settings: AppSettings
    /// The workspace as the controllers read it: the server's.
    var state: () -> ShepherdState
    /// Starts a new agent; returns once its pi is spawned.
    var startAgent: (NewAgentConfig) async throws -> AgentID
    /// Starts an existing agent's pi again in its own pane, idle, restoring exactly the conversation
    /// that holds `requiredEntry` when one is named (a Project follow-up).
    var restartAgent: (_ agent: Agent, _ tab: ShepherdCore.Tab, _ pane: LeafPane, _ requiredEntry: String?) async throws -> Void
    /// A banner, as automations post theirs.
    var notify: (_ title: String, _ body: String) -> Void
    /// One of the workspace's threads' requests.
    var nativeThread: (AgentID, NativeThreadRequest) async throws -> NativeThreadResult
    /// The checkouts a worktree operation holds, shared with the owner's other git operations.
    let worktrees: WorktreeQueries
    /// Paired Macs a Project may place work on: the app's connections, or the headless host's
    /// relay through this Mac's app while it runs (`relayed`).
    var executors = ProjectExecutors()
    /// The app's own: open a thread, and its thread store. The headless host shows nothing.
    var selectAgent: (AgentID) -> Void = { _ in }
    var threadStore: (AgentID) -> NativeThreadStore? = { _ in nil }
    var missionStartRequested: (get: () -> Bool, set: (Bool) -> Void) = ({ false }, { _ in })

    /// The paired Macs a Project reaches, each addressed only by its exact host and binding: never
    /// another host, never a local path.
    struct ProjectExecutors {
        /// The connected ones, with their visible Spaces when they take placements (nil: they don't).
        var hosts: () async -> [ProjectHostOption] = { [] }
        var place: (ProjectHostReference, ProjectExecutionRequest) async throws -> ProjectExecutionResult = { _, _ in
            throw AgentStartFailure(message: "The exact executor binding is unavailable. No fallback host was selected.")
        }
        var workerThread: (ProjectHostReference, AgentID, NativeThreadRequest) async throws -> NativeThreadResult = { _, _, _ in
            throw LogicalProjectsError("executor_unavailable", "The thread's exact executor binding is unavailable. No fallback host was selected.")
        }

        /// The background host's: through this Mac's app, which holds the connections, while it runs.
        static func relayed(through server: SessionServer) -> ProjectExecutors {
            server.relayProjectPlacementThroughApp()
            func relay(_ job: AppRelayJob) async throws -> AppRelayResult {
                let result = await withCheckedContinuation { done in server.relayToApp(job) { done.resume(returning: $0) } }
                switch result {
                case nil: throw LogicalProjectsError("app_closed", SessionServer.appClosedForPlacement)
                case .failed(let code, let message)?: throw LogicalProjectsError(code, message)
                case let result?: return result
                }
            }
            return ProjectExecutors(
                hosts: { await server.appProjectExecutors() },
                place: { host, request in
                    guard case .projectExecution(let result) = try await relay(.projectPlacement(host: host, request: request)) else {
                        throw LogicalProjectsError("protocol", "unexpected answer")
                    }
                    return result
                },
                workerThread: { host, agentID, request in
                    guard case .nativeThread(let result) = try await relay(.projectWorkerThread(host: host, agentID: agentID, request: request)) else {
                        throw LogicalProjectsError("protocol", "unexpected answer")
                    }
                    return result
                })
        }
    }

    /// The host's: agents start with the app's settings and MCP servers, as automation runs do.
    static func headless(server: SessionServer, settings: AppSettings, worktrees: WorktreeQueries,
                         mcp: @escaping AgentSpawn.MCP, notify: @escaping (String, String) -> Void) -> RuntimeHosting {
        RuntimeHosting(
            server: server, settings: settings, state: { server.state },
            startAgent: { config in
                try await server.startNewAgent(config, launch: settings.agentLaunch, defaultServiceTier: settings.defaultServiceTier, mcp: mcp)
            },
            restartAgent: { agent, _, _, entry in
                var spawn = AgentSpawn(agent: agent, cwd: "", settings: settings.agentLaunch)
                spawn.requiredHistoryEntryID = entry
                spawn.specKit = true
                spawn.mcp = mcp
                do {
                    guard try await server.respawnAgent(spawn) != nil else { throw AgentStartFailure(message: "The agent's pane is unavailable.") }
                } catch let refused as AgentSpawnRefused {
                    throw AgentStartFailure(message: refused.description)
                } catch let failed as PaneBindingFailed {
                    server.killSession(failed.sessionID)
                    throw AgentStartFailure(message: failed.description)
                }
            },
            notify: notify,
            nativeThread: { try await server.nativeThread(agentID: $0, request: $1) },
            worktrees: worktrees, executors: .relayed(through: server))
    }

    /// Builds the three controllers on `server` and serves their requests: missions (`missions.v1`
    /// and mission threads' messages), the Project runtime, placements, launches and executions,
    /// and Project-owned automation runs. Keep what it returns for as long as they serve.
    func serve() -> (missions: MissionController, coordinator: ProjectCoordinatorController, execution: ProjectExecutionController) {
        let missions = MissionController(hosting: self)
        let coordinator = ProjectCoordinatorController(hosting: self)
        let execution = ProjectExecutionController(hosting: self)
        missions.installRemote()
        coordinator.install()
        execution.install()
        return (missions, coordinator, execution)
    }
}
