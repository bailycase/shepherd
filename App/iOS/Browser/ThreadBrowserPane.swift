import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Regular-width Browser shows the thread's tabs and console. The compact screen shows the
// selected tab without reloading it or changing which tabs the thread keeps.

extension MobileLayout {
    /// The address bar (DuoSidePaneTabs: 40pt, radius 8).
    static let browserAddressHeight: CGFloat = 40
    /// Reload's and the menu's width in it, as tall as a touch target.
    static let browserBarButton: CGFloat = 36
    /// Nothing open: the globe (iPadPaneBrowser draws it bare), its title in 22 semibold, and the
    /// dev servers' words in 15.
    static let browserEmptyCircle: CGFloat = 44
    static let browserEmptyGlyph: CGFloat = 36
    static let browserEmptyTitle: CGFloat = 22
    static let browserServerText: CGFloat = 15
    static let browserServerDetail: CGFloat = 13
    /// The line under the page: its top and bottom padding.
    static let browserFootTop: CGFloat = 10
    static let browserFootBottom: CGFloat = 14
    /// A picked element's popover keeps this far from the element and the card's edges.
    static let browserPopoverGap: CGFloat = 12
}

/// The thread's Browser, for the side pane: the page fills what the pane gives it.
struct ThreadBrowserPane: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        if let host = hosts.host(thread.host) {
            MobileBrowserView(tabs: MobileBrowsers.shared.tabs(thread, host: host), host: host)
        } else {
            SHEmptyState(Text("No host"), message: "This thread’s host was removed.", showsMark: false) { EmptyView() }
        }
    }
}

/// The thread's Browser pushed full screen (compact width).
struct ThreadBrowserScreen: View {
    let thread: AgentRef

    var body: some View {
        ThreadBrowserPane(thread: thread)
            .padding(.top, SH.Space.m)
            .background(Color.sh.bgWindow)
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
    }
}

private struct MobileBrowserView: View {
    let tabs: MobileBrowserTabs
    let host: MobileHost
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let regular = navigator.layout == .pad
        VStack(spacing: 0) {
            if regular { BrowserTabChrome(tabs: tabs) }
            if let page = tabs.selectedPage {
                BrowserPageView(page: page, host: host, regular: regular).id(page.id)
                if regular { BrowserConsoleStrip(page: page) }
            }
        }
        .background(Color.sh.bgWindow)
    }
}

private struct BrowserTabChrome: View {
    let tabs: MobileBrowserTabs
    @State private var listOpen = false

    var body: some View {
        let items = tabs.items
        let selection = tabs.selection
        VStack(spacing: 0) {
            SHBrowserTabStrip(items: items, selection: selection.selected, canAdd: selection.canAdd, listOpen: listOpen, touch: true,
                              actions: .init(select: tabs.select, close: tabs.close, new: { _ = tabs.add() }, toggleList: { listOpen.toggle() }),
                              listButtonModifier: TabListPopover(isOpen: $listOpen, menu: menu))
            if let notice = tabs.notice {
                SHBrowserTabsNote(message: notice == .cap
                    ? "This thread has \(BrowserTabSelection.limit) tabs, the most it keeps. New links open in this tab."
                    : "A link opened a new window. Shepherd opened it as a tab.",
                    glyph: notice == .cap ? SHBrowserTabsNote.capGlyph : SHBrowserTabsNote.globeGlyph, touch: true) {
                        tabs.notice = nil
                    }
            }
        }
        #if DEBUG
        .onChange(of: tabs.fixtureListOpen, initial: true) { _, open in listOpen = open }
        #endif
    }

    private var menu: SHBrowserTabMenu {
        SHBrowserTabMenu(items: tabs.items, selection: tabs.selection.selected, maxTabs: BrowserTabSelection.limit, touch: true,
                         note: "sign-ins shared across this thread", select: { tabs.select($0); listOpen = false },
                         closeOthers: { tabs.closeOthers(); listOpen = false })
    }

    private struct TabListPopover: ViewModifier {
        @Binding var isOpen: Bool
        let menu: SHBrowserTabMenu

        func body(content: Content) -> some View {
            content.popover(isPresented: $isOpen, attachmentAnchor: .point(.bottom), arrowEdge: .top) {
                menu
                    .presentationCompactAdaptation(.popover)
                    .presentationBackground(Color.sh.bgRaised)
            }
        }
    }
}

private struct BrowserConsoleStrip: View {
    let page: BrowserPage

