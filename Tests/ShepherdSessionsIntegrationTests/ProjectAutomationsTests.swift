import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Project automations owner service", .integrationTimeLimit)
struct ProjectAutomationsTests {
    private func project(_ result: LogicalProjectsResult) throws -> Project {
        guard case .project(let value) = result else { throw WireError("Expected Project") }
        return value
    }

    private func refusal<T>(_ code: String, _ action: () async throws -> T) async {
        do { _ = try await action(); Issue.record("Expected \(code)") }
        catch let error as LogicalProjectsError { #expect(error.code == code) }
        catch let error as RemoteHostClientError {
            guard case .rejected(let actual, _) = error else { Issue.record("Unexpected \(error)"); return }
            #expect(actual == code)
        } catch { Issue.record("Unexpected \(error)") }
    }

    @Test func scopedCRUDUsesOwnerRevisionsAndLegacyEditsNeverDetach() async throws {
        let remote = try RemoteHost()
        remote.server.setProjectsEnabled(true)
        defer { remote.stop() }
        let a = try await remote.typed(), b = try await remote.typed()
        defer { a.disconnect(); b.disconnect() }
        let id = ProjectID(), automation = AutomationID()
        var p = try project(await a.logicalProjects(.create(projectID: id, name: "Project", goal: "")))
        let draft = RemoteAutomationDraft(name: "Inspect CI", prompt: "Inspect the supplied result", cwd: remote.host.dir.path, enabled: true)
        p = try project(await a.logicalProjects(.automation(projectID: id, expectedRevision: p.revision, automationID: automation, action: .create(draft: draft))))
        let saved = try #require(remote.server.state.automations.first)
        #expect(saved.projectID == id && saved.agentID == nil && saved.prompt == draft.prompt)
        let stale = p.revision
        p = try project(await b.logicalProjects(.automation(projectID: id, expectedRevision: p.revision, automationID: automation, action: .setEnabled(false))))
        await refusal("stale_project") {
            try await a.logicalProjects(.automation(projectID: id, expectedRevision: stale, automationID: automation, action: .setEnabled(true)))
        }
        let other = try project(await b.logicalProjects(.create(projectID: ProjectID(), name: "Other", goal: "")))
        await refusal("project_scope") {
            try await b.logicalProjects(.automation(projectID: other.id, expectedRevision: other.revision, automationID: automation, action: .delete))
        }
        var legacy = saved
        legacy.projectID = nil
        legacy.name = "An old viewer's edit"
        let old = legacy
        await refusal("project_scope") { try await remote.server.updateAutomation(old) }
        await refusal("project_scope") { try await a.automation(automation, request: .update(draft: draft)) }
        #expect(remote.server.state.automations.first?.projectID == id)
        #expect(remote.server.state.automations.first?.enabled == false)
        var edited = draft
        edited.name = "Edited"; edited.enabled = false
        p = try project(await a.logicalProjects(.automation(projectID: id, expectedRevision: p.revision, automationID: automation, action: .update(draft: edited))))
        #expect(remote.server.state.automations.first?.name == "Edited")
        p = try project(await a.logicalProjects(.automation(projectID: id, expectedRevision: p.revision, automationID: automation, action: .delete)))
        #expect(remote.server.state.automations.isEmpty)
        #expect(try remote.host.persisted().projects.first(where: { $0.id == id }) == p)
        #expect(await remote.server.listSessions().isEmpty)
    }

    @Test func linkingRequiresAStoppedUnscopedRecordAndCannotRaceAnOrdinaryStart() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let p = try project(await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Project", goal: "")))
        let ordinary = Automation(name: "Existing", prompt: "Inspect", cwd: host.dir.path)
        try await host.server.addAutomation(ordinary)
        let request = LogicalProjectsRequest.automation(projectID: p.id, expectedRevision: p.revision, automationID: ordinary.id, action: .link)
        try await host.server.beginAutomationStart(ordinary.id)
        await refusal("conflict") { try await host.server.logicalProjects(request) }
        await host.server.endAutomationStart(ordinary.id)
        _ = try await host.server.logicalProjects(request)
        #expect(host.server.state.automations.first?.projectID == p.id)
        await refusal("project_scope") { try await host.server.beginAutomationStart(ordinary.id) }
        await refusal("project_scope") { try await host.server.removeAutomation(ordinary.id) }
        var bypass = host.server.state
        bypass.automations[0].projectID = nil
        let snapshot = bypass
        await refusal("conflict") { try await host.server.putState(snapshot) }
    }

    @Test func unconfiguredAdmissionPausingAndRestartNeverLaunchAProjectAutomation() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        var p = try project(await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Project", goal: "")))
        let id = AutomationID()
        p = try project(await host.server.logicalProjects(.automation(projectID: p.id, expectedRevision: p.revision, automationID: id,
            action: .create(draft: .init(name: "Watch", prompt: "Watch", cwd: host.dir.path, enabled: true)))))
        let active = p
        await refusal("unsupported") { try await host.server.runProjectAutomation(projectID: active.id, expectedRevision: active.revision, automationID: id) }
        p = try project(await host.server.logicalProjects(.setPaused(projectID: p.id, expectedRevision: p.revision, paused: true)))
        let paused = p
        await refusal("project_paused") { try await host.server.runProjectAutomation(projectID: paused.id, expectedRevision: paused.revision, automationID: id) }
        _ = try await host.server.logicalProjects(.setPaused(projectID: p.id, expectedRevision: p.revision, paused: false))
        #expect(await host.server.listSessions().isEmpty)
        host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: host.dir)
        restarted.server.setProjectsEnabled(true)
        defer { restarted.stop() }
        #expect(restarted.server.state.projects.first?.paused == true)
        #expect(restarted.server.state.automations.first?.projectID == p.id)
        #expect(restarted.server.state.automations.first?.agentID == nil)
        #expect(await restarted.server.listSessions().isEmpty)
    }

