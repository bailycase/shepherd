import Foundation
import Testing
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

    @Test func liveTerminalsRefuseAnUpdateWithoutKillingTheProcess() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let session = try await host.host.shell("cat")
        #expect(!(await host.server.reserveHostUpdate()))
        #expect(await host.server.sessionInfo(sessionID: session.id) != nil)
    }
}
