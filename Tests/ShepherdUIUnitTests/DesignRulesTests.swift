import Foundation
import Testing
@testable import ShepherdUI

/// DESIGN.md's rules that a source scan can check, over the Mac app, ShepherdUI and the iOS
/// client. A view that breaks one fails here with the rule and how to fix it, instead of waiting
/// for a reviewer to find it. What predates the rules is in `DesignRuleAllowlist`.
@Suite("Design rules")
struct DesignRulesTests {
    private static let scan = DesignRules.scan()

    /// The files each rule's allowlist entry covers, summed per file.
    private static func ceilings(for rule: DesignRule) -> [String: Int] {
        Dictionary(DesignRuleAllowlist.entries.filter { $0.rule == rule }.map { ($0.path, $0.upTo) }, uniquingKeysWith: +)
    }

    /// New code names its sizes, takes status colors from AgentState, uses color roles, and draws
    /// shared glyphs through NWGlyph.
    @Test(arguments: DesignRule.allCases)
    func newCodeBreaksNoDesignRule(_ rule: DesignRule) {
        let ceilings = Self.ceilings(for: rule)
        let byFile = Dictionary(grouping: Self.scan.violations.filter { $0.rule == rule }, by: \.path)
        var report: [String] = []
        for path in byFile.keys.sorted() {
            let found = byFile[path] ?? []
            let allowed = ceilings[path] ?? 0
            guard found.count > allowed else { continue }
            // The allowlist counts, it does not name lines, so a file over its ceiling lists them all.
            let lines = found.map { "    \(path):\($0.line): \($0.text.prefix(110))" }.joined(separator: "\n")
            report.append("  \(path): \(found.count) found, \(allowed) allowed\n\(lines)")
        }
        guard !report.isEmpty else { return }
        Issue.record("""
            Design rule \(rule.rawValue) is broken.
            Rule: \(rule.rule)
            Fix: \(rule.fix)
            \(report.joined(separator: "\n"))
            The existing offenders are in Tests/ShepherdUIUnitTests/DesignRulesAllowlist.swift and only ever shrink: do not add to it for code you wrote.
            """)
    }

    /// An entry for a file that no longer breaks the rule, or no longer exists, is deleted, so the
    /// list shows what is left.
    @Test func theAllowlistHoldsNoEntryThatIsClean() {
        let found = Dictionary(grouping: Self.scan.violations, by: { "\($0.rule.rawValue) \($0.path)" })
        let stale = DesignRuleAllowlist.entries.filter { found["\($0.rule.rawValue) \($0.path)"] == nil }
        #expect(stale.isEmpty, "Delete these allowlist entries, their files are clean or gone: \(stale.map { "\($0.rule.rawValue) \($0.path)" })")
    }

    @Test func everyAllowlistEntryNamesItsReasonAndAFileThatCanBeScanned() {
        for entry in DesignRuleAllowlist.entries {
            #expect(entry.reason.count >= 20, "\(entry.path): say why \(entry.rule.rawValue) is allowed here")
            #expect(entry.upTo > 0, "\(entry.path): an entry allows at least one violation")
            #expect(DesignRules.roots.contains { entry.path.hasPrefix($0) }, "\(entry.path) is not under a scanned folder")
            #expect(!DesignRules.exempt.contains { entry.path.hasPrefix($0.prefix) }, "\(entry.path) is in a folder the rules skip")
        }
        let keys = DesignRuleAllowlist.entries.map { "\($0.rule.rawValue) \($0.path)" }
        #expect(Set(keys).count == keys.count, "a file has one entry per rule")
    }

    /// A scan that found no files would pass for the wrong reason.
    @Test func theScanReadsTheWholeCodeBase() {
        #expect(Self.scan.files > 300, "scanned \(Self.scan.files) files: did the folders move?")
    }

    // MARK: The patterns

    /// Each pattern fires on what its rule names and stays quiet on what the rules allow.
    @Test(arguments: [
        // A literal size is a violation; a named one is a metric.
        (".font(.nwMono(11))", [DesignRule.rawFontSize]),
        (".font(.nwSans(12.5, .medium))", [.rawFontSize]),
        (".font(.system(size: 14, weight: .medium))", [.rawFontSize]),
        (".nwText(size: 12.5, lineHeight: 1.45)", [.rawFontSize]),
        (".font(.nwMono(NWGoalMetrics.labelFont))", []),
        (".font(.nwSans(size - 0.5))", []),
        (".font(.system(size: NWComposerMetrics.chipSymbol, weight: .medium))", []),
        (".font(.nw(.caption))", []),
        // A status color with an opacity is a hand-made tint; a neutral role's fade is not.
        (".foregroundStyle(nw.lantern.opacity(0.6))", [.statusTintByOpacity]),
        (".background(Color.nw.failedTint.opacity(M.failureFillOpacity), in: shape)", [.statusTintByOpacity]),
        ("var tint: Color { color.opacity(NWGoalMetrics.tintOpacity) }", [.statusTintByOpacity]),
        (".fill(state.tint?.opacity(0.5))", [.statusTintByOpacity]),
        ("LinearGradient(colors: [Color.nw.bgWindow.opacity(0), Color.nw.bgWindow])", []),
        (".opacity(enabled ? 1 : NWControlMetrics.disabledOpacity)", []),
        (".fill(state.tint)", []),
        // A color is a role.
        ("Color(red: 0.1, green: 0.2, blue: 0.3)", [.rawColor]),
        ("Color(light: \"#4f46e5\", dark: \"#4f46e5\")", [.rawColor]),
        (".foregroundStyle(.white)", [.rawColor]),
        (".background(Color.indigo, in: shape)", [.rawColor]),
        ("attributes: [.foregroundColor: NSColor.systemRed]", [.rawColor]),
        (".foregroundStyle(Color.nw.textPrimary)", []),
        (".foregroundStyle(.nw.lantern)", []),
        ("Color(light: swatch.light, dark: swatch.dark)", []),
        // A shared glyph is NWGlyph's.
        ("Image(systemName: \"bolt.fill\")", [.rawGlyphName]),
        (".glyph(\"bolt\", attention: true)", [.rawGlyphName]),
        ("Image(systemName: tier == .standard ? \"bolt\" : \"bolt.fill\")", [.rawGlyphName]),
        ("Image(systemName: NWGlyph.automation.symbolName)", []),
        ("Image(systemName: \"bolt.circle\")", []),
        ("Text(\"A bolt of lightning\")", []),
    ] as [(String, [DesignRule])])
    func eachPatternFiresOnItsRuleAndNothingElse(code: String, rules: [DesignRule]) {
        #expect(DesignRules.rules(violatedBy: code) == rules, "\(code)")
        #expect(rules.isEmpty || DesignRules.prefilterAccepts(code), "the scan's quick test must let a violating line through: \(code)")
    }

    @Test(arguments: [
        ("let size = 12 // .nwMono(11) in a comment", "let size = 12 "),
        ("Text(\"https://example.com\") // note", "Text(\"https://example.com\") "),
        ("let url = \"//server/.nwMono(11)\"", "let url = \"//server/.nwMono(11)\""),
        ("let a = b // c // d", "let a = b "),
    ])
    func aTrailingCommentIsNotCode(line: String, code: String) {
        #expect(String(DesignRules.strippingComment(Substring(line))) == code)
    }
}
