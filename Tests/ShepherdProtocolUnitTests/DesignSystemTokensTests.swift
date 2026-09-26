import Foundation
import Testing
import ShepherdProtocol

/// A design system's tokens.json in both shapes, the stylesheet reader behind "--accent #4f46e5 ·
/// tokens.css:8", what a system may hold, and a Re-sync's changes.
@Suite("Design system tokens")
struct DesignSystemTokensTests {
    static let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Designs")

    static func decode(_ json: String) throws -> DesignSystemTokens {
        try DesignSystemTokens.decode(Data(json.utf8))
    }

    // MARK: Decoding

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var json: String
        var shape: DesignSystemTokens.Shape
        var counts: DesignSystemCounts
        /// The first color as "name value dark source".
        var firstColor: String?
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "Shepherd's schema", json: """
            {"format": "shepherd-tokens/1", "name": "acme-web", "namespace": "acme-web",
             "colors": [{"name": "--accent", "value": "#4f46e5", "source": {"file": "web/static/tokens.css", "line": 8}},
                        {"name": "--bg", "value": "#f8fafc", "dark": "#0b1020", "source": "web/static/tokens.css:4"}],
             "type": [{"name": "display", "size": 26, "weight": 700, "sample": "Checkout funnel"}],
             "spacing": [{"name": "--space-4", "px": 16}], "radii": [{"name": "--radius-md", "px": 8}],
             "components": [{"name": "Button", "source": {"file": "templates/partials/button.html"}}]}
            """, shape: .shepherd, counts: DesignSystemCounts(colors: 2, type: 1, lengths: 2, components: 1),
             firstColor: "--accent #4f46e5 - tokens.css:8"),
        Case(name: "no format key reads as Shepherd's", json: ##"{"colors": [{"name": "ink", "value": "rgb(12, 12, 20)"}]}"##,
             shape: .shepherd, counts: DesignSystemCounts(colors: 1), firstColor: "ink rgb(12, 12, 20) - -"),
        Case(name: "a canvas's own light and dark maps", json: """
            {"name": "Shepherd", "fonts": {"sans": {"family": "IBM Plex Sans", "fallback": "system-ui"}},
             "type": {"title": {"font": "sans", "size": 15, "weight": 600, "lineHeight": 1.4}},
             "color": {"light": {"accent": "#2c57b8", "shadow.thumb": "0 1px 2px rgba(0,0,0,0.1)"}, "dark": {"accent": "#6f95e6"}},
             "space": {"1": 2, "2": 4}, "radius": {"sm": 6}, "motion": {"hover": "120ms"}}
            """, shape: .canvas, counts: DesignSystemCounts(colors: 1, type: 1, lengths: 3), firstColor: "accent #2c57b8 #6f95e6 -"),
        Case(name: "empty", json: "{}", shape: .shepherd, counts: DesignSystemCounts(), firstColor: nil),
    ]

    @Test(arguments: cases)
    func readsEitherShape(_ c: Case) throws {
        let tokens = try Self.decode(c.json)
        #expect(tokens.shape == c.shape)
        #expect(tokens.counts == c.counts)
        let first = tokens.colors.first.map { [$0.name, $0.value, $0.dark ?? "-", $0.source?.label ?? "-"].joined(separator: " ") }
        #expect(first == c.firstColor)
    }

    @Test(arguments: [
        "[]",
        "not json",
        ##"{"colors": {"accent": "#fff"}}"##,
        ##"{"colors": [{"name": "accent"}]}"##,
        ##"{"type": [{"name": "body"}]}"##,
        ##"{"spacing": [{"name": "--space-1", "px": "4px"}]}"##,
        ##"{"components": [{"source": "a.html"}]}"##,
        ##"{"type": {"body": {"font": "sans"}}, "color": {"light": {}}}"##,
    ])
    func somethingHalfReadIsUnreadable(_ json: String) {
        #expect(throws: DesignSystemTokensError.self) { try Self.decode(json) }
    }

    @Test func theCanvasTokensFileReadsWhole() throws {
        let tokens = try DesignSystemTokens.decode(Data(contentsOf: Self.designs.appendingPathComponent("tokens.json")))
        #expect(tokens.shape == .canvas && tokens.name == "Shepherd" && tokens.version == "1.0.0")
        // Every light color but the two shadows, each with its dark value.
        #expect(tokens.colors.count == 31)
        #expect(tokens.colors.allSatisfy { $0.dark != nil })
        #expect(tokens.colors.first { $0.name == "accent" }.map { "\($0.value) \($0.dark ?? "")" } == "#2c57b8 #6f95e6")
        #expect(tokens.type.count == 10 && tokens.type.first { $0.name == "code" }?.family == "JetBrains Mono")
        #expect(tokens.spacing.count == 12 && tokens.radii.count == 6)
        #expect(tokens.radii.map(\.name).first == "radius.xs")
        #expect(tokens.fonts.map(\.name) == ["mono", "sans"])
        // What isn't a color or a step stays in the file's own words.
        #expect(tokens.extra["size"] != nil && tokens.extra["motion"] != nil)
        #expect(tokens.extra["color"] != nil, "the shadows keep the color map")
    }

    @Test func shepherdsSchemaRoundTripsWithEveryKeyItDoesntName() throws {
        let json = """
            {"format": "shepherd-tokens/1", "name": "acme-web", "brand": {"voice": "plain"},
             "colors": [{"name": "--accent", "value": "#4f46e5", "role": "brand", "source": {"file": "tokens.css", "line": 8}}],
             "type": [{"name": "display", "size": 26, "weight": 700, "lineHeight": 1.2, "tracking": -0.01}],
             "spacing": [{"name": "--space-4", "px": 16, "note": "gutter"}], "radii": [], "fonts": [], "components": []}
            """
        let tokens = try Self.decode(json)
        #expect(tokens.extra["brand"] == .object(["voice": .string("plain")]))
        #expect(tokens.colors[0].extra["role"] == .string("brand"))
        #expect(tokens.spacing[0].extra["note"] == .string("gutter"))
        let again = try DesignSystemTokens.decode(tokens.encoded())
        #expect(again == tokens)
        #expect(try JSONDecoder().decode(JSONValue.self, from: tokens.encoded()) == JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
    }

    // MARK: Rules

    @Test(arguments: [
        (##"{"colors": [{"name": "--accent", "value": "red; } body { background: url(x)"}]}"##, "is not a color"),
        (##"{"colors": [{"name": "--a{b", "value": "#fff"}]}"##, "can't name a token"),
        (##"{"colors": [{"name": "--ink", "value": "#fff", "dark": "url(https://x)"}]}"##, "is not a color"),
        (##"{"type": [{"name": "body", "size": 0}]}"##, "a size of 1–400"),
        (##"{"fonts": [{"name": "sans", "family": "Inter; } :root { x: y"}]}"##, "holds ;"),
        (##"{"components": [{"name": "Button", "specimen": "../escape.html"}]}"##, "not a file of the system"),
        (##"{"components": [{"name": "Button", "export": "Acme.__proto__.x"}]}"##, "is Ns.Component"),
        (##"{"namespace": "Acme Web"}"##, "namespace"),
    ])
    func whatCouldBreakOutOfTheStylesheetIsAProblem(_ json: String, _ problem: String) throws {
        let problems = try Self.decode(json).problems()
        #expect(problems.contains { $0.contains(problem) }, "\(problems)")
    }

    @Test(arguments: ["#4f46e5", "#FFF", "#0000000a", "rgb(79 70 229 / 0.5)", "rgba(0,0,0,0.1)", "oklch(62% 0.2 270)", "transparent"])
    func colorsATokenMayHold(_ value: String) {
        #expect(DesignSystemCSS.isColor(value))
    }

    @Test(arguments: ["", "#12", "var(--accent)", "url(x)", "rgb(1,2,3); color: red", "expression(alert(1))", "0 1px 3px rgba(0,0,0,0.06)"])
    func notColors(_ value: String) {
        #expect(!DesignSystemCSS.isColor(value))
    }

    @Test(arguments: [
        ("tokens.css", true), ("components/Button.html", true), ("api/components/Button.md", true), ("bundle.js", true),
        ("system.json", false), ("../x.css", false), ("/abs.css", false), ("a\\b.css", false), ("fonts/Inter.woff2", false),
        (".hidden.css", false), ("noextension", false),
    ])
    func filesASystemHolds(_ path: String, _ ok: Bool) {
        #expect(DesignSystemFile.isPath(path) == ok)
    }

    @Test func theStylesheetItGeneratesHoldsEveryTokenAndTheDarkVariant() throws {
        let tokens = DesignSystemTokens(
            name: "acme", colors: [.init(name: "--accent", value: "#4f46e5", dark: "#818cf8"), .init(name: "bg.canvas", value: "#f8fafc")],
            type: [.init(name: "body", size: 14, weight: 400, lineHeight: 1.5)],
            spacing: [.init(name: "--space-4", px: 16)], radii: [.init(name: "radius.md", px: 8)],
            fonts: [.init(name: "sans", family: "IBM Plex Sans", fallback: "system-ui")])
        #expect(tokens.css() == """
            /* Generated by Shepherd from tokens.json (acme). */
            :root {
              --accent: #4f46e5;
              --bg-canvas: #f8fafc;
              --space-4: 16px;
              --radius-md: 8px;
              --font-sans: "IBM Plex Sans", system-ui;
              --text-body-size: 14px;
              --text-body-weight: 400;
              --text-body-line-height: 1.5;
            }
            [data-theme="dark"] {
              --accent: #818cf8;
            }

            """)
        #expect(tokens.designTokens.colors.map(\.name) == ["--accent", "--bg-canvas"])
        #expect(tokens.designTokens.scale(.spacing) == [16] && tokens.designTokens.scale(.radius) == [8])
        #expect(tokens.designTokens.scale(.text) == [14])
    }

    // MARK: Reading stylesheets

    static let stylesheet = """
        /* acme-web tokens
           --not-a-token: #000; */
        :root {
          --bg: #f8fafc;
          --surface: #ffffff;
          --border: #e2e8f0;

          --accent: #4f46e5;
          --accent-soft: #eef2ff !important;
          --shadow: 0 1px 2px rgba(0, 0, 0, 0.1), 0 0 0 1px var(--border);
          --space-4: 1rem; --radius-md: 8px;
        }
        .card { color: var(--accent); padding: 16px; }
        @media (prefers-color-scheme: dark) { :root { --bg: #0b1020; } }
        """

    @Test func theReaderNamesEachCustomPropertyWithItsFileAndLine() {
        let found = DesignSystemCSS.declarations(Self.stylesheet, file: "web/static/tokens.css")
        #expect(found.map(\.label) == [
            "--bg #f8fafc · tokens.css:4",
            "--surface #ffffff · tokens.css:5",
            "--border #e2e8f0 · tokens.css:6",
            "--accent #4f46e5 · tokens.css:8",
            "--accent-soft #eef2ff · tokens.css:9",
            "--shadow 0 1px 2px rgba(0, 0, 0, 0.1), 0 0 0 1px var(--border) · tokens.css:10",
            "--space-4 1rem · tokens.css:11",
            "--radius-md 8px · tokens.css:11",
            "--bg #0b1020 · tokens.css:14",
        ])
        #expect(found.allSatisfy { $0.file == "web/static/tokens.css" })
    }

    @Test(arguments: [
        ("a { color: var(--x); }", 0),
        ("--loose: 1px", 1),
        (":root{--a:#fff;--b:#000}", 2),
        (":root { --a:\n  #fff; }", 1),
        ("/* --a: #fff; */", 0),
    ])
    func onlyDeclarationsCount(_ css: String, _ count: Int) {
        #expect(DesignSystemCSS.declarations(css, file: "x.css").count == count)
    }

    // MARK: Re-sync

    @Test func aResyncTakesTheStylesheetsValuesAndLines() throws {
        let tokens = DesignSystemTokens(
            name: "acme-web",
            colors: [
                .init(name: "--accent", value: "#4338ca", source: .init(file: "web/tokens.css", line: 3)),
                .init(name: "--gone", value: "#000000", source: .init(file: "web/tokens.css", line: 9)),
                .init(name: "--brand", value: "#ff0000"),
                .init(name: "--elsewhere", value: "#00ff00", source: .init(file: "web/missing.css", line: 1)),
            ],
            spacing: [.init(name: "--space-4", px: 12, source: .init(file: "web/tokens.css", line: 5))])
        let css = ":root {\n  --bg: #f8fafc;\n\n  --accent: #4f46e5;\n  --space-4: 16px;\n  --radius-md: 8px;\n  --text-lg: 18px;\n}\n"
        let (next, changes) = tokens.resynced(from: [
            "web/tokens.css": DesignSystemCSS.declarations(css, file: "web/tokens.css"),
            "web/missing.css": nil,
        ])
        #expect(changes.updated == ["--accent", "--space-4"])
        #expect(changes.removed == ["--gone"])
        #expect(changes.added == ["--bg", "--radius-md"], "a text size is the author's to name, not a step")
        #expect(changes.missingFiles == ["web/missing.css"])
        #expect(next.colors.map { "\($0.name) \($0.value) \($0.source?.label ?? "-")" } == [
            "--accent #4f46e5 tokens.css:4", "--brand #ff0000 -", "--elsewhere #00ff00 missing.css:1", "--bg #f8fafc tokens.css:2",
        ])
        #expect(next.spacing.map(\.px) == [16] && next.radii.map(\.name) == ["--radius-md"])

        let (same, none) = next.resynced(from: ["web/tokens.css": DesignSystemCSS.declarations(css, file: "web/tokens.css")])
        #expect(none.isEmpty && same == next)
    }
}
