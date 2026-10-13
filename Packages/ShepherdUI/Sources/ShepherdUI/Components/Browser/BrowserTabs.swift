import SwiftUI

// The Browser's tabs (BrowserTabsAgent, -Elsewhere, -Full, -Opened, -Popup, -Two): a 38pt strip of
// pages under the side pane's tabs, the list of every tab, a note under the strip, and the two
// ways the agent shows it is using a page. All of it takes plain values; the app owns the pages.

public enum NWBrowserTabsMetrics {
    /// The strip under the pane's tabs.
    public static let stripHeight: CGFloat = 38
    public static let tabHeight: CGFloat = 26
    public static let tabMinWidth: CGFloat = 64
    public static let tabMaxWidth: CGFloat = 200
    /// The close button's hit area. The board draws 20pt wide; 24 is the desktop minimum.
    public static let closeWidth: CGFloat = 24
    public static let closeGlyph: CGFloat = 10
    public static let favicon: CGFloat = 12
    public static let faviconLetter: CGFloat = 8
    public static let unseenDot: CGFloat = 6
    public static let stripGlyph: CGFloat = 14
    /// Others show their close button while the strip holds no more than this many tabs.
    public static let roomyTabs = 4
    /// The list of tabs.
    public static let menuWidth: CGFloat = 260
    public static let menuRowMinHeight: CGFloat = 30
    /// The rows scroll past this; eight rows at the board's size fit.
    public static let menuListMaxHeight: CGFloat = 420
    public static let menuCheckWidth: CGFloat = 14
    public static let menuCheckGlyph: CGFloat = 11
    /// The note under the strip.
    public static let noteGlyph: CGFloat = 13
    public static let noteDismiss: CGFloat = 24
    /// The agent's bar over the console, and the chip when it is on another tab.
    public static let agentBarHeight: CGFloat = NWBrowserMetrics.consoleBarHeight
    public static let agentSpinner: CGFloat = 11
    public static let agentChipSpinner: CGFloat = 12
    public static let agentTakeOverGlyph: CGFloat = 12
}

/// What fills a tab's tile: the board's four colors (BrowserTabsTwo, -Full). A page on this Mac's own
/// loopback is `running`; any other host gets one of the other three by a fixed hash of its site name,
/// so a site keeps its color. The board colors by brand and the app knows no brands, so a site can
/// land on a different one of the three than the board gave it.
public enum NWBrowserTabTint: Int, CaseIterable, Sendable {
    case running, done, violet, orange

    public func color(_ nw: NWPalette) -> Color {
        switch self {
        case .running: nw.running
        case .done: nw.done
        case .violet: nw.tabTileViolet
        case .orange: nw.tabTileOrange
        }
    }

    /// The host without its port: "docs.stripe.com:443" is "docs.stripe.com", "[::1]:8080" is "[::1]" (an
    /// IPv6 address keeps its brackets, as `BrowserAddress.display` writes it), lowercased.
    private static func withoutPort(_ host: String) -> String {
        let lower = host.lowercased()
        if lower.hasPrefix("[") {
            return lower.firstIndex(of: "]").map { String(lower[...$0]) } ?? lower
        }
        return lower.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    /// The site's name: the label before its public suffix ("docs.stripe.com:443" is "stripe"), the whole
    /// host for one label ("localhost") or an address ("127.0.0.1", "[::1]").
    public static func siteName(host: String) -> String {
        let bare = withoutPort(host)
        let labels = bare.split(separator: ".").map(String.init)
        guard labels.count > 1, !labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return bare }
        return labels[labels.count - 2]
    }

    /// The tile's letter: the site name's first letter or digit, or "·" for none ("[::1]" has none: its
    /// brackets are not a name).
    public static func initial(host: String) -> String {
        let name = siteName(host: host)
        return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "·"
    }

    public static func forHost(_ host: String) -> NWBrowserTabTint {
        let bare = withoutPort(host)
        if bare.isEmpty || bare == "localhost" || bare == "[::1]" || bare.hasPrefix("127.") { return .running }
        let others: [NWBrowserTabTint] = [.done, .violet, .orange]
        let sum = siteName(host: host).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return others[sum % others.count]
    }
}

/// The outline cross that closes a tab and dismisses the note under the strip: one place for the two uses.
/// It is not an `NWGlyph` case: the registry polices a raw `"xmark"` everywhere, and the app has 45 older
/// uses of it that are not this view's to change.
struct NWBrowserTabClose: View {
    var body: some View { Image(systemName: "xmark") }
}

