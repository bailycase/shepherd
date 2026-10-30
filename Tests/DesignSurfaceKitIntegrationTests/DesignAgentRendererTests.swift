import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import DesignSurfaceKit

@MainActor
@Suite(.mainActorExclusive)
struct DesignAgentRendererTests {
    @Test func aRuntimeThatNeverBootsTimesOutWithoutHoldingTheRendererForever() async throws {
        let h = try BoardHarness(files: [
            "Never.dc.html": "<html><head><script src='./never.js'></script></head><body>Waiting</body></html>",
            "never.js": "window.__shepherdDC={};"
        ])
        defer { try? FileManager.default.removeItem(at: h.folder) }
        let view = try h.view("Never.dc.html")
        do {
            try await view.load(timeout: .milliseconds(100))
            Issue.record("a board without a boot event completed loading")
        } catch { #expect(String(describing: error).contains("Timed out")) }
    }

    @Test func aLoadThatStartsWhileAnotherWaitsFailsTheEarlierCallerInsteadOfHoldingIt() async throws {
        let h = try BoardHarness(files: [
            "Never.dc.html": "<html><head><script src='./never.js'></script></head><body>Waiting</body></html>",
            "never.js": "window.__shepherdDC={};"
        ])
        defer { try? FileManager.default.removeItem(at: h.folder) }
        let view = try h.view("Never.dc.html")
        let first = Task { @MainActor in try await view.load(timeout: .seconds(30)) }
        defer { first.cancel() }
        try await eventuallyOnMain("the first board navigation to start") { view.webView.url != nil }
        let second = Task { @MainActor in try await view.load(timeout: .milliseconds(100)) }
        defer { second.cancel() }
        do {
            _ = try await first.value
            Issue.record("the superseded load completed")
        } catch {
            #expect(error is CancellationError)
        }
        do {
            _ = try await second.value
            Issue.record("a board without a boot event completed loading")
        } catch { #expect(String(describing: error).contains("Timed out")) }
    }

    @Test func aRuntimeInspectionPromiseThatNeverResolvesHitsItsNativeDeadline() async throws {
        let h = try BoardHarness(files: [
            "A.dc.html": "<html><head><script src='./never.js'></script></head><body>A</body></html>",
            "never.js": """
                window.__shepherdDC = {captureStatus: () => new Promise(() => {})};
                document.addEventListener('DOMContentLoaded', () => document.dispatchEvent(
                    new CustomEvent('shepherd-dc', {detail: JSON.stringify({type:'booted'})})));
                """
        ])
        let view = try h.view("A.dc.html")
        try await view.load()
        do {
            _ = try await view.captureStatus(timeout: .milliseconds(20))
            Issue.record("an unresolved runtime promise kept the caller waiting")
        } catch { #expect(String(describing: error).contains("Timed out while inspecting")) }
    }

    @Test func aBundledSystemFontLoadsThroughTheRendererWithoutAnExternalFetch() async throws {
        let font = try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf"))
        let h = try BoardHarness(files: ["A.dc.html": """
            <html><head><script src="./support.js"></script><style>
            @font-face { font-family: Fixture; src: url('./ds/acme/fonts/Fixture.ttf'); }
            </style></head><body><x-dc><div style="font-family:Fixture">Bundled font</div></x-dc></body></html>
            """])
        let target = h.project.appendingPathComponent("ds/acme/fonts/Fixture.ttf")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try font.write(to: target)
        let view = try h.view("A.dc.html")
        try await view.load()
        _ = try await view.captureStatus()
        #expect(try await h.page(view, "return document.fonts.check('12px Fixture')") as? Bool == true)
        #expect(try await h.page(view, "return Array.from(document.fonts).some(f => f.family === 'Fixture' && f.status === 'loaded')") as? Bool == true)
    }

    @Test func interactionsExerciseImportedControlsAndReturnDiagnostics() async throws {
        let component = """
            <!doctype html><html><head><script src="./support.js"></script></head><body>
            <x-dc><div style="width:400px;height:300px">
            <button id="save" onClick="{{save}}">Save</button>
            <input id="name" onInput="{{change}}" value="{{name}}">
            <span id="state">{{count}} {{name}}</span>
            <button id="unbound" onClick="{{missing}}">Broken</button>
            <div style="overflow:hidden;width:40px;height:10px"><span style="display:block;width:80px;height:20px">Clipped</span></div>
            <div><span style="display:inline-block;width:80px;height:20px">Left</span><span style="display:inline-block;width:80px;height:20px;margin-left:-30px">Right</span></div>
            </div></x-dc>
            <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300},"label":"Team"}'>
            class Component extends DCLogic {
              renderVals() { return {
                count: this.state.count || 0, name: this.state.name || '',
                save: () => { console.log('saved'); this.setState({count:(this.state.count || 0) + 1}); },
                change: event => this.setState({name:event.target.value})
              }; }
            }
            </script></body></html>
            """
        let board = """
            <!doctype html><html><head><script src="./support.js"></script></head><body>
            <x-dc><div style="width:400px;height:300px"><dc-import name="ds/acme/Form" typo="yes"></dc-import></div></x-dc>
            </body></html>
            """
        let h = try BoardHarness(files: ["flows/Main.dc.html": board, "ds/acme/Form.dc.html": component])
        defer { try? FileManager.default.removeItem(at: h.folder) }
        let view = try h.view("flows/Main.dc.html")
        try await view.load()
        let output = try await view.captureStatus(interactions: [
            .init(action: .click, selector: "#save"), .init(action: .type, selector: "#name", text: "Research")
        ])
        let state = try await h.text(view, "return document.querySelector('#state').textContent")
        #expect(state == "1 Research")
        #expect(output.contains { $0.contains("console.log: saved") })
        #expect(output.contains { $0.contains("unknown prop typo") })
        #expect(output.contains { $0.contains("unbound handler") })
        #expect(output.contains { $0.contains("is clipped") })
        #expect(output.contains { $0.contains("overlaps sibling") })
        #expect(!output.contains { $0.hasPrefix("Still loading: import") })
        do {
            _ = try await view.captureStatus(interactions: [.init(action: .click, selector: "button")])
            Issue.record("an ambiguous selector clicked an arbitrary button")
        } catch { #expect(String(describing: error).contains("selector must match one")) }
        try await h.page(view, "for(let i=0;i<100;i++)console.log('bounded '+i); return null")
        #expect(try await view.captureStatus().count <= 64)
        do {
            _ = try await view.captureStatus(interactions: Array(repeating: .init(action: .click, selector: "#save"), count: 17))
            Issue.record("more than 16 interaction steps ran")
        } catch { #expect(String(describing: error).contains("at most 16")) }
    }
}
