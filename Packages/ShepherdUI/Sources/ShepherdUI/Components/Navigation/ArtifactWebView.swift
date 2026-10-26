import SwiftUI
import WebKit

/// An HTML or SVG artifact, drawn in its own styles on its own background (PaneArtifacts › An open artifact). The file is the agent's
/// output and is treated as untrusted:
/// - JavaScript is off (`allowsContentJavaScript`), so nothing in it runs;
/// - it loads from a string with no base URL, so it reads no file at all (a relative image or stylesheet stays unloaded);
/// - a content rule list blocks every request but `data:`, so it cannot reach the network (an `<img>`, a stylesheet, a font, a prefetch);
/// - every navigation is cancelled (a link, a redirect, a form, a new window), and the page keeps no data between opens.
/// An SVG is drawn through an `<img>`, which never runs script or loads another resource.
public struct SHArtifactWebView: View {
    let html: String

    public init(html: String) { self.html = html }

    public init(svg: String) { self.html = SHArtifactHTML.picture(base64: Data(svg.utf8).base64EncodedString()) }

    public var body: some View { ArtifactWebHost(html: html) }
}

/// The documents the view loads, built as text so a test can read them.
public enum SHArtifactHTML {
    /// The page 18pt in from the pane's edge, padded on `html` so a report's own `body{margin:0}` keeps the inset (its background still
    /// fills it, since the root's background paints the canvas), put after its `<head>` so a leading doctype keeps its standards mode.
    public static func document(_ html: String) -> String {
        let style = "<style>html{padding:\(Int(SHArtifactMetrics.documentInset))px}:where(body){margin:0}</style>"
        if let head = html.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: style)
        }
        if let root = html.range(of: "<html[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: root.upperBound..<root.upperBound, with: "<head>\(style)</head>")
        }
        return "<!doctype html><html><head><meta charset=\"utf-8\">\(style)</head><body>\(html)</body></html>"
    }

    /// An SVG as a picture, scaled down to the pane.
    public static func picture(base64: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0}body{padding:\(Int(SHArtifactMetrics.documentInset))px}img{display:block;max-width:100%;height:auto}</style></head>
        <body><img alt="" src="data:image/svg+xml;base64,\(base64)"></body></html>
        """
    }

    /// Every request but `data:` is blocked.
    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
    """
}

@MainActor
final class SHArtifactWebRenderer: NSObject, WKNavigationDelegate {
    private(set) var webView: WKWebView!
    private var loaded: String?
    private var task: Task<Void, Never>?
    /// The compiled rules, shared: compiling is the slow part.
    private static var compiled: WKContentRuleList?

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
    }

    /// Loads `html` once the rules are on the view: a page never loads before them.
    func load(_ html: String) {
        guard loaded != html else { return }
        loaded = html
        task?.cancel()
        task = Task { [weak self] in
            guard let rules = await Self.rules() else { return }
            guard !Task.isCancelled, let self, self.loaded == html else { return }
            let controller = self.webView.configuration.userContentController
            controller.removeAllContentRuleLists()
            controller.add(rules)
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }

    private static func rules() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let list = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "shepherd.artifact", encodedContentRuleList: SHArtifactHTML.rules)
        compiled = list
        return list
    }

    func stop() {
        task?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    /// The first load is the page itself; nothing after it navigates.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let initial = navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank"
        decisionHandler(initial ? .allow : .cancel)
    }
}

@MainActor
private struct ArtifactWebHost {
    let html: String

    func makeCoordinator() -> SHArtifactWebRenderer { SHArtifactWebRenderer() }
    func update(_ renderer: SHArtifactWebRenderer) { renderer.load(SHArtifactHTML.document(html)) }
}

#if os(macOS)
extension ArtifactWebHost: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: SHArtifactWebRenderer) { coordinator.stop() }
}
#else
extension ArtifactWebHost: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateUIView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: SHArtifactWebRenderer) { coordinator.stop() }
}
#endif
