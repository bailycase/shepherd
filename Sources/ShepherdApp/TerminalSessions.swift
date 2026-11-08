import Foundation
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

enum TerminalSessionStoreError: Error, CustomStringConvertible {
    case paneUnavailable(PaneID)
    case bindingFailed(paneID: PaneID, sessionID: SessionID, reason: String)

    var description: String {
        switch self {
        case .paneUnavailable(let paneID):
            return "pane \(paneID) is no longer owned by the requested layout"
        case .bindingFailed(let paneID, let sessionID, let reason):
            return "failed to bind session \(sessionID) to pane \(paneID): \(reason)"
        }
    }
}

/// Maps panes to sessions owned by the in-process server. There is no
/// external connect/bootstrap dance: the store adopts
/// the persisted state at init and every pane renders against live sessions.
/// On relaunch all previously bound sessions are dead (they died with the
/// app), so a requested pane respawns fresh: `pi --mode rpc` for an agent's primary
/// pane, a login shell for everything else. Unrequested restored panes stay dormant.
@MainActor
final class TerminalSessionStore {

    /// One pane's session. Views observe phase and dormancy; everything else is attach and replay
    /// bookkeeping, and the terminal model is built lazily while a view renders.
    @MainActor
    @Observable
    final class PaneSession {
        enum Phase: Equatable {
            case connecting
            case live
            case failed(String)
            case exited(Int32?)
            /// An agent's pi stopped (before it served, on its own after, or Shepherd stopped it): the agent stays,
            /// its thread says why, and Retry starts pi again.
            case stopped
        }

        let paneID: PaneID
        /// True for the pi pane of an RPC agent: no Ghostty surface, no grid, no replay.
        /// The pane's process is reached only through `SessionServer.nativeThread`.
        let isRPC: Bool
        /// Set once `terminal` has been built; RPC panes must never build one.
        @ObservationIgnored private(set) var hasTerminalModel = false
        /// Built on first use so an RPC pane never pays for a Ghostty model.
        @ObservationIgnored lazy var terminal: AppTerminalModel = {
            assert(!isRPC, "RPC pane \(paneID) must not build a terminal model")
            hasTerminalModel = true
            return AppTerminalModel(
                fontSize: AppSettings.shared.terminalFontSize,
                fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
                terminal: ThemeManager.shared.current.terminal,
                // Rebound app shortcuts must fall through a focused terminal
                // exactly like the built-in ones.
                extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds
            )
        }()
        var phase: Phase = .connecting
        /// A restored, unrequested pane has neither a process nor a terminal surface.
        fileprivate(set) var isDormant = false
        var startupTrigger: DiagnosticFailureDetails.StartupTrigger = .unknown
        var startupLocation: DiagnosticFailureDetails.StartupLocation?
        @ObservationIgnored var sessionID: SessionID?
        struct BufferedOutput {
            let data: Data
            let sequence: UInt64
            var completion: (@Sendable () -> Void)? = nil
        }

        deinit {
            for chunk in buffered { chunk.completion?() }
        }

        /// Output that races the attach replay. Sequence watermarks decide
        /// which chunks the snapshot already contains.
        @ObservationIgnored fileprivate var buffered: [BufferedOutput] = []
        /// True while subscribed, including the atomic snapshot handoff.
        @ObservationIgnored fileprivate var attachRequested = false
        @ObservationIgnored fileprivate var surfaceGeneration: UInt64?
        @ObservationIgnored private var nextAttachAttempt: UInt64 = 0
        @ObservationIgnored fileprivate var activeAttachAttempt: UInt64?
        /// Last grid the surface reported via onResize; the PTY keeps this
        /// size. Defaults match createSession's fallback 80×24.
        @ObservationIgnored fileprivate(set) var lastCols = 80
        @ObservationIgnored fileprivate(set) var lastRows = 24
        /// True after Ghostty reports this surface's actual grid at least once.
        @ObservationIgnored fileprivate var hasReportedGrid = false
        /// Suspended `awaitGrid` callers, resumed by the first grid report (or
        /// by its timeout).
        @ObservationIgnored private var gridWaiters: [CheckedContinuation<Void, Never>] = []

        init(paneID: PaneID, isRPC: Bool = false) {
            self.paneID = paneID
            self.isRPC = isRPC
        }

        /// Record a surface grid report and wake anyone waiting for the first
        /// one.
        func noteGrid(cols: Int, rows: Int) {
            lastCols = cols
            lastRows = rows
            let isFirst = !hasReportedGrid
            hasReportedGrid = true
            if isFirst { releaseGridWaiters() }
        }

        /// Wait for the surface's first grid report so the PTY can be spawned
        /// at the size the child will actually render into. Falls back to the
        /// 80×24 default if the surface never lays out in time — a late,
        /// correctly-sized process beats a fast, mis-sized one, but a pane
        /// that never reports must still get its process.
        func awaitGrid(timeoutNanoseconds: UInt64) async {
            guard !hasReportedGrid else { return }
            let timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                self?.releaseGridWaiters()
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if hasReportedGrid {
                    continuation.resume()
                } else {
                    gridWaiters.append(continuation)
                }
            }
            timeout.cancel()
        }

