import AppKit
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A thread's Browser tab (PaneBrowser, BrowserTabs boards): the tab strip, a note, the toolbar, the
/// page (or Nothing open), the viewport menu, a picked element's popover, the agent's bar and the
/// console drawer. `session` is the thread's root page: it owns the remote claim (`browserPaneAppeared`)
/// and the tabs; the strip, toolbar, page and console are the tab on screen, `tabs.selectedPage`.
/// Each page is a session with its own web view, so switching tabs or threads never reloads one.
struct BrowserPane: View {
    var vm: ShepherdViewModel
    let session: BrowserSession
    let store: NativeThreadStore
    /// The layout is on screen: ⌘L, ⌘T and ⇧⌘C are the Browser's.
    let active: Bool
    @State private var address = ""
    @State private var listOpen: Bool
    /// ⌘T or New tab made a page that has no address yet: focus its field once it is the one shown.
    @State private var focusNewTab = false
    @FocusState private var addressFocused: Bool

    init(vm: ShepherdViewModel, session: BrowserSession, store: NativeThreadStore, active: Bool, listOpen: Bool = false) {
        self.vm = vm
        self.session = session
        self.store = store
        self.active = active
        _listOpen = State(initialValue: listOpen)
    }

    private var tabs: BrowserTabs { session.tabs }
    private var page: BrowserSession { tabs.selectedPage }

