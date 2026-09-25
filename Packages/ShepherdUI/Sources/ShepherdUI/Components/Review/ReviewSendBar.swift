import SwiftUI

/// The bar under a review with comments not yet sent (ChangesStates › ReviewSendBar;
/// iPadReview, iPadReviewSplit): a bubble glyph, "1 comment" in semibold and "on outbox.go, not
/// sent yet", then Discard and Send to agent. It replaced the overall-comment box: anything else
/// is said in the thread. At the accessibility sizes the buttons move under the text.
public struct NWReviewSendBar: View {
    let count: String
    let detail: String
    let sending: Bool
    let onDiscard: () -> Void
    let onSend: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(count: String, detail: String, sending: Bool = false, onDiscard: @escaping () -> Void, onSend: @escaping () -> Void) {
        self.count = count
        self.detail = detail
        self.sending = sending
        self.onDiscard = onDiscard
        self.onSend = onSend
    }

    public var body: some View {
        let nw = Color.nw
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: NW.Space.m)) : AnyLayout(HStackLayout(spacing: NW.Space.m))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
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
            if !stacked { Spacer(minLength: NW.Space.s) }
            HStack(spacing: NW.Space.s) {
                Button("Discard", action: onDiscard)
                    .buttonStyle(.nw(.ghost, size: .l))
                    .disabled(sending)
                    .accessibilityHint("Deletes the comments you haven't sent")
                Button("Send to agent", action: onSend)
                    .buttonStyle(.nw(.primary, size: .l))
                    .disabled(sending)
                    .accessibilityHint("Sends your comments as the agent's next message")
            }
            .fixedSize()
        }
        .padding(.leading, NW.Space.l + NW.Space.xxs)
        .padding(.trailing, NW.Space.m)
        .padding(.vertical, NW.Space.s)
        .frame(maxWidth: .infinity, minHeight: NW.Height.touch + NW.Space.l, alignment: .leading)
        .background(nw.bgWindow)
        .overlay(alignment: .top) { NWHairline() }
    }
}

#Preview("Review send bar") {
    NWPreviewBoth {
        NWReviewSendBar(count: "1 comment", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
            .frame(width: 620)
    }
}
