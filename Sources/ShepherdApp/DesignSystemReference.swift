import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdUI

/// The built-in design system's page as plain values (DesignSystemPage, DesignSystemColors,
/// DesignSystemType, DesignSystemSpacing, DesignSystemSizes, DesignSystemComponents): its tokens
/// grouped as the boards group them, the sizes the app lays out with, how many components the
/// catalog draws, and the designs using it. Derived from the system's own tokens, never from
/// strings in a view. Read-only: the boards' edit and Add controls are departures.
struct DesignSystemReference: Equatable {
    struct ColorRow: Equatable, Identifiable {
        var id: String { name }
        let name: String
        /// The light and dark values as written.
        let light: String
        let dark: String
        /// Contrast against `--bg-window` of the same variant, for the text tokens.
        let lightRatio: Double?
        let darkRatio: Double?
    }

    struct ColorGroup: Equatable, Identifiable {
        var id: String { title }
        let title: String
        let hint: String
        let rows: [ColorRow]
    }

    struct TypeRow: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let family: String
        let size: Double
        let weight: Int
        let uppercase: Bool
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
        /// What a radius is for ("pills, keycaps"); empty for a step with no note.
        let use: String
    }

    struct Size: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let px: Double
        let use: String
    }

    struct Used: Equatable, Identifiable {
        let id: DesignID
        let name: String
        let boards: Int
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
    var colors: [ColorGroup] = []
    var type: [TypeGroup] = []
    var spacing: [Step] = []
    var radii: [Step] = []
    var sizes: [Size] = []
    var components = 0
    var used: [Used] = []

    var colorCount: Int { colors.reduce(0) { $0 + $1.rows.count } }
    var typeCount: Int { type.reduce(0) { $0 + $1.rows.count } }

    /// A part's count in the contents menu; nil where the board draws none.
    func count(_ part: Part) -> Int? {
        switch part {
        case .overview, .voice: nil
        case .principles: DesignSystemCopy.principles.count
        case .colors: colorCount
        case .typography: typeCount
        case .spacing: spacing.count
        case .radius: radii.count
        case .size: sizes.count
        case .components: components
        }
    }

    /// The text a token must reach to be readable, from WCAG AA.
    static let readable = 4.5

    @MainActor
    static func make(tokens: DesignSystemTokens, namespace: String, designs: [DesignSystemPageModel.BoardsRow],
                     components: Int) -> DesignSystemReference {
        var reference = DesignSystemReference()
        reference.namespace = namespace
        reference.title = DesignSystemCopy.name
        reference.components = components
        reference.used = designs.map { Used(id: $0.id, name: $0.name, boards: $0.count) }

        let window = tokens.colors.first { $0.name == "--bg-window" }
        let rows = tokens.colors.map { color -> ColorRow in
            let measured = Self.measured.contains(color.name)
            let dark = color.dark ?? color.value
            return ColorRow(name: color.name, light: color.value, dark: dark,
                            lightRatio: measured ? window.flatMap { Self.ratio(color.value, on: $0.value) } : nil,
                            darkRatio: measured ? window.flatMap { Self.ratio(dark, on: $0.dark ?? $0.value) } : nil)
        }
        reference.colors = DesignSystemCopy.colorGroups.compactMap { group in
            let members = rows.filter { DesignSystemCopy.group(of: $0.name) == group.title }
            return members.isEmpty ? nil : ColorGroup(title: group.title, hint: group.hint, rows: members)
        }

        let styles = tokens.type.map { style -> TypeRow in
            let family = style.family.flatMap { name in tokens.fonts.first { $0.name == name }?.family ?? name } ?? "Geist"
            return TypeRow(name: style.name, family: family, size: style.size, weight: style.weight ?? 400,
                           uppercase: style.transform == "uppercase",
                           tag: "\(family) · \(Self.number(style.size)) / \(style.weight ?? 400)")
        }
        reference.type = [("Display", styles.filter { DesignSystemCopy.display.contains($0.name) }),
                          ("Text", styles.filter { !DesignSystemCopy.display.contains($0.name) && !$0.family.contains("Mono") }),
                          ("Mono", styles.filter { !DesignSystemCopy.display.contains($0.name) && $0.family.contains("Mono") })]
            .filter { !$1.isEmpty }.map { TypeGroup(title: $0, rows: $1) }

        reference.spacing = tokens.spacing.map { Step(name: $0.name, px: $0.px, use: "") }
        reference.radii = tokens.radii.map { Step(name: $0.name, px: $0.px, use: DesignSystemCopy.radiusUse[$0.name] ?? "") }
        reference.sizes = Self.sizes()
        return reference
    }

    /// The text tokens measured against `--bg-window`.
    static let measured: Set<String> = ["--text-primary", "--text-secondary", "--text-tertiary"]

    /// The contrast of `foreground` over `background`, nil when either is not a plain color.
    static func ratio(_ foreground: String, on background: String) -> Double? {
        guard let fore = HexColor(foreground), let back = HexColor(background) else { return nil }
        return fore.contrast(with: back)
    }

    /// The controls and columns the app lays out with, from the code that sets them.
    @MainActor
    static func sizes() -> [Size] {
        [Size(name: "control", px: NWSettingsControlMetrics.controlHeight, use: "Buttons and popups"),
         Size(name: "field", px: NWSettingsControlMetrics.fieldHeight, use: "Text fields and steppers"),
         Size(name: "segment", px: NWSettingsControlMetrics.segmentHeight, use: "Segmented control"),
         Size(name: "row", px: NW.Height.row, use: "Sidebar and list rows"),
         Size(name: "rail", px: AppLayout.settingsNavWidth, use: "Settings navigation"),
         Size(name: "thread", px: AppLayout.threadMaxWidth, use: "Thread column, most"),
         Size(name: "prose", px: AppLayout.proseMaxWidth, use: "Agent prose, most")]
    }

    /// 28 as "28", 13.5 as "13.5".
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// The page's authored words: the design's own copy for the built-in system (DesignSystemPage).
/// Everything that is a count or a value is derived instead.
enum DesignSystemCopy {
    /// What this page calls the built-in system, as the boards do. The system's registered title
    /// (`NightWatchSystem.title`, "Night Watch") is stored in designs that install it and is not changed; the
    /// Designs page, New design's card and the system's menu still use it.
    static let name = "Shepherd UI"

    static let tagline = "The app’s own components and tokens. Quiet chrome around agents at work."

    /// The lead, with the catalog's real count and the system's own folder.
    static func lead(components: Int, namespace: String) -> String {
        "This is what the Shepherd app draws with: the colors, type and spacing of its native views, and the \(components) components below. Designs link its tokens once, from ds/\(namespace)/tokens.css."
    }

    /// What the code guarantees of this system: the app registers it at launch from its Night Watch tokens, and the
    /// server refuses to write, rename, delete or re-sync a built-in.
    static let provenance = "Built into Shepherd from its Night Watch tokens each time the app launches. It is read-only and never synced from a project."

    static let principles: [(lead: String, text: String)] = [
        ("Readable measure.", "The thread column is at most 820pt and agent prose 640pt."),
        ("Shape, not labels.", "No speaker labels or avatars: your turn is a bubble, the agent’s is unboxed prose."),
        ("One quiet line per burst.", "Consecutive calls of one kind merge into one activity line."),
        ("Nothing in the thread spins.", "One thing moves at a time, and it is text."),
        ("Lantern means you.", "Amber marks the primary action and what needs you. Running blue marks work, links and focus."),
        ("Honest affordances.", "Never draw a control that does nothing or a shortcut that isn’t wired."),
    ]

    static let voiceLead = "Write like an engineer handing over work: plain, specific and short. The agent does things; Shepherd reports them."
    static let say = ["“The agent needs an answer about the retry schedule.”", "“Tests failed twice. Open the log?”", "“Fix pay button jump”"]
    static let avoid = ["“pi is waiting for your input!”", "“Oops! Something went wrong.”", "“New chat 3”"]
    static let voiceNotes = ["Sentence case in drawn UI, Title Case in native menus.",
                             "Say “the agent”, never “pi”, except where your own pi is the subject.",
                             "Status is a dot or glyph plus a word. Color is never the only signal."]

    /// A type style's preview words.
    static let sample = "The agent finished the refund ledger"
    static let microSample = "Section labels and counts"
    static let display: Set<String> = ["display", "title", "headline"]
    static let radiusUse = ["--radius-xs": "pills, keycaps", "--radius-s": "buttons, fields, rows",
                            "--radius-m": "cards, composer, code", "--radius-l": "popovers, sheets"]

    static let colorGroups: [(title: String, hint: String)] = [
        ("Surfaces", "Chrome, thread, cards and code"), ("Lines", "Hairlines, never shadows"),
        ("Text", "Measured against --bg-window"), ("Brand and state", "Lantern is you, blue is work"),
        ("Syntax", "Code blocks and diffs"),
    ]

    /// The group a color token belongs to: by its name's prefix, else brand and state.
    static func group(of name: String) -> String {
        if name.hasPrefix("--bg-") { return "Surfaces" }
        if name.hasPrefix("--line-") { return "Lines" }
        if name.hasPrefix("--syn-") { return "Syntax" }
        if ["--text-primary", "--text-secondary", "--text-tertiary"].contains(name) { return "Text" }
        return "Brand and state"
    }
}
