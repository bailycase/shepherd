import Foundation
@testable import ShepherdApp
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol
import ShepherdTestSupport

extension ShepherdState {
    /// The session a host bound to `pane`, as its state says.
    func session(boundTo pane: PaneID) -> SessionID? {
        tabs.lazy.compactMap { $0.layout.leaf(withID: pane)?.sessionID }.first
    }
}

@MainActor
extension AppHarness {
    /// The host's Project runtime.
    var coordinator: ProjectCoordinatorController { host!.runtime!.coordinator }
}

@MainActor
extension AppHarness {
    /// Waits for this Mac's app to tell its host it reaches `executor`, with `spaces` visible there
    /// (`ProjectExecutorsUpdate`): only then does the host's Project runtime accept or place on it.
    func hostReaches(_ executor: ProjectHostReference, spaces: [SpaceID] = []) async throws {
        let server = server
        try await eventuallyAsync("the host reaches the executor through the app") {
            await server.appProjectExecutors().contains { option in
                option.reference == executor && spaces.allSatisfy { id in option.spaces?.contains { $0.id == id } == true }
            }
        }
    }
}

@MainActor
extension AppHarness {
    /// A thread's subagents as its extension publishes them to the host (`agentChildren`).
    func publishChildren(_ agentID: AgentID, _ children: [ChildRun]) {
        server.onAgentChildren?(agentID, children)
    }
}

/// The staged engine (`python3 scripts/pi_engine.py stage`), for a host whose stores need its package.
func stagedPiSetup(home: URL) throws -> PiSetup {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    guard let engine = BundledPiEngine(contents: root.appendingPathComponent(".build/pi-engine")) else {
        throw TimedOut(what: "the staged pi engine (python3 scripts/pi_engine.py stage)")
    }
    return PiSetup(engine: .bundled(engine), home: home)
}

@MainActor
extension AppHarness {
    /// The host's server started again after a `server.stop()`, as a host restart: it listens on
    /// `host.sock` again and this Mac's app reconnects and adopts its workspace.
    func relisten() async throws {
        try server.startLocalListener(path: hostSocket, tokenURL: dir.appendingPathComponent("remote-token"))
        let server = server, vm = vm!
        try await eventuallyOnMain("the app back on its host", timeout: .seconds(30)) {
            vm.localHost?.phase == .connected && vm.state == server.state
        }
    }
}
