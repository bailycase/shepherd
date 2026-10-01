import Foundation
import Testing
@testable import ShepherdUI

/// The design-system rules that DESIGN.md states in prose and a source scan can check, so a view
/// that breaks one fails a test instead of waiting for a reviewer. `DesignRulesTests` runs them
/// over the Mac app, ShepherdUI and the iOS client; `DesignRulesAllowlist` lists the offenders
/// that predate them.
enum DesignRule: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case rawFontSize = "raw-font-size"
    case statusTintByOpacity = "status-tint-by-opacity"
    case rawColor = "raw-color"
    case rawGlyphName = "raw-glyph-name"

    var testDescription: String { rawValue }

    /// The rule, as DESIGN.md states it.
    var rule: String {
        switch self {
        case .rawFontSize:
            "A view never hardcodes a font size: a literal in .nwMono(11), .nwSans(12), .system(size: 13) or .nwText(size: 12.5, …). (DESIGN.md › Night Watch › Type)"
        case .statusTintByOpacity:
            "A status color is never tinted by hand: a lantern, running, done or failed role (or a tint) with .opacity(…) as a fill, line or text. (DESIGN.md › Night Watch › Color)"
        case .rawColor:
            "A view never hardcodes a color: Color(red:…), Color(light: \"#…\"), a hex string, Color.white, .foregroundStyle(.gray), NSColor.white. (DESIGN.md › Night Watch)"
        case .rawGlyphName:
            "A glyph with a shared definition is never named as a raw SF Symbol string: it comes from NWGlyph (Tokens/Glyphs.swift). (DESIGN.md › Night Watch › Icons)"
        }
    }

    /// What to do instead.
    var fix: String {
        switch self {
        case .rawFontSize:
            "Use a ramp style (.font(.nw(.caption)), .nwText(.body)). A size a board gives outside the ramp is a named constant in the component's metrics enum (NWThreadMetrics, NWGoalMetrics, …) or in AppLayout+<Domain>, used as .nwMono(NWGoalMetrics.labelFont); say in your PR which board gives it."
        case .statusTintByOpacity:
            "Take the pill or banner colors from AgentState: .textColor for the word, .color for dots and glyphs, .tint for the fill (NWStatusPill, NWStateGlyph, NWStatusDot draw them). A state AgentState lacks is a new role on ThemeColors, filled in both variants, not an alpha."
        case .rawColor:
            "Use Color.nw.<role>. A color that has no role is a new role on ThemeColors, filled in both variants of every theme, with a contrast rule if it carries text. A color that is the user's own data (a design system's swatch) goes in the allowlist with that reason."
        case .rawGlyphName:
            "Draw it through NWGlyph (NWGlyph.fastBolt.image, or NWFastBolt for the Fast mark) or pass NWGlyph.<case>.symbolName where an API takes a symbol name. A new glyph that more than one view draws is a new case in Tokens/Glyphs.swift."
        }
    }
}

/// One place a rule is broken.
struct DesignViolation: Hashable, Sendable {
    let rule: DesignRule
    /// Relative to the repository root.
    let path: String
    let line: Int
    let text: String
}

enum DesignRules {
    /// Where the scan looks: the Mac app, ShepherdUI's components, and the iPhone and iPad client.
    static let roots = ["Sources/ShepherdApp", "Packages/ShepherdUI/Sources", "App/iOS"]

    /// Folders the rules do not apply to, each with why.
    static let exempt: [(prefix: String, reason: String)] = [
        ("Packages/ShepherdUI/Sources/ShepherdUI/Tokens/", "the token definitions are where a literal belongs"),
        ("Packages/ShepherdUI/Sources/ShepherdUI/Previews/", "the Xcode canvas's scaffolding, drawn nowhere in the app"),
    ]

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Patterns

    private static func alternation(_ patterns: [String]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|"))
    }

    private static let statusRoles = "(?:lantern|lanternText|lanternTint|running|runningTint|done|doneTint|failed|failedTint)"
    private static let namedColors = "(?:white|black|red|green|blue|gray|grey|orange|yellow|pink|purple|cyan|mint|teal|indigo|brown|primary|secondary)"

    private static let fontSize = alternation([
        #"\.nw(?:Sans|Mono)\(\s*\d"#,
        #"\.system\(\s*size:\s*\d"#,
        #"\.nwText\(\s*size:\s*\d"#,
        #"\.custom\([^)]*size:\s*\d"#,
        #"\b(?:NS|UI)Font\.[A-Za-z]+\(ofSize:\s*\d"#,
    ])
    /// A status role with an opacity, or an opacity named for a tint, fill or line (a hand-made tint).
    private static let statusTint = alternation([
        #"\bnw\."# + statusRoles + #"\)?\.opacity\("#,
        #"\.(?:textColor|tint)\??\.opacity\("#,
        #"(?i:\.opacity\(\s*[\w.]*(?:tint|fill|line|border|wash)\w*opacity)"#,
    ])
    private static let color = alternation([
        #"\bColor\(\s*(?:red|white|hue|\.sRGB|\.displayP3|\.genericRGB|\.rgb)"#,
        #"\bColor\(\s*""#,
        #"#colorLiteral"#,
        #"\bColor\."# + namedColors + #"\b"#,
        #"\.(?:foregroundStyle|foregroundColor|background|fill|stroke|tint)\(\s*\."# + namedColors + #"\b"#,
        #"\b(?:NS|UI)Color\((?:red|white|srgbRed|calibrated|deviceRed|hue|displayP3)"#,
        #"\b(?:NS|UI)Color\.(?:white|black|red|green|blue|gray|orange|yellow|system[A-Za-z]+)\b"#,
        ##""#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?""##,
    ])

