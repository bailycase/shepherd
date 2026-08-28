import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
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
/// app), so each pane respawns fresh — pi for agent panes, a login shell for
/// everything else.
@MainActor
final class TerminalSessionStore: ObservableObject {

    @MainActor
    final class PaneSession: ObservableObject {
        enum Phase: Equatable {
            case connecting
            case live
            case failed(String)
            case exited(Int32?)
        }

        let paneID: PaneID
        let terminal: AppTerminalModel
        @Published var phase: Phase = .connecting
        var sessionID: SessionID?
        struct BufferedOutput {
            let data: Data
            let sequence: UInt64
        }

        /// Output that races the attach replay. Sequence watermarks decide
        /// which chunks the snapshot already contains.
        fileprivate var buffered: [BufferedOutput] = []
        /// Set while an initial attach or surface replacement is in flight.
        fileprivate var attachRequested = false
        private var nextAttachAttempt: UInt64 = 0
        fileprivate var activeAttachAttempt: UInt64?
        /// Last grid the surface reported via onResize; the PTY keeps this
        /// size. Defaults match createSession's fallback 80×24.
        fileprivate(set) var lastCols = 80
        fileprivate(set) var lastRows = 24
        /// True after Ghostty reports this surface's actual grid at least once.
        fileprivate var hasReportedGrid = false
        /// Suspended `awaitGrid` callers, resumed by the first grid report (or
        /// by its timeout).
        private var gridWaiters: [CheckedContinuation<Void, Never>] = []

        init(paneID: PaneID) {
            self.paneID = paneID
            self.terminal = AppTerminalModel(
                fontSize: AppSettings.shared.terminalFontSize,
                fontFamily: AppSettings.shared.resolvedTerminalFontFamily,
                terminal: ThemeManager.shared.current.terminal,
                // Rebound app shortcuts must fall through a focused terminal
                // exactly like the built-in ones.
                extraUnbinds: KeybindingsStore.shared.customGhosttyUnbinds
            )
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

        func receive(_ data: Data, sequence: UInt64) {
            if case .live = phase, activeAttachAttempt == nil {
                terminal.feed(data)
            } else {
                buffered.append(BufferedOutput(data: data, sequence: sequence))
            }
        }

        func beginAttachAttempt(replacing: Bool = false) -> UInt64? {
            guard replacing || !attachRequested else { return nil }
            nextAttachAttempt &+= 1
            attachRequested = true
            activeAttachAttempt = nextAttachAttempt
            return nextAttachAttempt
        }

        /// Go live on an attach snapshot.
        ///
        /// The snapshot is the whole screen as of the attach turn, so output
        /// that arrived *before* it is already represented and must be
        /// dropped, not fed again — replaying it drew pi's splash screen a
        /// second time, with two prompt boxes.
        ///
        /// `buffered` may hold bytes delivered before the snapshot and after
        /// it while the attach was in flight. The server watermark, rather
        /// than callback timing, decides which bytes the replay represents.
        @discardableResult
        fileprivate func goLive(
            replay: Data,
            watermark: UInt64,
            attempt: UInt64
        ) -> Bool {
            guard activeAttachAttempt == attempt else { return false }
            let fresh = Self.output(after: watermark, from: buffered)
            buffered.removeAll()
            attachRequested = false
            activeAttachAttempt = nil
            phase = .live
            if !replay.isEmpty {
                terminal.feed(replay)
            }
            for chunk in fresh {
                terminal.feed(chunk.data)
            }
            return true
        }

        @discardableResult
        fileprivate func replaceWithReplay(
            _ replay: Data,
            watermark: UInt64,
            attempt: UInt64,
            generation: UInt64
        ) -> Bool {
            guard activeAttachAttempt == attempt else { return false }
            guard terminal.replaceWithReplay(replay, generation: generation) else { return false }
            let fresh = Self.output(after: watermark, from: buffered)
            buffered.removeAll()
            attachRequested = false
            activeAttachAttempt = nil
            for chunk in fresh {
                terminal.feed(chunk.data)
            }
            return true
        }

        static func output(after watermark: UInt64, from buffered: [BufferedOutput]) -> [BufferedOutput] {
            buffered.filter { $0.sequence > watermark }
        }

        fileprivate func failAttach(attempt: UInt64, phase: Phase? = nil) {
            guard activeAttachAttempt == attempt else { return }
            attachRequested = false
            activeAttachAttempt = nil
            if let phase { self.phase = phase }
        }
    }

