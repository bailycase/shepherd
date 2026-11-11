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

/// Missions and Projects run on the background host (`RuntimeHosting`) and draw as This Mac's own:
/// the same records, in process and as the host's client, render the same window.
extension PreviewTests {
    /// A host serving threads, worktrees and the runtime on its local socket, as `ShepherdHost.main`
    /// does, seeded by `seed`, and `workspace`'s app taking its workspace as its own.
    func adoptRuntimeHost(into workspace: PreviewWorkspace, seed: (SessionServer) async throws -> Void) async throws -> ScratchServer {
        let host = try ScratchServer(dir: try makeScratchDirectory("host"))
        host.server.serveThreads(ThreadHosting(defaults: {
            ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard,
                                   worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
        }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
        let worktrees = host.server.serveAgentQueries(WorktreeHosting(defaults: { .init(generateDescription: false) },
                                                                      deleteAgent: { id, _ in try await host.server.deleteAgent(id) }))
        // The host follows the app's settings (`followOtherProcesses`); here it reads the same values.
        let settings = AppSettings(store: ScratchDefaults())
        settings.projectsEnabled = workspace.settings.projectsEnabled
        settings.missionsEnabled = workspace.settings.missionsEnabled
        host.server.setProjectsEnabled(settings.projectsEnabled)
        runtimeHosts.append(RuntimeHosting.headless(server: host.server, settings: settings, worktrees: worktrees,
                                                    mcp: { _, _, _, _, _ in nil }, notify: { _, _ in }).serve())
        try await seed(host.server)
        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let vm = workspace.vm
        vm.connectLocalHost(socket: socket, token: token)
        try await eventuallyOnMain("the host's workspace as the app's", timeout: .seconds(30)) {
            vm.state.missions == host.server.state.missions && vm.state.projects == host.server.state.projects
                && vm.state.agents == host.server.state.agents
        }
        return host
    }

    /// The Missions page's list, a mission's map and the sidebar's Missions section.
    @Test func localHostMissionsMatchInProcess() async throws {
        let fixture = try MissionPreviewFixture(dir: try makeScratchDirectory("missions"))
        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            workspace.settings.missionsEnabled = true
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            if mode == "in-process" { try await fixture.seed(workspace) } else {
                host = try await adoptRuntimeHost(into: workspace) { try await fixture.seed(server: $0) }
            }
            let vm = workspace.vm
            vm.openDestination(.missions)
            let page = try #require(vm.thisMacMissions)
            for (id, name) in [(MissionID?.none, "list"), (fixture.draft.id, "map")] {
                page.selectedID = id
                try await Preview.render("this-mac-missions-\(name)-\(mode)", size: CGSize(width: 1440, height: 900),
                                         ready: { !page.availableModels.isEmpty && page.records.count == 12 }) { RootView(vm: vm) }
            }
            try await Preview.render("this-mac-missions-sidebar-\(mode)", size: CGSize(width: 232, height: 900)) { SidebarView(vm: vm) }
        }
        try expectSameRenders("this-mac-missions-list-in-process", "this-mac-missions-list-client")
        try expectSameRenders("this-mac-missions-map-in-process", "this-mac-missions-map-client")
        try expectSameRenders("this-mac-missions-sidebar-in-process", "this-mac-missions-sidebar-client")
    }

    /// The Projects page and the sidebar with a Project's working threads, its workers started by the
    /// runtime on the stub engine.
    @Test func localHostProjectsMatchInProcess() async throws {
        try StubPi.installAsEngine()
        let folder = try makeScratchDirectory("sample-app")
        let space = Space(name: "sample-app", path: folder.path)
        let projectID = ProjectID()
        let prompts = [("Reading list research", "slow"), ("Library API draft", "slow")]
        for mode in ["in-process", "client"] {
            let workspace = try PreviewWorkspace(ownsWorkspace: mode == "in-process")
            workspace.settings.projectsEnabled = true
            var host: ScratchServer?
            defer { workspace.stop(); host?.stop() }
            let seed: (SessionServer) async throws -> Void = { server in
                try await server.putState(ShepherdState(spaces: [space]))
                _ = try await server.logicalProjects(.create(projectID: projectID, name: "Sample App",
                                                             goal: "Build a shared reading list for a small team", linkedSpaceIDs: [space.id]))
            }
            if mode == "in-process" {
                try await seed(workspace.server)
                let vm = workspace.vm, server = workspace.server
                try await eventuallyOnMain("the Project arrives") { vm.state.projects == server.state.projects }
            } else {
                host = try await adoptRuntimeHost(into: workspace, seed: seed)
            }
            let vm = workspace.vm
            let ref = LogicalProjectRef(home: .local, id: projectID)
            vm.openLogicalProject(ref)
            try await Preview.render("this-mac-project-\(mode)", size: CGSize(width: 1368, height: 900)) {
                LogicalProjectDestination(vm: vm).frame(width: 1368).background(Color.sh.bgWindow)
            }
            // Two workers the runtime starts, from the app's own Project model either way.
            for (index, (title, prompt)) in prompts.enumerated() {
                try await eventuallyOnMain("the app's copy is current") { vm.logicalProjects.project(ref) != nil && !vm.logicalProjects.busy.contains(ref) }
                #expect(await vm.logicalProjects.run(ref, .assign(operationID: UUID(), spaceID: space.id, title: title, prompt: prompt)),
                        "\(vm.logicalProjects.failure?.message ?? "")")
                try await eventuallyOnMain("worker \(index + 1) works", timeout: .seconds(30)) {
                    vm.state.projects.first?.tasks.count == index + 1 && vm.state.projects.first?.tasks.allSatisfy { $0.phase == .running } == true
                }
            }
            // Each worker's own thread, read through whoever runs it, says when it started.
            let workers = (vm.state.projects.first?.tasks ?? []).map(\.workerAgentID)
            for id in workers { Task { await vm.threadStores.store(for: id).run(request: { try await vm.nativeThread(id, request: $0) }) } }
            try await Preview.render("this-mac-project-working-\(mode)", size: CGSize(width: 1368, height: 900),
                                     ready: { workers.allSatisfy { vm.workerStarted($0) != nil } }) {
                LogicalProjectDestination(vm: vm).frame(width: 1368).background(Color.sh.bgWindow)
            }
            vm.destination = nil
            for style in [SHSidebarStyle.activity, .projects] {
                vm.settings.sidebarStyle = style
                try await Preview.render("this-mac-project-sidebar-\(style.rawValue)-\(mode)", size: CGSize(width: 232, height: 820)) { SidebarView(vm: vm) }
            }
        }
        try expectSameRenders("this-mac-project-in-process", "this-mac-project-client")
        try expectSameRenders("this-mac-project-working-in-process", "this-mac-project-working-client")
        for style in [SHSidebarStyle.activity, .projects] {
            try expectSameRenders("this-mac-project-sidebar-\(style.rawValue)-in-process", "this-mac-project-sidebar-\(style.rawValue)-client")
        }
    }
}

/// The runtime each preview's host serves, kept while it renders.
@MainActor private var runtimeHosts: [(missions: MissionController, coordinator: ProjectCoordinatorController, execution: ProjectExecutionController)] = []
