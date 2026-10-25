import Foundation
import ShepherdCore

// What a Project's page draws, as plain Equatable values derived once from the Project record the owner pushed
// (ProjectLead boards). Nothing here is sample text: a task's words are its own title, question and phase; the
// counts are counted; a phase the runtime has not reached is not drawn.

/// The right pane's groups: the boards' Waiting on you, Working and Resolved, plus Stopped: a settled turn is neither still
/// working nor reviewed, so it is drawn on its own rather than with a running dot.
public enum ProjectTaskGroup: String, CaseIterable, Equatable {
    case waiting = "Waiting on you"
    case working = "Working"
    case stopped = "Stopped"
    case resolved = "Resolved"
}

/// One file a task published, from the owner's host-validated receipt (state `ready`, this task's ID). A file name the model
/// wrote in prose, or a staged, refused or unverified receipt, is never one.
public struct ProjectTaskFile: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    /// Owner-relative: what the owner's `read` takes, never a path on this Mac.
    public let relativePath: String
    public let size: Int64
}

public struct ProjectTaskRow: Identifiable, Equatable {
    public let id: ProjectTaskID
    public let title: String
    public let group: ProjectTaskGroup
    public let phase: ProjectTask.Phase
    /// "Blocked · <question>" for a waiting task, its failure for a failed one, a stopped or resolved task's recorded outcome evidence,
    /// else nil.
    public let detail: String?
    /// The word before the detail ("Blocked", "Stopped", "Accepted"), drawn in `lanternText`.
    public let lead: String?
    public let workerAgentID: AgentID
    public let spaceID: SpaceID
    public let revision: UInt64
    /// A settled task the user may resolve. A resolved task is terminal: no row offers to reopen it.
    public let canResolve: Bool
    /// Seconds since 1970 of the last settlement, for the row's age.
    public let settledAt: Double?
    /// The task's ready published files, in publication order.
    public let files: [ProjectTaskFile]
    /// The operations that delivered the coordinator's assignment to the worker: its first user message carries one, which is how
    /// the worker thread tells the assignment from a person's own steering message.
    public let assignmentOperations: Set<UUID>
    /// The owner already holds the person's answer to this task's question (any phase of it but delivered).
    public var answerHeld = false
}

/// A Project's page state: its counts and rows, never computed in a view body.
public struct ProjectPagePresentation: Equatable {
    public let projectID: ProjectID
    public let name: String
    public let conversationAgent: AgentID?
    public let rows: [ProjectTaskRow]
    public let waiting: Int
    /// Queued, reserved or running: work actually in progress. A settled task has stopped, not finished successfully.
    public let working: Int
    public let resolved: Int
    /// Turn stopped, assignment not resolved: no review is implied, and it is never counted as done.
    public let settled: Int

    public var needsYou: Int { waiting }
    public var total: Int { rows.count }

