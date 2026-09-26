import Foundation
import ShepherdCore
import ShepherdProtocol

// Home across several hosts (the iOS client's Home, Needs you, Recents, the iPad sidebar and
// overview): plain values derived once per change from each host's pushed state and, for what
// the state does not say (a question's text, the command running now), one thread snapshot per
// agent that matters.

/// One agent on one host: agent ids are only unique within the host that made them.
public struct FleetRef: Hashable, Codable, Sendable {
    public var host: UUID
    public var agent: AgentID

    public init(host: UUID, agent: AgentID) {
        self.host = host
        self.agent = agent
    }
}

/// A host as Home reads it: its record, its connection, and its last pushed state.
public struct FleetHost: Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var address: String
    public var port: UInt16
    public var phase: RemoteHostPhase
    public var state: ShepherdState
    /// When this device's connection to it last ended (`HostLastSeen`).
    public var lastSeen: Date?

    public init(id: UUID, name: String, address: String, port: UInt16, phase: RemoteHostPhase, state: ShepherdState,
                lastSeen: Date? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.phase = phase
        self.state = state
        self.lastSeen = lastSeen
    }
}

// MARK: Digest

/// What one thread snapshot tells Home: the question waiting on the user, a subagent asking,
/// what runs now, and when the thread last moved.
public struct FleetDigest: Equatable, Sendable {
    public struct Question: Equatable, Sendable {
        public var dialogID: String
        public var kind: NativeThreadDialog.Kind
        public var title: String
        public var message: String?
        public var options: [String]
        /// False when the host cannot carry an answer from here (`unavailable`).
        public var answerable: Bool

        public init(dialogID: String, kind: NativeThreadDialog.Kind, title: String, message: String? = nil,
                    options: [String] = [], answerable: Bool = true) {
            self.dialogID = dialogID
            self.kind = kind
            self.title = title
            self.message = message
            self.options = options
            self.answerable = answerable
        }
    }

    public struct SubagentQuestion: Equatable, Sendable {
        public var runID: String
        public var label: String
        public var text: String
        /// The subagent's own word or two for its question ("retention?"), when it gave one.
        public var short: String?
        /// The answers it offered to pick from.
        public var options: [String]
        /// The host takes subagent commands for the thread, so an option can be sent from here.
        public var answerable: Bool

        public init(runID: String, label: String, text: String, short: String? = nil, options: [String] = [],
                    answerable: Bool = true) {
            self.runID = runID
            self.label = label
            self.text = text
            self.short = short
            self.options = options
            self.answerable = answerable
        }
    }

    public var session: NativeThreadSession
    public var revision: UInt64
    public var running: Bool
    public var question: Question?
    public var subagentQuestion: SubagentQuestion?
    /// A subagent is still running: background children outlive their parent's turn, so one may
    /// ask later while the thread itself is settled.
    public var liveSubagents: Bool
    /// The call running now ("swift build", "edit ThreadView.swift"); nil when none is.
    public var activity: String?
    /// When that call started (ms since epoch).
    public var activitySince: Double?
    /// The newest moment in the thread (ms since epoch).
    public var lastActivity: Double?

    public init(_ snapshot: NativeThreadSnapshot) {
        session = NativeThreadSession(piSessionID: snapshot.piSessionID, generation: snapshot.generation)
        revision = snapshot.revision
        running = snapshot.running
        // Without `answer` among the thread's actions its own composer refuses an answer too, so
        // the question is answered in the thread.
        let answers = snapshot.supportedActions.contains("answer")
        question = snapshot.dialogs.first.map { dialog in
            Question(dialogID: dialog.id, kind: dialog.kind, title: dialog.title, message: dialog.message,
                     options: dialog.options ?? [], answerable: answers && dialog.unavailable == nil)
        }
        let commands = snapshot.supportedActions.contains("subagents")
        subagentQuestion = (snapshot.subagents ?? []).first(where: \.needsAttention).map { run in
            SubagentQuestion(runID: run.runID, label: run.role ?? run.label,
                             text: run.question?.text ?? run.attentionText ?? "Waiting on you",
                             short: FleetModel.shortReason(run.question?.short),
                             options: run.question?.options ?? [], answerable: commands)
        }
        liveSubagents = (snapshot.subagents ?? []).contains { !$0.isTerminal }
        let entries = snapshot.messages + snapshot.provisional
        if snapshot.running, let call = entries.last(where: { $0.toolName != nil && $0.status == "running" }) {
            activity = Self.activity(NativeActivityCall(call))
            activitySince = call.startedAt ?? call.timestamp
        } else {
            activity = nil
            activitySince = nil
        }
        lastActivity = entries.compactMap(\.timestamp).max()
    }

