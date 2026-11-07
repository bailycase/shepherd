import Foundation
import UIKit
import WebKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Artifacts (iPadPaneArtifacts; the iPhone sheet): a thread whose `write` calls made a report, a plan, a diagram and a note. The host
// serves their bytes in `NativeImage.chunkBytes` pieces (`native.artifacts.v1`); the report is padded past one piece so the client
// reassembles it. `artifacts-old-host` is a host without the capability.
extension FixtureCatalog {
    static var artifacts: [FixtureScreen] {
        let ref = FixtureData.ref(FixtureData.preview)
        let thread = MobileRoute.thread(ref)
        let pane = MobileRoute.review(.changes(ref, file: nil))
        return [
            FixtureScreen(name: "artifacts-thread", hosts: ArtifactsFixture.hosts(), routes: [thread]),
            FixtureScreen(name: "artifacts-list", hosts: ArtifactsFixture.hosts(), routes: [thread, pane], prepare: { app in
                ArtifactsFixture.open(nil, app)
            }),
            FixtureScreen(name: "artifacts-html", hosts: ArtifactsFixture.hosts(), routes: [thread, pane], prepare: { app in
                ArtifactsFixture.open(ArtifactsFixture.report, app)
                await ArtifactsFixture.fetched(app, ArtifactsFixture.report)
                await ArtifactsFixture.checkPage()
            }),
            FixtureScreen(name: "artifacts-markdown", hosts: ArtifactsFixture.hosts(), routes: [thread, pane], prepare: { app in
                ArtifactsFixture.open(ArtifactsFixture.plan, app)
                await ArtifactsFixture.fetched(app, ArtifactsFixture.plan)
            }),
            FixtureScreen(name: "artifacts-svg", hosts: ArtifactsFixture.hosts(), routes: [thread, pane], prepare: { app in
                ArtifactsFixture.open(ArtifactsFixture.diagram, app)
                await ArtifactsFixture.fetched(app, ArtifactsFixture.diagram)
            }),
            FixtureScreen(name: "artifacts-iphone", hosts: ArtifactsFixture.hosts(), routes: [thread],
                          presented: .review(.artifact(ref, path: ArtifactsFixture.plan)), prepare: { app in
                              await ArtifactsFixture.fetched(app, ArtifactsFixture.plan)
                          }),
            // A host without `native.artifacts.v1`: the thread still lists what it made; opening one must settle, not spin.
            FixtureScreen(name: "artifacts-old-host", hosts: ArtifactsFixture.hosts(capable: false), routes: [thread, pane], prepare: { app in
                ArtifactsFixture.open(ArtifactsFixture.report, app)
                try? await Task.sleep(for: .seconds(3))
            }),
        ]
    }
}

enum ArtifactsFixture {
    static let report = "reports/load-test-report.html"
    static let plan = "retry-plan.md"
    static let diagram = "diagram.svg"
    static let notes = "notes.txt"

    static let reportHTML = """
    <!doctype html>
    <html><head><meta charset="utf-8"><title>Load test</title>
    <style>
    body{font-family:-apple-system,sans-serif;background:#fff;color:#111;margin:0}
    h1{font-size:22px;margin:0 0 4px} .sub{color:#667;font-size:13px;margin-bottom:16px}
    .cards{display:flex;gap:12px;margin-bottom:20px} .card{flex:1;border:1px solid #e3e5ea;border-radius:10px;padding:10px 14px}
    .card b{display:block;font-size:24px} .card span{color:#778;font-size:12px}
    table{width:100%;border-collapse:collapse;font-size:14px} th,td{padding:8px;border-bottom:1px solid #e3e5ea;text-align:left}
    .bad{color:#d22}
    </style></head>
    <body>
    <h1 id="title">Retry service: load test at 2× peak</h1>
    <div class="sub">Sep 24 · k6 · 12 minutes · build-01</div>
    <div class="cards">
      <div class="card"><span>p50</span><b>41 ms</b><span>target 60</span></div>
      <div class="card"><span>p95</span><b>186 ms</b><span>240 at 8:10</span></div>
      <div class="card"><span>Errors</span><b style="color:#1a8">0.02%</b><span>31 of 142k</span></div>
    </div>
    <table>
    <tr><th>Stage</th><th>Time</th><th>Load</th><th>p95</th><th>Errors</th></tr>
    <tr><td>Warm-up</td><td>0–2m</td><td>1×</td><td>44 ms</td><td>0.00%</td></tr>
    <tr><td>Ramp</td><td>2–6m</td><td>1× → 2×</td><td>63 ms</td><td>0.01%</td></tr>
    <tr><td>Peak</td><td>6–10m</td><td>2×</td><td class="bad">240 ms</td><td>0.09%</td></tr>
    <tr><td>Recover</td><td>10–12m</td><td>2×</td><td>79 ms</td><td>0.00%</td></tr>
    </table>
    <img id="remote" src="https://example.com/x.png" alt="REMOTE-IMAGE" width="120" height="40">
    <script>document.body.innerHTML = "<h1>SCRIPT RAN</h1>"; document.body.dataset.ran = "1";</script>
    </body></html>
    <!-- \(String(repeating: "padding past one 256 KiB piece. ", count: 9_000)) -->
    """

