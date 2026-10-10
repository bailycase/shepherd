import Foundation
import SwiftUI
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
@testable import ShepherdApp

/// Project settings (ProjectLead-SettingsGeneral, -SpacesV2, -Memory, -Automations) rendered from the real producers: a scratch
/// server that really holds the project, its linked Spaces (one the person added, one the project proposed and the person accepted),
/// its memory and its owned Automation records, with real run history in the run log. Each tab renders normal, empty and long,
/// light and dark, at text scale 1 and 1.3. Own suite so the conversation previews stay another writer's file. Set
/// `SHEPHERD_PREVIEW_SCALE=2` to capture at the boards' 2px per point and diff them pixel for pixel.
@Suite("Project settings fidelity previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct ProjectSettingsFidelityPreviewTests {
    private static let size = CGSize(width: 1208, height: 900)

    private static let remembered = [
        "Partners take the payment and draw on a prepaid balance (you decided, Oct 9).",
        "Gaming card margins are thin, about 1–3%, so card fees matter.",
        "Mockups go to the project’s files as single HTML pages.",
    ]
    private static let instructions = "Gamecards resells game gift cards through partner sites.\n- API work goes in gamecards-api, the widget in gamecards-web.\n- Mockups are single HTML pages in the project’s files.\n- Ask before anything that moves money, even in a sandbox."

    /// The run log's file, as the host keeps it, written before the server starts so its first load finds real history.
    private struct RunFile: Encodable {
        var version = 1
        var runs: [String: [AutomationRun]]
    }

    private enum Fill { case normal, empty, long }

    /// The owner's second host, as its own host list reports it (`ProjectHostOption`): a name and the owner-relative binding.
    private static let secondHost = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "build-01")

    /// One workspace: `fill` decides how much the real record holds.
    /// `hosts`: the owner knows a second host and the project is allowed on both (the designed normal Hosts row); false is the
    /// owner reporting only itself, or nothing at all (`unknown`), and the project's saved hosts stay This Mac.
    private func world(_ fill: Fill, hosts: Bool = false) async throws -> (PreviewWorkspace, LogicalProjectRef) {
        // Real run history for the first Automation, in the run log the host reads when it starts: 3 days ago it finished.
        let dir = try makeScratchDirectory("psf")
        let automations = [AutomationID(), AutomationID()]
        if fill != .empty {
            let start = Date().addingTimeInterval(-3 * 86_400).timeIntervalSince1970
            let file = RunFile(runs: [automations[0].rawValue: [AutomationRun(startedAt: start, settledAt: start + 40, endedAt: start + 45, result: .finished)]])
            try JSONEncoder().encode(file).write(to: dir.appendingPathComponent("automation-runs.json"))
        }
        let world = try PreviewWorkspace(dir: dir)
        world.settings.projectsEnabled = true  // Projects is an opt-in experiment
        let names = ["payments", "dashboard-web", "shepherd", "gamecards-api", "gamecards-web", "research"]
        var spaces: [Space] = []
        for name in names {
            let url = world.dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            spaces.append(Space(name: name, path: url.path))
        }
        try await world.seed(ShepherdState(spaces: spaces))
        let long = fill == .long
        let name = long ? "Gamecards, the partner API and the reseller storefront, launched together" : "Gamecards"
        let goal = fill == .empty ? "" : long ? "Launch a gift card reseller API for game partners, with sandbox keys, a prepaid balance and a reconciliation report that finance can read" : "Launch a gift card reseller API for game partners"
        guard case .project(var project) = try await world.server.logicalProjects(.create(projectID: ProjectID(), name: name, goal: goal, linkedSpaceIDs: [])) else {
            throw PreviewFixtureError("the server did not return a project")
        }
        let vm = world.vm
        try await eventuallyOnMain("the project arrives") { vm.state.projects.count == 1 }
        if fill != .empty {
            let linked = long ? ["gamecards-api", "gamecards-web", "research"] : ["gamecards-api"]
            for space in linked {
                let id = try #require(spaces.first { $0.name == space }?.id)
                guard case .project(let next) = try await world.server.logicalProjects(.linkSpace(projectID: project.id, expectedRevision: project.revision, spaceID: id)) else { throw PreviewFixtureError("link") }
                project = next
            }
            // Two more links the way the owner makes them: the project proposes a Space, the person accepts it.
            for space in (long ? [] : ["gamecards-web", "research"]) {
                let id = try #require(spaces.first { $0.name == space }?.id)
                let operation = UUID()
                _ = try await vm.projectCoordinator.perform(projectID: project.id, expectedRevision: project.revision,
                                                           request: .proposeSpace(operationID: operation, path: nil, spaceID: id, originTaskID: nil))
                try await eventuallyOnMain("the proposal is pending") { vm.state.projects.first?.spaceProposals.contains { $0.id == operation && $0.phase == .pending } == true }
                let proposal = try #require(vm.state.projects.first?.spaceProposals.first { $0.id == operation })
                #expect(await vm.logicalProjects.decideSpace(LogicalProjectRef(home: .local, id: project.id), proposal: proposal, accept: true))
                try await eventuallyOnMain("the link is recorded") { vm.state.projects.first?.linkedSpaces.contains { $0.spaceID == id } == true }
                project = try #require(vm.state.projects.first)
            }
            for text in Self.remembered + (long ? [String(repeating: "A long note the project kept so the row has to wrap onto a second line and a third, because what people write is longer than the board. ", count: 2)] : []) {
                guard case .project(let next) = try await world.server.logicalProjects(
                    .addMemory(projectID: project.id, expectedRevision: project.revision, memoryID: ProjectMemoryID(), text: text, source: "you")) else { throw PreviewFixtureError("memory") }
                project = next
            }
            var settings = project.settings
            settings.instructions = Self.instructions + (long ? "\n" + String(repeating: "- Another standing rule that runs long enough to wrap in the editor. ", count: 6) : "")
            settings.conversationModel = "claude-sonnet-4-6"
            if hosts {
                world.server.setProjectEligibleHosts([.local, Self.secondHost.reference])
                try await Task.sleep(for: .milliseconds(100))
                settings.allowedHosts = [.local, Self.secondHost.reference]
            }
            settings.threadModel = long ? "claude-opus-4-6-with-a-very-long-model-name-from-the-catalog" : "claude-opus-4-6"
            guard case .project(let next) = try await world.server.logicalProjects(.settings(projectID: project.id, expectedRevision: project.revision, settings: settings)) else { throw PreviewFixtureError("settings") }
            project = next
            // Owned Automation records through the owner's own API, one enabled and one not.
            for (index, title) in [long ? "Weekly market scan across every partner marketplace we resell on" : "Weekly market scan", "Review API PRs"].enumerated() {
                let draft = RemoteAutomationDraft(name: title, prompt: index == 0 ? "Scan the partner marketplaces and report price moves" : "Review each new pull request against the API guide",
                                                  cwd: spaces[index == 0 ? 5 : 3].path, enabled: index == 0)
                guard case .project(let next) = try await world.server.logicalProjects(
                    .automation(projectID: project.id, expectedRevision: project.revision, automationID: automations[index], action: .create(draft: draft))) else { throw PreviewFixtureError("automation") }
                project = next
            }
        }
        try await eventuallyOnMain("the record is adopted") { vm.state.projects.first?.revision == project.revision }
        if hosts {
            let local = ProjectHostOption(reference: .local, name: "This Mac")
            vm.logicalProjects.ownerHosts = { _ in [local, Self.secondHost] }
        }
        return (world, LogicalProjectRef(home: .local, id: project.id))
    }

    private func render(_ fill: Fill, _ tab: LogicalProjectSettingsTab, hosts: Bool = false, name: String? = nil) async throws {
        let (world, ref) = try await world(fill, hosts: hosts)
        defer { world.stop() }
        let vm = world.vm
        vm.openLogicalProjectSettings(ref, tab: tab)
        // The Automations caption reads real run history: the owner's run log, read once the page asks for it.
        let ready: @MainActor () -> Bool = { vm.logicalProjects.project(ref) != nil }
        try await Preview.renderMatrix("settings-\(tab.rawValue.lowercased())-\(name ?? "\(fill)")", size: Self.size, ready: ready) {
            LogicalProjectSettingsDestination(vm: vm).background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: [LogicalProjectSettingsTab.general, .spaces, .memory, .automations])
    func normal(tab: LogicalProjectSettingsTab) async throws { try await render(.normal, tab, hosts: true) }

    /// The owner reports only itself (a second host is disconnected or unknown): the Hosts row reads This Mac only. The saved
    /// record is the same as the normal one, so only what the owner says about hosts differs.
    @Test func spacesWithoutASecondHost() async throws { try await render(.normal, .spaces, name: "single-host") }

    /// Equal SpaceIDs on two hosts, from the owner's own inventory: this Mac's `payments` and build-01's `payments-api` share one ID, and
    /// both are linked. Each row is drawn against its own host; the caption names exactly one host, as the link holds exactly one.
    @Test func spacesLinkedOnTwoHostsWithOneSpaceID() async throws {
        let world = try PreviewWorkspace()
        world.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { world.stop() }
        let shared = SpaceID(rawValue: UUID().uuidString.lowercased())
        let folder = world.dir.appendingPathComponent("payments")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mine = Space(id: shared, name: "payments", path: folder.path)
        let theirs = Space(id: shared, name: "payments-api", path: "/srv/payments/api")
        try await world.seed(ShepherdState(spaces: [mine]))
        world.server.setProjectEligibleHosts([.local, Self.secondHost.reference])
        world.server.setProjectExecutionSpaces([Self.secondHost.reference: [theirs]])
        let vm = world.vm
        guard case .project(let created) = try await world.server.logicalProjects(.create(projectID: ProjectID(), name: "Gamecards", goal: "", linkedSpaceIDs: [shared])),
              case .project(let both) = try await world.server.logicalProjects(
                .linkSpace(projectID: created.id, expectedRevision: created.revision, spaceID: shared, host: Self.secondHost.reference)) else {
            throw PreviewFixtureError("the owner refused the links")
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == both.revision }
        let local = ProjectHostOption(reference: .local, name: "This Mac")
        let remote = ProjectHostOption(reference: Self.secondHost.reference, name: Self.secondHost.name, spaces: [theirs])
        vm.logicalProjects.ownerHosts = { _ in [local, remote] }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: both.id), tab: .spaces)
        try await Preview.renderMatrix("settings-spaces-two-hosts", size: Self.size) {
            LogicalProjectSettingsDestination(vm: vm).background(Color.nw.bgWindow)
        }
    }

    /// The narrowest window's main column (720pt less the 232pt sidebar) with a long path and a long host name: the path shortens, the
    /// host stays, the "can add spaces" help wraps beside its switch.
    @Test func spacesInTheNarrowestColumnWithLongNames() async throws {
        let world = try PreviewWorkspace()
        world.settings.projectsEnabled = true  // Projects is an opt-in experiment
        defer { world.stop() }
        let shared = SpaceID(rawValue: UUID().uuidString.lowercased())
        let theirs = Space(id: shared, name: "payments-api-for-the-reseller-storefront", path: "/srv/payments/api/for/the/reseller/storefront/and/its/sandbox/keys")
        let host = ProjectHostOption(reference: .remote(hostID: UUID(), bindingID: UUID()), name: "build-machine-in-the-office-basement", spaces: [theirs])
        try await world.seed(ShepherdState(spaces: []))
        world.server.setProjectEligibleHosts([.local, host.reference])
        world.server.setProjectExecutionSpaces([host.reference: [theirs]])
        let vm = world.vm
        guard case .project(let created) = try await world.server.logicalProjects(.create(projectID: ProjectID(), name: "Gamecards", goal: "", linkedSpaceIDs: [])),
              case .project(let linked) = try await world.server.logicalProjects(.linkSpace(projectID: created.id, expectedRevision: created.revision, spaceID: shared, host: host.reference)) else {
            throw PreviewFixtureError("the owner refused the link")
        }
        try await eventuallyOnMain("adopted") { vm.state.projects.first?.revision == linked.revision }
        vm.logicalProjects.ownerHosts = { _ in [ProjectHostOption(reference: .local, name: "This Mac"), host] }
        vm.openLogicalProjectSettings(LogicalProjectRef(home: .local, id: linked.id), tab: .spaces)
        try await Preview.renderMatrix("settings-spaces-narrowest", size: CGSize(width: AppLayout.windowMinWidth - AppLayout.sidebarDefaultWidth, height: 700)) {
            LogicalProjectSettingsDestination(vm: vm).background(Color.nw.bgWindow)
        }
    }

    @Test(arguments: [LogicalProjectSettingsTab.general, .spaces, .memory, .automations])
    func empty(tab: LogicalProjectSettingsTab) async throws { try await render(.empty, tab) }

    @Test(arguments: [LogicalProjectSettingsTab.general, .spaces, .memory, .automations])
    func long(tab: LogicalProjectSettingsTab) async throws { try await render(.long, tab) }
}

private struct PreviewFixtureError: Error { let message: String; init(_ message: String) { self.message = message } }