    var body: some View {
        let console = page.console
        VStack(spacing: 0) {
            SHConsoleBar(network: console.network, warnings: console.warnings, open: page.consoleOpen, touch: true) {
                page.consoleOpen.toggle()
            }
            if page.consoleOpen {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(console.lines) { SHConsoleRow($0).equatable() }
                    }
                    .padding(.vertical, SH.Space.s)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollBounceBehavior(.basedOnSize)
                .frame(idealHeight: SHBrowserMetrics.consoleListHeight, maxHeight: SHBrowserMetrics.consoleListHeight)
                .background(Color.sh.bgSunken)
                .accessibilityLabel("Console output")
            }
        }
    }
}

/// What the page's state is, in the order it is decided.
private enum BrowserPhase: Equatable {
    case offline
    case unsupported
    case waiting(URL)
    case page
    case nothingOpen
}

private struct BrowserPageView: View {
    let page: BrowserPage
    let host: MobileHost
    let regular: Bool
    @Environment(ThreadStores.self) private var threads
    @FocusState private var editing: Bool
    @State private var address = ""

    private struct LoadKey: Equatable {
        var session: UUID?
        var served: Bool
    }

    var body: some View {
        let sh = Color.sh
        let served = page.isServed
        let phase: BrowserPhase = if host.phase != .connected, page.url == nil {
            .offline
        } else if host.phase == .connected, !host.supports(RemoteProtocol.browserTunnelCapability) {
            .unsupported
        } else if let waiting = page.waitingFor {
            .waiting(waiting)
        } else if page.url != nil {
            .page
        } else {
            .nothingOpen
        }
        VStack(spacing: 0) {
            if regular {
                regularToolbar(served: served)
            } else {
                addressBar(served: served)
                    .padding(.horizontal, SH.Space.l)
                    .padding(.bottom, MobileLayout.browserFootTop)
            }
            ZStack(alignment: .top) {
                content(phase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = page.notice {
                    SHBrowserNotice(message: notice) { page.notice = nil }
                        .padding(SH.Space.l)
                }
            }
            .background(sh.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: regular ? 0 : SH.Radius.m))
            .shBorder(regular ? .clear : sh.lineSubtle, radius: SH.Radius.m)
            .padding(.horizontal, regular ? 0 : SH.Space.l)
            if !regular {
                Text("localhost here is the host’s dev server, forwarded over Shepherd’s connection.")
                    .font(.sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, SH.Space.xl)
                    .padding(.top, MobileLayout.browserFootTop)
                    .padding(.bottom, MobileLayout.browserFootBottom)
                    .overlay(alignment: .top) { SHHairline() }
                    .padding(.top, MobileLayout.browserFootTop)
            }
        }
        .task(id: LoadKey(session: host.session, served: served)) { await page.loadDevServers() }
        .onChange(of: editing) { _, now in
            if now { address = page.url.map(BrowserAddress.editingText) ?? "" }
        }
    }

    // MARK: Address bar

