import SwiftUI

// The Changes pane's menus (ChangesStates › Menus: ScopeMenu, CommitsMenu, BasePicker,
// DiffOptions): popovers at radius 12 with 6pt padding, 30pt rows (40pt with a subtitle) at
// radius 6, a 13pt glyph, the title in 12.5, a subtitle in 11 tertiary, and a trailing diff stat,
// count, tag or switch. Hovering a row fills it; the row whose submenu is open keeps the
// selected fill.

public enum NWChangesMenuMetrics {
    public static let scopeWidth: CGFloat = 320
    public static let commitsWidth: CGFloat = 360
    public static let baseWidth: CGFloat = 316
    public static let optionsWidth: CGFloat = 300
    public static let rowHeight: CGFloat = 30
    public static let tallRowHeight: CGFloat = 40
    public static let titleHeight: CGFloat = 24
    public static let searchHeight: CGFloat = 32
    public static let glyphWidth: CGFloat = 13
}

/// A menu's surface: its width, 6pt in, the popover's fill, line and shadow.
public struct NWChangesMenu<Content: View>: View {
    let width: CGFloat
    let content: Content

    public init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(NW.Space.s)
            .frame(width: width)
            .nwPopover()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

/// A section title: mono 10, uppercase, tracked, tertiary ("Diff", "On agent/refund-events").
public struct NWChangesMenuTitle: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        Text(title)
            .font(.nwMono(10, .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, NW.Space.m)
            .frame(maxWidth: .infinity, minHeight: NWChangesMenuMetrics.titleHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The line between a menu's groups.
public struct NWChangesMenuDivider: View {
    public init() {}

    public var body: some View {
        NWHairline().padding(.vertical, NW.Space.xs).padding(.horizontal, NW.Space.xxs)
    }
}

/// A quiet line at a menu's foot ("Pick two with ⇧ to see the range between them.").
public struct NWChangesMenuNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.nwSans(11))
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NW.Space.m)
            .padding(.vertical, NW.Space.s)
    }
}

/// What trails a menu row.
public enum NWChangesMenuTrailing: Equatable, Sendable {
    case none
    case stat(added: Int, removed: Int)
    /// Mono 11 tertiary: "4", "#31 draft", "a1c9f2e · 12m", "worktree", "origin/main".
    case text(String)
}

/// One row of a Changes menu.
public struct NWChangesMenuRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let titleIsMono: Bool
    let trailing: NWChangesMenuTrailing
    let checked: Bool
    let hasSubmenu: Bool
    let highlighted: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    /// `systemImage` nil leaves the glyph's slot empty (Unstaged and Staged sit under
    /// Uncommitted); `highlighted` keeps the fill (the row whose submenu is open).
    public init(_ title: String, subtitle: String? = nil, systemImage: String?, titleIsMono: Bool = false,
                trailing: NWChangesMenuTrailing = .none, checked: Bool = false, hasSubmenu: Bool = false,
                highlighted: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.titleIsMono = titleIsMono
        self.trailing = trailing
        self.checked = checked
        self.hasSubmenu = hasSubmenu
        self.highlighted = highlighted
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 9) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: NWChangesMenuMetrics.glyphWidth, height: NWChangesMenuMetrics.glyphWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(titleIsMono ? .nw(.code) : .nw(.ui, weight: .regular))
                    .foregroundStyle(enabled ? nw.textPrimary : nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.nwSans(11)).foregroundStyle(nw.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: NW.Space.m) {
                switch trailing {
                case .none: EmptyView()
                case .stat(let added, let removed): NWDiffStat(added: added, removed: removed, font: .nwMono(11))
                case .text(let text): Text(text).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                }
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(nw.textPrimary)
                }
                if hasSubmenu {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(nw.textTertiary)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, NW.Space.m)
        .frame(minHeight: subtitle == nil ? NWChangesMenuMetrics.rowHeight : NWChangesMenuMetrics.tallRowHeight)
        .background(fill(nw), in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .onHover { hovering = $0 && enabled }
        .onTapGesture { if enabled { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if enabled { action() } }
    }

    private func fill(_ nw: NWPalette) -> Color {
        highlighted ? nw.bgSelected : hovering ? nw.bgHover : .clear
    }
}

/// A switch row (DiffOptions): the glyph, the title (and subtitle), and a switch. Toggles, not
/// one-way actions: the menu stays open.
public struct NWChangesMenuToggle: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    @Binding var isOn: Bool
    @State private var hovering = false

    public init(_ title: String, subtitle: String? = nil, systemImage: String, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        _isOn = isOn
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textSecondary)
                .frame(width: NWChangesMenuMetrics.glyphWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.nwSans(11)).foregroundStyle(nw.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.nwSwitch)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .padding(.horizontal, NW.Space.m)
        .frame(minHeight: subtitle == nil ? NWChangesMenuMetrics.rowHeight : NWChangesMenuMetrics.tallRowHeight)
        .background(hovering ? nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: NW.Radius.s))
        .onHover { hovering = $0 }
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { isOn.toggle() }
    }
}

/// The base picker's search (BasePicker): a 32pt field at radius 6 with a magnifier.
public struct NWChangesMenuSearch: View {
    @Binding var text: String
    let prompt: String
    var isFocused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onEscape: () -> Void

    public init(text: Binding<String>, prompt: String, isFocused: FocusState<Bool>.Binding,
                onSubmit: @escaping () -> Void, onEscape: @escaping () -> Void) {
        _text = text
        self.prompt = prompt
        self.isFocused = isFocused
        self.onSubmit = onSubmit
        self.onEscape = onEscape
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(nw.textTertiary))
                .textFieldStyle(.plain)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textPrimary)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) { onEscape(); return .handled }
        }
        .padding(.horizontal, 10)
        .frame(height: NWChangesMenuMetrics.searchHeight)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
        .nwBorder(nw.lineStrong, radius: NW.Radius.s)
        .padding(.bottom, NW.Space.xs)
        .onAppear { isFocused.wrappedValue = true }
    }
}
