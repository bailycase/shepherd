import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a banner is about: clicking it (or Open) goes there.
public enum BannerTarget: Hashable, Sendable {
    case agent(AgentID)
    case remote(RemoteAgentRef)
    case host(UUID)

    /// The id text inside identifiers and `threadIdentifier`s: a remote agent's carries its host.
    public var key: String {
        switch self {
        case .agent(let id): id.rawValue
        case .remote(let ref): "\(ref.hostID.uuidString)/\(ref.agentID.rawValue)"
        case .host(let id): id.uuidString
        }
    }
}

/// A banner's action, in the order the catalog gives them (NotifCatalog › Actions and answering).
public enum BannerAction: Equatable, Sendable {
    /// Open Shepherd at the thing.
    case open
    /// Send the prompt that opened a failed turn again.
    case retry
    /// Open the thread's Changes.
    case review
    /// Reconnect to a host now.
    case reconnect
    /// One of a question's options, by its number.
    case option(Int, title: String)
    /// A typed answer: Reply…, answered with Send.
    case reply(placeholder: String)

    public var identifier: String {
        switch self {
        case .open: "open"
        case .retry: "retry"
        case .review: "review"
        case .reconnect: "reconnect"
        case .option(let number, _): "option.\(number)"
        case .reply: "reply"
        }
    }

    public var title: String {
        switch self {
        case .open: "Open"
        case .retry, .reconnect: "Retry"
        case .review: "Review"
        case .option(_, let title): title
        case .reply: "Reply…"
        }
    }

    /// Open and Review bring Shepherd forward; answering and retrying never do.
    public var opensShepherd: Bool {
        switch self {
        case .open, .review: true
        case .retry, .reconnect, .option, .reply: false
        }
    }

    /// The action a response identifier names, given the banner's actions.
    public static func named(_ identifier: String, in actions: [BannerAction]) -> BannerAction? {
        actions.first { $0.identifier == identifier }
    }
}

/// One system notification, decided apart from UserNotifications so the rules can be tested
/// (NotifCatalog, NotifMac): the title names the thing, the subtitle is the kind, the body one
/// sentence, and the actions are the choices the app shows for that moment.
public struct AgentBanner: Equatable, Sendable {
    /// How loud: finished work is quiet (Passive); what needs you and problems are Active.
    public enum Level: Equatable, Sendable { case active, passive }

    /// A newer banner with the same identifier replaces the older one.
    public let identifier: String
    public let target: BannerTarget
    public let title: String
    /// The kind ("Turn finished", "Question"), or nothing for the notify tool's own.
    public let subtitle: String?
    public let body: String
    public let level: Level
    public let actions: [BannerAction]
    /// Grouped by the thing, not the app: a thread's banners stack together.
    public let group: String
    /// What a question's actions answer: pi's dialog id.
    public var question: String? = nil
    /// Continue's immutable checkpoint, captured when this banner was posted.
    public var recovery: NativeThreadRequest? = nil

    public var sound: Bool { level == .active }

    public init(identifier: String, target: BannerTarget, title: String, subtitle: String?, body: String, level: Level,
                actions: [BannerAction], group: String, question: String? = nil, recovery: NativeThreadRequest? = nil) {
        self.identifier = identifier
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.actions = actions
        self.group = group
        self.question = question
        self.recovery = recovery
    }
}

public enum AgentBanners {
    public static func recovery(in snapshot: NativeThreadSnapshot) -> NativeThreadRequest? {
        guard !snapshot.running, snapshot.dialogs.isEmpty,
              snapshot.supportedActions.contains("checkpointRecovery"),
              let checkpoint = snapshot.checkpointRecovery?.checkpoint,
              let entryID = lastPromptEntry(in: snapshot.messages) else { return nil }
        return .retry(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation,
                      operationID: checkpoint.operationID(sessionID: snapshot.piSessionID),
                      entryID: entryID, checkpoint: checkpoint)
    }

    public static func matchesRecovery(_ request: NativeThreadRequest, in snapshot: NativeThreadSnapshot) -> Bool {
        guard case .retry(let sessionID, let generation, _, let entryID, let checkpoint) = request,
              let checkpoint else { return false }
        return !snapshot.running && snapshot.dialogs.isEmpty && snapshot.supportedActions.contains("checkpointRecovery") &&
            sessionID == snapshot.piSessionID && generation == snapshot.generation &&
            checkpoint == snapshot.checkpointRecovery?.checkpoint && entryID == lastPromptEntry(in: snapshot.messages)
    }

