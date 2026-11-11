import SwiftUI
import WebKit

extension EnvironmentValues {
    /// Whether an `html-render` fence draws as a live page. Only an agent's reply turns it on: an issue body or a
    /// repository file is someone else's HTML, and stays code.
    @Entry public var shProseHTML = false
}

/// A page an agent drew in its reply: a finished `html-render` fence in a sandboxed web view, with its title and size
/// under it (ThreadHTMLDiagram, ThreadHTMLInteractive boards). While the fence is open, its code under a "Drawing" line
/// (ThreadHTMLWriting). The sandbox is `SHMermaidBlock`'s (no network, files, storage or navigation) except that the
/// page's own inline scripts run; it falls back to its code when WebKit can't render it.
struct SHHTMLBlock<Code: View>: View {
    let source: String
    let writing: Bool
    @ViewBuilder let code: () -> Code
    @Environment(\.colorScheme) private var colorScheme
    @State private var height = SHMermaidMetrics.initialHeight
    @State private var status = SHMermaidStatus.loading

    static func renders(language: String?, pages: Bool) -> Bool {
        pages && language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "html-render"
    }

    var body: some View {
        let sh = Color.sh
        if writing {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                caption(title: "Drawing", meta: "html · \(size) so far", glyph: sh.running)
                code()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if status == .failed {
                    VStack(alignment: .leading, spacing: SH.Space.m) {
                        Text("Page couldn’t be rendered. Its source is below.")
                            .font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                        code()
                    }
                    .padding(SH.Space.l)
                } else {
                    HTMLWebView(source: source, colors: ThemeStore.shared.theme.variant(dark: colorScheme == .dark).colors,
                                dark: colorScheme == .dark, height: $height, status: $status)
                        .frame(height: height)
                        .accessibilityLabel(Self.title(source) ?? "Page")
                }
                caption(title: Self.title(source) ?? "Page", meta: meta, glyph: sh.textSecondary)
                    .padding(.horizontal, SH.Space.l).padding(.vertical, SH.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sh.bgRaised)
                    .overlay(alignment: .top) { SHHairline() }
            }
            .background(sh.bgBase)
            .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
            .shBorder(sh.lineSubtle, radius: SH.Radius.l)
        }
    }

    private func caption(title: String, meta: String, glyph: Color) -> some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(glyph).accessibilityHidden(true)
            Text(title).font(.sh(.ui)).fontWeight(.semibold).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Text(meta).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        }
        .font(.sh(.caption))
    }

    private var size: String { Int64(source.utf8.count).formatted(.byteCount(style: .file)) }
    private var meta: String {
        source.range(of: "<script", options: .caseInsensitive) == nil ? "html · \(size)" : "html · \(size) · interactive"
    }

    /// The page's `<title>`, which names the card.
    static func title(_ source: String) -> String? {
        guard let match = source.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        let inner = source[match].replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return inner.isEmpty ? nil : inner
    }

    /// The agent's markup in a body after our head: the policy comes first, so nothing in the page can loosen it; no
    /// network, frames, forms or plugins; inline scripts and styles run. Theme colors are CSS variables the page may use.
    static func document(source: String, colors: ThemeColors, dark: Bool, revision: String) -> String? {
        guard source.utf8.count <= SHHTMLMetrics.maximumSourceBytes, let fontData = MermaidRenderer.fontData else { return nil }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; media-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>@font-face{font-family:Geist;src:url(data:font/otf;base64,\(fontData)) format('opentype')}
        :root{color-scheme:\(dark ? "dark" : "light");--bg:\(colors.bgBase);--bg-raised:\(colors.bgRaised);--bg-sunken:\(colors.bgSunken);--text:\(colors.textPrimary);--text-secondary:\(colors.textSecondary);--text-tertiary:\(colors.textTertiary);--line:\(colors.lineSubtle);--line-strong:\(colors.lineStrong);--accent:\(colors.running);--accent-tint:\(colors.runningTint);--done:\(colors.done);--failed:\(colors.failed)}
        html{background:transparent;overflow:hidden}body{margin:\(Int(SH.Space.xl))px;font:\(SHTextStyle.body.size)px/1.5 Geist,-apple-system,sans-serif;color:var(--text);overflow:hidden}</style>
        <script>(() => {
          const report = () => window.webkit.messageHandlers.diagram.postMessage({revision:'\(revision)',state:'ready',
            height:Math.ceil(document.body.getBoundingClientRect().bottom + parseFloat(getComputedStyle(document.body).marginBottom))});
          addEventListener('DOMContentLoaded', () => { new ResizeObserver(report).observe(document.body); report(); });
        })();</script></head><body>
        \(source)
        </body></html>
        """
    }
}

enum SHHTMLMetrics {
    /// Inline SVG makes pages larger than Mermaid sources; past this the fence stays code.
    static let maximumSourceBytes = 200_000
}

@MainActor
private struct HTMLWebView {
    let source: String
    let colors: ThemeColors
    let dark: Bool
    @Binding var height: CGFloat
    @Binding var status: SHMermaidStatus

    func makeCoordinator() -> MermaidRenderer { MermaidRenderer() }
    func update(_ renderer: MermaidRenderer) {
        renderer.onStatus = { state, measured in
            status = state
            if let measured { height = measured }
        }
        renderer.load(key: source + String(describing: colors) + String(dark)) { revision in
            SHHTMLBlock<EmptyView>.document(source: source, colors: colors, dark: dark, revision: revision)
        }
    }
}

#if os(macOS)
extension HTMLWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateNSView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleNSView(_ view: WKWebView, coordinator: MermaidRenderer) { coordinator.stop() }
}
#else
extension HTMLWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.webView }
    func updateUIView(_ view: WKWebView, context: Context) { update(context.coordinator) }
    static func dismantleUIView(_ view: WKWebView, coordinator: MermaidRenderer) { coordinator.stop() }
}
#endif
