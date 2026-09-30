import SwiftUI

private struct AddressPreview: View {
    let host: String?
    let path: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NWBrowserAddressField(host: host, path: path, hostChip: "This Mac", text: $text, isFocused: $focused, submit: {})
    }
}

#Preview("Browser toolbar") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.l) {
            NWBrowserToolbar(state: NWBrowserToolbarState(canGoBack: true, canReload: true, selecting: true, canOpenExternally: true),
                             selectShortcut: "⇧⌘C", actions: .init()) {
                AddressPreview(host: "localhost:5173", path: "/checkout")
            }
            NWBrowserToolbar(state: NWBrowserToolbarState(viewportMenuOpen: true), actions: .init()) {
                AddressPreview(host: nil, path: nil)
            }
        }
        .frame(width: 600)
    }
}

#Preview("Browser — nothing open") {
    NWPreviewBoth {
        NWBrowserEmpty(message: "Start a dev server from this repository, or open a URL. Pages you open stay with this thread.",
                       servers: [NWDevServerItem(id: "dev", command: "pnpm dev", detail: "from package.json · acme-web"),
                                 NWDevServerItem(id: "preview", command: "pnpm preview", detail: "from package.json · acme-web")],
                       openShortcut: "⌘L", start: { _ in }, openURL: {})
            .frame(width: 600, height: 460)
    }
}

#Preview("Browser — viewport, element, console") {
    NWPreviewBoth {
        HStack(alignment: .top, spacing: NW.Space.xl) {
            NWViewportMenu(options: [NWViewportOption(id: "fit", title: "Fit the pane"),
                                     NWViewportOption(id: "phone", title: "iPhone 16", width: "393"),
                                     NWViewportOption(id: "tablet", title: "iPad mini", width: "744"),
                                     NWViewportOption(id: "laptop", title: "Laptop", width: "1280")],
                           selection: "fit", dark: false, choose: { _ in }, toggleDark: {})
            VStack(alignment: .leading, spacing: NW.Space.l) {
                NWElementPopover(source: "Checkout.tsx:88", add: {}, copy: {})
                NWElementChip("button.pay", source: "Checkout.tsx:88", remove: {})
                NWElementChip("input#promo", size: .compact)
            }
            VStack(spacing: 0) {
                NWConsoleBar(network: 24, warnings: 1, open: true, toggle: {})
                NWConsoleRow(NWConsoleLine(id: 1, time: "14:02:11", text: "[vite] hmr update /src/components/Checkout.tsx"))
                NWConsoleRow(NWConsoleLine(id: 2, time: "14:02:13", text: "Each child in a list should have a unique \"key\" prop.",
                                           level: .warning))
                NWConsoleRow(NWConsoleLine(id: 3, time: "14:02:14", text: "TypeError: cart is undefined", level: .error))
            }
            .frame(width: 420)
        }
    }
}
