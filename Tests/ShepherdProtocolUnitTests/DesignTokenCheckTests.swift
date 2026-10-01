import Foundation
import Testing
@testable import ShepherdProtocol

/// Token enforcement on a write: the values a board holds that the design's systems don't, found as
/// `design_check` finds them, narrowed to what one write introduced, and snapped on request.
@Suite("Design token enforcement")
struct DesignTokenCheckTests {
    static let tokens = DesignTokenSet(
        colors: [.init(name: "--accent", hex: "#3056d3"), .init(name: "--ink", hex: "#1c2330"), .init(name: "--ground", hex: "#f7f6f2"),
                 .init(name: "--ink", hex: "#e8ecf4", dark: true)],
        lengths: [.init(name: "--space-2", px: 8, role: .spacing), .init(name: "--space-3", px: 12, role: .spacing),
                  .init(name: "--space-4", px: 16, role: .spacing), .init(name: "--radius-md", px: 8, role: .radius),
                  .init(name: "--text-body-size", px: 14, role: .text), .init(name: "--text-title-size", px: 20, role: .text)],
        source: "acme")

    /// A style attribute per line, so a line is one element.
    static func lines(_ styles: [String]) -> String {
        styles.map { #"<div style="\#($0)"></div>"# }.joined(separator: "\n")
    }

    @Test func aColorOrSizeTheTokensDontHoldIsOffSystem() {
        let found = DesignTokenCheck.occurrences(in: Self.lines([
            "color: #3056d3; padding: 12px",        // on-system
            "color: #3a56d4; padding: 13px",        // off
            "background: #E8ECF4; gap: 1px",        // a dark value is on-system; 1px is never checked
            "border-radius: 9px; font-size: 15px",
        ]), tokens: Self.tokens)
        #expect(found.map(\.value) == ["#3a56d4", "13px", "9px", "15px"])
        #expect(found.map(\.line) == [2, 2, 4, 4])
        #expect(found.allSatisfy { $0.inCSS })
    }

    @Test func whereDesignCheckLooksIsWhereTheCheckLooks() {
        let source = """
        <helmet><style>.a { color: #aa0000; margin: 7px }</style></helmet>
        <svg><path fill="#00aa00" stroke="#3056d3"/></svg>
        <div data-x="#bb0000" style="color: #0000aa"></div>
        <script type="text/x-dc" data-dc-script data-props='{"accent":{"default":"#cc0000"}}'>
        const c = { tone: "#dd0000", padding: "5px" };
        </script>
        """
        let found = DesignTokenCheck.occurrences(in: source, tokens: Self.tokens)
        #expect(found.map(\.value).sorted() == ["#00aa00", "#0000aa", "#aa0000", "#cc0000", "#dd0000", "7px"].sorted())
        #expect(found.first { $0.value == "#00aa00" }?.inCSS == false, "an SVG attribute is not CSS")
        #expect(found.first { $0.value == "#cc0000" }?.inCSS == false, "data-props is not CSS")
        #expect(found.first { $0.value == "#aa0000" }?.inCSS == true)
    }

    @Test func aSizeWithAHoleOrNoTokenLengthsIsNotChecked() {
        #expect(DesignTokenCheck.occurrences(in: Self.lines(["padding: {{ gap }}px"]), tokens: Self.tokens).isEmpty)
        let colorsOnly = DesignTokenSet(colors: Self.tokens.colors, lengths: [], source: "acme")
        let found = DesignTokenCheck.occurrences(in: Self.lines(["padding: 13px; color: #123456"]), tokens: colorsOnly)
        #expect(found.map(\.value) == ["#123456"])
    }

    @Test func aWriteIntroducesOnlyTheValuesOnTheLinesItAdded() {
        let old = Self.lines(["color: #3a56d4", "padding: 13px", "color: #3056d3"])
        let new = Self.lines(["color: #3a56d4", "padding: 13px", "color: #3056d3", "color: #112233; padding: 9px"])
        let found = DesignTokenCheck.enforce(.warn, tokens: Self.tokens, old: old, new: new)
        #expect(found.remaining.map(\.value) == ["#112233", "9px"], "the old #3a56d4 and 13px are not this write's")
        #expect(found.source == new && found.replacements.isEmpty)
    }

    @Test func aLineTheWriteTouchedKeepsTheValuesItAlreadyHad() {
        let old = Self.lines(["color: #3a56d4; padding: 13px"])
        let new = Self.lines(["color: #3a56d4; padding: 13px; margin: 24px"])
        let found = DesignTokenCheck.enforce(.warn, tokens: Self.tokens, old: old, new: new)
        #expect(found.remaining.map(\.value) == ["24px"], "the changed line's #3a56d4 and 13px were already there")
    }

    @Test func aNewBoardIntroducesEverythingItHolds() {
        let found = DesignTokenCheck.enforce(.warn, tokens: Self.tokens, old: nil, new: Self.lines(["color: #3a56d4", "color: #3a56d4; gap: 13px"]))
        #expect(found.remaining == [
            DesignTokenFinding(value: "#3a56d4", count: 2, lines: [1, 2], nearest: "--accent #3056d3"),
            DesignTokenFinding(value: "13px", count: 1, lines: [2], nearest: "--space-3 12px"),
        ])
    }

    @Test func snapReplacesEachIntroducedValueWithTheNearestTokenOfItsRole() {
        let new = Self.lines([
            "color: #3a56d4; padding: 13px 24px",
            "border-radius: 9px; font-size: 15px; background: #f6f6f1",
        ])
        let found = DesignTokenCheck.enforce(.snap, tokens: Self.tokens, old: nil, new: new)
        #expect(found.source == Self.lines([
            "color: var(--accent); padding: var(--space-3) var(--space-4)",
            "border-radius: var(--radius-md); font-size: var(--text-body-size); background: var(--ground)",
        ]))
        #expect(found.remaining.isEmpty)
        #expect(found.replacements.map(\.from) == ["#3a56d4", "13px", "24px", "9px", "15px", "#f6f6f1"])
        #expect(found.replacements.map(\.to) == ["var(--accent)", "var(--space-3)", "var(--space-4)", "var(--radius-md)",
                                                 "var(--text-body-size)", "var(--ground)"])
        #expect(found.replacements.first?.token == "#3056d3" && found.replacements.first?.line == 1)
    }

    @Test func snapLeavesWhatItCannotSnapAndSaysSo() {
        let new = """
        <svg><path fill="#00aa00"/></svg>
        <div style="color: #11223388; margin: -13px; letter-spacing: 3px"></div>
        """
        let found = DesignTokenCheck.enforce(.snap, tokens: Self.tokens, old: nil, new: new)
        #expect(found.source == new, "outside CSS, with transparency, a negative size and letter-spacing stay")
        #expect(found.replacements.isEmpty)
        #expect(Set(found.remaining.map(\.value)) == ["#00aa00", "#11223388", "13px", "3px"])
    }

    @Test func snapOnlyTouchesWhatTheWriteIntroduced() {
        let old = Self.lines(["color: #3a56d4", "padding: 5px"])
        let new = Self.lines(["color: #3a56d4", "padding: 5px", "color: #3a56d5"])
        let found = DesignTokenCheck.enforce(.snap, tokens: Self.tokens, old: old, new: new)
        #expect(found.source == Self.lines(["color: #3a56d4", "padding: 5px", "color: var(--accent)"]))
    }

    @Test func snappingEverythingTakesInWhatWasAlreadyThere() {
        let old = Self.lines(["color: #3a56d4", "padding: 13px"])
        let found = DesignTokenCheck.enforce(.snap, tokens: Self.tokens, old: old, new: old, all: true)
        #expect(found.source == Self.lines(["color: var(--accent)", "padding: var(--space-3)"]))
        #expect(found.replacements.count == 2)
    }

    @Test func aDesignWithoutTokensHasNothingToHoldABoardTo() {
        let none = DesignTokenSet(systems: [])
        #expect(none.isEmpty)
        #expect(DesignTokenCheck.occurrences(in: Self.lines(["color: #123456"]), tokens: none).count == 1,
                "the colors are still found; the store skips an empty set before it asks")
    }

    @Test func tokensComeFromAnInstalledSystemsOwnCustomProperties() throws {
        var system = DesignSystemTokens(name: "acme", namespace: "acme")
        system.colors = [.init(name: "bg.canvas", value: "#f7f6f2", dark: "#101216"), .init(name: "--accent", value: "#3056d3")]
        system.spacing = [.init(name: "space.4", px: 16)]
        system.radii = [.init(name: "--radius-md", px: 8)]
        system.type = [.init(name: "body", size: 14)]
        let set = DesignTokenSet(systems: [DesignSystemInstalled(namespace: "acme", title: nil, shepherd: true, tokens: system, tokensFile: nil)])
        #expect(set.source == "acme")
        #expect(set.colors.map(\.name).contains("--bg-canvas"))
        #expect(set.colors.contains { $0.hex == "#101216" && $0.dark })
        #expect(set.lengths.map(\.name).sorted() == ["--radius-md", "--space-4", "--text-body-size"])
        #expect(set.lengths.first { $0.name == "--text-body-size" }?.role == .text)
    }

    @Test func aTokenNamedOddlyIsNeverWrittenIntoABoard() {
        let odd = DesignTokenSet(colors: [.init(name: "--a;b", hex: "#101010")], lengths: [], source: "x")
        let found = DesignTokenCheck.enforce(.snap, tokens: odd, old: nil, new: Self.lines(["color: #111111"]))
        #expect(found.replacements.isEmpty && found.remaining.map(\.value) == ["#111111"])
    }
}