        private func releaseGridWaiters() {
            let waiters = gridWaiters
            gridWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        func receive(_ data: Data, sequence: UInt64, completion: @escaping @Sendable () -> Void) {
            guard attachRequested else { completion(); return }
            if activeAttachAttempt == nil {
                terminal.feed(data, completion: completion)
            } else {
                buffered.append(BufferedOutput(data: data, sequence: sequence, completion: completion))
            }
        }

        func beginAttachAttempt() -> UInt64? {
            guard !attachRequested else { return nil }
            nextAttachAttempt &+= 1
            attachRequested = true
            activeAttachAttempt = nextAttachAttempt
            return nextAttachAttempt
        }

        /// Apply the snapshot only to its ready generation, then feed bytes
        /// beyond its watermark. Absent views never collect a local backlog.
        @discardableResult
        fileprivate func goLive(
            replay: Data,
            watermark: UInt64,
            attempt: UInt64,
            generation: UInt64
        ) -> Bool {
            guard activeAttachAttempt == attempt,
                  terminal.replaceWithReplay(replay, generation: generation) else { return false }
            let fresh = Self.output(after: watermark, from: buffered)
            for chunk in buffered where chunk.sequence <= watermark { chunk.completion?() }
            buffered.removeAll()
            activeAttachAttempt = nil
            phase = .live
            for chunk in fresh {
                terminal.feed(chunk.data, completion: chunk.completion)
            }
            return true
        }

        fileprivate func stopOutput() {
            attachRequested = false
            activeAttachAttempt = nil
            for chunk in buffered { chunk.completion?() }
            buffered.removeAll()
        }

        static func output(after watermark: UInt64, from buffered: [BufferedOutput]) -> [BufferedOutput] {
            buffered.filter { $0.sequence > watermark }
        }

        fileprivate func failAttach(attempt: UInt64, phase: Phase? = nil) {
            guard activeAttachAttempt == attempt else { return }
            stopOutput()
            if let phase { self.phase = phase }
        }
    }

    /// How long a spawn waits for its surface to report a grid before falling
    /// back to 80×24. Layout normally lands within a frame or two; this only
    /// bounds the pathological case.
    static let gridWaitNanoseconds: UInt64 = 400_000_000

    /// The in-process server. Owned by the app (one per process).
    let server: SessionServer
    var reserveCheckoutForLaunch: ((String) throws -> (() -> Void))?
    /// What an agent's pi gets for MCP when it starts (`MCPLaunch.forAgents`); the app sets it,
    /// and an agent launched without it has no MCP.
    var mcpLaunch: () throws -> MCPLaunch? = { nil }
    private var sessions: [PaneID: PaneSession] = [:]
    private var paneBySession: [SessionID: PaneID] = [:]
    private typealias PendingExit = SessionExit

    /// A very short-lived child can exit before the create/adopt continuation
    /// installs its pane mapping. Keep that exit until adoption catches up.
    private var pendingExits: [SessionID: PendingExit] = [:]
    private var handledExits: Set<SessionID> = []
    /// A closed pane no longer has a consumer to adopt its dead session. Keep
    /// those ids separate so the exit callback can retire them directly.
    private var detachedSessionIDs: Set<SessionID> = []
    /// Panes whose pi process the agent-creation flow is about to spawn.
    /// `addAgent` broadcasts state before `createAgentSession` runs, which
    /// mounts the new pane and sends its view through `start()` — without
    /// this guard that respawn path raced the creation flow and spawned a
    /// second pi into the same pane (two splash screens, doubled output).
    private var reservedPanes: Set<PaneID> = []
    /// How long a pane's start waits for the server to own it before giving up.
    private let ownershipTimeout: Duration

    /// Claim a pane for `createAgentSession` before the agent is added to
    /// server state. Must be called before `addAgent` broadcasts.
    func reserveAgentPane(_ paneID: PaneID) {
        reservedPanes.insert(paneID)
    }

    /// Release a reservation without creating a session (addAgent failed).
    func unreserveAgentPane(_ paneID: PaneID) {
        reservedPanes.remove(paneID)
    }
    private var bootstrapTask: Task<Void, Error>?

    /// Server-authoritative state mirror, adopted at bootstrap and kept in
    /// sync with every server broadcast. View-model-originated optimistic
    /// updates also flow here so session lookup never lags the visible tree.
    private var serverState: ShepherdState?
    private var aliveSessions: Set<SessionID> = []

    /// Fired for bootstrap and every server snapshot. Adopts the committed
    /// workspace so the sidebar and panes rebuild.
    var onStateChanged: ((ShepherdState) -> Void)?
    /// Fired whenever this store persists a layout change (session bindings).
    var onTabLayoutChanged: ((TabID, PaneNode) -> Void)?
    /// Fired on server agentStatus events (from the pi status extension), with the failure of a
    /// turn that ended in an error.
    var onAgentStatus: ((AgentID, AgentStatus, TurnFailure?) -> Void)?
    /// Fired on subagents-extension child-run publishes (full replace).
    var onAgentChildren: ((AgentID, [ChildRun]) -> Void)?
    /// Fired when an agent's notify tool asks for a system notification.
    var onNotify: ((AgentID, String, String) -> Void)?
    /// Fired when a watched agent's native thread has a new revision to fetch, at most once per
    /// display frame (`SessionServer.onThreadRevision`).
    var onThreadRevision: ((AgentID) -> Void)?
    /// Fired when a pane's process exits, after the local session is marked
    /// exited and before it is dropped from the store.
    var onPaneSessionExited: ((PaneID) -> Void)?
    /// Fired when an agent's pi stops (before it served, on its own after, or Shepherd stopped it),
    /// with why (nil for a stop Shepherd asked for): the agent stays, waiting for Retry. Fired again
    /// with nil and false when Retry starts it.
    var onAgentStopped: ((AgentID, NativeStartProblem?, Bool) -> Void)?
    /// Fired the moment an agent's pi begins serving its thread
    /// (`SessionServer.onNativeThreadServable`).
    var onThreadServable: ((AgentID) -> Void)?

    /// The order restored agents' pi start in, and the work that starts each one queued.
    private(set) var startQueue = AgentStartQueue()
    private var queuedStarts: [AgentID: () async -> Bool] = [:]
    /// Restored panes may mount in the hidden layout deck without starting a process.
    private var dormantPanes: Set<PaneID> = []

