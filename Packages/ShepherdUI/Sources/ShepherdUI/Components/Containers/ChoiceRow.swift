import SwiftUI

/// A choice row's measures (the Where it runs board): a 15pt mono name over a 12pt detail, at
/// least 56pt tall, with a 20pt leading column for the icon or status dot.
public enum NWChoiceRowMetrics {
    public static let titleSize: CGFloat = 15
    public static let minHeight: CGFloat = 56
    public static let leadingWidth: CGFloat = 20
    public static let statusDot: CGFloat = 8
}

/// One option in a picker list (a repo, a host): a leading icon or status dot, the name over a
/// detail line and an optional note, and a checkmark when chosen. `trailing` takes an inline
/// action instead (Retry). Draw it as a button's label, inside an `NWGroupCard`.
public struct NWChoiceRow<Leading: View, Trailing: View>: View {
    let title: String
    let detail: String?
    let note: String?
    let mono: Bool
    let selected: Bool
    let dimmed: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, detail: String? = nil, note: String? = nil, mono: Bool = true, selected: Bool = false, dimmed: Bool = false,
                @ViewBuilder leading: @escaping () -> Leading, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.detail = detail
        self.note = note
        self.mono = mono
        self.selected = selected
        self.dimmed = dimmed
        self.leading = leading
        self.trailing = trailing
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            leading()
                .frame(width: NWChoiceRowMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(mono ? .nwMono(NWChoiceRowMetrics.titleSize, .medium) : .nw(.ui))
                    .foregroundStyle(dimmed ? nw.textTertiary : nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail).nwText(.caption).foregroundStyle(dimmed ? nw.textTertiary : nw.textSecondary)
                        .lineLimit(2)
                }
                if let note {
                    Text(note).nwText(.caption).foregroundStyle(nw.lanternText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: NW.Space.m)
            trailing()
            if selected {
                Image(systemName: "checkmark")
                    .font(.nw(.ui, weight: .semibold))
                    .foregroundStyle(nw.running)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity, minHeight: NWChoiceRowMetrics.minHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension NWChoiceRow where Trailing == EmptyView {
    public init(_ title: String, detail: String? = nil, note: String? = nil, mono: Bool = true, selected: Bool = false, dimmed: Bool = false,
                @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title, detail: detail, note: note, mono: mono, selected: selected, dimmed: dimmed, leading: leading, trailing: { EmptyView() })
    }
}

#Preview("Choice rows") {
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWGroupCard {
                NWChoiceRow("shepherd", detail: "~/code/shepherd", selected: true) {
                    Image(systemName: "book.closed").foregroundStyle(Color.nw.textSecondary)
                }
                NWChoiceRow("orders-svc", detail: "on build-01") {
                    Image(systemName: "book.closed").foregroundStyle(Color.nw.textSecondary)
                }
            }
            NWGroupCard {
                NWChoiceRow("Studio", detail: "connected · 2 threads running", selected: true) {
                    NWStatusDot(.done, size: NWChoiceRowMetrics.statusDot)
                }
                NWChoiceRow("build-01", detail: "connected", note: "Update Shepherd on build-01 to send images.") {
                    NWStatusDot(.done, size: NWChoiceRowMetrics.statusDot)
                }
                NWChoiceRow("horizon", detail: "unreachable", dimmed: true) {
                    NWStatusDot(.failed, size: NWChoiceRowMetrics.statusDot)
                } trailing: {
                    Button("Retry") {}.buttonStyle(.nwLink)
                }
            }
        }
        .frame(width: 360)
    }
}
