import Foundation

/// What the glance surfaces draw (GlanceWatch, GlanceFollow, GlanceIsland, GlanceLock, GlanceHome,
/// GlanceiPad, GlanceControls): every host's threads as one ordered list, most urgent first, and
/// the hosts' line. Codable so it is a Live Activity's content and a widget's entry as it is.
public struct SHGlance: Codable, Hashable, Sendable {
    /// A thread's state, in the order the surfaces rank them: needs you, failed, running, done.
    public enum State: Int, Codable, Hashable, Sendable, Comparable {
        case needsYou, failed, running, done

        public static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The shared status the dots and glyphs draw.
        public var agentState: AgentState {
            switch self {
            case .needsYou: .attention
            case .failed: .failed
            case .running: .running
            case .done: .done
            }
        }
    }

    /// The pi session an answer or a stop must still be talking to.
    public struct Session: Codable, Hashable, Sendable {
        public var piSessionID: String
        public var generation: String

        public init(piSessionID: String, generation: String) {
            self.piSessionID = piSessionID
            self.generation = generation
        }
    }

    /// A thread's subagents: going, waiting on their parent, finished.
    public struct Subagents: Codable, Hashable, Sendable {
        public var running: Int
        public var waiting: Int
        public var done: Int

        public init(running: Int, waiting: Int, done: Int) {
            self.running = running
            self.waiting = waiting
            self.done = done
        }

        public var total: Int { running + waiting + done }
    }

    /// The files a turn changed.
    public struct Changes: Codable, Hashable, Sendable {
        public var files: Int
        public var added: Int
        public var removed: Int

        public init(files: Int, added: Int, removed: Int) {
            self.files = files
            self.added = added
            self.removed = removed
        }
    }

    public struct Item: Codable, Hashable, Sendable, Identifiable {
        /// The host's id.
        public var host: String
        /// The agent's id on that host.
        public var agent: String
        public var title: String
        public var state: State
        public var hostName: String
        /// Running: since the call started. Needs you: since it asked. Done, failed: when.
        public var since: Date?
        /// The sidebar's short reason while it needs you ("retention?", "approve plan").
        public var tag: String?
        public var question: String?
        /// Answers that fit as buttons, the recommended one first; empty when only the thread can
        /// answer.
        public var options: [String]
        /// The question is a yes or no: its options are "Yes" and "No".
        public var confirms: Bool
        public var dialogID: String?
        public var session: Session?
        /// The call running now, as typed ("swift test --filter toolPreview").
        public var command: String?
        /// A finished or failed turn's one line ("Done. 3 files changed, tests pass.").
        public var result: String?
        public var subagents: Subagents?
        public var changes: Changes?
        public var queued: Int
        /// The thread's goal and where it stands ("Ship the glance surfaces · checking").
        public var goal: String?
        /// An automation's run, by the automation's name.
        public var automation: String?

        public var id: String { "\(host)/\(agent)" }

        public init(host: String, agent: String, title: String, state: State, hostName: String, since: Date? = nil,
                    tag: String? = nil, question: String? = nil, options: [String] = [], confirms: Bool = false,
                    dialogID: String? = nil,
                    session: Session? = nil, command: String? = nil, result: String? = nil, subagents: Subagents? = nil,
                    changes: Changes? = nil, queued: Int = 0, goal: String? = nil, automation: String? = nil) {
            self.host = host
            self.agent = agent
            self.title = title
            self.state = state
            self.hostName = hostName
            self.since = since
            self.tag = tag
            self.question = question
            self.options = options
            self.confirms = confirms
            self.dialogID = dialogID
            self.session = session
            self.command = command
            self.result = result
            self.subagents = subagents
            self.changes = changes
            self.queued = queued
            self.goal = goal
            self.automation = automation
        }

        /// Its buttons, or Open alone once the card no longer knows what it shows.
        public func actions(stale: Bool) -> [SHGlanceAction] { stale ? [.open] : actions }

        /// The buttons its card offers, at most one primary. Answers need a question the phone
        /// can answer; Stop needs the session it stops.
        public var actions: [SHGlanceAction] {
            switch state {
            case .needsYou:
                guard dialogID != nil, session != nil, !options.isEmpty else { return [.reply] }
                return options.prefix(SHGlance.answersShown).enumerated().map { index, option in
                    .answer(option, recommended: index == 0)
                } + [.reply]
            case .running: return session == nil ? [.steer] : [.steer, .stop]
            case .done: return [.review]
            case .failed: return [.open]
            }
        }
    }

    /// A host, and whether this device reaches it.
    public struct Host: Codable, Hashable, Sendable {
        public var name: String
        public var online: Bool

        public init(name: String, online: Bool) {
            self.name = name
            self.online = online
        }
    }

    /// Every item, most urgent first (`ordered`).
    public var items: [Item]
    public var hosts: [Host]
    /// When the phone last read its hosts: after `staleAfter` the surfaces say so.
    public var updated: Date
    /// Items left out to keep a Live Activity small (`forActivity`), counted by state.
    public var omitted: [State: Int]

    public init(items: [Item], hosts: [Host], updated: Date, omitted: [State: Int] = [:]) {
        self.items = Self.ordered(items)
        self.hosts = hosts
        self.updated = updated
        self.omitted = omitted
    }

