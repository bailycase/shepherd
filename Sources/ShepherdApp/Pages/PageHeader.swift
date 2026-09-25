import SwiftUI
import ShepherdUI

/// A destination page's header (Destination pages; NavNewThread, NavAutomations, NavHosts): 52pt
/// on `bgWindow` with a hairline beneath, 24pt leading and 16pt trailing padding, 12pt between
/// items. The title in `title` (Geist 15 semibold), an optional subtitle in 12.5 `textTertiary`,
/// then the page's own controls at the trailing end. It drags the window.
struct DestinationPageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let chrome: PageHeaderChrome
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: NW.Space.l) {
            if let showSidebar = chrome.showSidebar {
                Button(action: showSidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.nwIcon)
                    .nwHelp("Show sidebar", shortcut: KeybindingsStore.shared.display(.toggleSidebar))
                    .accessibilityLabel("Show sidebar")
            }
            Text(title)
                .font(.nw(.title))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            }
            Spacer(minLength: NW.Space.l)
            trailing()
        }
        .padding(.leading, AppLayout.pageHeaderLeading + chrome.leadingInset)
        .padding(.trailing, AppLayout.pageHeaderTrailing)
        .frame(height: AppLayout.pageHeaderHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .contentShape(Rectangle())
        .gesture(WindowDragGesture())
    }
}

extension DestinationPageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, chrome: PageHeaderChrome) {
        self.init(title: title, subtitle: subtitle, chrome: chrome) { EmptyView() }
    }
}
