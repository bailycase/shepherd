import SwiftUI

/// The Browser's tab chrome as one board, driven by plain local state through the components' own
/// inputs (no model). Previews and the press tests use it; the app draws the same components.
public struct NWBrowserTabsBoard: View {
    public enum Scene: Sendable {
        /// Board 86: two tabs.
        case two
        /// Board 83: eight tabs, the list open, the cap note.
        case full
        /// Board 84: the agent opened a tab; its dot, and the note with Show it.
        case opened
        /// Board 85: a link opened a window.
        case popup
        /// Board 81: the agent is using the shown page.
        case agent
        /// Board 82: the agent is in another tab.
        case elsewhere
        /// One tab only, and long titles.
        case single
    }

    public static let paneWidth: CGFloat = 600

    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private static func item(_ n: Int, _ title: String, _ address: String, _ letter: String, source: NWBrowserTabSource = .user,
                             active: Bool = false, unseen: Bool = false) -> NWBrowserTabItem {
        NWBrowserTabItem(id: id(n), title: title, address: address, letter: letter, tint: .forHost(address), source: source,
                         agentActive: active, unseen: unseen)
    }

    static func items(for scene: Scene) -> [NWBrowserTabItem] {
        switch scene {
        case .two:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Stripe · Test mode", "dashboard.stripe.com/test/payments", "S", source: .agent)]
        case .full:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Checkout", "localhost:3000/checkout", "C", source: .agent),
             item(3, "Refunds API · Stripe Docs", "docs.stripe.com/api/refunds", "S", source: .agent),
             item(4, "Stripe · Test mode", "dashboard.stripe.com/test/payments", "S"),
             item(5, "Refund overview · staging", "staging.acme.dev/refunds", "A", source: .agent),
             item(6, "Refunds · Grafana", "grafana.internal/d/refunds", "G"),
             item(7, "Refunds API · Stripe Docs", "docs.stripe.com/api/refunds", "S", source: .link),
             item(8, "Checkout", "localhost:3000/checkout", "C")]
        case .opened:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Refund overview · staging", "staging.acme.dev/refunds", "A", source: .agent, unseen: true)]
        case .popup:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Stripe · Test mode", "dashboard.stripe.com/test/payments", "S", source: .link)]
        case .agent:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Checkout", "localhost:3000/checkout", "C", source: .agent, active: true),
             item(3, "Refunds API · Stripe Docs", "docs.stripe.com/api/refunds", "S", source: .agent)]
        case .elsewhere:
            [item(1, "Refund overview", "localhost:3000/refunds", "A"),
             item(2, "Checkout", "localhost:3000/checkout", "C", source: .agent, active: true),
             item(3, "Refunds API · Stripe Docs", "docs.stripe.com/api/refunds", "S", source: .agent)]
        case .single:
            [item(1, "A very long page title that a site might really send, well past any tab", "localhost:3000/a/long/path?with=query", "A")]
        }
    }

    let scene: Scene
    let log: (String) -> Void
    @State private var items: [NWBrowserTabItem]
    @State private var selection: UUID?
    @State private var listOpen: Bool
    @State private var note: Note?
    @State private var address = ""
    @FocusState private var focused: Bool

    struct Note { let message: String; let glyph: String; let action: String? }

    public init(_ scene: Scene, listOpen: Bool = false, log: @escaping (String) -> Void = { _ in }) {
        self.scene = scene
        self.log = log
        let items = Self.items(for: scene)
        _items = State(initialValue: items)
        let selected: Int = switch scene {
        case .two, .opened, .popup, .single, .elsewhere: 0
        case .agent: 1
        case .full: 7
        }
        _selection = State(initialValue: items[selected].id)
        _listOpen = State(initialValue: listOpen || scene == .full)
        _note = State(initialValue: {
            switch scene {
            case .full: Note(message: "This thread has 8 tabs, the most it keeps. New links open in this tab.",
                             glyph: NWBrowserTabsNote.capGlyph, action: nil)
            case .opened: Note(message: "The agent opened Refund overview · staging in a new tab.", glyph: NWBrowserTabsNote.globeGlyph, action: "Show it")
            case .popup: Note(message: "A link opened a new window. Shepherd opened it as a tab.", glyph: NWBrowserTabsNote.globeGlyph, action: nil)
            default: nil
            }
        }())
    }

    private var shown: NWBrowserTabItem? { items.first { $0.id == selection } }
    private var agentElsewhere: NWBrowserTabItem? { items.first { $0.agentActive && $0.id != selection } }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            NWBrowserTabStrip(items: items, selection: selection, canAdd: items.count < 8, listOpen: listOpen,
                              actions: .init(select: { select($0) }, close: { close($0) }, new: { log("new") },
                                             toggleList: { listOpen.toggle() }))
            if let note {
                NWBrowserTabsNote(message: note.message, glyph: note.glyph,
                                  action: note.action.map { title in .init(title) { log("show"); self.note = nil } },
                                  dismiss: { log("dismiss"); self.note = nil })
            }
            NWBrowserToolbar(state: NWBrowserToolbarState(canGoBack: false, canReload: true, canOpenExternally: true), actions: .init()) {
                NWBrowserAddressField(host: shown?.address.split(separator: "/").first.map(String.init), path: nil, hostChip: "This Mac",
                                      text: $address, isFocused: $focused, submit: {})
            }
            ZStack(alignment: .bottomTrailing) {
                nw.bgWindow
                Text(shown?.title ?? "").font(.nw(.display)).foregroundStyle(nw.textPrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(NW.Space.xxl)
                if scene == .agent { NWAgentRing() }
                if let other = agentElsewhere {
                    NWAgentElsewhere(title: other.title) { select(other.id) }.padding(NW.Space.l)
                }
                if listOpen {
                    Color.clear.contentShape(Rectangle()).onTapGesture { listOpen = false }.accessibilityHidden(true)
                    NWBrowserTabMenu(items: items, selection: selection, maxTabs: 8,
                                     select: { select($0); listOpen = false },
                                     closeOthers: { log("closeOthers"); if let s = shown { items = [s] }; listOpen = false })
                        .padding(.trailing, NW.Space.m).padding(.top, NW.Space.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(maxHeight: .infinity)
            if scene == .agent { NWAgentBar(note: "filling the checkout form") { log("takeOver") } }
            NWConsoleBar(network: 12, warnings: 1, open: false, toggle: {})
        }
        .frame(width: Self.paneWidth, height: 560)
        .background(nw.bgWindow)
    }

    private func select(_ id: UUID) {
        log("select \(id.uuidString.suffix(1))")
        selection = id
        items = items.map { $0.id == id && $0.unseen ? NWBrowserTabItem(id: $0.id, title: $0.title, address: $0.address, letter: $0.letter, tint: $0.tint, source: $0.source, agentActive: $0.agentActive, unseen: false) : $0 }
    }

    private func close(_ id: UUID) {
        log("close \(id.uuidString.suffix(1))")
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }
}

#Preview("Browser tabs") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWBrowserTabsBoard(.two)
            NWBrowserTabsBoard(.full)
        }
    }
}

#Preview("Browser tabs — the agent") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWBrowserTabsBoard(.agent)
            NWBrowserTabsBoard(.elsewhere)
        }
    }
}

#Preview("Browser tabs — notes") {
    NWPreviewBoth {
        VStack(spacing: NW.Space.xl) {
            NWBrowserTabsBoard(.opened)
            NWBrowserTabsBoard(.popup)
        }
    }
}
