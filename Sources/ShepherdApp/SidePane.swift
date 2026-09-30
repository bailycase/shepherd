import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The side pane's tab strip over the current tab (PaneStates, Review): Changes, with its count
/// of changed files, and a local thread's Browser. Artifacts and Files are not built, so they have
/// no tab and no placeholder; each joins `SidePaneTab` and the switch below when it is. The
/// subagent inspector is not a tab: it takes the whole pane over while a run is inspected
/// (`AgentLayoutView`).
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

    var body: some View {
        VStack(spacing: 0) {
            SidePaneTabBar(vm: vm, owner: owner, tab: tab, news: news, review: review, maximized: maximized)
                // The tab's brief tip hangs below the strip, over the tab's page.
                .zIndex(1)
            ZStack {
                switch tab {
                case .changes:
                    if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: isRemote), store: store,
                                       maximized: maximized)
                            .id(review.id)
                            .nwTransition(.content)
                    }
                case .browser:
                    switch owner {
                    case .local(let agentID):
                        BrowserPane(vm: vm, session: vm.browsers.session(for: agentID), store: store, active: active)
                            .nwTransition(.content)
                    case .remote(let ref):
                        // A remote thread's page renders here and reaches its host through the tunnel.
                        BrowserPane(vm: vm, session: vm.browsers.session(for: ref, hosts: vm.remoteHosts), store: store, active: active)
                            .nwTransition(.content)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nw.bgWindow)
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
    let maximized: Bool

    /// What pi last opened in this thread's Browser, for the tab's brief tip.
    private var browserTip: NWSidePaneTabTip? {
        guard case .local(let agentID) = owner else { return nil }
        return SidePaneTabs.tip(opened: vm.browsers.existing(agentID)?.openedByAgent)
    }

    var body: some View {
        NWSidePaneTabs(SidePaneTabs.items(news: news, changedFiles: review.flatMap { $0.isLoading ? nil : $0.files.count },
                                          browser: vm.sidePaneTabs(for: owner).contains(.browser), browserTip: browserTip),
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
    static func items(news: Set<SidePaneTab>, changedFiles: Int?, browser: Bool = true, browserTip: NWSidePaneTabTip? = nil) -> [NWSidePaneTab] {
        SidePaneTab.tabs(browser: browser).map { tab in
            let count: Int? = switch tab {
            case .changes: changedFiles
            case .browser: nil
            }
            return NWSidePaneTab(id: tab.rawValue, title: tab.title, systemImage: tab.systemImage, count: count,
                                 news: news.contains(tab), shortcut: tab.shortcutDisplay, tip: tab == .browser ? browserTip : nil)
        }
    }

    /// "localhost:5173/checkout": the page pi opened, as the address field shows it.
    static func tip(opened: (url: URL, at: Date)?) -> NWSidePaneTabTip? {
        guard let opened, let shown = BrowserAddress.display(opened.url) else { return nil }
        return NWSidePaneTabTip(text: shown.host + shown.path, openedAt: opened.at)
    }
}
