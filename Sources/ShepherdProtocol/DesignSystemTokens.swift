import Foundation

/// A design system's `tokens.json` (docs/designs.md › Design systems): its colors, type styles,
/// spacing and radius steps, fonts and components, each token saying where it came from
/// (`tokens.css:8`).
///
/// Shepherd writes its own schema (`"format": "shepherd-tokens/1"`, lists of named tokens). It
/// also reads the older shape a canvas's own `tokens.json` has (`color.light` and `color.dark`
/// maps, `type`, `space` and `radius` maps, `fonts`), so either can be installed and checked
/// against. Every key this build doesn't name is kept, at the top and on each token.
public struct DesignSystemTokens: Hashable, Sendable {
    public static let format = "shepherd-tokens/1"

    /// Which shape the file had.
    public enum Shape: String, Hashable, Sendable, Codable {
        /// Shepherd's schema: `colors`, `type`, `spacing`, `radii`, `fonts`, `components` lists.
        case shepherd
        /// A canvas's own tokens.json: `color.light`/`color.dark`, `type`, `space`, `radius` maps.
        case canvas
    }

    /// Where a token is declared: a file (relative to the project it was read from) and a line.
    public struct Source: Hashable, Sendable, Codable {
        public var file: String
        public var line: Int?

        public init(file: String, line: Int? = nil) {
            self.file = file
            self.line = line
        }

        /// "tokens.css:8": the file's name, then its line.
        public var label: String {
            let name = file.split(separator: "/").last.map(String.init) ?? file
            return line.map { "\(name):\($0)" } ?? name
        }
    }

    public struct Color: Hashable, Sendable {
        /// `--accent`, or a dotted name from a canvas's tokens (`bg.canvas`).
        public var name: String
        /// As written: `#4f46e5`, `rgb(…)`, `oklch(…)`.
        public var value: String
        /// Its value in a dark variant, when the system has one.
        public var dark: String?
        public var source: Source?
        public var extra: [String: JSONValue]

        public init(name: String, value: String, dark: String? = nil, source: Source? = nil, extra: [String: JSONValue] = [:]) {
            self.name = name
            self.value = value
            self.dark = dark
            self.source = source
            self.extra = extra
        }
    }

    public struct TypeStyle: Hashable, Sendable {
        public var name: String
        /// px.
        public var size: Double
        public var weight: Int?
        /// A multiple of the size.
        public var lineHeight: Double?
        public var family: String?
        /// em.
        public var tracking: Double?
        public var transform: String?
        /// A line set in it ("Checkout funnel").
        public var sample: String?
        public var source: Source?
        public var extra: [String: JSONValue]

        public init(name: String, size: Double, weight: Int? = nil, lineHeight: Double? = nil, family: String? = nil,
                    tracking: Double? = nil, transform: String? = nil, sample: String? = nil, source: Source? = nil,
                    extra: [String: JSONValue] = [:]) {
            self.name = name
            self.size = size
            self.weight = weight
            self.lineHeight = lineHeight
            self.family = family
            self.tracking = tracking
            self.transform = transform
            self.sample = sample
            self.source = source
            self.extra = extra
        }
    }

    /// A spacing or radius step.
    public struct Length: Hashable, Sendable {
        public var name: String
        public var px: Double
        public var source: Source?
        public var extra: [String: JSONValue]

        public init(name: String, px: Double, source: Source? = nil, extra: [String: JSONValue] = [:]) {
            self.name = name
            self.px = px
            self.source = source
            self.extra = extra
        }
    }

    public struct Font: Hashable, Sendable {
        /// What type styles call it: `sans`, `mono`.
        public var name: String
        public var family: String
        public var fallback: String?
        public var extra: [String: JSONValue]

        public init(name: String, family: String, fallback: String? = nil, extra: [String: JSONValue] = [:]) {
            self.name = name
            self.family = family
            self.fallback = fallback
            self.extra = extra
        }
    }

    /// A component the system has: where it is written in the project, a specimen file in the
    /// system's folder that shows it, and the global a bundle mounts it by (`Acme.Button`, for
    /// `<x-import component-from-global-scope>`).
    public struct Component: Hashable, Sendable {
        public var name: String
        public var source: Source?
        public var specimen: String?
        public var export: String?
        public var extra: [String: JSONValue]

