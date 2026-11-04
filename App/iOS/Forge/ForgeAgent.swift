import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Hands an Issues & PRs brief (`ForgeBriefs`) to the existing thread paths: a thread it names
/// gets the prompt as its next message; otherwise a new thread starts in the repository's space
/// (on a new worktree when the brief names one) with the prompt as its first message. Either way
/// the thread opens.
@MainActor
enum ForgeAgent {
    /// Nil once the host took it; else why not, in words.
    static func run(_ brief: ForgeBrief, host: UUID, hosts: MobileHosts, threads: ThreadStores,
                    navigator: MobileNavigator) async -> String? {
        guard let mobile = hosts.host(host), let client = mobile.connectedClient else {
            return "\(hosts.host(host)?.name ?? "The host") isn't connected."
        }
        if let agent = brief.agentID {
            let ref = AgentRef(host: host, agent: agent)
            navigator.open(.thread(ref))
            let store = threads.store(for: ref)
            // The thread's store starts once its screen polls it. ponytail: a bounded wait (5 s)
            // rather than an observation hook; past it the prompt waits in the composer instead.
            for _ in 0..<25 where !store.ready { try? await Task.sleep(for: .milliseconds(200)) }
            if store.ready {
                await store.send(text: brief.prompt)
            } else {
                store.draft = brief.prompt
            }
            return nil
        }
        guard let cwd = brief.cwd,
              let space = mobile.state.spaces.first(where: { cwd == $0.path || cwd.hasPrefix($0.path + "/") }) else {
            return "\(mobile.name) has no space for this repository. Add it as a space on the Mac first."
        }
        do {
            let agent = try await client.createAgent(spaceID: space.id, cwd: cwd, model: nil, thinking: nil,
                                                     initialPrompt: brief.prompt, worktreeBranch: brief.worktreeBranch)
            navigator.open(.thread(AgentRef(host: host, agent: agent)))
            return nil
        } catch RemoteHostClientError.rejected(_, let message) {
            return message
        } catch {
            return "Couldn't start the thread on \(mobile.name)."
        }
    }
}
