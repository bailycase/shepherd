import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Remote host updates", .integrationTimeLimit)
struct RemoteHostUpdateTests {
    @Test func headlessHostsDoNotAdvertiseOrAcceptUpdates() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(!client.capabilities.contains(RemoteProtocol.hostUpdateCapability))
        await #expect(throws: RemoteHostClientError.self) { try await client.hostUpdate(.check) }
        let raw = try await host.raw()
        try raw.send(.hostUpdate(id: 42, request: .check))
        guard case .error(42, "unsupported", _) = try await raw.next() else {
            Issue.record("Expected correlated refusal")
            return
        }
    }

    @Test func requestsAreCorrelatedAndStatusSurvivesAClientReconnect() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let expected = HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: .available,
                                        offerID: UUID(), offeredVersion: "3", canInstall: true)
        host.server.onRemoteHostUpdate = { _, _, completion in completion(expected) }
        let client = try await host.typed()
        #expect(try await client.hostUpdate(.check) == expected)
        client.disconnect()
        let reconnected = try await host.typed()
        defer { reconnected.disconnect() }
        #expect(try await reconnected.hostUpdate() == expected)
    }

    @Test func unauthenticatedRequestsNeverReachTheUpdater() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let called = Locked(false)
        host.server.onRemoteHostUpdate = { _, _, _ in called.withValue { $0 = true } }
        let raw = try await host.raw(authenticated: false)
        try raw.send(.hostUpdate(id: 42, request: .install(offerID: UUID(), authorized: true)))
        guard case .error(0, "unauthenticated", _) = try await raw.next() else {
            Issue.record("Expected authentication refusal")
            return
        }
        #expect(!called.current)
    }

    @Test func aHandlerThatNeverAnswersIsBoundedOnTheHost() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        host.server.onRemoteHostUpdate = { _, _, _ in }
        let raw = try await host.raw()
        try raw.send(.hostUpdate(id: 42, request: .check))
        guard case .error(42, "timeout", _) = try await raw.next(timeout: .seconds(15)) else {
            Issue.record("Expected bounded correlated timeout")
            return
        }
    }

    @Test func disconnectRevokesAuthorizationBeforeAnAsyncInstallCanBegin() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let authorization = Locked<(() async -> Bool)?>(nil)
        host.server.onRemoteHostUpdate = { _, authorized, _ in authorization.withValue { $0 = authorized } }
        let raw = try await host.raw()
        try raw.send(.hostUpdate(id: 42, request: .check))
        try await eventually("update handler invoked") { authorization.current != nil }
        raw.closeConnection()
        try await eventually("disconnected authorization revoked") {
            guard let authorized = authorization.current else { return false }
            return !(await authorized())
        }
    }

    @Test func reservationFencesNewSessionsAndRejectsConcurrentInstallers() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        #expect(await host.server.reserveHostUpdate())
        #expect(!(await host.server.reserveHostUpdate()))
        await #expect(throws: Error.self) { try await host.host.shell("exit 0") }
        #expect(await host.server.hostUpdateCanRestart())
        let canTerminate = await withCheckedContinuation { continuation in
            host.server.checkHostUpdateTermination { continuation.resume(returning: $0) }
        }
        #expect(canTerminate)
        host.server.releaseHostUpdate()
        let unreservedTermination = await withCheckedContinuation { continuation in
            host.server.checkHostUpdateTermination { continuation.resume(returning: $0) }
        }
        #expect(!unreservedTermination)
        #expect(await host.server.reserveHostUpdate())
        host.server.releaseHostUpdate()
    }

    @Test func dormantUnpausedProjectsDoNotBlockUpdatesOrStartAfterRestart() async throws {
        let host = try ScratchServer.fresh()
        host.server.setProjectsEnabled(true)
        guard case .project(let project) = try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Idle Project", goal: "")) else {
            Issue.record("Expected Project")
            host.stop()
            return
        }
        #expect(!project.paused)
        #expect(await host.server.hostUpdateBlockReason() == nil)
        #expect(await host.server.reserveHostUpdate())
        #expect(await host.server.hostUpdateCanRestart())
        host.stop(keepFiles: true)
        let restarted = try ScratchServer(dir: host.dir)
        defer { restarted.stop() }
        restarted.server.setProjectsEnabled(true)
        #expect(restarted.server.state.projects.first?.paused == false)
        #expect(await restarted.server.listSessions().isEmpty)
        #expect(await restarted.server.hostUpdateBlockReason() == nil)
    }

    @Test(arguments: [ProjectMessage.Phase.queued, .delivering, .unknown])
    func pendingProjectDeliveriesStillBlockUpdates(phase: ProjectMessage.Phase) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        host.server.setProjectsEnabled(true)
        guard case .project(let project) = try await host.server.logicalProjects(.create(projectID: ProjectID(), name: "Pending Project", goal: "")) else {
            Issue.record("Expected Project")
            return
        }
        _ = try await host.server.updateRuntimeProject(project.id) {
            $0.messages = [ProjectMessage(id: UUID(), text: "preserve this", phase: phase)]
        }
        #expect(!(await host.server.reserveHostUpdate()))
        #expect(await host.server.hostUpdateBlockReason()?.contains("Pending Project") == true)
        #expect(host.server.state.projects.first?.messages.first?.text == "preserve this")
    }

    @Test func liveTerminalsRefuseAnUpdateWithoutKillingTheProcess() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let session = try await host.host.shell("cat")
        #expect(!(await host.server.reserveHostUpdate()))
        #expect(await host.server.hostUpdateBlockReason()?.contains("Close open terminals") == true)
        #expect(await host.server.sessionInfo(sessionID: session.id) != nil)
    }

    @Test func aCanceledUpdateReleasesSavedQueueWithoutPausingOrLosingIt() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.send("slow", from: try await pi.ready())
        let working = try await pi.snapshot { $0.running && !$0.provisional.isEmpty }
        _ = try await pi.send("after update", from: working)
        #expect(await host.server.reserveHostUpdate())
        let reserved = try await pi.snapshot()
        #expect(try await pi.queue(.clear, from: reserved).failureCode == "host_updating")
        #expect(try await pi.send("not accepted", from: reserved).failureCode == "host_updating")
        pi.release(1)
        pi.release(2)
        let settled = try await pi.snapshot { !$0.running }
        #expect(settled.queue?.items.first?.text == "after update")
        #expect(settled.queue?.paused == false)
        #expect(pi.stdin("prompt").count == 1, "Reserved work stays in the durable queue")
        try await eventually("saved queue ready for restart") { await host.server.hostUpdateBlockReason() == nil }
        #expect(await host.server.hostUpdateCanRestart())
        host.server.releaseHostUpdate()
        let queued = try await pi.waitForStdin("prompt", count: 2)
        #expect(queued["message"] as? String == "after update")
    }

    @Test func pendingToolQuestionsRefuseAnUpdateWithoutDiscardingTheQuestion() async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.send("question", from: try await pi.ready())
        let question = try await pi.snapshot { !$0.dialogs.isEmpty }
        #expect(!(await host.server.reserveHostUpdate()))
        #expect(await host.server.hostUpdateBlockReason()?.contains("Pending tool questions") == true)
        let unchanged = try await pi.snapshot()
        #expect(unchanged.dialogs == question.dialogs)
    }

    @Test(arguments: [false, true])
    func failedCheckpointWritesRefuseTheUpdate(beforeRestart: Bool) async throws {
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running && !$0.provisional.isEmpty }
        if beforeRestart { #expect(await host.server.reserveHostUpdate()) }
        let directory = host.dir.appendingPathComponent("agent-recovery")
        let backup = host.dir.appendingPathComponent("saved-agent-recovery")
        try FileManager.default.moveItem(at: directory, to: backup)
        try Data().write(to: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.moveItem(at: backup, to: directory)
        }
        if beforeRestart {
            #expect(!(await host.server.hostUpdateCanRestart()))
            let canTerminate = await withCheckedContinuation { continuation in
                host.server.checkHostUpdateTermination { continuation.resume(returning: $0) }
            }
            #expect(!canTerminate)
            host.server.releaseHostUpdate()
        } else {
            #expect(!(await host.server.reserveHostUpdate()), "Even a cached checkpoint must be written before restart")
        }
        let shell = try await host.shell("exit 0")
        #expect(await host.server.sessionInfo(sessionID: shell.id) != nil)
    }
}