    var body: some View {
        let page = page
        VStack(spacing: 0) {
            tabStrip
            tabsNote
            // The list hangs under the note (or the strip), over the toolbar and the page (BrowserTabsFull).
            VStack(spacing: 0) {
            toolbar(page)
            ZStack(alignment: .topTrailing) {
                if page.hasPage {
                    BrowserPageArea(vm: vm, session: page)
                        .id(page.tabID)
                } else {
                    empty(page)
                }
                if page.menuOpen { viewportMenu(page) }
                // Why nothing loaded (a remote page's port that can't be forwarded here), or that another
                // Mac took the agent's browser. The thread's own notice belongs to the root, so it stays in
                // view whichever tab is shown, and it is dismissed on the page that holds it.
                if let (owner, notice) = visibleNotice(page) {
                    SHBrowserNotice(message: notice.message, dismiss: { owner.dismissNotice() })
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .shTransition(.overlay, edge: .top)
                }
                // The agent works in a tab that is not the one shown.
                if let other = tabs.agentPage, other !== page {
                    SHAgentElsewhere(title: other.tabTitle) { tabs.select(other.tabID) }
                        .padding(SH.Space.l)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .shTransition(.overlay, edge: .bottom)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shAnimation(.overlay, value: page.menuOpen)
            .shAnimation(.overlay, value: visibleNotice(page)?.1)
            .shAnimation(.overlay, value: tabs.agentPage?.tabID)
            if let agent = page.agentOverlay {
                SHAgentBar(note: agent.note, takeOver: { vm.takeOverBrowser(page) })
                    .shTransition(.overlay, edge: .bottom)
            }
            if page.hasPage {
                BrowserConsoleDrawer(console: page.console, open: page.consoleOpen) { page.consoleOpen.toggle() }
            }
            }
            .overlay { if listOpen { tabList } }
        }
        .shAnimation(.overlay, value: page.agentOverlay != nil)
        .background {
            BrowserKeys(active: active, focusAddress: { page.focusAddress() }, select: { page.toggleSelecting() }, newTab: { newTab() })
        }
        // A remote thread's dev servers come from its host, so they are asked for again when it connects.
        .task(id: TabLoad(tab: page.tabID, connected: session.remote?.isConnected)) { vm.loadDevServers(page) }
        // On a remote thread the tab on screen claims the agent's browser on the host, and lets it go
        // a while after it goes out of sight (docs/browser.md › Remote). The claim is the thread's, so
        // it is the root's, whichever tab is shown.
        .onAppear { vm.browserPaneAppeared(session) }
        .onDisappear { vm.browserPaneDisappeared(session) }
        .onChange(of: page.addressFocusRequests) { old, new in
            guard new != old else { return }
            page.menuOpen = false
            addressFocused = true
        }
        .onChange(of: page.tabID) { _, _ in
            // Another tab: whatever was being typed belongs to the one left, and a field that was
            // already being edited keeps its focus through the change, so its text is set here.
            listOpen = false
            addressFocused = false
            address = BrowserAddress.editingText(page.url)
            if focusNewTab {
                focusNewTab = false
                addressFocused = true
            }
        }
        .onChange(of: addressFocused) { _, focused in
            if focused { address = BrowserAddress.editingText(page.url) }
        }
    }

    /// The page's own notice, else the thread's (the root's) while another tab is shown.
    private func visibleNotice(_ page: BrowserSession) -> (BrowserSession, BrowserNotice)? {
        if let notice = page.notice { return (page, notice) }
        if page !== session, let notice = session.notice { return (session, notice) }
        return nil
    }

    private struct TabLoad: Equatable {
        let tab: UUID
        let connected: Bool?
    }

    private func newTab() {
        listOpen = false
        focusNewTab = true
        if tabs.newTab() == nil { focusNewTab = false }
    }

    // MARK: Tabs

    private var tabStrip: some View {
        let items = tabs.pages.map(\.tabItem)
        return SHBrowserTabStrip(items: items, selection: page.tabID, canAdd: tabs.canAdd, listOpen: listOpen,
                                 newShortcut: vm.keybindings.display(.browserNewTab),
                                 actions: .init(select: { tabs.select($0) }, close: { tabs.close($0) }, new: { newTab() },
                                                toggleList: { listOpen.toggle() }))
            .shAnimation(.list, value: items)
    }

    @ViewBuilder private var tabsNote: some View {
        if let notice = tabs.notice {
            SHBrowserTabsNote(message: notice.words, glyph: notice.glyph, dismiss: { tabs.dismissNotice() })
                .shTransition(.overlay, edge: .top)
        } else if let opened = tabs.openedPage {
            SHBrowserTabsNote(message: "The agent opened \(opened.tabTitle) in a new tab.",
                              action: .init("Show it") { tabs.showOpenedPage() }, dismiss: { tabs.dismissNotice() })
                .shTransition(.overlay, edge: .top)
        }
    }

    private var tabList: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { listOpen = false }
                .accessibilityHidden(true)
            SHBrowserTabMenu(items: tabs.pages.map(\.tabItem), selection: page.tabID, maxTabs: BrowserTabs.maxTabs,
                             select: { tabs.select($0); listOpen = false },
                             closeOthers: { tabs.closeOthers(); listOpen = false })
                .padding(.top, AppLayout.browserMenuDrop)
                .padding(.trailing, SH.Space.m)
                .shTransition(.overlay, edge: .top)
        }
        .onKeyPress(.escape) {
            listOpen = false
            return .handled
        }
    }

    // MARK: The page

    private func toolbar(_ page: BrowserSession) -> some View {
        let display = BrowserAddress.display(page.url)
        let state = SHBrowserToolbarState(canGoBack: page.canGoBack, canGoForward: page.canGoForward, canReload: page.hasPage,
                                          isLoading: page.isLoading, selecting: page.selecting, viewportMenuOpen: page.menuOpen,
                                          canOpenExternally: page.hasPage)
        return SHBrowserToolbar(state: state, selectShortcut: vm.keybindings.display(.selectElement), actions: .init(
            back: { page.goBack() }, forward: { page.goForward() }, reload: { page.reload() },
            select: { page.toggleSelecting() }, viewport: { page.menuOpen.toggle() },
            openExternally: { vm.openInDefaultBrowser(page) })) {
            SHBrowserAddressField(host: display?.host, path: display?.path, hostChip: page.hostChip, text: $address,
                                  isFocused: $addressFocused,
                                  submit: {
                                      if page.open(address: address) { addressFocused = false }
                                  },
                                  cancel: { addressFocused = false })
                .shHelp("Search or enter a URL", shortcut: vm.keybindings.display(.focusAddressBar))
        }
    }

