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
    /// shared glyphs through SHGlyph.
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
        (".font(.shMono(11))", [DesignRule.rawFontSize]),
        (".font(.shSans(12.5, .medium))", [.rawFontSize]),
        (".font(.system(size: 14, weight: .medium))", [.rawFontSize]),
        (".shText(size: 12.5, lineHeight: 1.45)", [.rawFontSize]),
        (".font(.shMono(SHGoalMetrics.labelFont))", []),
        (".font(.shSans(size - 0.5))", []),
        (".font(.system(size: SHComposerMetrics.chipSymbol, weight: .medium))", []),
        (".font(.sh(.caption))", []),
        // A status color with an opacity is a hand-made tint; a neutral role's fade is not.
        (".foregroundStyle(sh.lantern.opacity(0.6))", [.statusTintByOpacity]),
        (".background(Color.sh.failedTint.opacity(M.failureFillOpacity), in: shape)", [.statusTintByOpacity]),
        ("var tint: Color { color.opacity(SHGoalMetrics.tintOpacity) }", [.statusTintByOpacity]),
        (".fill(state.tint?.opacity(0.5))", [.statusTintByOpacity]),
        ("LinearGradient(colors: [Color.sh.bgWindow.opacity(0), Color.sh.bgWindow])", []),
        (".opacity(enabled ? 1 : SHControlMetrics.disabledOpacity)", []),
        (".fill(state.tint)", []),
        // A color is a role.
        ("Color(red: 0.1, green: 0.2, blue: 0.3)", [.rawColor]),
        ("Color(light: \"#4f46e5\", dark: \"#4f46e5\")", [.rawColor]),
        (".foregroundStyle(.white)", [.rawColor]),
        (".background(Color.indigo, in: shape)", [.rawColor]),
        ("attributes: [.foregroundColor: NSColor.systemRed]", [.rawColor]),
        (".foregroundStyle(Color.sh.textPrimary)", []),
        (".foregroundStyle(.sh.lantern)", []),
        ("Color(light: swatch.light, dark: swatch.dark)", []),
        // A shared glyph is SHGlyph's.
        ("Image(systemName: \"bolt.fill\")", [.rawGlyphName]),
        (".glyph(\"bolt\", attention: true)", [.rawGlyphName]),
        ("Image(systemName: tier == .standard ? \"bolt\" : \"bolt.fill\")", [.rawGlyphName]),
        ("Image(systemName: SHGlyph.automation.symbolName)", []),
        ("Image(systemName: \"bolt.circle\")", []),
        ("Text(\"A bolt of lightning\")", []),
    ] as [(String, [DesignRule])])
    func eachPatternFiresOnItsRuleAndNothingElse(code: String, rules: [DesignRule]) {
        #expect(DesignRules.rules(violatedBy: code) == rules, "\(code)")
        #expect(rules.isEmpty || DesignRules.prefilterAccepts(code), "the scan's quick test must let a violating line through: \(code)")
    }

    /// A symbol that is renamed under a content transition is found, whatever the transition's
    /// sibling views or a stack of fixed glyphs look like.
    @Test(arguments: SymbolSwapSample.all)
    func aRenamedSymbolUnderAContentTransitionIsFoundAndNothingElse(sample: SymbolSwapSample) {
        let found = DesignRules.symbolSwaps(in: sample.source)
        #expect(found.count == sample.hits, "\(sample.name): \(found)")
        if let line = sample.line { #expect(found.first?.line == line, "\(sample.name): reports the image's line") }
    }

    /// A glyph added to `SHGlyph` is policed at once: the scan's quick test and its rule both know it.
    @Test(arguments: SHGlyph.allCases)
    func everyRegisteredGlyphIsPolicedAsARawString(glyph: SHGlyph) {
        let line = "Image(systemName: \"\(glyph.symbolName)\")"
        #expect(DesignRules.prefilterAccepts(line), "\(line)")
        #expect(DesignRules.rules(violatedBy: line) == [.rawGlyphName], "\(line)")
    }

    @Test(arguments: [
        ("let size = 12 // .shMono(11) in a comment", "let size = 12 "),
        ("Text(\"https://example.com\") // note", "Text(\"https://example.com\") "),
        ("let url = \"//server/.shMono(11)\"", "let url = \"//server/.shMono(11)\""),
        ("let a = b // c // d", "let a = b "),
    ])
    func aTrailingCommentIsNotCode(line: String, code: String) {
        #expect(String(DesignRules.strippingComment(Substring(line))) == code)
    }
}

/// Source as a view writes it, and how many renamed symbols under a content transition the scan finds in it.
struct SymbolSwapSample: Sendable, CustomTestStringConvertible {
    let name: String
    let source: String
    let hits: Int
    /// The line the one hit is reported on.
    var line: Int?

    var testDescription: String { name }

    static let all: [SymbolSwapSample] = [
        .init(name: "Send and Stop as one renamed image", source: """
            Button(action: action) {
                Image(systemName: send ? "arrow.up" : "stop.fill")
                    .font(.system(size: send ? 13 : 10, weight: .semibold))
                    .foregroundStyle(send ? sh.textOnLantern : sh.textOnFailed)
                    .shContentTransition(.crossFade)
            }
            """, hits: 1, line: 2),
        .init(name: "a copy glyph's symbol replace", source: """
            var body: some View {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.sh(.caption))
                    .shContentTransition(.symbol)
                    .shAnimation(.content, value: copied)
            }
            """, hits: 1, line: 2),
        .init(name: "a state's symbol", source: """
            Image(systemName: state.symbolName)
                .shContentTransition(.symbol)
            """, hits: 1, line: 1),
        .init(name: "the transition on the image's own line", source: """
            Image(systemName: name).shContentTransition(.crossFade)
            """, hits: 1, line: 1),
        .init(name: "the SwiftUI spelling", source: """
            Image(systemName: name)
                .contentTransition(.symbolEffect(.replace))
            """, hits: 1, line: 1),
        .init(name: "a symbol that never changes", source: """
            Image(systemName: "checkmark")
                .shContentTransition(.symbol)
            """, hits: 0),
        .init(name: "a registered glyph", source: """
            Image(systemName: SHGlyph.pin.symbolName)
                .shContentTransition(.crossFade)
            """, hits: 0),
        .init(name: "a label's transition, with an image above it", source: """
            if let symbol {
                Image(systemName: symbol)
                    .font(.sh(.caption))
            }
            Text(label)
                .font(.sh(.caption))
                .shContentTransition(.crossFade)
            """, hits: 0),
        .init(name: "a numeric transition", source: """
            Image(systemName: open ? "chevron.down" : "chevron.right")
            Text("\\(count)")
                .shContentTransition(.numeric())
            """, hits: 0),
        .init(name: "a rename with no transition", source: """
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.sh(.caption))
                .shAnimation(.disclosure, value: expanded)
            """, hits: 0),
        .init(name: "glyphs stacked and faded", source: """
            ZStack {
                Image(systemName: "arrow.up").opacity(send ? 1 : 0)
                Image(systemName: "stop.fill").opacity(send ? 0 : 1)
            }
            .shAnimation(.content, value: send)
            """, hits: 0),
        .init(name: "a commented-out image", source: """
            // Image(systemName: name)
                .shContentTransition(.crossFade)
            """, hits: 0),
    ]
}
