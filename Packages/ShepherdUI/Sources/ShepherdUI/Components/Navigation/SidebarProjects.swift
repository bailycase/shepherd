import SwiftUI

// The sidebar organized by project (Sidebar — Projects: SidebarTree, SidebarProjects,
// SidebarProjectsHosts): a folder row per project with its threads under it, the Projects header
// with its +, and the Organize by picker Settings ▸ Appearance shows.

/// How the sidebar lists threads under the destinations (Settings ▸ Appearance ▸ Organize by).
public enum SHSidebarStyle: String, CaseIterable, Identifiable, Sendable {
    /// Needs you, then Recents: every kind, newest first. The default.
    case activity
    /// A folder for each project with its threads inside.
    case projects

    public var id: Self { self }

    public var title: String {
        switch self {
        case .activity: "Activity"
        case .projects: "Spaces"
        }
    }

    /// What the style lists, as the picker's cards say it.
    public var summary: String {
        switch self {
        case .activity: "Needs you, then Recents: every kind, newest first."
        case .projects: "A folder for each space with its threads inside."
        }
    }
}

/// The project tree's own measures (SidebarTree › Tree rows). Row heights follow `SHDensity`.
public enum SHProjectMetrics {
    /// The chevron's slot, and the chevron in it.
    public static let chevronSlot: CGFloat = 14
    public static let chevron: CGFloat = 9
    /// The folder glyph.
    public static let folder: CGFloat = 14
    /// The gap between a space row's chevron slot, folder slot, name and count (ProjectLead-AddsSpace: 8pt).
    public static let gap: CGFloat = 8
    /// The Spaces and Projects headers (ProjectLead-AddsSpace): 34pt tall, the title `ui` 12.5/500 `textTertiary` at the
    /// bottom with 2pt under it, 8pt in from the left and 2pt from the right, and a 24pt `+` with a 10pt glyph.
    public static let headerHeight: CGFloat = 34
    public static let headerBottom: CGFloat = 2
    public static let headerLeading: CGFloat = 8
    public static let headerTrailing: CGFloat = 2
    /// Between this mode's rows and headers (`--space-xxs`).
    public static let listSpacing: CGFloat = 2
    /// A project row sits 2pt further out than a thread row.
    public static let outdent: CGFloat = 2
    /// The + and ··· circles a hovered project row shows, 2pt apart, and their glyphs.
    public static let action: CGFloat = 20
    public static let actionGap: CGFloat = 2
    public static let actionGlyph: CGFloat = 11
    /// The rolled-up dot's gap to the count.
    public static let rollupGap: CGFloat = 5
    /// The Projects header's + circle and its glyph.
    public static let addButton: CGFloat = 24
    public static let addGlyph: CGFloat = 10
    /// The board's `+` button is 24pt (x 197...221) but its glyph is drawn at x 201...211, left of the box's center (ProjectLead-Started).
    public static let addGlyphShift: CGFloat = -3.75
    /// A project being dragged, in place while the line marks where it lands.
    public static let draggedOpacity: Double = 0.55
}

extension SHDensity {
    /// A project row's leading padding: 2pt outside a thread row's.
    public var projectRowLeading: CGFloat { sidebarRowPadding - SHProjectMetrics.outdent }
    /// A thread row inside a project: its dot sits under the project's folder.
    public var treeChildLeading: CGFloat { projectRowLeading + SHProjectMetrics.chevronSlot + SHProjectMetrics.gap }
}

// MARK: Project row

/// What a collapsed project says about the threads inside it: something waits on you, something
/// runs, or neither.
public enum SHProjectRollup: Equatable, Sendable {
    case quiet
    case running
    case waiting
}

/// A project in the tree (SidebarTree, `SHProjectRow`): a chevron (right while collapsed, down
/// while open), a folder, the name in the row font at medium, and the count in mono 10.5
/// `textTertiary`. Collapsed, the count rolls up what is inside: a glowing lantern dot and the
/// count in `lanternText` while something waits on you, a running dot while something runs.
/// Hovered, the count gives way to + (a thread in this project) and ··· (the project menu), 20pt
/// circles, built only while hovered (a long name gives them its tail while they show). The
/// density's height, radius 8, `bgHover` under the pointer. A tap toggles; interaction beyond the
/// row (⌥-click, drag, the context menu) is the caller's. Compared without its actions.
public struct SHProjectRow<MenuContent: View>: View, Equatable {
    public typealias Rollup = SHProjectRollup

