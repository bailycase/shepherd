import Foundation

/// One theme: a light and a dark variant, each filling every role. Pure data (hex strings), so
/// built-in themes and, later, user themes loaded from JSON go through the same model.
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

    /// Every color string that fails to parse as `#RRGGBB`, as "variant.path" labels. A theme
    /// with any is rejected; built-ins are checked by tests.
    public var invalidColors: [String] {
        light.invalidColors.map { "light.\($0)" } + dark.invalidColors.map { "dark.\($0)" }
    }
}

public struct ThemeVariant: Codable, Hashable, Sendable {
    public var colors: ThemeColors
    public var syntax: SyntaxColors
    public var terminal: TerminalColors
    public var pi: PiColors

    public init(colors: ThemeColors, syntax: SyntaxColors, terminal: TerminalColors, pi: PiColors) {
        self.colors = colors
        self.syntax = syntax
        self.terminal = terminal
        self.pi = pi
    }

    var invalidColors: [String] {
        func check(_ prefix: String, _ value: Any) -> [String] {
            Mirror(reflecting: value).children.flatMap { child -> [String] in
                let label = "\(prefix).\(child.label ?? "?")"
                switch child.value {
                case let string as String: return HexColor(string) == nil ? [label] : []
                case let optional as String?: return optional.map { HexColor($0) == nil ? [label] : [] } ?? []
                case let list as [String]: return list.enumerated().compactMap { HexColor($1) == nil ? "\(label)[\($0)]" : nil }
                default: return []
                }
            }
        }
        return check("colors", colors) + check("syntax", syntax) + check("terminal", terminal) + check("pi", pi)
    }
}

/// The design roles every theme fills. Names match the design handoff's tokens.
public struct ThemeColors: Codable, Hashable, Sendable {
    /// Window and sidebar.
    public var bgCanvas: String
    /// Thread area, tool groups, settings cards.
    public var bgSurface: String
    /// Composer, popovers, menus.
    public var bgRaised: String
    /// Expanded tool output, sticky file headers.
    public var bgMuted: String
    /// User turns.
    public var bgBubble: String
    /// Active sidebar row, selected chip.
    public var bgSelected: String
    /// Row hover on bgSurface.
    public var bgHover: String
    /// Row hover on bgCanvas.
    public var bgHoverStrong: String
    /// Segmented control and slider track.
    public var bgTrack: String
    /// Between rows inside a group.
    public var borderSubtle: String
    /// Panels, groups, header rule.
    public var border: String
    /// Buttons, fields, composer.
    public var borderStrong: String
    /// Prose, paths, labels.
    public var text: String
    /// Tool output, inactive segments.
    public var textSecondary: String
    /// Tool names, section headings, thinking.
    public var textTertiary: String
    /// Timestamps, counts, hints; the lightest text allowed on bgSurface and bgCanvas.
    public var textMuted: String
    /// Separators and disabled controls only.
    public var textDisabled: String
    /// Current agent, running, links, focus.
    public var accent: String
    /// Accent-colored text; only on accentBg or bgSurface.
    public var accentText: String
    /// Accent tint fill.
    public var accentBg: String
    /// Done, passed, alive, additions.
    public var success: String
    public var successText: String
    public var successBg: String
    /// Needs you, questions, warnings.
    public var warning: String
    public var warningText: String
    public var warningBg: String
    /// Failed, exit ≠ 0, unreachable, removals, Stop.
    public var danger: String
    public var dangerText: String
    public var dangerBg: String
    /// Status dot of an idle agent that is not the open thread.
    public var dotIdle: String

    public init(
        bgCanvas: String,
        bgSurface: String,
        bgRaised: String,
        bgMuted: String,
        bgBubble: String,
        bgSelected: String,
        bgHover: String,
        bgHoverStrong: String,
        bgTrack: String,
        borderSubtle: String,
        border: String,
        borderStrong: String,
        text: String,
        textSecondary: String,
        textTertiary: String,
        textMuted: String,
        textDisabled: String,
        accent: String,
        accentText: String,
        accentBg: String,
        success: String,
        successText: String,
        successBg: String,
        warning: String,
        warningText: String,
        warningBg: String,
        danger: String,
        dangerText: String,
        dangerBg: String,
        dotIdle: String
    ) {
        self.bgCanvas = bgCanvas
        self.bgSurface = bgSurface
        self.bgRaised = bgRaised
        self.bgMuted = bgMuted
        self.bgBubble = bgBubble
        self.bgSelected = bgSelected
        self.bgHover = bgHover
        self.bgHoverStrong = bgHoverStrong
        self.bgTrack = bgTrack
        self.borderSubtle = borderSubtle
        self.border = border
        self.borderStrong = borderStrong
        self.text = text
        self.textSecondary = textSecondary
        self.textTertiary = textTertiary
        self.textMuted = textMuted
        self.textDisabled = textDisabled
        self.accent = accent
        self.accentText = accentText
        self.accentBg = accentBg
        self.success = success
        self.successText = successText
        self.successBg = successBg
        self.warning = warning
        self.warningText = warningText
        self.warningBg = warningBg
        self.danger = danger
        self.dangerText = dangerText
        self.dangerBg = dangerBg
        self.dotIdle = dotIdle
    }
}

/// Code colors for diffs and code blocks.
public struct SyntaxColors: Codable, Hashable, Sendable {
    public var comment: String
    public var keyword: String
    public var function: String
    public var variable: String
    public var string: String
    public var number: String
    public var type: String
    public var operators: String
    public var punctuation: String

