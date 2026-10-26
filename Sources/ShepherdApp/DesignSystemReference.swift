import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A design system's page as plain values (DesignSystemPage, DesignSystemColors, DesignSystemType,
/// DesignSystemSpacing, DesignSystemSizes, DesignSystemComponents), for any system: its tokens grouped as
/// the boards group them, each text color's contrast, the components that have a specimen, the designs
/// drawn in it, and the page copy the system carries in its tokens.json (`page`: a tagline, a summary,
/// principles, voice and sizes). A part the system has nothing for is left out. Derived from the system's
/// own files, never from strings in a view. Read-only: the boards' Edit and Add are departures.
struct DesignSystemReference: Equatable {
    struct ColorRow: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// The light and dark values as written (the light one when it names no dark).
        let light: String
        let dark: String
        /// Contrast against what the color is read on, in the same variant, for a text color.
        let lightRatio: Double?
        let darkRatio: Double?
    }

    struct ColorGroup: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let hint: String?
        let rows: [ColorRow]
    }

    struct TypeRow: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// The face it names, nil when it names none.
        let family: String?
        let size: Double
        let weight: Int
        let uppercase: Bool
        /// The words it is shown in: its own sample, else the page's.
        let sample: String
        /// "Geist · 28 / 600".
        let tag: String
    }

    struct TypeGroup: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let rows: [TypeRow]
    }

    struct Step: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let px: Double
        /// What it is for ("pills, keycaps"), from the token's `use`; empty when it says nothing.
        let use: String
    }

    struct Size: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// As written ("32px").
        let value: String
        let use: String
    }

    struct Used: Equatable, Identifiable {
        let id: DesignID
        let name: String
        let boards: Int
    }

    /// A component the page draws: one with a specimen, by its place in the system's list (what its
    /// specimen image is kept by).
    struct Component: Equatable, Identifiable {
        let id: Int
        let name: String
        /// The global its bundle mounts it by ("Shepherd.SettingsButton").
        let export: String?
        let group: String?
    }

    struct Principle: Equatable {
        let lead: String
        let text: String
    }

    struct Example: Equatable {
        let say: String
        let avoid: String
    }

    /// One of the hero's six tiles: a color of the system in each variant.
    struct Tile: Equatable {
        let light: String
        let dark: String
    }

    /// A part of the page the contents menu scrolls to.
    enum Part: String, CaseIterable, Identifiable {
        case overview, principles, voice, colors, typography, spacing, radius, size, components
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .principles: "Principles"
            case .voice: "Voice"
            case .colors: "Colors"
            case .typography: "Typography"
            case .spacing: "Spacing"
            case .radius: "Corner radius"
            case .size: "Size"
            case .components: "Components"
            }
        }
    }

    var namespace = ""
    var title = ""
    var tagline: String?
    var summary: String?
    /// Where the system says it came from ("Made in Shepherd chat UI from the app's Shepherd Design values."); nil when
    /// it says nothing, and the page says what Shepherd knows instead (its project, its stylesheets).
    var source: String?
    var principles: [Principle] = []
    var voiceLead: String?
    var examples: [Example] = []
    var voiceRules: [String] = []
    /// The hero's six tiles in the boards' order (the big tile first); nil where the system has no color for one.
    var tiles: [Tile?] = []
    var colors: [ColorGroup] = []
    /// "Geist and Geist Mono": the faces the system names.
    var faces: String?
    var type: [TypeGroup] = []
    var spacing: [Step] = []
    var radii: [Step] = []
    var sizes: [Size] = []
    /// The components with a specimen, in the system's order.
    var components: [Component] = []
    /// Every component the system lists, with a specimen or not.
    var componentTotal = 0
    var componentGroups: [String] = []
    var used: [Used] = []

    var colorCount: Int { colors.reduce(0) { $0 + $1.rows.count } }
    var typeCount: Int { type.reduce(0) { $0 + $1.rows.count } }
    var hasVoice: Bool { voiceLead != nil || !examples.isEmpty || !voiceRules.isEmpty }

    /// The parts this system has, in the page's order: the overview always, the rest when there is something in them.
    var parts: [Part] {
        Part.allCases.filter { part in
            switch part {
            case .overview: true
            case .principles: !principles.isEmpty
            case .voice: hasVoice
            case .colors: colorCount > 0
            case .typography: typeCount > 0
            case .spacing: !spacing.isEmpty
            case .radius: !radii.isEmpty
            case .size: !sizes.isEmpty
            case .components: componentTotal > 0
            }
        }
    }

    /// A part's count in the contents menu; nil where the board draws none.
    func count(_ part: Part) -> Int? {
        switch part {
        case .overview, .voice: nil
        case .principles: principles.count
        case .colors: colorCount
        case .typography: typeCount
        case .spacing: spacing.count
        case .radius: radii.count
        case .size: sizes.count
        case .components: componentTotal
        }
    }

    /// The card heads' sub lines, from the data.
    var colorsSub: String {
        let both = colors.contains { $0.rows.contains { $0.dark != $0.light } }
        return "\(Self.plural(colorCount, "token"))" + (both ? " · light and dark" : "")
    }

    var typographySub: String { [faces, Self.plural(typeCount, "style")].compactMap { $0 }.joined(separator: " · ") }
    var spacingSub: String { Self.range(spacing) }
    var radiusSub: String { Self.range(radii) }
    var sizeSub: String { Self.plural(sizes.count, "size") }
    var componentsSub: String { "\(componentTotal) in \(title), drawn live" }

    /// Under the components when some have no specimen: "Showing 5 of 193, the ones with a specimen."
    var componentsShown: String? {
        components.count < componentTotal ? "Showing \(components.count) of \(componentTotal), the ones with a specimen." : nil
    }

    /// The text a token must reach to be readable, from WCAG AA.
    static let readable = 4.5

    static func make(title: String, namespace: String, tokens: DesignSystemTokens?, designs: [DesignSystemPageModel.BoardsRow]) -> DesignSystemReference {
        var reference = DesignSystemReference()
        reference.namespace = namespace
        reference.title = title
        reference.used = designs.map { Used(id: $0.id, name: $0.name, boards: $0.count) }
        guard let tokens else { return reference }

        let page = tokens.extra["page"]
        reference.tagline = text(page?["tagline"], limit: 200)
        reference.summary = text(page?["summary"], limit: 1_200)
        reference.source = text(page?["source"], limit: 300)
        reference.principles = list(page?["principles"]).compactMap { item in
            text(item["lead"], limit: 120).map { Principle(lead: $0, text: text(item["text"], limit: 600) ?? "") }
        }
        let voice = page?["voice"]
        reference.voiceLead = text(voice?["lead"], limit: 600)
        reference.examples = list(voice?["examples"]).compactMap { item in
            guard let say = text(item["say"], limit: 200), let avoid = text(item["avoid"], limit: 200) else { return nil }
            return Example(say: say, avoid: avoid)
        }
        reference.voiceRules = list(voice?["rules"]).compactMap { text($0, limit: 300) }
        reference.sizes = list(page?["sizes"], max: 64).compactMap { item in
            guard let name = text(item["name"], limit: 64), let value = text(item["value"], limit: 32) else { return nil }
            return Size(name: name, value: value, use: text(item["use"], limit: 120) ?? "")
        }

        reference.tiles = tiles(tokens.colors)
        reference.colors = colorGroups(tokens.colors, background: DesignSystemPresentation.background(tokens))

        let families = tokens.fonts.map(\.family)
        let named = families.isEmpty ? orderedUnique(tokens.type.compactMap(\.family)) : orderedUnique(families)
        reference.faces = named.isEmpty ? nil : ListFormatter.localizedString(byJoining: named)
        let styles = tokens.type.map { style -> TypeRow in
            let family = style.family.map { name in tokens.fonts.first { $0.name == name }?.family ?? name }
            let weight = style.weight ?? 400
            let uppercase = style.transform == "uppercase"
            let sample = text(style.sample.map(JSONValue.string), limit: 120) ?? (uppercase ? Copy.microSample : Copy.sample)
            return TypeRow(name: style.name, family: family, size: style.size, weight: weight, uppercase: uppercase,
                           sample: uppercase ? sample.uppercased() : sample,
                           tag: [family, "\(number(style.size)) / \(weight)"].compactMap { $0 }.joined(separator: " · "))
        }
        reference.type = [("Display", styles.filter { Copy.display.contains($0.name) }),
                          ("Text", styles.filter { !Copy.display.contains($0.name) && !Self.isMono($0) }),
                          ("Mono", styles.filter { !Copy.display.contains($0.name) && Self.isMono($0) })]
            .filter { !$1.isEmpty }.map { TypeGroup(title: $0, rows: $1) }

        reference.spacing = tokens.spacing.map { Step(name: $0.name, px: $0.px, use: text($0.extra["use"], limit: 120) ?? "") }
        reference.radii = tokens.radii.map { Step(name: $0.name, px: $0.px, use: text($0.extra["use"], limit: 120) ?? "") }

        reference.componentTotal = tokens.components.count
        reference.components = tokens.components.enumerated().compactMap { index, component in
            component.specimen == nil ? nil
                : Component(id: index, name: component.name, export: component.export, group: text(component.extra["group"], limit: 64))
        }
        reference.componentGroups = orderedUnique(reference.components.compactMap(\.group))
        return reference
    }

    private static func isMono(_ style: TypeRow) -> Bool { style.family?.localizedCaseInsensitiveContains("mono") == true }

    // MARK: Colors

    /// The boards' groups (the design's own page rules, by the token's name), then whatever none of them takes.
    static func colorGroups(_ colors: [DesignSystemTokens.Color], background: DesignSystemPresentation.Swatch?) -> [ColorGroup] {
        let window = colors.first { $0.name == "--bg-window" }
        let windowName = window?.name ?? colors.first { DesignSystemPresentation.hex($0.value) == background?.light }?.name
        let rows = colors.map { color -> ColorRow in
            let dark = color.dark ?? color.value
            let base = against(color.name, in: colors) ?? window.map { (light: $0.value, dark: $0.dark ?? $0.value) }
                ?? background.map { (light: $0.light, dark: $0.dark) }
            let measured = words(color.name).contains("text") && base != nil
            return ColorRow(name: color.name, light: color.value, dark: dark,
                            lightRatio: measured ? base.flatMap { ratio(color.value, on: $0.light) } : nil,
                            darkRatio: measured ? base.flatMap { ratio(dark, on: $0.dark) } : nil)
        }
        var taken = Set<String>()
        var groups: [ColorGroup] = Copy.colorGroups.compactMap { group in
            let members = rows.filter { !taken.contains($0.name) && group.matches($0.name) }
            members.forEach { taken.insert($0.name) }
            guard !members.isEmpty else { return nil }
            let hint = group.title == "Text" ? windowName.map { "Measured against \($0)" } : group.hint
            return ColorGroup(title: group.title, hint: hint, rows: members)
        }
        let rest = rows.filter { !taken.contains($0.name) }
        if !rest.isEmpty { groups.append(ColorGroup(title: "Other", hint: nil, rows: rest)) }
        return groups
    }

    /// What `--text-on-<x>` is read on: `--<x>`, in each variant. Nil for any other name.
    private static func against(_ name: String, in colors: [DesignSystemTokens.Color]) -> (light: String, dark: String)? {
        guard name.hasPrefix("--text-on-") else { return nil }
        let on = "--" + name.dropFirst("--text-on-".count)
        return colors.first { $0.name == on }.map { (light: $0.value, dark: $0.dark ?? $0.value) }
    }

    /// The hero's six tiles (DesignSystemPage): the boards' roles by name, else a color whose name says the role,
    /// else the system's next colors.
    static func tiles(_ colors: [DesignSystemTokens.Color]) -> [Tile?] {
        let drawable = colors.compactMap { color -> (name: String, tile: Tile)? in
            guard let light = DesignSystemPresentation.hex(color.value) else { return nil }
            return (color.name, Tile(light: light, dark: color.dark.flatMap(DesignSystemPresentation.hex) ?? light))
        }
        var used = Set<String>()
        var tiles: [Tile?] = Copy.tileRoles.map { role in
            let found = drawable.first { $0.name == role.name }
                ?? drawable.filter { !used.contains($0.name) && !Set(words($0.name)).isDisjoint(with: role.words) }
                    .min { $0.name.count < $1.name.count }
            guard let found, !used.contains(found.name) else { return nil }
            used.insert(found.name)
            return found.tile
        }
        var rest = drawable.filter { !used.contains($0.name) }.makeIterator()
        for index in tiles.indices where tiles[index] == nil { tiles[index] = rest.next()?.tile }
        return tiles
    }

    /// The contrast of `foreground` over `background`, nil when either is not a plain color.
    static func ratio(_ foreground: String, on background: String) -> Double? {
        guard let fore = DesignSystemPresentation.hex(foreground).flatMap(HexColor.init),
              let back = DesignSystemPresentation.hex(background).flatMap(HexColor.init) else { return nil }
        return fore.contrast(with: back)
    }

    // MARK: Words

    /// 28 as "28", 13.5 as "13.5".
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    /// "2 to 32px", "8px".
    private static func range(_ steps: [Step]) -> String {
        guard let low = steps.map(\.px).min(), let high = steps.map(\.px).max() else { return "" }
        return low == high ? "\(number(low))px" : "\(number(low)) to \(number(high))px"
    }

    private static func words(_ name: String) -> [String] {
        name.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    /// A string of the system's page copy: trimmed, cut to `limit` characters; nil when blank or not a string.
    private static func text(_ value: JSONValue?, limit: Int) -> String? {
        guard let raw = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return String(raw.prefix(limit))
    }

    /// A list of the system's page copy, at most `max` items.
    private static func list(_ value: JSONValue?, max: Int = 24) -> [JSONValue] { Array((value?.arrayValue ?? []).prefix(max)) }

    /// The page's own words, the same for every system (the design's page component): the type samples, the
    /// display styles, the color groups and their hints, and the roles of the hero's tiles.
    enum Copy {
        static let sample = "The agent finished the refund ledger"
        static let microSample = "Section labels and counts"
        static let display: Set<String> = ["display", "title", "headline"]

        struct Group {
            let title: String
            let hint: String?
            /// The name prefixes it takes, after the leading `--`.
            let prefixes: [String]
            func matches(_ name: String) -> Bool { prefixes.contains { name.hasPrefix("--" + $0) } }
        }

        static let colorGroups = [
            Group(title: "Surfaces", hint: "Chrome, thread, cards and code", prefixes: ["bg-"]),
            Group(title: "Lines", hint: "Hairlines, never shadows", prefixes: ["line-"]),
            Group(title: "Text", hint: nil, prefixes: ["text-primary", "text-secondary", "text-tertiary"]),
            Group(title: "Brand and state", hint: "Lantern is you, blue is work",
                  prefixes: ["lantern", "running", "done", "failed", "text-on-"]),
            Group(title: "Syntax", hint: "Code blocks and diffs", prefixes: ["syn-"]),
        ]

        /// The hero's tiles in order: the big tile, the tall one, the small one at the top, the tall bordered one,
        /// and the two small ones at the bottom, each by its name in Shepherd UI and the words that say its role.
        static let tileRoles: [(name: String, words: Set<String>)] = [
            ("--lantern", ["accent", "primary", "brand"]),
            ("--running", ["running", "info", "link"]),
            ("--done", ["done", "success", "ok", "positive"]),
            ("--bg-raised", ["raised", "surface", "card", "panel"]),
            ("--lantern-tint", ["tint", "soft", "subtle"]),
            ("--failed", ["failed", "danger", "error"]),
        ]
    }
}
