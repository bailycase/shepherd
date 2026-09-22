import SwiftUI
import Foundation
import AppKit
import ShepherdDesign

/// The active theme variant: a theme definition plus the light/dark side currently in effect.
/// App chrome never reads this for colors (views use `Tokens`, which follow each view's own
/// appearance); it drives what cannot follow appearance on its own — Ghostty surfaces and the
/// pi theme file for a pi run by hand in a shell.
struct ShepherdTheme: Identifiable, Equatable {
    typealias Terminal = TerminalColors
    typealias PiColors = ShepherdDesign.PiColors

    let definition: ThemeDefinition
    let isDark: Bool

    /// "basalt-dark" / "basalt-light": written to the variant marker file Neovim watches, so
    /// the spelling is an external contract.
    var id: String { "\(definition.id)-\(isDark ? "dark" : "light")" }
    var name: String { "\(definition.name) \(isDark ? "Dark" : "Light")" }
    var variant: ThemeVariant { definition.variant(dark: isDark) }
    var terminal: TerminalColors { variant.terminal }
    var pi: PiColors { variant.pi }

    static let basaltDark = ShepherdTheme(definition: .basalt, isDark: true)
    static let basaltLight = ShepherdTheme(definition: .basalt, isDark: false)
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
