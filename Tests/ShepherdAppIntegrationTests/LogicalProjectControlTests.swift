import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The new Projects, pressed through accessibility on a real scratch server (ProjectLead boards):
/// New project creates one atomically with its chosen Space, and a stale second view is refused without being
/// overwritten. The Settings controls (every popup, Pause, Goal, instructions, Forget, Add and Remove a Space) are pressed in
/// `ProjectSettingsFidelityControlTests`. No window is focused and no event is posted.
private struct ControlTestError: Error { let message: String; init(_ message: String) { self.message = message } }

@Suite("Logical project controls", .mainActorExclusive)
@MainActor
struct LogicalProjectControlTests {
    @Test func newProjectCreatesWithItsChosenSpaceAndOpensItsPage() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.create() } }
        expectScenarioCompleted(result)
    }

    @Test func theOverviewsRowsAndSuggestionsArePressableAtEveryStateOfARealProject() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.overview() } }
        expectScenarioCompleted(result)
    }

    @Test func deleteSaysTheProjectsFilesStayAndRemovesOnlyTheRecord() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.delete() } }
        expectScenarioCompleted(result)
    }

    @Test func theSidebarChipAndRowsOpenTheSheetAndThePageInBothModes() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.sidebar() } }
        expectScenarioCompleted(result)
    }

    // MARK: Sidebar

    private static func sidebar() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let vm = try await app.start(with: Fixture.state(spaces: [Fixture.space("web", path: app.dir.path)], agents: []))
        let id = ProjectID()
        _ = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: []))
        try await eventuallyOnMain("adopted") { vm.state.projects.count == 1 }
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        // Activity: the header's chip opens New project; the row opens the page.
        vm.settings.sidebarStyle = .activity
        try await eventuallyOnMain("the chip") { window.layout(); return window.element("New project") != nil }
        let chip = try #require(window.controls().first { $0.label == "New project" })
        #expect(ControlPress.undersized([chip], minimum: .desktop).isEmpty, "the chip is \(chip.frame.size)")
        try window.press("New project")
        try await eventuallyOnMain("the sheet opens") { vm.newLogicalProject != nil }
        vm.newLogicalProject = nil
        try await eventuallyOnMain("the sheet closes") { window.window.attachedSheet == nil }
        try await eventuallyOnMain("the row") { window.layout(); return window.element("Gamecards, project") != nil }
        try window.press("Gamecards, project")
        try await eventuallyOnMain("the page opens") {
            let shown: MainDestination? = vm.shownDestination
            return vm.selectedLogicalProject?.id == id && shown == MainDestination.project
        }
        // Spaces mode: Projects above Spaces; the + opens the same sheet.
        vm.settings.sidebarStyle = .projects
        try await eventuallyOnMain("the + ") { window.layout(); return window.element("New project") != nil }
        try window.press("New project")
        try await eventuallyOnMain("the sheet opens again") { vm.newLogicalProject != nil }
        let items = vm.presentedSidebarTree
        let kinds = items.prefix(3).map { item -> String in
            switch item { case .leadHeader: "lead"; case .leadProject: "project"; case .header: "spaces"; default: "other" }
        }
        #expect(kinds == ["lead", "project", "spaces"], "Projects sit above Spaces: \(kinds)")
    }

    // MARK: Overview (board 09, Empty)

    /// A fresh Project with a linked Space, then one with none and a long name: every row and suggestion is a 24pt control, a
    /// suggestion fills the composer without sending, and a context row opens its settings tab. The Project is the owner's own create.
    private static func overview() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let folder = app.dir.appendingPathComponent("gamecards-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("gamecards-api", path: folder.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        let long = String(repeating: "Gamecards platform ", count: 6)
        guard case .project(let linked) = try await app.server.logicalProjects(.create(projectID: ProjectID(), name: "Gamecards", goal: "Launch a gift card reseller API", linkedSpaceIDs: [space.id])),
              case .project(let bare) = try await app.server.logicalProjects(.create(projectID: ProjectID(), name: long, goal: "", linkedSpaceIDs: [])) else { throw ControlTestError("create") }
        try await eventuallyOnMain("both projects arrive") { vm.state.projects.count == 2 }
        let window = OffscreenWindow(size: CGSize(width: 1600, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        for scale in [CGFloat(1), 1.3] {
            ThemeStore.shared.textScale = scale
            defer { ThemeStore.shared.textScale = 1 }
            vm.openLogicalProject(LogicalProjectRef(home: .local, id: linked.id))
            try await eventuallyOnMain("the overview, linked, at \(scale)") { window.layout(); return window.controls().contains { $0.label == "Instructions, memory, In project settings" } }
            let named = window.controls().filter { ["Instructions, memory, In project settings", "Set up this project from my recent threads", "Help me work out a plan for this project",
                                                    "Look around gamecards-api and suggest first threads"].contains($0.label ?? "") || ($0.label ?? "").hasPrefix("Spaces, gamecards-api") }
            #expect(named.count == 5, "the rows and suggestions are controls at \(scale): \(named.map(\.description))")
            #expect(ControlPress.undersized(named, minimum: .desktop).isEmpty, "undersized at \(scale): \(named.map(\.description))")
        }
        let ref = LogicalProjectRef(home: .local, id: linked.id)
        vm.openLogicalProject(ref)
        try await eventuallyOnMain("the overview") { window.layout(); return window.controls().contains { $0.label == "Help me work out a plan for this project" } }
        try window.press("Help me work out a plan for this project")
        #expect(vm.emptyProjectConversation.draft == "Help me work out a plan for this project", "a suggestion fills the composer")
        #expect(app.server.state.projects.first { $0.id == linked.id }?.messages.isEmpty == true, "and sends nothing")
        try window.press("Instructions, memory, In project settings")
        try await eventuallyOnMain("the Memory tab opens") { vm.logicalProjectSettingsTab == .memory }

        // No Space and a long name: the Spaces row says so, and the controls are still there and 24pt.
        vm.openLogicalProject(LogicalProjectRef(home: .local, id: bare.id))
        try await eventuallyOnMain("the bare overview") { window.layout(); return window.controls().contains { ($0.label ?? "").hasPrefix("Spaces, None yet") } }
        ThemeStore.shared.textScale = 1.3
        defer { ThemeStore.shared.textScale = 1 }
        window.layout()
        let rows = window.controls().filter { ($0.label ?? "").hasPrefix("Spaces, None yet") || ($0.label ?? "").hasPrefix("Instructions, memory") || ($0.label ?? "").hasPrefix("Set up this project") }
        #expect(rows.count == 3 && ControlPress.undersized(rows, minimum: .desktop).isEmpty, "the bare project's rows: \(rows.map(\.description))")
        try window.press(try #require(rows.first { ($0.label ?? "").hasPrefix("Spaces") }?.label))
        try await eventuallyOnMain("the Spaces tab opens") { vm.logicalProjectSettingsTab == .spaces }
    }

    // MARK: New project

    private static func create() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let folder = app.dir.appendingPathComponent("gamecards-api")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = Fixture.space("gamecards-api", path: folder.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        vm.showNewProject()
        let window = OffscreenWindow(size: CGSize(width: 1100, height: 850), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the sheet") { window.layout(); return window.window.attachedSheet?.contentView != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        // The named controls are at least 24pt (the popup's own menu parts are system pieces inside a 28pt control).
        for name in ["Close", "Cancel", "Create project"] {
            let control = try #require(ControlPress.controls(in: sheet).first { $0.label == name })
            #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size)")
        }
        // Boxes against the board's markup (03-ProjectNew, 560 x 640 sheet, origin at its corner): title 17, 23.5; Close 28 at 517, 19; fields 526 x 32 at
        // y 84 and 155; help 526 wide; Add a space popup 129 x 32 at 17, 269; Cancel 62.7 and Create project 105.4 wide, 28 tall at y 597.
        let nodes = AccessibilityNode.all(under: sheet)
        let root = try #require(nodes.first { $0.role == "AXGroup" }).frame
        func box(_ matches: (AccessibilityNode) -> Bool) throws -> CGRect {
            guard let node = nodes.first(where: matches) else { throw ControlTestError("no such element in the sheet") }
            let f = node.frame
            return CGRect(x: f.minX - root.minX, y: root.maxY - f.maxY, width: f.width, height: f.height)
        }
        let fieldName = try box { $0.label == "Project name" }, fieldGoal = try box { $0.label == "Goal" && $0.role == "AXTextField" }
        #expect(fieldName.origin == CGPoint(x: 17, y: 84) && fieldName.width == 526 && fieldName.height == 32, "Name field \(fieldName)")
        #expect(fieldGoal.origin == CGPoint(x: 17, y: 155) && fieldGoal.width == 526, "Goal field \(fieldGoal)")
        let closeBox = try box { $0.label == "Close" }
        #expect(closeBox.origin == CGPoint(x: 517, y: 19) && closeBox.width == 28, "Close \(closeBox)")
        let cancelBox = try box { $0.label == "Cancel" }, createBox = try box { $0.label == "Create project" }
        // The accessibility tree rounds a frame outward to whole points: 62.7 and 105.4 read as 63 and 106, 0.3 and 0.6 over.
        #expect(abs(cancelBox.width - 62.7) < 0.5 && abs(createBox.width - 105.4) < 0.7 && cancelBox.minY == 597 && createBox.height == 28, "buttons \(cancelBox) \(createBox)")
        #expect(abs(createBox.maxX - 543) < 0.2, "Create ends on the 16pt margin: \(createBox)")
        let help = try box { ($0.value ?? "").hasPrefix("Folders threads work in") }
        #expect(help.width == 526 || help.width > 500, "help \(help)")
        let popupBox = try box { $0.role == ControlRole.menuButton }
        #expect(popupBox.origin == CGPoint(x: 17, y: 269) && abs(popupBox.width - 129) < 0.6 && popupBox.height == 32, "Add a space popup \(popupBox)")
        // Name is required: Create is disabled while it is blank.
        let create = try #require(ControlPress.controls(in: sheet).first { $0.label == "Create project" })
        #expect(!create.isEnabled)
        // The Name and Goal fields take their values through accessibility, as a person typing would.
        try set("Project name", to: "Gamecards", under: sheet)
        try set("Goal", to: "Launch a gift card reseller API", under: sheet)
        try await eventuallyOnMain("the typed name reaches the draft") { vm.newLogicalProject?.name == "Gamecards" }
        #expect(vm.newLogicalProject?.goal == "Launch a gift card reseller API")
        // Add a space is a native menu: choose the one real Space from it, as a person does.
        let addSpace = try #require(AccessibilityNode.all(under: sheet).first { node in
            node.role == ControlRole.menuButton && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == "Add a space…"
        }, "Add a space… is a popup")
        let offered = try await NativeMenuChoice.choose("gamecards-api", from: addSpace)
        #expect(offered == ["gamecards-api"], "the menu offers the owner's real Spaces: \(offered)")
        try await eventuallyOnMain("the chosen Space reaches the draft") { vm.newLogicalProject?.spaces == [space.id] }
        sheet.layoutSubtreeIfNeeded()
        try await eventuallyOnMain("Create is enabled once Name is filled") {
            sheet.layoutSubtreeIfNeeded()
            return ControlPress.controls(in: sheet).first { $0.label == "Create project" }?.isEnabled == true
        }
        try ControlPress.press("Create project", under: sheet)
        try await eventuallyOnMain("the project on the server") { !app.server.state.projects.isEmpty }
        let made = try #require(app.server.state.projects.first)
        #expect(made.name == "Gamecards" && made.goal == "Launch a gift card reseller API")
        #expect(made.linkedSpaces.map(\.spaceID) == [space.id], "created with its Space in one request")
        #expect(!made.paused, "a new project is ready, not paused")
        #expect(made.settings.maxConcurrentWorkers == 3)
        try await eventuallyOnMain("opens its page") {
            let shown: MainDestination? = vm.shownDestination
            return vm.selectedLogicalProject?.id == made.id && shown == MainDestination.project
        }
        #expect(vm.newLogicalProject == nil)
        #expect(await app.server.listSessions().isEmpty, "creating a project starts no session")
    }

    /// A view that is a revision behind is refused by the owner and never overwrites: the model re-reads
    /// and keeps its draft. This is the model against the real server, with a deliberately old snapshot.
    @Test func aStaleViewIsRefusedAndNothingIsOverwritten() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.stale() } }
        expectScenarioCompleted(result)
    }

    private static func stale() async throws {
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        _ = try await app.start()
        let id = ProjectID()
        guard case .project(let first) = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: [])) else {
            Issue.record("Expected a project"); return
        }
        let server = app.server
        // The model's pushed snapshot stays at revision 1; the owner moves on.
        let model = LogicalProjectsModel(send: { _, request in try await server.logicalProjects(request) }, pushed: { _ in [first] })
        _ = try await app.server.logicalProjects(.edit(projectID: id, expectedRevision: first.revision, name: "Renamed elsewhere", goal: ""))
        let ref = LogicalProjectRef(home: .local, id: id)
        let saved = await model.edit(ref, name: "Overwrite", goal: "")
        #expect(!saved)
        #expect(model.failure?.stale == true, "the refusal is shown as a changed project")
        #expect(app.server.state.projects.first?.name == "Renamed elsewhere", "the stale edit overwrote nothing")
        // The refusal re-read the owner, so the next action carries the owner's revision.
        let latest = try #require(model.project(ref))
        #expect(latest.revision > first.revision && latest.name == "Renamed elsewhere")
    }

    @Test func aProjectsAutomationsToggleThroughTheOwnerAndItsSidebarRowOffersNoGenericStop() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.automations() } }
        expectScenarioCompleted(result)
    }

    private static func automations() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let folder = app.dir.appendingPathComponent("research")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let vm = try await app.start(with: Fixture.state(spaces: [Fixture.space("research", path: folder.path)], agents: []))
        let id = ProjectID()
        guard case .project(var project) = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: [])) else {
            throw ControlTestError("no project")
        }
        let automation = AutomationID()
        let draft = RemoteAutomationDraft(name: "Weekly market scan", prompt: "Scan the market and report\nwith sources", cwd: folder.path, enabled: false)
        guard case .project(let created) = try await app.server.logicalProjects(
            .automation(projectID: id, expectedRevision: project.revision, automationID: automation, action: .create(draft: draft))) else {
            throw ControlTestError("no automation")
        }
        project = created
        try await eventuallyOnMain("adopted") { vm.state.automations.contains { $0.id == automation && $0.projectID == id } }
        let ref = LogicalProjectRef(home: .local, id: id)
        vm.openLogicalProjectSettings(ref, tab: .automations)
        let window = OffscreenWindow(size: CGSize(width: 1280, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the row") { window.layout(); return window.element("Run Weekly market scan") != nil }
        // The caption holds only what the record has: the prompt's first line, the owner, and that it never ran. No schedule.
        let words = AccessibilityNode.all(under: window.host).compactMap { $0.value ?? $0.label }
        #expect(words.contains { $0.contains("Scan the market and report") && $0.contains("never run") }, "caption: \(words.filter { $0.contains("Scan") })")
        #expect(!words.contains { $0.contains("Monday") || $0.contains("PR opens") }, "no invented schedule or trigger")
        let toggle = try #require(window.controls().first { $0.label == "Run Weekly market scan" })
        #expect(toggle.isEnabled && ControlPress.undersized([toggle], minimum: .desktop).isEmpty, "the switch is \(toggle.frame.size)")
        try window.press("Run Weekly market scan", role: toggle.role)
        try await eventuallyOnMain("enabled through the owner") { app.server.state.automations.first { $0.id == automation }?.enabled == true }
        #expect(app.server.state.projects.first?.revision ?? 0 > project.revision, "the toggle advanced the Project revision")

        // A stale view is refused without changing the record, and the model re-reads.
        let stale = LogicalProjectsModel(send: { _, request in try await app.server.logicalProjects(request) }, pushed: { _ in [project] })
        let ok = await stale.automation(ref, automation, .setEnabled(false))
        #expect(!ok && stale.failure?.stale == true)
        #expect(app.server.state.automations.first { $0.id == automation }?.enabled == true, "the stale toggle changed nothing")

        // The generic sidebar row for this automation's run offers Open Project Settings, never Stop, Run Now or Delete.
        #expect(vm.projectOwning(automation) == ref)
        #expect(vm.projectOwning(AutomationID()) == nil)
    }

    // MARK: Delete

    private static func delete() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let vm = try await app.start()
        let id = ProjectID()
        _ = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: []))
        try await eventuallyOnMain("adopted") { vm.state.projects.count == 1 }
        let kept = app.dir.appendingPathComponent("logical-projects/\(id.rawValue)")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id))
        let window = OffscreenWindow(size: CGSize(width: 1280, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the page") { window.layout(); return window.element("Delete…") != nil }
        try window.press("Delete…")
        try await eventuallyOnMain("confirmation") { window.layout(); return window.window.attachedSheet?.contentView != nil }
        let sheet = try #require(window.window.attachedSheet?.contentView)
        sheet.layoutSubtreeIfNeeded()
        let words: [String] = AccessibilityNode.all(under: sheet).compactMap { $0.value ?? $0.label }
        let saysFilesStay = words.contains { $0.contains("files stay on") }
        #expect(saysFilesStay, "the confirmation says the project's files stay")
        try ControlPress.press("Cancel", under: sheet)
        try await eventuallyOnMain("cancel closes") { window.window.attachedSheet == nil }
        #expect(app.server.state.projects.count == 1, "Cancel deletes nothing")
        try window.press("Delete…")
        try await eventuallyOnMain("confirmation again") { window.layout(); return window.window.attachedSheet?.contentView != nil }
        let again = try #require(window.window.attachedSheet?.contentView)
        try ControlPress.press("Delete project", under: again)
        try await eventuallyOnMain("record removed") { app.server.state.projects.isEmpty }
        #expect(FileManager.default.fileExists(atPath: kept.path), "the project's directory is retained, as the dialog said")
    }

    // MARK: Helpers

    /// Types into a field through accessibility, then tells the native field's delegate, exactly as the
    /// existing project controls tests do, so SwiftUI's binding sees the text.
    private static func set(_ label: String, to value: String, under host: NSView) throws {
        let fields = AccessibilityNode.all(under: host).filter { $0.label == label && ["AXTextField", "AXTextArea"].contains($0.role ?? "") }
        let field = try #require(fields.first)
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(field.object.responds(to: setter))
        _ = field.object.perform(setter, with: value)
        func nativeField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == value { return field }
            return view.subviews.compactMap(nativeField).first
        }
        let text = field.object as? NSTextField ?? (field.object as? NSCell)?.controlView as? NSTextField ?? nativeField(host)
        text?.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: text))
        host.layoutSubtreeIfNeeded()
    }
}
