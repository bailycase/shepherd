import SwiftUI

// Deleting and importing designs (DesignLifecycleStates): the dialogs, the toast, the drop
// target over Designs, the card an import is filling, and a card's •••. Each takes values and
// closures; what they say and do is the app's.

// MARK: - Alert dialogs

/// The glyph tile of an alert dialog: `failed` for a deletion or a failed import, `attention`
/// for a question (ImportAgain).
public enum NWDesignAlertTone: Sendable {
    case failed, attention

    @MainActor var fill: Color { self == .failed ? .nw.failedTint : .nw.lanternTint }
    @MainActor var glyph: Color { self == .failed ? .nw.failed : .nw.lanternText }
}

/// An alert dialog of the Design tool (DeleteDesignDialog, DeleteSystemDialog, ImportErrorDialog,
/// ImportAgainDialog): a 36pt tile with the glyph, 14pt before the title (15.5 semibold) and the
/// body under it, 8pt apart; the buttons trailing, 8pt apart, 16pt under it all. On `bgWindow`;
/// the sheet it sits in draws the window's corners and shadow.
public struct NWDesignAlert<Content: View, Actions: View>: View {
    let symbol: String
    let tone: NWDesignAlertTone
    let title: String
    let width: CGFloat
    let content: Content
    let actions: Actions

