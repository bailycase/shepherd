import SwiftUI

/// The review's files as a horizontally scrolling strip of 24pt chips (Review board): a bold
/// status letter, the filename, and for a modified file its diff stat. The selected chip has the
/// selected fill; viewed files dim; a running dot marks a file the agent is editing right now.
/// The selection slides from chip to chip (it cross-fades under Reduce Motion) and the strip
/// scrolls it into view; with `animatesSelection` false (keyboard navigation) both land at once.
public struct NWFileStrip: View {
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

        /// Added and deleted files show only their letter; the count is the whole file.
        public var showsStat: Bool { status == .modified || status == .renamed }

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
                HStack(spacing: NW.Space.xs) {
                    ForEach(items) { item in
                        NWFileChip(item: item, selected: item.id == selection, selectionSpace: reduceMotion ? nil : selectionSpace) {
                            onSelect(item.id)
                        }
                        .nwTransition(.list, edge: .leading)
                    }
                }
                .padding(NW.Space.s)
                // Files arriving or leaving (a reload, a revert) move the chips aside.
                .nwAnimation(.list, value: items.map(\.id))
                .animation(animatesSelection ? NW.Motion.content.animation(reduceMotion: reduceMotion) : nil, value: selection)
            }
            .scrollIndicators(.hidden)
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
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.s) {
                Text(item.status.letter).font(.nwMono(11, .bold)).foregroundStyle(item.status.color)
                Text(item.name).font(.nwMono(11)).foregroundStyle(nw.textPrimary).lineLimit(1)
                if item.showsStat { NWDiffStat(added: item.added, removed: item.removed, font: .nwMono(11)) }
                if item.isTouched { NWStatusDot(.running).nwTransition(.content) }
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: NW.Height.controlS)
            .opacity(item.isViewed ? 0.5 : 1)
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

    @ViewBuilder private var selectionFill: some View {
        let fill = RoundedRectangle(cornerRadius: NW.Radius.s).fill(Color.nw.bgSelected)
        if let selectionSpace {
            fill.matchedGeometryEffect(id: "selection", in: selectionSpace)
        } else {
            fill
        }
    }
}
