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

/// Project settings against the boards' measured geometry (ProjectLead-Settings*), pressed through accessibility on a real scratch
/// server: every control the four boards draw has the board's size and a hit area of at least 24pt, and pressing it sends the request
/// and leaves the state the board implies. No window is focused and no event is posted.
///
/// Each scenario runs in its own process (`ControlPress` attaches an assistive client to the whole process) and ends by printing the
/// shared sentinel (`completingScenario`), which the parent requires (`expectScenarioCompleted`): `processExitsWith: .success` alone
/// also passes a child that exited early with status 0. A native menu is chosen with `NativeMenuChoice`, which leaves its tracking
/// open, so a scenario chooses at most ONE menu item (a second menu never shows) and reads the saved record afterward.
private struct FidelityError: Error { let message: String; init(_ message: String) { self.message = message } }

/// `#require` throws `ExpectationFailedError`, which `recordingErrors` swallows, so a failed requirement in a child process would end the
/// scenario as a pass. This throws an error that is recorded as an issue.
private func need<T>(_ value: T?, _ message: @autoclosure () -> String = "a required value is missing") throws -> T {
    guard let value else { throw FidelityError(message()) }
    return value
}

@Suite("Project settings fidelity controls", .mainActorExclusive)
@MainActor
struct ProjectSettingsFidelityControlTests {
    // MARK: General

