import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// What a banner is about: clicking it (or Open) goes there.
enum BannerTarget: Hashable {
    case agent(AgentID)
    case remote(RemoteAgentRef)
    case host(UUID)

    /// The id text inside identifiers and `threadIdentifier`s: a remote agent's carries its host.
    var key: String {
        switch self {
        case .agent(let id): id.rawValue
        case .remote(let ref): "\(ref.hostID.uuidString)/\(ref.agentID.rawValue)"
        case .host(let id): id.uuidString
        }
    }
}

/// A banner's action, in the order the catalog gives them (NotifCatalog › Actions and answering).
enum BannerAction: Equatable {
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

    var identifier: String {
        switch self {
        case .open: "open"
        case .retry: "retry"
        case .review: "review"
        case .reconnect: "reconnect"
        case .option(let number, _): "option.\(number)"
        case .reply: "reply"
        }
    }

    var title: String {
        switch self {
        case .open: "Open"
        case .retry, .reconnect: "Retry"
        case .review: "Review"
        case .option(_, let title): title
        case .reply: "Reply…"
        }
    }

    /// Open and Review bring Shepherd forward; answering and retrying never do.
    var opensShepherd: Bool {
        switch self {
        case .open, .review: true
        case .retry, .reconnect, .option, .reply: false
        }
    }

    /// The action a response identifier names, given the banner's actions.
    static func named(_ identifier: String, in actions: [BannerAction]) -> BannerAction? {
        actions.first { $0.identifier == identifier }
    }
}

/// One system notification, decided apart from UserNotifications so the rules can be tested
/// (NotifCatalog, NotifMac): the title names the thing, the subtitle is the kind, the body one
/// sentence, and the actions are the choices the app shows for that moment.
struct AgentBanner: Equatable {
    /// How loud: finished work is quiet (Passive); what needs you and problems are Active.
    enum Level: Equatable { case active, passive }

    /// A newer banner with the same identifier replaces the older one.
    let identifier: String
    let target: BannerTarget
    let title: String
    /// The kind ("Turn finished", "Subagent question"), or nothing for the notify tool's own.
    let subtitle: String?
    let body: String
    let level: Level
    let actions: [BannerAction]
    /// Grouped by the thing, not the app: a thread's banners stack together.
    let group: String
    /// What a question's actions answer: pi's dialog id, or the subagent run's id.
    var question: String? = nil

    var sound: Bool { level == .active }
}

enum AgentBanners {
    /// The longest error, question or result a banner quotes, in characters.
    static let quoteLimit = 200

    /// What a subagent run asks: its question, or the attention text it published.
    static func runQuestion(_ run: ChildRun) -> String? {
        run.question?.text ?? run.attentionText
    }

