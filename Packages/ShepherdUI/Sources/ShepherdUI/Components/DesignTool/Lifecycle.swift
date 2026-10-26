import SwiftUI

// Deleting and importing designs (DesignLifecycleStates): the dialogs, the toast, the drop
// target over Designs, the card an import is filling, and a card's •••. Each takes values and
// closures; what they say and do is the app's.

// MARK: - Alert dialogs

/// The glyph tile of an alert dialog: `failed` for a deletion or a failed import, `attention`
/// for a question (ImportAgain).
public enum SHDesignAlertTone: Sendable {
    case failed, attention

    @MainActor var fill: Color { self == .failed ? .sh.failedTint : .sh.lanternTint }
    @MainActor var glyph: Color { self == .failed ? .sh.failed : .sh.lanternText }
}

/// An alert dialog of the Design tool (DeleteDesignDialog, DeleteSystemDialog, ImportErrorDialog,
/// ImportAgainDialog): a 36pt tile with the glyph, 14pt before the title (15.5 semibold) and the
/// body under it, 8pt apart; the buttons trailing, 8pt apart, 16pt under it all. On `bgWindow`;
/// the sheet it sits in draws the window's corners and shadow.
public struct SHDesignAlert<Content: View, Actions: View>: View {
    let symbol: String
    let tone: SHDesignAlertTone
    let title: String
    let width: CGFloat
    let content: Content
    let actions: Actions

    public init(symbol: String, tone: SHDesignAlertTone = .failed, title: String, width: CGFloat = SHDesignMetrics.alertWidth,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tone = tone
        self.title = title
        self.width = width
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.alertSpacing) {
            HStack(alignment: .top, spacing: SHDesignMetrics.alertTileGap) {
                Image(systemName: symbol)
                    .font(.shSans(SHDesignMetrics.alertTileGlyph, .medium))
                    .foregroundStyle(tone.glyph)
                    .frame(width: SHDesignMetrics.alertTile, height: SHDesignMetrics.alertTile)
                    .background(tone.fill, in: RoundedRectangle(cornerRadius: SHDesignMetrics.alertTileRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    Text(title)
                        .font(.shSans(SHDesignMetrics.alertTitleSize, .semibold))
                        .foregroundStyle(Color.sh.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    content
                }
                .padding(.top, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: SH.Space.m) {
                Spacer(minLength: 0)
                actions
            }
        }
        .padding([.top, .horizontal], SHDesignMetrics.alertPadding)
        .padding(.bottom, SHDesignMetrics.alertBottomPadding)
        .frame(width: width, alignment: .leading)
        .background(Color.sh.bgWindow)
    }
}

/// An alert's message in 13, `textSecondary`: pass bold names and mono paths as `Text` spans.
public struct SHDesignAlertMessage: View {
    let text: Text

    public init(_ text: Text) { self.text = text }
    public init(_ string: String) { self.text = Text(string) }

    public var body: some View {
        text
            .font(.shSans(SHDesignMetrics.alertMessageSize))
            .foregroundStyle(Color.sh.textSecondary)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// A span in the message's `textPrimary` semibold ("Checkout funnel").
    public static func strong(_ string: String) -> Text {
        Text(string).fontWeight(.semibold).foregroundStyle(Color.sh.textPrimary)
    }

    /// A span in mono, `textPrimary` ("canvas.json", "mobile-app").
    public static func mono(_ string: String, size: CGFloat = SHDesignMetrics.alertMonoSize) -> Text {
        Text(string).font(.shMono(size)).foregroundStyle(Color.sh.textPrimary)
    }
}

/// What a line of an alert's list says of its subject: it goes (`failed`), it stays (`done`),
/// or a note (`textTertiary`).
public enum SHDesignAlertLineRole: Sendable {
    case goes, stays, note, neutral

    @MainActor var color: Color {
        switch self {
        case .goes: .sh.failed
        case .stays: .sh.done
        case .note: .sh.textTertiary
        case .neutral: .sh.textSecondary
        }
    }
}

/// One line of an alert's list: a 12pt glyph in its role's color, 8pt before the words in 12.5.
public struct SHDesignAlertLine: View {
    let symbol: String
    let role: SHDesignAlertLineRole
    let text: Text

    public init(symbol: String, role: SHDesignAlertLineRole, _ text: Text) {
        self.symbol = symbol
        self.role = role
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Image(systemName: symbol)
                .font(.shSans(SHDesignMetrics.alertItemGlyph, .medium))
                .foregroundStyle(role.color)
                .accessibilityHidden(true)
            text
                .font(.shSans(SHDesignMetrics.alertLineSize))
                .foregroundStyle(Color.sh.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The box an alert lists its lines in: 10×12 padding, 6pt between lines, a hairline at radius
/// 8 on `bgSunken`.
public struct SHDesignAlertList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.alertListSpacing) { content }
            .padding(.vertical, SHDesignMetrics.alertListPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.alertListPaddingHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
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
                    Text("→").font(.shSans(SHDesignMetrics.alertMonoSize)).foregroundStyle(Color.sh.textTertiary)
                    Text(link.to).foregroundStyle(Color.sh.failed)
                }
                .font(.shMono(SHDesignMetrics.alertLinkSize))
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A warning under an alert's list (DeleteDesignDialog while the agent draws): a 13pt glyph and
/// the words in 12.5 `lanternText`, on `lanternTint` at radius 8.
public struct SHDesignAlertWarning: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.shSans(SHDesignMetrics.alertItemGlyph + 1, .medium))
                .accessibilityHidden(true)
            Text(text)
                .font(.shSans(SHDesignMetrics.alertLineSize))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.sh.lanternText)
        .padding(.vertical, SHDesignMetrics.alertListPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.alertListPaddingHorizontal)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.m))
    }
}