    init(server: SessionServer, ownershipTimeout: Duration = .seconds(3)) {
        self.server = server
        self.ownershipTimeout = ownershipTimeout
        server.onNativeThreadDemand = { [weak self] agentID in
            self?.activateAgent(agentID)
        }
        server.onOutputConsumed = { [weak self] sessionID, data, sequence, completion in
            guard let pane = self?.session(forSessionID: sessionID) else { completion(); return }
            pane.receive(data, sequence: sequence, completion: completion)
        }
        server.onSessionExited = { [weak self] sessionID, exit in
            guard let self, !self.handledExits.contains(sessionID) else { return }
            self.aliveSessions.remove(sessionID)
            guard self.paneBySession[sessionID] != nil else {
                if self.detachedSessionIDs.remove(sessionID) != nil {
                    self.handledExits.insert(sessionID)
                    Task { [weak self] in
                        await self?.server.retireSession(sessionID: sessionID)
                    }
                    return
                }
                // The PTY can finish between createSession and adopt. Do not
                // drop that exit, or the pane will wait forever for a session
                // that is already dead.
                self.pendingExits[sessionID] = exit
                return
            }
            self.processExit(sessionID: sessionID, exit: exit)
        }
        server.onStateChanged = { [weak self] state in
            self?.serverState = state
            self?.onStateChanged?(state)
        }
        server.onAgentStatus = { [weak self] agentID, status, failure in
            self?.onAgentStatus?(agentID, status, failure)
        }
        server.onAgentChildren = { [weak self] agentID, children in
            self?.onAgentChildren?(agentID, children)
        }
        server.onNotify = { [weak self] agentID, title, body in
            self?.onNotify?(agentID, title, body)
        }
        server.onNativeThreadServable = { [weak self] agentID in
            self?.threadServable(agentID)
        }
        server.onThreadRevision = { [weak self] agentID in
            self?.onThreadRevision?(agentID)
        }
    }

    private func threadServable(_ agentID: AgentID) {
        onThreadServable?(agentID)
        startFinished(agentID)
    }

    /// The agents whose thread is on screen: only their revisions are pushed (`onThreadRevision`).
    func watchThreadRevisions(of agentIDs: Set<AgentID>) {
        server.watchThreadRevisions(of: agentIDs)
    }

    /// Kick off bootstrap without waiting for a pane to appear.
    func warmUp() {
        Task { try? await ensureBootstrapped() }
    }

