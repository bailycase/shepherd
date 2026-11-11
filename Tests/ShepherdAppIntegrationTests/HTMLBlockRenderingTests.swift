import AppKit
import SwiftUI
import Testing
import WebKit
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdUI
@testable import ShepherdApp

/// An agent's `html-render` page: its scripts run, but it reaches no network and never navigates; and only a reply draws it.
@Suite("Agent pages", .serialized, .mainActorExclusive)
@MainActor
struct HTMLBlockRenderingTests {
    static let page = """
    <title>Counter</title>
    <button id="b" onclick="this.textContent = 'clicked'">press</button>
    <a id="link" href="https://example.com/">out</a>
    <div style="height: 300px"></div>
    """

    @Test func scriptsRunButNothingLeavesThePage() async throws {
        let renderer = MermaidRenderer()
        let window = OffscreenWindow(size: CGSize(width: 640, height: 480))
        window.window.contentView = renderer.webView
        renderer.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        defer { renderer.stop(); window.close() }
        var status = SHMermaidStatus.loading, height: CGFloat = 0
        renderer.onStatus = { status = $0; if let measured = $1 { height = measured } }
        let colors = ThemeDefinition.shepherdDesign.light.colors
        renderer.load(key: Self.page) { SHHTMLBlock<EmptyView>.document(source: Self.page, colors: colors, dark: false, revision: $0) }
        try await eventuallyOnMain("page ready") { status == .ready }
        #expect(height > 300 && height < 400, "the page's own height, not the view's")
        #expect(!renderer.webView.configuration.websiteDataStore.isPersistent)
        #expect(try await renderer.webView.evaluateJavaScript("document.getElementById('b').click(); document.getElementById('b').textContent") as? String == "clicked")
        let networkBlocked = try await renderer.webView.callAsyncJavaScript(
            """
            return await new Promise(resolve => {
                document.addEventListener('securitypolicyviolation', event => resolve(event.effectiveDirective === 'connect-src'), {once:true});
                fetch('https://example.com/').then(() => resolve(false)).catch(() => {});
                setTimeout(() => resolve(false), 1000);
            });
            """, arguments: [:], in: nil, contentWorld: .page)
        #expect(networkBlocked as? Bool == true)
        _ = try await renderer.webView.evaluateJavaScript("document.getElementById('link').click(); location.href = 'https://example.com/'; 1")
        #expect(renderer.webView.url?.absoluteString == "about:blank")
        #expect(!renderer.webView.isLoading)
        #expect(try await renderer.webView.evaluateJavaScript("document.getElementById('b').textContent") as? String == "clicked", "the page is still the one we loaded")
        #expect(SHHTMLBlock<EmptyView>.title(Self.page) == "Counter")
    }

    @Test func onlyAFinishedFenceInAReplyIsAPage() async throws {
        let closed = nativeMarkdownParse("```html-render\n\(Self.page)\n```\n", streaming: true)
        let open = nativeMarkdownParse("```html-render\n\(Self.page)\n", streaming: true)
        for (blocks, writing, pages, expected) in [(closed.blocks, false, true, 1), (closed.blocks, false, false, 0), (open.blocks, true, true, 0)] {
            let window = OffscreenWindow(Prose(blocks: blocks, writingFence: writing).environment(\.shProseHTML, pages))
            defer { window.close() }
            try await eventuallyOnMain("\(expected) page web views (pages \(pages), writing \(writing))", timeout: .seconds(5)) {
                window.layout()
                return webViews(in: window.host).count == expected
            }
        }
    }
}

@Suite("Agent page previews", .serialized, .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] != nil, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct HTMLBlockPreviewTests {
    @Test func replyWithPages() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reply = """
        Every request goes through Caddy to the API, and the API reads the session from Postgres on each call.

        ```html-render
        <title>Session read path</title>
        <style>.row{display:flex;gap:12px;align-items:center}.box{padding:10px 16px;border:1px solid var(--line-strong);border-radius:8px;background:var(--bg-raised)}.new{border-style:dashed;border-color:var(--accent);color:var(--accent)}</style>
        <div class="row"><div class="box">Browser</div>→<div class="box">Caddy</div>→<div class="box">api</div>→<div class="box">Postgres</div><div class="box new">Redis</div></div>
        ```

        ```html-render
        <title>Retry delay</title>
        <button id="t" style="font:inherit">Failed checkouts</button>
        <p id="o">Retry after 400 ms: 0.6% still fail</p>
        <script>document.getElementById('t').onclick = () => document.getElementById('o').textContent = 'adds 0.4 s at p95'</script>
        ```

        ```html-render
        <title>Still writing</title>
        <svg viewBox="0 0 100 20">
        """
        let parsed = nativeMarkdownParse(reply, streaming: true)
        for dark in [false, true] {
            let size = CGSize(width: 720, height: 760)
            let window = OffscreenWindow(size: size, dark: dark,
                Prose(blocks: parsed.blocks, writingFence: parsed.endsInOpenFence).padding()
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(Color.sh.bgWindow)
                    .environment(\.shProseHTML, true)
                    .environment(\.colorScheme, dark ? .dark : .light))
            defer { window.close() }
            try await eventuallyOnMain("two pages at their reported heights") {
                window.layout()
                let pages = webViews(in: window.host)
                return pages.count == 2 && pages.allSatisfy { $0.frame.height != SHMermaidMetrics.initialHeight }
            }
            var snapshots: [(WKWebView, NSImage)] = []
            for web in webViews(in: window.host) { snapshots.append((web, try await web.takeSnapshot(configuration: nil))) }
            let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
            window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
            // AppKit cacheDisplay omits WebKit's remote compositor. Overlay its actual snapshot.
            let image = NSImage(size: window.host.bounds.size)
            image.lockFocus()
            bitmap.draw(in: CGRect(origin: .zero, size: image.size))
            for (web, snapshot) in snapshots {
                let frame = web.convert(web.bounds, to: window.host)
                snapshot.draw(in: CGRect(x: frame.minX, y: image.size.height - frame.maxY, width: frame.width, height: frame.height))
            }
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let output = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try output.write(to: directory.appendingPathComponent("thread-pages-\(dark ? "dark" : "light").png"))
        }
    }
}

@MainActor
private func webViews(in view: NSView) -> [WKWebView] {
    if let web = view as? WKWebView { return [web] }
    return view.subviews.flatMap { webViews(in: $0) }
}
