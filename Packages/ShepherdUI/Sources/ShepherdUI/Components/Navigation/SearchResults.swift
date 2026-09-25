import SwiftUI

/// Search's own measures (MobileSearch and iPadPalette boards).
public enum NWSearchMetrics {
    /// A result row on a phone's card: 52pt, never under the touch minimum.
    public static let rowHeight: CGFloat = 52
    /// A result row in the iPad palette's list.
    public static let compactRowHeight: CGFloat = 48
    /// The column the leading icon or status dot centers in.
    public static let iconColumn: CGFloat = 20
    /// The leading icon's size.
    public static let iconSize: CGFloat = 15
    /// The phone's search field.
    public static let fieldHeight: CGFloat = 40
    /// The palette's search row.
    public static let largeFieldHeight: CGFloat = 56
    /// The trailing chevron of a row that opens something.
    public static let chevronSize: CGFloat = 12
    /// The status dot in the icon column.
    public static let statusDot: CGFloat = 8
}

/// A run of text, and whether it matched the query.
public struct NWHighlightRun: Hashable, Sendable {
    public var text: String
    public var highlighted: Bool

    public init(_ text: String, highlighted: Bool = false) {
        self.text = text
        self.highlighted = highlighted
    }
}

/// Text with the query's matches in the lantern's text color at semibold (the boards'
/// highlight), the rest in `color`. One line unless `lines` says more, tail-truncated.
public struct NWHighlightedText: View, Equatable {
    let runs: [NWHighlightRun]
    let style: NWTextStyle
    let color: NWHighlightColor
    let lines: Int

    public enum NWHighlightColor: Hashable, Sendable { case primary, secondary, tertiary }

    public init(_ runs: [NWHighlightRun], style: NWTextStyle, color: NWHighlightColor = .primary, lines: Int = 1) {
        self.runs = runs
        self.style = style
        self.color = color
        self.lines = lines
    }

    public var body: some View {
        let nw = Color.nw
        let base: Color = switch color {
        case .primary: nw.textPrimary
        case .secondary: nw.textSecondary
        case .tertiary: nw.textTertiary
        }
        var text = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            if run.highlighted {
                part.foregroundColor = nw.lanternText
                part.font = .nw(style, weight: .semibold)
            }
            text.append(part)
        }
        return Text(text)
            .font(.nw(style))
            .foregroundStyle(base)
            .lineLimit(lines)
            .truncationMode(.tail)
    }
}

/// One search result: a leading glyph (a status dot for a thread, an icon for a conversation or
/// an action), the title over a detail line, both with the query highlighted, the host as a
/// tag, and a chevron when it opens a screen. `selected` is the palette's keyboard highlight
/// (running tint). The caller makes it a button; the row draws only.
public struct NWSearchResultRow: View, Equatable {
    public enum Leading: Hashable, Sendable {
        case status(AgentState)
        case symbol(String)
    }

    let leading: Leading
    let title: [NWHighlightRun]
    let detail: [NWHighlightRun]
    let tag: String?
    let shortcut: String?
    let chevron: Bool
    let selected: Bool
    let dimmed: Bool
    let minHeight: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.leading == rhs.leading && lhs.title == rhs.title && lhs.detail == rhs.detail && lhs.tag == rhs.tag
            && lhs.shortcut == rhs.shortcut && lhs.chevron == rhs.chevron && lhs.selected == rhs.selected
            && lhs.dimmed == rhs.dimmed && lhs.minHeight == rhs.minHeight
    }

    public init(leading: Leading, title: [NWHighlightRun], detail: [NWHighlightRun] = [], tag: String? = nil,
                shortcut: String? = nil, chevron: Bool = false, selected: Bool = false, dimmed: Bool = false,
                minHeight: CGFloat = NWSearchMetrics.rowHeight) {
        self.leading = leading
        self.title = title
        self.detail = detail
        self.tag = tag
        self.shortcut = shortcut
        self.chevron = chevron
        self.selected = selected
        self.dimmed = dimmed
        self.minHeight = minHeight
    }

    public var body: some View {
        let _ = NWRenderProbe.tick("search.row")
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            Group {
                switch leading {
                case .status(let state):
                    NWStatusDot(state, size: NWSearchMetrics.statusDot)
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: NWSearchMetrics.iconSize, weight: .regular))
                        .foregroundStyle(selected ? nw.running : nw.textSecondary)
                }
            }
            .frame(width: NWSearchMetrics.iconColumn)
            .accessibilityHidden(true)
            // At accessibility sizes the text wraps and the tag moves under it, so the title
            // keeps the row's width.
            let large = typeSize.isAccessibilitySize
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                NWHighlightedText(title, style: .ui, lines: large ? 3 : 1)
                if !detail.isEmpty {
                    NWHighlightedText(detail, style: .caption, color: .tertiary, lines: large ? 3 : 1)
                }
                if large, let tag { NWTag(tag, mono: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !large, let tag { NWTag(tag, mono: true) }
            if let shortcut { NWKeycap(shortcut) }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: NWSearchMetrics.chevronSize, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity, minHeight: max(minHeight, NW.Height.touch), alignment: .leading)
        .background(selected ? nw.runningTint : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .opacity(dimmed ? NWSearchResultRow.dimmedOpacity : 1)
        .contentShape(Rectangle())
    }

    /// An offline host's last known thread.
    public static let dimmedOpacity = 0.55
}

