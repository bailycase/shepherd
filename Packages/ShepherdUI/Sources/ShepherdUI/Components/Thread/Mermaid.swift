import SwiftUI
import WebKit

/// Window-owned presentation state; environment updates compare its stable identity.
@MainActor @Observable public final class SHDiagramPresentation {
    public var source: String?
    public init() {}
}

extension EnvironmentValues {
    /// Opens a diagram in the owning window without replacing a callback on every layout.
    @Entry public var shDiagramPresentation: SHDiagramPresentation? = nil
    /// An explicit callback takes precedence over window-owned presentation; retained for existing clients.
    @Entry public var shPresentDiagram: ((String) -> Void)? = nil
}

/// A finished Mermaid fence. Source stays copyable even when WebKit or Mermaid cannot render it.
/// Pinch or ⌘-scroll zooms the chart in place, a drag pans it once zoomed, and the corner button opens it full screen.
public struct SHMermaidBlock: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shProseSize) private var proseSize
    @Environment(\.shPresentDiagram) private var presentDiagram
    @Environment(\.shDiagramPresentation) private var diagramPresentation
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1
    @State private var height = SHMermaidMetrics.initialHeight
    @State private var status = SHMermaidStatus.loading
    @State private var expanded = false

    public init(_ source: String) { self.source = source }

    public static func renders(language: String?, writing: Bool) -> Bool {
        !writing && language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            MermaidWebView(source: source, colors: ThemeStore.shared.theme.variant(dark: colorScheme == .dark).colors,
                           fontSize: (SHTextStyle.body.size - proseSize.step) * ThemeStore.shared.textScale * dynamicTypeScale,
                           viewer: false, height: $height, status: $status)
                .frame(height: status == .failed ? 0 : height)
                .accessibilityLabel("Mermaid diagram")
            if status == .ready {
                DisclosureGroup("Diagram source") { SHCodeBlock(source, language: "mermaid") }
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    // On the source line, not over the chart, so it never hides part of the diagram.
                    .overlay(alignment: .topTrailing) {
                        if canExpand {
                            Button {
                                if let presentDiagram { presentDiagram(source) }
                                else if let diagramPresentation { diagramPresentation.source = source }
                                else { expanded = true }
                            } label: {
                                Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                            }
                            .buttonStyle(.sh(.ghost, size: .s))
                            .accessibilityLabel("Open diagram full screen")
                            .shHelp("Open full screen")
                        }
                    }
            } else {
                Text(status == .failed ? "Diagram couldn’t be rendered. View or copy the source below." : "Rendering diagram…")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                SHCodeBlock(source, language: "mermaid")
            }
        }
        .padding(SH.Space.l)
        .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
        #if os(iOS)
        .fullScreenCover(isPresented: $expanded) { SHMermaidViewer(source) { expanded = false } }
        #endif
    }

    private var canExpand: Bool {
        #if os(iOS)
        true
        #else
        presentDiagram != nil || diagramPresentation != nil
        #endif
    }
}

/// A diagram open over the thread, in the image viewer: the chart fills the room, pinch or ⌘-scroll zooms,
/// scroll or drag pans, double-click zooms in or back to fit. Copy takes the source.
public struct SHMermaidViewer: View {
    let source: String
    let close: () -> Void

    public init(_ source: String, close: @escaping () -> Void) {
        self.source = source
        self.close = close
    }

    public var body: some View {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).count
        SHImageViewer(name: "Mermaid diagram", facts: lines == 1 ? "1 line" : "\(lines) lines",
                      content: .diagram(AnyView(MermaidCanvas(source: source))),
                      caption: Self.caption,
                      copy: { SHPasteboard.copy(source) }, close: close)
    }
}

extension SHMermaidViewer {
    #if os(macOS)
    static let caption = "Pinch or ⌘-scroll to zoom · Drag to pan · Double-click to zoom · Esc to close"
    #else
    static let caption = "Pinch to zoom · Drag to pan · Double-tap to zoom"
    #endif
}

/// The chart that fills the viewer, or why it cannot.
private struct MermaidCanvas: View {
    let source: String
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var dynamicTypeScale: CGFloat = 1
    @State private var height = SHMermaidMetrics.initialHeight
    @State private var status = SHMermaidStatus.loading