    /// How long a spawn waits for its surface to report a grid before falling
    /// back to 80×24. Layout normally lands within a frame or two; this only
    /// bounds the pathological case.
    static let gridWaitNanoseconds: UInt64 = 400_000_000

    /// The in-process server. Owned by the app (one per process).
    let server: SessionServer
    private var sessions: [PaneID: PaneSession] = [:]
    private var paneBySession: [SessionID: PaneID] = [:]
    private struct PendingExit {
        let code: Int32?
    }

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
    /// Fired on server agentStatus events (from the pi status extension).
    var onAgentStatus: ((AgentID, AgentStatus) -> Void)?
    /// Fired on subagents-extension child-run publishes (full replace).
    var onAgentChildren: ((AgentID, [ChildRun]) -> Void)?
    /// Fired when an agent's notify tool asks for a system notification.
    var onNotify: ((AgentID, String, String) -> Void)?
    /// Fired when a pane's process exits, after the local session is marked
    /// exited and before it is dropped from the store.
    var onPaneSessionExited: ((PaneID) -> Void)?

    init(server: SessionServer) {
        self.server = server
        server.onSequencedOutput = { [weak self] sessionID, data, sequence in
            self?.session(forSessionID: sessionID)?.receive(data, sequence: sequence)
        }
        server.onSessionExited = { [weak self] sessionID, exitCode in
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
                self.pendingExits[sessionID] = PendingExit(code: exitCode)
                return
            }
            self.processExit(sessionID: sessionID, exitCode: exitCode)
        }
        server.onStateChanged = { [weak self] state in
            self?.serverState = state
            self?.onStateChanged?(state)
        }
        server.onAgentStatus = { [weak self] agentID, status in
            self?.onAgentStatus?(agentID, status)
        }
        server.onAgentChildren = { [weak self] agentID, children in
            self?.onAgentChildren?(agentID, children)
        }
        server.onNotify = { [weak self] agentID, title, body in
            self?.onNotify?(agentID, title, body)
        }
    }

    /// Kick off bootstrap without waiting for a pane to appear.
    func warmUp() {
        Task { try? await ensureBootstrapped() }
    }

    /// Recolor every live local surface in place. Ghostty applies theme
    /// configuration without replacing the NSView, so no detach or replay is
    /// involved and Pi's simultaneous repaint cannot race a screen snapshot.
    func updateAppearance(_ terminal: ShepherdTheme.Terminal) {
        for session in sessions.values {
            session.terminal.updateAppearance(terminal)
        }
    }

