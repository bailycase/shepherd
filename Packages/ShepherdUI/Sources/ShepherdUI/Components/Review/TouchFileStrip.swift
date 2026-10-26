import SwiftUI

/// The review's files as touch chips (iPadReview board): 44pt bordered chips on `bgRaised` with
/// the filename in mono 12; the selected chip is filled, viewed files dim. The strip scrolls the
/// selection into view.
public struct SHTouchFileStrip: View {
    let items: [SHFileStrip.Item]
    let selection: SHFileStrip.Item.ID?
    let onSelect: (SHFileStrip.Item.ID) -> Void

    public init(_ items: [SHFileStrip.Item], selection: SHFileStrip.Item.ID?, onSelect: @escaping (SHFileStrip.Item.ID) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: SH.Space.s) {
                    ForEach(items) { item in
                        SHTouchFileChip(item: item, selected: item.id == selection) { onSelect(item.id) }
                            .equatable()
                    }
                }
                .padding(SH.Space.m)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    /// The chips' height, the touch minimum.
    public static let chipHeight: CGFloat = SH.Height.touch
}

private struct SHTouchFileChip: View, Equatable {
    let item: SHFileStrip.Item
    let selected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.s)
        Button(action: action) {
            Text(item.name)
                .font(.sh(.mono))
                .foregroundStyle(sh.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SHTouchFileStrip.chipHeight)
                .opacity(item.isViewed ? 0.5 : 1)
                .background(selected ? sh.bgSelected : sh.bgRaised, in: shape)
                .shBorder(sh.lineStrong, radius: SH.Radius.s)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityText)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A file's header over its diff (iPadReview board): at least a touch target tall on
/// `bgSunken`, the path with its directory in tertiary and the name in semibold mono, the hunk
/// count or diff stat, then the caller's controls (Mark viewed, the diff style).
public struct SHTouchFileHeader<Accessory: View>: View {
    let path: String
    let detail: String?
    let added: Int?
    let removed: Int?
    @ViewBuilder let accessory: () -> Accessory

    /// `detail` ("2 hunks") or the stat (`added`/`removed`) follow the path.
    public init(path: String, detail: String? = nil, added: Int? = nil, removed: Int? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.path = path
        self.detail = detail
        self.added = added
        self.removed = removed
        self.accessory = accessory
    }

    public var body: some View {
        let sh = Color.sh
        let (directory, name) = SHFileHeader.split(path)
        HStack(spacing: SH.Space.m) {
            Text("\(Text(directory).foregroundStyle(sh.textTertiary))\(Text(name).font(.sh(.code, weight: .semibold)).foregroundStyle(sh.textPrimary))")
                .font(.sh(.code))
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel(directory.isEmpty ? name : "\(name), in \(directory)")
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).fixedSize()
            }
            if let added, let removed {
                SHDiffStat(added: added, removed: removed, font: .sh(.micro, weight: .regular))
            }
            Spacer(minLength: SH.Space.s)
            accessory()
        }
        .padding(.leading, SH.Space.l + SH.Space.xxs)
        .padding(.trailing, SH.Space.s)
        .frame(minHeight: SH.Height.touch)
        .background(sh.bgSunken)
        .overlay(alignment: .bottom) { SHHairline() }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Touch file strip") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHTouchFileStrip([
                .init(id: "a", path: "App/iOS/FleetView.swift", status: .modified, added: 10, removed: 54),
                .init(id: "b", path: "App/iOS/ThreadView.swift", status: .modified, added: 48, removed: 3),
                .init(id: "c", path: "App/iOS/HostCard.swift", status: .added, added: 31, removed: 0, isViewed: true),
            ], selection: "a") { _ in }
            SHTouchFileHeader(path: "App/iOS/FleetView.swift", detail: "2 hunks") {
                Button {} label: { Image(systemName: "checkmark") }
                    .buttonStyle(.shIcon(size: SH.Height.controlS))
                    .accessibilityLabel("Mark viewed")
            }
        }
        .frame(width: 520)
    }
}