    @Test func generalSizesPauseResumeAndDeleteWork() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.general() } }
        expectScenarioCompleted(result)
    }

    @Test func threadsAtOnceOffersOneToSixAndSavesTheChoice() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.limit) } }
        expectScenarioCompleted(result)
    }

    @Test func theConversationModelOffersDefaultThenTheOwnersCatalogAndSavesTheChoice() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.conversationModel) } }
        expectScenarioCompleted(result)
    }

    @Test func theThreadModelSavesTheChoiceAndLeavesTheConversationModelAlone() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.threadModel) } }
        expectScenarioCompleted(result)
    }

    @Test func choosingDefaultClearsASavedModel() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.defaultModel) } }
        expectScenarioCompleted(result)
    }

    // MARK: Spaces, Memory, Automations

    @Test func spacesMemoryAndAutomationsControlsHaveTheBoardsSizesAndWork() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.lists() } }
        expectScenarioCompleted(result)
    }

    @Test func addASpaceOffersTheUnlinkedSpacesAndLinksTheChosenOne() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.addSpace) } }
        expectScenarioCompleted(result)
    }

    @Test func hostsOffersTheOwnersChoicesAndSavesTheChosenPolicy() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.hosts) } }
        expectScenarioCompleted(result)
    }

    @Test func thisMacOnlyReturnsAnyConnectedHostToTheOwnersHostAndKeepsItsList() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.menu(.thisMacOnly) } }
        expectScenarioCompleted(result)
    }

    // MARK: Text scale 1.3

    @Test func atTextScale1Point3EveryControlStaysWithinTheColumnAndAboveTheHitArea() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.scaled() } }
        expectScenarioCompleted(result)
    }

    // MARK: Narrow window

    @Test func inANarrowWindowLongTextWrapsTheToggleRowHoldsAndTheHostSurvivesAShortenedPath() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.narrow() } }
        expectScenarioCompleted(result)
    }

    // MARK: Edits

    @Test func goalCommitsAndMemorySaveAndRevertPersistWithTheBoardsHitAreas() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.edits() } }
        expectScenarioCompleted(result)
    }

    // MARK: Equal SpaceIDs on two hosts

    @Test func equalSpaceIDsOnTwoHostsShowEachHostsOwnSpaceAndRemoveTouchesOnlyTheChosenLink() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.crossHost(adding: false) } }
        expectScenarioCompleted(result)
    }

    @Test func addAcrossHostsOffersEachHostsSpacesByDestinationAndLinksOnTheChosenHost() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { try await Self.crossHost(adding: true) } }
        expectScenarioCompleted(result)
    }

    // MARK: Helpers

    enum Popup { case limit, conversationModel, threadModel, defaultModel, addSpace, hosts, thisMacOnly }

    /// Types into a field the way assistive technology does: sets its accessibility value, then tells the native editor's delegate,
    /// so SwiftUI's binding sees the text. Posts no event and takes no focus.
    fileprivate static func type(_ label: String, _ value: String, under host: NSView) throws {
        let field = try need(AccessibilityNode.all(under: host).first { $0.label == label && ["AXTextField", "AXTextArea"].contains($0.role ?? "") },
                             "\(label) is a text control")
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(field.object.responds(to: setter))
        field.object.perform(setter, with: value)
        func first<V: NSView>(_ type: V.Type, _ view: NSView, where match: (V) -> Bool) -> V? {
            if let found = view as? V, match(found) { return found }
            for sub in view.subviews { if let found = first(type, sub, where: match) { return found } }
            return nil
        }
        if field.role == "AXTextArea", let text = first(NSTextView.self, host, where: { _ in true }) {
            text.string = value
            text.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: text))
        } else if let text = first(NSTextField.self, host, where: { $0.stringValue == value }) {
            text.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: text))
        }
        host.layoutSubtreeIfNeeded()
    }

    /// Accessibility frames are whole points, so a width that comes from text (the board's 60.11 for General) reads within 1pt.
    fileprivate static func near(_ value: CGFloat, _ expected: CGFloat, _ what: String, tolerance: CGFloat = 0.6) {
        #expect(abs(value - expected) <= tolerance, "\(what) is \(value), the board draws \(expected)")
    }

    fileprivate static func control(_ window: OffscreenWindow, _ label: String) throws -> Control {
        try need(window.controls().first { $0.label == label }, "\(label) is a control")
    }

    /// A native menu button names itself by its tooltip.
    fileprivate static func popup(_ window: OffscreenWindow, _ help: String) throws -> AccessibilityNode {
        try need(AccessibilityNode.all(under: window.host).first { node in
            node.role == ControlRole.menuButton
                && (node.object.perform(NSSelectorFromString("accessibilityHelp"))?.takeUnretainedValue() as? String) == help
        }, "\(help) is a popup")
    }

    /// A scratch owner with one Project open on its settings page (1208 x 900, the main column of the boards' window).
    fileprivate static func page(spaces: [Space] = [], name: String = "Gamecards", goal: String = "", linked: [Space] = [], tab: LogicalProjectSettingsTab = .general,
                                 settings change: ((inout LogicalProjectSettings) -> Void)? = nil,
                                 _ body: @MainActor (AppHarness, ShepherdViewModel, OffscreenWindow, ProjectID) async throws -> Void) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: []))
        let id = ProjectID()
        guard case .project(var project) = try await app.server.logicalProjects(.create(projectID: id, name: name, goal: goal, linkedSpaceIDs: linked.map(\.id))) else {
            throw FidelityError("no project")
        }
        if let change {
            var settings = project.settings
            change(&settings)
            guard case .project(let next) = try await app.server.logicalProjects(.settings(projectID: id, expectedRevision: project.revision, settings: settings)) else {
                throw FidelityError("settings")
            }
            project = next
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == project.revision }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id), tab: tab)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        window.layout()
        try await body(app, vm, window, id)
    }

    fileprivate static func folder(_ app: AppHarness, _ name: String) throws -> Space {
        let url = app.dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return Fixture.space(name, path: url.path)
    }

    // MARK: General

    private static func general() async throws {
        try await page(goal: "Launch a gift card reseller API for game partners") { app, vm, window, id in
            try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil && window.element("Delete…") != nil }
            @MainActor func current() -> Project { app.server.state.projects[0] }

            // Sizes the boards' markup computes: tabs 34 tall (the 32pt label and its 2pt rule), General 60.1 wide and a 6pt gap to Spaces;
            // Pause, Delete… 28 tall at text + 22; the popups 32 tall.
            let general = try control(window, "General"), spaces = try control(window, "Spaces")
            near(general.frame.height, 34, "a tab's height"); near(general.frame.width, 60.1, "General's width", tolerance: 1)
            near(abs(spaces.frame.minX - general.frame.maxX), 6, "the gap between tabs")
            let pause = try control(window, "Pause"), delete = try control(window, "Delete…")
            near(pause.frame.height, 28, "Pause's height"); near(pause.frame.width, 57.9, "Pause's width", tolerance: 1)
            near(delete.frame.height, 28, "Delete…'s height"); near(delete.frame.width, 68.1, "Delete…'s width", tolerance: 1)
            for name in ["Conversation model", "Thread model", "Threads at once"] {
                let node = try popup(window, name)
                near(node.frame.height, 32, "\(name)'s height")
                #expect(node.isEnabled, "\(name) is enabled")
                #expect(node.frame.height >= HitArea.desktop.minimum, "\(name) clears the 24pt hit area")
            }
            let goal = try need(AccessibilityNode.all(under: window.host).first { $0.label == "Goal" && ["AXTextField", "AXTextArea"].contains($0.role ?? "") })
            near(goal.frame.width, 320, "the Goal field's width"); near(goal.frame.height, 36.75, "the Goal field's height")
            for control in [general, spaces, pause, delete] {
                #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(control) is under 24pt")
            }
            // The row says only what the board says: the retained-files sentence lives in the confirmation, not the row.
            let words = AccessibilityNode.all(under: window.host).compactMap { $0.value ?? $0.label }
            #expect(!words.contains { $0.contains("files stay on") }, "the Delete row's help ends at 'untouched.'")
            #expect(words.contains { $0.contains("branches and PRs are untouched.") })

            // Pause and Resume send setPaused; the button and its help change with the state.
            try window.press("Pause")
            try await eventuallyOnMain("paused") { current().paused }
            try await eventuallyOnMain("Resume shows") { window.layout(); return window.element("Resume") != nil }
            let resume = try control(window, "Resume")
            #expect(ControlPress.undersized([resume], minimum: .desktop).isEmpty)
            try window.press("Resume")
            try await eventuallyOnMain("resumed") { !current().paused }

            // Delete… opens the confirmation (which says the files stay); Cancel keeps the project; confirming removes only the record.
            let kept = app.dir.appendingPathComponent("logical-projects/\(id.rawValue)")
            try await eventuallyOnMain("Delete… is back") { window.layout(); return window.element("Delete…") != nil }
            try window.press("Delete…")
            try await eventuallyOnMain("confirmation") { window.layout(); return window.window.attachedSheet?.contentView != nil }
            let sheet = try need(window.window.attachedSheet?.contentView)
            sheet.layoutSubtreeIfNeeded()
            #expect(AccessibilityNode.all(under: sheet).compactMap { $0.value ?? $0.label }.contains { $0.contains("files stay on") })
            try ControlPress.press("Cancel", under: sheet)
            try await eventuallyOnMain("cancel closes") { window.window.attachedSheet == nil }
            #expect(app.server.state.projects.count == 1)
            try window.press("Delete…")
            try await eventuallyOnMain("confirmation again") { window.layout(); return window.window.attachedSheet?.contentView != nil }
            try ControlPress.press("Delete project", under: try need(window.window.attachedSheet?.contentView))
            try await eventuallyOnMain("record removed") { app.server.state.projects.isEmpty }
            #expect(FileManager.default.fileExists(atPath: kept.path), "the project's directory is retained")
        }
    }

    /// One native menu, chosen as the scenario's last interaction (see the note on this suite), then the saved record is read.
    fileprivate static func menu(_ which: Popup) async throws {
        let catalog = ScratchServer.standInModels.models
        switch which {
        case .limit:
            try await page { app, _, window, _ in
                try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }
                #expect(app.server.state.projects[0].settings.maxConcurrentWorkers == 3, "a new project defaults to three threads at once")
                let counts = try await NativeMenuChoice.choose("5", from: try popup(window, "Threads at once"))
                #expect(counts == ["1", "2", "3", "4", "5", "6"], "threads at once is 1 to 6: \(counts)")
                try await eventuallyOnMain("limit saved") { app.server.state.projects[0].settings.maxConcurrentWorkers == 5 }
            }
        case .conversationModel:
            try await page { app, _, window, _ in
                try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }
                let offered = try await NativeMenuChoice.choose(try need(catalog.first), from: try popup(window, "Conversation model"))
                #expect(offered == ["Default"] + catalog, "the owner's own catalog, Default first: \(offered)")
                try await eventuallyOnMain("conversation model saved") { app.server.state.projects[0].settings.conversationModel == catalog.first }
                #expect(app.server.state.projects[0].settings.threadModel == nil, "choosing the conversation model leaves the thread model alone")
            }
        case .threadModel:
            try await page(settings: { $0.conversationModel = catalog.first }) { app, _, window, _ in
                try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }
                _ = try await NativeMenuChoice.choose(try need(catalog.last), from: try popup(window, "Thread model"))
                try await eventuallyOnMain("thread model saved") { app.server.state.projects[0].settings.threadModel == catalog.last }
                #expect(app.server.state.projects[0].settings.conversationModel == catalog.first, "choosing the thread model leaves the conversation model alone")
            }
        case .defaultModel:
            try await page(settings: { $0.conversationModel = catalog.first }) { app, _, window, _ in
                try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }
                _ = try await NativeMenuChoice.choose("Default", from: try popup(window, "Conversation model"))
                try await eventuallyOnMain("Default clears it") { app.server.state.projects[0].settings.conversationModel == nil }
            }
        case .addSpace:
            try await pageWithSpaces(tab: .spaces) { app, vm, window, id, spaces in
                try await eventuallyOnMain("Spaces") { window.layout(); return window.element("Remove \(spaces[0].name)") != nil }
                let choices = try await NativeMenuChoice.choose(spaces[1].name, from: try popup(window, "Add a space…"))
                #expect(choices == [spaces[1].name], "the menu offers the owner's unlinked Spaces: \(choices)")
                try await eventuallyOnMain("linked on the owner") {
                    Set(app.server.state.projects[0].linkedSpaces.map(\.spaceID)) == Set(spaces.map(\.id))
                }
                #expect(app.server.state.projects[0].linkedSpaces.allSatisfy { $0.destination == .local }, "a local choice links on this Mac")
            }
        case .hosts:
            try await pageWithSpaces(tab: .spaces) { app, _, window, _, _ in
                try await eventuallyOnMain("Spaces") { window.layout(); return window.element("The project can add spaces") != nil }
                // The toggle first, then the one menu.
                let toggle = try control(window, "The project can add spaces")
                #expect(ControlPress.undersized([toggle], minimum: .desktop).isEmpty, "the switch is \(toggle.frame.size)")
                try window.press("The project can add spaces", role: toggle.role)
                try await eventuallyOnMain("toggle saved") { app.server.state.projects[0].settings.canRequestSpaceLinks == false }
                try await eventuallyOnMain("Hosts is a popup") { window.layout(); return (try? popup(window, "Hosts").isEnabled) == true }
                let saved = app.server.state.projects[0].settings
                #expect(saved.hostPolicy == .selected && saved.allowedHosts == [.local], "a new project runs on its owner only")
                let choices = try await NativeMenuChoice.choose("Any connected host", from: try popup(window, "Hosts"))
                #expect(choices == ["This Mac only", "Any connected host"], "no other host is connected, so two choices: \(choices)")
                try await eventuallyOnMain("hosts saved") { app.server.state.projects[0].settings.hostPolicy == .anyConnected }
                #expect(app.server.state.projects[0].settings.allowedHosts == [.local], "the saved hosts are kept")
                try await eventuallyOnMain("the row says so") { window.layout(); return window.elements().contains { $0.value == "Any connected host" } }
            }
        case .thisMacOnly:
            try await page(tab: .spaces, settings: { $0.hostPolicy = .anyConnected }) { app, _, window, _ in
                try await eventuallyOnMain("Hosts shows the saved policy") {
                    window.layout(); return window.elements().contains { $0.value == "Any connected host" }
                }
                _ = try await NativeMenuChoice.choose("This Mac only", from: try popup(window, "Hosts"))
                try await eventuallyOnMain("this Mac only saved") {
                    app.server.state.projects[0].settings.hostPolicy == .selected && app.server.state.projects[0].settings.allowedHosts == [.local]
                }
            }
        }
    }

    /// A project that already has its first Space linked, with a second Space the owner can offer.
    private static func pageWithSpaces(tab: LogicalProjectSettingsTab, _ body: @MainActor (AppHarness, ShepherdViewModel, OffscreenWindow, ProjectID, [Space]) async throws -> Void) async throws {
        AccessibilityNode.enable()
        let probe = try AppHarness()
        probe.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { probe.stop() }
        let spaces = [try folder(probe, "gamecards-api"), try folder(probe, "research")]
        let vm = try await probe.start(with: Fixture.state(spaces: spaces, agents: []))
        let id = ProjectID()
        guard case .project(let project) = try await probe.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: [spaces[0].id])) else {
            throw FidelityError("no project")
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == project.revision }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id), tab: tab)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        window.layout()
        try await body(probe, vm, window, id, spaces)
    }

    /// Text scale 1.3 (Settings > Appearance): the controls grow with the text, none is under 24pt, and none leaves the window.
    private static func scaled() async throws {
        ThemeStore.shared.textScale = 1.3
        try await page(goal: "Launch a gift card reseller API for game partners, with sandbox keys and a prepaid balance") { app, _, window, _ in
            try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }
            for name in ["General", "Spaces", "Memory", "Automations", "Pause", "Delete…"] {
                let control = try control(window, name)
                #expect(ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size) at 1.3")
            }
            for name in ["Conversation model", "Thread model", "Threads at once"] {
                let node = try popup(window, name)
                #expect(node.frame.height >= HitArea.desktop.minimum, "\(name) is \(node.frame.size) at 1.3")
            }
            // Every control sits inside the window, so nothing is pushed off the card's right side.
            let screen = window.window.frame
            for control in window.controls() where control.frame.width > 0 {
                #expect(control.frame.minX >= screen.minX - 1 && control.frame.maxX <= screen.maxX + 1, "\(control) leaves the window at 1.3")
            }
        }
    }

    // MARK: Spaces, Memory, Automations

    private static func lists() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let spaces = [try folder(app, "gamecards-api"), try folder(app, "research")]
        let vm = try await app.start(with: Fixture.state(spaces: spaces, agents: []))
        let id = ProjectID(), automation = AutomationID()
        guard case .project(var project) = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: spaces.map(\.id))) else {
            throw FidelityError("no project")
        }
        for text in ["Partners take the payment and draw on a prepaid balance (you decided, Oct 9).", "Gaming card margins are thin."] {
            guard case .project(let next) = try await app.server.logicalProjects(
                .addMemory(projectID: id, expectedRevision: project.revision, memoryID: ProjectMemoryID(), text: text, source: "you")) else { throw FidelityError("memory") }
            project = next
        }
        guard case .project(let withAutomation) = try await app.server.logicalProjects(
            .automation(projectID: id, expectedRevision: project.revision, automationID: automation,
                        action: .create(draft: RemoteAutomationDraft(name: "Weekly market scan", prompt: "Scan the market", cwd: spaces[1].path, enabled: false)))) else {
            throw FidelityError("automation")
        }
        project = withAutomation
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == project.revision && vm.state.automations.contains { $0.id == automation } }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id), tab: .spaces)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        @MainActor func current() -> Project { app.server.state.projects[0] }

        // Spaces: Remove is the ghost 28pt button at text + 22; Add a space… is a 32pt popup; the toggle is the 30 x 18 switch in a 24pt slot.
        try await eventuallyOnMain("Spaces") { window.layout(); return window.element("Remove gamecards-api") != nil && window.element("Remove research") != nil }
        let remove = try control(window, "Remove gamecards-api")
        near(remove.frame.height, 28, "Remove's height"); near(remove.frame.width, 69.2, "Remove's width", tolerance: 1)
        #expect(ControlPress.undersized([remove], minimum: .desktop).isEmpty, "Remove is \(remove.frame.size)")
        near(try popup(window, "Hosts").frame.height, 32, "Hosts' height")
        try window.press("Remove research")
        try await eventuallyOnMain("unlinked") { current().linkedSpaces.map(\.spaceID) == [spaces[0].id] }
        try await eventuallyOnMain("Add a space… is enabled again") { window.layout(); return (try? popup(window, "Add a space…").isEnabled) == true }
        near(try popup(window, "Add a space…").frame.height, 32, "Add a space…'s height")

        // Memory: Forget is the same ghost button; the counter reads the real text.
        vm.logicalProjectSettingsTab = .memory
        try await eventuallyOnMain("Memory") { window.layout(); return window.element("Forget: Gaming card margins are thin.") != nil }
        let forget = try control(window, "Forget: Gaming card margins are thin.")
        near(forget.frame.height, 28, "Forget's height"); near(forget.frame.width, 60.2, "Forget's width", tolerance: 1)
        #expect(ControlPress.undersized([forget], minimum: .desktop).isEmpty, "Forget is \(forget.frame.size)")
        try window.press("Forget: Gaming card margins are thin.")
        try await eventuallyOnMain("forgotten") { current().memory.count == 1 }

        // Automations: the switch is a real toggle that enables through the owner, and it never runs anything.
        vm.logicalProjectSettingsTab = .automations
        try await eventuallyOnMain("Automations") { window.layout(); return window.element("Run Weekly market scan") != nil }
        let words = AccessibilityNode.all(under: window.host).compactMap { $0.value ?? $0.label }
        #expect(words.contains { $0.contains("Scan the market") && $0.contains("research") && $0.contains("This Mac") && $0.contains("never run") },
                "caption: \(words.filter { $0.contains("Scan") })")
        let run = try control(window, "Run Weekly market scan")
        #expect(ControlPress.undersized([run], minimum: .desktop).isEmpty, "the switch is \(run.frame.size)")
        try window.press("Run Weekly market scan", role: run.role)
        try await eventuallyOnMain("enabled") { app.server.state.automations.first { $0.id == automation }?.enabled == true }
        #expect(app.server.state.agents.isEmpty && app.server.state.automations.first?.agentID == nil, "enabling starts nothing")
    }

    // MARK: Edits

    /// Goal: typing alone saves nothing; the field's commit does, as one revisioned edit that keeps the name. Memory: Save writes the
    /// instructions, Revert restores the saved text. Every control is at least 24pt and nothing is pressed with a posted event.
    private static func edits() async throws {
        try await page(goal: "Launch") { app, _, window, _ in
            @MainActor func current() -> Project { app.server.state.projects[0] }
            try await eventuallyOnMain("the page") { window.layout(); return window.element("Pause") != nil }

            // Goal. Typing is not committing.
            let revision = current().revision
            try type("Goal", "Launch a gift card reseller API", under: window.host)
                #expect(current().goal == "Launch" && current().revision == revision, "typing alone saves nothing")
            // Commit without an event, through the field's own accessibility path: `accessibilityPerformConfirm`, the action VoiceOver's
            // Return performs on a text field. Measured on this macOS, SwiftUI's field runs `onSubmit` for it but returns false, so the
            // result is read from the persisted record, never from the return value. Typing alone was shown above to save nothing, so
            // the save is the confirm's.
            let goal = try need(AccessibilityNode.all(under: window.host).first { $0.label == "Goal" && $0.role == "AXTextField" })
            #expect(goal.frame.height >= 24 && goal.frame.width >= 24, "the Goal field is \(goal.frame.size)")
            typealias Call = @convention(c) (AnyObject, Selector) -> Bool
            let confirm = NSSelectorFromString("accessibilityPerformConfirm")
            _ = try need(goal.object.responds(to: confirm) ? true : nil, "the Goal field offers AXConfirm")
            _ = unsafeBitCast(goal.object.method(for: confirm), to: Call.self)(goal.object, confirm)
            try await eventuallyOnMain("goal saved by AXConfirm") { current().goal == "Launch a gift card reseller API" }
            #expect(current().revision > revision && current().name == "Gamecards", "one revisioned edit that keeps the name")

            // Memory: Save and Revert only exist while the text differs, and Save writes the instructions.
            try window.press("Memory")
            try await eventuallyOnMain("Memory") { window.layout(); return window.element("Project instructions") != nil }
            #expect(window.element("Save") == nil && window.element("Revert") == nil, "neither shows while the text is saved")
            try type("Project instructions", "Ask before money moves.", under: window.host)
            try await eventuallyOnMain("Save and Revert appear") { window.layout(); return window.element("Save") != nil && window.element("Revert") != nil }
            for name in ["Save", "Revert"] {
                let control = try need(window.controls().first { $0.label == name })
                #expect(control.isEnabled && ControlPress.undersized([control], minimum: .desktop).isEmpty, "\(name) is \(control.frame.size)")
                near(control.frame.height, 28, "\(name)'s height")
            }
            try window.press("Revert")
            try await eventuallyOnMain("Revert hides both") { window.layout(); return window.element("Save") == nil }
            #expect(current().settings.instructions.isEmpty, "Revert saved nothing")
            try type("Project instructions", "Ask before money moves.", under: window.host)
            try await eventuallyOnMain("Save is back") { window.layout(); return window.element("Save") != nil }
            let beforeSave = current().revision
            try window.press("Save")
            try await eventuallyOnMain("instructions saved") { current().settings.instructions == "Ask before money moves." }
            #expect(current().revision > beforeSave)
            try await eventuallyOnMain("Save hides once saved") { window.layout(); return window.element("Save") == nil }
            #expect(window.elements().contains { ($0.label ?? $0.value ?? "").contains("23 of 16,000 characters") }, "the counter reads the saved text")
        }
    }

    // MARK: Narrow window

    /// The shell's narrowest window (`AppLayout.windowMinWidth`, 720pt, so the main column is about 490pt beside the sidebar) at text
    /// scale 1.3 with a Space whose path and host name are long: the rows wrap, the "The project can add spaces"
    /// row's text wraps beside its switch (which keeps its 30 x 24pt slot and stays inside the window), Remove keeps its hit area, and the
    /// host's name is still on the row after the path is shortened.
    private static func narrow() async throws {
        AccessibilityNode.enable()
        ThemeStore.shared.textScale = 1.3
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let shared = SpaceID(rawValue: UUID().uuidString.lowercased())
        let theirs = Space(id: shared, name: "payments-api-for-the-reseller-storefront", path: "/srv/payments/api/for/the/reseller/storefront/and/its/sandbox/keys")
        let host = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let hostName = "build-machine-in-the-office-basement"
        let vm = try await app.start(with: Fixture.state(spaces: [], agents: []))
        app.server.setProjectEligibleHosts([.local, host])
        app.server.setProjectExecutionSpaces([host: [theirs]])
        vm.logicalProjects.ownerHosts = { _ in [ProjectHostOption(reference: .local, name: "This Mac"), ProjectHostOption(reference: host, name: hostName, spaces: [theirs])] }
        let id = ProjectID()
        guard case .project(let created) = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: [])),
              case .project(let linked) = try await app.server.logicalProjects(.linkSpace(projectID: id, expectedRevision: created.revision, spaceID: shared, host: host)) else {
            throw FidelityError("the owner refused the link")
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == linked.revision }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id), tab: .spaces)
        let window = OffscreenWindow(size: CGSize(width: AppLayout.windowMinWidth, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let remove = "Remove \(theirs.name) on \(hostName)"
        try await eventuallyOnMain("the row") { window.layout(); return window.element(remove) != nil && window.element("The project can add spaces") != nil }

        // The host's name is on the row (the row's label reads path and host), whatever the path was shortened to.
        let words = AccessibilityNode.all(under: window.host).compactMap { $0.value ?? $0.label }
        #expect(words.contains { $0.contains(hostName) && $0.contains("/srv/payments") }, "the row names its host and its path: \(words.filter { $0.contains("srv") })")
        // Remove: its hit area, and it stays inside the window.
        let removeControl = try control(window, remove)
        #expect(ControlPress.undersized([removeControl], minimum: .desktop).isEmpty, "Remove is \(removeControl.frame.size) at 1.3")
        // The switch: its 24pt hit area, inside the window, and its row's title and help wrapped rather than pushed it off.
        let toggle = try control(window, "The project can add spaces")
        #expect(ControlPress.undersized([toggle], minimum: .desktop).isEmpty, "the switch is \(toggle.frame.size)")
        // Every control is inside the window's own frame (the window sits far off screen, so its frame, not 0...520, is the bound).
        let frame = window.window.frame
        // The shell's own "Show sidebar" button belongs to the sidebar lane; this checks the Settings page's controls.
        let page = window.controls().filter { $0.label != "Show sidebar" }
        let outside = page.filter { $0.frame.minX < frame.minX - 1 || $0.frame.maxX > frame.maxX + 1 }
        let rows = AccessibilityNode.all(under: window.host).filter { $0.frame.width > 560 }.map { "\($0.role ?? "?") \(($0.label ?? $0.value ?? "-").prefix(40)) w\(Int($0.frame.width)) x\(Int($0.frame.minX - frame.minX))" }
        let extents = (page.map { "\($0.label?.prefix(14) ?? "?") x \(Int($0.frame.minX - frame.minX))..\(Int($0.frame.maxX - frame.minX))" }) + ["WIDE:"] + rows
        #expect(outside.isEmpty, "window \(frame.minX)..\(frame.maxX) (w \(frame.width)), host \(window.host.frame.width): \(extents)")
        // And it is still a working switch and a working Remove, by press.
        try window.press("The project can add spaces", role: toggle.role)
        try await eventuallyOnMain("toggle saved") { app.server.state.projects[0].settings.canRequestSpaceLinks == false }
        try window.press(remove)
        try await eventuallyOnMain("removed from its own host") { app.server.state.projects[0].linkedSpaces.isEmpty }
    }

    // MARK: Equal SpaceIDs on two hosts

    /// One SpaceID on this Mac and on a second host, with different names and paths on each. The owner (a real server) holds both as
    /// links; the page shows each against its own host. `adding: false` presses Remove on the remote row, then the local one, and checks
    /// that each removed only its own (destination, SpaceID). `adding: true` chooses the other host's other Space from Add a space… (the
    /// scenario's one menu) and checks it linked on that host and not on this Mac. Nothing is inferred from an equal ID, name or path.
    fileprivate static func crossHost(adding: Bool) async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { app.stop() }
        let shared = SpaceID(rawValue: UUID().uuidString.lowercased())
        let mineFolder = app.dir.appendingPathComponent("payments")
        try FileManager.default.createDirectory(at: mineFolder, withIntermediateDirectories: true)
        let mine = Space(id: shared, name: "payments", path: mineFolder.path)
        let theirs = Space(id: shared, name: "payments-api", path: "/srv/payments")
        let other = Space(id: SpaceID(rawValue: UUID().uuidString.lowercased()), name: "reports", path: "/srv/reports")
        let host = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let vm = try await app.start(with: Fixture.state(spaces: [mine], agents: []))
        // The owner's own inventory of the second host: the one its validation and the page both read.
        // A third host the owner linked while it was connected and no longer lists (its link stays, honestly named).
        let gone = ProjectHostReference.remote(hostID: UUID(), bindingID: UUID())
        let lost = Space(id: SpaceID(rawValue: UUID().uuidString.lowercased()), name: "lost", path: "/srv/lost")
        app.server.setProjectEligibleHosts([.local, host, gone])
        app.server.setProjectExecutionSpaces([host: [theirs, other], gone: [lost]])
        let options = [ProjectHostOption(reference: .local, name: "This Mac"), ProjectHostOption(reference: host, name: "build-01", spaces: [theirs, other])]
        vm.logicalProjects.ownerHosts = { _ in options }
        let id = ProjectID()
        guard case .project(let created) = try await app.server.logicalProjects(.create(projectID: id, name: "Gamecards", goal: "", linkedSpaceIDs: [shared])) else {
            throw FidelityError("no project")
        }
        guard case .project(var project) = try await app.server.logicalProjects(.linkSpace(projectID: id, expectedRevision: created.revision, spaceID: shared, host: host)) else {
            throw FidelityError("the owner refused the remote link")
        }
        if !adding {
            guard case .project(let withGone) = try await app.server.logicalProjects(.linkSpace(projectID: id, expectedRevision: project.revision, spaceID: lost.id, host: gone)) else {
                throw FidelityError("the owner refused the disconnected host's link")
            }
            project = withGone
            guard case .project(let both) = try await app.server.logicalProjects(.linkSpace(projectID: id, expectedRevision: project.revision, spaceID: other.id, host: host)) else {
                throw FidelityError("the owner refused the second remote link")
            }
            project = both
        }
        @MainActor func current() -> Project { app.server.state.projects[0] }
        #expect(Set(current().linkedSpaces.filter { $0.spaceID == shared }.map(\.destination)) == [.local, host], "the same SpaceID is linked on both hosts")
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == project.revision }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: id), tab: .spaces)
        let window = OffscreenWindow(size: CGSize(width: 1208, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }

        // Each row is its own host's Space: the name, the path and the host on its own machine, never the owner's Space with that ID.
        try await eventuallyOnMain("both rows") { window.layout(); return window.element("Remove payments-api on build-01") != nil && window.element("Remove payments") != nil }
        let words = AccessibilityNode.all(under: window.host).compactMap { $0.value ?? $0.label }
        #expect(words.contains { $0 == "payments-api" } && words.contains { $0.contains("/srv/payments") && $0.contains("build-01") }, "\(words)")
        #expect(words.contains { $0 == "payments" } && words.contains { $0.hasSuffix("· This Mac") && $0.contains("payments") }, "\(words)")
        #expect(!words.contains { $0.contains("payments-api") && $0.contains("This Mac") }, "the remote Space is never drawn on this Mac")
        for name in ["Remove payments", "Remove payments-api on build-01"] {
            let remove = try control(window, name)
            #expect(ControlPress.undersized([remove], minimum: .desktop).isEmpty, "\(name) is \(remove.frame.size)")
        }

        if adding {
            // Add offers the other host's other Space by its destination, and not the pairs that are already linked.
            let offered = try await NativeMenuChoice.choose("reports on build-01", from: try popup(window, "Add a space…"))
            #expect(offered == ["reports on build-01"], "only unlinked (destination, SpaceID) pairs are offered: \(offered)")
            try await eventuallyOnMain("linked on the chosen host") { current().linkedSpaces.contains { $0.spaceID == other.id && $0.destination == host } }
            #expect(!current().linkedSpaces.contains { $0.spaceID == other.id && $0.destination == .local }, "never linked on this Mac")
            #expect(current().linkedSpaces.filter { $0.spaceID == shared }.count == 2, "the existing links stay")
            return
        }
        // The host the owner no longer lists is an honest row, not this Mac's or another host's Space, and its Remove unlinks only it.
        let goneRemove = "Remove A space on a host that is not connected on an unknown host"
        try await eventuallyOnMain("the disconnected host's row") { window.layout(); return window.element(goneRemove) != nil }
        try window.press(goneRemove)
        try await eventuallyOnMain("disconnected link removed") { !current().linkedSpaces.contains { $0.spaceID == lost.id } }
        #expect(current().linkedSpaces.count == 3, "the other three links stay")
        // Remove on the remote row removes only that destination's link.
        try window.press("Remove payments-api on build-01")
        try await eventuallyOnMain("remote link removed") { !current().linkedSpaces.contains { $0.spaceID == shared && $0.destination == host } }
        #expect(current().linkedSpaces.contains { $0.spaceID == shared && $0.destination == .local }, "this Mac's link with the same SpaceID stays")
        #expect(current().linkedSpaces.contains { $0.spaceID == other.id && $0.destination == host }, "the other remote link stays")
        // And the local row removes only the local pair.
        try await eventuallyOnMain("local row still drawn") { window.layout(); return window.element("Remove payments") != nil }
        try window.press("Remove payments")
        try await eventuallyOnMain("local link removed") { !current().linkedSpaces.contains { $0.spaceID == shared } }
        #expect(current().linkedSpaces.map(\.spaceID) == [other.id] && current().linkedSpaces[0].destination == host)
    }
}
