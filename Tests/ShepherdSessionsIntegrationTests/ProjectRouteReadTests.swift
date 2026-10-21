import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project directory read grants", .serialized, .integrationTimeLimit)
struct ProjectRouteReadTests {
    @Test(arguments: ["remove", "restore", "binding", "path", "hidden", "noop", "unrelated", "rename"])
    func realExecutorContinuationRechecksRouteTransitions(change: String) async throws {
        let rig = try ProjectExecutionTests.Rig(); defer { rig.stop() }
        var assignment = try await rig.assignment("tools:0 long:100")
        guard case .project(let project) = try await rig.owner.server.logicalProjects(.create(projectID: assignment.key.projectID, name: "Read grant", goal: "")) else { throw WireError("owner") }
        assignment.key.ownerID = project.ownerID
        rig.owner.server.onProjectRuntimeLaunch = { _, done in done(.failure(WireError("No model call"))) }
        let hostID = UUID(), binding = ProjectHostReference.remote(hostID: hostID, bindingID: UUID()), exact = assignment
        _ = try await rig.owner.server.updateRuntimeProject(project.id) { owner in
            owner.settings.allowedHosts = [binding]; owner.linkedSpaces = [.init(spaceID: exact.executorSpaceID, linkedAt: 0, host: binding)]
            var task = ProjectTask(id: exact.taskID, operationID: exact.key.operationID, workerAgentID: exact.reservedWorkerID, spaceID: exact.executorSpaceID, title: exact.title, prompt: exact.prompt, phase: .running, host: binding)
            task.executionAssignment = exact; owner.tasks = [task]
        }
        let spaces = rig.host.server.state.spaces
        let originalSpace = try #require(spaces.first { $0.id == exact.executorSpaceID })
        rig.owner.server.setProjectEligibleHosts([.local, binding])
        rig.owner.server.setProjectExecutionSpaces([binding: spaces])
        let client = try await rig.remote.typed(); defer { client.disconnect() }
        rig.owner.server.onProjectPlacement = { _, request, done in
            Task { do { done(.success(try await client.projectExecution(request))) } catch { done(.failure(error)) } }
        }
        _ = try await client.projectExecution(.execute(exact))
        try await eventually("executor settled") { rig.receipt(exact)?.phase == .settled }
        rig.owner.server.reconcileProjectExecutions(host: binding)
        try await eventually("owner received exact receipt") { rig.owner.server.state.projects[0].tasks[0].executionReceipt?.phase == .settled }
        let first = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: .result(taskID: exact.taskID, operationID: exact.key.operationID))
        let firstPage = try #require(first.resultPage), offset = try #require(firstPage.nextOffset)
        let routeToken = try await rig.owner.server.enqueue { try #require(rig.owner.server.projectExecutionSpaceAuthority[binding]?[exact.executorSpaceID]) }
        let workerGrant = try await rig.owner.server.projectWorkerReadGrant(project.id)
        let task = try #require(rig.owner.server.state.projects[0].tasks.first)
        let release = Locked<(@Sendable () -> Void)?>(nil)
        rig.owner.server.onProjectPlacement = { _, request, done in
            Task {
                do {
                    let value = try await client.projectExecution(request)
                    if case .result = request { release.withValue { $0 = { done(.success(value)) } } }
                    else { done(.success(value)) }
                } catch { done(.failure(error)) }
            }
        }
        let request = ProjectRuntimeRequest.result(taskID: exact.taskID, operationID: exact.key.operationID, offset: offset, sha256: firstPage.sha256)
        let read = Task { try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: request) }
        try await eventually("real typed executor continuation is held before owner release") { release.current != nil }
        defer { release.withValue { let done = $0; $0 = nil; return done }?() }
        var changed = originalSpace
        switch change {
        case "remove", "restore": rig.owner.server.setProjectExecutionSpaces([binding: []])
        case "binding": rig.owner.server.setProjectExecutionSpaces([.remote(hostID: hostID, bindingID: UUID()): spaces])
        case "path": changed.path += "/replacement"; rig.owner.server.setProjectExecutionSpaces([binding: [changed]])
        case "hidden": changed.hidden = true; rig.owner.server.setProjectExecutionSpaces([binding: [changed]])
        case "noop": rig.owner.server.setProjectExecutionSpaces([binding: spaces])
        case "unrelated": rig.owner.server.setProjectExecutionSpaces([binding: spaces + [Space(name: "Unrelated", path: "/unrelated")]])
        case "rename": changed.name = "Renamed executor Space"; rig.owner.server.setProjectExecutionSpaces([binding: [changed]])
        default: throw WireError("test change")
        }
        _ = try await rig.owner.server.enqueue { rig.owner.server.projectExecutionSpaces }
        if change != "remove" {
            rig.owner.server.setProjectExecutionSpaces([binding: spaces])
            _ = try await rig.owner.server.enqueue { rig.owner.server.projectExecutionSpaces }
        }
        let benign = ["noop", "unrelated", "rename"].contains(change)
        let currentToken = try await rig.owner.server.enqueue { rig.owner.server.projectExecutionSpaceAuthority[binding]?[exact.executorSpaceID] }
        #expect((currentToken == routeToken) == benign)
        release.withValue { let done = $0; $0 = nil; return done }?()
        if benign {
            let page = try #require(try await read.value.resultPage)
            #expect(page.availability == .complete && page.offset == offset && !page.data.isEmpty && page.sha256 == firstPage.sha256)
            try await rig.owner.server.validateProjectWorkerRead(project.id, grant: workerGrant, task: task)
        } else {
            do { _ = try await read.value; Issue.record("Removed/restored route revived a stale continuation") }
            catch let error as LogicalProjectsError { #expect(error.code == "project_scope") }
            await #expect(throws: LogicalProjectsError.self) { try await rig.owner.server.validateProjectWorkerRead(project.id, grant: workerGrant, task: task) }
        }
        // A valid restoration allows a NEW grant to fetch the same immutable page, never the held old request.
        rig.owner.server.setProjectExecutionSpaces([binding: spaces])
        rig.owner.server.onProjectPlacement = { _, request, done in
            Task { do { done(.success(try await client.projectExecution(request))) } catch { done(.failure(error)) } }
        }
        let fresh = try await rig.owner.server.projectRuntime(project.id, expectedRevision: rig.owner.server.state.projects[0].revision, request: request)
        #expect(fresh.resultPage?.availability == .complete && fresh.resultPage?.offset == offset && fresh.resultPage?.sha256 == firstPage.sha256 && fresh.resultPage?.identity == firstPage.identity)
        #expect(fresh.resultPage?.data.isEmpty == false)
        // Route replacements do not leave a lifetime-growing route tombstone ledger.
        for _ in 0..<40 {
            rig.owner.server.setProjectExecutionSpaces([.remote(hostID: UUID(), bindingID: UUID()): [originalSpace]])
        }
        rig.owner.server.setProjectExecutionSpaces([binding: spaces])
        let tokens = try await rig.owner.server.enqueue { rig.owner.server.projectExecutionSpaceAuthority }
        #expect(tokens.count == 1 && tokens[binding]?.count == spaces.filter { !$0.hidden }.count)
    }
}
