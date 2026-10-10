import Foundation
import ShepherdCore
import ShepherdProtocol
import Testing
@testable import ShepherdApp

/// What the Project page says about its tasks is counted from the Project record, never typed in: the groups, the strip over
/// the composer, the pane's sentence, and the sidebar summary all read the same tasks.
@Suite("Project page presentation")
struct ProjectPagePresentationTests {
    private func task(_ title: String, _ phase: ProjectTask.Phase, question: String? = nil, error: String? = nil) -> ProjectTask {
        var task = ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: title, prompt: "p", phase: phase)
        task.question = question
        task.error = error
        return task
    }

    private func page(_ tasks: [ProjectTask], paused: Bool = false) -> ProjectPagePresentation {
        var project = Project(name: "Gamecards", paused: paused)
        project.tasks = tasks
        return ProjectPagePresentation(project)
    }

    @Test func groupsFollowTheBoardsAndEachTaskLandsInExactlyOne() {
        let p = page([task("Asking", .waiting, question: "Who pays?"), task("Running", .running), task("Queued", .queued),
                      task("Done", .resolved), task("Failed", .failed, error: "pi exited"), task("Lost", .unknown)])
        #expect(p.rows(in: .waiting).map(\.title) == ["Asking", "Failed", "Lost"], "a failed or unknown task needs the person too")
        #expect(p.rows(in: .working).map(\.title) == ["Running", "Queued"])
        #expect(p.rows(in: .resolved).map(\.title) == ["Done"])
        #expect(p.rows.count == p.waiting + p.working + p.resolved + p.settled)
    }

    @Test func aWaitingTaskCarriesTheWorkersOwnQuestionAndAFailedOneItsOwnError() {
        let p = page([task("Asking", .waiting, question: "How should I handle the uncommitted edits?"), task("Broke", .failed, error: "Worker process exited.")])
        #expect(p.rows[0].lead == "Blocked" && p.rows[0].detail == "How should I handle the uncommitted edits?")
        #expect(p.rows[1].lead == "Failed" && p.rows[1].detail == "Worker process exited.")
    }

    @Test(arguments: [
        (ProjectQuestionAnswer.Phase.queued, "Answer queued", "Sends when the project resumes."),
        (.delivering, "Answering", "How should I proceed?"),
        (.failed, "Answer failed", "The question changed before it could be sent. Open the thread to answer again."),
        (.unknown, "Answer unconfirmed", "Shepherd restarted before it knew the worker got it. Open the thread to check."),
    ])
    func anAnswerTheOwnerHoldsIsSaidInWordsAndItsEnvelopeNeverShown(phase: ProjectQuestionAnswer.Phase, lead: String, detail: String) {
        var asking = task("Asking", .waiting, question: "How should I proceed?")
        let secret = Data("SECRET-ENVELOPE".utf8)
        asking.pendingAnswer = ProjectQuestionAnswer(operationID: UUID(), sessionID: "s", generation: "g", dialogID: "d", request: secret, phase: phase)
        let row = page([asking]).rows[0]
        #expect(row.lead == lead && row.detail == detail)
        #expect(![row.lead, row.detail, row.title].compactMap { $0 }.contains { $0.contains("SECRET") }, "the envelope is never rendered")
    }

    // MARK: Accepted messages the transcript has not taken in

    @Test func everyDeliveryStateOfAPersonsMessageIsRepresentedAndNeverRetriedForThem() {
        func message(_ text: String, _ phase: ProjectMessage.Phase, source: ProjectEventSource? = nil, native: UUID? = nil) -> ProjectMessage {
            var m = ProjectMessage(id: UUID(), text: text, phase: phase, source: source)
            m.nativeDeliveryID = native
            return m
        }
        let queued = message("queued", .queued), delivering = message("sending", .delivering)
        let unknown = message("unknown", .unknown), failed = message("failed", .failed)
        let delivered = message("delivered", .delivered)
        let report = message("a worker report", .queued, source: ProjectEventSource(kind: .settled, taskID: ProjectTaskID(), operationID: UUID(),
                                                                                      workerAgentID: AgentID(), sessionID: nil))
        let all = [queued, delivering, unknown, failed, delivered, report]

        let running = ProjectHeldMessages.held(messages: all, paused: false, consumed: [])
        #expect(running.map(\.text) == ["queued", "sending", "unknown", "failed"], "a delivered message is the transcript's, a worker report is the runtime's")
        #expect(running.map(\.note) == ["Waiting to send", "Sending", "Delivery unconfirmed. Send it again to retry.", "Not delivered. Send it again to retry."])
        #expect(ProjectHeldMessages.held(messages: [queued], paused: true, consumed: []).first?.note == "Sends when the project resumes")
    }

    @Test func aMessageLeavesTheHeldListOnlyWhenTheTranscriptHasItsOperationOrItsNativeDelivery() {
        var m = ProjectMessage(id: UUID(), text: "hi", phase: .delivering)
        let native = UUID()
        m.nativeDeliveryID = native
        #expect(ProjectHeldMessages.held(messages: [m], paused: false, consumed: [UUID()]).count == 1, "an unrelated operation consumes nothing")
        #expect(ProjectHeldMessages.held(messages: [m], paused: false, consumed: [m.id]).isEmpty, "its own operation id")
        #expect(ProjectHeldMessages.held(messages: [m], paused: false, consumed: [native]).isEmpty, "the native delivery id the owner recorded")
    }

    @Test func aTypedReferenceDrawsOnlyWhatStillExistsInThisProject() {
        var project = Project(name: "Gamecards")
        let kept = task("Title that names nothing", .running)
        project.tasks = [kept]
        let pending = ProjectSpaceProposal(id: UUID(), operationID: UUID(), path: "/x/web", displayPath: "~/web")
        var denied = ProjectSpaceProposal(id: UUID(), operationID: UUID(), path: "/x/docs", displayPath: "~/docs")
        denied.phase = .denied
        project.spaceProposals = [pending, denied]
        let resolver = ProjectActionResolver(project: project, presentation: ProjectPagePresentation(project))
        func ref(task: ProjectTaskID? = nil, proposal: UUID? = nil, project id: ProjectID? = nil) -> NativeProjectAction {
            NativeProjectAction(projectID: id ?? project.id, revision: 1, operationID: UUID(), taskID: task, proposalID: proposal)
        }
        #expect(resolver.resolve(ref(task: kept.id)) == .task(ProjectPagePresentation(project).rows[0]))
        #expect(resolver.resolve(ref(task: ProjectTaskID())) == nil, "a task that is gone is never redrawn")
        #expect(resolver.resolve(ref(task: kept.id, project: ProjectID())) == nil, "another project's reference is never routed here")
        #expect(resolver.resolve(ref(proposal: pending.id)) == .proposal(pending))
        #expect(resolver.resolve(ref(proposal: denied.id)) == nil, "a consumed proposal is not offered again")
        #expect(resolver.resolve(ref(proposal: UUID())) == nil)
    }

    /// A chip is a host-validated receipt for THIS task in state `ready`. A staged or refused one, another task's, and a file name the
    /// model only wrote in prose are never chips.
    @Test func aTaskCardChipsAreOnlyItsOwnReadyReceipts() throws {
        var project = Project(name: "Gamecards")
        let mine = task("Partner API draft", .settled), other = task("Checkout widget mockup", .settled)
        project.tasks = [mine, other]
        func receipt(_ task: ProjectTask, _ name: String, _ state: ProjectArtifactReceipt.State) -> ProjectArtifactReceipt {
            var r = ProjectArtifactReceipt(id: UUID(), key: .init(ownerID: UUID(), projectID: project.id, operationID: task.operationID),
                                           taskID: task.id, workerAgentID: task.workerAgentID, sessionID: "s", generation: "g",
                                           artifactName: name, size: 12, sha256: String(repeating: "a", count: 64),
                                           sourceIdentity: String(repeating: "b", count: 64), state: state)
            r.relativePath = name
            return r
        }
        project.artifacts = [receipt(mine, "overview.md", .ready), receipt(mine, "draft.md", .staged), receipt(mine, "nope.md", .refused),
                             receipt(other, "checkout-widget.html", .ready), receipt(mine, "openapi.yaml", .ready)]
        let rows = ProjectPagePresentation(project).rows
        #expect(rows[0].files.map(\.name) == ["overview.md", "openapi.yaml"], "ready receipts of this task only, in publication order")
        #expect(rows[0].files.map(\.relativePath) == ["overview.md", "openapi.yaml"], "the owner-relative path the owner reads")
        #expect(rows[1].files.map(\.name) == ["checkout-widget.html"])
        #expect(page([task("No receipts", .settled)]).rows[0].files.isEmpty)
    }

    /// The typed task link: the coordinator's `shepherd-project-task://<projectID>/<taskID>` opens the task whatever the words say.
    @Test func aTaskLinkResolvesByIDInThisProjectAndNeverByTitle() throws {
        var project = Project(name: "Gamecards")
        let first = task("Same name", .running), second = task("Same name", .waiting, question: "Which?")
        project.tasks = [first, second]
        let presentation = ProjectPagePresentation(project)
        func url(_ project: ProjectID, _ task: ProjectTaskID) throws -> URL { try #require(URL(string: ProjectTaskLinks.url(project: project, task: task))) }
        #expect(ProjectTaskLinks.task(in: try url(project.id, second.id), project: project.id, presentation: presentation) == second.id,
                "two tasks with one title: the ID decides")
        #expect(ProjectTaskLinks.task(in: try url(project.id, ProjectTaskID()), project: project.id, presentation: presentation) == nil, "a stale task")
        #expect(ProjectTaskLinks.task(in: try url(ProjectID(), first.id), project: project.id, presentation: presentation) == nil, "another project's")
        #expect(ProjectTaskLinks.task(in: try #require(URL(string: "shepherd-project-task://nowhere")), project: project.id, presentation: presentation) == nil)
        #expect(ProjectTaskLinks.task(in: try #require(URL(string: "https://example.com/\(first.id.rawValue)")), project: project.id, presentation: presentation) == nil)
        let table = ProjectTaskLinks.table(project: project.id, presentation: presentation)
        #expect(table.links[ProjectTaskLinks.url(project: project.id, task: first.id)]?.tone == .running)
        #expect(table.links[ProjectTaskLinks.url(project: project.id, task: second.id)]?.tone == .attention)
        #expect(table.links[ProjectTaskLinks.url(project: ProjectID(), task: first.id)] == nil)
    }

    /// The live line's words come from typed state: queued or reserved tasks make the coordinator "Starting threads"; a worker is
    /// "Working" with the seconds since its own turn began. Neither is read from a reply's text, and nothing else is claimed.
    @Test(arguments: [
        (true, false, nil as Double?, "Starting threads" as String?),
        (false, false, nil, nil),
        (true, true, 1_000_000 - 52_000, "Working · 52s"),
        (false, true, 1_000_000 - 125_000, "Working · 2m 05s"),
        (false, true, nil, "Working"),
    ])
    func theLiveLineSaysOnlyWhatTheOwnersStateSupports(starting: Bool, worker: Bool, startedAt: Double?, words: String?) {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ProjectRunStatus.text(startingThreads: starting, worker: worker, startedAt: startedAt, now: now) == words)
    }

    @Test func settledIsNotDoneAndNotWorkingUntilThePersonResolvesIt() {
        let p = page([task("A", .settled), task("B", .resolved), task("C", .running)])
        #expect(p.settled == 1 && p.working == 1 && p.resolved == 1)
        #expect(p.summary == "1 of 3 done · 1 in progress", "a settled turn is not proof of success, so it is not counted done")
        #expect(p.rows[0].canResolve && !p.rows[0].canReopen)
        #expect(p.rows[1].canReopen && !p.rows[1].canResolve)
    }

    @Test func theSentenceUnderWelcomeBackReadsTheCounts() {
        #expect(page([]).status == "Nothing running yet.")
        #expect(page([task("A", .running), task("B", .running), task("C", .queued)]).status == "3 threads are working.")
        #expect(page([task("A", .waiting, question: "?")]).status == "1 thread is waiting on you.")
        #expect(page([task("A", .waiting, question: "?")], paused: true).status == "Paused. 1 thread is still waiting on you.")
        #expect(page([task("A", .running)], paused: true).status == "Paused.")
    }

    @Test func noTasksMeansNoStripAndNoSummary() {
        #expect(page([]).summary == nil)
    }

    @Test func theSidebarSummaryNamesWhatNeedsYouBeforeWhatIsWorking() {
        let waiting = page([task("A", .waiting, question: "?"), task("B", .running)])
        #expect(waiting.waiting == 1 && waiting.working == 1)
        let summary = waiting.waiting > 0 ? "\(waiting.waiting) needs you" : waiting.working > 0 ? "\(waiting.working) working" : nil
        #expect(summary == "1 needs you")
    }

    @Test func theAgeIsTheTasksOwnClockInMinutesHoursThenDays() {
        let now = Date().timeIntervalSince1970 * 1000
        #expect(LogicalProjectPane.age(now - 29 * 60_000) == "29m")
        #expect(LogicalProjectPane.age(now - 3 * 3_600_000) == "3h")
        #expect(LogicalProjectPane.age(now - 2 * 86_400_000) == "2d")
    }
}