        public init(name: String, source: Source? = nil, specimen: String? = nil, export: String? = nil,
                    extra: [String: JSONValue] = [:]) {
            self.name = name
            self.source = source
            self.specimen = specimen
            self.export = export
            self.extra = extra
        }
    }

    public var shape: Shape
    /// The system's title ("acme-web").
    public var name: String?
    public var namespace: String?
    public var version: String?
    public var colors: [Color]
    public var type: [TypeStyle]
    public var spacing: [Length]
    public var radii: [Length]
    public var fonts: [Font]
    public var components: [Component]
    /// Keys this build doesn't name (a canvas's `size` and `motion`, say).
    public var extra: [String: JSONValue]

    public init(name: String? = nil, namespace: String? = nil, version: String? = nil, colors: [Color] = [],
                type: [TypeStyle] = [], spacing: [Length] = [], radii: [Length] = [], fonts: [Font] = [],
                components: [Component] = [], extra: [String: JSONValue] = [:]) {
        shape = .shepherd
        self.name = name
        self.namespace = namespace
        self.version = version
        self.colors = colors
        self.type = type
        self.spacing = spacing
        self.radii = radii
        self.fonts = fonts
        self.components = components
        self.extra = extra
    }

    /// How many of each a system has, as its page counts them.
    public var counts: DesignSystemCounts {
        DesignSystemCounts(colors: colors.count, type: type.count, lengths: spacing.count + radii.count,
                           components: components.count)
    }

    // MARK: Limits

    public static let maxTokens = 500
    public static let maxComponents = 200
    public static let maxNameLength = 80
    public static let maxValueLength = 120
}

/// How many tokens of each kind a system has ("11 colors, 4 type styles, 7 spacing and radius
/// steps, 9 components").
public struct DesignSystemCounts: Hashable, Sendable, Codable {
    public var colors: Int
    public var type: Int
    /// Spacing and radius steps together.
    public var lengths: Int
    public var components: Int

    public init(colors: Int = 0, type: Int = 0, lengths: Int = 0, components: Int = 0) {
        self.colors = colors
        self.type = type
        self.lengths = lengths
        self.components = components
    }
}

/// Why a tokens.json can't be read.
public struct DesignSystemTokensError: Error, Hashable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

// MARK: - Reading

extension DesignSystemTokens {
    public static func decode(_ data: Data) throws -> DesignSystemTokens {
        let json: JSONValue
        do { json = try JSONDecoder().decode(JSONValue.self, from: data) } catch {
            throw DesignSystemTokensError("tokens.json is not JSON")
        }
        return try DesignSystemTokens(json: json)
    }

    /// Reads either shape. A token without a name, or a color, size or step without its value,
    /// makes the file unreadable: nothing half-read is checked against.
    public init(json: JSONValue) throws {
        guard case .object(var object) = json else { throw DesignSystemTokensError("tokens.json is not an object") }
        let isCanvasShape = object["colors"] == nil && (object["color"]?.objectValue != nil || object["space"]?.objectValue != nil
                                                        || object["radius"]?.objectValue != nil)
        self.init()
        name = object.removeValue(forKey: "name")?.stringValue ?? object["title"]?.stringValue
        if name != nil, object["title"]?.stringValue == name { object["title"] = nil }
        namespace = object.removeValue(forKey: "namespace")?.stringValue
        version = object.removeValue(forKey: "version").flatMap { $0.stringValue ?? $0.doubleValue.map { String($0) } }
        if isCanvasShape {
            shape = .canvas
            try readCanvasShape(&object)
        } else {
            if let format = object["format"]?.stringValue, format == Self.format { object["format"] = nil }
            try readShepherdShape(&object)
        }
        extra = object
    }

