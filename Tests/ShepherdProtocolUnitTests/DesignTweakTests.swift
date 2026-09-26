import Foundation
import Testing
import ShepherdProtocol

/// Tweak's edits to a board's source (docs/designs.md › Tweak): inline-style splices at the
/// parser's offsets, token snapping, and data-props values in canvas.json.
@Suite("Design style edits")
struct DesignStyleEditTests {
    static func board(_ attributes: String, tag: String = "div") -> String {
        """
        <!doctype html><html><head><script src="./support.js"></script></head><body><x-dc>
        <\(tag)\(attributes)><span>Checkout funnel</span></\(tag)>
        </x-dc></body></html>
        """
    }

    @Test(arguments: [
        (#" style="padding: 20px 24px; color: #111""#, ["padding": "24px"], #" style="padding: 24px; color: #111""#),
        (#" style="background: #fff; ""#, ["padding": "24px"], #" style="background: #fff; padding: 24px; ""#),
        (#" style="background: #fff""#, ["padding": "24px"], #" style="background: #fff; padding: 24px""#),
        (#" style="""#, ["padding": "24px"], #" style="padding: 24px""#),
        (#" class="card""#, ["padding": "24px"], #" style="padding: 24px" class="card""#),
        (#" style="padding: 4px !important""#, ["padding": "24px"], #" style="padding: 24px !important""#),
        (#" style='padding: 4px'"#, ["padding": "var(--space-6)"], #" style='padding: var(--space-6)'"#),
        (#" style=padding:4px"#, ["padding": "24px"], #" style="padding:24px""#),
        (#" style="font-family: &quot;Geist&quot;; padding: 2px""#, ["padding": "8px"], #" style="font-family: &quot;Geist&quot;; padding: 8px""#),
        (#" style="width: {{ pct }}%""#, ["padding": "8px"], #" style="width: {{ pct }}%; padding: 8px""#),
        (#" style="background: url(a;b.png); padding: 2px""#, ["padding": "8px"], #" style="background: url(a;b.png); padding: 8px""#),
    ] as [(String, [String: String], String)])
    func aValueIsSplicedIntoTheStyleAsWritten(_ before: String, _ changes: [String: String], _ after: String) throws {
        let source = Self.board(before)
        let edited = try DesignStyleEdit.apply(changes.mapValues { Optional($0) }, to: 0, in: source)
        #expect(edited == Self.board(after))
    }

    @Test(arguments: [
        (#" style="padding: 4px; color: red""#, "padding", #" style="color: red""#),
        (#" style="padding: 4px; color: red""#, "color", #" style="padding: 4px""#),
        (#" style="padding: 1px; padding: 2px""#, "padding", #" style="""#),
        (#" style="color: red; padding: 1px; gap: 2px""#, "padding", #" style="color: red; gap: 2px""#),
        (#" class="card""#, "padding", #" class="card""#),
    ])
    func removingADeclarationTakesOutOnlyIt(_ before: String, _ property: String, _ after: String) throws {
        let edited = try DesignStyleEdit.apply([property: nil], to: 0, in: Self.board(before))
        #expect(edited == Self.board(after))
    }

    @Test func settingOneValueAndRemovingAnotherAtOnceKeepsBothEdits() throws {
        let edited = try DesignStyleEdit.apply(["gap": "8px", "color": nil], to: 0,
                                               in: Self.board(#" style="padding: 4px; color: red""#))
        #expect(edited == Self.board(#" style="padding: 4px; gap: 8px""#))
    }

    @Test(arguments: [
        (#" style="width: {{ pct }}%""#, "width", DesignStyleEdit.Problem.bound("width")),
        (#" style="{{ barStyle }}""#, "padding", .bound("style")),
    ])
    func whatTheBoardsLogicSetsIsNotSpliced(_ attributes: String, _ property: String, _ problem: DesignStyleEdit.Problem) {
        #expect(throws: problem) { try DesignStyleEdit.apply([property: "8px"], to: 0, in: Self.board(attributes)) }
    }

    @Test(arguments: ["24px; color: red", "\"x\"", "url(<b>)", "a}b", #"a\b"#, ""])
    func aValueATweakNeverWritesIsRefused(_ value: String) {
        #expect(throws: DesignStyleEdit.Problem.unsafe(value)) {
            try DesignStyleEdit.apply(["padding": value], to: 0, in: Self.board(#" style="padding: 2px""#))
        }
    }

    @Test(arguments: ["dc-import", "sc-if"])
    func anElementThatTakesNoStyleIsRefused(_ tag: String) {
        #expect(throws: DesignStyleEdit.Problem.notStyled(0)) {
            try DesignStyleEdit.apply(["padding": "8px"], to: 0, in: Self.board(#" name="Card""#, tag: tag))
        }
    }

    @Test func everyElementOfANameIsFoundByItsDataEl() {
        let source = """
        <script src="./support.js"></script><x-dc><div data-el="funnel card" style="padding: 4px"></div>\
        <div><span data-el="funnel card"></span><span data-el="other"></span></div></x-dc>
        """
        #expect(DesignStyleEdit.elements(named: "funnel card", in: source) == [0, 2])
        #expect(DesignStyleEdit.attribute("data-el", of: 3, in: source) == "other")
        #expect(DesignStyleEdit.style(of: 0, in: source)?.value("padding") == "4px")
        #expect(DesignStyleEdit.style(of: 1, in: source) == .empty)
    }

    // MARK: Real boards

    static let designs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Designs")

    /// Every board in `Tests/Designs/boards`: three from Shepherd's own canvas and two synthetic.
    static let fixtureBoards = ["DZStart.dc.html", "NWDesignTool.dc.html", "ThreadRichContent.dc.html", "Edges.dc.html", "Minimal.dc.html"]

    /// Every styled element of a real board takes a new padding (set where it has one, added
    /// where not) in one splice: only the style attributes change, every element keeps its tid
    /// and path, every other declaration is kept as written, and the board still passes its
    /// write checks.
    @Test(arguments: fixtureBoards)
    func aSpliceOnEveryElementOfARealBoardRoundTrips(_ name: String) throws {
        let source = try String(contentsOf: Self.designs.appendingPathComponent("boards/\(name)"), encoding: .utf8)
        try Self.checkRoundTrip(source, name: name)
    }

    /// The same over a whole local canvas (opt-in: `SHEPHERD_DESIGN_CANVAS`, a design folder
    /// holding `project/`, or the project folder itself).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_DESIGN_CANVAS"] != nil, "set SHEPHERD_DESIGN_CANVAS"))
    func aSpliceOnEveryElementOfEveryBoardOfALocalCanvasRoundTrips() throws {
        var folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHEPHERD_DESIGN_CANVAS"] ?? "", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("project").path) { folder.appendPathComponent("project") }
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".dc.html") }.sorted()
        #expect(!names.isEmpty)
        for name in names {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            try Self.checkRoundTrip(source, name: name)
        }
    }

    static func checkRoundTrip(_ source: String, name: String) throws {
        let before = try #require(DesignTemplate(board: source), "\(name)")
        let styles = DesignStyleEdit.styles(in: source)
        let editable = styles.filter { !$0.value.isBoundWhole && $0.value.declaration("padding")?.isBound != true }
        #expect(!editable.isEmpty, "\(name) has styled elements")
        let edited = try DesignStyleEdit.apply(editable.mapValues { _ in ["padding": "24px"] }, in: source)
        let after = try #require(DesignTemplate(board: edited), "\(name)")
        #expect(after.elements.map(\.name) == before.elements.map(\.name), "\(name): the same elements")
        #expect(after.elements.map(\.path) == before.elements.map(\.path), "\(name): the same paths")
        // Outside the start tags, nothing moved.
        #expect(outsideTags(source, before) == outsideTags(edited, after), "\(name): only start tags changed")
        let now = DesignStyleEdit.styles(in: edited)
        for (tid, style) in editable {
            let kept = style.declarations.filter { $0.property != "padding" }.map { [$0.property, $0.value] }
            let edits = try #require(now[tid])
            #expect(edits.declarations.filter { $0.property != "padding" }.map { [$0.property, $0.value] } == kept, "\(name) #\(tid)")
            #expect(edits.value("padding") == "24px", "\(name) #\(tid)")
        }
        if (try? DesignBoardCheck.check(source)) != nil {
            #expect(throws: Never.self, "\(name) still passes its checks") { try DesignBoardCheck.check(edited) }
        }
    }

    /// The text between the template's start tags.
    static func outsideTags(_ source: String, _ template: DesignTemplate) -> [String] {
        let bytes = Array(source.utf8)
        var parts: [String] = []
        var at = 0
        for range in template.elements.compactMap(\.tagRange).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            parts.append(String(decoding: bytes[at..<range.lowerBound], as: UTF8.self))
            at = range.upperBound
        }
        parts.append(String(decoding: bytes[at...], as: UTF8.self))
        return parts
    }
}

@Suite("Design tokens")
struct DesignTokensTests {
    static let css = """
    :root {
      --accent: #4F46E5; --slate: #475569; --success: #059669; --overlay: #00000080;
      --space-2: 8px; --space-4: 16px; --space-6: 24px; --gap-l: 1.5rem;
      --radius-s: 8px; --radius-m: 12px; --radius-l: 16px;
      --text-s: 12px; --text-m: 14px; --text-l: 16px;
      --shadow: 0 1px 2px #000;
    }
    """

    @Test func customPropertiesBecomeColorAndLengthTokens() {
        let tokens = DesignTokens.read(css: Self.css)
        #expect(tokens.colors.map(\.name) == ["--accent", "--slate", "--success", "--overlay"])
        #expect(tokens.colors.first?.hex == "#4f46e5")
        #expect(tokens.colors.first?.title == "accent")
        #expect(tokens.scale(.spacing) == [8, 16, 24])
        #expect(tokens.scale(.radius) == [8, 12, 16])
        #expect(tokens.scale(.text) == [12, 14, 16])
        #expect(!tokens.declares("--shadow"))
    }

    @Test func aBoardsOwnStyleBlocksDeclareTokens() {
        let board = "<head><style>:root{--accent:#0f766e}</style></head><x-dc><helmet><style>:root{--pad-m: 12px}</style></helmet></x-dc>"
        let tokens = DesignTokens.read(board: board)
        #expect(tokens.colors == [.init(name: "--accent", hex: "#0f766e")])
        #expect(tokens.scale(.spacing) == [12])
        let merged = tokens.merged(with: DesignTokens.read(css: Self.css))
        #expect(merged.colors.first?.hex == "#0f766e", "the board's own token wins")
        #expect(merged.colors.count == 4)
    }

    @Test(arguments: [
        (23.0, [8.0, 16, 24], 24.0), (20, [8, 16, 24], 16), (0, [8, 16, 24], 8), (100, [8, 16, 24], 24), (5, [], 5),
    ] as [(Double, [Double], Double)])
    func aValueSnapsToTheNearestTokenTheLowerOnATie(_ value: Double, _ scale: [Double], _ snapped: Double) {
        #expect(DesignTokens.snap(value, to: scale) == snapped)
    }

    @Test func withoutTokensForARoleShepherdsScaleStandsIn() {
        let tokens = DesignTokens.read(css: ":root{--accent:#4f46e5}")
        let spacing = tokens.scaleOrFallback(.spacing)
        #expect(!spacing.fromTokens && spacing.values.contains(24))
        #expect(DesignTokens.read(css: Self.css).scaleOrFallback(.radius) == ([8, 12, 16], true))
    }

    @Test(arguments: [
        ("var(--accent)", "--accent"), ("#4f46e5", "--accent"), ("#4F46E5FF", "--accent"), ("var(--slate, #000)", "--slate"),
        ("#123456", nil), ("red", nil),
    ] as [(String, String?)])
    func aWrittenColorIsTheTokenItNames(_ written: String, _ token: String?) {
        #expect(DesignTokens.read(css: Self.css).color(written)?.name == token)
    }

    @Test(arguments: [
        ("24px", 24.0), ("1.5rem", 24), ("0", 0), ("var(--space-4)", 16), ("var(--nope)", nil), ("auto", nil),
    ] as [(String, Double?)])
    func aWrittenLengthReadsAsPixels(_ written: String, _ px: Double?) {
        #expect(DesignTokens.read(css: Self.css).px(written) == px)
    }

    @Test(arguments: [
        ("#ABC", "#aabbcc"), ("#aabbccff", "#aabbcc"), ("#aabbcc80", "#aabbcc80"), ("#abcd", "#aabbccdd"), ("abc", nil), ("#ggg", nil),
    ] as [(String, String?)])
    func hexIsNormalized(_ raw: String, _ hex: String?) {
        #expect(DesignTokens.normalizedHex(raw) == hex)
    }
}

@Suite("Design props")
struct DesignPropsTests {
    static let board = """
    <!doctype html><html><head><script src="./support.js"></script></head><body><x-dc><div>{{ title }}</div></x-dc>
    <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":1280,"height":800},
      "title":{"editor":"text","default":"Tom &amp; Jerry&#39;s"},
      "density":{"editor":"enum","options":["compact","cozy"],"default":"cozy","section":"Layout"},
      "rows":{"editor":"int","min":1,"max":8,"default":4},
      "onPick":{"editor":null},
      "accent":{"editor":"color","options":["#4f46e5","#0f766e"]},
      "counts":{"editor":"boolean","default":true},
      "scale":{"editor":"range","min":0,"max":1,"step":0.1,"default":0.5}}'>
    class Component extends DCLogic {}
    </script></body></html>
    """

    @Test func editorsComeInTheOrderDataPropsWritesThem() {
        let editors = DesignProps.editors(in: Self.board)
        #expect(editors.map(\.name) == ["title", "density", "rows", "accent", "counts", "scale"])
        #expect(editors.first?.defaultValue == .string("Tom & Jerry's"), "character references decode first")
        #expect(editors[1].kind == .choice && editors[1].section == "Layout" && editors[1].options.count == 2)
        #expect(editors[2].min == 1 && editors[2].max == 8)
    }

    @Test func aBoardWithoutDataPropsOffersNothing() {
        #expect(DesignProps.editors(in: "<script src=\"./support.js\"></script><x-dc><div></div></x-dc>").isEmpty)
    }

    @Test(arguments: [
        ("rows", JSONValue.number(9), JSONValue?.some(.number(8))),
        ("rows", .number(2.6), .number(3)),
        ("scale", .number(0.33), .number(0.3)),
        ("density", .string("spacious"), nil),
        ("density", .string("compact"), .string("compact")),
        ("accent", .string("#0F766E"), .string("#0f766e")),
        ("accent", .string("#123456"), nil),
        ("accent", .string("#475569"), .string("#475569")),
        ("counts", .string("yes"), nil),
        ("title", .string("Hi"), .string("Hi")),
    ])
    func aValueIsAcceptedOnlyAsItsEditorAllows(_ name: String, _ value: JSONValue, _ accepted: JSONValue?) throws {
        let editor = try #require(DesignProps.editors(in: Self.board).first { $0.name == name })
        #expect(editor.accepting(value, colors: ["#475569"]) == accepted)
    }

    @Test func tweakValuesLiveInCanvasJSONUnderTweaks() throws {
        let path = try #require(DesignPath("A.dc.html"))
        var index = DesignIndex(title: "Checkout", extra: ["attachments": .array([])])
        index = try index.merging(DesignIndex.tweakPatch(path, ["rows": .number(6), "counts": .bool(false)]))
        #expect(index.tweaks(for: path) == ["rows": .number(6), "counts": .bool(false)])
        #expect(index.extra["attachments"] == .array([]), "every other key is kept")
        index = try index.merging(DesignIndex.tweakPatch(path, ["rows": nil]))
        #expect(index.tweaks(for: path) == ["counts": .bool(false)], "nil puts a prop back to its default")
        let decoded = try DesignIndex.decode(index.encoded())
        #expect(decoded.tweaks(for: path) == ["counts": .bool(false)])
        let editor = try #require(DesignProps.editors(in: DesignPropsTests.board).first { $0.name == "counts" })
        #expect(DesignProps.value(of: editor, tweaks: decoded.tweaks(for: path)) == .bool(false))
        let rows = try #require(DesignProps.editors(in: DesignPropsTests.board).first { $0.name == "rows" })
        #expect(DesignProps.value(of: rows, tweaks: decoded.tweaks(for: path)) == .number(4))
    }
}