/// The last line of an import's alert: a `done` check and "Nothing was imported." (or "Nothing’s
/// imported until you choose.") in 12.5 `textTertiary`.
public struct SHDesignAlertReassurance: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Image(systemName: "checkmark")
                .font(.shSans(SHDesignMetrics.alertItemGlyph, .semibold))
                .foregroundStyle(Color.sh.done)
                .accessibilityHidden(true)
            Text(text)
                .font(.shSans(SHDesignMetrics.alertLineSize))
                .foregroundStyle(Color.sh.textTertiary)
        }
    }
}

// MARK: - The toast

/// The toast after a deletion (UndoToast, DeleteFailedToast): a 15pt glyph, the words in 13 (the
/// name semibold), a 24pt button with its glyph, and a close. Raised on the popover's line and
/// shadow at radius 12. Nothing in it counts down.
public struct SHUndoToast: View {
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
        HStack(spacing: SHDesignMetrics.toastSpacing) {
            Image(systemName: tone == .done ? "trash" : "exclamationmark.triangle")
                .font(.shSans(SHDesignMetrics.toastGlyph))
                .foregroundStyle(tone == .done ? Color.sh.textSecondary : Color.sh.failed)
                .accessibilityHidden(true)
            message
                .font(.shSans(SHDesignMetrics.toastTextSize))
                .foregroundStyle(Color.sh.textPrimary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: action) {
                Label(actionTitle, systemImage: actionSymbol)
            }
            .buttonStyle(.sh(.secondary, size: .s))
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.shIcon(size: SH.Height.controlS))
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(.vertical, SHDesignMetrics.toastPaddingVertical)
        .padding(.leading, SHDesignMetrics.toastPaddingLeading)
        .padding(.trailing, SHDesignMetrics.toastPaddingTrailing)
        .frame(maxWidth: SHDesignMetrics.toastWidth)
        .shPopover(radius: SH.Radius.l)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Import

/// The drop target over the Designs page (ImportDrop): a 2pt dashed `lantern` line around the
/// page on `lanternTint`, and in its middle a card on `bgWindow` with the tray glyph in a
/// `lanternTint` tile, "Drop to import as a new design" and what it takes. Drawn only while a ZIP
/// or folder is over the page.
public struct SHDesignsDropTarget: View {
    public init() {}

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.dropRadius)
        ZStack {
            shape.fill(Color.sh.lanternTint)
            shape.strokeBorder(Color.sh.lantern, style: StrokeStyle(lineWidth: SHDesignMetrics.dropLine, dash: [6, 5]))
            VStack(spacing: SHDesignMetrics.dropSpacing) {
                Image(systemName: "square.and.arrow.down")
                    .font(.shSans(SHDesignMetrics.dropTileGlyph, .medium))
                    .foregroundStyle(Color.sh.lanternText)
                    .frame(width: SHDesignMetrics.dropTile, height: SHDesignMetrics.dropTile)
                    .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.l))
                Text("Drop to import as a new design")
                    .font(.shSans(SHDesignMetrics.dropTitleSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                Text("A Claude Design project, as a ZIP or a folder")
                    .font(.shSans(SHDesignMetrics.dropLineSize))
                    .foregroundStyle(Color.sh.textSecondary)
            }
            .padding(.vertical, SHDesignMetrics.dropCardPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.dropCardPaddingHorizontal)
            .background(Color.sh.bgWindow, in: RoundedRectangle(cornerRadius: SHDesignMetrics.dropRadius))
            .shBorder(Color.sh.lineStrong, radius: SHDesignMetrics.dropRadius)
        }
        .padding(SHDesignMetrics.dropInset)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// The card of a design being imported (ImportProgress), first among Recent designs: its boards
/// as small tiles filling in as they land, "Importing Checkout funnel…" shimmering, "7 of 12
/// boards · with Checkout DS", and a `running` bar filling.
public struct SHImportingCard: View {
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
        let shape = RoundedRectangle(cornerRadius: SHDesignMetrics.cardRadius)
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                SHDotGrid(spacing: SHDesignMetrics.cardGridSpacing)
                tiles
            }
            .frame(maxWidth: .infinity)
            .frame(height: SHDesignMetrics.cardThumbnailHeight)
            .background(Color.sh.bgBase)
            .clipped()
            .overlay(alignment: .bottom) { SHHairline() }
            VStack(alignment: .leading, spacing: SHDesignMetrics.importLineSpacing) {
                Text("Importing \(title)…")
                    .font(.shSans(SHDesignMetrics.cardNameSize, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(1)
                    .shShimmer(active: true)
                count
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.sh.lineSubtle)
                        Capsule().fill(Color.sh.running).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: SHDesignMetrics.importBarHeight)
                .shAnimation(.content, value: done)
            }
            .padding(.vertical, SHDesignMetrics.cardPaddingVertical)
            .padding(.horizontal, SHDesignMetrics.cardPaddingHorizontal)
        }
        .clipShape(shape)
        .shBorder(Color.sh.lineStrong, radius: SHDesignMetrics.cardRadius)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Importing \(title), \(done) of \(total) boards")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var count: some View {
        let boards = Text("\(Text("\(min(done, total)) of \(total)").font(.shMono(SHDesignMetrics.cardMetaSize)).foregroundStyle(Color.sh.textSecondary)) boards")
        let line: Text = if let system {
            Text("\(boards) · with \(Text(system).font(.shMono(SHDesignMetrics.cardMetaSize)).foregroundStyle(Color.sh.textSecondary))")
        } else {
            boards
        }
        return line
            .font(.shSans(SHDesignMetrics.cardMetaSize))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
    }

    private var tiles: some View {
        let shown = max(0, min(total, SHDesignMetrics.importTilesShown))
        let drawn = total > 0 ? Int((CGFloat(shown) * fraction).rounded(.down)) : 0
        let columns = Array(repeating: GridItem(.fixed(SHDesignMetrics.importTile.width), spacing: SHDesignMetrics.importTileSpacing),
                            count: SHDesignMetrics.importTileColumns)
        return LazyVGrid(columns: columns, spacing: SHDesignMetrics.importTileSpacing) {
            ForEach(0..<shown, id: \.self) { index in
                let tile = RoundedRectangle(cornerRadius: SHDesignMetrics.importTileRadius)
                Group {
                    if index < drawn {
                        tile.fill(Color.sh.lineStrong)
                    } else {
                        tile.strokeBorder(Color.sh.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    }
                }
                .frame(width: SHDesignMetrics.importTile.width, height: SHDesignMetrics.importTile.height)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - A card's •••

/// A card's ••• (DesignCardMenu): a 26pt circle on `bgRaised` with the popover's line and shadow,
/// its glyph 13pt. It opens the card's menu, the same one a right-click opens.
public struct SHDesignMoreButton<Items: View>: View {
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
                .font(.shSans(SHDesignMetrics.cardMoreGlyph, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .frame(width: SHDesignMetrics.cardMoreSize, height: SHDesignMetrics.cardMoreSize)
                .shPopover(radius: SHDesignMetrics.cardMoreSize / 2)
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
public struct SHDesignTagBadge: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.shSans(SHDesignMetrics.tagBadgeTextSize))
            .foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SHDesignMetrics.tagBadgePadding)
            .frame(height: SHDesignMetrics.tagBadgeHeight)
            .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
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