    /// Reconfigure every live local surface in place (terminal font,
    /// keybind unbinds). Like updateAppearance, ghostty applies the config
    /// without replacing the NSView — no detach, no replay, no blank pane.
    func updateSurfaceConfiguration() {
        for session in sessions.values {
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
        for session in sessions.values {
            if let sessionID = session.sessionID {
                server.detach(sessionID: sessionID)
            }
        }
        sessions.removeAll()
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
        if let sessionID = session.sessionID {
            paneBySession.removeValue(forKey: sessionID)
            detachedSessionIDs.insert(sessionID)
            server.detach(sessionID: sessionID)
        }
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
    private func processExit(sessionID: SessionID, exitCode: Int32?) {
        guard !handledExits.contains(sessionID) else { return }
        guard let paneID = paneBySession[sessionID] else {
            pendingExits[sessionID] = PendingExit(code: exitCode)
            return
        }
        handledExits.insert(sessionID)
        sessions[paneID]?.phase = .exited(exitCode)
        onPaneSessionExited?(paneID)
        sessions.removeValue(forKey: paneID)
        paneBySession.removeValue(forKey: sessionID)
        detachedSessionIDs.remove(sessionID)
        Task { [weak self] in
            await self?.server.retireSession(sessionID: sessionID)
        }
    }

    /// SwiftUI structural changes (splits collapsing, panes moving in the
    /// tree) recreate the ghostty NSView; the fresh surface starts blank, so
    /// re-pull the server's current-screen replay into it.
    private func makeSession(paneID: PaneID) -> PaneSession {
        let session = PaneSession(paneID: paneID)
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
        session.terminal.onSurfaceReplaced = { [weak self, weak session] generation in
            guard let self, let session else { return }
            self.resyncSurface(session, generation: generation)
        }
        return session
    }

    private func resyncSurface(_ session: PaneSession, generation: UInt64) {
        guard let sessionID = session.sessionID else { return }
        guard case .live = session.phase else {
            // Initial attachment already owns the authoritative replay; only
            // release this replacement so goLive can feed it when ready.
            _ = session.terminal.replaceWithReplay(Data(), generation: generation)
            return
        }
        guard let attempt = session.beginAttachAttempt(replacing: true) else { return }
        Task {
            // Size-sync before the snapshot so it serializes at this surface's
            // width (fire-and-forget resize precedes attach; both go through
            // the server queue in order).
            server.reportLocalViewport(sessionID: sessionID, cols: session.lastCols, rows: session.lastRows)
            guard let snapshot = try? await server.attachSnapshot(sessionID: sessionID, replay: true) else {
                session.failAttach(attempt: attempt)
                return
            }
            guard self.sessions[session.paneID] === session,
                  session.sessionID == sessionID,
                  session.phase == .live else { return }
            // Ignore a replay that raced with another structural replacement.
            _ = session.replaceWithReplay(
                snapshot.replay,
                watermark: snapshot.outputSequence,
                attempt: attempt,
                generation: generation
            )
        }
    }

    func session(for pane: LeafPane, in tab: Tab) -> PaneSession {
        if let existing = sessions[pane.id] {
            return existing
        }
        let session = makeSession(paneID: pane.id)
        sessions[pane.id] = session
        Task { await start(session, pane: pane, tab: tab) }
        return session
    }

    /// Spawn the pi session for a freshly created agent, bind it to its pane,
    /// and attach — so the pane view's `session(for:in:)` finds it live.
    func createAgentSession(pane: LeafPane, tab: Tab, agent: Agent, initialPrompt: String?, isAutomation: Bool = false) async throws {
        defer { reservedPanes.remove(pane.id) }
        try await ensureBootstrapped()
        guard let state = serverState,
              state.tabs.first(where: { $0.id == tab.id })?.layout.contains(pane.id) == true else {
            throw TerminalSessionStoreError.paneUnavailable(pane.id)
        }

        let session = sessions[pane.id] ?? makeSession(paneID: pane.id)
        sessions[pane.id] = session
        var createdSessionID: SessionID?
        do {
            guard session.sessionID == nil, liveBinding(forPane: pane.id) == nil else {
                throw TerminalSessionStoreError.paneUnavailable(pane.id)
            }
            let cwd = Self.resolvedCwd(pane.cwd)
            let command = try Self.agentCommand(for: agent, cwd: cwd, initialPrompt: initialPrompt, isAutomation: isAutomation)
            // Give pi a session to find, so --session-id does not warn.
            PiSessionFile.seedIfMissing(sessionID: agent.id.rawValue, cwd: cwd)
            // Spawn at the surface's real grid: pi paints its TUI once, at the
            // right size, instead of drawing at 80×24 and visibly reflowing on
            // the first resize.
            await session.awaitGrid(timeoutNanoseconds: Self.gridWaitNanoseconds)
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: agent.id),
                  session.sessionID == nil,
                  liveBinding(forPane: pane.id) == nil else {
                throw TerminalSessionStoreError.paneUnavailable(pane.id)
            }
            let info = try await server.createSession(
                params: CreateSessionParams(
                    cwd: cwd,
                    command: command.argv,
                    cols: session.lastCols,
                    rows: session.lastRows,
                    env: command.env.isEmpty ? nil : command.env
                )
            )
            createdSessionID = info.id
            aliveSessions.insert(info.id)
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
        let state = server.state
        serverState = state
        aliveSessions = Set(await server.listSessions().filter(\.isAlive).map(\.id))
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
        expectedAgentID: AgentID?,
        timeout: Duration = .seconds(3)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
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

    private func start(_ session: PaneSession, pane: LeafPane, tab: Tab) async {
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
                return
            }

            // The agent-creation flow owns this pane's spawn; it will adopt
            // this same PaneSession. Spawning here too put two pi processes
            // in one pane.
            if reservedPanes.contains(session.paneID) { return }

            // No live binding: agent leaves come back as pi (rebuilt from the
            // agent record), everything else as a login shell in the leaf cwd.
            let cwd = Self.resolvedCwd(pane.cwd)
            let command: SessionCommand
            if let agentID = pane.agentID,
               let agent = serverState?.agents.first(where: { $0.id == agentID }) {
                command = try Self.agentCommand(for: agent, cwd: cwd, initialPrompt: nil)
                // Respawn after relaunch: an agent that was never prompted has
                // no session file yet, so seed one before pi looks for it.
                PiSessionFile.seedIfMissing(sessionID: agent.id.rawValue, cwd: cwd)
            } else {
                command = SessionCommand(argv: AppSettings.shared.shellCommand, env: [:])
                // A global shell that was running something when the app
                // last quit restarts it: type the recorded command into the
                // fresh shell (visible and cancelable, not a hidden exec).
                if let restore = serverState?.tabs.first(where: {
                    $0.isShell && $0.layout.firstLeaf.id == pane.id
                })?.restoreCommand, !restore.isEmpty {
                    let paneID = session.paneID
                    Task { [weak self] in
                        guard let self else { return }
                        guard let sessionID = await self.awaitSession(forPane: paneID, timeout: .seconds(5)) else {
                            return
                        }
                        // A beat for the shell to print its prompt and
                        // install its own tty settings.
                        try? await Task.sleep(for: .milliseconds(500))
                        self.server.write(sessionID: sessionID, data: Data((restore + "\n").utf8))
                    }
                }
            }
            await session.awaitGrid(timeoutNanoseconds: Self.gridWaitNanoseconds)
            guard ownsPane(session, pane: pane, tabID: tab.id, expectedAgentID: pane.agentID),
                  session.sessionID == nil,
                  liveBinding(forPane: session.paneID) == nil else {
                throw TerminalSessionStoreError.paneUnavailable(session.paneID)
            }
            let info = try await server.createSession(
                params: CreateSessionParams(
                    cwd: cwd,
                    command: command.argv,
                    cols: session.lastCols,
                    rows: session.lastRows,
                    env: command.env.isEmpty ? nil : command.env
                )
            )
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
        }
    }

    /// Bind a pane to a server session. Kept internal so lifecycle tests can
    /// exercise the short-lived-process handoff without constructing SwiftUI.
    func adopt(
        _ session: PaneSession,
        sessionID: SessionID
    ) async throws {
        session.sessionID = sessionID
        session.attachRequested = false
        sessions[session.paneID] = session
        paneBySession[sessionID] = session.paneID
        detachedSessionIDs.remove(sessionID)

        if let earlyExit = pendingExits.removeValue(forKey: sessionID) {
            aliveSessions.remove(sessionID)
            processExit(sessionID: sessionID, exitCode: earlyExit.code)
            return
        }

        guard let info = await server.sessionInfo(sessionID: sessionID) else {
            aliveSessions.remove(sessionID)
            processExit(sessionID: sessionID, exitCode: nil)
            return
        }
        if !info.isAlive {
            aliveSessions.remove(sessionID)
            processExit(sessionID: sessionID, exitCode: nil)
            return
        }

        if session.hasReportedGrid {
            server.reportLocalViewport(
                sessionID: sessionID,
                cols: session.lastCols,
                rows: session.lastRows
            )
            attachIfNeeded(session, sessionID: sessionID)
        }

        // Fallback for surfaces that never lay out (or whose grid matches and
        // fires no resize): attach anyway after a short grace period.
        Task { [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, let session,
                  self.sessions[session.paneID] === session,
                  session.sessionID == sessionID else { return }
            self.attachIfNeeded(session, sessionID: sessionID)
        }
    }

    private func attachIfNeeded(_ session: PaneSession, sessionID: SessionID) {
        guard sessions[session.paneID] === session,
              session.sessionID == sessionID else { return }
        if case .exited = session.phase { return }
        guard let attempt = session.beginAttachAttempt() else { return }
        Task { [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let snapshot = try await self.server.attachSnapshot(sessionID: sessionID, replay: true)
                guard self.sessions[session.paneID] === session,
                      session.sessionID == sessionID else { return }
                if case .exited = session.phase { return }
                _ = session.goLive(
                    replay: snapshot.replay,
                    watermark: snapshot.outputSequence,
                    attempt: attempt
                )
            } catch {
                guard self.sessions[session.paneID] === session else { return }
                session.failAttach(attempt: attempt, phase: .failed(String(describing: error)))
            }
        }
    }

    private static func agentCommand(for agent: Agent, cwd: String, initialPrompt: String?, isAutomation: Bool = false) throws -> SessionCommand {
        let theme = ThemeManager.shared.current
        // Pass model/thinking only into a session pi has never written to.
        // Once pi owns the session it persists both (model_change /
        // thinking_level_change events) and restores them on resume; passing
        // the flags again would reset in-session changes on every relaunch.
        let sessionIsFresh = !PiSessionFile.hasRuntimeState(
            sessionID: agent.effectivePiSessionID,
            cwd: cwd
        )
        return StatusExtension.command(
            agentID: agent.id,
            piSessionID: agent.effectivePiSessionID,
            socketPath: ShepherdPaths.socketURL().path,
            extensionPath: try StatusExtension.installedPath(),
            themeExtensionPath: try ThemeExtension.installedPath(),
            panesExtensionPath: try PanesExtension.installedPath(),
            subagentsExtensionPath: try SubagentsExtension.installedPath(),
            // The namer loads whenever auto-naming is on: besides titling a
            // provisional agent from its opening prompt, it retitles on
            // /resume (pi session names are free; unnamed resumed sessions
            // cost one cheap-model call).
            namerExtensionPath: AppSettings.shared.autoNameAgents
                ? try NamerExtension.installedPath()
                : nil,
            needsName: Self.wantsNamer(for: agent, autoName: AppSettings.shared.autoNameAgents),
            isAutomation: isAutomation,
            piThemePath: try ShepherdPiTheme.installedPath(for: theme),
            piThemeName: ShepherdPiTheme.name,
            model: sessionIsFresh ? agent.model : nil,
            thinking: sessionIsFresh ? agent.thinkingLevel : nil,
            initialPrompt: initialPrompt
        )
    }

    /// An agent gets pi's namer only while its name is still provisional and
    /// the user has left auto-naming on.
    static func wantsNamer(for agent: Agent, autoName: Bool) -> Bool {
        !agent.nameIsFinal && autoName
    }

    static func resolvedCwd(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            return expanded
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
}
