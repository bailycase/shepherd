import Foundation
import Observation

/// Settings navigation belongs to one window.
@MainActor @Observable
final class SettingsSelection {
    /// Hooks or Sources beside the iPad's list (iPadHooks).
    var hooksSources = false
    var page: SettingsPage = .appearance
}
