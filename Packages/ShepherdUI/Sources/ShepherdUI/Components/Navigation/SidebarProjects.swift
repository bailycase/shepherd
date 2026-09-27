import SwiftUI

// The sidebar organized by project (Sidebar — Projects: SidebarTree, SidebarProjects,
// SidebarProjectsHosts): a folder row per project with its threads under it, the Projects header
// with its +, and the Organize by picker Settings ▸ Appearance shows.

/// How the sidebar lists threads under the destinations (Settings ▸ Appearance ▸ Organize by).
public enum NWSidebarStyle: String, CaseIterable, Identifiable, Sendable {
    /// Needs you, then Recents: every kind, newest first. The default.
    case activity
    /// A folder for each project with its threads inside.
    case projects

    public var id: Self { self }

    public var title: String {
        switch self {
        case .activity: "Activity"
        case .projects: "Projects"
        }
    }

    /// What the style lists, as the picker's cards say it.
    public var summary: String {
        switch self {
        case .activity: "Needs you, then Recents: every kind, newest first."
        case .projects: "A folder for each project with its threads inside."
        }
    }
}

/// The project tree's own measures (SidebarTree › Tree rows). Row heights follow `NWDensity`.
public enum NWProjectMetrics {
    /// The chevron's slot, and the chevron in it.
    public static let chevronSlot: CGFloat = 14
    public static let chevron: CGFloat = 9
    /// The folder glyph.
    public static let folder: CGFloat = 12
    /// The gap between a project row's chevron, folder, name and count.
    public static let gap: CGFloat = 6
    /// A project row sits 2pt further out than a thread row.
    public static let outdent: CGFloat = 2
    /// The + and ··· circles a hovered project row shows, 2pt apart, and their glyphs.
    public static let action: CGFloat = 20
    public static let actionGap: CGFloat = 2
    public static let actionGlyph: CGFloat = 11
    /// The rolled-up dot's gap to the count.
    public static let rollupGap: CGFloat = 5
    /// The Projects header's + circle and its glyph.
    public static let addButton: CGFloat = 18
    public static let addGlyph: CGFloat = 9
    /// A project being dragged, in place while the line marks where it lands.
    public static let draggedOpacity: Double = 0.55
}

extension NWDensity {
    /// A project row's leading padding: 2pt outside a thread row's.
    public var projectRowLeading: CGFloat { sidebarRowPadding - NWProjectMetrics.outdent }
    /// A thread row inside a project: its dot sits under the project's folder.
    public var treeChildLeading: CGFloat { projectRowLeading + NWProjectMetrics.chevronSlot + NWProjectMetrics.gap }
}

// MARK: Project row

/// What a collapsed project says about the threads inside it: something waits on you, something
/// runs, or neither.
public enum NWProjectRollup: Equatable, Sendable {
    case quiet
    case running
    case waiting
}

/// A project in the tree (SidebarTree, `NWProjectRow`): a chevron (right while collapsed, down
/// while open), a folder, the name in the row font at medium, and the count in mono 10.5
/// `textTertiary`. Collapsed, the count rolls up what is inside: a glowing lantern dot and the
/// count in `lanternText` while something waits on you, a running dot while something runs.
/// Hovered, the count gives way to + (a thread in this project) and ··· (the project menu), 20pt
/// circles, built only while hovered (a long name gives them its tail while they show). The
/// density's height, radius 8, `bgHover` under the pointer. A tap toggles; interaction beyond the
/// row (⌥-click, drag, the context menu) is the caller's. Compared without its actions.
public struct NWProjectRow<MenuContent: View>: View, Equatable {
    public typealias Rollup = NWProjectRollup

    let name: String
    let count: Int
    let expanded: Bool
    let rollup: Rollup
    let dimmed: Bool
    let hovered: Bool
    let toggle: () -> Void
    let newThread: (() -> Void)?
    let menu: () -> MenuContent
    @Environment(\.nwDensity) private var density
    @State private var pointer = false

