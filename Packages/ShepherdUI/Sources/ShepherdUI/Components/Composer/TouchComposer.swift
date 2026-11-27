import SwiftUI

// The composer's touch parts (MobileThread, MobileQueue, iPadThread, DuoClosedThread boards): the
// one-line pill with its action inside, on every touch screen, and the slash-command list that
// opens above the composer while a draft is "/…".

public enum SHTouchComposerMetrics {
    /// The pill's minimum height (the boards' `.gt-cmp`: 52, a full-radius capsule).
    public static let capsuleHeight: CGFloat = 52
    /// The attach button's circle at the pill's leading end.
    public static let attachSize: CGFloat = 42
    /// The + glyph in it.
    public static let plusGlyph: CGFloat = 22
    /// The action's circle inside the pill (`SHComposerMetrics.actionSize`).
    public static let actionSize: CGFloat = SHComposerMetrics.actionSize
    /// The pill's padding: 4 before the attach button, 6 after the action; 6 between its parts.
    public static let leadingPadding: CGFloat = SH.Space.xs
    public static let trailingPadding: CGFloat = SH.Space.s
    public static let gap: CGFloat = SH.Space.s
    /// The model chip's text (the boards' 13).
    public static let chipSize: CGFloat = 13
    /// A command row's minimum height.
    public static let commandRowHeight: CGFloat = SH.Height.touch
    /// Command rows the list shows before it scrolls.
    public static let commandRows = 5
    /// The command name's column on a wide composer (iPad); a phone stacks name over description.
    public static let commandNameWidth: CGFloat = 180
}

/// The thread's field on every touch screen (MobileThread, MobileQueue, iPadThread, DuoClosedThread boards): one pill, the
/// attach button at its leading edge, the words growing to a few lines, the model chip, then the
/// context ring and action (Send or Stop). A flat `bgRaised` capsule on the `lift` shadow with a
/// hairline, never live glass. Everything else the composer offers (commands, thinking level, speed)
/// opens from the attach button and the model chip.
public struct SHCapsuleComposer<Leading: View, Field: View, Trailing: View, Action: View>: View {
    let leading: Leading?
    let field: Field
    let trailing: Trailing
    let action: Action
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder field: () -> Field, @ViewBuilder trailing: () -> Trailing,
                @ViewBuilder action: () -> Action) {
        self.leading = leading()
        self.field = field()
        self.trailing = trailing()
        self.action = action()
    }

    public var body: some View {
        let M = SHTouchComposerMetrics.self
        let shape = RoundedRectangle(cornerRadius: M.capsuleHeight / 2)
        Group {
            if typeSize.isAccessibilitySize {
                // From the accessibility sizes the words take the pill's whole width and the buttons sit in a row under them: beside
                // the model's name the field was a few letters wide.
                VStack(alignment: .leading, spacing: 0) {
                    field
                        .padding(.vertical, SH.Space.m)
                        .padding(.horizontal, SH.Space.xl - M.leadingPadding)
                        .frame(maxWidth: .infinity, minHeight: M.capsuleHeight, alignment: .leading)
                    HStack(alignment: .center, spacing: M.gap) {
                        if let leading {
                            leading.frame(minWidth: M.attachSize, minHeight: M.capsuleHeight)
                        }
                        Spacer(minLength: 0)
                        trailing
                            .frame(minHeight: M.capsuleHeight)
                            .layoutPriority(1)
                        action
                            .frame(minHeight: M.capsuleHeight)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: M.gap) {
                    if let leading {
                        leading.frame(minWidth: M.attachSize, minHeight: M.capsuleHeight)
                    }
                    field
                        .padding(.vertical, (M.capsuleHeight - SHTextStyle.body.size * SHTextStyle.body.lineHeight) / 2)
                        .padding(.leading, leading == nil ? SH.Space.xl - M.leadingPadding : 0)
                        .frame(minHeight: M.capsuleHeight, alignment: .leading)
                    // The model's name is read whole; the words give way to it.
                    trailing
                        .frame(minHeight: M.capsuleHeight)
                        .layoutPriority(1)
                    action
                        .frame(minHeight: M.capsuleHeight)
                }
            }
        }
        .padding(.leading, M.leadingPadding)
        .padding(.trailing, M.trailingPadding)
        .background(Color.sh.bgRaised, in: shape)
        .shBorder(Color.sh.lineSubtle, radius: M.capsuleHeight / 2)
        .shLift(shape)
    }
}

extension SHCapsuleComposer where Trailing == EmptyView {
    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder field: () -> Field, @ViewBuilder action: () -> Action) {
        self.init(leading: leading, field: field, trailing: { EmptyView() }, action: action)
    }
}