    private mutating func readShepherdShape(_ object: inout [String: JSONValue]) throws {
        func list(_ key: String) throws -> [[String: JSONValue]] {
            guard let value = object.removeValue(forKey: key) else { return [] }
            guard let items = value.arrayValue else { throw DesignSystemTokensError("\(key) is a list") }
            return try items.map { item in
                guard let fields = item.objectValue else { throw DesignSystemTokensError("each of \(key) is an object") }
                return fields
            }
        }
        colors = try list("colors").map { fields in
            var f = fields
            guard let name = Self.take(&f, "name")?.stringValue, let value = Self.take(&f, "value")?.stringValue else {
                throw DesignSystemTokensError("a color needs a name and a value")
            }
            return Color(name: name, value: value, dark: Self.take(&f, "dark")?.stringValue,
                         source: Self.source(Self.take(&f, "source")), extra: f)
        }
        type = try list("type").map { fields in
            var f = fields
            guard let name = Self.take(&f, "name")?.stringValue, let size = Self.number(Self.take(&f, "size")) else {
                throw DesignSystemTokensError("a type style needs a name and a size")
            }
            return TypeStyle(name: name, size: size, weight: Self.number(Self.take(&f, "weight")).map { Int($0) },
                             lineHeight: Self.number(Self.take(&f, "lineHeight")), family: Self.take(&f, "family")?.stringValue,
                             tracking: Self.number(Self.take(&f, "tracking")), transform: Self.take(&f, "transform")?.stringValue,
                             sample: Self.take(&f, "sample")?.stringValue, source: Self.source(Self.take(&f, "source")), extra: f)
        }
        spacing = try list("spacing").map(Self.length)
        radii = try list("radii").map(Self.length)
        fonts = try list("fonts").map { fields in
            var f = fields
            guard let name = Self.take(&f, "name")?.stringValue, let family = Self.take(&f, "family")?.stringValue else {
                throw DesignSystemTokensError("a font needs a name and a family")
            }
            return Font(name: name, family: family, fallback: Self.take(&f, "fallback")?.stringValue, extra: f)
        }
        components = try list("components").map { fields in
            var f = fields
            guard let name = Self.take(&f, "name")?.stringValue else { throw DesignSystemTokensError("a component needs a name") }
            return Component(name: name, source: Self.source(Self.take(&f, "source")), specimen: Self.take(&f, "specimen")?.stringValue,
                             export: Self.take(&f, "export")?.stringValue, extra: f)
        }
    }