    /// The longest error, question or result a banner quotes, in characters.
    public static let quoteLimit = 200

    /// A status report's banner: a turn that finished or failed. Only working→done wants you;
    /// idle churn (launch resets, session restarts) does not, and neither does anything while
    /// you're `watching` the agent. `result` is the turn's closing sentence, when it had one.
    public static func status(of agent: Agent, from old: AgentStatus, failure: TurnFailure?, result: String? = nil,
                       watching: Bool) -> AgentBanner? {
        guard old == .working, agent.status == .done, !watching else { return nil }
        // Only unattended goal work suppresses an ordinary turn's completion.
        guard agent.goalState != "working", agent.goalState != "checking" else { return nil }
        let target = BannerTarget.agent(agent.id)
        if let failure {
            return AgentBanner(identifier: identifier("status", target), target: target, title: agent.name,
                               subtitle: "Turn failed", body: quote(failure.message) ?? "The model request failed.",
                               level: .active, actions: [.retry, .open], group: group(target))
        }
        return AgentBanner(identifier: identifier("status", target), target: target, title: agent.name,
                           subtitle: "Turn finished", body: quote(result) ?? "Finished its turn.",
                           level: .passive, actions: [.review], group: group(target))
    }

    /// A question the thread asks (a pi dialog, `Agent.waitingOn`): its title as the body and
    /// the dock's choices as actions. An automation's run asks as "Automation question".
    public static func question(_ prompt: NativeQuestionPrompt?, asked: String, title: String, target: BannerTarget,
                         automation: Bool) -> AgentBanner {
        AgentBanner(identifier: identifier("question", target), target: target, title: title,
                    subtitle: automation ? "Automation question" : "Question",
                    body: quote(prompt?.question) ?? quote(asked) ?? asked, level: .active,
                    actions: prompt.map(answers) ?? [.open], group: group(target), question: prompt?.id)
    }

    /// The thread waits on you with no question to show (an asking tool that opened no dialog).
    public static func waiting(_ agent: Agent) -> AgentBanner {
        let target = BannerTarget.agent(agent.id)
        return AgentBanner(identifier: identifier("question", target), target: target, title: agent.name,
                           subtitle: "Question", body: "Waiting on your answer.", level: .active, actions: [.open],
                           group: group(target))
    }

    /// A remote host that went away while Shepherd was connected to it.
    public static func hostOffline(name: String, hostID: UUID) -> AgentBanner {
        let target = BannerTarget.host(hostID)
        return AgentBanner(identifier: identifier("offline", target), target: target, title: "\(name) is offline",
                           subtitle: "Host offline", body: "Remote agents resume when it’s back.", level: .active,
                           actions: [.reconnect], group: "host:\(target.key)")
    }

    /// Automation banners name no thread; clicking one opens nothing in particular.
    public static let automationsHost = UUID(uuidString: "00000000-0000-0000-0000-00000000a170")!
    /// Closed-thread banners name no thread either.
    public static let pullRequestHost = UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!

    /// An automation could not run, or a trigger needs you.
    public static func automation(title: String, body: String) -> AgentBanner {
        AgentBanner(identifier: "automation-\(title)", target: .host(automationsHost), title: title,
                    subtitle: "Automation", body: body, level: .active, actions: [], group: "automations")
    }

    /// A merged pull request's thread was closed (Settings ▸ Worktrees).
    public static func pullRequestClosed(_ agent: Agent, number: Int, branch: String, remote: String) -> AgentBanner {
        AgentBanner(identifier: "pull-request-closed-\(agent.id.rawValue)", target: .host(pullRequestHost),
                    title: "Closed \(agent.name)", subtitle: "Pull request #\(number) merged",
                    body: "Deleted the thread, its worktree, \(branch) and \(remote).", level: .passive, actions: [],
                    group: "pull-request-closed")
    }

    /// A merged pull request's thread was kept, for `reason`.
    public static func pullRequestKept(_ agent: Agent, number: Int, reason: String) -> AgentBanner {
        let target = BannerTarget.agent(agent.id)
        return AgentBanner(identifier: "pull-request-kept-\(agent.id.rawValue)", target: target,
                           title: "Kept \(agent.name)", subtitle: "Pull request #\(number) merged",
                           body: "Not closed: \(reason).", level: .active, actions: [], group: group(target))
    }

