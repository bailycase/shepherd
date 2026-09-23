import SwiftUI

/// The subagent inspector's header (Agents board): the branch glyph in the run's state, its
/// name with "· 3 of 3", a mono meta line ending in a state-colored accent ("done 11:02"), and
/// the caller's controls on the trailing side.
public struct NWInspectorHeader<Trailing: View>: View {
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
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            NWBranchGlyph(state, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Text(title).font(.nwSans(13, .semibold)).foregroundStyle(nw.textPrimary))\(Text(position.map { " · \($0)" } ?? "").font(.nwSans(13)).foregroundStyle(nw.textSecondary))")
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Text("\(Text(meta))\(Text(accentText).foregroundStyle(state.textColor))")
                    .font(.nwMono(10.5))
                    .foregroundStyle(nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(meta + accentText)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: NW.Space.m)
            HStack(spacing: NW.Space.xs) { trailing() }
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.s)
        .frame(maxWidth: .infinity, minHeight: minHeight)
        .overlay(alignment: .bottom) { NWHairline() }
    }

    private var accentText: String {
        guard let accent else { return "" }
        return meta.isEmpty ? accent : " · \(accent)"
    }
}

/// A run's brief under the inspector header (Agents board): its GOAL (with an optional mono
/// note on the right, "step 1 / 1 · 62%"), and once it finished its RESULT in the state's color
/// followed by the caller's file links.
public struct NWRunBrief<Files: View>: View {
    let goal: String
    let note: String?
    let result: String?
    let resultState: AgentState
    @ViewBuilder let files: () -> Files

    public init(goal: String, note: String? = nil, result: String? = nil, resultState: AgentState = .done,
                @ViewBuilder files: @escaping () -> Files) {
        self.goal = goal
        self.note = note
        self.result = result
        self.resultState = resultState
        self.files = files
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                NWBriefLabel(text: "Goal")
                Spacer(minLength: NW.Space.m)
                if let note {
                    Text(note).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).monospacedDigit().lineLimit(1)
                        .nwContentTransition(.numeric())
                }
            }
            .nwAnimation(.content, value: note)
            Text(goal)
                .font(.nw(.ui, weight: .regular)).lineSpacing(NW.Space.xs)
                .foregroundStyle(nw.textSecondary)
                .lineLimit(6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    NWBriefLabel(text: "Result", color: resultState.textColor)
                    NWInlineText(text: result, codeSize: 11.5).equatable()
                        .font(.nw(.ui, weight: .regular)).lineSpacing(NW.Space.xs)
                        .foregroundStyle(nw.textPrimary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    files()
                }
                .nwTransition(.disclosure)
            }
        }
        .nwAnimation(.disclosure, value: result != nil)
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken)
    }
}

extension NWRunBrief where Files == EmptyView {
    public init(goal: String, note: String? = nil, result: String? = nil, resultState: AgentState = .done) {
        self.init(goal: goal, note: note, result: result, resultState: resultState) { EmptyView() }
    }
}

/// The bar under a finished run (Agents board): its actions (Re-run · Fork · Copy transcript)
/// on a hairline, with an optional trailing note.
public struct NWRunActions<Actions: View, Trailing: View>: View {
    @ViewBuilder let actions: () -> Actions
    @ViewBuilder let trailing: () -> Trailing

    public init(@ViewBuilder actions: @escaping () -> Actions, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.actions = actions
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.s) {
            actions()
            Spacer(minLength: NW.Space.m)
            trailing()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { NWHairline() }
    }
}

extension NWRunActions where Trailing == EmptyView {
    public init(@ViewBuilder actions: @escaping () -> Actions) {
        self.init(actions: actions) { EmptyView() }
    }
}
