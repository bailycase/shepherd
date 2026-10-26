import SwiftUI

// The Browser's tabs (BrowserTabsAgent, -Elsewhere, -Full, -Opened, -Popup, -Two): a 38pt strip of
// pages under the side pane's tabs, the list of every tab, a note under the strip, and the two
// ways the agent shows it is using a page. All of it takes plain values; the app owns the pages.

public enum SHBrowserTabsMetrics {
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
    public static let agentBarHeight: CGFloat = SHBrowserMetrics.consoleBarHeight
    public static let agentSpinner: CGFloat = 11
    public static let agentChipSpinner: CGFloat = 12
    public static let agentTakeOverGlyph: CGFloat = 12
}

/// What fills a tab's tile: the board's four colors (BrowserTabsTwo, -Full). A page on this Mac's own
/// loopback is `running`; any other host gets one of the other three by a fixed hash of its site name,
/// so a site keeps its color. The board colors by brand and the app knows no brands, so a site can
/// land on a different one of the three than the board gave it.
public enum SHBrowserTabTint: Int, CaseIterable, Sendable {
    case running, done, violet, orange

    public func color(_ sh: SHPalette) -> Color {
        switch self {
        case .running: sh.running
        case .done: sh.done
        case .violet: sh.tabTileViolet
        case .orange: sh.tabTileOrange
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

    public static func forHost(_ host: String) -> SHBrowserTabTint {
        let bare = withoutPort(host)
        if bare.isEmpty || bare == "localhost" || bare == "[::1]" || bare.hasPrefix("127.") { return .running }
        let others: [SHBrowserTabTint] = [.done, .violet, .orange]
        let sum = siteName(host: host).unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return others[sum % others.count]
    }
}

/// The outline cross that closes a tab and dismisses the note under the strip: one place for the two uses.
/// It is not an `SHGlyph` case: the registry polices a raw `"xmark"` everywhere, and the app has 45 older
/// uses of it that are not this view's to change.
struct SHBrowserTabClose: View {
    var body: some View { Image(systemName: "xmark") }
}

/// How a tab came to be, as the list's trailing tag says it.
public enum SHBrowserTabSource: Sendable {
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
public struct SHBrowserTabItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    /// The address as the field shows it ("localhost:3000/checkout"); empty for a page not yet opened.
    public let address: String
    public let letter: String
    public let tint: SHBrowserTabTint
    public let source: SHBrowserTabSource
    /// The agent is using this page now: a spinner stands in for the favicon.
    public let agentActive: Bool
    /// The agent opened it and nobody has looked yet: a 6pt dot.
    public let unseen: Bool

    public init(id: UUID, title: String, address: String, letter: String, tint: SHBrowserTabTint, source: SHBrowserTabSource = .user,
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

public struct SHBrowserTabStrip: View {
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

    let items: [SHBrowserTabItem]
    let selection: UUID?
    let canAdd: Bool
    let listOpen: Bool
    let newShortcut: String?
    let actions: Actions

    public init(items: [SHBrowserTabItem], selection: UUID?, canAdd: Bool, listOpen: Bool, newShortcut: String? = nil, actions: Actions) {
        self.items = items
        self.selection = selection
        self.canAdd = canAdd
        self.listOpen = listOpen
        self.newShortcut = newShortcut
        self.actions = actions
    }

    public var body: some View {
        HStack(spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.xxs) {
                ForEach(items) { item in
                    Tab(item: item, selected: item.id == selection, showClose: items.count <= SHBrowserTabsMetrics.roomyTabs,
                        select: { actions.select(item.id) }, close: { actions.close(item.id) })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages in this thread")
            Button(action: actions.new) { Image(systemName: "plus").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.shIcon(size: SH.Height.controlS))
                .disabled(!canAdd)
                .shHelp(canAdd ? "New tab" : "This thread has the most tabs it keeps", shortcut: canAdd ? newShortcut : nil)
                .accessibilityLabel("New tab")
            Button(action: actions.toggleList) { Image(systemName: "chevron.down").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.shIcon(size: SH.Height.controlS))
                .shHelp("All tabs")
                .accessibilityLabel("All tabs")
                .accessibilityValue(listOpen ? "open" : "closed")
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHBrowserTabsMetrics.stripHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private struct Tab: View {
        let item: SHBrowserTabItem
        let selected: Bool
        let showClose: Bool
        let select: () -> Void
        let close: () -> Void
        @State private var hovering = false

        var body: some View {
            let sh = Color.sh
            HStack(spacing: 0) {
                Button(action: select) {
                    HStack(spacing: SH.Space.s) {
                        if item.agentActive {
                            ProgressView().progressViewStyle(.shSpinner(size: SHBrowserTabsMetrics.favicon)).accessibilityHidden(true)
                                .frame(width: SHBrowserTabsMetrics.favicon, height: SHBrowserTabsMetrics.favicon)
                        } else {
                            SHBrowserFavicon(letter: item.letter, tint: item.tint)
                        }
                        Text(item.title)
                            .font(.sh(.ui, weight: selected ? .medium : .regular))
                            .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if item.unseen {
                            Circle().fill(sh.running).frame(width: SHBrowserTabsMetrics.unseenDot, height: SHBrowserTabsMetrics.unseenDot)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, SH.Space.m)
                    .padding(.trailing, SH.Space.s)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: SHBrowserTabsMetrics.tabHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shFocusRing()
                .shHelp(item.tooltip.isEmpty ? item.title : item.tooltip)
                .accessibilityLabel(item.spoken)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if selected || showClose || hovering {
                    Button(action: close) {
                        SHBrowserTabClose().font(.system(size: SHBrowserTabsMetrics.closeGlyph, weight: .medium))
                            .foregroundStyle(hovering ? sh.textPrimary : sh.textTertiary)
                            .frame(width: SHBrowserTabsMetrics.closeWidth, height: SHBrowserTabsMetrics.tabHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shFocusRing()
                    .shHelp("Close tab")
                    .accessibilityLabel("Close \(item.title)")
                }
            }
            .frame(minWidth: SHBrowserTabsMetrics.tabMinWidth, maxWidth: SHBrowserTabsMetrics.tabMaxWidth)
            .background(selected ? sh.bgSelected : hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .layoutPriority(selected ? 1 : 0)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
        }
    }
}

/// A page's tile: its first letter on a themed square.
public struct SHBrowserFavicon: View {
    let letter: String
    let tint: SHBrowserTabTint

    public init(letter: String, tint: SHBrowserTabTint) {
        self.letter = letter
        self.tint = tint
    }

    public var body: some View {
        let sh = Color.sh
        Text(letter.prefix(1).uppercased())
            .font(.shSans(SHBrowserTabsMetrics.faviconLetter, .semibold))
            .foregroundStyle(sh.bgBase)
            .frame(width: SHBrowserTabsMetrics.favicon, height: SHBrowserTabsMetrics.favicon)
            .background(tint.color(sh), in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            .accessibilityHidden(true)
    }
}

// MARK: The list

/// Every tab, the chosen one checked, with Close other tabs under a divider and the count and the
/// sign-in line at its foot (BrowserTabsFull).
public struct SHBrowserTabMenu: View {
    let items: [SHBrowserTabItem]
    let selection: UUID?
    let maxTabs: Int
    let select: (UUID) -> Void
    let closeOthers: () -> Void
    @State private var rowsHeight: CGFloat = 0

    public init(items: [SHBrowserTabItem], selection: UUID?, maxTabs: Int, select: @escaping (UUID) -> Void,
                closeOthers: @escaping () -> Void) {
        self.items = items
        self.selection = selection
        self.maxTabs = maxTabs
        self.select = select
        self.closeOthers = closeOthers
    }

    public var body: some View {
        let sh = Color.sh
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
            .frame(height: min(rowsHeight, SHBrowserTabsMetrics.menuListMaxHeight))
            SHChangesMenuDivider()
            Button(action: closeOthers) {
                Text("Close other tabs").font(.sh(.ui, weight: .regular))
                    .foregroundStyle(items.count > 1 ? sh.textPrimary : sh.textTertiary)
                    .padding(.horizontal, SH.Space.m)
                    .frame(maxWidth: .infinity, minHeight: SHBrowserTabsMetrics.menuRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.shRow())
            .disabled(items.count < 2)
            Text("\(items.count) of \(maxTabs) tabs · sign-ins shared across the space")
                .font(.sh(.micro, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.Space.m)
                .padding(.top, SH.Space.s)
                .padding(.bottom, SH.Space.xs)
        }
        .padding(SH.Space.s)
        .frame(width: SHBrowserTabsMetrics.menuWidth)
        .shPopover()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All tabs")
    }

    private struct Row: View {
        let item: SHBrowserTabItem
        let checked: Bool
        let action: () -> Void

        var body: some View {
            let sh = Color.sh
            Button(action: action) {
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "checkmark").font(.system(size: SHBrowserTabsMetrics.menuCheckGlyph, weight: .semibold))
                        .foregroundStyle(sh.textPrimary).opacity(checked ? 1 : 0)
                        .frame(width: SHBrowserTabsMetrics.menuCheckWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(item.title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                        if !item.address.isEmpty {
                            Text(item.address).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let tag = item.source.tag {
                        Text(tag).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary)
                    }
                }
                .padding(.horizontal, SH.Space.m)
                .padding(.vertical, SH.Space.s)
                .frame(minHeight: SHBrowserTabsMetrics.menuRowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.shRow(selected: false))
            .accessibilityLabel([item.title, item.address.isEmpty ? nil : item.address, item.source.tag].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
    }
}

// MARK: The note

/// A line under the strip on `bgSunken` (BrowserTabsOpened, -Popup, -Full): a 13pt glyph, the
/// words in `caption`, an optional action, and a dismiss button. The app supplies the words.
public struct SHBrowserTabsNote: View {
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

    public init(message: String, glyph: String = SHBrowserTabsNote.globeGlyph, action: Action? = nil, dismiss: @escaping () -> Void) {
        self.message = message
        self.glyph = glyph
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: glyph).font(.system(size: SHBrowserTabsMetrics.noteGlyph)).foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(message).font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                Button(action.title, action: action.run).buttonStyle(.sh(.secondary, size: .s)).fixedSize()
            }
            Button(action: dismiss) { SHBrowserTabClose().font(.system(size: SHBrowserTabsMetrics.closeGlyph, weight: .medium)) }
                .buttonStyle(.shIcon(size: SHBrowserTabsMetrics.noteDismiss, tint: sh.textTertiary))
                .padding(.vertical, -SH.Space.xxs)
                .shHelp("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.s)
        .frame(maxWidth: .infinity)
        .background(sh.bgSunken)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: The agent

/// "Agent is filling the checkout form" with Take over, a bar over the console (BrowserTabsAgent):
/// `runningTint`, a hairline above, the words in `caption`, an 11pt `running` spinner.
public struct SHAgentBar: View {
    public static let glyph = "hand.raised"

    let note: String
    let takeOver: () -> Void

    public init(note: String, takeOver: @escaping () -> Void) {
        self.note = note
        self.takeOver = takeOver
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            ProgressView().progressViewStyle(.shSpinner(size: SHBrowserTabsMetrics.agentSpinner))
                .frame(width: SHBrowserTabsMetrics.agentSpinner, height: SHBrowserTabsMetrics.agentSpinner)
                .accessibilityHidden(true)
            Text("Agent is \(note)").font(.sh(.caption, weight: .regular)).foregroundStyle(sh.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: takeOver) {
                Label("Take over", systemImage: Self.glyph)
            }
            .buttonStyle(.sh(.secondary, size: .s))
            .fixedSize()
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(height: SHBrowserTabsMetrics.agentBarHeight)
        .background(sh.runningTint)
        .overlay(alignment: .top) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is \(note)")
    }
}

/// "Agent is in Checkout", over the page's lower trailing corner while the agent works in a tab
/// that is not the one shown (BrowserTabsElsewhere). Pressing it shows that tab.
public struct SHAgentElsewhere: View {
    let title: String
    let show: () -> Void

    public init(title: String, show: @escaping () -> Void) {
        self.title = title
        self.show = show
    }

    public var body: some View {
        Button(action: show) {
            HStack(spacing: SH.Space.s) {
                ProgressView().progressViewStyle(.shSpinner(size: SHBrowserTabsMetrics.agentChipSpinner))
                    .frame(width: SHBrowserTabsMetrics.agentChipSpinner, height: SHBrowserTabsMetrics.agentChipSpinner)
                    .accessibilityHidden(true)
                Text("Agent is in \(title)").lineLimit(1).truncationMode(.tail)
            }
        }
        .buttonStyle(.sh(.secondary, size: .s))
        .fixedSize()
        .shHelp("Show the tab the agent is using")
        .accessibilityLabel("Agent is in \(title). Show it")
    }
}
