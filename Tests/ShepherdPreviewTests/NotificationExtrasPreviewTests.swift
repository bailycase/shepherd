import Foundation
import ShepherdCore
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The notification follow-ups' new controls, in light and dark. Both sit in system chrome a test can't open (a
/// Mac menu, the buttons under an opened push), so a card stands in for the chrome and draws the items with the
/// titles and glyphs the code gives them.
@Suite("Notification extras previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct NotificationExtrasPreviewTests {
    private func item(_ title: String, _ symbol: String? = nil) -> some View {
        HStack(spacing: SH.Space.m) {
            Image(systemName: symbol ?? "circle").frame(width: SH.Height.controlS).opacity(symbol == nil ? 0 : 1)
            Text(title)
            Spacer(minLength: SH.Space.l)
        }
        .font(.sh(.ui))
        .foregroundStyle(Color.sh.textPrimary)
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.s)
    }

    private func menu<V: View>(@ViewBuilder _ items: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) { items() }
            .padding(.vertical, SH.Space.xs)
            .frame(width: 260)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: SH.Radius.l, style: .continuous).stroke(Color.sh.lineSubtle))
    }

    /// The thread options menu (ThreadHeader) for a thread whose host keeps mutes: unmuted, then muted.
    @Test func threadOptionsMute() async throws {
        try await Preview.render("thread-options-mute", size: CGSize(width: 640, height: 260)) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                ForEach([false, true], id: \.self) { muted in
                    menu {
                        item("Refresh Thread")
                        Divider()
                        item("Rename…")
                        item(PinWords.menuTitle(pinned: false), PinWords.symbol(pinned: false))
                        item(MuteWords.menuTitle(muted: muted), MuteWords.symbol(muted: muted))
                    }
                }
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgBase)
        }
    }

    /// A question push opened with a long press (NotifPhoneRich): the preview from real `PushDetail`, then
    /// the buttons `PushButtons.actions` gives it (each option, Reply…, Open).
    @Test func questionOptions() async throws {
        let detail = try PushPreviewTests.wire(PushDetail.question(options: ["checkout_id", "order_id"]))
        try await Preview.render("push-question", size: CGSize(width: 500, height: 520)) {
            VStack(alignment: .leading, spacing: SH.Space.l) {
                SHPushPreview(title: "Refunds in the ledger", subtitle: "Question",
                              body: "Which key joins a refund to the funnel?", date: Date(), detail: detail)
                    .frame(width: 370)
                    .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                menu {
                    item("checkout_id")
                    item("order_id")
                    Divider()
                    item("Reply…")
                    item("Open", "chevron.right")
                }
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgBase)
        }
        #expect(detail?.options == ["checkout_id", "order_id"])
    }
}
