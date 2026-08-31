import SwiftUI
import Foundation
import AppKit

/// One complete Basalt variant: every solid-color design token plus Ghostty
/// and pi terminal colors.
struct ShepherdTheme: Identifiable {
    struct Terminal {
        var background: String
        var foreground: String
        var cursorColor: String
        var selectionBackground: String?
        var selectionForeground: String?
        var palette: [String]
    }

    /// Pi's complete TUI color contract. Keeping the schema explicit makes a
    /// missing color a compile error whenever a Shepherd theme is added.
    struct PiColors: Encodable {
        // Core UI
        let accent: String
        let border: String
        let borderAccent: String
        let borderMuted: String
        let success: String
        let error: String
        let warning: String
        let muted: String
        let dim: String
        let text: String
        let thinkingText: String

        // Backgrounds and content
        let selectedBg: String
        let scrollbarThumb: String
        let searchMatchBg: String
        let searchMatchText: String
        let userMessageBg: String
        let userMessageText: String
        let customMessageBg: String
        let customMessageText: String
        let customMessageLabel: String
        let toolPendingBg: String
        let toolSuccessBg: String
        let toolErrorBg: String
        let toolTitle: String
        let toolOutput: String

        // Markdown
        let mdHeading: String
        let mdLink: String
        let mdLinkUrl: String
        let mdCode: String
        let mdCodeBlock: String
        let mdCodeBlockBorder: String
        let mdQuote: String
        let mdQuoteBorder: String
        let mdHr: String
        let mdListBullet: String

        // Diffs
        let toolDiffAdded: String
        let toolDiffRemoved: String
        let toolDiffContext: String

        // Syntax highlighting
        let syntaxComment: String
        let syntaxKeyword: String
        let syntaxFunction: String
        let syntaxVariable: String
        let syntaxString: String
        let syntaxNumber: String
        let syntaxType: String
        let syntaxOperator: String
        let syntaxPunctuation: String

        // Thinking-level editor borders and bash mode
        let thinkingOff: String
        let thinkingMinimal: String
        let thinkingLow: String
        let thinkingMedium: String
        let thinkingHigh: String
        let thinkingXhigh: String
        let thinkingMax: String
        let bashMode: String
    }

    let id: String
    let name: String

    // Surfaces (all flat — no vibrancy materials anywhere)
    /// Sidebar column, the darkest surface.
    let sidebarBg: Color
    /// Header, workspace, status line, and terminal background.
    let workspaceBg: Color
    /// Selected agent row fill (full-bleed, square).
    let rowSelection: Color
    /// Active space header fill; also the grouped-settings block surface.
    let rowActiveHeader: Color
    /// Neutral pane-frame hairline (the frame takes a status color when the
    /// focused agent is blocked).
    let paneBorder: Color

    // Text ramp (all mono)
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    /// Idle/dim row names, collapsed space headers, empty states.
    let textDim: Color
    /// Counts, ages, secondary summary lines.
    let textMetadata: Color
    /// Header path and status-line key hints — the quietest text on screen.
    let textHint: Color

    // Status
    let statusWorking: Color
    let statusBlocked: Color
    let statusIdle: Color
    let statusDone: Color

    // Accents
    let focusAccent: Color
    let accentButton: Color
    let destructive: Color

    let pi: PiColors
    let terminal: Terminal
}

