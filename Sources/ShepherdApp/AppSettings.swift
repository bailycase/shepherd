import Foundation
import AppKit
import SwiftUI
import ShepherdCore

/// User preferences that are not part of the workspace.
///
/// `state.json` (owned by the session server) is the workspace: spaces,
/// agents, layouts. This is the other half — how the app looks and what a new
/// agent starts with — and it lives in UserDefaults because it is per-user
/// chrome, not shared session state. Every setting here is wired to real
/// behavior; a preference nothing reads is a bug, not a placeholder.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Key {
        static let terminalFontFamily = "shepherd.terminal.fontFamily"
        static let terminalFontSize = "shepherd.terminal.fontSize"
        static let defaultModel = "shepherd.agent.defaultModel"
        static let defaultThinking = "shepherd.agent.defaultThinking"
        static let autoNameAgents = "shepherd.agent.autoName"
        static let shellPath = "shepherd.pane.shell"
        static let uiDensity = "shepherd.ui.density"
        static let uiTextScale = "shepherd.ui.textScale"
        static let sidebarWidth = "shepherd.ui.sidebarWidth"
        static let remoteListenerEnabled = "shepherd.remote.listener"
        static let remoteListenerPort = "shepherd.remote.listenerPort"

        static let all = [
            terminalFontFamily, terminalFontSize, defaultModel,
            defaultThinking, autoNameAgents, shellPath,
            uiDensity, uiTextScale, sidebarWidth,
            remoteListenerEnabled, remoteListenerPort,
        ]
    }

    enum Defaults {
        static let terminalFontFamily = "SF Mono"
        static let terminalFontSize: Double = 12.5
        static let thinking: ThinkingLevel = .medium
        static let autoNameAgents = true
        /// The user's login shell when it is a real executable, else zsh.
        static var shellPath: String {
            let env = ProcessInfo.processInfo.environment["SHELL"] ?? ""
            return FileManager.default.isExecutableFile(atPath: env) ? env : "/bin/zsh"
        }
    }

    /// Terminal surfaces are rebuilt on change, so both font values are
    /// applied to every live pane the moment they are edited.
    @Published var terminalFontFamily: String {
        didSet { store.set(terminalFontFamily, forKey: Key.terminalFontFamily) }
    }

    @Published var terminalFontSize: Double {
        didSet { store.set(terminalFontSize, forKey: Key.terminalFontSize) }
    }

    /// Empty means "whatever pi picks" — Shepherd never invents a model id.
    @Published var defaultModel: String {
        didSet { store.set(defaultModel, forKey: Key.defaultModel) }
    }

    @Published var defaultThinking: ThinkingLevel {
        didSet { store.set(defaultThinking.rawValue, forKey: Key.defaultThinking) }
    }

    /// Off means agents keep their provisional name (the truncated opening
    /// prompt) and the namer extension is never passed to pi.
    @Published var autoNameAgents: Bool {
        didSet { store.set(autoNameAgents, forKey: Key.autoNameAgents) }
    }

    /// Shell for panes that are not an agent's pi process (⌘D splits, space
    /// workspaces, panes an agent opens for itself).
    @Published var shellPath: String {
        didSet { store.set(shellPath, forKey: Key.shellPath) }
    }

    /// Row-height multiplier for app chrome (sidebar rows, headers). 1.0 is
    /// the designed density; smaller packs more agents on screen.
    @Published var uiDensity: Double {
        didSet { store.set(uiDensity, forKey: Key.uiDensity) }
    }

    /// Multiplier on every chrome font size (never the terminal's — that is
    /// `terminalFontSize`).
    @Published var uiTextScale: Double {
        didSet { store.set(uiTextScale, forKey: Key.uiTextScale) }
    }

    @Published var sidebarWidth: Double {
        didSet { store.set(sidebarWidth, forKey: Key.sidebarWidth) }
    }

    /// Serve this Mac's sessions to remote Shepherd clients (the mini role).
    /// Applied at launch and on toggle; persists so a host stays a host
    /// across reboots.
    @Published var remoteListenerEnabled: Bool {
        didSet { store.set(remoteListenerEnabled, forKey: Key.remoteListenerEnabled) }
    }

    @Published var remoteListenerPort: Int {
        didSet { store.set(remoteListenerPort, forKey: Key.remoteListenerPort) }
    }

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        terminalFontFamily = store.string(forKey: Key.terminalFontFamily) ?? Defaults.terminalFontFamily
        let size = store.double(forKey: Key.terminalFontSize)
        terminalFontSize = Self.clampFontSize(size == 0 ? Defaults.terminalFontSize : size)
        defaultModel = store.string(forKey: Key.defaultModel) ?? ""
        defaultThinking = store.string(forKey: Key.defaultThinking)
            .flatMap(ThinkingLevel.init(rawValue:)) ?? Defaults.thinking
        autoNameAgents = store.object(forKey: Key.autoNameAgents) as? Bool ?? Defaults.autoNameAgents
        shellPath = store.string(forKey: Key.shellPath) ?? Defaults.shellPath
        let density = store.double(forKey: Key.uiDensity)
        uiDensity = min(max(density == 0 ? 1 : density, Self.uiDensityRange.lowerBound), Self.uiDensityRange.upperBound)
        let textScale = store.double(forKey: Key.uiTextScale)
        uiTextScale = min(max(textScale == 0 ? 1 : textScale, Self.uiTextScaleRange.lowerBound), Self.uiTextScaleRange.upperBound)
        let width = store.double(forKey: Key.sidebarWidth)
        sidebarWidth = Self.clampSidebarWidth(width == 0 ? 230 : width)
        remoteListenerEnabled = store.bool(forKey: Key.remoteListenerEnabled)
        let port = store.integer(forKey: Key.remoteListenerPort)
        remoteListenerPort = (port > 0 && port <= 65535) ? port : Int(RemoteSettingsDefaults.port)
    }

    static let uiDensityRange: ClosedRange<Double> = 0.8...1.5
    static let uiTextScaleRange: ClosedRange<Double> = 0.85...1.3
    static let sidebarWidthRange: ClosedRange<Double> = 190...340

    static func clampSidebarWidth(_ width: Double) -> Double {
        min(max(width, sidebarWidthRange.lowerBound), sidebarWidthRange.upperBound)
    }

    /// Chrome identity key: views wrap their appearance-sensitive subtrees in
    /// `.id(settings.appearanceKey)` so a slider drag rebuilds rows whose
    /// SwiftUI inputs did not change (fonts and metrics are read inside
    /// `body`, invisible to struct diffing). Never applied around terminal
    /// panes — chrome only, so surfaces are not torn down.
    var appearanceKey: String {
        "\(uiDensity)-\(uiTextScale)"
    }

    // MARK: Derived values

    static let fontSizeRange: ClosedRange<Double> = 9...24

    static func clampFontSize(_ size: Double) -> Double {
        min(fontSizeRange.upperBound, max(fontSizeRange.lowerBound, size))
    }

    /// What a ⌘N agent and the New Agent sheet start with.
    var agentDefaults: AgentDefaults {
        let trimmed = defaultModel.trimmingCharacters(in: .whitespaces)
        return AgentDefaults(model: trimmed.isEmpty ? nil : trimmed, thinking: defaultThinking)
    }

    /// argv for a plain (non-agent) pane. Login shell so the user's PATH and
    /// rc files apply, exactly as before this was configurable.
    var shellCommand: [String] {
        let path = shellPath.trimmingCharacters(in: .whitespaces)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return [Defaults.shellPath, "-l"]
        }
        return [path, "-l"]
    }

    func resetToDefaults() {
        // Assign first: each `didSet` writes its value back, so removing the
        // keys before this would leave every one of them re-persisted.
        terminalFontFamily = Defaults.terminalFontFamily
        terminalFontSize = Defaults.terminalFontSize
        defaultModel = ""
        defaultThinking = Defaults.thinking
        autoNameAgents = Defaults.autoNameAgents
        shellPath = Defaults.shellPath
        // Then clear the store, so an unset preference reads as "never
        // configured" and follows a future change of default.
        for key in Key.all {
            store.removeObject(forKey: key)
        }
    }

    /// Sentinel picker value meaning "use the system monospaced font".
    static let systemFontFamily = "System Font"

    /// The family name terminals should actually load. The true system mono
    /// font is hidden (dot-prefixed) and breaks ghostty's cell metrics, so
    /// the sentinel resolves to the closest publicly visible system family:
    /// SF Mono where installed, else Menlo (always shipped).
    var resolvedTerminalFontFamily: String {
        guard terminalFontFamily == Self.systemFontFamily else { return terminalFontFamily }
        let visible = NSFontManager.shared.availableFontFamilies
        return ["SF Mono", "Menlo"].first(where: visible.contains) ?? "Menlo"
    }

    /// Fixed-pitch families installed on this machine, with the configured one
    /// always present so a missing font is still shown (ghostty falls back
    /// silently, so the name must remain visible and correctable).
    static func monospacedFamilies(including current: String) -> [String] {
        var families = NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            // Symbols-only families (Nerd Font glyph packs) are fixed-pitch
            // but carry no Latin letters; a terminal set to one renders
            // fallback glyphs on a broken double-wide grid.
            return font.isFixedPitch && font.coveredCharacterSet.contains("a")
        }
        if !families.contains(current), current != systemFontFamily {
            families.append(current)
        }
        return families.sorted()
    }

    /// Shells listed in /etc/shells that actually exist, plus the current one.
    static func knownShells(including current: String) -> [String] {
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        var shells = listed
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && FileManager.default.isExecutableFile(atPath: $0) }
        if !current.isEmpty, !shells.contains(current) {
            shells.append(current)
        }
        var seen = Set<String>()
        return shells.filter { seen.insert($0).inserted }
    }
}

/// The model/thinking pair a new agent inherits. Passed explicitly so agent
/// creation stays testable without touching UserDefaults.
struct AgentDefaults: Equatable {
    var model: String?
    var thinking: ThinkingLevel

    static let piDefaults = AgentDefaults(model: nil, thinking: .medium)
}