    /// The symbol names `NWGlyph` registers, as the string literals that must not appear elsewhere.
    private static let registeredSymbols: [String] = NWGlyph.allCases.map { "\"\($0.symbolName)\"" }

    /// The rules a line of code breaks. `code` has its comments removed (`strippingComment`).
    static func rules(violatedBy code: String) -> [DesignRule] {
        var broken: [DesignRule] = []
        let range = NSRange(code.startIndex..., in: code)
        func matches(_ expression: NSRegularExpression) -> Bool { expression.firstMatch(in: code, range: range) != nil }
        if matches(fontSize) { broken.append(.rawFontSize) }
        if code.contains(".opacity("), matches(statusTint) { broken.append(.statusTintByOpacity) }
        if matches(color) { broken.append(.rawColor) }
        if registeredSymbols.contains(where: code.contains) { broken.append(.rawGlyphName) }
        return broken
    }

    /// `line` without a `//` comment, leaving `://` and anything inside a string alone.
    static func strippingComment(_ line: Substring) -> Substring {
        guard line.contains("//") else { return line }
        var inString = false, previous: Character = " "
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"", previous != "\\" { inString.toggle() }
            if !inString, character == "/", previous == "/", index > line.startIndex {
                let slashes = line.index(before: index)
                if slashes == line.startIndex || line[line.index(before: slashes)] != ":" { return line[..<slashes] }
            }
            previous = character
            index = line.index(after: index)
        }
        return line
    }

    // MARK: Scanning

    /// A cheap test on a line's bytes that any line breaking a rule passes, so that the patterns
    /// run on a few lines in a hundred. It over-accepts and `rules(violatedBy:)` decides.
    private static func mightBreakARule(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        func has(_ needle: StaticString, notFollowedBy skip: StaticString? = nil) -> Bool {
            guard let base = line.baseAddress, line.count >= needle.utf8CodeUnitCount else { return false }
            var offset = 0
            while offset < line.count {
                guard let found = memmem(base + offset, line.count - offset, needle.utf8Start, needle.utf8CodeUnitCount) else { return false }
                let after = base.distance(to: found.assumingMemoryBound(to: UInt8.self)) + needle.utf8CodeUnitCount
                guard let skip else { return true }
                if after + skip.utf8CodeUnitCount > line.count || memcmp(base + after, skip.utf8Start, skip.utf8CodeUnitCount) != 0 { return true }
                offset = after
            }
            return false
        }
        return has(".nwSans(") || has(".nwMono(") || has("size:") || has("Size:") || has(".opacity(")
            || has("Color(") || has("Color.", notFollowedBy: "nw") || has("#colorLiteral") || has("\"#") || has("NSColor") || has("UIColor")
            || has("foregroundStyle(.", notFollowedBy: "nw") || has("foregroundColor(.", notFollowedBy: "nw")
            || has(".background(.", notFollowedBy: "nw") || has(".fill(.", notFollowedBy: "nw") || has(".stroke(.", notFollowedBy: "nw")
            || has(".tint(.", notFollowedBy: "nw") || has("\"bolt")
    }

    /// `mightBreakARule` for a line of text.
    static func prefilterAccepts(_ code: String) -> Bool {
        var code = code
        return code.withUTF8 { mightBreakARule($0) }
    }

    /// Every violation under the scanned folders, in path then line order, and how many files it
    /// read. About five hundred files, which a test run reads once.
    static func scan() -> (violations: [DesignViolation], files: Int) {
        var violations: [DesignViolation] = []
        var files = 0
        for folder in roots {
            let base = root.appendingPathComponent(folder)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            var urls = (walker.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            urls.sort { $0.path < $1.path }
            for url in urls {
                let path = String(url.path.dropFirst(root.path.count + 1))
                if exempt.contains(where: { path.hasPrefix($0.prefix) }) { continue }
                guard let data = FileManager.default.contents(atPath: url.path) else { continue }
                files += 1
                data.withUnsafeBytes { raw in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    guard let base = bytes.baseAddress else { return }
                    var start = 0, number = 0
                    while start <= bytes.count {
                        number += 1
                        let end = memchr(base + start, 10, bytes.count - start).map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? bytes.count
                        defer { start = end + 1 }
                        let line = UnsafeBufferPointer(start: base + start, count: end - start)
                        guard mightBreakARule(line) else { continue }
                        let text = String(decoding: line, as: UTF8.self)
                        let trimmed = text.drop { $0 == " " || $0 == "\t" }
                        if trimmed.hasPrefix("//") { continue }
                        for rule in rules(violatedBy: String(strippingComment(Substring(text)))) {
                            violations.append(DesignViolation(rule: rule, path: path, line: number, text: String(trimmed)))
                        }
                    }
                }
            }
        }
        return (violations, files)
    }
}
