#if os(macOS)
import SwiftUI

// The Mac's drawn menus (GXBranchPicker, GXRemote boards' `.pop`): a raised surface at radius 12 with 6pt
// inside, 30pt rows at radius 7 that fill with the selected tone under the pointer, a 26pt header in
// `caption`, and a hairline between groups. Names a branch in mono, a Mac or a thread in sans.

public enum SHPopMenuMetrics {
    /// The surface's padding; a search row runs flush to its edges, so it takes this back.
    public static let padding: CGFloat = SH.Space.s
    public static let rowHeight: CGFloat = 30
    public static let rowSpacing: CGFloat = 10
    public static let rowInset: CGFloat = SH.Space.m
    public static let headerHeight: CGFloat = 26
    public static let searchHeight: CGFloat = 38
    public static let searchInset: CGFloat = 14
    /// The check's column, and a glyph's.
    public static let checkWidth: CGFloat = 14
    public static let glyphWidth: CGFloat = 16
    public static let glyphSize: CGFloat = 12
    public static let chevronSize: CGFloat = 9
    /// A nested row's disclosure chevron and its box, and the indent per level.
    public static let disclosureSize: CGFloat = 10
    public static let disclosureWidth: CGFloat = 10
    public static let disclosureIndent: CGFloat = 14
    /// A branch name trailing a row, in mono.
    public static let trailingCodeSize: CGFloat = 11
    /// The caption under a switch's title.
    public static let toggleCaptionGap: CGFloat = 1
    /// A branch's name in mono.
    public static let codeSize: CGFloat = 12.5
    public static let separatorInset = EdgeInsets(top: 5, leading: SH.Space.m, bottom: 5, trailing: SH.Space.m)
    /// The line under a list's foot (a note about what the rows can't do).
    public static let noteInset = EdgeInsets(top: SH.Space.xs, leading: SH.Space.m, bottom: SH.Space.xs, trailing: SH.Space.m)
}

/// The surface: `width` wide, its rows 6pt in, the popover's fill, line and shadow.
public struct SHPopMenu<Content: View>: View {
    let width: CGFloat
    let content: Content

    public init(width: CGFloat, @ViewBuilder content: () -> Content) {
        self.width = width
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(SHPopMenuMetrics.padding)
            .frame(width: width)
            .shPopover(radius: SH.Radius.l)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
    }
}

/// A line over the rows ("Running on mini"): `caption`, `textTertiary`.
public struct SHPopMenuHeader: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, SHPopMenuMetrics.rowInset)
            .frame(maxWidth: .infinity, minHeight: SHPopMenuMetrics.headerHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The hairline between groups.
public struct SHPopMenuSeparator: View {
    public init() {}

    public var body: some View {
        SHHairline().padding(SHPopMenuMetrics.separatorInset)
    }
}

/// A quiet line under the rows (why a branch can't be chosen, what a search found).
public struct SHPopMenuNote: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.sh(.caption))
            .foregroundStyle(Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(SHPopMenuMetrics.noteInset)
    }
}

/// What leads a row.
public enum SHPopMenuLead: Equatable, Sendable {
    /// Nothing, and no column.
    case none
    /// A 14pt column holding a check when `true` (a branch list: the one in use).
    case check(Bool)
    /// A 16pt column holding a symbol ("plus", "arrow.clockwise").
    case glyph(String)
}

/// How a row's trailing text reads.
public enum SHPopMenuTrailingStyle: Equatable, Sendable {
    /// A quiet word ("HEAD", "Has room"); cut at its end.
    case word
    /// A path ("~/Developer/payments"); cut at its start, where the name is.
    case path
    /// A branch in mono; cut in the middle.
    case code
}

/// A nested row: its depth, and whether it folds others under it (a chevron, turned while open). Rows
/// of a list that nests all take one, so their checks line up; a leaf's chevron is clear.
public struct SHPopMenuDisclosure: Equatable, Sendable {
    public var indent: Int
    public var isParent: Bool
    public var isOpen: Bool

