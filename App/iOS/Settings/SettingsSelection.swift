import Foundation
import Observation

/// Settings navigation and the host a control will change belong to one window.
@MainActor @Observable
final class SettingsSelection {
    var chosenHost: UUID?
    /// The host Settings › Hooks shows (among those that serve hooks).
    var hooksHost: UUID?
    /// Hooks or Sources beside the iPad's list (iPadHooks).
    var hooksSources = false
    var page: SettingsPage = .appearance
}
