import SwiftUI

/// The side pane's and the branch chip's fixed measures (PaneStates, Main boards).
public enum NWSidePaneMetrics {
    /// Narrower than this, the tab strip drops its labels; glyphs, counts and dots stay.
    public static let labelsMinWidth: CGFloat = 480
    /// The dot on a tab pi opened something in, and on the header button.
    public static let tabDot: CGFloat = 6
    public static let buttonDot: CGFloat = 8
    /// The branch chip: 24pt, its glyph 12pt, the host's 10pt, the chevron 9pt.
    public static let chipGlyph: CGFloat = 12
    public static let chipHostGlyph: CGFloat = 10
    public static let chipChevron: CGFloat = 9
    public static let chipLabelSize: CGFloat = 11
    public static let chipHostSize: CGFloat = 10.5
    /// The "pi opened something" tip under the header button.
    public static let tipWidth: CGFloat = 330
    /// A tab's glyph and side padding (a little tighter without its label).
    public static let tabGlyph: CGFloat = 14
    public static let tabPadding: CGFloat = 10
    public static let narrowTabPadding: CGFloat = 9

    /// Whether a strip `width` wide shows its tabs' labels.
    public static func showsLabels(width: CGFloat) -> Bool { width >= labelsMinWidth }
}

// MARK: Branch chip

/// The branch chip beside the thread's title (Main, QuestionAsk, TerminalSplit boards): where the
/// agent works. A worktree Shepherd made reads "⧉ pi/swiftui-previews ●3"; the space's own
/// checkout reads "⌂ chore/remove-homarr your checkout ●11" in lantern, since pi edits your
/// files there. The count is files changed in that checkout (left out at zero), and a remote
/// host trails it ("▭ horizon").
public struct NWBranchChip: View {
    public enum Kind: Equatable, Sendable {
        case worktree, checkout
    }

    let kind: Kind
    let branch: String
    let changedFiles: Int
    let host: String?
    let showsChevron: Bool

    public init(kind: Kind, branch: String, changedFiles: Int, host: String? = nil, showsChevron: Bool = true) {
        self.kind = kind
        self.branch = branch
        self.changedFiles = changedFiles
        self.host = host
        self.showsChevron = showsChevron
    }

    public var body: some View {
        let nw = Color.nw
        let checkout = kind == .checkout
        HStack(spacing: NW.Space.s) {
            Image(systemName: checkout ? "house" : "square.on.square")
                .font(.system(size: NWSidePaneMetrics.chipGlyph, weight: .medium))
                .foregroundStyle(checkout ? nw.lanternText : nw.textSecondary)
            Text(branch)
                .font(.nw(.mono))
                .foregroundStyle(checkout ? nw.lanternText : nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(-1)
            if checkout {
                Text("your checkout")
                    .font(.nwSans(NWSidePaneMetrics.chipLabelSize))
                    .foregroundStyle(nw.lanternText)
                    .lineLimit(1)
                    .fixedSize()
            }
            if changedFiles > 0 {
                Text("●\(changedFiles)")
                    .font(.nw(.micro, weight: .regular))
                    .foregroundStyle(nw.lanternText)
                    .fixedSize()
                    .nwContentTransition(.numeric())
            }
            if let host {
                HStack(spacing: NW.Space.xxs) {
                    Image(systemName: "display")
                        .font(.system(size: NWSidePaneMetrics.chipHostGlyph))
                    Text(host).lineLimit(1)
                }
                .font(.nwSans(NWSidePaneMetrics.chipHostSize))
                .foregroundStyle(nw.textTertiary)
                .fixedSize()
            }
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: NWSidePaneMetrics.chipChevron, weight: .semibold))
                    .foregroundStyle(checkout ? nw.lanternText : nw.textTertiary)
            }
        }
        .padding(.horizontal, NW.Space.m)
        .frame(height: NW.Height.controlS)
        .background(checkout ? nw.lanternTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .nwBorder(checkout ? nw.lantern : nw.lineStrong, radius: NW.Radius.s)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(kind: kind, branch: branch, changedFiles: changedFiles, host: host))
    }

    /// "Worktree, pi/x, 3 files changed, on horizon".
    public static func accessibilityLabel(kind: Kind, branch: String, changedFiles: Int, host: String?) -> String {
        [kind == .worktree ? "Worktree" : "Your checkout", branch,
         changedFiles > 0 ? "\(changedFiles) file\(changedFiles == 1 ? "" : "s") changed" : nil,
         host.map { "on \($0)" }].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: Header button

/// The one side-pane button in the thread's header (`SidePaneButton`, PaneStates): shows or
/// hides the pane, lit while it shows. When pi opens something for the pane while it is closed,
/// the button takes an 8pt running dot instead of the pane opening, and a tip under it says what
/// ("pi opened a review in Changes ⇧⌘B") for a few seconds, and again while it is hovered.
public struct NWSidePaneButton: View {
    let isOn: Bool
    let news: String?
    let shortcut: String?
    let action: () -> Void
    @State private var tipShown = false
    @State private var hovering = false

    public init(isOn: Bool, news: String? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.isOn = isOn
        self.news = news
        self.shortcut = shortcut
        self.action = action
    }

    public var body: some View {
        let label = isOn ? "Hide side pane" : "Show side pane"
        Button(action: action) { Image(systemName: "sidebar.right") }
            .buttonStyle(.nwIcon(isOn: isOn))
            .overlay(alignment: .topTrailing) { NWToggleBadge(visible: news != nil) }
            .nwHelp(news.map { "\(label) · \($0)" } ?? label, shortcut: shortcut)
            .accessibilityLabel(label)
            .accessibilityValue(news ?? "")
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) {
                if let news, tipShown || hovering {
                    NWPaneNewsTip(news, shortcut: shortcut)
                        .fixedSize()
                        .offset(y: NW.Height.controlM + NW.Space.s)
                        .allowsHitTesting(false)
                        .nwTransition(.overlay, edge: .top)
                }
            }
            .nwAnimation(.overlay, value: tipShown || hovering)
            // Each new thing pi opens shows the tip for a moment.
            .task(id: news) {
                guard news != nil else { tipShown = false; return }
                tipShown = true
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { tipShown = false }
            }
    }
}