    var body: some View {
        ZStack {
            MermaidWebView(source: source, colors: ThemeStore.shared.theme.variant(dark: colorScheme == .dark).colors,
                           fontSize: SHTextStyle.body.size * ThemeStore.shared.textScale * dynamicTypeScale,
                           viewer: true, height: $height, status: $status)
                .opacity(status == .ready ? 1 : 0)
                .accessibilityLabel("Mermaid diagram")
            if status != .ready {
                Text(status == .failed ? "Diagram couldn’t be rendered." : "Rendering diagram…")
                    .font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary)
            }
        }
    }
}

enum SHMermaidStatus: Equatable { case loading, ready, failed }

enum SHMermaidMetrics {
    static let initialHeight: CGFloat = 120
    static let maximumHeight: CGFloat = 1200
    static let maximumSourceBytes = 50_000
    static let timeout: Duration = .seconds(15)
    /// How far a chart zooms in past its fitted size.
    static let maximumZoom = 8
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
    var onStatus: (SHMermaidStatus, CGFloat?) -> Void = { _, _ in }

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
        // The page pans and zooms the chart itself; an unzoomed drag goes on to the thread's scroll view.
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        #endif
    }

    private func publish(_ state: SHMermaidStatus, _ height: CGFloat?) {
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

    func render(source: String, colors: ThemeColors, fontSize: CGFloat, viewer: Bool = false) {
        let input = source + String(describing: colors) + String(describing: fontSize) + String(viewer)
        guard key != input else { return }
        key = input
        revision = UUID().uuidString
        let current = revision
        timeout?.cancel()
        publish(.loading, nil)
        guard source.utf8.count <= SHMermaidMetrics.maximumSourceBytes,
              let html = Self.document(source: source, colors: colors, fontSize: fontSize, viewer: viewer, revision: current) else {
            webView.loadHTMLString("", baseURL: nil)
            publish(.failed, nil)
            return
        }
        navigation = webView.loadHTMLString(html, baseURL: nil)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: SHMermaidMetrics.timeout)
            guard !Task.isCancelled, let self, self.revision == current else { return }
            self.fail()
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              body["revision"] as? String == revision, let state = body["state"] as? String else { return }
        if state == "ready", let height = body["height"] as? Double, height.isFinite, height > 0 {
            timeout?.cancel()
            publish(.ready, min(CGFloat(height), SHMermaidMetrics.maximumHeight))
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

    static func document(source: String, colors: ThemeColors, fontSize: CGFloat, viewer: Bool = false, revision: String) -> String? {
        guard let bundleScript, let fontData else { return nil }
        let payload: [String: Any] = ["source": source, "revision": revision, "viewer": viewer, "variables": [
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
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(revision)'; style-src 'unsafe-inline'; img-src 'none'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>@font-face{font-family:Geist;src:url(data:font/otf;base64,\(fontData)) format('opentype')}html,body{margin:0;background:transparent;overflow:hidden}#chart{transform-origin:0 0;touch-action:pan-y;user-select:none;-webkit-user-select:none}#chart svg{display:block;max-width:100%;height:auto}body.viewer #chart{height:100vh;touch-action:none}body.viewer #chart svg{width:100%;height:100%;max-width:none!important}*{animation:none!important;transition:none!important}</style>
        <script nonce="\(revision)">\(safeBundle)</script></head><body><div id="chart"></div>
        <script nonce="\(revision)">
        const input = \(safeJSON);
        const chart = document.getElementById('chart');
        const report = (state, height) => window.webkit.messageHandlers.diagram.postMessage({revision:input.revision,state,height});
        // Zoom and pan as a transform on the chart: 1 is fitted, the chart never leaves its box. Inline, a plain scroll
        // pans only a zoomed chart and passes through at its edges, so the thread keeps scrolling; the viewer always pans.
        function zoomable(viewer) {
          let s = 1, x = 0, y = 0, start = 1, drag = null;
          const set = (ns, nx, ny) => {
            ns = Math.min(Math.max(ns, 1), \(SHMermaidMetrics.maximumZoom));
            const w = chart.offsetWidth, h = chart.offsetHeight;
            nx = Math.min(0, Math.max(w - w * ns, nx));
            ny = Math.min(0, Math.max(h - h * ns, ny));
            const moved = ns !== s || nx !== x || ny !== y;
            s = ns; x = nx; y = ny;
            chart.style.transform = s === 1 ? '' : `translate(${x}px,${y}px) scale(${s})`;
            if (!viewer) chart.style.touchAction = s > 1 ? 'none' : 'pan-y';
            chart.style.cursor = s > 1 ? 'grab' : '';
            return moved;
          };
          const at = event => [event.clientX - chart.offsetLeft, event.clientY - chart.offsetTop];
          const zoomAt = (k, [px, py]) => {
            const ns = Math.min(Math.max(s * k, 1), \(SHMermaidMetrics.maximumZoom)), r = ns / s;
            return set(ns, px - (px - x) * r, py - (py - y) * r);
          };
          window.shZoom = { state: () => ({s, x, y}), reset: () => set(1, 0, 0) };
          addEventListener('wheel', event => {
            const unit = event.deltaMode === 1 ? 16 : 1;
            if (event.ctrlKey || event.metaKey) {
              event.preventDefault();
              zoomAt(Math.exp(-event.deltaY * unit / 200), at(event));
            } else if ((viewer || s > 1) && (set(s, x - event.deltaX * unit, y - event.deltaY * unit) || viewer)) {
              event.preventDefault();
            }
          }, {passive: false});
          // WebKit reports a pinch (trackpad or touch) as gesture events; ctrl/⌘-wheel above covers mice.
          addEventListener('gesturestart', event => { event.preventDefault(); start = s; });
          addEventListener('gesturechange', event => { event.preventDefault(); zoomAt(start * event.scale / s, at(event)); });
          addEventListener('gestureend', event => event.preventDefault());
          chart.addEventListener('pointerdown', event => {
            if (s === 1 || event.button !== 0) return;
            drag = {id: event.pointerId, x: event.clientX, y: event.clientY};
            chart.setPointerCapture(event.pointerId);
            chart.style.cursor = 'grabbing';
          });
          chart.addEventListener('pointermove', event => {
            if (!drag || drag.id !== event.pointerId) return;
            set(s, x + event.clientX - drag.x, y + event.clientY - drag.y);
            drag.x = event.clientX; drag.y = event.clientY;
          });
          const end = () => { drag = null; chart.style.cursor = s > 1 ? 'grab' : ''; };
          chart.addEventListener('pointerup', end);
          chart.addEventListener('pointercancel', end);
          chart.addEventListener('dblclick', event => { if (s > 1) set(1, 0, 0); else zoomAt(2.5, at(event)); });
        }
        (async () => {
          try {
            const secure = [...new Set([...Object.keys(mermaid.mermaidAPI.getConfig()), 'secure', 'themeCSS', 'themeVariables', 'htmlLabels'])];
            const fontSize = parseFloat(input.variables.fontSize);
            mermaid.initialize({startOnLoad:false,securityLevel:'strict',suppressErrorRendering:true,
              maxTextSize:\(SHMermaidMetrics.maximumSourceBytes),maxEdges:500,htmlLabels:false,theme:'base',
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
            if (input.viewer) document.body.classList.add('viewer');
            zoomable(input.viewer);
            // The layout height, not the zoomed one: zooming never resizes the block.
            const size = () => report('ready', Math.ceil(chart.offsetHeight || chart.getBoundingClientRect().height));
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
    let viewer: Bool
    @Binding var height: CGFloat
    @Binding var status: SHMermaidStatus

    func makeCoordinator() -> MermaidRenderer { MermaidRenderer() }
    func update(_ renderer: MermaidRenderer) {
        renderer.onStatus = { state, measured in
            status = state
            if let measured { height = measured }
        }
        renderer.render(source: source, colors: colors, fontSize: fontSize, viewer: viewer)
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

#Preview("Mermaid · light") { SHMermaidBlock("flowchart LR\n  Request --> Agent --> Review").preferredColorScheme(.light) }
#Preview("Mermaid · dark") { SHMermaidBlock("flowchart LR\n  Request --> Agent --> Review").preferredColorScheme(.dark) }