    /// A status report's banner: a turn that finished or failed. Only working→done wants you;
    /// idle churn (launch resets, session restarts) does not, and neither does anything while
    /// you're `watching` the agent. `result` is the turn's closing sentence, when it had one.
    static func status(of agent: Agent, from old: AgentStatus, failure: TurnFailure?, result: String? = nil,
                       watching: Bool) -> AgentBanner? {
        guard old == .working, agent.status == .done, !watching else { return nil }
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
    static func question(_ prompt: NativeQuestionPrompt?, asked: String, title: String, target: BannerTarget,
                         automation: Bool) -> AgentBanner {
        AgentBanner(identifier: identifier("question", target), target: target, title: title,
                    subtitle: automation ? "Automation question" : "Question",
                    body: quote(prompt?.question) ?? quote(asked) ?? asked, level: .active,
                    actions: prompt.map(answers) ?? [.open], group: group(target), question: prompt?.id)
    }

    /// The thread waits on you with no question to show (an asking tool that opened no dialog).
    static func waiting(_ agent: Agent) -> AgentBanner {
        let target = BannerTarget.agent(agent.id)
        return AgentBanner(identifier: identifier("question", target), target: target, title: agent.name,
                           subtitle: "Question", body: "Waiting on your answer.", level: .active, actions: [.open],
                           group: group(target))
    }

    /// A subagent's question: "thread · subagent", its options, then Reply….
    static func subagentQuestion(_ run: ChildRun, of agentName: String, target: BannerTarget) -> AgentBanner {
        let name = nativeRunNames(run).name
        let prompt = NativeQuestionPrompt(runID: run.runID, name: name, question: AgentBanners.runQuestion(run) ?? "",
                                          options: run.question?.options)
        return AgentBanner(identifier: subagentIdentifier(run.id, target), target: target, title: "\(agentName) · \(name)",
                           subtitle: "Subagent question", body: quote(AgentBanners.runQuestion(run)) ?? "Waiting on your answer.",
                           level: .active, actions: answers(prompt), group: group(target), question: run.runID)
    }

    /// A remote host that went away while Shepherd was connected to it.
    static func hostOffline(name: String, hostID: UUID) -> AgentBanner {
        let target = BannerTarget.host(hostID)
        return AgentBanner(identifier: identifier("offline", target), target: target, title: "\(name) is offline",
                           subtitle: "Host offline", body: "Remote agents resume when it’s back.", level: .active,
                           actions: [.reconnect], group: "host:\(target.key)")
    }

    /// A question's actions: each option the asker offered, then Reply… where it takes words.
    /// A question that can't be answered from here has only Open.
    static func answers(_ prompt: NativeQuestionPrompt) -> [BannerAction] {
        guard prompt.blocked == nil else { return [.open] }
        var actions = prompt.options.map { BannerAction.option($0.number, title: $0.title) }
        if prompt.kind == .open || prompt.takesOther { actions.append(.reply(placeholder: prompt.placeholder)) }
        return actions.isEmpty ? [.open] : actions
    }

    /// What a banner's action answers: an option by its number, or the words typed into Reply….
    static func answer(_ prompt: NativeQuestionPrompt, option: Int?, words: String?) -> NativeQuestionAnswer? {
        if let option {
            return prompt.options.first { $0.number == option }.map { .option($0, note: nil) }
        }
        let text = words?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : .words(prompt.reply == .editor ? words ?? text : text)
    }

    static func identifier(_ kind: String, _ target: BannerTarget) -> String { "shepherd-\(kind)-\(target.key)" }

    static func subagentIdentifier(_ runID: String, _ target: BannerTarget) -> String { "shepherd-subagent-\(target.key)-\(runID)" }

    static func group(_ target: BannerTarget) -> String { "thread:\(target.key)" }

    /// The first line of `text`, cut to `quoteLimit`.
    static func quote(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line.count > quoteLimit ? String(line.prefix(quoteLimit - 1)) + "…" : line
    }

    /// A finished turn's result: the first line of the agent's closing reply ("Done. 3 files
    /// changed, tests pass."), its Markdown markers dropped; nil when the reply has no words.
    static func result(_ reply: String?) -> String? {
        quote(reply.map(plain))
    }

    /// The last reply in `messages` after the last prompt: the text an agent closed its turn with.
    static func closingReply(in messages: [NativeThreadMessage]) -> String? {
        for message in messages.reversed() {
            if message.role == "user" { return nil }
            guard message.role == "assistant" else { continue }
            let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        }
        return nil
    }

    /// The prompt that opened the last turn in `messages`, for Retry.
    static func lastPrompt(in messages: [NativeThreadMessage]) -> String? {
        guard let message = messages.last(where: { $0.role == "user" && $0.status != "queued" }) else { return nil }
        let text = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
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

/// Which subagent runs are asking, per agent, so a banner goes up once per question: when a
/// run starts asking, or asks something new. The extension republishes every 45 s, and the
/// sidebar's rows can be swept, so this keeps its own memory.
struct SubagentAsks<Key: Hashable> {
    private var asking: [Key: [String: String]] = [:]

    /// Takes an agent's full published runs and returns those that began asking since the last,
    /// and the ids of runs that stopped asking (answered, or gone).
    mutating func update(_ key: Key, children: [ChildRun]) -> (asking: [ChildRun], answered: [String]) {
        let previous = asking[key] ?? [:]
        var current: [String: String] = [:]
        var started: [ChildRun] = []
        for run in children where run.needsAttention {
            let question = AgentBanners.runQuestion(run) ?? ""
            current[run.id] = question
            if previous[run.id] != question { started.append(run) }
        }
        asking[key] = current.isEmpty ? nil : current
        return (started, previous.keys.filter { current[$0] == nil }.sorted())
    }

    /// Forgets `key`, returning the runs it had asking.
    @discardableResult
    mutating func forget(_ key: Key) -> [String] {
        asking.removeValue(forKey: key).map { $0.keys.sorted() } ?? []
    }
}

/// Which question each thread asks, so a question posts once and its banner goes when it is
/// answered: the agent's `waitingOn`, as the host last reported it.
struct ThreadAsks<Key: Hashable> {
    private var asked: [Key: String] = [:]

    enum Change: Equatable {
        /// A new question (or another one): post it.
        case asked(String)
        /// Nothing asked any more: take its banner down.
        case answered
    }

    mutating func update(_ key: Key, waitingOn: String?) -> Change? {
        let question = waitingOn?.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = question?.isEmpty == false ? question : nil
        let before = asked[key]
        guard now != before else { return nil }
        asked[key] = now
        if let now { return .asked(now) }
        return .answered
    }

    func isAsking(_ key: Key) -> Bool { asked[key] != nil }

    /// The question `key` asks now.
    func current(_ key: Key) -> String? { asked[key] }

    mutating func forget(_ key: Key) { asked.removeValue(forKey: key) }

    /// Drops the keys `drop` picks, returning them.
    mutating func prune(_ drop: (Key) -> Bool) -> [Key] {
        let gone = asked.keys.filter(drop)
        for key in gone { asked.removeValue(forKey: key) }
        return gone
    }
}