/// What pi opened, under the header button or a tab (PaneStates): a raised card with a glyph,
/// the sentence, and the pane's chord as keycaps.
public struct NWPaneNewsTip: View {
    let text: String
    let shortcut: String?

    public init(_ text: String, shortcut: String? = nil) {
        self.text = text
        self.shortcut = shortcut
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Image(systemName: "sparkles")
                .font(.system(size: NWSidePaneMetrics.chipGlyph))
                .foregroundStyle(Color.nw.textSecondary)
            Text(text)
                .font(.nw(.caption))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
            if let shortcut { NWKeycap(shortcut) }
        }
        .padding(.horizontal, NW.Space.m)
        .padding(.vertical, NW.Space.xs)
        .frame(maxWidth: NWSidePaneMetrics.tipWidth, alignment: .leading)
        .padding(NW.Space.xs)
        .nwPopover(radius: NW.Radius.l)
    }
}

// MARK: Tab strip

/// One tab of the side pane's strip.
public struct NWSidePaneTab: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let systemImage: String
    /// Files changed, new artifacts; nil shows none.
    public let count: Int?
    /// pi opened something there that you haven't looked at.
    public let news: Bool
    /// The chord that selects it ("⌃1").
    public let shortcut: String?

    public init(id: String, title: String, systemImage: String, count: Int? = nil, news: Bool = false, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.count = count
        self.news = news
        self.shortcut = shortcut
    }
}

/// The side pane's tab strip (`SidePaneTabs`, PaneStates, Review): 44pt so it lines up with the
/// toolbar, tabs 2pt apart, then the pane's ⋯ menu and close. A tab is 28pt: its glyph, its
/// label, and its count; the current one on `bgSelected`, semibold. A tab pi opened something
/// in carries a 6pt running dot. Under 480pt the labels drop; glyphs, counts and dots stay.
public struct NWSidePaneTabs<Options: View>: View {
    let tabs: [NWSidePaneTab]
    let selection: String
    let select: (String) -> Void
    let closeShortcut: String?
    let close: () -> Void
    /// While the pane is maximized (ChangesWide): Restore the thread, a bordered circle before the
    /// options.
    let restore: (() -> Void)?
    @ViewBuilder let options: () -> Options
    @State private var showsLabels = true

    public init(_ tabs: [NWSidePaneTab], selection: String, select: @escaping (String) -> Void,
                closeShortcut: String? = nil, close: @escaping () -> Void, restore: (() -> Void)? = nil,
                @ViewBuilder options: @escaping () -> Options) {
        self.tabs = tabs
        self.selection = selection
        self.select = select
        self.closeShortcut = closeShortcut
        self.close = close
        self.restore = restore
        self.options = options
    }

    public var body: some View {
        HStack(spacing: NW.Space.xxs) {
            ForEach(tabs) { tab in
                TabButton(tab: tab, isSelected: tab.id == selection, showsLabel: showsLabels) { select(tab.id) }
            }
            Spacer(minLength: NW.Space.m)
            HStack(spacing: NW.Space.xs) {
                if let restore {
                    Button(action: restore) { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                        .buttonStyle(.nwIcon(bordered: true))
                        .nwHelp("Restore the thread")
                        .accessibilityLabel("Restore the thread")
                }
                NWOptionsMenu("Pane options", content: options)
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.nwIcon)
                    .nwHelp("Hide side pane", shortcut: closeShortcut)
                    .accessibilityLabel("Hide side pane")
            }
        }
        .padding(.horizontal, NWSidePaneMetrics.tabPadding)
        .frame(height: NWToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
        .onGeometryChange(for: Bool.self) { NWSidePaneMetrics.showsLabels(width: $0.size.width) } action: { showsLabels = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Side pane tabs")
    }

    private struct TabButton: View {
        let tab: NWSidePaneTab
        let isSelected: Bool
        let showsLabel: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            let nw = Color.nw
            Button(action: action) {
                HStack(spacing: NW.Space.s) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: NWSidePaneMetrics.tabGlyph, weight: .medium))
                    if showsLabel {
                        Text(tab.title)
                            .font(.nw(.ui, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    if let count = tab.count {
                        Text("\(count)")
                            .font(.nw(.micro, weight: .regular))
                            .foregroundStyle(nw.textTertiary)
                            .nwContentTransition(.numeric())
                    }
                    if tab.news {
                        Circle().fill(nw.running)
                            .frame(width: NWSidePaneMetrics.tabDot, height: NWSidePaneMetrics.tabDot)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(isSelected || hovering ? nw.textPrimary : nw.textSecondary)
                .padding(.horizontal, showsLabel ? NWSidePaneMetrics.tabPadding : NWSidePaneMetrics.narrowTabPadding)
                .frame(height: NW.Height.controlM)
                .background(isSelected ? nw.bgSelected : hovering ? nw.bgHover : .clear,
                            in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .nwAnimation(.hover, value: hovering)
            .nwHelp(tab.title, shortcut: tab.shortcut)
            .accessibilityLabel(tab.title)
            .accessibilityValue([tab.count.map { "\($0)" }, tab.news ? "pi opened something" : nil].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }
}
