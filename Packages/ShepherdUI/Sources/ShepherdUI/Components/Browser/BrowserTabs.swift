import SwiftUI

// The Browser's tabs (BrowserTabsAgent, -Elsewhere, -Full, -Opened, -Popup, -Two): a 38pt strip of
// pages under the side pane's tabs, the list of every tab, a note under the strip, and the two
// ways the agent shows it is using a page. All of it takes plain values; the app owns the pages.

public enum SHBrowserTabsMetrics {
    /// The strip under the pane's tabs.
    public static let stripHeight: CGFloat = 38
    #if os(macOS)
    /// GXPaneBrowserTabs: a tab is 28pt and at most 176pt wide, down to 56pt when many share the strip
    /// (the board draws 72; eight fit a pane narrower than its 720pt this way).
    public static let tabHeight: CGFloat = 28
    public static let tabMinWidth: CGFloat = 56
    public static let tabMaxWidth: CGFloat = 176
    #else
    public static let tabHeight: CGFloat = 26
    public static let tabMinWidth: CGFloat = 64
    public static let tabMaxWidth: CGFloat = 200
    #endif
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
    /// The Mac's agent line under the page (GXPaneBrowserAgent's `.astat`): 34pt.
    public static let agentStatusHeight: CGFloat = 34
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
    /// The agent is using this page now: its title shimmers.
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

public struct SHBrowserTabStrip<ListButtonModifier: ViewModifier>: View {
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
    let touch: Bool
    let actions: Actions
    let listButtonModifier: ListButtonModifier