    private func empty(_ page: BrowserSession) -> some View {
        let servers = page.devServers ?? []
        return SHBrowserEmpty(message: BrowserEmptyWords.message(waiting: page.waitingFor),
                              servers: servers.map { $0.item(startTitle: page.startTitle) }, openShortcut: vm.keybindings.display(.focusAddressBar),
                              start: { item in
                                  guard let server = servers.first(where: { $0.id == item.id }) else { return }
                                  vm.startDevServer(server, in: page)
                              },
                              openURL: { page.focusAddress() })
    }

    private func viewportMenu(_ page: BrowserSession) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { page.menuOpen = false }
                .accessibilityHidden(true)
            SHViewportMenu(options: BrowserViewport.allCases.map(\.option), selection: page.viewport.rawValue, dark: page.dark,
                           choose: { option in page.viewport = BrowserViewport(rawValue: option.id) ?? .fit },
                           toggleDark: { page.dark.toggle() })
                .padding(.top, AppLayout.browserMenuDrop)
                .padding(.trailing, AppLayout.browserMenuTrailing)
                .shTransition(.overlay, edge: .top)
        }
        .onKeyPress(.escape) {
            page.menuOpen = false
            return .handled
        }
    }
}

@MainActor
extension BrowserTabNotice {
    /// What the note under the strip says.
    var words: String {
        switch self {
        case .popup: "A link opened a new window. Shepherd opened it as a tab."
        case .cap: "This thread has \(BrowserTabs.maxTabs) tabs, the most it keeps. New links open in this tab."
        }
    }

    var glyph: String {
        switch self {
        case .popup: SHBrowserTabsNote.globeGlyph
        case .cap: SHBrowserTabsNote.capGlyph
        }
    }
}

extension BrowserSession {
    /// The page as the strip and the list draw it: its title, its address, and the tile of its site.
    var tabItem: SHBrowserTabItem {
        let display = BrowserAddress.display(url)
        let host = display?.host ?? ""
        return SHBrowserTabItem(id: tabID, title: tabTitle, address: display.map { $0.host + $0.path } ?? "",
                                letter: SHBrowserTabTint.initial(host: host), tint: .forHost(host), source: tabSource.item,
                                agentActive: agentOverlay != nil, unseen: tabUnseen)
    }
}

private extension BrowserTabSource {
    var item: SHBrowserTabSource {
        switch self {
        case .user: .user
        case .agent: .agent
        case .link: .link
        }
    }
}

/// What Nothing open says under "No page open" (the board's words exactly, the user's decision
/// 2026-09-29).
enum BrowserEmptyWords {
    static func message(waiting: URL?) -> String {
        if let waiting, let host = BrowserAddress.display(waiting)?.host {
            return "Waiting for \(host) to answer. Its page opens here when it does."
        }
        return "The agent opens pages here when it starts a dev server. Ports on remote hosts are forwarded for you."
    }
}

/// The page, fitted to the pane or in a frame at a chosen width (PaneStates › viewport), with a
/// picked element's popover beside the element.
private struct BrowserPageArea: View {
    var vm: ShepherdViewModel
    let session: BrowserSession
    @State private var popoverSize = CGSize(width: SHBrowserMetrics.popoverWidth, height: 90)

