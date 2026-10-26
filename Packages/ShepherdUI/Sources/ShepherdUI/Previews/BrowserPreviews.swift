import SwiftUI

private struct AddressPreview: View {
    let host: String?
    let path: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SHBrowserAddressField(host: host, path: path, hostChip: "This Mac", text: $text, isFocused: $focused, submit: {})
    }
}

#Preview("Browser toolbar") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHBrowserToolbar(state: SHBrowserToolbarState(canGoBack: true, canReload: true, selecting: true, canOpenExternally: true),
                             selectShortcut: "⇧⌘C", actions: .init()) {
                AddressPreview(host: "localhost:5173", path: "/checkout")
            }
            SHBrowserToolbar(state: SHBrowserToolbarState(viewportMenuOpen: true), actions: .init()) {
                AddressPreview(host: nil, path: nil)
            }
        }
        .frame(width: 600)
    }
}

#Preview("Browser — a remote host") {
    SHPreviewBoth {
        VStack(spacing: SH.Space.l) {
            SHBrowserToolbar(state: SHBrowserToolbarState(canGoBack: true, canReload: true, canOpenExternally: true), actions: .init()) {
                RemoteAddressPreview(host: "localhost:5173", path: "/checkout")
            }
            SHBrowserNotice(message: "Port 5173 is in use on this Mac, so build-01’s 5173 can’t be forwarded. Stop what is using it and try again.",
                            dismiss: {})
                .padding(.horizontal, SH.Space.l)
        }
        .frame(width: 600)
    }
}

private struct RemoteAddressPreview: View {
    let host: String?
    let path: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SHBrowserAddressField(host: host, path: path, hostChip: "build-01", text: $text, isFocused: $focused, submit: {})
    }
}

#Preview("Browser — nothing open") {
    SHPreviewBoth {
        SHBrowserEmpty(message: "Start a dev server from this repository, or open a URL. Pages you open stay with this thread.",
                       servers: [SHDevServerItem(id: "dev", command: "pnpm dev", detail: "from package.json · acme-web"),
                                 SHDevServerItem(id: "preview", command: "pnpm preview", detail: "from package.json · acme-web")],
                       openShortcut: "⌘L", start: { _ in }, openURL: {})
            .frame(width: 600, height: 460)
    }
}

#Preview("Browser — viewport, element, console") {
    SHPreviewBoth {
        HStack(alignment: .top, spacing: SH.Space.xl) {
            SHViewportMenu(options: [SHViewportOption(id: "fit", title: "Fit the pane"),
                                     SHViewportOption(id: "phone", title: "iPhone 16", width: "393"),
                                     SHViewportOption(id: "tablet", title: "iPad mini", width: "744"),
                                     SHViewportOption(id: "laptop", title: "Laptop", width: "1280")],
                           selection: "fit", dark: false, choose: { _ in }, toggleDark: {})
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHElementPopover(source: "Checkout.tsx:88", add: {}, copy: {})
                SHElementChip("button.pay", source: "Checkout.tsx:88", remove: {})
                SHElementChip("input#promo", size: .compact)
            }
            VStack(spacing: 0) {
                SHConsoleBar(network: 24, warnings: 1, open: true, toggle: {})
                SHConsoleRow(SHConsoleLine(id: 1, time: "14:02:11", text: "[vite] hmr update /src/components/Checkout.tsx"))
                SHConsoleRow(SHConsoleLine(id: 2, time: "14:02:13", text: "Each child in a list should have a unique \"key\" prop.",
                                           level: .warning))
                SHConsoleRow(SHConsoleLine(id: 3, time: "14:02:14", text: "TypeError: cart is undefined", level: .error))
            }
            .frame(width: 420)
        }
    }
}

#Preview("Browser — the agent is using it") {
    SHPreviewBoth {
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
            SHBrowserAgentOverlay(pointer: CGPoint(x: 176, y: 214))
        }
        .frame(width: 440, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
    }
}

#Preview("Browser — the agent's bar, long note") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHAgentBar(note: "clicking through checkout", takeOver: {})
            SHAgentBar(note: "typing in “Card number” and checking that every field on the page took its value", takeOver: {})
        }
        .frame(width: 420)
    }
}

#Preview("Side pane — the agent opened a tab") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHSidePaneTabs([SHSidePaneTab(id: "changes", title: "Changes", systemImage: "plus.forwardslash.minus", count: 2, shortcut: "⌃1"),
                            SHSidePaneTab(id: "browser", title: "Browser", systemImage: "globe", news: true, shortcut: "⌃2",
                                          tip: SHSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date().addingTimeInterval(-10)))],
                           selection: "changes", select: { _ in }, close: {}) {
                Button("Reset Width") {}
            }
            SHPaneTabTip(SHSidePaneTabTip(text: "localhost:5173/checkout", openedAt: Date().addingTimeInterval(-10)))
        }
        .frame(width: 460, height: 130, alignment: .topLeading)
    }
}