    /// `newThread` nil leaves the + out (a host that can't take one); `dimmed` is a project on
    /// a host that is not connected. `hovered` draws it hovered whatever the pointer does (the
    /// board's hover sample).
    public init(_ name: String, count: Int, expanded: Bool, rollup: Rollup = .quiet, dimmed: Bool = false, hovered: Bool = false,
                toggle: @escaping () -> Void, newThread: (() -> Void)?, @ViewBuilder menu: @escaping () -> MenuContent) {
        self.name = name
        self.count = count
        self.expanded = expanded
        self.rollup = rollup
        self.dimmed = dimmed
        self.hovered = hovered
        self.toggle = toggle
        self.newThread = newThread
        self.menu = menu
    }

    public nonisolated static func == (a: NWProjectRow, b: NWProjectRow) -> Bool {
        a.name == b.name && a.count == b.count && a.expanded == b.expanded && a.rollup == b.rollup && a.dimmed == b.dimmed
            && a.hovered == b.hovered && (a.newThread == nil) == (b.newThread == nil)
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("sidebar.project")
        let nw = Color.nw
        let hovering = pointer || hovered
        HStack(spacing: NWProjectMetrics.gap) {
            Image(systemName: "chevron.right")
                .font(.system(size: NWProjectMetrics.chevron, weight: .semibold))
                .foregroundStyle(nw.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .nwAnimation(.disclosure, value: expanded)
                .frame(width: NWProjectMetrics.chevronSlot)
            Image(systemName: "folder")
                .font(.system(size: NWProjectMetrics.folder, weight: .regular))
                .foregroundStyle(nw.textSecondary)
            Text(name)
                .font(density.rowTitleFont(weight: .medium))
                .foregroundStyle(nw.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: NW.Space.xs)
            ZStack(alignment: .trailing) {
                if hovering, !dimmed {
                    actions
                } else {
                    summary
                }
            }
        }
        .padding(.leading, density.projectRowLeading)
        .padding(.trailing, density.sidebarRowPadding)
        .frame(maxWidth: .infinity, minHeight: density.rowHeight, alignment: .leading)
        .nwRowBackground(selected: false, hovering: hovering, radius: NW.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .onTapGesture(perform: toggle)
        .onHover { pointer = $0 }
        .nwAnimation(.hover, value: hovering)
        .opacity(dimmed ? NWListMetrics.dimmedOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: "New thread in \(name)") { newThread?() }
    }

    private var accessibilityLabel: String {
        var parts = [name, count == 1 ? "1 thread" : "\(count) threads"]
        if !expanded {
            switch rollup {
            case .waiting: parts.append("needs you")
            case .running: parts.append("running")
            case .quiet: break
            }
        }
        return parts.joined(separator: ", ")
    }

    /// The count, rolled up while collapsed.
    @ViewBuilder private var summary: some View {
        let waiting = !expanded && rollup == .waiting
        HStack(spacing: NWProjectMetrics.rollupGap) {
            if !expanded, rollup != .quiet {
                NWSidebarDot(state: waiting ? .attention : .running)
            }
            if count > 0 {
                Text("\(count)")
                    .font(.nwMono(10.5))
                    .foregroundStyle(waiting ? Color.nw.lanternText : Color.nw.textTertiary)
                    .monospacedDigit()
                    .nwContentTransition(.numeric())
            }
        }
        .nwAnimation(.content, value: count)
        .nwAnimation(.content, value: rollup)
    }

    /// + and ···, built only while hovered.
    private var actions: some View {
        HStack(spacing: NWProjectMetrics.actionGap) {
            if let newThread {
                Button(action: newThread) {
                    Image(systemName: "plus").font(.system(size: NWProjectMetrics.actionGlyph, weight: .medium))
                }
                .buttonStyle(.nwIcon(size: NWProjectMetrics.action))
                .nwHelp("New thread in \(name)")
                .accessibilityLabel("New thread in \(name)")
            }
            Menu(content: menu) {
                Image(systemName: "ellipsis").font(.system(size: NWProjectMetrics.actionGlyph, weight: .medium))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.nwIcon(size: NWProjectMetrics.action))
            .fixedSize()
            .accessibilityLabel("More for \(name)")
        }
    }
}

// MARK: Projects header

/// The tree's header (SidebarTree): "Projects" in Geist 11.5 medium `textTertiary`, spaced like
/// Needs you and Recents, with an 18pt + circle trailing that opens `menu` (add a project, and
/// bring back one hidden from the sidebar).
public struct NWProjectsHeader<MenuContent: View>: View, Equatable {
    let title: String
    let menu: () -> MenuContent
    @Environment(\.nwDensity) private var density

    public init(_ title: String = "Projects", @ViewBuilder menu: @escaping () -> MenuContent) {
        self.title = title
        self.menu = menu
    }

    public nonisolated static func == (a: NWProjectsHeader, b: NWProjectsHeader) -> Bool { a.title == b.title }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            Text(title)
                .font(.nwSans(11.5, .medium))
                .foregroundStyle(Color.nw.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.xs)
            Menu(content: menu) {
                Image(systemName: "plus").font(.system(size: NWProjectMetrics.addGlyph, weight: .semibold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.nwIcon(size: NWProjectMetrics.addButton, tint: .nw.textTertiary))
            .fixedSize()
            .nwHelp("Add project")
            .accessibilityLabel("Add project")
        }
        .padding(EdgeInsets(top: density.sidebarHeaderTop, leading: density.sidebarRowPadding, bottom: NW.Space.xs,
                            trailing: density.sidebarRowPadding))
    }
}

// MARK: Organize by

/// Settings ▸ Appearance ▸ Sidebar ▸ Organize by (SettingsAppearance, `NWSidebarStylePicker`):
/// Activity and Projects as two cards side by side, each a small drawing of the sidebar it makes
/// over a radio, its name and what it lists. The chosen card's ring is 1.5pt `lantern`, the other
/// 1pt `lineSubtle`, on `bgSunken` at radius 10. Represented to accessibility as a native radio
/// group.
public struct NWSidebarStylePicker: View {
    @Binding var selection: NWSidebarStyle

    public init(selection: Binding<NWSidebarStyle>) {
        _selection = selection
    }

    public var body: some View {
        HStack(alignment: .top, spacing: NW.Space.l) {
            ForEach(NWSidebarStyle.allCases) { style in
                card(style)
            }
        }
        .accessibilityRepresentation {
            Picker("Organize by", selection: $selection) {
                ForEach(NWSidebarStyle.allCases) { Text($0.title).tag($0) }
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
        }
    }

    private func card(_ style: NWSidebarStyle) -> some View {
        let nw = Color.nw
        let chosen = style == selection
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        return Button { selection = style } label: {
            VStack(alignment: .leading, spacing: 10) {
                NWSidebarStyleThumbnail(style: style)
                HStack(alignment: .top, spacing: NW.Space.m) {
                    NWRadioMark(selected: chosen).padding(.top, 1)
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(style.title)
                            .font(.nwSans(13, .semibold))
                            .foregroundStyle(nw.textPrimary)
                        Text(style.summary)
                            .font(.nwSans(12))
                            .foregroundStyle(nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, NW.Space.xs)
            }
            .padding(EdgeInsets(top: NW.Space.m, leading: NW.Space.m, bottom: 10, trailing: NW.Space.m))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(nw.bgSunken, in: shape)
            .overlay { shape.strokeBorder(chosen ? nw.lantern : nw.lineSubtle, lineWidth: chosen ? 1.5 : 1) }
            .contentShape(shape)
            .nwComponentAnimation(.content, value: chosen)
        }
        .buttonStyle(NWPlainPressStyle())
    }
}

/// A card's drawing: a small sidebar beside a page's lines. Activity draws Needs you's two amber
/// rows over Recents; Projects draws a folder open on three threads, then two more folders. The
/// sidebar's rows shrink together to fit the drawing's height, as the board's column does.
struct NWSidebarStyleThumbnail: View {
    let style: NWSidebarStyle

    private enum M {
        static let height: CGFloat = 104
        static let sidebarWidth: CGFloat = 118
        static let row: CGFloat = 11
        static let rowGap: CGFloat = 2
        static let rowInset: CGFloat = 5
        static let childInset: CGFloat = 17
        static let glyph: CGFloat = 5
        static let bar: CGFloat = 4
        static let header: CGFloat = 3
        /// A header's box, the bar at its foot, and the gap under the destinations, before fitting.
        static let headerBox: CGFloat = 10
        static let destinationsGap: CGFloat = 3
        static let destinations = 3
    }

    /// How much the sidebar's rows, headers and gap shrink so every one of them fits.
    var fit: CGFloat {
        let (headers, rows) = switch style {
        case .activity: (2, 6)
        case .projects: (1, 6)
        }
        let items = M.destinations + 1 + headers + rows
        let content = CGFloat(M.destinations + rows) * M.row + M.destinationsGap + CGFloat(headers) * M.headerBox
        let room = M.height - 2 * NW.Space.m - CGFloat(items - 1) * M.rowGap
        return min(1, room / content)
    }

    var body: some View {
        let nw = Color.nw
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: M.rowGap) {
                ForEach([34, 28, 40] as [CGFloat], id: \.self) { width in
                    row { RoundedRectangle(cornerRadius: 1.5).strokeBorder(nw.textTertiary, lineWidth: 1) } bar: { bar(width, nw.lineStrong) }
                }
                Color.clear.frame(height: M.destinationsGap * fit)
                switch style {
                case .activity: activity
                case .projects: projects
                }
            }
            .padding(.vertical, NW.Space.m)
            .padding(.horizontal, NW.Space.xs)
            .frame(width: M.sidebarWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(nw.bgBase)
            .overlay(alignment: .trailing) { Rectangle().fill(nw.lineSubtle).frame(width: 1) }
            VStack(alignment: .leading, spacing: NW.Space.s) {
                ForEach([120, 150, 96] as [CGFloat], id: \.self) { bar($0, nw.lineSubtle) }
                Color.clear.frame(height: NW.Space.s)
                ForEach([140, 110] as [CGFloat], id: \.self) { bar($0, nw.lineSubtle) }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, NW.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(height: M.height)
        .background(nw.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.s).strokeBorder(nw.lineSubtle, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var activity: some View {
        let nw = Color.nw
        header(26, nw.lantern)
        row { Circle().fill(nw.lantern) } bar: { bar(52, nw.lineStrong) }
        row { Circle().fill(nw.lantern) } bar: { bar(40, nw.lineStrong) }
        header(22, nw.lineStrong)
        row(selected: true) { Circle().fill(nw.running) } bar: { bar(56, nw.textSecondary) }
        row { Circle().strokeBorder(nw.textTertiary, lineWidth: 1) } bar: { bar(44, nw.lineStrong) }
        row { Circle().fill(nw.running) } bar: { bar(50, nw.lineStrong) }
        row { Circle().strokeBorder(nw.textTertiary, lineWidth: 1) } bar: { bar(36, nw.lineStrong) }
    }

    @ViewBuilder private var projects: some View {
        let nw = Color.nw
        header(24, nw.lineStrong)
        folder(open: true, 34)
        row(inset: M.childInset) { Circle().fill(nw.lantern) } bar: { bar(44, nw.lineStrong) }
        row(inset: M.childInset, selected: true) { Circle().fill(nw.running) } bar: { bar(52, nw.textSecondary) }
        row(inset: M.childInset) { Circle().strokeBorder(nw.textTertiary, lineWidth: 1) } bar: { bar(38, nw.lineStrong) }
        folder(open: false, 42)
        folder(open: false, 30)
    }

    private func folder(open: Bool, _ width: CGFloat) -> some View {
        let nw = Color.nw
        return HStack(spacing: M.glyph) {
            Image(systemName: "chevron.right")
                .font(.system(size: 5, weight: .bold))
                .foregroundStyle(nw.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: M.glyph)
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(nw.textSecondary, lineWidth: 1).frame(width: 8, height: 6)
            bar(width, nw.textTertiary)
        }
        .padding(.horizontal, M.rowInset)
        .frame(height: M.row * fit)
    }

    private func header(_ width: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: M.header)
            .padding(EdgeInsets(top: 0, leading: M.rowInset, bottom: NW.Space.xxs, trailing: M.rowInset))
            .frame(height: M.headerBox * fit, alignment: .bottom)
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: M.bar)
    }

    private func row<Glyph: View, Bar: View>(inset: CGFloat = M.rowInset, selected: Bool = false, @ViewBuilder glyph: () -> Glyph,
                                             @ViewBuilder bar: () -> Bar) -> some View {
        HStack(spacing: M.glyph) {
            glyph().frame(width: M.glyph, height: M.glyph)
            bar()
        }
        .padding(.leading, inset)
        .padding(.trailing, M.rowInset)
        .frame(maxWidth: .infinity, minHeight: M.row * fit, maxHeight: M.row * fit, alignment: .leading)
        .background(selected ? Color.nw.bgSelected : .clear, in: RoundedRectangle(cornerRadius: 3))
    }
}
