import Foundation
import Observation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Terminals on the phone and iPad: one `MobileTerminalSession` per host session, attached
/// while its view is on screen, and each thread's panel state (shown, the chosen tab, maximized,
/// its height). The terminals and their shells are the host's; this never spawns or resizes
/// anything but through the host's own requests (attach, detach, input, resize, open and close).
///
/// It owns the `onOutput` and `onSessionExited` callbacks of every host's `RemoteHostClient`
/// (nothing else on iOS attaches terminals), wiring each new connection's client on its first
/// attach.
@MainActor
@Observable
final class MobileTerminals {
    static let shared = MobileTerminals()

    /// One thread's panel.
    struct Panel: Equatable {
        /// iPad: the panel is open under the thread.
        var shown = false
        /// The tab picked last; `TerminalPanel.selected` falls back when it closes.
        var chosenTab: PaneID?
        /// The panel fills the thread; the thread folds away until it is restored.
        var maximized = false
    }

    struct SessionKey: Hashable {
        var host: UUID
        var session: SessionID
    }

    private(set) var panels: [AgentRef: Panel] = [:]
    /// The panel's height on iPad, shared by every thread (`shepherd.ios.terminalHeight`).
    var panelHeight: CGFloat {
        didSet { if panelHeight != oldValue { defaults.set(Double(panelHeight), forKey: Self.heightKey) } }
    }
    /// Each thread's last terminal request that failed, for its panel to say so.
    var problems: [AgentRef: String] = [:]
    /// What each thread's terminals run, from its host (`RemoteAgentQuery.terminals`).
    private(set) var activity: [AgentRef: [PaneID: RemoteTerminalActivity]] = [:]
    /// Each session's news (`RemoteTerminalActivity.news`) when it was last on screen.
    private(set) var seen: [SessionKey: UInt64] = [:]

    /// Fixtures only: sessions show these screens and never attach, so a screenshot neither
    /// resizes nor types into a host's terminal.
    @ObservationIgnored var cannedScreens: [SessionID: Data]?
    /// Fixtures only: the tab whose close confirmation shows, as if its × was tapped. Nothing
    /// else sets it, so it never changes in the app.
    var cannedClose: PaneID?

