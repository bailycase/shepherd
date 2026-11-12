import Foundation
import AppKit
import Observation
import ShepherdCore
import ShepherdRemote
import ShepherdUI

/// A tab of the side pane beside a thread (FileOpenSplit board for Files).
/// Pull request takes ⌃3 (the removed Artifacts tab's), Subagents ⌃4 and Files ⌃5. The digit is fixed per tab (not derived
/// from CaseIterable index) so adding or removing a tab never shifts existing chords.
enum SidePaneTab: String, CaseIterable, Hashable, Sendable {
    case changes
    /// A thread's Browser (PaneBrowser): a local thread's, or a remote one's whose host carries
    /// tunnels (`browser.tunnel.v1`).
    case browser
    /// The thread branch's pull request (PRPane, PRPaneMerged), while the branch has one.
    case pullRequest
    /// Every subagent of the thread, this turn's and the earlier ones (SubagentList).
    case subagents
    /// The space's file browser (FileOpenSplit board): read-only tree and viewer.
    case files
    /// A board the agent showed in the thread, opened beside it (ThreadBoardPane), while one is.
    case design

    var title: String {
        switch self {
        case .changes: "Changes"
        case .browser: "Browser"
        case .pullRequest: "Pull request"
        case .subagents: "Subagents"
        case .files: "Files"
        case .design: "Design"
        }
    }

    var systemImage: String {
        switch self {
        case .changes: "plus.forwardslash.minus"
        case .browser: "globe"
        case .pullRequest: ForgeSymbol.pullRequest
        case .subagents: SHGlyph.gitBranch.symbolName
        case .files: SHGlyph.document.symbolName
        case .design: "pencil.tip"
        }
    }

    /// The tabs a thread's pane shows: Changes, Pull request while the branch has one, Browser,
    /// Design while a board is open in it, Files (always, for local; the tab itself shows unavailable for remote), and
    /// Subagents once it has a run.
    /// `SidePaneTabs.items` and `ShepherdViewModel.sidePaneTabs(for:)` drop conditional ones while they have nothing.
    static func tabs(browser: Bool, pullRequest: Bool = false, design: Bool = false) -> [SidePaneTab] {
        [.changes] + (pullRequest ? [.pullRequest] : []) + (browser ? [.browser] : []) + (design ? [.design] : []) + [.files, .subagents]
    }

    /// Fixed chord digits: ⌃1 Changes, ⌃2 Browser, ⌃3 Pull request, ⌃4 Subagents, ⌃5 Files, ⌃6 Design.
    /// A tab keeps its digit regardless of which tabs are visible.
    var digit: Int {
        switch self {
        case .changes: 1
        case .browser: 2
        case .pullRequest: 3
        case .subagents: 4
        case .files: 5
        case .design: 6
        }
    }
    var shortcutDisplay: String { "⌃\(digit)" }

    /// What the header button's tip says when pi opened something here with the pane closed.
    var newsText: String {
        switch self {
        case .changes: "Agent opened a review in Changes"
        case .browser: "Agent opened a page in Browser"
        // Nothing marks it either: the branch's pull request is looked up, not opened by pi.
        case .pullRequest: "The branch has a pull request"
        // Nothing marks this tab as news: the dot is pi opening something, and a subagent opens nothing in the pane.
        case .subagents: "Agent started a subagent"
        // Files is user-driven; the agent never opens it.
        case .files: "Files changed in the workspace"
        // Only the user opens a board here, from its card.
        case .design: "A board is open in Design"
        }
    }
}

/// Whose side pane: a local agent's, or a remote one's on this Mac.
enum SidePaneOwner: Hashable {
    case local(AgentID)
    case remote(RemoteAgentRef)

    var isRemote: Bool {
        if case .remote = self { return true }
        return false
    }
}

