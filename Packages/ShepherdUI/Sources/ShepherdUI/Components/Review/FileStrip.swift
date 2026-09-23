import SwiftUI

/// The review's files as a horizontally scrolling strip of 24pt chips (Review board): a bold
/// status letter, the filename, and for a modified file its diff stat. The selected chip has the
/// selected fill; viewed files dim; a running dot marks a file the agent is editing right now.
/// The strip scrolls the selection into view (without animation under Reduce Motion).
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
    let onSelect: (Item.ID) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ items: [Item], selection: Item.ID?, onSelect: @escaping (Item.ID) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: NW.Space.xs) {
                    ForEach(items) { item in
                        NWFileChip(item: item, selected: item.id == selection) { onSelect(item.id) }
                    }
                }
                .padding(NW.Space.s)
            }
            .scrollIndicators(.hidden)
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: NW.Motion.hover.duration)) { proxy.scrollTo(id) }
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
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.s) {
                Text(item.status.letter).font(.nwMono(11, .bold)).foregroundStyle(item.status.color)
                Text(item.name).font(.nwMono(11)).foregroundStyle(nw.textPrimary).lineLimit(1)
                if item.showsStat { NWDiffStat(added: item.added, removed: item.removed, font: .nwMono(11)) }
                if item.isTouched { NWStatusDot(.running) }
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: NW.Height.controlS)
            .opacity(item.isViewed ? 0.5 : 1)
        }
        .buttonStyle(.nwRow(selected: selected))
        .help(item.path)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
