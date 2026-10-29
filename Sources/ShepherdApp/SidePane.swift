import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// The side pane's tab strip over the current tab (PaneStates, Review, SubagentList, FilesTab): Changes, with
/// its count of changed files, a local thread's Browser, Files with the space's file browser,
/// and Subagents with its count of runs.
/// The subagent inspector is not a tab: it takes the
/// whole pane over while a run is inspected (`AgentLayoutView`), and the Subagents tab is the list
/// that opens it.
struct SidePaneView: View {
    var vm: ShepherdViewModel
    let owner: SidePaneOwner
    let tab: SidePaneTab
    let news: Set<SidePaneTab>
    let review: ReviewSession?
    let store: NativeThreadStore
    var maximized = false
    /// The layout is on screen: the Browser answers its chords.
    var active = true
    /// Opens a run in the inspector over the pane (the Subagents tab).
    var inspect: (ChildRun) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            SidePaneTabBar(vm: vm, owner: owner, tab: tab, news: news, review: review, store: store, maximized: maximized)
                // The tab's brief tip hangs below the strip, over the tab's page.
                .zIndex(1)
            ZStack {
                switch tab {
                case .changes:
                    if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: isRemote), store: store,
                                       maximized: maximized)
                            .id(review.id)
                            .shTransition(.content)
                    }
                case .browser:
                    switch owner {
                    case .local(let agentID):
                        BrowserPane(vm: vm, session: vm.browsers.session(for: agentID), store: store, active: active)
                            .shTransition(.content)
                    case .remote(let ref):
                        // A remote thread's page renders here and reaches its host through the tunnel.
                        BrowserPane(vm: vm, session: vm.browsers.session(for: ref, hosts: vm.remoteHosts), store: store, active: active)
                            .shTransition(.content)
                    }
                case .subagents:
                    SubagentListTab(store: store, inspect: inspect)
                        .shTransition(.content)
                case .files:
                    filesContent
                        .shTransition(.content)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
    }

    @ViewBuilder
    private var filesContent: some View {
        switch owner {
        case .local(let agentID):
            if let model = vm.fileTree(for: agentID) {
                FilesTab(model: model)
                    .id(model.rootPath)
            } else {
                Text("Loading files…")
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task { vm.ensureFileTree(owner) }
            }
        case .remote(let ref):
            if let model = vm.fileTree(for: ref) {
                FilesTab(model: model)
                    .id(model.rootPath)
                    .task { vm.ensureFileTree(owner) }
            } else {
                FilesUnavailableView(host: vm.remoteHosts.connections.first { $0.id == ref.hostID }?.config.name)
                    .task { vm.ensureFileTree(owner) }
            }
        }
    }

    private var isRemote: Bool { owner.isRemote }
}

/// The strip, in a view of its own: a count that changes redraws it, not the tab under it.
private struct SidePaneTabBar: View {
    var vm: ShepherdViewModel
    let owner: SidePaneOwner
    let tab: SidePaneTab
    let news: Set<SidePaneTab>
    let review: ReviewSession?
    let store: NativeThreadStore
    let maximized: Bool

    /// What pi last opened in this thread's Browser, for the tab's brief tip.
    private var browserTip: SHSidePaneTabTip? {
        switch owner {
        case .local(let agentID): SidePaneTabs.tip(opened: vm.browsers.existing(agentID)?.openedByAgent)
        case .remote(let ref): SidePaneTabs.tip(opened: vm.browsers.existing(ref)?.openedByAgent)
        }
    }

    var body: some View {
        SHSidePaneTabs(SidePaneTabs.items(news: news, changedFiles: review.flatMap { $0.isLoading ? nil : $0.files.count },
                                          browser: vm.sidePaneTabs(for: owner).contains(.browser), browserTip: browserTip,
                                          subagents: SidePaneTabs.subagents(store.subagents)),
                       selection: tab.rawValue,
                       select: { id in SidePaneTab(rawValue: id).map { vm.showSidePane(owner, tab: $0) } },
                       closeShortcut: vm.keybindings.display(.toggleRightPane),
                       close: { vm.hideSidePane(owner) },
                       restore: maximized ? { vm.toggleSidePaneMaximized(owner) } : nil) {
            // The pane's ⋯ menu: what the tab on screen offers, then the pane's own. Split below,
            // Open in its own window and Show tabs wait for the tabs that need them.
            if tab == .changes, let review {
                ReviewOptionItems(session: review, maximized: maximized, toggleMaximized: { vm.toggleSidePaneMaximized(owner) })
                Divider()
            }
            Button("Reset Width") { vm.subagentInspector.width = 0 }
                .disabled(vm.subagentInspector.width == 0)
        }
    }
}

/// The strip's tabs, from what each one holds.
enum SidePaneTabs {
    /// `browserTip` is what pi last opened in the Browser: the brief line under its tab while it is news.
    /// `subagents` is the thread's run count and status; nil while it has none (no tab).
    static func items(news: Set<SidePaneTab>, changedFiles: Int?, browser: Bool = true, browserTip: SHSidePaneTabTip? = nil,
                      subagents: (count: Int, status: AgentState)? = nil) -> [SHSidePaneTab] {
        SidePaneTab.tabs(browser: browser).compactMap { tab in
            let count: Int? = switch tab {
            case .changes: changedFiles
            case .browser: nil
            case .files: nil
            case .subagents: subagents?.count
            }
            if tab == .subagents, subagents == nil { return nil }
            return SHSidePaneTab(id: tab.rawValue, title: tab.title, systemImage: tab.systemImage, count: count,
                                 news: news.contains(tab), status: tab == .subagents ? subagents?.status : nil, shortcut: tab.shortcutDisplay, tip: tab == .browser ? browserTip : nil)
        }
    }

    /// "localhost:5173/checkout": the page pi opened, as the address field shows it.
    static func tip(opened: (url: URL, at: Date)?) -> SHSidePaneTabTip? {
        guard let opened, let shown = BrowserAddress.display(opened.url) else { return nil }
        return SHSidePaneTabTip(text: shown.host + shown.path, openedAt: opened.at)
    }
}
