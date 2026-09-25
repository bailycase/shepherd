import Foundation
import ShepherdCore

/// One agent a search can reach, on one host. Built by the client from each host's pushed
/// state; agent ids are unique only within their host, so `id` carries both.
public struct SearchTarget: Hashable, Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public var host: UUID
        public var agent: AgentID

        public init(host: UUID, agent: AgentID) {
            self.host = host
            self.agent = agent
        }
    }

    public var host: UUID
    public var hostName: String
    public var agent: AgentID
    public var title: String
    public var status: AgentStatus
    public var space: String?
    /// The host is connected, so the thread opens live (an offline host's agents are its last
    /// known state).
    public var online: Bool
    /// The host answers `agentQuery(.search)`: connected, and new enough to inspect agents.
    public var searchable: Bool

    public var id: ID { ID(host: host, agent: agent) }

    public init(host: UUID, hostName: String, agent: AgentID, title: String, status: AgentStatus, space: String?,
                online: Bool, searchable: Bool) {
        self.host = host
        self.hostName = hostName
        self.agent = agent
        self.title = title
        self.status = status
        self.space = space
        self.online = online
        self.searchable = searchable
    }
}

/// A host as search sees it: why its conversations can or cannot be searched.
public struct SearchHost: Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var online: Bool
    public var searchable: Bool
    public var agentCount: Int

    public init(id: UUID, name: String, online: Bool, searchable: Bool, agentCount: Int) {
        self.id = id
        self.name = name
        self.online = online
        self.searchable = searchable
        self.agentCount = agentCount
    }
}

/// A run of text, and whether it matched the query (drawn in the highlight).
public struct SearchSegment: Hashable, Sendable {
    public var text: String
    public var highlighted: Bool

    public init(_ text: String, highlighted: Bool = false) {
        self.text = text
        self.highlighted = highlighted
    }
}

/// One result: a thread whose title matched, or one whose conversation did (with a snippet).
public struct SearchResultRow: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case thread, conversation }

    public var kind: Kind
    public var target: SearchTarget.ID
    public var title: [SearchSegment]
    /// A thread's status and space, or the conversation's snippet.
    public var detail: [SearchSegment]
    public var hostName: String
    public var status: AgentStatus
    public var online: Bool

    public var id: String {
        (kind == .thread ? "thread:" : "conversation:") + target.host.uuidString + ":" + target.agent.rawValue
    }

    /// The row read aloud: title, detail, host.
    public var spokenText: String {
        [title, detail].map { $0.map(\.text).joined() }.filter { !$0.isEmpty }.joined(separator: ", ") + ", on " + hostName
    }
}

public struct SearchSection: Identifiable, Hashable, Sendable {
    public enum Kind: Int, Hashable, Sendable, CaseIterable {
        case threads, conversations
    }

    public var kind: Kind
    public var rows: [SearchResultRow]

    public var id: Kind { kind }

    public var title: String {
        switch kind {
        case .threads: "Threads"
        case .conversations: "In conversations"
        }
    }
}

/// How far the conversation search has come: agents answered out of those asked.
public struct SearchProgress: Hashable, Sendable {
    public var searched: Int
    public var total: Int

    public init(searched: Int = 0, total: Int = 0) {
        self.searched = searched
        self.total = total
    }

    public var isSearching: Bool { searched < total }
}

/// What one host answered for one agent.
public enum SearchOutcome: Hashable, Sendable {
    case found(snippet: String)
    case none
    /// The host could not search (too old, disconnected, an error); its remaining agents are
    /// not asked and report the same reason.
    case failed(String)
}

/// Everything a search screen draws for one query.
public struct SearchResults: Hashable, Sendable {
    public var query: String
    public var sections: [SearchSection]
    public var progress: SearchProgress
    /// Why some conversations were not searched ("build-01 is offline").
    public var notices: [String]

    public init(query: String = "", sections: [SearchSection] = [], progress: SearchProgress = SearchProgress(), notices: [String] = []) {
        self.query = query
        self.sections = sections
        self.progress = progress
        self.notices = notices
    }

    public static let empty = SearchResults()

