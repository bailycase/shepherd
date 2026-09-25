import SwiftUI

/// A run's brief for touch (MobileSubagent, iPadSubagents boards): "GOAL · FROM THE PARENT" over
/// the task, a mono note on the right while it runs ("step 1 of 3 · 62%"), and once finished its
/// RESULT (inline Markdown) under a label in the state's color.
public struct NWRunGoal: View {
    let goal: String
    let label: String
    let note: String?
    let result: String?
    let resultState: AgentState

    public init(goal: String, label: String = "Goal · from the parent", note: String? = nil, result: String? = nil,
                resultState: AgentState = .done) {
        self.goal = goal
        self.label = label
        self.note = note
        self.result = result
        self.resultState = resultState
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            HStack(alignment: .firstTextBaseline) {
                NWBriefLabel(text: label)
                Spacer(minLength: NW.Space.m)
                if let note {
                    Text(note).font(.nw(.micro)).foregroundStyle(nw.textTertiary).monospacedDigit().lineLimit(1)
                }
            }
            Text(goal)
                .nwText(.ui)
                .fontWeight(.regular)
                .foregroundStyle(nw.textPrimary)
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                NWBriefLabel(text: "Result", color: resultState.textColor)
                    .padding(.top, NW.Space.xs)
                NWInlineText(text: result, codeSize: NWTextStyle.caption.size).equatable()
                    .nwText(.ui)
                    .fontWeight(.regular)
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.l))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.l)
        .accessibilityElement(children: .combine)
    }
}

/// The field that steers one run (MobileSubagent board): a rounded field with Send inside it,
/// growing to five lines, and a mono caption under it saying who it reaches ("to: worker · not
/// the parent · lands before its next turn"). Return adds a line; Send sends.
public struct NWSteerField: View {
    @Binding var text: String
    let prompt: String
    let caption: String?
    let isEnabled: Bool
    let focus: FocusState<Bool>.Binding?
    let accessibilityText: String
    let send: () -> Void
    @FocusState private var ownFocus: Bool

    public init(text: Binding<String>, prompt: String, caption: String? = nil, isEnabled: Bool = true,
                focus: FocusState<Bool>.Binding? = nil, accessibilityLabel: String? = nil, send: @escaping () -> Void) {
        _text = text
        self.prompt = prompt
        self.caption = caption
        self.isEnabled = isEnabled
        self.focus = focus
        accessibilityText = accessibilityLabel ?? prompt
        self.send = send
    }

    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }
    private var sendable: Bool { isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NWRunTouchMetrics.steerHeight / 2)
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(alignment: .bottom, spacing: NW.Space.m) {
                field
                    .font(.nw(.body))
                    .foregroundStyle(nw.textPrimary)
                    .tint(nw.lantern)
                    .lineLimit(1...5)
                    .padding(.vertical, NW.Space.m + NW.Space.xxs)
                    .accessibilityLabel(accessibilityText)
                NWComposerActionButton(.send, enabled: sendable, action: send)
                    .padding(.bottom, NW.Space.s + NW.Space.xxs)
                    .accessibilityLabel("Send")
            }
            .padding(.leading, NW.Space.xl)
            .padding(.trailing, NW.Space.s + NW.Space.xxs)
            .frame(minHeight: NWRunTouchMetrics.steerHeight)
            .background(nw.bgRaised, in: shape)
            .nwBorder(isFocused ? nw.textTertiary : nw.lineStrong, in: shape)
            .nwAnimation(.hover, value: isFocused)
            if let caption {
                Text(caption).font(.nw(.micro)).foregroundStyle(nw.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.m)
            }
        }
    }

    @ViewBuilder private var field: some View {
        if let focus {
            TextField(prompt, text: $text, axis: .vertical).textFieldStyle(.plain).focused(focus)
        } else {
            TextField(prompt, text: $text, axis: .vertical).textFieldStyle(.plain).focused($ownFocus)
        }
    }
}
