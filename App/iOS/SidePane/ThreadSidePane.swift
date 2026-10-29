import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The thread with its side pane on regular width (DuoOpenSidePane, DuoBookSidePane; the Mac's right sidebar). The pane docks by
/// `PadSplitLayout.pane`: beside the thread while the thread keeps 400pt and the pane 380pt, else over the thread's column. Half open
/// (iPhone Duo), the thread ends at the fold and the pane starts after it. The thread stays mounted either way, so its poll, draft,
/// scroll and toolbar (the side-pane button among it) stay.
struct ThreadWithSidePane: View {
    let ref: AgentRef
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let pane = navigator.sidePane
        if pane.isOpen, pane.tab == .changes, ReviewStores.shared.store(for: ref).padLayout == .full {
            PadChangesFull(ref: ref)
        } else {
            GeometryReader { proxy in
                let fold = proxy.verticalFold
                let dock = PadSplitLayout.pane(column: proxy.size.width)
                let alone = pane.isOpen && fold == nil && dock == .alone
                let threadWidth = fold?.lowerBound ?? dock.width.map { proxy.size.width - $0 - PadSplitLayout.dividerWidth }
                HStack(spacing: 0) {
                    ThreadScreen(ref: ref)
                        .paneWidth(pane.isOpen ? (alone ? 0 : fold?.lowerBound) : nil)
                        .padding(.trailing, pane.isOpen ? fold.map { $0.upperBound - $0.lowerBound } ?? 0 : 0)
                        .opacity(alone ? 0 : 1)
                        .accessibilityHidden(alone)
                    if pane.isOpen {
                        if !alone { SHHairline(.vertical, color: Color.sh.lineStrong) }
                        ThreadSidePane(ref: ref)
                            .paneWidth(fold != nil || alone ? nil : dock.width)
                            .shTransition(.pane, edge: .trailing)
                    }
                }
                .environment(\.threadTitleMaxWidth, pane.isOpen && !alone ? threadWidth : nil)
                // Beside the pane, the thread's title leads instead of centering across both.
                .toolbarRole(pane.isOpen && !alone ? .editor : .automatic)
                .shAnimation(.pane, value: pane.isOpen)
            }
        }
    }
}

/// A thread pushed over a stack: with its side pane on regular width, alone on a phone.
struct ThreadDestination: View {
    let ref: AgentRef
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if navigator.layout == .pad {
            ThreadWithSidePane(ref: ref)
        } else {
            ThreadScreen(ref: ref)
        }
    }
}

private extension PadSplitLayout.PaneDock {
    var width: CGFloat? {
        if case .beside(let width) = self { width } else { nil }
    }
}

/// The side pane (DuoSidePaneTabs): its tabs, then the open tab. Changes, Terminal and Subagents host the screens iOS already has;
/// Files (`ThreadFilesPane`, files.v1) and Browser (`ThreadBrowserPane`, browser.tunnel.v1) are their own views.
struct ThreadSidePane: View {
    let ref: AgentRef
    @Environment(MobileNavigator.self) private var navigator
    @Environment(ThreadStores.self) private var threads

    var body: some View {
        let pane = navigator.sidePane
        let store = threads.store(for: ref)
        let review = ReviewStores.shared.store(for: ref)
        let shown = PadSidePaneTab.allCases
        let tab = pane.tab
        VStack(spacing: 0) {
            SHPadPaneHead(SidePaneTabs.items(shown, review: review, thread: store, terminals: runningTerminals(ref)),
                          selection: tab.rawValue, select: { id in PadSidePaneTab(rawValue: id).map(pane.show) }) {
                SidePaneOptions(ref: ref, tab: tab)
            }
            Group {
                switch tab {
                case .changes: SidePaneChanges(ref: ref)
                case .files: ThreadFilesPane(thread: ref)
                case .terminal: TerminalScreen(ref: ref, embedded: true)
                case .subagents: PadSubagentInspector(ref: ref)
                case .browser: ThreadBrowserPane(thread: ref)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.sh.bgWindow)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side pane")
    }
}

/// The pane's ⋯: the open tab's options, then Hide side pane.
private struct SidePaneOptions: View {
    let ref: AgentRef
    let tab: PadSidePaneTab
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if tab == .changes {
            SidePaneChangesOptions(ref: ref)
        }
        Button("Hide side pane", systemImage: "sidebar.right") { navigator.sidePane.isOpen = false }
    }
}

/// The pane's tabs and the thread menu's rows: one glyph and name per tab, with what each says of its work.
@MainActor
enum SidePaneTabs {
    static func systemImage(_ tab: PadSidePaneTab) -> String {
        switch tab {
        case .changes: "plus.forwardslash.minus"
        case .files: "folder"
        case .terminal: "apple.terminal"
        case .subagents: SHGlyph.gitBranch.symbolName
        case .browser: "globe"
        }
    }

    static func items(_ tabs: [PadSidePaneTab], review: ReviewStore, thread: NativeThreadStore, terminals: Int) -> [SHPadPaneTab] {
        let subagentsRun = nativeRunTally(thread.subagents).map { AgentState($0.phase) } == .running
        return tabs.map { tab in
            let count: Int? = switch tab {
            case .changes: review.loaded ? review.entries.count : nil
            default: nil
            }
            let status: AgentState? = switch tab {
            case .terminal: terminals > 0 ? .running : nil
            case .subagents: subagentsRun ? .running : nil
            default: nil
            }
            return SHPadPaneTab(id: tab.rawValue, title: tab.title, systemImage: systemImage(tab), count: count, status: status)
        }
    }
}
