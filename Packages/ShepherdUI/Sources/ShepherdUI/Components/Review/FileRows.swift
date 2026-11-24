import SwiftUI

/// The Changes pane's files as rows (GXSidePane `.pf`): the first few, each 28pt with its name, its directory in `caption`
/// `textTertiary` and its diff stat; the current one on `bgSelected`; "Show 4 more" opens the rest. A viewed file's name
/// dims with a `done` check, and a running dot marks one the agent is editing right now. Selecting a file below the first few
/// opens the rest, so the current one never hides.
public struct SHFileRows: View {
    public enum Metrics {
        public static let rowHeight: CGFloat = 28
        /// How many rows show before "Show N more".
        public static let collapsed = 3
        /// Opened, a long list scrolls after this many rows.
        public static let openRows = 10
        public static let gap: CGFloat = SH.Space.m
        public static let dirGap: CGFloat = SH.Space.s
        public static let checkSize: CGFloat = 9
    }

    let items: [SHFileStrip.Item]
    let selection: SHFileStrip.Item.ID?
    let onSelect: (SHFileStrip.Item.ID) -> Void
    @State private var opened = false

    public init(_ items: [SHFileStrip.Item], selection: SHFileStrip.Item.ID?, onSelect: @escaping (SHFileStrip.Item.ID) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    /// The rows on show: all of them once opened or when the current file is below the first few.
    static func shown(_ items: [SHFileStrip.Item], selection: SHFileStrip.Item.ID?, opened: Bool) -> ArraySlice<SHFileStrip.Item> {
        let selected = selection.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        return opened || selected >= Metrics.collapsed ? items[...] : items.prefix(Metrics.collapsed)
    }

    public var body: some View {
        let shown = Self.shown(items, selection: selection, opened: opened)
        let hidden = items.count - shown.count
        VStack(alignment: .leading, spacing: 0) {
            if shown.count > Metrics.openRows {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) { rows(shown) }
                    }
                    .scrollIndicators(.never)
                    .frame(height: Metrics.rowHeight * CGFloat(Metrics.openRows))
                    .onChange(of: selection) { _, id in if let id { proxy.scrollTo(id) } }
                }
            } else {
                rows(shown)
            }
            if hidden > 0 {
                toggle("Show \(hidden) more", help: "Show every changed file")
            } else if opened, items.count > Metrics.collapsed {
                toggle("Show fewer", help: "Show the first \(Metrics.collapsed) files")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    private func rows(_ shown: ArraySlice<SHFileStrip.Item>) -> some View {
        ForEach(shown) { item in
            SHFileRow(item: item, selected: item.id == selection) { onSelect(item.id) }
                .equatable()
                .id(item.id)
        }
    }

    private func toggle(_ title: String, help: String) -> some View {
        Button { withSHAnimation(.disclosure) { opened.toggle() } } label: {
            Text(title)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(Color.sh.textSecondary)
                .padding(.horizontal, SH.Space.m)
                .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.shRow())
        .help(help)
    }
}

private struct SHFileRow: View, Equatable {
    let item: SHFileStrip.Item
    let selected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let _ = SHRenderProbe.tick("review.fileRow")
        let sh = Color.sh
        let (directory, name) = SHFileHeader.split(item.path)
        Button(action: action) {
            HStack(spacing: SHFileRows.Metrics.gap) {
                HStack(spacing: SHFileRows.Metrics.dirGap) {
                    Text(name).font(.sh(.ui, weight: .regular)).foregroundStyle(item.isViewed && !selected ? sh.textTertiary : sh.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if !directory.isEmpty {
                        Text(directory.hasSuffix("/") ? String(directory.dropLast()) : directory)
                            .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 0)
                if item.isTouched { SHStatusDot(.running).shTransition(.content) }
                if item.isViewed {
                    Image(systemName: "checkmark").font(.system(size: SHFileRows.Metrics.checkSize, weight: .semibold)).foregroundStyle(sh.done)
                        .accessibilityHidden(true)
                        .shTransition(.content)
                }
                SHDiffStat(added: item.added, removed: item.removed, font: .sh(.caption), hidesZero: true)
            }
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHFileRows.Metrics.rowHeight, alignment: .leading)
            .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(hoverFill: selected ? .clear : nil))
        .shAnimation(.content, value: item.isTouched)
        .help(item.path)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
