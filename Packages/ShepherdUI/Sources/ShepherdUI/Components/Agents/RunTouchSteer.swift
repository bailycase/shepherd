import SwiftUI

/// A run's brief for touch (MobileSubagent, iPadSubagents boards): a raised card, "Goal · from the parent" over
/// the task, a note on the right while it runs ("Step 1 of 3 · 34%"), and once finished its
/// Result (inline Markdown) under a label in the state's color.
public struct SHRunGoal: View {
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
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.xxl)
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.shSans(SHTouchQueueMetrics.headerSize)).foregroundStyle(sh.textSecondary)
                Spacer(minLength: SH.Space.m)
                if let note {
                    Text(note).font(.shSans(SHTouchQueueMetrics.headerSize)).foregroundStyle(sh.textTertiary).monospacedDigit().lineLimit(1)
                }
            }
            Text(goal)
                .shText(.ui)
                .fontWeight(.regular)
                .foregroundStyle(sh.textPrimary)
                .lineLimit(8)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let result {
                Text("Result").font(.shSans(SHTouchQueueMetrics.headerSize, .medium)).foregroundStyle(resultState.textColor)
                    .padding(.top, SH.Space.xs)
                SHInlineText(text: result, codeSize: SHTextStyle.caption.size).equatable()
                    .shText(.ui)
                    .fontWeight(.regular)
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.vertical, SH.Space.l + SH.Space.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shBorder(sh.lineSubtle, radius: SH.Radius.xxl)
        .shLift(shape)
        .accessibilityElement(children: .combine)
    }
}

/// The field that steers one run (MobileSubagent board): a pill with Send inside it,
/// growing to five lines, and a caption under it saying who it reaches ("Goes to worker, not
/// the parent. It lands before its next turn."). Return adds a line; Send sends.
public struct SHSteerField: View {
    @Binding var text: String
    let prompt: String
    let caption: String?
    let isEnabled: Bool
    let focus: FocusState<Bool>.Binding?
    let accessibilityText: String
    let sendLabel: String
    let send: () -> Void
    @FocusState private var ownFocus: Bool

    /// `sendLabel` is what VoiceOver calls the field's button: "Send", or "Reply" for a run
    /// that was waiting on its parent.
    public init(text: Binding<String>, prompt: String, caption: String? = nil, isEnabled: Bool = true,
                focus: FocusState<Bool>.Binding? = nil, accessibilityLabel: String? = nil, sendLabel: String = "Send",
                send: @escaping () -> Void) {
        _text = text
        self.prompt = prompt
        self.caption = caption
        self.isEnabled = isEnabled
        self.focus = focus
        accessibilityText = accessibilityLabel ?? prompt
        self.sendLabel = sendLabel
        self.send = send
    }

    private var isFocused: Bool { focus?.wrappedValue ?? ownFocus }
    private var sendable: Bool { isEnabled && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SHRunTouchMetrics.steerHeight / 2)
        VStack(alignment: .center, spacing: SH.Space.m) {
            HStack(alignment: .bottom, spacing: SH.Space.m) {
                field
                    .font(.sh(.body))
                    .foregroundStyle(sh.textPrimary)
                    .tint(sh.lantern)
                    .lineLimit(1...5)
                    .padding(.vertical, (SHRunTouchMetrics.steerHeight - SHTextStyle.body.size * SHTextStyle.body.lineHeight) / 2)
                    .accessibilityLabel(accessibilityText)
                SHComposerActionButton(.send, enabled: sendable, action: send)
                    .padding(.bottom, (SHRunTouchMetrics.steerHeight - SHComposerMetrics.actionSize) / 2)
                    .accessibilityLabel(sendLabel)
            }
            .padding(.leading, SH.Space.xl)
            .padding(.trailing, SHTouchComposerMetrics.trailingPadding)
            .frame(minHeight: SHRunTouchMetrics.steerHeight)
            .background(sh.bgRaised, in: shape)
            .shBorder(isFocused ? sh.textTertiary : sh.lineSubtle, in: shape)
            .shLift(shape)
            .shAnimation(.hover, value: isFocused)
            if let caption {
                Text(caption).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.m)
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
