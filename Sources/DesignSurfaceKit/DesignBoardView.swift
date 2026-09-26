import Foundation
import ShepherdProtocol
import WebKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
public typealias DesignPlatformView = NSView
#else
import UIKit
public typealias DesignPlatformView = UIView
#endif

/// What a board view tells its host.
public enum DesignBoardEvent: Equatable, Sendable {
    /// The board rendered for the first time (fonts, images and imports settled, or three seconds
    /// passed). `size` is what it drew, measured from the page; `preview` is its `$preview`.
    case booted(size: CGSize, preview: CGSize?)
    /// What the board draws changed size after it booted.
    case resized(CGSize)
    /// The board's logic, template, an import or a script failed. The board keeps rendering what
    /// it can.
    case problem(DesignBoardProblem)
    /// The board asked to go to another board of the design (`<a href="Cart.dc.html">`). Nothing
    /// navigates; the host decides.
    case link(DesignPath)
    /// The board's web content process ended. `load()` starts it again.
    case terminated
}

public struct DesignBoardProblem: Error, Equatable, Sendable, CustomStringConvertible {
    /// Where it happened: `boot`, `logic`, `template`, `props`, `render`, `import` or `script`.
    public var phase: String
    public var message: String
    public var line: Int?

    public init(phase: String, message: String, line: Int? = nil) {
        self.phase = phase
        self.message = message
        self.line = line
    }

    public var description: String { "\(phase): \(message)" }
}

public enum DesignBoardError: Error, Equatable, Sendable {
    /// The page never loaded (the board file is missing, or the load failed).
    case loadFailed(String)
    /// The page loaded without Shepherd's runtime: the board lacks its `./support.js` line.
    case noRuntime
    /// The content process ended before the board booted.
    case terminated
    /// `replaceSource` or `snapshot` before the board booted.
    case notBooted
    /// The runtime refused new source; the board keeps what it showed.
    case refused(String)
    case snapshotFailed
    case rulesUnavailable
}

/// One board of a design, live: a `WKWebView` in the design's sandbox, loaded from
/// `shepherd-design://`, that runs Shepherd's runtime and reports through a bridge in a content
/// world of its own. It is sized to the board (its canvas `w` × `h` in points); the canvas
/// scales it.
///
/// Board content is untrusted: loads other than the design's scheme (and Google Fonts, when the
/// surface allows them) are blocked by content rules and a CSP, every navigation is refused
/// (in-project links come back as `.link`), and no window opens.
@MainActor
public final class DesignBoardView: DesignPlatformView {
    public let surface: DesignSurface
    public let board: DesignPath
    /// Everything the board reports, on the main actor.
    public var onEvent: ((DesignBoardEvent) -> Void)?
    /// What the board drew, once it booted.
    public private(set) var contentSize: CGSize?

    public var boardSize: CGSize {
        didSet { frame.size = boardSize }
    }

    let webView: WKWebView
    /// Navigations the page started, the first load included. `replaceSource` never adds one.
    private(set) var navigationsStarted = 0
    /// Navigations the board asked for and was refused.
    private(set) var navigationsRefused = 0

    private let delegate = Delegate()
    private var bootWaiter: CheckedContinuation<CGSize, any Error>?
    private var loadURL: URL?
    private var rulesInstalled = false

    static let bridgeWorld = WKContentWorld.world(name: "shepherd-design-bridge")
    static let messageName = "shepherdDesign"