    public var rows: [SearchResultRow] { sections.flatMap(\.rows) }
    public var isEmpty: Bool { sections.allSatisfy(\.rows.isEmpty) }
    /// The query was long enough to search conversations.
    public var searchesConversations: Bool { CrossHostSearch.searchesConversations(query) }
}

/// Search across every agent on every connected host, fanned out on the client: thread titles
/// match at once from the pushed state, and each host searches its agents' conversations one
/// `agentQuery(.search)` at a time (the host reads the last 512 KB of each agent's session and
/// answers one snippet). Pure, apart from `fanOut`, which only schedules the caller's requests.
public enum CrossHostSearch {
    /// Conversation search needs at least this many characters, as on the Mac (the host
    /// ignores shorter queries).
    public static let minContentQuery = 3
    /// Requests in flight to one host at a time.
    public static let perHostLimit = 3

    public static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func searchesConversations(_ query: String) -> Bool {
        normalized(query).count >= minContentQuery
    }

    /// The Mac palette's ranking: a prefix beats a word prefix beats a substring beats a
    /// scattered subsequence (lower is better); nil for no match. Case-insensitive.
    public static func rank(query: String, in text: String) -> Int? {
        let q = query.lowercased()
        let t = text.lowercased()
        if q.isEmpty { return 0 }
        if t.hasPrefix(q) { return 0 }
        if t.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" }).contains(where: { $0.hasPrefix(q) }) { return 1 }
        if t.contains(q) { return 2 }
        var index = t.startIndex
        for ch in q {
            guard let found = t[index...].firstIndex(of: ch) else { return nil }
            index = t.index(after: found)
        }
        return 3
    }

