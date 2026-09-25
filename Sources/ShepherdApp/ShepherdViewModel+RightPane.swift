import Foundation
import AppKit
import Observation
import ShepherdCore
import ShepherdRemote

/// A tab of the side pane beside a thread (DESIGN.md › Side pane). Only the tabs Shepherd has
/// are here; Browser, Artifacts and Files join as cases when they are built, each with its
/// content in `SidePaneView` and its ⌃ digit following its place.
enum SidePaneTab: String, CaseIterable, Hashable, Sendable {
    case changes

    var title: String {
        switch self {
        case .changes: "Changes"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: "plus.forwardslash.minus"
        }
    }

    /// Its fixed chord: ⌃1 for the first tab, and so on (⌃1–4 are the pane's).
    var digit: Int { (Self.allCases.firstIndex(of: self) ?? 0) + 1 }
    var shortcutDisplay: String { "⌃\(digit)" }

    /// What the header button's tip says when pi opened something here with the pane closed.
    var newsText: String {
        switch self {
        case .changes: "pi opened a review in Changes"
        }
    }
}

/// Whose side pane: a local agent's, or a remote one's on this Mac.
enum SidePaneOwner: Hashable {
    case local(AgentID)
    case remote(RemoteAgentRef)
}

/// The side pane beside a thread (DESIGN.md › Side pane): one pane per window, docked right,
/// with a tab per surface (Changes today). The subagent inspector takes the pane over while a run
/// is inspected; closing it goes back to the tab underneath, if the pane was open. Nothing opens
/// the pane by itself: when pi opens something for it (`review_diff`), the tab takes a dot, and
/// with the pane closed so does the header's button.
extension ShepherdViewModel {
    enum RightPaneContent: Equatable {
        case inspector(runID: String)
        /// The Changes tab.
        case review
    }

    /// The side pane of the thread on screen.
    var sidePaneOwner: SidePaneOwner? {
        if let remote = selectedRemoteAgent { return .remote(remote) }
        guard let agent = selectedAgent, activeTabID == agent.tabID else { return nil }
        return .local(agent.id)
    }

    /// What the side pane shows for the workspace on screen.
    var rightPaneContent: RightPaneContent? {
        guard let owner = sidePaneOwner else { return nil }
        if let run = subagentInspector.run(for: owner) { return .inspector(runID: run) }
        return subagentInspector.open.contains(owner) ? .review : nil
    }

    var isRightPaneOpen: Bool { rightPaneContent != nil }

    /// ⇧⌘B and the header's button: hide the pane (and an inspected subagent over it), or show it
    /// on its tab.
    func toggleRightPane() {
        guard let owner = sidePaneOwner else { NSSound.beep(); return }
        if rightPaneContent != nil { hideSidePane(owner) } else { showSidePane(owner) }
    }

    /// ⌃1…, a tab's button, a palette command: the pane on `tab`, in front of an inspected
    /// subagent.
    func selectSidePaneTab(_ tab: SidePaneTab) {
        guard let owner = sidePaneOwner else { NSSound.beep(); return }
        showSidePane(owner, tab: tab)
    }

    /// Shows `owner`'s pane on `tab` (else the tab it was on). Asking for a tab brings it in front
    /// of an inspected subagent. Whatever the tab shows is made ready (a review starts loading),
    /// and its dot clears: you are looking at it.
    func showSidePane(_ owner: SidePaneOwner, tab: SidePaneTab? = nil) {
        let panes = subagentInspector
        if let tab {
            if panes.tabs[owner] != tab { panes.tabs[owner] = tab }
            closeInspector(owner)
        }
        let shown = panes.tab(for: owner)
        if !panes.open.contains(owner) { panes.open.insert(owner) }
        panes.clearNews(owner, shown)
        switch shown {
        case .changes: ensureReview(owner)
        }
    }

    /// The pane over the whole layout (ChangesWide), or back beside the thread.
    func toggleSidePaneMaximized(_ owner: SidePaneOwner) {
        let panes = subagentInspector
        if panes.maximized.contains(owner) { panes.maximized.remove(owner) } else { panes.maximized.insert(owner) }
    }

    /// Hides `owner`'s pane: the inspector closes, and the review is discarded like a cancel.
    func hideSidePane(_ owner: SidePaneOwner) {
        if subagentInspector.maximized.contains(owner) { subagentInspector.maximized.remove(owner) }
        closeInspector(owner)
        guard subagentInspector.open.contains(owner) else { return }
        subagentInspector.open.remove(owner)
        switch owner {
        case .local(let agentID):
            for session in reviewSessions.values where session.agentID == agentID { cancelReview(session) }
        case .remote(let target):
            if let session = remoteReviews[target], !session.hostReviewPane { cancelReview(session) }
        }
    }

    func closeInspector(_ owner: SidePaneOwner) {
        switch owner {
        case .local(let id): if subagentInspector.runByAgent[id] != nil { subagentInspector.runByAgent.removeValue(forKey: id) }
        case .remote(let ref): if subagentInspector.remoteRuns[ref] != nil { subagentInspector.remoteRuns.removeValue(forKey: ref) }
        }
    }

    /// The Changes tab's review for `owner`, begun if there is none.
    private func ensureReview(_ owner: SidePaneOwner) {
        switch owner {
        case .local(let agentID):
            if !reviewSessions.values.contains(where: { $0.agentID == agentID }) {
                beginReview(agentID: agentID, cwd: nil, reference: nil)
            }
        case .remote(let target):
            if remoteReviews[target] == nil { openRemoteReview(target, pullRequest: false) }
        }
    }

    /// The header button's state for `owner` (`SidePaneTab.button`).
    func sidePaneButton(for owner: SidePaneOwner) -> (isOn: Bool, news: String?) {
        let panes = subagentInspector
        return SidePaneTab.button(open: panes.open.contains(owner), inspecting: panes.run(for: owner) != nil,
                                  news: panes.news[owner] ?? [])
    }
}

extension SidePaneTab {
    /// The header's side-pane button: lit while the pane shows (its tabs or an inspected run),
    /// and carrying what pi opened while the tab strip is out of sight (the pane closed, or the
    /// inspector over it). With the strip on screen the tab's own dot says it.
    static func button(open: Bool, inspecting: Bool, news: Set<SidePaneTab>) -> (isOn: Bool, news: String?) {
        let stripShows = open && !inspecting
        return (open || inspecting, stripShows ? nil : allCases.first { news.contains($0) }?.newsText)
    }
}

/// Keyboard commands aimed at the thread on screen (menu items and rebindable chords). The
/// visible thread view observes `request` and acts when the key is its own.
@MainActor @Observable
final class ThreadCommandCenter {
    /// `thinkingMenu` has no chord of its own; it opens the composer's thinking menu the way ⇧⌘M
    /// opens the model picker.
    enum Command: Equatable { case modelPicker, thinkingMenu, previousTurn, nextTurn, inspectSubagent }

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
        guard selectedRemoteAgent == nil, let agent = selectedAgent, activeTabID == agent.tabID else { return nil }
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
