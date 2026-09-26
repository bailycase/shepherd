import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdApp
@testable import ShepherdRemote

/// The Tweak tab's controls (DZTweak): which rows an element's style offers, how they snap to
/// the design's tokens, what they write, and the rows a board's data-props give.
@Suite("Design tweak controls")
struct DesignTweakControlTests {
    static let tokens = DesignTokens.read(css: """
    :root { --accent: #4f46e5; --slate: #475569; --success: #059669;
      --space-2: 8px; --space-4: 16px; --space-6: 24px; --space-8: 32px;
      --radius-s: 8px; --radius-m: 12px; --radius-l: 16px;
      --text-s: 12px; --text-m: 14px; --text-l: 16px; --text-xl: 20px; }
    """)

    static func style(_ attribute: String) throws -> DesignInlineStyle {
        let source = "<script src=\"./support.js\"></script><x-dc><div style=\"\(attribute)\">Checkout</div></x-dc>"
        return try #require(DesignStyleEdit.style(of: 0, in: source))
    }

    static func rows(_ groups: [DesignTweakGroup]) -> [String] {
        groups.flatMap { group in group.rows.map { "\(group.title)/\($0.label)" } }
    }

    @Test(arguments: [
        ("display: flex; gap: 16px; padding: 20px 24px; background: #fff; border-radius: 12px", DesignElementKind.shape,
         ["Layout/Direction", "Layout/Gap", "Layout/Padding", "Layout/Radius", "Color/Fill"]),
        ("display: grid; gap: 8px", .shape, ["Layout/Gap", "Layout/Padding", "Layout/Radius", "Color/Fill"]),
        ("font-size: 14px; color: #0f172a", .text, ["Layout/Padding", "Layout/Radius", "Color/Text", "Text/Text size"]),
        ("height: 30px; background: #eef2ff; border-radius: 8px", .text,
         ["Layout/Padding", "Layout/Radius", "Color/Fill", "Color/Text", "Text/Text size"]),
        ("width: 100%", .image, ["Layout/Radius"]),
        ("", .line, []),
        ("background: linear-gradient(#fff, #000)", .shape, ["Layout/Padding", "Layout/Radius"]),
        ("padding: {{ pad }}; width: {{ w }}%", .shape, ["Layout/Radius", "Color/Fill"]),
        ("{{ barStyle }}", .shape, []),
    ] as [(String, DesignElementKind, [String])])
    func anElementOffersTheControlsItsStyleAndKindAllow(_ attribute: String, _ kind: DesignElementKind, _ expected: [String]) throws {
        let groups = DesignTweakControls.styleGroups(try Self.style(attribute), kind: kind, tokens: Self.tokens)
        #expect(Self.rows(groups) == expected)
    }

    @Test func withoutColorTokensNoColorIsOffered() throws {
        let tokens = DesignTokens.read(css: ":root{--space-4:16px}")
        let groups = DesignTweakControls.styleGroups(try Self.style("background: #fff; color: #111"), kind: .text, tokens: tokens)
        #expect(!Self.rows(groups).contains { $0.hasPrefix("Color/") }, "never a free hex")
    }