    @ObservationIgnored private var sessions: [SessionKey: MobileTerminalSession] = [:]
    @ObservationIgnored private var wired: [UUID: ObjectIdentifier] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let heightKey = "shepherd.ios.terminalHeight"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.double(forKey: Self.heightKey)
        panelHeight = stored > 0 ? CGFloat(stored) : MobileLayout.terminalPanelHeight
    }

    func panel(_ ref: AgentRef) -> Panel { panels[ref] ?? Panel() }

    func update(_ ref: AgentRef, _ change: (inout Panel) -> Void) {
        var panel = panels[ref] ?? Panel()
        change(&panel)
        if panels[ref] != panel { panels[ref] = panel }
    }

    func choose(_ tab: TerminalPanelTab, in ref: AgentRef) {
        update(ref) { $0.chosenTab = tab.id }
    }

    // MARK: Activity

    /// Asks the host what the thread's terminals run, every few seconds while the caller runs
    /// (the thread or its terminal on screen). Hosts without `terminal.activity.v1` are not asked.
    func watchActivity(_ ref: AgentRef, client: RemoteHostClient) async {
        guard client.capabilities.contains(RemoteProtocol.terminalActivityCapability) else { return }
        while !Task.isCancelled {
            if case .terminals(let rows)? = try? await client.agentQuery(agentID: ref.agent, query: .terminals), !Task.isCancelled {
                let byPane = Dictionary(rows.map { ($0.paneID, $0) }, uniquingKeysWith: { first, _ in first })
                if activity[ref] != byPane { activity[ref] = byPane }
                for row in rows where seen[SessionKey(host: ref.host, session: row.sessionID)] == nil {
                    // Output from before the first look is not news.
                    seen[SessionKey(host: ref.host, session: row.sessionID)] = row.news
                }
            }
            try? await Task.sleep(for: Self.activityInterval)
        }
    }

    static let activityInterval: Duration = .seconds(2)

    /// The tab's output is on screen now: nothing in it is unseen.
    func markSeen(_ ref: AgentRef, sessions: [SessionID]) {
        for id in sessions {
            guard let sequence = activity[ref]?.values.first(where: { $0.sessionID == id })?.news else { continue }
            let key = SessionKey(host: ref.host, session: id)
            if seen[key] != sequence { seen[key] = sequence }
        }
    }

    /// A session printed since it was last on screen.
    func hasUnseen(_ ref: AgentRef, session id: SessionID) -> Bool {
        guard let row = activity[ref]?.values.first(where: { $0.sessionID == id }),
              let seen = seen[SessionKey(host: ref.host, session: id)] else { return false }
        return row.news > seen
    }

    // MARK: Sessions

    /// The session for a pane's host session, made on first use and kept while the app runs so a
    /// tab shown again keeps its screen until the host's replay redraws it.
    func session(host: UUID, id: SessionID) -> MobileTerminalSession {
        let key = SessionKey(host: host, session: id)
        if let session = sessions[key] { return session }
        let session = MobileTerminalSession(key: key)
        sessions[key] = session
        return session
    }

    /// The session if one was made; reading a tab's state never makes one.
    func existingSession(host: UUID, id: SessionID) -> MobileTerminalSession? {
        sessions[SessionKey(host: host, session: id)]
    }

    /// Routes a connection's pushed output to its sessions. Called before every attach; a client
    /// already wired is left alone.
    func wire(_ client: RemoteHostClient, host: UUID) {
        let identity = ObjectIdentifier(client)
        guard wired[host] != identity else { return }
        wired[host] = identity
        client.onOutput = { [weak self] id, data in
            MainActor.assumeIsolated {
                guard let self, self.wired[host] == identity else { return }
                self.sessions[SessionKey(host: host, session: id)]?.receive(data)
            }
        }
        client.onSessionExited = { [weak self] id, code in
            MainActor.assumeIsolated {
                guard let self, self.wired[host] == identity else { return }
                self.sessions[SessionKey(host: host, session: id)]?.exited(code)
            }
        }
    }

    /// Drops the sessions the host no longer lists, and every session of a host that is gone.
    func prune(host: UUID, live: Set<SessionID>) {
        for (key, session) in sessions where key.host == host && !live.contains(key.session) {
            session.release()
            sessions[key] = nil
        }
    }

    func forget(host: UUID) {
        prune(host: host, live: [])
        wired[host] = nil
        for ref in panels.keys where ref.host == host { panels[ref] = nil }
        for ref in activity.keys where ref.host == host { activity[ref] = nil }
        for ref in problems.keys where ref.host == host { problems[ref] = nil }
        for key in seen.keys where key.host == host { seen[key] = nil }
    }

    // MARK: Terminal requests

    /// + in the tab bar, and the thread's options with no terminal yet: a new terminal under the
    /// thread, which the host makes a tab of its own. The request names the thread, as it always
    /// has: a current host opens a tab whatever it is told, an older one splits it to make one.
    /// The panel shows on the new terminal once the host has made it; a failure shows the panel's
    /// banner while it is up, and otherwise only a haptic, so an empty panel is never drawn.
    func newTab(_ ref: AgentRef, layout: PaneNode, thread: PaneID?, client: RemoteHostClient) async {
        let anchor = TerminalPanel.newTabAnchor(in: layout, thread: thread)
        do {
            let opened = try await client.openPane(agentID: ref.agent, relativeTo: anchor.pane, axis: anchor.axis)
            update(ref) {
                $0.shown = true
                $0.chosenTab = opened
            }
        } catch {
            problems[ref] = Self.message(error, doing: "open a terminal")
            if !panel(ref).shown { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
    }

    /// Closes a terminal on the host, which kills its shell. It refuses the thread's own.
    func close(_ ref: AgentRef, terminal: PaneID, client: RemoteHostClient) async {
        do {
            try await client.closePane(agentID: ref.agent, paneID: terminal)
        } catch {
            problems[ref] = Self.message(error, doing: "close the terminal")
        }
    }

    static func message(_ error: Error, doing action: String) -> String {
        if case RemoteHostClientError.rejected(let code, let message) = error {
            switch code {
            case "unsupported": return "Update Shepherd on the host to \(action) here."
            case "not_closable": return "An agent's own thread can't be closed."
            default: return message
            }
        }
        return "Couldn't \(action): \(error)"
    }
}

/// One host terminal session shown here: its SwiftTerm view, and its attachment to the host
/// (`RemoteTerminalLink`). Views observe the phase, the title and whether it has the keyboard;
/// the transport and the view are unobserved.
@MainActor
@Observable
final class MobileTerminalSession {
    let key: MobileTerminals.SessionKey
    private(set) var phase: RemoteTerminalLink.Phase = .detached
    /// What the shell calls itself (its OSC title), once it has said.
    private(set) var title: String?
    /// The terminal has the keyboard: the key row shows.
    var focused = false
    /// The pane view whose window shows the screen. A UIView lives in one window, so when two
    /// iPad windows show the same thread, the first to appear keeps it until it leaves.
    private(set) var viewer: UUID?

    /// The live view, made by `TerminalSurface` and kept here across remounts.
    @ObservationIgnored var surface: TerminalSurfaceView?
    @ObservationIgnored private var link = RemoteTerminalLink()
    @ObservationIgnored private weak var client: RemoteHostClient?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var holds = 0
    @ObservationIgnored private var letGo: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// Fixtures: the screen this session shows instead of attaching.
    var canned: Data? { MobileTerminals.shared.cannedScreens?[key.session] }
    /// Ctrl and ⌥ latched from the key row for the next key.
    var control = false
    var option = false

    /// Output settles this long before a new grid goes to the host: a rotation or a drag reports
    /// a grid per frame, and each would redraw the shell.
    static let settleDelay: Duration = .milliseconds(120)
    static let detachGrace: Duration = .seconds(1)

    init(key: MobileTerminals.SessionKey) {
        self.key = key
    }

    var isCanned: Bool { canned != nil }

    /// Keeps the session attached through `client` while the caller runs (its view is on screen,
    /// the app active, the host connected); detaches when the last holder leaves.
    func hold(_ client: RemoteHostClient) async {
        guard canned == nil else { return }
        if self.client !== client {
            // A new connection: the old one's attachment died with it.
            link.disconnected()
            sync()
        }
        self.client = client
        MobileTerminals.shared.wire(client, host: key.host)
        holds += 1
        letGo?.cancel()
        perform(link.want(true))
        // Cancelled when the view leaves or the connection changes.
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        holds -= 1
        guard holds == 0 else { return }
        retry?.cancel()
        // A view remade in place (a rotation) holds again at once: detach only
        // once nothing has for a moment, so it keeps its attachment instead of a fresh replay.
        letGo = Task { [weak self] in
            try? await Task.sleep(for: Self.detachGrace)
            guard !Task.isCancelled, let self, self.holds == 0 else { return }
            self.perform(self.link.want(false))
        }
    }

    func claim(_ view: UUID) {
        if viewer == nil { viewer = view }
    }

    func letGo(_ view: UUID) {
        if viewer == view { viewer = nil }
    }

    /// The view laid out at a grid; the host hears it once it settles.
    func noteGrid(cols: Int, rows: Int) {
        guard canned == nil else { return }
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let self else { return }
            self.perform(self.link.noteGrid(cols: cols, rows: rows))
        }
    }

    func receive(_ data: Data) {
        guard link.acceptsOutput else { return }
        surface?.feed(data)
    }

    func exited(_ code: Int32?) {
        link.exited(code)
        sync()
    }

    func titleChanged(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, self.title != trimmed { self.title = trimmed }
    }

    /// Keystrokes from the view or the key row. Nothing is typed into a canned screen or an exited
    /// session.
    func send(_ bytes: [UInt8]) {
        guard canned == nil, !bytes.isEmpty, let client else { return }
        if case .exited = phase { return }
        client.write(sessionID: key.session, data: Data(bytes))
    }

    /// A key-row key: a modifier latches, anything else is sent with the latched modifiers.
    func press(_ key: TerminalKey) {
        switch key {
        case .control: control.toggle()
        case .option: option.toggle()
        default:
            let applicationCursor = surface?.applicationCursor ?? false
            send(key.bytes(applicationCursor: applicationCursor, control: control, option: option))
            if control { control = false }
            if option { option = false }
        }
        surface?.latch(control: control, option: option)
    }

    /// The host dropped the session from its layout.
    func release() {
        settle?.cancel()
        letGo?.cancel()
        retry?.cancel()
        if link.acceptsOutput { client?.detach(sessionID: key.session) }
        surface = nil
    }

    private func perform(_ commands: [RemoteTerminalLink.Command]) {
        sync()
        guard let client else { return }
        let id = key.session
        for command in commands {
            switch command {
            case .attach(let cols, let rows):
                // The host replays its screen: start from a clean one.
                surface?.reset()
                let attempt = link.attempt
                Task { [weak self] in
                    do {
                        _ = try await client.attach(sessionID: id, cols: cols, rows: rows)
                        self?.link.attached(attempt: attempt)
                    } catch {
                        if let self, let delay = self.link.attachFailed(Self.reason(error), attempt: attempt) {
                            self.retry(after: delay, attempt: attempt)
                        }
                    }
                    self?.sync()
                }
            case .resize(let cols, let rows):
                client.resize(sessionID: id, cols: cols, rows: rows)
            case .detach:
                client.detach(sessionID: id)
            }
        }
    }

    /// A refused attach is asked again while the pane stays on screen: a host that just
    /// relaunched may not serve its session yet.
    private func retry(after delay: Duration, attempt: Int) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.holds > 0 else { return }
            self.perform(self.link.retry(attempt: attempt))
        }
    }

    private func sync() {
        if phase != link.phase { phase = link.phase }
    }

    private static func reason(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(let code, _) = error, code == "no_such_session" { return "not running on the host" }
        return String(describing: error)
    }
}
