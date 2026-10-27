import AppKit
import Foundation
import ShepherdCore
import ShepherdUI

/// The actions on one of this Mac's threads, listed once: the Agent menu, ⌘K's "This thread"
/// section and the sidebar row's menu all offer this list, so nothing is reachable from one
/// surface alone.
enum ThreadCommand: String, CaseIterable, Identifiable {
    case fork, copyTranscript, reviewChanges, openInFinder, finalizeWorktree, delete

    var id: String { rawValue }

    /// Menu casing ("Copy Transcript").
    var title: String {
        switch self {
        case .fork: "Fork Thread"
        case .copyTranscript: "Copy Transcript"
        case .reviewChanges: "Review Changes"
        case .openInFinder: "Open in Finder"
        case .finalizeWorktree: "Finalize Worktree…"
        case .delete: "Delete Agent…"
        }
    }

    /// Palette casing ("Copy transcript").
    var paletteTitle: String {
        switch self {
        case .fork: "Fork thread"
        case .copyTranscript: "Copy transcript"
        case .reviewChanges: "Review changes"
        case .openInFinder: "Open in Finder"
        case .finalizeWorktree: "Finalize worktree…"
        case .delete: "Delete agent…"
        }
    }

    var symbol: String {
        switch self {
        case .fork: "arrow.branch"
        case .copyTranscript: "doc.on.doc"
        case .reviewChanges: "plus.forwardslash.minus"
        case .openInFinder: "folder"
        case .finalizeWorktree: SHGlyph.gitBranch.symbolName
        case .delete: "trash"
        }
    }

    var isDestructive: Bool { self == .delete }

    var shortcut: ShortcutAction? { self == .delete ? .deleteAgent : nil }

    /// Finalize is a worktree agent's alone; the rest apply to any of this Mac's threads.
    func applies(to agent: Agent) -> Bool {
        self != .finalizeWorktree || agent.worktreeBranch != nil
    }

    static func commands(for agent: Agent) -> [ThreadCommand] { allCases.filter { $0.applies(to: agent) } }
}

/// The agent menu's actions beyond rename, review and delete (SHComposer › Menus): Fork from
/// Here, Copy Transcript and Open in Finder, for This Mac's agents, read from pi's session file.
@MainActor
extension ShepherdViewModel {
    func perform(_ command: ThreadCommand, on id: AgentID) {
        switch command {
        case .fork: forkAgent(id)
        case .copyTranscript: copyAgentTranscript(id)
        case .reviewChanges: selectAgent(id); openUserReview()
        case .openInFinder: openAgentInFinder(id)
        case .finalizeWorktree: beginFinalizeWorktree(id)
        case .delete: requestDeleteAgent(id)
        }
    }

    /// The agent's session file and the directory pi runs in; nil for an agent no longer listed.
    private func sessionSource(_ id: AgentID) -> (sessionID: String, cwd: String, agent: Agent)? {
        guard let agent = state.agents.first(where: { $0.id == id }) else { return nil }
        return (agent.effectivePiSessionID, TerminalSessionStore.resolvedCwd(agentCwd(agent)), agent)
    }

    /// Fork from Here: the whole conversation so far, copied into a new pi session, becomes a new
    /// agent beside this one ("<name> (fork)", named again by the namer from its next turn). A
    /// failure says why and creates nothing.
    func forkAgent(_ id: AgentID) {
        guard let source = sessionSource(id) else { return }
        Task {
            do {
                let (sessionID, cwd, root) = (source.sessionID, source.cwd, server.pi.sessionsRoot)
                let forked = try await Task.detached(priority: .userInitiated) {
                    guard let file = PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: root) else {
                        throw PiSessionFile.ForkFailure(message: "This agent has nothing to fork yet.")
                    }
                    return try PiSessionFile.fork(sessionFile: file.path, cwd: cwd, sessionsRoot: root)
                }.value
                var config = NewAgentConfig(spaceID: source.agent.spaceID, workingDirectory: cwd, model: source.agent.model,
                                            thinking: source.agent.thinkingLevel ?? .medium, initialPrompt: nil)
                config.initialName = Self.forkName(source.agent.name)
                config.piSessionID = forked
                try await startAgent(config)
            } catch {
                actionError = ActionError(title: "Couldn’t fork “\(source.agent.name)”", message: ActionError.describe(error))
            }
        }
    }

    /// "Restyle native UI (fork)".
    nonisolated static func forkName(_ name: String) -> String { "\(name) (fork)" }

    /// Copy Transcript: what was said in the agent's session, the whole of it, on the pasteboard.
    func copyAgentTranscript(_ id: AgentID) {
        guard let source = sessionSource(id) else { return }
        Task {
            let (sessionID, cwd, root) = (source.sessionID, source.cwd, server.pi.sessionsRoot)
            let text = await Task.detached(priority: .userInitiated) {
                PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: root).flatMap(PiSessionFile.transcript(file:))
            }.value
            guard let text else {
                remoteActionError = "“\(source.agent.name)” has no transcript yet. Nothing was copied."
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Open in Finder: the folder the agent works in.
    func openAgentInFinder(_ id: AgentID) {
        guard let source = sessionSource(id) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: source.cwd, isDirectory: true))
    }
}
