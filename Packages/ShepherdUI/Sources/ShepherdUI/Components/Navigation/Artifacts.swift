import SwiftUI

// The Artifacts tab and its card in the thread (PaneArtifacts, iPadPaneArtifacts): files the agent made. Plain values in, closures out;
// the Mac and the iPad draw the same parts at their own sizes (`SHArtifactMetrics.Scale`).

/// What the tab's parts are measured by. The Mac's values are PaneArtifacts', the iPad's iPadPaneArtifacts' (a 52pt bar, 36pt controls).
public enum SHArtifactMetrics {
    /// The card in the thread: 34pt tile and 17pt glyph, padding 10 × 12, 12pt gaps.
    public static let cardTile: CGFloat = 34
    public static let cardGlyph: CGFloat = 17
    public static let cardPaddingV: CGFloat = 10
    /// A list row: at least 48pt, a 30pt tile and 15pt glyph.
    public static let rowMinHeight: CGFloat = 48
    public static let rowTile: CGFloat = 30
    public static let rowGlyph: CGFloat = 15
    /// The open view's bar: 44pt on the Mac, 52pt on the iPad; the kind tile 22pt with a 12pt glyph.
    public static let barHeight: CGFloat = 44
    public static let padBarHeight: CGFloat = 52
    public static let barTile: CGFloat = 22
    public static let barGlyph: CGFloat = 12
    /// A name in a row and in the bar: Geist 13 (medium in a row, semibold when open and in the bar), a size the ramp does not have.
    public static let nameSize: CGFloat = 13
    /// A document drawn on its own surface sits 18pt in from the pane's edge (HTML keeps its own styles and background).
    public static let documentInset: CGFloat = 18
    /// The most an artifact's source draws: more is cut with a note, so a megabyte of text is never laid out as one view.
    public static let sourceCharacterLimit = 200_000
}

/// What an artifact is, as the tab draws it. Plain values: the views compare them and parse nothing.
public struct SHArtifactRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// "HTML · 6m ago".
    public var detail: String
    public var symbol: String

    public init(id: String, name: String, detail: String, symbol: String) {
        self.id = id
        self.name = name
        self.detail = detail
        self.symbol = symbol
    }
}

/// The kind's tile: a `bgSelected` square holding the kind's glyph in `textSecondary`.
public struct SHArtifactTile: View {
    let symbol: String
    let size: CGFloat
    let glyph: CGFloat
    let radius: CGFloat

