import AppKit
import Foundation
import Testing
import WebKit
import ShepherdTestSupport
@testable import ShepherdUI

/// An HTML artifact is the agent's output and untrusted: its page loads, but its script never runs, nothing it names is fetched, and it
/// cannot navigate away (docs/design/side-pane-artifacts.md › Artifacts).
@Suite("Artifact web view", .serialized, .mainActorExclusive)
@MainActor
struct ArtifactWebViewTests {
    /// Polls `condition` (async: it asks the page) until it holds, never a fixed sleep for the thing being waited on.
    private func until(_ what: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out waiting for \(what)")
    }

    private func load(_ html: String) async throws -> NWArtifactWebRenderer {
        let renderer = NWArtifactWebRenderer()
        renderer.webView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        renderer.load(NWArtifactHTML.document(html))
        try await until("the page to load") {
            guard (try? await renderer.webView.evaluateJavaScript("document.readyState")) as? String == "complete" else { return false }
            return (try? await renderer.webView.evaluateJavaScript("document.body ? document.body.innerText : ''")) as? String != ""
        }
        return renderer
    }

    @Test func thePageLoadsButItsScriptNeverRuns() async throws {
        let renderer = try await load("<html><head><title>start</title></head><body><p id=a>hello</p><script>document.title='ran';document.getElementById('a').textContent='scripted'</script></body></html>")
        defer { renderer.stop() }
        #expect(try await renderer.webView.evaluateJavaScript("document.getElementById('a').textContent") as? String == "hello")
        #expect(try await renderer.webView.evaluateJavaScript("document.title") as? String == "start")
    }

    @Test func nothingItNamesIsFetched() async throws {
        let renderer = try await load(#"<body><img id=i src="https://example.com/pixel.png"><link rel=stylesheet href="https://example.com/a.css"><img id=f src="file:///etc/hosts">ok</body>"#)
        defer { renderer.stop() }
        // Give the blocked loads their chance to finish: a blocked image reports as loaded-with-no-size.
        try await Task.sleep(for: .milliseconds(400))
        for id in ["i", "f"] {
            #expect(try await renderer.webView.evaluateJavaScript("document.getElementById('\(id)').naturalWidth") as? Int == 0, "\(id)")
        }
    }

    @Test func aDataImageStillDraws() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let renderer = try await load(#"<body><img id=d src="data:image/png;base64,\#(png)">x</body>"#)
        defer { renderer.stop() }
        try await until("the data image to load") { (try? await renderer.webView.evaluateJavaScript("document.getElementById('d').naturalWidth")) as? Int == 1 }
    }

    @Test func aLinkIsNotFollowed() async throws {
        let renderer = try await load(#"<body><a id=l href="https://example.com/">go</a></body>"#)
        defer { renderer.stop() }
        _ = try? await renderer.webView.evaluateJavaScript("document.getElementById('l').click()")
        try await Task.sleep(for: .milliseconds(400))
        #expect(renderer.webView.url?.scheme != "https")
    }

    @Test func theDocumentKeepsItsDoctypeAndTheMargin() {
        #expect(NWArtifactHTML.document("<!doctype html><html><head><title>t</title></head><body>x</body></html>").hasPrefix("<!doctype html><html><head><style>"))
        #expect(NWArtifactHTML.document("<h1>bare</h1>").contains("<body><h1>bare</h1></body>"))
        #expect(NWArtifactHTML.document("<html><body>x</body></html>").contains("<html><head><style>"))
    }
}