    /// A call as one short line: a command as typed, a file by its name after the tool's verb.
    static func activity(_ call: NativeActivityCall) -> String {
        if call.kind == .run { return call.detail }
        if call.isPath {
            let name = call.detail.split(separator: "/").last.map(String.init) ?? call.detail
            return "\(call.label) \(name)"
        }
        return call.detail.isEmpty ? call.label : "\(call.label) \(call.detail)"
    }

    /// Whether Home reads this thread on every poll rather than once per connection: it runs,
    /// waits on the user, or has a subagent that may still ask.
    public static func watches(status: AgentStatus, digest: FleetDigest?) -> Bool {
        if status == .working || status == .blocked { return true }
        guard let digest else { return false }
        return digest.running || digest.question != nil || digest.subagentQuestion != nil || digest.liveSubagents
    }

    /// Whether the snapshot's `unchanged` answer still describes this digest.
    public func matches(piSessionID: String, generation: String, revision: UInt64) -> Bool {
        session.piSessionID == piSessionID && session.generation == generation && self.revision == revision
    }
}

// MARK: Rows

/// A time a row shows beside its status: live while it runs, or how long ago it moved.
public enum FleetClock: Equatable, Sendable {
    /// Counting up from a moment (a running call), in ms since epoch.
    case elapsed(since: Double)
    /// How long ago the thread last moved, in ms since epoch.
    case ago(Double)
}

/// One thread in Recents, the overview's Running and Finished lists, and the sidebar.
public struct FleetThreadRow: Identifiable, Equatable, Sendable {
    public var ref: FleetRef
    public var title: String
    public var status: AgentStatus
    /// "running · swift build", "idle · Shepherd": the status word and what it runs or where.
    public var detail: String
    /// The call running now, alone ("swift build").
    public var activity: String?
    public var clock: FleetClock?
    public var hostName: String
    /// The host's name when rows from several hosts mix; nil with one host.
    public var hostTag: String?
    public var worktree: Bool
    /// Its host is not connected: the row is its last known state.
    public var offline: Bool

    public var id: FleetRef { ref }
}

/// Something waiting on the user: an agent's question, a subagent asking, or an agent
/// blocked before its snapshot says why.
public struct FleetAttention: Identifiable, Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        case thread
        /// An automation's run, by the automation's name.
        case automation(String)
        /// A subagent of the thread, by the subagent's name.
        case subagent(String)
    }

    /// How it can be answered without opening the thread.
    public enum Reply: Equatable, Sendable {
        /// One of these options (a select with a few short ones).
        case choose([String])
        /// Yes or no.
        case confirm
        /// Only in the thread (typed answers, long lists, a subagent, no question yet).
        case open
    }

    public var ref: FleetRef
    public var origin: Origin
    /// The thread it belongs to.
    public var thread: String
    /// The question, or what is known without one ("Waiting on you").
    public var question: String
    /// The question's longer text.
    public var message: String?
    /// The sidebar's short reason ("asked you", "reviewer").
    public var reason: String
    public var reply: Reply
    public var dialogID: String?
    public var session: NativeThreadSession?
    /// The subagent run asking.
    public var runID: String?
    public var hostName: String
    public var hostTag: String?
    /// When the thread last moved (ms since epoch).
    public var since: Double?

    public var id: String { "\(ref.host.uuidString)/\(ref.agent.rawValue)/\(runID ?? dialogID ?? "blocked")" }

    /// The card's kind line: "Thread", "Automation · Nightly", "Subagent · Fix the login".
    public var originLabel: String {
        switch origin {
        case .thread: "Thread"
        case .automation(let name): "Automation · \(name)"
        case .subagent: "Subagent · \(thread)"
        }
    }

    /// The card's title: the thread, or "reviewer asks" for a subagent.
    public var title: String {
        if case .subagent(let name) = origin { return "\(name) asks" }
        return thread
    }
}