    public init(comment: String, keyword: String, function: String, variable: String, string: String, number: String, type: String, operators: String, punctuation: String) {
        self.comment = comment
        self.keyword = keyword
        self.function = function
        self.variable = variable
        self.string = string
        self.number = number
        self.type = type
        self.operators = operators
        self.punctuation = punctuation
    }
}

/// Ghostty colors for shell panes. `palette` is the 16 ANSI colors.
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

/// Pi's complete TUI color contract (its theme schema), written to the file pi watches.
public struct PiColors: Codable, Hashable, Sendable {
    // Core UI
    public var accent: String
    public var border: String
    public var borderAccent: String
    public var borderMuted: String
    public var success: String
    public var error: String
    public var warning: String
    public var muted: String
    public var dim: String
    public var text: String
    public var thinkingText: String
    // Backgrounds and content
    public var selectedBg: String
    public var scrollbarThumb: String
    public var searchMatchBg: String
    public var searchMatchText: String
    public var userMessageBg: String
    public var userMessageText: String
    public var customMessageBg: String
    public var customMessageText: String
    public var customMessageLabel: String
    public var toolPendingBg: String
    public var toolSuccessBg: String
    public var toolErrorBg: String
    public var toolTitle: String
    public var toolOutput: String
    // Markdown
    public var mdHeading: String
    public var mdLink: String
    public var mdLinkUrl: String
    public var mdCode: String
    public var mdCodeBlock: String
    public var mdCodeBlockBorder: String
    public var mdQuote: String
    public var mdQuoteBorder: String
    public var mdHr: String
    public var mdListBullet: String
    // Diffs
    public var toolDiffAdded: String
    public var toolDiffRemoved: String
    public var toolDiffContext: String
    // Syntax highlighting
    public var syntaxComment: String
    public var syntaxKeyword: String
    public var syntaxFunction: String
    public var syntaxVariable: String
    public var syntaxString: String
    public var syntaxNumber: String
    public var syntaxType: String
    public var syntaxOperator: String
    public var syntaxPunctuation: String
    // Thinking-level editor borders and bash mode
    public var thinkingOff: String
    public var thinkingMinimal: String
    public var thinkingLow: String
    public var thinkingMedium: String
    public var thinkingHigh: String
    public var thinkingXhigh: String
    public var thinkingMax: String
    public var bashMode: String

    public init(accent: String, border: String, borderAccent: String, borderMuted: String, success: String, error: String, warning: String, muted: String, dim: String, text: String, thinkingText: String, selectedBg: String, scrollbarThumb: String, searchMatchBg: String, searchMatchText: String, userMessageBg: String, userMessageText: String, customMessageBg: String, customMessageText: String, customMessageLabel: String, toolPendingBg: String, toolSuccessBg: String, toolErrorBg: String, toolTitle: String, toolOutput: String, mdHeading: String, mdLink: String, mdLinkUrl: String, mdCode: String, mdCodeBlock: String, mdCodeBlockBorder: String, mdQuote: String, mdQuoteBorder: String, mdHr: String, mdListBullet: String, toolDiffAdded: String, toolDiffRemoved: String, toolDiffContext: String, syntaxComment: String, syntaxKeyword: String, syntaxFunction: String, syntaxVariable: String, syntaxString: String, syntaxNumber: String, syntaxType: String, syntaxOperator: String, syntaxPunctuation: String, thinkingOff: String, thinkingMinimal: String, thinkingLow: String, thinkingMedium: String, thinkingHigh: String, thinkingXhigh: String, thinkingMax: String, bashMode: String) {
        self.accent = accent
        self.border = border
        self.borderAccent = borderAccent
        self.borderMuted = borderMuted
        self.success = success
        self.error = error
        self.warning = warning
        self.muted = muted
        self.dim = dim
        self.text = text
        self.thinkingText = thinkingText
        self.selectedBg = selectedBg
        self.scrollbarThumb = scrollbarThumb
        self.searchMatchBg = searchMatchBg
        self.searchMatchText = searchMatchText
        self.userMessageBg = userMessageBg
        self.userMessageText = userMessageText
        self.customMessageBg = customMessageBg
        self.customMessageText = customMessageText
        self.customMessageLabel = customMessageLabel
        self.toolPendingBg = toolPendingBg
        self.toolSuccessBg = toolSuccessBg
        self.toolErrorBg = toolErrorBg
        self.toolTitle = toolTitle
        self.toolOutput = toolOutput
        self.mdHeading = mdHeading
        self.mdLink = mdLink
        self.mdLinkUrl = mdLinkUrl
        self.mdCode = mdCode
        self.mdCodeBlock = mdCodeBlock
        self.mdCodeBlockBorder = mdCodeBlockBorder
        self.mdQuote = mdQuote
        self.mdQuoteBorder = mdQuoteBorder
        self.mdHr = mdHr
        self.mdListBullet = mdListBullet
        self.toolDiffAdded = toolDiffAdded
        self.toolDiffRemoved = toolDiffRemoved
        self.toolDiffContext = toolDiffContext
        self.syntaxComment = syntaxComment
        self.syntaxKeyword = syntaxKeyword
        self.syntaxFunction = syntaxFunction
        self.syntaxVariable = syntaxVariable
        self.syntaxString = syntaxString
        self.syntaxNumber = syntaxNumber
        self.syntaxType = syntaxType
        self.syntaxOperator = syntaxOperator
        self.syntaxPunctuation = syntaxPunctuation
        self.thinkingOff = thinkingOff
        self.thinkingMinimal = thinkingMinimal
        self.thinkingLow = thinkingLow
        self.thinkingMedium = thinkingMedium
        self.thinkingHigh = thinkingHigh
        self.thinkingXhigh = thinkingXhigh
        self.thinkingMax = thinkingMax
        self.bashMode = bashMode
    }
}
