import Foundation
import ShepherdProtocol

// The Tweak tab's controls (DZTweak; docs/designs.md › Tweak), worked out from the selected
// element's inline style, the board's data-props and the design's tokens. Pure, so the rules
// are tested without a board.

/// A style a tweak changes on the selected element: the fixed set the plan starts with (flex
/// layout, padding, radius, color, text size).
enum DesignTweakProperty: String, CaseIterable, Hashable, Sendable {
    case direction, gap, padding, radius, fill, color, textSize

    /// The token role its lengths snap to.
    var role: DesignTokens.Role? {
        switch self {
        case .gap, .padding: .spacing
        case .radius: .radius
        case .textSize: .text
        case .direction, .fill, .color: nil
        }
    }
}

/// A color a chip offers: a design token, or a swatch a board's data-props lists.
struct DesignTweakColor: Hashable, Sendable, Identifiable {
    /// What the chip says: the token's name without dashes, or the swatch's hex.
    let title: String
    /// The custom property (`--accent`), when it is a token.
    let token: String?
    let hex: String

    var id: String { token ?? hex }
}

/// One row of the Tweak tab.
struct DesignTweakRow: Hashable, Sendable, Identifiable {
    enum ID: Hashable, Sendable {
        case style(DesignTweakProperty)
        case prop(String)
    }

    enum Control: Hashable, Sendable {
        /// A slider over a scale's steps; `index` is the step shown.
        case steps(values: [Double], index: Int)
        /// A slider over numbers, `min`…`max` by `step`.
        case slider(value: Double, min: Double, max: Double, step: Double)
        /// A segmented picker (2–4 options): each option's value and its title.
        case choice(options: [Choice], selected: String?)
        /// A menu of options, for more than a picker holds.
        case menu(options: [Choice], selected: String?)
        case colors([DesignTweakColor], selected: String?)
        case toggle(Bool)
        case stepper(Int)
        case text(String)
    }

    struct Choice: Hashable, Sendable {
        let value: String
        let title: String
    }

    let id: ID
    let label: String
    let control: Control
}

struct DesignTweakGroup: Hashable, Sendable, Identifiable {
    let title: String
    let rows: [DesignTweakRow]

    var id: String { title }
}

enum DesignTweakControls {
    // MARK: Style

    /// The rows the selected element's inline style offers, grouped as DZTweak groups them:
    /// Layout (direction and gap for a flex or grid container, padding, radius), Color (a fill
    /// for a shape or a filled element, the text's color), and Text (its size). A value the
    /// board's logic sets is left out, and so is every color when the design has no color tokens.
    static func styleGroups(_ style: DesignInlineStyle, kind: DesignElementKind, tokens: DesignTokens) -> [DesignTweakGroup] {
        guard !style.isBoundWhole else { return [] }
        func free(_ property: String) -> Bool { style.declaration(property)?.isBound != true }
        let display = style.value("display")?.lowercased() ?? ""
        let flex = display.contains("flex"), grid = display.contains("grid")
        var layout: [DesignTweakRow] = []
        if flex, free("flex-direction") {
            let current = style.value("flex-direction")?.lowercased() ?? "row"
            layout.append(DesignTweakRow(id: .style(.direction), label: "Direction", control: .choice(
                options: [.init(value: "row", title: "Row"), .init(value: "column", title: "Column")],
                selected: ["row", "column"].contains(current) ? current : nil)))
        }
        if (flex || grid), free("gap") {
            layout.append(steps(.gap, label: "Gap", current: tokens.firstPx(style.value("gap") ?? ""), tokens: tokens))
        }
        if kind != .image, kind != .line, free("padding") {
            layout.append(steps(.padding, label: "Padding", current: tokens.firstPx(style.value("padding") ?? ""), tokens: tokens))
        }
        if kind != .line, free("border-radius") {
            layout.append(radius(current: tokens.firstPx(style.value("border-radius") ?? ""), tokens: tokens))
        }
        var color: [DesignTweakRow] = []
        if !tokens.colors.isEmpty {
            let fill = fillProperty(style)
            let fillValue = style.value(fill)
            let fillIsColor = fillValue.map { tokens.color($0) != nil || DesignTokens.normalizedHex($0) != nil } ?? true
            if kind == .shape || fillValue != nil, fillIsColor, free(fill) {
                color.append(colors(.fill, label: "Fill", current: fillValue, tokens: tokens))
            }
            if kind == .text, free("color") {
                color.append(colors(.color, label: "Text", current: style.value("color"), tokens: tokens))
            }
        }
        var text: [DesignTweakRow] = []
        if kind == .text, free("font-size") {
            text.append(textSize(current: tokens.px(style.value("font-size") ?? ""), tokens: tokens))
        }
        return [("Layout", layout), ("Color", color), ("Text", text)].compactMap { title, rows in
            rows.isEmpty ? nil : DesignTweakGroup(title: title, rows: rows)
        }
    }

