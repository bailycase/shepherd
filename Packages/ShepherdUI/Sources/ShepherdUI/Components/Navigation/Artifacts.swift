import SwiftUI

// The Artifacts tab and its card in the thread (PaneArtifacts, iPadPaneArtifacts): files the agent made. Plain values in, closures out;
// the Mac and the iPad draw the same parts at their own sizes (`NWArtifactMetrics.Scale`).

/// What the tab's parts are measured by. The Mac's values are PaneArtifacts', the iPad's iPadPaneArtifacts' (a 52pt bar, 36pt controls).
public enum NWArtifactMetrics {
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
public struct NWArtifactRow: Identifiable, Equatable, Sendable {
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
public struct NWArtifactTile: View {
    let symbol: String
    let size: CGFloat
    let glyph: CGFloat
    let radius: CGFloat

    public init(symbol: String, size: CGFloat, glyph: CGFloat, radius: CGFloat = NW.Radius.m) {
        self.symbol = symbol
        self.size = size
        self.glyph = glyph
        self.radius = radius
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: glyph, weight: .medium))
            .foregroundStyle(Color.nw.textSecondary)
            .frame(width: size, height: size)
            .background(Color.nw.bgSelected, in: RoundedRectangle(cornerRadius: radius))
            .accessibilityHidden(true)
    }
}

/// The card the thread draws where the agent made a file (PaneArtifacts › in the thread): `bgRaised`, a `lineStrong` line, radius 8,
/// padding 10 × 12 and 12pt gaps; the tile, the name in `body` semibold over "HTML · 6m ago" in `caption` `textTertiary`, and Open.
public struct NWArtifactCard: View, Equatable {
    let row: NWArtifactRow
    /// nil where nothing can open it (a transcript with no pane beside it): the card draws no Open.
    let open: (() -> Void)?

    public init(_ row: NWArtifactRow, open: (() -> Void)?) {
        self.row = row
        self.open = open
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m + NW.Space.xxs) {
            NWArtifactTile(symbol: row.symbol, size: NWArtifactMetrics.cardTile, glyph: NWArtifactMetrics.cardGlyph)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(row.name).font(.nw(.body, weight: .semibold)).foregroundStyle(nw.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(.nw(.caption)).foregroundStyle(nw.textTertiary).lineLimit(1)
            }
            Spacer(minLength: NW.Space.m)
            if let open {
                Button(action: open) {
                    Label("Open", systemImage: "sidebar.right")
                }
                .buttonStyle(.nw(.secondary, size: .s))
                .nwTouchTarget(height: NW.Height.controlS)
                .accessibilityLabel("Open \(row.name)")
            }
        }
        .padding(.horizontal, NW.Space.m + NW.Space.xxs)
        .padding(.vertical, NWArtifactMetrics.cardPaddingV)
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineStrong, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }
}

/// The tab's list (`ArtifactList`): "This thread · 4" as a section label, then a row per artifact, newest first. A row is at least
/// 48pt (more on a touch screen) with padding 6 × 8, radius 8 and 10pt gaps. The open one is on `bgSelected`, name semibold.
public struct NWArtifactList: View {
    let rows: [NWArtifactRow]
    let selection: String?
    let open: (String) -> Void
    let extraMenu: ((NWArtifactRow) -> AnyView)?

    public init(_ rows: [NWArtifactRow], selection: String? = nil, open: @escaping (String) -> Void,
                menu: ((NWArtifactRow) -> AnyView)? = nil) {
        self.rows = rows
        self.selection = selection
        self.open = open
        self.extraMenu = menu
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                Text("This thread · \(rows.count)")
                    .nwSectionLabel()
                    .padding(EdgeInsets(top: NW.Space.m, leading: NW.Space.m, bottom: NW.Space.xs, trailing: NW.Space.m))
                    .accessibilityAddTraits(.isHeader)
                ForEach(rows) { row in
                    NWArtifactListRow(row: row, isSelected: row.id == selection) { open(row.id) }.equatable()
                }
            }
            .padding(NW.Space.s)
        }
        .scrollIndicators(.automatic)
        .background(Color.nw.bgWindow)
    }
}

