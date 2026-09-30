import AppKit
import SwiftUI
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A local thread's Browser tab (PaneBrowser, PaneStates › Browser): the toolbar, the page (or
/// Nothing open), the viewport menu, a picked element's popover, and the console drawer. The page
/// is the session's own web view (`BrowserPageView`), so switching tabs or threads never reloads it.
struct BrowserPane: View {
    var vm: ShepherdViewModel
    let session: BrowserSession
    let store: NativeThreadStore
    /// The layout is on screen: ⌘L and ⇧⌘C are the Browser's.
    let active: Bool
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ZStack(alignment: .topTrailing) {
                if session.hasPage {
                    BrowserPageArea(vm: vm, session: session)
                } else {
                    empty
                }
                if session.menuOpen { viewportMenu }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nwAnimation(.overlay, value: session.menuOpen)
            if session.hasPage {
                BrowserConsoleDrawer(console: session.console, open: session.consoleOpen) { session.consoleOpen.toggle() }
            }
        }
        .background {
            BrowserKeys(active: active, focusAddress: { session.focusAddress() }, select: { session.toggleSelecting() })
        }
        .onAppear { vm.loadDevServers(session) }
        .onChange(of: session.addressFocusRequests) { _, _ in
            session.menuOpen = false
            addressFocused = true
        }
        .onChange(of: addressFocused) { _, focused in
            if focused { address = BrowserAddress.editingText(session.url) }
        }
    }

    private var toolbar: some View {
        let display = BrowserAddress.display(session.url)
        let state = NWBrowserToolbarState(canGoBack: session.canGoBack, canGoForward: session.canGoForward, canReload: session.hasPage,
                                          isLoading: session.isLoading, selecting: session.selecting, viewportMenuOpen: session.menuOpen,
                                          canOpenExternally: session.hasPage)
        return NWBrowserToolbar(state: state, selectShortcut: vm.keybindings.display(.selectElement), actions: .init(
            back: { session.goBack() }, forward: { session.goForward() }, reload: { session.reload() },
            select: { session.toggleSelecting() }, viewport: { session.menuOpen.toggle() },
            openExternally: { vm.openInDefaultBrowser(session) })) {
            NWBrowserAddressField(host: display?.host, path: display?.path, hostChip: "This Mac", text: $address,
                                  isFocused: $addressFocused,
                                  submit: {
                                      if session.open(address: address) { addressFocused = false }
                                  },
                                  cancel: { addressFocused = false })
                .nwHelp("Search or enter a URL", shortcut: vm.keybindings.display(.focusAddressBar))
        }
    }

    private var empty: some View {
        let servers = session.devServers ?? []
        return NWBrowserEmpty(message: BrowserEmptyWords.message(waiting: session.waitingFor),
                              servers: servers.map { $0.item(startTitle: "Start on This Mac") }, openShortcut: vm.keybindings.display(.focusAddressBar),
                              start: { item in
                                  guard let server = servers.first(where: { $0.id == item.id }) else { return }
                                  vm.startDevServer(server, in: session)
                              },
                              openURL: { session.focusAddress() })
    }

    private var viewportMenu: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { session.menuOpen = false }
                .accessibilityHidden(true)
            NWViewportMenu(options: BrowserViewport.allCases.map(\.option), selection: session.viewport.rawValue, dark: session.dark,
                           choose: { option in session.viewport = BrowserViewport(rawValue: option.id) ?? .fit },
                           toggleDark: { session.dark.toggle() })
                .padding(.top, AppLayout.browserMenuDrop)
                .padding(.trailing, AppLayout.browserMenuTrailing)
                .nwTransition(.overlay, edge: .top)
        }
        .onKeyPress(.escape) {
            session.menuOpen = false
            return .handled
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
    @State private var popoverSize = CGSize(width: NWBrowserMetrics.popoverWidth, height: 90)

    var body: some View {
        GeometryReader { geo in
            let margin = AppLayout.browserFrameMargin
            let layout = session.viewport.layout(available: geo.size.width, margin: margin)
            let top: CGFloat = layout.framed ? margin : 0
            let origin = CGPoint(x: (geo.size.width - layout.width) / 2, y: top)
            ZStack(alignment: .topLeading) {
                if layout.framed { Color.nw.bgSunken }
                BrowserPageView(session: session)
                    .frame(width: layout.width, height: max(0, geo.size.height - top))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: layout.framed ? NWBrowserMetrics.frameRadius : 0,
                                                      topTrailingRadius: layout.framed ? NWBrowserMetrics.frameRadius : 0))
                    .overlay {
                        if layout.framed {
                            UnevenRoundedRectangle(topLeadingRadius: NWBrowserMetrics.frameRadius, topTrailingRadius: NWBrowserMetrics.frameRadius)
                                .strokeBorder(Color.nw.lineStrong, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                    }
                    .offset(x: origin.x, y: origin.y)
                if let rect = session.pickedRect, let picked = session.picked {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { session.dismissPick() }
                        .accessibilityHidden(true)
                    NWElementPopover(source: picked.sourceShort, add: { vm.addPickedElement(session) },
                                     copy: { vm.copyPickedSelector(session) })
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
                        .offset(BrowserPopoverPlacement.origin(for: rect, pageOrigin: origin, zoom: layout.zoom, popover: popoverSize,
                                                               area: geo.size, gap: AppLayout.browserPopoverGap).size)
                        .onKeyPress(.escape) {
                            session.dismissPick()
                            return .handled
                        }
                        .nwTransition(.overlay, edge: .leading)
                }
                // The agent is using the page: the ring, its pointer and the card. Native and over
                // the page, never in it; only the card takes clicks.
                if let agent = session.agentOverlay {
                    NWBrowserAgentOverlay(
                        note: agent.note,
                        pointer: agent.pointer.map { CGPoint(x: origin.x + $0.x * layout.zoom, y: origin.y + $0.y * layout.zoom) },
                        takeOver: { vm.takeOverBrowser(session) })
                        .frame(width: geo.size.width, height: geo.size.height)
                        .nwTransition(.overlay)
                }
            }
            .nwAnimation(.overlay, value: session.agentOverlay != nil)
            .onChange(of: layout.zoom, initial: true) { _, zoom in session.apply(zoom: zoom) }
        }
        .clipped()
        .nwAnimation(.overlay, value: session.picked)
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
            NWConsoleBar(network: console.network, warnings: console.warnings, open: open, toggle: toggle)
            if open {
                BrowserConsoleLines(lines: console.lines)
                    .frame(height: NWBrowserMetrics.consoleListHeight)
                    .background(Color.nw.bgBase)
            }
        }
    }
}

/// The console's lines: one row per line, each equal unless it changed, newest at the bottom.
struct BrowserConsoleLines: View, Equatable {
    let lines: [NWConsoleLine]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(lines) { line in
                    NWConsoleRow(line).equatable()
                }
            }
            .padding(.top, NW.Space.xs)
            .padding(.bottom, NW.Space.m)
        }
        .defaultScrollAnchor(.bottom)
        .accessibilityLabel("Console")
    }
}

/// ⌘L and ⇧⌘C while the Browser shows on screen, whatever has the keyboard in the window (the
/// composer, the page, a terminal): the Browser's scope in `KeybindingsStore`.
struct BrowserKeys: NSViewRepresentable {
    let active: Bool
    let focusAddress: () -> Void
    let select: () -> Void

    func makeNSView(context: Context) -> Watcher { Watcher() }

    func updateNSView(_ view: Watcher, context: Context) {
        view.active = active
        view.focusAddress = focusAddress
        view.select = select
    }

    static func dismantleNSView(_ view: Watcher, coordinator: ()) {
        view.stop()
    }

    final class Watcher: NSView {
        var active = false
        var focusAddress: () -> Void = {}
        var select: () -> Void = {}
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
            return false
        }
    }
}
