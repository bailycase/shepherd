import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The thread's Can't start banner above the composer, the Mac's (`Composer`): why the agent's pi
/// stopped, then the buttons `NativeStartProblem.actions` names. Retry and Start new conversation
/// need a host that takes `restartPi` (`NativeStartRestart.isOffered`) and a live connection;
/// without the capability the advice sends the person to the host Mac. A missing folder has no
/// Retry: it is fixed on the host, and the advice says so.
struct StartProblemBanner: View {
    let ref: AgentRef
    let problem: NativeStartProblem
    let store: NativeThreadStore
    @Environment(MobileHosts.self) private var hosts
    /// Why the host refused or couldn't be reached; cleared when the problem changes.
    @State private var failure: String?
    @State private var asking = false

    var body: some View {
        let host = hosts.host(ref.host)
        let offered = host.map { NativeStartRestart.isOffered(by: $0.capabilities) } ?? false
        let actions = problem.actions(canRestart: offered, canLocateFolder: false)
        let message = problem.message(host: host?.name ?? "the host", retryHere: offered)
        SHBanner(.failed, title: problem.title, message: failure.map { message + "\n\n" + $0 } ?? message, stacked: !actions.isEmpty) {
            ForEach(actions, id: \.self) { action in
                Button(action == .startNewConversation ? "Start new conversation" : "Retry") { perform(action) }
                    .buttonStyle(.sh(action == .startNewConversation ? .ghost : .secondary))
                    .disabled(asking || host?.connectedClient == nil)
            }
        }
        .onChange(of: problem) { _, _ in failure = nil }
    }

    private func perform(_ action: NativeStartAction) {
        guard let client = hosts.host(ref.host)?.connectedClient, !asking else { return }
        asking = true
        failure = nil
        Task {
            defer { asking = false }
            do {
                try await NativeStartRestart.perform(action, store: store) { try await client.agentAction(agentID: ref.agent, action: $0) }
            } catch {
                failure = "Couldn’t start the agent: \(error.localizedDescription)"
            }
        }
    }
}
