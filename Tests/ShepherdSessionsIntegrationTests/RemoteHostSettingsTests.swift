import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// A host's settings over the listener: the host's GUI answers every request, one change at a
/// time, and a host without one has none to share.
@Suite("Remote host settings", .integrationTimeLimit)
struct RemoteHostSettingsTests {
    @Test func aClientReadsAndChangesTheSettingsTheHostsGUIKeeps() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let kept = Locked(HostSettings(shepherdVersion: "0.4.2", piVersion: "0.87.1", defaultModel: "anthropic/claude-opus",
                                       bundledExtensions: [HostSettings.BundledExtension(id: "review", name: "Diff review tool", on: true)]))
        let requests = Locked<[RemoteHostSettingsRequest]>([])
        host.server.onRemoteHostSettings = { request, completion in
            requests.withValue { $0.append(request) }
            if case .change(let change) = request { kept.withValue { $0.apply(change) } }
            completion(.success(kept.current))
        }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.hostSettingsCapability))

        let fetched = try await client.hostSettings()
        #expect(fetched.piVersion == "0.87.1")
        #expect(fetched.defaultModel == "anthropic/claude-opus")
        let changed = try await client.hostSettings(.change(.bundledExtension(id: "review", on: false)))
        #expect(changed.bundledExtensions.map(\.on) == [false])
        #expect(requests.current == [.fetch, .change(.bundledExtension(id: "review", on: false))])
    }

    @Test func aHostsGUIThatCantApplyAChangeSaysWhy() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        host.server.onRemoteHostSettings = { _, completion in completion(.failure(RemoteCreateAgentError("Host is shutting down"))) }
        let raw = try await host.raw()

        try raw.send(.hostSettings(id: 3, request: .change(.updatePiDaily(true))))

        guard case .error(3, let code, let message) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(code == "settings_failed")
        #expect(message == "Host is shutting down")
    }

    @Test func aHostWithoutAGUIHasNoSettingsToShare() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let raw = try await host.raw()

        try raw.send(.hostSettings(id: 4, request: .fetch))

        guard case .error(4, let code, _) = try await raw.next() else { Issue.record("expected an error"); return }
        #expect(code == "unavailable")
    }
}
