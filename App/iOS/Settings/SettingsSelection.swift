import Foundation
import Observation

/// Settings navigation belongs to one window.
@MainActor @Observable
final class SettingsSelection {
    /// Hooks or Sources beside the iPad's list (iPadHooks).
    var hooksSources = false
    private var location: (page: SettingsPage, row: String?) = (.general, nil)
    var page: SettingsPage {
        get { location.page }
        set { select(newValue) }
    }
    /// The list's search text, on iPhone and beside the iPad's list; per window, so a
    /// fixture can set it before its shot.
    var searchQuery = ""

    func select(_ page: SettingsPage, row: String? = nil) {
        location = (page, row)
    }

    func isSelected(_ page: SettingsPage, row: String? = nil) -> Bool {
        location.page == page && location.row == row
    }
}
