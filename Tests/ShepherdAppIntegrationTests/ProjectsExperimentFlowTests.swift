import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings ▸ Experiments ▸ Projects, pressed through accessibility on a real scratch server. Off (the default) there is no Projects
/// group, no New project and no Project page in either sidebar; Spaces and ordinary threads are unchanged. On shows the existing
/// Projects. Off again closes only Project navigation and keeps the records, the files and the unsent draft; on again reopens nothing
/// and resumes nothing.
@Suite("Projects experiment", .mainActorExclusive)
@MainActor
struct ProjectsExperimentFlowTests {
    @Test func theSettingsSwitchShowsAndHidesProjectsInBothSidebarsWithoutLosingAnything() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressTheSwitch() }
        }
        expectScenarioCompleted(result)
    }

    @Test func everyProgrammaticWayIntoAProjectIsRefusedWhileOff() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.refusedWhileOff() }
        }
        expectScenarioCompleted(result)
    }

    /// Off while a Project page and the New project sheet are open: the callback clears the page and the draft, the sheet dismisses, and
    /// turning Projects on again opens nothing (the sheet's draft binding must not write its last value back while it dismisses).
    @Test func offWithAPageAndTheSheetOpenDoesNotReopenTheSheetWhenTurnedOnAgain() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.sheetAndPageThenOff() }
        }
        expectScenarioCompleted(result)
    }

    @Test func offWithAPageAndTheAssignSheetOpenLeavesNoDraftWhenTurnedOnAgain() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.assignSheetThenOff() }
        }
        expectScenarioCompleted(result)
    }

    // MARK: Scenarios

    private static func switchNode(_ window: OffscreenWindow) -> AccessibilityNode? {
        window.elements().first { $0.label == "Projects" && ($0.role == "AXCheckBox" || $0.role == "AXSwitch") }
    }

    /// The view model binds the real `onProjectsChange` at creation (server gate, then `projectsExperimentChanged`), and this rig
    /// never replaces it. The saved record is seeded the way an earlier session left it: the host is enabled directly (the setting
    /// stays off), the Project is created, and the host is turned off again, which pauses it for real.
    private static func rig(_ app: AppHarness) async throws -> (vm: ShepherdViewModel, space: Space, ref: LogicalProjectRef, agent: AgentFixture) {
        #expect(!AppSettings(store: ScratchDefaults()).projectsEnabled, "a fresh AppSettings starts with Projects off")
        let folder = app.dir.appendingPathComponent("gamecards-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("gamecards-api", path: folder.path)
        let agent = Fixture.agent("ordinary thread", in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        #expect(!app.settings.projectsEnabled && !vm.projectsEnabled)
        app.server.setProjectsEnabled(true)
        guard case .project(let project) = try await app.server.logicalProjects(
            .create(projectID: ProjectID(), name: "Gamecards", goal: "Launch a gift card reseller API", linkedSpaceIDs: [space.id])) else {
            throw RigError("no project")
        }
        app.server.setProjectsEnabled(false)
        try await eventuallyAsync("the host to refuse and the saved Project to be paused") {
            guard await refuses(app) else { return false }
            let saved = app.server.state.projects.first
            return saved?.paused == true && saved?.interruptPending == false
        }
        try await eventuallyOnMain("the view model to adopt the paused record") { vm.state.projects == app.server.state.projects }
        return (vm, space, LogicalProjectRef(home: .local, id: project.id), agent)
    }

    /// True when the host says "Enable Projects in Settings > Experiments." to a Project request.
    private static func refuses(_ app: AppHarness) async -> Bool {
        do { _ = try await app.server.logicalProjects(.list); return false }
        catch let error as LogicalProjectsError { return error.code == "unsupported" && error.description.contains("Settings > Experiments") }
        catch { return false }
    }

    /// What a Project keeps whatever the switch does: everything but the revision and the pause flags a real pause changes.
    private static func retained(_ project: Project) -> Project {
        var kept = project
        kept.revision = 0; kept.paused = false; kept.interruptPending = false
        return kept
    }

    private struct RigError: Error { let message: String; init(_ message: String) { self.message = message } }

    private static func pressTheSwitch() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        #expect(!app.settings.projectsEnabled, "Projects starts off")
        let (vm, space, ref, agent) = try await rig(app)
        let experiments = OffscreenWindow(size: CGSize(width: 1100, height: 900), dark: true,
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: app.settings, openInstructions: {}))
        defer { experiments.close() }
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }

        // Off: Activity has no Projects header, chip or row; Spaces has no Projects block and keeps its folders and threads.
        vm.settings.sidebarStyle = .activity
        func activityHasProjects() -> Bool {
            vm.sidebarActivityItems.contains { if case .header(.projects, _, _) = $0 { true } else if case .project = $0 { true } else { false } }
        }
        func treeHasProjects() -> Bool {
            vm.presentedSidebarTree.contains { if case .leadHeader = $0 { true } else if case .leadProject = $0 { true } else { false } }
        }
        #expect(!activityHasProjects() && vm.sidebarLogicalProjects.isEmpty)
        try await eventuallyOnMain("the Activity sidebar to draw without Projects") {
            window.layout()
            return window.element("New project") == nil && window.element("Gamecards, project") == nil
        }
        vm.settings.sidebarStyle = .projects
        #expect(!treeHasProjects())
        #expect(vm.sidebarTree.projects.map(\.name) == ["gamecards-api"], "Spaces are not Projects and stay")
        try await eventuallyOnMain("the Spaces sidebar to draw without Projects") {
            window.layout()
            return window.element("New project") == nil && window.element("Gamecards, project") == nil
        }
        vm.settings.sidebarStyle = .activity

        // The card's switch is a 24pt control, and pressing it turns the setting on.
        try await eventuallyOnMain("the Projects switch to attach") { switchNode(experiments) != nil }
        let toggle = try #require(switchNode(experiments))
        let control = try #require(experiments.controls().first { $0.label == "Projects" && $0.role == toggle.role })
        #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "the Projects switch is \(control)")
        #expect(await refuses(app), "the host refuses Project requests while off")
        try experiments.press("Projects", role: #require(toggle.role))
        try await eventuallyOnMain("Projects to turn on") { app.settings.projectsEnabled }
        #expect(AppSettings(store: app.defaults).projectsEnabled, "the choice is stored")
        // The real callback reached the host: it serves Projects again, and the saved Project is still paused (opting in never resumes).
        try await eventuallyAsync("the host to serve Projects after the press") { !(await refuses(app)) }
        #expect(app.server.state.projects.first?.paused == true)

        // On: the existing Project shows in both sidebars, and the chip and row work.
        try await eventuallyOnMain("the Projects group and its chip") {
            window.layout()
            return window.element("New project") != nil && window.element("Gamecards, project") != nil
        }
        try window.press("New project")
        try await eventuallyOnMain("the New project sheet opens") { vm.newLogicalProject != nil }
        vm.newLogicalProject = nil
        try await eventuallyOnMain("the sheet closes") { window.window.attachedSheet == nil }
        try window.press("Gamecards, project")
        try await eventuallyOnMain("the Project page opens") { vm.selectedLogicalProject == ref && vm.shownDestination == .project }
        vm.settings.sidebarStyle = .projects
        #expect(treeHasProjects())
        // An unsent message and the pane's filter belong to the person, not to the switch.
        vm.emptyProjectConversation.draft = "ask about the launch date"
        vm.logicalProjectPaneQuery = "payments"
        let seeded = try #require(app.server.state.projects.first)
        #expect(seeded.paused, "the saved Project was paused when the host went off")
        let kept = retained(seeded)
        vm.showNewProject()
        #expect(vm.newLogicalProject != nil)
        vm.newLogicalProject = nil
        try await eventuallyOnMain("the sheet closes again") { window.layout(); return window.window.attachedSheet == nil }

        // Off again while a Project page is open.
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn off") { !app.settings.projectsEnabled }
        #expect(!AppSettings(store: app.defaults).projectsEnabled)
        // The real callback closed the host: creation and runtime are refused, and the Project is paused.
        try await eventuallyAsync("the host to refuse after the press") { await refuses(app) }
        do {
            _ = try await app.server.logicalProjects(.create(projectID: ProjectID(), name: "Late", goal: "", linkedSpaceIDs: []))
            Issue.record("the host created a Project while off")
        } catch let error as LogicalProjectsError { #expect(error.code == "unsupported") }
        do {
            _ = try await app.server.projectRuntime(ref.id, expectedRevision: seeded.revision, request: .resume)
            Issue.record("the host resumed a Project while off")
        } catch let error as LogicalProjectsError { #expect(error.code == "unsupported") }
        try await eventuallyAsync("the Project to be paused") { app.server.state.projects.first?.paused == true }
        #expect(vm.selectedLogicalProject == nil && vm.destination == nil, "selected \(String(describing: vm.selectedLogicalProject)) destination \(String(describing: vm.destination))")
        #expect(vm.shownDestination != .project && vm.shownDestination != .projectSettings)
        try await eventuallyOnMain("the sheet to go") { window.layout(); return window.window.attachedSheet == nil }
        #expect(!treeHasProjects())
        vm.settings.sidebarStyle = .activity
        #expect(!activityHasProjects())
        try await eventuallyOnMain("the chip and row to go") {
            window.layout()
            return window.element("New project") == nil && window.element("Gamecards, project") == nil
        }
        // Only Project navigation closed. The record, its Space, the draft, the filter and ordinary threads remain.
        try await eventuallyOnMain("the view model to hold the host's record") { vm.state.projects == app.server.state.projects }
        #expect(vm.state.projects.map(retained) == [kept], "nothing was deleted or changed but the pause")
        #expect(app.server.state.projects.count == 1, "the refused create left no second Project")
        #expect(vm.emptyProjectConversation.draft == "ask about the launch date")
        #expect(vm.logicalProjectPaneQuery == "payments")
        #expect(vm.state.spaces.map(\.id) == [space.id] && vm.state.agents.map(\.id) == [agent.agent.id])
        vm.selectAgent(agent.agent.id)
        #expect(vm.selectedAgentID == agent.agent.id && vm.shownDestination == nil, "ordinary threads stay reachable")
        #expect(FileManager.default.fileExists(atPath: space.path))

        // On again: the Project is listed, nothing reopens itself, and no work started.
        let offRevision = try #require(app.server.state.projects.first).revision
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn back on") { app.settings.projectsEnabled }
        try await eventuallyAsync("the host to serve Projects again") { !(await refuses(app)) }
        try await eventuallyOnMain("the Project to be listed again") {
            window.layout()
            return window.element("Gamecards, project") != nil
        }
        #expect(vm.selectedLogicalProject == nil && vm.destination == nil, "no automatic reopen of a Project page")
        #expect(vm.newLogicalProject == nil, "turning Projects on left a New project draft behind")
        let again = try #require(app.server.state.projects.first)
        #expect(again.paused && again.revision == offRevision && retained(again) == kept, "on never resumes or changes a Project")
        #expect(vm.state.projects == app.server.state.projects)
        #expect(vm.emptyProjectConversation.draft == "ask about the launch date")
    }

    private static func sheetAndPageThenOff() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, _, ref, _) = try await rig(app)
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        let experiments = OffscreenWindow(size: CGSize(width: 1100, height: 900), dark: true,
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: app.settings, openInstructions: {}))
        defer { experiments.close() }
        try await eventuallyOnMain("the Projects switch to attach") { switchNode(experiments) != nil }
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn on") { app.settings.projectsEnabled }
        vm.openLogicalProject(ref)
        vm.showNewProject()
        try await eventuallyOnMain("the sheet presents") { window.layout(); return window.window.attachedSheet != nil }
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn off") { !app.settings.projectsEnabled }
        try await eventuallyOnMain("the sheet to dismiss") { window.layout(); return window.window.attachedSheet == nil }
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn on again") { app.settings.projectsEnabled }
        for _ in 0..<10 { await Task.yield(); window.layout() }
        #expect(vm.newLogicalProject == nil && window.window.attachedSheet == nil, "turning Projects on reopened the New project sheet")
    }

    private static func assignSheetThenOff() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, _, ref, _) = try await rig(app)
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        let experiments = OffscreenWindow(size: CGSize(width: 1100, height: 900), dark: true,
            ExperimentsSettings(model: vm.suggestions, instructions: vm.instructions, settings: app.settings, openInstructions: {}))
        defer { experiments.close() }
        try await eventuallyOnMain("the Projects switch to attach") { switchNode(experiments) != nil }
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn on") { app.settings.projectsEnabled }
        vm.openLogicalProject(ref)
        vm.beginAssigningProjectTask(ref)
        #expect(vm.assigningProjectTask != nil)
        try await eventuallyOnMain("the assign sheet presents") { window.layout(); return window.window.attachedSheet != nil }
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn off") { !app.settings.projectsEnabled }
        #expect(vm.assigningProjectTask == nil, "the callback cleared the assign draft")
        try await eventuallyOnMain("the assign sheet to dismiss") { window.layout(); return window.window.attachedSheet == nil }
        for _ in 0..<10 { await Task.yield(); window.layout() }
        #expect(vm.assigningProjectTask == nil, "dismissing the sheet wrote its draft back")
        try experiments.press("Projects", role: #require(switchNode(experiments)?.role))
        try await eventuallyOnMain("Projects to turn on again") { app.settings.projectsEnabled }
        for _ in 0..<10 { await Task.yield(); window.layout() }
        #expect(vm.assigningProjectTask == nil && window.window.attachedSheet == nil, "turning Projects on reopened the assign sheet")
    }

    private static func refusedWhileOff() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, _, ref, _) = try await rig(app)
        #expect(!vm.projectsEnabled)
        vm.showNewProject()
        vm.openLogicalProject(ref)
        vm.openLogicalProjectSettings(ref, tab: .automations)
        vm.selectedLogicalProject = ref
        vm.openDestination(.project)
        vm.openDestination(.projectSettings)
        #expect(vm.newLogicalProject == nil && vm.destination == nil, "no entry point opens a Project page or the sheet")
        // A page left behind by an older run of the app covers nothing and shows nothing.
        vm.destination = .project
        #expect(vm.shownDestination != .project, "a leftover Project page is not shown")
        #expect(vm.activeTabID != nil || vm.shownDestination == .newThread, "the thread layer is not hidden behind it")
        // The sheet cannot present from a draft set behind the flag's back.
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        vm.newLogicalProject = NewLogicalProjectDraft()
        for _ in 0..<20 {
            await Task.yield()
            window.layout()
        }
        #expect(window.window.attachedSheet == nil, "no New project sheet while off")
        vm.newLogicalProject = nil
        // The same draft presents once the flag is on, so the absence above is the gate and not a slow sheet.
        app.settings.projectsEnabled = true
        vm.newLogicalProject = NewLogicalProjectDraft()
        try await eventuallyOnMain("the sheet presents once Projects is on") { window.layout(); return window.window.attachedSheet != nil }
        vm.newLogicalProject = nil
        try await eventuallyOnMain("the sheet closes") { window.layout(); return window.window.attachedSheet == nil }
        // On, a page is open; turning the setting off runs the view model's own callback, which clears it and closes the host.
        vm.openLogicalProject(ref)
        #expect(vm.selectedLogicalProject == ref && vm.shownDestination == .project)
        app.settings.projectsEnabled = false
        #expect(vm.destination == nil && vm.selectedLogicalProject == nil, "the bound callback cleared the page")
        try await eventuallyAsync("the host to refuse") { await refuses(app) }
        vm.openLogicalProject(ref)
        #expect(vm.selectedLogicalProject == nil && vm.shownDestination != .project, "off again refuses the entry")
    }
}
