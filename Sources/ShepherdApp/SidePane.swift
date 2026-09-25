import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The side pane's tab strip over the current tab (PaneStates, Review): Changes today, with its
/// count of changed files. Browser, Artifacts and Files are not built, so they have no tab and no
/// placeholder; each joins `SidePaneTab` and the switch below when it is. The subagent inspector
/// is not a tab: it takes the whole pane over while a run is inspected (`AgentLayoutView`).
struct SidePaneView: View {
    var vm: ShepherdViewModel
    let owner: SidePaneOwner
    let tab: SidePaneTab
    let news: Set<SidePaneTab>
    let review: ReviewSession?
    let store: NativeThreadStore

    var body: some View {
        VStack(spacing: 0) {
            SidePaneTabBar(vm: vm, owner: owner, tab: tab, news: news, review: review)
            ZStack {
                switch tab {
                case .changes:
                    if let review {
                        ReviewPaneHost(session: review, actions: vm.reviewActions(for: review, remote: isRemote), store: store)
                            .id(review.id)
                            .nwTransition(.content)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.nw.bgWindow)
    }

    private var isRemote: Bool {
        if case .remote = owner { return true }
        return false
    }
}

/// The strip, in a view of its own: a count that changes redraws it, not the tab under it.
private struct SidePaneTabBar: View {
    var vm: ShepherdViewModel
    let owner: SidePaneOwner
    let tab: SidePaneTab
    let news: Set<SidePaneTab>
    let review: ReviewSession?

    var body: some View {
        NWSidePaneTabs(SidePaneTabs.items(news: news, changedFiles: review.flatMap { $0.isLoading ? nil : $0.files.count }),
                       selection: tab.rawValue,
                       select: { id in SidePaneTab(rawValue: id).map { vm.showSidePane(owner, tab: $0) } },
                       closeShortcut: vm.keybindings.display(.toggleRightPane),
                       close: { vm.hideSidePane(owner) }) {
            // The pane's ⋯ menu: what the tab on screen offers, then the pane's own. Split below,
            // Open in its own window and Show tabs wait for the tabs that need them.
            if tab == .changes, let review {
                ReviewOptionItems(session: review)
                Divider()
            }
            Button("Reset Width") { vm.subagentInspector.width = 0 }
                .disabled(vm.subagentInspector.width == 0)
        }
    }
}

/// The strip's tabs, from what each one holds.
enum SidePaneTabs {
    static func items(news: Set<SidePaneTab>, changedFiles: Int?) -> [NWSidePaneTab] {
        SidePaneTab.allCases.map { tab in
            let count: Int? = switch tab {
            case .changes: changedFiles
            }
            return NWSidePaneTab(id: tab.rawValue, title: tab.title, systemImage: tab.systemImage, count: count,
                                 news: news.contains(tab), shortcut: tab.shortcutDisplay)
        }
    }
}
