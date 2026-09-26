import Foundation
import ShepherdCore
import ShepherdProtocol

// New thread on a remote host (the iOS client's creation flow): the rows its pickers show, the
// defaults and worktree base it loads from the host, what may block Start, and the createAgent
// request it sends. The rules mirror the Mac's New Agent sheet (NewAgentSheet.swift).

/// What New thread knows about one host.
public struct NewThreadHostInput: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var phase: RemoteHostPhase
    public var capabilities: Set<String>
    public var state: ShepherdState
    /// When this device's connection to it last ended (`HostLastSeen`).
    public var lastSeen: Date?

    public init(id: UUID, name: String, phase: RemoteHostPhase, capabilities: Set<String>, state: ShepherdState,
                lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.phase = phase
        self.capabilities = capabilities
        self.state = state
        self.lastSeen = lastSeen
    }

    /// Spaces the user sees: not the hidden space automation runs live in.
    public var spaces: [Space] { state.spaces.filter { !$0.hidden } }

    /// Creating in a new worktree needs the host to resolve a base and to make worktrees.
    public var supportsWorktrees: Bool {
        capabilities.isSuperset(of: [RemoteProtocol.creationOptionsCapability, RemoteProtocol.worktreeActionsCapability])
    }

    /// Images go with the first send, which needs native threads v2.
    public var supportsImages: Bool { capabilities.contains(RemoteProtocol.nativeThreadV2Capability) }
}

/// A host in the Host list (Where it runs) and the iPad's Run on popover.
public struct NewThreadHostRow: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable { case connected, connecting, offline }

    public let id: UUID
    public let name: String
    public let status: Status
    /// "connected · 2 threads running", "connecting…", "unreachable · last seen 7:12 AM".
    public let detail: String
    /// What this host cannot do from here, and why: an older Shepherd.
    public let limitation: String?
    public let selected: Bool

    /// Only a connected host can create anything.
    public var selectable: Bool { status == .connected }
    /// An offline host offers Retry in its row.
    public var offersRetry: Bool { status == .offline }
}

/// A repo in the Repo list: a space on the chosen host, then the spaces of the other connected
/// hosts (choosing one moves the thread to that host).
public struct NewThreadRepoRow: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        public let host: UUID
        public let space: SpaceID

        public init(host: UUID, space: SpaceID) {
            self.host = host
            self.space = space
        }
    }

    public let id: ID
    public let name: String
    /// The space's path for the chosen host's repos (`~/code/shepherd`), else "on build-01".
    public let detail: String
    public let selected: Bool
}

public enum NewThreadRows {
    public static func hosts(_ hosts: [NewThreadHostInput], selected: UUID?, now: Date = Date(),
                             calendar: Calendar = .current, locale: Locale = .current) -> [NewThreadHostRow] {
        hosts.map { host in
            let status: NewThreadHostRow.Status = switch host.phase {
            case .connected: .connected
            case .connecting: .connecting
            case .disconnected, .failed: .offline
            }
            var detail = detail(host, status: status)
            if status == .offline, let seen = host.lastSeen {
                detail += " · last seen " + HostLastSeen.short(seen, now: now, calendar: calendar, locale: locale)
            }
            return NewThreadHostRow(id: host.id, name: host.name, status: status, detail: detail,
                                    limitation: status == .connected ? NewThreadRules.limitation(host) : nil,
                                    selected: host.id == selected)
        }
    }

    public static func repos(_ hosts: [NewThreadHostInput], host selectedHost: UUID?, space selectedSpace: SpaceID?) -> [NewThreadRepoRow] {
        let chosen = hosts.first { $0.id == selectedHost }
        let others = hosts.filter { $0.id != selectedHost && $0.phase.isConnected }
        let own = (chosen?.spaces ?? []).map { space in
            NewThreadRepoRow(id: .init(host: chosen!.id, space: space.id), name: space.name,
                             detail: NewThreadRules.abbreviatedPath(space.path), selected: space.id == selectedSpace)
        }
        let elsewhere = others.flatMap { host in
            host.spaces.map { space in
                NewThreadRepoRow(id: .init(host: host.id, space: space.id), name: space.name, detail: "on \(host.name)", selected: false)
            }
        }
        return own + elsewhere
    }

