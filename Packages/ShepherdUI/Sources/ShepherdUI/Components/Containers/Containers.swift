import SwiftUI

/// A section label ("THIS MAC  19"): micro mono caps in tertiary, with an optional trailing
/// count or accessory.
public struct NWSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Text(title).nwSectionLabel().lineLimit(1)
            Spacer(minLength: NW.Space.xs)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension NWSectionHeader where Trailing == Text? {
    public init(_ title: String, count: Int? = nil) {
        self.init(title) {
            count.map { Text("\($0)").font(.nw(.micro)).foregroundStyle(.nw.textTertiary) }
        }
    }
}

/// A grouped card (settings groups, lists of rows): `.nwCard()` with a 1px `lineSubtle` rule
/// between its children. Pass rows; the rules are inserted.
public struct NWGroupCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { NWHairline() }
                    subview
                }
            }
        }
        .nwCard()
    }
}

/// A card row (settings): title, optional description and inline problem (in `failed`), and a
/// trailing control. At least 52pt, scaled by density.
public struct NWCardRow<Control: View>: View {
    let title: String
    let description: String?
    let problem: String?
    @ViewBuilder let control: () -> Control

    public init(_ title: String, description: String? = nil, problem: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.description = description
        self.problem = problem
        self.control = control
    }

    public var body: some View {
        let nw = Color.nw
        HStack(alignment: .center, spacing: NW.Space.xl) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.nw(.ui)).foregroundStyle(nw.textPrimary)
                if let description {
                    Text(description).nwText(.caption).foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Text(problem).nwText(.caption).foregroundStyle(nw.failed)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.l)
        .frame(minHeight: NW.Height.scaled(52))
    }
}
