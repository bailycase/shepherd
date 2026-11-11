import Foundation
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// Issues & PRs: what this Mac's app and a paired device get for `RemoteRequest.forge`. The workspace is read on the server queue; gh runs off it.
    public func forge(_ request: RemoteForgeRequest) async -> Result<RemoteForgeResult, ForgeError> {
        let context = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.forgeContext()) }
        }
        return await forge.answer(request, context: context)
    }

    /// The threads, folders and GitHub-triggered automations the forge links items to. On the
    /// server queue.
    func forgeContext() -> ForgeContext {
        let state = store.state
        let spaces = Dictionary(state.spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let automations = Dictionary(state.automations.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }
        let agents: [ForgeContext.Agent] = state.agents.compactMap { agent in
            let leaf = state.tabs.first { $0.id == agent.tabID }?.layout.firstLeaf.cwd
            guard let directory = agent.worktreePath ?? leaf ?? spaces[agent.spaceID]?.path else { return nil }
            let origin = agent.automationOrigin
            return ForgeContext.Agent(
                id: agent.id, title: agent.name, running: agent.status == .working || agent.status == .blocked,
                branch: agent.worktreeBranch ?? agent.checkout?.branch, worktreePath: agent.worktreePath, directory: expanded(directory),
                automationName: origin.flatMap { automations[$0.automationID]?.name },
                automationItem: origin?.eventID.flatMap(AutomationEvent.itemKey(ofEventID:)))
        }
        let folders = state.spaces.filter { !$0.hidden }.map { expanded($0.path) } + agents.map(\.directory)
        let watches: [ForgeContext.Watch] = state.automations.flatMap { automation -> [ForgeContext.Watch] in
            guard case .github(let triggers) = automation.trigger else { return [] }
            return triggers.map { ForgeContext.Watch(automationName: automation.name, directory: expanded(automation.cwd), repo: $0.repo, labels: $0.labels) }
        }
        return ForgeContext(agents: agents, directories: folders, watches: watches)
    }
}
