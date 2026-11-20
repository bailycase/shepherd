import Foundation
import Observation

/// Settings navigation belongs to one window.
@MainActor @Observable
final class SettingsSelection {
    /// Hooks or Sources beside the iPad's list (iPadHooks).
    var hooksSources = false
    var page: SettingsPage = .general
    /// The list's search text, on iPhone and beside the iPad's list; per window, so a
    /// fixture can set it before its shot.
    var searchQuery = ""
}
