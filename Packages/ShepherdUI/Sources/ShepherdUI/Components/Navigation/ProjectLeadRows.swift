import SwiftUI

// The new Projects feature's sidebar parts (ProjectLead-Activity, ProjectLead-AddsSpace). A Project
// is not a folder: its glyph is the board's stacked outline, never `folder`.

extension SHSidebarMetrics {
    /// The Project glyph's box: the boards draw it in the 14pt row slot (the supplied icon is 14pt).
    public static let projectGlyphBox: CGFloat = 14
    /// The Project toolbar's name: Geist 13 semibold, as the thread toolbar's title.
    public static let projectToolbarTitle: CGFloat = 13
}

/// A Project in the sidebar, Activity mode (ProjectLead-Activity): the supplied Project glyph in the 14pt slot
/// (`lanternText` while selected, else `textTertiary`), the name (semibold while selected) in the density's row
/// font, and a mono 10 summary (`lanternText` when it needs you). 28pt, radius 8, 8pt in from the sides, 9pt gaps;
/// the same box as every Activity row. The summary and its tone come only from a real lifecycle.
public struct SHLeadProjectRow: View, Equatable {
    let name: String
    let selected: Bool
    let summary: String?
    let needsYou: Bool
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    public init(_ name: String, selected: Bool, summary: String? = nil, needsYou: Bool = false) {
        self.name = name
        self.selected = selected
        self.summary = summary
        self.needsYou = needsYou
    }