    /// How many are in `state`, those left out included.
    public func count(_ state: State) -> Int { items.count { $0.state == state } + (omitted[state] ?? 0) }

    /// How many were left out in all.
    public var omittedCount: Int { omitted.values.reduce(0, +) }

    /// No item says something it no longer knows past this: the Live Activity's `staleDate`, and
    /// the widgets' last entry.
    public static let staleAfter: TimeInterval = 5 * 60
    /// The answers a card shows as buttons, beside Reply….
    public static let answersShown = 2

    /// Needs you, oldest question first; failed, newest first; running, longest first; done,
    /// newest first.
    public static func ordered(_ items: [Item]) -> [Item] {
        items.sorted { a, b in
            if a.state != b.state { return a.state < b.state }
            let (x, y) = (a.since ?? .distantPast, b.since ?? .distantPast)
            if x != y {
                switch a.state {
                case .needsYou, .running: return x < y
                case .failed, .done: return x > y
                }
            }
            return a.id < b.id
        }
    }

    public var needsYou: [Item] { items.filter { $0.state == .needsYou } }
    public var working: [Item] { items.filter { $0.state == .running } }
    public var failed: [Item] { items.filter { $0.state == .failed } }
    public var done: [Item] { items.filter { $0.state == .done } }

    /// The item a card leads with.
    public var lead: Item? { items.first }

    /// The most urgent state anything is in; nil when nothing is.
    public var urgent: State? { lead?.state }

    public func isStale(at now: Date) -> Bool { now.timeIntervalSince(updated) > Self.staleAfter }

    /// Nothing waits, fails or runs.
    public var isQuiet: Bool { items.allSatisfy { $0.state == .done } }

    /// "3 need you · 4 working", "4 working", "Nothing running".
    public var summary: String {
        let (need, failed, working) = (count(.needsYou), count(.failed), count(.running))
        var parts: [String] = []
        if need > 0 { parts.append("\(need) need\(need == 1 ? "s" : "") you") }
        if failed > 0 { parts.append("\(failed) failed") }
        if working > 0 { parts.append("\(working) working") }
        return parts.isEmpty ? "Nothing running" : parts.joined(separator: " · ")
    }

    /// "build-01, This Mac online · horizon offline".
    public var hostsLine: String {
        let online = hosts.filter(\.online).map(\.name)
        let offline = hosts.filter { !$0.online }.map(\.name)
        var parts: [String] = []
        if !online.isEmpty { parts.append(online.joined(separator: ", ") + " online") }
        if !offline.isEmpty { parts.append(offline.joined(separator: ", ") + " offline") }
        return parts.joined(separator: " · ")
    }

    /// The hosts this device cannot reach now, by name ("This Mac unreachable").
    public var unreachable: String? {
        let names = hosts.filter { !$0.online }.map(\.name)
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    /// Only one host's items and line (a widget scoped to a host).
    public func scoped(toHost host: String) -> SHGlance {
        var copy = self
        copy.items = items.filter { $0.host == host }
        let name = items.first { $0.host == host }?.hostName
        copy.hosts = hosts.filter { $0.name == name }
        return copy
    }

    /// At most `count` items, the most urgent.
    public func prefix(_ count: Int) -> SHGlance {
        var copy = self
        copy.items = Array(items.prefix(count))
        return copy
    }

    /// A Live Activity's content, which must stay under 4 KB: the `kept` most urgent items, their
    /// words cut to what a card shows, and the rest only counted (`omitted`).
    public func forActivity(kept: Int = SHGlanceMetrics.watchRows + 1) -> SHGlance {
        func cut(_ text: String?, _ length: Int) -> String? {
            text.map { $0.count > length ? String($0.prefix(length - 1)) + "…" : $0 }
        }
        var copy = self
        copy.items = items.prefix(kept).map { item in
            var item = item
            item.title = cut(item.title, 80) ?? ""
            item.question = cut(item.question, 200)
            item.options = item.options.prefix(Self.answersShown).map { cut($0, 40) ?? "" }
            item.tag = cut(item.tag, 16)
            item.command = cut(item.command, 100)
            item.result = cut(item.result, 140)
            item.goal = cut(item.goal, 80)
            return item
        }
        copy.omitted = Dictionary(items.dropFirst(kept).map { ($0.state, 1) }, uniquingKeysWith: +)
            .merging(omitted, uniquingKeysWith: +)
        return copy
    }

    /// One item, when it is still known.
    public func item(_ id: String) -> Item? { items.first { $0.id == id } }
}

/// A button on a glance card. The surface decides what runs it (an App Intent, a link).
public enum SHGlanceAction: Hashable, Sendable {
    /// One of the question's options; the recommended one is the card's primary.
    case answer(String, recommended: Bool)
    /// Opens the question in the thread.
    case reply
    /// Opens the thread to steer it.
    case steer
    /// Stops the turn, asking nothing.
    case stop
    /// Opens the turn's changes.
    case review
    /// Opens the thread.
    case open

    public var title: String {
        switch self {
        case .answer(let option, _): option
        case .reply: "Reply…"
        case .steer: "Steer"
        case .stop: "Stop"
        case .review: "Review"
        case .open: "Open"
        }
    }

    public var isPrimary: Bool {
        if case .answer(_, true) = self { return true }
        return false
    }
}
