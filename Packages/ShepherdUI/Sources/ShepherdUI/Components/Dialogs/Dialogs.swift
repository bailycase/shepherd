import SwiftUI

/// Sheet geometry shared by every dialog part, so rows, lists and the footer line up.
public enum SHDialogMetrics {
    /// The dialog's outer inset: header, rows, footer.
    public static let inset: CGFloat = SH.Space.xxl
    /// The label column of a labeled row.
    public static let labelWidth: CGFloat = 96
    /// A labeled row fits a default control with a step of air above and below.
    public static let rowMinHeight: CGFloat = SH.Height.controlM + 2 * SH.Space.m
    public static let width: CGFloat = 460
}

/// A modal sheet: a title, an optional explanation, the body (labeled rows, banners, lists),
/// and a footer with an optional status on the leading edge and the actions trailing. Flat on
/// `bgWindow`. Exactly one primary action is the ⏎ default; a destructive action never is.
public struct SHDialog<Content: View, Status: View, Actions: View>: View {
    let title: String
    let message: String?
    let width: CGFloat
    let content: Content
    let status: Status
    let actions: Actions

    public init(_ title: String, message: String? = nil, width: CGFloat = SHDialogMetrics.width,
                @ViewBuilder content: () -> Content, @ViewBuilder status: () -> Status,
                @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.width = width
        self.content = content()
        self.status = status()
        self.actions = actions()
    }

    public var body: some View {
        let sh = Color.sh
        let inset = SHDialogMetrics.inset
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text(title)
                    .shText(.title)
                    .foregroundStyle(sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .shText(.body)
                        .foregroundStyle(sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: inset, leading: inset, bottom: SH.Space.l, trailing: inset))

            content

            HStack(spacing: SH.Space.m) {
                status
                Spacer(minLength: SH.Space.l)
                // Actions never truncate; the status wraps instead.
                HStack(spacing: SH.Space.m) { actions }
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(EdgeInsets(top: SH.Space.xl, leading: inset, bottom: inset, trailing: inset))
        }
        .frame(width: width)
        .background(sh.bgWindow)
    }
}

extension SHDialog where Status == EmptyView {
    public init(_ title: String, message: String? = nil, width: CGFloat = SHDialogMetrics.width,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title, message: message, width: width, content: content, status: { EmptyView() }, actions: actions)
    }
}

/// The footer's status line: a caption in `textSecondary`, or `failed` for an error.
public struct SHDialogStatus: View {
    let text: String
    let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var body: some View {
        Text(text)
            .shText(.caption)
            .foregroundStyle(isError ? Color.sh.failed : Color.sh.textSecondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}

/// One labeled row of a sheet: the label column, the control filling the rest, a hairline
/// underneath. No form chrome and no grouped boxes.
public struct SHSheetRow<Control: View>: View {
    let label: String
    let alignment: VerticalAlignment
    let control: Control

    /// `alignment` aligns the label with a control that wraps (`.firstTextBaseline`).
    public init(_ label: String, alignment: VerticalAlignment = .center, @ViewBuilder control: () -> Control) {
        self.label = label
        self.alignment = alignment
        self.control = control()
    }

    public var body: some View {
        let inset = SHDialogMetrics.inset
        HStack(alignment: alignment, spacing: SH.Space.l) {
            Text(label)
                .font(.sh(.ui))
                .foregroundStyle(Color.sh.textSecondary)
                .frame(width: SHDialogMetrics.labelWidth, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHDialogMetrics.rowMinHeight)
        .overlay(alignment: .bottom) { SHHairline().padding(.leading, inset) }
        .accessibilityElement(children: .contain)
    }
}

/// A step or check in a sheet's list (a pipeline, a prerequisite checklist): the state glyph,
/// the label, and a trailing detail. A row can carry its remedy underneath.
///
/// The glyph, the label's color and the detail fade as the state moves on, and the glyph pops
/// once when a step passes. A remedy that comes and goes (`showsRemedy`) discloses; animate the
/// list around it (`shAnimation(.disclosure, value:)`) so the rows below make room in step.
public struct SHChecklistRow<Remedy: View>: View {
    let title: String
    let state: AgentState
    let stateLabel: String
    let detail: String?
    let remedy: Remedy
    let hasRemedy: Bool
    @State private var passes = 0

    /// `stateLabel` replaces the state's word for VoiceOver ("passed", "pending"). The remedy
    /// shows while `showsRemedy` (a failed check's fix); the row stays the same view either way.
    public init(_ title: String, state: AgentState, stateLabel: String? = nil, detail: String? = nil,
                showsRemedy: Bool = true, @ViewBuilder remedy: () -> Remedy) {
        self.title = title
        self.state = state
        self.stateLabel = stateLabel ?? state.label
        self.detail = detail.flatMap { $0.isEmpty ? nil : $0 }
        self.remedy = remedy()
        hasRemedy = showsRemedy && Remedy.self != EmptyView.self
    }

    public var body: some View {
        let sh = Color.sh
        let inset = SHDialogMetrics.inset
        let titleColor: Color = switch state {
        case .queued, .idle: sh.textTertiary
        case .failed, .stuck: sh.failed
        case .done: sh.textSecondary
        case .running, .attention: sh.textPrimary
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                SHStateGlyph(state)
                    .shPop(trigger: passes)
                Text(title)
                    .font(.sh(.ui))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.m)
                if let detail {
                    Text(detail)
                        .font(.sh(.caption))
                        .foregroundStyle(state == .failed ? sh.failed : sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail)
                        .shContentTransition(.crossFade)
                }
            }
            .frame(minHeight: SH.Height.row)
            .shComponentAnimation(.content, value: detail)
            .shComponentAnimation(.content, value: state)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, stateLabel, detail].compactMap(\.self).joined(separator: ", "))
            if hasRemedy {
                remedy
                    .padding(.leading, SHChecklistMetrics.glyph + SH.Space.m)
                    .padding(.bottom, SH.Space.m)
                    .shTransition(.disclosure)
            }
        }
        .padding(.horizontal, inset)
        // A disclosing remedy shows as the row makes room for it, never over what follows.
        .clipped()
        .overlay(alignment: .bottom) { SHHairline().padding(.leading, inset) }
        .accessibilityElement(children: .contain)
        .onChange(of: state) { old, new in
            // A step that passes pops once; leaving done (a re-run) doesn't.
            if new == .done, old != .done { passes += 1 }
        }
    }
}

