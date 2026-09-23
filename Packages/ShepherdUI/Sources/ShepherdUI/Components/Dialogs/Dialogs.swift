import SwiftUI

/// Sheet geometry shared by every dialog part, so rows, lists and the footer line up.
public enum NWDialogMetrics {
    /// The dialog's outer inset: header, rows, footer.
    public static let inset: CGFloat = NW.Space.xxl
    /// The label column of a labeled row.
    public static let labelWidth: CGFloat = 96
    /// A labeled row fits a default control with a step of air above and below.
    public static let rowMinHeight: CGFloat = NW.Height.controlM + 2 * NW.Space.m
    public static let width: CGFloat = 460
}

/// A modal sheet: a title, an optional explanation, the body (labeled rows, banners, lists),
/// and a footer with an optional status on the leading edge and the actions trailing. Flat on
/// `bgWindow`. Exactly one primary action is the ⏎ default; a destructive action never is.
public struct NWDialog<Content: View, Status: View, Actions: View>: View {
    let title: String
    let message: String?
    let width: CGFloat
    let content: Content
    let status: Status
    let actions: Actions

    public init(_ title: String, message: String? = nil, width: CGFloat = NWDialogMetrics.width,
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
        let nw = Color.nw
        let inset = NWDialogMetrics.inset
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text(title)
                    .nwText(.title)
                    .foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message {
                    Text(message)
                        .nwText(.body)
                        .foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: inset, leading: inset, bottom: NW.Space.l, trailing: inset))

            content

            HStack(spacing: NW.Space.m) {
                status
                Spacer(minLength: NW.Space.l)
                // Actions never truncate; the status wraps instead.
                HStack(spacing: NW.Space.m) { actions }
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(EdgeInsets(top: NW.Space.xl, leading: inset, bottom: inset, trailing: inset))
        }
        .frame(width: width)
        .background(nw.bgWindow)
    }
}

extension NWDialog where Status == EmptyView {
    public init(_ title: String, message: String? = nil, width: CGFloat = NWDialogMetrics.width,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.init(title, message: message, width: width, content: content, status: { EmptyView() }, actions: actions)
    }
}

/// The footer's status line: a caption in `textSecondary`, or `failed` for an error.
public struct NWDialogStatus: View {
    let text: String
    let isError: Bool

    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    public var body: some View {
        Text(text)
            .nwText(.caption)
            .foregroundStyle(isError ? Color.nw.failed : Color.nw.textSecondary)
            .lineLimit(2)
            .textSelection(.enabled)
    }
}

/// One labeled row of a sheet: the label column, the control filling the rest, a hairline
/// underneath. No form chrome and no grouped boxes.
public struct NWSheetRow<Control: View>: View {
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
        let inset = NWDialogMetrics.inset
        HStack(alignment: alignment, spacing: NW.Space.l) {
            Text(label)
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textSecondary)
                .frame(width: NWDialogMetrics.labelWidth, alignment: .leading)
            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, inset)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWDialogMetrics.rowMinHeight)
        .overlay(alignment: .bottom) { NWHairline().padding(.leading, inset) }
        .accessibilityElement(children: .contain)
    }
}

/// A step or check in a sheet's list (a pipeline, a prerequisite checklist): the state glyph,
/// the label, and a trailing detail. A row can carry its remedy underneath.
public struct NWChecklistRow<Remedy: View>: View {
    let title: String
    let state: AgentState
    let stateLabel: String
    let detail: String?
    let remedy: Remedy
    let hasRemedy: Bool

    /// `stateLabel` replaces the state's word for VoiceOver ("passed", "pending").
    public init(_ title: String, state: AgentState, stateLabel: String? = nil, detail: String? = nil,
                @ViewBuilder remedy: () -> Remedy) {
        self.title = title
        self.state = state
        self.stateLabel = stateLabel ?? state.label
        self.detail = NWChecklistMetrics.oneLine(detail)
        self.remedy = remedy()
        hasRemedy = Remedy.self != EmptyView.self
    }

    public var body: some View {
        let nw = Color.nw
        let inset = NWDialogMetrics.inset
        let titleColor: Color = switch state {
        case .queued, .idle: nw.textTertiary
        case .failed, .stuck: nw.failed
        case .done: nw.textSecondary
        case .running, .attention: nw.textPrimary
        }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                NWStateGlyph(state)
                Text(title)
                    .font(.nw(.ui))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if let detail {
                    Text(detail)
                        .font(.nw(.caption))
                        .foregroundStyle(state == .failed ? nw.failed : nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(detail)
                }
            }
            .frame(minHeight: NW.Height.row)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([title, stateLabel, detail].compactMap(\.self).joined(separator: ", "))
            if hasRemedy {
                remedy
                    .padding(.leading, NWChecklistMetrics.glyph + NW.Space.m)
                    .padding(.bottom, NW.Space.m)
            }
        }
        .padding(.horizontal, inset)
        .overlay(alignment: .bottom) { NWHairline().padding(.leading, inset) }
        .accessibilityElement(children: .contain)
    }
}

extension NWChecklistRow where Remedy == EmptyView {
    public init(_ title: String, state: AgentState, stateLabel: String? = nil, detail: String? = nil) {
        self.init(title, state: state, stateLabel: stateLabel, detail: detail) { EmptyView() }
    }
}

enum NWChecklistMetrics {
    /// `NWStateGlyph`'s default size: the remedy indents past it.
    static let glyph: CGFloat = 14

    /// A detail on one line. Details are often a tool's stderr, and a one-line `Text` of several
    /// lines shows only a fragment of the last one; nil when there is nothing to show.
    static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.isEmpty ? nil : line
    }
}

/// A row of Settings' navigation, the sidebar's anatomy: a 28pt row (density-scaled), an icon,
/// the page name, `bgSelected` and a semibold name when selected.
public struct NWSettingsNavRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    public init(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.selected = selected
        self.action = action
    }

    public var body: some View {
        let nw = Color.nw
        Button(action: action) {
            HStack(spacing: NW.Space.m) {
                // Scales with the text size, like the name beside it.
                Image(systemName: systemImage)
                    .font(.nw(.body, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(selected ? nw.textPrimary : nw.textSecondary)
                    .frame(width: NW.Space.xl)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.nw(.ui, weight: selected ? .semibold : .regular))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NW.Space.m)
            .frame(minHeight: NW.Height.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.nwRow(selected: selected))
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
