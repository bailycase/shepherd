import SwiftUI

// A push's long-press preview (NotifPhoneRich), drawn by the notification content extension
// from the push's `shepherd.detail`. The buttons under it are the system's.

/// The push's `detail`, decoded from the relay's JSON: the same keys the host's `PushDetail` writes.
public struct SHPushDetail: Codable, Hashable, Sendable {
    /// A question's options, each a button under the push.
    public var options: [String]?
    public init(options: [String]? = nil) {
        self.options = options
    }
}

/// The preview's measures, from the boards.
public enum SHPushPreviewMetrics {
    /// The app mark in the header, and the crook inside it.
    public static let mark: CGFloat = 26
    public static let crook: CGFloat = 16
    public static let title: CGFloat = 15
    public static let heading: CGFloat = 15
    public static let body: CGFloat = 13.5
    public static let meta: CGFloat = 11.5
}

/// One push, opened: its own text under the Shepherd header.
public struct SHPushPreview: View {
    let title: String
    let subtitle: String?
    let message: String?
    let date: Date
    let detail: SHPushDetail?

    public init(title: String, subtitle: String?, body: String?, date: Date, detail: SHPushDetail?) {
        self.title = title
        self.subtitle = subtitle.flatMap { $0.isEmpty ? nil : $0 }
        self.message = body.flatMap { $0.isEmpty ? nil : $0 }
        self.date = date
        self.detail = detail
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            header
            plain
        }
        .padding(SH.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: SH.Space.l) {
            SHCrook()
                .frame(width: SHPushPreviewMetrics.crook, height: SHPushPreviewMetrics.crook)
                .frame(width: SHPushPreviewMetrics.mark, height: SHPushPreviewMetrics.mark)
                .background(Color.sh.lanternTint, in: RoundedRectangle(cornerRadius: SH.Radius.s, style: .continuous))
            Text(title).font(.shSans(SHPushPreviewMetrics.title, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
            Spacer(minLength: SH.Space.m)
            // Drawn once when opened: "now" for the first minute, as the system's banner says.
            Text(Date.now.timeIntervalSince(date) < 60 ? "now" : date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                .font(.shSans(SHPushPreviewMetrics.meta)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        }
    }

    @ViewBuilder private var plain: some View {
        if let subtitle {
            Text(subtitle).font(.shSans(SHPushPreviewMetrics.heading, .semibold)).foregroundStyle(Color.sh.textPrimary)
        }
        if let message {
            Text(message).font(.shSans(SHPushPreviewMetrics.body)).foregroundStyle(Color.sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview("Question · dark") {
    SHPushPreview(title: "Checkout funnel events", subtitle: "Question", body: "Which key joins a refund to the funnel?", date: .now,
                  detail: SHPushDetail(options: ["checkout_id", "order_id"]))
        .background(Color.sh.bgRaised).preferredColorScheme(.dark)
}
