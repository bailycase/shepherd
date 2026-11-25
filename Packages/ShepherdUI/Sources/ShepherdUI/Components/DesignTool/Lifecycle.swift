import SwiftUI

// Deleting and importing designs (DesignLifecycleStates): the dialogs, the toast, the drop
// target over Designs, the card an import is filling, and a card's •••. Each takes values and
// closures; what they say and do is the app's.

// MARK: - Sheets

/// A sheet of the Design tool (DeleteDesignDialog, DeleteSystemDialog, ImportErrorDialog,
/// ImportAgainDialog; the boards' `.gdz-sheet`): on `bgRaised`, 20pt in at the sides, 18 over its
/// title and 16 under its buttons. The title is in `title` (15 semibold); `content` follows it;
/// the footer puts `leading` (a "Don't ask again" check) at the front and the buttons at the end,
/// 18pt apart. The sheet it sits in draws the window's corners and shadow.
public struct SHDesignSheet<Content: View, Leading: View, Actions: View>: View {
    let title: String
    let width: CGFloat
    let content: Content
    let leading: Leading
    let actions: Actions

    public init(title: String, width: CGFloat = SHDesignSheetMetrics.width, @ViewBuilder content: () -> Content,
                @ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.width = width
        self.content = content()
        self.leading = leading()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.shSans(SHDesignSheetMetrics.titleSize, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content
            HStack(spacing: SHDesignSheetMetrics.footerSpacing) {
                leading
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, SHDesignSheetMetrics.footerTop)
        }
        .padding(.top, SHDesignSheetMetrics.paddingTop)
        .padding(.horizontal, SHDesignSheetMetrics.paddingHorizontal)
        .padding(.bottom, SHDesignSheetMetrics.paddingBottom)
        .frame(width: width, alignment: .leading)
        .background(Color.sh.bgRaised)
    }
}

extension SHDesignSheet where Leading == EmptyView {
    public init(title: String, width: CGFloat = SHDesignSheetMetrics.width, @ViewBuilder content: () -> Content,
                @ViewBuilder actions: () -> Actions) {
        self.init(title: title, width: width, content: content, leading: { EmptyView() }, actions: actions)
    }
}

/// The sheets' measures (the boards' `.gdz-sheet`).
public enum SHDesignSheetMetrics {
    public static let width: CGFloat = 460
    public static let wideWidth: CGFloat = 520
    public static let paddingTop: CGFloat = 18
    public static let paddingHorizontal: CGFloat = 20
    public static let paddingBottom: CGFloat = SH.Space.xl
    public static let titleSize: CGFloat = 15
    public static let footerTop: CGFloat = 18
    public static let footerSpacing: CGFloat = 18
    /// The message under the title, the facts under that (14pt, a hairline, 12pt more), a note
    /// under them, and a warning over them.
    public static let messageTop: CGFloat = SH.Space.m
    public static let factsTop: CGFloat = 14
    public static let factsPadding: CGFloat = SH.Space.l
    public static let factsRowSpacing: CGFloat = SH.Space.xs
    public static let factLabelWidth: CGFloat = 64
    public static let noteTop: CGFloat = SH.Space.l
    public static let warningTop: CGFloat = SH.Space.l
    public static let warningPaddingVertical: CGFloat = 9
    public static let warningRadius: CGFloat = 10
    /// The line height the boards set (19pt at 13) and a note's (17pt at 12), as leading over the face's own.
    public static let messageLineSpacing: CGFloat = 3
    public static let noteLineSpacing: CGFloat = 2
    public static let checkbox: CGFloat = 14
    public static let checkboxSpacing: CGFloat = 10
    /// The footer's buttons: a pill 26pt tall, 11pt in, in 12 medium.
    public static let pillHeight: CGFloat = 26
    public static let pillPadding: CGFloat = 11
    public static let pillTextSize: CGFloat = 12
    public static let monoSize: CGFloat = 12
    public static let linkSize: CGFloat = 11.5
}

/// A sheet's message in `ui` `textSecondary`, 8pt under the title: pass bold names and mono paths
/// as `Text` spans.
public struct SHDesignAlertMessage: View {
    let text: Text

    public init(_ text: Text) { self.text = text }
    public init(_ string: String) { self.text = Text(string) }

