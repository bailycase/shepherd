import Foundation
import AppKit
import Observation
import ShepherdCore
import ShepherdRemote

/// The right pane beside a thread (spec §9, §10): the subagent inspector or the review. While
/// one is open the sidebar takes its compact form.
extension ShepherdViewModel {
    enum RightPaneContent: Equatable {
        case inspector(runID: String)
        case review
    }

    /// What the right pane shows for the workspace on screen.
    var rightPaneContent: RightPaneContent? {
        if let remote = selectedRemoteAgent {
            if let run = subagentInspector.remoteRuns[remote] { return .inspector(runID: run) }
            return remoteReviews[remote] != nil ? .review : nil
        }
        guard selectedShellID == nil, let agent = selectedAgent, activeTabID == agent.tabID else { return nil }
        if let run = subagentInspector.runByAgent[agent.id] { return .inspector(runID: run) }
        return reviewSessions.values.contains { $0.agentID == agent.id } ? .review : nil
    }

    var isRightPaneOpen: Bool { rightPaneContent != nil }

    /// ⌘⇧B and the header's pane button: close whatever is open, otherwise open the review.
    func toggleRightPane() {
        switch rightPaneContent {
        case .inspector:
            if let remote = selectedRemoteAgent { subagentInspector.remoteRuns.removeValue(forKey: remote) }
            else if let id = selectedAgentID { subagentInspector.runByAgent.removeValue(forKey: id) }
        case .review, nil:
            openUserReview()
        }
    }
}

/// Keyboard commands aimed at the thread on screen (menu items and rebindable chords). The
/// visible thread view observes `request` and acts when the key is its own.
@MainActor @Observable
final class ThreadCommandCenter {
    enum Command: Equatable { case modelPicker, previousTurn, nextTurn, inspectSubagent }

    struct Request: Equatable {
        let command: Command
        let thread: String
        let id = UUID()
    }

    private(set) var request: Request?

    func send(_ command: Command, to thread: String) {
        request = Request(command: command, thread: thread)
    }

    static func key(local agentID: AgentID) -> String { "local:\(agentID.rawValue)" }
    static func key(remote ref: RemoteAgentRef) -> String { "remote:\(ref.hostID.uuidString):\(ref.agentID.rawValue)" }
}

extension ShepherdViewModel {
    /// The thread on screen: its store and its command key.
    var visibleThread: (store: NativeThreadStore, key: String)? {
        if let remote = selectedRemoteAgent, remoteInspectingAgent != remote {
            return (remoteThreadStores.store(for: remote), ThreadCommandCenter.key(remote: remote))
        }
        guard selectedRemoteAgent == nil, selectedShellID == nil, let agent = selectedAgent, activeTabID == agent.tabID else { return nil }
        return (threadStores.store(for: agent.id), ThreadCommandCenter.key(local: agent.id))
    }

    func sendThreadCommand(_ command: ThreadCommandCenter.Command) {
        guard let thread = visibleThread else { NSSound.beep(); return }
        threadCommands.send(command, to: thread.key)
    }

    /// ⌘. — stop the visible agent's turn.
    func stopVisibleAgent() {
        guard let store = visibleThread?.store, store.supports("abort") else { NSSound.beep(); return }
        Task { await store.abort() }
    }
}
