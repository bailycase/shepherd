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

/// One row: what leads it, its title (`prefix` quietly before it), and what trails it, a quiet word
/// or a chevron. A disabled row reads in `textTertiary` and takes no click.
public struct SHPopMenuRow: View {
    let title: String
    let prefix: String?
    let mono: Bool
    let lead: SHPopMenuLead
    let trailing: String?
    let chevron: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    public init(_ title: String, prefix: String? = nil, mono: Bool = false, lead: SHPopMenuLead = .none, trailing: String? = nil,
                chevron: Bool = false, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.prefix = prefix
        self.mono = mono
        self.lead = lead
        self.trailing = trailing
        self.chevron = chevron
        self.enabled = enabled
        self.action = action
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("pop.menu.row")
        let sh = Color.sh
        let M = SHPopMenuMetrics.self
        HStack(spacing: M.rowSpacing) {
            switch lead {
            case .none:
                EmptyView()
            case .check(let on):
                Image(systemName: "checkmark").font(.system(size: M.glyphSize, weight: .medium)).foregroundStyle(sh.textPrimary)
                    .opacity(on ? 1 : 0).frame(width: M.checkWidth)
            case .glyph(let name):
                Image(systemName: name).font(.system(size: M.glyphSize)).foregroundStyle(sh.textSecondary).frame(width: M.glyphWidth)
            }
            if let prefix {
                Text(prefix).font(.sh(.ui)).foregroundStyle(sh.textSecondary).lineLimit(1).fixedSize()
            }
            Text(title)
                .font(mono ? .shMono(M.codeSize) : .sh(.ui))
                .foregroundStyle(enabled ? sh.textPrimary : sh.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.system(size: M.chevronSize, weight: .semibold)).foregroundStyle(sh.textTertiary)
            }
        }
        .padding(.horizontal, M.rowInset)
        .frame(minHeight: M.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && enabled ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.s))
        .contentShape(RoundedRectangle(cornerRadius: SH.Radius.s))
        .onHover { hovering = $0 }
        .onTapGesture { if enabled { action() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(lead == .check(true) ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { if enabled { action() } }
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