    public init(surface: DesignSurface, board: DesignPath, size: CGSize) {
        self.surface = surface
        self.board = board
        boardSize = size
        let configuration = surface.makeConfiguration()
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: DesignRuntime.bridgeScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true, in: Self.bridgeWorld))
        controller.add(delegate, contentWorld: Self.bridgeWorld, name: Self.messageName)
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        super.init(frame: CGRect(origin: .zero, size: size))
        delegate.owner = self
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        webView.allowsMagnification = false
        webView.autoresizingMask = [.width, .height]
        #else
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.isScrollEnabled = false
        #endif
        addSubview(webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Loading

    /// Loads the board from its file and waits until it has rendered. Returns what it drew.
    @discardableResult
    public func load() async throws -> CGSize {
        if !rulesInstalled {
            let rules = try await DesignContentRules.list(network: surface.network)
            if !rulesInstalled {
                webView.configuration.userContentController.add(rules)
                rulesInstalled = true
            }
        }
        finishBoot(.failure(CancellationError()))
        contentSize = nil
        let url = surface.url(for: board)
        loadURL = url
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bootWaiter = continuation
                webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task { @MainActor in
                self.webView.stopLoading()
                self.finishBoot(.failure(CancellationError()))
            }
        }
    }

    /// Re-renders the board from `source` in place: no navigation, no blank frame, and the
    /// board's state is kept. The source is the whole `.dc.html` file, as it is written.
    ///
    /// Only the template, the logic and the helmet change this way; the lines of the board's
    /// `<head>` (its title aside) take effect at the next `load()`.
    public func replaceSource(_ source: String) async throws {
        guard contentSize != nil else { throw DesignBoardError.notBooted }
        let result = try await webView.callAsyncJavaScript(
            "return window.__shepherdDC ? window.__shepherdDC.replaceSource(source) : { ok: false, error: 'no runtime' }",
            arguments: ["source": source], in: nil, contentWorld: .page)
        let reply = result as? [String: Any]
        guard reply?["ok"] as? Bool == true else {
            throw DesignBoardError.refused(reply?["error"] as? String ?? "the runtime gave no answer")
        }
    }

    /// The board as drawn, `boardSize` from its top left, at the view's backing scale.
    public func snapshot() async throws -> CGImage {
        guard contentSize != nil else { throw DesignBoardError.notBooted }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: boardSize)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DesignBoardError.snapshotFailed }
        #else
        guard let cgImage = image.cgImage else { throw DesignBoardError.snapshotFailed }
        #endif
        return cgImage
    }

    // MARK: Events

    private func finishBoot(_ result: Result<CGSize, any Error>) {
        guard let waiter = bootWaiter else { return }
        bootWaiter = nil
        waiter.resume(with: result)
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "booted":
            let size = CGSize(width: Self.number(message["width"]) ?? 0, height: Self.number(message["height"]) ?? 0)
            var preview: CGSize?
            if let width = Self.number(message["previewWidth"]), let height = Self.number(message["previewHeight"]) {
                preview = CGSize(width: width, height: height)
            }
            contentSize = size
            onEvent?(.booted(size: size, preview: preview))
            finishBoot(.success(size))
        case "size":
            guard contentSize != nil else { return }
            let size = CGSize(width: Self.number(message["width"]) ?? 0, height: Self.number(message["height"]) ?? 0)
            contentSize = size
            onEvent?(.resized(size))
        case "error":
            let problem = DesignBoardProblem(phase: message["phase"] as? String ?? "script",
                                             message: message["message"] as? String ?? "",
                                             line: (message["line"] as? NSNumber).map(\.intValue).flatMap { $0 > 0 ? $0 : nil })
            onEvent?(.problem(problem))
        default:
            break
        }
    }

    private static func number(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber, !(value is Bool) else { return nil }
        let double = number.doubleValue
        return double.isFinite && double >= 0 ? CGFloat(double) : nil
    }

    fileprivate func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        let policy = decide(action)
        if policy == .cancel { navigationsRefused += 1 }
        return policy
    }

    private func decide(_ action: WKNavigationAction) -> WKNavigationActionPolicy {
        guard action.targetFrame?.isMainFrame == true, let url = action.request.url else { return .cancel }
        if action.shouldPerformDownload { return .cancel }
        // The load `load()` asked for.
        if let loadURL, url == loadURL, action.navigationType == .other || action.navigationType == .reload {
            self.loadURL = nil
            return .allow
        }
        // A jump within the board (`href="#id"`).
        if let current = webView.url, Self.sameDocument(url, current) { return .allow }
        if action.navigationType == .linkActivated, let target = surface.board(at: url) {
            onEvent?(.link(target))
        }
        return .cancel
    }

    private static func sameDocument(_ a: URL, _ b: URL) -> Bool {
        guard a.fragment != nil else { return false }
        var left = URLComponents(url: a, resolvingAgainstBaseURL: false)
        var right = URLComponents(url: b, resolvingAgainstBaseURL: false)
        left?.fragment = nil
        right?.fragment = nil
        return left != nil && left == right
    }

    fileprivate func started() {
        navigationsStarted += 1
    }

    fileprivate func failed(_ error: any Error) {
        finishBoot(.failure(DesignBoardError.loadFailed(error.localizedDescription)))
    }

    fileprivate func finished() {
        guard bootWaiter != nil else { return }
        Task {
            let kind = try? await webView.evaluateJavaScript("typeof window.__shepherdDC", in: nil, contentWorld: .page) as? String
            if kind != "object" { finishBoot(.failure(DesignBoardError.noRuntime)) }
        }
    }

    fileprivate func terminated() {
        contentSize = nil
        finishBoot(.failure(DesignBoardError.terminated))
        onEvent?(.terminated)
    }

    // MARK: Delegate

    /// WebKit's delegates and the bridge's message handler, held weakly toward the view (the
    /// content controller retains its handlers).
    private final class Delegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var owner: DesignBoardView?

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.world == DesignBoardView.bridgeWorld, message.frameInfo.isMainFrame else { return }
            owner?.received(message.body)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            decisionHandler(owner?.policy(for: action) ?? .cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            // A file that isn't a page never opens as one (and never downloads).
            decisionHandler(response.isForMainFrame && !response.canShowMIMEType ? .cancel : .allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            owner?.started()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            owner?.finished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            owner?.failed(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            owner?.failed(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            owner?.terminated()
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }
    }
}
