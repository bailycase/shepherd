import SwiftUI

// The new Projects feature's sidebar parts (ProjectLead-Activity, ProjectLead-AddsSpace). A Project
// is not a folder: its glyph is the board's stacked outline, never `folder`.

extension NWSidebarMetrics {
    /// The Project glyph's box: the boards draw it in the 14pt row slot (the supplied icon is 14pt).
    public static let projectGlyphBox: CGFloat = 14
    /// The Project toolbar's name: Geist 13 semibold, as the thread toolbar's title.
    public static let projectToolbarTitle: CGFloat = 13
}

/// A Project in the sidebar, Activity mode (ProjectLead-Activity): the supplied Project glyph in the 14pt slot
/// (`lanternText` while selected, else `textTertiary`), the name (semibold while selected) in the density's row
/// font, and a mono 10 summary (`lanternText` when it needs you). 28pt, radius 8, 8pt in from the sides, 9pt gaps;
/// the same box as every Activity row. The summary and its tone come only from a real lifecycle.
public struct NWLeadProjectRow: View, Equatable {
    let name: String
    let selected: Bool
    let summary: String?
    let needsYou: Bool
    @Environment(\.nwDensity) private var density
    @State private var hovering = false

    public init(_ name: String, selected: Bool, summary: String? = nil, needsYou: Bool = false) {
        self.name = name
        self.selected = selected
        self.summary = summary
        self.needsYou = needsYou
    }

