import SwiftUI

// The Changes pane's menus (ChangesStates › Menus: ScopeMenu, CommitsMenu, BasePicker,
// DiffOptions): popovers at radius 12 with 6pt padding, 30pt rows (40pt with a subtitle) at
// radius 6, a 13pt glyph, the title in 12.5, a subtitle in 11 tertiary, and a trailing diff stat,
// count, tag or switch. Hovering a row fills it; the row whose submenu is open keeps the
// selected fill.

public enum SHChangesMenuMetrics {
    #if os(macOS)
    /// The Mac's menus (the boards' `.gch-pop`): 340, 320, 300 and 300 wide; a row with a subtitle takes its 7 above and below.
    public static let scopeWidth: CGFloat = 340
    public static let commitsWidth: CGFloat = 320
    public static let baseWidth: CGFloat = 300
    public static let optionsWidth: CGFloat = 300
    public static let rowHeight: CGFloat = 30
    public static let tallRowHeight: CGFloat = 30
    public static let titleHeight: CGFloat = 26
    public static let searchHeight: CGFloat = 38
    public static let glyphWidth: CGFloat = 16
    public static let rowGap: CGFloat = 10
    public static let glyphSize: CGFloat = 12
    public static let markWidth: CGFloat = 14
    public static let twoLinePadding: CGFloat = 7
    #else
    public static let scopeWidth: CGFloat = 320
    public static let commitsWidth: CGFloat = 360
    public static let baseWidth: CGFloat = 316
    public static let optionsWidth: CGFloat = 300
    public static let rowHeight: CGFloat = 30
    public static let tallRowHeight: CGFloat = 40
    public static let titleHeight: CGFloat = 24
    public static let searchHeight: CGFloat = 32
    public static let glyphWidth: CGFloat = 13
    #endif
}

/// A menu's surface: its width, 6pt in, the popover's fill, line and shadow.
public struct SHChangesMenu<Content: View>: View {
    let width: CGFloat
    let content: Content

    public init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(SH.Space.s)
            .frame(width: width)
            .shPopover()
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

/// A section title: mono 10, uppercase, tracked, tertiary ("Diff", "On agent/refund-events").
public struct SHChangesMenuTitle: View {
    let title: String

    public init(_ title: String) { self.title = title }

    public var body: some View {
        #if os(macOS)
        // The boards' `.mh`: 26pt, `caption` in `textTertiary`, as written.
        Text(title)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHChangesMenuMetrics.titleHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        #else
        Text(title)
            .font(.shMono(10, .medium))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, SH.Space.m)
            .frame(maxWidth: .infinity, minHeight: SHChangesMenuMetrics.titleHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
        #endif
    }
}

/// The line between a menu's groups.
public struct SHChangesMenuDivider: View {
    public init() {}

    public var body: some View {
        SHHairline().padding(.vertical, SH.Space.xs).padding(.horizontal, SH.Space.xxs)
    }
}

/// A quiet line at a menu's foot ("Pick two with ⇧ to see the range between them.").
public struct SHChangesMenuNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    #if os(macOS)
    @MainActor static var font: Font { .sh(.caption) }
    static let vertical: CGFloat = SH.Space.xs
    #else
    @MainActor static var font: Font { .shSans(11) }
    static let vertical: CGFloat = SH.Space.s
    #endif

    public var body: some View {
        Text(text)
            .font(SHChangesMenuNote.font)
            .foregroundStyle(Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SH.Space.m)
            .padding(.vertical, SHChangesMenuNote.vertical)
    }
}

/// What trails a menu row.
public enum SHChangesMenuTrailing: Equatable, Sendable {
    case none
    case stat(added: Int, removed: Int)
    /// Mono 11 tertiary: "4", "#31 draft", "a1c9f2e · 12m", "worktree", "origin/main".
    case text(String)
    /// A chord as keycaps ("⌘D"; NewTerminalMenu).
    case chord(String)
}

/// One row of a Changes menu.
public struct SHChangesMenuRow: View {
    let title: String
    let subtitle: String?
    let systemImage: String?
    let titleIsMono: Bool
    let trailing: SHChangesMenuTrailing
    let checked: Bool
    let hasSubmenu: Bool
    let highlighted: Bool
    let enabled: Bool
    let tallHeight: CGFloat
    let action: () -> Void
    @State private var hovering = false

    /// `systemImage` nil leaves the glyph's slot empty (Unstaged and Staged sit under
    /// Uncommitted); `highlighted` keeps the fill (the row whose submenu is open). `tallHeight` is a
    /// row with a subtitle's least height (the terminal's menu draws 36).
    public init(_ title: String, subtitle: String? = nil, systemImage: String?, titleIsMono: Bool = false,
                trailing: SHChangesMenuTrailing = .none, checked: Bool = false, hasSubmenu: Bool = false,
                highlighted: Bool = false, enabled: Bool = true, tallHeight: CGFloat = SHChangesMenuMetrics.tallRowHeight,
                action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.titleIsMono = titleIsMono
        self.trailing = trailing
        self.checked = checked
        self.hasSubmenu = hasSubmenu
        self.highlighted = highlighted
        self.enabled = enabled
        self.tallHeight = tallHeight
        self.action = action
    }

