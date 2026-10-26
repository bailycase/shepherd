import SwiftUI

// The composer's touch parts (MobileThread, MobileQueue, iPadPortrait boards): the phone's
// capsule field with its action inside, and the slash-command list that opens above the
// composer while a draft is "/…". The iPad keeps the Mac's card (`SHComposer`) with its row of
// chips.

public enum SHTouchComposerMetrics {
    /// The capsule's minimum height, and the round attach button beside it.
    public static let capsuleHeight: CGFloat = SH.Height.touch
    /// The action's circle inside the capsule.
    public static let actionSize: CGFloat = SH.Height.controlL
    /// A command row's minimum height.
    public static let commandRowHeight: CGFloat = SH.Height.touch
    /// Command rows the list shows before it scrolls.
    public static let commandRows = 5
    /// The command name's column on a wide composer (iPad); a phone stacks name over description.
    public static let commandNameWidth: CGFloat = 180
}

/// The phone's field (MobileThread, MobileSteer boards): one glass capsule (the system material)
/// with the paperclip at its leading edge, the field growing to a few lines, and the context
/// ring and action (Send or Stop) at its trailing end. Chips sit above it, in the app.
public struct SHCapsuleComposer<Leading: View, Field: View, Action: View>: View {
    let leading: Leading?
    let field: Field
    let action: Action

    public init(@ViewBuilder leading: () -> Leading, @ViewBuilder field: () -> Field, @ViewBuilder action: () -> Action) {
        self.leading = leading()
        self.field = field()
        self.action = action()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: SHTouchComposerMetrics.capsuleHeight / 2)
        HStack(alignment: .bottom, spacing: 0) {
            if let leading {
                leading.frame(minHeight: SHTouchComposerMetrics.capsuleHeight)
            }
            field
                .padding(.vertical, SH.Space.m)
                .padding(.leading, leading == nil ? SH.Space.xl : 0)
                .frame(minHeight: SHTouchComposerMetrics.capsuleHeight, alignment: .leading)
            action
                .frame(minHeight: SHTouchComposerMetrics.capsuleHeight)
        }
        .padding(.horizontal, SH.Space.xxs)
        .glassEffect(.regular, in: shape)
    }
}

extension SHCapsuleComposer where Leading == EmptyView {
    /// A capsule with no paperclip (the host takes no images).
    public init(@ViewBuilder field: () -> Field, @ViewBuilder action: () -> Action) {
        self.leading = nil
        self.field = field()
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
    let wide: Bool
    let onChoose: (SHTouchCommand) -> Void

    public init(commands: [SHTouchCommand], total: Int, query: String, wide: Bool, onChoose: @escaping (SHTouchCommand) -> Void) {
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
                Text("Commands").shSectionLabel().foregroundStyle(sh.textTertiary)
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