    public init(items: [SHBrowserTabItem], selection: UUID?, canAdd: Bool, listOpen: Bool, newShortcut: String? = nil,
                touch: Bool = false, actions: Actions, listButtonModifier: ListButtonModifier) {
        self.items = items
        self.selection = selection
        self.canAdd = canAdd
        self.listOpen = listOpen
        self.newShortcut = newShortcut
        self.touch = touch
        self.actions = actions
        self.listButtonModifier = listButtonModifier
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if os(macOS)
    /// GXPaneBrowserTabs: the tabs with + right after the last, and the list's chevron at the end. The board
    /// draws the chevron only with many tabs, and no strip for one page; both stay so New tab and All tabs
    /// are always a click away.
    private var macBody: some View {
        HStack(spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.xxs) {
                tabs
                Button(action: actions.new) { Image(systemName: "plus").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                    .buttonStyle(.shIcon)
                    .disabled(!canAdd)
                    .shHelp(canAdd ? "New tab" : "This thread has the most tabs it keeps", shortcut: canAdd ? newShortcut : nil)
                    .accessibilityLabel("New tab")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages in this thread")
            Button(action: actions.toggleList) { Image(systemName: "chevron.down").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.shIcon(isOn: listOpen))
                .shHelp("All tabs")
                .accessibilityLabel("All tabs")
                .accessibilityValue(listOpen ? "open" : "closed")
                .modifier(listButtonModifier)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHBrowserTabsMetrics.stripHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }
    #endif

    private var touchBody: some View {
        HStack(spacing: SH.Space.xxs) {
            Group {
                if touch {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) { tabs }
                            .scrollIndicators(.hidden)
                            .onChange(of: selection, initial: true) { _, id in
                                if let id { proxy.scrollTo(id) }
                            }
                    }
                } else {
                    tabs
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pages in this thread")
            Button(action: actions.new) { Image(systemName: "plus").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.shIcon(size: touch ? SH.Height.touch : SH.Height.controlS))
                .disabled(!canAdd)
                .shHelp(canAdd ? "New tab" : "This thread has the most tabs it keeps", shortcut: canAdd ? newShortcut : nil)
                .accessibilityLabel("New tab")
            Button(action: actions.toggleList) { Image(systemName: "chevron.down").font(.system(size: SHBrowserTabsMetrics.stripGlyph)) }
                .buttonStyle(.shIcon(size: touch ? SH.Height.touch : SH.Height.controlS))
                .shHelp("All tabs")
                .accessibilityLabel("All tabs")
                .accessibilityValue(listOpen ? "open" : "closed")
                .modifier(listButtonModifier)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(height: touch ? SH.Height.touch : SHBrowserTabsMetrics.stripHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private var tabs: some View {
        HStack(spacing: SH.Space.xxs) {
            ForEach(items) { item in
                Tab(item: item, selected: item.id == selection, showClose: items.count <= SHBrowserTabsMetrics.roomyTabs,
                    touch: touch, select: { actions.select(item.id) }, close: { actions.close(item.id) })
            }
        }
    }

    private struct Tab: View {
        let item: SHBrowserTabItem
        let selected: Bool
        let showClose: Bool
        let touch: Bool
        let select: () -> Void
        let close: () -> Void
        @State private var hovering = false

        var body: some View {
            let sh = Color.sh
            HStack(spacing: 0) {
                Button(action: select) {
                    HStack(spacing: SH.Space.s) {
                        #if os(macOS)
                        // The board draws every page's tile as the plain globe.
                        Image(systemName: "globe").font(.system(size: SHBrowserTabsMetrics.favicon))
                            .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                            .frame(width: SHBrowserTabsMetrics.favicon, height: SHBrowserTabsMetrics.favicon)
                            .accessibilityHidden(true)
                        #else
                        SHBrowserFavicon(letter: item.letter, tint: item.tint)
                        #endif
                        // The agent using this page: its title shimmers.
                        Text(item.title)
                            .font(.sh(.ui, weight: Self.titleWeight(selected: selected)))
                            .shShimmer(active: item.agentActive)
                            .foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if item.unseen {
                            Circle().fill(sh.running).frame(width: SHBrowserTabsMetrics.unseenDot, height: SHBrowserTabsMetrics.unseenDot)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.leading, SH.Space.m)
                    #if os(macOS)
                    .padding(.trailing, SH.Space.xs)
                    #else
                    .padding(.trailing, SH.Space.s)
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minWidth: touch ? SH.Height.touch : nil)
                    .frame(height: touch ? SH.Height.touch : SHBrowserTabsMetrics.tabHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shFocusRing()
                .shHelp(item.tooltip.isEmpty ? item.title : item.tooltip)
                .accessibilityLabel(item.spoken)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if Self.alwaysClose || selected || showClose || hovering {
                    Button(action: close) {
                        SHBrowserTabClose().font(.system(size: SHBrowserTabsMetrics.closeGlyph, weight: .medium))
                            .foregroundStyle(hovering ? sh.textPrimary : sh.textTertiary)
                            .frame(width: touch ? SH.Height.touch : SHBrowserTabsMetrics.closeWidth,
                                   height: touch ? SH.Height.touch : SHBrowserTabsMetrics.tabHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shFocusRing()
                    .shHelp("Close tab")
                    .accessibilityLabel("Close \(item.title)")
                }
            }
            .frame(minWidth: SHBrowserTabsMetrics.tabMinWidth, maxWidth: SHBrowserTabsMetrics.tabMaxWidth)
            .background {
                RoundedRectangle(cornerRadius: SH.Radius.s)
                    .fill(selected ? sh.bgSelected : hovering ? sh.bgHover : .clear)
                    .frame(height: touch ? SH.Height.controlL : SHBrowserTabsMetrics.tabHeight)
            }
            .layoutPriority(selected ? 1 : 0)
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
        }

        /// The board shows a × on every tab, selected or not; on the Mac only (a touch tab shows it when roomy).
        private static var alwaysClose: Bool {
            #if os(macOS)
            true
            #else
            false
            #endif
        }

        /// The Mac's selected tab changes color only (`.btab.on`).
        private static func titleWeight(selected: Bool) -> Font.Weight {
            #if os(macOS)
            .regular
            #else
            selected ? .medium : .regular
            #endif
        }
    }
}

extension SHBrowserTabStrip where ListButtonModifier == EmptyModifier {
    public init(items: [SHBrowserTabItem], selection: UUID?, canAdd: Bool, listOpen: Bool, newShortcut: String? = nil,
                touch: Bool = false, actions: Actions) {
        self.init(items: items, selection: selection, canAdd: canAdd, listOpen: listOpen, newShortcut: newShortcut,
                  touch: touch, actions: actions, listButtonModifier: EmptyModifier())
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
    let touch: Bool
    let note: LocalizedStringKey
    let select: (UUID) -> Void
    let closeOthers: () -> Void
    @State private var rowsHeight: CGFloat = 0

    public init(items: [SHBrowserTabItem], selection: UUID?, maxTabs: Int, touch: Bool = false,
                note: LocalizedStringKey = "sign-ins shared across the space", select: @escaping (UUID) -> Void,
                closeOthers: @escaping () -> Void) {
        self.items = items
        self.selection = selection
        self.maxTabs = maxTabs
        self.touch = touch
        self.note = note
        self.select = select
        self.closeOthers = closeOthers
    }

    public var body: some View {
        Group {
            if touch {
                menuContent
            } else {
                menuContent.frame(width: SHBrowserTabsMetrics.menuWidth).shPopover()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("All tabs")
    }

    #if os(macOS)
    /// GXPaneBrowserTabs' list: how many tabs there are, a globe and the title per tab (the chosen one filled),
    /// Close other tabs under a rule, and the foot's line. A tab's address is its tooltip.
    private var menuContent: some View {
        let sh = Color.sh
        let listHeight = min(rowsHeight, SHBrowserTabsMetrics.menuListMaxHeight)
        return VStack(alignment: .leading, spacing: 0) {
            Text(items.count >= maxTabs ? "\(items.count) tabs, the most a thread keeps" : "\(items.count) of \(maxTabs) tabs")
                .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: SHChangesMenuMetrics.titleHeight + SH.Space.xxs, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Row(item: item, checked: item.id == selection, minHeight: SHBrowserTabsMetrics.menuRowMinHeight) { select(item.id) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: listHeight, maxHeight: listHeight)
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
            Text(items.count >= maxTabs ? "Close a tab to open another" : note)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: SHBrowserTabsMetrics.menuRowMinHeight, alignment: .leading)
        }
        .padding(SH.Space.s)
    }

    private struct Row: View {
        let item: SHBrowserTabItem
        let checked: Bool
        let minHeight: CGFloat
        let action: () -> Void

        var body: some View {
            let sh = Color.sh
            Button(action: action) {
                HStack(spacing: SH.Space.l) {
                    Image(systemName: "globe").font(.sh(.caption)).foregroundStyle(sh.textSecondary)
                        .frame(width: SH.Space.xl)
                        .accessibilityHidden(true)
                    Text(item.title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    if let tag = item.source.tag {
                        Text(tag).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    }
                }
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.shRow(selected: checked))
            .shHelp(item.tooltip.isEmpty ? item.title : item.tooltip)
            .accessibilityLabel([item.title, item.address.isEmpty ? nil : item.address, item.source.tag].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
    }
    #else
    private var menuContent: some View {
        let sh = Color.sh
        let listHeight = min(rowsHeight, SHBrowserTabsMetrics.menuListMaxHeight)
        return VStack(alignment: .leading, spacing: 0) {
            // Rows keep their height; a menu taller than the pane scrolls instead of squeezing them.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        Row(item: item, checked: item.id == selection,
                            minHeight: touch ? SH.Height.touch : SHBrowserTabsMetrics.menuRowMinHeight) { select(item.id) }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: touch ? nil : listHeight, idealHeight: touch ? listHeight : nil, maxHeight: listHeight)
            SHChangesMenuDivider()
            Button(action: closeOthers) {
                Text("Close other tabs").font(.sh(.ui, weight: .regular))
                    .foregroundStyle(items.count > 1 ? sh.textPrimary : sh.textTertiary)
                    .padding(.horizontal, SH.Space.m)
                    .frame(maxWidth: .infinity, minHeight: touch ? SH.Height.touch : SHBrowserTabsMetrics.menuRowMinHeight, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.shRow())
            .disabled(items.count < 2)
            Text("\(items.count) of \(maxTabs) tabs · \(Text(note))")
                .font(.sh(.micro, weight: .regular))
                .foregroundStyle(sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SH.Space.m)
                .padding(.top, SH.Space.s)
                .padding(.bottom, SH.Space.xs)
        }
        .padding(SH.Space.s)
    }

    private struct Row: View {
        let item: SHBrowserTabItem
        let checked: Bool
        let minHeight: CGFloat
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
                .frame(minHeight: minHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.shRow(selected: false))
            .accessibilityLabel([item.title, item.address.isEmpty ? nil : item.address, item.source.tag].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(checked ? .isSelected : [])
        }
    }
    #endif
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
    let touch: Bool
    let dismiss: () -> Void

    /// The glyph the cap warns with; every other note is the globe.
    public static let capGlyph = "exclamationmark.triangle"
    public static let globeGlyph = "globe"

    public init(message: String, glyph: String = SHBrowserTabsNote.globeGlyph, action: Action? = nil, touch: Bool = false,
                dismiss: @escaping () -> Void) {
        self.message = message
        self.glyph = glyph
        self.action = action
        self.touch = touch
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
                .buttonStyle(.shIcon(size: touch ? SH.Height.touch : SHBrowserTabsMetrics.noteDismiss, tint: sh.textTertiary))
                .padding(.vertical, touch ? 0 : -SH.Space.xxs)
                .shHelp("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, touch ? 0 : SH.Space.s)
        .frame(maxWidth: .infinity)
        .background(sh.bgSunken)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: The agent

/// "Agent is filling the checkout form" with Take over, a bar over the console (BrowserTabsAgent):
/// `runningTint`, a hairline above, the words in `caption`, shimmering.
public struct SHAgentBar: View {
    public static let glyph = "hand.raised"

    let note: String
    let takeOver: () -> Void

    public init(note: String, takeOver: @escaping () -> Void) {
        self.note = note
        self.takeOver = takeOver
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if os(macOS)
    /// GXPaneBrowserAgent's `.astat`: 34pt on the pane, "The agent is typing the test card" in `textSecondary`
    /// and Take over in ink, no tint or rule (the page's ring says the agent is there).
    private var macBody: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            Text("The agent is \(note)").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: takeOver) { Text("Take over").frame(minHeight: SH.Height.controlS) }
                .buttonStyle(.shLink(color: sh.textPrimary, font: .sh(.ui, weight: .medium)))
                .fixedSize()
                .padding(.trailing, SH.Space.s)
        }
        .padding(.leading, SH.Space.l)
        .padding(.horizontal, SH.Space.m)
        .frame(height: SHBrowserTabsMetrics.agentStatusHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is \(note)")
    }
    #endif

    private var touchBody: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            Text("Agent is \(note)").font(.sh(.caption, weight: .regular)).shShimmer(active: true).foregroundStyle(sh.textPrimary)
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
                Text("Agent is in \(title)").lineLimit(1).truncationMode(.tail).shShimmer(active: true)
            }
        }
        .buttonStyle(.sh(.secondary, size: .s))
        .fixedSize()
        .shHelp("Show the tab the agent is using")
        .accessibilityLabel("Agent is in \(title). Show it")
    }
}
