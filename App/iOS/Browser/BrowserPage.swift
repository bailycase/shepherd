import SwiftUI
import UIKit
import WebKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A remote thread's Browser page on the phone and iPad: the page renders in
// this device's own web view and its URL stays `localhost:5173`; its traffic to the host's loopback
// ports goes to the host over the authenticated connection, through a listener on this device's
// loopback at the same port (`BrowserPagePorts`, `BrowserPortForwarder`, `BrowserTunnelHub`, all
// shared with the Mac). The only file of the iOS app that imports WebKit.
//
// The page is the user's alone: the host's agent does not drive it (`browser.drive.v1` is not
// built here), so a host can't make this device open anything. The user selects an element in it
// with the Mac's picker (`BrowserScripts`), in Shepherd's own content world, and adds it to their
// message (iPadPaneBrowser).

/// One tab's web view, dev servers and loading state. Its thread owns the forwarded ports.
@MainActor
@Observable
final class BrowserPage {
    let ref: AgentRef
    let id: UUID
    let source: SHBrowserTabSource
    private let autoOpenRunning: Bool
    private(set) var title = ""
    let console = MobileBrowserConsole()
    var consoleOpen = false
    /// The page open now (WebKit's, once it navigates); nil before anything was opened.
    private(set) var url: URL?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Start ran, or a dev server was picked, and its port has not answered yet.
    private(set) var waitingFor: URL?
    /// The dev servers the thread's folder on the host offers; nil until read.
    private(set) var devServers: [DevServer]?
    /// The ports of the dev servers were tried once, so a page with nothing open opens one that runs.
    private(set) var lookedForRunning = false
    /// Why nothing loaded: a port that can't be forwarded, a load that failed. Cleared by the next load.
    var notice: String?
    /// The next tap in the page picks the element under it.
    private(set) var selecting = false
    /// The element the user picked, and where it is in the page's viewport (CSS pixels, points here).
    private(set) var picked: BrowserElement?
    private(set) var pickedRect: CGRect?

    @ObservationIgnored weak var host: MobileHost?
    @ObservationIgnored private weak var tabs: MobileBrowserTabs?
    @ObservationIgnored private let ports: BrowserPagePorts
    @ObservationIgnored private var closed = false
    @ObservationIgnored var allowsPopupTabs = false
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    /// Shepherd's world in the page: the page can't see or call the picker that runs there.
    static let world = WKContentWorld.world(name: "shepherd-browser")

    /// How long Start waits for its port, tried every half second, as on the Mac.
    static let waitSeconds = 90
    /// The schemes a page may take its main frame to: web pages, blank and blob documents.
    static let pageSchemes: Set<String> = ["http", "https", "about", "blob"]

    init(id: UUID, source: SHBrowserTabSource, tabs: MobileBrowserTabs, autoOpenRunning: Bool = false) {
        self.id = id
        self.source = source
        self.tabs = tabs
        self.ref = tabs.ref
        self.host = tabs.host
        self.ports = tabs.ports
        self.autoOpenRunning = autoOpenRunning
    }

    var tabItem: SHBrowserTabItem {
        let shown = BrowserAddress.display(url ?? waitingFor)
        let host = shown?.host ?? ""
        return SHBrowserTabItem(id: id, title: title.isEmpty ? shown?.host ?? "New tab" : title,
                                address: host + (shown?.path ?? ""), letter: SHBrowserTabTint.initial(host: host),
                                tint: SHBrowserTabTint.forHost(host), source: source)
    }

    var hostName: String { host?.name ?? "the host" }

    /// The host is connected and carries Browser tunnels.
    var isServed: Bool { host?.phase == .connected && host?.supports(RemoteProtocol.browserTunnelCapability) == true }

    /// "this iPhone", "this iPad": where the forwarded ports listen, for a refusal's words.
    static var here: String { "this \(UIDevice.current.model)" }