    public var body: some View {
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if os(macOS)
    /// The boards' `.gch-mi`: the glyph in a 16pt slot, the title in 13 (the subtitle under it in 12), then a stat, a quiet word, and a
    /// 14pt column that holds the check or the submenu's chevron.
    @ViewBuilder private var macBody: some View {
        let _ = SHRenderProbe.tick("changes.menu.row")
        let sh = Color.sh
        let M = SHChangesMenuMetrics.self
        HStack(alignment: subtitle == nil ? .center : .top, spacing: M.rowGap) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: M.glyphSize)).foregroundStyle(sh.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: M.glyphWidth)
            .padding(.top, subtitle == nil ? 0 : SH.Space.xxs)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui))
                    .foregroundStyle(enabled ? sh.textPrimary : sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SH.Space.m) {
                switch trailing {
                case .none: EmptyView()
                case .stat(let added, let removed): SHDiffStat(added: added, removed: removed, font: .sh(.caption, weight: .regular), hidesZero: true)
                case .text(let text): Text(text).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                case .chord(let chord): SHKeycap(chord)
                }
            }
            .fixedSize()
            Group {
                if hasSubmenu {
                    Image(systemName: "chevron.right").font(.system(size: M.glyphSize - 3, weight: .semibold)).foregroundStyle(sh.textSecondary)
                } else if checked {
                    Image(systemName: "checkmark").font(.system(size: M.glyphSize, weight: .medium)).foregroundStyle(sh.textPrimary)
                } else {
                    Color.clear
                }
            }
            .frame(width: M.markWidth)
        }
        .padding(.horizontal, SH.Space.m)
        .padding(.vertical, subtitle == nil ? 0 : M.twoLinePadding)
        .frame(minHeight: M.rowHeight)
        .background(fill(sh), in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { hovering = $0 && enabled }
        .onTapGesture { if enabled { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if enabled { action() } }
    }
    #endif

    @ViewBuilder private var touchBody: some View {
        let _ = SHRenderProbe.tick("changes.menu.row")
        let sh = Color.sh
        HStack(spacing: 9) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textSecondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: SHChangesMenuMetrics.glyphWidth, height: SHChangesMenuMetrics.glyphWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(titleIsMono ? .sh(.code) : .sh(.ui, weight: .regular))
                    .foregroundStyle(enabled ? sh.textPrimary : sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.shSans(11)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: SH.Space.m) {
                switch trailing {
                case .none: EmptyView()
                case .stat(let added, let removed): SHDiffStat(added: added, removed: removed, font: .shMono(11))
                case .text(let text): Text(text).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).lineLimit(1)
                case .chord(let chord): SHKeycap(chord)
                }
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(sh.textPrimary)
                }
                if hasSubmenu {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(sh.textTertiary)
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, SH.Space.m)
        .frame(minHeight: subtitle == nil ? SHChangesMenuMetrics.rowHeight : tallHeight)
        .background(fill(sh), in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { hovering = $0 && enabled }
        .onTapGesture { if enabled { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(checked ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if enabled { action() } }
    }

    private func fill(_ sh: SHPalette) -> Color {
        #if os(macOS)
        highlighted || hovering ? sh.bgSelected : .clear
        #else
        highlighted ? sh.bgSelected : hovering ? sh.bgHover : .clear
        #endif
    }
}

/// A switch row (DiffOptions): the glyph, the title (and subtitle), and a switch. Toggles, not
/// one-way actions: the menu stays open.
public struct SHChangesMenuToggle: View {
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
        #if os(macOS)
        // The boards' options are check rows (`.gch-mk`), not switches.
        SHChangesMenuRow(title, subtitle: subtitle, systemImage: systemImage, checked: isOn) { isOn.toggle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(isOn ? "on" : "off")
            .accessibilityAddTraits(.isToggle)
            .accessibilityAction { isOn.toggle() }
        #else
        touchBody
        #endif
    }

    @ViewBuilder private var touchBody: some View {
        let sh = Color.sh
        HStack(spacing: 9) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textSecondary)
                .frame(width: SHChangesMenuMetrics.glyphWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.shSans(11)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .padding(.horizontal, SH.Space.m)
        .frame(minHeight: subtitle == nil ? SHChangesMenuMetrics.rowHeight : SHChangesMenuMetrics.tallRowHeight)
        .background(hovering ? sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
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
public struct SHChangesMenuSearch: View {
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
        #if os(macOS)
        macBody
        #else
        touchBody
        #endif
    }

    #if os(macOS)
    /// The boards' `.srch`: 38pt across the whole menu with a line under it; the words in 13.
    @ViewBuilder private var macBody: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: SHChangesMenuMetrics.glyphSize + 1, weight: .medium)).foregroundStyle(sh.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) { onEscape(); return .handled }
        }
        .padding(.horizontal, SH.Space.xl - SH.Space.xxs)
        .frame(height: SHChangesMenuMetrics.searchHeight)
        .overlay(alignment: .bottom) { SHHairline() }
        .padding(.top, -SH.Space.s)
        .padding(.horizontal, -SH.Space.s)
        .padding(.bottom, SH.Space.s)
        .onAppear { isFocused.wrappedValue = true }
    }
    #endif

    @ViewBuilder private var touchBody: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) { onEscape(); return .handled }
        }
        .padding(.horizontal, 10)
        .frame(height: SHChangesMenuMetrics.searchHeight)
        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .shBorder(sh.lineStrong, radius: SH.Radius.s)
        .padding(.bottom, SH.Space.xs)
        .onAppear { isFocused.wrappedValue = true }
    }
}