    var body: some View {
        GeometryReader { geo in
            let margin = AppLayout.browserFrameMargin
            let layout = session.viewport.layout(available: geo.size.width, margin: margin)
            let top: CGFloat = layout.framed ? margin : 0
            let origin = CGPoint(x: (geo.size.width - layout.width) / 2, y: top)
            ZStack(alignment: .topLeading) {
                if layout.framed { Color.sh.bgSunken }
                BrowserPageView(session: session)
                    .frame(width: layout.width, height: max(0, geo.size.height - top))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: layout.framed ? SHBrowserMetrics.frameRadius : 0,
                                                      topTrailingRadius: layout.framed ? SHBrowserMetrics.frameRadius : 0))
                    .overlay {
                        if layout.framed {
                            UnevenRoundedRectangle(topLeadingRadius: SHBrowserMetrics.frameRadius, topTrailingRadius: SHBrowserMetrics.frameRadius)
                                .strokeBorder(Color.sh.lineStrong, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .offset(x: origin.x, y: origin.y)
                if let rect = session.pickedRect, let picked = session.picked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { session.dismissPick() }
                        .accessibilityHidden(true)
                    SHElementPopover(source: picked.sourceShort, add: { vm.addPickedElement(session) },
                                     copy: { vm.copyPickedSelector(session) })
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
                        .offset(BrowserPopoverPlacement.origin(for: rect, pageOrigin: origin, zoom: layout.zoom, popover: popoverSize,
                                                               area: geo.size, gap: AppLayout.browserPopoverGap).size)
                        .onKeyPress(.escape) {
                            session.dismissPick()
                            return .handled
                        }
                        .shTransition(.overlay, edge: .leading)
                }
                // The agent is using the page: the ring and its pointer. Native and over the page, never
                // in it, and they take no clicks. The words and Take over are the bar under the page.
                if let agent = session.agentOverlay {
                    SHBrowserAgentOverlay(
                        pointer: agent.pointer.map { CGPoint(x: origin.x + $0.x * layout.zoom, y: origin.y + $0.y * layout.zoom) })
                        .frame(width: geo.size.width, height: geo.size.height)
                        .shTransition(.overlay)
                }
            }
            .shAnimation(.overlay, value: session.agentOverlay != nil)
            .onChange(of: layout.zoom, initial: true) { _, zoom in session.apply(zoom: zoom) }
        }
        .clipped()
        .shAnimation(.overlay, value: session.picked)
    }
}

private extension CGPoint {
    var size: CGSize { CGSize(width: x, height: y) }
}

/// The console drawer (PaneBrowser): the bar, then the lines while open, a lazy list that
/// follows the newest line.
struct BrowserConsoleDrawer: View {
    let console: BrowserConsoleLog
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SHConsoleBar(network: console.network, warnings: console.warnings, open: open, toggle: toggle)
            if open {
                BrowserConsoleLines(lines: console.lines)
                    .frame(height: SHBrowserMetrics.consoleListHeight)
                    .background(Color.sh.bgBase)
            }
        }
    }
}

/// The console's lines: one row per line, each equal unless it changed, newest at the bottom.
struct BrowserConsoleLines: View, Equatable {
    let lines: [SHConsoleLine]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(lines) { line in
                    SHConsoleRow(line).equatable()
                }
            }
            .padding(.top, SH.Space.xs)
            .padding(.bottom, SH.Space.m)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityLabel("Console")
    }
}

/// ⌘L, ⇧⌘C and ⌘T while the Browser shows on screen, whatever has the keyboard in the window (the
/// composer, the page, a terminal): the Browser's scope in `KeybindingsStore`.
struct BrowserKeys: NSViewRepresentable {
    let active: Bool
    let focusAddress: () -> Void
    let select: () -> Void
    let newTab: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.active = active
        view.focusAddress = focusAddress
        view.select = select
        view.newTab = newTab
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stop()
    }

    final class Watcher: NSView {
        var active = false
        var focusAddress: () -> Void = {}
        var select: () -> Void = {}
        var newTab: () -> Void = {}
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else { start() }
        }

        private func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) == true }
                return taken ? nil : event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        func handle(_ event: NSEvent) -> Bool {
            guard active, event.window === window, window != nil, !isHiddenOrHasHiddenAncestor else { return false }
            let keys = KeybindingsStore.shared
            if keys.chord(for: .focusAddressBar).matches(event) {
                focusAddress()
                return true
            }
            if keys.chord(for: .selectElement).matches(event) {
                select()
                return true
            }
            if keys.chord(for: .browserNewTab).matches(event) {
                newTab()
                return true
            }
            return false
        }
    }
}