/// The touch search field: a glass, the field, and a clear button once there is text, on a
/// filled capsule (`large` is the palette's plain 56pt row). Focus stays with the caller, so it
/// can focus the field on appear and read keys (`.onKeyPress`) while it is focused.
public struct NWTouchSearchField: View {
    let placeholder: String
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let large: Bool
    let submit: () -> Void

    public init(_ placeholder: String, text: Binding<String>, focus: FocusState<Bool>.Binding, large: Bool = false,
                submit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.focus = focus
        self.large = large
        self.submit = submit
    }

    public var body: some View {
        let nw = Color.nw
        let row = HStack(spacing: NW.Space.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: NWSearchMetrics.iconSize, weight: .regular))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(nw.textTertiary))
                .textFieldStyle(.plain)
                .font(large ? .nw(.headline, weight: .regular) : .nw(.body))
                .foregroundStyle(nw.textPrimary)
                .tint(nw.lantern)
                .focused(focus)
                .submitLabel(.search)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit(submit)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: NWSearchMetrics.iconSize, weight: .regular))
                        .foregroundStyle(nw.textTertiary)
                        .nwTouchTarget(height: NWSearchMetrics.iconSize, width: NWSearchMetrics.iconSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        if large {
            row.padding(.horizontal, NW.Space.xl)
                .frame(minHeight: NWSearchMetrics.largeFieldHeight)
        } else {
            row.padding(.horizontal, NW.Space.l)
                .frame(minHeight: NWSearchMetrics.fieldHeight)
                .background(nw.bgSelected, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        }
    }
}

#Preview("Search results") {
    @Previewable @State var query = "funnel"
    @Previewable @State var empty = ""
    @Previewable @FocusState var focused: Bool
    let match = [NWHighlightRun("Checkout "), NWHighlightRun("funnel", highlighted: true), NWHighlightRun(" events")]
    let snippet = [NWHighlightRun("“…"), NWHighlightRun("funnel", highlighted: true), NWHighlightRun(" rows can’t be joined…”")]
    NWPreviewBoth {
        VStack(alignment: .leading, spacing: NW.Space.l) {
            NWTouchSearchField("Search threads", text: $query, focus: $focused)
            NWTouchSearchField("Search threads and actions", text: $empty, focus: $focused, large: true)
            VStack(spacing: 0) {
                NWSearchResultRow(leading: .status(.attention), title: match, detail: [NWHighlightRun("Needs you · Shepherd")],
                                  tag: "Studio", chevron: true)
                NWHairline()
                NWSearchResultRow(leading: .symbol("text.bubble"), title: [NWHighlightRun("Plan shepherd extensions")],
                                  detail: snippet, tag: "build-01", chevron: true)
                NWHairline()
                NWSearchResultRow(leading: .status(.idle), title: [NWHighlightRun("Old notes")], detail: [NWHighlightRun("Idle")],
                                  tag: "MacBook Air", chevron: true, dimmed: true)
            }
            .nwCard(radius: NW.Radius.l)
            NWSearchResultRow(leading: .symbol("pencil"), title: [NWHighlightRun("Rename…")],
                              detail: [NWHighlightRun("Investigate SwiftUI live preview")], shortcut: "↩", selected: true,
                              minHeight: NWSearchMetrics.compactRowHeight)
        }
        .frame(width: 390)
    }
}
