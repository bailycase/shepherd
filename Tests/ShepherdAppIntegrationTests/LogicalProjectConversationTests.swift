import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
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

    @Test func theCoordinatorAppearsInNoOrdinaryThreadList() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.hidden() } }
        expectScenarioCompleted(result)
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
        let folder = app.dir.appendingPathComponent("gamecards-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("gamecards-api", path: folder.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        guard case .project(let project) = try await app.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Gamecards", goal: "Launch a gift card reseller API", linkedSpaceIDs: [space.id])) else {
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
        try await eventuallyOnMain("the empty project") { window.layout(); return window.element("Ask Gamecards a question or start a task…") != nil
            || window.elements().contains { $0.label == "Message the agent" } }
        #expect(r.vm.state.agents.isEmpty, "opening a project starts no conversation")
        #expect(window.element("Spaces, gamecards-api · add more in settings") != nil)
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
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Gift card market scan", prompt: "slow"))
        // The owner records the first worker running asynchronously: the second assign waits for that published record, so it
        // carries the revision the owner really holds (a refused action is never retried to hide the race).
        try await eventuallyOnMain("the first task is running on the owner") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let current = try #require(r.app.server.state.projects.first)
        _ = try await coordinator.perform(projectID: r.project.id, expectedRevision: current.revision,
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Partner API draft", prompt: "ask"))
        try await eventuallyOnMain("two tasks exist") { r.vm.state.projects.first?.tasks.count == 2 }
        try await eventuallyOnMain("one waits on you") { r.vm.state.projects.first?.tasks.contains { $0.phase == .waiting } == true }
        let waiting = try #require(r.vm.state.projects.first?.tasks.first { $0.phase == .waiting })
        let presentation = ProjectPagePresentation(try #require(r.vm.state.projects.first))
        #expect(presentation.waiting >= 1 && presentation.rows(in: .waiting).first?.title == "Partner API draft")
        #expect(presentation.status.contains("waiting on you"))

        r.vm.openLogicalProject(r.ref)
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: r.vm))
        defer { window.close() }
        try await eventuallyOnMain("the pane lists the task") { window.layout(); return window.element("Partner API draft, Blocked") != nil
            || window.elements().contains { $0.label?.hasPrefix("Partner API draft") == true } }
        let group = try #require(window.controls().first { $0.label?.hasPrefix("Waiting on you, 1") == true })
        #expect(ControlPress.undersized([group], minimum: .desktop).isEmpty)

        // Opening a task shows the worker's own native thread in the pane; Open as a thread selects the ordinary thread.
        // The pane's row reads "<title>, Blocked, <the worker's own question>": its words come from the native thread's dialog.
        let rowControl = try #require(window.controls().first { $0.label?.hasPrefix("Partner API draft, Blocked") == true })
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

    private static func paneHeader() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let coordinator = r.vm.projectCoordinator
        // Each assign carries the revision the owner last published: the second waits for the first worker's own running record
        // (the owner persists it asynchronously), so the fixture is stable without a sleep or a retry of a refused action.
        var revision = r.project.revision
        for (index, title) in ["Gift card market scan", "Partner API draft"].enumerated() {
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
            return window.controls().contains { $0.label == "Gift card market scan" } }
        // Search narrows the list to what matches, over the real task titles.
        try window.press("Search threads")
        try await eventuallyOnMain("the field opens") { r.vm.logicalProjectPaneSearching }
        r.vm.logicalProjectPaneQuery = "partner"
        // The pane's own rows are named by the task title alone (the sidebar's say their state too), so match them exactly.
        try await eventuallyOnMain("only the match shows") { window.layout()
            return window.controls().contains { $0.label == "Partner API draft" }
                && !window.controls().contains { $0.label == "Gift card market scan" } }
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
        try Data("# Market scan\nTango, Tremendous".utf8).write(to: root.appendingPathComponent("gift-card-platforms.md"))
        try Data("inside".utf8).write(to: root.appendingPathComponent("reports/nested.txt"))
        try Data([0, 1, 2, 3]).write(to: root.appendingPathComponent("blob.bin"))
        try window.press("Files")
        try await eventuallyOnMain("the files tab") { r.vm.logicalProjectPaneTab == .files }
        try await eventuallyOnMain("the owner's entries are listed") {
            window.layout()
            return window.controls().contains { $0.label?.hasPrefix("gift-card-platforms.md") == true } && window.controls().contains { $0.label == "reports" }
        }
        for name in ["gift-card-platforms.md", "reports"] {
            let row = try #require(window.controls().first { $0.label?.hasPrefix(name) == true })
            #expect(ControlPress.undersized([row], minimum: .desktop).isEmpty, "\(name) is \(row.frame.size)")
        }
        // A text file previews as data, never opened; a binary one says it cannot be previewed.
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("gift-card-platforms.md") == true }?.label))
        try await eventuallyOnMain("the text is previewed") { window.layout(); return window.elements().contains { $0.value?.contains("Tango, Tremendous") == true || $0.label?.contains("Tango, Tremendous") == true } }
        try window.press("Close preview")
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("blob.bin") == true }?.label))
        try await eventuallyOnMain("a binary file is refused in words") {
            window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "").contains("can't be previewed") }
        }
        try window.press("Close preview")
        // A folder opens the next directory, and Back returns.
        try window.press("reports")
        try await eventuallyOnMain("the folder lists its own file") { window.layout(); return window.controls().contains { $0.label?.hasPrefix("nested.txt") == true } }
        #expect(!window.controls().contains { $0.label?.hasPrefix("gift-card-platforms.md") == true }, "one directory at a time")
        try window.press(try #require(window.controls().first { $0.label?.hasPrefix("Back") == true }?.label))
        try await eventuallyOnMain("back at the root") { window.layout(); return window.controls().contains { $0.label?.hasPrefix("gift-card-platforms.md") == true } }
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
        let web = r.app.dir.appendingPathComponent("gamecards-web")
        let docs = r.app.dir.appendingPathComponent("gamecards-docs")
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
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Gift card market scan", prompt: "slow"))
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
            window.layout(); return window.controls().contains { $0.label == "Gift card market scan, working" || $0.label?.hasPrefix("Gift card market scan, working,") == true }
        }
        let card = try #require(window.controls().first { $0.label == "Gift card market scan, working" || $0.label?.hasPrefix("Gift card market scan, working,") == true })
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
        let worker: [String: Any] = ["prompts": ["publish-one": [["publish": ["source": "src.md", "name": "overview.md", "content": "# Overview\nPartners charge users."]],
                                                                  ["wait": "hold-workers", "timeout": 120]],
                                                  "plain": [["wait": "hold-workers", "timeout": 120]]], "socket": socket]
        try JSONSerialization.data(withJSONObject: worker).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let coordinator = r.vm.projectCoordinator
        let first = try await coordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                  request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Partner API draft", prompt: "publish-one"))
        try await eventuallyOnMain("the first task is running") { r.app.server.state.projects.first?.tasks.first?.phase == .running }
        let afterFirst = try #require(r.app.server.state.projects.first)
        _ = try await coordinator.perform(projectID: r.project.id, expectedRevision: afterFirst.revision,
                                          request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Partner API draft", prompt: "plain"))
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
        #expect(await r.vm.logicalProjects.sendMessage(r.ref, text: "name them"))
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
        func chipControls() -> [Control] { window.controls().filter { $0.role == ControlRole.button && ($0.label ?? "").hasPrefix("Open Partner API draft") } }
        try await eventuallyOnMain("both resolving references are controls") { window.layout(); return chipControls().count == 2 }
        let chips = chipControls()
        #expect(chips.map(\.description) == Array(repeating: "AXButton \"Open Partner API draft, working\" \(Int(chips[0].frame.width.rounded()))×24", count: 2), "the actionable tree: two 24pt buttons")
        #expect(!window.controls().contains { ($0.label ?? "").contains("gone") || ($0.label ?? "").contains("foreign") }, "stale and foreign references are inert")
        #expect(ControlPress.undersized(chips, minimum: .desktop).isEmpty, "the chips are \(chips.map(\.frame.size))")
        // Pressed through the rendered control (as VoiceOver does), the ID in the link decides which task opens.
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Partner API draft, working", nth: 0)
        try await eventuallyOnMain("the first chip opened its own task") { r.vm.logicalProjectPaneTask == publisher.id }
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Partner API draft, working", nth: 1)
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
            window.layout(); return window.elements().contains { ($0.value ?? $0.label ?? "").contains("Partners charge users.") }
        }
        // Switching Threads and back to Files is an ordinary tab switch: the preview of the earlier chip is not carried over.
        try window.press("Threads")
        try await eventuallyOnMain("on Threads") { r.vm.logicalProjectPaneTab == .threads }
        #expect(r.vm.logicalProjectPaneFile == nil, "the request was consumed")
        try window.press("Files")
        try await eventuallyOnMain("the Files tab lists the owner's file, with no preview") {
            window.layout(); return window.controls().contains { $0.label?.hasPrefix("overview.md") == true }
        }
        #expect(!window.elements().contains { ($0.value ?? $0.label ?? "").contains("Partners charge users.") }, "no stale preview after a tab switch")
        // A request that names another Project is never taken by this one's Files tab.
        r.vm.logicalProjectPaneFile = (LogicalProjectRef(home: .local, id: ProjectID()), try #require(row.files.first))
        try await eventuallyOnMain("a foreign request waits unread") { window.layout(); return r.vm.logicalProjectPaneFile != nil }
        #expect(!window.elements().contains { ($0.value ?? $0.label ?? "").contains("Partners charge users.") }, "a foreign request previews nothing")
        r.vm.openLogicalProject(r.ref)
        #expect(r.vm.logicalProjectPaneFile == nil, "opening a Project drops a request that is not its own")
    }

    /// One task named twice in one paragraph is two chips, each a labelled 24pt button that opens that task; a title longer than the line wraps over
    /// two lines and is still a single control. (Each mention restarts its own fragment count, so a later mention keeps its dot and control.)
    private static func repeatedAndWrappedChips() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let long = "Compare how every gift card marketplace handles partner payouts, refunds and chargebacks across regions"
        let socket = r.app.scratch.socketPath
        let hold: [String: Any] = ["prompts": ["slow": [["wait": "hold-workers", "timeout": 120]], "long": [["wait": "hold-workers", "timeout": 120]]], "socket": socket]
        try JSONSerialization.data(withJSONObject: hold).write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let coordinator = r.vm.projectCoordinator
        let first = try await coordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
                                                  request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Partner API draft", prompt: "slow"))
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
        try await eventuallyOnMain("every mention is a control") { window.layout(); return chips("Open Partner API draft").count == 2 && chips("Open Compare how").count >= 1 }
        #expect(chips("Open Partner API draft").count == 2, "the same task mentioned twice is two controls")
        #expect(chips("Open Compare how").count == 1, "a long chip that wraps over two lines is one control, not one per line")
        #expect(ControlPress.undersized(chips("Open "), minimum: .desktop).isEmpty, "every chip is a 24pt target: \(chips("Open ").map(\.description))")
        // Both mentions of the same task open it; the long one opens its own task.
        r.vm.logicalProjectPaneTask = nil
        try window.press("Open Partner API draft, working", nth: 1)
        try await eventuallyOnMain("the second mention of the same task opens it") { r.vm.logicalProjectPaneTask == shortID }
        r.vm.logicalProjectPaneTask = nil
        try window.press(try #require(chips("Open Compare how").first?.label))
        try await eventuallyOnMain("the long chip opens its own task") { r.vm.logicalProjectPaneTask == longID }
    }

    /// ControlPress: pause, send while paused, resume. The message the owner accepted is represented in the conversation the whole
    /// time (held, then in the transcript once its native operation is consumed), and is never drawn twice.
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
        func noteCount(_ note: String) -> Int {
            window.layout()
            return window.elements().filter { ($0.label ?? $0.value ?? "") == note }.count
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
        // It is still represented: the person's own words are in the conversation, with the state said once, in the thread's own style.
        try await eventuallyOnMain("the held message is drawn with its state") { noteCount("Sends when the project resumes") == 1 }
        #expect(heldNow().map(\.text) == ["send me later"], "its own words are what is held")
        #expect(noteCount("Sends when the project resumes") == 1, "it is drawn once")
        // Resume: the owner delivers it once; the held row gives way to the transcript's own bubble. Never two.
        try window.press("Resume", nth: 0)
        try await eventuallyOnMain("resumed and delivered") {
            r.app.server.state.projects.first?.messages.first { $0.text == "send me later" }?.phase == .delivered
        }
        // The thread's own bubble takes over once its native operation is consumed: nothing held, no note, never two.
        try await eventuallyOnMain("the held row gave way to the transcript") {
            window.layout()
            return heldNow().isEmpty && noteCount("Sends when the project resumes") == 0
                && store.rows.flatMap(\.turn.messages).contains { $0.role == "user" && $0.blocks.contains { $0.text == "send me later" } }
        }
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
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Gift card market scan", prompt: "slow"))
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
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Checkout widget mockup", prompt: "project-plan"))
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
        #expect(window.elements().filter { ($0.label ?? "").contains("Building the storefront") }.count == 1)
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
        try JSONSerialization.data(withJSONObject: ["prompts": ["Build the checkout widget": [["wait": "hold-workers", "timeout": 120]]], "socket": socket])
            .write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Checkout widget mockup", prompt: "Build the checkout widget"))
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
        if case .assignment(let words) = segments.first { #expect(words == "Build the checkout widget") } else { Issue.record("the assignment is not first and plain") }
        if case .person(let kept) = segments.last { #expect(kept.bubbles.map(\.text) == ["use the blue theme"]) } else { Issue.record("the person's words lost their bubble") }
        // Drawn: the assignment is one left-aligned text node the column's width, and the person's words are a bubble (a combined, unlabeled
        // element, narrower than the column) that ends on the column's trailing edge.
        try await eventuallyOnMain("both are drawn") {
            window.layout()
            let nodes = window.elements()
            guard let prose = nodes.first(where: { $0.role == "AXStaticText" && $0.value == "Build the checkout widget" }) else { return false }
            return nodes.contains { $0.role == "AXUnknown" && ($0.label ?? "").isEmpty && abs($0.frame.maxX - prose.frame.maxX) < 1 && $0.frame.width < prose.frame.width / 2 }
        }
        let nodes = window.elements()
        let prose = try #require(nodes.first { $0.role == "AXStaticText" && $0.value == "Build the checkout widget" })
        #expect(prose.frame.width > 400, "the assignment is the pane column's own text, not a bubble: \(prose.frame)")
        #expect(store.rows.filter(\.isUser).count == 1, "one user row, as before")
    }

    /// ProjectLead-ThreadRunning's left composer. The coordinator's turn is held by the engine's own `project-action` script (it waits for
    /// `continue-1`, which this test never creates), so the thread is running while the composer is drawn. The board draws the disabled arrow,
    /// not Stop (a Stop would pause the Project). With words typed, Send is enabled and the outlined Stop stands beside it.
    private static func projectComposerWhileRunning() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Gift card market scan", prompt: "slow"))
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
        try await eventuallyOnMain("a draft enables Send and brings the outlined Stop beside it") {
            window.layout()
            return window.controls().contains { $0.label == "Stop" } && window.controls().contains { $0.label == "Send" && $0.isEnabled }
        }
        #expect(r.app.server.state.projects.first?.paused == false, "nothing paused the Project")
    }

    /// The worker's empty composer while its turn runs is the board's red Stop; pressing it aborts that worker's own turn only.
    private static func workerStop() async throws {
        let r = try await rig()
        defer { r.app.stop() }
        try JSONSerialization.data(withJSONObject: ["prompts": ["Build the checkout widget": [["wait": "hold-workers", "timeout": 120]]], "socket": r.app.scratch.socketPath])
            .write(to: URL(fileURLWithPath: r.space.path).appendingPathComponent("project-script.json"))
        let assigned = try await r.vm.projectCoordinator.perform(projectID: r.project.id, expectedRevision: r.project.revision,
            request: .assign(operationID: UUID(), spaceID: r.space.id, title: "Checkout widget mockup", prompt: "Build the checkout widget"))
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
}
