import SwiftUI

// A push's long-press preview (NotifPhoneRich, NotifPhoneReview), drawn by the notification
// content extension from the push's `shepherd.detail`. The buttons under it are the system's.

/// The push's `detail`, decoded from the relay's JSON: the same keys the host's `PushDetail` writes.
public struct SHPushDetail: Codable, Hashable, Sendable {
    public struct Lane: Codable, Hashable, Sendable {
        public enum State: String, Codable, Hashable, Sendable { case done, running, failed, waiting }
        public var name: String
        public var states: [State]
        public var status: String
        public init(name: String, states: [State], status: String) { self.name = name; self.states = states; self.status = status }
    }
    public struct Stuck: Codable, Hashable, Sendable {
        public var lane: String
        public var count: Int
        public var tries: [String]
        public init(lane: String, count: Int, tries: [String]) { self.lane = lane; self.count = count; self.tries = tries }
    }
    public struct Repo: Codable, Hashable, Sendable {
        public var name: String
        public var pr: Int?
        public var added: Int?
        public var removed: Int?
        public init(name: String, pr: Int? = nil, added: Int? = nil, removed: Int? = nil) {
            self.name = name; self.pr = pr; self.added = added; self.removed = removed
        }
    }
    public struct Contract: Codable, Hashable, Sendable {
        public var passed: Int
        public var total: Int
        public init(passed: Int, total: Int) { self.passed = passed; self.total = total }
    }
    public var lanes: [Lane]?
    public var stuck: Stuck?
    public var read: String?
    public var repos: [Repo]?
    public var contract: Contract?
    public var options: [String]?
    public init(lanes: [Lane]? = nil, stuck: Stuck? = nil, read: String? = nil, repos: [Repo]? = nil,
                contract: Contract? = nil, options: [String]? = nil) {
        self.lanes = lanes; self.stuck = stuck; self.read = read; self.repos = repos; self.contract = contract; self.options = options
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
    public static let line: CGFloat = 13
    public static let mono: CGFloat = 12
    public static let meta: CGFloat = 11.5
    /// A lane's name column and its station track.
    public static let laneName: CGFloat = 96
    public static let track: CGFloat = 110
    public static let station: CGFloat = 9
    public static let wire: CGFloat = 2
    /// A try's numbered ring.
    public static let tryRing: CGFloat = 18
}

/// One push, opened: the mission's lanes and its stuck lane, a review's repositories, or the push's own text.
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
            if let repos = detail?.repos {
                review(repos)
            } else if let lanes = detail?.lanes {
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in LaneRow(lane: lane) }
                }
                SHHairline()
                stuck
            } else {
                plain
            }
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

    @ViewBuilder private var stuck: some View {
        if let stuck = detail?.stuck {
            Text("\(stuck.lane) is stuck after \(stuck.count) tr\(stuck.count == 1 ? "y" : "ies")")
                .font(.shSans(SHPushPreviewMetrics.heading, .semibold)).foregroundStyle(Color.sh.textPrimary)
            VStack(alignment: .leading, spacing: SH.Space.m) {
                ForEach(Array(stuck.tries.enumerated()), id: \.offset) { index, attempt in
                    HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                        Text("\(stuck.count - stuck.tries.count + index + 1)")
                            .font(.shSans(SHPushPreviewMetrics.meta)).foregroundStyle(Color.sh.failed)
                            .frame(width: SHPushPreviewMetrics.tryRing, height: SHPushPreviewMetrics.tryRing)
                            .overlay(Circle().stroke(Color.sh.failed, lineWidth: 1))
                        Text(attempt).font(.shSans(SHPushPreviewMetrics.line)).foregroundStyle(Color.sh.textSecondary)
                    }
                }
            }
        } else if let subtitle {
            Text(subtitle).font(.shSans(SHPushPreviewMetrics.heading, .semibold)).foregroundStyle(Color.sh.textPrimary)
        }
        if let read = detail?.read {
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                Text("Planner’s read").font(.shSans(SHPushPreviewMetrics.meta)).foregroundStyle(Color.sh.textTertiary)
                Text(read).font(.shSans(SHPushPreviewMetrics.body)).foregroundStyle(Color.sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m, style: .continuous))
        }
    }

    private func review(_ repos: [SHPushDetail.Repo]) -> some View {
        VStack(alignment: .leading, spacing: SH.Space.l) {
            if let subtitle {
                Text(subtitle).font(.shSans(SHPushPreviewMetrics.heading, .semibold)).foregroundStyle(Color.sh.textPrimary)
            }
            if let contract = detail?.contract {
                HStack(spacing: SH.Space.s) {
                    Image(systemName: "checkmark.shield").font(.shSans(SHPushPreviewMetrics.line, .medium))
                        .foregroundStyle(contract.passed == contract.total ? AgentState.done.color : AgentState.failed.color)
                    (Text("Contract: \(contract.passed) of \(contract.total) passed").foregroundStyle(Color.sh.textPrimary)
                     + Text(repos.count > 1 ? " · merges in this order" : "").foregroundStyle(Color.sh.textTertiary))
                        .font(.shSans(SHPushPreviewMetrics.line)).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: SH.Space.l) {
                ForEach(Array(repos.enumerated()), id: \.offset) { index, repo in
                    HStack(spacing: SH.Space.m) {
                        Text("\(index + 1)").font(.shMono(SHPushPreviewMetrics.meta)).foregroundStyle(Color.sh.textTertiary)
                        Text(repo.name).font(.shMono(SHPushPreviewMetrics.mono, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                        if let pr = repo.pr {
                            Text("#\(pr)").font(.shMono(SHPushPreviewMetrics.mono)).foregroundStyle(Color.sh.running)
                        }
                        Spacer(minLength: SH.Space.m)
                        if let added = repo.added, let removed = repo.removed {
                            Text("+\(added)").font(.shMono(SHPushPreviewMetrics.meta)).foregroundStyle(AgentState.done.textColor)
                            Text("−\(removed)").font(.shMono(SHPushPreviewMetrics.meta)).foregroundStyle(AgentState.failed.textColor)
                        }
                    }
                }
            }
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

/// A lane: its name, its stations on a wire, and the word for where it is.
private struct LaneRow: View {
    let lane: SHPushDetail.Lane

    var body: some View {
        HStack(spacing: SH.Space.m) {
            Text(lane.name).font(.shMono(SHPushPreviewMetrics.mono)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                .frame(width: SHPushPreviewMetrics.laneName, alignment: .leading)
            ZStack {
                Rectangle().fill(AgentState.done.color).frame(height: SHPushPreviewMetrics.wire)
                    .padding(.horizontal, SHPushPreviewMetrics.station / 2)
                HStack(spacing: 0) {
                    ForEach(Array(lane.states.enumerated()), id: \.offset) { index, state in
                        if index > 0 { Spacer(minLength: 0) }
                        StationDot(state: state)
                    }
                }
            }
            .frame(width: SHPushPreviewMetrics.track)
            Spacer(minLength: SH.Space.m)
            Text(lane.status).font(.shMono(SHPushPreviewMetrics.mono)).foregroundStyle(statusColor).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lane.name), \(lane.status)")
    }

    private var statusColor: Color {
        if lane.states.contains(.failed) { return AgentState.failed.textColor }
        if lane.states.contains(.running) { return AgentState.running.textColor }
        return Color.sh.textTertiary
    }
}

/// A station: filled when done or failed, a ring while it works or waits.
private struct StationDot: View {
    let state: SHPushDetail.Lane.State

    var body: some View {
        let size = SHPushPreviewMetrics.station
        Group {
            switch state {
            case .done: Circle().fill(AgentState.done.color)
            case .failed: Circle().fill(AgentState.failed.color)
            case .running: Circle().fill(Color.sh.bgRaised).overlay(Circle().stroke(AgentState.running.color, lineWidth: SHPushPreviewMetrics.wire))
            case .waiting: Circle().fill(Color.sh.bgRaised).overlay(Circle().stroke(Color.sh.lineStrong, lineWidth: SHPushPreviewMetrics.wire))
            }
        }
        .frame(width: size, height: size)
    }
}

#Preview("Stuck lane · dark") {
    SHPushPreview(title: "Checkout funnel events", subtitle: "Blocked", body: nil, date: .now, detail: SHPushDetail(
        lanes: [.init(name: "contracts", states: [.done, .done, .done], status: "done"),
                .init(name: "orders", states: [.done, .done, .failed], status: "stuck")],
        stuck: .init(lane: "orders", count: 3, tries: ["Wrote OrderPlaced after InsertOrder"]),
        read: "The outbox opens its own connection."))
        .background(Color.sh.bgRaised).preferredColorScheme(.dark)
}

#Preview("Review · light") {
    SHPushPreview(title: "Checkout funnel events", subtitle: "Ready to review", body: nil, date: .now, detail: SHPushDetail(
        repos: [.init(name: "contracts", pr: 412, added: 38, removed: 2)], contract: .init(passed: 10, total: 10)))
        .background(Color.sh.bgRaised).preferredColorScheme(.light)
}