extension SHChecklistRow where Remedy == EmptyView {
    public init(_ title: String, state: AgentState, stateLabel: String? = nil, detail: String? = nil) {
        self.init(title, state: state, stateLabel: stateLabel, detail: detail, showsRemedy: false) { EmptyView() }
    }
}

enum SHChecklistMetrics {
    /// `SHStateGlyph`'s default size: the remedy indents past it.
    static let glyph: CGFloat = 14
}

/// A row of Settings' navigation (every Settings board): 32pt, scaled by density, radius `s`; a
/// 15pt icon in `textSecondary` (`textPrimary` when selected), then the page name in Geist 13,
/// on `bgSelected` at medium weight when selected, `bgHover` while hovered.
public struct SHSettingsNavRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    /// A 6pt `lantern` dot trailing while the page wants attention (Sign-in).
    let attention: Bool
    let action: () -> Void

    private let artwork: SHGlyph.Settings?

    public init(_ title: String, systemImage: String, selected: Bool, attention: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.attention = attention
        self.action = action
        self.artwork = nil
    }

    public init(_ title: String, glyph: SHGlyph.Settings, selected: Bool, attention: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = ""
        self.selected = selected
        self.attention = attention
        self.action = action
        self.artwork = glyph
    }

    public var body: some View {
        let sh = Color.sh
        Button(action: action) {
            HStack(spacing: SHSettingsNavMetrics.iconGap) {
                // Scales with the text size, like the name beside it.
                Group {
                    if let artwork { artwork.image }
                    else { Image(systemName: systemImage).font(.shSans(SHSettingsNavMetrics.glyphSize)).symbolRenderingMode(.monochrome) }
                }.foregroundStyle(selected ? sh.textPrimary : sh.textSecondary)
                    .frame(width: SHSettingsNavMetrics.iconSize).accessibilityHidden(true)
                Text(title)
                    .font(.shSans(SHSettingsNavMetrics.textSize, selected ? .medium : .regular))
                    .offset(y: artwork != nil ? SHSettingsNavMetrics.textBaseline * ThemeStore.shared.textScale : 0)
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if attention {
                    Circle().fill(sh.lantern).frame(width: SHSettingsNavMetrics.attentionDot, height: SHSettingsNavMetrics.attentionDot)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, SHSettingsNavMetrics.rowPadding)
            .frame(minHeight: SH.Height.scaled(SHSettingsNavMetrics.rowHeight))
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(selected: selected, selectedFill: Color.sh.settingsNavSelected, focusColor: artwork != nil ? .sh.running : nil))
        .accessibilityLabel(title)
        .accessibilityLabel(attention ? "\(title), needs you" : title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// Settings' navigation rows (every Settings board).
public enum SHSettingsNavMetrics {
    /// Before density.
    public static let rowHeight: CGFloat = 32
    public static let iconSize: CGFloat = 15
    /// The symbol's point size: its outline fills the 15pt box as the boards' 1.4pt-stroke icons do.
    public static let glyphSize: CGFloat = 13
    /// 10pt in from the row's sides, and from the icon to the name.
    public static let rowPadding: CGFloat = 10
    public static let iconGap: CGFloat = 10
    /// The nav's own sides: 10pt.
    public static let sidePadding: CGFloat = 10
    /// The page names, and the Back row's words.
    public static let textSize: CGFloat = 13
    /// A page under another: 28pt, 35pt in (past the icon), Geist 12.5.
    public static let subTextSize: CGFloat = 12.5
    public static let attentionDot: CGFloat = 6
    /// CSS points, not device pixels, in the supplied Settings boards.
    public static let borderWidth: CGFloat = 1
    public static let searchHeight: CGFloat = 34
    public static let textBaseline: CGFloat = 1.5
}