    private static func detail(_ host: NewThreadHostInput, status: NewThreadHostRow.Status) -> String {
        switch status {
        case .connecting: return "connecting…"
        case .offline: return host.phase.failure?.headline.lowercased() ?? "unreachable"
        case .connected:
            let hidden = Set(host.state.spaces.filter(\.hidden).map(\.id))
            let visible = host.state.agents.filter { !hidden.contains($0.spaceID) && !host.state.isDesignAgent($0) }
            let running = visible.filter { $0.status == .working }.count
            if running > 0 { return "connected · \(running) \(running == 1 ? "thread" : "threads") running" }
            if visible.isEmpty { return "connected" }
            return "connected · \(visible.count) \(visible.count == 1 ? "thread" : "threads")"
        }
    }
}

/// A host's model and thinking for a new thread, from `creationOptions`. The user's edits
/// survive the answer when it is for the same host; a new host starts over. Only the newest
/// request lands (the Mac's `NewAgentTargetDefaults`).
public struct NewThreadDefaults: Equatable, Sendable {
    public private(set) var requestID = UUID()
    public private(set) var hostID: UUID?
    public private(set) var loading = false
    public private(set) var ready = false
    public var model = ""
    public var thinking: ThinkingLevel = .medium
    public var modelEdited = false
    public var thinkingEdited = false

    public init() {}

    /// Starts loading for `hostID`; the result goes to `apply` with the returned id.
    public mutating func begin(hostID: UUID) -> UUID {
        let sameTarget = self.hostID == hostID && !ready
        requestID = UUID()
        self.hostID = hostID
        if !sameTarget || !modelEdited { model = ""; modelEdited = false }
        if !sameTarget || !thinkingEdited { thinking = .medium; thinkingEdited = false }
        loading = true
        ready = false
        return requestID
    }

    public mutating func apply(requestID: UUID, model: String?, thinking: ThinkingLevel) {
        guard self.requestID == requestID else { return }
        if !modelEdited { self.model = model ?? "" }
        if !thinkingEdited { self.thinking = thinking }
        loading = false
        ready = true
    }

    public mutating func fail(requestID: UUID) {
        guard self.requestID == requestID else { return }
        loading = false
        ready = false
    }

    public mutating func edit(model: String) {
        self.model = model
        modelEdited = true
    }

    public mutating func edit(thinking: ThinkingLevel) {
        self.thinking = thinking
        thinkingEdited = true
    }
}

/// The worktree's base, resolved on the host for one target (host, repo, directory). A new
/// target clears it; only the newest request lands.
public struct NewThreadBase: Equatable, Sendable {
    public struct Target: Hashable, Sendable {
        public var host: UUID
        public var space: SpaceID
        public var cwd: String

        public init(host: UUID, space: SpaceID, cwd: String) {
            self.host = host
            self.space = space
            self.cwd = cwd
        }
    }

    public private(set) var requestID = UUID()
    public private(set) var target: Target?
    public private(set) var resolving = false
    /// The base answered for `target`; the field may be edited after.
    public private(set) var resolved = false
    public var base = ""
    public private(set) var note = ""
    public var fetchFirst = false

    public init() {}

    /// Clears what was resolved for another target, and starts resolving this one.
    public mutating func begin(_ target: Target) -> UUID {
        if self.target != target {
            base = ""
            note = ""
            fetchFirst = false
            resolved = false
        }
        self.target = target
        requestID = UUID()
        resolving = true
        return requestID
    }

    public mutating func apply(requestID: UUID, options: RemoteCreationOptions) {
        guard self.requestID == requestID else { return }
        base = options.base
        note = options.note
        fetchFirst = options.fetchFirst
        resolved = true
        resolving = false
    }

    public mutating func fail(requestID: UUID) {
        guard self.requestID == requestID else { return }
        resolving = false
    }

    /// Resolved for `target` and not re-resolving.
    public func isReady(for target: Target?) -> Bool {
        target != nil && self.target == target && resolved && !resolving
    }
}

/// Everything New thread's Start depends on.
public struct NewThreadDraft: Equatable, Sendable {
    public var prompt: String
    public var host: NewThreadHostInput?
    public var space: Space?
    public var defaults: NewThreadDefaults
    public var worktree: Bool
    public var branch: String
    public var base: NewThreadBase
    public var attachments: Int
    public var starting: Bool

    public init(prompt: String, host: NewThreadHostInput?, space: Space?, defaults: NewThreadDefaults, worktree: Bool,
                branch: String, base: NewThreadBase, attachments: Int = 0, starting: Bool = false) {
        self.prompt = prompt
        self.host = host
        self.space = space
        self.defaults = defaults
        self.worktree = worktree
        self.branch = branch
        self.base = base
        self.attachments = attachments
        self.starting = starting
    }

    /// The directory the agent starts in: the space's own.
    public var cwd: String? { space?.path }

    public var baseTarget: NewThreadBase.Target? {
        guard let host, let space else { return nil }
        return .init(host: host.id, space: space.id, cwd: space.path)
    }