/// The side pane beside a thread: one pane per window, docked right,
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
        guard let agent = structuralAgent(selectedAgentID), activeTabID == agent.tabID else { return nil }
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
        if let tab, !sidePaneTabs(for: owner).contains(tab) {
            NSSound.beep()
            return
        }
        if let tab {
            if panes.tabs[owner] != tab { panes.tabs[owner] = tab }
            closeInspector(owner)
        }
        let shown = panes.tab(for: owner)
        if !panes.open.contains(owner) { panes.open.insert(owner) }
        panes.clearNews(owner, shown)
        switch shown {
        case .changes: ensureReview(owner)
        case .files: ensureFileTree(owner)
        case .browser, .subagents, .pullRequest, .design: break
        }
    }

    /// A board card's picture (ThreadBoardPane): the board opens in the pane's Design tab, beside
    /// the thread, as the card shows it.
    func showBoardBeside(_ owner: SidePaneOwner, _ board: DesignReferenceChips.Board) {
        if subagentInspector.boards[owner] != board { subagentInspector.boards[owner] = board }
        showSidePane(owner, tab: .design)
    }

    /// The pane over the whole layout (ChangesWide), or back beside the thread.
    func toggleSidePaneMaximized(_ owner: SidePaneOwner) {
        let panes = subagentInspector
        if panes.maximized.contains(owner) {
            panes.maximized.remove(owner)
        } else {
            // Hidden layouts keep the column's size while the pane covers the window, so taking
            // the sidebar's and the toolbar's room relays out the visible one alone.
            wideFrozenSize = workspaceColumn.size
            panes.maximized.insert(owner)
        }
    }

    /// The side pane on screen covers the window (ChangesWide): its rail replaces the sidebar
    /// and the toolbar, until the thread is restored or something else takes the column.
    var isSidePaneWide: Bool {
        guard destination == nil, !showSettings, !showComponentGallery, let owner = sidePaneOwner,
              rightPaneContent == .review else { return false }
        return subagentInspector.maximized.contains(owner)
    }

    /// The rail's Back to the thread.
    func restoreWideSidePane() {
        guard let owner = sidePaneOwner, subagentInspector.maximized.contains(owner) else { return }
        subagentInspector.maximized.remove(owner)
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

    /// The Files tab's tree for `owner`, created lazily. Replaces the model if the
    /// agent's cwd has changed (e.g. moved to a different worktree).
    func ensureFileTree(_ owner: SidePaneOwner) {
        if case .remote(let ref) = owner { return ensureRemoteFileTree(ref) }
        guard case .local(let agentID) = owner else { return }
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { return }
        let cwd = agentCwd(agent)
        if let existing = fileTrees[agentID], existing.rootPath == cwd { return }
        // New or changed root: replace model, prune stale tabs
        fileTrees[agentID] = makeFileTree(agentID, cwd: cwd)
    }

    /// A local thread's tree: its Saves tell the branch chip and the Changes tab (`workingTreeChanged`).
    private func makeFileTree(_ agentID: AgentID, cwd: String) -> FileTreeModel {
        let model = FileTreeModel(rootPath: cwd)
        model.onSaved = { [weak self] _ in self?.workingTreeChanged(agentID) }
        model.onWrite = { [weak self] path in await self?.personWriteBegan(agentID, paths: [path]) }
        return model
    }

    /// Reading from a view never creates stores or mutates observed state.
    func fileTree(for agentID: AgentID) -> FileTreeModel? { fileTrees[agentID] }
    func fileTree(for ref: RemoteAgentRef) -> FileTreeModel? { remoteFileTrees[ref] }

    /// A remote thread's tree, over its host's `files.v1`, rooted at the thread's folder there (as the host reads it).
    private func ensureRemoteFileTree(_ ref: RemoteAgentRef) {
        guard let connection = remoteHosts.allConnections.first(where: { $0.id == ref.hostID }), connection.supportsFiles,
              let agent = connection.state.agents.first(where: { $0.id == ref.agentID }),
              let folder = connection.state.tabs.first(where: { $0.id == agent.tabID })?.layout.firstLeaf.cwd
                ?? connection.state.spaces.first(where: { $0.id == agent.spaceID })?.path else { return }
        if remoteFileTrees[ref]?.rootPath == folder { return }
        remoteFileTrees[ref] = FileTreeModel(rootPath: folder, source: .remote(root: folder, agentID: ref.agentID, host: connection.config.name) {
            [weak connection] in connection?.filesClient
        })
    }

    /// Reconcile retained browsers on adoption, including moves while Files is open.
    func pruneFileTrees() {
        let agents = Dictionary(uniqueKeysWithValues: state.agents.map { ($0.id, $0) })
        for (id, model) in fileTrees {
            guard let agent = agents[id] else {
                fileTrees.removeValue(forKey: id)
                continue
            }
            let cwd = agentCwd(agent)
            if model.rootPath != cwd { fileTrees[id] = makeFileTree(id, cwd: cwd) }
        }
    }

    /// The tabs `owner`'s pane shows: a remote thread has the Browser only while its host carries
    /// tunnels (an older host has none, as before), and Subagents only once the thread has a run.
    func sidePaneTabs(for owner: SidePaneOwner) -> [SidePaneTab] {
        let hasRuns: Bool
        let browser: Bool
        switch owner {
        case .local(let id):
            hasRuns = threadStores.existing(for: id)?.subagents.isEmpty == false
            browser = true
        case .remote(let ref):
            hasRuns = remoteThreadStores.existing(for: ref)?.subagents.isEmpty == false
            browser = remoteHosts.allConnections.first { $0.id == ref.hostID }?.supportsBrowser == true
        }
        let pullRequest = if case .local(let id) = owner { branchPullRequests[id] != nil } else { false }
        return SidePaneTab.tabs(browser: browser, pullRequest: pullRequest, design: subagentInspector.boards[owner] != nil)
            .filter { $0 != .subagents || hasRuns }
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
    /// opens the model picker. `speedMenu` is the same for the Speed menu (⌘K's Toggle fast mode
    /// switches the tier without opening it).
    enum Command: Equatable { case modelPicker, thinkingMenu, speedMenu, previousTurn, nextTurn, inspectSubagent }

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
