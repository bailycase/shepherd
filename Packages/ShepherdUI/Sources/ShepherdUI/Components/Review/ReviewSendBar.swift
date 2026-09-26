import SwiftUI

/// Unsent comments (ChangesStates › ReviewSendBar; ChangesSplit, iPadReview, iPadReviewSplit): a
/// `bgRaised` bar under a strong line, a bubble glyph, "1 comment" in semibold and "on outbox.go,
/// not sent yet", then Discard and Send to agent. It replaced the overall-comment box: anything
/// else is said in the thread. Only there while there are unsent comments. The Mac's bar is 48pt
/// with small buttons; the touch bar is 58pt with medium ones. At the accessibility sizes the
/// buttons move under the text.
public struct NWReviewSendBar: View {
    public enum Size: Sendable { case regular, touch }

    let count: String
    let detail: String
    let sending: Bool
    let size: Size
    let onDiscard: () -> Void
    let onSend: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(count: String, detail: String, sending: Bool = false, size: Size = .regular,
                onDiscard: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.count = count
        self.detail = detail
        self.sending = sending
        self.size = size
        self.onDiscard = onDiscard
        self.onSend = onSend
    }

    public var body: some View {
        let nw = Color.nw
        let stacked = typeSize.isAccessibilitySize
        let buttons: NWButtonStyle.Size = size == .touch ? .m : .s
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: NW.Space.m)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.nw(.ui))
                    .foregroundStyle(nw.running)
                    .accessibilityHidden(true)
                Text("\(Text(count).fontWeight(.semibold).foregroundStyle(nw.textPrimary)) \(Text(detail).foregroundStyle(nw.textSecondary))")
                    .font(.nw(.ui))
                    .lineLimit(stacked ? nil : 1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            if !stacked { Spacer(minLength: NW.Space.m) }
            HStack(spacing: NW.Space.s) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.nw(.ghost, size: buttons))
                    .disabled(sending)
                    .accessibilityHint("Deletes the comments you haven't sent")
                Button(action: onSend) {
                    HStack(spacing: NW.Space.s) {
                        if sending { ProgressView().progressViewStyle(.nwSpinner(size: 10)) }
                        Text("Send to agent")
                    }
                }
                .buttonStyle(.nw(.primary, size: buttons))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending)
                .help("Send your comments as the agent's next message (⌘↩)")
                .accessibilityHint("Sends your comments as the agent's next message")
            }
            .fixedSize()
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, stacked ? NW.Space.s : 0)
        .frame(maxWidth: .infinity, minHeight: size == .touch ? NWChangesMetrics.touchSendBarHeight : NWChangesMetrics.sendBarHeight,
               alignment: .leading)
        .background(nw.bgRaised)
        .overlay(alignment: .top) { NWHairline(color: nw.lineStrong) }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Review send bar") {
    NWPreviewBoth {
        VStack(spacing: 0) {
            NWReviewSendBar(count: "1 comment", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
            NWReviewSendBar(count: "1 comment", detail: "on outbox.go, not sent yet", size: .touch, onDiscard: {}, onSend: {})
        }
        .frame(width: 620)
    }
}
