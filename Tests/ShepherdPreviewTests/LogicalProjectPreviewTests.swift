import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
@testable import ShepherdApp

/// The new Projects, rendered from the real producers (ProjectLead boards): a scratch server that
/// really holds the projects, Spaces and memory, driven through the view model the way the app does.
/// Every surface renders in light and dark at text scale 1 and 1.3 (`Preview.renderMatrix`), plus
/// empty and long names. The people and projects are fixtures; none of the board's strings are
/// copied in. Nothing is launched and no thread is faked.
struct PreviewError: Error { let message: String; init(_ message: String) { self.message = message } }

@Suite("Logical project previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct LogicalProjectPreviewTests {
    func world(spaces: Int = 3, projects: [(String, String)] = [("Sample App", "Build a shared reading list for a small team"),
                                                                       ("Latency budget", "")],
                       link: Bool = true) async throws -> (PreviewWorkspace, [Project]) {
        let world = try PreviewWorkspace()
        world.settings.projectsEnabled = true  // Projects is an opt-in experiment
        let names = ["library", "demo-web", "demo-tools", "sample-app-api"]
        var folders: [Space] = []
        for name in names.prefix(spaces) {
            let url = world.dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            folders.append(Space(name: name, path: url.path))
        }
        try await world.seed(ShepherdState(spaces: folders))
        var made: [Project] = []
        for (index, (name, goal)) in projects.enumerated() {
            let links = (link && index == 0) ? [folders.last!.id] : []
            guard case .project(let project) = try await world.server.logicalProjects(
                .create(projectID: ProjectID(), name: name, goal: goal, linkedSpaceIDs: links)) else { throw PreviewError("the server did not return a project") }
            made.append(project)
        }
        let vm = world.vm
        try await eventuallyOnMain("the projects arrive") { vm.state.projects.count == made.count }
        return (world, made)
    }

    // MARK: Conversation and tasks (real runtime, stub engine)

    /// The Project page populated by the real runtime: three workers started through the launcher on the stub
    /// engine, the coordinator conversation created by a first message. 1600 x 900, the boards' window.
    private func running(_ prompts: [(String, String)], paused: Bool = false) async throws -> (PreviewWorkspace, LogicalProjectRef) {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Sample App", "Build a shared reading list for a small team")])
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        let space = try #require(vm.state.spaces.last { !$0.hidden })
        var revision = projects[0].revision
        for (title, prompt) in prompts {
            let updated = try await vm.projectCoordinator.perform(projectID: ref.id, expectedRevision: revision,
                                                                 request: .assign(operationID: UUID(), spaceID: space.id, title: title, prompt: prompt))
            // The owner records each worker running asynchronously: the next assign carries the revision it really holds.
            let started = prompts.firstIndex { $0.0 == title }.map { $0 + 1 } ?? 1
            try await eventuallyOnMain("task \(started) is recorded on the owner") { (vm.state.projects.first?.tasks.count ?? 0) >= started
                && vm.state.projects.first?.tasks.allSatisfy { $0.phase != .queued && $0.phase != .reserved } == true
                && (!prompt.hasPrefix("ask") || vm.state.projects.first?.tasks.last?.phase == .waiting) }
            revision = vm.state.projects.first?.revision ?? updated.revision
        }
        try await eventuallyOnMain("workers started") { vm.state.projects.first?.tasks.count == prompts.count }
        // The conversation: a real first message through the runtime, answered by the stub engine's own native turn.
        try await eventuallyOnMain("the conversation sees the workers' current revision") {
            vm.logicalProjects.project(ref)?.revision == world.scratch.server.state.projects.first?.revision
        }
        #expect(await vm.logicalProjects.sendMessage(ref, text: "Create starter tasks for our sample reading-list app."),
                "\(vm.logicalProjects.failure?.message ?? "no refusal")")
        try await eventuallyOnMain("the coordinator exists and the message is delivered") {
            vm.state.projects.first?.messages.first?.phase == .delivered && vm.state.projects.first?.coordinatorAgentID != nil
        }
        let coordinator = try #require(vm.state.projects.first?.coordinatorAgentID)
        // The thread polls only while it is on screen: the page's own ThreadView runs the store once it is mounted, so
        // nothing is awaited here (its poll loop never returns).
        _ = coordinator
        if paused { _ = await vm.logicalProjects.setPaused(ref, true) }
        vm.openLogicalProject(ref)
        return (world, ref)
    }

    @Test func taskSummaryCollapsedAndExpanded() async throws {
        let (world, ref) = try await running([("Reading list research", "tools:0 finish"),
                                             ("Library API implementation", "slow"),
                                             ("Reading widget decision", "ask")])
        defer { world.stop() }
        try await eventuallyOnMain("finished and waiting tasks reach the summary") {
            let tasks = world.vm.state.projects.first?.tasks ?? []
            return tasks.contains { $0.phase == .settled } && tasks.contains { $0.phase == .waiting }
        }
        for expanded in [false, true] {
            try await Preview.renderMatrix("lead-task-summary-\(expanded ? "expanded" : "collapsed")",
                                           size: CGSize(width: 700, height: 350), scales: [1, 1.3]) {
                VStack {
                    if let project = world.vm.state.projects.first(where: { $0.id == ref.id }) {
                        let presentation = ProjectPagePresentation(project)
                        if let summary = presentation.summary {
                            ProjectSummaryStrip(vm: world.vm, ref: ref, summary: summary, rows: presentation.rows, expanded: expanded)
                        }
                    }
                }
                .padding(NW.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background(Color.nw.bgWindow)
            }
        }
    }

    /// Five tasks past the four-row cap, at text scale 1.3: the list stays bounded and the rest scroll.
    @Test func taskSummaryCapsFiveTasks() async throws {
        let (world, projects) = try await world(projects: [("Sample App", "")])
        defer { world.stop() }
        var project = projects[0]
        project.tasks = ["Research", "API draft", "Widget mockup", "Docs", "Release notes"].map {
            ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: $0, prompt: "p", phase: .queued)
        }
        let ref = LogicalProjectRef(home: .local, id: project.id)
        let presentation = ProjectPagePresentation(project)
        let summary = try #require(presentation.summary)
        try await Preview.renderMatrix("lead-task-summary-five", size: CGSize(width: 700, height: 400), scales: [1, 1.3]) {
            ProjectSummaryStrip(vm: world.vm, ref: ref, summary: summary, rows: presentation.rows, expanded: true)
                .padding(NW.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .background(Color.nw.bgWindow)
        }
    }

    @Test func startedWithThreeWorkingThreads() async throws {
        let (world, _) = try await running([("Reading list research", "slow"), ("Library API draft", "slow"), ("Reading widget mockup", "slow")])
        defer { world.stop() }
        let vm = world.vm
        let ready: @MainActor () -> Bool = { vm.state.projects.first.flatMap { $0.coordinatorAgentID }.flatMap { vm.projectCoordinator.conversationStore(agentID: $0) }?.rows.isEmpty == false }
        try await Preview.renderMatrix("lead-started", size: CGSize(width: 1368, height: 900), scales: [1], ready: ready) {
            LogicalProjectDestination(vm: vm).frame(width: 1368).background(Color.nw.bgWindow)
        }
    }

    /// A worker that really asks (the stub engine's own select dialog, with a Recommended first option), one that settled,
    /// and one still working: the Question board. Its words are the stub's, never the board's.
    @Test func questionWithOneWaitingOneSettledOneWorking() async throws {
        let (world, ref) = try await running([("Reading list research", "slow"), ("Library API draft", "ask-choice"), ("Reading widget mockup", "slow")])
        defer { world.stop() }
        let vm = world.vm
        try await eventuallyOnMain("one task waits") { vm.state.projects.first?.tasks.contains { $0.phase == .waiting } == true }
        let waiting = try #require(vm.state.projects.first?.tasks.first { $0.phase == .waiting })
        // Ready once the worker's own native dialog has been read (the card draws only from it).
        // The card reads the worker's own dialog, which that worker's store loads once polling: the page's card starts it, so ready
        // is just that the coordinator's reply is in; the render waits for the dialog through its own `ready` re-check below.
        let server = vm.server
        let workerStore = vm.threadStores.store(for: waiting.workerAgentID)
        Task { await workerStore.run(request: { try await server.nativeThread(agentID: waiting.workerAgentID, request: $0) }, preview: nil) }
        let ready: @MainActor () -> Bool = {
            !workerStore.dialogs.isEmpty
                && vm.state.projects.first.flatMap { $0.coordinatorAgentID }.flatMap { vm.projectCoordinator.conversationStore(agentID: $0) }?.rows.isEmpty == false
        }
        vm.settings.sidebarStyle = .projects
        vm.collapsedProjects = Set(vm.state.spaces.map { SidebarProjectID.local($0.id).key })
        // The Question board draws the conversation alone: Overview's pane is closed.
        vm.logicalProjectPaneOpen = false
        try await Preview.renderMatrix("lead-question", size: CGSize(width: 1368, height: 900), scales: [1], ready: ready) {
            HStack(spacing: 0) {
                SidebarView(vm: vm).frame(width: 232).background(Color.nw.bgBase)
                LogicalProjectDestination(vm: vm).frame(width: 1368 - 232)
            }
        }
        _ = ref
    }

    /// Paused, from the real runtime: Pause aborts running turns, so a worker that was only asking ends its turn and its task is
    /// `.settled`, not `.waiting` (ProjectLead-PausedV2 draws a paused Project that still has a question: not reachable
    /// from this data, reported to the runtime owner). This renders what the runtime really does: the banner, both Resume
    /// controls, and the settled rows.
    @Test func pausedAsTheRuntimeActuallyLeavesIt() async throws {
        let (world, ref) = try await running([("Reading list research", "slow"), ("Library API draft", "ask-choice")], paused: true)
        defer { world.stop() }
        let vm = world.vm
        try await eventuallyOnMain("paused") { vm.state.projects.first?.paused == true }
        vm.settings.sidebarStyle = .projects
        vm.collapsedProjects = Set(vm.state.spaces.map { SidebarProjectID.local($0.id).key })
        try await Preview.renderMatrix("lead-paused", size: CGSize(width: 1368, height: 900), scales: [1]) {
            HStack(spacing: 0) {
                SidebarView(vm: vm).frame(width: 232).background(Color.nw.bgBase)
                LogicalProjectDestination(vm: vm).frame(width: 1368 - 232)
            }
        }
        _ = ref
    }

    /// A paused Project holding a message with an image, beside one the engine refused: the queued one in the composer's shared Up next
    /// (read-only, Paused, the image by name), the refused one in the transcript with the owner's reason. All from the real runtime.
    @Test func pausedQueueWithAnImageAndARefusedMessage() async throws {
        let (world, ref) = try await running([])
        defer { world.stop() }
        let vm = world.vm
        // The stub engine refuses a prompt with "refuse" in it: a definite refusal, recorded with its reason.
        #expect(await vm.logicalProjects.sendMessage(ref, text: "Please refuse this one so its note shows."))
        try await eventuallyOnMain("the refusal is recorded") { vm.state.projects.first?.messages.contains { $0.phase == .failed } == true }
        #expect(await vm.logicalProjects.setPaused(ref, true))
        try await eventuallyOnMain("paused and acknowledged") { vm.state.projects.first.map { $0.paused && !$0.interruptPending } == true }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        #expect(await vm.logicalProjects.sendMessage(ref, text: "Use this sketch for the reading-list layout when you continue.",
                                                      images: [NativeImage(mimeType: "image/png", data: png, name: "reading-list-sketch.png")]))
        try await eventuallyOnMain("the owner holds it") { vm.state.projects.first?.messages.last?.phase == .queued }
        vm.logicalProjectPaneOpen = false
        let ready: @MainActor () -> Bool = {
            vm.state.projects.first.flatMap { $0.coordinatorAgentID }.flatMap { vm.projectCoordinator.conversationStore(agentID: $0) }?.rows.isEmpty == false
        }
        try await Preview.renderMatrix("lead-paused-queue", size: CGSize(width: 1136, height: 700), scales: [1, 1.3], ready: ready) {
            LogicalProjectDestination(vm: vm).frame(width: 1136).background(Color.nw.bgWindow)
        }
    }

    // MARK: Full window (1600 x 900, the boards' own frame): the sidebar and the Project page side by side

    func window(_ vm: ShepherdViewModel, style: NWSidebarStyle) -> some View {
        vm.settings.sidebarStyle = style
        // The boards draw Designs in the navigation: the Design tool experiment is on, through its real setting.
        vm.settings.designToolEnabled = true
        vm.collapsedProjects = Set(vm.state.spaces.map { SidebarProjectID.local($0.id).key })
        return HStack(spacing: 0) {
            // The boards' 232pt sidebar includes its own 1pt trailing edge, so the page begins at 232.
            SidebarView(vm: vm).frame(width: 232).background(Color.nw.bgBase)
                .overlay(alignment: .trailing) { Rectangle().fill(Color.nw.lineSubtle).frame(width: 1) }
            LogicalProjectDestination(vm: vm).frame(width: 1600 - 232)
        }
        .frame(width: 1600, height: 900)
    }

    @Test func fullWindowStartedAndEmptyAndSettings() async throws {
        let (world, ref) = try await running([("Reading list research", "slow"), ("Library API draft", "slow"), ("Reading widget mockup", "slow")])
        defer { world.stop() }
        let vm = world.vm
        let workers = (vm.state.projects.first?.tasks ?? []).map(\.workerAgentID)
        // The stub engine pauses a "slow" turn twice. Releasing the first lets each worker reach its tool call, which pauses
        // again while it runs: the native activity line the rows read ("Running ls"), from the workers' own threads.
        let folder = try #require(vm.state.spaces.last { !$0.hidden }).path
        FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent("continue-1"), contents: nil)
        // The second worker has two subagents running: published as the children extension publishes them (the VM's own
        // `onAgentChildren` path), so the row's pill is the live count, not a typed string.
        if workers.count > 1 {
            let runs = (1...2).map { ChildRun(runID: "run-\($0)", label: "worker \($0)", state: "running", startedAt: Date().timeIntervalSince1970 * 1000) }
            vm.sessions.onAgentChildren?(workers[1], runs)
        }
        for id in workers { Task { await vm.threadStores.store(for: id).run(request: { try await vm.server.nativeThread(agentID: id, request: $0) }) } }
        let ready: @MainActor () -> Bool = {
            vm.state.projects.first.flatMap { $0.coordinatorAgentID }.flatMap { vm.projectCoordinator.conversationStore(agentID: $0) }?.rows.isEmpty == false
                && workers.allSatisfy { vm.workerActivity($0) != nil && vm.workerStarted($0) != nil }
        }
        try await Preview.renderMatrix("win-started-activity", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .activity) }
        try await Preview.renderMatrix("win-started-spaces", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
        // The task detail pane: a running worker's own native thread beside the conversation.
        let task = try #require(vm.state.projects.first?.tasks.first)
        vm.logicalProjectPaneTask = task.id
        try await Preview.renderMatrix("win-thread-running", size: CGSize(width: 1600, height: 900), scales: [1, 1.3]) { window(vm, style: .projects) }
        _ = ref
    }

    /// ProjectLead-AddsSpace: a real pending proposal (from the owner's own `proposeSpace`), drawn as the offer card over the composer.
    @Test func addsSpaceOfferFromARealProposal() async throws {
        try StubPi.installAsEngine()
        let (world, projects) = try await world(projects: [("Sample App", "Build a shared reading list for a small team"), ("Latency budget", "")])
        defer { world.stop() }
        let vm = world.vm
        let ref = LogicalProjectRef(home: .local, id: projects[0].id)
        #expect(await vm.logicalProjects.sendMessage(ref, text: "Create starter tasks for our sample reading-list app."))
        let folder = world.dir.appendingPathComponent("sample-app-web")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shown = try #require(vm.state.projects.first { $0.id == ref.id })
        _ = try await vm.projectCoordinator.perform(projectID: ref.id, expectedRevision: shown.revision,
            request: .proposeSpace(operationID: UUID(), path: folder.path, spaceID: nil, originTaskID: nil))
        try await eventuallyOnMain("the proposal is pending") { vm.state.projects.first { $0.id == ref.id }?.spaceProposals.contains { $0.phase == .pending } == true }
        vm.openLogicalProject(ref)
        vm.logicalProjectPaneOpen = false   // the AddsSpace board has no Threads pane
        let ready: @MainActor () -> Bool = {
            let project = vm.state.projects.first { $0.id == ref.id }
            return project?.coordinatorAgentID != nil && project?.messages.first?.phase == .delivered
                && project?.spaceProposals.contains { $0.phase == .pending } == true
        }
        try await Preview.renderMatrix("lead-adds-space", size: CGSize(width: 1600, height: 900), scales: [1, 1.3], ready: ready) { window(vm, style: .projects) }
    }

    // MARK: Sidebar

    /// Activity: Designs / Needs you / Working / Done / Projects / Recents. Needs-you, working, done and
    /// recents rows are real agents in a real workspace; the Projects rows are real projects.
    @Test func activitySidebarListsProjectsBetweenDoneAndRecents() async throws {
        let (world, _) = try await world()
        defer { world.stop() }
        let vm = world.vm
        let space = try #require(vm.state.spaces.first)
        var rows: [(Agent, ShepherdCore.Tab)] = []
        for (index, status) in [AgentStatus.blocked, .working, .done, .idle].enumerated() {
            rows.append(try await world.agent(["Library API draft", "Improve reading-list latency", "Reading list research", "Fix terminal output buffer"][index],
                                              in: space, order: index, status: status))
        }
        var state = vm.state
        state.tabs = rows.map(\.1); state.agents = rows.map(\.0)
        state.agents[0].waitingOn = "Who organizes the list?"
        try await world.seed(state)
        vm.settings.sidebarStyle = .activity
        try await Preview.renderMatrix("lead-sidebar-activity", size: CGSize(width: 232, height: 820)) {
            SidebarView(vm: vm)
        }
    }

    /// The folder-organized mode: Projects above the Spaces, no `+` on Spaces.
    @Test func spacesSidebarPutsProjectsAboveSpaces() async throws {
        let (world, projects) = try await world()
        defer { world.stop() }
        let vm = world.vm
        vm.settings.sidebarStyle = .projects
        vm.collapsedProjects = Set(vm.state.spaces.map { SidebarProjectID.local($0.id).key })
        vm.openLogicalProject(LogicalProjectRef(home: .local, id: projects[0].id))
        try await Preview.renderMatrix("lead-sidebar-spaces", size: CGSize(width: 232, height: 820)) {
            SidebarView(vm: vm)
        }
    }

    @Test func sidebarWithNoProjectsStillOffersNewProject() async throws {
        let (world, _) = try await world(projects: [])
        defer { world.stop() }
        let vm = world.vm
        vm.settings.sidebarStyle = .projects
        try await Preview.renderMatrix("lead-sidebar-empty", size: CGSize(width: 232, height: 520)) { SidebarView(vm: vm) }
    }

    // MARK: Sheet

    @Test(arguments: ["empty", "filled", "long"])
    func newProjectSheet(state: String) async throws {
        let (world, _) = try await world(projects: [])
        defer { world.stop() }
        let vm = world.vm
        var draft = NewLogicalProjectDraft()
        if state != "empty" {
            draft.name = state == "long" ? String(repeating: "Sample App platform ", count: 6) : "Sample App"
            draft.goal = state == "long" ? String(repeating: "Build a shared reading list for a small team. ", count: 5) : "Build a shared reading list"
            draft.spaces = state == "long" ? vm.state.spaces.map(\.id) : [try #require(vm.state.spaces.last).id]
        }
        let binding = Binding(get: { draft }, set: { draft = $0 })
        try await Preview.renderMatrix("lead-new-project-\(state)", size: CGSize(width: 560, height: 640)) {
            NewProjectSheet(vm: vm, draft: binding, dismiss: {})
        }
    }

    // MARK: Overview

    @Test(arguments: ["sample-app", "bare", "paused"])
    func overview(state: String) async throws {
        let (world, projects) = try await world(projects: state == "bare" ? [("Latency budget", "")] : [("Sample App", "Build a shared reading list for a small team")],
                                                link: state != "bare")
        defer { world.stop() }
        let vm = world.vm
        var project = projects[0]
        if state == "paused" {
            guard case .project(let paused) = try await world.server.logicalProjects(.setPaused(projectID: project.id, expectedRevision: project.revision, paused: true)) else { return }
            project = paused
            try await eventuallyOnMain("paused") { vm.state.projects.first?.paused == true }
        }
        let ref = LogicalProjectRef(home: .local, id: project.id)
        vm.openLogicalProject(ref)
        try await Preview.renderMatrix("lead-overview-\(state)", size: CGSize(width: 1100, height: 700)) {
            LogicalProjectDestination(vm: vm)
        }
    }

    // MARK: Settings

    @Test(arguments: [LogicalProjectSettingsTab.general, .spaces, .memory, .automations])
    func settings(tab: LogicalProjectSettingsTab) async throws {
        let (world, projects) = try await world()
        defer { world.stop() }
        let vm = world.vm
        var project = projects[0]
        // Real memory and instructions, written through the same API the Memory page reads.
        for text in ["Readers save bookmarks into a shared folder (demo decision).",
                     "Use simple tags so saved bookmarks stay easy to find.",
                     "Mockups go to the project’s files as single HTML pages."] {
            guard case .project(let next) = try await world.server.logicalProjects(
                .addMemory(projectID: project.id, expectedRevision: project.revision, memoryID: ProjectMemoryID(), text: text, source: "you")) else { return }
            project = next
        }
        var settings = project.settings
        settings.instructions = "Sample App helps a small team organize reading lists.\n- API work goes in sample-app-api, the widget in sample-app-web.\n- Ask before deleting any saved links, even in a demo."
        settings.conversationModel = "claude-sonnet-4-6"
        guard case .project = try await world.server.logicalProjects(.settings(projectID: project.id, expectedRevision: project.revision, settings: settings)) else { return }
        try await eventuallyOnMain("settings pushed") { vm.state.projects.first?.settings.instructions == settings.instructions }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: project.id), tab: tab)
        try await Preview.renderMatrix("lead-settings-\(tab.rawValue.lowercased())", size: CGSize(width: 1100, height: 760)) {
            LogicalProjectSettingsDestination(vm: vm)
        }
    }

    @Test func settingsWithNothingInThem() async throws {
        let (world, projects) = try await world(spaces: 0, projects: [("Latency budget", "")], link: false)
        defer { world.stop() }
        let vm = world.vm
        for tab in [LogicalProjectSettingsTab.spaces, .memory] {
            vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: projects[0].id), tab: tab)
            try await Preview.renderMatrix("lead-settings-empty-\(tab.rawValue.lowercased())", size: CGSize(width: 1100, height: 560)) {
                LogicalProjectSettingsDestination(vm: vm)
            }
        }
    }

    @Test func deleteConfirmationSaysTheFilesStay() async throws {
        let (world, projects) = try await world()
        defer { world.stop() }
        let vm = world.vm
        try await Preview.renderMatrix("lead-delete-project", size: CGSize(width: 560, height: 360)) {
            DeleteLogicalProjectDialog(vm: vm, ref: LogicalProjectRef(home: .local, id: projects[0].id), project: projects[0], dismiss: {})
        }
    }
}