    let name: String
    let count: Int
    let expanded: Bool
    let rollup: Rollup
    let dimmed: Bool
    let missing: Bool
    let pinned: Bool
    let hovered: Bool
    let toggle: () -> Void
    let newThread: (() -> Void)?
    let menu: () -> MenuContent
    @Environment(\.shDensity) private var density
    @State private var pointer = false

    /// `newThread` nil leaves the + out (a host that can't take one); `dimmed` is a project on
    /// a host that is not connected. `hovered` draws it hovered whatever the pointer does (the
    /// board's hover sample). `missing` is a space whose folder is gone: a `failed` cross in place
    /// of the folder and "missing" in place of the count. `pinned` draws the outline pin after the name.
    public init(_ name: String, count: Int, expanded: Bool, rollup: Rollup = .quiet, dimmed: Bool = false, missing: Bool = false,
                pinned: Bool = false,
                hovered: Bool = false,
                toggle: @escaping () -> Void, newThread: (() -> Void)?, @ViewBuilder menu: @escaping () -> MenuContent) {
        self.name = name
        self.count = count
        self.expanded = expanded
        self.rollup = rollup
        self.dimmed = dimmed
        self.missing = missing
        self.pinned = pinned
        self.hovered = hovered
        self.toggle = toggle
        self.newThread = newThread
        self.menu = menu
    }

    public nonisolated static func == (a: SHProjectRow, b: SHProjectRow) -> Bool {
        a.name == b.name && a.count == b.count && a.expanded == b.expanded && a.rollup == b.rollup && a.dimmed == b.dimmed
            && a.missing == b.missing && a.pinned == b.pinned && a.hovered == b.hovered && (a.newThread == nil) == (b.newThread == nil)
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("sidebar.project")
        let sh = Color.sh
        let hovering = pointer || hovered
        HStack(spacing: SHProjectMetrics.gap) {
            Image(systemName: "chevron.right")
                .font(.system(size: SHProjectMetrics.chevron, weight: .semibold))
                .foregroundStyle(sh.textTertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .shAnimation(.disclosure, value: expanded)
                .frame(width: SHProjectMetrics.chevronSlot)
            (missing ? SHGlyph.failedStep.image : Image(systemName: "folder"))
                .font(.system(size: SHProjectMetrics.folder, weight: .regular))
                .foregroundStyle(missing ? sh.failed : sh.textSecondary)
                .frame(width: SHSidebarMetrics.rowSlot)
            Text(name)
                .font(density.rowTitleFont(weight: .medium))
                .foregroundStyle(missing ? sh.textTertiary : sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            if pinned {
                SHGlyph.pin.image
                    .font(.system(size: SHProjectMetrics.chevron, weight: .medium))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: SH.Space.xs)
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
        .shRowBackground(selected: false, hovering: hovering, radius: SH.Radius.m)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        .onTapGesture(perform: toggle)
        .onHover { pointer = $0 }
        .shAnimation(.hover, value: hovering)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(expanded ? "expanded" : "collapsed")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
        .accessibilityAction(named: "New thread in \(name)") { newThread?() }
    }

    private var accessibilityLabel: String {
        var parts = [name, count == 1 ? "1 thread" : "\(count) threads"]
        if missing { parts.append("folder missing") }
        if pinned { parts.append("pinned") }
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
        HStack(spacing: SHProjectMetrics.rollupGap) {
            if missing {
                Text("missing").font(.shMono(10)).foregroundStyle(Color.sh.failed).lineLimit(1).fixedSize()
            }
            // The boards draw a Space row as its count alone (ProjectLead-AddsSpace): the rollup is said to VoiceOver in the row's
            // label ("needs you", "running") but draws no dot.
            if count > 0 {
                Text("\(count)")
                    .font(.shMono(10.5))
                    .foregroundStyle(Color.sh.textTertiary)
                    .monospacedDigit()
                    .shContentTransition(.numeric())
            }
        }
        .shAnimation(.content, value: count)
        .shAnimation(.content, value: rollup)
    }

    /// + and ···, built only while hovered.
    private var actions: some View {
        HStack(spacing: SHProjectMetrics.actionGap) {
            if let newThread {
                Button(action: newThread) {
                    Image(systemName: "plus").font(.system(size: SHProjectMetrics.actionGlyph, weight: .medium))
                }
                .buttonStyle(.shIcon(size: SHProjectMetrics.action))
                .shHelp("New thread in \(name)")
                .accessibilityLabel("New thread in \(name)")
            }
            Menu(content: menu) {
                Image(systemName: "ellipsis").font(.system(size: SHProjectMetrics.actionGlyph, weight: .medium))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.shIcon(size: SHProjectMetrics.action))
            .fixedSize()
            .accessibilityLabel("More for \(name)")
        }
    }
}

// MARK: Projects header

/// A tree section's header (SidebarTree): its title in Geist 11.5 medium `textTertiary`, spaced like
/// Needs you and Recents. Two kinds:
///
/// - **Projects** (ProjectLead-AddsSpace): an 18pt `+` circle that opens New project.
/// - **Spaces**: the folder tree's header. The board draws no `+` here, so a Space header shows an
///   18pt `+` menu only while a Space is hidden from the sidebar (bring it back); otherwise it is the title alone.
///   Adding a Space stays in Settings ▸ Spaces and the existing menus.
public struct SHProjectsHeader<MenuContent: View>: View, Equatable {
    let title: String
    let menu: (() -> MenuContent)?
    let add: (() -> Void)?
    let hasMenu: Bool
    @Environment(\.shDensity) private var density

    /// A header whose `+` opens `menu` (the Spaces header's hidden-space list).
    public init(_ title: String = "Spaces", hasMenu: Bool = true, @ViewBuilder menu: @escaping () -> MenuContent) {
        self.title = title
        self.menu = menu
        self.add = nil
        self.hasMenu = hasMenu
    }

    public nonisolated static func == (a: SHProjectsHeader, b: SHProjectsHeader) -> Bool {
        a.title == b.title && a.hasMenu == b.hasMenu && (a.add == nil) == (b.add == nil)
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: SH.Space.s) {
            Text(title)
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textTertiary)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, SHProjectMetrics.headerBottom)
            Spacer(minLength: SH.Space.xs)
            if let add {
                Button(action: add) {
                    Image(systemName: "plus").font(.system(size: SHProjectMetrics.addGlyph, weight: .medium))
                        .offset(x: SHProjectMetrics.addGlyphShift)
                }
                .buttonStyle(.shIcon(size: SHProjectMetrics.addButton, tint: .sh.textSecondary))
                .shHelp("New project")
                .accessibilityLabel("New project")
            } else if let menu, hasMenu {
                Menu(content: menu) {
                    Image(systemName: "plus").font(.system(size: SHProjectMetrics.addGlyph, weight: .medium))
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.shIcon(size: SHProjectMetrics.addButton, tint: .sh.textSecondary))
                .fixedSize()
                .shHelp("Hidden spaces")
                .accessibilityLabel("Hidden spaces")
            }
        }
        .padding(EdgeInsets(top: 0, leading: SHProjectMetrics.headerLeading, bottom: SHProjectMetrics.headerBottom,
                            trailing: SHProjectMetrics.headerTrailing))
        .frame(maxWidth: .infinity, minHeight: SHProjectMetrics.headerHeight, alignment: .bottomLeading)
    }
}

