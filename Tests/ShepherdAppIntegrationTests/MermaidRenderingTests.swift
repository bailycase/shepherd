import AppKit
import SwiftUI
import Testing
import WebKit
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdUI
@testable import ShepherdApp

@Suite("Mermaid rendering", .serialized, .mainActorExclusive)
@MainActor
struct MermaidRenderingTests {
    @Test func localRenderErrorAndSecurity() async throws {
        let renderer = MermaidRenderer()
        let window = OffscreenWindow(size: CGSize(width: 640, height: 480))
        window.window.contentView = renderer.webView
        renderer.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        defer { renderer.stop(); window.close() }
        var status = NWMermaidStatus.loading
        renderer.onStatus = { status = $0; _ = $1 }
        let colors = ThemeDefinition.nightWatch.light.colors
        renderer.render(source: "flowchart LR\n A[Request] --> B[Review]", colors: colors, fontSize: NWTextStyle.body.size)
        try await eventuallyOnMain("Mermaid rendered") { status == .ready }
        #expect(try await renderer.webView.evaluateJavaScript("document.querySelectorAll('#chart svg').length") as? Int == 1)
        #expect(!renderer.webView.configuration.websiteDataStore.isPersistent)
        #expect(try await renderer.webView.evaluateJavaScript("mermaid.mermaidAPI.getConfig().securityLevel") as? String == "strict")
        let networkBlocked = try await renderer.webView.callAsyncJavaScript(
            """
            return await new Promise(resolve => {
                document.addEventListener('securitypolicyviolation', event => resolve(event.effectiveDirective === 'connect-src'), {once:true});
                fetch('data:text/plain,blocked').then(() => resolve(false)).catch(() => {});
                setTimeout(() => resolve(false), 1000);
            });
            """,
            arguments: [:], in: nil, contentWorld: .page)
        #expect(networkBlocked as? Bool == true)
        for (source, label) in [
            ("sequenceDiagram\nAlice->>Bob: Review request\nBob-->>Alice: Approved", "Review request"),
            ("erDiagram\nPROJECT ||--o{ TASK : contains\nTASK {\n string title\n}", "title")
        ] {
            status = .loading
            renderer.render(source: source, colors: colors, fontSize: NWTextStyle.body.size)
            try await eventuallyOnMain("Mermaid sequence/ER chart") { status == .ready }
            let text = try await renderer.webView.evaluateJavaScript("document.querySelector('#chart svg').textContent") as? String
            #expect(text?.contains(label) == true)
            if label == "Review request" {
                #expect(try await renderer.webView.evaluateJavaScript("getComputedStyle(document.querySelector('#chart .messageText')).fontFamily.includes('Geist')") as? Bool == true)
                let messageSize = try await renderer.webView.evaluateJavaScript("parseFloat(getComputedStyle(document.querySelector('#chart .messageText')).fontSize)") as? Double
                #expect(messageSize == Double(NWTextStyle.body.size))
            }
        }
        status = .loading
        renderer.render(source: "not a diagram", colors: colors, fontSize: NWTextStyle.body.size)
        try await eventuallyOnMain("Mermaid parse error") { status == .failed }
        status = .loading
        renderer.render(source: "%%{init: {'securityLevel':'loose'}}%%\nflowchart LR\nA-->B", colors: colors, fontSize: NWTextStyle.body.size)
        try await eventuallyOnMain("Mermaid directive rendered safely") { status == .ready }
        #expect(try await renderer.webView.evaluateJavaScript("mermaid.mermaidAPI.getConfig().securityLevel") as? String == "strict")
        status = .loading
        renderer.render(source: "---\ntitle: Safe title\nconfig:\n  securityLevel: loose\n---\nflowchart LR\nA-->B", colors: colors, fontSize: NWTextStyle.body.size)
        try await eventuallyOnMain("Mermaid frontmatter") { status == .ready }
        #expect(try await renderer.webView.evaluateJavaScript("mermaid.mermaidAPI.getConfig().securityLevel") as? String == "strict")
        status = .loading
        renderer.render(source: "flowchart LR\nOld-->Result", colors: colors, fontSize: NWTextStyle.body.size)
        renderer.render(source: "flowchart LR\nCurrent-->Result", colors: ThemeDefinition.nightWatch.dark.colors, fontSize: NWTextStyle.body.size * 1.3)
        try await eventuallyOnMain("latest Mermaid render") { status == .ready }
        let text = try await renderer.webView.evaluateJavaScript("document.getElementById('chart').textContent") as? String
        #expect(text?.contains("Current") == true)
        #expect(text?.contains("Old") == false)
        status = .loading
        renderer.render(source: String(repeating: "x", count: NWMermaidMetrics.maximumSourceBytes + 1), colors: colors, fontSize: NWTextStyle.body.size)
        try await eventuallyOnMain("oversized diagram source rejected") { status == .failed }
    }