    public var body: some View {
        text
            .font(.sh(.ui))
            .foregroundStyle(Color.sh.textSecondary)
            .lineSpacing(SHDesignSheetMetrics.messageLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .padding(.top, SHDesignSheetMetrics.messageTop)
    }

    /// A span in the message's `textPrimary` semibold ("Checkout funnel").
    public static func strong(_ string: String) -> Text {
        Text(string).fontWeight(.semibold).foregroundStyle(Color.sh.textPrimary)
    }

    /// A span in mono, `textPrimary` ("canvas.json", "mobile-app").
    public static func mono(_ string: String, size: CGFloat = SHDesignSheetMetrics.monoSize) -> Text {
        Text(string).font(.shMono(size)).foregroundStyle(Color.sh.textPrimary)
    }
}

/// What a sheet lists under a hairline (the boards' `.gdz-kv`): a 64pt column of labels in
/// `textTertiary` ("Goes", "Stays", "New copy") and the facts in `textPrimary`, 4pt apart. A fact
/// with no label belongs to the one above it.
public struct SHDesignSheetFacts<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: SHDesignSheetMetrics.factsRowSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, SHDesignSheetMetrics.factsPadding)
            .overlay(alignment: .top) { SHHairline() }
            .padding(.top, SHDesignSheetMetrics.factsTop)
    }
}

/// One line of the facts: its label (or none) and its words.
public struct SHDesignSheetFact: View {
    let label: String?
    let text: Text

    public init(_ label: String? = nil, _ text: Text) {
        self.label = label
        self.text = text
    }

    public var body: some View {
        GridRow(alignment: .top) {
            Text(label ?? "")
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textTertiary)
                .frame(width: SHDesignSheetMetrics.factLabelWidth, alignment: .leading)
                .accessibilityHidden(label == nil)
            text
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .lineSpacing(SHDesignSheetMetrics.messageLineSpacing - 1)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The line under a sheet's facts (the boards' `.nt`): `caption` `textTertiary`, 12pt under them.
public struct SHDesignSheetNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .lineSpacing(SHDesignSheetMetrics.noteLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, SHDesignSheetMetrics.noteTop)
    }
}

/// A warning over the facts (DeleteDesignDialog while the agent draws): the words in `ui`
/// `textPrimary` on `lanternTint` at radius 10, 9×12 padding.
public struct SHDesignAlertWarning: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.ui))
            .foregroundStyle(Color.sh.textPrimary)
            .lineSpacing(SHDesignSheetMetrics.messageLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, SHDesignSheetMetrics.warningPaddingVertical)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SHDesignSheetMetrics.warningRadius))
            .padding(.top, SHDesignSheetMetrics.warningTop)
    }
}

/// The box a sheet lists paths in (an import's links that point outside): 10×12 padding, a hairline
/// at radius 8 on `bgSunken`.
public struct SHDesignAlertList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) { content }
            .padding(.vertical, 10)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .padding(.top, SHDesignSheetMetrics.factsTop)
    }
}

/// Paths that point out of a project (ImportErrorDialog › links outside): each "from → to" in
/// mono 11.5, the target in `failed`, up to three.
public struct SHDesignAlertLinks: View {
    public struct Link: Hashable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    let links: [Link]

    public init(_ links: [Link]) { self.links = links }

