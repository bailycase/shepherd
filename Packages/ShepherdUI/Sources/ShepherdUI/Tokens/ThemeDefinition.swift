import Foundation

/// One theme: a light and a dark variant, each filling every role. Pure data (hex strings), so
/// the built-in Night Watch and, later, user themes loaded from JSON go through the same model.
public struct ThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var light: ThemeVariant
    public var dark: ThemeVariant

    public init(id: String, name: String, light: ThemeVariant, dark: ThemeVariant) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }

    public func variant(dark isDark: Bool) -> ThemeVariant { isDark ? dark : light }

    /// Every color string that fails to parse, as "variant.path" labels. A theme with any is
    /// rejected; built-ins are checked by tests.
    public var invalidColors: [String] {
        light.invalidColors.map { "light.\($0)" } + dark.invalidColors.map { "dark.\($0)" }
    }
}

public struct ThemeVariant: Codable, Hashable, Sendable {
    public var colors: ThemeColors
    public var syntax: SyntaxColors
    public var terminal: TerminalColors

    public init(colors: ThemeColors, syntax: SyntaxColors, terminal: TerminalColors) {
        self.colors = colors
        self.syntax = syntax
        self.terminal = terminal
    }

    /// UI roles may be translucent (`#RRGGBBAA`); syntax and terminal colors are handed to
    /// renderers that want opaque `#RRGGBB`.
    var invalidColors: [String] {
        func check(_ prefix: String, _ value: Any, allowAlpha: Bool) -> [String] {
            func invalid(_ string: String) -> Bool {
                guard let color = HexColor(string) else { return true }
                return !allowAlpha && !color.isOpaque
            }
            return Mirror(reflecting: value).children.flatMap { child -> [String] in
                let label = "\(prefix).\(child.label ?? "?")"
                switch child.value {
                case let string as String: return invalid(string) ? [label] : []
                case let optional as String?: return optional.map { invalid($0) ? [label] : [] } ?? []
                case let list as [String]: return list.enumerated().compactMap { invalid($1) ? "\(label)[\($0)]" : nil }
                default: return []
                }
            }
        }
        return check("colors", colors, allowAlpha: true) + check("syntax", syntax, allowAlpha: false)
            + check("terminal", terminal, allowAlpha: false)
    }
}

/// The Night Watch roles every theme fills (the Foundations board). Views read them as
/// `Color.nw.<role>`. Translucent roles are `#RRGGBBAA`.
public struct ThemeColors: Codable, Hashable, Sendable {
    // Surfaces
    /// Sidebar, window chrome.
    public var bgBase: String
    /// Thread, panes.
    public var bgWindow: String
    /// Cards, composer, menus.
    public var bgRaised: String
    /// Code, tool output, headers.
    public var bgSunken: String
    /// User messages.
    public var bgBubble: String
    /// Row hover (translucent).
    public var bgHover: String
    /// Selected row (translucent).
    public var bgSelected: String

    // Lines and text
    /// Dividers, row separators, card borders.
    public var lineSubtle: String
    /// Control borders, popovers.
    public var lineStrong: String
    /// Body, titles.
    public var textPrimary: String
    /// Labels, previews.
    public var textSecondary: String
    /// Meta, timestamps.
    public var textTertiary: String
    /// Text on brand (lantern) fills.
    public var textOnLantern: String

    // Brand and state
    /// Brand, primary action, needs-you.
    public var lantern: String
    /// Lantern text on its tint.
    public var lanternText: String
    /// Needs-you backgrounds (translucent).
    public var lanternTint: String
    /// Running, links, focus.
    public var running: String
    /// Running backgrounds (translucent).
    public var runningTint: String
    /// Success, additions.
    public var done: String
    /// Done and added-line backgrounds (translucent).
    public var doneTint: String
    /// Failure, deletions, destructive.
    public var failed: String
    /// Failed and removed-line backgrounds (translucent).
    public var failedTint: String

    public init(
        bgBase: String, bgWindow: String, bgRaised: String, bgSunken: String, bgBubble: String,
        bgHover: String, bgSelected: String,
        lineSubtle: String, lineStrong: String,
        textPrimary: String, textSecondary: String, textTertiary: String, textOnLantern: String,
        lantern: String, lanternText: String, lanternTint: String,
        running: String, runningTint: String,
        done: String, doneTint: String,
        failed: String, failedTint: String
    ) {
        self.bgBase = bgBase
        self.bgWindow = bgWindow
        self.bgRaised = bgRaised
        self.bgSunken = bgSunken
        self.bgBubble = bgBubble
        self.bgHover = bgHover
        self.bgSelected = bgSelected
        self.lineSubtle = lineSubtle
        self.lineStrong = lineStrong
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textOnLantern = textOnLantern
        self.lantern = lantern
        self.lanternText = lanternText
        self.lanternTint = lanternTint
        self.running = running
        self.runningTint = runningTint
        self.done = done
        self.doneTint = doneTint
        self.failed = failed
        self.failedTint = failedTint
    }
}

/// Code colors for code blocks and diffs. The first six are the board's `syn*` roles; the last
/// three cover the highlighter's remaining captures.
public struct SyntaxColors: Codable, Hashable, Sendable {
    public var keyword: String
    public var type: String
    public var string: String
    public var number: String
    public var function: String
    public var comment: String
    public var variable: String
    public var operators: String
    public var punctuation: String

    public init(keyword: String, type: String, string: String, number: String, function: String,
                comment: String, variable: String, operators: String, punctuation: String) {
        self.keyword = keyword
        self.type = type
        self.string = string
        self.number = number
        self.function = function
        self.comment = comment
        self.variable = variable
        self.operators = operators
        self.punctuation = punctuation
    }
}

/// Ghostty colors for terminal panes. `palette` is the 16 ANSI colors.
public struct TerminalColors: Codable, Hashable, Sendable {
    public var background: String
    public var foreground: String
    public var cursor: String
    public var selectionBackground: String?
    public var selectionForeground: String?
    public var palette: [String]

    public init(background: String, foreground: String, cursor: String, selectionBackground: String?, selectionForeground: String?, palette: [String]) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }
}
