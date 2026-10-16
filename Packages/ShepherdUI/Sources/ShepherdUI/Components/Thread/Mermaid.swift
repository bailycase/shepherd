import SwiftUI
import WebKit

/// A finished Mermaid fence. Source stays copyable even when WebKit or Mermaid cannot render it.
public struct NWMermaidBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nwProseSize) private var proseSize
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1
    @State private var height = NWMermaidMetrics.initialHeight
    @State private var status = NWMermaidStatus.loading

    public init(_ source: String) { self.source = source }

    public static func renders(language: String?, writing: Bool) -> Bool {
        !writing && language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            MermaidWebView(source: source, colors: ThemeStore.shared.theme.variant(dark: colorScheme == .dark).colors,
                           fontSize: (NWTextStyle.body.size - proseSize.step) * ThemeStore.shared.textScale * dynamicTypeScale,
                           height: $height, status: $status)
                .frame(height: status == .failed ? 0 : height)
                .accessibilityLabel("Mermaid diagram")
            if status == .ready {
                DisclosureGroup("Diagram source") { NWCodeBlock(source, language: "mermaid") }
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            } else {
                Text(status == .failed ? "Diagram couldn’t be rendered. View or copy the source below." : "Rendering diagram…")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                NWCodeBlock(source, language: "mermaid")
            }
        }
        .padding(NW.Space.l)
        .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
    }
}

enum NWMermaidStatus: Equatable { case loading, ready, failed }

enum NWMermaidMetrics {
    static let initialHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 1200
    static let maximumSourceBytes = 50_000
    static let timeout: Duration = .seconds(15)
}

