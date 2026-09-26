import SwiftUI

/// The review's files as a horizontally scrolling strip of 26pt chips (FileStrip): a bold status
/// letter, the filename, and its diff stat. The selected chip has the selected fill and its name
/// in `textPrimary`; a viewed file's name dims to tertiary with a `done` check; a running dot
/// marks a file the agent is editing right now.
/// The selection slides from chip to chip (it cross-fades under Reduce Motion) and the strip
/// scrolls it into view; with `animatesSelection` false (keyboard navigation) both land at once.
public struct NWFileStrip: View {
    static let chipHeight: CGFloat = 26
    static let chipPadding: CGFloat = 9

    public struct Item: Identifiable, Equatable, Sendable {
        public let id: String
        /// The full path: the chip's help tag.
        public let path: String
        public let status: NWFileStatus
        public let added: Int
        public let removed: Int
        public let isViewed: Bool
        public let isTouched: Bool

        public init(id: String, path: String, status: NWFileStatus, added: Int, removed: Int, isViewed: Bool = false, isTouched: Bool = false) {
            self.id = id
            self.path = path
            self.status = status
            self.added = added
            self.removed = removed
            self.isViewed = isViewed
            self.isTouched = isTouched
        }

        public var name: String { NWFileHeader.split(path).name }

        /// Every file shows its stat, a new file's too (FileStrip).
        public var showsStat: Bool { true }

        /// "FleetView.swift, modified, 10 added, 54 removed, viewed".
        public var accessibilityText: String {
            var parts = [name, status.label, "\(added) added, \(removed) removed"]
            if isViewed { parts.append("viewed") }
            if isTouched { parts.append("being edited") }
            return parts.joined(separator: ", ")
        }
    }

    let items: [Item]
    let selection: Item.ID?
    let animatesSelection: Bool
    let onSelect: (Item.ID) -> Void
    @Namespace private var selectionSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ items: [Item], selection: Item.ID?, animatesSelection: Bool = true, onSelect: @escaping (Item.ID) -> Void) {
        self.items = items
        self.selection = selection
        self.animatesSelection = animatesSelection
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                // Lazy: a big change touches hundreds of files, and only the chips in view are built.
                LazyHStack(spacing: NW.Space.xxs) {
                    ForEach(items) { item in
                        NWFileChip(item: item, selected: item.id == selection, selectionSpace: reduceMotion ? nil : selectionSpace) {
                            onSelect(item.id)
                        }
                        // A chip that leaves goes at once and the chips after it close up: fading
                        // where it was, it would show through the chips sliding over it.
                        .transition(.asymmetric(insertion: NW.Motion.list.transition(reduceMotion: reduceMotion, edge: .leading),
                                                removal: .identity))
                    }
                }
                .padding(.horizontal, NW.Space.m)
                .padding(.vertical, NW.Space.s)
                // Files arriving or leaving (a reload, a revert) move the chips aside.
                .nwAnimation(.list, value: items.map(\.id))
                .animation(animatesSelection ? NW.Motion.content.animation(reduceMotion: reduceMotion) : nil, value: selection)
            }
            .scrollIndicators(.hidden)
            // As tall as its chips: a lazy stack would otherwise take whatever height it's offered.
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { old, id in
                guard let id else { return }
                // The first selection lands with the pane: an animation started there would
                // carry the rest of that first layout with it (the thread beside the pane too).
                if animatesSelection, old != nil {
                    withNWAnimation(.scroll) { proxy.scrollTo(id) }
                } else {
                    proxy.scrollTo(id)
                }
            }
        }
        .background(Color.nw.bgBase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }
}

private struct NWFileChip: View, Equatable {
    let item: NWFileStrip.Item
    let selected: Bool
    /// Where the selection's fill slides between chips; nil under Reduce Motion.
    let selectionSpace: Namespace.ID?
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.item == rhs.item && lhs.selected == rhs.selected && lhs.selectionSpace == rhs.selectionSpace
    }

    var body: some View {
        let _ = NWRenderProbe.tick("review.fileChip")
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.s) {
                Text(item.status.letter).font(.nwMono(10.5, .bold)).foregroundStyle(item.status.color)
                Text(item.name).font(.nw(.mono)).foregroundStyle(nameColor(nw)).lineLimit(1)
                if item.showsStat { NWDiffStat(added: item.added, removed: item.removed, font: .nwMono(10.5)) }
                if item.isViewed {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(nw.done)
                        .nwTransition(.content)
                }
                if item.isTouched { NWStatusDot(.running).nwTransition(.content) }
            }
            .padding(.horizontal, NWFileStrip.chipPadding)
            .frame(minHeight: NWFileStrip.chipHeight)
            .background {
                if selected { selectionFill }
            }
        }
        // The chip draws the selected fill itself, so the fill can travel to the next chip; the
        // row style only hovers, and never over the selection.
        .buttonStyle(.nwRow(hoverFill: selected ? .clear : nil))
        .nwAnimation(.hover, value: item.isViewed)
        .nwAnimation(.content, value: item.isTouched)
        .help(item.path)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func nameColor(_ nw: NWPalette) -> Color {
        selected ? nw.textPrimary : item.isViewed ? nw.textTertiary : nw.textSecondary
    }

    @ViewBuilder private var selectionFill: some View {
        let fill = RoundedRectangle(cornerRadius: NW.Radius.s).fill(Color.nw.bgSelected)
        if let selectionSpace {
            fill.matchedGeometryEffect(id: "selection", in: selectionSpace)
        } else {
            fill
        }
    }
}
