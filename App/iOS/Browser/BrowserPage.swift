import SwiftUI
import UIKit
import WebKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A remote thread's Browser page on the phone and iPad (docs/browser.md › Remote): the page renders in
// this device's own web view and its URL stays `localhost:5173`; its traffic to the host's loopback
// ports goes to the host over the authenticated connection, through a listener on this device's
// loopback at the same port (`BrowserPagePorts`, `BrowserPortForwarder`, `BrowserTunnelHub`, all
// shared with the Mac). The only file of the iOS app that imports WebKit.
//
// The page is the user's alone: the host's agent does not drive it (`browser.drive.v1` is not
// built here), so a host can't make this device open anything.

/// One thread's page: its web view, the ports it holds, the host's dev servers, and why nothing
/// loaded. Made by `MobileBrowsers`, which lets its ports go while the host is disconnected.
@MainActor
@Observable
final class BrowserPage {
    let ref: AgentRef
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

    @ObservationIgnored weak var host: MobileHost?
    @ObservationIgnored let ports: BrowserPagePorts
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var waitTask: Task<Void, Never>?

    /// How long Start waits for its port, tried every half second, as on the Mac.
    static let waitSeconds = 90
    /// The schemes a page may take its main frame to: web pages, blank and blob documents.
    static let pageSchemes: Set<String> = ["http", "https", "about", "blob"]

    init(ref: AgentRef, host: MobileHost, forwarder: BrowserPortForwarder) {
        self.ref = ref
        self.host = host
        ports = BrowserPagePorts(forwarder: forwarder,
                                 owner: BrowserPortForwarder.Owner(id: "\(ref.host.uuidString)/\(ref.agent.rawValue)", hostName: host.name),
                                 agent: ref.agent, slot: host.tunnelSlot)
    }

    var hostName: String { host?.name ?? "the host" }

    /// The host is connected and carries Browser tunnels.
    var isServed: Bool { host?.phase == .connected && host?.supports(RemoteProtocol.browserTunnelCapability) == true }

    /// "this iPhone", "this iPad": where the forwarded ports listen, for a refusal's words.
    static var here: String { "this \(UIDevice.current.model)" }

    // MARK: The connection

    /// The host is connected: the ports the page held are taken again.
    func resume() {
        guard host?.supports(RemoteProtocol.browserTunnelCapability) == true else { return }
        let refused = ports.resume()
        if let first = refused.first { notice = first.message(hostName: hostName, here: Self.here) }
    }

    /// The host went away (or the app is leaving the foreground): nothing listens until it is back.
    func suspend() {
        stopWaiting()
        ports.suspend()
    }

    /// The page is gone: its ports, its web view and its wait go with it.
    func close() {
        stopWaiting()
        ports.close()
        observations.removeAll()
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        delegate = nil
    }

    // MARK: Opening

    /// Opens `url`, making the web view the first time. False, with the reason in `notice`, when a
    /// port of the host can't be forwarded for it: nothing loads then.
    @discardableResult
    func open(_ url: URL) -> Bool {
        stopWaiting()
        if let refusal = ports.forward(url) {
            notice = refusal.message(hostName: hostName, here: Self.here)
            return false
        }
        notice = nil
        let view = webView ?? makeWebView()
        if self.url != url { self.url = url }
        view.load(URLRequest(url: url))
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

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    // MARK: Dev servers

    /// Reads the host's dev servers once a connection is up, then opens the first whose port
    /// answers when nothing is open yet.
    func loadDevServers() async {
        guard isServed, let client = host?.connectedClient else { return }
        if devServers == nil {
            guard let found = try? await client.devServers(agentID: ref.agent) else { return }
            devServers = found
        }
        guard url == nil, waitingFor == nil, !lookedForRunning, let hub = host?.tunnelSlot.hub else { return }
        lookedForRunning = true
        var tried: Set<Int> = []
        for server in devServers ?? [] {
            guard let serverURL = server.url, let port = server.port, tried.insert(port).inserted else { continue }
            if await hub.probe(agentID: ref.agent, port: port) == .reachable {
                if url == nil, waitingFor == nil { open(serverURL) }
                return
            }
        }
    }

    /// Start on the host: runs the script in a new terminal of the thread's layout there, and opens
    /// its page once the port answers (when the port is known).
    func start(_ server: DevServer) async {
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
        guard let port = BrowserTunnelTarget.port(of: url) else {
            open(url)
            return
        }
        waitTask?.cancel()
        // The port is forwarded first, so it answers by the way the page will go.
        if let refusal = ports.forward(url) {
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

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // Nothing of the page is kept on the device or shared with another thread's page.
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        let delegate = Delegate(page: self)
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        self.delegate = delegate
        observations = [
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
        guard let url = action.request.url else { return .allow }
        if action.shouldPerformDownload { return .cancel }
        let isMain = action.targetFrame?.isMainFrame ?? true
        if isMain, !Self.pageSchemes.contains(url.scheme?.lowercased() ?? "") { return .cancel }
        if let refusal = ports.forward(url) {
            notice = refusal.message(hostName: hostName, here: Self.here)
            return .cancel
        }
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

    @MainActor
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var page: BrowserPage?

        init(page: BrowserPage) { self.page = page }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(page?.decide(navigationAction) ?? .cancel)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            page?.notice = nil
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

        /// A link that opens a new window opens in this page instead: a thread has one page here.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
            return nil
        }
    }
}

/// The page's web view, wherever the page is shown (the side pane, or pushed full screen): one web
/// view a thread, moved into whichever container is in a window, so it never reloads.
struct BrowserWebView: UIViewRepresentable {
    let page: BrowserPage

    func makeUIView(context: Context) -> Container {
        let container = Container()
        container.webView = page.webView
        return container
    }

    func updateUIView(_ container: Container, context: Context) {
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