/// A local, inert document: no file access, network, persistence, navigation, or executable diagram labels.
/// Each revision loads a fresh document, and its nonce also rejects messages from superseded renders.
@MainActor
final class MermaidRenderer: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private(set) var webView: WKWebView!
    private var revision = ""
    private var navigation: WKNavigation?
    private var key: String?
    private var timeout: Task<Void, Never>?
    var onStatus: (NWMermaidStatus, CGFloat?) -> Void = { _, _ in }

    override init() {
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(self, name: "diagram")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        #endif
    }

    private func publish(_ state: NWMermaidStatus, _ height: CGFloat?) {
        let current = revision
        Task { @MainActor [weak self] in
            guard let self, self.revision == current else { return }
            self.onStatus(state, height)
        }
    }

    func stop() {
        revision = UUID().uuidString
        timeout?.cancel()
        navigation = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "diagram")
        webView.navigationDelegate = nil
    }

    func render(source: String, colors: ThemeColors, fontSize: CGFloat) {
        let input = source + String(describing: colors) + String(describing: fontSize)
        guard key != input else { return }
        key = input
        revision = UUID().uuidString
        let current = revision
        timeout?.cancel()
        publish(.loading, nil)
        guard source.utf8.count <= NWMermaidMetrics.maximumSourceBytes,
              let html = Self.document(source: source, colors: colors, fontSize: fontSize, revision: current) else {
            webView.loadHTMLString("", baseURL: nil)
            publish(.failed, nil)
            return
        }
        navigation = webView.loadHTMLString(html, baseURL: nil)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: NWMermaidMetrics.timeout)
            guard !Task.isCancelled, let self, self.revision == current else { return }
            self.fail()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              body["revision"] as? String == revision, let state = body["state"] as? String else { return }
        if state == "ready", let height = body["height"] as? Double, height.isFinite, height > 0 {
            timeout?.cancel()
            publish(.ready, min(CGFloat(height), NWMermaidMetrics.maximumHeight))
        } else if state == "error" {
            fail()
        }
    }

    private func fail() {
        revision = UUID().uuidString
        timeout?.cancel()
        navigation = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        publish(.failed, nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType == .other && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        if (error as NSError).code != NSURLErrorCancelled { fail() }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail()
    }

    private static let fontData: String? = {
        guard let url = Bundle.module.url(forResource: "Geist-Regular", withExtension: "otf", subdirectory: "Fonts") else { return nil }
        return (try? Data(contentsOf: url))?.base64EncodedString()
    }()

    private static let bundleScript: String? = {
        guard let url = Bundle.module.url(forResource: "mermaid.min", withExtension: "js", subdirectory: "Mermaid") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    static func document(source: String, colors: ThemeColors, fontSize: CGFloat, revision: String) -> String? {
        guard let bundleScript, let fontData else { return nil }
        let payload: [String: Any] = ["source": source, "revision": revision, "variables": [
            "background": colors.bgSunken, "primaryColor": colors.bgRaised,
            "primaryTextColor": colors.textPrimary, "primaryBorderColor": colors.lineStrong,
            "secondaryColor": colors.bgWindow, "tertiaryColor": colors.bgRaised,
            "lineColor": colors.textSecondary, "textColor": colors.textPrimary,
            "edgeLabelBackground": colors.bgSunken, "fontFamily": "Geist",
            "fontSize": "\(fontSize)px"
        ]]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return nil }
        // Neither source nor a theme value can close a script element.
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        let safeBundle = bundleScript.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(revision)'; style-src 'unsafe-inline'; img-src 'none'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>@font-face{font-family:Geist;src:url(data:font/otf;base64,\(fontData)) format('opentype')}html,body{margin:0;background:transparent}#chart svg{display:block;max-width:100%;height:auto}*{animation:none!important;transition:none!important}</style>
        <script nonce="\(revision)">\(safeBundle)</script></head><body><div id="chart"></div>
        <script nonce="\(revision)">
        const input = \(safeJSON);
        const chart = document.getElementById('chart');
        const report = (state, height) => window.webkit.messageHandlers.diagram.postMessage({revision:input.revision,state,height});
        (async () => {
          try {
            const secure = [...new Set([...Object.keys(mermaid.mermaidAPI.getConfig()), 'secure', 'themeCSS', 'themeVariables', 'htmlLabels'])];
            const fontSize = parseFloat(input.variables.fontSize);
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
              maxTextSize:\(NWMermaidMetrics.maximumSourceBytes),maxEdges:500,htmlLabels:false,theme:'base',
              fontSize,fontFamily:'Geist',themeVariables:input.variables,flowchart:{htmlLabels:false},secure});
            await document.fonts.load(input.variables.fontSize + ' Geist');
            const result = await mermaid.render('diagram', input.source);
            const parsed = new DOMParser().parseFromString(result.svg, 'image/svg+xml');
            if (parsed.querySelector('parsererror') || parsed.documentElement.localName !== 'svg') throw Error('Invalid SVG');
            // Defense in depth beyond Mermaid's strict sanitizer. Links are never interactive.
            parsed.querySelectorAll('script,foreignObject,image,iframe,object,embed,animate,animateMotion,animateTransform,set').forEach(node => node.remove());
            parsed.querySelectorAll('*').forEach(node => {
              for (const attr of [...node.attributes]) {
                if (/^on/i.test(attr.name) || /href$/i.test(attr.name) && (!attr.value.startsWith('#') || node.localName === 'a')) node.removeAttribute(attr.name);
              }
            });
            chart.replaceChildren(document.importNode(parsed.documentElement, true));
            const size = () => report('ready', Math.ceil(chart.getBoundingClientRect().height));
            new ResizeObserver(size).observe(chart);
            size();
          } catch (_) { chart.replaceChildren(); report('error', null); }
        })();
        </script></body></html>
        """
    }
}

@MainActor
private struct MermaidWebView {
    let source: String
    let colors: ThemeColors
    let fontSize: CGFloat
    @Binding var height: CGFloat
    @Binding var status: NWMermaidStatus

    func makeCoordinator() -> MermaidRenderer { MermaidRenderer() }
    func update(_ renderer: MermaidRenderer) {
        renderer.onStatus = { state, measured in
            status = state
            if let measured { height = measured }
        }
        renderer.render(source: source, colors: colors, fontSize: fontSize)
    }
}

#if os(macOS)
extension MermaidWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: MermaidRenderer) { coordinator.stop() }
}
#else
extension MermaidWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateUIView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: MermaidRenderer) { coordinator.stop() }
}
#endif

#Preview("Mermaid · light") { NWMermaidBlock("flowchart LR\n  Request --> Agent --> Review").preferredColorScheme(.light) }
#Preview("Mermaid · dark") { NWMermaidBlock("flowchart LR\n  Request --> Agent --> Review").preferredColorScheme(.dark) }
