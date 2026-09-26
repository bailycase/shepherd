import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// A design system's components on a board (`<x-import component-from-global-scope>`), from a
/// bundle installed in the design's `ds/<namespace>/`, against the real runtime.
@MainActor
@Suite(.mainActorExclusive)
struct DesignComponentImportTests {
    /// A bundle the way a system ships one: it puts its namespace on `window` and uses the
    /// page's React.
    static let bundle = """
        (function () {
          var h = React.createElement;
          function Button(props) {
            return h('button', { className: 'acme-button ' + (props.variant || 'plain'), onClick: props.onClick,
              'data-icon-only': props.iconOnly === true ? 'yes' : 'no', style: { color: 'var(--accent)' } }, props.children);
          }
          function TextInput(props) {
            return h('label', { className: 'acme-field' }, props.label, h('input', { defaultValue: props.defaultValue }));
          }
          function Broken() { throw new Error('broken on purpose'); }
          window.Acme = { Button: Button, Field: { TextInput: TextInput }, Broken: Broken };
        })();
        """

    static let board = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>Settings</title>
        <script src="./support.js"></script>
        <link rel="stylesheet" href="ds/acme/tokens.css">
        <script src="ds/acme/bundle.js"></script>
        </head>
        <body>
        <x-dc>
        <div id="root" style="width: 400px; height: 300px; display: flex; flex-direction: column; gap: 8px; padding: 16px">
        <x-import component-from-global-scope="Acme.Button" variant="primary" icon-only="{{yes}}" on-click="{{save}}">Save</x-import>
        <x-import component-from-global-scope="Acme.Field.TextInput" label="Team name" default-value="Research" style="width: 200px"></x-import>
        <x-import component-from-global-scope="Missing.Button">Nope</x-import>
        <x-import component-from-global-scope="React.createElement">Nope</x-import>
        <x-import component-from-global-scope="Acme.Broken"></x-import>
        <span id="count">{{count}}</span>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic {
          renderVals() { return { yes: true, count: this.state.count || 0, save: () => this.setState({ count: (this.state.count || 0) + 1 }) }; }
        }
        </script>
        </body>
        </html>
        """

    func harness() throws -> BoardHarness {
        try BoardHarness(files: [
            "Settings.dc.html": Self.board,
            "ds/acme/bundle.js": Self.bundle,
            "ds/acme/tokens.css": ":root { --accent: #4f46e5; }\n",
        ])
    }

    @Test func aComponentFromTheSystemsBundleMountsWithItsPropsAndChildren() async throws {
        let harness = try harness()
        let view = try harness.view("Settings.dc.html")
        try await view.load()

        #expect(try await harness.text(view, """
            const b = document.querySelector('button.acme-button');
            return [b.className, b.textContent, b.dataset.iconOnly, getComputedStyle(b).color].join('|');
            """) == "acme-button primary|Save|yes|rgb(79, 70, 229)")
        // Nested exports resolve; kebab-case attributes are camelCase props.
        #expect(try await harness.text(view, """
            const f = document.querySelector('label.acme-field');
            return f.textContent + '|' + f.querySelector('input').value;
            """) == "Team name|Research")
        // A handler from renderVals() runs; the board re-renders with its state.
        #expect(try await harness.text(view, """
            document.querySelector('button.acme-button').click();
            await new Promise(resolve => setTimeout(resolve, 0));
            return document.getElementById('count').textContent;
            """) == "1")
    }

    @Test func onlyABundlesGlobalsMountAndAFailingComponentLeavesTheRestDrawn() async throws {
        let harness = try harness()
        let view = try harness.view("Settings.dc.html")
        try await view.load()
        try await eventuallyOnMain("the three failures to be reported") { harness.problems.count >= 3 }
        let messages = harness.problems.map(\.message)
        #expect(messages.contains { $0.contains("no design system component Missing.Button") })
        #expect(messages.contains { $0.contains("no design system component React.createElement") },
                "a global the page had before any bundle is never a component")
        #expect(messages.contains { $0.contains("Acme.Broken") && $0.contains("broken on purpose") })
        #expect(try await harness.text(view, "return String(document.querySelectorAll('[data-dc-x-import]').length)") == "5")
        #expect(try await harness.text(view, "return document.getElementById('count').textContent") == "0")
    }

    @Test func selectionNamesTheImportForWhatItsComponentDrew() async throws {
        let harness = try harness()
        let view = try harness.view("Settings.dc.html")
        try await view.load()
        let template = try #require(DesignTemplate(board: Self.board))
        let buttonTid = try #require(template.elements.first { $0.name == "x-import" }?.tid)

        let box = try #require(try await harness.page(view, """
            const r = document.querySelector('button.acme-button').getBoundingClientRect();
            return [r.left + r.width / 2, r.top + r.height / 2];
            """) as? [Double])
        let hit = try #require(await view.hitTest(at: CGPoint(x: box[0], y: box[1])))
        #expect(hit.tid == buttonTid && hit.noun == "component" && hit.name == "Acme.Button")

        // A styled slot is the import's own box.
        let field = try #require(template.elements.filter { $0.name == "x-import" }.dropFirst().first?.tid)
        let slot = try #require(try await harness.page(view, """
            const s = document.querySelector('[data-dc-tid="\(field)"]');
            const r = s.getBoundingClientRect();
            return [s.getAttribute('data-dc-x-import'), r.width];
            """) as? [Any])
        #expect(slot.first as? String == "Acme.Field.TextInput" && slot.last as? Double == 200)
        let found = try #require(await view.element(tid: field))
        #expect(found.rect.width == 200)
    }
}