    /// Recolor every live local surface in place. Ghostty applies theme
    /// configuration without replacing the NSView, so no detach or replay is
    /// involved and Pi's simultaneous repaint cannot race a screen snapshot.
    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        for session in sessions.values where !session.isRPC && session.hasTerminalModel {
            session.terminal.updateAppearance(terminal)
        }
    }

    /// Reconfigure every live local surface in place (terminal font,
    /// keybind unbinds). Like updateAppearance, ghostty applies the config
    /// without replacing the NSView — no detach, no replay, no blank pane.
    func updateSurfaceConfiguration() {
        for session in sessions.values where !session.isRPC && session.hasTerminalModel {
            session.terminal.updateConfiguration(
                fontSize: AppSettings.shared.terminalFontSize,
                fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
                extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds
            )
        }
    }

    /// Surface-structure changes: drop every
    /// local surface; pane views rebuild lazily and reattach with replay.
    /// Session processes remain alive in the in-process server.
    func rebuildAllSurfaces() {
        for session in sessions.values where !session.isRPC {
            session.stopOutput()
            if let sessionID = session.sessionID {
                server.detach(sessionID: sessionID)
            }
        }
        // RPC panes have no surface to rebuild; their binding stays.
        sessions = sessions.filter { $0.value.isRPC }
    }

    /// Mirror view-model-originated state mutations already persisted (or
    /// about to be) so binding lookups and agent rebuilds see them.
    func stateDidChange(_ state: ShepherdState) {
        serverState = state
    }

    /// Wait for a pane to have a live session bound.
    ///
    /// A pane's process is spawned when its view first renders, so a pane the
    /// agent just opened has none yet. Polls rather than adding a callback
    /// path: this is only used by agent-driven pane opening, where a short
    /// wait is fine and a missed callback would hang the request.
    /// Live session bound to a pane, if any.
    func liveSession(forPane paneID: PaneID) -> SessionID? {
        guard let sessionID = sessions[paneID]?.sessionID, aliveSessions.contains(sessionID) else {
            return nil
        }
        return sessionID
    }

    func awaitSession(forPane paneID: PaneID, timeout: Duration) async -> SessionID? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let sessionID = sessions[paneID]?.sessionID, aliveSessions.contains(sessionID) {
                return sessionID
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return sessions[paneID]?.sessionID
    }

    /// View-only detach: drop the local pane session without killing anything.
    func detachPane(_ paneID: PaneID) {
        guard let session = sessions.removeValue(forKey: paneID) else { return }
        session.stopOutput()
        if let sessionID = session.sessionID {
            paneBySession.removeValue(forKey: sessionID)
            detachedSessionIDs.insert(sessionID)
            server.detach(sessionID: sessionID)
        }
    }

    /// Cold-park a hidden pane: release its Ghostty surface and stop the
    /// server streaming to it, but keep the pane→session mapping so an exit
    /// while parked still closes the pane. Remounting the pane goes through
    /// `session(for:in:)` → `start` → `adopt`, which reattaches with the
    /// server's screen snapshot at the surface's real grid.
    func parkPane(_ paneID: PaneID) {
        // Nothing to release for an RPC pane; the native view stops polling on its own. A pane
        // without a session yet (dormant, or its start in flight) keeps its entry: dropping it
        // would strand that start against a stale object.
        guard let session = sessions[paneID], !session.isRPC, let sessionID = session.sessionID else { return }
        sessions.removeValue(forKey: paneID)
        session.stopOutput()
        server.detach(sessionID: sessionID)
    }

    /// True when `pane` is `agent`'s primary pane, where its pi runs over RPC. Auxiliary
    /// panes an agent opens are ordinary shells.
    private func isRPCPane(_ pane: LeafPane, agent: Agent?) -> Bool {
        guard let agent else { return false }
        return pane.agentID == agent.id && agent.paneID == pane.id
    }

    private func session(forSessionID id: SessionID) -> PaneSession? {
        if let paneID = paneBySession[id], let session = sessions[paneID] {
            return session
        }
        return nil
    }

    /// Process the exit before dropping the local mapping. The view-model's
    /// callback removes the pane from its layout during this turn; only after
    /// that handoff is the server-side dead session retired.
    private func processExit(sessionID: SessionID, exit: SessionExit) {
        guard !handledExits.contains(sessionID) else { return }
        guard let paneID = paneBySession[sessionID] else {
            pendingExits[sessionID] = exit
            return
        }
        handledExits.insert(sessionID)
        ShepherdDiagnostics.shared.record(.processExited, code: exit.code)
        if let problem = exit.startProblem, problem.kind != .stopped {
            let session = sessions[paneID]
            ShepherdDiagnostics.shared.capture(.agentStartFailed, code: exit.code, details: .init(
                startupKind: problem.kind, trigger: session?.startupTrigger, location: session?.startupLocation))
        }
        // Read before the view model retires the agent: a pi that exits while it boots frees its
        // place in the launch queue now, not when its hold runs out.
        let agent = serverState?.agents.first { $0.paneID == paneID }
        paneBySession.removeValue(forKey: sessionID)
        detachedSessionIDs.remove(sessionID)
        if exit.keepsAgent, let agent, let session = sessions[paneID], session.isRPC {
            // The agent waits with its pane session, so the pane's view never spawns pi again
            // on its own: only Retry does (`retryStart`).
            session.phase = .stopped
            session.sessionID = nil
            startFinished(agent.id)
            onAgentStopped?(agent.id, exit.startProblem, true)
        } else {
            sessions[paneID]?.phase = .exited(exit.code)
            onPaneSessionExited?(paneID)
            sessions.removeValue(forKey: paneID)
            if let agent { startFinished(agent.id) }
        }
        Task { [weak self] in
            await self?.server.retireSession(sessionID: sessionID)
        }
    }

    /// The model an agent's next start takes, whatever its session says (Use another model).
    var modelOverrides: [AgentID: String] = [:]

    /// Retry for an agent whose pi stopped, before it served or on its own after: starts its pi again in the same pane.
    /// `newConversation` (a pi that didn't find the conversation it was resuming) starts it
    /// without that check, as pi would on its own.
    func retryStart(_ agentID: AgentID, newConversation: Bool = false) {
        guard let state = serverState, let agent = state.agents.first(where: { $0.id == agentID }),
              let paneID = agent.paneID, let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let pane = tab.layout.leaf(withID: paneID), let session = sessions[paneID],
              session.isRPC, session.phase == .stopped else { return }
        session.phase = .connecting
        session.startupTrigger = .retry
        onAgentStopped?(agentID, nil, false)
        let stopped = pane.sessionID
        Task { [weak self] in
            guard let self else { return }
            if let stopped { await self.server.retryStart(sessionID: stopped) }
            await self.start(session, pane: pane, tab: tab, checksResume: !newConversation)
        }
    }

    /// SwiftUI structural changes (splits collapsing, panes moving in the
    /// tree) recreate the ghostty NSView; the fresh surface starts blank, so
    /// re-pull the server's current-screen replay into it.
    private func makeSession(paneID: PaneID, isRPC: Bool = false, isDormant: Bool = false) -> PaneSession {
        let session = PaneSession(paneID: paneID, isRPC: isRPC)
        session.isDormant = isDormant
        if !isRPC, !isDormant { configureTerminal(session) }
        return session
    }

    private func configureTerminal(_ session: PaneSession) {
        session.terminal.onInput = { [weak self, weak session] data in
            guard let self, let session, let sessionID = session.sessionID else { return }
            self.server.write(sessionID: sessionID, data: data)
        }
        session.terminal.onResize = { [weak self, weak session] cols, rows in
            guard let self, let session else { return }
            // Recorded even before a session exists: the spawn path waits for
            // this so the child starts at the surface's real grid.
            session.noteGrid(cols: cols, rows: rows)
            guard let sessionID = session.sessionID else { return }
            self.server.reportLocalViewport(sessionID: sessionID, cols: cols, rows: rows)
            // Resize enters the server queue before attach, so the replay is
            // serialized at the exact grid the Ghostty surface will render.
            self.attachIfNeeded(session, sessionID: sessionID)
        }
        session.terminal.onSurfaceAttachmentChanged = { [weak self, weak session] generation in
            guard let self, let session, self.sessions[session.paneID] === session else { return }
            session.surfaceGeneration = generation
            session.stopOutput()
            guard let sessionID = session.sessionID else { return }
            if generation == nil {
                self.server.detach(sessionID: sessionID)
            } else {
                self.attachIfNeeded(session, sessionID: sessionID)
            }
        }
    }

    func session(for pane: LeafPane, in tab: Tab, trigger: DiagnosticFailureDetails.StartupTrigger = .unknown) -> PaneSession {
        // Before bootstrap the mirror is empty; the pane's role decides the session kind, so
        // read the server directly rather than guess a shell.
        let agents = (serverState ?? server.state).agents
        let agent = pane.agentID.flatMap { id in agents.first { $0.id == id } }
        let rpc = isRPCPane(pane, agent: agent)
        if let existing = sessions[pane.id] {
            if existing.isRPC == rpc { return existing }
            // The pane changed role under an unbound pane session: a session of the other
            // kind can never serve this pane.
            detachPane(pane.id)
        }
        let session = makeSession(paneID: pane.id, isRPC: rpc, isDormant: dormantPanes.contains(pane.id))
        session.startupTrigger = trigger
        sessions[pane.id] = session
        scheduleStart(session, pane: pane, tab: tab)
        return session
    }

    private func scheduleStart(_ session: PaneSession, pane: LeafPane, tab: Tab) {
        // Creation owns reserved panes; hidden restored layouts own no processes yet.
        guard !reservedPanes.contains(pane.id), !dormantPanes.contains(pane.id) else { return }
        // Only an agent's first start waits its turn; a pane session made again later starts now.
        guard session.isRPC, let agentID = pane.agentID, !startQueue.started.contains(agentID) else {
            Task { await start(session, pane: pane, tab: tab) }
            return
        }
        // An agent's pi starts in the queue's order: the ones on screen first.
        queuedStarts[agentID] = { [weak self, weak session] in
            guard let self, let session else { return false }
            return await self.start(session, pane: pane, tab: tab)
        }
        if startQueue.enqueue(agentID) { beginStart(agentID, ahead: true) }
        pumpStarts()
    }

    /// Classify before hidden layouts mount. Only selection, demand, or durable unfinished
    /// ordinary work starts a restored pi; recovery never starts its auxiliary terminals.
    func restoreAgents(_ order: [AgentID], first: [AgentID], in state: ShepherdState) {
        let tabs = Set(state.agents.map(\.tabID))
        dormantPanes.formUnion(state.tabs.filter { tabs.contains($0.id) }.flatMap { $0.layout.leaves.map(\.id) })
        for id in first { startAhead(id, trigger: .restore) }
        Task { [weak self] in
            guard let self else { return }
            let recovery = await server.agentsNeedingStartupRecovery()
            for id in order where recovery.contains(id) { activateAgent(id, trigger: .recovery) }
        }
    }

    private func activatePane(_ pane: LeafPane, in tab: Tab, trigger: DiagnosticFailureDetails.StartupTrigger = .demand) {
        if dormantPanes.remove(pane.id) != nil, let session = sessions[pane.id] {
            session.startupTrigger = trigger
            session.isDormant = false
            if !session.isRPC, !session.hasTerminalModel { configureTerminal(session) }
            scheduleStart(session, pane: pane, tab: tab)
        } else {
            _ = session(for: pane, in: tab, trigger: trigger)
        }
    }

    /// Demand for one auxiliary pane (a remote viewer's, or its tab shown on this Mac) starts
    /// only it, without selecting its agent; a pane already started is left as it is.
    func activateTerminal(_ pane: LeafPane, in tab: Tab) {
        activatePane(pane, in: tab)
    }

    /// Explicit native/remote demand starts the primary thread, not hidden terminals.
    func activateAgent(_ agentID: AgentID, trigger: DiagnosticFailureDetails.StartupTrigger = .demand) {
        guard let state = serverState, let agent = state.agents.first(where: { $0.id == agentID }),
              let paneID = agent.paneID, let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let pane = tab.layout.leaf(withID: paneID) else { return }
        activatePane(pane, in: tab, trigger: trigger)
    }

    /// Explicit design/worktree restoration starts the requested agents in queue order.
    func startRestoredAgents(_ order: [AgentID], first: [AgentID], in state: ShepherdState) {
        for agentID in first { startAhead(agentID) }
        for agentID in first + order {
            guard let agent = state.agents.first(where: { $0.id == agentID }), let paneID = agent.paneID,
                  let tab = state.tabs.first(where: { $0.id == agent.tabID }),
                  let pane = tab.layout.leaf(withID: paneID) else { continue }
            activatePane(pane, in: tab)
        }
    }

    /// `agentID` is on screen: if its pi is still waiting to start, it starts now, ahead of the
    /// others; if it has not been queued yet, it will be as soon as it is.
    func startAhead(_ agentID: AgentID, trigger: DiagnosticFailureDetails.StartupTrigger = .demand) {
        // A new agent's pi is its creation's to spawn, never queued.
        if let paneID = serverState?.agents.first(where: { $0.id == agentID })?.paneID, reservedPanes.contains(paneID) { return }
        if startQueue.startAhead(agentID) { beginStart(agentID, ahead: true) }
        activateAgent(agentID, trigger: trigger)
        if let state = serverState, let agent = state.agents.first(where: { $0.id == agentID }),
           let tab = state.tabs.first(where: { $0.id == agent.tabID }) {
            for pane in tab.layout.leaves where dormantPanes.contains(pane.id) {
                activatePane(pane, in: tab, trigger: trigger)
            }
        }
    }

    /// Holds every queued agent start (`AgentStartQueue.hold`): the first launch's copy from the
    /// user's pi and its welcome step come first.
    func holdStarts() {
        startQueue.hold()
    }

    /// Ends the hold: the agents on screen start first, then the rest in order.
    func releaseStarts() {
        for agentID in startQueue.release() { beginStart(agentID, ahead: true) }
        pumpStarts()
    }

    /// Keeps `ids` waiting past the end of the hold on everything (Something missing).
    func holdStarts(of ids: Set<AgentID>) {
        startQueue.hold(ids)
    }

    /// Ends the hold on the agents held one by one: the ones on screen first.
    func releaseHeldAgents() {
        for agentID in startQueue.releaseAgents() { beginStart(agentID, ahead: true) }
        pumpStarts()
    }

    private func beginStart(_ agentID: AgentID, ahead: Bool) {
        guard let body = queuedStarts.removeValue(forKey: agentID) else {
            startFinished(agentID)
            return
        }
        Task { [weak self] in
            let spawned = await body()
            guard let self else { return }
            // A pi it spawned holds its place until it serves (`threadServable`), or so long.
            if spawned {
                try? await Task.sleep(for: ahead ? AgentStartQueue.aheadHold : AgentStartQueue.slotTimeout)
            }
            self.startFinished(agentID)
        }
    }

    private func startFinished(_ agentID: AgentID) {
        startQueue.finished(agentID)
        pumpStarts()
    }

    private func pumpStarts() {
        for agentID in startQueue.next() { beginStart(agentID, ahead: false) }
    }

    /// Spawn the pi session for a freshly created agent, bind it to its pane,
    /// and attach — so the pane view's `session(for:in:)` finds it live.
    func createAgentSession(pane: LeafPane, tab: Tab, agent: Agent, openingPrompt: OpeningPrompt?, isAutomation: Bool = false,
                            requiredHistoryEntryID: String? = nil) async throws {
        defer { reservedPanes.remove(pane.id) }
        try await ensureBootstrapped()
        guard let state = serverState,
              state.tabs.first(where: { $0.id == tab.id })?.layout.contains(pane.id) == true else {
            throw TerminalSessionStoreError.paneUnavailable(pane.id)
        }

        let rpc = isRPCPane(pane, agent: agent)
        if let stale = sessions[pane.id], stale.isRPC != rpc { detachPane(pane.id) }
        let session = sessions[pane.id] ?? makeSession(paneID: pane.id, isRPC: rpc)
        sessions[pane.id] = session
        var createdSessionID: SessionID?
        do {
            guard session.sessionID == nil, liveBinding(forPane: pane.id) == nil, session.isRPC == rpc else {
                throw TerminalSessionStoreError.paneUnavailable(pane.id)
            }
            let cwd = AgentLaunch.resolvedCwd(pane.cwd)
            guard rpc else { throw TerminalSessionStoreError.paneUnavailable(pane.id) }
            var spawn = agentSpawn(agent, cwd: cwd, session: session)
            spawn.isAutomation = isAutomation
            spawn.requiredHistoryEntryID = requiredHistoryEntryID
            spawn.specKit = true
            spawn.stillWanted = { [unowned self] in
                ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: agent.id)
                    && session.sessionID == nil && liveBinding(forPane: pane.id) == nil
            }
            let spawned: SessionInfo?
            do { spawned = try await server.spawnAgent(spawn) }
            catch let refused as AgentSpawnRefused { throw AgentStartFailure(message: refused.description) }
            guard let info = spawned else { throw TerminalSessionStoreError.paneUnavailable(pane.id) }
            createdSessionID = info.id
            aliveSessions.insert(info.id)
            // The host holds it until pi serves, so no snapshot shows the thread without it.
            if let openingPrompt { await server.sendOpeningPrompt(openingPrompt, sessionID: info.id) }
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: agent.id) else {
                throw TerminalSessionStoreError.paneUnavailable(pane.id)
            }
            try await persistBinding(
                pane: pane,
                session: session,
                sessionID: info.id,
                tabID: tab.id
            )
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: agent.id),
                  binding(forPane: pane.id) == info.id else {
                throw TerminalSessionStoreError.bindingFailed(
                    paneID: pane.id,
                    sessionID: info.id,
                    reason: "pane ownership changed after binding"
                )
            }
            try await adopt(session, sessionID: info.id)
            createdSessionID = nil
        } catch {
            if let createdSessionID {
                await discardCreatedSession(
                    createdSessionID,
                    paneID: pane.id,
                    session: session
                )
            }
            if sessions[pane.id] === session {
                session.phase = .failed(String(describing: error))
            }
            throw error
        }
    }

    private func ensureBootstrapped() async throws {
        if bootstrapTask == nil {
            bootstrapTask = Task { try await bootstrap() }
        }
        do {
            try await bootstrapTask!.value
        } catch {
            bootstrapTask = nil
            throw error
        }
    }

    /// Adopt the persisted workspace. All prior sessions are dead (they died
    /// with the previous app run), so `aliveSessions` is whatever the server
    /// holds right now — normally empty.
    private func bootstrap() async throws {
        serverState = server.state
        aliveSessions = Set(await server.listSessions().filter(\.isAlive).map(\.id))
        // Read again: adopting the snapshot from before the await would roll back anything
        // committed meanwhile (a space added while the app starts).
        let state = server.state
        serverState = state
        onStateChanged?(state)
    }

    private func binding(forPane paneID: PaneID) -> SessionID? {
        guard let state = serverState else { return nil }
        for tab in state.tabs {
            if let leaf = tab.layout.leaf(withID: paneID) {
                return leaf.sessionID
            }
        }
        return nil
    }

    /// A persisted binding to a session that died with a previous app run is
    /// no binding at all — restored layouts carry last run's sessionID in
    /// every leaf, and those panes must respawn fresh, not be rejected.
    private func liveBinding(forPane paneID: PaneID) -> SessionID? {
        guard let bound = binding(forPane: paneID), aliveSessions.contains(bound) else { return nil }
        return bound
    }

    /// Poll `ownsPane` briefly — optimistic layout writes commit through a
    /// serialized queue, so a just-split pane becomes owned within one queue
    /// turn unless it was genuinely removed.
    private func waitForOwnership(
        _ session: PaneSession,
        pane: LeafPane,
        tabID: TabID,
        expectedAgentID: AgentID?
    ) async -> Bool {
        let deadline = ContinuousClock.now + ownershipTimeout
        while true {
            if ownsPane(session, pane: pane, tabID: tabID, expectedAgentID: expectedAgentID) { return true }
            guard ContinuousClock.now < deadline, sessions[pane.id] === session else { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    private func ownsPane(
        _ session: PaneSession,
        pane: LeafPane,
        tabID: TabID,
        expectedAgentID: AgentID? = nil
    ) -> Bool {
        guard sessions[pane.id] === session else { return false }
        let current = server.state
        serverState = current
        guard let tab = current.tabs.first(where: { $0.id == tabID }),
              let leaf = tab.layout.leaf(withID: pane.id),
              leaf.cwd == pane.cwd,
              leaf.agentID == pane.agentID else { return false }
        if let expectedAgentID {
            guard let agent = current.agents.first(where: { $0.id == expectedAgentID }),
                  agent.tabID == tabID,
                  agent.paneID == pane.id else { return false }
        }
        return true
    }

    private func persistBinding(
        pane: LeafPane,
        session: PaneSession,
        sessionID: SessionID,
        tabID: TabID
    ) async throws {
        guard ownsPane(session, pane: pane, tabID: tabID, expectedAgentID: pane.agentID) else {
            throw TerminalSessionStoreError.paneUnavailable(pane.id)
        }
        do {
            // Bind only this leaf. Replacing a whole layout here can erase a
            // split that was committed while the session was starting.
            try await server.updatePaneSession(tabID: tabID, paneID: pane.id, sessionID: sessionID)
        } catch {
            throw TerminalSessionStoreError.bindingFailed(
                paneID: pane.id,
                sessionID: sessionID,
                reason: String(describing: error)
            )
        }
        try didBind(pane: pane, session: session, sessionID: sessionID, tabID: tabID)
    }

    /// After the server bound `sessionID` to the pane: adopt the committed layout, and check the
    /// pane is still this session's.
    private func didBind(pane: LeafPane, session: PaneSession, sessionID: SessionID, tabID: TabID) throws {
        let committed = server.state
        serverState = committed
        if let layout = committed.tabs.first(where: { $0.id == tabID })?.layout {
            onTabLayoutChanged?(tabID, layout)
        }
        guard ownsPane(session, pane: pane, tabID: tabID, expectedAgentID: pane.agentID),
              binding(forPane: pane.id) == sessionID else {
            throw TerminalSessionStoreError.bindingFailed(
                paneID: pane.id,
                sessionID: sessionID,
                reason: "pane ownership changed while binding"
            )
        }
    }

    private func discardCreatedSession(
        _ sessionID: SessionID,
        paneID: PaneID,
        session: PaneSession
    ) async {
        if sessions[paneID] === session {
            sessions.removeValue(forKey: paneID)
        }
        if paneBySession[sessionID] == paneID {
            paneBySession.removeValue(forKey: sessionID)
        }
        aliveSessions.remove(sessionID)
        if pendingExits.removeValue(forKey: sessionID) != nil {
            handledExits.insert(sessionID)
        }
        detachedSessionIDs.insert(sessionID)
        server.killSession(sessionID)

        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            guard let info = await server.sessionInfo(sessionID: sessionID) else { break }
            if !info.isAlive { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        await server.retireSession(sessionID: sessionID)
        detachedSessionIDs.remove(sessionID)
        handledExits.insert(sessionID)
    }

    /// Spawns the pane's process, or adopts the live one already bound to it. True only when it
    /// spawned one. `checksResume`: an agent's pi that doesn't find the conversation it resumes is
    /// stopped (`SessionServer.createSession(params:resuming:)`); Retry's Start new conversation
    /// turns it off.
    @discardableResult
    private func start(_ session: PaneSession, pane: LeafPane, tab: Tab, checksResume: Bool = true) async -> Bool {
        var createdSessionID: SessionID?
        do {
            try await ensureBootstrapped()

            // A freshly split pane renders (and spawns) before the queued
            // layout write commits, and ownsPane reads committed server
            // state — so give the persistence queue a moment before ruling
            // the pane out. Failing here strands the pane in "session
            // unavailable" with no retry.
            guard await waitForOwnership(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID) else {
                throw TerminalSessionStoreError.paneUnavailable(session.paneID)
            }

            if let bound = binding(forPane: session.paneID), aliveSessions.contains(bound) {
                try await adopt(session, sessionID: bound)
                return false
            }

            // The agent-creation flow owns this pane's spawn; it will adopt
            // this same PaneSession. Spawning here too put two pi processes
            // in one pane.
            if reservedPanes.contains(session.paneID) { return false }
            if let agentID = pane.agentID, server.state.isMissionAgent(agentID) {
                // Mission dispatch creates new attempt sessions explicitly. Restoring or viewing
                // an old attempt must never restart its tools or replay its opening prompt.
                session.phase = .stopped
                onAgentStopped?(agentID, nil, true)
                return false
            }

            // No live binding: an agent's primary pane comes back as `pi --mode rpc` (rebuilt
            // from the agent record, resuming its pi session), everything else as a login
            // shell in the leaf cwd.
            let cwd = AgentLaunch.resolvedCwd(pane.cwd)
            let info: SessionInfo
            if let agentID = pane.agentID,
               let agent = serverState?.agents.first(where: { $0.id == agentID }) {
                guard session.isRPC, isRPCPane(pane, agent: agent) else {
                    throw TerminalSessionStoreError.paneUnavailable(session.paneID)
                }
                if agent.worktreePath.map(AgentLaunch.resolvedCwd) == cwd {
                    session.startupLocation = .worktree
                } else if serverState?.spaces.first(where: { $0.id == agent.spaceID }).map({ AgentLaunch.resolvedCwd($0.path) }) == cwd {
                    session.startupLocation = .space
                } else {
                    session.startupLocation = .other
                }
                var spawn = agentSpawn(agent, cwd: cwd, session: session)
                spawn.checksResume = checksResume
                spawn.stillWanted = { [unowned self] in
                    ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID)
                        && session.sessionID == nil && liveBinding(forPane: session.paneID) == nil
                }
                // Respawn after relaunch, bound to its pane by the server: an agent that was never
                // prompted has no session file yet, so the spawn seeds one before pi looks for it.
                let spawned: SessionInfo?
                do { spawned = try await server.respawnAgent(spawn) }
                catch let refused as PaneBindingFailed {
                    createdSessionID = refused.sessionID
                    throw TerminalSessionStoreError.bindingFailed(paneID: refused.paneID, sessionID: refused.sessionID, reason: refused.reason)
                }
                guard let spawned else { throw TerminalSessionStoreError.paneUnavailable(session.paneID) }
                createdSessionID = spawned.id
                aliveSessions.insert(spawned.id)
                try didBind(pane: pane, session: session, sessionID: spawned.id, tabID: tab.id)
                try await adopt(session, sessionID: spawned.id)
                createdSessionID = nil
                return true
            } else {
                let command = ShellIntegration.command(shell: AppSettings.shared.shellCommand)
                if !session.isRPC { await session.awaitGrid(timeoutNanoseconds: Self.gridWaitNanoseconds) }
                guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID),
                      session.sessionID == nil,
                      liveBinding(forPane: session.paneID) == nil else {
                    throw TerminalSessionStoreError.paneUnavailable(session.paneID)
                }
                let releaseCheckout = try reserveCheckoutForLaunch?(cwd)
                defer { releaseCheckout?() }
                info = try await server.createSession(
                    params: CreateSessionParams(
                        cwd: cwd,
                        command: command.argv,
                        cols: session.lastCols,
                        rows: session.lastRows,
                        env: command.env.isEmpty ? nil : command.env,
                        runtime: session.isRPC ? .rpc : .pty
                    )
                )
            }
            createdSessionID = info.id
            aliveSessions.insert(info.id)
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID) else {
                throw TerminalSessionStoreError.paneUnavailable(session.paneID)
            }
            try await persistBinding(
                pane: pane,
                session: session,
                sessionID: info.id,
                tabID: tab.id
            )
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID),
                  binding(forPane: session.paneID) == info.id else {
                throw TerminalSessionStoreError.bindingFailed(
                    paneID: session.paneID,
                    sessionID: info.id,
                    reason: "pane ownership changed after binding"
                )
            }
            try await adopt(session, sessionID: info.id)
            createdSessionID = nil
            return true
        } catch {
            if let createdSessionID {
                await discardCreatedSession(
                    createdSessionID,
                    paneID: session.paneID,
                    session: session
                )
            }
            if sessions[session.paneID] === session {
                session.phase = .failed(String(describing: error))
            }
            return false
        }
    }

    /// Bind a pane to a server session. Kept internal so lifecycle tests can
    /// exercise the short-lived-process handoff without constructing SwiftUI.
    func adopt(
        _ session: PaneSession,
        sessionID: SessionID
    ) async throws {
        session.sessionID = sessionID
        session.stopOutput()
        sessions[session.paneID] = session
        paneBySession[sessionID] = session.paneID
        detachedSessionIDs.remove(sessionID)

        if let earlyExit = pendingExits.removeValue(forKey: sessionID) {
            aliveSessions.remove(sessionID)
            processExit(sessionID: sessionID, exit: earlyExit)
            return
        }

        guard let info = await server.sessionInfo(sessionID: sessionID), info.isAlive else {
            aliveSessions.remove(sessionID)
            // An agent's pi that died meanwhile: its exit is on its way to the main queue (the
            // server reports every one) and says whether the agent stays, so it decides.
            if session.isRPC, !handledExits.contains(sessionID) { return }
            processExit(sessionID: sessionID, exit: SessionExit(code: nil))
            return
        }

        // No terminal: the binding itself is the whole attachment.
        if session.isRPC {
            session.phase = .live
            return
        }

        if session.hasReportedGrid {
            server.reportLocalViewport(
                sessionID: sessionID,
                cols: session.lastCols,
                rows: session.lastRows
            )
        }

        attachIfNeeded(session, sessionID: sessionID)
    }

    private func attachIfNeeded(_ session: PaneSession, sessionID: SessionID) {
        guard sessions[session.paneID] === session,
              session.sessionID == sessionID,
              let generation = session.surfaceGeneration else { return }
        if case .exited = session.phase { return }
        guard let attempt = session.beginAttachAttempt() else { return }
        // Submit both operations before yielding the main actor. A disappearance
        // must enqueue its detach after this attach, never before it.
        server.reportLocalViewport(sessionID: sessionID, cols: session.lastCols, rows: session.lastRows)
        server.attachSnapshot(sessionID: sessionID, replay: true) { [weak self, weak session] result in
            guard let self, let session,
                  self.sessions[session.paneID] === session,
                  session.sessionID == sessionID,
                  session.activeAttachAttempt == attempt else { return }
            if case .exited = session.phase { return }
            switch result {
            case .success(let snapshot):
                _ = session.goLive(
                    replay: snapshot.replay,
                    watermark: snapshot.outputSequence,
                    attempt: attempt,
                    generation: generation
                )
            case .failure(let error):
                session.failAttach(attempt: attempt, phase: .failed(String(describing: error)))
            }
        }
    }

    /// An agent's spawn from this store: the app's settings and MCP, the pane's grid, its checkout hold.
    private func agentSpawn(_ agent: Agent, cwd: String, session: PaneSession) -> AgentSpawn {
        var spawn = AgentSpawn(agent: agent, cwd: cwd, settings: AppSettings.shared.agentLaunch)
        spawn.takeModelOverride = { [unowned self] in modelOverrides.removeValue(forKey: agent.id) }
        spawn.cols = session.lastCols
        spawn.rows = session.lastRows
        spawn.mcp = { [mcpLaunch] parent, agent, cwd, state, verifiedWorktree in
            try mcpLaunch()?.sharingProject(parent, agent: agent, cwd: cwd, state: state, verifiedWorktree: verifiedWorktree)
        }
        spawn.reserveCheckout = reserveCheckoutForLaunch
        return spawn
    }
}