extension ShepherdTheme {
    /// Basalt Standard: https://github.com/bailycase/basalt-standard
    static let basaltDark = ShepherdTheme(
        id: "basalt-dark",
        name: "Basalt Dark",
        sidebarBg: Color(hex: "#0D0E10"),
        workspaceBg: Color(hex: "#111215"),
        rowSelection: Color(hex: "#1A1B1D"),
        rowActiveHeader: Color(hex: "#161718"),
        paneBorder: Color(hex: "#191A1D"),
        textPrimary: Color(hex: "#EDEDED"),
        textSecondary: Color(hex: "#ADADAE"),
        textTertiary: Color(hex: "#777879"),
        textDim: Color(hex: "#5D5D5F"),
        textMetadata: Color(hex: "#565758"),
        textHint: Color(hex: "#4E4F51"),
        statusWorking: Color(hex: "#9DB56B"),
        statusBlocked: Color(hex: "#C18065"),
        statusIdle: Color(hex: "#3A3B3C"),
        statusDone: Color(hex: "#8892B5"),
        focusAccent: Color(hex: "#C18065"),
        accentButton: Color(hex: "#8892B5"),
        destructive: Color(hex: "#B87D6E"),
        pi: PiColors(
            accent: "#C18065",
            border: "#323337",
            borderAccent: "#C18065",
            borderMuted: "#24252A",
            success: "#A1C592",
            error: "#B87D6E",
            warning: "#CEB370",
            muted: "#6F727F",
            dim: "#51545E",
            text: "#CDD0D7",
            thinkingText: "#6F727F",
            selectedBg: "#1A1B1D",
            scrollbarThumb: "#323337",
            searchMatchBg: "#3A3325",
            searchMatchText: "#EDEDED",
            userMessageBg: "#16171A",
            userMessageText: "#CDD0D7",
            customMessageBg: "#15161A",
            customMessageText: "#ABAEB7",
            customMessageLabel: "#C18065",
            toolPendingBg: "#17181C",
            toolSuccessBg: "#141814",
            toolErrorBg: "#1A1416",
            toolTitle: "#CDD0D7",
            toolOutput: "#6F727F",
            mdHeading: "#CEB370",
            mdLink: "#8892B5",
            mdLinkUrl: "#51545E",
            mdCode: "#CEB370",
            mdCodeBlock: "#CDD0D7",
            mdCodeBlockBorder: "#323337",
            mdQuote: "#ABAEB7",
            mdQuoteBorder: "#323337",
            mdHr: "#323337",
            mdListBullet: "#C18065",
            toolDiffAdded: "#A1C592",
            toolDiffRemoved: "#B87D6E",
            toolDiffContext: "#6F727F",
            syntaxComment: "#ABAEB7",
            syntaxKeyword: "#C18065",
            syntaxFunction: "#CEB370",
            syntaxVariable: "#CDD0D7",
            syntaxString: "#A1C592",
            syntaxNumber: "#C99284",
            syntaxType: "#8892B5",
            syntaxOperator: "#ABAEB7",
            syntaxPunctuation: "#ABAEB7",
            thinkingOff: "#323337",
            thinkingMinimal: "#51545E",
            thinkingLow: "#8892B5",
            thinkingMedium: "#C18065",
            thinkingHigh: "#CEB370",
            thinkingXhigh: "#A1C592",
            thinkingMax: "#EDEDED",
            bashMode: "#A1C592"
        ),
        terminal: Terminal(
            background: "111215",
            foreground: "CDD0D7",
            cursorColor: "CDD0D7",
            selectionBackground: "2B2D33",
            selectionForeground: "EDEDED",
            palette: [
                "#1A1B1D", "#B87D6E", "#A1C592", "#CEB370",
                "#8892B5", "#A38FB5", "#8FB3AD", "#CDD0D7",
                "#565758", "#C99284", "#B3D1A4", "#DCC48A",
                "#9FA9C9", "#B8A6C9", "#A4C7C1", "#EDEDED",
            ]
        )
    )

    static let basaltLight = ShepherdTheme(
        id: "basalt-light",
        name: "Basalt Light",
        sidebarBg: Color(hex: "#E7E4DE"),
        workspaceBg: Color(hex: "#F3F1ED"),
        rowSelection: Color(hex: "#E1DED7"),
        rowActiveHeader: Color(hex: "#ECE9E3"),
        paneBorder: Color(hex: "#D4D0C9"),
        textPrimary: Color(hex: "#242424"),
        textSecondary: Color(hex: "#4F504F"),
        textTertiary: Color(hex: "#5D6065"),
        textDim: Color(hex: "#747570"),
        textMetadata: Color(hex: "#656664"),
        textHint: Color(hex: "#6C6964"),
        statusWorking: Color(hex: "#456536"),
        statusBlocked: Color(hex: "#8F4E37"),
        statusIdle: Color(hex: "#928E87"),
        statusDone: Color(hex: "#526184"),
        focusAccent: Color(hex: "#8F4E37"),
        accentButton: Color(hex: "#526184"),
        destructive: Color(hex: "#94493F"),
        pi: PiColors(
            accent: "#8F4E37",
            border: "#B8B2A8",
            borderAccent: "#8F4E37",
            borderMuted: "#D4D0C9",
            success: "#456536",
            error: "#94493F",
            warning: "#7B5D16",
            muted: "#5D6065",
            dim: "#747570",
            text: "#2E3032",
            thinkingText: "#5D6065",
            selectedBg: "#E1DED7",
            scrollbarThumb: "#B8B2A8",
            searchMatchBg: "#E1DED7",
            searchMatchText: "#242424",
            userMessageBg: "#ECE9E3",
            userMessageText: "#2E3032",
            customMessageBg: "#ECE9E3",
            customMessageText: "#4F5256",
            customMessageLabel: "#8F4E37",
            toolPendingBg: "#E7E2D8",
            toolSuccessBg: "#E2E3DB",
            toolErrorBg: "#EAE0DC",
            toolTitle: "#2E3032",
            toolOutput: "#5D6065",
            mdHeading: "#7B5D16",
            mdLink: "#526184",
            mdLinkUrl: "#747570",
            mdCode: "#7B5D16",
            mdCodeBlock: "#2E3032",
            mdCodeBlockBorder: "#B8B2A8",
            mdQuote: "#4F5256",
            mdQuoteBorder: "#B8B2A8",
            mdHr: "#B8B2A8",
            mdListBullet: "#8F4E37",
            toolDiffAdded: "#456536",
            toolDiffRemoved: "#94493F",
            toolDiffContext: "#5D6065",
            syntaxComment: "#4F5256",
            syntaxKeyword: "#8F4E37",
            syntaxFunction: "#7B5D16",
            syntaxVariable: "#2E3032",
            syntaxString: "#456536",
            syntaxNumber: "#8E5146",
            syntaxType: "#526184",
            syntaxOperator: "#4F5256",
            syntaxPunctuation: "#4F5256",
            thinkingOff: "#B8B2A8",
            thinkingMinimal: "#8F4E37",
            thinkingLow: "#8F4E37",
            thinkingMedium: "#8F4E37",
            thinkingHigh: "#8F4E37",
            thinkingXhigh: "#8F4E37",
            thinkingMax: "#8F4E37",
            bashMode: "#456536"
        ),
        terminal: Terminal(
            background: "F3F1ED",
            foreground: "2E3032",
            cursorColor: "8F4E37",
            selectionBackground: "D7D2C9",
            selectionForeground: "242424",
            palette: [
                "#2E3032", "#94493F", "#456536", "#7B5D16",
                "#526184", "#6D587F", "#3F655F", "#4F5256",
                "#747570", "#A65E50", "#608250", "#927326",
                "#68769A", "#826D93", "#5B817B", "#242424",
            ]
        )
    )

