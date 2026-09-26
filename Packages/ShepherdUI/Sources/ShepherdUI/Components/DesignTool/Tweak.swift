import SwiftUI

// The Tweak tab's parts (DZTweak, NWDesignTool): its header, groups of rows, token chips, the
// scope, and the footer. The app composes them from what the selected element offers.

/// The Tweak tab's header: the path to the element in mono 11 `textTertiary` with the element in
/// `textPrimary` ("A · Funnel first › card · Checkout funnel"), then a note in 11.5 `textTertiary`
/// ("Changes show on the canvas as you drag."). 14×18 padding, a hairline under it.
public struct NWTweakHeader: View {
    let board: String
    let element: String?
    let note: String

    public init(board: String, element: String?, note: String) {
        self.board = board
        self.element = element
        self.note = note
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NWDesignMetrics.tweakHeaderSpacing) {
            Group {
                if let element {
                    Text("\(board) › ") + Text(element).foregroundStyle(Color.nw.textPrimary)
                } else {
                    Text(board).foregroundStyle(Color.nw.textPrimary)
                }
            }
            .font(.nwMono(NWDesignMetrics.tweakPathSize))
            .foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            Text(note)
                .font(.nwSans(NWDesignMetrics.tweakNoteSize))
                .foregroundStyle(Color.nw.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NWDesignMetrics.tweakPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.tweakPaddingHorizontal)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// A group of tweak rows under its section label (`.nwSectionLabel()`, 6pt above them), at 14×18
/// padding with a hairline under it (none under the last).
public struct NWTweakGroup<Content: View>: View {
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
                .nwSectionLabel()
                .foregroundStyle(Color.nw.textTertiary)
                .padding(.bottom, NWDesignMetrics.tweakLabelGap)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, NWDesignMetrics.tweakPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.tweakPaddingHorizontal)
        .overlay(alignment: .bottom) { if divided { NWHairline() } }
    }
}

/// One tweak (`NWTweakRow`): its label in 12.5 `textSecondary` in a 92pt column, then the control,
/// 12pt apart. A slider row is at least 30pt and its slider leads; any other control (a segmented
/// picker, a switch, token chips) sits at the trailing edge of a row at least 32pt tall.
public struct NWTweakRow<Control: View>: View {
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
                    HStack(spacing: NWDesignMetrics.tweakRowSpacing) {
                        title
                        control
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: NWDesignMetrics.tweakControlSpacing) {
                        title
                        control
                    }
                }
            case .trailing:
                // A control wider than the row leaves beside the label goes under it, trailing.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: NWDesignMetrics.tweakRowSpacing) {
                        title
                        Spacer(minLength: 0)
                        control
                    }
                    VStack(alignment: .trailing, spacing: NWDesignMetrics.tweakControlSpacing) {
                        title.frame(maxWidth: .infinity, alignment: .leading)
                        control
                    }
                }
            }
        }
        .frame(minHeight: layout == .slider ? NWDesignMetrics.tweakSliderRowHeight : NWDesignMetrics.tweakRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private var title: some View {
        Text(label)
            .font(.nwSans(NWDesignMetrics.tweakLabelSize))
            .foregroundStyle(Color.nw.textSecondary)
            .lineLimit(1)
            .frame(width: NWDesignMetrics.tweakLabelWidth, alignment: .leading)
    }
}

/// A color from the design's tokens, never a free hex (`NWTokenChip`): 26pt, 8pt padding,
/// radius 6, a 10pt swatch (radius 3) and the token's name in mono 11.5. Selected, a 1px
/// `running` line on `runningTint`; otherwise a 1px `lineSubtle` line. The swatch is the design's
/// own color, not Shepherd's.
public struct NWTokenChip: View {
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
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NWDesignMetrics.tokenChipSpacing) {
                RoundedRectangle(cornerRadius: NWDesignMetrics.tokenChipSwatchRadius)
                    .fill(swatch)
                    .frame(width: NWDesignMetrics.tokenChipSwatch, height: NWDesignMetrics.tokenChipSwatch)
                Text(name)
                    .font(.nwMono(NWDesignMetrics.tokenChipTextSize))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, NWDesignMetrics.tokenChipPadding)
            .frame(height: NWDesignMetrics.tokenChipHeight)
            .background(isSelected ? nw.runningTint : .clear, in: RoundedRectangle(cornerRadius: NWDesignMetrics.tokenChipRadius))
            .nwBorder(isSelected ? nw.running : nw.lineSubtle, radius: NWDesignMetrics.tokenChipRadius)
            .contentShape(Rectangle())
            .nwFocusRing(radius: NWDesignMetrics.tokenChipRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Token chips in a row that wraps, trailing-aligned, 6pt apart.
public struct NWTokenChipFlow: Layout {
    public init() {}

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * NWDesignMetrics.tweakControlSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            var x = bounds.maxX - row.width
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + NWDesignMetrics.tweakControlSpacing
            }
            y += row.height + NWDesignMetrics.tweakControlSpacing
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
            let added = row.indices.isEmpty ? size.width : row.width + NWDesignMetrics.tweakControlSpacing + size.width
            if !row.indices.isEmpty, added > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + NWDesignMetrics.tweakControlSpacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// Where a tweak applies (`NWTweakScope`): "This board" or every element that matches ("Every
/// funnel card"), as a small segmented picker.
public struct NWTweakScope: View {
    public enum Scope: Hashable, Sendable { case board, every }

    @Binding var selection: Scope
    let every: String

    public init(selection: Binding<Scope>, every: String) {
        _selection = selection
        self.every = every
    }

    public var body: some View {
        NWSegmentedPicker("Scope", selection: $selection, options: [(.board, "This board"), (.every, every)], size: .s)
    }
}

/// The note under a group's rows (the scope's reach): 11.5/1.45 `textTertiary`, 6pt under them.
public struct NWTweakNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nwSans(NWDesignMetrics.tweakNoteSize))
            .lineSpacing(NWDesignMetrics.tweakScopeNoteLineSpacing)
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, NWDesignMetrics.tweakScopeNoteGap)
    }
}

/// The Tweak tab's footer, pinned to its bottom: Reset (ghost, 24pt) leading and "Ask the agent
/// instead…" (secondary, 24pt) trailing, at 12×14 padding under a hairline.
public struct NWTweakFooter: View {
    let canReset: Bool
    let reset: () -> Void
    let ask: () -> Void

    public init(canReset: Bool, reset: @escaping () -> Void, ask: @escaping () -> Void) {
        self.canReset = canReset
        self.reset = reset
        self.ask = ask
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Button("Reset", action: reset)
                .buttonStyle(.nw(.ghost, size: .s))
                .disabled(!canReset)
            Spacer(minLength: 0)
            Button("Ask the agent instead…", action: ask)
                .buttonStyle(.nw(.secondary, size: .s))
        }
        .padding(.vertical, NWDesignMetrics.tweakFooterPaddingVertical)
        .padding(.horizontal, NWDesignMetrics.tweakFooterPaddingHorizontal)
        .overlay(alignment: .top) { NWHairline() }
    }
}