    /// A custom notification from an agent's notify tool. Always posted: the agent explicitly
    /// asked, so visibility rules don't apply. Grouped with its thread.
    public static func agentNotify(_ agent: Agent, title: String, body: String) -> AgentBanner {
        let target = BannerTarget.agent(agent.id)
        return AgentBanner(identifier: UUID().uuidString, target: target, title: title, subtitle: nil,
                           body: body.isEmpty ? agent.name : "\(agent.name)\n\(body)", level: .active, actions: [],
                           group: group(target))
    }

    /// A question's actions: each option the asker offered, then Reply… for an open question.
    /// A question that can't be answered from here has only Open.
    public static func answers(_ prompt: NativeQuestionPrompt) -> [BannerAction] {
        guard prompt.blocked == nil else { return [.open] }
        var actions = prompt.options.map { BannerAction.option($0.number, title: $0.title) }
        if prompt.kind == .open { actions.append(.reply(placeholder: prompt.placeholder)) }
        return actions.isEmpty ? [.open] : actions
    }

    /// What a banner's action answers: an option by its number, or the words typed into Reply….
    public static func answer(_ prompt: NativeQuestionPrompt, option: Int?, words: String?) -> NativeQuestionAnswer? {
        if let option {
            return prompt.options.first { $0.number == option }.map { .option($0) }
        }
        let text = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : .words(prompt.reply == .editor ? words ?? text : text)
    }

    public static func identifier(_ kind: String, _ target: BannerTarget) -> String { "shepherd-\(kind)-\(target.key)" }

    public static func group(_ target: BannerTarget) -> String { "thread:\(target.key)" }

    /// The first line of `text`, cut to `quoteLimit`.
    public static func quote(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line.count > quoteLimit ? String(line.prefix(quoteLimit - 1)) + "…" : line
    }

    /// A finished turn's result: the first line of the agent's closing reply ("Done. 3 files
    /// changed, tests pass."), its Markdown markers dropped; nil when the reply has no words.
    public static func result(_ reply: String?) -> String? {
        quote(reply.map(plain))
    }

    /// The last reply in `messages` after the last prompt: the text an agent closed its turn with.
    public static func closingReply(in messages: [NativeThreadMessage]) -> String? {
        for message in messages.reversed() {
            if message.role == "user" { return nil }
            guard message.role == "assistant" else { continue }
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The prompt that opened the last turn in `messages`, for Retry.
    public static func lastPrompt(in messages: [NativeThreadMessage]) -> String? {
        guard let message = messages.last(where: { $0.role == "user" && $0.status != "queued" }) else { return nil }
        let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// The user message that opened the last turn in `messages`, which Retry sends again in place:
    /// the last one pi has read that wasn't steered into a turn.
    public static func lastPromptEntry(in messages: [NativeThreadMessage]) -> String? {
        messages.last { $0.role == "user" && $0.status == nil && $0.origin != .steered }?.entryID
    }

    /// A line of Markdown as a sentence: headings, emphasis, code ticks and bullets dropped.
    private static func plain(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { line in
                var line = line.trimmingCharacters(in: .whitespaces)
                while let first = line.first, "#>-*+".contains(first) { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Which question each thread asks, so a question posts once and its banner goes when it is
/// answered: the agent's `waitingOn`, as the host last reported it.
public struct ThreadAsks<Key: Hashable> {
    private var asked: [Key: String] = [:]

    public init() {}

    public enum Change: Equatable {
        /// A new question (or another one): post it.
        case asked(String)
        /// Nothing asked any more: take its banner down.
        case answered
    }

    public mutating func update(_ key: Key, waitingOn: String?) -> Change? {
        let question = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = question?.isEmpty == false ? question : nil
        let before = asked[key]
        guard now != before else { return nil }
        asked[key] = now
        if let now { return .asked(now) }
        return .answered
    }

    public func isAsking(_ key: Key) -> Bool { asked[key] != nil }

    /// The question `key` asks now.
    public func current(_ key: Key) -> String? { asked[key] }

    public mutating func forget(_ key: Key) { asked.removeValue(forKey: key) }

    /// Drops the keys `drop` picks, returning them.
    public mutating func prune(_ drop: (Key) -> Bool) -> [Key] {
        let gone = asked.keys.filter(drop)
        for key in gone { asked.removeValue(forKey: key) }
        return gone
    }
}
