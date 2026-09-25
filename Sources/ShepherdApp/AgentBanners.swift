import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// One system notification, decided apart from UserNotifications so the rules can be tested.
struct AgentBanner: Equatable {
    /// A newer banner with the same identifier replaces the older one.
    let identifier: String
    /// Clicking the banner selects this agent.
    let agentID: AgentID
    let title: String
    let body: String
    let sound: Bool
}

enum AgentBanners {
    /// The longest error or question a banner quotes, in characters.
    static let quoteLimit = 200

    /// A status report's banner: a turn that finished or failed, or the agent asking a question.
    /// Only working→done and working→blocked want you; idle churn (launch resets, session
    /// restarts) does not, and neither does anything while you're `watching` the agent.
    static func status(of agent: Agent, from old: AgentStatus, failure: TurnFailure?, watching: Bool) -> AgentBanner? {
        guard old == .working, agent.status == .done || agent.status == .blocked, !watching else { return nil }
        let body: String
        if agent.status == .blocked {
            body = "Agent needs your input"
        } else if let failure {
            body = lines("Turn failed", quote(failure.message))
        } else {
            body = "Agent finished"
        }
        // One banner per agent: a newer status replaces the older one.
        return AgentBanner(identifier: "agent-status-\(agent.id.rawValue)", agentID: agent.id, title: agent.name,
                           body: body, sound: agent.status == .blocked || failure != nil)
    }

    /// A subagent's question, under its agent's name. Each run has its own banner, so two
    /// subagents asking at once both show.
    static func subagentQuestion(_ run: ChildRun, of agent: Agent) -> AgentBanner {
        AgentBanner(identifier: "agent-subagent-\(agent.id.rawValue)-\(run.id)", agentID: agent.id, title: agent.name,
                    body: lines("Subagent \(run.label) needs your input", quote(SubagentAsks.question(run))),
                    sound: true)
    }

    /// The first line of `text`, cut to `quoteLimit`.
    static func quote(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else { return nil }
        return line.count > quoteLimit ? String(line.prefix(quoteLimit - 1)) + "…" : line
    }

    private static func lines(_ first: String, _ second: String?) -> String {
        second.map { "\(first)\n\($0)" } ?? first
    }
}

/// Which subagent runs are asking, per agent, so a banner goes up once per question: when a
/// run starts asking, or asks something new. The extension republishes every 45 s, and the
/// sidebar's rows can be swept, so this keeps its own memory.
struct SubagentAsks {
    private var asking: [AgentID: [String: String]] = [:]

    /// Takes an agent's full published runs and returns those that began asking since the last.
    mutating func update(agentID: AgentID, children: [ChildRun]) -> [ChildRun] {
        let previous = asking[agentID] ?? [:]
        var current: [String: String] = [:]
        var started: [ChildRun] = []
        for run in children where run.needsAttention {
            let question = Self.question(run) ?? ""
            current[run.id] = question
            if previous[run.id] != question { started.append(run) }
        }
        asking[agentID] = current.isEmpty ? nil : current
        return started
    }

    mutating func forget(_ agentID: AgentID) {
        asking.removeValue(forKey: agentID)
    }

    static func question(_ run: ChildRun) -> String? {
        run.question?.text ?? run.attentionText
    }
}