    public var body: some View {
        SHDesignAlertList {
            ForEach(links, id: \.self) { link in
                HStack(spacing: SH.Space.m) {
                    Text(link.from).foregroundStyle(Color.sh.textPrimary)
                    Text("→").font(.shSans(SHDesignSheetMetrics.monoSize)).foregroundStyle(Color.sh.textTertiary)
                    Text(link.to).foregroundStyle(Color.sh.failed)
                }
                .font(.shMono(SHDesignSheetMetrics.linkSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A sheet's check ("Don't ask again"): a 14pt box with a `textTertiary` line, `textPrimary`
/// filled with a check when on, then the words in `ui` `textSecondary`, 10pt on.
public struct SHDesignSheetCheckStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: SHDesignSheetMetrics.checkboxSpacing) {
                let box = RoundedRectangle(cornerRadius: SH.Radius.xs)
                box.fill(configuration.isOn ? Color.sh.textPrimary : .clear)
                    .overlay {
                        Image(systemName: "checkmark")
                            .font(.shSans(9, .bold))
                            .foregroundStyle(Color.sh.bgRaised)
                            .opacity(configuration.isOn ? 1 : 0)
                    }
                    .shBorder(configuration.isOn ? Color.sh.textPrimary : Color.sh.textTertiary, in: box)
                    .frame(width: SHDesignSheetMetrics.checkbox, height: SHDesignSheetMetrics.checkbox)
                    .accessibilityHidden(true)
                configuration.label
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shFocusRing(radius: SH.Radius.xs)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

extension ToggleStyle where Self == SHDesignSheetCheckStyle {
    /// `.toggleStyle(.shSheetCheck)`.
    public static var shSheetCheck: SHDesignSheetCheckStyle { SHDesignSheetCheckStyle() }
}

/// A button in a sheet's footer: plain words (the boards' `.lk`), or the one ink pill (`.sbtn`).
public struct SHSheetButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        /// Cancel: `textSecondary`.
        case quiet
        /// A choice: `textPrimary`, medium.
        case link
        /// Delete: `failed`, medium.
        case danger
        /// The sheet's one action: an ink pill.
        case pill
    }

    let kind: Kind

    public init(_ kind: Kind = .link) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        SHSheetButton(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == SHSheetButtonStyle {
    /// `.buttonStyle(.shSheet(.pill))`.
    public static func shSheet(_ kind: SHSheetButtonStyle.Kind = .link) -> SHSheetButtonStyle { SHSheetButtonStyle(kind) }
}

private struct SHSheetButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHSheetButtonStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let pill = kind == .pill
        let active = enabled && (hovering || configuration.isPressed)
        let shape = Capsule()
        configuration.label
            .font(pill ? .shSans(SHDesignSheetMetrics.pillTextSize, .medium) : .shSans(13, kind == .quiet ? .regular : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground(sh, active: active))
            .padding(.horizontal, pill ? SHDesignSheetMetrics.pillPadding : 0)
            .frame(minHeight: pill ? SHDesignSheetMetrics.pillHeight : SH.Height.controlS)
            .background(pill ? (configuration.isPressed && enabled ? sh.primaryPressed : hovering && enabled ? sh.primaryHover : sh.primary) : .clear, in: shape)
            .shEnabledOpacity(enabled)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .shAnimation(.hover, value: hovering)
            .shFocusRing(radius: pill ? SHDesignSheetMetrics.pillHeight / 2 : SH.Radius.xs)
    }

    private func foreground(_ sh: SHPalette, active: Bool) -> Color {
        switch kind {
        case .quiet: active ? sh.textPrimary : sh.textSecondary
        case .link: sh.textPrimary
        case .danger: sh.failed
        case .pill: sh.textOnPrimary
        }
    }
}

// MARK: - The toast

/// The toast after a deletion (UndoToast, DeleteFailedToast; the boards' `.gdz-toast`): a glyph in
/// `textSecondary` (`failed` when it failed), the words in `ui` with the name semibold, its action
/// in plain words, and a 24pt close. On `bgRaised` at radius 12 with the popover's shadow, 8pt in
/// (14 before the glyph), 12pt between parts. Nothing in it counts down.
public struct SHUndoToast: View {
    public enum Tone: Sendable { case done, failed }

    let tone: Tone
    let message: Text
    let actionTitle: String
    let action: () -> Void
    let dismiss: () -> Void

    public init(tone: Tone = .done, message: Text, actionTitle: String, action: @escaping () -> Void, dismiss: @escaping () -> Void) {
        self.tone = tone
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: SH.Space.l) {
            Image(systemName: tone == .done ? "arrow.uturn.backward" : "exclamationmark.triangle")
                .font(.shSans(SHDesignMetrics.toastGlyph - 1))
                .foregroundStyle(tone == .done ? Color.sh.textSecondary : Color.sh.failed)
                .accessibilityHidden(true)
            message
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textPrimary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(actionTitle, action: action)
                .buttonStyle(.shSheet(.link))
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.shSans(SH.Space.l, .medium))
                    .foregroundStyle(Color.sh.textTertiary)
                    .frame(width: SH.Height.controlS, height: SH.Height.controlS)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, SH.Space.m)
        .padding(.leading, SHDesignMetrics.toastPaddingLeading)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: SH.Height.controlL + SH.Space.m, alignment: .leading)
        .frame(maxWidth: SHDesignMetrics.toastWidth)
        .shPopover(radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Import

/// The drop target over the Designs page (ImportDrop): a 1.5pt dashed `textSecondary` line at
/// radius 16 around the page, which fades under a `bgWindow` veil, and in its middle a card with
/// the tray glyph, "Drop to import as a new design" and what it takes. Drawn only while a ZIP or
/// folder is over the page.
public struct SHDesignsDropTarget: View {
    public init() {}

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xxl)
        ZStack {
            shape.fill(Color.sh.bgWindow.opacity(SHDesignsHomeMetrics.dropVeil))
            shape.strokeBorder(Color.sh.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            VStack(spacing: SH.Space.s) {
                Image(systemName: "square.and.arrow.down")
                    .font(.shSans(SHDesignMetrics.dropTileGlyph - 2))
                    .foregroundStyle(Color.sh.textSecondary)
                Text("Drop to import as a new design")
                    .font(.shSans(15, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .padding(.top, SH.Space.xs)
                Text("A Claude Design project, as a ZIP or a folder")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
            }
            .padding(.vertical, SHDesignMetrics.dropCardPaddingVertical)
            .padding(.horizontal, 30)
            .shPopover(radius: SH.Radius.xl)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.bottom, SH.Space.l)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The card of a design being imported (ImportProgress), first among Recent designs: its boards
/// as tiles filling in as they land (drawn on `bgRaised`, or dashed while they wait),
/// "Importing Checkout funnel…" shimmering, "7 of 12 boards · with Checkout DS", and a 4pt bar
/// in `textPrimary` filling.
public struct SHImportingCard: View {
    let title: String
    let done: Int
    let total: Int
    let meta: String

    public init(title: String, done: Int, total: Int, system: String? = nil) {
        self.title = title
        self.done = done
        self.total = total
        self.meta = "\(min(done, total)) of \(total) boards" + (system.map { " · with \($0)" } ?? "")
    }

    private var fraction: CGFloat { total > 0 ? CGFloat(min(done, total)) / CGFloat(total) : 0 }

    public var body: some View {
        let M = SHDesignsHomeMetrics.self
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xl)
        let top = UnevenRoundedRectangle(topLeadingRadius: SH.Radius.xl, topTrailingRadius: SH.Radius.xl)
        VStack(alignment: .leading, spacing: 0) {
            tiles
                .frame(maxWidth: .infinity)
                .frame(height: M.thumbnailHeight)
                .background(Color.sh.bgHover, in: top)
                .overlay(alignment: .bottom) { SHHairline() }
            VStack(alignment: .leading, spacing: 0) {
                Text("Importing \(title)…")
                    .font(.sh(.headline))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .shShimmer(active: true)
                Text(meta)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
                    .padding(.top, M.cardMetaTop)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.sh.bgHover)
                        Capsule().fill(Color.sh.textPrimary).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: SHDesignMetrics.importBarHeight + 1)
                .padding(.top, SH.Space.m)
                .shAnimation(.content, value: done)
            }
            .padding(.top, M.cardPaddingTop)
            .padding(.bottom, M.cardPaddingBottom)
            .padding(.horizontal, M.cardPaddingHorizontal)
        }
        .background { Color.clear.shLift(shape) }
        .shBorder(Color.sh.lineSubtle, in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Importing \(title), \(done) of \(total) boards")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var tiles: some View {
        let shown = max(0, min(total, SHDesignMetrics.importTilesShown))
        let drawn = total > 0 ? Int((CGFloat(shown) * fraction).rounded(.down)) : 0
        let columns = Array(repeating: GridItem(.fixed(SHDesignMetrics.importTile.width + SH.Space.xs), spacing: SHDesignMetrics.importTileSpacing),
                            count: SHDesignMetrics.importTileColumns)
        return LazyVGrid(columns: columns, spacing: SHDesignMetrics.importTileSpacing) {
            ForEach(0..<shown, id: \.self) { index in
                let tile = RoundedRectangle(cornerRadius: SH.Radius.xs)
                Group {
                    if index < drawn {
                        tile.fill(Color.sh.bgRaised).shBorder(Color.sh.lineSubtle, in: tile)
                    } else {
                        tile.fill(.clear).shBorder(Color.sh.lineSubtle, in: tile, dash: [3, 2])
                    }
                }
                .frame(width: SHDesignMetrics.importTile.width + SH.Space.xs, height: SHDesignMetrics.importTile.height + SH.Space.xs)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - A card's •••

/// A card's ••• (DesignCardMenu, SystemCardMenu; the boards' `.gdz-more`): a 26pt rounded square,
/// the glyph in `textTertiary` and, under the pointer, `textPrimary` on `bgSelected`. It opens the
/// card's menu, the same one a right-click opens.
public struct SHDesignMoreButton<Items: View>: View {
    let label: String
    let items: Items
    @State private var hovering = false

    public init(label: String = "More", @ViewBuilder items: () -> Items) {
        self.label = label
        self.items = items()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.shSans(SHDesignsHomeMetrics.moreGlyph, .semibold))
                .foregroundStyle(hovering ? Color.sh.textPrimary : Color.sh.textTertiary)
                .frame(width: SHDesignsHomeMetrics.moreSize, height: SHDesignsHomeMetrics.moreSize)
                .background(hovering ? Color.sh.bgSelected : .clear, in: shape)
                .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// ••• in a design's toolbar, or on a system's page (DesignToolbarMenu): a 28pt icon button in
/// `textSecondary`, the hover fill under it, opening the design's menu.
public struct SHDesignToolbarMore<Items: View>: View {
    let label: String
    let items: Items
    @State private var hovering = false

    public init(label: String = "More", @ViewBuilder items: () -> Items) {
        self.label = label
        self.items = items()
    }

    public var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.shSans(SHDesignMetrics.cardMoreGlyph, .semibold))
                .foregroundStyle(hovering ? Color.sh.textPrimary : Color.sh.textSecondary)
                .frame(width: SH.Height.controlM, height: SH.Height.controlM)
                .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}
