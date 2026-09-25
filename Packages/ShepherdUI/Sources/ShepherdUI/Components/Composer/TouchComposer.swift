import SwiftUI

// The composer's touch parts (MobileThread, MobileQueue, iPadPortrait boards): the phone's
// capsule field with its action inside, and the slash-command list that opens above the
// composer while a draft is "/…". The iPad keeps the Mac's card (`NWComposer`) with its row of
// chips.

public enum NWTouchComposerMetrics {
    /// The capsule's minimum height, and the round attach button beside it.
    public static let capsuleHeight: CGFloat = NW.Height.touch
    /// The action's circle inside the capsule.
    public static let actionSize: CGFloat = NW.Height.controlL
    /// A command row's minimum height.
    public static let commandRowHeight: CGFloat = NW.Height.touch
    /// Command rows the list shows before it scrolls.
    public static let commandRows = 5
    /// The command name's column on a wide composer (iPad); a phone stacks name over description.
    public static let commandNameWidth: CGFloat = 180
}

/// The phone's field (MobileThread board): a capsule on `bgRaised` with a `lineStrong` line
/// (`textTertiary` while focused), the field growing to a few lines, and the action (Send or
/// Stop) inside its trailing end. Attachments and chips sit above it, in the app.
public struct NWCapsuleComposer<Field: View, Action: View>: View {
    let isFocused: Bool
    let field: Field
    let action: Action

    public init(isFocused: Bool, @ViewBuilder field: () -> Field, @ViewBuilder action: () -> Action) {
        self.isFocused = isFocused
        self.field = field()
        self.action = action()
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NWTouchComposerMetrics.capsuleHeight / 2)
        HStack(alignment: .bottom, spacing: NW.Space.s) {
            field
                .padding(.vertical, NW.Space.m)
                .frame(minHeight: NWTouchComposerMetrics.capsuleHeight, alignment: .leading)
            action
                .frame(minHeight: NWTouchComposerMetrics.capsuleHeight)
        }
        .padding(.leading, NW.Space.xl)
        .padding(.trailing, NW.Space.s)
        .background(nw.bgRaised, in: shape)
        .overlay {
            Color.clear
                .nwBorder(isFocused ? nw.textTertiary : nw.lineStrong, in: shape)
                .nwAnimation(.hover, value: isFocused)
                .allowsHitTesting(false)
        }
    }
}

/// A slash command as the touch list draws it.
public struct NWTouchCommand: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var description: String?
    /// "prompt" or "skill"; none for an extension command.
    public var tag: String?

    public init(name: String, description: String? = nil, tag: String? = nil) {
        self.name = name
        self.description = description
        self.tag = tag
    }
}

/// The commands a "/…" draft matches (iPadPortrait board): "Commands" and "n of m", then one
/// 44pt row per command, the typed prefix in semibold. A phone stacks each name over its
/// description; a wide composer puts them side by side. Past `commandRows` rows it scrolls.
public struct NWTouchCommandList: View {
    let commands: [NWTouchCommand]
    let total: Int
    let query: String
    let wide: Bool
    let onChoose: (NWTouchCommand) -> Void

    public init(commands: [NWTouchCommand], total: Int, query: String, wide: Bool, onChoose: @escaping (NWTouchCommand) -> Void) {
        self.commands = commands
        self.total = total
        self.query = query
        self.wide = wide
        self.onChoose = onChoose
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Commands").nwSectionLabel().foregroundStyle(nw.textTertiary)
                Spacer(minLength: NW.Space.m)
                Text("\(commands.count) of \(total)").font(.nw(.mono)).foregroundStyle(nw.textTertiary).monospacedDigit()
            }
            .padding(.horizontal, NW.Space.l)
            .padding(.top, NW.Space.m)
            .padding(.bottom, NW.Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if commands.isEmpty {
                Text("No command matches").font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textTertiary)
                    .padding(.horizontal, NW.Space.l)
                    .frame(minHeight: NWTouchComposerMetrics.commandRowHeight)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(commands) { command in
                            Button { onChoose(command) } label: { row(command) }
                                .buttonStyle(.nwRow(radius: NW.Radius.s))
                                .accessibilityLabel("/\(command.name)" + (command.description.map { ", \($0)" } ?? ""))
                        }
                    }
                    .padding(.horizontal, NW.Space.xs)
                    .padding(.bottom, NW.Space.xs)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: CGFloat(NWTouchComposerMetrics.commandRows) * NWTouchComposerMetrics.commandRowHeight + NW.Space.xs)
                .fixedSize(horizontal: false, vertical: commands.count <= NWTouchComposerMetrics.commandRows)
            }
        }
        .background(nw.bgRaised, in: shape)
        .clipShape(shape)
        .nwBorder(nw.lineStrong, radius: NW.Radius.l)
    }

    @ViewBuilder private func row(_ command: NWTouchCommand) -> some View {
        let nw = Color.nw
        // Only a name that starts with the query shows it typed; one that merely contains it is plain.
        let prefix = command.name.lowercased().hasPrefix(query.lowercased()) ? query.count : 0
        let typed = Text(String(command.name.prefix(prefix))).fontWeight(.semibold).foregroundStyle(nw.textPrimary)
        let rest = Text(String(command.name.dropFirst(prefix))).foregroundStyle(nw.textSecondary)
        let name = Text("\(Text("/").foregroundStyle(nw.textSecondary))\(typed)\(rest)")
        let layout = wide
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: NW.Space.l))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: NW.Space.xxs))
        HStack(spacing: NW.Space.m) {
            layout {
                name.font(.nw(.code)).lineLimit(1)
                    .frame(width: wide ? NWTouchComposerMetrics.commandNameWidth : nil, alignment: .leading)
                if let description = command.description {
                    Text(description).font(.nw(wide ? .ui : .caption, weight: .regular)).foregroundStyle(nw.textSecondary)
                        .lineLimit(wide ? 1 : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let tag = command.tag {
                Text(tag).font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                    .padding(.horizontal, NW.Space.s)
                    .padding(.vertical, NW.Space.xxs)
                    .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.xs))
            }
        }
        .padding(.horizontal, NW.Space.m)
        .padding(.vertical, NW.Space.s)
        .frame(minHeight: NWTouchComposerMetrics.commandRowHeight)
        .contentShape(Rectangle())
    }
}
