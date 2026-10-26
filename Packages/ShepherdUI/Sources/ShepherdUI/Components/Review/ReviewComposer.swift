import SwiftUI

/// The review's composer (Review board): a raised card with a strong 1px line and radius 8. An
/// "Overall comment" field, then the inline comment count, Commit (secondary), and Request
/// changes (primary, ⌘⏎). Inline comments attach on their own; Request changes sends everything
/// as one message. Where the host commits from review (`onCommitDirectly`), Commit… opens the
/// commit sheet and the agent's commit reads "Ask agent to commit".
public struct SHReviewComposer: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let inlineCount: Int
    let canCommit: Bool
    let canRequestChanges: Bool
    let onCommit: () -> Void
    let onRequestChanges: () -> Void
    let onCommitDirectly: (() -> Void)?

    /// `onCommit` asks the agent to commit; `onCommitDirectly`, when the host commits from review,
    /// opens the commit sheet.
    public init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, inlineCount: Int, canCommit: Bool, canRequestChanges: Bool,
                onCommit: @escaping () -> Void, onRequestChanges: @escaping () -> Void, onCommitDirectly: (() -> Void)? = nil) {
        _text = text
        self.isFocused = isFocused
        self.inlineCount = inlineCount
        self.canCommit = canCommit
        self.canRequestChanges = canRequestChanges
        self.onCommit = onCommit
        self.onRequestChanges = onRequestChanges
        self.onCommitDirectly = onCommitDirectly
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: 0) {
            TextField("Overall comment", text: $text, prompt: Text("Overall comment").foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.shSans(13))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.lantern)
                .focused(isFocused)
                .padding(EdgeInsets(top: SHReviewComposer.fieldTop, leading: SH.Space.l, bottom: SH.Space.xxs, trailing: SH.Space.l))
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    if canRequestChanges { onRequestChanges() }
                    return .handled
                }
            HStack(spacing: SH.Space.s) {
                Text("\(inlineCount) inline")
                    .font(.sh(.micro, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .shContentTransition(.numeric())
                    .shAnimation(.content, value: inlineCount)
                    .padding(.horizontal, SH.Space.s)
                    .accessibilityLabel("\(inlineCount) inline comment\(inlineCount == 1 ? "" : "s")")
                Spacer(minLength: 0)
                if let onCommitDirectly {
                    Button("Ask agent to commit", action: onCommit)
                        .buttonStyle(.sh(.ghost, size: .s))
                        .disabled(!canCommit)
                        .help("Send the agent a turn asking it to commit these changes")
                    Button("Commit\u{2026}", action: onCommitDirectly)
                        .buttonStyle(.sh(.secondary, size: .s))
                        .disabled(!canCommit)
                        .help("Choose files and a message, then commit, push or open a pull request")
                } else {
                    Button("Commit", action: onCommit)
                        .buttonStyle(.sh(.secondary, size: .s))
                        .disabled(!canCommit)
                        .help("Ask the agent to commit these changes")
                }
                Button("Request changes", action: onRequestChanges)
                    .buttonStyle(.sh(.primary, size: .s))
                    .disabled(!canRequestChanges)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send the comments as the agent's next message (⌘⏎)")
            }
            .padding(SH.Space.s)
        }
        .shCard(radius: SH.Radius.m, line: sh.lineStrong)
        .shFocusRing(isFocused.wrappedValue, radius: SH.Radius.m)
    }

    static let fieldTop: CGFloat = 10
}
