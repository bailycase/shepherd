import SwiftUI

/// Unsent comments (ChangesStates › ReviewSendBar; ChangesSplit, iPadReview, iPadReviewSplit): a
/// `bgRaised` bar under a strong line, a bubble glyph, "1 comment" in semibold and "on outbox.go,
/// not sent yet", then Discard and Send to agent. It replaced the overall-comment box: anything
/// else is said in the thread. Only there while there are unsent comments. The Mac's bar is 48pt
/// with small buttons; the touch bar is 58pt with medium ones. At the accessibility sizes the
/// buttons move under the text.
public struct SHReviewSendBar: View {
    public enum Size: Sendable { case regular, touch }

    let count: String
    let detail: String
    let sending: Bool
    let size: Size
    let onDiscard: () -> Void
    let onSend: () -> Void
    /// Post the comments on GitHub as a review instead (a pull request's Changes tab).
    let onPost: (() -> Void)?
    /// The main button's words: "Send to agent", or "Post on GitHub" over a pull request's diff.
    let sendTitle: String
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(count: String, detail: String, sending: Bool = false, size: Size = .regular,
                sendTitle: String = "Send to agent", onDiscard: @escaping () -> Void, onSend: @escaping () -> Void,
                onPost: (() -> Void)? = nil) {
        self.onPost = onPost
        self.sendTitle = sendTitle
        self.count = count
        self.detail = detail
        self.sending = sending
        self.size = size
        self.onDiscard = onDiscard
        self.onSend = onSend
    }

    public var body: some View {
        let sh = Color.sh
        let stacked = typeSize.isAccessibilitySize
        let buttons: SHButtonStyle.Size = size == .touch ? .m : .s
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: SH.Space.m)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.sh(.ui))
                    .foregroundStyle(sh.running)
                    .accessibilityHidden(true)
                Text("\(Text(count).fontWeight(.semibold).foregroundStyle(sh.textPrimary)) \(Text(detail).foregroundStyle(sh.textSecondary))")
                    .font(.sh(.ui))
                    .lineLimit(stacked ? nil : 1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            if !stacked { Spacer(minLength: SH.Space.m) }
            HStack(spacing: SH.Space.s) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.sh(.ghost, size: buttons))
                    .disabled(sending)
                    .accessibilityHint("Deletes the comments you haven't sent")
                if let onPost {
                    Button("Comment on GitHub", action: onPost)
                        .buttonStyle(.sh(.secondary, size: buttons))
                        .disabled(sending)
                        .help("Post your comments on the pull request as a review")
                }
                Button(action: onSend) {
                    HStack(spacing: SH.Space.s) {
                        if sending { ProgressView().progressViewStyle(.shSpinner(size: 10)) }
                        // The Mac's main action draws its chord; touch has no ⌘↩ to teach.
                        if size == .regular { SHButtonTitle(sendTitle, chord: "⌘↩") } else { Text(sendTitle) }
                    }
                }
                .buttonStyle(.sh(.primary, size: buttons))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending)
                .help("\(sendTitle) (⌘↩)")
                .accessibilityHint(sendTitle == "Send to agent" ? "Sends your comments as the agent's next message" : sendTitle)
            }
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, stacked ? SH.Space.s : 0)
        .frame(maxWidth: .infinity, minHeight: size == .touch ? SHChangesMetrics.touchSendBarHeight : SHChangesMetrics.sendBarHeight,
               alignment: .leading)
        .background(sh.bgRaised)
        .overlay(alignment: .top) { SHHairline(color: sh.lineStrong) }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Review send bar") {
    SHPreviewBoth {
        VStack(spacing: 0) {
            SHReviewSendBar(count: "1 comment", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
            SHReviewSendBar(count: "1 comment", detail: "on outbox.go, not sent yet", size: .touch, onDiscard: {}, onSend: {})
        }
        .frame(width: 620)
    }
}