    /// A closed tab must never claim ports again, including through a late callback or Start reply.
    func close() {
        closed = true
        stopWaiting()
        ports.closeTab(id)
        observations.removeAll()
        if let content = webView?.configuration.userContentController {
            content.removeScriptMessageHandler(forName: BrowserScripts.pickerHandler, contentWorld: Self.world)
            content.removeScriptMessageHandler(forName: BrowserScripts.consoleHandler, contentWorld: .page)
        }
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        delegate = nil
    }

    // MARK: Opening

    /// Opens `url`, making the web view the first time. False, with the reason in `notice`, when a
    /// port of the host can't be forwarded for it: nothing loads then.
    @discardableResult
    func open(_ url: URL) -> Bool { open(URLRequest(url: url)) }

    @discardableResult
    private func open(_ request: URLRequest) -> Bool {
        guard !closed, let url = request.url else { return false }
        stopWaiting()
        if let refusal = ports.forward(url, tab: id) {
            notice = refusal.message(hostName: hostName, here: Self.here)
            return false
        }
        notice = nil
        let view = webView ?? makeWebView()
        if self.url != url { self.url = url }
        view.load(request)
        return true
    }

    /// The address field's words: a port (":5173"), a URL, or a search.
    @discardableResult
    func open(address: String) -> Bool {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // A bare port names one on the host, as ":5173" does.
        let input = !text.isEmpty && text.allSatisfy(\.isNumber) ? ":" + text : text
        guard let url = BrowserAddress.resolve(input) else { return false }
        return open(url)
    }

    /// Reload, or Stop while the page loads; the page that didn't load is tried again.
    func reload() {
        if let webView, webView.isLoading {
            webView.stopLoading()
        } else if let webView, webView.url != nil {
            notice = nil
            webView.reload()
        } else if let url {
            open(url)
        }
    }

    // MARK: Selecting an element

    func toggleSelecting() { setSelecting(!selecting) }

    func setSelecting(_ on: Bool) {
        guard let webView, url != nil else { return }
        if selecting != on { selecting = on }
        clearPick()
        let palette = Self.palette(webView.traitCollection)
        webView.callAsyncJavaScript("return window.__shepherdBrowser ? window.__shepherdBrowser.setSelecting(on, palette) : false",
                                    arguments: ["on": on, "palette": palette], in: nil, in: Self.world) { _ in }
    }

    /// The popover closed (or its element was added): the outline goes with it.
    func dismissPick() {
        clearPick()
        webView?.callAsyncJavaScript("if (window.__shepherdBrowser) window.__shepherdBrowser.clear()", arguments: [:], in: nil,
                                     in: Self.world) { _ in }
    }

    private func clearPick() {
        if picked != nil { picked = nil }
        if pickedRect != nil { pickedRect = nil }
    }

    /// The outline's colors, as on the Mac: the `running` role and its tint, and text on it, in the page's appearance.
    static func palette(_ traits: UITraitCollection) -> [String: String] {
        let colors = ThemeStore.shared.theme.variant(dark: traits.userInterfaceStyle == .dark).colors
        return ["accent": colors.running, "tint": colors.runningTint, "text": colors.textOnRunning]
    }