    @Test(arguments: ["pause", "delete", "disable"])
    func stoppingProjectWatchersPreservesOrdinaryWorkersAndTheirFiles(action: String) async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let normalSpace = Fixture.space(path: host.dir.path)
        let watcherSpace = Space(name: "Automations", path: host.dir.path, hidden: true)
        let worker = Fixture.agent(in: normalSpace)
        try await host.seed(ShepherdState(spaces: [normalSpace, watcherSpace], tabs: [worker.tab], agents: [worker.agent]))
        var p = try project(await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Project", goal: "")))
        let id = AutomationID()
        p = try project(await host.server.logicalProjects(.automation(projectID: p.id, expectedRevision: p.revision, automationID: id,
            action: .create(draft: .init(name: "Watcher", prompt: "Watch", cwd: host.dir.path, enabled: true)))))
        let session = try await host.server.createSession(params: .init(cwd: host.dir.path, command: StubPi.command, runtime: .rpc))
        let watcher = Fixture.agent(in: watcherSpace, sessionID: session.id)
        // Stand in only for an already admitted/published watcher; no new scheduler or model call.
        try await host.server.enqueue {
            try host.server.mutateState {
                $0.agents.append(watcher.agent); $0.tabs.append(watcher.tab)
                $0.automations[0].agentID = watcher.agent.id
            }
        }
        let file = host.dir.appendingPathComponent("worker-artifact")
        try Data("keep".utf8).write(to: file)
        switch action {
        case "pause": _ = try await host.server.logicalProjects(.setPaused(projectID: p.id, expectedRevision: p.revision, paused: true))
        case "delete": _ = try await host.server.logicalProjects(.delete(projectID: p.id, expectedRevision: p.revision))
        default: _ = try await host.server.logicalProjects(.automation(projectID: p.id, expectedRevision: p.revision, automationID: id, action: .setEnabled(false)))
        }
        #expect(host.server.state.agents == [worker.agent])
        #expect(host.server.state.tabs == [worker.tab])
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
        #expect(host.server.state.automations.first?.agentID == nil)
        #expect(action != "delete" || host.server.state.automations.isEmpty)
        try await host.waitForExit(session.id)
        let history = await host.server.automationRuns(id)
        if action == "delete" { #expect(history.isEmpty) }
        else { #expect(history.last?.result == .stopped) }
    }

    @Test(arguments: ["pause", "delete", "disable", "disableEnable"])
    func pauseOrDeleteWhileAdmissionIsPendingRefusesALateSuccess(action: String) async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let id = ProjectID(), automation = AutomationID()
        _ = try await host.server.logicalProjects(.create(projectID: id, name: "Project", goal: ""))
        let p = try project(await host.server.logicalProjects(.automation(projectID: id, expectedRevision: 1, automationID: automation,
            action: .create(draft: .init(name: "Watch", prompt: "Watch", cwd: host.dir.path, enabled: true)))))
        let task = ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "Watch", prompt: "Watch", phase: .reserved)
        let pending = Locked<(@Sendable (Result<ProjectTaskID, Error>) -> Void)?>(nil)
        host.server.onProjectAutomationRun = { _, _, _, completion in
            host.server.changeRuntimeProject(id, { $0.tasks.append(task) }) { _ in
                pending.withValue { $0 = completion }
            }
        }
        let run = Task { try await host.server.runProjectAutomation(projectID: id, expectedRevision: p.revision, automationID: automation) }
        try await eventually("admission held before launch") { pending.current != nil }
        let revision = try #require(host.server.state.projects.first?.revision)
        switch action {
        case "delete": _ = try await host.server.logicalProjects(.delete(projectID: id, expectedRevision: revision))
        case "disable", "disableEnable":
            host.server.setProjectsEnabled(false)
            if action == "disableEnable" { host.server.setProjectsEnabled(true) }
            try await eventually("disabled Project paused") { host.server.state.projects.first?.paused == true }
        default: _ = try await host.server.logicalProjects(.setPaused(projectID: id, expectedRevision: revision, paused: true))
        }
        pending.current?(.success(task.id))
        await refusal(action == "disable" ? "unsupported" : "conflict") { try await run.value }
        #expect(host.server.state.agents.isEmpty)
        #expect(await host.server.listSessions().isEmpty)
        if action != "delete" { #expect(host.server.state.projects.first?.tasks.first?.phase.occupiesSlot == true) }
    }

    @Test func oversizedSettingsAreRefusedWithoutOverwritingTheProject() async throws {
        let host = try ScratchServer()
        host.server.setProjectsEnabled(true)
        defer { host.stop() }
        let p = try project(await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Project", goal: "")))
        let draft = RemoteAutomationDraft(name: "Watch", prompt: String(repeating: "x", count: Project.maximumEncodedCollectionBytes), cwd: host.dir.path, enabled: true)
        await refusal("project_limit") {
            try await host.server.logicalProjects(.automation(projectID: p.id, expectedRevision: p.revision, automationID: AutomationID(), action: .create(draft: draft)))
        }
        #expect(host.server.state.projects == [p])
        #expect(host.server.state.automations.isEmpty)
    }

    @Test func olderHostAndViewerCannotSilentlyLoseAssociation() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        remote.server.advertisedCapabilities.removeAll { $0 == RemoteProtocol.logicalProjectAutomationsCapability }
        let client = try await remote.typed()
        defer { client.disconnect() }
        let request = LogicalProjectsRequest.automation(projectID: ProjectID(), expectedRevision: 1, automationID: AutomationID(), action: .link)
        await refusal("update_required") { try await client.logicalProjects(request) }
        let raw = try await remote.raw()
        try raw.send(.logicalProjects(id: 11, request: request))
        guard case .error(_, let code, _) = try await raw.next() else { Issue.record("Expected capability refusal"); return }
        #expect(code == "unsupported")
    }
}