    @Test func slidersAndPickersShowTheNearestTokenOfTheCurrentValue() throws {
        let groups = DesignTweakControls.styleGroups(try Self.style("display: flex; gap: 15px; padding: var(--space-6); border-radius: 12px; font-size: 16px"),
                                                     kind: .text, tokens: Self.tokens)
        let rows = Dictionary(uniqueKeysWithValues: groups.flatMap(\.rows).map { ($0.label, $0.control) })
        #expect(rows["Gap"] == .steps(values: [8, 16, 24, 32], index: 1))
        #expect(rows["Padding"] == .steps(values: [8, 16, 24, 32], index: 2))
        #expect(rows["Radius"] == .choice(options: [.init(value: "8", title: "8"), .init(value: "12", title: "12"), .init(value: "16", title: "16")],
                                          selected: "12"))
        #expect(rows["Text size"] == .choice(options: [.init(value: "14", title: "S"), .init(value: "16", title: "M"), .init(value: "20", title: "L")],
                                             selected: "16"))
        #expect(rows["Direction"] == .choice(options: [.init(value: "row", title: "Row"), .init(value: "column", title: "Column")], selected: "row"))
    }

    @Test func aTokenColorIsSelectedByNameOrValue() throws {
        for written in ["var(--accent)", "#4F46E5"] {
            let groups = DesignTweakControls.styleGroups(try Self.style("background: \(written)"), kind: .shape, tokens: Self.tokens)
            guard case .colors(let colors, let selected)? = groups.flatMap(\.rows).first(where: { $0.label == "Fill" })?.control else {
                Issue.record("no fill row for \(written)")
                continue
            }
            #expect(colors.map(\.title) == ["accent", "slate", "success"])
            #expect(selected == "--accent")
        }
    }

    @Test func withoutTokensForARoleShepherdsScaleStandsIn() throws {
        let groups = DesignTweakControls.styleGroups(try Self.style("padding: 22px"), kind: .shape, tokens: DesignTokens())
        guard case .steps(let values, let index)? = groups.first?.rows.first(where: { $0.label == "Padding" })?.control else {
            Issue.record("no padding row")
            return
        }
        #expect(values == DesignTokens.fallback[.spacing])
        #expect(values[index] == 20, "22 snaps to the nearest step, the lower on a tie")
    }

    @Test(arguments: [
        (24.0, DesignTokens.Role.spacing, ":root{--space-6:24px}", "var(--space-6)"),
        (24, .spacing, "", "24px"),
        (12, .radius, ":root{--radius-m:12px;--gap:12px}", "var(--radius-m)"),
        (0.5, .spacing, "", "0.5px"),
    ] as [(Double, DesignTokens.Role, String, String)])
    func aLengthWritesTheBoardsTokenWhenItDeclaresOne(_ px: Double, _ role: DesignTokens.Role, _ css: String, _ written: String) {
        #expect(DesignTweakControls.lengthValue(px, role: role, boardTokens: DesignTokens.read(css: css)) == written)
    }

    @Test func aColorWritesTheBoardsTokenElseTheTokensValue() {
        let accent = DesignTweakColor(title: "accent", token: "--accent", hex: "#4f46e5")
        #expect(DesignTweakControls.colorValue(accent, boardTokens: DesignTokens.read(css: ":root{--accent:#4f46e5}")) == "var(--accent)")
        #expect(DesignTweakControls.colorValue(accent, boardTokens: DesignTokens()) == "#4f46e5", "a project token the board doesn't declare")
    }

    @Test func dataPropsBecomeRowsGroupedByTheirSection() {
        let editors: [DesignPropEditor] = [
            DesignPropEditor(name: "showCounts", kind: .boolean, defaultValue: .bool(true), section: "Labels"),
            DesignPropEditor(name: "rows", kind: .int, defaultValue: .number(4), min: 1, max: 8),
            DesignPropEditor(name: "limit", kind: .int, defaultValue: .number(10)),
            DesignPropEditor(name: "density", kind: .choice, options: [.string("compact"), .string("cozy")], section: "Labels"),
            DesignPropEditor(name: "tone", kind: .choice, options: ["a", "b", "c", "d", "e"].map { .string($0) }),
            DesignPropEditor(name: "accent", kind: .color),
            DesignPropEditor(name: "stripe", kind: .color, options: [.string("#0F766E")]),
            DesignPropEditor(name: "headline", kind: .text, defaultValue: .string("Checkout")),
        ]
        let groups = DesignTweakControls.propGroups(editors, tweaks: ["rows": .number(6), "showCounts": .bool(false)], tokens: Self.tokens)
        #expect(groups.map(\.title) == ["Labels", "Board"])
        #expect(Self.rows(groups) == ["Labels/Show counts", "Labels/Density", "Board/Rows", "Board/Limit", "Board/Tone", "Board/Accent",
                                      "Board/Stripe", "Board/Headline"])
        let controls = groups.flatMap(\.rows).map(\.control)
        #expect(controls[0] == .toggle(false), "the tweak, not the default")
        #expect(controls[2] == .slider(value: 6, min: 1, max: 8, step: 1))
        #expect(controls[3] == .stepper(10))
        if case .menu(let options, _) = controls[4] { #expect(options.count == 5) } else { Issue.record("more than four options is a menu") }
        if case .colors(let colors, _) = controls[5] { #expect(colors.map(\.title) == ["accent", "slate", "success"]) } else { Issue.record("token colors") }
        if case .colors(let colors, _) = controls[6] { #expect(colors.map(\.hex) == ["#0f766e"]) } else { Issue.record("the prop's own swatches") }
        #expect(controls[7] == .text("Checkout"))
    }

    @Test(arguments: [("showCounts", "Show counts"), ("drop_off", "Drop off"), ("title", "Title"), ("barURL", "Bar url"), ("rows-per-page", "Rows per page")])
    func aPropsNameReadsAsALabel(_ name: String, _ label: String) {
        #expect(DesignTweakControls.label(name) == label)
    }

    @Test func theScopesNoteNamesWhatEveryReaches() {
        #expect(DesignTweakControls.scopeNote(name: "funnel card", boards: ["A · Funnel first", "A · phone"], system: "acme-web", fromTokens: true)
                == "Every funnel card: A · Funnel first and A · phone. Values snap to acme-web tokens.")
        #expect(DesignTweakControls.list(["A", "B", "C"]) == "A, B and C")
    }
}