    public init(symbol: String, size: CGFloat, glyph: CGFloat, radius: CGFloat = SH.Radius.m) {
        self.symbol = symbol
        self.size = size
        self.glyph = glyph
        self.radius = radius
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(Color.sh.textSecondary)
            .frame(width: size, height: size)
            .background(Color.sh.bgSelected, in: RoundedRectangle(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

/// The card the thread draws where the agent made a file (PaneArtifacts › in the thread): `bgRaised`, a `lineStrong` line, radius 8,
/// padding 10 × 12 and 12pt gaps; the tile, the name in `body` semibold over "HTML · 6m ago" in `caption` `textTertiary`, and Open.
public struct SHArtifactCard: View, Equatable {
    let row: SHArtifactRow
    /// nil where nothing can open it (a transcript with no pane beside it): the card draws no Open.
    let open: (() -> Void)?

    public init(_ row: SHArtifactRow, open: (() -> Void)?) {
        self.row = row
        self.open = open
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m + SH.Space.xxs) {
            SHArtifactTile(symbol: row.symbol, size: SHArtifactMetrics.cardTile, glyph: SHArtifactMetrics.cardGlyph)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(row.name).font(.sh(.body, weight: .semibold)).foregroundStyle(sh.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
            Spacer(minLength: SH.Space.m)
            if let open {
                Button(action: open) {
                    Label("Open", systemImage: "sidebar.right")
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .shTouchTarget(height: SH.Height.controlS)
                .accessibilityLabel("Open \(row.name)")
            }
        }
        .padding(.horizontal, SH.Space.m + SH.Space.xxs)
        .padding(.vertical, SHArtifactMetrics.cardPaddingV)
        .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .shBorder(sh.lineStrong, radius: SH.Radius.m)
        .accessibilityElement(children: .contain)
    }
}

/// The tab's list (`ArtifactList`): "This thread · 4" as a section label, then a row per artifact, newest first. A row is at least
/// 48pt (more on a touch screen) with padding 6 × 8, radius 8 and 10pt gaps. The open one is on `bgSelected`, name semibold.
public struct SHArtifactList: View {
    let rows: [SHArtifactRow]
    let selection: String?
    let open: (String) -> Void
    let extraMenu: ((SHArtifactRow) -> AnyView)?

    public init(_ rows: [SHArtifactRow], selection: String? = nil, open: @escaping (String) -> Void,
                menu: ((SHArtifactRow) -> AnyView)? = nil) {
        self.rows = rows
        self.selection = selection
        self.open = open
        self.extraMenu = menu
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("This thread · \(rows.count)")
                    .shSectionLabel()
                    .padding(EdgeInsets(top: SH.Space.m, leading: SH.Space.m, bottom: SH.Space.xs, trailing: SH.Space.m))
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    SHArtifactListRow(row: row, isSelected: row.id == selection) { open(row.id) }.equatable()
                }
            }
            .padding(SH.Space.s)
        }
        .scrollIndicators(.automatic)
        .background(Color.sh.bgWindow)
    }
}

struct SHArtifactListRow: View, Equatable {
    let row: SHArtifactRow
    let isSelected: Bool
    let open: () -> Void
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.isSelected == rhs.isSelected }

    var body: some View {
        let sh = Color.sh
        Button(action: open) {
            HStack(spacing: SH.Space.m + SH.Space.xxs) {
                SHArtifactTile(symbol: row.symbol, size: SHArtifactMetrics.rowTile, glyph: SHArtifactMetrics.rowGlyph)
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(row.name).font(.shSans(SHArtifactMetrics.nameSize, isSelected ? .semibold : .medium)).foregroundStyle(sh.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(row.detail).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
                Spacer(minLength: SH.Space.s)
            }
            .padding(.horizontal, SH.Space.s)
            .padding(.vertical, SH.Space.xs + SH.Space.xxs)
            .frame(minHeight: max(SHArtifactMetrics.rowMinHeight, touchMinimum))
            .background(isSelected ? sh.bgSelected : hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel("\(row.name), \(row.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var touchMinimum: CGFloat {
        #if os(iOS)
        SH.Height.touch
        #else
        0
        #endif
    }
}

/// What the tab says with nothing to list. The tab itself only shows once the thread has an artifact, so this is for a thread whose last
/// artifact went away, and for a list that is still loading.
public struct SHArtifactEmpty: View {
    let title: String
    let line: String

    public init(_ title: String, line: String) {
        self.title = title
        self.line = line
    }

    public var body: some View {
        VStack(spacing: SH.Space.s) {
            Text(title).font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
            Text(line).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).multilineTextAlignment(.center)
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// How the open artifact is drawn.
public enum SHArtifactMode: String, Hashable, Sendable { case preview, source }

/// The open artifact's bar (PaneArtifacts): All artifacts (back to the list), the kind tile, the name, Preview | Source (kinds that
/// have both), then the actions given. 44pt on the Mac and 52pt on the iPad, 8pt padding and gaps.
public struct SHArtifactBar<Actions: View>: View {
    let name: String
    let symbol: String
    let hasPreview: Bool
    @Binding var mode: SHArtifactMode
    let back: () -> Void
    let pad: Bool
    @ViewBuilder let actions: () -> Actions

    public init(name: String, symbol: String, hasPreview: Bool, mode: Binding<SHArtifactMode>, pad: Bool = false,
                back: @escaping () -> Void, @ViewBuilder actions: @escaping () -> Actions) {
        self.name = name
        self.symbol = symbol
        self.hasPreview = hasPreview
        _mode = mode
        self.pad = pad
        self.back = back
        self.actions = actions
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.s) {
            Button(action: back) { Image(systemName: "chevron.left") }
                .buttonStyle(.shIcon(size: pad ? SH.Height.touch - SH.Space.s : SH.Height.controlM))
                .shTouchTarget(height: SH.Height.controlM, width: SH.Height.controlM)
                .shHelp("All artifacts")
                .accessibilityLabel("All artifacts")
            SHArtifactTile(symbol: symbol, size: SHArtifactMetrics.barTile, glyph: SHArtifactMetrics.barGlyph, radius: SH.Radius.s)
            Text(name).font(.shSans(SHArtifactMetrics.nameSize, .semibold)).foregroundStyle(sh.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.s)
            if hasPreview {
                SHSegmentedPicker("View", selection: $mode, options: [(.preview, "Preview"), (.source, "Source")], size: .s)
                    .fixedSize()
            }
            actions()
        }
        .padding(.horizontal, SH.Space.s)
        .frame(height: pad ? SHArtifactMetrics.padBarHeight : SHArtifactMetrics.barHeight)
        .background(sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// An artifact's source: the text in mono on `bgSunken`, selectable, cut at `SHArtifactMetrics.sourceCharacterLimit` with a note.
public struct SHArtifactSource: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        let sh = Color.sh
        let cut = text.count > SHArtifactMetrics.sourceCharacterLimit
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text(cut ? String(text.prefix(SHArtifactMetrics.sourceCharacterLimit)) : text)
                    .font(.sh(.code))
                    .foregroundStyle(sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                if cut {
                    Text("Showing the first \(SHArtifactMetrics.sourceCharacterLimit.formatted()) characters.")
                        .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
            .padding(SHArtifactMetrics.documentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(sh.bgSunken)
    }
}

/// What an open artifact shows while its file is on its way, or when it cannot be had.
public struct SHArtifactNotice: View {
    public enum Kind: Equatable, Sendable { case loading, unavailable, failed(String) }
    let kind: Kind
    let retry: (() -> Void)?

    public init(_ kind: Kind, retry: (() -> Void)? = nil) {
        self.kind = kind
        self.retry = retry
    }

    public var body: some View {
        let sh = Color.sh
        VStack(spacing: SH.Space.m) {
            switch kind {
            case .loading:
                Text("Opening…").font(.sh(.ui)).foregroundStyle(sh.textTertiary)
            case .unavailable:
                Text("This file isn’t available").font(.sh(.headline)).foregroundStyle(sh.textPrimary)
                Text("It was moved or deleted, it is too large to open here, or the host can’t serve it.")
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary).multilineTextAlignment(.center)
            case .failed(let message):
                Text(message).font(.sh(.ui)).foregroundStyle(sh.textSecondary).multilineTextAlignment(.center)
                if let retry { Button("Try again", action: retry).buttonStyle(.sh(.secondary, size: .s)) }
            }
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(sh.bgWindow)
        .accessibilityElement(children: .contain)
    }
}