    private func regularToolbar(served: Bool) -> some View {
        HStack(spacing: 0) {
            navigationButton("Back", glyph: "chevron.left", enabled: served && page.canGoBack, action: page.goBack)
            navigationButton("Forward", glyph: "chevron.right", enabled: served && page.canGoForward, action: page.goForward)
            reloadButton(served: served)
            addressBar(served: served)
            Button { page.toggleSelecting() } label: { Image(systemName: shElementGlyph) }
                .buttonStyle(.shIcon(isOn: page.selecting, size: SH.Height.touch))
                .disabled(page.url == nil || !served)
                .accessibilityLabel(page.selecting ? "Stop selecting" : "Select an element")
                .accessibilityAddTraits(page.selecting ? .isSelected : [])
        }
        .padding(.horizontal, SH.Space.s)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private func navigationButton(_ label: LocalizedStringKey, glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: glyph) }
            .buttonStyle(.shIcon(size: SH.Height.touch))
            .disabled(!enabled)
            .accessibilityLabel(label)
    }

    private func addressBar(served: Bool) -> some View {
        let sh = Color.sh
        let shown = BrowserAddress.display(page.url ?? page.waitingFor)
        return HStack(spacing: regular ? SH.Space.s : SH.Space.m) {
            Image(systemName: "globe")
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                TextField("Address", text: $address, prompt: Text("Port or URL").foregroundStyle(sh.textTertiary))
                    .font(.sh(.code))
                    .foregroundStyle(sh.textPrimary)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($editing)
                    .disabled(!served)
                    .onSubmit {
                        if page.open(address: address) { editing = false }
                    }
                    .opacity(editing || shown == nil ? 1 : 0)
                if !editing, let shown {
                    Button { editing = true } label: {
                        (Text(shown.host).foregroundStyle(sh.textPrimary) + Text(shown.path).foregroundStyle(sh.textSecondary))
                            .font(.sh(.code))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!served)
                    .accessibilityLabel("Address, \(shown.host)\(shown.path)")
                }
            }
            .frame(maxWidth: .infinity)
            serversMenu(served: served)
            if !regular { reloadButton(served: served) }
        }
        .padding(.leading, regular ? SH.Space.m : SH.Space.l)
        .padding(.trailing, SH.Space.xs)
        .frame(height: regular ? SH.Height.touch : MobileLayout.browserAddressHeight)
        .background(sh.bgSelected, in: Capsule())
    }

    private func reloadButton(served: Bool) -> some View {
        Button { page.reload() } label: {
            ZStack {
                Image(systemName: "xmark").opacity(page.isLoading ? 1 : 0)
                Image(systemName: "arrow.clockwise").opacity(page.isLoading ? 0 : 1)
            }
            .font(.sh(.ui))
        }
        .buttonStyle(.shIcon(size: regular ? SH.Height.touch : MobileLayout.browserBarButton))
        .disabled(page.url == nil || !served)
        .accessibilityLabel(page.isLoading ? "Stop loading" : "Reload")
    }

    /// "from macbook", and the host's dev servers under it: open one (waiting for it to answer), or
    /// start it on the host.
    private func serversMenu(served: Bool) -> some View {
        let sh = Color.sh
        let servers = page.devServers ?? []
        return Menu {
            let open = servers.filter { $0.port != nil }
            if !open.isEmpty {
                Section("Open") {
                    ForEach(open) { server in
                        Button {
                            if let url = server.url { page.wait(for: url) }
                        } label: {
                            Label("\(server.command) · :\(server.port ?? 0)", systemImage: "globe")
                        }
                    }
                }
            }
            if !servers.isEmpty {
                Section("Start on \(page.hostName)") {
                    ForEach(servers) { server in
                        Button {
                            Task { await page.start(server) }
                        } label: {
                            Label(server.command, systemImage: "play.fill")
                        }
                    }
                }
            }
            Button {
                editing = true
            } label: {
                Label("Open a port or URL", systemImage: "character.cursor.ibeam")
            }
        } label: {
            HStack(spacing: SH.Space.xs) {
                Text("from \(page.hostName)").lineLimit(1)
                Image(systemName: SHGlyph.popupChevrons.symbolName)
            }
            .font(.sh(.caption))
            .foregroundStyle(sh.textTertiary)
            .frame(minHeight: SH.Height.touch)
            .contentShape(Rectangle())
        }
        .disabled(!served)
        .accessibilityLabel("From \(page.hostName). Dev servers")
    }

    // MARK: The card

    @ViewBuilder
    private func content(_ phase: BrowserPhase) -> some View {
        switch phase {
        case .offline:
            BrowserMessage(title: "\(page.hostName) is offline",
                           message: "Its dev servers open here when it’s back.")
        case .unsupported:
            BrowserMessage(title: "No Browser on \(page.hostName)", message: RemoteHostClient.tunnelsRefusal)
        case .waiting(let url):
            BrowserWaiting(page: page, url: url)
        case .page:
            BrowserWebView(page: page, allowsPopupTabs: regular)
                .overlay { BrowserPickOverlay(page: page, add: addPicked) }
        case .nothingOpen:
            BrowserNothingOpen(page: page) { editing = true }
        }
    }
}

extension BrowserPageView {
    /// Add to message: the picked element joins the thread's composer as a chip, at most five a message.
    func addPicked() {
        guard let element = page.picked else { return }
        if threads.store(for: page.ref).attach(element: element) {
            page.dismissPick()
        } else {
            page.notice = "A message takes at most \(BrowserElement.maxPerMessage) page elements. Send or remove one first."
        }
    }
}

/// A picked element's popover over the page (iPadPaneBrowser): beside the element, Add to message and Copy selector; a tap
/// anywhere else closes it. The page's CSS pixels are points here.
private struct BrowserPickOverlay: View {
    let page: BrowserPage
    let add: () -> Void
    @State private var popoverSize = CGSize(width: SHBrowserMetrics.popoverWidth, height: SH.Height.touch * 2)

