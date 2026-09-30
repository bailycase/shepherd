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

    /// Whether a page with no pane parks its window on a screen's corner (the app) rather than far
    /// off every screen (tests and previews, whose windows never touch the user's screen).
    var parksOnAScreen: Bool { self == .persistent }

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
/// Select an element, the viewport, and the console (`BrowserConsoleLog`, observed apart). The
/// agent's tools drive the same page (`BrowserDriver.swift`): with no pane showing it, the view is
/// hosted in an off-screen window so it still lays out, runs timers and can be snapshotted.
@MainActor @Observable
final class BrowserSession {
    /// Shepherd's own content world: the picker, the agent's script and the network count, out of
    /// the page's reach.
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
        didSet {
            if viewport != oldValue {
                menuOpen = false
                layoutParked()
            }
        }
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

    /// The agent is using the page: the pane's ring, pointer and card. Nil when it is not (or the
    /// user has taken over).
    private(set) var agentOverlay: BrowserAgentOverlay?
    /// The user took the page over: the agent's actions are refused until they message the thread.
    private(set) var userHasControl = false
    /// What the header's button and the tab's tip say the agent opened, and when.
    private(set) var openedByAgent: (url: URL, at: Date)?

    @ObservationIgnored let console = BrowserConsoleLog()
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var waitTask: Task<Void, Never>?
    /// The page's zoom the viewport last applied.
    @ObservationIgnored private(set) var zoom: CGFloat = 1

    // The agent's use of the page (BrowserDriver.swift).
    @ObservationIgnored var presence = BrowserAgentPresence()
    @ObservationIgnored var events = BrowserEvents()
    @ObservationIgnored var reportedErrors = 0
    @ObservationIgnored var operationTail: Task<Void, Never>?
    /// Moves when the agent gives up its queued requests (`abandonQueued`).
    @ObservationIgnored var operationEpoch = 0
    /// How long a call into the page may take before the driver gives up on it (tests shorten it).
    @ObservationIgnored var scriptDeadline = BrowserLimits.scriptSeconds
    /// The same for a script the agent's `browser_eval` runs.
    @ObservationIgnored var evalDeadline = BrowserLimits.evalSeconds
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private(set) var navigationSerial = 0
    @ObservationIgnored private(set) var loadState: BrowserLoadState = .idle
    @ObservationIgnored private(set) var mainStatus: Int?
    /// Addresses the user typed that a page could not navigate to by itself (`file:`).
    @ObservationIgnored private var userNavigations: Set<URL> = []
    /// Called when the page tells the app the user's own input reached it while the agent is using it.
    @ObservationIgnored var onUserInput: (() -> Void)?

