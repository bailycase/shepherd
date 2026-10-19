import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Project page over the real runtime (ProjectLead boards): the shared thread over the coordinator's own native
/// store, tasks from workers the launcher really started on the stub engine, and every control pressed through
/// accessibility. Nothing is typed in from the boards: every line is what the stub's native thread produced.
@Suite("Project conversation and tasks", .mainActorExclusive)
@MainActor
struct LogicalProjectConversationTests {
    @Test func theFirstMessageStartsTheConversationAndPausedMessagesWaitForResume() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.conversation() } }
        expectScenarioCompleted(result)
    }

    @Test func aTaskThatAsksIsWaitingOnYouAndSettledWorkResolvesAndReopens() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.tasks() } }
        expectScenarioCompleted(result)
    }

    @Test func thePaneHeaderSearchesFiltersExpandsAssignsAndFilesSaysWhatItCannotRead() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.paneHeader() } }
        expectScenarioCompleted(result)
    }

    @Test func theThreadsPaneResizesAtItsDividerLikeAThreadsSidePane() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.paneResize() } }
        expectScenarioCompleted(result)
    }

    /// The same divider dragged by mouse events sent to the window (never posted). The scenario first checks, in its own process,
    /// that such a drag reaches a plain SwiftUI `DragGesture` in a window of its own (`SyntheticMouse`); only where it does not is
    /// this test cancelled, by name. Where events arrive, the divider must follow them exactly.
    @Test func theThreadsPaneFollowsAMouseDragAtItsDivider() async throws {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.paneMouseDrag() } }
        expectScenarioCompleted(result)
        if String(decoding: result?.standardOutputContent ?? [], as: UTF8.self).contains(SyntheticMouse.undeliveredLine) {
            try Test.cancel("this process does not deliver synthetic mouse events to SwiftUI gestures; the drag path is covered without them")
        }
    }

    @Test func aChosenFilterOffersShowAllAndChoosingItClearsTheFilter() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.filterReset() } }
        expectScenarioCompleted(result)
    }

    @Test func aProposedSpaceIsOfferedAndEachChoiceGoesToTheOwnerWithItsRevision() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.offer() } }
        expectScenarioCompleted(result)
    }

    @Test func thePaperclipOpensThePickerAndAnImageSendsWithItsWordsOrAloneAndAFailedSendKeepsEverything() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.paperclip() } }
        expectScenarioCompleted(result)
    }

    @Test func aTypedToolResultIsDrawnInlineAsItsTaskAndSpaceCardsAndNeverFromProse() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.inlineCards() } }
        expectScenarioCompleted(result)
    }

    @Test func aTaskCardsFileChipsAndTheCoordinatorsTypedTaskLinksPressThroughTheOwner() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.chipsAndLinks() } }
        expectScenarioCompleted(result)
    }

    @Test func aTaskMentionedTwiceIsTwoPressableChipsAndALongWrappedOneIsOne() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.repeatedAndWrappedChips() } }
        expectScenarioCompleted(result)
    }

    @Test func aPausedMessageStaysVisibleUntilResumeAndAnUnconfirmedOneIsNeverLostOrRetriedForThePerson() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.heldMessages() } }
        expectScenarioCompleted(result)
    }

    @Test func aQueuedMessageStaysInUpNextThroughAPausedRelaunchAndASlowStartAndOnlyTheHandoffMovesIt() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.upNextUntilHandoff() } }
        expectScenarioCompleted(result)
    }

    @Test func theFirstMessageCanBeAnImageAloneBeforeAnyCoordinatorExistsThroughTheRealComposer() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.firstImageOnly() } }
        expectScenarioCompleted(result)
    }

    @Test func aRemoteProjectsWorkerThreadIsReadThroughItsOwnerByProjectAndTaskWithNoExecutorOnTheViewer() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.workerThroughOwner() } }
        expectScenarioCompleted(result)
    }

    @Test func aWorkersPlanFromTheEnginesFixtureIsDrawnAsOneStepsCardAndNeverAlsoAsActivity() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.stepsCard() } }
        expectScenarioCompleted(result)
    }

    @Test func aWorkerTurnHoldingTheAssignmentAndAPersonsSteerDrawsPlainProseAndABubble() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.mixedWorkerTurn() } }
        expectScenarioCompleted(result)
    }

    @Test func aRunningWorkersEmptyComposerIsTheBoardsStopAndPressingItAbortsOnlyThatWorker() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.workerStop() } }
        expectScenarioCompleted(result)
    }

    @Test func theProjectsOwnComposerIsTheBoardsDisabledArrowWhileTheCoordinatorsTurnRunsAndAnEmptyFieldNeverStopsIt() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.projectComposerWhileRunning() } }
        expectScenarioCompleted(result)
    }

    @Test func aRefusedSendFromTheSendButtonKeepsTheWordsAndImagesAndOnlyAnExplicitRetryReusesItsOperation() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.refusedSend() } }
        expectScenarioCompleted(result)
    }

    @Test func theConversationComposerPicksTheMainModelBeforeTheFirstMessageAndShowsNoBranch() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.modelAndBranch() } }
        expectScenarioCompleted(result)
    }

    @Test func aConversationModelTheOwnerLacksFailsTheLaunchAndTheComposerNeverReportsALostConnection() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.unavailableModel() } }
        expectScenarioCompleted(result)
    }

    @Test func aPickOnARunningCoordinatorIsSavedAndThenSetOnItsRealNativeThread() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.liveModelPick() } }
        expectScenarioCompleted(result)
    }

    @Test func aCoordinatorWhoseCreationIsHeldIsStartingNotALostConnectionAndThenTheThreadIsReady() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.heldCreation() } }
        expectScenarioCompleted(result)
    }

    @Test func aRefusedModelSaveChangesNeitherTheChipNorTheLiveModelAndSaysSo() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.refusedModelSave() } }
        expectScenarioCompleted(result)
    }

    @Test func theFirstMessagesThreadLeavesStartingEvenWhenItsCoordinatorIsRecordedBeforeItsAgentIsRegistered() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.firstMessageRace() } }
        expectScenarioCompleted(result)
    }

    @Test func aHeldOffCoordinatorsModelAndReasoningAreTheProjectsOwnSettingsAndItsNextLaunchUsesThem() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.heldOffModelAndReasoning() } }
        expectScenarioCompleted(result)
    }

    @Test func aSavedCoordinatorsHistoryShowsOnAColdLaunchAndTheNextMessageStartsItsPi() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.coldCoordinator() } }
        expectScenarioCompleted(result)
    }

    @Test func aResolvedWorkersThreadDrawsNoComposerUntilItIsReopened() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.resolvedHasNoComposer() } }
        expectScenarioCompleted(result)
    }

    @Test func aBlockingQuestionSaysTruthfullyWhatAReplyDoesAndAHeldAnswerLeavesNoSecondAnswerButton() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.questionCopy() } }
        expectScenarioCompleted(result)
    }

    @Test(arguments: ["pane-option", "pane-text", "project-text"], [false, true])
    func aWorkersSelectAnsweredFromThePanesDockIsDeliveredOnceAndTheDockLeaves(route: String, rejectedFirst: Bool) async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { [route = route as String, rejectedFirst = rejectedFirst as Bool] in await completingScenario { try await Self.paneDockAnswer(route: route, rejectedFirst: rejectedFirst) } }
        expectScenarioCompleted(result)
    }

    @Test func thePausedFooterMatchesItsSourceGeometryAndTheResolvedFooterKeepsItsOwn() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.footerGeometry() } }
        expectScenarioCompleted(result)
    }

    @Test func theCoordinatorAppearsInNoOrdinaryThreadList() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.hidden() } }
        expectScenarioCompleted(result)
    }

    @Test func theSummaryDisclosesCurrentTasksOpensThemAndResetsForAnotherProject() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.summaryDisclosure() } }
        expectScenarioCompleted(result)
    }

    private static func summaryDisclosure() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Finished research", prompt: "tools:0 finish"))
        try await eventuallyOnMain("the first task settles") { r.vm.state.projects.first?.tasks.first?.phase == .settled }
        let current = try #require(r.vm.state.projects.first)
        let finished = try #require(current.tasks.first)
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: current.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Ongoing implementation", prompt: "slow"))
        try await eventuallyOnMain("the second task runs") { r.vm.state.projects.first?.tasks.last?.phase == .running }
        guard case .project(let other) = try await r.app.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Other project", goal: "", linkedSpaceIDs: [r.space.id])) else { throw RigError("no other project") }
        _ = try await r.vm.projectCoordinator.perform(projectID: other.id, expectedRevision: other.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Other work", prompt: "slow"))
        try await eventuallyOnMain("the other project has its task") { r.vm.state.projects.first { $0.id == other.id }?.tasks.last?.phase == .running }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneOpen = false
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the collapsed summary") { window.layout(); return window.element("Show project tasks") != nil }
        #expect(window.controls().first { $0.label == "Show project tasks" }?.value == "Collapsed, 1 of 2 done · 1 in progress")
        #expect(!window.controls().contains { $0.label?.hasPrefix(finished.title) == true })
        try window.press("Show project tasks")
        try await eventuallyOnMain("the expanded tasks") {
            window.layout()
            return window.element("Hide project tasks") != nil && window.controls().contains { $0.label?.hasPrefix(finished.title) == true }
        }
        let header = try #require(window.controls().first { $0.label == "Hide project tasks" })
        #expect(header.value == "Expanded, 1 of 2 done · 1 in progress")
        // A worker's cached activity (refreshed only by the pane) never reaches the strip: the running row is its title alone.
        let ongoing = try #require(current.tasks.count == 1 ? r.vm.state.projects.first?.tasks.last : nil)
        let worker = r.vm.projectWorkerStore(.local, ongoing.workerAgentID)
        let polling = Task { await worker.run(request: r.vm.projectWorkerRequest(r.ref, task: ongoing.id)) }
        try await eventuallyOnMain("the worker has cached activity") { r.vm.workerActivity(ongoing.workerAgentID) != nil }
        polling.cancel()
        window.layout()
        #expect(window.controls().contains { $0.label == "Ongoing implementation" })
        #expect(ControlPress.undersized([header], minimum: .desktop).isEmpty)
        let row = try #require(window.controls().first { $0.label?.hasPrefix(finished.title) == true })
        r.vm.logicalProjectPaneOpen = false
        r.vm.logicalProjectPaneTab = .files
        try window.press(try #require(row.label))
        #expect(r.vm.logicalProjectPaneOpen && r.vm.logicalProjectPaneTab == .threads && r.vm.logicalProjectPaneTask == finished.id)
        try await eventuallyOnMain("the selected worker opens in the pane") { window.layout(); return window.element("Open as a thread") != nil }
        r.vm.logicalProjectPaneOpen = false

        // The open list follows the owner, without closing or changing what "done" counts.
        let latest = try #require(r.app.server.state.projects.first { $0.id == r.project.id })
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: latest.revision,
            request: .resolve(taskID: finished.id, operationID: UUID()))
        try await eventuallyOnMain("the resolved task reaches the open list") {
            r.vm.state.projects.first { $0.id == r.project.id }?.tasks.first?.phase == .resolved
        }
        window.layout()
        #expect(window.element("Hide project tasks") != nil)
        #expect(window.controls().first { $0.label == "Hide project tasks" }?.value == header.value)
        let running = try #require(latest.tasks.last)
        guard case .snapshot(let snapshot) = try await r.app.server.nativeThread(agentID: running.workerAgentID, request: .snapshot()) else {
            throw RigError("no worker snapshot")
        }
        _ = try await r.app.server.nativeThread(agentID: running.workerAgentID,
            request: .abort(expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID()))
        try await eventuallyOnMain("completion updates the expanded summary") {
            window.layout(); return window.controls().first { $0.label == "Hide project tasks" }?.value == "Expanded, 2 of 2 done"
        }
        try window.press("Hide project tasks")
        try await eventuallyOnMain("collapse removes the rows") {
            window.layout(); return !window.controls().contains { $0.label?.hasPrefix(finished.title) == true }
        }
        try window.press("Show project tasks")
        r.vm.openLogicalProject(LogicalProjectRef(home: .local, id: other.id))
        try await eventuallyOnMain("another project starts collapsed") {
            window.layout(); return window.controls().first { $0.label == "Show project tasks" }?.value == "Collapsed, 0 of 1 done · 1 in progress"
        }
        #expect(!window.controls().contains { $0.label?.hasPrefix("Other work") == true })
        try window.press("Show project tasks")
        try await eventuallyOnMain("the second project's own task") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix("Other work") == true }
        }
        #expect(!window.controls().contains { $0.label?.hasPrefix(finished.title) == true })
    }

    // MARK: Rig

    private struct Rig {
        let app: AppHarness
        let vm: ShepherdViewModel
        let project: Project
        let space: Space
        let ref: LogicalProjectRef
    }

    private static func rig() async throws -> Rig {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        let folder = app.dir.appendingPathComponent("sample-app-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("sample-app-api", path: folder.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        guard case .project(let project) = try await app.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Sample App", goal: "Build a shared reading list", linkedSpaceIDs: [space.id])) else {
            throw RigError("no project")
        }
        try await eventuallyOnMain("the project arrives") { vm.state.projects.count == 1 }
        return Rig(app: app, vm: vm, project: project, space: space, ref: LogicalProjectRef(home: .local, id: project.id))
    }

    private struct RigError: Error { let message: String; init(_ message: String) { self.message = message } }

    // MARK: Conversation

    private static func conversation() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        // Empty: no coordinator exists, the real composer says who it asks, and the context rows are real.
        try await eventuallyOnMain("the empty project") { window.layout(); return window.element("Ask Sample App a question or start a task…") != nil
            || window.elements().contains { $0.label == "Message the agent" } }
        #expect(r.vm.state.agents.isEmpty, "opening a project starts no conversation")
        #expect(window.element("Spaces, sample-app-api · add more in settings") != nil)
        // The pane is a 480 box beside a 232 sidebar in a 1600 window, so the conversation is 888 wide and its 680 column starts at x 336 (the
        // boards' 336), not 336.5 as it did beside a 479 pane. Both appearances, both text scales.
        let original = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = original }
        for (dark, scale) in [(true, CGFloat(1)), (false, 1), (true, 1.3), (false, 1.3)] {
            window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.host.appearance = window.window.appearance
            ThemeStore.shared.textScale = scale
            window.layout()
            let page = try #require(window.elements().first { $0.role == "AXGroup" }?.frame)
            let field = try #require(window.elements().first { $0.label == "Message the agent" }?.frame)
            // The page beside a 480 pane is 888 wide, and the 680 column is centred in it: 104 each side, so the column starts at 336 (a
            // 479 pane left 336.5). The composer's accessibility frame is the field inside the card, so it is the column less its own insets.
            let sidebar = AppLayout.sidebarDefaultWidth
            let columnLeft = sidebar + (page.width - sidebar - NWLeadMetrics.paneWidth - NWLeadMetrics.columnWidth) / 2
            let inset = field.minX - page.minX - columnLeft
            #expect(columnLeft == 336, "the column starts at \(columnLeft) in \(dark ? "dark" : "light") x\(scale)")
            #expect(inset == 15 && field.width < NWLeadMetrics.columnWidth, "the composer's field starts \(inset) inside the column and within it: \(field.minX - page.minX) + \(field.width)")
        }

        // Sending is the Project runtime's: the first message creates the coordinator and delivers once.
        let sent = await r.vm.logicalProjects.sendMessage(r.ref, text: "hello")
        #expect(sent)
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a hidden agent") {
            r.vm.state.agents.contains { $0.id == coordinator && $0.coordinatorFor == r.project.id }
        }
        #expect(!r.vm.state.isOrdinaryThread(try #require(r.vm.state.agents.first { $0.id == coordinator })))
        #expect(r.vm.projectCoordinator.conversationStore(agentID: coordinator) === r.vm.threadStores.store(for: coordinator))

        // Pause: the banner says so, Resume is a real control, and a message sent while paused is held, not delivered.
        #expect(await r.vm.logicalProjects.setPaused(r.ref, true))
        try await eventuallyOnMain("the paused banner") { window.layout(); return window.elements().contains { $0.label?.hasPrefix("Paused.") == true || $0.value?.hasPrefix("Paused.") == true } }
        let held = await r.vm.logicalProjects.sendMessage(r.ref, text: "wait for me")
        #expect(held, "the runtime accepts and keeps it: \(r.vm.logicalProjects.failure?.message ?? "no refusal")")
        let messages = try #require(r.app.server.state.projects.first).messages
        #expect(messages.contains { $0.text == "wait for me" && $0.phase == .queued }, "queued, not delivered, while paused: \(messages)")
        try await eventuallyOnMain("the interruption is acknowledged") { r.app.server.state.projects.first?.interruptPending == false }
        try await eventuallyOnMain("the banner's Resume is enabled once the interruption is acknowledged") {
            window.layout(); return window.controls().contains { $0.label == "Resume" && $0.isEnabled }
        }
        let resumes = window.controls().filter { $0.label == "Resume" }
        let resume = try #require(resumes.first { $0.isEnabled })
        #expect(ControlPress.undersized([resume], minimum: .desktop).isEmpty, "Resume is \(resume.frame.size)")
        try window.press("Resume", nth: try #require(resumes.firstIndex { $0.isEnabled }))
        try await eventuallyOnMain("resumed") { r.app.server.state.projects.first?.paused == false }
    }

    // MARK: Tasks

    private static func tasks() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        // Real workers through the real runtime: one asks (the stub's "ask"), one settles.
        let coordinator = r.vm.projectCoordinator
        _ = try await coordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading list research", prompt: "slow"))
        // The owner records the first worker running asynchronously: the second assign waits for that published record, so it
        // carries the revision the owner really holds (a refused action is never retried to hide the race).
        try await eventuallyOnMain("the first task is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let current = try #require(r.app.server.state.projects.first)
        _ = try await coordinator.perform(projectID: r.project.id, expectedRevision: current.revision,
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "ask"))
        try await eventuallyOnMain("two tasks exist") { r.vm.state.projects.first?.tasks.count == 2 }
        try await eventuallyOnMain("one waits on you") { r.vm.state.projects.first?.tasks.contains { $0.phase == .waiting } == true }
        let waiting = try #require(r.vm.state.projects.first?.tasks.first { $0.phase == .waiting })
        let presentation = ProjectPagePresentation(try #require(r.vm.state.projects.first))
        #expect(presentation.waiting >= 1 && presentation.rows(in: .waiting).first?.title == "Library API draft")
        #expect(presentation.status.contains("waiting on you"))

        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the pane lists the task") { window.layout(); return window.element("Library API draft, Blocked") != nil
            || window.elements().contains { $0.label?.hasPrefix("Library API draft") == true } }
        let group = try #require(window.controls().first { $0.label?.hasPrefix("Waiting on you, 1") == true })
        #expect(ControlPress.undersized([group], minimum: .desktop).isEmpty)

        // Opening a task shows the worker's own native thread in the pane; Open as a thread selects the ordinary thread.
        // The pane's row reads "<title>, Blocked, <the worker's own question>": its words come from the native thread's dialog.
        let rowControl = try #require(window.controls().first { $0.label?.hasPrefix("Library API draft, Blocked") == true })
        #expect(ControlPress.undersized([rowControl], minimum: .desktop).isEmpty, "the row is \(rowControl.frame.size)")
        try window.press(try #require(rowControl.label))
        try await eventuallyOnMain("the task opens beside the conversation") { r.vm.logicalProjectPaneTask == waiting.id }
        try await eventuallyOnMain("the detail's controls") { window.layout(); return window.element("Open as a thread") != nil }
        for name in ["Threads", "Open as a thread", "Close"] {
            let control = try #require(window.controls().first { $0.label == name })
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size)")
        }
        try window.press("Close")
        try await eventuallyOnMain("the pane returns to Threads") { r.vm.logicalProjectPaneTask == nil }
    }

    /// The Threads pane's leading edge is `RightPaneSplit`'s divider, as a thread's side pane is: a column-resize handle you drag, or
    /// adjust with VoiceOver, that keeps the conversation 400pt while it docks, persists one width for every Project, and survives
    /// Close, Expand, a narrower window and larger text. The drag is real mouse events sent to the off-screen window (never posted).
    private static func paneResize() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        guard case .project(let other) = try await r.app.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Other project", goal: "", linkedSpaceIDs: [r.space.id])) else { throw RigError("no other project") }
        try await eventuallyOnMain("both projects") { r.vm.state.projects.count == 2 }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        func handle() -> AccessibilityNode? { window.elements().first { $0.label == "Pane width" } }
        /// The drawn pane's width: the window's trailing edge less the 1pt divider, which the 9pt handle centres on.
        func paneWidth() -> String? { handle().map { "\(Int((window.window.frame.maxX - $0.frame.midX - AppLayout.dividerWidth / 2).rounded())) points" } }
        func drawn() -> CGFloat? { handle().map { window.window.frame.maxX - $0.frame.midX - AppLayout.dividerWidth / 2 } }
        func control(_ label: String) throws -> Control { try #require(window.controls().first { $0.label == label }, "\(label) on screen") }
        /// The pane's header stays inside the window and the conversation's composer stays left of the divider.
        func expectReachable(_ when: String) throws {
            let edge = try #require(handle()).frame
            let close = try control("Close")
            let field = try #require(window.elements().first { $0.label == "Message the agent" }).frame
            #expect(close.frame.maxX <= window.window.frame.maxX + 0.5 && close.frame.minX > edge.maxX, "Close is reachable \(when): \(close.frame) beside \(edge)")
            #expect(field.maxX <= edge.minX, "the composer \(field) stays left of the divider \(edge) \(when)")
        }
        try await eventuallyOnMain("the divider") { paneWidth() == "479 points" }
        // The default is the board's: a 1pt divider and the 479 pane, so the conversation keeps its 888.
        let edge = try #require(handle()).frame
        #expect(edge.width == AppLayout.resizeHandleWidth, "the shared 9pt handle: \(edge)")
        #expect(abs(window.window.frame.maxX - (edge.midX - AppLayout.dividerWidth / 2) - NWLeadMetrics.paneWidth) < 0.5, "the divider and pane are the board's 480: \(edge)")
        try expectReachable("by default")

        // VoiceOver's increment widens it by the shared step, and the width is saved where a thread's pane keeps its own.
        let increment = NSSelectorFromString("accessibilityPerformIncrement")
        _ = try #require(handle()).object.perform(increment)
        try await eventuallyOnMain("incremented") { paneWidth() == "\(479 + Int(AppLayout.paneAdjustStep)) points" }
        let saved = r.app.defaults.double(forKey: ShepherdViewModel.logicalProjectPaneWidthKey)
        #expect(saved == Double(479 + AppLayout.paneAdjustStep), "saved \(saved), the state holds \(r.vm.logicalProjectPane.width)")
        #expect(r.app.defaults.object(forKey: RightPaneState.widthKey) == nil, "a thread's pane width is untouched")

        // A drag, through the handle's own path: `RightPaneDrag` is what its DragGesture's onChanged builds from each pointer
        // location and what its onEnded saves, and `RightPaneDrag.layout` is what the split draws meanwhile. Driven over the page's
        // real split (its width checked against the drawn divider) and the view model's real binding, without mouse events, which
        // CI's headless runner does not deliver (theThreadsPaneFollowsAMouseDragAtItsDivider sends them where they arrive).
        // The page is the window less the 232 sidebar and its 1pt edge: 1367, so the widest pane (half of it) is 683.5.
        let page = AppLayout.sidebarDefaultWidth + AppLayout.dividerWidth
        let total = window.window.frame.width - page
        let layout = RightPaneDrag.layout(nil, state: r.vm.logicalProjectPane, containerWidth: total)
        #expect(layout == ShellLayout.Pane(mode: .docked, width: 519, contentWidth: total - 520), "the split lays out the saved width")
        let line = try #require(handle()).frame.midX - AppLayout.dividerWidth / 2 - window.window.frame.minX
        #expect(line == page + layout.contentWidth, "the divider is drawn where that layout puts it: \(line)")
        /// One drag: the pointer taken at the divider's trailing edge, then moved by `deltas` in turn; each step previews without
        /// saving, and letting go saves (and persists) what the last preview drew.
        func drag(by deltas: [CGFloat], previews: [CGFloat], saves saved: CGFloat) throws {
            let before = r.vm.logicalProjectPane.width
            var pointer = total - before
            var last: RightPaneDrag?
            for (delta, preview) in zip(deltas, previews) {
                pointer += delta
                let step = RightPaneDrag(pointerX: pointer, containerWidth: total)
                #expect(RightPaneDrag.layout(step, state: r.vm.logicalProjectPane, containerWidth: total).width == preview,
                        "after \(delta) the pane previews \(preview)")
                #expect(r.vm.logicalProjectPane.width == before, "nothing is saved while the drag lasts")
                last = step
            }
            try #require(last).end(in: r.vm.logicalProjectPane, containerWidth: total)
            #expect(r.vm.logicalProjectPane.width == saved)
            #expect(r.app.defaults.double(forKey: ShepherdViewModel.logicalProjectPaneWidthKey) == Double(saved), "persisted")
        }
        // Past the widest (half the page, 683.5) and past the narrowest (380): each bound holds while dragging and when let go.
        try drag(by: [-300, -400], previews: [683.5, 683.5], saves: 683.5)
        try await eventuallyOnMain("the widest is drawn") { drawn().map { abs($0 - 683.5) <= 0.5 } == true }
        try drag(by: [200, 200], previews: [483.5, 380], saves: 380)
        try await eventuallyOnMain("the narrowest is drawn") { paneWidth() == "380 points" }
        // Five 50pt moves add up, then 11 back: the pointer's place decides, so 239pt left of 380 is 619.
        try drag(by: [-50, -50, -50, -50, -50, 11], previews: [430, 480, 530, 580, 630, 619], saves: 619)
        #expect(r.app.defaults.object(forKey: RightPaneState.widthKey) == nil, "a thread's pane width is untouched")
        try await eventuallyOnMain("the drawn width follows") { paneWidth() == "619 points" }
        try expectReachable("after the drag")

        // Another Project: one width for every Project, as one width serves every thread.
        r.vm.openLogicalProject(LogicalProjectRef(home: .local, id: other.id))
        try await eventuallyOnMain("the other project") { window.layout(); return window.elements().contains { $0.label == "Other project" } }
        #expect(paneWidth() == "619 points")
        r.vm.openLogicalProject(r.ref)

        // A narrower window: the pane gives way so the conversation keeps 400 (1200 less the 232 sidebar and its edge is 967, half
        // of which is 483); narrower still, it overlays the conversation as a thread's does. The saved width is kept for later.
        window.window.setContentSize(CGSize(width: 1200, height: 900))
        try await eventuallyOnMain("clamped") { paneWidth() == "483 points" }
        try expectReachable("in a 1200 window")
        #expect(r.vm.logicalProjectPane.width == 619)
        window.window.setContentSize(CGSize(width: 960, height: 900))
        try await eventuallyOnMain("overlaid") { window.layout(); return (try? control("Close").frame.maxX).map { $0 <= window.window.frame.maxX + 0.5 } == true }
        window.window.setContentSize(CGSize(width: 1600, height: 900))
        try await eventuallyOnMain("back to its width") { paneWidth() == "619 points" }

        // Larger text: the header's controls stay inside the pane, in both appearances.
        let original = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = original }
        for dark in [true, false] {
            window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.host.appearance = window.window.appearance
            ThemeStore.shared.textScale = 1.3
            window.layout()
            try expectReachable("at 1.3x in \(dark ? "dark" : "light")")
        }
        ThemeStore.shared.textScale = original

        // Close hides the divider with the pane, Overview brings both back at the same width.
        try window.press("Close")
        try await eventuallyOnMain("closed") { !r.vm.logicalProjectPaneOpen && handle() == nil }
        try window.press("Overview")
        try await eventuallyOnMain("reopened") { paneWidth() == "619 points" }
        // Expand covers the page with the pane and drops the divider; Collapse restores both.
        try window.press("Expand")
        try await eventuallyOnMain("expanded") { r.vm.logicalProjectPaneExpanded && handle() == nil }
        try window.press("Collapse")
        try await eventuallyOnMain("collapsed") { paneWidth() == "619 points" }

        // The next launch reads the saved width (ShellLayoutTests covers an unsaved or too-narrow one restoring 479).
        #expect(RightPaneState(widthKey: ShepherdViewModel.logicalProjectPaneWidthKey, defaultWidth: 479, defaults: r.app.defaults).width == 619)
    }

    /// The divider under real mouse events sent to the window: while the button is down the pane follows the pointer and nothing is
    /// saved; letting go saves where it was drawn. Never posted, never key.
    private static func paneMouseDrag() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        func handle() -> AccessibilityNode? { window.elements().first { $0.label == "Pane width" } }
        func paneWidth() -> String? { handle().map { "\(Int((window.window.frame.maxX - $0.frame.midX - AppLayout.dividerWidth / 2).rounded())) points" } }
        try await eventuallyOnMain("the divider") { paneWidth() == "479 points" }
        guard await SyntheticMouse.reachesSwiftUIGestures() else {
            FileHandle.standardOutput.write(Data(SyntheticMouse.undeliveredLine.utf8))
            return
        }
        // Window coordinates from the window's own geometry, taken at the 1pt line's trailing edge so the widths are whole.
        let grab = try #require(handle()).frame.midX + AppLayout.dividerWidth / 2 - window.window.frame.minX
        let mouse = SyntheticMouse(window: window.window, y: window.host.bounds.midY)
        try mouse.press(at: grab)
        for step in 1...5 { try mouse.move(to: grab - CGFloat(step) * 20) }
        try await eventuallyOnMain("the pane follows the pointer") { paneWidth() == "579 points" }
        #expect(r.vm.logicalProjectPane.width == 0, "nothing is saved while the button is down")
        try mouse.move(to: grab - 1000)
        try await eventuallyOnMain("no wider than half the page (683.5)") {
            handle().map { abs(window.window.frame.maxX - $0.frame.midX - AppLayout.dividerWidth / 2 - 683.5) <= 0.5 } == true
        }
        try mouse.move(to: grab - 140)
        try mouse.release(at: grab - 140)
        try await eventuallyOnMain("saved where it was let go") { r.vm.logicalProjectPane.width == 619 }
        #expect(r.app.defaults.double(forKey: ShepherdViewModel.logicalProjectPaneWidthKey) == 619)
        try await eventuallyOnMain("drawn where it was saved") { paneWidth() == "619 points" }
        #expect(!window.window.isKeyWindow, "local mouse dispatch never takes the user's focus")
    }

    private static func paneHeader() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let coordinator = r.vm.projectCoordinator
        // Each assign carries the revision the owner last published: the second waits for the first worker's own running record
        // (the owner persists it asynchronously), so the fixture is stable without a sleep or a retry of a refused action.
        var revision = r.project.revision
        for (index, title) in ["Reading list research", "Library API draft"].enumerated() {
            let updated = try await coordinator.perform(projectID: r.project.id, expectedRevision: revision,
                                                        request: .assign(operationID: UUID(), spaceID: r.space.id, title: title, prompt: "slow"))
            revision = updated.revision
            try await eventuallyOnMain("task \(index + 1) is running on the owner") {
                let tasks = r.app.server.state.projects.first?.tasks ?? []
                return tasks.count == index + 1 && tasks.allSatisfy { $0.phase == .running }
            }
            revision = try #require(r.app.server.state.projects.first?.revision)
        }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the pane lists both") { window.layout(); return window.element("Search threads") != nil }
        for name in ["Files", "Automations", "New thread", "Search threads", "Expand", "Close"] {
            let control = try #require(window.controls().first { $0.label == name }, "\(name) is drawn; have \(window.controls().compactMap(\.label).filter { $0.count < 24 })")
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size)")
        }
        // Filter is a native menu button: reached through the accessibility tree, and it has the 28pt box the board draws.
        // A native menu button reports its name as help ("Filter"), not as a label.
        let filter = try #require(window.elements().first { node in
            node.role == "AXMenuButton" && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "Filter"
        }, "Filter is drawn and named")
        #expect(filter.frame.width >= 24 && filter.frame.height >= 24, "Filter is \(filter.frame.size)")
        // Its items come from the real task groups; choosing one filters the list.
        // Choosing "Working" in the real menu filters the list to that group; "Show all" then clears it.
        let offered = try await NativeMenuChoice.choose("Working", from: filter)
        #expect(offered == ["Waiting on you", "Working", "Resolved"], "the menu offers the task groups: \(offered)")
        try await eventuallyOnMain("the choice reached the view model") { r.vm.logicalProjectPaneFilter == [.working] }
        try await eventuallyOnMain("only working threads show") { window.layout()
            return window.controls().contains { $0.label == "Reading list research" } }
        // Search narrows the list to what matches, over the real task titles.
        try window.press("Search threads")
        try await eventuallyOnMain("the field opens") { r.vm.logicalProjectPaneSearching }
        r.vm.logicalProjectPaneQuery = "library"
        // The pane's own rows are named by the task title alone (the sidebar's say their state too), so match them exactly.
        try await eventuallyOnMain("only the match shows") { window.layout()
            return window.controls().contains { $0.label == "Library API draft" }
                && !window.controls().contains { $0.label == "Reading list research" } }
        r.vm.logicalProjectPaneQuery = ""
        // Expand gives the pane the page, and again brings the conversation back.
        try window.press("Expand")
        try await eventuallyOnMain("expanded") { r.vm.logicalProjectPaneExpanded }
        // Expanded, the pane is the whole page less the sidebar; its header's Collapse sits at the pane's trailing edge as before, and the
        // 1pt line still takes its own point at the leading edge.
        let wide = try #require(window.controls().first { $0.label == "Collapse" })
        let pageFrame = try #require(window.elements().first { $0.role == "AXGroup" }?.frame)
        #expect(wide.frame.maxX - pageFrame.minX > pageFrame.width - 40, "Collapse sits at the page's trailing edge: \(wide.frame)")
        try window.press("Collapse")
        try await eventuallyOnMain("collapsed") { !r.vm.logicalProjectPaneExpanded }
        // New thread opens the assignment sheet with the project's linked space chosen. This owner has no other host connected, so
        // the sheet offers no host to choose: the thread runs on the owner.
        try window.press("New thread", nth: 0)
        try await eventuallyOnMain("the sheet") { r.vm.assigningProjectTask?.space == r.space.id }
        #expect(r.vm.assigningProjectTask?.host == nil)
        r.vm.assigningProjectTask = nil
        // Files: the owner's own private folder, listed and previewed through the files.v1 requests. Nothing is opened on this Mac.
        let root = r.app.dir.appendingPathComponent("logical-projects/\(r.project.id.rawValue)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("reports"), withIntermediateDirectories: true)
        try Data("# Reading lists\nBookmarks, tags".utf8).write(to: root.appendingPathComponent("reading-list-notes.md"))
        try Data("inside".utf8).write(to: root.appendingPathComponent("reports/nested.txt"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
        try window.press("Files")
        try await eventuallyOnMain("the files tab") { r.vm.logicalProjectPaneTab == .files }
        try await eventuallyOnMain("the owner's entries are listed") {
            window.layout()
            return window.controls().contains { $0.label?.hasPrefix("reading-list-notes.md") == true } && window.controls().contains { $0.label == "reports" }
        }
        for name in ["reading-list-notes.md", "reports"] {
            let row = try #require(window.controls().first { $0.label?.hasPrefix(name) == true })
            #expect(ControlPress.undersized([row], minimum: .desktop).isEmpty, "\(name) is \(row.frame.size)")
        }
        // A text file previews as data, never opened; a binary one says it cannot be previewed.
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("reading-list-notes.md") == true }?.label))
        try await eventuallyOnMain("the text is previewed") { window.layout(); return window.elements().contains { $0.value?.contains("Bookmarks, tags") == true || $0.label?.contains("Bookmarks, tags") == true } }
        try window.press("Close preview")
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("blob.bin") == true }?.label))
        try await eventuallyOnMain("a binary file is refused in words") {
            window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "").contains("can't be previewed") }
        }
        try window.press("Close preview")
        // A folder opens the next directory, and Back returns.
        try window.press("reports")
        try await eventuallyOnMain("the folder lists its own file") { window.layout(); return window.controls().contains { $0.label?.hasPrefix("nested.txt") == true } }
        #expect(!window.controls().contains { $0.label?.hasPrefix("reading-list-notes.md") == true }, "one directory at a time")
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("Back") == true }?.label))
        try await eventuallyOnMain("back at the root") { window.layout(); return window.controls().contains { $0.label?.hasPrefix("reading-list-notes.md") == true } }
    }

    /// The pane's Filter menu is chosen once per process, so "Show all" starts from the saved choice rather than a first menu.
    private static func filterReset() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneFilter = [.working]
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the Filter menu") { window.layout(); return window.elements().contains { $0.role == "AXMenuButton" } }
        let filter = try #require(window.elements().first { node in
            node.role == "AXMenuButton" && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "Filter"
        }, "Filter is drawn and named")
        let offered = try await NativeMenuChoice.choose("Show all", from: filter)
        #expect(offered.contains("Show all"), "a chosen filter offers its own reset: \(offered)")
        try await eventuallyOnMain("Show all cleared the filter") { r.vm.logicalProjectPaneFilter.isEmpty }
    }

    private static func offer() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        // A real conversation first, so the project has its coordinator; then two proposals through the owner's own request.
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let web = r.app.dir.appendingPathComponent("sample-app-web")
        let docs = r.app.dir.appendingPathComponent("sample-app-docs")
        for folder in [web, docs] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        func propose(_ folder: URL) async throws {
            let shown = try #require(r.app.server.state.projects.first)
            _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: shown.revision,
                request: .proposeSpace(operationID: UUID(), path: folder.path, spaceID: nil, originTaskID: nil))
        }
        try await propose(web)
        try await eventuallyOnMain("the first proposal is pending") { r.app.server.state.projects.first?.spaceProposals.filter { $0.phase == .pending }.count == 1 }
        try await propose(docs)
        try await eventuallyOnMain("both are pending") { r.app.server.state.projects.first?.spaceProposals.filter { $0.phase == .pending }.count == 2 }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the offers are drawn") { window.layout(); return window.controls().filter { $0.label == "Add to project" }.count == 2 }
        for name in ["Not now", "Add to project"] {
            for control in window.controls().filter({ $0.label == name }) {
                #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size)")
                // 02-ProjectAddsSpace markup: Not now 71 x 28 and Add to project 105.1 x 28 (label + 10pt each side inside a 1pt line); the
                // accessibility frame rounds outward to whole points.
                let board: CGFloat = name == "Not now" ? 71 : 105.1
                #expect(abs(control.frame.width - board) < 1 && control.frame.height == 28, "\(name) is \(control.frame.size), board \(board) x 28")
            }
        }
        // "Add to project" links the folder on the owner with provenance "project", and the card goes away.
        let first = try #require(r.app.server.state.projects.first?.spaceProposals.first { $0.phase == .pending })
        try window.press("Add to project", nth: 0)
        try await eventuallyOnMain("accepted on the owner") {
            let project = r.app.server.state.projects.first
            return project?.spaceProposals.first { $0.id == first.id }?.phase == .accepted
                && project?.linkedSpaces.contains { $0.provenance == .project } == true
        }
        try await eventuallyOnMain("one offer left") { window.layout(); return window.controls().filter { $0.label == "Add to project" }.count == 1 }
        // "Not now" is consumed as a denial: nothing is linked and nothing stays actionable.
        let linked = r.app.server.state.projects.first?.linkedSpaces.count
        try window.press("Not now")
        try await eventuallyOnMain("denied on the owner") { r.app.server.state.projects.first?.spaceProposals.filter { $0.phase == .pending }.isEmpty == true }
        #expect(r.app.server.state.projects.first?.spaceProposals.contains { $0.phase == .denied } == true)
        #expect(r.app.server.state.projects.first?.linkedSpaces.count == linked, "denying links nothing")
        try await eventuallyOnMain("no offer is drawn") { window.layout(); return !window.controls().contains { $0.label == "Add to project" } }
    }

    private static func paperclip() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent, so its thread store is kept") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the composer is up") { window.layout(); return window.controls().contains { $0.label == "Attach file" } }
        // The paperclip is a real control with a 24pt hit area, and pressing it takes (it opens the system image picker, which
        // cannot be driven offscreen, so the picked file is not claimed here).
        let clip = try #require(window.controls().first { $0.label == "Attach file" })
        #expect(ControlPress.undersized([clip], minimum: .desktop).isEmpty, "Attach file is \(clip.frame.size)")
        #expect(clip.isEnabled, "the paperclip is enabled once the coordinator's thread supports images")
        try window.press("Attach file")

        // An actual fixture image, put on the card through the composer's own attach path (the one a picked file also goes through).
        let png = r.app.dir.appendingPathComponent("fixture.png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in NSColor.systemOrange.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])).write(to: png)
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: coordinator))
        let input = r.vm.threadStores.input(for: coordinator)
        func messages() -> [ProjectMessage] { r.app.server.state.projects.first?.messages ?? [] }
        let before = messages().count

        // Image with words: Send is the real control. The runtime accepts it, the draft and the submitted image clear, and the owner
        // holds the image's own bytes (the project message records its byte count).
        input.add(urls: [png], store: store, localFiles: true, imagesSupported: r.vm.projectCarriesImages(r.ref.home))
        try await eventuallyOnMain("the image is on the card") { input.attachments.items.count == 1 }
        let bytes = try #require(input.attachments.images.first?.data.count)
        store.draft = "look at this"
        try await eventuallyOnMain("Send is offered") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }
        try window.press("Send")
        try await eventuallyOnMain("the owner recorded the message with its image") {
            let sent = messages().dropFirst(before).first { $0.text == "look at this" }
            return sent?.images?.first?.byteCount == bytes
        }
        try await eventuallyOnMain("the draft and the submitted image cleared") { store.draft.isEmpty && input.attachments.items.isEmpty }

        // Image alone: no text is forced, and it is accepted.
        input.add(urls: [png], store: store, localFiles: true, imagesSupported: r.vm.projectCarriesImages(r.ref.home))
        try await eventuallyOnMain("the second image is on the card") { input.attachments.items.count == 1 }
        // The control row redraws on a change of what it draws; an image arriving alone is that change.
        try await eventuallyOnMain("Send is offered for an image alone") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }
        try window.press("Send")
        try await eventuallyOnMain("an image-only message is recorded") { messages().dropFirst(before).contains { $0.text.isEmpty && $0.images?.count == 1 } }
        try await eventuallyOnMain("the image-only draft cleared") { input.attachments.items.isEmpty }

        // A refused send keeps the words and every image: the project is deleted under the composer, so the owner refuses it.
        input.add(urls: [png], store: store, localFiles: true, imagesSupported: r.vm.projectCarriesImages(r.ref.home))
        store.draft = "this one fails"
        try await eventuallyOnMain("the failing image is on the card") { input.attachments.items.count == 1 }
        let shown = try #require(r.app.server.state.projects.first)
        _ = try await r.app.server.logicalProjects(.delete(projectID: shown.id, expectedRevision: shown.revision))
        try await eventuallyOnMain("the owner has no project") { r.app.server.state.projects.isEmpty }
        let attempts = r.vm.logicalProjects.failure
        _ = attempts
        _ = await r.vm.logicalProjects.sendMessage(r.ref, text: "this one fails", images: input.attachments.images)
        #expect(input.attachments.items.count == 1, "the image stays after a refusal")
        #expect(store.draft == "this one fails", "the words stay after a refusal")
    }

    /// The coordinator's real native transcript carries the owner's typed receipt (`projectAction`), produced by the stub engine's own
    /// `project-action` turn: its tool result is the Project JSON the owner returned and the identifiers in `details`. The card is
    /// drawn from those identifiers resolved against the current Project, in the transcript, not from the words.
    private static func inlineCards() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading list research", prompt: "slow"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the task is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let current = try #require(r.app.server.state.projects.first)
        let text = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
        let result: [String: Any] = ["toolName": "project_assign", "content": [["type": "text", "text": text]],
                                    "details": ["projectID": current.id.rawValue, "revision": current.revision,
                                                "operationID": task.operationID.uuidString, "taskID": task.id.rawValue], "isError": false]
        // The coordinator's working directory is the project's private folder; the stub reads its tool result from there.
        let folder = r.app.dir.appendingPathComponent("logical-projects/\(current.id.rawValue)")
        try JSONSerialization.data(withJSONObject: result).write(to: folder.appendingPathComponent("project-tool-result.json"))
        try await eventuallyOnMain("the view receives the worker's running revision before sending") {
            r.vm.logicalProjects.project(r.ref)?.revision == r.app.server.state.projects.first?.revision
        }
        let accepted = await r.vm.logicalProjects.sendMessage(r.ref, text: "project-action")
        try #require(accepted, "\(String(describing: r.vm.logicalProjects.failure))")
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the page's Project record names its coordinator") { r.vm.logicalProjects.project(r.ref)?.coordinatorAgentID == coordinator }
        try await eventuallyOnMain("the coordinator is a known agent, so its thread store is kept") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: coordinator))
        // The stub's turn holds until `continue-1` appears in its cwd (the coordinator's own folder). The page's thread polls its store
        // once it is mounted; the first pull is what starts the turn's events arriving.
        FileManager.default.createFile(atPath: folder.appendingPathComponent("continue-1").path, contents: nil)
        let server = r.vm.server
        Task { await store.run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        try await eventuallyOnMain("the typed result is in the transcript") {
            window.layout()
            return store.rows.flatMap(\.turn.messages).contains { $0.projectAction?.taskID == task.id }
        }
        // Inline, in the transcript: a card for the task named by its identifier, and no "activity" line standing for the same call.
        try await eventuallyOnMain("the task card is drawn from the reference") {
            window.layout(); return window.controls().contains { $0.label == "Reading list research, working" || $0.label?.hasPrefix("Reading list research, working,") == true }
        }
        let card = try #require(window.controls().first { $0.label == "Reading list research, working" || $0.label?.hasPrefix("Reading list research, working,") == true })
        #expect(ControlPress.undersized([card], minimum: .desktop).isEmpty, "the card is \(card.frame.size)")
        // Pressing it opens that task in the Threads pane.
        try window.press(try #require(card.label))
        try await eventuallyOnMain("the pane shows the task") { r.vm.logicalProjectPaneTask == task.id }
    }

    /// A worker that really publishes (the stub plays `project_publish` against the owner's publisher), and a coordinator that names
    /// its tasks by the IDs `assign` returned. Two tasks share one title: the link's ID, not the words, decides which opens.
private static func chipsAndLinks() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let socket = r.app.scratch.socketPath
        let worker: [String: Any] = ["prompts": ["publish-one": [["publish": ["source": "src.md", "name": "overview.md", "content": "# Overview\nReaders organize links."]],
                                                                  ["wait": "hold-workers", "timeout": 120]],
                                                  "plain": [["wait": "hold-workers", "timeout": 120]]], "socket": socket]
        try JSONSerialization.data(withJSONObject: worker).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let coordinator = r.vm.projectCoordinator
        let first = try await coordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                  request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "publish-one"))
        try await eventuallyOnMain("the first task is running and has published") {
            r.app.server.state.projects.first?.tasks.first?.phase == .running
                && r.app.server.state.projects.first?.artifacts.filter { $0.state == .ready }.count == 1
        }
        let afterFirst = try #require(r.app.server.state.projects.first)
        _ = try await coordinator.perform(projectID: r.project.id, expectedRevision: afterFirst.revision,
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "plain"))
        try await eventuallyOnMain("two tasks with one title") { r.vm.state.projects.first?.tasks.count == 2 }
        let tasks = try #require(r.vm.state.projects.first?.tasks)
        let publisherID = try #require(first.tasks.first?.id)
        let publisher = try #require(tasks.first { $0.id == publisherID })
        let other = try #require(tasks.first { $0.id != publisherID })
        try await eventuallyOnMain("the owner holds a ready receipt for the publisher only", timeout: .seconds(40)) {
            let ready = r.vm.state.projects.first?.artifacts.filter { $0.state == .ready } ?? []
            return ready.count == 1 && ready[0].taskID == publisher.id && ready[0].artifactName == "overview.md"
        }
        // The coordinator's words: a link per task, written with the IDs the owner returned, plus a stale one and another Project's.
        let known = ProjectTaskLinks.url(project: r.project.id, task: other.id)
        let firstURL = ProjectTaskLinks.url(project: r.project.id, task: publisher.id)
        let stale = ProjectTaskLinks.url(project: r.project.id, task: ProjectTaskID())
        let foreign = ProjectTaskLinks.url(project: ProjectID(), task: other.id)
        let said = "Look at [the first](\(firstURL)) and [the second draft](\(known)), not [a gone one](\(stale)) or [a foreign one](\(foreign))."
        let folder = r.app.dir.appendingPathComponent("logical-projects/\(r.project.id.rawValue)")
        try JSONSerialization.data(withJSONObject: ["prompts": ["name them": [["text": said]]], "socket": socket])
            .write(to: folder.appendingPathComponent("project-script.json"))
        try await eventuallyOnMain("both workers are running and the conversation sees their current revision") {
            r.app.server.state.projects.first?.tasks.allSatisfy { $0.phase == .running } == true
                && r.vm.logicalProjects.project(r.ref)?.revision == r.app.server.state.projects.first?.revision
        }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "name them"),
                "\(r.vm.logicalProjects.failure?.message ?? "no refusal")")
        let agent = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == agent } }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: agent))
        let server = r.vm.server
        Task { await store.run(request: { try await server.nativeThread(agentID: agent, request: $0) }) }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneOpen = true
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the coordinator's words are in the transcript") {
            window.layout(); return store.rows.flatMap(\.turn.messages).contains { $0.blocks.contains { $0.text.hasPrefix("Look at") } }
        }

        // Typed links, pressed as controls: each resolving reference is one labelled button at least 24pt tall over its chip; the stale and
        // foreign ones are words with no control anywhere. Two tasks share one title, so the same label appears twice, in text order.
        func chipControls() -> [Control] { window.controls().filter { $0.role == ControlRole.button && ($0.label ?? "").hasPrefix("Open Library API draft") } }
        try await eventuallyOnMain("both resolving references are controls") { window.layout(); return chipControls().count == 2 }
        let chips = chipControls()
        #expect(chips.map(\.label) == Array(repeating: "Open Library API draft, working", count: 2))
        #expect(chips.allSatisfy { $0.frame.height == 24 })
        // Identical chips can round to adjacent pixels at different positions in the paragraph.
        #expect(abs(chips[0].frame.width - chips[1].frame.width) <= 1)
        #expect(!window.controls().contains { ($0.label ?? "").contains("gone") || ($0.label ?? "").contains("foreign") }, "stale and foreign references are inert")
        #expect(ControlPress.undersized(chips, minimum: .desktop).isEmpty, "the chips are \(chips.map(\.frame.size))")
        // Pressed through the rendered control (as VoiceOver does), the ID in the link decides which task opens.
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Library API draft, working", nth: 0)
        try await eventuallyOnMain("the first chip opened its own task") { r.vm.logicalProjectPaneTask == publisher.id }
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Library API draft, working", nth: 1)
        try await eventuallyOnMain("the second chip, with the same title, opened the other task") { r.vm.logicalProjectPaneTask == other.id }
        #expect(r.vm.logicalProjectPaneTab == .threads)
        // The handler itself: stale and foreign references open nothing and never reach the system; any other link is the system's.
        let presentation = ProjectPagePresentation(try #require(r.vm.state.projects.first))
        func press(_ url: String) -> Bool { ProjectTaskLinks.open(try! #require(URL(string: url)), in: r.vm, project: r.project.id, presentation: presentation) }
        r.vm.logicalProjectPaneTask = nil
        #expect(press(stale) && press(foreign) && r.vm.logicalProjectPaneTask == nil)
        #expect(!press("https://example.com/"))

        // Cards: the publisher's card has its receipt's chip; the other card has none.
        r.vm.logicalProjectPaneTask = nil
        // The transcript draws the task cards from typed tool results; this rig's conversation has none, so the card is drawn
        // directly from the same presentation row to press its chip through the real owner read.
        let record = try #require(r.vm.state.projects.first)
        let rows = ProjectPagePresentation(record).rows
        let row = try #require(rows.first { $0.id == publisher.id })
        #expect(row.files.map(\.name) == ["overview.md"])
        #expect(rows.first { $0.id == other.id }?.files.isEmpty == true)
        let card = OffscreenWindow(size: CGSize(width: 900, height: 200), dark: true, ProjectTaskCard(vm: r.vm, ref: r.ref, row: row).padding())
        defer { card.close() }
        let chip = try #require(card.controls().first { $0.label == "Open overview.md" })
        #expect(ControlPress.undersized([chip], minimum: .desktop).isEmpty, "the chip is \(chip.frame.size)")
        try card.press("Open overview.md")
        try await eventuallyOnMain("the chip opened the Files tab on the owner's file") {
            r.vm.logicalProjectPaneTab == .files && r.vm.logicalProjectPaneTask == nil
        }
        try await eventuallyOnMain("the owner's published bytes are previewed as data") {
            window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "").contains("Readers organize links.") }
        }
        // Switching Threads and back to Files is an ordinary tab switch: the preview of the earlier chip is not carried over.
        try window.press("Threads")
        try await eventuallyOnMain("on Threads") { r.vm.logicalProjectPaneTab == .threads }
        #expect(r.vm.logicalProjectPaneFile == nil, "the request was consumed")
        try window.press("Files")
        try await eventuallyOnMain("the Files tab lists the owner's file, with no preview") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix("overview.md") == true }
        }
        #expect(!window.elements().contains { ($0.value ?? $0.label ?? "").contains("Readers organize links.") }, "no stale preview after a tab switch")
        // A request that names another Project is never taken by this one's Files tab.
        r.vm.logicalProjectPaneFile = (LogicalProjectRef(home: .local, id: ProjectID()), try #require(row.files.first))
        try await eventuallyOnMain("a foreign request waits unread") { window.layout(); return r.vm.logicalProjectPaneFile != nil }
        #expect(!window.elements().contains { ($0.value ?? $0.label ?? "").contains("Readers organize links.") }, "a foreign request previews nothing")
        r.vm.openLogicalProject(r.ref)
        #expect(r.vm.logicalProjectPaneFile == nil, "opening a Project drops a request that is not its own")
    }

    /// One task named twice in one paragraph is two chips, each a labelled 24pt button that opens that task; a title longer than the line wraps over
    /// two lines and is still a single control. (Each mention restarts its own fragment count, so a later mention keeps its dot and control.)
    private static func repeatedAndWrappedChips() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let long = "Compare how different reading lists organize bookmarks, notes and shared folders across regions"
        let socket = r.app.scratch.socketPath
        let hold: [String: Any] = ["prompts": ["slow": [["wait": "hold-workers", "timeout": 120]], "long": [["wait": "hold-workers", "timeout": 120]]], "socket": socket]
        try JSONSerialization.data(withJSONObject: hold).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let coordinator = r.vm.projectCoordinator
        let first = try await coordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                  request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "slow"))
        try await eventuallyOnMain("the first task is running") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let afterFirst = try #require(r.app.server.state.projects.first)
        let second = try await coordinator.perform(projectID: r.project.id, expectedRevision: afterFirst.revision,
                                                   request: .assign(operationID: UUID(), spaceID: r.space.id, title: long, prompt: "long"))
        try await eventuallyOnMain("both tasks are running on the owner") {
            let tasks = r.app.server.state.projects.first?.tasks ?? []
            return tasks.count == 2 && tasks.allSatisfy { $0.phase == .running } && r.vm.state.projects.first?.revision == r.app.server.state.projects.first?.revision
        }
        let shortID = try #require(first.tasks.first?.id)
        let longID = try #require(r.vm.state.projects.first?.tasks.first { $0.id != shortID }?.id)
        _ = second
        let short = ProjectTaskLinks.url(project: r.project.id, task: shortID), wide = ProjectTaskLinks.url(project: r.project.id, task: longID)
        let said = "Start with [the draft](\(short)), then [that same draft again](\(short)), and last [the long one](\(wide)) which is wide enough to wrap."
        let folder = r.app.dir.appendingPathComponent("logical-projects/\(r.project.id.rawValue)")
        try JSONSerialization.data(withJSONObject: ["prompts": ["name them": [["text": said]]], "socket": socket]).write(to: folder.appendingPathComponent("project-script.json"))
        let sent = await r.vm.logicalProjects.sendMessage(r.ref, text: "name them")
        #expect(sent, "refused: \(r.vm.logicalProjects.failure?.message ?? "no message")")
        let agent = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == agent } }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: agent))
        let server = r.vm.server
        Task { await store.run(request: { try await server.nativeThread(agentID: agent, request: $0) }) }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneOpen = false   // a narrow column would wrap even the short ones: the wide conversation wraps only the long title
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        func chips(_ prefix: String) -> [Control] { window.controls().filter { $0.role == ControlRole.button && ($0.label ?? "").hasPrefix(prefix) } }
        try await eventuallyOnMain("every mention is a control") { window.layout(); return chips("Open Library API draft").count == 2 && chips("Open Compare how").count >= 1 }
        #expect(chips("Open Library API draft").count == 2, "the same task mentioned twice is two controls")
        #expect(chips("Open Compare how").count == 1, "a long chip that wraps over two lines is one control, not one per line")
        #expect(ControlPress.undersized(chips("Open "), minimum: .desktop).isEmpty, "every chip is a 24pt target: \(chips("Open ").map(\.description))")
        // Both mentions of the same task open it; the long one opens its own task.
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Library API draft, working", nth: 1)
        try await eventuallyOnMain("the second mention of the same task opens it") { r.vm.logicalProjectPaneTask == shortID }
        r.vm.logicalProjectPaneTask = nil
        try window.press(try #require(chips("Open Compare how").first?.label))
        try await eventuallyOnMain("the long chip opens its own task") { r.vm.logicalProjectPaneTask == longID }
    }

    /// ControlPress: pause, send while paused, resume. The message the owner accepted is represented in the conversation the whole
    /// time: in the composer's shared Up next (read-only, Paused) while the owner holds it, then in the transcript once its native
    /// operation is there. Never a sent-looking bubble while it waits, and never drawn twice.
    private static func heldMessages() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: coordinator))
        let server = r.vm.server
        Task { await store.run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        try await eventuallyOnMain("the first message reached the transcript") {
            window.layout(); return r.app.server.state.projects.first?.messages.first?.phase == .delivered
        }
        // A user bubble is one combined element ("<words>, <state note>"), so it is found by the words it begins with.
        // The words come from the real producer the view draws from (the Project's messages minus the transcript's consumed
        // operations); the state is the one drawn note, which accessibility exposes.
        func heldNow() -> [ProjectHeldMessage] {
            let project = r.vm.logicalProjects.project(r.ref)
            let consumed = Set((store.messages + store.pending + store.rows.flatMap(\.turn.messages)).compactMap { $0.operationID })
            return ProjectHeldMessages.held(messages: project?.messages ?? [], paused: project?.paused ?? false, consumed: consumed)
        }
        // The shared Up next row's own label, and the transcript's bubble for the same words (with or without a note).
        let row = "Queued 1 of 1: send me later"
        func upNextRows() -> Int { window.elements().filter { $0.label == row }.count }
        func bubbles() -> Int {
            window.elements().filter { node in
                let label = node.label ?? node.value ?? ""
                return label == "send me later" || label.hasPrefix("send me later, ")
            }.count
        }
        // Pause through the real control, then send through the real composer: the owner accepts and holds it.
        try window.press("Project settings")
        try await eventuallyOnMain("settings") { window.layout(); return window.element("Pause") != nil }
        try window.press("Pause")
        try await eventuallyOnMain("paused") { r.app.server.state.projects.first?.paused == true }
        r.vm.openLogicalProject(r.ref)
        try await eventuallyOnMain("the page is back") { window.layout(); return window.controls().contains { $0.label == "Send" } }
        store.draft = "send me later"
        try await eventuallyOnMain("Send is offered") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }
        try window.press("Send")
        try await eventuallyOnMain("the owner holds it queued") {
            r.app.server.state.projects.first?.messages.first { $0.text == "send me later" }?.phase == .queued
        }
        try await eventuallyOnMain("the draft cleared, so the person knows it was accepted") { store.draft.isEmpty }
        // It is still represented, as a normal thread's queued message: the shared Up next row, its header Paused, and no bubble.
        try await window.diagnosing(stores: [store], needles: [row, "send me later"], extra: {
            ["held=\(heldNow().map { "\($0.text) | \($0.phase)" }) projectMessages=\((r.vm.logicalProjects.project(r.ref)?.messages ?? []).map { "\($0.text) \($0.phase)" })"]
        }) {
            try await eventuallyOnMain("the held message waits in Up next") { upNextRows() == 1 }
        }
        #expect(heldNow().map(\.text) == ["send me later"], "its own words are what is held")
        #expect(window.element("Up next, 1 message") != nil, "the shared stack's header counts it")
        #expect(window.elements().contains { $0.label == "Paused" || $0.value == "Paused" }, "the header says the Project holds it")
        #expect(bubbles() == 0, "never a sent-looking transcript bubble while the owner holds it")
        // The owner offers no queue controls: none of the native stack's are drawn, and no empty options menu.
        let unsupported: Set = ["Queue options", "Steer now", "Send now", "Edit", "Delete", "Back to the queue", "Steer all now", "Send all now"]
        #expect(!window.controls().contains { unsupported.contains($0.label ?? "") }, "\(window.controls().compactMap(\.label))")
        // Resume: the owner hands it to pi only now. Until the native transcript holds its operation it stays in Up next; then it is the
        // transcript's alone. Each observation is one place or (for a frame while the two pushes cross) none, never two.
        try window.press("Resume", nth: 0)
        var sawTwo = false
        try await eventuallyOnMain("resumed and delivered") {
            if upNextRows() > 0 && bubbles() > 0 { sawTwo = true }
            return r.app.server.state.projects.first?.messages.first { $0.text == "send me later" }?.phase == .delivered
        }
        // The thread's own bubble takes over once its native operation is consumed: nothing held, no row, never two.
        try await eventuallyOnMain("the Up next row gave way to the transcript") {
            heldNow().isEmpty && upNextRows() == 0 && window.element("Up next, 1 message") == nil
                && store.rows.flatMap(\.turn.messages).count { $0.role == "user" && $0.blocks.contains { $0.text == "send me later" } } == 1
        }
        #expect(!sawTwo, "never drawn in both places")
    }

    /// A relaunch with the Project paused: the owner holds a queued message (with an image), one whose delivery was refused and one
    /// that was in flight when the app quit. The queued one is in Up next with its image's name, the refused and lost ones stay in the
    /// transcript with their own notes. Resume starts the coordinator's pi, which takes a while: the message stays pending in Up next
    /// all that time. Only the real handoff (the owner's native send, whose pending row the transcript then holds) moves it, and it is
    /// `.delivering` there until pi starts it. Nothing undelivered is resent.
    private static func upNextUntilHandoff() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let directory = try makeScratchDirectory("upn")
        let stateURL = directory.appendingPathComponent("state.json")
        let folder = directory.appendingPathComponent("logical-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The coordinator's pi waits for `release-pi` before it serves (a slow start).
        try JSONSerialization.data(withJSONObject: ["gate": "release-pi"]).write(to: folder.appendingPathComponent("stub-pi-startup.json"))
        let space = Space(name: "Projects", path: folder.path, hidden: true, holdsProjects: true)
        var fixture = Fixture.agent("Sample App", in: space)
        var project = Project(name: "Sample App", goal: "", coordinatorAgentID: fixture.agent.id, paused: true)
        fixture.agent.coordinatorFor = project.id
        var refused = ProjectMessage(id: UUID(), text: "this one was refused", phase: .failed)
        refused.failureDetail = "The agent refused it: no API key"
        let lost = ProjectMessage(id: UUID(), text: "this one was in flight", phase: .delivering)
        // `preflight-compact` makes the stub hold the prompt (preflight-go, then preflight-reply) before it starts the user message.
        var waiting = ProjectMessage(id: UUID(), text: "preflight-compact the reading list", phase: .queued)
        waiting.humanSubmitted = true
        // The owner's own private input, stored where the delivery reads it, so the image really goes with the message.
        try LogicalProjectDirectory.create(id: project.id, beside: stateURL)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        waiting.images = try LogicalProjectDirectory.storeInputs(id: project.id, operation: waiting.id,
                                                                 images: [NativeImage(mimeType: "image/png", data: png, name: "sketch.png")], beside: stateURL)
        project.messages = [ProjectMessage(id: UUID(), text: "hello", phase: .delivered), refused, lost, waiting]
        var state = Fixture.state(spaces: [space], agents: [fixture])
        state.projects = [project]
        try JSONEncoder().encode(state).write(to: stateURL)
        let app = try AppHarness(directory: directory)
        defer { app.stop() }
        app.settings.projectsEnabled = true
        // The owner's launch is the only start path here: with agents restored at launch, the app's own restored start can still be in
        // flight when Resume asks the owner to launch the coordinator, and that launch is refused (`paneUnavailable`), which pauses the
        // Project again. That race is the owner lifecycle's, reported separately; this test is about what the conversation draws.
        let vm = try await app.start()
        func message(_ id: UUID) -> ProjectMessage? { app.server.state.projects.first?.messages.first { $0.id == id } }
        // The relaunch never claims an in-flight delivery happened, and never resends it: it is unknown.
        #expect(message(lost.id)?.phase == .unknown, "in flight at quit is unknown after a relaunch: \(String(describing: message(lost.id)?.phase))")
        let ref = LogicalProjectRef(home: .local, id: project.id)
        vm.openLogicalProject(ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let store = vm.threadStores.store(for: fixture.agent.id)
        let row = "Queued 1 of 1: preflight-compact the reading list"
        func held() -> [ProjectHeldMessage] {
            let shown = vm.logicalProjects.project(ref)
            let consumed = Set((store.messages + store.pending + store.rows.flatMap(\.turn.messages)).compactMap { $0.operationID })
            return ProjectHeldMessages.held(messages: shown?.messages ?? [], paused: shown?.paused ?? false, consumed: consumed)
        }
        func labelled(_ text: String, note: String? = nil) -> Int {
            let labels = note.map { [$0, "\(text), \($0)"] } ?? [text]
            return window.elements().filter { labels.contains($0.label ?? $0.value ?? "") }.count
        }
        func echoes() -> Int {
            store.rows.flatMap(\.turn.messages).count { $0.role == "user" && $0.blocks.contains { $0.text == waiting.text } }
        }
        try await window.diagnosing(stores: [store], needles: [row], extra: { ["held=\(held().map { "\($0.text) \($0.phase)" })"] }) {
            try await eventuallyOnMain("the queued message waits in Up next") { window.layout(); return labelled(row) == 1 }
        }
        #expect(window.elements().contains { $0.label == "Paused" || $0.value == "Paused" } && window.element("Up next, 1 message") != nil)
        #expect(labelled(waiting.text) == 0 && echoes() == 0, "no transcript bubble while the owner holds it")
        // The image goes by the name the owner holds; this Mac draws no bytes for it.
        #expect(ProjectHeldMessages.upNext(held()).queue.map { $0.images.map(\.name) } == [["sketch.png"]])
        // Undelivered outcomes stay in the transcript, each with its own note: a refusal's reason, an unknown's none.
        #expect(labelled("this one was refused", note: "Not delivered. The agent refused it: no API key. Send it again to retry.") == 1)
        #expect(labelled("this one was in flight", note: "Delivery unconfirmed. Send it again to retry.") == 1)

        // The relaunch holds the coordinator off on purpose (nothing can be delivered while paused), as a cold Project does.
        try await eventuallyOnMain("the restored coordinator is held off") { store.offline && !store.starting && store.loadError == nil }
        // Resume: the owner starts the coordinator's pi, which is still booting. Resume alone sends nothing, so nothing looks sent.
        #expect(await vm.logicalProjects.setPaused(ref, false))
        let watchedUntil = ContinuousClock.now + .milliseconds(900)
        var moved = false
        try await eventuallyOnMain("the start is watched") {
            window.layout()
            if message(waiting.id)?.phase != .queued || labelled(row) != 1 || echoes() != 0 || labelled(waiting.text) != 0 { moved = true }
            return ContinuousClock.now >= watchedUntil
        }
        #expect(!moved, "while pi starts, the message stays queued and in Up next only: \(String(describing: message(waiting.id)?.phase))")
        #expect(!window.elements().contains { $0.label == "Paused" || $0.value == "Paused" }, "resumed: the header no longer says Paused")

        // pi serves: the owner hands the message over. Once the transcript holds the delivery's pending row it is there alone, still
        // `.delivering`: pi has neither accepted nor started it.
        try Data().write(to: folder.appendingPathComponent("release-pi"))
        let delivery = { message(waiting.id).map { $0.nativeDeliveryID ?? $0.id } }
        try await window.diagnosing(stores: [store], needles: [waiting.text], extra: { ["phase=\(String(describing: message(waiting.id)?.phase)) paused=\(String(describing: app.server.state.projects.first?.paused)) loadError=\(String(describing: store.loadError))"] }) {
            try await eventuallyOnMain("the handoff's native pending row is in the transcript", timeout: .seconds(30)) {
                window.layout()
                return message(waiting.id)?.phase == .delivering
                    && store.rows.flatMap(\.turn.messages).contains { $0.operationID != nil && $0.operationID == delivery() }
            }
        }
        try await eventuallyOnMain("Up next gave way to the transcript's echo") { window.layout(); return labelled(row) == 0 && echoes() == 1 }
        #expect(message(waiting.id)?.phase == .delivering, "a handoff is not a delivery")
        #expect(window.element("Up next, 1 message") == nil)

        // pi starts it: only native consumption marks it delivered, and it is still drawn once.
        try Data().write(to: folder.appendingPathComponent("preflight-go"))
        try Data().write(to: folder.appendingPathComponent("preflight-reply"))
        try await eventuallyOnMain("delivered once pi starts it", timeout: .seconds(30)) { message(waiting.id)?.phase == .delivered }
        try await eventuallyOnMain("drawn once, in the transcript") { window.layout(); return labelled(row) == 0 && echoes() == 1 }
        // Nothing undelivered was resent on its own.
        #expect(message(refused.id)?.phase == .failed && message(lost.id)?.phase == .unknown)
        #expect(app.server.state.projects.first?.messages.count == 4, "no new message was made for a retry")
    }

    /// F9: before the first message there is no coordinator, so its native snapshot (empty `supportedActions`) says nothing. The
    /// paperclip, the picker, paste and drop all ask the Project's owner instead, and an image alone is a first message.
    private static func firstImageOnly() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        #expect(r.app.server.state.projects.first?.coordinatorAgentID == nil, "no coordinator exists yet")
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the composer is up") { window.layout(); return window.controls().contains { $0.label == "Attach file" } }
        let clip = try #require(window.controls().first { $0.label == "Attach file" })
        #expect(clip.isEnabled, "the paperclip is offered before any coordinator exists")
        #expect(ControlPress.undersized([clip], minimum: .desktop).isEmpty, "Attach file is \(clip.frame.size)")
        #expect(r.vm.projectCarriesImages(.local), "this Mac's own runtime carries images")
        try window.press("Attach file")
        // The picked file, paste and drop all end in the same add: a real fixture image, with no coordinator behind it.
        let png = r.app.dir.appendingPathComponent("first.png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in NSColor.systemTeal.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let encoded = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try encoded.write(to: png)
        let store = r.vm.emptyProjectConversation
        let input = r.vm.emptyProjectInput
        input.add(urls: [png], store: store, localFiles: true, imagesSupported: true)
        try await eventuallyOnMain("the image is on the card") { input.attachments.items.count == 1 }
        #expect(input.attachments.error == nil, "an image is not refused for want of a coordinator")
        let bytes = try #require(input.attachments.images.first?.data.count)
        store.draft = ""
        try await eventuallyOnMain("Send is offered for an image alone") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }
        try window.press("Send")
        try await eventuallyOnMain("the owner recorded an image-only first message") {
            r.app.server.state.projects.first?.messages.first { $0.text.isEmpty }?.images?.first?.byteCount == bytes
        }
        try await eventuallyOnMain("a coordinator was created by it") { r.app.server.state.projects.first?.coordinatorAgentID != nil }
        try await eventuallyOnMain("the image cleared once the owner accepted it") { input.attachments.items.isEmpty }
    }

    /// F8: a worker's thread goes through the OWNER keyed by Project and task. The viewer (this Mac's UI against a remote owner)
    /// has no executor connection at all; what it asks is `.worker(projectID:taskID:request:)`, and the owner finds the worker.
    private static func workerThroughOwner() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading list research", prompt: "slow"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the task has an opened worker session on the owner") {
            r.app.server.state.projects.first?.tasks.first?.workerSessionID != nil
        }
        // The helper the pane, the conversation's question card and the worker thread all use: by Project and task, never by agent.
        let request = r.vm.projectWorkerRequest(r.ref, task: task.id)
        let snapshot = try await request(.snapshot())
        guard case .snapshot(let value) = snapshot else { throw RigError("the owner did not return the worker's thread") }
        #expect(value.piSessionID.isEmpty == false, "the owner served the worker's own native thread")
        // A task the owner does not know is refused by the owner, not routed anywhere else.
        let unknown = r.vm.projectWorkerRequest(r.ref, task: ProjectTaskID())
        do { _ = try await unknown(.snapshot()); throw RigError("an unknown task was served") }
        catch let error as LogicalProjectsError { #expect(error.code == "not_found") }
        // A remote home addresses its owner through the same transport, and no executor is configured on this viewer.
        #expect(r.vm.remoteHosts.connections.isEmpty, "this viewer has no executor or any other host connection")
    }

    /// Board 08: the worker's own plan. The stub engine returns the canonical `project_plan` result (`Tests/Extensions/project-plan-results.json`,
    /// the same JSON the pinned engine test produces) as a real tool call; the production RPC projection and `NativeProjectPlan` type it,
    /// and the pane's worker thread draws the card from the typed plan. The first update is replaced by none: one card, no activity line.
    private static func stepsCard() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Extensions/project-plan-results.json"))) as? [[String: Any]])
        var result = try #require(fixture.first { $0["id"] as? String == "plan-1" }?["result"] as? [String: Any])
        result["toolName"] = "project_plan"
        // Every worker runs in the linked Space's folder; the stub reads its next tool result from there.
        try JSONSerialization.data(withJSONObject: result).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-plan-result.json"))
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading widget mockup", prompt: "project-plan"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the worker is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneTask = task.id
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = r.vm.projectWorkerStore(.local, task.workerAgentID)
        let request = r.vm.projectWorkerRequest(r.ref, task: task.id)
        Task { await store.run(request: request) }
        try await eventuallyOnMain("the typed plan reached the worker's native transcript") {
            window.layout()
            return store.rows.contains { $0.presentation?.latestProjectPlan != nil }
        }
        let plans: [NativeProjectPlan] = store.rows.compactMap { $0.presentation?.latestProjectPlan }
        let plan = try #require(plans.last)
        #expect(plan.steps.map(\.state) == [.current, .pending])
        // The card is one element named Steps whose rows are the plan's own words, in order, each saying its state.
        try await eventuallyOnMain("the Steps card is drawn") { window.layout(); return window.elements().contains { $0.label == "Steps" } }
        let rows = window.elements().filter { $0.label == plan.steps[0].text || $0.label == plan.steps[1].text }
        #expect(rows.map(\.label) == plan.steps.map(\.text), "each step is drawn once, in order: \(rows.map { $0.label ?? "" })")
        #expect(rows.map(\.value) == ["in progress", "pending"])
        // The generic activity line for the same call is not drawn: nothing is named for the tool, and the words are not repeated.
        #expect(!window.elements().contains { ($0.label ?? "").lowercased().contains("project_plan") || ($0.label ?? "").hasPrefix("Ran ") },
                "no activity line stands for the plan call")
        #expect(window.elements().filter { ($0.label ?? "").contains("Building the library") }.count == 1)
        // Board 08 markup (1x): the card is 447 x 66 (1137, 183.78), each step row 17 tall at 1x, 6 apart, and the live line a 15pt box 16pt
        // under the card (card bottom 249.78, line 265.78). The same window is measured in both appearances and at the Mac's largest text size,
        // where rows grow with the text but the card's width, its 12pt padding and the 16pt gap stay.
        let original = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = original }
        for (dark, scale) in [(true, CGFloat(1)), (false, 1), (true, 1.3), (false, 1.3)] {
            window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.host.appearance = window.window.appearance
            ThemeStore.shared.textScale = scale
            let mode = "\(dark ? "dark" : "light") x\(scale)"
            try await eventuallyOnMain("the Steps card is drawn in \(mode)") { window.layout(); return window.elements().contains { $0.label == "Steps" } }
            let card = try #require(window.elements().first { $0.label == "Steps" })
            let rows = window.elements().filter { $0.label == plan.steps[0].text || $0.label == plan.steps[1].text }
            let live = try #require(window.elements().first { ($0.label ?? "").hasPrefix("Working") })
            #expect(card.frame.width == 447, "Steps card \(card.frame.size) in \(mode), board 447 wide")
            // The pane is a 480 box (a 1pt leading line, then the 479 aside), so the box begins where the conversation, the page minus 480,
            // ends, and the Steps card sits the aside's 16pt gutter in from there.
            let page = window.elements().first { $0.role == "AXGroup" }?.frame ?? .zero
            let boxLeft = card.frame.minX - page.minX - NWLeadMetrics.paneBorder - NWLeadMetrics.paneThreadGutter
            #expect(abs(boxLeft - (page.width - NWLeadMetrics.paneWidth)) < 0.5, "the pane box begins at \(boxLeft) in \(mode); the page is \(page.width) wide")
            let gap = rows.count == 2 ? abs(rows[1].frame.minY - rows[0].frame.maxY) : -1
            #expect(abs(gap - 6) < 0.6 || abs(rows[0].frame.minY - rows[1].frame.maxY - 6) < 0.6, "6pt between rows in \(mode)")
            #expect(abs((card.frame.minY - live.frame.maxY) - 16) < 0.5, "live line \(card.frame.minY - live.frame.maxY) under the card in \(mode); board 16")
            if scale == 1 {
                #expect(card.frame.height == 66, "Steps card \(card.frame.size) in \(mode), board 447 x 66")
                #expect(rows.allSatisfy { $0.frame.height == 17 } && live.frame.height == 15, "rows \(rows.map(\.frame.size)) and live line \(live.frame.size) in \(mode), board 17 and 15")
            } else {
                #expect(card.frame.height > 66, "the card grows with the text: \(card.frame.size) in \(mode)")
            }
        }
    }

    /// ProjectLead-ThreadRunning from the real runtime. The assignment and the person's own steer are consecutive user messages, so one
    /// native user turn: the assignment is plain prose (no bubble), the person's words are a bubble, in one row.
    private static func mixedWorkerTurn() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let socket = r.app.scratch.socketPath
        try JSONSerialization.data(withJSONObject: ["prompts": ["Build the reading widget": [["wait": "hold-workers", "timeout": 120]]], "socket": socket])
            .write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading widget mockup", prompt: "Build the reading widget"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the worker is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneTask = task.id
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = r.vm.projectWorkerStore(.local, task.workerAgentID)
        Task { await store.run(request: r.vm.projectWorkerRequest(r.ref, task: task.id)) }
        try await eventuallyOnMain("the assignment is the worker's first user message") {
            window.layout(); return store.rows.contains { $0.isUser } && store.running
        }
        // The person steers while the assignment's turn is still the last user turn.
        store.draft = "use the blue theme"
        let sent = await store.send(delivery: .steer)
        #expect(sent)
        // The engine reads a steer between steps: the worker's held step ends, then it reads the person's words into the same turn.
        FileManager.default.createFile(atPath: URL(fileURLWithPath: r.space.path).appendingPathComponent("hold-workers").path, contents: nil)
        try await eventuallyOnMain("the person's words and the assignment share one user turn") {
            window.layout()
            return store.rows.contains { $0.isUser && $0.turn.messages.count == 2 }
        }
        let current = try #require(r.vm.state.projects.first?.tasks.first { $0.id == task.id })
        let row = try #require(store.rows.first { $0.isUser })
        let origins = ProjectUserOrigins(assignment: Set([current.operationID] + [current.nativeDeliveryID].compactMap { $0 }))
        let segments = origins.segments(row.turn)
        #expect(segments.count == 2, "assignment then the person: \(segments)")
        if case .assignment(let words) = segments.first { #expect(words == "Build the reading widget") } else { Issue.record("the assignment is not first and plain") }
        if case .person(let kept) = segments.last { #expect(kept.bubbles.map(\.text) == ["use the blue theme"]) } else { Issue.record("the person's words lost their bubble") }
        // Drawn: the assignment spans the column and the person's narrower bubble ends on its trailing edge.
        // macOS 26 labels the combined bubble with its text; macOS 27 leaves that same element unlabeled.
        try await window.diagnosing(stores: [store], needles: ["Build the reading widget", "use the blue theme"], extra: {
            ["segments=\(segments)"]
        }) {
            try await eventuallyOnMain("both are drawn") {
                window.layout()
                let nodes = window.elements()
                guard let prose = nodes.first(where: { $0.role == "AXStaticText" && $0.value == "Build the reading widget" }) else { return false }
                return nodes.contains {
                    $0.role == "AXUnknown" && ["", "use the blue theme"].contains($0.label ?? "")
                        && abs($0.frame.maxX - prose.frame.maxX) < 1 && $0.frame.width < prose.frame.width / 2
                }
            }
        }
        let nodes = window.elements()
        let prose = try #require(nodes.first { $0.role == "AXStaticText" && $0.value == "Build the reading widget" })
        #expect(prose.frame.width > 400, "the assignment is the pane column's own text, not a bubble: \(prose.frame)")
        #expect(store.rows.filter(\.isUser).count == 1, "one user row, as before")
    }

    /// ProjectLead-ThreadRunning's left composer. The coordinator's turn is held by the engine's own `project-action` script (it waits for
    /// `continue-1`, which this test never creates), so the thread is running while the composer is drawn. The board draws the disabled arrow,
    /// not Stop (a Stop would pause the Project). With words typed, Send is enabled and remains the only action.
    private static func projectComposerWhileRunning() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading list research", prompt: "slow"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the task is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let current = try #require(r.app.server.state.projects.first)
        let text = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
        let result: [String: Any] = ["toolName": "project_assign", "content": [["type": "text", "text": text]],
                                    "details": ["projectID": current.id.rawValue, "revision": current.revision,
                                                "operationID": task.operationID.uuidString, "taskID": task.id.rawValue], "isError": false]
        // The coordinator's working directory is the project's private folder; the stub reads its tool result from there.
        let folder = r.app.dir.appendingPathComponent("logical-projects/\(current.id.rawValue)")
        try JSONSerialization.data(withJSONObject: result).write(to: folder.appendingPathComponent("project-tool-result.json"))
        try await eventuallyOnMain("the view receives the worker's running revision before sending") {
            r.vm.logicalProjects.project(r.ref)?.revision == r.app.server.state.projects.first?.revision
        }
        let accepted = await r.vm.logicalProjects.sendMessage(r.ref, text: "project-action")
        try #require(accepted, "\(String(describing: r.vm.logicalProjects.failure))")
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the page's Project record names its coordinator") { r.vm.logicalProjects.project(r.ref)?.coordinatorAgentID == coordinator }
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: coordinator))
        let server = r.vm.server
        Task { await store.run(request: { try await server.nativeThread(agentID: coordinator, request: $0) }) }
        try await eventuallyOnMain("the coordinator's turn is running") { window.layout(); return store.running }
        #expect(store.draft.isEmpty, "the field is empty")
        let sends = window.controls().filter { $0.label == "Send" }
        #expect(sends.count == 1 && sends.allSatisfy { !$0.isEnabled }, "the Project's own composer shows a disabled arrow: \(sends.map(\.description))")
        #expect(!window.controls().contains { $0.label == "Stop" }, "and no Stop while its field is empty")
        store.draft = "one more thing"
        try await eventuallyOnMain("a draft enables the single Send action") {
            window.layout()
            return window.controls().contains { $0.label == "Send" && $0.isEnabled }
        }
        #expect(!window.controls().contains { $0.label == "Stop" }, "typing never adds a second action to the Project composer")
        #expect(r.app.server.state.projects.first?.paused == false, "nothing paused the Project")
    }

    /// The worker's empty composer while its turn runs is the board's red Stop; pressing it aborts that worker's own turn only.
    private static func workerStop() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        try JSONSerialization.data(withJSONObject: ["prompts": ["Build the reading widget": [["wait": "hold-workers", "timeout": 120]]], "socket": r.app.scratch.socketPath])
            .write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Reading widget mockup", prompt: "Build the reading widget"))
        let task = try #require(assigned.tasks.first)
        try await eventuallyOnMain("the worker is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneTask = task.id
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = r.vm.projectWorkerStore(.local, task.workerAgentID)
        Task { await store.run(request: r.vm.projectWorkerRequest(r.ref, task: task.id)) }
        try await eventuallyOnMain("the worker's Stop is drawn") { window.layout(); return store.running && window.controls().contains { $0.label == "Stop" && $0.isEnabled } }
        let stops = window.controls().filter { $0.label == "Stop" }
        #expect(stops.count == 1, "one Stop in the window (the conversation has no turn): \(stops.map(\.description))")
        #expect(ControlPress.undersized(stops, minimum: .desktop).isEmpty, "Stop is \(stops.map(\.frame.size))")
        #expect(!window.controls().contains { $0.label == "Send" && $0.frame.minX > 1100 }, "the worker's empty composer draws no Send")
        // Board 08 markup, 1600x900 window: Stop is 28 x 28 at (1534, 855); Attach 26 x 26 at (1143, 856). The AX frame of a 28pt disc is
        // its 34pt hit target centred on it (x 1531, y 852 here).
        let origin = try #require(window.elements().first { $0.role == "AXGroup" }?.frame)
        func rect(_ c: Control) -> CGRect { CGRect(x: c.frame.minX - origin.minX, y: origin.maxY - c.frame.maxY, width: c.frame.width, height: c.frame.height) }
        let stopRect = rect(try #require(stops.first))
        let attach = try #require(window.controls().filter { $0.label == "Attach file" }.map(rect).first { $0.minX > 1100 })
        #expect(stopRect.midX == 1548 && stopRect.midY == 869, "Stop centre \(stopRect.midX), \(stopRect.midY); board 1548, 869")
        #expect(attach.minX == 1143 && attach.minY == 856, "Attach at \(attach.origin); board 1143, 856")
        try window.press("Stop")
        try await eventuallyOnMain("the worker's turn was aborted") { !store.running }
        #expect(r.app.server.state.projects.first?.paused == false, "a worker's Stop does not pause the project")
    }

    /// The person's Send button, a refusal and the explicit retry. The owner no longer has the Project (deleted under the open composer), so
    /// it refuses every send. Nothing here posts an event or takes focus: the press is the accessibility action, the window is off screen.
    private static func refusedSend() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = try #require(r.vm.projectCoordinator.conversationStore(agentID: coordinator))
        let input = r.vm.threadStores.input(for: coordinator)
        let png = r.app.dir.appendingPathComponent("keep.png")
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in NSColor.systemPurple.setFill(); rect.fill(); return true }
        let tiff = try #require(image.tiffRepresentation)
        let encoded = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
        try encoded.write(to: png)
        input.add(urls: [png], store: store, localFiles: true, imagesSupported: r.vm.projectCarriesImages(r.ref.home))
        store.draft = "this one is refused"
        try await eventuallyOnMain("the image is on the card and Send is offered") {
            window.layout(); return input.attachments.items.count == 1 && window.controls().contains { $0.label == "Send" && $0.isEnabled }
        }
        let shown = try #require(r.app.server.state.projects.first)
        _ = try await r.app.server.logicalProjects(.delete(projectID: shown.id, expectedRevision: shown.revision))
        try await eventuallyOnMain("the owner has no project") { r.app.server.state.projects.isEmpty }
        try await eventuallyOnMain("Send is still offered") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }

        // The Send button: the owner refuses, so the draft and the image stay, and the reason is shown.
        let before = r.vm.logicalProjects.operations[r.ref]?.id
        #expect(before == nil, "no operation is kept before the first press")
        try window.press("Send")
        try await eventuallyOnMain("the owner's refusal is reported") { r.vm.logicalProjects.failure != nil }
        #expect(store.draft == "this one is refused", "the words stay after a refusal")
        #expect(input.attachments.items.count == 1, "the image stays after a refusal")
        let kept = r.vm.logicalProjects.operations[r.ref]?.id
        // Nothing retries on its own: the identity and the owner's record are as the refusal left them.
        try await Task.sleep(for: .milliseconds(300))
        #expect(r.vm.logicalProjects.operations[r.ref]?.id == kept, "no automatic retry made another operation")
        #expect(r.app.server.state.projects.isEmpty)
        // The explicit retry is the person pressing Send again with the same words: the same operation, the same payload.
        // Clearing the shown refusal makes the second attempt observable: it is only back once the owner has refused that attempt too.
        r.vm.logicalProjects.failure = nil
        try window.press("Send")
        try await eventuallyOnMain("the owner refused the second attempt too") { r.vm.logicalProjects.failure != nil }
        #expect(r.vm.logicalProjects.operations[r.ref]?.id == kept, "the retry reuses the operation identity")
        #expect(store.draft == "this one is refused" && input.attachments.items.count == 1, "a second refusal keeps everything too")
        // Changing the words is a different message: another operation.
        store.draft = "now with other words"
        r.vm.logicalProjects.failure = nil
        try window.press("Send")
        try await eventuallyOnMain("the changed words are another operation, refused too") {
            r.vm.logicalProjects.failure != nil && r.vm.logicalProjects.operations[r.ref]?.id != kept
        }
        #expect(store.draft == "now with other words" && input.attachments.items.count == 1)
    }

    // MARK: First message, store stability

    /// The owner records the coordinator's ID on the Project before it registers the agent. The mounted thread already holds the
    /// store for that ID and polls it, so an adoption in the gap must keep the store (and its poll), and the thread must reach
    /// ready (or show an error) instead of sitting on "Starting the agent".
    private static func firstMessageRace() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the empty project") { window.layout(); return window.elements().contains { $0.label == "Message the agent" } }

        // The gap, made exact: the Project names a coordinator that is not an agent yet. The page mounts its thread over that ID.
        let named = AgentID()
        var gap = r.vm.state
        gap.projects[0].coordinatorAgentID = named
        r.vm.adopt(gap)
        let kept = r.vm.threadStores.store(for: named)
        try await eventuallyOnMain("the thread polls the named coordinator") { window.layout(); return kept.isLive }
        r.vm.adopt(gap)
        #expect(r.vm.threadStores.existing(for: named) === kept && kept.isLive, "an adoption in the gap keeps the mounted thread's store and poll")
        // Anything else that is not an agent is still pruned: ordinary stores keep their lifetime.
        let stray = AgentID()
        _ = r.vm.threadStores.store(for: stray)
        r.vm.adopt(gap)
        #expect(r.vm.threadStores.existing(for: stray) == nil)
        r.vm.adopt(r.app.server.state)

        // The real first message: the coordinator registers, and the thread must still reach ready (or say why not) instead of
        // sitting on "Starting the agent".
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let real = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("the coordinator is a known agent") { r.vm.state.agents.contains { $0.id == real } }
        try await eventuallyOnMain("the coordinator's thread is ready or failed") {
            window.layout()
            let live = r.vm.threadStores.existing(for: real)
            return live?.ready == true || live?.startProblem != nil
        }
        #expect(r.vm.threadStores.existing(for: real)?.isLive == true, "and it keeps polling")
    }

    // MARK: Cold launch of a saved conversation

    /// A relaunched app with a Project whose coordinator already has a saved pi session, paused by the person (a
    /// relaunch leaves its pi off either way): the page shows the saved history from disk at once and keeps the composer usable, nothing is started until a message is
    /// sent, and that send starts the coordinator's pi and reaches ready.
    private static func coldCoordinator() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        // The saved workspace is on disk before the server starts, as a relaunch finds it.
        let directory = try makeScratchDirectory("srv")
        let folder = directory.appendingPathComponent("logical-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let held = Space(name: "Projects", path: folder.path, hidden: true, holdsProjects: true)
        var fixture = Fixture.agent("Sample App", in: held)
        var project = Project(name: "Sample App", goal: "", coordinatorAgentID: fixture.agent.id, paused: true)
        fixture.agent.coordinatorFor = project.id
        let session = fixture.agent.effectivePiSessionID
        project.messages = [ProjectMessage(id: UUID(), text: "Reply with exactly READY", phase: .delivered, source: nil)]
        var state = Fixture.state(spaces: [held], agents: [fixture])
        state.projects = [project]
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"))
        let app = try AppHarness(directory: directory)
        defer { app.stop() }
        app.settings.projectsEnabled = true
        let sessionsDirectory = PiSessionFile.projectDirectory(forCwd: folder.path, sessionsRoot: app.server.pi.sessionsRoot)
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session","version":3,"id":"\#(session)","timestamp":"2026-09-24T00:00:00.000Z","cwd":"\#(PiSessionFile.realPath(folder.path))"}"#,
            #"{"type":"message","id":"e0","parentId":null,"timestamp":"2026-09-24T00:00:01.000Z","message":{"role":"user","content":"Reply with exactly READY","timestamp":1733234567890}}"#,
            #"{"type":"message","id":"e1","parentId":"e0","timestamp":"2026-09-24T00:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"READY"}],"provider":"anthropic","model":"claude-sonnet-4-20250514","stopReason":"stop","timestamp":1733234567891}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: sessionsDirectory.appendingPathComponent("2026-09-24T00-00-00-000Z_\(session).jsonl"))
        let vm = try await app.start(restoringAgents: true)
        #expect(vm.state.projects.first?.coordinatorAgentID == fixture.agent.id, "the saved coordinator was loaded")
        let ref = LogicalProjectRef(home: .local, id: project.id)
        vm.openLogicalProject(ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let store = vm.threadStores.store(for: fixture.agent.id)
        try await eventuallyOnMain("the saved history is on the page") {
            window.layout(); return store.rows.contains { $0.turn.messages.contains { $0.blocks.contains { $0.text == "READY" } } }
        }
        #expect(store.acceptsSend && store.loadError == nil, "the composer stays usable on a cold conversation")
        #expect(!window.controls().contains { $0.label == "Reconnect" })
        #expect(app.server.state.projects.first?.paused == true, "showing history starts nothing")
        // The coordinator stays off on purpose, so the composer must never claim it is starting: watched past the indicator's delay.
        let startingLabel = "Starting the agent"
        let watchedUntil = ContinuousClock.now + AppLayout.startingIndicatorDelay + .milliseconds(700)
        var saidStarting = false
        try await eventuallyOnMain("the starting indicator's delay passes") {
            window.layout()
            if window.elements().contains(where: { $0.label == startingLabel }) { saidStarting = true }
            return ContinuousClock.now >= watchedUntil
        }
        #expect(!saidStarting, "a cold Project's composer says nothing about starting")
        #expect(store.offline && store.loadError == nil && !store.starting, "the store knows the owner holds the pi off on purpose")
        #expect(window.elements().contains { ($0.value ?? $0.label ?? "").hasPrefix("Paused.") })

        // Leaving the page and coming back must not lose the owner's "held off on purpose".
        for _ in 0..<3 {
            vm.openLogicalProjectSettings(ref)
            try await eventuallyOnMain("the page unmounts for settings") { window.layout(); return window.element("Message the agent") == nil }
            vm.openLogicalProject(ref)
            try await eventuallyOnMain("the page is back") { window.layout(); return window.element("Message the agent") != nil }
            #expect(store.offline && store.loadError == nil && !store.starting && !store.awaitingPi,
                    "back on a cold Project the store is still held off: offline=\(store.offline) error=\(String(describing: store.loadError)) starting=\(store.starting)")
        }

        // A second Project's page replaces this one, and the first comes back: its store is still held off.
        let second = try await app.server.logicalProjects(.create(projectID: ProjectID(), name: "Other", goal: "", linkedSpaceIDs: []))
        guard case .project(let other) = second else { throw RigError("no second project") }
        try await eventuallyOnMain("the second Project arrives") { vm.state.projects.count == 2 }
        for _ in 0..<3 {
            vm.openLogicalProject(LogicalProjectRef(home: .local, id: other.id))
            try await eventuallyOnMain("the other page is shown") { window.layout(); return vm.selectedLogicalProject?.id == other.id }
            vm.openLogicalProject(ref)
            try await eventuallyOnMain("the first page is back with its composer") { window.layout(); return vm.selectedLogicalProject == ref && window.element("Message the agent") != nil }
            #expect(store.offline && store.loadError == nil && !store.starting && !store.awaitingPi,
                    "after switching Projects and back: offline=\(store.offline) error=\(String(describing: store.loadError)) starting=\(store.starting)")
        }

        // The owner's state, not a view's lifetime, decides it. A stray clear and a replaced store both fall back to it at once.
        store.offline = false
        vm.adopt(app.server.state)
        #expect(store.offline, "a stray clear is corrected from the owner's state")
        // A store the registry makes for a cold coordinator starts held off (checked on a spare key, so the page's store keeps serving).
        let spare = AgentID()
        var spareState = vm.state
        spareState.projects[0].coordinatorAgentID = spare
        vm.state = spareState
        let replacement = vm.threadStores.store(for: spare)
        #expect(replacement.offline && replacement.loadError == nil && !replacement.starting && !replacement.awaitingPi,
                "a store made for a cold Project's coordinator starts held off")
        vm.adopt(app.server.state)

        // Resume alone launches nothing; the next message starts the saved coordinator's pi and the thread goes ready.
        #expect(await vm.logicalProjects.setPaused(ref, false))
        #expect(store.offline, "a resumed Project with nothing to deliver still holds its pi off")
        #expect(!window.elements().contains { $0.label == startingLabel })
        #expect(await vm.logicalProjects.sendMessage(ref, text: "Reply with exactly READY2"))
        try await eventuallyOnMain("the coordinator's pi serves its thread") { window.layout(); return store.ready && !store.offline }
        try await eventuallyOnMain("the message is delivered") { app.server.state.projects.first?.messages.last?.phase == .delivered }
    }

    /// The reported case: a relaunched Project whose coordinator's pi is held off (here paused). Its composer is the ordinary one, and its
    /// model and reasoning controls open: no git chip, the model picker and the Thinking segments from the catalog's levels for the model.
    /// A pick changes the Project's own coordinator settings on the owner (never a task thread's), a model's new levels clamp the saved
    /// level as pi would, and the owner applies both to the relaunched coordinator before it delivers the next message.
    private static func heldOffModelAndReasoning() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let directory = try makeScratchDirectory("mdl")
        let folder = directory.appendingPathComponent("logical-project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let held = Space(name: "Projects", path: folder.path, hidden: true, holdsProjects: true)
        var fixture = Fixture.agent("Sample App", in: held)
        var project = Project(name: "Sample App", goal: "", coordinatorAgentID: fixture.agent.id, paused: true)
        project.settings.threadModel = "anthropic/claude-haiku-4-5"
        fixture.agent.coordinatorFor = project.id
        project.messages = [ProjectMessage(id: UUID(), text: "hello", phase: .delivered)]
        var state = Fixture.state(spaces: [held], agents: [fixture])
        state.projects = [project]
        try JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"))
        let app = try AppHarness(directory: directory)
        defer { app.stop() }
        app.settings.projectsEnabled = true
        let vm = try await app.start()
        let ref = LogicalProjectRef(home: .local, id: project.id)
        vm.openLogicalProject(ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let store = vm.threadStores.store(for: fixture.agent.id)
        func owner() -> LogicalProjectSettings? { app.server.state.projects.first?.settings }
        func chip() -> Control? { window.controls().first { $0.label?.hasPrefix("Model settings:") == true } }
        try await eventuallyOnMain("the held-off coordinator's composer") {
            window.layout(); return store.offline && !store.ready && chip()?.isEnabled == true
        }
        // Nothing is saved and pi is off: this existing coordinator resumes its own level, which nothing here knows, so the chip names none.
        #expect((chip()?.value ?? "").isEmpty, "no reasoning level is invented: \(String(describing: chip()?.value))")
        #expect(!window.elements().contains { ($0.label ?? "").localizedCaseInsensitiveContains("branch") || ($0.label ?? "").localizedCaseInsensitiveContains("worktree") },
                "the Project composer draws no git affordance")

        // The model, from the full picker: the owner's setting for the coordinator, not the task threads'.
        try window.press(try #require(chip()?.label))
        try await eventuallyOnMain("the settings popover with the Project's levels") {
            window.layout(); return window.element("All models\u{2026}") != nil && !window.buttons(in: "Thinking").isEmpty
        }
        // The default model is not one the catalog lists, so the standard four are offered.
        #expect(window.buttons(in: "Thinking").compactMap(\.label) == ["Off", "Low", "Medium", "High"])
        try window.press("All models\u{2026}")
        let pick = "openai/gpt-5"
        try await eventuallyOnMain("the full picker lists the pick") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix(pick + ", ") == true && $0.isEnabled }
        }
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix(pick + ", ") == true }?.label))
        try await eventuallyOnMain("the owner saved the coordinator's model") { owner()?.conversationModel == pick && !vm.logicalProjects.busy.contains(ref.id) }
        #expect(owner()?.threadModel == "anthropic/claude-haiku-4-5", "the task threads' model is untouched")
        try await eventuallyOnMain("the chip names it") { window.layout(); return chip()?.label == "Model settings: \(pick)" }

        // Reasoning: the levels the catalog lists for that model, and a pick is the Project's setting.
        try window.press("Model settings: \(pick)")
        try await eventuallyOnMain("the Thinking segments for gpt-5") { window.layout(); return !window.buttons(in: "Thinking").isEmpty }
        let offered = window.buttons(in: "Thinking").compactMap(\.label)
        #expect(!offered.contains("Minimal") && offered.contains("Extra high"), "gpt-5's own levels (no Minimal, Extra high): \(offered)")
        try window.press("Extra high", in: "Thinking")
        // One owner write at a time: each save is acknowledged before the next control is pressed.
        try await eventuallyOnMain("the owner saved the coordinator's level") { owner()?.conversationThinking == "xhigh" && !vm.logicalProjects.busy.contains(ref.id) }
        try await eventuallyOnMain("the chip names it") { window.layout(); return chip()?.value?.contains("Extra high") == true }
        #expect(store.offline && !store.ready, "setting the Project's coordinator starts nothing")

        // Back to a model whose levels lack Extra high: the saved level is clamped with it, as pi would. A level leaves the popover open,
        // as in any thread.
        try window.press("All models\u{2026}")
        let back = "anthropic/claude-opus-4-5"
        try await eventuallyOnMain("the full picker lists it") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix(back + ", ") == true && $0.isEnabled }
        }
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix(back + ", ") == true }?.label))
        try await eventuallyOnMain("the model and its clamped level are saved together") {
            owner()?.conversationModel == back && owner()?.conversationThinking == "high" && !vm.logicalProjects.busy.contains(ref.id)
        }

        // The next message relaunches the coordinator: the owner's launch carries the Project's model and level. (This harness's owner
        // lists stand-in models, not the composer's catalog, so the launch is refused here and the Project re-pauses; the owner applying
        // both to a running coordinator before delivery is `ProjectCoordinatorFlowTests`'.)
        let launching = app.server.onProjectRuntimeLaunch
        let launched = Locked<[ProjectRuntimeLaunch]>([])
        app.server.onProjectRuntimeLaunch = { request, done in launched.withValue { $0.append(request) }; launching?(request, done) }
        #expect(await vm.logicalProjects.setPaused(ref, false))
        #expect(await vm.logicalProjects.sendMessage(ref, text: "hello again"))
        try await eventuallyOnMain("the owner launches the coordinator") { !launched.current.isEmpty }
        let launch = try #require(launched.current.first)
        #expect(launch.coordinator && launch.agentID == fixture.agent.id, "the coordinator, never a task thread")
        #expect(launch.model == back && launch.thinking == "high", "launched with the Project's model and level: \(String(describing: launch.model)) \(String(describing: launch.thinking))")
    }

    // MARK: A resolved worker

    /// A real worker settles; its thread in the pane shows the steering composer. Marking it resolved removes the composer entirely
    /// (the footer card and Reopen stand in): absent, not disabled. Reopen brings it back.
    private static func resolvedHasNoComposer() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                      request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Publish file", prompt: "hello"))
        try await eventuallyOnMain("the worker's turn ends") { r.app.server.state.projects.first?.tasks.first?.phase == .settled }
        let task = try #require(r.app.server.state.projects.first?.tasks.first)
        r.vm.openLogicalProject(r.ref)
        r.vm.logicalProjectPaneTask = task.id
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        // The conversation's composer is in the left column; the worker's is in the pane on the right.
        func paneComposers() -> Int {
            let paneLeft = window.window.frame.maxX - NWLeadMetrics.paneWidth
            return window.elements().filter { $0.label == "Message the agent" && $0.frame.minX > paneLeft }.count
        }
        try await eventuallyOnMain("the settled worker's thread shows its steering composer") {
            window.layout(); return window.element("Mark resolved") != nil && paneComposers() == 1
        }
        try window.press("Mark resolved")
        try await eventuallyOnMain("resolved on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .resolved }
        try await eventuallyOnMain("the resolved footer is drawn") { window.layout(); return window.controls().contains { $0.label == "Reopen" } }
        #expect(paneComposers() == 0, "the resolved worker draws no composer: absent, not disabled")
        try window.press("Reopen")
        try await eventuallyOnMain("reopened on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .settled }
        try await eventuallyOnMain("the composer is back") { window.layout(); return paneComposers() == 1 }
    }

    // MARK: A blocking question

    /// A real worker asks (the stub's "ask": a native select dialog the worker waits on). The conversation's question card must say the
    /// worker waits for the answer (never that it "keeps going on its best guess"), and a paused Project says the answer waits for Resume.
    /// Once the person answers while paused, the owner holds it: the card is gone and the pane's dock offers no second answer.
    private static func questionCopy() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        // A native select with named options, as `project_question` leaves: the worker's turn stays open until it is answered.
        let script: [String: Any] = ["prompts": ["ask-word": [["ask": ["title": "Pick the test word", "options": ["ALPHA", "BETA"]]]]], "socket": r.app.scratch.socketPath]
        try JSONSerialization.data(withJSONObject: script).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                      request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "ask-word"))
        try await eventuallyOnMain("the worker is waiting on its question") { r.vm.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(r.vm.state.projects.first?.tasks.first)
        r.vm.openLogicalProject(r.ref)
        // The conversation draws the card from the worker's own dialog, which its store reads: a coordinator thread makes the column.
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        func footer() -> String? { window.elements().compactMap { $0.value ?? $0.label }.first { $0.hasPrefix("Or just reply in chat.") } }
        try await eventuallyOnMain("the question card is drawn with its footer") { window.layout(); return footer() != nil }
        #expect(footer() == "Or just reply in chat. Library API draft is waiting for your answer.", "\(footer() ?? "none")")
        #expect(!(footer() ?? "").contains("best guess"))

        // Paused: the footer says an answer waits until Resume.
        #expect(await r.vm.logicalProjects.setPaused(r.ref, true))
        try await eventuallyOnMain("the paused footer") { window.layout(); return footer() == "Or just reply in chat. Your answer waits until you resume." }

        // Answer while paused through the card's own option button: the owner holds it, and no second active answer remains.
        try window.press("ALPHA")
        try await eventuallyOnMain("the owner holds the answer or reports why it could not") {
            r.app.server.state.projects.first?.tasks.first?.pendingAnswer != nil || r.vm.logicalProjects.failure != nil
        }
        #expect(r.vm.logicalProjects.failure == nil, "\(r.vm.logicalProjects.failure?.message ?? "")")
        #expect(r.app.server.state.projects.first?.tasks.first?.pendingAnswer != nil)
        // The view model's copy of the Project lags the owner's; read the row only once it has the held answer too.
        try await eventuallyOnMain("the app sees the held answer") { r.vm.state.projects.first?.tasks.first?.pendingAnswer != nil }
        let held = ProjectPagePresentation(try #require(r.vm.state.projects.first)).rows[0]
        #expect(held.answerHeld && held.lead == "Answer queued" && held.id == task.id)
        try await eventuallyOnMain("the card is gone once its answer is held") { window.layout(); return footer() == nil }

        // The pane's own question dock for the same worker: it stays (the worker still waits) but offers no second answer.
        r.vm.logicalProjectPaneTask = task.id
        func paneOptions() -> [Control] {
            let paneLeft = window.window.frame.maxX - NWLeadMetrics.paneWidth
            return window.controls().filter { ($0.label?.hasPrefix("ALPHA") == true || $0.label?.hasPrefix("BETA") == true) && $0.frame.minX > paneLeft }
        }
        try await eventuallyOnMain("the pane's dock is drawn") { window.layout(); return !paneOptions().isEmpty }
        #expect(paneOptions().allSatisfy { !$0.isEnabled }, "no second answer is offered while the owner holds one: \(paneOptions().map { "\($0.label ?? "") \($0.isEnabled)" })")
    }

    // MARK: Pane dock answer (#301)

    /// Real Project choice-input: offered buttons and a final field, answered from either surface.
    /// Rejection preserves the pick/text; acceptance delivers one answer and removes both views.
    private static func paneDockAnswer(route: String, rejectedFirst: Bool) async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let options = ["Use SQLite", "Use Postgres"]
        let hints = String(decoding: try JSONEncoder().encode(options), as: UTF8.self)
        let script: [String: Any] = ["prompts": ["ask-store": [["ask": ["method": "input", "title": "Which store should the API use?\n\nOptions:\n" + hints, "placeholder": "Say anything"]]]],
                                     "socket": r.app.scratch.socketPath]
        try JSONSerialization.data(withJSONObject: script).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                      request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Library API draft", prompt: "ask-store"))
        try await eventuallyOnMain("the worker is waiting on its question") { r.vm.state.projects.first?.tasks.first?.phase == .waiting }
        let task = try #require(r.vm.state.projects.first?.tasks.first)
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        let store = r.vm.projectWorkerStore(.local, task.workerAgentID)
        try await eventuallyOnMain("the worker list has connected its store") { window.layout(); return store.ready }
        let inPane = route != "project-text", typed = route != "pane-option"
        if inPane { r.vm.openProjectTask(task.id) }
        func onTarget(_ frame: CGRect) -> Bool {
            (frame.minX > window.window.frame.maxX - NWLeadMetrics.paneWidth) == inPane
        }
        func controls(_ label: String) -> [Control] {
            window.controls().filter { $0.role == ControlRole.button && $0.label == label && onTarget($0.frame) }
        }
        func field() -> AccessibilityNode? {
            window.elements().first { $0.label == "Say anything" && ["AXTextField", "AXTextArea"].contains($0.role ?? "") && onTarget($0.frame) }
        }
        func type(_ value: String) throws {
            let node = try #require(field()), setter = NSSelectorFromString("setAccessibilityValue:")
            try #require(node.object.responds(to: setter))
            _ = node.object.perform(setter, with: value)
            if let editor = node.object as? NSTextView { NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor) }
            func native(_ view: NSView) -> NSTextField? {
                if let text = view as? NSTextField, text.stringValue == value { return text }
                return view.subviews.compactMap(native).first
            }
            let text = node.object as? NSTextField ?? (node.object as? NSCell)?.controlView as? NSTextField ?? native(window.host)
            text?.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: text))
        }
        let submit = inPane ? "Answer" : "Send"
        try await eventuallyOnMain("offered choices and a final field, not a Say anything button") {
            window.layout(); return options.allSatisfy { !controls($0).isEmpty } && field() != nil
        }
        #expect(controls("Say anything").isEmpty)
        #expect(controls(submit).first?.isEnabled == false)
        let words = "  Use an in-memory cache instead.  "
        let expected = typed ? words.trimmingCharacters(in: .whitespacesAndNewlines) : "Use Postgres"
        if typed {
            try type("   ")
            #expect(controls(submit).first?.isEnabled == false, "whitespace is not an answer")
            if inPane {
                #expect(try #require(controls("Use Postgres").first).node.press())
                try await eventuallyOnMain("picking clears the field") { field()?.value == "" }
            }
            try type(words)
        } else {
            #expect(try #require(controls("Use Postgres").first).node.press())
        }
        try await eventuallyOnMain("the answer can be submitted") { window.layout(); return controls(submit).first?.isEnabled == true }
        if !typed { #expect(controls("Use Postgres").first?.isSelected == true) }
        else if inPane {
            try await eventuallyOnMain("typing clears the pick") { controls("Use Postgres").first?.isSelected == false }
        }
        if rejectedFirst {
            let session = try #require(store.session), dialog = try #require(store.dialogs.first)
            let reply = NativeThreadRequest.answer(expectedSessionID: "stale-session", generation: session.generation,
                                                   operationID: UUID(), dialogID: dialog.id, answer: .input(value: expected))
            if inPane {
                await store.answer(dialogID: dialog.id, sessionID: "stale-session", generation: session.generation, answer: .input(value: expected))
            } else {
                #expect(await r.vm.logicalProjects.answer(r.ref, task: task.id, request: reply) == false)
            }
            let notice = try #require(inPane ? store.notice : r.vm.logicalProjects.failure?.message)
            do {
                try await eventuallyOnMain("the rejection is visible beside the answer") {
                    window.layout(); return window.elements().contains { ($0.label ?? "").contains(notice) || ($0.value ?? "").contains(notice) }
                }
            } catch {
                if let dir = ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] {
                    let nodes = window.elements().map { "\($0.role ?? ""): \($0.label ?? "") = \($0.value ?? "")" }
                    try ("Expected notice: \(notice)\n" + nodes.joined(separator: "\n")).write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("\(route)-failure-AX.txt"), atomically: true, encoding: .utf8)
                    let frames = await MotionProbe.record(window) {}
                    try frames.settled.bitmap.representation(using: .png, properties: [:])?.write(
                        to: URL(fileURLWithPath: dir).appendingPathComponent("\(route)-failure.png"))
                }
                throw error
            }
            if typed { #expect(field()?.value == words, "a refusal preserves the typed draft") }
            else { #expect(controls("Use Postgres").first?.isSelected == true) }
            #expect(controls(submit).first?.isEnabled == true, "the same answer can be retried")
            #expect(store.dialogs.first?.id == dialog.id, "a rejection does not dismiss the dialog")
        }
        if let dir = ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] {
            for dark in [false, true] {
                let frames = await MotionProbe.record(window) {
                    window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.host.appearance = window.window.appearance
                }
                let png = try #require(frames.settled.bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("ProjectQuestion-\(route)-\(rejectedFirst ? "Rejected" : "Ready")-\(dark ? "dark" : "light").png"))
            }
        }

        #expect(try #require(controls(submit).first).node.press())
        let worker = task.workerAgentID
        func snapshot() async throws -> NativeThreadSnapshot? {
            guard case .snapshot(let value) = try await r.app.server.nativeThread(agentID: worker, request: .snapshot()) else { return nil }
            return value
        }
        try await eventuallyAsync("pi takes the answer and the dialog closes") { try await snapshot()?.dialogs.isEmpty == true }
        let answered = try #require(try await snapshot())
        let records = (answered.messages + answered.provisional).compactMap(\.question)
        #expect(records.count == 1 && records.first?.answer == expected, "one native answer, exactly as selected or typed: \(records)")
        try await eventuallyOnMain("the task leaves waiting") { r.app.server.state.projects.first?.tasks.first?.phase != .waiting }
        try await eventuallyOnMain("the question leaves both surfaces") {
            window.layout()
            return !window.elements().contains { $0.label == "Say anything" && ["AXTextField", "AXTextArea"].contains($0.role ?? "") }
                && !window.controls().contains { $0.label == "Use Postgres" }
        }
        #expect(r.vm.logicalProjects.failure == nil, "\(r.vm.logicalProjects.failure?.message ?? "")")
        #expect(r.vm.projectWorkerStore(.local, worker).notice == nil, "no silent refusal: \(r.vm.projectWorkerStore(.local, worker).notice ?? "")")
    }

    // MARK: Footer geometry

    /// ProjectLead-PausedV2's footer: 8pt from the pane's sides and bottom (margin 0 / 8 / 8) around a 46pt card (padding 8, a 28pt
    /// button, a 1pt line). The resolved footer is its own wrapper (12 / 16 / 16) and keeps its 50pt card.
    private static func footerGeometry() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        _ = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                      request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Publish file", prompt: "hello"))
        try await eventuallyOnMain("the worker settles") { r.app.server.state.projects.first?.tasks.first?.phase == .settled }
        let task = try #require(r.app.server.state.projects.first?.tasks.first)
        let paused = try #require(r.app.server.state.projects.first)
        _ = try await r.vm.projectCoordinator.perform(projectID: paused.id, expectedRevision: paused.revision, request: .pause)
        try await eventuallyOnMain("paused and acknowledged") { r.app.server.state.projects.first?.paused == true && r.app.server.state.projects.first?.interruptPending == false }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the paused footer is drawn in the pane") {
            window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "") == "The project is paused." }
        }
        let paneRight = window.window.frame.maxX, paneBottom = window.window.frame.minY
        let resume = try #require(window.controls().filter { $0.label == "Resume" }.max { $0.frame.minX < $1.frame.minX }?.frame)
        // The button sits 8pt in from the card's right edge, and the card 8pt in from the pane's edge: 16 from the window's right.
        #expect(abs(paneRight - resume.maxX - (NWLeadMetrics.pausedFooterMargin + NW.Space.m)) <= 1.5, "Resume ends \(paneRight - resume.maxX) from the pane's edge")
        // The card is 46 tall around the 28pt button (8 above and below), 8 from the bottom: the button's bottom is 16 from the window's.
        #expect(abs(resume.minY - paneBottom - (NWLeadMetrics.pausedFooterMargin + NW.Space.m)) <= 1.5, "Resume sits \(resume.minY - paneBottom) above the bottom")
        #expect(NWLeadMetrics.pausedFooterHeight == 46 && NWLeadMetrics.pausedFooterHeight < NWLeadMetrics.footerHeight)

        // The resolved footer is unchanged: its own 16pt inset and 50pt card.
        _ = try await r.vm.projectCoordinator.perform(projectID: paused.id, expectedRevision: try #require(r.app.server.state.projects.first).revision, request: .resume)
        r.vm.logicalProjectPaneTask = task.id
        try await eventuallyOnMain("resumed") { r.app.server.state.projects.first?.paused == false }
        try await eventuallyOnMain("the worker detail opens") { window.layout(); return window.element("Mark resolved") != nil }
        try window.press("Mark resolved")
        try await eventuallyOnMain("the resolved footer is drawn") { window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "") == "This thread is resolved." } }
        let reopen = try #require(window.controls().first { $0.label == "Reopen" }?.frame)
        #expect(abs(paneRight - reopen.maxX - (NWLeadMetrics.footerInset + NW.Space.m)) <= 1.5, "Reopen ends \(paneRight - reopen.maxX) from the pane's edge")
        #expect(abs(reopen.minY - paneBottom - (NWLeadMetrics.footerInset + (NWLeadMetrics.footerHeight - 28) / 2)) <= 2, "Reopen sits \(reopen.minY - paneBottom) above the bottom")
    }

    // MARK: Hidden coordinator

    private static func hidden() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        let coordinator = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        try await eventuallyOnMain("coordinator in state") { r.vm.state.agents.contains { $0.id == coordinator } }
        r.vm.settings.sidebarStyle = .activity
        #expect(!r.vm.sidebarLists.all.contains { $0.id == .local(coordinator) }, "not in Activity")
        r.vm.settings.sidebarStyle = .projects
        #expect(!r.vm.sidebarTree.projects.flatMap(\.rows).contains { $0.id == .local(coordinator) }, "not in the Spaces tree")
        #expect(!r.vm.canPin(.local(coordinator)), "not pinnable")
        #expect(r.vm.selectedAgentID != coordinator, "never selected as an ordinary thread")
    }

    // MARK: Model and branch

    /// The standard composer on a Project: before the first message its chip names the Project's conversation model and picking one
    /// saves it as the Project's setting (the launch's model); the control row draws no branch.
    private static func modelAndBranch() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the empty project's model chip") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix("Model settings:") == true }
        }
        #expect(r.app.server.state.projects.first?.settings.conversationModel == nil)
        let chip = try #require(window.controls().first { $0.label?.hasPrefix("Model settings:") == true })
        #expect(chip.isEnabled, "the model is settable before a coordinator exists")
        #expect(ControlPress.undersized([chip], minimum: .desktop).isEmpty, "the chip is \(chip.frame.size)")
        try window.press(try #require(chip.label))
        // The popover lists the owner's catalog, and its first model row is the pick (its row says which model: "claude-opus-4-5").
        let choice = "anthropic/claude-opus-4-5"
        try await eventuallyOnMain("the popover lists the owner's models") { window.layout(); return window.element("Model, thinking and speed") != nil }
        try window.press("All models…")
        try await eventuallyOnMain("the full picker") { window.layout(); return window.element("Choose a model") != nil }
        let choiceLabel = try #require(window.controls().first { $0.label == choice || $0.label?.hasPrefix(choice + ", ") == true }?.label)
        try window.press(choiceLabel)
        try await eventuallyOnMain("the pick is the Project's conversation model") {
            r.app.server.state.projects.first?.settings.conversationModel == choice
        }
        try await eventuallyOnMain("the chip names it") { window.layout(); return window.element("Model settings: \(choice)") != nil
            || window.controls().contains { $0.label?.hasPrefix("Model settings:") == true && $0.label?.contains("Default") == false } }
        #expect(!window.elements().contains { $0.label?.localizedCaseInsensitiveContains("branch") == true || $0.label?.localizedCaseInsensitiveContains("worktree") == true },
                "a Project's composer draws no branch")
    }

    /// The launch itself refuses a model the owner does not list, and a Project whose conversation model is one pauses with the page
    /// still showing the ready composer: the reserved coordinator ID has no agent behind it, and the thread must not ask the server
    /// about it ("native_unavailable: The agent no longer exists." drawn as "Lost connection to the agent process.").
    private static func unavailableModel() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let launch = ProjectRuntimeLaunch(projectID: r.project.id, agentID: AgentID(), spaceID: r.space.id, cwd: r.space.path,
                                          name: r.project.name, model: "nowhere/not-a-model", coordinator: true)
        do {
            _ = try await r.vm.projectCoordinator.launch(launch)
            Issue.record("a model the owner does not list launched")
        } catch {
            #expect(String(describing: error).contains("not available"), "the refusal says why: \(error)")
        }
        #expect(r.vm.state.agents.isEmpty, "a refused launch creates no agent")

        #expect(await r.vm.logicalProjects.saveSettings(r.ref) { $0.conversationModel = "nowhere/not-a-model" })
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        _ = await r.vm.logicalProjects.sendMessage(r.ref, text: "hello")
        try await eventuallyOnMain("the failed launch pauses the Project") { r.app.server.state.projects.first?.paused == true }
        try await Task.sleep(for: .seconds(1))
        window.layout()
        #expect(r.vm.state.agents.isEmpty, "no coordinator was created")
        #expect(!window.elements().contains { $0.label?.contains("Lost connection") == true || $0.label?.contains("no longer exists") == true },
                "the page draws no lost connection for an agent that was never created")
        #expect(window.controls().contains { $0.label == "Resume" }, "the pause is shown with its Resume")
        #expect(window.element("Message the agent") != nil, "and the composer stays")
    }

    /// A pick is saved as the Project's model first and nothing else changes until the owner accepts it. The owner refuses here (the Project
    /// is gone under the open composer), so the chip keeps the model it had and the composer says why. The live `setModel` that follows an
    /// accepted save on a running coordinator is not driven here: the stub engine's coordinator thread never reports ready in this rig.
    private static func refusedModelSave() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the model chip") { window.layout(); return window.controls().contains { $0.label == "Model settings: Default model" && $0.isEnabled } }
        // The page holds the owner's last answer, then the owner deletes the Project under it: every save is refused from here on.
        #expect(await r.vm.logicalProjects.saveSettings(r.ref) { $0.maxConcurrentWorkers = 2 })
        let shown = try #require(r.app.server.state.projects.first)
        _ = try await r.app.server.logicalProjects(.delete(projectID: shown.id, expectedRevision: shown.revision))
        try await eventuallyOnMain("the owner has no project") { r.app.server.state.projects.isEmpty }
        try await eventuallyOnMain("the chip is still offered") { window.layout(); return window.controls().contains { $0.label == "Model settings: Default model" && $0.isEnabled } }
        try window.press("Model settings: Default model")
        try await eventuallyOnMain("the popover") { window.layout(); return window.element("All models…") != nil }
        try window.press("All models…")
        try await eventuallyOnMain("the full picker") { window.layout(); return window.element("Choose a model") != nil }
        let choice = "anthropic/claude-opus-4-5"
        let choiceLabel = try #require(window.controls().first { $0.label == choice || $0.label?.hasPrefix(choice + ", ") == true }?.label)
        try window.press(choiceLabel)
        try await eventuallyOnMain("the refusal is reported") { r.vm.logicalProjects.failure != nil }
        try await eventuallyOnMain("the composer says the model was not saved") {
            window.layout(); return window.elements().contains { $0.label?.contains(r.vm.logicalProjects.failure?.message ?? "\u{0}") == true }
        }
        #expect(window.element("Model settings: Default model") != nil, "the chip still names the model it had")
        #expect(window.element("Model settings: anthropic/claude-opus-4-5") == nil, "and never the one that was refused")
        // The refusal as drawn: the composer's own failed banner, in both appearances and at both text scales, from this real refusal.
        if let directory = ProcessInfo.processInfo.environment["SHEPHERD_PREVIEW_DIR"] {
            let original = ThemeStore.shared.textScale
            defer { ThemeStore.shared.textScale = original }
            for (dark, scale) in [(true, CGFloat(1)), (false, 1), (true, 1.3), (false, 1.3)] {
                window.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.host.appearance = window.window.appearance
                ThemeStore.shared.textScale = scale
                window.layout()
                try await Task.sleep(for: .milliseconds(300)); window.layout()
                let bitmap = try #require(window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds))
                window.host.cacheDisplay(in: window.host.bounds, to: bitmap)
                let name = "project-model-save-refused\(scale == 1 ? "" : "-x1.3")-\(dark ? "dark" : "light").png"
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    /// A served coordinator thread (a scripted host that records every request and applies a model or level as the real one does,
    /// `ComposerThread`'s way) under the Project's own composer wiring. A pick is saved as the Project's conversation model FIRST and
    /// only then reaches the thread as a native `setModel`; a refused save sends none. A level is saved as the Project's reasoning level
    /// first, then reaches the thread as `setThinking`.
    private static func liveModelPick() async throws {
        AccessibilityNode.enable()
        try StubPi.installAsEngine()
        let models = ModelCatalogFixture.entries
        var snapshot = ComposerThread.snapshot(messages: 2, commands: [], model: "anthropic/claude-opus-4-5")
        snapshot.thinkingLevels = ["off", "low", "medium", "high"]
        let store = NativeThreadStore()
        let input = ThreadInput()
        let requests = Locked<[NativeThreadRequest]>([])
        let saved = Locked<[String]>([])
        let savedLevels = Locked<[String]>([])
        let accept = Locked(true)
        let host = Locked(snapshot)
        let request: NativeThreadStore.Request = { value in
            requests.withValue { $0.append(value) }
            switch value {
            case .send(_, _, let operation, _, _, _, _, _, _): return .accepted(operationID: operation)
            case .setModel(_, _, let operation, let model):
                #expect(accept.current && saved.current == [model, model], "the accepted Project save precedes the native setModel")
                host.withValue { $0.model = model; $0.revision += 1 }
                return .accepted(operationID: operation)
            case .setThinking(_, _, let operation, let level):
                #expect(savedLevels.current.last == level, "the accepted Project save precedes the native setThinking")
                host.withValue { $0.thinking = level; $0.revision += 1 }
                return .accepted(operationID: operation)
            default: return .snapshot(value: host.current)
            }
        }
        let send = ProjectComposerSend(
            placeholder: "Ask Sample App a question or start a task\u{2026}", send: { _, _ in true },
            model: ProjectConversationModel(current: nil, choose: { id, _ in
                saved.withValue { $0.append(id) }
                return accept.current
            }, chooseThinking: { level in
                savedLevels.withValue { $0.append(level) }
                return accept.current
            }))
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), dark: true)
        defer { window.close() }
        window.show(AnyView(ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: nil, agentName: "Sample App",
                                       listModels: { ModelCatalog(models) }, retainedInput: input)
            .environment(\.projectComposerSend, send)))
        try await eventuallyOnMain("the thread to load") { store.ready }
        let chip = "Model settings: anthropic/claude-opus-4-5"
        try await eventuallyOnMain("the idle thread's model chip") { window.layout(); return window.controls().contains { $0.label == chip && $0.isEnabled } }
        #expect(!window.elements().contains { $0.label?.localizedCaseInsensitiveContains("branch") == true }, "no branch beside the chip")
        func settings() async throws { try window.press(chip); try await eventuallyOnMain("the popover") { window.layout(); return window.element("All models\u{2026}") != nil } }

        let pick = "anthropic/claude-3-5-haiku-20241022"
        let row = "\(pick), \(try #require(ModelCatalog(models).model(pick)).thinking)"
        func pickFromFullPicker() async throws {
            try window.press("All models\u{2026}")
            try await eventuallyOnMain("one enabled model row in the full picker") {
                let groups = window.elements().filter { $0.role == ControlRole.group && $0.label == "Choose a model" }
                let choices = ControlPress.controls(in: "Choose a model", under: window.host).filter { $0.role == ControlRole.button && $0.label == row }
                return groups.count == 1 && choices.count == 1 && choices[0].isEnabled && !choices[0].frame.isEmpty
            }
            try window.press(row, in: "Choose a model")
        }

        // A refused save: the thread is never told, the chip keeps its model.
        accept.withValue { $0 = false }
        try await settings()
        try await pickFromFullPicker()
        try await eventuallyOnMain("the save was attempted") { saved.current == [pick] }
        try await eventuallyOnMain("the refused pick closes the full picker") { window.element("Choose a model") == nil }
        #expect(!requests.current.contains { if case .setModel = $0 { true } else { false } }, "a refused save sends the thread no setModel")
        #expect(store.model == "anthropic/claude-opus-4-5")

        // An accepted save: the Project's setting first, then the thread's own native setModel, and the chip follows.
        accept.withValue { $0 = true }
        try await eventuallyOnMain("the chip is offered again") { window.layout(); return window.controls().contains { $0.label == chip && $0.isEnabled } }
        try await settings()
        try await pickFromFullPicker()
        try await eventuallyOnMain("the thread was sent setModel for the pick") {
            requests.current.contains { if case .setModel(_, _, _, let model) = $0 { model == pick } else { false } }
        }
        #expect(saved.current == [pick, pick], "saved before each attempt: \(saved.current)")
        try await eventuallyOnMain("the thread reports the new model") { store.model == pick }
        try await eventuallyOnMain("the chip names it") { window.layout(); return window.element("Model settings: \(pick)") != nil }

        // Thinking is the thread's own setting: a level goes to it as setThinking, with the popover open.
        try window.press("Model settings: \(pick)")
        try await eventuallyOnMain("the popover with levels") { window.layout(); return !window.buttons(in: "Thinking").isEmpty }
        try window.press("High", in: "Thinking")
        try await eventuallyOnMain("the thread was sent setThinking high") {
            requests.current.contains { if case .setThinking(_, _, _, let level) = $0 { level == "high" } else { false } }
        }
        try await eventuallyOnMain("the thread reports high") { store.thinking == "high" }
        #expect(savedLevels.current == ["high"], "the level is the Project's coordinator setting first: \(savedLevels.current)")
    }

    /// The coordinator's ID is reserved before its agent exists. With the app's real launch held there, the page's own request closure
    /// (the one a person's screen uses) must answer "starting", never "The agent no longer exists" drawn as a lost connection; once the
    /// launch is released the agent is created and the very same page's thread becomes ready.
    private static func heldCreation() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let launch = try #require(r.app.server.onProjectRuntimeLaunch)
        let held = Locked<(ProjectRuntimeLaunch, @Sendable (Result<AgentID, Error>) -> Void)?>(nil)
        r.app.server.onProjectRuntimeLaunch = { request, done in held.withValue { $0 = (request, done) } }
        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "hello"))
        try await eventuallyOnMain("the launch is held with the coordinator reserved and no agent") { held.current != nil }
        let reserved = try #require(r.app.server.state.projects.first?.coordinatorAgentID)
        #expect(r.vm.state.agents.isEmpty, "the agent does not exist yet")
        try await eventuallyOnMain("the page mounts the reserved coordinator's thread") {
            window.layout(); return r.vm.logicalProjects.project(r.ref)?.coordinatorAgentID == reserved
        }
        // Give the page's own loop time to pull while the creation is held.
        try await Task.sleep(for: .seconds(2)); window.layout()
        let store = r.vm.threadStores.store(for: reserved)
        #expect(store.loadError == nil, "no error while the creation is held: \(store.loadError ?? "-")")
        #expect(!window.elements().contains { $0.label?.contains("Lost connection") == true || $0.label?.contains("no longer exists") == true },
                "the page draws no lost connection while the agent is being created")
        #expect(window.element("Message the agent") != nil, "and the composer stays")

        // Release the real launch: the agent is created and the page's thread becomes ready on it.
        let (request, done) = try #require(held.current)
        r.app.server.onProjectRuntimeLaunch = launch
        Task { do { done(.success(try await r.vm.projectCoordinator.launch(request))) } catch { done(.failure(error)) } }
        try await eventuallyOnMain("the coordinator is created") { r.vm.state.agents.contains { $0.id == reserved } }
        // This rig's window re-mounts the page's thread as the agent appears, so the store is run on the same owner path, as the other scenarios do.
        let server = r.vm.server, projectID = r.project.id
        Task { await store.run(request: { try await server.projectConversation(projectID, request: $0) }) }
        try await eventuallyOnMain("the page's thread is ready on it", timeout: .seconds(40)) {
            window.layout(); return store.ready && store.loadError == nil
        }
    }
}
