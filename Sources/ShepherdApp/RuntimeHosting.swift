import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// What Missions and Projects (`MissionController`, `ProjectCoordinatorController`,
/// `ProjectExecutionController`) need from whoever runs them: the app's view model in process, or
/// `Shepherd --host` (`headless`). They run where the agents run, so with the background service
/// on they keep acting after Quit; a restart still brings them back paused (the server's start).
@MainActor
struct RuntimeHosting {
    let server: SessionServer
    let settings: AppSettings
    /// The workspace as the controllers read it: the app's observed copy, or the server's.
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
    /// Paired hosts a Project may place work on: the app's connections. The headless host has none.
    var connections: () -> [RemoteHostStore.Connection] = { [] }
    /// The app's own: open a thread, and its thread store. The headless host shows nothing.
    var selectAgent: (AgentID) -> Void = { _ in }
    var threadStore: (AgentID) -> NativeThreadStore? = { _ in nil }
    var missionStartRequested: (get: () -> Bool, set: (Bool) -> Void) = ({ false }, { _ in })

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
            worktrees: worktrees)
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

extension ShepherdViewModel {
    /// The app's own, while it owns the workspace: agents start and restart through its sessions,
    /// adopting the server's state first so the new thread's pane is the one it binds.
    var runtimeHosting: RuntimeHosting {
        let server = server
        var hosting = RuntimeHosting(
            server: server, settings: settings, state: { [unowned self] in state },
            startAgent: { [unowned self] config in
                sessions.stateDidChange(server.state)
                state = server.state
                return try await startAgent(config, selectAfter: false, focusWindow: false)
            },
            restartAgent: { [unowned self] agent, tab, pane, entry in
                sessions.stateDidChange(server.state)
                state = server.state
                // A Project follow-up replaces whatever the worker's pane last held.
                if entry != nil {
                    sessions.detachPane(pane.id)
                    sessions.reserveAgentPane(pane.id)
                }
                try await sessions.createAgentSession(pane: pane, tab: tab, agent: agent, openingPrompt: nil, requiredHistoryEntryID: entry)
            },
            notify: { [unowned self] title, body in notifications.post(AgentBanners.automation(title: title, body: body)) },
            nativeThread: { [unowned self] in try await nativeThread($0, request: $1) },
            worktrees: worktrees)
        hosting.connections = { [unowned self] in remoteHosts.allConnections }
        hosting.selectAgent = { [unowned self] in selectAgent($0) }
        hosting.threadStore = { [unowned self] in threadStores.store(for: $0) }
        hosting.missionStartRequested = ({ [unowned self] in missionStartRequested }, { [unowned self] in missionStartRequested = $0 })
        return hosting
    }
}