extension SHProjectsHeader where MenuContent == EmptyView {
    /// The Projects header: a `+` that runs `add`.
    public init(_ title: String, add: @escaping () -> Void) {
        self.title = title
        self.menu = nil
        self.add = add
        self.hasMenu = false
    }
}

// MARK: Organize by

/// Settings ▸ Appearance ▸ Sidebar ▸ Organize by (SettingsAppearance, `SHSidebarStylePicker`):
/// Activity and Projects as two cards side by side, each a small drawing of the sidebar it makes
/// over a radio, its name and what it lists. The chosen card's ring is 1.5pt `lantern`, the other
/// 1pt `lineSubtle`, on `bgSunken` at radius 10. Represented to accessibility as a native radio
/// group.
public struct SHSidebarStylePicker: View {
    @Binding var selection: SHSidebarStyle

    public init(selection: Binding<SHSidebarStyle>) {
        _selection = selection
    }

    public var body: some View {
        HStack(alignment: .top, spacing: SH.Space.l) {
            ForEach(SHSidebarStyle.allCases) { style in
                card(style)
            }
        }
        .accessibilityRepresentation {
            Picker("Organize by", selection: $selection) {
                ForEach(SHSidebarStyle.allCases) { Text($0.title).tag($0) }
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            #else
            .pickerStyle(.inline)
            #endif
        }
    }

    private func card(_ style: SHSidebarStyle) -> some View {
        let sh = Color.sh
        let chosen = style == selection
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        return Button { selection = style } label: {
            VStack(alignment: .leading, spacing: 10) {
                SHSidebarStyleThumbnail(style: style)
                HStack(alignment: .top, spacing: SH.Space.m) {
                    SHRadioMark(selected: chosen).padding(.top, 1)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(style.title)
                            .font(.shSans(13, .semibold))
                            .foregroundStyle(sh.textPrimary)
                        Text(style.summary)
                            .font(.shSans(12))
                            .foregroundStyle(sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, SH.Space.xs)
            }
            .padding(EdgeInsets(top: SH.Space.m, leading: SH.Space.m, bottom: 10, trailing: SH.Space.m))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(sh.bgSunken, in: shape)
            .overlay { shape.strokeBorder(chosen ? sh.lantern : sh.lineSubtle, lineWidth: chosen ? 1.5 : 1) }
            .contentShape(shape)
            .shComponentAnimation(.content, value: chosen)
        }
        .buttonStyle(SHPlainPressStyle())
    }
}

/// A card's drawing: a small sidebar beside a page's lines. Activity draws Needs you's two amber
/// rows over Recents; Projects draws a folder open on three threads, then two more folders. The
/// sidebar's rows shrink together to fit the drawing's height, as the board's column does.
struct SHSidebarStyleThumbnail: View {
    let style: SHSidebarStyle

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
        let room = M.height - 2 * SH.Space.m - CGFloat(items - 1) * M.rowGap
        return min(1, room / content)
    }

    var body: some View {
        let sh = Color.sh
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: M.rowGap) {
                ForEach([34, 28, 40] as [CGFloat], id: \.self) { width in
                    row { RoundedRectangle(cornerRadius: 1.5).strokeBorder(sh.textTertiary, lineWidth: 1) } bar: { bar(width, sh.lineStrong) }
                }
                Color.clear.frame(height: M.destinationsGap * fit)
                switch style {
                case .activity: activity
                case .projects: projects
                }
            }
            .padding(.vertical, SH.Space.m)
            .padding(.horizontal, SH.Space.xs)
            .frame(width: M.sidebarWidth, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(sh.bgBase)
            .overlay(alignment: .trailing) { Rectangle().fill(sh.lineSubtle).frame(width: 1) }
            VStack(alignment: .leading, spacing: SH.Space.s) {
                ForEach([120, 150, 96] as [CGFloat], id: \.self) { bar($0, sh.lineSubtle) }
                Color.clear.frame(height: SH.Space.s)
                ForEach([140, 110] as [CGFloat], id: \.self) { bar($0, sh.lineSubtle) }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, SH.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .frame(height: M.height)
        .background(sh.bgWindow)
        .clipShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .overlay { RoundedRectangle(cornerRadius: SH.Radius.s).strokeBorder(sh.lineSubtle, lineWidth: 1) }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var activity: some View {
        let sh = Color.sh
        header(26, sh.lantern)
        row { Circle().fill(sh.lantern) } bar: { bar(52, sh.lineStrong) }
        row { Circle().fill(sh.lantern) } bar: { bar(40, sh.lineStrong) }
        header(22, sh.lineStrong)
        row(selected: true) { Circle().fill(sh.running) } bar: { bar(56, sh.textSecondary) }
        row { Circle().strokeBorder(sh.textTertiary, lineWidth: 1) } bar: { bar(44, sh.lineStrong) }
        row { Circle().fill(sh.running) } bar: { bar(50, sh.lineStrong) }
        row { Circle().strokeBorder(sh.textTertiary, lineWidth: 1) } bar: { bar(36, sh.lineStrong) }
    }

    @ViewBuilder private var projects: some View {
        let sh = Color.sh
        header(24, sh.lineStrong)
        folder(open: true, 34)
        row(inset: M.childInset) { Circle().fill(sh.lantern) } bar: { bar(44, sh.lineStrong) }
        row(inset: M.childInset, selected: true) { Circle().fill(sh.running) } bar: { bar(52, sh.textSecondary) }
        row(inset: M.childInset) { Circle().strokeBorder(sh.textTertiary, lineWidth: 1) } bar: { bar(38, sh.lineStrong) }
        folder(open: false, 42)
        folder(open: false, 30)
    }

    private func folder(open: Bool, _ width: CGFloat) -> some View {
        let sh = Color.sh
        return HStack(spacing: M.glyph) {
            Image(systemName: "chevron.right")
                .font(.system(size: 5, weight: .bold))
                .foregroundStyle(sh.textTertiary)
                .rotationEffect(.degrees(open ? 90 : 0))
                .frame(width: M.glyph)
            RoundedRectangle(cornerRadius: 1.5).strokeBorder(sh.textSecondary, lineWidth: 1).frame(width: 8, height: 6)
            bar(width, sh.textTertiary)
        }
        .padding(.horizontal, M.rowInset)
        .frame(height: M.row * fit)
    }

    private func header(_ width: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: M.header)
            .padding(EdgeInsets(top: 0, leading: M.rowInset, bottom: SH.Space.xxs, trailing: M.rowInset))
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
        .background(selected ? Color.sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: 3))
    }
}