    /// The worktree switch counts only where the host can make one.
    public var usesWorktree: Bool { worktree && host?.supportsWorktrees == true }
}

/// Why Start is unavailable. Each says what to do.
public enum NewThreadBlocker: Equatable, Sendable {
    case starting
    case noHost
    case hostOffline(String)
    case noRepo(String)
    case loadingDefaults(String)
    case defaultsFailed(String)
    case noBranch
    case resolvingBase(String)
    case baseUnresolved
    case imagesUnsupported(String)
    case imagesNeedPrompt

    public var message: String {
        switch self {
        case .starting: "Starting…"
        case .noHost: "Add a host in Settings to start a thread."
        case .hostOffline(let name): "\(name) is offline. Retry it, or choose another host."
        case .noRepo(let name): "Add a repo on \(name) to start a thread there."
        case .loadingDefaults(let name): "Loading \(name)'s defaults…"
        case .defaultsFailed(let name): "\(name)'s defaults didn't load. Try again."
        case .noBranch: "Name the worktree's branch."
        case .resolvingBase(let name): "Resolving the base on \(name)…"
        case .baseUnresolved: "Resolve the worktree's base first."
        case .imagesUnsupported(let name): "Update Shepherd on \(name) to send images."
        case .imagesNeedPrompt: "Add a prompt to send the images with."
        }
    }

    /// Waiting on the host, not on the user.
    public var isPending: Bool {
        switch self {
        case .starting, .loadingDefaults, .resolvingBase: true
        default: false
        }
    }
}

/// The createAgent request, and the first send when images go with it.
public struct NewThreadCreation: Equatable, Sendable {
    public var spaceID: SpaceID
    public var cwd: String?
    public var model: String?
    public var thinking: ThinkingLevel
    /// The prompt the host sends as the thread's first message (the Mac's opening prompt).
    public var initialPrompt: String?
    public var worktreeBranch: String?
    public var worktreeBase: String?
    public var worktreeFetchFirst: Bool?
    /// With images, the prompt goes with them as the first send instead: createAgent takes no
    /// images.
    public var firstSend: String?
}

