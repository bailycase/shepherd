import SwiftUI

/// The subagent inspector's header (Agents board): the branch glyph in the run's state, its
/// name with "· 3 of 3", a mono meta line ending in a state-colored accent ("done 11:02"), and
/// the caller's controls on the trailing side.
public struct SHInspectorHeader<Trailing: View>: View {
    let title: String
    let position: String?
    let state: AgentState
    let meta: String
    let accent: String?
    let minHeight: CGFloat
    @ViewBuilder let trailing: () -> Trailing

    /// `minHeight` lets the pane line its header up with the thread's.
    public init(_ title: String, position: String? = nil, state: AgentState, meta: String, accent: String? = nil,
                minHeight: CGFloat = 44, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.position = position
        self.state = state
        self.meta = meta
        self.accent = accent
        self.minHeight = minHeight
        self.trailing = trailing
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            SHBranchGlyph(state, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(title).font(.shSans(13, .semibold)).foregroundStyle(sh.textPrimary))\(Text(position.map { " · \($0)" } ?? "").font(.shSans(13)).foregroundStyle(sh.textSecondary))")
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(Text(meta))\(Text(accentText).foregroundStyle(state.textColor))")
                    .font(.shMono(10.5))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(meta + accentText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: SH.Space.m)
            HStack(spacing: SH.Space.xs) { trailing() }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay(alignment: .bottom) { SHHairline() }
    }

    private var accentText: String {
        guard let accent else { return "" }
        return meta.isEmpty ? accent : " · \(accent)"
    }
}

/// A run's brief under the inspector header (Agents board): its GOAL (with an optional mono
/// note on the right, "step 1 / 1 · 62%"), and once it finished its RESULT in the state's color
/// followed by the caller's file links. A run that asked its parent shows its question under
/// "Asked the parent" in the place of the result.
public struct SHRunBrief<Files: View>: View {
    let goal: String
    let note: String?
    let result: String?
    let resultLabel: String
    let resultState: AgentState
    @ViewBuilder let files: () -> Files

    public init(goal: String, note: String? = nil, result: String? = nil, resultLabel: String = "Result",
                resultState: AgentState = .done, @ViewBuilder files: @escaping () -> Files) {
        self.goal = goal
        self.note = note
        self.result = result
        self.resultLabel = resultLabel
        self.resultState = resultState
        self.files = files
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                SHBriefLabel(text: "Goal")
                Spacer(minLength: SH.Space.m)
                if let note {
                    Text(note).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).monospacedDigit().lineLimit(1)
                        .shContentTransition(.numeric())
                }
            }
            .shAnimation(.content, value: note)
            Text(goal)
                .font(.sh(.ui, weight: .regular)).lineSpacing(SH.Space.xs)
                .foregroundStyle(sh.textSecondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    SHBriefLabel(text: resultLabel, color: resultState.textColor)
                    SHInlineText(text: result, codeSize: 11.5).equatable()
                        .font(.sh(.ui, weight: .regular)).lineSpacing(SH.Space.xs)
                        .foregroundStyle(sh.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    files()
                }
                .shTransition(.disclosure)
            }
        }
        .shAnimation(.disclosure, value: result != nil)
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgSunken)
    }
}

extension SHRunBrief where Files == EmptyView {
    public init(goal: String, note: String? = nil, result: String? = nil, resultLabel: String = "Result",
                resultState: AgentState = .done) {
        self.init(goal: goal, note: note, result: result, resultLabel: resultLabel, resultState: resultState) { EmptyView() }
    }
}

/// The bar under a finished run (Agents board): its actions (Re-run · Fork · Copy transcript)
/// on a hairline, with an optional trailing note.
public struct SHRunActions<Actions: View, Trailing: View>: View {
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let trailing: () -> Trailing

    public init(@ViewBuilder actions: @escaping () -> Actions, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.actions = actions
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            actions()
            Spacer(minLength: SH.Space.m)
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { SHHairline() }
    }
}

extension SHRunActions where Trailing == EmptyView {
    public init(@ViewBuilder actions: @escaping () -> Actions) {
        self.init(actions: actions) { EmptyView() }
    }
}
