import SwiftUI

/// The review's composer (Review board): a raised card with a strong 1px line and radius 8. An
/// "Overall comment" field, then the inline comment count, Commit (secondary), and Request
/// changes (primary, ⌘⏎). Inline comments attach on their own; Request changes sends everything
/// as one message.
public struct NWReviewComposer: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let inlineCount: Int
    let canCommit: Bool
    let canRequestChanges: Bool
    let onCommit: () -> Void
    let onRequestChanges: () -> Void

    public init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, inlineCount: Int, canCommit: Bool, canRequestChanges: Bool,
                onCommit: @escaping () -> Void, onRequestChanges: @escaping () -> Void) {
        _text = text
        self.isFocused = isFocused
        self.inlineCount = inlineCount
        self.canCommit = canCommit
        self.canRequestChanges = canRequestChanges
        self.onCommit = onCommit
        self.onRequestChanges = onRequestChanges
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: 0) {
            TextField("Overall comment", text: $text, prompt: Text("Overall comment").foregroundStyle(nw.textTertiary), axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.nwSans(13))
                .foregroundStyle(nw.textPrimary)
                .tint(nw.lantern)
                .focused(isFocused)
                .padding(EdgeInsets(top: NWReviewComposer.fieldTop, leading: NW.Space.l, bottom: NW.Space.xxs, trailing: NW.Space.l))
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if canRequestChanges { onRequestChanges() }
                    return .handled
                }
            HStack(spacing: NW.Space.s) {
                Text("\(inlineCount) inline")
                    .font(.nw(.micro, weight: .regular))
                    .foregroundStyle(nw.textTertiary)
                    .padding(.horizontal, NW.Space.s)
                    .accessibilityLabel("\(inlineCount) inline comment\(inlineCount == 1 ? "" : "s")")
                Spacer(minLength: 0)
                Button("Commit", action: onCommit)
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(!canCommit)
                    .help("Ask the agent to commit these changes")
                Button("Request changes", action: onRequestChanges)
                    .buttonStyle(.nw(.primary, size: .s))
                    .disabled(!canRequestChanges)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send the comments as the agent's next message (⌘⏎)")
            }
            .padding(NW.Space.s)
        }
        .nwCard(radius: NW.Radius.m, line: nw.lineStrong)
        .nwFocusRing(isFocused.wrappedValue, radius: NW.Radius.m)
    }

    static let fieldTop: CGFloat = 10
}
