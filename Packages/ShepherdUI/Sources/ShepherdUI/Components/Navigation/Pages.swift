import SwiftUI

// The sidebar destinations' shared frame (NavAutomations, NavHosts, and the other destination
// boards): the page header with its filter and primary button, a table's columns and head, a
// bordered card, a labeled section, and a fact row. Plain values in; what a button does is the
// caller's.

/// The destination pages' own measures.
public enum NWPageMetrics {
    /// The page header (the thread toolbar is 44).
    public static let headerHeight: CGFloat = 52
    public static let headerLeading: CGFloat = NW.Space.xxl
    public static let headerTrailing: CGFloat = NW.Space.xl
    /// Between the header's items.
    public static let headerSpacing: CGFloat = NW.Space.l
    /// The header's filter field.
    public static let filterWidth: CGFloat = 220
    public static let filterPadding: CGFloat = 10
    public static let filterGlyph: CGFloat = 12
    /// A page's side inset (the header's leading edge, a table's rows, a card grid).
    public static let sideInset: CGFloat = NW.Space.xxl
    /// Above and below a page body of cards.
    public static let bodyVertical: CGFloat = 20
    /// Between a table's columns, and between cards.
    public static let columnGap: CGFloat = NW.Space.xl
    /// Above and below a table row's content.
    public static let rowVertical: CGFloat = NW.Space.l
    /// Under the table's column labels.
    public static let headBottom: CGFloat = NW.Space.m
    /// A card's corners (the boards' 10, between `NW.Radius.m` and `.l`).
    public static let cardRadius: CGFloat = 10
    /// A fact row's shortest height (a host card's).
    public static let factMinHeight: CGFloat = 26
    /// Between a host card's fact label and its value.
    public static let factGap: CGFloat = 10
    /// A quoted block's padding above and below (a prompt); 12 at the sides.
    public static let quoteVertical: CGFloat = 10
    /// The extra leading that sets a quoted block at the boards' 1.55 line height.
    public static let quoteLineSpacing: CGFloat = 4
    /// A dot beside a status or outcome.
    public static let dot: CGFloat = 6
    /// Between a table row's switch and its name.
    public static let switchGap: CGFloat = 10
}

/// A destination page's header: the title, an optional subtitle ("3 hosts · 1 offline"), then
/// the trailing controls (a filter, the page's one primary button), on the window's background
/// with a hairline beneath. As the thread toolbar (`NWThreadToolbar`): a sidebar button leads
/// while the sidebar is not docked, and `leadingInset` clears the window controls.
public struct NWPageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    let sidebarLabel: String
    let trailing: Trailing

    public init(_ title: String, subtitle: String? = nil, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil,
                sidebarLabel: String = "Show sidebar", @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.sidebarLabel = sidebarLabel
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: NWPageMetrics.headerSpacing) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.nwIcon)
                    .nwHelp(sidebarLabel)
                    .accessibilityLabel(sidebarLabel)
            }
            Text(title)
                .font(.nw(.title))
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.nw(.ui, weight: .regular))
                    .foregroundStyle(Color.nw.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: NW.Space.m)
            trailing
        }
        .padding(.leading, NWPageMetrics.headerLeading + leadingInset)
        .padding(.trailing, NWPageMetrics.headerTrailing)
        .frame(height: NWPageMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

extension NWPageHeader where Trailing == EmptyView {
    public init(_ title: String, subtitle: String? = nil, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil) {
        self.init(title, subtitle: subtitle, leadingInset: leadingInset, sidebar: sidebar) { EmptyView() }
    }
}

/// The header's filter ("Filter automations"): a borderline field with no fill, a glass, and a
/// clear button once there is text. Lighter than `NWSearchField`, as the boards draw it.
public struct NWPageFilterField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    public init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.nwSans(NWPageMetrics.filterGlyph - 1, .medium))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(nw.textTertiary))
                .textFieldStyle(.plain)
                .font(.nwSans(12))
                .foregroundStyle(nw.textPrimary)
                .tint(nw.lantern)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark")
                        .font(.nwSans(9, .semibold))
                        .foregroundStyle(nw.textTertiary)
                        .frame(width: NW.Space.xl, height: NW.Space.xl)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, NWPageMetrics.filterPadding)
        .frame(width: NWPageMetrics.filterWidth, height: NW.Height.controlM)
        .nwBorder(nw.lineSubtle, radius: NW.Radius.s)
        .overlay {
            Color.clear
                .nwFocusRing(focused, radius: NW.Radius.s)
                .nwComponentAnimation(.hover, value: focused)
                .allowsHitTesting(false)
        }
    }
}