    /// A canvas's own tokens.json: `color.light` names the colors (with `color.dark` their dark
    /// values), `type` maps names to styles whose `font` names one of `fonts`, and `space` and
    /// `radius` map step names to px. A color value that isn't a color (a shadow) stays where it
    /// was, in `extra`.
    private mutating func readCanvasShape(_ object: inout [String: JSONValue]) throws {
        if let fonts = object["fonts"]?.objectValue {
            object["fonts"] = nil
            self.fonts = fonts.sorted { $0.key < $1.key }.compactMap { name, value in
                guard var f = value.objectValue, let family = Self.take(&f, "family")?.stringValue else { return nil }
                return Font(name: name, family: family, fallback: Self.take(&f, "fallback")?.stringValue, extra: f)
            }
        }
        if let color = object["color"]?.objectValue {
            let light = color["light"]?.objectValue ?? color.filter { $0.value.stringValue != nil }
            let dark = color["dark"]?.objectValue ?? [:]
            func asColor(_ value: JSONValue?) -> String? {
                value?.stringValue.flatMap { DesignSystemCSS.isColor($0) ? $0 : nil }
            }
            for (key, value) in light.sorted(by: { $0.key < $1.key }) {
                guard let text = asColor(value) else { continue }
                colors.append(Color(name: key, value: text, dark: asColor(dark[key])))
            }
            // The map leaves the file's extra keys only when every entry in it was read as a
            // color; otherwise it stays in the file's own words.
            let read = Set(colors.map(\.name))
            let whole = color["light"] != nil && Set(color.keys).isSubset(of: ["light", "dark"])
                && Set(light.keys) == read && dark.allSatisfy { read.contains($0.key) && asColor($0.value) != nil }
            object["color"] = whole ? nil : .object(color)
        }
        if let styles = object["type"]?.objectValue {
            object["type"] = nil
            let families = Dictionary(fonts.map { ($0.name, $0.family) }, uniquingKeysWith: { a, _ in a })
            type = try styles.sorted { $0.key < $1.key }.map { name, value in
                guard var f = value.objectValue, let size = Self.number(Self.take(&f, "size")) else {
                    throw DesignSystemTokensError("type \(name) needs a size")
                }
                let font = Self.take(&f, "font")?.stringValue
                if let font, families[font] == nil { f["font"] = .string(font) }
                return TypeStyle(name: name, size: size, weight: Self.number(Self.take(&f, "weight")).map { Int($0) },
                                 lineHeight: Self.number(Self.take(&f, "lineHeight")),
                                 family: font.flatMap { families[$0] } ?? Self.take(&f, "family")?.stringValue,
                                 tracking: Self.number(Self.take(&f, "tracking")), transform: Self.take(&f, "transform")?.stringValue,
                                 extra: f)
            }
        }
        func steps(_ key: String, prefix: String) -> [Length] {
            guard let map = object[key]?.objectValue else { return [] }
            object[key] = nil
            let numeric = map.compactMap { name, value in Self.number(value).map { (name, $0) } }
            if numeric.count != map.count { object[key] = .object(map.filter { Self.number($0.value) == nil }) }
            return numeric
                .sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0 < b.0 }
                .map { Length(name: "\(prefix).\($0.0)", px: $0.1) }
        }
        spacing = steps("space", prefix: "space")
        radii = steps("radius", prefix: "radius")
    }

    private static func length(_ fields: [String: JSONValue]) throws -> Length {
        var f = fields
        guard let name = take(&f, "name")?.stringValue, let px = number(take(&f, "px")) else {
            throw DesignSystemTokensError("a step needs a name and px")
        }
        return Length(name: name, px: px, source: source(take(&f, "source")), extra: f)
    }

    private static func take(_ fields: inout [String: JSONValue], _ key: String) -> JSONValue? {
        fields.removeValue(forKey: key)
    }

    private static func number(_ value: JSONValue?) -> Double? {
        value?.doubleValue.flatMap { $0.isFinite ? $0 : nil }
    }

    /// `{"file": "tokens.css", "line": 8}`, or the same written `"tokens.css:8"`.
    private static func source(_ value: JSONValue?) -> Source? {
        guard let value else { return nil }
        if let fields = value.objectValue, let file = fields["file"]?.stringValue {
            return Source(file: file, line: number(fields["line"]).map { Int($0) })
        }
        if let text = value.stringValue, !text.isEmpty {
            if let colon = text.lastIndex(of: ":"), let line = Int(text[text.index(after: colon)...]) {
                return Source(file: String(text[..<colon]), line: line)
            }
            return Source(file: text)
        }
        return nil
    }
}

// MARK: - Writing

extension DesignSystemTokens {
    /// tokens.json in Shepherd's schema: typed fields, then every key it kept.
    public var json: JSONValue {
        var o = extra
        o["format"] = .string(Self.format)
        if let name { o["name"] = .string(name) }
        if let namespace { o["namespace"] = .string(namespace) }
        if let version { o["version"] = .string(version) }
        o["colors"] = .array(colors.map { color in
            var f = color.extra
            f["name"] = .string(color.name)
            f["value"] = .string(color.value)
            if let dark = color.dark { f["dark"] = .string(dark) }
            if let source = color.source { f["source"] = Self.json(source) }
            return .object(f)
        })
        o["type"] = .array(type.map { style in
            var f = style.extra
            f["name"] = .string(style.name)
            f["size"] = .number(style.size)
            if let weight = style.weight { f["weight"] = .number(Double(weight)) }
            if let lineHeight = style.lineHeight { f["lineHeight"] = .number(lineHeight) }
            if let family = style.family { f["family"] = .string(family) }
            if let tracking = style.tracking { f["tracking"] = .number(tracking) }
            if let transform = style.transform { f["transform"] = .string(transform) }
            if let sample = style.sample { f["sample"] = .string(sample) }
            if let source = style.source { f["source"] = Self.json(source) }
            return .object(f)
        })
        o["spacing"] = .array(spacing.map(Self.json))
        o["radii"] = .array(radii.map(Self.json))
        o["fonts"] = .array(fonts.map { font in
            var f = font.extra
            f["name"] = .string(font.name)
            f["family"] = .string(font.family)
            if let fallback = font.fallback { f["fallback"] = .string(fallback) }
            return .object(f)
        })
        o["components"] = .array(components.map { component in
            var f = component.extra
            f["name"] = .string(component.name)
            if let source = component.source { f["source"] = Self.json(source) }
            if let specimen = component.specimen { f["specimen"] = .string(specimen) }
            if let export = component.export { f["export"] = .string(export) }
            return .object(f)
        })
        return .object(o)
    }

