import SwiftUI

/// The review's files as touch chips (iPadReview board): 44pt bordered chips on `bgRaised` with
/// the filename in mono 12; the selected chip is filled, viewed files dim. The strip scrolls the
/// selection into view.
public struct NWTouchFileStrip: View {
    let items: [NWFileStrip.Item]
    let selection: NWFileStrip.Item.ID?
    let onSelect: (NWFileStrip.Item.ID) -> Void

    public init(_ items: [NWFileStrip.Item], selection: NWFileStrip.Item.ID?, onSelect: @escaping (NWFileStrip.Item.ID) -> Void) {
        self.items = items
        self.selection = selection
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: NW.Space.s) {
                    ForEach(items) { item in
                        NWTouchFileChip(item: item, selected: item.id == selection) { onSelect(item.id) }
                            .equatable()
                    }
                }
                .padding(NW.Space.m)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection, initial: true) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Changed files")
    }

    /// The chips' height, the touch minimum.
    public static let chipHeight: CGFloat = NW.Height.touch
}

private struct NWTouchFileChip: View, Equatable {
    let item: NWFileStrip.Item
    let selected: Bool
    let action: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.item == rhs.item && lhs.selected == rhs.selected }

    var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.s)
        Button(action: action) {
            Text(item.name)
                .font(.nw(.mono))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, NW.Space.l)
                .frame(minHeight: NWTouchFileStrip.chipHeight)
                .opacity(item.isViewed ? 0.5 : 1)
                .background(selected ? nw.bgSelected : nw.bgRaised, in: shape)
                .nwBorder(nw.lineStrong, radius: NW.Radius.s)
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
public struct NWTouchFileHeader<Accessory: View>: View {
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
        let nw = Color.nw
        let (directory, name) = NWFileHeader.split(path)
        HStack(spacing: NW.Space.m) {
            Text("\(Text(directory).foregroundStyle(nw.textTertiary))\(Text(name).font(.nw(.code, weight: .semibold)).foregroundStyle(nw.textPrimary))")
                .font(.nw(.code))
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel(directory.isEmpty ? name : "\(name), in \(directory)")
                .accessibilityAddTraits(.isHeader)
            if let detail {
                Text(detail).font(.nw(.micro, weight: .regular)).foregroundStyle(nw.textTertiary).fixedSize()
            }
            if let added, let removed {
                NWDiffStat(added: added, removed: removed, font: .nw(.micro, weight: .regular))
            }
            Spacer(minLength: NW.Space.s)
            accessory()
        }
        .padding(.leading, NW.Space.l + NW.Space.xxs)
        .padding(.trailing, NW.Space.s)
        .frame(minHeight: NW.Height.touch)
        .background(nw.bgSunken)
        .overlay(alignment: .bottom) { NWHairline() }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Touch file strip") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWTouchFileStrip([
                .init(id: "a", path: "App/iOS/FleetView.swift", status: .modified, added: 10, removed: 54),
                .init(id: "b", path: "App/iOS/ThreadView.swift", status: .modified, added: 48, removed: 3),
                .init(id: "c", path: "App/iOS/HostCard.swift", status: .added, added: 31, removed: 0, isViewed: true),
            ], selection: "a") { _ in }
            NWTouchFileHeader(path: "App/iOS/FleetView.swift", detail: "2 hunks") {
                Button {} label: { Image(systemName: "checkmark") }
                    .buttonStyle(.nwIcon(size: NW.Height.controlS))
                    .accessibilityLabel("Mark viewed")
            }
        }
        .frame(width: 520)
    }
}