    /// `text` split around every case-insensitive occurrence of `query`.
    public static func segments(_ text: String, highlighting query: String) -> [SearchSegment] {
        let needle = normalized(query)
        guard !needle.isEmpty, !text.isEmpty else { return text.isEmpty ? [] : [SearchSegment(text)] }
        var result: [SearchSegment] = []
        var rest = text.startIndex
        while let found = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: rest..<text.endIndex) {
            if found.lowerBound > rest { result.append(SearchSegment(String(text[rest..<found.lowerBound]))) }
            result.append(SearchSegment(String(text[found]), highlighted: true))
            rest = found.upperBound
        }
        if rest < text.endIndex { result.append(SearchSegment(String(text[rest...]))) }
        return result
    }

    /// A host's snippet as a row shows it: one line, quoted, elided at both ends
    /// (“…funnel rows can’t be joined…”).
    public static func snippet(_ raw: String) -> String {
        let core = raw
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "…. "))
        return core.isEmpty ? "" : "“…" + core + "…”"
    }

    /// Threads whose title matches, best first (ties keep the hosts' order). A thread matches on
    /// its space or host name too, ranked below every title match.
    public static func threadMatches(_ query: String, in targets: [SearchTarget]) -> [SearchTarget] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return [] }
        var ranked: [(target: SearchTarget, rank: Int, index: Int)] = []
        for (index, target) in targets.enumerated() {
            let context = [target.space, target.hostName].compactMap { $0 }.joined(separator: " ")
            if let rank = rank(query: needle, in: target.title) ?? rank(query: needle, in: context).map({ $0 + 4 }) {
                ranked.append((target, rank, index))
            }
        }
        ranked.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return ranked.map(\.target)
    }

    /// The agents whose conversations to ask about: on a searchable host, and not already a
    /// title match (as on the Mac, a thread shows once).
    public static func contentTargets(_ query: String, in targets: [SearchTarget]) -> [SearchTarget] {
        guard searchesConversations(query) else { return [] }
        let titled = Set(threadMatches(query, in: targets).map(\.id))
        return targets.filter { $0.searchable && !titled.contains($0.id) }
    }

    /// The rows for `query`: title matches, then the conversations that answered with a snippet
    /// (in the hosts' order, so a late answer never reorders what is already on screen), with
    /// the progress over `contentTargets` and why any host was left out.
    public static func results(_ query: String, targets: [SearchTarget], hosts: [SearchHost],
                               outcomes: [SearchTarget.ID: SearchOutcome]) -> SearchResults {
        let needle = normalized(query)
        guard !needle.isEmpty else { return .empty }
        let threads = threadMatches(needle, in: targets).map { target in
            let detail = [statusWord(target.status), target.space].compactMap { $0 }.joined(separator: " · ")
            return SearchResultRow(kind: .thread, target: target.id, title: segments(target.title, highlighting: needle),
                                   detail: segments(detail, highlighting: needle), hostName: target.hostName,
                                   status: target.status, online: target.online)
        }
        let asked = contentTargets(needle, in: targets)
        var conversations: [SearchResultRow] = []
        var searched = 0
        var failures: [UUID: String] = [:]
        for target in asked {
            guard let outcome = outcomes[target.id] else { continue }
            searched += 1
            switch outcome {
            case .found(let raw):
                conversations.append(SearchResultRow(kind: .conversation, target: target.id,
                                                     title: segments(target.title, highlighting: needle),
                                                     detail: segments(snippet(raw), highlighting: needle),
                                                     hostName: target.hostName, status: target.status, online: target.online))
            case .none: break
            case .failed(let reason): failures[target.host] = failures[target.host] ?? reason
            }
        }
        var sections: [SearchSection] = []
        if !threads.isEmpty { sections.append(SearchSection(kind: .threads, rows: threads)) }
        if !conversations.isEmpty { sections.append(SearchSection(kind: .conversations, rows: conversations)) }
        var notices: [String] = []
        if searchesConversations(needle) {
            for host in hosts where host.agentCount > 0 {
                if !host.online {
                    notices.append("\(host.name) is offline · its conversations weren’t searched")
                } else if !host.searchable {
                    notices.append("Update Shepherd on \(host.name) to search its conversations")
                } else if let reason = failures[host.id] {
                    notices.append("\(host.name) couldn’t search: \(reason)")
                }
            }
        }
        return SearchResults(query: needle, sections: sections, progress: SearchProgress(searched: searched, total: asked.count),
                             notices: notices)
    }

    /// The status word rows use, as Home's rows and the Mac palette say it.
    public static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: "Running"
        case .blocked: "Needs you"
        case .done: "Done"
        case .idle: "Idle"
        }
    }

    /// Asks every target, at most `perHost` at a time on each host and every host at once, and
    /// hands each answer to `deliver` as it lands. A host that fails stops being asked; its
    /// remaining targets are delivered as the same failure, so progress completes. Nothing is
    /// delivered once the task is cancelled (the query changed).
    public static func fanOut(
        _ targets: [SearchTarget],
        perHost: Int = perHostLimit,
        search: @escaping @Sendable (SearchTarget) async throws -> String?,
        deliver: @escaping @MainActor @Sendable (SearchTarget.ID, SearchOutcome) -> Void
    ) async {
        var byHost: [UUID: [SearchTarget]] = [:]
        var order: [UUID] = []
        for target in targets {
            if byHost[target.host] == nil { order.append(target.host) }
            byHost[target.host, default: []].append(target)
        }
        let limit = max(1, perHost)
        await withTaskGroup(of: Void.self) { hosts in
            for host in order {
                let queue = byHost[host] ?? []
                hosts.addTask {
                    await searchHost(queue, limit: limit, search: search, deliver: deliver)
                }
            }
        }
    }

    private static func searchHost(
        _ queue: [SearchTarget], limit: Int,
        search: @escaping @Sendable (SearchTarget) async throws -> String?,
        deliver: @escaping @MainActor @Sendable (SearchTarget.ID, SearchOutcome) -> Void
    ) async {
        var next = 0
        var failure: String?
        await withTaskGroup(of: (SearchTarget.ID, SearchOutcome).self) { group in
            func start(_ target: SearchTarget) {
                group.addTask {
                    do {
                        let snippet = try await search(target)
                        return (target.id, snippet.map { .found(snippet: $0) } ?? .none)
                    } catch {
                        return (target.id, .failed(String(describing: error)))
                    }
                }
            }
            while next < min(limit, queue.count) {
                start(queue[next])
                next += 1
            }
            while let (id, outcome) = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                await deliver(id, outcome)
                if case .failed(let reason) = outcome, failure == nil { failure = reason }
                if failure == nil, next < queue.count {
                    start(queue[next])
                    next += 1
                }
            }
        }
        guard !Task.isCancelled, let failure else { return }
        for target in queue[next...] {
            await deliver(target.id, .failed(failure))
        }
    }
}