    /// What the picker posts: a pick, its element moving as the page scrolls, or Esc.
    fileprivate func picker(_ body: Any) {
        guard let body = body as? [String: Any] else { return }
        switch body["kind"] as? String {
        case "network":
            if let count = (body["count"] as? NSNumber)?.intValue, count >= 0 { console.network = count }
        case "pick":
            guard let pick = BrowserScripts.pick(body, page: url?.absoluteString ?? "") else { return }
            if selecting { selecting = false }
            picked = pick.element
            pickedRect = pick.rect
        case "rect":
            if picked != nil, let rect = BrowserScripts.rect(body["rect"]) { pickedRect = rect }
        case "cancel":
            if selecting { selecting = false }
        default:
            break
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    // MARK: Dev servers

    /// Reads the host's dev servers once a connection is up, then opens the first whose port
    /// answers when nothing is open yet.
    func loadDevServers() async {
        guard !closed, isServed, let client = host?.connectedClient else { return }
        if devServers == nil {
            guard let found = try? await client.devServers(agentID: ref.agent), !closed, !Task.isCancelled else { return }
            devServers = found
        }
        guard autoOpenRunning, url == nil, waitingFor == nil, !lookedForRunning, let hub = host?.tunnelSlot.hub else { return }
        lookedForRunning = true
        var tried: Set<Int> = []
        for server in devServers ?? [] {
            guard let serverURL = server.url, let port = server.port, tried.insert(port).inserted else { continue }
            if await hub.probe(agentID: ref.agent, port: port) == .reachable {
                if !closed, url == nil, waitingFor == nil { open(serverURL) }
                return
            }
        }
    }

    /// Start on the host: runs the script in a new terminal of the thread's layout there, and opens
    /// its page once the port answers (when the port is known).
    func start(_ server: DevServer) async {
        guard !closed else { return }
        guard isServed, let client = host?.connectedClient else {
            notice = "\(hostName) is not connected. Reconnect and try again."
            return
        }
        do {
            try await client.openTerminal(agentID: ref.agent, cwd: server.directory, command: server.command)
            if let serverURL = server.url { wait(for: serverURL) }
        } catch RemoteHostClientError.rejected(_, let message) {
            notice = message
        } catch {
            notice = String(describing: error)
        }
    }

    /// Opens `url` once its port answers on the host, tried every half second for 90 seconds.
    func wait(for url: URL) {
        guard !closed else { return }
        guard let port = BrowserTunnelTarget.port(of: url) else {
            open(url)
            return
        }
        waitTask?.cancel()
        // The port is forwarded first, so it answers by the way the page will go.
        if let refusal = ports.forward(url, tab: id) {
            notice = refusal.message(hostName: hostName, here: Self.here)
            return
        }
        notice = nil
        waitingFor = url
        let agent = ref.agent
        waitTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(Self.waitSeconds)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let hub = self?.host?.tunnelSlot.hub, await hub.probe(agentID: agent, port: port) == .reachable {
                    guard !Task.isCancelled, let self, self.waitingFor == url else { return }
                    self.open(url)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            guard !Task.isCancelled, let self, self.waitingFor == url else { return }
            self.waitingFor = nil
            self.notice = "\(BrowserAddress.display(url)?.host ?? url.absoluteString) didn’t answer on \(self.hostName). Start its dev server and try again."
        }
    }

    func stopWaiting() {
        waitTask?.cancel()
        waitTask = nil
        if waitingFor != nil { waitingFor = nil }
    }

    // MARK: The web view

    fileprivate func makeWebView(popup: WKWebViewConfiguration? = nil) -> WKWebView {
        let configuration = popup ?? WKWebViewConfiguration()
        if popup == nil { configuration.websiteDataStore = tabs?.websiteDataStore ?? .nonPersistent() }
        configuration.allowsInlineMediaPlayback = true
        // WebKit's popup configuration can share its opener's controller. Keep handlers tab-local.
        let content = WKUserContentController()
        configuration.userContentController = content
        let delegate = Delegate(page: self)
        // The page's world answers the picker's source question (a React dev build's JSX location); the picker runs in ours.
        content.addUserScript(WKUserScript(source: BrowserScripts.pageShim, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                           in: .page))
        content.addUserScript(WKUserScript(source: BrowserScripts.picker, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                           in: Self.world))
        content.add(WeakHandler(delegate), contentWorld: Self.world, name: BrowserScripts.pickerHandler)
        content.add(WeakHandler(delegate), contentWorld: .page, name: BrowserScripts.consoleHandler)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        self.delegate = delegate
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    let title = String((view.title ?? "").prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
                    if self?.title != title { self?.title = title }
                }
            },
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if let url = view.url, self?.url != url { self?.url = url } }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if self?.isLoading != view.isLoading { self?.isLoading = view.isLoading } }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if self?.canGoBack != view.canGoBack { self?.canGoBack = view.canGoBack } }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { if self?.canGoForward != view.canGoForward { self?.canGoForward = view.canGoForward } }
            },
        ]
        webView = view
        return view
    }

    /// Where the page may go on its own: a link, a redirect, a script, an iframe. A port of the host
    /// is forwarded before it goes (refused past the page's eight, or one another program holds).
    fileprivate func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard !closed else { return .cancel }
        guard let url = action.request.url else { return .allow }
        if action.shouldPerformDownload { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        if isMain, !Self.pageSchemes.contains(url.scheme?.lowercased() ?? "") { return .cancel }
        // WebKit calls the UI delegate for this request; the destination tab will claim the port.
        if action.targetFrame == nil { return .allow }
        if let refusal = ports.forward(url, tab: id) {
            notice = refusal.message(hostName: hostName, here: Self.here)
            return .cancel
        }
        if isMain, self.url == nil { self.url = url }
        return .allow
    }

    fileprivate func failed(_ error: Error) {
        let error = error as NSError
        // Stop, a newer load, and a navigation the policy cancelled are not failures.
        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
        if error.domain == WKError.errorDomain, error.code == 102 { return }
        let shown = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL).flatMap { BrowserAddress.display($0)?.host }
            ?? BrowserAddress.display(url)?.host ?? "The page"
        notice = isServed
            ? "\(shown) didn’t load: \(error.localizedDescription)"
            : "\(shown) didn’t load: \(hostName) is not connected."
    }

    fileprivate func popup(_ action: WKNavigationAction, configuration: WKWebViewConfiguration) -> WKWebView? {
        guard !closed, action.targetFrame == nil, !action.shouldPerformDownload,
              let url = action.request.url, Self.pageSchemes.contains(url.scheme?.lowercased() ?? ""),
              let tabs, tabs.selectedPage === self else { return nil }
        if allowsPopupTabs, let page = tabs.add(source: .link) {
            tabs.notice = .popup
            return page.makeWebView(popup: configuration)
        }
        open(action.request)
        return nil
    }

    @MainActor
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var page: BrowserPage?

        init(page: BrowserPage) { self.page = page }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(page?.decide(navigationAction) ?? .cancel)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            page?.console.clear()
            page?.notice = nil
            // A new document: nothing is picked or being picked in it.
            if page?.selecting == true || page?.picked != nil { page?.setSelecting(false) }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            // Page-world input is untrusted display text. Only the isolated world can pick elements.
            if message.name == BrowserScripts.consoleHandler, message.world == .page {
                page?.console.append(message.body)
            } else if message.name == BrowserScripts.pickerHandler, message.world == BrowserPage.world {
                page?.picker(message.body)
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            page?.failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            page?.failed(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            page?.popup(navigationAction, configuration: configuration)
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard let page, page.source == .link else { return }
            page.tabs?.close(page.id)
        }
    }
}