    public init(indent: Int, isParent: Bool, isOpen: Bool) {
        self.indent = indent
        self.isParent = isParent
        self.isOpen = isOpen
    }
}

/// The column a row's lead takes.
private struct SHPopMenuLeadView: View {
    let lead: SHPopMenuLead

    var body: some View {
        let sh = Color.sh
        let M = SHPopMenuMetrics.self
        switch lead {
        case .none:
            EmptyView()
        case .check(let on):
            Image(systemName: "checkmark").font(.system(size: M.glyphSize, weight: .medium)).foregroundStyle(sh.textPrimary)
                .opacity(on ? 1 : 0).frame(width: M.checkWidth)
        case .glyph(let name):
            Image(systemName: name).font(.system(size: M.glyphSize)).foregroundStyle(sh.textSecondary).frame(width: M.glyphWidth)
        }
    }
}

/// One row: what leads it, its title (`prefix` quietly before it), and what trails it, a quiet word
/// or a chevron. A disabled row reads in `textTertiary` and takes no click.
///
/// The pointer highlights a row itself, so moving it redraws that row and the one it left. A list
/// the keyboard also moves through passes `highlighted`, and `onHighlight` with its `index` for the
/// pointer to move its own highlight: the row then follows that alone. A row redraws only when what it draws changes (its closures
/// aside), so a highlight moving redraws the two rows it moves between, whatever the list's length.
/// Not a `Button`: each button brings an AppKit focus-ring view, and a long list scrolls rows in and
/// out; the search field keeps keyboard focus.
public struct SHPopMenuRow: View {
    let values: SHPopMenuRowValues
    let action: () -> Void
    let onHighlight: ((Int) -> Void)?
    let onDisclose: () -> Void

    public init(_ title: String, prefix: String? = nil, mono: Bool = false, lead: SHPopMenuLead = .none, trailing: String? = nil,
                trailingStyle: SHPopMenuTrailingStyle = .word, chevron: Bool = false, enabled: Bool = true, quiet: Bool = false,
                disclosure: SHPopMenuDisclosure? = nil, highlighted: Bool? = nil, index: Int = 0,
                onHighlight: ((Int) -> Void)? = nil, onDisclose: @escaping () -> Void = {}, action: @escaping () -> Void) {
        values = SHPopMenuRowValues(title: title, prefix: prefix, mono: mono, lead: lead, trailing: trailing, trailingStyle: trailingStyle,
                                    chevron: chevron, enabled: enabled, quiet: quiet, disclosure: disclosure, highlighted: highlighted,
                                    index: index)
        self.action = action
        self.onHighlight = onHighlight
        self.onDisclose = onDisclose
    }

    public var body: some View {
        SHPopMenuRowFace(values: values, action: action, onHighlight: onHighlight, onDisclose: onDisclose).equatable()
    }
}

/// What a row draws: the rest of a row is its closures.
struct SHPopMenuRowValues: Equatable {
    let title: String
    let prefix: String?
    let mono: Bool
    let lead: SHPopMenuLead
    let trailing: String?
    let trailingStyle: SHPopMenuTrailingStyle
    let chevron: Bool
    let enabled: Bool
    /// The title in `textSecondary` ("Add folder…").
    let quiet: Bool
    let disclosure: SHPopMenuDisclosure?
    /// Nil: the pointer highlights it.
    let highlighted: Bool?
    /// Where it sits in its list, handed to `onHighlight`. In what a row draws, so a list that
    /// filters or reorders never leaves a row holding its old place.
    let index: Int
}

private struct SHPopMenuRowFace: View, Equatable {
    let values: SHPopMenuRowValues
    let action: () -> Void
    let onHighlight: ((Int) -> Void)?
    let onDisclose: () -> Void
    @State private var hovering = false

    static func == (a: Self, b: Self) -> Bool { a.values == b.values }