    static let all: [ShepherdTheme] = [.basaltDark, .basaltLight]
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    fileprivate var appKitAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()
    static var effectiveSystemColorScheme: ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
    private static let defaultsKey = "shepherd.appearance"
    private static let legacyThemeKey = "shepherd.theme"

    private let store: UserDefaults
    private let launchOverride: AppearanceMode?
    private var systemColorScheme: ColorScheme
    @Published private(set) var mode: AppearanceMode
    @Published private(set) var current: ShepherdTheme

    init(
        store: UserDefaults = .standard,
        environmentTheme: String? = ProcessInfo.processInfo.environment["SHEPHERD_THEME"],
        systemColorScheme: ColorScheme? = nil
    ) {
        let systemColorScheme = systemColorScheme ?? Self.effectiveSystemColorScheme
        self.store = store
        self.systemColorScheme = systemColorScheme
        let launchOverride = Self.mode(forThemeID: environmentTheme)
        let mode = launchOverride
            ?? store.string(forKey: Self.defaultsKey).flatMap(AppearanceMode.init(rawValue:))
            ?? .system
        self.launchOverride = launchOverride
        self.mode = mode
        current = Self.theme(for: mode, systemColorScheme: systemColorScheme)
    }

    func target(for mode: AppearanceMode, systemColorScheme: ColorScheme? = nil) -> ShepherdTheme {
        Self.theme(for: mode, systemColorScheme: systemColorScheme ?? self.systemColorScheme)
    }

    func select(_ mode: AppearanceMode, systemColorScheme: ColorScheme? = nil) {
        if let systemColorScheme { self.systemColorScheme = systemColorScheme }
        self.mode = mode
        current = target(for: mode)
        store.set(mode.rawValue, forKey: Self.defaultsKey)
        store.removeObject(forKey: Self.legacyThemeKey)
    }

    @discardableResult
    func updateSystemColorScheme(_ colorScheme: ColorScheme) -> ShepherdTheme? {
        systemColorScheme = colorScheme
        guard mode == .system else { return nil }
        let target = Self.theme(for: .system, systemColorScheme: colorScheme)
        guard target.id != current.id else { return nil }
        current = target
        return target
    }

    func applyApplicationAppearance() {
        NSApp?.appearance = mode.appKitAppearance
    }

    var resetTarget: ShepherdTheme {
        target(for: launchOverride ?? .system)
    }

    @discardableResult
    func resetToDefault() -> ShepherdTheme {
        store.removeObject(forKey: Self.defaultsKey)
        store.removeObject(forKey: Self.legacyThemeKey)
        mode = launchOverride ?? .system
        current = resetTarget
        return current
    }

    private static func theme(for mode: AppearanceMode, systemColorScheme: ColorScheme) -> ShepherdTheme {
        switch mode {
        case .light: return .basaltLight
        case .dark: return .basaltDark
        case .system: return systemColorScheme == .dark ? .basaltDark : .basaltLight
        }
    }

    private static func mode(forThemeID id: String?) -> AppearanceMode? {
        switch id {
        case "basalt-light": return .light
        case "basalt-dark", "shepherd-dark": return .dark
        default: return nil
        }
    }
}
