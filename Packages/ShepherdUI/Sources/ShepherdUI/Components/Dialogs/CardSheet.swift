#if os(macOS)
import SwiftUI

// The branch card's sheets (GXBranchCommit, GXBranchConflict boards): a raised card 480pt wide with its title in 15
// semibold, a one-line explanation, a labeled list or field, and a foot of words with the one action as an ink pill.

public enum SHCardSheetMetrics {
    public static let width: CGFloat = 480
    public static let padding = EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20)
    public static let titleSize: CGFloat = 15
    public static let titleLine: CGFloat = 20
    /// The explanation sits 6pt under the title, set on 19pt lines.
    public static let messageTop: CGFloat = SH.Space.s
    public static let messageLine: CGFloat = 19
    /// A label above a list or field: 14pt over it, 6pt under.
    public static let labelTop: CGFloat = 14
    public static let labelBottom: CGFloat = SH.Space.s
    public static let rowHeight: CGFloat = 28
    public static let rowGap: CGFloat = SH.Space.xxs
    public static let rowInset: CGFloat = SH.Space.xxs
    public static let rowSpacing: CGFloat = 10
    public static let listPadding: CGFloat = SH.Space.xs
    public static let directoryGap: CGFloat = SH.Space.s
    public static let fieldMinHeight: CGFloat = 76
    public static let fieldPadding = EdgeInsets(top: SH.Space.m, leading: 10, bottom: SH.Space.m, trailing: 10)
    public static let amendTop: CGFloat = 10
    public static let footTop: CGFloat = 18
    public static let footGap: CGFloat = 18
    public static let pillHeight: CGFloat = 26
    public static let pillPadding: CGFloat = 11
    public static let checkbox: CGFloat = 14
}

/// The sheet: `title`, an optional `message`, the content, and the foot's actions (right-aligned, the last one the pill).
public struct SHCardSheet<Content: View, Actions: View>: View {
    let title: String
    let message: Text?
    let width: CGFloat
    let content: Content
    let actions: Actions

    public init(_ title: String, message: Text? = nil, width: CGFloat = SHCardSheetMetrics.width,
                @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.width = width
        self.content = content()
        self.actions = actions()
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHCardSheetMetrics.self
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.shSans(M.titleSize, .semibold))
                .foregroundStyle(sh.textPrimary)
                .frame(minHeight: M.titleLine, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let message {
                message
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineSpacing(M.messageLine - 18)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, M.messageTop)
            }
            content
            HStack(spacing: M.footGap) {
                Spacer(minLength: 0)
                actions
            }
            .padding(.top, M.footTop)
        }
        .padding(M.padding)
        .frame(width: width)
        .background(sh.bgRaised)
    }
}

/// A label over a list or field ("Changes  4 of 5", "Message"), with a link at its end.
public struct SHCardSheetLabel<Trailing: View>: View {
    let text: String
    let count: String?
    let trailing: Trailing

    public init(_ text: String, count: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.text = text
        self.count = count
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            Text(text).foregroundStyle(Color.sh.textSecondary)
            if let count { Text(count).foregroundStyle(Color.sh.textTertiary) }
            Spacer(minLength: 0)
            trailing
        }
        .font(.sh(.caption))
        .padding(.top, SHCardSheetMetrics.labelTop)
        .padding(.bottom, SHCardSheetMetrics.labelBottom)
        .accessibilityElement(children: .contain)
    }
}

extension SHCardSheetLabel where Trailing == EmptyView {
    public init(_ text: String, count: String? = nil) { self.init(text, count: count) { EmptyView() } }
}

/// The rows' container: a hairline above and below, 4pt in, 2pt between rows.
public struct SHCardSheetList<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        VStack(alignment: .leading, spacing: SHCardSheetMetrics.rowGap) { content }
            .padding(.vertical, SHCardSheetMetrics.listPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) { SHHairline() }
            .overlay(alignment: .bottom) { SHHairline() }
    }
}

/// A file in a sheet's list: its name with its directory after it, and either its diff stat or a word in `failed` (a conflict).
/// `checked` draws the box (and the row toggles); nil draws none.
public struct SHCardSheetFileRow: View, Equatable {
    let name: String
    let directory: String
    let checked: Bool?
    let added: Int
    let removed: Int
    let word: String?
    let help: String?
    let toggle: () -> Void

