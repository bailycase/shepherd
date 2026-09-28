import Foundation
import Observation

/// Settings navigation and the host a control will change belong to one window.
@MainActor @Observable
final class SettingsSelection {
    var chosenHost: UUID?
    var instructionsHost: UUID?
    var page: SettingsPage = .appearance
}