    public nonisolated static func == (a: NWLeadProjectRow, b: NWLeadProjectRow) -> Bool {
        a.name == b.name && a.selected == b.selected && a.summary == b.summary && a.needsYou == b.needsYou
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("sidebar.leadProject")
        HStack(spacing: density.sidebarRowGap) {
            NWProjectGlyphView(tint: selected ? .nw.lanternText : .nw.textTertiary)
                .frame(width: NWSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            if let summary {
                Text(summary)
                    .font(.nwMono(NWSidebarMetrics.accessoryFont))
                    .foregroundStyle(needsYou ? Color.nw.lanternText : Color.nw.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: selected, hovering: hovering, radius: NW.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, "project", summary].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A Project in the Spaces-mode sidebar (ProjectLead-AddsSpace, -Paused): the same glyph and name, then a mono
/// 10.5 count of its threads (`textTertiary`; semibold while selected) or, when something waits on it, a 6pt
/// lantern dot before the count. 6pt in from the left (not 8), 8pt from the right, 8pt gaps: the board's
/// `ls-row` box, which differs from an Activity row's.
public struct NWLeadSpaceProjectRow: View, Equatable {
    let name: String
    let selected: Bool
    let count: Int
    let needsYou: Bool

    public init(_ name: String, selected: Bool, count: Int, needsYou: Bool = false) {
        self.name = name
        self.selected = selected
        self.count = count
        self.needsYou = needsYou
    }

    public nonisolated static func == (a: NWLeadSpaceProjectRow, b: NWLeadSpaceProjectRow) -> Bool {
        a.name == b.name && a.selected == b.selected && a.count == b.count && a.needsYou == b.needsYou
    }

    @Environment(\.nwDensity) private var density
    @State private var hovering = false

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            NWProjectGlyphView(tint: selected ? .nw.lanternText : .nw.textTertiary)
                .frame(width: NWSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            if needsYou {
                Circle().fill(Color.nw.lantern).frame(width: NWSidebarMetrics.sectionPulse + 1, height: NWSidebarMetrics.sectionPulse + 1)
                    .accessibilityHidden(true)
            }
            Text("\(count)")
                .font(.nwMono(NWSidebarMetrics.sectionCountFont, selected ? .semibold : .regular))
                .foregroundStyle(Color.nw.textTertiary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.leading, NW.Space.s)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: selected, hovering: hovering, radius: NW.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, "project", count == 1 ? "1 thread" : "\(count) threads", needsYou ? "needs you" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The text chip beside a section header ("New project", like "Mark all seen"): a 20pt `bgHover` pill.
public struct NWSidebarHeaderChip: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.nwSans(NWSidebarMetrics.sectionActionFont))
                .foregroundStyle(.nw.textSecondary)
                .fixedSize()
                .padding(.horizontal, NW.Space.s)
                .frame(height: NWSidebarMetrics.markSeenHeight)
                .background(Color.nw.bgHover, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                .frame(minHeight: NW.Height.controlS)
                .contentShape(Rectangle())
        }
        .buttonStyle(NWPlainPressStyle())
        .accessibilityLabel(title)
    }
}

/// A Project's toolbar (ProjectLead-EmptyV2): the Project glyph in `lantern` and the name, then the
/// trailing controls (Overview, settings). The 44pt toolbar height and its hairline are the app's.
public struct NWLeadToolbar<Trailing: View>: View {
    let name: String
    let leadingInset: CGFloat
    let sidebar: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    public init(_ name: String, leadingInset: CGFloat = 0, sidebar: (() -> Void)? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.name = name
        self.leadingInset = leadingInset
        self.sidebar = sidebar
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.nwIcon)
                    .nwHelp("Show sidebar")
                    .accessibilityLabel("Show sidebar")
            }
            // The glyph's 14pt box, then the title 6pt on (the boards: glyph x 244, title x 264, in a page that begins at 232).
            HStack(spacing: NWLeadMetrics.toolbarTitleGap) {
                NWProjectGlyphView(tint: .nw.lantern)
                Text(name)
                    .font(.nwSans(NWSidebarMetrics.projectToolbarTitle, .semibold))
                    .foregroundStyle(.nw.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: NW.Space.l)
            HStack(spacing: NW.Space.xs) { trailing() }.fixedSize()
        }
        .padding(.leading, (sidebar == nil ? NWLeadMetrics.toolbarLeading : NWToolbarMetrics.leadingPadding) + leadingInset)
        .padding(.trailing, NWToolbarMetrics.trailingPadding)
        .frame(height: NWToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .bottom) { NWHairline() }
    }
}

/// The toolbar's Overview button: the list glyph and the word, on `bgHover` while it is the page shown.
public struct NWLeadToolbarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let dot: Bool
    let badge: Int
    let action: () -> Void

    /// `dot`: a 6pt lantern dot after the title (something needs you, Overview). `badge`: a count in a 16pt `running` pill (the
    /// Threads tab).
    public init(_ title: String, symbol: String, selected: Bool, dot: Bool = false, badge: Int = 0, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.selected = selected
        self.dot = dot
        self.badge = badge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: NW.Space.s) {
                Image(systemName: symbol).font(.system(size: NWLeadMetrics.toolbarGlyph, weight: .regular))
                Text(title).font(.nw(.ui, weight: .regular))
                if dot {
                    Circle().fill(Color.nw.lantern).frame(width: NWLeadMetrics.toolbarDot, height: NWLeadMetrics.toolbarDot)
                        .accessibilityHidden(true)
                }
                if badge > 0 {
                    Text("\(badge)")
                        .font(.nwSans(NWLeadMetrics.badgeSize, .semibold))
                        .foregroundStyle(Color.nw.textOnRunning)
                        .frame(minWidth: NWLeadMetrics.badge, minHeight: NWLeadMetrics.badge)
                        .background(Color.nw.running, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
                }
            }
            .foregroundStyle(selected ? Color.nw.textPrimary : Color.nw.textSecondary)
            .padding(.horizontal, NW.Space.m)
            .frame(height: NWLeadMetrics.toolbarButtonHeight)
            .background(selected ? Color.nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(NWPlainPressStyle())
        .accessibilityLabel(dot ? "\(title), needs you" : badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A task thread under its Project in the Spaces mode (ProjectLead-Paused, -Question): a 6pt dot (`lantern` while it waits on
/// you, else `running`) in a 14pt slot 26pt in from the left, the title, and a mono 10.5 word ("answer") in `lanternText`.
public struct NWLeadTaskRow: View, Equatable {
    let title: String
    let attention: Bool
    let word: String?
    @Environment(\.nwDensity) private var density
    @State private var hovering = false

    public init(title: String, attention: Bool, word: String? = nil) {
        self.title = title
        self.attention = attention
        self.word = word
    }

    public nonisolated static func == (a: NWLeadTaskRow, b: NWLeadTaskRow) -> Bool {
        a.title == b.title && a.attention == b.attention && a.word == b.word
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Circle().fill(attention ? Color.nw.lantern : Color.nw.running)
                .frame(width: NWLeadMetrics.taskDot, height: NWLeadMetrics.taskDot)
                .frame(width: NWSidebarMetrics.rowSlot)
                .accessibilityHidden(true)
            Text(title)
                .font(density.rowTitleFont(weight: .regular))
                .foregroundStyle(.nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            if let word {
                Text(word).font(.nwMono(NWSidebarMetrics.sectionCountFont)).foregroundStyle(Color.nw.lanternText).fixedSize()
            }
        }
        .padding(.leading, NWLeadMetrics.sidebarTaskLeading)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: false, hovering: hovering, radius: NW.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
    }
}