/// A host's card (More, Settings ▸ Hosts, the sidebar's footer).
public struct FleetHostCard: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// "studio.local:7433".
    public var address: String
    public var phase: RemoteHostPhase
    /// "2 threads running · Shepherd, horizon", "3 threads", or why it is offline.
    public var summary: String
    public var threads: Int
    public var running: Int
    public var needsYou: Int
    /// When it was last connected, while it is not (MobileMore's "Last seen today 07:12").
    public var lastSeen: Date?

    /// Retry makes sense: neither connected nor already connecting.
    public var canRetry: Bool { !phase.isConnected && phase != .connecting }
}

/// An automation, read-only: what it runs, where, and how its run is doing.
public struct FleetAutomationRow: Identifiable, Equatable, Sendable {
    public var id: String { "\(host.uuidString)/\(automationID.rawValue)" }
    public var host: UUID
    public var automationID: AutomationID
    public var name: String
    public var prompt: String
    /// The working directory's last component ("Shepherd").
    public var place: String
    public var enabled: Bool
    /// Its run's agent, while one exists.
    public var run: FleetRef?
    public var runStatus: AgentStatus?
    /// "running", "needs you", "done", "stopped", "off".
    public var stateWord: String
    public var hostName: String
    public var hostTag: String?
    public var offline: Bool
}

// MARK: Model

/// Everything Home draws, derived once per change.
public struct FleetModel: Equatable, Sendable {
    public var hosts: [FleetHostCard] = []
    /// The hosts that are not connected, for Home's notices.
    public var offlineHosts: [FleetHostCard] = []
    /// "Studio · build-01 · MacBook Air", for the sidebar's footer.
    public var hostNames = ""
    public var needsYou: [FleetAttention] = []
    /// Threads not waiting on you, most recently active first; running ones lead.
    public var recents: [FleetThreadRow] = []
    public var running: [FleetThreadRow] = []
    public var finished: [FleetThreadRow] = []
    public var automations: [FleetAutomationRow] = []
    /// Automations whose run is working or waiting on you now.
    public var automationsRunning: [FleetAutomationRow] = []
    /// The rest: stopped, off, or done.
    public var automationsQuiet: [FleetAutomationRow] = []
    /// Rows carry their host's name: more than one host is known.
    public var tagsHosts = false

    public init() {}

    public var offlineCount: Int { offlineHosts.count }
    public var connectedCount: Int { hosts.count - offlineHosts.count }

    /// Threads and automation runs going now: the overview's Running now.
    public var runningCount: Int { running.count + automationsRunning.count }

