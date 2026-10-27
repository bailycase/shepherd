import Foundation
import ShepherdRemote
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
        var project = Project(name: "Sample App", paused: paused)
        project.tasks = tasks
        return ProjectPagePresentation(project)
    }

    /// The page, the pane and the sidebar read one presentation per project change, not one per render.
    @Test @MainActor func thePresentationIsDerivedOncePerProjectChange() {
        var project = Project(name: "Sample App", paused: false)
        project.tasks = [task("Running", .running)]
        let first = ProjectPagePresentation.memoized(project)
        #expect(ProjectPagePresentation.memoized(project) == first && first.working == 1)
        project.tasks.append(task("Done", .resolved))
        let second = ProjectPagePresentation.memoized(project)
        #expect(second.resolved == 1 && second != first)
    }

    @Test func groupsFollowTheBoardsAndEachTaskLandsInExactlyOne() {
        let p = page([task("Asking", .waiting, question: "Who pays?"), task("Running", .running), task("Queued", .queued),
                      task("Done", .resolved), task("Failed", .failed, error: "pi exited"), task("Lost", .unknown)])
        #expect(p.rows(in: .waiting).map(\.title) == ["Asking", "Failed", "Lost"], "a failed or unknown task needs the person too")
        #expect(p.rows(in: .working).map(\.title) == ["Running", "Queued"])
        #expect(p.rows(in: .stopped).isEmpty)
        #expect(p.rows(in: .resolved).map(\.title) == ["Done"])
        #expect(p.rows.count == p.waiting + p.working + p.resolved + p.settled)
    }

    @Test func aWaitingTaskCarriesTheWorkersOwnQuestionAndAFailedOneItsOwnError() {
        let p = page([task("Asking", .waiting, question: "How should I handle the uncommitted edits?"), task("Broke", .failed, error: "Worker process exited.")])
        #expect(p.rows[0].lead == "Blocked" && p.rows[0].detail == "How should I handle the uncommitted edits?")
        #expect(p.rows[1].lead == "Failed" && p.rows[1].detail == "Worker process exited.")
    }

    @Test(arguments: [
        (ProjectQuestionAnswer.Phase.queued, "Answer queued", "Waiting to send."),
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

        let running = ProjectHeldMessages.held(messages: all, consumed: [])
        #expect(running.map(\.text) == ["queued", "sending", "unknown", "failed"], "a delivered message is the transcript's, a worker report is the runtime's")
        #expect(running.map(\.note) == ["Waiting to send", "Sending", "Delivery unconfirmed. Send it again to retry.", "Not delivered. Send it again to retry."])
        // A definite refusal shows the owner's reason; an unknown outcome and a record without one show no invented text.
        var refused = failed
        refused.failureDetail = "The agent refused it: No API key found for the model provider"
        var unknownWithDetail = unknown
        unknownWithDetail.failureDetail = "must never show"
        let notes = ProjectHeldMessages.held(messages: [refused, unknownWithDetail], consumed: []).map(\.note)
        #expect(notes == ["Not delivered. The agent refused it: No API key found for the model provider. Send it again to retry.",
                          "Delivery unconfirmed. Send it again to retry."])
    }

    @Test func aMessageLeavesTheHeldListOnlyWhenTheTranscriptHasItsOperationOrItsNativeDelivery() {
        var m = ProjectMessage(id: UUID(), text: "hi", phase: .delivering)
        let native = UUID()
        m.nativeDeliveryID = native
        #expect(ProjectHeldMessages.held(messages: [m], consumed: [UUID()]).count == 1, "an unrelated operation consumes nothing")
        #expect(ProjectHeldMessages.held(messages: [m], consumed: [m.id]).isEmpty, "its own operation id")
        #expect(ProjectHeldMessages.held(messages: [m], consumed: [native]).isEmpty, "the native delivery id the owner recorded")
    }

    @Test func aTypedReferenceDrawsOnlyWhatStillExistsInThisProject() {
        var project = Project(name: "Sample App")
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
        var project = Project(name: "Sample App")
        let mine = task("Library API draft", .settled), other = task("Reading widget mockup", .settled)
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
                             receipt(other, "reading-widget.html", .ready), receipt(mine, "openapi.yaml", .ready)]
        let rows = ProjectPagePresentation(project).rows
        #expect(rows[0].files.map(\.name) == ["overview.md", "openapi.yaml"], "ready receipts of this task only, in publication order")
        #expect(rows[0].files.map(\.relativePath) == ["overview.md", "openapi.yaml"], "the owner-relative path the owner reads")
        #expect(rows[1].files.map(\.name) == ["reading-widget.html"])
        #expect(page([task("No receipts", .settled)]).rows[0].files.isEmpty)
    }

    /// The typed task link: the coordinator's `shepherd-project-task://<projectID>/<taskID>` opens the task whatever the words say.
    @Test func aTaskLinkResolvesByIDInThisProjectAndNeverByTitle() throws {
        var project = Project(name: "Sample App")
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

    /// A Project is a long-lived workspace of many unrelated tasks, not one campaign: the strip counts execution facts, never "N of M
    /// done". A stopped turn is its own fact (not working, not success), and resolution is not delivery.
    @Test func theStripShowsOnlyTheOwnersQuestionOrFailureNeverWorkerActivity() {
        let p = page([task("Run", .running), task("Ask", .waiting, question: "Which API?"),
                      task("Fail", .failed, error: "Launch failed"), task("Done", .resolved)])
        #expect(p.rows.map(ProjectSummaryStrip.detail) == [nil, "Which API?", "Launch failed", nil], "a resolved task with no recorded outcome claims nothing")
    }

    @Test func aStoppedTurnIsNeitherWorkingNorDoneAndTheStripNamesEachFact() throws {
        let p = page([task("A", .settled), task("B", .resolved), task("C", .running), task("D", .queued)])
        #expect(p.settled == 1 && p.working == 2 && p.resolved == 1)
        #expect(p.summary == "2 working · 1 stopped · 1 resolved")
        #expect(page([task("A", .settled), task("B", .settled)]).summary == "2 stopped")
        #expect(page([task("Q", .waiting, question: "?"), task("A", .settled)]).summary == "1 needs you · 1 stopped")
        #expect(p.status == "2 threads are working.")
        #expect(page([task("A", .settled)]).status == "Nothing is running.")
        for summary in [p.summary, page([task("A", .resolved)]).summary] { #expect(summary?.contains("done") == false) }
        let stopped = try #require(p.rows.first { $0.phase == .settled })
        #expect(stopped.group == .stopped && stopped.tone == .stopped && stopped.lead == "Stopped" && stopped.detail == "No outcome recorded",
                "settled proves only that the turn stopped; no review is implied")
        #expect(![stopped.lead, stopped.detail, stopped.outcomeLine].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains("review") })
        #expect(p.rows.first { $0.phase == .running }?.tone == .running)
    }

    /// Outcomes are bound to the exact activation. A legacy task, or a resolved one nobody recorded an outcome for, stays unknown; an
    /// earlier activation's verdict never labels a later follow-up; a coordinator's claim is never drawn as the person's.
    @Test func outcomesShowOnlyForTheirExactOperationAndUnknownStaysUnknown() throws {
        let coordinator = AgentID()
        var legacy = task("Legacy", .resolved)
        #expect(legacy.outcomes == nil && legacy.currentOutcome == nil)
        var followed = task("Followed", .settled)
        let earlier = followed.operationID
        followed.outcomes = [.init(id: UUID(), operationID: earlier, kind: .needsChanges, recordedBy: coordinator, recordedAt: 1)]
        followed.previousOperations = [earlier]; followed.operationID = UUID()
        var merged = task("Merged", .resolved)
        merged.outcomes = [.init(id: UUID(), operationID: merged.operationID, kind: .accepted, recordedBy: coordinator, recordedAt: 1),
                           .init(id: UUID(), operationID: merged.operationID, kind: .merged, evidence: "PR #12", recordedBy: coordinator, recordedAt: 2)]
        var owner = task("Owner", .settled)
        owner.outcomes = [.init(id: UUID(), operationID: owner.operationID, kind: .accepted, recordedAt: 1)]
        legacy.title = "Legacy"
        let rows = page([legacy, followed, merged, owner]).rows
        #expect(rows[0].lead == nil && rows[0].detail == nil && rows[0].outcomeLine == nil, "resolved alone is not success")
        #expect(rows[1].lead == "Stopped" && rows[1].detail == "No outcome recorded", "an earlier activation's verdict is not this one's")
        #expect(rows[2].group == .resolved && rows[2].lead == "Merged" && rows[2].detail == "PR #12 · per coordinator")
        #expect(merged.outcomes?.count == 2, "earlier facts are retained, not replaced")
        #expect(rows[3].group == .stopped && rows[3].lead == "Accepted" && rows[3].detail == "recorded by owner",
                "an owner-control record names its source and never reads as a person's approval")
        #expect(rows.allSatisfy { !($0.outcomeLine ?? "").localizedCaseInsensitiveContains("approved") })
        #expect(rows[3].canResolve, "recording an outcome never resolves or changes the phase")
    }

    /// A real fact for this run replaces the neutral line; it never coexists with an inferred review claim. A follow-up after a
    /// verdict reads neutral again until its own fact exists.
    @Test func aRecordedVerdictReplacesTheNeutralLineOnlyForItsOwnRun() {
        let coordinator = AgentID()
        var t = task("Iterated", .settled)
        let first = t.operationID
        t.outcomes = [.init(id: UUID(), operationID: first, kind: .needsChanges, recordedBy: coordinator, recordedAt: 1)]
        var row = page([t]).rows[0]
        #expect(row.lead == "Needs changes" && row.detail == "per coordinator" && row.outcomeLine == "Needs changes · per coordinator")
        #expect(!(row.outcomeLine ?? "").contains(ProjectPagePresentation.noOutcome))
        t.previousOperations = [first]; t.operationID = UUID()
        row = page([t]).rows[0]
        #expect(row.lead == "Stopped" && row.detail == ProjectPagePresentation.noOutcome)
        t.outcomes?.append(.init(id: UUID(), operationID: t.operationID, kind: .accepted, recordedBy: coordinator, recordedAt: 2))
        #expect(page([t]).rows[0].outcomeLine == "Accepted · per coordinator")
        t.phase = .resolved
        #expect(page([t]).rows[0].group == .resolved && page([t]).rows[0].lead == "Accepted")
    }

    /// Resolved Project tasks are terminal: the row offers nothing to send or resolve, keeps its worker (history opens through
    /// "Open as a thread") and stays Resolved. Only a settled task offers Mark resolved; live, waiting, failed and unknown work does not.
    @Test func onlyASettledTaskOffersResolveAndAResolvedOneKeepsItsThreadForHistory() throws {
        let phases: [ProjectTask.Phase] = [.queued, .running, .waiting, .failed, .unknown, .settled, .resolved]
        let tasks = phases.map { task("\($0)", $0, question: $0 == .waiting ? "Which API?" : nil, error: $0 == .failed ? "Launch failed" : nil) }
        let p = page(tasks)
        #expect(p.rows.map(\.canResolve) == phases.map { $0 == .settled })
        let resolved = try #require(p.rows.first { $0.phase == .resolved })
        #expect(resolved.group == .resolved && resolved.workerAgentID == tasks.last?.workerAgentID)
        #expect(p.rows(in: .resolved).map(\.title) == ["resolved"])
        let actions = Mirror(reflecting: resolved).children.compactMap(\.label).filter { $0.hasPrefix("can") }
        #expect(actions == ["canResolve"], "a row offers Resolve as its only runtime action, never Reopen: \(actions)")
    }

    /// A relaunched Project keeps the coordinator's pi off until a message needs it, yet its composer said "Starting…" indefinitely.
    /// Projects never pause on their own, so a resumed Project with nothing queued is just as offline, and a send still launches it.
    @Test func aProjectHoldsItsCoordinatorsPiOffUntilAMessageCanBeDelivered() {
        func message(_ phase: ProjectMessage.Phase, source: ProjectEventSource? = nil) -> ProjectMessage { ProjectMessage(id: UUID(), text: "hi", phase: phase, source: source) }
        let worker = ProjectEventSource(kind: .settled, taskID: ProjectTaskID(), operationID: UUID(), workerAgentID: AgentID(), sessionID: nil)
        // Cold, with only history: offline, paused or not. A paused Project holds even a queued message.
        #expect(ProjectComposerSend.isOffline(paused: true, messages: [message(.delivered)], coordinatorLive: false))
        #expect(ProjectComposerSend.isOffline(paused: false, messages: [message(.delivered), message(.failed), message(.unknown)], coordinatorLive: false))
        #expect(ProjectComposerSend.isOffline(paused: true, messages: [message(.queued)], coordinatorLive: false))
        // A message the owner can deliver now launches the pi, a worker's wake-up included: that start is the ordinary warm-up.
        #expect(!ProjectComposerSend.isOffline(paused: false, messages: [message(.queued)], coordinatorLive: false))
        #expect(!ProjectComposerSend.isOffline(paused: false, messages: [message(.queued, source: worker)], coordinatorLive: false))
        #expect(!ProjectComposerSend.isOffline(paused: false, messages: [message(.delivering)], coordinatorLive: false))
        // A running coordinator is never offline, whatever the Project holds.
        #expect(!ProjectComposerSend.isOffline(paused: true, messages: [], coordinatorLive: true))
        #expect(!ProjectComposerSend.isOffline(paused: false, messages: [message(.delivered)], coordinatorLive: true))
    }

    /// The question card told people the worker "keeps going on its best guess", which is false for a blocking native question.
    @Test func theQuestionFootersCopyIsTruthful() {
        #expect(TaskQuestion.footer(title: "Question check") == "Or just reply in chat. Question check is waiting for your answer.")
        #expect(!TaskQuestion.footer(title: "X").contains("best guess"))
    }

    @Test func aTaskWithAHeldAnswerSaysSoAndIsMarkedSoItsDockOffersNoSecondAnswer() {
        var asking = task("Asking", .waiting, question: "Pick")
        #expect(page([asking]).rows[0].answerHeld == false)
        asking.pendingAnswer = ProjectQuestionAnswer(operationID: UUID(), sessionID: "s", generation: "g", dialogID: "d", request: Data("x".utf8), phase: .queued)
        let row = page([asking], paused: true).rows[0]
        #expect(row.answerHeld && row.lead == "Answer queued" && row.detail == "Waiting to send.")
    }

    @Test func theSentenceUnderWelcomeBackReadsTheCounts() {
        #expect(page([]).status == "Nothing running yet.")
        #expect(page([task("A", .running), task("B", .running), task("C", .queued)]).status == "3 threads are working.")
        #expect(page([task("A", .waiting, question: "?")]).status == "1 thread is waiting on you.")
        #expect(page([task("A", .waiting, question: "?")], paused: true).status == "1 thread is waiting on you.", "no Paused wording")
        #expect(page([task("A", .running)], paused: true).status == "1 thread is working.")
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