    var body: some View {
        GeometryReader { geo in
            if let rect = page.pickedRect, let picked = page.picked {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { page.dismissPick() }
                        .accessibilityHidden(true)
                    SHElementPopover(source: picked.sourceShort, add: add, copy: {
                        UIPasteboard.general.string = picked.selector
                        page.dismissPick()
                    })
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { popoverSize = $0 }
                    .offset(placement(rect, area: geo.size))
                    .shTransition(.overlay, edge: .leading)
                }
            }
        }
    }

    private func placement(_ rect: CGRect, area: CGSize) -> CGSize {
        let origin = BrowserPopoverPlacement.origin(for: rect, pageOrigin: .zero, zoom: 1, popover: popoverSize, area: area,
                                                    gap: MobileLayout.browserPopoverGap)
        return CGSize(width: origin.x, height: origin.y)
    }
}

/// Nothing open, or nothing can be: the globe, a title and a line.
private struct BrowserMessage<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    init(title: String, message: String, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        let sh = Color.sh
        ScrollView {
            VStack(spacing: SH.Space.l) {
                Image(systemName: "globe")
                    .font(.system(size: MobileLayout.browserEmptyGlyph))
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: MobileLayout.browserEmptyCircle, height: MobileLayout.browserEmptyCircle)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.shSans(MobileLayout.browserEmptyTitle, .semibold))
                    .foregroundStyle(sh.textPrimary)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                actions
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Start ran, or a server was picked: its port is tried until it answers.
private struct BrowserWaiting: View {
    let page: BrowserPage
    let url: URL

    var body: some View {
        let host = BrowserAddress.display(url)?.host ?? url.absoluteString
        let port = BrowserTunnelTarget.port(of: url)
        let servers = (page.devServers ?? []).filter { $0.port == port }
        BrowserMessage(title: "Waiting for \(host)", message: "Its page opens here when it answers on \(page.hostName).") {
            SHBusyLabel("Waiting…")
            ForEach(servers) { server in
                Button {
                    Task { await page.start(server) }
                } label: {
                    Label("Start \(server.command) on \(page.hostName)", systemImage: "play.fill")
                }
                .buttonStyle(.sh(.secondary, size: .m))
                .frame(minHeight: SH.Height.touch)
            }
            Button("Cancel") { page.stopWaiting() }
                .buttonStyle(.sh(.ghost, size: .m))
                .frame(minHeight: SH.Height.touch)
        }
    }
}

/// Nothing open: the host's dev servers, each with Start on the host, and Open a port.
private struct BrowserNothingOpen: View {
    let page: BrowserPage
    let openAddress: () -> Void

    var body: some View {
        let sh = Color.sh
        let servers = page.devServers
        let message = switch servers {
        case nil: "Looking for dev servers in this thread’s folder on \(page.hostName)…"
        case let servers? where servers.isEmpty: "No dev server in this thread’s folder. Open a port \(page.hostName) serves, such as 5173."
        default: "None of them is running on \(page.hostName). Start one, or open a port."
        }
        BrowserMessage(title: "No page open", message: message) {
            VStack(spacing: SH.Space.l) {
                // The host's dev servers in a card, a hairline between them (iPadPaneBrowser).
                if let servers, !servers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(servers) { server in
                            HStack(spacing: SH.Space.l) {
                                Image(systemName: "terminal")
                                    .font(.sh(.caption))
                                    .foregroundStyle(sh.textSecondary)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                                    Text(server.command).font(.shMono(MobileLayout.browserServerText)).foregroundStyle(sh.textPrimary).lineLimit(1)
                                    Text(server.detail).font(.shSans(MobileLayout.browserServerDetail)).foregroundStyle(sh.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button {
                                    Task { await page.start(server) }
                                } label: {
                                    Text("Start on \(page.hostName)").font(.shSans(MobileLayout.browserServerText, .medium))
                                        .foregroundStyle(sh.textPrimary).lineLimit(1)
                                        .frame(minHeight: SH.Height.touch).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .fixedSize()
                                .accessibilityLabel("Start \(server.command) on \(page.hostName)")
                            }
                            .padding(.horizontal, SH.Space.xl)
                            .padding(.vertical, SH.Space.xs)
                            .overlay(alignment: .top) { SHHairline().padding(.leading, SH.Space.xl).opacity(server.id == servers.first?.id ? 0 : 1) }
                        }
                    }
                    .shCard(radius: SH.Radius.xxl, line: sh.lineSubtle)
                }
                Button(action: openAddress) {
                    Text("Open a port or URL").font(.shSans(MobileLayout.browserServerText, .medium))
                        .foregroundStyle(sh.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, SH.Space.m)
        }
    }
}
