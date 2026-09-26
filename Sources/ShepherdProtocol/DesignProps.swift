import Foundation

/// One control a board offers in Tweak: a prop its `data-props` gives an editor (format.md:
/// `{"editor": "text"|"color"|"int"|"float"|"range"|"boolean"|"enum", "default", "options",
/// "min", "max", "step", "unit", "section"}`). `editor: null` props (callbacks, objects) have none.
public struct DesignPropEditor: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case text, color, int, float, range, boolean
        case choice = "enum"
    }

    public let name: String
    public let kind: Kind
    public let defaultValue: JSONValue?
    /// An enum's options; a color's swatches (hex strings).
    public let options: [JSONValue]
    public let min: Double?
    public let max: Double?
    public let step: Double?
    public let unit: String?
    public let section: String?

    public init(name: String, kind: Kind, defaultValue: JSONValue? = nil, options: [JSONValue] = [], min: Double? = nil,
                max: Double? = nil, step: Double? = nil, unit: String? = nil, section: String? = nil) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.options = options
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
        self.section = section
    }

    /// `value` as this editor accepts it, or nil: a number clamped to `min`…`max` and rounded to
    /// `step` (an int to a whole number), an enum value among its options, a color among its
    /// swatches or `colors` (the design's token hexes, lower-case), text under 2000 characters.
    public func accepting(_ value: JSONValue, colors: Set<String> = []) -> JSONValue? {
        switch kind {
        case .text:
            guard case .string(let text) = value, text.count <= 2000 else { return nil }
            return value
        case .boolean:
            guard case .bool = value else { return nil }
            return value
        case .int, .float, .range:
            guard case .number(var number) = value, number.isFinite else { return nil }
            if let min { number = Swift.max(min, number) }
            if let max { number = Swift.min(max, number) }
            if let step, step > 0 {
                let base = min ?? 0
                number = base + ((number - base) / step).rounded() * step
                // Undo what binary fractions add (0.1 × 3).
                number = (number * 1_000_000).rounded() / 1_000_000
            }
            if kind == .int { number = number.rounded() }
            return .number(number)
        case .choice:
            return options.contains(value) ? value : nil
        case .color:
            guard case .string(let text) = value, let hex = DesignTokens.normalizedHex(text) else { return nil }
            let swatches = Set(options.compactMap { $0.stringValue.flatMap(DesignTokens.normalizedHex) })
            return swatches.contains(hex) || colors.contains(hex) ? .string(hex) : nil
        }
    }
}

/// A board's `data-props`, read from its source as the runtime reads them: the `data-props`
/// attribute of its `<script type="text/x-dc" data-dc-script>`, after the template.
public enum DesignProps {
    /// Every prop with an editor, in the order `data-props` writes them (`$preview` and
    /// `editor: null` left out).
    public static func editors(in source: String) -> [DesignPropEditor] {
        guard let raw = attribute(in: source), let data = raw.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return [] }
        return orderedKeys(raw).compactMap { name in
            guard !name.hasPrefix("$"), case .object(let spec)? = object[name],
                  let editor = spec["editor"]?.stringValue, let kind = DesignPropEditor.Kind(rawValue: editor) else { return nil }
            return DesignPropEditor(name: name, kind: kind, defaultValue: spec["default"], options: spec["options"]?.arrayValue ?? [],
                                    min: spec["min"]?.doubleValue, max: spec["max"]?.doubleValue, step: spec["step"]?.doubleValue,
                                    unit: spec["unit"]?.stringValue, section: spec["section"]?.stringValue)
        }
    }

    /// What a prop shows now: the design's tweak for it, else its default.
    public static func value(of editor: DesignPropEditor, tweaks: [String: JSONValue]) -> JSONValue? {
        tweaks[editor.name] ?? editor.defaultValue
    }

    /// The `data-props` text of the board's logic script, character references decoded.
    static func attribute(in source: String) -> String? {
        let bytes = Array(source.utf8)
        let start = DesignTemplate.fragmentRange(in: bytes)?.upperBound ?? 0
        var tokenizer = HTMLTokenizer(bytes: bytes, range: start..<bytes.count)
        while let tag = tokenizer.next() {
            guard !tag.isEnd, tag.name == "script" else { continue }
            let logic = tag.attribute("data-dc-script") != nil || tag.attribute("type")?.lowercased() == "text/x-dc"
            if logic { return tag.attribute("data-props") }
            tokenizer.skipRawText(of: "script")
        }
        return nil
    }

    /// An object's own keys in the order its text writes them.
    static func orderedKeys(_ json: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var i = json.startIndex
        var expectKey = false
        while i < json.endIndex {
            let c = json[i]
            if c == "\"" {
                // A string: read it whole.
                var j = json.index(after: i)
                var text = ""
                while j < json.endIndex, json[j] != "\"" {
                    if json[j] == "\\" { j = json.index(after: j); if j < json.endIndex { text.append(json[j]) } } else { text.append(json[j]) }
                    if j < json.endIndex { j = json.index(after: j) }
                }
                if depth == 1, expectKey { keys.append(text); expectKey = false }
                i = j < json.endIndex ? json.index(after: j) : j
                continue
            }
            switch c {
            case "{", "[":
                depth += 1
                expectKey = c == "{" && depth == 1
            case "}", "]":
                depth -= 1
            case ",":
                if depth == 1 { expectKey = true }
            default:
                break
            }
            i = json.index(after: i)
        }
        return keys
    }
}

extension DesignIndex {
    /// canvas.json's key for the values viewers set through Tweak (decision 13): `{"tweaks":
    /// {"<board path>": {"<prop>": value}}}`. Shepherd's own; other readers keep it as unknown.
    public static let tweaksKey = "tweaks"

    /// A board's tweaked prop values.
    public func tweaks(for path: DesignPath) -> [String: JSONValue] {
        guard case .object(let boards)? = extra[Self.tweaksKey], case .object(let values)? = boards[path.rawValue] else { return [:] }
        return values
    }

    /// The canvas update that sets a board's prop values (nil clears one back to its default).
    public static func tweakPatch(_ path: DesignPath, _ values: [String: JSONValue?]) -> JSONValue {
        .object([tweaksKey: .object([path.rawValue: .object(values.mapValues { $0 ?? .null })])])
    }
}
