import SwiftUI

// The Tweak tab's parts (DZTweak, SHDesignTool): its header, groups of rows, token chips, the
// scope, and the footer. The app composes them from what the selected element offers.

/// The Tweak tab's header: the path to the element in mono 11 `textTertiary` with the element in
/// `textPrimary` ("A · Funnel first › card · Checkout funnel"), then a note in 11.5 `textTertiary`
/// ("Changes show on the canvas as you drag."). 14×18 padding, a hairline under it.
public struct SHTweakHeader: View {
    let board: String
    let element: String?
    let note: String

    public init(board: String, element: String?, note: String) {
        self.board = board
        self.element = element
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHDesignMetrics.tweakHeaderSpacing) {
            Group {
                if let element {
                    Text("\(board) › ") + Text(element).foregroundStyle(Color.sh.textPrimary)
                } else {
                    Text(board).foregroundStyle(Color.sh.textPrimary)
                }
            }
            .font(.shMono(SHDesignMetrics.tweakPathSize))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            Text(note)
                .font(.shSans(SHDesignMetrics.tweakNoteSize))
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SHDesignMetrics.tweakPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.tweakPaddingHorizontal)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// A group of tweak rows under its section label (`.shSectionLabel()`, 6pt above them), at 14×18
/// padding with a hairline under it (none under the last).
public struct SHTweakGroup<Content: View>: View {
    let title: String
    let divided: Bool
    let content: Content

    public init(_ title: String, divided: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.divided = divided
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .shSectionLabel()
                .foregroundStyle(Color.sh.textTertiary)
                .padding(.bottom, SHDesignMetrics.tweakLabelGap)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SHDesignMetrics.tweakPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.tweakPaddingHorizontal)
        .overlay(alignment: .bottom) { if divided { SHHairline() } }
    }
}

/// One tweak (`SHTweakRow`): its label in 12.5 `textSecondary` in a 92pt column, then the control,
/// 12pt apart. A slider row is at least 30pt and its slider leads; any other control (a segmented
/// picker, a switch, token chips) sits at the trailing edge of a row at least 32pt tall.
public struct SHTweakRow<Control: View>: View {
    public enum Layout: Sendable { case slider, trailing }

    let label: String
    let layout: Layout
    let control: Control

    public init(_ label: String, layout: Layout = .trailing, @ViewBuilder control: () -> Control) {
        self.label = label
        self.layout = layout
        self.control = control()
    }

    public var body: some View {
        Group {
            switch layout {
            case .slider:
                // A slider wider than the row leaves beside the label (the iPad's narrower pane)
                // goes under it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SHDesignMetrics.tweakRowSpacing) {
                        title
                        control
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: SHDesignMetrics.tweakControlSpacing) {
                        title
                        control
                    }
                }
            case .trailing:
                // A control wider than the row leaves beside the label goes under it, trailing.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: SHDesignMetrics.tweakRowSpacing) {
                        title
                        Spacer(minLength: 0)
                        control
                    }
                    VStack(alignment: .trailing, spacing: SHDesignMetrics.tweakControlSpacing) {
                        title.frame(maxWidth: .infinity, alignment: .leading)
                        control
                    }
                }
            }
        }
        .frame(minHeight: layout == .slider ? SHDesignMetrics.tweakSliderRowHeight : SHDesignMetrics.tweakRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var title: some View {
        Text(label)
            .font(.shSans(SHDesignMetrics.tweakLabelSize))
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(1)
            .frame(width: SHDesignMetrics.tweakLabelWidth, alignment: .leading)
    }
}

/// A color from the design's tokens, never a free hex (`SHTokenChip`): 26pt, 8pt padding,
/// radius 6, a 10pt swatch (radius 3) and the token's name in mono 11.5. Selected, a 1px
/// `running` line on `runningTint`; otherwise a 1px `lineSubtle` line. The swatch is the design's
/// own color, not Shepherd's.
public struct SHTokenChip: View {
    let name: String
    let swatch: Color
    let isSelected: Bool
    let action: () -> Void