    public init(symbol: String, tone: NWDesignAlertTone = .failed, title: String, width: CGFloat = NWDesignMetrics.alertWidth,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.width = width
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NWDesignMetrics.alertSpacing) {
            HStack(alignment: .top, spacing: NWDesignMetrics.alertTileGap) {
                Image(systemName: symbol)
                    .font(.nwSans(NWDesignMetrics.alertTileGlyph, .medium))
                    .foregroundStyle(tone.glyph)
                    .frame(width: NWDesignMetrics.alertTile, height: NWDesignMetrics.alertTile)
                    .background(tone.fill, in: RoundedRectangle(cornerRadius: NWDesignMetrics.alertTileRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    Text(title)
                        .font(.nwSans(NWDesignMetrics.alertTitleSize, .semibold))
                        .foregroundStyle(Color.nw.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    content
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: NW.Space.m) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding([.top, .horizontal], NWDesignMetrics.alertPadding)
        .padding(.bottom, NWDesignMetrics.alertBottomPadding)
        .frame(width: width, alignment: .leading)
        .background(Color.nw.bgWindow)
    }
}

/// An alert's message in 13, `textSecondary`: pass bold names and mono paths as `Text` spans.
public struct NWDesignAlertMessage: View {
    let text: Text

    public init(_ text: Text) { self.text = text }
    public init(_ string: String) { self.text = Text(string) }

    public var body: some View {
        text
            .font(.nwSans(NWDesignMetrics.alertMessageSize))
            .foregroundStyle(Color.nw.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// A span in the message's `textPrimary` semibold ("Checkout funnel").
    public static func strong(_ string: String) -> Text {
        Text(string).fontWeight(.semibold).foregroundStyle(Color.nw.textPrimary)
    }

    /// A span in mono, `textPrimary` ("canvas.json", "mobile-app").
    public static func mono(_ string: String, size: CGFloat = NWDesignMetrics.alertMonoSize) -> Text {
        Text(string).font(.nwMono(size)).foregroundStyle(Color.nw.textPrimary)
    }
}

/// What a line of an alert's list says of its subject: it goes (`failed`), it stays (`done`),
/// or a note (`textTertiary`).
public enum NWDesignAlertLineRole: Sendable {
    case goes, stays, note, neutral

    @MainActor var color: Color {
        switch self {
        case .goes: .nw.failed
        case .stays: .nw.done
        case .note: .nw.textTertiary
        case .neutral: .nw.textSecondary
        }
    }
}

/// One line of an alert's list: a 12pt glyph in its role's color, 8pt before the words in 12.5.
public struct NWDesignAlertLine: View {
    let symbol: String
    let role: NWDesignAlertLineRole
    let text: Text

    public init(symbol: String, role: NWDesignAlertLineRole, _ text: Text) {
        self.symbol = symbol
        self.role = role
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Image(systemName: symbol)
                .font(.nwSans(NWDesignMetrics.alertItemGlyph, .medium))
                .foregroundStyle(role.color)
                .accessibilityHidden(true)
            text
                .font(.nwSans(NWDesignMetrics.alertLineSize))
                .foregroundStyle(Color.nw.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The box an alert lists its lines in: 10×12 padding, 6pt between lines, a hairline at radius
/// 8 on `bgSunken`.
public struct NWDesignAlertList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: NWDesignMetrics.alertListSpacing) { content }
            .padding(.vertical, NWDesignMetrics.alertListPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.alertListPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
    }
}

/// Paths that point out of a project (ImportErrorDialog › links outside): each "from → to" in
/// mono 11.5, the target in `failed`, up to three.
public struct NWDesignAlertLinks: View {
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
        NWDesignAlertList {
            ForEach(links, id: \.self) { link in
                HStack(spacing: NW.Space.m) {
                    Text(link.from).foregroundStyle(Color.nw.textPrimary)
                    Text("→").font(.nwSans(NWDesignMetrics.alertMonoSize)).foregroundStyle(Color.nw.textTertiary)
                    Text(link.to).foregroundStyle(Color.nw.failed)
                }
                .font(.nwMono(NWDesignMetrics.alertLinkSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A warning under an alert's list (DeleteDesignDialog while the agent draws): a 13pt glyph and
/// the words in 12.5 `lanternText`, on `lanternTint` at radius 8.
public struct NWDesignAlertWarning: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.nwSans(NWDesignMetrics.alertItemGlyph + 1, .medium))
                .accessibilityHidden(true)
            Text(text)
                .font(.nwSans(NWDesignMetrics.alertLineSize))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.nw.lanternText)
        .padding(.vertical, NWDesignMetrics.alertListPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.alertListPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.m))
    }
}

/// The last line of an import's alert: a `done` check and "Nothing was imported." (or "Nothing’s
/// imported until you choose.") in 12.5 `textTertiary`.
public struct NWDesignAlertReassurance: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "checkmark")
                .font(.nwSans(NWDesignMetrics.alertItemGlyph, .semibold))
                .foregroundStyle(Color.nw.done)
                .accessibilityHidden(true)
            Text(text)
                .font(.nwSans(NWDesignMetrics.alertLineSize))
                .foregroundStyle(Color.nw.textTertiary)
        }
    }
}

// MARK: - The toast

/// The toast after a deletion (UndoToast, DeleteFailedToast): a 15pt glyph, the words in 13 (the
/// name semibold), a 24pt button with its glyph, and a close. Raised on the popover's line and
/// shadow at radius 12. Nothing in it counts down.
public struct NWUndoToast: View {
    public enum Tone: Sendable { case done, failed }

    let tone: Tone
    let message: Text
    let actionTitle: String
    let actionSymbol: String
    let action: () -> Void
    let dismiss: () -> Void

    public init(tone: Tone = .done, message: Text, actionTitle: String, actionSymbol: String, action: @escaping () -> Void,
                dismiss: @escaping () -> Void) {
        self.tone = tone
        self.message = message
        self.actionTitle = actionTitle
        self.actionSymbol = actionSymbol
        self.action = action
        self.dismiss = dismiss
    }

    public var body: some View {
        HStack(spacing: NWDesignMetrics.toastSpacing) {
            Image(systemName: tone == .done ? "trash" : "exclamationmark.triangle")
                .font(.nwSans(NWDesignMetrics.toastGlyph))
                .foregroundStyle(tone == .done ? Color.nw.textSecondary : Color.nw.failed)
                .accessibilityHidden(true)
            message
                .font(.nwSans(NWDesignMetrics.toastTextSize))
                .foregroundStyle(Color.nw.textPrimary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Label(actionTitle, systemImage: actionSymbol)
            }
            .buttonStyle(.nw(.secondary, size: .s))
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.nwIcon(size: NW.Height.controlS))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, NWDesignMetrics.toastPaddingVertical)
        .padding(.leading, NWDesignMetrics.toastPaddingLeading)
        .padding(.trailing, NWDesignMetrics.toastPaddingTrailing)
        .frame(maxWidth: NWDesignMetrics.toastWidth)
        .nwPopover(radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Import

/// The drop target over the Designs page (ImportDrop): a 2pt dashed `lantern` line around the
/// page on `lanternTint`, and in its middle a card on `bgWindow` with the tray glyph in a
/// `lanternTint` tile, "Drop to import as a new design" and what it takes. Drawn only while a ZIP
/// or folder is over the page.
public struct NWDesignsDropTarget: View {
    public init() {}

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.dropRadius)
        ZStack {
            shape.fill(Color.nw.lanternTint)
            shape.strokeBorder(Color.nw.lantern, style: StrokeStyle(lineWidth: NWDesignMetrics.dropLine, dash: [6, 5]))
            VStack(spacing: NWDesignMetrics.dropSpacing) {
                Image(systemName: "square.and.arrow.down")
                    .font(.nwSans(NWDesignMetrics.dropTileGlyph, .medium))
                    .foregroundStyle(Color.nw.lanternText)
                    .frame(width: NWDesignMetrics.dropTile, height: NWDesignMetrics.dropTile)
                    .background(Color.nw.lanternTint, in: RoundedRectangle(cornerRadius: NW.Radius.l))
                Text("Drop to import as a new design")
                    .font(.nwSans(NWDesignMetrics.dropTitleSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                Text("A Claude Design project, as a ZIP or a folder")
                    .font(.nwSans(NWDesignMetrics.dropLineSize))
                    .foregroundStyle(Color.nw.textSecondary)
            }
            .padding(.vertical, NWDesignMetrics.dropCardPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.dropCardPaddingHorizontal)
            .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NWDesignMetrics.dropRadius))
            .nwBorder(Color.nw.lineStrong, radius: NWDesignMetrics.dropRadius)
        }
        .padding(NWDesignMetrics.dropInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The card of a design being imported (ImportProgress), first among Recent designs: its boards
/// as small tiles filling in as they land, "Importing Checkout funnel…" shimmering, "7 of 12
/// boards · with Checkout DS", and a `running` bar filling.
public struct NWImportingCard: View {
    let title: String
    let done: Int
    let total: Int
    let system: String?

    public init(title: String, done: Int, total: Int, system: String? = nil) {
        self.title = title
        self.done = done
        self.total = total
        self.system = system
    }

    private var fraction: CGFloat { total > 0 ? CGFloat(min(done, total)) / CGFloat(total) : 0 }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: NWDesignMetrics.cardRadius)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                NWDotGrid(spacing: NWDesignMetrics.cardGridSpacing)
                tiles
            }
            .frame(maxWidth: .infinity)
            .frame(height: NWDesignMetrics.cardThumbnailHeight)
            .background(Color.nw.bgBase)
            .clipped()
            .overlay(alignment: .bottom) { NWHairline() }
            VStack(alignment: .leading, spacing: NWDesignMetrics.importLineSpacing) {
                Text("Importing \(title)…")
                    .font(.nwSans(NWDesignMetrics.cardNameSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .nwShimmer(active: true)
                count
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.nw.lineSubtle)
                        Capsule().fill(Color.nw.running).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: NWDesignMetrics.importBarHeight)
                .nwAnimation(.content, value: done)
            }
            .padding(.vertical, NWDesignMetrics.cardPaddingVertical)
            .padding(.horizontal, NWDesignMetrics.cardPaddingHorizontal)
        }
        .clipShape(shape)
        .nwBorder(Color.nw.lineStrong, radius: NWDesignMetrics.cardRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Importing \(title), \(done) of \(total) boards")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var count: some View {
        let boards = Text("\(Text("\(min(done, total)) of \(total)").font(.nwMono(NWDesignMetrics.cardMetaSize)).foregroundStyle(Color.nw.textSecondary)) boards")
        let line: Text = if let system {
            Text("\(boards) · with \(Text(system).font(.nwMono(NWDesignMetrics.cardMetaSize)).foregroundStyle(Color.nw.textSecondary))")
        } else {
            boards
        }
        return line
            .font(.nwSans(NWDesignMetrics.cardMetaSize))
            .foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1)
    }

    private var tiles: some View {
        let shown = max(0, min(total, NWDesignMetrics.importTilesShown))
        let drawn = total > 0 ? Int((CGFloat(shown) * fraction).rounded(.down)) : 0
        let columns = Array(repeating: GridItem(.fixed(NWDesignMetrics.importTile.width), spacing: NWDesignMetrics.importTileSpacing),
                            count: NWDesignMetrics.importTileColumns)
        return LazyVGrid(columns: columns, spacing: NWDesignMetrics.importTileSpacing) {
            ForEach(0..<shown, id: \.self) { index in
                let tile = RoundedRectangle(cornerRadius: NWDesignMetrics.importTileRadius)
                Group {
                    if index < drawn {
                        tile.fill(Color.nw.lineStrong)
                    } else {
                        tile.strokeBorder(Color.nw.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .frame(width: NWDesignMetrics.importTile.width, height: NWDesignMetrics.importTile.height)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - A card's •••

/// A card's ••• (DesignCardMenu): a 26pt circle on `bgRaised` with the popover's line and shadow,
/// its glyph 13pt. It opens the card's menu, the same one a right-click opens.
public struct NWDesignMoreButton<Items: View>: View {
    let label: String
    let items: Items

    public init(label: String = "More", @ViewBuilder items: () -> Items) {
        self.label = label
        self.items = items()
    }

    public var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis")
                .font(.nwSans(NWDesignMetrics.cardMoreGlyph, .semibold))
                .foregroundStyle(Color.nw.textPrimary)
                .frame(width: NWDesignMetrics.cardMoreSize, height: NWDesignMetrics.cardMoreSize)
                .nwPopover(radius: NWDesignMetrics.cardMoreSize / 2)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A system card's tag after its name ("Built-in"): 16pt, 5pt padding, radius 4, 10 in
/// `textSecondary` on `bgSelected`.
public struct NWDesignTagBadge: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nwSans(NWDesignMetrics.tagBadgeTextSize))
            .foregroundStyle(Color.nw.textSecondary)
            .padding(.horizontal, NWDesignMetrics.tagBadgePadding)
            .frame(height: NWDesignMetrics.tagBadgeHeight)
            .background(Color.nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
    }
}

/// ••• in a design's toolbar, or on a system's page (DesignToolbarMenu): a 28pt icon button in
/// `textSecondary`, the hover fill under it, opening the design's menu.
public struct NWDesignToolbarMore<Items: View>: View {
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
                .font(.nwSans(NWDesignMetrics.cardMoreGlyph, .semibold))
                .foregroundStyle(hovering ? Color.nw.textPrimary : Color.nw.textSecondary)
                .frame(width: NW.Height.controlM, height: NW.Height.controlM)
                .background(hovering ? Color.nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .help(label)
        .accessibilityLabel(label)
    }
}