    /// Where the fill goes: `background-color` when the element writes it, else `background`.
    static func fillProperty(_ style: DesignInlineStyle) -> String {
        style.declaration("background-color") != nil ? "background-color" : "background"
    }

    /// The CSS property a row writes.
    static func cssProperty(_ property: DesignTweakProperty, style: DesignInlineStyle) -> String {
        switch property {
        case .direction: "flex-direction"
        case .gap: "gap"
        case .padding: "padding"
        case .radius: "border-radius"
        case .fill: fillProperty(style)
        case .color: "color"
        case .textSize: "font-size"
        }
    }

    private static func steps(_ property: DesignTweakProperty, label: String, current: Double?, tokens: DesignTokens) -> DesignTweakRow {
        let values = tokens.scaleOrFallback(property.role ?? .spacing).values
        return DesignTweakRow(id: .style(property), label: label, control: .steps(values: values, index: nearest(current ?? 0, in: values)))
    }

    /// Radius: up to four of the scale's values around the current one, as a segmented picker.
    private static func radius(current: Double?, tokens: DesignTokens) -> DesignTweakRow {
        let values = tokens.scaleOrFallback(.radius).values
        let shown = window(values, around: nearest(current ?? 0, in: values), count: 4)
        return DesignTweakRow(id: .style(.radius), label: "Radius", control: .choice(
            options: shown.map { .init(value: format($0), title: format($0)) },
            selected: current.flatMap { value in shown.contains(value) ? format(value) : nil }))
    }

    /// Text size: three steps of the type scale around the current size, S · M · L.
    private static func textSize(current: Double?, tokens: DesignTokens) -> DesignTweakRow {
        let values = tokens.scaleOrFallback(.text).values
        let shown = window(values, around: nearest(current ?? 14, in: values), count: 3)
        let titles = shown.count == 3 ? ["S", "M", "L"] : shown.map(format)
        return DesignTweakRow(id: .style(.textSize), label: "Text size", control: .choice(
            options: zip(shown, titles).map { .init(value: format($0), title: $1) },
            selected: current.flatMap { value in shown.contains(value) ? format(value) : nil }))
    }

    private static func colors(_ property: DesignTweakProperty, label: String, current: String?, tokens: DesignTokens) -> DesignTweakRow {
        let options = tokens.colors.map { DesignTweakColor(title: $0.title, token: $0.name, hex: $0.hex) }
        return DesignTweakRow(id: .style(property), label: label, control: .colors(options, selected: current.flatMap { tokens.color($0)?.name }))
    }

    /// The index of the scale's value nearest `value`.
    static func nearest(_ value: Double, in values: [Double]) -> Int {
        let snapped = DesignTokens.snap(value, to: values)
        return values.firstIndex(of: snapped) ?? 0
    }

    /// `count` values of `values` around `index`, keeping the window inside the scale.
    static func window(_ values: [Double], around index: Int, count: Int) -> [Double] {
        guard values.count > count else { return values }
        let start = min(max(0, index - (count - 1) / 2), values.count - count)
        return Array(values[start..<(start + count)])
    }

    /// `24`, `1.5`.
    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    // MARK: Writing

    /// What a length writes: the token's `var(--name)` when the board declares one for it, else
    /// px (`24px`).
    static func lengthValue(_ px: Double, role: DesignTokens.Role, boardTokens: DesignTokens) -> String {
        if let token = boardTokens.length(px, role: role) { return "var(\(token.name))" }
        return "\(format(px))px"
    }

