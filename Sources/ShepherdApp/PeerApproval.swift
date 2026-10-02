import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions

/// What `PeerApprovalDialog` says about one call an agent made on another thread, from the names
/// and folders the app holds now. Plain values, so every state is table-tested and rendered from
/// this and not from copy written beside it.
struct PeerApprovalPresentation: Equatable {
    struct Row: Equatable, Identifiable {
        enum Style: Equatable {
            /// The thread's name.
            case name
            case secondary
            /// A folder or branch.
            case mono
        }

        let label: String
        let value: String
        let style: Style
        var id: String { label }
    }

    let title: String
    let subtitle: String
    let rows: [Row]
    /// The message or prompt, clipped, and what its row is called; nil when the call carries none.
    let textLabel: String?
    let text: String?
    /// What "Allow for this thread" covers.
    let note: String
    /// "2 more waiting", when other calls are queued behind this one.
    let status: String?

    /// How much of a long message the dialog shows: the rest is counted, not drawn.
    static let textLimit = 4_000
    /// `AgentMessageGate.approvalTimeout`, in the words the subtitle uses.
    static let timeoutWords = "two minutes"

    static func make(_ prompt: AgentApprovalPrompt, in state: ShepherdState, waiting: Int) -> PeerApprovalPresentation {
        let sender = state.agents.first { $0.id == prompt.senderID }?.name
        let asker = quoted(sender, fallback: "An agent")
        let target = prompt.action.targetAgentID.flatMap { id in state.agents.first { $0.id == id } }
        let named = quoted(target?.name, fallback: "another thread")
        let askedBy = Row(label: "Asked by", value: sender ?? "An agent", style: .secondary)
        var rows: [Row] = []
        var textLabel: String?
        var text: String?
        let title: String
        let what: String

        switch prompt.action {
        case .send(_, let message, let delivery):
            title = "Message another thread"
            what = delivery == .report ? "wants to send \(named) a report" : "wants to message \(named)"
            rows = targetRows(target, in: state)
            rows.append(Row(label: "Delivery", value: delivery == .report ? "Context only, starts no turn" : "Starts or queues a turn",
                            style: .secondary))
            (textLabel, text) = ("Message", clipped(message))
        case .steer(_, let message):
            title = "Steer another thread"
            what = "wants to steer \(named)"
            rows = targetRows(target, in: state)
            rows.append(Row(label: "Delivery", value: "Lands at its next step, or starts an idle thread", style: .secondary))
            (textLabel, text) = ("Message", clipped(message))
        case .interrupt:
            title = "Interrupt another thread"
            what = "wants to stop what \(named) is doing"
            rows = targetRows(target, in: state)
        case .read:
            title = "Read another thread"
            what = "wants to read \(named)'s conversation"
            rows = targetRows(target, in: state)
        case .spawn(let cwd, let prompt):
            title = "Start a new thread"
            what = "wants to start a new thread"
            rows = [Row(label: "Folder", value: (cwd as NSString).abbreviatingWithTildeInPath, style: .mono)]
            (textLabel, text) = ("Prompt", clipped(prompt))
        }
        rows.append(askedBy)
        return PeerApprovalPresentation(
            title: title,
            subtitle: "\(asker) \(what). If you don't answer within \(timeoutWords), it is denied.",
            rows: rows,
            textLabel: textLabel,
            text: text,
            note: "Allow for this thread lets \(asker) message, steer, interrupt, read and start threads until you quit Shepherd or its pi restarts.",
            status: waiting > 0 ? "\(waiting) more waiting" : nil)
    }

    /// The thread the call acts on: its name, which of its branch or folder tells it from another
    /// thread of the same name, and its space.
    private static func targetRows(_ agent: Agent?, in state: ShepherdState) -> [Row] {
        guard let agent else { return [Row(label: "To", value: "Another thread", style: .secondary)] }
        var rows = [Row(label: "To", value: agent.name, style: .name)]
        if let branch = agent.worktreeBranch {
            rows.append(Row(label: "Branch", value: branch, style: .mono))
        } else if let directory = state.tabs.first(where: { $0.id == agent.tabID })?.layout.leaves.first(where: { $0.agentID == agent.id })?.cwd {
            rows.append(Row(label: "Directory", value: (directory as NSString).abbreviatingWithTildeInPath, style: .mono))
        }
        if let space = state.spaces.first(where: { $0.id == agent.spaceID })?.name {
            rows.append(Row(label: "Space", value: space, style: .secondary))
        }
        return rows
    }

    /// A name inside a sentence, set off so a name made of words reads as one.
    private static func quoted(_ name: String?, fallback: String) -> String {
        name.map { "“\($0)”" } ?? fallback
    }

    /// `text`, or its first `textLimit` characters and how many more there are.
    static func clipped(_ text: String) -> String {
        guard text.count > textLimit else { return text }
        return String(text.prefix(textLimit)) + "\n… \(text.count - textLimit) more characters"
    }
}