    /// Inline, a plain scroll over an unzoomed chart is the thread's; ⌘-scroll zooms toward the pointer, then a scroll pans until
    /// the chart's edge and passes through there. The viewer keeps every scroll.
    @Test func zoomAndPan() async throws {
        for viewer in [false, true] {
            let renderer = MermaidRenderer()
            let window = OffscreenWindow(size: CGSize(width: 640, height: 480))
            window.window.contentView = renderer.webView
            renderer.webView.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            defer { renderer.stop(); window.close() }
            var status = NWMermaidStatus.loading
            renderer.onStatus = { status = $0; _ = $1 }
            renderer.render(source: "flowchart LR\nA[Request] --> B[Review] --> C[Approved]",
                            colors: ThemeDefinition.nightWatch.light.colors, fontSize: NWTextStyle.body.size, viewer: viewer)
            try await eventuallyOnMain("chart rendered") { status == .ready }
            func wheel(_ dx: Double, _ dy: Double, meta: Bool = false) async throws -> Bool {
                let script = """
                const event = new WheelEvent('wheel', {deltaX: \(dx), deltaY: \(dy), metaKey: \(meta), clientX: 40, clientY: 20, cancelable: true, bubbles: true});
                document.getElementById('chart').dispatchEvent(event);
                return event.defaultPrevented;
                """
                return try await renderer.webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page) as? Bool == true
            }
            func zoom() async throws -> [String: Double] {
                try #require(try await renderer.webView.evaluateJavaScript("window.nwZoom.state()") as? [String: Double])
            }
            #expect(try await wheel(0, 40) == viewer, "an unzoomed scroll passes to the thread only inline")
            #expect(try await zoom()["s"] == 1)
            #expect(try await wheel(0, -200, meta: true))
            let zoomed = try await zoom()
            #expect(zoomed["s"]! > 2)
            #expect(try await wheel(30, 0), "a zoomed chart pans")
            #expect(try await zoom()["x"]! < zoomed["x"]!)
            _ = try await wheel(-100_000, 0)
            #expect(try await zoom()["x"] == 0, "panning stops at the chart's edge")
            #expect(try await wheel(-40, 0) == viewer, "at the edge, a scroll passes through only inline")
            #expect(try await wheel(0, 100_000, meta: true))
            #expect(try await zoom()["s"] == 1, "zooming out stops at the fitted size")
            #expect(try await wheel(0, -100_000, meta: true))
            #expect(try await zoom()["s"] == Double(NWMermaidMetrics.maximumZoom))
        }
    }

    @Test func markdownRoutesFinishedFencesOnly() async throws {
        let open = nativeMarkdownParse("```mermaid\nflowchart LR\nA-->B\n", streaming: true)
        let closed = nativeMarkdownParse("```mermaid\nflowchart LR\nA-->B\n```\n", streaming: true)
        #expect(open.endsInOpenFence)
        #expect(!closed.endsInOpenFence)
        #expect(NWProseBlock.lastCodePath(Prose.proseBlocks(closed.blocks)) == [0])
        let repeated = nativeMarkdownParse("```mermaid\nflowchart LR\nA-->B\n```\n```mermaid\nflowchart LR\nA-->B", streaming: true)
        let window = OffscreenWindow(Prose(blocks: repeated.blocks, writingFence: repeated.endsInOpenFence))
        defer { window.close() }
        try await eventuallyOnMain("completed duplicate stays a diagram", timeout: .seconds(5)) {
            window.layout()
            return mermaidWebViews(in: window.host).count == 1
        }
        window.show(Prose(blocks: repeated.blocks, writingFence: false))
        try await eventuallyOnMain("both finished diagrams render", timeout: .seconds(5)) {
            window.layout()
            return mermaidWebViews(in: window.host).count == 2
        }
    }
}

