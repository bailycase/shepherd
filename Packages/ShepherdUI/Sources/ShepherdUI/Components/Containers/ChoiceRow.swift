import SwiftUI

/// A choice row's measures (the Where it runs board): a 15pt mono name over a 12pt detail, at
/// least 56pt tall, with a 20pt leading column for the icon or status dot.
public enum SHChoiceRowMetrics {
    public static let titleSize: CGFloat = 15
    public static let minHeight: CGFloat = 56
    public static let leadingWidth: CGFloat = 20
    public static let statusDot: CGFloat = 8
}

/// One option in a picker list (a repo, a host): a leading icon or status dot, the name over a
/// detail line and an optional note, and a checkmark when chosen. `trailing` takes an inline
/// action instead (Retry). Draw it as a button's label, inside an `SHGroupCard`.
public struct SHChoiceRow<Leading: View, Trailing: View>: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            leading()
                .frame(width: SHChoiceRowMetrics.leadingWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(mono ? .shMono(SHChoiceRowMetrics.titleSize, .medium) : .sh(.ui))
                    .foregroundStyle(dimmed ? sh.textTertiary : sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail {
                    Text(detail).shText(.caption).foregroundStyle(dimmed ? sh.textTertiary : sh.textSecondary)
                        .lineLimit(2)
                }
                if let note {
                    Text(note).shText(.caption).foregroundStyle(sh.lanternText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SH.Space.m)
            trailing()
            if selected {
                Image(systemName: "checkmark")
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(sh.running)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SHChoiceRowMetrics.minHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension SHChoiceRow where Trailing == EmptyView {
    public init(_ title: String, detail: String? = nil, note: String? = nil, mono: Bool = true, selected: Bool = false, dimmed: Bool = false,
                @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title, detail: detail, note: note, mono: mono, selected: selected, dimmed: dimmed, leading: leading, trailing: { EmptyView() })
    }
}

#Preview("Choice rows") {
    SHPreviewBoth {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            SHGroupCard {
                SHChoiceRow("shepherd", detail: "~/code/shepherd", selected: true) {
                    Image(systemName: "book.closed").foregroundStyle(Color.sh.textSecondary)
                }
                SHChoiceRow("orders-svc", detail: "on build-01") {
                    Image(systemName: "book.closed").foregroundStyle(Color.sh.textSecondary)
                }
            }
            SHGroupCard {
                SHChoiceRow("Studio", detail: "connected · 2 threads running", selected: true) {
                    SHStatusDot(.done, size: SHChoiceRowMetrics.statusDot)
                }
                SHChoiceRow("build-01", detail: "connected", note: "Update Shepherd on build-01 to send images.") {
                    SHStatusDot(.done, size: SHChoiceRowMetrics.statusDot)
                }
                SHChoiceRow("horizon", detail: "unreachable", dimmed: true) {
                    SHStatusDot(.failed, size: SHChoiceRowMetrics.statusDot)
                } trailing: {
                    Button("Retry") {}.buttonStyle(.shLink)
                }
            }
        }
        .frame(width: 360)
    }
}