    /// "4 need you · 6 running · 3 hosts".
    public var summary: String {
        var parts: [String] = []
        if !needsYou.isEmpty { parts.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you") }
        parts.append("\(runningCount) running")
        parts.append(nativeCount(hosts.count, "host"))
        return parts.joined(separator: " · ")
    }

    /// "1 host offline", nil when every host is connected.
    public var offlineSummary: String? {
        offlineCount == 0 ? nil : "\(offlineCount) host\(offlineCount == 1 ? "" : "s") offline"
    }

    public init(hosts: [FleetHost], digests: [FleetRef: FleetDigest]) {
        tagsHosts = hosts.count > 1
        var recents: [(row: FleetThreadRow, order: Int, key: Double)] = []
        var order = 0
        for host in hosts {
            let connected = host.phase.isConnected
            let tag = tagsHosts ? host.name : nil
            let spaces = Dictionary(host.state.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let automationByAgent = Dictionary(host.state.automations.compactMap { automation in
                automation.agentID.map { ($0, automation) }
            }, uniquingKeysWith: { first, _ in first })
            var running = 0, needs = 0
            for agent in host.state.agents {
                let ref = FleetRef(host: host.id, agent: agent.id)
                let digest = digests[ref]
                let automation = automationByAgent[agent.id]
                let space = spaces[agent.spaceID]
                let attention = connected ? Self.attention(agent, ref: ref, digest: digest, automation: automation,
                                                           hostName: host.name, hostTag: tag) : []
                needs += attention.count
                needsYou.append(contentsOf: attention)
                // Automation runs live under Automations, not among the threads.
                guard automation == nil, space?.hidden != true else { continue }
                if agent.status == .working { running += 1 }
                let row = Self.row(agent, ref: ref, digest: digest, space: space, hostName: host.name, hostTag: tag,
                                   offline: !connected)
                if connected, agent.status == .working { self.running.append(row) }
                if agent.status == .done { finished.append(row) }
                if attention.isEmpty {
                    let key = agent.status == .working && connected ? .infinity : digest?.lastActivity ?? -1
                    recents.append((row, order, key))
                }
                order += 1
            }
            for automation in host.state.automations {
                let agent = automation.agentID.flatMap { id in host.state.agents.first { $0.id == id } }
                automations.append(FleetAutomationRow(
                    host: host.id, automationID: automation.id, name: automation.name, prompt: automation.prompt,
                    place: Self.lastComponent(automation.cwd), enabled: automation.enabled,
                    run: agent.map { FleetRef(host: host.id, agent: $0.id) }, runStatus: agent?.status,
                    stateWord: Self.automationWord(automation, agent: agent), hostName: host.name, hostTag: tag,
                    offline: !connected))
            }
            self.hosts.append(FleetHostCard(
                id: host.id, name: host.name, address: "\(host.address):\(host.port)", phase: host.phase,
                summary: Self.hostSummary(host, running: running), threads: host.state.agents.count,
                running: running, needsYou: needs, lastSeen: host.phase.isConnected ? nil : host.lastSeen))
        }
        offlineHosts = self.hosts.filter { !$0.phase.isConnected }
        hostNames = self.hosts.map(\.name).joined(separator: " · ")
        let live = { (row: FleetAutomationRow) in !row.offline && (row.runStatus == .working || row.runStatus == .blocked) }
        automationsRunning = automations.filter(live)
        automationsQuiet = automations.filter { !live($0) }
        self.recents = recents.sorted { $0.key != $1.key ? $0.key > $1.key : $0.order < $1.order }.map(\.row)
        needsYou.sort { ($0.since ?? -1) > ($1.since ?? -1) }
        finished.sort { (Self.lastMoved($0) ?? -1) > (Self.lastMoved($1) ?? -1) }
    }

    private static func lastMoved(_ row: FleetThreadRow) -> Double? {
        if case .ago(let at) = row.clock { return at }
        return nil
    }

    static func attention(_ agent: Agent, ref: FleetRef, digest: FleetDigest?, automation: Automation?,
                          hostName: String, hostTag: String?) -> [FleetAttention] {
        var items: [FleetAttention] = []
        let origin: FleetAttention.Origin = automation.map { .automation($0.name) } ?? .thread
        let since = digest?.lastActivity
        if let question = digest?.question {
            let reply: FleetAttention.Reply
            if !question.answerable {
                reply = .open
            } else {
                switch question.kind {
                case .confirm: reply = .confirm
                case .select: reply = Self.choosable(question.options) ? .choose(question.options) : .open
                case .input, .editor: reply = .open
                }
            }
            items.append(FleetAttention(ref: ref, origin: origin, thread: agent.name, question: question.title,
                                        message: question.message, reason: shortReason(agent.waitingReason) ?? "asked you", reply: reply,
                                        dialogID: question.dialogID, session: digest?.session, hostName: hostName,
                                        hostTag: hostTag, since: since))
        } else if agent.status == .blocked {
            items.append(FleetAttention(ref: ref, origin: origin, thread: agent.name, question: "Waiting on you",
                                        reason: "needs you", reply: .open, session: digest?.session,
                                        hostName: hostName, hostTag: hostTag, since: since))
        }
        if let asking = digest?.subagentQuestion {
            // Its options answer in place as a select's do; a reply in its own words is written in
            // the thread (MobileInbox).
            let reply: FleetAttention.Reply = asking.answerable && Self.choosable(asking.options) ? .choose(asking.options) : .open
            items.append(FleetAttention(ref: ref, origin: .subagent(asking.label), thread: agent.name,
                                        question: asking.text, reason: asking.short ?? asking.label, reply: reply,
                                        session: digest?.session, runID: asking.runID, hostName: hostName,
                                        hostTag: hostTag, since: since))
        }
        return items
    }

    /// An agent's own short reason as a chip (one line, cut as the Mac's), or nil when it gave none.
    static func shortReason(_ short: String?) -> String? {
        let line = short?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        return line.isEmpty ? nil : NeedsYouReason.shortened(line)
    }

    /// A select answers in place when its options fit as a row of buttons.
    static func choosable(_ options: [String]) -> Bool {
        !options.isEmpty && options.count <= 3 && options.allSatisfy { $0.count <= 32 }
    }

    static func row(_ agent: Agent, ref: FleetRef, digest: FleetDigest?, space: Space?, hostName: String,
                    hostTag: String?, offline: Bool) -> FleetThreadRow {
        let word = statusWord(agent.status)
        let live = agent.status == .working && !offline
        let activity = live ? digest?.activity : nil
        let clock: FleetClock? = if live {
            digest?.activitySince.map { FleetClock.elapsed(since: $0) }
        } else {
            digest?.lastActivity.map { FleetClock.ago($0) }
        }
        let detail = [word, activity ?? space?.name].compactMap { $0 }.joined(separator: " · ")
        return FleetThreadRow(ref: ref, title: agent.name, status: agent.status, detail: detail, activity: activity,
                              clock: clock, hostName: hostName, hostTag: hostTag, worktree: agent.worktreeBranch != nil,
                              offline: offline)
    }

    /// The row's status word, as the Mac's sidebar says it.
    public static func statusWord(_ status: AgentStatus) -> String {
        switch status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle: "idle"
        case .done: "done"
        }
    }

    static func automationWord(_ automation: Automation, agent: Agent?) -> String {
        guard let agent else { return automation.enabled ? "stopped" : "off" }
        return switch agent.status {
        case .working: "running"
        case .blocked: "needs you"
        case .idle, .done: "done"
        }
    }

    static func hostSummary(_ host: FleetHost, running: Int) -> String {
        switch host.phase {
        case .connecting: return "Connecting…"
        case .failed(let failure): return failure.message(host: host.name)
        case .disconnected: return "Not connected"
        case .connected: break
        }
        let agents = host.state.agents.filter { agent in
            !(host.state.spaces.first { $0.id == agent.spaceID }?.hidden ?? false)
        }
        guard !agents.isEmpty else { return "No threads yet" }
        let busy = Set(agents.filter { $0.status == .working }.map(\.spaceID))
        let places = host.state.spaces.filter { busy.contains($0.id) }.map(\.name)
        if running > 0 {
            return (["\(nativeCount(running, "thread")) running"] + [places.joined(separator: ", ")].filter { !$0.isEmpty })
                .joined(separator: " · ")
        }
        return "\(nativeCount(agents.count, "thread")) · none running"
    }

    static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// The text of a Needs you row's reason chip, shared by the Mac's sidebar and the iPad's.
public enum NeedsYouReason {
    /// The longest chip ("approve plan"); the Mac reads it as `NWSidebarMetrics.reasonLength`.
    public static let length = 14

    /// One line, at most `limit` characters: cut at a word where one ends past the middle, with
    /// an ellipsis.
    public static func shortened(_ text: String, limit: Int = length) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        let clipped = flat.prefix(limit - 1)
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) >= limit / 2 {
            return clipped[..<space].trimmingCharacters(in: .punctuationCharacters) + "…"
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}