    // Off-screen hosting: a page nobody looks at still lays out and runs.
    @ObservationIgnored private var parkWindow: NSWindow?
    @ObservationIgnored private(set) var paneSize = CGSize(width: 1024, height: 768)

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
        // The app's own load of a `file:` (the address field) is let through once; a page's is not.
        if !BrowserURLPolicy.allowsPageNavigation(to: url) { userNavigations.insert(url) }
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
        expiry?.cancel()
        observations.removeAll()
        webView?.stopLoading()
        webView?.configuration.userContentController.removeAllScriptMessageHandlers()
        webView?.removeFromSuperview()
        webView = nil
        parkWindow?.orderOut(nil)
        parkWindow?.contentView = nil
        parkWindow = nil
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
        return ["accent": colors.running, "tint": colors.runningTint, "text": colors.textOnRunning]
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
        case .userInput:
            if agentOverlay != nil { takeOver() }
        }
    }

    // MARK: The agent using the page

    /// An agent action begins: the ring and card show, with `note` ("clicking “Pay $148.00”").
    func agentBegan(note: String) {
        presence.begin(note: note)
        syncOverlay()
    }

    func agentDescribed(_ note: String) {
        presence.describe(note)
        syncOverlay()
    }

    /// Where the action pointed, in the page's CSS pixels.
    func agentPointed(at point: CGPoint?) {
        presence.point(at: point)
        syncOverlay()
    }

    func agentEnded() {
        presence.end(now: Date())
        syncOverlay()
    }

    /// Take over (the card's button, or the user's own click or key in the page).
    func takeOver() {
        presence.takeOver()
        if !userHasControl { userHasControl = true }
        syncOverlay()
    }

    /// The user sent the thread a message: the agent has the page back.
    func handBack() {
        presence.handBack()
        if userHasControl { userHasControl = false }
        syncOverlay()
    }

    /// The agent opened a page: the header's button and the Browser tab say so until it is looked at.
    func noteAgentOpened(_ url: URL) {
        openedByAgent = (url, Date())
    }

    private func syncOverlay() {
        let shown = presence.isShown(now: Date())
        let next = shown ? BrowserAgentOverlay(note: presence.note, pointer: presence.pointer) : nil
        if next != agentOverlay { agentOverlay = next }
        expiry?.cancel()
        if let until = presence.expiry {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, until.timeIntervalSinceNow) + 0.05))
                guard !Task.isCancelled else { return }
                self?.syncOverlay()
            }
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

    // MARK: Off-screen hosting

    /// The page's size in points, wherever it is hosted: the pane's, else the last one it had.
    func paneSizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 1, size != paneSize else { return }
        paneSize = size
    }

    /// The view is in no window (the pane hidden, another tab, another thread on screen): it moves
    /// into a borderless window that hangs off a screen's corner (`BrowserParkPlacement`), ordered
    /// to the back, nearly transparent, deaf to the mouse and never key, so it lays out, runs timers
    /// and animation frames and can be snapshotted. The page never reloads.
    func parkOffscreen() {
        guard let webView, webView.superview == nil else { return }
        let window = parkWindow ?? makeParkWindow()
        parkWindow = window
        placeParked(window)
        let content = window.contentView ?? NSView()
        window.contentView = content
        webView.frame = content.bounds
        webView.autoresizingMask = [.width, .height]
        content.addSubview(webView)
        apply(zoom: 1)
        if !window.isVisible { window.orderBack(nil) }
    }

    /// The parked window's size: the viewport's width (else the pane's) by the pane's height.
    private var parkedSize: CGSize {
        CGSize(width: viewport.width ?? paneSize.width, height: paneSize.height)
    }

    private func placeParked(_ window: NSWindow) {
        // Tests and previews (in-memory stores) keep their windows far off every screen; the app's
        // hang off a corner so the page stays visible to macOS.
        let screens = dataStores.parksOnAScreen ? NSScreen.screens.map(\.frame) : []
        let frame = BrowserParkPlacement.frame(size: parkedSize, screens: screens)
        window.setFrame(window.frameRect(forContentRect: frame), display: false)
    }

    /// A viewport chosen while the page is parked resizes its window.
    private func layoutParked() {
        guard let window = parkWindow, webView?.window === window else { return }
        placeParked(window)
    }

    private func makeParkWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: BrowserParkPlacement.farAway, size: paneSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.alphaValue = 0.01
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = NSView(frame: NSRect(origin: .zero, size: paneSize))
        return window
    }

    // MARK: Driver primitives (BrowserDriver.swift)

    /// Makes the web view if there is none, hosted off screen until a pane takes it.
    func prepareWebView() {
        if webView == nil { _ = makeWebView() }
    }

    var pageTitle: String? { webView?.title }
    var pageURLString: String? { webView?.url?.absoluteString ?? url?.absoluteString }

    /// Loads `url` for the agent: a page is a navigation like any other, but `file:` and the like
    /// were refused before this (`BrowserURLPolicy.agentURL`).
    func loadForAgent(_ url: URL) {
        guard BrowserURLPolicy.allowsPageNavigation(to: url), url.scheme?.lowercased() != "blob" else { return }
        prepareWebView()
        load(url)
    }

    func stepHistory(_ direction: BrowserHistoryStep) {
        switch direction {
        case .back: webView?.goBack()
        case .forward: webView?.goForward()
        case .reload: webView?.reload()
        }
    }

    var canStep: (back: Bool, forward: Bool) { (webView?.canGoBack ?? false, webView?.canGoForward ?? false) }

    /// Where stepping `direction` would land: the previous or next history entry, or the page itself
    /// for a reload.
    func historyTarget(_ direction: BrowserHistoryStep) -> URL? {
        switch direction {
        case .back: webView?.backForwardList.backItem?.url
        case .forward: webView?.backForwardList.forwardItem?.url
        case .reload: webView?.url
        }
    }

    /// Calls a function of the agent's script (in Shepherd's world) and answers its JSON object.
    func callAgent(_ function: String, _ argument: [String: Any] = [:]) async throws -> [String: Any] {
        guard let webView else { throw BrowserScriptFailure(message: "There is no page open.") }
        let body = "if (!window.__shepherdAgent) return JSON.stringify({error: 'no_page', message: 'The page is not ready yet.'});"
            + " return JSON.stringify(await window.__shepherdAgent.\(function)(args));"
        // A page stuck in a script never answers: the call is given up on after `scriptDeadline`
        // rather than holding every later tool call for good.
        let arguments: [String: Any] = ["args": argument]
        switch await withDeadline(scriptDeadline, { try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: Self.world) }) {
        case .value(let value):
            guard let text = value as? String, let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw BrowserScriptFailure(message: "The page answered something unexpected.")
            }
            return object
        case .thrown(let error):
            throw BrowserScriptFailure(error)
        case .timedOut:
            throw BrowserScriptFailure.timedOut
        }
    }

    /// Runs `body` (a function body; `return` an answer) in the page's own world, for at most
    /// `deadline` seconds (`scriptDeadline` by default).
    func callPage(_ body: String, deadline: Double? = nil) async throws -> Any? {
        guard let webView else { throw BrowserScriptFailure(message: "There is no page open.") }
        switch await withDeadline(deadline ?? scriptDeadline, { try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) }) {
        case .value(let value): return value
        case .thrown(let error): throw BrowserScriptFailure(error)
        case .timedOut: throw BrowserScriptFailure.timedOut
        }
    }

    /// The visible viewport (or `rect` of it, in points) as an image, or nil when it can't be taken.
    func snapshotImage(rect: CGRect?) async -> CGImage? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        if let rect { configuration.rect = rect }
        configuration.afterScreenUpdates = true
        guard case .value(let image) = await withDeadline(scriptDeadline, { try await webView.takeSnapshot(configuration: configuration) }) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
        content.addUserScript(WKUserScript(source: BrowserScripts.agent, injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                           in: Self.world))
        content.addUserScript(WKUserScript(source: BrowserScripts.inputWatch, injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                           in: Self.world))
        content.addUserScript(WKUserScript(source: BrowserScripts.picker, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                                           in: Self.world))
        content.add(delegate, contentWorld: .page, name: BrowserScripts.consoleHandler)
        content.add(delegate, contentWorld: Self.world, name: BrowserScripts.pickerHandler)
        let view = WKWebView(frame: NSRect(origin: .zero, size: paneSize), configuration: configuration)
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
        parkOffscreen()
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
        events.navigations += 1
        presence.documentChanged()
        syncOverlay()
    }

    fileprivate func navigationStarted() {
        navigationSerial += 1
        loadState = .loading
        mainStatus = nil
    }

    fileprivate func navigationFinished() {
        loadState = .finished
    }

    fileprivate func navigationFailed(_ error: Error) {
        let failure = error as NSError
        // A navigation replaced by another one reports itself cancelled; the newer one decides.
        if failure.code == NSURLErrorCancelled, failure.domain == NSURLErrorDomain { return }
        loadState = .failed(BrowserLoadFailure.describe(failure))
    }

    /// Whether the address field's own `file:` (or the like) load may go through, once.
    fileprivate func consumeUserNavigation(_ url: URL) -> Bool {
        userNavigations.remove(url) != nil
    }

    fileprivate func recordMainStatus(_ status: Int, url: URL?) {
        mainStatus = status
        if status >= 400 { console.append(.error, "HTTP \(status) \(url?.absoluteString ?? "")") }
    }

    /// Answers WebKit for the session without holding it.
    private final class Delegate: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        weak var session: BrowserSession?

        init(session: BrowserSession) { self.session = session }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            MainActor.assumeIsolated {
                guard let session else { return }
                // A frame's word counts only for the user's own input in it (a card form in an iframe).
                guard message.frameInfo.isMainFrame else {
                    if message.world == BrowserSession.world, (message.body as? [String: Any])?["kind"] as? String == "userInput" {
                        session.handle(.userInput)
                    }
                    return
                }
                let parsed = message.name == BrowserScripts.consoleHandler
                    ? BrowserScriptMessage(console: message.body)
                    : message.world == BrowserSession.world
                        ? BrowserScriptMessage(picker: message.body, page: session.url?.absoluteString ?? "") : nil
                if let parsed { session.handle(parsed) }
            }
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            MainActor.assumeIsolated {
                guard let session else { decisionHandler(.allow); return }
                if navigationAction.shouldPerformDownload {
                    let name = navigationAction.request.url?.lastPathComponent ?? "a file"
                    session.events.downloads.append(name)
                    decisionHandler(.cancel)
                    return
                }
                guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else {
                    decisionHandler(.allow)
                    return
                }
                // History (Back, Forward, Reload) replays what an allowed load put there.
                let replay = navigationAction.navigationType == .reload || navigationAction.navigationType == .backForward
                if replay || BrowserURLPolicy.allowsPageNavigation(to: url) || session.consumeUserNavigation(url) {
                    decisionHandler(.allow)
                } else {
                    session.console.append(.error, "Blocked a navigation to \(url.scheme ?? "that")\(url.scheme == nil ? "" : ":") URL.")
                    decisionHandler(.cancel)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            MainActor.assumeIsolated {
                guard let session else { decisionHandler(.allow); return }
                let response = navigationResponse.response
                let http = response as? HTTPURLResponse
                let attachment = http?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
                if navigationResponse.isForMainFrame, !navigationResponse.canShowMIMEType || attachment {
                    session.events.downloads.append(response.suggestedFilename ?? response.url?.lastPathComponent ?? "a file")
                    decisionHandler(.cancel)
                    return
                }
                if navigationResponse.isForMainFrame, let http { session.recordMainStatus(http.statusCode, url: http.url) }
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            MainActor.assumeIsolated { session?.navigationStarted() }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            MainActor.assumeIsolated { session?.committed() }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            MainActor.assumeIsolated { session?.navigationFinished() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated { session?.navigationFailed(error) }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            MainActor.assumeIsolated {
                let error = error as NSError
                session?.navigationFailed(error)
                guard error.code != NSURLErrorCancelled else { return }
                session?.console.append(.error, error.localizedDescription)
            }
        }

        // MARK: UI: a page has no way to put anything in front of the user or the agent

        /// A link that opens a new window opens here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }

        /// Alerts are accepted; confirms and prompts are dismissed. Each is told to the agent.
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping () -> Void) {
            MainActor.assumeIsolated {
                session?.events.dialogs.append(BrowserReport.dialog(kind: "alert", message: message, handled: "accepted"))
                completionHandler()
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            MainActor.assumeIsolated {
                session?.events.dialogs.append(BrowserReport.dialog(kind: "confirm", message: message, handled: "dismissed"))
                completionHandler(false)
            }
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            MainActor.assumeIsolated {
                session?.events.dialogs.append(BrowserReport.dialog(kind: "prompt", message: prompt, handled: "dismissed"))
                completionHandler(nil)
            }
        }

        /// A file chooser is cancelled.
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping ([URL]?) -> Void) {
            MainActor.assumeIsolated {
                session?.console.append(.warning, "A file chooser was cancelled.")
                completionHandler(nil)
            }
        }

        /// Camera and microphone requests are denied.
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}

// MARK: View

/// The session's web view in the pane. The view is the session's, so taking this out of the
/// window (the pane hidden, another tab, a layout parked) keeps the page as it was: it goes back
/// to the session's off-screen window (`parkOffscreen`) and comes here again when the pane does.
struct BrowserPageView: NSViewRepresentable {
    let session: BrowserSession

    func makeNSView(context: Context) -> Container { Container(session: session) }

    func updateNSView(_ container: Container, context: Context) {
        container.attach(session.webView)
    }

    static func dismantleNSView(_ container: Container, coordinator: ()) {
        container.detach()
    }

    final class Container: NSView {
        private weak var page: WKWebView?
        private weak var session: BrowserSession?

        init(session: BrowserSession) {
            self.session = session
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            if page != nil { MainActor.assumeIsolated { session?.paneSizeChanged(bounds.size) } }
        }

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
            MainActor.assumeIsolated { session?.parkOffscreen() }
        }
    }
}

// MARK: What WebKit says

/// A script the page's web view could not run: the exception's own words, for the agent to read.
struct BrowserScriptFailure: Error {
    var message: String
    /// The script did not compile (the exception is a `SyntaxError`).
    var isSyntaxError = false
    /// The page did not answer in time.
    var isTimeout = false

    init(message: String) { self.message = message }

    static var timedOut: BrowserScriptFailure {
        var failure = BrowserScriptFailure(message: "The page did not answer in time.")
        failure.isTimeout = true
        return failure
    }

    init(_ error: Error) {
        let nsError = error as NSError
        if let thrown = nsError.userInfo["WKJavaScriptExceptionMessage"] as? String {
            message = thrown
            isSyntaxError = thrown.hasPrefix("SyntaxError")
        } else {
            message = nsError.localizedDescription
        }
    }
}