public enum NewThreadRules {
    public static func blocker(_ draft: NewThreadDraft) -> NewThreadBlocker? {
        if draft.starting { return .starting }
        guard let host = draft.host else { return .noHost }
        guard host.phase.isConnected else { return .hostOffline(host.name) }
        guard draft.space != nil else { return .noRepo(host.name) }
        if draft.defaults.hostID != host.id || draft.defaults.loading { return .loadingDefaults(host.name) }
        if !draft.defaults.ready { return .defaultsFailed(host.name) }
        if draft.usesWorktree {
            if draft.branch.trimmingCharacters(in: .whitespaces).isEmpty { return .noBranch }
            if draft.base.resolving { return .resolvingBase(host.name) }
            if !draft.base.isReady(for: draft.baseTarget) { return .baseUnresolved }
        }
        if draft.attachments > 0 {
            if !host.supportsImages { return .imagesUnsupported(host.name) }
            if draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .imagesNeedPrompt }
        }
        return nil
    }

    /// The request Start sends, or nil while something blocks it. The prompt is trimmed and
    /// dropped when empty, and a blank model means the host's default, as on the Mac.
    public static func creation(_ draft: NewThreadDraft) -> NewThreadCreation? {
        guard blocker(draft) == nil, let space = draft.space else { return nil }
        let model = draft.defaults.model.trimmingCharacters(in: .whitespaces)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktree = draft.usesWorktree
        let images = draft.attachments > 0
        return NewThreadCreation(
            spaceID: space.id,
            cwd: draft.cwd,
            model: model.isEmpty ? nil : model,
            thinking: draft.defaults.thinking,
            initialPrompt: images || prompt.isEmpty ? nil : prompt,
            worktreeBranch: worktree ? draft.branch.trimmingCharacters(in: .whitespaces) : nil,
            worktreeBase: worktree ? draft.base.base : nil,
            worktreeFetchFirst: worktree ? draft.base.fetchFirst : nil,
            firstSend: images ? prompt : nil
        )
    }

    /// What a connected host cannot do from here, or nil when it can do everything New thread
    /// offers.
    public static func limitation(_ host: NewThreadHostInput) -> String? {
        switch (host.supportsWorktrees, host.supportsImages) {
        case (true, true): nil
        case (false, true): "Update Shepherd on \(host.name) to start threads in a new worktree."
        case (true, false): "Update Shepherd on \(host.name) to send images."
        case (false, false): "Update Shepherd on \(host.name) for new worktrees and images."
        }
    }

    /// The line beside Attach: where the thread will work.
    public static func worktreeSummary(repo: String?, worktree: Bool) -> String {
        guard let repo else { return "Choose a repo" }
        return worktree ? "New worktree on \(repo)" : "In \(repo)'s checkout"
    }

    /// Under the New worktree switch: what the worktree keeps clean (the base's branch, without
    /// its remote).
    public static func worktreeCaption(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let branch = trimmed.hasPrefix("origin/") ? String(trimmed.dropFirst("origin/".count)) : trimmed
        return branch.isEmpty ? "Keeps the checkout clean. Merge it from Review." : "Keeps \(branch) clean. Merge it from Review."
    }

    /// A model id as a chip shows it: without its provider ("anthropic/claude-opus" →
    /// "claude-opus"); a blank id is the host's default.
    public static func shortModel(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "Default model" }
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// A home directory shown as `~` (`/Users/dev/code/app` → `~/code/app`).
    public static func abbreviatedPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // "", "Users", "<name>", …
        guard parts.count >= 3, parts[0].isEmpty, parts[1] == "Users" || parts[1] == "home", !parts[2].isEmpty else { return path }
        let rest = parts.dropFirst(3).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }

    /// The model ids to show for a typed query: prefix matches, then substrings, then scattered
    /// subsequences, each in catalog order; the catalog's first `limit` for an empty query.
    public static func rankModels(_ query: String, in options: [String], limit: Int = 50) -> [String] {
        let query = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return Array(options.prefix(limit)) }
        var ranked: [(id: String, rank: Int, order: Int)] = []
        for (order, id) in options.enumerated() {
            let lowered = id.lowercased()
            let short = shortModel(id).lowercased()
            let rank: Int
            if short.hasPrefix(query) || lowered.hasPrefix(query) { rank = 0 } else if lowered.contains(query) { rank = 1 } else if NewThreadFolders.fuzzyMatches(query, in: lowered) { rank = 2 } else { continue }
            ranked.append((id, rank, order))
        }
        return ranked.sorted { ($0.rank, $0.order) < ($1.rank, $1.order) }.prefix(limit).map(\.id)
    }

    /// A disposable, readable branch (`agent/<adjective>-<noun>-<4 digits>`), as the Mac
    /// generates one. The suffix keeps repeat creations from colliding.
    public static func generatedBranch<R: RandomNumberGenerator>(using generator: inout R) -> String {
        let adjectives = [
            "calm", "brave", "quiet", "amber", "bright", "clever", "eager", "gentle",
            "lucid", "mellow", "noble", "rapid", "solid", "swift", "vivid", "warm",
        ]
        let nouns = [
            "stone", "river", "cedar", "comet", "ember", "falcon", "harbor", "lantern",
            "meadow", "otter", "pine", "quartz", "raven", "summit", "tide", "willow",
        ]
        let adjective = adjectives.randomElement(using: &generator)!
        let noun = nouns.randomElement(using: &generator)!
        let number = Int.random(in: 1000...9999, using: &generator)
        return "agent/\(adjective)-\(noun)-\(number)"
    }

    public static func generatedBranch() -> String {
        var generator = SystemRandomNumberGenerator()
        return generatedBranch(using: &generator)
    }
}

/// A host folder listing as the folder browser shows it (the Mac's directory picker rules).
public enum NewThreadFolders {
    /// Hidden folders only on request (or when the filter asks for them), narrowed by a fuzzy
    /// filter: prefix matches first, then subsequences, each by name.
    public static func visible(_ dirs: [String], filter: String, showHidden: Bool) -> [String] {
        let shown = dirs.filter { !$0.hasPrefix(".") }
        let all = showHidden || filter.hasPrefix(".") ? shown + dirs.filter { $0.hasPrefix(".") } : shown
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all
            .map { (name: $0, lowered: $0.lowercased()) }
            .filter { fuzzyMatches(query, in: $0.lowered) }
            .map { (name: $0.name, prefix: $0.lowered.hasPrefix(query)) }
            .sorted { lhs, rhs in
                if lhs.prefix != rhs.prefix { return lhs.prefix }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map(\.name)
    }

    /// `query`'s characters appear in `candidate` in order (both lowercased).
    public static func fuzzyMatches(_ query: String, in candidate: String) -> Bool {
        var remaining = candidate[...]
        for character in query {
            guard let match = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: match)...]
        }
        return true
    }

    /// A folder inside `path`.
    public static func child(_ name: String, of path: String) -> String {
        path.hasSuffix("/") ? path + name : path + "/" + name
    }
}
