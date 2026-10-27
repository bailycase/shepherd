import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A thread's Browser on iOS (DuoSidePaneTabs › Browser; docs/browser.md › Remote): the address bar
// ("localhost:5173", "from macbook", the host's dev servers, Reload), the page in a card, and the
// line under it. The page is the thread's `BrowserPage` (one web view a thread, kept by
// `MobileBrowsers`), so the side pane and the pushed screen show the same page without reloading.

extension MobileLayout {
    /// The address bar (DuoSidePaneTabs: 40pt, radius 8).
    static let browserAddressHeight: CGFloat = 40
    /// Reload's and the menu's width in it, as tall as a touch target.
    static let browserBarButton: CGFloat = 36
    /// Nothing open: the globe's circle and the glyph in it.
    static let browserEmptyCircle: CGFloat = 44
    static let browserEmptyGlyph: CGFloat = 20
    /// The line under the page: its top and bottom padding.
    static let browserFootTop: CGFloat = 10
    static let browserFootBottom: CGFloat = 14
}

/// The thread's Browser, for the side pane: the page fills what the pane gives it.
struct ThreadBrowserPane: View {
    let thread: AgentRef
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        if let host = hosts.host(thread.host) {
            BrowserPageView(page: MobileBrowsers.shared.page(thread, host: host), host: host)
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
            addressBar(served: served)
                .padding(.horizontal, SH.Space.l)
                .padding(.bottom, MobileLayout.browserFootTop)
            ZStack(alignment: .top) {
                content(phase)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let notice = page.notice {
                    SHBrowserNotice(message: notice) { page.notice = nil }
                        .padding(SH.Space.l)
                }
            }
            .background(sh.bgRaised)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(sh.lineSubtle, radius: SH.Radius.m)
            .padding(.horizontal, SH.Space.l)
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
        .task(id: LoadKey(session: host.session, served: served)) { await page.loadDevServers() }
        .onChange(of: editing) { _, now in
            if now { address = page.url.map(BrowserAddress.editingText) ?? "" }
        }
    }

    // MARK: Address bar

    private func addressBar(served: Bool) -> some View {
        let sh = Color.sh
        let shown = BrowserAddress.display(page.url ?? page.waitingFor)
        return HStack(spacing: SH.Space.m) {
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
                    (Text(shown.host).foregroundStyle(sh.textPrimary) + Text(shown.path).foregroundStyle(sh.textSecondary))
                        .font(.sh(.code))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { editing = true }
                        .accessibilityLabel("Address, \(shown.host)\(shown.path)")
                        .accessibilityAddTraits(.isButton)
                }
            }
            .frame(maxWidth: .infinity)
            serversMenu(served: served)
            Button {
                page.reload()
            } label: {
                Image(systemName: page.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.sh(.ui))
                    .frame(width: MobileLayout.browserBarButton, height: SH.Height.touch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(sh.textSecondary)
            .disabled(page.url == nil || !served)
            .opacity(page.url == nil || !served ? SHBrowserToolbar<EmptyView>.disabledOpacity : 1)
            .accessibilityLabel(page.isLoading ? "Stop loading" : "Reload")
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.xs)
        .frame(height: MobileLayout.browserAddressHeight)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
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
            BrowserWebView(page: page)
        case .nothingOpen:
            BrowserNothingOpen(page: page) { editing = true }
        }
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
                    .background(sh.bgSelected, in: Circle())
                    .accessibilityHidden(true)
                Text(title)
                    .font(.sh(.headline))
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
            ProgressView()
                .accessibilityLabel("Waiting")
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
            VStack(spacing: SH.Space.m) {
                ForEach(servers ?? []) { server in
                    HStack(spacing: SH.Space.m) {
                        Image(systemName: "terminal")
                            .font(.sh(.caption))
                            .foregroundStyle(sh.textSecondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            Text(server.command).font(.sh(.code)).foregroundStyle(sh.textPrimary).lineLimit(1)
                            Text(server.detail).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            Task { await page.start(server) }
                        } label: {
                            Label("Start on \(page.hostName)", systemImage: "play.fill")
                        }
                        .buttonStyle(.sh(.secondary, size: .m))
                        .fixedSize()
                        .frame(minHeight: SH.Height.touch)
                        .accessibilityLabel("Start \(server.command) on \(page.hostName)")
                    }
                    .padding(.horizontal, SH.Space.l)
                    .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                    .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                }
                Button(action: openAddress) {
                    Label("Open a port or URL", systemImage: "character.cursor.ibeam")
                        .frame(maxWidth: .infinity, minHeight: SH.Height.touch)
                }
                .buttonStyle(.sh(.ghost, size: .m))
            }
            .padding(.top, SH.Space.m)
        }
    }
}