    static let planMarkdown = """
    # Retry plan

    The provider recovered at 8:10 and every queued retry fired at once. Spread them out:

    - Jitter each retry by up to 30% of its backoff.
    - Cap concurrent retries per merchant at **8**.
    - Shed retries older than `5m` instead of replaying them.

    ```go
    func backoff(attempt int) time.Duration {
        base := time.Second << attempt
        return base + time.Duration(rand.Int63n(int64(base) * 3 / 10))
    }
    ```

    Then run the load test again at 2× peak.
    """

    static let diagramSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="360" height="140" viewBox="0 0 360 140">
      <rect x="10" y="40" width="100" height="60" rx="8" fill="#4f46e5"/><text x="60" y="75" fill="#fff" font-size="14" text-anchor="middle">Client</text>
      <line x1="110" y1="70" x2="240" y2="70" stroke="#888" stroke-width="3"/><polygon points="240,62 254,70 240,78" fill="#888"/>
      <rect x="254" y="40" width="100" height="60" rx="8" fill="#16a34a"/><text x="304" y="75" fill="#fff" font-size="14" text-anchor="middle">Retry</text>
    </svg>
    """

    static let notesText = "k6 run --vus 400 retry.js\nprovider outage 8:00–8:40\n"

    static var files: [String: Data] {
        [report: Data(reportHTML.utf8), plan: Data(planMarkdown.utf8), diagram: Data(diagramSVG.utf8), notes: Data(notesText.utf8)]
    }

    static func write(_ id: String, _ path: String, _ content: String, minutesAgo: Double) -> NativeThreadMessage {
        let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["path": path, "content": content]), as: UTF8.self)
        let at = Date().timeIntervalSince1970 * 1000 - FixtureData.start - minutesAgo * 60_000
        return FixtureData.tool(id, "write", args: args, output: "Successfully wrote \(content.utf8.count) bytes to \(path)", at: at)
    }

    static func thread() -> NativeThreadSnapshot {
        let ago = Date().timeIntervalSince1970 * 1000 - FixtureData.start
        var snapshot = FixtureData.snapshot([
            FixtureData.user("a1", "Load test the retry path at 2× peak and write it up.", at: ago - 14 * 60_000),
            FixtureData.tool("a2", "bash", args: #"{"command":"k6 run --vus 400 retry.js"}"#, output: "✓ 142k requests", at: ago - 8 * 60_000),
            write("a3", report, reportHTML, minutesAgo: 6),
            write("a4", plan, planMarkdown, minutesAgo: 5),
            write("a5", diagram, diagramSVG, minutesAgo: 4),
            write("a6", notes, notesText, minutesAgo: 3),
            FixtureData.assistant("a7", "p95 stayed under the SLO except for 70 seconds after the provider came back. The report, the retry plan and a diagram are open beside you.",
                                  at: ago - 2 * 60_000),
        ])
        snapshot.supportedActions.append("artifacts")
        return snapshot
    }

    static func hosts(capable: Bool = true) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        if let index = hosts[0].state.agents.firstIndex(where: { $0.id == FixtureData.preview }) {
            hosts[0].state.agents[index].name = "Plan the payments retry service"
        }
        hosts[0].threads[FixtureData.preview] = thread()
        hosts[0].artifacts = files
        if !capable {
            hosts[0].capabilities = hosts[0].defaultCapabilities.filter { $0 != RemoteProtocol.nativeArtifactsCapability }
        }
        return hosts
    }

    @MainActor static var store: ReviewStore { ReviewStores.shared.store(for: FixtureData.ref(FixtureData.preview)) }

    /// The pane on its Artifacts tab: the list, or `path` open.
    @MainActor static func open(_ path: String?, _ app: MobileApp) {
        app.navigator.sidePane.show(.artifacts)
        store.artifact = path
    }

    /// Waits until the thread's store holds the file's bytes, every piece of it.
    @MainActor static func fetched(_ app: MobileApp, _ path: String) async {
        let thread = app.threads.store(for: FixtureData.ref(FixtureData.preview))
        await ReviewFixture.until {
            thread.artifacts.first { $0.path == path }.flatMap { thread.artifactFiles.cached($0) } == files[path]
        }
    }

    /// The report's page drew its own content, its script did not run, and its remote image did not load.
    @MainActor static func checkPage() async {
        guard let web = await webView() else { return FixtureCheck.report("FIXTURE CHECK FAILED artifacts-html: no web view") }
        await FixtureWindows.wait("report loaded", seconds: 10) { !web.isLoading && web.url != nil }
        try? await Task.sleep(for: .seconds(1))
        let probe = """
        JSON.stringify({title: (document.getElementById('title')||{}).textContent || null, ran: document.body.dataset.ran || null,
          cards: document.querySelectorAll('.card').length, rows: document.querySelectorAll('tr').length,
          image: (document.getElementById('remote')||{}).naturalWidth || 0})
        """
        let result = (try? await web.evaluateJavaScript(probe)) as? String ?? "nil"
        let ok = result.contains("load test at 2") && result.contains("\"ran\":null") && result.contains("\"cards\":3")
            && result.contains("\"rows\":5") && result.contains("\"image\":0")
        FixtureCheck.report("FIXTURE CHECK \(ok ? "ok" : "FAILED") artifacts-html \(result)")
    }

    @MainActor private static func webView() async -> WKWebView? {
        for _ in 0..<100 {
            for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
                for window in scene.windows { if let found = find(in: window) { return found } }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    @MainActor private static func find(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }
}