extension SHCapsuleComposer where Leading == EmptyView, Trailing == EmptyView {
    /// A capsule with no attach button (the host takes no images and offers no commands).
    public init(@ViewBuilder field: () -> Field, @ViewBuilder action: () -> Action) {
        self.leading = nil
        self.field = field()
        self.trailing = EmptyView()
        self.action = action()
    }
}

extension SHCapsuleComposer where Leading == EmptyView {
    public init(@ViewBuilder field: () -> Field, @ViewBuilder trailing: () -> Trailing, @ViewBuilder action: () -> Action) {
        self.leading = nil
        self.field = field()
        self.trailing = trailing()
        self.action = action()
    }
}

/// A slash command as the touch list draws it.
public struct SHTouchCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// A prompt template's argument hint ("[session]"), drawn after the name.
    public var arguments: String?
    /// "prompt" or "skill"; none for an extension command.
    public var tag: String?

    public init(name: String, description: String? = nil, arguments: String? = nil, tag: String? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.tag = tag
    }
}

/// The commands a "/…" draft matches (iPadPortrait board): "Commands" and "n of m", then one
/// 44pt row per command, the typed prefix in semibold. A phone stacks each name over its
/// description; a wide composer puts them side by side. Past `commandRows` rows it scrolls.
public struct SHTouchCommandList: View {
    let commands: [SHTouchCommand]
    let total: Int
    let query: String
    let title: String
    let wide: Bool
    let onChoose: (SHTouchCommand) -> Void

    public init(commands: [SHTouchCommand], total: Int, query: String, title: String = "Commands", wide: Bool,
                onChoose: @escaping (SHTouchCommand) -> Void) {
        self.title = title
        self.commands = commands
        self.total = total
        self.query = query
        self.wide = wide
        self.onChoose = onChoose
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.l)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).shSectionLabel().foregroundStyle(sh.textTertiary)
                Spacer(minLength: SH.Space.m)
                Text("\(commands.count) of \(total)").font(.sh(.mono)).foregroundStyle(sh.textTertiary).monospacedDigit()
            }
            .padding(.horizontal, SH.Space.l)
            .padding(.top, SH.Space.m)
            .padding(.bottom, SH.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if commands.isEmpty {
                Text("No command matches").font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                    .padding(.horizontal, SH.Space.l)
                    .frame(minHeight: SHTouchComposerMetrics.commandRowHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(commands) { command in
                            Button { onChoose(command) } label: { row(command) }
                                .buttonStyle(.shRow(radius: SH.Radius.s))
                                .accessibilityLabel("/\(command.name)" + (command.arguments.map { " \($0)" } ?? "")
                                                    + (command.description.map { ", \($0)" } ?? ""))
                        }
                    }
                    .padding(.horizontal, SH.Space.xs)
                    .padding(.bottom, SH.Space.xs)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: CGFloat(SHTouchComposerMetrics.commandRows) * SHTouchComposerMetrics.commandRowHeight + SH.Space.xs)
                .fixedSize(horizontal: false, vertical: commands.count <= SHTouchComposerMetrics.commandRows)
            }
        }
        .background(sh.bgRaised, in: shape)
        .clipShape(shape)
        .shBorder(sh.lineStrong, radius: SH.Radius.l)
    }

    @ViewBuilder private func row(_ command: SHTouchCommand) -> some View {
        let sh = Color.sh
        // Only a name that starts with the query shows it typed; one that merely contains it is plain.
        let prefix = command.name.lowercased().hasPrefix(query.lowercased()) ? query.count : 0
        let typed = Text(String(command.name.prefix(prefix))).fontWeight(.semibold).foregroundStyle(sh.textPrimary)
        let rest = Text(String(command.name.dropFirst(prefix))).foregroundStyle(sh.textSecondary)
        let arguments = Text(command.arguments.map { " " + $0 } ?? "").foregroundStyle(sh.textTertiary)
        let name = Text("\(Text("/").foregroundStyle(sh.textSecondary))\(typed)\(rest)\(arguments)")
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: SH.Space.l))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.xxs))
        HStack(spacing: SH.Space.m) {
            layout {
                name.font(.sh(.code)).lineLimit(1)
                    .frame(width: wide ? SHTouchComposerMetrics.commandNameWidth : nil, alignment: .leading)
                if let description = command.description {
                    Text(description).font(.sh(wide ? .ui : .caption, weight: .regular)).foregroundStyle(sh.textSecondary)
                        .lineLimit(wide ? 1 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = command.tag {
                Text(tag).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    .padding(.horizontal, SH.Space.s)
                    .padding(.vertical, SH.Space.xxs)
                    .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.xs))
            }
        }
        .padding(.horizontal, SH.Space.m)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: SHTouchComposerMetrics.commandRowHeight)
        .contentShape(Rectangle())
    }
}