    public init(_ name: String, swatch: Color, isSelected: Bool, action: @escaping () -> Void) {
        self.name = name
        self.swatch = swatch
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SHDesignMetrics.tokenChipSpacing) {
                RoundedRectangle(cornerRadius: SHDesignMetrics.tokenChipSwatchRadius)
                    .fill(swatch)
                    .frame(width: SHDesignMetrics.tokenChipSwatch, height: SHDesignMetrics.tokenChipSwatch)
                Text(name)
                    .font(.shMono(SHDesignMetrics.tokenChipTextSize))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, SHDesignMetrics.tokenChipPadding)
            .frame(height: SHDesignMetrics.tokenChipHeight)
            .background(isSelected ? sh.runningTint : .clear, in: RoundedRectangle(cornerRadius: SHDesignMetrics.tokenChipRadius))
            .shBorder(isSelected ? sh.running : sh.lineSubtle, radius: SHDesignMetrics.tokenChipRadius)
            .contentShape(Rectangle())
            .shFocusRing(radius: SHDesignMetrics.tokenChipRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Token chips in a row that wraps, trailing-aligned, 6pt apart.
public struct SHTokenChipFlow: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * SHDesignMetrics.tweakControlSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + SHDesignMetrics.tweakControlSpacing
            }
            y += row.height + SHDesignMetrics.tweakControlSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let added = row.indices.isEmpty ? size.width : row.width + SHDesignMetrics.tweakControlSpacing + size.width
            if !row.indices.isEmpty, added > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + SHDesignMetrics.tweakControlSpacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where a tweak applies (`SHTweakScope`): "This board" or every element that matches ("Every
/// funnel card"), as a small segmented picker.
public struct SHTweakScope: View {
    public enum Scope: Hashable, Sendable { case board, every }

    @Binding var selection: Scope
    let every: String

    public init(selection: Binding<Scope>, every: String) {
        _selection = selection
        self.every = every
    }

    public var body: some View {
        SHSegmentedPicker("Scope", selection: $selection, options: [(.board, "This board"), (.every, every)], size: .s)
    }
}

/// The note under a group's rows (the scope's reach): 11.5/1.45 `textTertiary`, 6pt under them.
public struct SHTweakNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.shSans(SHDesignMetrics.tweakNoteSize))
            .lineSpacing(SHDesignMetrics.tweakScopeNoteLineSpacing)
            .foregroundStyle(Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, SHDesignMetrics.tweakScopeNoteGap)
    }
}

/// An element that is one use of a shared piece (`SHTweakPieceNote`): the piece draws it, so a style
/// written on the instance would do nothing, and the tab offers none. It is the "Shared piece" group
/// at the tab's padding, saying where a change goes (the piece, once, for every board that uses it)
/// in the scope note's 11.5/1.45 `textTertiary`, with a small ghost "Go to source" under it when the
/// piece has a frame on the canvas to go to. Under it, a hairline.
public struct SHTweakPieceNote: View {
    let piece: String
    let boards: String?
    let goToSource: (() -> Void)?

    /// `piece` is its name ("Card"); `boards` how many boards use it ("3 boards"), when known;
    /// `goToSource` brings the piece's board into view (nil: it has no frame).
    public init(piece: String, boards: String? = nil, goToSource: (() -> Void)?) {
        self.piece = piece
        self.boards = boards
        self.goToSource = goToSource
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shared piece")
                .shSectionLabel()
                .foregroundStyle(Color.sh.textTertiary)
                .padding(.bottom, SHDesignMetrics.tweakLabelGap)
            Text("This is one use of \(piece)\(boards.map { ", drawn by \($0)" } ?? ""). Its look comes from the piece: change the piece to change every use.")
                .font(.shSans(SHDesignMetrics.tweakNoteSize))
                .lineSpacing(SHDesignMetrics.tweakScopeNoteLineSpacing)
                .foregroundStyle(Color.sh.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let goToSource {
                Button("Go to source", action: goToSource)
                    .buttonStyle(.sh(.secondary, size: .s))
                    .padding(.top, SHDesignMetrics.tweakControlSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, SHDesignMetrics.tweakPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.tweakPaddingHorizontal)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shared piece \(piece)")
    }
}

/// The Tweak tab's footer, pinned to its bottom: Reset (ghost, 24pt) leading and "Ask the agent
/// instead…" (secondary, 24pt) trailing, at 12×14 padding under a hairline.
public struct SHTweakFooter: View {
    let canReset: Bool
    let reset: () -> Void
    let ask: () -> Void

    public init(canReset: Bool, reset: @escaping () -> Void, ask: @escaping () -> Void) {
        self.canReset = canReset
        self.reset = reset
        self.ask = ask
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Button("Reset", action: reset)
                .buttonStyle(.sh(.ghost, size: .s))
                .disabled(!canReset)
            Spacer(minLength: 0)
            Button("Ask the agent instead…", action: ask)
                .buttonStyle(.sh(.secondary, size: .s))
        }
        .padding(.vertical, SHDesignMetrics.tweakFooterPaddingVertical)
        .padding(.horizontal, SHDesignMetrics.tweakFooterPaddingHorizontal)
        .overlay(alignment: .top) { SHHairline() }
    }
}