    private static func json(_ length: Length) -> JSONValue {
        var f = length.extra
        f["name"] = .string(length.name)
        f["px"] = .number(length.px)
        if let source = length.source { f["source"] = json(source) }
        return .object(f)
    }

    private static func json(_ source: Source) -> JSONValue {
        var f: [String: JSONValue] = ["file": .string(source.file)]
        if let line = source.line { f["line"] = .number(Double(line)) }
        return .object(f)
    }

    /// Sorted keys, two-space indents: the bytes Shepherd writes.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }
}

extension DesignSystemTokens: Codable {
    public init(from decoder: Decoder) throws {
        do { try self.init(json: JSONValue(from: decoder)) } catch let error as DesignSystemTokensError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: error.description))
        }
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

// MARK: - Rules

extension DesignSystemTokens {
    /// What a write must not hold: names and values that could break out of the stylesheet
    /// Shepherd generates from them, and more tokens than a system keeps. Empty when sound.
    public func problems() -> [String] {
        var problems: [String] = []
        if let namespace, !DesignPath.isSystemNamespace(namespace) {
            problems.append("namespace \"\(namespace)\" is [a-z0-9][a-z0-9_-]{0,63}")
        }
        let tokens = colors.count + type.count + spacing.count + radii.count + fonts.count
        if tokens > Self.maxTokens { problems.append("at most \(Self.maxTokens) tokens") }
        if components.count > Self.maxComponents { problems.append("at most \(Self.maxComponents) components") }
        let names = colors.map(\.name) + type.map(\.name) + spacing.map(\.name) + radii.map(\.name) + fonts.map(\.name)
            + components.map(\.name)
        for name in names where !Self.isName(name) {
            problems.append("\"\(name.prefix(40))\" can't name a token: 1–\(Self.maxNameLength) letters, digits, and . _ - (a leading -- is fine)")
        }
        for color in colors {
            for value in [color.value] + (color.dark.map { [$0] } ?? []) where !DesignSystemCSS.isColor(value) {
                problems.append("\(color.name): \"\(value.prefix(40))\" is not a color")
            }
        }
        for style in type where !(1...400).contains(style.size) || style.weight.map({ !(1...1000).contains($0) }) == true {
            problems.append("\(style.name): a size of 1–400 px and a weight of 1–1000")
        }
        for style in type {
            for text in [style.family, style.transform, style.sample].compactMap({ $0 }) where !DesignSystemCSS.isSafeValue(text) {
                problems.append("\(style.name): \"\(text.prefix(40))\" holds ; { } < > \\ or a line break")
            }
        }
        for font in fonts {
            for text in [font.family] + (font.fallback.map { [$0] } ?? []) where !DesignSystemCSS.isSafeValue(text) {
                problems.append("font \(font.name): \"\(text.prefix(40))\" holds ; { } < > \\ or a line break")
            }
        }
        for length in spacing + radii where !(0...10_000).contains(length.px) {
            problems.append("\(length.name): px is 0–10000")
        }
        for component in components {
            if let specimen = component.specimen, !DesignSystemFile.isPath(specimen) {
                problems.append("\(component.name): specimen \"\(specimen.prefix(60))\" is not a file of the system")
            }
            if let export = component.export, !DesignSystemCSS.isGlobalPath(export) {
                problems.append("\(component.name): export \"\(export.prefix(60))\" is Ns.Component")
            }
        }
        return problems
    }

    static func isName(_ name: String) -> Bool {
        let body = name.hasPrefix("--") ? name.dropFirst(2) : Substring(name)
        guard !body.isEmpty, name.utf8.count <= maxNameLength else { return false }
        return body.utf8.allSatisfy { b in
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
                || b == UInt8(ascii: "_") || b == UInt8(ascii: "-") || b == UInt8(ascii: ".") || b == UInt8(ascii: " ")
        }
    }