@Suite("Mermaid previews", .serialized, .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] != nil, "set SHEPHERD_PREVIEW_DIR"))
@MainActor
struct MermaidPreviewTests {
    @Test func markdownDiagram() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let blocks = nativeMarkdownBlocks("""
            ### Review workflow
            The finished chart renders inline; its source remains available below.

            ```mermaid
            flowchart LR
              Request --> Agent
              Agent --> Review
              Review --> Approved
            ```

            ```mermaid
            sequenceDiagram
              Agent->>Reviewer: Review request
              Reviewer-->>Agent: Approved
            ```
            """)
            let window = OffscreenWindow(size: CGSize(width: 680, height: 620), dark: dark,
                Prose(blocks: blocks).padding()
                    .frame(width: 680, height: 620, alignment: .topLeading)
                    .background(Color.nw.bgWindow)
                    .environment(\.nwPresentDiagram) { _ in }
                    .environment(\.colorScheme, dark ? .dark : .light))
            defer { window.close() }

            try await eventuallyOnMain("Markdown Mermaid web views") {
                window.layout()
                return mermaidWebViews(in: window.host).count == 2
            }
            var snapshots: [(WKWebView, NSImage)] = []
            for chart in mermaidWebViews(in: window.host) {
                try await eventually("Markdown Mermaid SVG and layout") { @Sendable @MainActor in
                    window.layout()
                    guard let height = try? await chart.evaluateJavaScript("document.querySelector('#chart svg') && document.getElementById('chart').getBoundingClientRect().height") as? Double else { return false }
                    return height > 0 && abs(chart.frame.height - min(CGFloat(height), NWMermaidMetrics.maximumHeight)) < 1
                }
                snapshots.append((chart, try await chart.takeSnapshot(configuration: nil)))
            }
            window.layout()
            let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
            window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
            // AppKit cacheDisplay omits WebKit's remote compositor. Overlay its actual snapshot.
            let image = NSImage(size: window.host.bounds.size)
            image.lockFocus()
            bitmap.draw(in: CGRect(origin: .zero, size: image.size))
            for (chart, snapshot) in snapshots {
                let frame = chart.convert(chart.bounds, to: window.host)
                let rect = CGRect(x: frame.minX, y: image.size.height - frame.maxY, width: frame.width, height: frame.height)
                snapshot.draw(in: rect)
            }
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let output = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try output.write(to: directory.appendingPathComponent("thread-mermaid-\(dark ? "dark" : "light").png"))
        }
    }

    /// The viewer over a window: the bar, the chart fitted to the room, and the hint line.
    @Test func fullScreenViewer() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"])
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = "flowchart TD\n  Request --> Agent\n  Agent --> Review\n  Review -->|changes| Agent\n  Review --> Approved"
        for dark in [false, true] {
            let size = CGSize(width: 900, height: 640)
            let window = OffscreenWindow(size: size, dark: dark,
                NWMermaidViewer(source) {}
                    .frame(width: size.width, height: size.height)
                    .background(Color.nw.bgWindow)
                    .environment(\.colorScheme, dark ? .dark : .light))
            defer { window.close() }
            var chart: WKWebView?
            try await eventuallyOnMain("viewer web view") {
                window.layout()
                chart = mermaidWebViews(in: window.host).first
                return chart != nil
            }
            let web = try #require(chart)
            try await eventually("viewer SVG") { @Sendable @MainActor in
                window.layout()
                return (try? await web.evaluateJavaScript("document.body.classList.contains('viewer') && document.querySelector('#chart svg').getBoundingClientRect().height > 0")) as? Bool == true
            }
            // The chart fills the room it is given, not its inline height.
            #expect(web.frame.height > size.height / 2)
            let snapshot = try await web.takeSnapshot(configuration: nil)
            let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
            window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
            let image = NSImage(size: window.host.bounds.size)
            image.lockFocus()
            bitmap.draw(in: CGRect(origin: .zero, size: image.size))
            let frame = web.convert(web.bounds, to: window.host)
            snapshot.draw(in: CGRect(x: frame.minX, y: image.size.height - frame.maxY, width: frame.width, height: frame.height))
            image.unlockFocus()
            let tiff = try #require(image.tiffRepresentation)
            let output = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
            try output.write(to: directory.appendingPathComponent("thread-mermaid-viewer-\(dark ? "dark" : "light").png"))
        }
    }
}

@MainActor
private func mermaidWebViews(in view: NSView) -> [WKWebView] {
    if let web = view as? WKWebView { return [web] }
    return view.subviews.flatMap { mermaidWebViews(in: $0) }
}