struct NWArtifactListRow: View, Equatable {
    let row: NWArtifactRow
    let isSelected: Bool
    let open: () -> Void
    @State private var hovering = false

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row && lhs.isSelected == rhs.isSelected }

    var body: some View {
        let nw = Color.nw
        Button(action: open) {
            HStack(spacing: NW.Space.m + NW.Space.xxs) {
                NWArtifactTile(symbol: row.symbol, size: NWArtifactMetrics.rowTile, glyph: NWArtifactMetrics.rowGlyph)
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text(row.name).font(.nwSans(NWArtifactMetrics.nameSize, isSelected ? .semibold : .medium)).foregroundStyle(nw.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(row.detail).font(.nw(.caption)).foregroundStyle(nw.textTertiary).lineLimit(1)
                }
                Spacer(minLength: NW.Space.s)
            }
            .padding(.horizontal, NW.Space.s)
            .padding(.vertical, NW.Space.xs + NW.Space.xxs)
            .frame(minHeight: max(NWArtifactMetrics.rowMinHeight, touchMinimum))
            .background(isSelected ? nw.bgSelected : hovering ? nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel("\(row.name), \(row.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var touchMinimum: CGFloat {
        #if os(iOS)
        NW.Height.touch
        #else
        0
        #endif
    }
}

/// What the tab says with nothing to list. The tab itself only shows once the thread has an artifact, so this is for a thread whose last
/// artifact went away, and for a list that is still loading.
public struct NWArtifactEmpty: View {
    let title: String
    let line: String

    public init(_ title: String, line: String) {
        self.title = title
        self.line = line
    }

    public var body: some View {
        VStack(spacing: NW.Space.s) {
            Text(title).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
            Text(line).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).multilineTextAlignment(.center)
        }
        .padding(NW.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// How the open artifact is drawn.
public enum NWArtifactMode: String, Hashable, Sendable { case preview, source }

/// The open artifact's bar (PaneArtifacts): All artifacts (back to the list), the kind tile, the name, Preview | Source (kinds that
/// have both), then the actions given. 44pt on the Mac and 52pt on the iPad, 8pt padding and gaps.
public struct NWArtifactBar<Actions: View>: View {
    let name: String
    let symbol: String
    let hasPreview: Bool
    @Binding var mode: NWArtifactMode
    let back: () -> Void
    let pad: Bool
    @ViewBuilder let actions: () -> Actions

    public init(name: String, symbol: String, hasPreview: Bool, mode: Binding<NWArtifactMode>, pad: Bool = false,
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
        let nw = Color.nw
        HStack(spacing: NW.Space.s) {
            Button(action: back) { Image(systemName: "chevron.left") }
                .buttonStyle(.nwIcon(size: pad ? NW.Height.touch - NW.Space.s : NW.Height.controlM))
                .nwTouchTarget(height: NW.Height.controlM, width: NW.Height.controlM)
                .nwHelp("All artifacts")
                .accessibilityLabel("All artifacts")
            NWArtifactTile(symbol: symbol, size: NWArtifactMetrics.barTile, glyph: NWArtifactMetrics.barGlyph, radius: NW.Radius.s)
            Text(name).font(.nwSans(NWArtifactMetrics.nameSize, .semibold)).foregroundStyle(nw.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.s)
            if hasPreview {
                NWSegmentedPicker("View", selection: $mode, options: [(.preview, "Preview"), (.source, "Source")], size: .s)
                    .fixedSize()
            }
            actions()
        }
        .padding(.horizontal, NW.Space.s)
        .frame(height: pad ? NWArtifactMetrics.padBarHeight : NWArtifactMetrics.barHeight)
        .background(nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// An artifact's source: the text in mono on `bgSunken`, selectable, cut at `NWArtifactMetrics.sourceCharacterLimit` with a note.
public struct NWArtifactSource: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        let nw = Color.nw
        let cut = text.count > NWArtifactMetrics.sourceCharacterLimit
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: NW.Space.m) {
                Text(cut ? String(text.prefix(NWArtifactMetrics.sourceCharacterLimit)) : text)
                    .font(.nw(.code))
                    .foregroundStyle(nw.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                if cut {
                    Text("Showing the first \(NWArtifactMetrics.sourceCharacterLimit.formatted()) characters.")
                        .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                }
            }
            .padding(NWArtifactMetrics.documentInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(nw.bgSunken)
    }
}

/// What an open artifact shows while its file is on its way, or when it cannot be had.
public struct NWArtifactNotice: View {
    public enum Kind: Equatable, Sendable { case loading, unavailable, failed(String) }
    let kind: Kind
    let retry: (() -> Void)?

    public init(_ kind: Kind, retry: (() -> Void)? = nil) {
        self.kind = kind
        self.retry = retry
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: NW.Space.m) {
            switch kind {
            case .loading:
                Text("Opening…").font(.nw(.ui)).foregroundStyle(nw.textTertiary)
            case .unavailable:
                Text("This file isn’t available").font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                Text("It was moved or deleted, it is too large to open here, or the host can’t serve it.")
                    .font(.nw(.caption)).foregroundStyle(nw.textTertiary).multilineTextAlignment(.center)
            case .failed(let message):
                Text(message).font(.nw(.ui)).foregroundStyle(nw.textSecondary).multilineTextAlignment(.center)
                if let retry { Button("Try again", action: retry).buttonStyle(.nw(.secondary, size: .s)) }
            }
        }
        .padding(NW.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(nw.bgWindow)
        .accessibilityElement(children: .contain)
    }
}
