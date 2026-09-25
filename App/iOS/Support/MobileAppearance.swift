import SwiftUI

/// Settings ▸ Appearance: follow the system, or keep Shepherd light or dark. Local to this
/// device, never sent to a host.
@MainActor
@Observable
final class MobileAppearance {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    static let defaultsKey = "shepherd.ios.appearance"

    var mode: Mode {
        didSet { if mode != oldValue { defaults.set(mode.rawValue, forKey: Self.defaultsKey) } }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(Mode.init(rawValue:)) ?? .system
    }
}
