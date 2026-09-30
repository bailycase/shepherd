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

#Preview("Browser — the agent is using it") {
    NWPreviewBoth {
        // A page stands in behind the ring, pointer and card.
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 10) {
                Text("Checkout").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                Text("Promo code FALL24 applied").font(.system(size: 13)).foregroundStyle(.gray)
                Text("Pay $148.00").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 240, height: 44).background(Color.indigo, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(28)
            .padding(.top, 44)
            NWBrowserAgentOverlay(note: "clicking through checkout", pointer: CGPoint(x: 176, y: 214), takeOver: {})
        }
        .frame(width: 440, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
    }
}

#Preview("Browser — the agent's card, long note") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWAgentCard(note: "clicking through checkout", takeOver: {})
            NWAgentCard(note: "typing in “Card number” and checking that every field on the page took its value", takeOver: {})
        }
        .frame(width: 420)
    }
}

#Preview("Side pane — the agent opened a tab") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWSidePaneTabs([NWSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2, shortcut: "⌃1"),
                            NWSidePaneTab(id: "browser", title: "Browser", systemImage: "globe", news: true, shortcut: "⌃2",
                                          tip: NWSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date().addingTimeInterval(-10)))],
                           selection: "changes", select: { _ in }, close: {}) {
                Button("Reset Width") {}
            }
            NWPaneTabTip(NWSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date().addingTimeInterval(-10)))
        }
        .frame(width: 460, height: 130, alignment: .topLeading)
    }
}
