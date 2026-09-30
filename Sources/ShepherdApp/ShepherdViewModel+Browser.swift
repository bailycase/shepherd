import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// A local thread's Browser (DESIGN.md › Side pane › Browser): what its page asks of the app.
/// The page itself is `BrowserSession` (`BrowserHost.swift`).
extension ShepherdViewModel {
    /// Reads the dev servers the thread's folder offers, once per session, off the main thread. A
    /// remote thread's are read on its host, which can answer only while it is connected: asked
    /// again when the pane shows and when the connection comes back, until it does.
    func loadDevServers(_ session: BrowserSession) {
        guard session.devServers == nil else { return }
        if let remote = session.remote {
            Task { [weak session] in
                guard let found = await remote.devServers() else { return }
                if session?.devServers == nil { session?.devServers = found }
            }
            return
        }
        guard let agent = state.agents.first(where: { $0.id == session.agentID }) else { return }
        let root = URL(fileURLWithPath: agentCwd(agent), isDirectory: true)
        Task { [weak session] in
            let found = await Task.detached(priority: .utility) { DevServerDiscovery.find(in: root) }.value
            if session?.devServers == nil { session?.devServers = found }
        }
    }

    /// Start: runs the script in a new terminal pane of the thread's layout, and opens its page
    /// once it answers (when the port is known).
    func startDevServer(_ server: DevServer, in session: BrowserSession) {
        // On another Mac's host: the command runs in a new terminal pane of the thread's layout
        // there, and the page opens through the tunnel once the port answers.
        if let remote = session.remote {
            Task { @MainActor [weak self, weak session] in
                do {
                    try await remote.start(server)
                    session?.wait(for: server)
                } catch let error as RemoteHostClientError {
                    if case .rejected(_, let message) = error { self?.remoteActionError = message } else { self?.remoteActionError = error.description }
                } catch {
                    self?.remoteActionError = String(describing: error)
                }
            }
            return
        }
        let agentID = session.agentID
        openTerminalPane(for: agentID, cwd: server.directory, command: server.command) { [weak self, weak session] outcome in
            MainActor.assumeIsolated {
                switch outcome {
                case .opened: session?.wait(for: server)
                case .failed(_, let message): self?.remoteActionError = message
                default: break
                }
            }
        }
    }

    /// A remote viewer's "Start on <host>": runs `command` in a new terminal pane of the thread's
    /// layout, by the same rules as an agent's `pane_open`, in `cwd`, which must be the thread's
    /// folder or one inside it (where its dev servers were found). The viewer already holds the
    /// token, which lets it type into any terminal of the host; this only keeps the request to what
    /// the Browser offers.
    func startCommandForRemote(_ agentID: AgentID, cwd: String, command: String) async throws {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { throw RemoteCreateAgentError("Agent no longer exists") }
        let root = URL(fileURLWithPath: agentCwd(agent)).standardizedFileURL.path
        let target = URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath).standardizedFileURL.path
        guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw RemoteCreateAgentError("That folder is not in the thread's folder.")
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteCreateAgentError("Nothing to run.") }
        let outcome = await withCheckedContinuation { continuation in
            openTerminalPane(for: agentID, cwd: target, command: command) { continuation.resume(returning: $0) }
        }
        if case .failed(_, let message) = outcome { throw RemoteCreateAgentError(message) }
    }

    /// Add to message: the picked element joins the thread's composer as a chip.
    func addPickedElement(_ session: BrowserSession) {
        guard let element = session.picked else { return }
        let store = session.remote.map { remoteThreadStores.store(for: $0.ref) } ?? threadStores.store(for: session.agentID)
        if store.attach(element: element) {
            session.dismissPick()
        } else {
            NSSound.beep()
        }
    }

    func copyPickedSelector(_ session: BrowserSession) {
        guard let element = session.picked else { return }
        Self.copyToPasteboard(element.selector)
        session.dismissPick()
    }

    /// Open in your browser.
    func openInDefaultBrowser(_ session: BrowserSession) {
        guard let url = session.url else { return }
        NSWorkspace.shared.open(url)
    }
}
