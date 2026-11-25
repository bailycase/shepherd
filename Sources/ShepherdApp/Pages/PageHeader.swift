import SwiftUI
import ShepherdUI

/// A destination page's header (Destination pages; NavNewThread, NavAutomations, NavHosts):
/// `SHPageHeader` with the page's chrome, and the Show sidebar button's chord from the keybindings.
struct DestinationPageHeader<Accessory: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    let chrome: PageHeaderChrome
    /// The hairline under it; New thread draws none (the boards' `.tbar`).
    var rule = true
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        SHPageHeader(title, subtitle: subtitle, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                     sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar), rule: rule, accessory: accessory, trailing: trailing)
    }
}

extension DestinationPageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, chrome: PageHeaderChrome, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, subtitle: subtitle, chrome: chrome, accessory: { EmptyView() }, trailing: trailing)
    }
}

extension DestinationPageHeader where Trailing == EmptyView, Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, chrome: PageHeaderChrome, rule: Bool = true) {
        self.init(title: title, subtitle: subtitle, chrome: chrome, rule: rule, accessory: { EmptyView() }, trailing: { EmptyView() })
    }
}