    public init(name: String, directory: String, checked: Bool? = nil, added: Int = 0, removed: Int = 0, word: String? = nil,
                help: String? = nil, toggle: @escaping () -> Void = {}) {
        self.name = name
        self.directory = directory
        self.checked = checked
        self.added = added
        self.removed = removed
        self.word = word
        self.help = help
        self.toggle = toggle
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.directory == b.directory && a.checked == b.checked && a.added == b.added && a.removed == b.removed
            && a.word == b.word && a.help == b.help
    }

    public var body: some View {
        let sh = Color.sh
        let M = SHCardSheetMetrics.self
        let row = HStack(spacing: M.rowSpacing) {
            if let checked {
                Toggle(name, isOn: .constant(checked))
                    .toggleStyle(.shCheckbox)
                    .labelsHidden()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            HStack(spacing: M.directoryGap) {
                Text(name).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                if !directory.isEmpty {
                    Text(directory).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let word {
                Text(word).font(.sh(.caption)).foregroundStyle(sh.failed)
            } else {
                SHDiffStat(added: added, removed: removed, font: .sh(.caption), hidesZero: true)
            }
        }
        .padding(.horizontal, M.rowInset)
        .frame(minHeight: M.rowHeight)
        .contentShape(Rectangle())
        if checked != nil {
            Button(action: toggle) { row }
                .buttonStyle(.plain)
                .help(help ?? "")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([name, directory.isEmpty ? nil : "in \(directory)", help].compactMap { $0 }.joined(separator: ", "))
                .accessibilityValue(checked == true ? "Selected" : "Not selected")
                .accessibilityAddTraits(.isToggle)
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([name, directory.isEmpty ? nil : "in \(directory)", word].compactMap { $0 }.joined(separator: ", "))
        }
    }
}

/// A bordered field's frame (the commit message): the line, radius 8, 8pt over 10pt inside, 76pt at least.
public struct SHCardSheetField<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .padding(SHCardSheetMetrics.fieldPadding)
            .frame(maxWidth: .infinity, minHeight: SHCardSheetMetrics.fieldMinHeight, alignment: .topLeading)
            .overlay { RoundedRectangle(cornerRadius: SH.Radius.m).strokeBorder(Color.sh.lineSubtle, lineWidth: 1) }
    }
}

/// A foot action: a word in `textPrimary` medium (`dim`: `textSecondary` regular, for the way out; `small`: a link in a label), or the ink pill.
public struct SHCardSheetActionStyle: ButtonStyle {
    public enum Kind: Sendable { case link, dim, small, pill }
    let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public func makeBody(configuration: Configuration) -> some View {
        SHCardSheetAction(configuration: configuration, kind: kind)
    }
}

extension ButtonStyle where Self == SHCardSheetActionStyle {
    public static func shCardSheet(_ kind: SHCardSheetActionStyle.Kind) -> SHCardSheetActionStyle { SHCardSheetActionStyle(kind) }
}

private struct SHCardSheetAction: View {
    let configuration: ButtonStyleConfiguration
    let kind: SHCardSheetActionStyle.Kind
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        let sh = Color.sh
        let M = SHCardSheetMetrics.self
        switch kind {
        case .pill:
            let pill = Capsule()
            configuration.label
                .font(.sh(.caption, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(sh.textOnPrimary)
                .padding(.horizontal, M.pillPadding)
                .frame(height: M.pillHeight)
                .background(configuration.isPressed ? sh.primaryPressed : hovering && enabled ? sh.primaryHover : sh.primary, in: pill)
                .contentShape(pill)
                .shEnabledOpacity(enabled)
                .onHover { hovering = $0 }
                .shAnimation(.hover, value: hovering)
                .shFocusRing(radius: M.pillHeight / 2)
        case .link, .dim, .small:
            configuration.label
                .font(kind == .small ? .sh(.caption, weight: .medium) : .sh(.ui, weight: kind == .link ? .medium : .regular))
                .lineLimit(1)
                .foregroundStyle(kind != .dim || hovering && enabled ? sh.textPrimary : sh.textSecondary)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
                .shEnabledOpacity(enabled)
                .onHover { hovering = $0 }
                .shFocusRing(radius: SH.Radius.xs)
        }
    }
}
#endif