/// How a tab came to be, as the list's trailing tag says it.
public enum NWBrowserTabSource: Sendable {
    case user, agent, link

    public var tag: String? {
        switch self {
        case .user: nil
        case .agent: "Agent"
        case .link: "Link"
        }
    }

    /// The tab's tooltip suffix and what VoiceOver adds.
    public var phrase: String? {
        switch self {
        case .user: nil
        case .agent: "opened by the agent"
        case .link: "opened by a link"
        }
    }
}

/// One page, as the strip and the list draw it.
public struct NWBrowserTabItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// The address as the field shows it ("localhost:3000/checkout"); empty for a page not yet opened.
    public let address: String
    public let letter: String
    public let tint: NWBrowserTabTint
    public let source: NWBrowserTabSource
    /// The agent is using this page now: a spinner stands in for the favicon.
    public let agentActive: Bool
    /// The agent opened it and nobody has looked yet: a 6pt dot.
    public let unseen: Bool

    public init(id: UUID, title: String, address: String, letter: String, tint: NWBrowserTabTint, source: NWBrowserTabSource = .user,
                agentActive: Bool = false, unseen: Bool = false) {
        self.id = id
        self.title = title
        self.address = address
        self.letter = letter
        self.tint = tint
        self.source = source
        self.agentActive = agentActive
        self.unseen = unseen
    }

    /// The tab's accessibility label: the title, then what is worth knowing.
    var spoken: String {
        [title, unseen ? "new" : nil, agentActive ? "agent is using it" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    var tooltip: String {
        [address.isEmpty ? nil : address, source.phrase].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: The strip

public struct NWBrowserTabStrip: View {
    public struct Actions {
        public var select: (UUID) -> Void
        public var close: (UUID) -> Void
        public var new: () -> Void
        public var toggleList: () -> Void

        public init(select: @escaping (UUID) -> Void = { _ in }, close: @escaping (UUID) -> Void = { _ in }, new: @escaping () -> Void = {},
                    toggleList: @escaping () -> Void = {}) {
            self.select = select
            self.close = close
            self.new = new
            self.toggleList = toggleList
        }
    }

    let items: [NWBrowserTabItem]
    let selection: UUID?
    let canAdd: Bool
    let listOpen: Bool
    let newShortcut: String?
    let actions: Actions

    public init(items: [NWBrowserTabItem], selection: UUID?, canAdd: Bool, listOpen: Bool, newShortcut: String? = nil, actions: Actions) {
        self.items = items
        self.selection = selection
        self.canAdd = canAdd
        self.listOpen = listOpen
        self.newShortcut = newShortcut
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: NW.Space.xxs) {
            HStack(spacing: NW.Space.xxs) {
                ForEach(items) { item in
                    Tab(item: item, selected: item.id == selection, showClose: items.count <= NWBrowserTabsMetrics.roomyTabs,
                        select: { actions.select(item.id) }, close: { actions.close(item.id) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages in this thread")
            Button(action: actions.new) { Image(systemName: "plus").font(.system(size: NWBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.nwIcon(size: NW.Height.controlS))
                .disabled(!canAdd)
                .nwHelp(canAdd ? "New tab" : "This thread has the most tabs it keeps", shortcut: canAdd ? newShortcut : nil)
                .accessibilityLabel("New tab")
            Button(action: actions.toggleList) { Image(systemName: "chevron.down").font(.system(size: NWBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.nwIcon(size: NW.Height.controlS))
                .nwHelp("All tabs")
                .accessibilityLabel("All tabs")
                .accessibilityValue(listOpen ? "open" : "closed")
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NWBrowserTabsMetrics.stripHeight)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private struct Tab: View {
        let item: NWBrowserTabItem
        let selected: Bool
        let showClose: Bool
        let select: () -> Void
        let close: () -> Void
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            HStack(spacing: 0) {
                Button(action: select) {
                    HStack(spacing: NW.Space.s) {
                        if item.agentActive {
                            ProgressView().progressViewStyle(.nwSpinner(size: NWBrowserTabsMetrics.favicon)).accessibilityHidden(true)
                                .frame(width: NWBrowserTabsMetrics.favicon, height: NWBrowserTabsMetrics.favicon)
                        } else {
                            NWBrowserFavicon(letter: item.letter, tint: item.tint)
                        }
                        Text(item.title)
                            .font(.nw(.ui, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if item.unseen {
                            Circle().fill(nw.running).frame(width: NWBrowserTabsMetrics.unseenDot, height: NWBrowserTabsMetrics.unseenDot)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, NW.Space.m)
                    .padding(.trailing, NW.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: NWBrowserTabsMetrics.tabHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .nwFocusRing()
                .nwHelp(item.tooltip.isEmpty ? item.title : item.tooltip)
                .accessibilityLabel(item.spoken)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if selected || showClose || hovering {
                    Button(action: close) {
                        NWBrowserTabClose().font(.system(size: NWBrowserTabsMetrics.closeGlyph, weight: .medium))
                            .foregroundStyle(hovering ? nw.textPrimary : nw.textTertiary)
                            .frame(width: NWBrowserTabsMetrics.closeWidth, height: NWBrowserTabsMetrics.tabHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .nwFocusRing()
                    .nwHelp("Close tab")
                    .accessibilityLabel("Close \(item.title)")
                }
            }
            .frame(minWidth: NWBrowserTabsMetrics.tabMinWidth, maxWidth: NWBrowserTabsMetrics.tabMaxWidth)
            .background(selected ? nw.bgSelected : hovering ? nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .layoutPriority(selected ? 1 : 0)
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
        }
    }
}

/// A page's tile: its first letter on a themed square.
public struct NWBrowserFavicon: View {
    let letter: String
    let tint: NWBrowserTabTint

    public init(letter: String, tint: NWBrowserTabTint) {
        self.letter = letter
        self.tint = tint
    }

    public var body: some View {
        let nw = Color.nw
        Text(letter.prefix(1).uppercased())
            .font(.nwSans(NWBrowserTabsMetrics.faviconLetter, .semibold))
            .foregroundStyle(nw.bgBase)
            .frame(width: NWBrowserTabsMetrics.favicon, height: NWBrowserTabsMetrics.favicon)
            .background(tint.color(nw), in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            .accessibilityHidden(true)
    }
}

// MARK: The list

/// Every tab, the chosen one checked, with Close other tabs under a divider and the count and the
/// sign-in line at its foot (BrowserTabsFull).
public struct NWBrowserTabMenu: View {
    let items: [NWBrowserTabItem]
    let selection: UUID?
    let maxTabs: Int
    let select: (UUID) -> Void
    let closeOthers: () -> Void
    @State private var rowsHeight: CGFloat = 0

    public init(items: [NWBrowserTabItem], selection: UUID?, maxTabs: Int, select: @escaping (UUID) -> Void,
                closeOthers: @escaping () -> Void) {
        self.items = items
        self.selection = selection
        self.maxTabs = maxTabs
        self.select = select
        self.closeOthers = closeOthers
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            // Rows keep their height; a menu taller than the pane scrolls instead of squeezing them.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Row(item: item, checked: item.id == selection) { select(item.id) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(rowsHeight, NWBrowserTabsMetrics.menuListMaxHeight))
            NWChangesMenuDivider()
            Button(action: closeOthers) {
                Text("Close other tabs").font(.nw(.ui, weight: .regular))
                    .foregroundStyle(items.count > 1 ? nw.textPrimary : nw.textTertiary)
                    .padding(.horizontal, NW.Space.m)
                    .frame(maxWidth: .infinity, minHeight: NWBrowserTabsMetrics.menuRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow())
            .disabled(items.count < 2)
            Text("\(items.count) of \(maxTabs) tabs · sign-ins shared across the space")
                .font(.nw(.micro, weight: .regular))
                .foregroundStyle(nw.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NW.Space.m)
                .padding(.top, NW.Space.s)
                .padding(.bottom, NW.Space.xs)
        }
        .padding(NW.Space.s)
        .frame(width: NWBrowserTabsMetrics.menuWidth)
        .nwPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All tabs")
    }

    private struct Row: View {
        let item: NWBrowserTabItem
        let checked: Bool
        let action: () -> Void

        var body: some View {
            let nw = Color.nw
            Button(action: action) {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "checkmark").font(.system(size: NWBrowserTabsMetrics.menuCheckGlyph, weight: .semibold))
                        .foregroundStyle(nw.textPrimary).opacity(checked ? 1 : 0)
                        .frame(width: NWBrowserTabsMetrics.menuCheckWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(item.title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(1)
                        if !item.address.isEmpty {
                            Text(item.address).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let tag = item.source.tag {
                        Text(tag).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary)
                    }
                }
                .padding(.horizontal, NW.Space.m)
                .padding(.vertical, NW.Space.s)
                .frame(minHeight: NWBrowserTabsMetrics.menuRowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.nwRow(selected: false))
            .accessibilityLabel([item.title, item.address.isEmpty ? nil : item.address, item.source.tag].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
    }
}

// MARK: The note

/// A line under the strip on `bgSunken` (BrowserTabsOpened, -Popup, -Full): a 13pt glyph, the
/// words in `caption`, an optional action, and a dismiss button. The app supplies the words.
public struct NWBrowserTabsNote: View {
    public struct Action {
        public let title: String
        public let run: () -> Void

        public init(_ title: String, run: @escaping () -> Void) {
            self.title = title
            self.run = run
        }
    }

    let message: String
    let glyph: String
    let action: Action?
    let dismiss: () -> Void

    /// The glyph the cap warns with; every other note is the globe.
    public static let capGlyph = "exclamationmark.triangle"
    public static let globeGlyph = "globe"

    public init(message: String, glyph: String = NWBrowserTabsNote.globeGlyph, action: Action? = nil, dismiss: @escaping () -> Void) {
        self.message = message
        self.glyph = glyph
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: glyph).font(.system(size: NWBrowserTabsMetrics.noteGlyph)).foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            Text(message).font(.nw(.caption, weight: .regular)).foregroundStyle(nw.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.nw(.secondary, size: .s)).fixedSize()
            }
            Button(action: dismiss) { NWBrowserTabClose().font(.system(size: NWBrowserTabsMetrics.closeGlyph, weight: .medium)) }
                .buttonStyle(.nwIcon(size: NWBrowserTabsMetrics.noteDismiss, tint: nw.textTertiary))
                .padding(.vertical, -NW.Space.xxs)
                .nwHelp("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.s)
        .frame(maxWidth: .infinity)
        .background(nw.bgSunken)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: The agent

/// "Agent is filling the checkout form" with Take over, a bar over the console (BrowserTabsAgent):
/// `runningTint`, a hairline above, the words in `caption`, an 11pt `running` spinner.
public struct NWAgentBar: View {
    public static let glyph = "hand.raised"

    let note: String
    let takeOver: () -> Void

    public init(note: String, takeOver: @escaping () -> Void) {
        self.note = note
        self.takeOver = takeOver
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            ProgressView().progressViewStyle(.nwSpinner(size: NWBrowserTabsMetrics.agentSpinner))
                .frame(width: NWBrowserTabsMetrics.agentSpinner, height: NWBrowserTabsMetrics.agentSpinner)
                .accessibilityHidden(true)
            Text("Agent is \(note)").font(.nw(.caption, weight: .regular)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: takeOver) {
                Label("Take over", systemImage: Self.glyph)
            }
            .buttonStyle(.nw(.secondary, size: .s))
            .fixedSize()
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.s)
        .frame(height: NWBrowserTabsMetrics.agentBarHeight)
        .background(nw.runningTint)
        .overlay(alignment: .top) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is \(note)")
    }
}

/// "Agent is in Checkout", over the page's lower trailing corner while the agent works in a tab
/// that is not the one shown (BrowserTabsElsewhere). Pressing it shows that tab.
public struct NWAgentElsewhere: View {
    let title: String
    let show: () -> Void

    public init(title: String, show: @escaping () -> Void) {
        self.title = title
        self.show = show
    }

    public var body: some View {
        Button(action: show) {
            HStack(spacing: NW.Space.s) {
                ProgressView().progressViewStyle(.nwSpinner(size: NWBrowserTabsMetrics.agentChipSpinner))
                    .frame(width: NWBrowserTabsMetrics.agentChipSpinner, height: NWBrowserTabsMetrics.agentChipSpinner)
                    .accessibilityHidden(true)
                Text("Agent is in \(title)").lineLimit(1).truncationMode(.tail)
            }
        }
        .buttonStyle(.nw(.secondary, size: .s))
        .fixedSize()
        .nwHelp("Show the tab the agent is using")
        .accessibilityLabel("Agent is in \(title). Show it")
    }
}