/// A table's column widths: fixed points, or a share of what the fixed ones leave (the boards'
/// `2fr 76px 76px 1.15fr`). Lays its children out one per column, vertically centered; a
/// child past the last column gets no width.
public struct NWTableColumns: Layout {
    public enum Column: Equatable, Sendable {
        case fixed(CGFloat)
        case flex(CGFloat)
    }

    let columns: [Column]
    let spacing: CGFloat

    public init(_ columns: [Column], spacing: CGFloat = NWPageMetrics.columnGap) {
        self.columns = columns
        self.spacing = spacing
    }

    /// Each column's width in `total` points.
    public static func widths(_ columns: [Column], spacing: CGFloat, total: CGFloat) -> [CGFloat] {
        guard !columns.isEmpty else { return [] }
        let gaps = spacing * CGFloat(columns.count - 1)
        var fixed: CGFloat = 0, shares: CGFloat = 0
        for column in columns {
            switch column {
            case .fixed(let width): fixed += width
            case .flex(let share): shares += share
            }
        }
        let free = max(0, total - gaps - fixed)
        return columns.map { column in
            switch column {
            case .fixed(let width): width
            case .flex(let share): shares > 0 ? free * share / shares : 0
            }
        }
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? Self.widths(columns, spacing: spacing, total: 0).reduce(0, +)
            + spacing * CGFloat(max(0, columns.count - 1))
        let widths = Self.widths(columns, spacing: spacing, total: total)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: total, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(columns, spacing: spacing, total: bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            guard index < widths.count else {
                subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .leading, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }
}

/// A table's column labels in mono caps ("AUTOMATION", "HOST"), on its columns.
public struct NWTableHead: View {
    let labels: [String]
    let columns: [NWTableColumns.Column]

    public init(_ labels: [String], columns: [NWTableColumns.Column]) {
        self.labels = labels
        self.columns = columns
    }

    public var body: some View {
        NWTableColumns(columns) {
            ForEach(Array(labels.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .nwSectionLabel()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, NWPageMetrics.sideInset)
        .padding(.bottom, NWPageMetrics.headBottom)
        .accessibilityHidden(true)
    }
}

extension View {
    /// A destination page's card: a 1pt `lineSubtle` border at the boards' 10pt radius, clipped.
    public func nwPageCard() -> some View {
        clipShape(RoundedRectangle(cornerRadius: NWPageMetrics.cardRadius))
            .nwBorder(Color.nw.lineSubtle, radius: NWPageMetrics.cardRadius)
    }
}

/// A labeled fact: a fixed label column in `textSecondary`, then the value (mono for a host, a
/// path, a model). A host card's rows are at least 26pt tall with mono 11.5 values; a detail
/// pane's are tight, with values at the label's size.
public struct NWPageFact: View, Equatable {
    public enum Style: Sendable { case card, detail }

    let label: String
    let value: String
    let mono: Bool
    let labelWidth: CGFloat
    let style: Style

    public init(_ label: String, value: String, mono: Bool = true, labelWidth: CGFloat, style: Style = .card) {
        self.label = label
        self.value = value
        self.mono = mono
        self.labelWidth = labelWidth
        self.style = style
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: style == .card ? NWPageMetrics.factGap : 0) {
            Text(label)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(valueFont)
                .foregroundStyle(Color.nw.textPrimary)
                .lineLimit(style == .card ? 1 : 3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: style == .card ? NWPageMetrics.factMinHeight : nil)
        .accessibilityElement(children: .combine)
    }

    private var valueFont: Font {
        switch style {
        case .card: mono ? .nw(.mono) : .nw(.ui, weight: .regular)
        case .detail: mono ? .nwMono(NWTextStyle.ui.size) : .nw(.ui, weight: .regular)
        }
    }
}

/// A detail pane's section label in mono caps ("PROMPT", "RECENT RUNS").
public struct NWPageSectionLabel: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .nwSectionLabel()
            .accessibilityAddTraits(.isHeader)
    }
}

/// A block of text set apart on `bgSunken` with a `lineSubtle` border (an automation's prompt).
public struct NWPageQuote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nw(.ui, weight: .regular))
            .lineSpacing(NWPageMetrics.quoteLineSpacing)
            .foregroundStyle(Color.nw.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, NWPageMetrics.quoteVertical)
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nwCard(radius: NW.Radius.m, fill: Color.nw.bgSunken, line: Color.nw.lineSubtle)
    }
}
