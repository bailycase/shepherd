import Foundation
import ShepherdCore

// What a Project's page draws, as plain Equatable values derived once from the Project record the owner pushed
// (ProjectLead boards). Nothing here is sample text: a task's words are its own title, question and phase; the
// counts are counted; a phase the runtime has not reached is not drawn.

/// The right pane's three groups, in the boards' order: Waiting on you, Working, Resolved.
enum ProjectTaskGroup: String, CaseIterable, Equatable {
    case waiting = "Waiting on you"
    case working = "Working"
    case resolved = "Resolved"
}

/// One file a task published, from the owner's host-validated receipt (state `ready`, this task's ID). A file name the model
/// wrote in prose, or a staged, refused or unverified receipt, is never one.
struct ProjectTaskFile: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// Owner-relative: what the owner's `read` takes, never a path on this Mac.
    let relativePath: String
    let size: Int64
}

struct ProjectTaskRow: Identifiable, Equatable {
    let id: ProjectTaskID
    let title: String
    let group: ProjectTaskGroup
    let phase: ProjectTask.Phase
    /// "Blocked · <question>" for a waiting task, its failure for a failed one, else nil.
    let detail: String?
    /// The word before the question ("Blocked"), drawn in `lanternText`.
    let lead: String?
    let workerAgentID: AgentID
    let spaceID: SpaceID
    let revision: UInt64
    /// A settled task the user may resolve; a resolved one they may reopen.
    let canResolve: Bool
    let canReopen: Bool
    /// Seconds since 1970 of the last settlement, for the row's age.
    let settledAt: Double?
    /// The task's ready published files, in publication order.
    let files: [ProjectTaskFile]
    /// The operations that delivered the coordinator's assignment to the worker: its first user message carries one, which is how
    /// the worker thread tells the assignment from a person's own steering message.
    let assignmentOperations: Set<UUID>
}

/// A Project's page state: its counts and rows, never computed in a view body.
struct ProjectPagePresentation: Equatable {
    let projectID: ProjectID
    let name: String
    let paused: Bool
    let interruptPending: Bool
    let conversationAgent: AgentID?
    let rows: [ProjectTaskRow]
    let waiting: Int
    /// Queued, reserved or running: work actually in progress. A settled task is finished, not working.
    let working: Int
    let resolved: Int
    /// Finished and not yet resolved by the person. The boards draw no group for these.
    let settled: Int

    var needsYou: Int { waiting }
    var total: Int { rows.count }

    /// "2 of 3 done · 1 needs you", or "0 of 3 done · 3 in progress": counted from the tasks. nil without tasks.
    var summary: String? {
        guard total > 0 else { return nil }
        // "Done" is what the person resolved. A settled turn is not proof the task succeeded (docs/project-lead.md).
        var parts = ["\(resolved) of \(total) done"]
        if waiting > 0 { parts.append("\(waiting) needs you") }
        else if working > 0 { parts.append("\(working) in progress") }
        return parts.joined(separator: " · ")
    }

    /// The pane's sentence under "Welcome back": "3 threads are working.", "Paused. 1 thread is still waiting on you."
    var status: String {
        func threads(_ n: Int) -> String { n == 1 ? "1 thread" : "\(n) threads" }
        if total == 0 { return "Nothing running yet." }
        if paused {
            return waiting > 0 ? "Paused. \(threads(waiting)) \(waiting == 1 ? "is" : "are") still waiting on you." : "Paused."
        }
        if waiting > 0 { return "\(threads(waiting)) \(waiting == 1 ? "is" : "are") waiting on you." }
        if working > 0 { return "\(threads(working)) \(working == 1 ? "is" : "are") working." }
        return "Nothing is running."
    }

    func rows(in group: ProjectTaskGroup) -> [ProjectTaskRow] { rows.filter { $0.group == group } }

    init(_ project: Project) {
        projectID = project.id
        name = project.name
        paused = project.paused
        interruptPending = project.interruptPending
        conversationAgent = project.coordinatorAgentID
        let published = Dictionary(grouping: project.artifacts.filter { $0.state == .ready }, by: \.taskID)
        let built = project.tasks.map { task in
            Self.row(task, files: (published[task.id] ?? []).map {
                ProjectTaskFile(id: $0.id, name: $0.artifactName, relativePath: $0.relativePath, size: $0.size)
            })
        }
        rows = built
        waiting = built.filter { $0.group == .waiting }.count
        working = built.filter { $0.group == .working && $0.phase != .settled }.count
        settled = built.filter { $0.phase == .settled }.count
        resolved = built.filter { $0.group == .resolved }.count
    }

    /// The word before the line for an answer the owner holds: queued waits for Resume, delivering is on its way, failed and unknown
    /// are honest about not knowing the worker got it.
    static func answerLead(_ phase: ProjectQuestionAnswer.Phase) -> String {
        switch phase {
        case .queued: "Answer queued"
        case .delivering: "Answering"
        case .delivered: "Answered"
        case .failed: "Answer failed"
        case .unknown: "Answer unconfirmed"
        }
    }

    static func answerDetail(_ phase: ProjectQuestionAnswer.Phase) -> String? {
        switch phase {
        case .queued: "Sends when the project resumes."
        case .delivering: nil
        case .delivered: nil
        case .failed: "The question changed before it could be sent. Open the thread to answer again."
        case .unknown: "Shepherd restarted before it knew the worker got it. Open the thread to check."
        }
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
            group = .resolved
        case .failed:
            group = .waiting; lead = "Failed"; detail = task.error
        case .unknown:
            group = .waiting; lead = "Unknown"; detail = "The host did not confirm what happened. Open the thread to check."
        case .queued:
            group = .working; lead = "Queued"; detail = nil
        case .reserved, .running:
            group = .working
        case .settled:
            group = .working
        }
        return ProjectTaskRow(id: task.id, title: task.title, group: group, phase: task.phase, detail: detail, lead: lead,
                              workerAgentID: task.workerAgentID, spaceID: task.spaceID, revision: task.revision,
                              canResolve: task.phase == .settled, canReopen: task.phase == .resolved, settledAt: task.settledAt, files: files,
                              assignmentOperations: Set([task.operationID] + [task.nativeDeliveryID].compactMap { $0 }))
    }
}