    /// The CSS custom property a token is written as in tokens.css: its name when it is one
    /// (`--accent`), else `--` and the name with each run of other characters as `-`
    /// (`bg.canvas` → `--bg-canvas`).
    public static func cssName(_ name: String) -> String {
        if name.hasPrefix("--") { return name }
        var out = ""
        var dash = false
        for scalar in name.unicodeScalars {
            let ok = CharacterSet.alphanumerics.contains(scalar) && scalar.isASCII || scalar == "_"
            if ok {
                out.unicodeScalars.append(scalar)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return "--" + out
    }

    /// tokens.css: every color, step and type size as a custom property on `:root`, with the dark
    /// values under `[data-theme="dark"]`. A board opts into the dark variant on its root.
    public func css() -> String {
        var light: [String] = []
        var dark: [String] = []
        for color in colors {
            light.append("  \(Self.cssName(color.name)): \(color.value);")
            if let value = color.dark { dark.append("  \(Self.cssName(color.name)): \(value);") }
        }
        for step in spacing + radii { light.append("  \(Self.cssName(step.name)): \(Self.number(step.px))px;") }
        for font in fonts {
            let family = font.family.contains(" ") ? "\"\(font.family)\"" : font.family
            light.append("  \(Self.cssName("font-" + font.name)): \(family)\(font.fallback.map { ", \($0)" } ?? "");")
        }
        for style in type {
            let base = Self.cssName("text-" + style.name)
            light.append("  \(base)-size: \(Self.number(style.size))px;")
            if let weight = style.weight { light.append("  \(base)-weight: \(weight);") }
            if let lineHeight = style.lineHeight { light.append("  \(base)-line-height: \(Self.number(lineHeight));") }
        }
        var out = "/* Generated by Shepherd from tokens.json\(name.map { " (\($0))" } ?? ""). */\n:root {\n"
        out += light.joined(separator: "\n") + "\n}\n"
        if !dark.isEmpty { out += "[data-theme=\"dark\"] {\n" + dark.joined(separator: "\n") + "\n}\n" }
        return out
    }

    /// The first line of a stylesheet Shepherd generated: a tokens.css starting with it may be
    /// rewritten when the tokens change; one the author wrote is left alone.
    public static let generatedMarker = "/* Generated by Shepherd from tokens.json"

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    /// The tokens as Tweak and the board check read them: each color (and its dark value) by
    /// its custom property, and the spacing, radius and type sizes by role.
    public var designTokens: DesignTokens {
        var colorTokens: [DesignTokens.Color] = []
        for color in colors {
            if let hex = DesignTokens.normalizedHex(color.value) { colorTokens.append(.init(name: Self.cssName(color.name), hex: hex)) }
        }
        var lengths: [DesignTokens.Length] = []
        lengths += spacing.map { .init(name: Self.cssName($0.name.hasPrefix("--") ? $0.name : "space-" + Self.tail($0.name)), px: $0.px) }
        lengths += radii.map { .init(name: Self.cssName($0.name.hasPrefix("--") ? $0.name : "radius-" + Self.tail($0.name)), px: $0.px) }
        lengths += type.map { .init(name: Self.cssName("text-" + $0.name) + "-size", px: $0.size) }
        return DesignTokens(colors: colorTokens, lengths: lengths)
    }

    /// `space.4` → `4`: a canvas step's own name.
    private static func tail(_ name: String) -> String {
        name.split(separator: ".").last.map(String.init) ?? name
    }
}

// MARK: - Re-sync

/// What a re-sync changed: tokens whose value or line moved, tokens the source declares that the
/// system didn't have, tokens it no longer declares, and source files that weren't there.
public struct DesignSystemSyncChanges: Hashable, Sendable, Codable {
    public var updated: [String]
    public var added: [String]
    public var removed: [String]
    public var missingFiles: [String]

    public init(updated: [String] = [], added: [String] = [], removed: [String] = [], missingFiles: [String] = []) {
        self.updated = updated
        self.added = added
        self.removed = removed
        self.missingFiles = missingFiles
    }

    public var isEmpty: Bool { updated.isEmpty && added.isEmpty && removed.isEmpty }
}

extension DesignSystemTokens {
    /// The tokens read again from their stylesheets (`declarations`, by file; a file that isn't
    /// there is nil). A color or step whose source is one of those files takes the value and line
    /// it has there now, or leaves when the file no longer declares it. A custom property a file
    /// declares that no token names joins the system: a color for a hex value, a radius or spacing
    /// step for a px or rem length, by its name. Type, fonts and components are the author's and
    /// stay as they are.
    public func resynced(from declarations: [String: [DesignCSSDeclaration]?]) -> (DesignSystemTokens, DesignSystemSyncChanges) {
        var next = self
        var changes = DesignSystemSyncChanges()
        changes.missingFiles = declarations.filter { $0.value == nil }.keys.sorted()
        let read = declarations.compactMapValues { $0 }
        func latest(_ name: String, in file: String) -> DesignCSSDeclaration? {
            read[file]?.last { $0.name == name }
        }
        var colors: [Color] = []
        for color in self.colors {
            guard let source = color.source, read[source.file] != nil else { colors.append(color); continue }
            guard let found = latest(color.name, in: source.file), DesignSystemCSS.isColor(found.value) else {
                changes.removed.append(color.name)
                continue
            }
            var copy = color
            copy.value = found.value
            copy.source = Source(file: source.file, line: found.line)
            if copy != color { changes.updated.append(color.name) }
            colors.append(copy)
        }
        func steps(_ list: [Length]) -> [Length] {
            var out: [Length] = []
            for step in list {
                guard let source = step.source, read[source.file] != nil else { out.append(step); continue }
                guard let found = latest(step.name, in: source.file), let px = DesignSystemCSS.px(found.value) else {
                    changes.removed.append(step.name)
                    continue
                }
                var copy = step
                copy.px = px
                copy.source = Source(file: source.file, line: found.line)
                if copy != step { changes.updated.append(step.name) }
                out.append(copy)
            }
            return out
        }
        var spacing = steps(self.spacing)
        var radii = steps(self.radii)
        var known = Set(colors.map(\.name) + spacing.map(\.name) + radii.map(\.name) + changes.removed)
        known.formUnion(type.map(\.name))
        for file in read.keys.sorted() {
            for found in read[file] ?? [] where !known.contains(found.name) {
                let source = Source(file: file, line: found.line)
                if DesignSystemCSS.isHex(found.value) {
                    colors.append(Color(name: found.name, value: found.value, source: source))
                } else if let px = DesignSystemCSS.px(found.value) {
                    switch DesignTokens.role(of: found.name) {
                    case .radius: radii.append(Length(name: found.name, px: px, source: source))
                    case .spacing, nil: spacing.append(Length(name: found.name, px: px, source: source))
                    case .text: continue
                    }
                } else {
                    continue
                }
                known.insert(found.name)
                changes.added.append(found.name)
            }
        }
        next.colors = colors
        next.spacing = spacing
        next.radii = radii
        return (next, changes)
    }
}

// MARK: - Stylesheets

/// One custom property declared in a stylesheet: `--accent: #4f46e5` on line 8 of tokens.css.
public struct DesignCSSDeclaration: Hashable, Sendable, Codable {
    public var name: String
    public var value: String
    public var file: String
    public var line: Int

    public init(name: String, value: String, file: String, line: Int) {
        self.name = name
        self.value = value
        self.file = file
        self.line = line
    }

    /// "--accent #4f46e5 · tokens.css:8", as a system's page lists it.
    public var label: String {
        "\(name) \(value) · \(DesignSystemTokens.Source(file: file, line: line).label)"
    }
}

/// Reading and checking what stylesheets and tokens hold.
public enum DesignSystemCSS {
    /// Every custom property `css` declares, in order, with the line its name is on. Comments
    /// are skipped; a value is trimmed and loses `!important`.
    public static func declarations(_ css: String, file: String) -> [DesignCSSDeclaration] {
        let text = Array(css.unicodeScalars)
        var out: [DesignCSSDeclaration] = []
        var line = 1
        var i = 0
        func at(_ index: Int) -> Unicode.Scalar? { index < text.count ? text[index] : nil }
        func isNameScalar(_ s: Unicode.Scalar) -> Bool {
            (s.isASCII && (CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_")) || !s.isASCII
        }
        // Where a declaration may start: after `{`, `;` or the start, skipping space.
        var canStart = true
        while i < text.count {
            let s = text[i]
            if s == "/", at(i + 1) == "*" {
                i += 2
                while i < text.count, !(text[i] == "*" && at(i + 1) == "/") {
                    if text[i] == "\n" { line += 1 }
                    i += 1
                }
                i += 2
                continue
            }
            if s == "\n" { line += 1; i += 1; continue }
            if s == " " || s == "\t" || s == "\r" { i += 1; continue }
            if s == "{" || s == ";" || s == "}" { canStart = true; i += 1; continue }
            if canStart, s == "-", at(i + 1) == "-" {
                let start = i
                let startLine = line
                var j = i + 2
                while j < text.count, isNameScalar(text[j]) { j += 1 }
                var k = j
                while k < text.count, text[k] == " " || text[k] == "\t" { k += 1 }
                if k > start + 2, at(k) == ":" {
                    let name = String(String.UnicodeScalarView(text[start..<j]))
                    var v = k + 1
                    var depth = 0
                    var value = String.UnicodeScalarView()
                    while v < text.count {
                        let c = text[v]
                        if c == "(" { depth += 1 }
                        if c == ")" { depth = max(0, depth - 1) }
                        if depth == 0, c == ";" || c == "}" || c == "{" { break }
                        if c == "/", at(v + 1) == "*" { break }
                        if c == "\n" { line += 1 }
                        value.append(c)
                        v += 1
                    }
                    var trimmed = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.lowercased().hasSuffix("!important") {
                        trimmed = String(trimmed.dropLast("!important".count)).trimmingCharacters(in: .whitespaces)
                    }
                    if !trimmed.isEmpty { out.append(DesignCSSDeclaration(name: name, value: trimmed, file: file, line: startLine)) }
                    i = v
                    canStart = false
                    continue
                }
            }
            canStart = false
            i += 1
        }
        return out
    }

    /// A hex color (`#abc`, `#aabbcc`, `#aabbccdd`).
    public static func isHex(_ value: String) -> Bool { DesignTokens.normalizedHex(value) != nil }

    /// A color a token may hold: a hex, a color function (`rgb`, `rgba`, `hsl`, `hsla`, `hwb`,
    /// `lab`, `lch`, `oklab`, `oklch`, `color`) with nothing inside that could break out, or a
    /// named color.
    public static func isColor(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        if isHex(text) { return true }
        guard !text.isEmpty, text.utf8.count <= DesignSystemTokens.maxValueLength, isSafeValue(text) else { return false }
        let lower = text.lowercased()
        if let open = lower.firstIndex(of: "("), lower.hasSuffix(")") {
            let function = lower[..<open]
            let inside = lower[lower.index(after: open)..<lower.index(before: lower.endIndex)]
            let functions: Set<Substring> = ["rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color"]
            return functions.contains(function) && !inside.contains("(") && !inside.contains(")")
                && inside.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || " .,%/-+#".unicodeScalars.contains($0)) }
        }
        return lower.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.lowercaseLetters.contains($0) } && lower.count <= 24
    }

    /// Text safe to set in a declaration Shepherd writes: no `;`, braces, angle brackets,
    /// backslash, comment opener or line break.
    public static func isSafeValue(_ value: String) -> Bool {
        value.utf8.count <= 200 && !value.contains("/*")
            && !value.unicodeScalars.contains { ";{}<>\\\n\r".unicodeScalars.contains($0) || $0.value < 0x20 }
    }

    /// `24px`, `1.5rem` (16px to the rem) or `0` as px; nil for anything else.
    public static func px(_ value: String) -> Double? {
        let text = value.trimmingCharacters(in: .whitespaces).lowercased()
        if text == "0" { return 0 }
        if text.hasSuffix("px"), let number = Double(text.dropLast(2)), number.isFinite, number >= 0 { return number }
        if text.hasSuffix("rem"), let number = Double(text.dropLast(3)), number.isFinite, number >= 0 { return number * 16 }
        return nil
    }

    /// `Ns.Component`, at any depth: identifiers joined by dots, never a prototype's own names.
    public static func isGlobalPath(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...6).contains(parts.count), value.utf8.count <= 120 else { return false }
        let banned: Set<Substring> = ["__proto__", "prototype", "constructor"]
        return parts.allSatisfy { part in
            guard let first = part.unicodeScalars.first, !banned.contains(part),
                  first == "_" || first == "$" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
            return part.unicodeScalars.allSatisfy { $0 == "_" || $0 == "$" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
        }
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
