import Foundation
import ShepherdCore
import ShepherdUI
import SwiftUI
import Testing

/// A push opened with a long press (NotifPhoneRich), from what the host sends: `PushDetail`
/// through JSON, decoded the way the extension decodes it. The notification's platter and the
/// buttons under it are the system's: `card` stands in for the platter.
@Suite("Push previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR to render previews"))
@MainActor
struct PushPreviewTests {
    static func wire(_ detail: PushDetail?) throws -> SHPushDetail? {
        try detail.map { try JSONDecoder().decode(SHPushDetail.self, from: JSONEncoder().encode($0)) }
    }

    func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(width: 370)
            .background(Color.sh.bgRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @Test func questionAndPlain() async throws {
        let now = Date()
        let question = try Self.wire(PushDetail.question(options: ["checkout_id", "order_id"]))
        try await Preview.render("push-preview", size: CGSize(width: 900, height: 400)) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                card { SHPushPreview(title: "Refunds in the ledger", subtitle: "Question",
                                     body: "Which key joins a refund to the funnel?", date: now, detail: question) }
                card { SHPushPreview(title: "Checkout funnel events", subtitle: "Turn finished",
                                     body: "Every order joins the funnel now; the checks pass.", date: now, detail: nil) }
            }
            .padding(SH.Space.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.sh.bgBase)
        }
        #expect(question?.options == ["checkout_id", "order_id"])
    }
}
