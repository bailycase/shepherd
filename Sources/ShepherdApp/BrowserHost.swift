import AppKit
import CryptoKit
import SwiftUI
import WebKit
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

// The Browser tab's web views, and the only app file that imports WebKit (as DesignHost is for
// DesignSurfaceKit and TerminalHost for TerminalSurfaceKit). Each local thread has at most one
// page (`BrowserSession`), made the first time it opens something, in a website data store of
// its own keyed on the agent: it shares cookies, storage and caches with nothing else, and its
// store is removed when the agent is deleted. The page lives as long as the thread: hiding the
// pane, another tab, or another thread on screen only takes its view out of the window, so it
// never reloads.

// MARK: Stores

/// Where each thread's website data lives: on disk per agent in the app, or in memory (tests).
enum BrowserDataStores: Sendable {
    case persistent
    case ephemeral

    /// The store's identifier for `agent`: its id when that is a UUID, else a UUID made from it.
    static func identifier(for agent: AgentID) -> UUID {
        if let uuid = UUID(uuidString: agent.rawValue) { return uuid }
        var bytes = Array(Insecure.SHA1.hash(data: Data(("shepherd-browser:" + agent.rawValue).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// `WKWebsiteDataStore(forIdentifier:)` crashed CI's macOS 26 test process (SIGSEGV), and
    /// nobody has confirmed it's safe there in the app either, so `.persistent` falls back to a
    /// non-persistent store per thread on macOS 26 and keeps identified, on-disk stores from
    /// macOS 27. A pure function of the version so it can be unit-tested without the OS.
    static func usesIdentifiedStores(osVersion: OperatingSystemVersion) -> Bool {
        osVersion.majorVersion >= 27
    }

    @MainActor
    func store(for agent: AgentID) -> WKWebsiteDataStore {
        switch self {
        case .persistent:
            Self.usesIdentifiedStores(osVersion: ProcessInfo.processInfo.operatingSystemVersion)
                ? WKWebsiteDataStore(forIdentifier: Self.identifier(for: agent))
                : .nonPersistent()
        case .ephemeral: .nonPersistent()
        }
    }

    /// Removes `agent`'s store from disk (nothing for ephemeral stores, or for `.persistent` on
    /// macOS 26, where it never touched disk). WebKit refuses while a web view it made is still
    /// going away, so a refusal tries again a few times.
    @MainActor
    func remove(for agent: AgentID) {
        guard self == .persistent, Self.usesIdentifiedStores(osVersion: ProcessInfo.processInfo.operatingSystemVersion) else { return }
        Self.remove(Self.identifier(for: agent), tries: 10)
    }

    @MainActor
    private static func remove(_ identifier: UUID, tries: Int) {
        WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
            guard error != nil, tries > 1 else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                remove(identifier, tries: tries - 1)
            }
        }
    }
}

/// Every local thread's page, made on demand.
@MainActor
final class BrowserSessions {
    let dataStores: BrowserDataStores
    private var sessions: [AgentID: BrowserSession] = [:]
    private var known: Set<AgentID> = []

    init(dataStores: BrowserDataStores) {
        self.dataStores = dataStores
    }

    func session(for agent: AgentID) -> BrowserSession {
        if let session = sessions[agent] { return session }
        let session = BrowserSession(agentID: agent, dataStores: dataStores)
        sessions[agent] = session
        return session
    }

    func existing(_ agent: AgentID) -> BrowserSession? { sessions[agent] }

    /// Agents that are gone take their page and their website data with them. The first state
    /// only teaches it who is here: agents are deleted only while Shepherd runs.
    func prune(live: Set<AgentID>) {
        defer { known = live }
        guard !known.isEmpty else { return }
        for gone in known.subtracting(live) {
            sessions.removeValue(forKey: gone)?.close()
            dataStores.remove(for: gone)
        }
    }
}

// MARK: Session

/// One thread's page: the web view (made when something first opens), what the toolbar shows,
/// Select an element, the viewport, and the console (`BrowserConsoleLog`, observed apart).
@MainActor @Observable
final class BrowserSession {
    /// Shepherd's own content world: the picker and the network count, out of the page's reach.
    static let world = WKContentWorld.world(name: "shepherd-browser")

    let agentID: AgentID
    @ObservationIgnored let dataStores: BrowserDataStores

    private(set) var url: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    /// Select an element is on: the page outlines what the pointer is over.
    private(set) var selecting = false
    /// The element Select an element picked, and where it is in the page (CSS pixels).
    private(set) var picked: BrowserElement?
    private(set) var pickedRect: CGRect?
    var viewport: BrowserViewport = .fit {
        didSet { if viewport != oldValue { menuOpen = false } }
    }
    var dark = false {
        didSet { if dark != oldValue { applyAppearance() } }
    }
    var menuOpen = false
    var consoleOpen = true
    /// ⌘L asks the address field for the keyboard; it counts, so each press asks again.
    private(set) var addressFocusRequests = 0
    /// Start ran a dev server that isn't answering yet.
    private(set) var waitingFor: URL?
    /// The dev servers the thread's repository offers, once read.
    var devServers: [DevServer]?

    @ObservationIgnored let console = BrowserConsoleLog()
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    /// The page's zoom the viewport last applied.
    @ObservationIgnored private(set) var zoom: CGFloat = 1

    init(agentID: AgentID, dataStores: BrowserDataStores) {
        self.agentID = agentID
        self.dataStores = dataStores
    }

    var hasPage: Bool { url != nil }

    // MARK: Navigation

    /// Opens `url`, making the web view the first time.
    func load(_ url: URL) {
        waitTask?.cancel()
        waitTask = nil
        if waitingFor != nil { waitingFor = nil }
        let view = webView ?? makeWebView()
        if self.url != url { self.url = url }
        view.load(URLRequest(url: url))
    }

    /// The address field's words: a URL, or a search.
    @discardableResult
    func open(address: String) -> Bool {
        guard let url = BrowserAddress.resolve(address) else { return false }
        load(url)
        return true
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    func reload() {
        guard let webView else { return }
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    func focusAddress() { addressFocusRequests &+= 1 }

    /// Opens `server`'s page once it answers, trying every half second for a minute and a half.
    func wait(for server: DevServer) {
        guard let url = server.url else { return }
        waitTask?.cancel()
        waitingFor = url
        waitTask = Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(90)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if await Self.answers(url) {
                    guard !Task.isCancelled, let self, self.waitingFor == url else { return }
                    self.load(url)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if let self, self.waitingFor == url, !Task.isCancelled { self.waitingFor = nil }
        }
    }

    func stopWaiting() {
        waitTask?.cancel()
        waitTask = nil
        if waitingFor != nil { waitingFor = nil }
    }

    private nonisolated static func answers(_ url: URL) async -> Bool {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 1)
        request.httpMethod = "HEAD"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        return (try? await session.data(for: request)) != nil
    }

    /// The agent is gone: the page stops.
    func close() {
        stopWaiting()
        observations.removeAll()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        webView = nil
    }

    // MARK: Select an element

    /// ⇧⌘C and the toolbar's button: selecting on or off. Turning it on clears a pick.
    func toggleSelecting() { setSelecting(!selecting) }

    func setSelecting(_ on: Bool) {
        guard let webView, url != nil else { return }
        if selecting != on { selecting = on }
        clearPick()
        let palette = Self.palette()
        webView.callAsyncJavaScript("return window.__shepherdBrowser ? window.__shepherdBrowser.setSelecting(on, palette) : false",
                                    arguments: ["on": on, "palette": palette], in: nil, in: Self.world) { _ in }
    }

    /// The popover closed: the outline goes with it.
    func dismissPick() {
        clearPick()
        webView?.callAsyncJavaScript("if (window.__shepherdBrowser) window.__shepherdBrowser.clear()", arguments: [:], in: nil,
                                     in: Self.world) { _ in }
    }

    private func clearPick() {
        if picked != nil { picked = nil }
        if pickedRect != nil { pickedRect = nil }
    }

    /// The outline's colors, from the theme: the `running` role and its tint, and text on it.
    static func palette() -> [String: String] {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let colors = ThemeStore.shared.theme.variant(dark: dark).colors
        return ["accent": colors.running, "tint": colors.runningTint, "text": colors.textOnLantern]
    }

    // MARK: What the page reports

    func handle(_ message: BrowserScriptMessage) {
        switch message {
        case .console(let level, let text):
            console.append(level, text)
        case .network(let count):
            console.setNetwork(count)
        case .pick(let element, let rect):
            if selecting { selecting = false }
            picked = element
            pickedRect = rect
        case .moved(let rect):
            if picked != nil, pickedRect != rect { pickedRect = rect }
        case .cancel:
            if selecting { selecting = false }
            clearPick()
        }
    }

    // MARK: Viewport

    /// The page's zoom for the viewport's layout; the web view relays out only when it changes.
    func apply(zoom: CGFloat) {
        guard let webView, abs(zoom - self.zoom) > 0.0001 else { return }
        self.zoom = zoom
        webView.pageZoom = zoom
    }

    private func applyAppearance() {
        webView?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    // MARK: The web view

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStores.store(for: agentID)
        let delegate = Delegate(session: self)
        self.delegate = delegate
        let content = configuration.userContentController
        content.addUserScript(WKUserScript(source: BrowserScripts.pageShim, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                           in: .page))
        content.addUserScript(WKUserScript(source: BrowserScripts.picker, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                           in: Self.world))
        content.add(delegate, contentWorld: .page, name: BrowserScripts.consoleHandler)
        content.add(delegate, contentWorld: Self.world, name: BrowserScripts.pickerHandler)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        observations = [
            view.observe(\.url, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.sync(view) }
            },
            view.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.sync(view) }
            },
            view.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.sync(view) }
            },
            view.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.sync(view) }
            },
        ]
        webView = view
        return view
    }

    private func sync(_ view: WKWebView) {
        if let current = view.url, current != url { url = current }
        if canGoBack != view.canGoBack { canGoBack = view.canGoBack }
        if canGoForward != view.canGoForward { canGoForward = view.canGoForward }
        if isLoading != view.isLoading { isLoading = view.isLoading }
    }

    /// A new document: its console, network count, pick and selecting start over.
    fileprivate func committed() {
        console.clear()
        clearPick()
        if selecting { selecting = false }
    }

    /// Answers WebKit for the session without holding it.
    private final class Delegate: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var session: BrowserSession?

        init(session: BrowserSession) { self.session = session }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let session, message.frameInfo.isMainFrame else { return }
                let parsed = message.name == BrowserScripts.consoleHandler
                    ? BrowserScriptMessage(console: message.body)
                    : message.world == BrowserSession.world
                        ? BrowserScriptMessage(picker: message.body, page: session.url?.absoluteString ?? "") : nil
                if let parsed { session.handle(parsed) }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated { session?.committed() }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                let error = error as NSError
                guard error.code != NSURLErrorCancelled else { return }
                session?.console.append(.error, error.localizedDescription)
            }
        }

        /// A link that opens a new window opens here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

// MARK: View

/// The session's web view in the pane. The view is the session's, so taking this out of the
/// window (the pane hidden, another tab, a layout parked) keeps the page as it was.
struct BrowserPageView: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> Container { Container() }

    func updateNSView(_ container: Container, context: Context) {
        container.attach(session.webView)
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.detach()
    }

    final class Container: NSView {
        private weak var page: WKWebView?

        func attach(_ view: WKWebView?) {
            guard page !== view else { return }
            detach()
            guard let view else { return }
            view.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            page = view
        }

        func detach() {
            if let page, page.superview === self { page.removeFromSuperview() }
            page = nil
        }
    }
}