    var body: some View {
        let _ = SHRenderProbe.tick("pop.menu.row")
        let sh = Color.sh
        let M = SHPopMenuMetrics.self
        let v = values
        HStack(spacing: M.rowSpacing) {
            if let disclosure = v.disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: M.disclosureSize, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .rotationEffect(.degrees(disclosure.isOpen ? 90 : 0))
                    .frame(width: M.disclosureWidth)
                    .opacity(disclosure.isParent ? 1 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture { if disclosure.isParent { onDisclose() } else if v.enabled { action() } }
                    .accessibilityHidden(true)
                    .padding(.leading, CGFloat(disclosure.indent) * M.disclosureIndent)
            }
            SHPopMenuLeadView(lead: v.lead)
            if let prefix = v.prefix {
                Text(prefix).font(.sh(.ui)).foregroundStyle(sh.textSecondary).lineLimit(1).fixedSize()
            }
            Text(v.title)
                .font(v.mono ? .shMono(M.codeSize) : .sh(.ui))
                .foregroundStyle(!v.enabled ? sh.textTertiary : v.quiet ? sh.textSecondary : sh.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let trailing = v.trailing {
                Text(trailing)
                    .font(v.trailingStyle == .code ? .shMono(M.trailingCodeSize) : .sh(.caption))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(v.trailingStyle == .path ? .head : v.trailingStyle == .code ? .middle : .tail)
            }
            if v.chevron {
                Image(systemName: "chevron.right").font(.system(size: M.chevronSize, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
        }
        .padding(.horizontal, M.rowInset)
        .frame(minHeight: M.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((v.highlighted ?? hovering) && v.enabled ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { inside in
            if let onHighlight { if inside { onHighlight(v.index) } } else { hovering = inside }
        }
        .onTapGesture { if v.enabled { action() } }
        .accessibilityElement(children: .combine)
        // Selected to VoiceOver as it is to the eye: the highlighted row of a list the keyboard moves
        // through, else the one checked.
        .accessibilityAddTraits(v.highlighted ?? (v.lead == .check(true)) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if v.enabled { action() } }
    }
}

/// A switch row: its title and a caption under it (what it does), and the switch. The whole row
/// toggles; the menu stays open.
public struct SHPopMenuToggle: View {
    let title: String
    let caption: String?
    let lead: SHPopMenuLead
    @Binding var isOn: Bool

    public init(_ title: String, caption: String? = nil, lead: SHPopMenuLead = .none, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self.lead = lead
        _isOn = isOn
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHPopMenuMetrics.self
        HStack(spacing: M.rowSpacing) {
            SHPopMenuLeadView(lead: lead)
            VStack(alignment: .leading, spacing: M.toggleCaptionGap) {
                Text(title).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                if let caption {
                    Text(caption).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SH.Space.m)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.shSwitch)
                .labelsHidden()
                .allowsHitTesting(false)
        }
        .padding(.horizontal, M.rowInset)
        .padding(.vertical, SH.Space.xs)
        .frame(minHeight: M.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onTapGesture { isOn.toggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction { isOn.toggle() }
    }
}

/// The search over a list: 38pt, running to the surface's edges with a hairline under it.
public struct SHPopMenuSearch: View {
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
        let sh = Color.sh
        let M = SHPopMenuMetrics.self
        HStack(spacing: SH.Space.m) {
            Image(systemName: "magnifyingglass").font(.system(size: M.glyphSize + 1, weight: .medium)).foregroundStyle(sh.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(sh.textTertiary))
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .onKeyPress(.escape) { onEscape(); return .handled }
        }
        .padding(.horizontal, M.searchInset)
        .frame(height: M.searchHeight)
        .overlay(alignment: .bottom) { SHHairline() }
        .padding(.top, -M.padding)
        .padding(.horizontal, -M.padding)
        .padding(.bottom, M.padding)
        .onAppear { isFocused.wrappedValue = true }
    }
}
#endif