    /// "1 needs you · 2 working · 1 stopped · 3 resolved": each execution fact counted from the tasks, zeros left out. A Project is
    /// a long-lived workspace, not one campaign, so nothing is "N of M done": a stopped turn is not success and resolution is not
    /// delivery. nil without tasks.
    public var summary: String? {
        guard total > 0 else { return nil }
        let parts = [(waiting, "needs you"), (working, "working"), (settled, "stopped"), (resolved, "resolved")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.joined(separator: " · ")
    }

    /// The pane's sentence under "Welcome back": "3 threads are working.", "1 thread is waiting on you."
    public var status: String {
        func threads(_ n: Int) -> String { n == 1 ? "1 thread" : "\(n) threads" }
        if total == 0 { return "Nothing running yet." }
        if waiting > 0 { return "\(threads(waiting)) \(waiting == 1 ? "is" : "are") waiting on you." }
        if working > 0 { return "\(threads(working)) \(working == 1 ? "is" : "are") working." }
        return "Nothing is running."
    }

    public func rows(in group: ProjectTaskGroup) -> [ProjectTaskRow] { rows.filter { $0.group == group } }

    public init(_ project: Project) {
        projectID = project.id
        name = project.name
        conversationAgent = project.coordinatorAgentID
        let published = Dictionary(grouping: project.artifacts.filter { $0.state == .ready }, by: \.taskID)
        let built = project.tasks.map { task in
            Self.row(task, files: (published[task.id] ?? []).map {
                ProjectTaskFile(id: $0.id, name: $0.artifactName, relativePath: $0.relativePath, size: $0.size)
            })
        }
        rows = built
        waiting = built.filter { $0.group == .waiting }.count
        working = built.filter { $0.group == .working }.count
        settled = built.filter { $0.phase == .settled }.count
        resolved = built.filter { $0.group == .resolved }.count
    }

    /// The word before the line for an answer the owner holds: queued waits for Resume, delivering is on its way, failed and unknown
    /// are honest about not knowing the worker got it.
    public static func answerLead(_ phase: ProjectQuestionAnswer.Phase) -> String {
        switch phase {
        case .queued: "Answer queued"
        case .delivering: "Answering"
        case .delivered: "Answered"
        case .failed: "Answer failed"
        case .unknown: "Answer unconfirmed"
        }
    }

    public static func answerDetail(_ phase: ProjectQuestionAnswer.Phase) -> String? {
        switch phase {
        case .queued: "Waiting to send."
        case .delivering: nil
        case .delivered: nil
        case .failed: "The question changed before it could be sent. Open the thread to answer again."
        case .unknown: "Shepherd restarted before it knew the worker got it. Open the thread to check."
        }
    }

    public static let noOutcome = "No outcome recorded"

    /// "Merged · PR #12 · per coordinator": the fact, its evidence as recorded, and who recorded it, always. Neither attribution is a
    /// person's approval: the coordinator's is its own claim, and an owner-control record says only where it came from.
    public static func outcome(_ outcome: ProjectTaskOutcome) -> (String, String?) {
        (outcome.kind.label, [outcome.evidence, outcome.recordedBy == nil ? "recorded by owner" : "per coordinator"].compactMap { $0 }.joined(separator: " · "))
    }

    private static func row(_ task: ProjectTask, files: [ProjectTaskFile]) -> ProjectTaskRow {
        let group: ProjectTaskGroup
        var lead: String?, detail: String?
        switch task.phase {
        case .waiting:
            group = .waiting; lead = "Blocked"; detail = task.question
            // An answer the person already gave is said in words. The envelope itself is never read here, shown or logged.
            if let answer = task.pendingAnswer { lead = Self.answerLead(answer.phase); detail = Self.answerDetail(answer.phase) ?? task.question }
        case .resolved:
            // No recorded outcome stays unknown: resolution alone claims no acceptance, merge or release.
            group = .resolved
            if let outcome = task.currentOutcome { (lead, detail) = Self.outcome(outcome) }
        case .failed:
            group = .waiting; lead = "Failed"; detail = task.error
        case .unknown:
            group = .waiting; lead = "Unknown"; detail = "The host did not confirm what happened. Open the thread to check."
        case .queued:
            group = .working; lead = "Queued"; detail = nil
        case .reserved, .running:
            group = .working
        case .settled:
            group = .stopped
            // Settled proves only that the turn stopped. Review is optional, so without a fact for THIS run nothing is claimed.
            (lead, detail) = task.currentOutcome.map(Self.outcome) ?? ("Stopped", Self.noOutcome)
        }
        return ProjectTaskRow(id: task.id, title: task.title, group: group, phase: task.phase, detail: detail, lead: lead,
                              workerAgentID: task.workerAgentID, spaceID: task.spaceID, revision: task.revision,
                              canResolve: task.phase == .settled, settledAt: task.settledAt, files: files,
                              assignmentOperations: Set([task.operationID] + [task.nativeDeliveryID].compactMap { $0 }),
                              answerHeld: task.pendingAnswer != nil)
    }
}