    public nonisolated static func == (a: SHLeadProjectRow, b: SHLeadProjectRow) -> Bool {
        a.name == b.name && a.selected == b.selected && a.summary == b.summary && a.needsYou == b.needsYou
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.leadProject")
        HStack(spacing: density.sidebarRowGap) {
            SHProjectGlyphView(tint: selected ? .sh.lanternText : .sh.textTertiary)
                .frame(width: SHSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SH.Space.xs)
            if let summary {
                Text(summary)
                    .font(.shMono(SHSidebarMetrics.accessoryFont))
                    .foregroundStyle(needsYou ? Color.sh.lanternText : Color.sh.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, "project", summary].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A Project in the Spaces-mode sidebar (ProjectLead-AddsSpace, -Paused): the same glyph and name, then a mono
/// 10.5 count of its threads (`textTertiary`; semibold while selected) or, when something waits on it, a 6pt
/// lantern dot before the count. 6pt in from the left (not 8), 8pt from the right, 8pt gaps: the board's
/// `ls-row` box, which differs from an Activity row's.
public struct SHLeadSpaceProjectRow: View, Equatable {
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

    public nonisolated static func == (a: SHLeadSpaceProjectRow, b: SHLeadSpaceProjectRow) -> Bool {
        a.name == b.name && a.selected == b.selected && a.count == b.count && a.needsYou == b.needsYou
    }

    @Environment(\.shDensity) private var density
    @State private var hovering = false

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            SHProjectGlyphView(tint: selected ? .sh.lanternText : .sh.textTertiary)
                .frame(width: SHSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: selected ? .semibold : .regular))
                .foregroundStyle(.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SH.Space.xs)
            if needsYou {
                Circle().fill(Color.sh.lantern).frame(width: SHSidebarMetrics.sectionPulse + 1, height: SHSidebarMetrics.sectionPulse + 1)
                    .accessibilityHidden(true)
            }
            Text("\(count)")
                .font(.shMono(SHSidebarMetrics.sectionCountFont, selected ? .semibold : .regular))
                .foregroundStyle(Color.sh.textTertiary)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.leading, SH.Space.s)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .shRowBackground(selected: selected, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([name, "project", count == 1 ? "1 thread" : "\(count) threads", needsYou ? "needs you" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The text chip beside a section header ("New project", like "Mark all seen"): a 20pt `bgHover` pill.
public struct SHSidebarHeaderChip: View {
    let title: String
    let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.shSans(SHSidebarMetrics.sectionActionFont))
                .foregroundStyle(.sh.textSecondary)
                .fixedSize()
                .padding(.horizontal, SH.Space.s)
                .frame(height: SHSidebarMetrics.markSeenHeight)
                .background(Color.sh.bgHover, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                .frame(minHeight: SH.Height.controlS)
                .contentShape(Rectangle())
        }
        .buttonStyle(SHPlainPressStyle())
        .accessibilityLabel(title)
    }
}

/// A Project's toolbar (ProjectLead-EmptyV2): the Project glyph in `lantern` and the name, then the
/// trailing controls (Overview, settings). The 44pt toolbar height and its hairline are the app's.
public struct SHLeadToolbar<Trailing: View>: View {
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
        HStack(spacing: SH.Space.m) {
            if let sidebar {
                Button(action: sidebar) { Image(systemName: "sidebar.left") }
                    .buttonStyle(.shIcon)
                    .shHelp("Show sidebar")
                    .accessibilityLabel("Show sidebar")
            }
            // The glyph's 14pt box, then the title 6pt on (the boards: glyph x 244, title x 264, in a page that begins at 232).
            HStack(spacing: SHLeadMetrics.toolbarTitleGap) {
                SHProjectGlyphView(tint: .sh.lantern)
                Text(name)
                    .font(.shSans(SHSidebarMetrics.projectToolbarTitle, .semibold))
                    .foregroundStyle(.sh.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: SH.Space.l)
            HStack(spacing: SH.Space.xs) { trailing() }.fixedSize()
        }
        .padding(.leading, (sidebar == nil ? SHLeadMetrics.toolbarLeading : SHToolbarMetrics.leadingPadding) + leadingInset)
        .padding(.trailing, SHToolbarMetrics.trailingPadding)
        .frame(height: SHToolbarMetrics.height)
        .frame(maxWidth: .infinity)
        .background(Color.sh.bgWindow)
        .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// The toolbar's Overview button: the list glyph and the word, on `bgHover` while it is the page shown.
public struct SHLeadToolbarButton: View {
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
            HStack(spacing: SH.Space.s) {
                Image(systemName: symbol).font(.system(size: SHLeadMetrics.toolbarGlyph, weight: .regular))
                Text(title).font(.sh(.ui, weight: .regular))
                if dot {
                    Circle().fill(Color.sh.lantern).frame(width: SHLeadMetrics.toolbarDot, height: SHLeadMetrics.toolbarDot)
                        .accessibilityHidden(true)
                }
                if badge > 0 {
                    Text("\(badge)")
                        .font(.shSans(SHLeadMetrics.badgeSize, .semibold))
                        .foregroundStyle(Color.sh.textOnRunning)
                        .frame(minWidth: SHLeadMetrics.badge, minHeight: SHLeadMetrics.badge)
                        .background(Color.sh.running, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
                }
            }
            .foregroundStyle(selected ? Color.sh.textPrimary : Color.sh.textSecondary)
            .padding(.horizontal, SH.Space.m)
            .frame(height: SHLeadMetrics.toolbarButtonHeight)
            .background(selected ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
            .contentShape(Rectangle())
        }
        .buttonStyle(SHPlainPressStyle())
        .accessibilityLabel(dot ? "\(title), needs you" : badge > 0 ? "\(title), \(badge)" : title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A task thread under its Project in the Spaces mode (ProjectLead-Paused, -Question): a 6pt dot (`lantern` while it waits on
/// you, else `running`) in a 14pt slot 26pt in from the left, the title, and a mono 10.5 word ("answer") in `lanternText`.
public struct SHLeadTaskRow: View, Equatable {
    let title: String
    let attention: Bool
    let word: String?
    @Environment(\.shDensity) private var density
    @State private var hovering = false

    public init(title: String, attention: Bool, word: String? = nil) {
        self.title = title
        self.attention = attention
        self.word = word
    }

    public nonisolated static func == (a: SHLeadTaskRow, b: SHLeadTaskRow) -> Bool {
        a.title == b.title && a.attention == b.attention && a.word == b.word
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            Circle().fill(attention ? Color.sh.lantern : Color.sh.running)
                .frame(width: SHLeadMetrics.taskDot, height: SHLeadMetrics.taskDot)
                .frame(width: SHSidebarMetrics.rowSlot)
                .accessibilityHidden(true)
            Text(title)
                .font(density.rowTitleFont(weight: .regular))
                .foregroundStyle(.sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: SH.Space.xs)
            if let word {
                Text(word).font(.shMono(SHSidebarMetrics.sectionCountFont)).foregroundStyle(Color.sh.lanternText).fixedSize()
            }
        }
        .padding(.leading, SHLeadMetrics.sidebarTaskLeading)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .shRowBackground(selected: false, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
    }
}
