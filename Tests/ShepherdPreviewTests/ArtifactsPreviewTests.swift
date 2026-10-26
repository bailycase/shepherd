import AppKit
import Foundation
import ShepherdCore
@testable import ShepherdUI
import ShepherdProtocol
import ShepherdRemote
import SwiftUI
import ShepherdTestSupport
import Testing
import WebKit
@testable import ShepherdApp

/// The side pane's Artifacts tab (PaneArtifacts) and the card in the thread, in light and dark, drawn from a real `NativeThreadStore`
/// fed a snapshot with real `write` calls, whose files a client fetches through the same chunked request the iPad uses (here answered
/// from a scratch folder by `NativeArtifactFile`, the reader the host serves with). See `PreviewTests` for how previews run.
@Suite("Artifact previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ArtifactsPreviewTests {
    private static var now: Double { Date().timeIntervalSince1970 * 1000 }

    static let report = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    body{font-family:-apple-system,Helvetica,sans-serif;color:#1c2330;background:#ffffff}
    h1{font-size:22px;margin:0 0 4px}.sub{color:#5b6b85;font-size:13px;margin-bottom:18px}
    .cards{display:flex;gap:12px;margin-bottom:18px}.card{flex:1;border:1px solid #dde3ee;border-radius:8px;padding:12px}
    .card b{display:block;font-size:26px}.good{color:#0a9b6a}.k{color:#5b6b85;font-size:12px}
    table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:right;padding:7px 0;border-bottom:1px solid #e7ebf3}
    th:first-child,td:first-child{text-align:left}.bad{color:#d92d20}
    </style></head><body>
    <h1>Retry service: load test at 2× peak</h1><div class="sub">Sep 24 · k6 · 12 minutes · build-01</div>
    <div class="cards"><div class="card"><span class="k">p50</span><b>41 ms</b><span class="k">target 60</span></div>
    <div class="card"><span class="k">p95</span><b>186 ms</b><span class="k">240 at 8:10</span></div>
    <div class="card"><span class="k">Errors</span><b class="good">0.02%</b><span class="k">31 of 142k</span></div></div>
    <p>The provider came back after a 40-second outage and every queued retry fired at once.</p>
    <table><tr><th>Stage</th><th>Time</th><th>p95</th><th>Errors</th></tr>
    <tr><td>Warm-up</td><td>0–2m</td><td>44 ms</td><td>0.00%</td></tr><tr><td>Ramp</td><td>2–6m</td><td>63 ms</td><td>0.01%</td></tr>
    <tr><td>Peak</td><td>6–10m</td><td class="bad">240 ms</td><td>0.09%</td></tr></table>
    <script>document.title = 'ran'; fetch('https://example.com/leak')</script><img src="https://example.com/pixel.png">
    </body></html>
    """

    static let plan = """
    # Retry plan

    Full jitter on the backoff, and a **budget** so a recovering provider is not hit all at once.

    ## Steps

    1. Add `jitter` to `Backoff` (full, not equal).
    2. Cap in-flight retries at 200.
    3. Re-run the 2× peak test and compare p95.

    | Stage | p95 |
    | --- | --- |
    | Peak | 240 ms |
    | Recover | 79 ms |

    ```swift
    let delay = Double.random(in: 0...base)
    ```

    ![diagram](https://example.com/remote.png)
    """

    private struct Folder {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("artifact-preview-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ name: String, _ text: String) throws {
            let file = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
    }

    private static func write(_ path: String, id: String, minutesAgo: Double) -> NativeThreadMessage {
        let at = now - minutesAgo * 60_000
        return NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: "Successfully wrote")], toolName: "write",
                                   toolCallID: id, argumentsText: #"{"content":"x","path":"\#(path)"}"#, status: "complete", isError: false, timestamp: at, startedAt: at - 2000)
    }

    private static func messages(_ writes: [(String, Double)]) -> [NativeThreadMessage] {
        var rows = [NativeThreadMessage(entryID: "u", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Load test the retry path at 2× peak and write it up.")],
                                        timestamp: now - 20 * 60_000)]
        for (index, write) in writes.enumerated() { rows.append(write.0.isEmpty ? rows[0] : Self.write(write.0, id: "w\(index)", minutesAgo: write.1)) }
        rows.append(NativeThreadMessage(entryID: "a", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: "p95 stayed under the 200 ms SLO except for 70 seconds after the provider came back. The report has the chart and the stage table.")],
                                        status: "stop", timestamp: now - 60_000))
        return rows
    }

    /// A store whose host serves files from `folder`, as `RPCThreadState` does for the written paths.
    private static func loaded(_ rows: [NativeThreadMessage], folder: URL) async throws -> (NativeThreadStore, Task<Void, Never>) {
        let snapshot = NativeThreadSnapshot(piSessionID: "fixture", generation: "g", revision: 1, running: false, model: "anthropic/claude-opus-4-5",
                                            supportedActions: ["send", "artifacts"], dialogsSupported: true, dialogs: [], messages: rows, provisional: [],
                                            clipped: false, runtime: "rpc")
        let store = NativeThreadStore()
        let written = Set(rows.compactMap { $0.toolName == "write" ? NativeActivityCall($0).path : nil })
        let task = Task {
            await store.run { request in
                switch request {
                case .artifact(_, let path, let offset):
                    guard written.contains(path) else { return .failure(code: NativeArtifactCode.unknown, message: "") }
                    switch NativeArtifactFile.read(path, offset: offset, cwd: folder.path) {
                    case .chunk(let chunk): return .artifactChunk(value: chunk)
                    case .outOfRange: return .failure(code: NativeArtifactCode.unknown, message: "")
                    case .unavailable: return .failure(code: NativeArtifactCode.unavailable, message: "")
                    }
                default: return .snapshot(value: snapshot)
                }
            }
        }
        try await eventuallyOnMain("the thread to load") { store.ready && store.artifacts.count == Set(written).count }
        return (store, task)
    }

    private static let board = [("reports/Load test report.html", 6.0), ("docs/retry-plan.md", 0.1), ("diagrams/flow.svg", 95), ("notes/summary.txt", 1500)]

    /// The strip over the tab, as the workspace composes the pane.
    private struct Pane: View {
        let store: NativeThreadStore
        let size: CGSize
        var selection: String?
        var body: some View {
            VStack(spacing: 0) {
                SHSidePaneTabs(SidePaneTabs.items(news: [], changedFiles: 2, artifacts: store.artifacts.count), selection: SidePaneTab.artifacts.rawValue,
                               select: { _ in }, closeShortcut: "⇧⌘B", close: {}) {}
                ArtifactsTab(store: store, actions: ArtifactsActions(selection: selection, show: { _ in }, editorURL: { URL(fileURLWithPath: "/tmp/\($0.name)") }, failed: { _ in }))
            }
            .frame(width: size.width, height: size.height)
            .background(Color.sh.bgWindow)
        }
    }

    private func render(_ surface: String, selection: String? = nil, size: CGSize = CGSize(width: 600, height: 560), ready: String? = nil) async throws {
        let folder = try Folder()
        try folder.write("reports/Load test report.html", Self.report)
        try folder.write("docs/retry-plan.md", Self.plan)
        try folder.write("diagrams/flow.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='360' height='120'><rect width='360' height='120' fill='#eef2ff'/><circle cx='60' cy='60' r='30' fill='#4f46e5'/><text x='110' y='66' font-size='20' fill='#1c2330'>Request → Agent</text></svg>")
        try folder.write("notes/summary.txt", "Retry budget: 200 in flight.\nJitter: full.\n")
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let (store, task) = try await Self.loaded(Self.messages(Self.board), folder: folder.url)
        defer { task.cancel(); store.stop() }
        // The open artifact is fetched by its own view; the capture waits for the store to hold its file.
        try await Preview.render(surface, size: size, ready: {
            selection.flatMap { path in store.artifacts.first { $0.path == path } }.map { store.artifactFiles.cached($0) != nil } ?? true
        }) { Pane(store: store, size: size, selection: selection) }
    }

    @Test func theList() async throws { try await render("artifacts-list", size: CGSize(width: 600, height: 360)) }

    @Test func aMarkdownPlanInShepherdDesignColors() async throws { try await render("artifacts-markdown", selection: "docs/retry-plan.md") }

    @Test func anHtmlReportOnItsOwnBackground() async throws {
        try await render("artifacts-html", selection: "reports/Load test report.html", size: CGSize(width: 600, height: 620))
    }

    @Test func anSvgAsAnImage() async throws { try await render("artifacts-svg", selection: "diagrams/flow.svg", size: CGSize(width: 600, height: 300)) }

    @Test func aTextFileAsSource() async throws { try await render("artifacts-text", selection: "notes/summary.txt", size: CGSize(width: 600, height: 240)) }

    @Test func aFileThatCannotBeOpened() async throws {
        let folder = try Folder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let (store, task) = try await Self.loaded(Self.messages([("gone.md", 3)]), folder: folder.url)
        defer { task.cancel(); store.stop() }
        try await Preview.render("artifacts-unavailable", size: CGSize(width: 600, height: 260)) { Pane(store: store, size: CGSize(width: 600, height: 260), selection: "gone.md") }
    }

    // MARK: In the thread

    /// The turn as the thread draws it: the line, the words after it, then the card (PaneArtifacts › In the thread).
    @Test func theLineAndTheCardInTheThread() async throws {
        let folder = try Folder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let rows = Self.messages([("reports/Load test report.html", 6), ("scratch.swift", 5)])
        let presentation = nativeTurnPresentation(Array(rows.dropFirst()), live: false)
        #expect(presentation.items.contains { if case .artifact = $0 { true } else { false } })
        try await Preview.renderMatrix("artifacts-thread", size: CGSize(width: 660, height: 300)) {
            AgentTurn(presentation: presentation, live: false, startedAt: Self.now - 20 * 60_000, footer: false)
                .environment(\.openArtifact, { _ in })
                .padding(SH.Space.xxl)
                .frame(width: 660, alignment: .leading)
                .background(Color.sh.bgWindow)
        }
    }

    // MARK: The page itself

    /// `cacheDisplay` cannot capture a web view's layers, so the HTML artifact's page is snapshotted from the web view itself, through
    /// the same renderer the pane uses (JavaScript off, every request but `data:` blocked): the report's own styles on its own background,
    /// its script and its remote image absent.
    @Test func theHtmlPageAsTheLockedDownWebViewDrawsIt() async throws {
        let directory = try #require(Preview.directory)
        let renderer = SHArtifactWebRenderer()
        renderer.webView.frame = CGRect(x: 0, y: 0, width: 600, height: 560)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = renderer.webView
        window.orderBack(nil)
        defer { renderer.stop(); window.orderOut(nil); window.contentView = nil }
        renderer.load(SHArtifactHTML.document(Self.report))
        var shot: NSImage?
        for _ in 0..<200 where shot == nil {
            try await Task.sleep(for: .milliseconds(50))
            guard (try? await renderer.webView.evaluateJavaScript("document.readyState")) as? String == "complete" else { continue }
            let text = (try? await renderer.webView.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String ?? ""
            guard text.contains("Retry service") else { continue }
            let title = (try? await renderer.webView.evaluateJavaScript("document.title")) as? String
            #expect(title != "ran", "its script did not run")
            try await Task.sleep(for: .milliseconds(500))
            shot = try? await renderer.webView.takeSnapshot(configuration: WKSnapshotConfiguration())
        }
        let image = try #require(shot)
        let tiff = try #require(image.tiffRepresentation)
        let rep = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("artifacts-html-page.png"))
    }

    // MARK: The iPad pane

    /// The iPad pane (iPadPaneArtifacts) as the iOS screens compose it, from the shared components and the same store: the segmented
    /// head, the 52pt bar, the list, and an open Markdown artifact. (The iOS target itself is built, not run, by `xcodebuild`.)
    private struct PadPane: View {
        let store: NativeThreadStore
        var open: NativeArtifact?
        @State private var mode = SHArtifactMode.preview
        var body: some View {
            VStack(spacing: 0) {
                SHPadPaneHead([SHPadPaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2),
                               SHPadPaneTab(id: "artifacts", title: "Artifacts", systemImage: SHGlyph.artifact.symbolName, count: store.artifacts.count)],
                              selection: "artifacts", select: { _ in }, close: {})
                if let open {
                    SHArtifactBar(name: open.name, symbol: open.kind.symbol, hasPreview: true, mode: $mode, pad: true, back: {}) {
                        Button {} label: { Image(systemName: "square.and.arrow.down") }.buttonStyle(.shIcon(size: SH.Height.touch - SH.Space.xs))
                    }
                    if case .markdown(let blocks, _) = NativeArtifactDocument(open, data: Data(ArtifactsPreviewTests.plan.utf8)) {
                        ScrollView { SHAgentProse(Prose.proseBlocks(blocks), maxWidth: .infinity).padding(SHArtifactMetrics.documentInset).frame(maxWidth: .infinity, alignment: .leading) }
                    }
                } else {
                    SHArtifactList(store.artifacts.map { ArtifactRows.row($0) }, open: { _ in })
                }
            }
            .frame(width: 640, height: 560)
            .background(Color.sh.bgWindow)
        }
    }

    @Test func theIPadPane() async throws {
        let folder = try Folder()
        defer { try? FileManager.default.removeItem(at: folder.url) }
        let (store, task) = try await Self.loaded(Self.messages(Self.board), folder: folder.url)
        defer { task.cancel(); store.stop() }
        try await Preview.render("artifacts-ipad-list", size: CGSize(width: 640, height: 560)) { PadPane(store: store) }
        try await Preview.render("artifacts-ipad-open", size: CGSize(width: 640, height: 560)) {
            PadPane(store: store, open: store.artifacts.first { $0.kind == .markdown })
        }
    }
}
