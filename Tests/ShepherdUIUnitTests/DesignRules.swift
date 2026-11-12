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
    case symbolRenameUnderAnimation = "symbol-rename-under-animation"

    var testDescription: String { rawValue }

    /// The rule, as DESIGN.md states it.
    var rule: String {
        switch self {
        case .rawFontSize:
            "A view never hardcodes a font size: a literal in .shMono(11), .shSans(12), .system(size: 13) or .shText(size: 12.5, …). (DESIGN.md › Shepherd Design › Type)"
        case .statusTintByOpacity:
            "A status color is never tinted by hand: a lantern, running, done or failed role (or a tint) with .opacity(…) as a fill, line or text. (DESIGN.md › Shepherd Design › Color)"
        case .rawColor:
            "A view never hardcodes a color: Color(red:…), Color(light: \"#…\"), a hex string, Color.white, .foregroundStyle(.gray), NSColor.white. (DESIGN.md › Shepherd Design)"
        case .rawGlyphName:
            "A glyph with a shared definition is never named as a raw SF Symbol string: it comes from SHGlyph (Tokens/Glyphs.swift). (DESIGN.md › Shepherd Design › Icons)"
        case .symbolRenameUnderAnimation:
            "An SF Symbol is never renamed where an animation can reach it: an Image(systemName:) or systemImage: whose name follows state (a ? \"x\" : \"y\"), or any dynamic name under .shAnimation, .animation or a content transition. SwiftUI draws the rename through RenderBox, which loads about 258 MB of accelerated drawing pool for 1.2 to 1.6 s on every animated change, from any ancestor's .shAnimation or withSHAnimation. (DESIGN.md › Shepherd Design › Motion)"
        }
    }

    /// What to do instead.
    var fix: String {
        switch self {
        case .rawFontSize:
            "Use a ramp style (.font(.sh(.caption)), .shText(.body)). A size a board gives outside the ramp is a named constant in the component's metrics enum (SHThreadMetrics, SHGoalMetrics, …) or in AppLayout+<Domain>, used as .shMono(SHGoalMetrics.labelFont); say in your PR which board gives it."
        case .statusTintByOpacity:
            "Take the pill or banner colors from AgentState: .textColor for the word, .color for dots and glyphs, .tint for the fill (SHStatusPill, SHStateGlyph, SHStatusDot draw them). A state AgentState lacks is a new role on ThemeColors, filled in both variants, not an alpha."
        case .rawColor:
            "Use Color.sh.<role>. A color that has no role is a new role on ThemeColors, filled in both variants of every theme, with a contrast rule if it carries text. A color that is the user's own data (a design system's swatch) goes in the allowlist with that reason."
        case .rawGlyphName:
            "Draw it through SHGlyph (SHGlyph.fastBolt.image, or SHFastBolt for the Fast mark) or pass SHGlyph.<case>.symbolName where an API takes a symbol name. A new glyph that more than one view draws is a new case in Tokens/Glyphs.swift."
        case .symbolRenameUnderAnimation:
            "A disclosure chevron is one SHTurningChevron that turns. Any other pair is two images that fade: stack fixed images and fade them by opacity under .shAnimation(.content, value:) (SHComposerActionButton), or key one image with .id(state) and .shTransition(.content) in a ZStack (SHCopyGlyph, SHStateGlyph, SHCommitMessageEditor). A name that follows state where nothing animates (a menu or toolbar item, a kind that is fixed for the row) goes in the allowlist with why."
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
    static let roots = ["Sources/ShepherdApp", "Packages/ShepherdUI/Sources", "App/iOS", "App/Glance", "App/Widgets"]

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
        #"\.sh(?:Sans|Mono)\(\s*\d"#,
        #"\.system\(\s*size:\s*\d"#,
        #"\.shText\(\s*size:\s*\d"#,
        #"\.custom\([^)]*size:\s*\d"#,
        #"\b(?:NS|UI)Font\.[A-Za-z]+\(ofSize:\s*\d"#,
    ])
    /// A status role with an opacity, or an opacity named for a tint, fill or line (a hand-made tint).
    private static let statusTint = alternation([
        #"\bsh\."# + statusRoles + #"\)?\.opacity\("#,
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

    /// The symbol names `SHGlyph` registers, as the string literals that must not appear elsewhere.
    private static let registeredSymbols: [String] = SHGlyph.allCases.map { "\"\($0.symbolName)\"" }
    private static let registeredNeedles: [[UInt8]] = registeredSymbols.map { Array($0.utf8) }

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

    // MARK: Symbols renamed where an animation can reach them

    private static let symbolSite = try! NSRegularExpression(pattern: #"Image\(systemName:|\bsystemImage:"#)
    private static let animationModifier = try! NSRegularExpression(
        pattern: #"\.(?:shAnimation|shComponentAnimation|animation|shContentTransition|contentTransition|shTransition|transition|symbolEffect)\("#)
    /// `SHGlyph.pin.symbolName`, `ForgeSymbol.filter`: a named constant is one symbol.
    private static let constantName = try! NSRegularExpression(pattern: #"^[A-Z]\w*(?:\.\w+)+$"#)

    /// The text of the argument that starts at `start` in `line`: up to the comma or the closing
    /// bracket that ends it, with strings and nested brackets skipped.
    private static func argument(in line: String, from start: String.Index) -> String {
        var depth = 0, inString = false
        var previous: Character = " "
        var end = start
        while end < line.endIndex {
            let character = line[end]
            if character == "\"", previous != "\\" { inString.toggle() }
            else if !inString {
                if "([{".contains(character) { depth += 1 }
                else if ")]}".contains(character) {
                    if depth == 0 { break }
                    depth -= 1
                } else if character == ",", depth == 0 { break }
            }
            previous = character
            end = line.index(after: end)
        }
        return line[start..<end].trimmingCharacters(in: .whitespaces)
    }

    /// The `Image(systemName:)` and `systemImage:` arguments in `source` that can rename a symbol
    /// while an animation reaches it, reported at the line of the name.
    ///
    /// A name that follows state (`a ? "x" : "y"`) is always a rename: the animation that decides
    /// whether it costs the drawing pool is on some ancestor, or in a `withSHAnimation` in the
    /// caller, which a scan of one file cannot see. Any other name that is not a constant is a
    /// rename only where its own modifier chain animates (`.shAnimation`, a content transition).
    /// An image keyed with `.id(…)` is a new image on each change, not a renamed one.
    static func symbolRenames(in source: String) -> [(line: Int, text: String)] {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map { String(strippingComment($0)) }
        func trimmed(_ index: Int) -> Substring { lines[index].drop { $0 == " " || $0 == "\t" } }
        func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        var found: [(line: Int, text: String)] = []
        for index in lines.indices {
            let text = lines[index]
            guard text.contains("systemName:") || text.contains("systemImage:"), !trimmed(index).hasPrefix("//") else { continue }
            for site in symbolSite.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let end = Range(site.range, in: text)?.upperBound else { continue }
                let name = argument(in: text, from: end)
                let isLiteral = name.hasPrefix("\"") && name.hasSuffix("\"") && name.count > 1 && !name.dropFirst().dropLast().contains("\"")
                // A declaration (`let systemImage: String`, `systemImage: String,`) names no symbol.
                guard !name.isEmpty, !isLiteral, !matches(constantName, name), !name.hasPrefix("String") else { continue }
                var chain = text
                var next = index + 1
                while next < lines.count, trimmed(next).hasPrefix(".") { chain += " " + lines[next]; next += 1 }
                guard !chain.contains(".id(") else { continue }
                if name.contains(" ? ") || matches(animationModifier, chain) {
                    found.append((index + 1, String(trimmed(index))))
                    break
                }
            }
        }
        return found
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
        return has(".shSans(") || has(".shMono(") || has("size:") || has("Size:") || has(".opacity(")
            || has("Color(") || has("Color.", notFollowedBy: "sh") || has("#colorLiteral") || has("\"#") || has("NSColor") || has("UIColor")
            || has("foregroundStyle(.", notFollowedBy: "sh") || has("foregroundColor(.", notFollowedBy: "sh")
            || has(".background(.", notFollowedBy: "sh") || has(".fill(.", notFollowedBy: "sh") || has(".stroke(.", notFollowedBy: "sh")
            || has(".tint(.", notFollowedBy: "sh") || mentionsARegisteredSymbol(line)
    }

    private static func mentionsARegisteredSymbol(_ line: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let base = line.baseAddress else { return false }
        return registeredNeedles.contains { needle in
            line.count >= needle.count && needle.withUnsafeBufferPointer { memmem(base, line.count, $0.baseAddress, $0.count) != nil }
        }
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
                if data.range(of: Data("systemName:".utf8)) != nil || data.range(of: Data("systemImage:".utf8)) != nil {
                    for rename in symbolRenames(in: String(decoding: data, as: UTF8.self)) {
                        violations.append(DesignViolation(rule: .symbolRenameUnderAnimation, path: path, line: rename.line, text: rename.text))
                    }
                }
            }
        }
        return (violations, files)
    }
}