/// The thread keeps these tabs across side-pane switches and folds, until its browser is evicted.
@MainActor @Observable
final class MobileBrowserTabs {
    enum Notice { case popup, cap }

    let ref: AgentRef
    weak var host: MobileHost?
    let ports: BrowserPagePorts
    // Preserve the existing isolation between threads, while sharing sign-ins within this one.
    @ObservationIgnored lazy var websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private(set) var selection: BrowserTabSelection
    private var pages: [UUID: BrowserPage] = [:]
    var notice: Notice?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?

    init(ref: AgentRef, host: MobileHost, forwarder: BrowserPortForwarder) {
        self.ref = ref
        self.host = host
        let ports = BrowserPagePorts(forwarder: forwarder,
                                     owner: .init(id: "\(ref.host.uuidString)/\(ref.agent.rawValue)", hostName: host.name),
                                     agent: ref.agent, slot: host.tunnelSlot)
        self.ports = ports
        selection = BrowserTabSelection(first: ports.firstTab)
        pages[ports.firstTab] = BrowserPage(id: ports.firstTab, source: .user, tabs: self, autoOpenRunning: true)
    }

    var selectedPage: BrowserPage? { pages[selection.selected] }
    var items: [SHBrowserTabItem] { selection.ids.compactMap { pages[$0]?.tabItem } }

    @discardableResult
    func add(source: SHBrowserTabSource = .user) -> BrowserPage? {
        guard selectedPage != nil else { return nil }
        let id = UUID()
        guard selection.add(id) else { notice = .cap; return nil }
        return makePage(id, source: source)
    }