    /// What a color writes: the token's `var(--name)` when the board declares it, else its hex.
    static func colorValue(_ color: DesignTweakColor, boardTokens: DesignTokens) -> String {
        if let token = color.token, boardTokens.declares(token) { return "var(\(token))" }
        return color.hex
    }

    // MARK: Props

    /// A board's data-props as rows, grouped by their `section` (in the order first written);
    /// props without one are under "Board".
    static func propGroups(_ editors: [DesignPropEditor], tweaks: [String: JSONValue], tokens: DesignTokens) -> [DesignTweakGroup] {
        var order: [String] = []
        var rows: [String: [DesignTweakRow]] = [:]
        for editor in editors {
            let section = editor.section?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Board"
            guard let row = propRow(editor, value: DesignProps.value(of: editor, tweaks: tweaks), tokens: tokens) else { continue }
            if rows[section] == nil { order.append(section) }
            rows[section, default: []].append(row)
        }
        return order.map { DesignTweakGroup(title: $0, rows: rows[$0] ?? []) }
    }

    static func propRow(_ editor: DesignPropEditor, value: JSONValue?, tokens: DesignTokens) -> DesignTweakRow? {
        let control: DesignTweakRow.Control
        switch editor.kind {
        case .boolean:
            control = .toggle(value?.boolValue ?? false)
        case .choice:
            let options = editor.options.compactMap { option -> DesignTweakRow.Choice? in
                guard let text = option.stringValue ?? option.doubleValue.map(format) else { return nil }
                return .init(value: text, title: text)
            }
            guard !options.isEmpty else { return nil }
            let selected = value?.stringValue ?? value?.doubleValue.map(format)
            control = options.count <= 4 ? .choice(options: options, selected: selected) : .menu(options: options, selected: selected)
        case .int, .float, .range:
            let number = value?.doubleValue ?? editor.min ?? 0
            if let min = editor.min, let max = editor.max, max > min {
                let step = editor.step.flatMap { $0 > 0 ? $0 : nil } ?? (editor.kind == .int ? 1 : (max - min) / 100)
                control = .slider(value: Swift.min(max, Swift.max(min, number)), min: min, max: max, step: step)
            } else if editor.kind == .int {
                control = .stepper(Int(number.rounded()))
            } else {
                control = .text(format(number))
            }
        case .text:
            control = .text(value?.stringValue ?? "")
        case .color:
            let swatches = editor.options.compactMap { $0.stringValue.flatMap(DesignTokens.normalizedHex) }
            let options = swatches.isEmpty
                ? tokens.colors.map { DesignTweakColor(title: $0.title, token: $0.name, hex: $0.hex) }
                : swatches.map { DesignTweakColor(title: $0, token: nil, hex: $0) }
            guard !options.isEmpty else { return nil }
            let current = value?.stringValue.flatMap(DesignTokens.normalizedHex)
            control = .colors(options, selected: options.first { $0.hex == current }?.id)
        }
        return DesignTweakRow(id: .prop(editor.name), label: label(editor.name), control: control)
    }

    /// A prop's name as a label: `showCounts` → "Show counts", `drop_off` → "Drop off".
    static func label(_ name: String) -> String {
        var words: [String] = []
        var word = ""
        for character in name {
            if character == "_" || character == "-" || character == " " {
                if !word.isEmpty { words.append(word); word = "" }
            } else if character.isUppercase, !word.isEmpty, word.last?.isUppercase == false {
                words.append(word)
                word = String(character)
            } else {
                word.append(character)
            }
        }
        if !word.isEmpty { words.append(word) }
        guard let first = words.first else { return name }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst().map { $0.lowercased() }).joined(separator: " ")
    }

    // MARK: Scope

    /// What "Every <name>" reaches, under the scope ("Every funnel card: A and A · phone.
    /// Values snap to acme-web tokens.").
    static func scopeNote(name: String, boards: [String], system: String, fromTokens: Bool) -> String {
        let reach = boards.isEmpty ? "" : "Every \(name): \(list(boards)). "
        let snap = fromTokens ? "Values snap to \(system) tokens." : "Values snap to \(system) tokens, or to Shepherd's scale where it declares none."
        return reach + snap
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