    func select(_ id: UUID) { selection.select(id) }

    func close(_ id: UUID) {
        guard let page = pages.removeValue(forKey: id) else { return }
        page.close()
        selection.close(id, replacement: UUID())
        if selectedPage == nil { _ = makePage(selection.selected, source: .user) }
        if notice == .cap { notice = nil }
    }

    func closeOthers() {
        for id in selection.ids where id != selection.selected { pages.removeValue(forKey: id)?.close() }
        selection.closeOthers()
        notice = nil
    }

    private func makePage(_ id: UUID, source: SHBrowserTabSource) -> BrowserPage {
        ports.openTab(id)
        let page = BrowserPage(id: id, source: source, tabs: self)
        pages[id] = page
        return page
    }

    func resume() {
        guard host?.supports(RemoteProtocol.browserTunnelCapability) == true else { return }
        resumeTask?.cancel()
        report(ports.resume())
        guard !ports.pending.isEmpty else { return }
        resumeTask = Task { [weak self] in
            guard let self else { return }
            let refused = await ports.finishResume()
            if !Task.isCancelled { report(refused) }
        }
    }

    func suspend() {
        for page in pages.values { page.stopWaiting() }
        resumeTask?.cancel()
        ports.suspend()
    }

    func closeAll() {
        resumeTask?.cancel()
        ports.close()
        for page in pages.values { page.close() }
        pages.removeAll()
    }

    private func report(_ refused: [BrowserPortForwarder.Refusal]) {
        for page in pages.values {
            guard let url = page.url,
                  let failure = refused.first(where: { $0.port == BrowserTunnelTarget.port(of: url) }) else { continue }
            page.notice = failure.message(hostName: page.hostName, here: BrowserPage.here)
        }
    }
}

/// Web content can forge its own log lines. Keep the payload bounded and render it only as text.
@MainActor @Observable
final class MobileBrowserConsole {
    private static let maxLines = 500
    private static let maxTextLength = 2000
    private(set) var lines: [SHConsoleLine] = []
    private(set) var warnings = 0
    var network = 0
    @ObservationIgnored private var nextID = 0

    func append(_ body: Any) {
        guard let batch = (body as? [String: Any])?["lines"] as? [Any] else { return }
        let clock = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        let time = String(format: "%02d:%02d:%02d", clock.hour ?? 0, clock.minute ?? 0, clock.second ?? 0)
        var newLines: [SHConsoleLine] = []
        var newWarnings = 0
        for entry in batch.suffix(Self.maxLines) {
            guard let line = entry as? [String: Any], let text = line["text"] as? String else { continue }
            let level = line["level"] as? String
            let warning = level == "warning" || level == "error"
            nextID += 1
            if warning { newWarnings += 1 }
            newLines.append(SHConsoleLine(id: nextID, time: time, text: String(text.prefix(Self.maxTextLength)),
                                          level: warning ? .warning : .log))
        }
        guard !newLines.isEmpty else { return }
        lines = Array((lines + newLines).suffix(Self.maxLines))
        if newWarnings > 0 { warnings += newWarnings }
    }

    func clear() {
        lines.removeAll()
        warnings = 0
        network = 0
    }
}

/// The page's web view, wherever the page is shown (the side pane, or pushed full screen): one web
/// view per tab, moved into whichever container is in a window, so it never reloads.
struct BrowserWebView: UIViewRepresentable {
    let page: BrowserPage
    let allowsPopupTabs: Bool

    func makeUIView(context: Context) -> Container {
        let container = Container()
        page.allowsPopupTabs = allowsPopupTabs
        container.webView = page.webView
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
        page.allowsPopupTabs = allowsPopupTabs
        container.webView = page.webView
    }

    final class Container: UIView {
        weak var webView: WKWebView? {
            didSet { adopt() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            adopt()
        }

        private func adopt() {
            guard window != nil, let webView, webView.superview !== self else { return }
            webView.removeFromSuperview()
            webView.frame = bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(webView)
        }
    }
}

/// The content controller holds its handlers strongly: this keeps the page's delegate out of that cycle.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
