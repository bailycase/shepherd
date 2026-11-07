import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Settings served by the background host with no app (`ShepherdHost.serveSettings` and
/// `HostSettingsMapping.serve`): a client over `host.sock` reads and changes them, a change
/// reaches the host's server, and Serve this Mac opens the TCP listener in the host.
@Suite("Settings hosted with no app", .mainActorExclusive)
@MainActor
struct HostedSettingsTests {
    @Test func aClientReadsAndChangesTheHostsSettingsAndServeThisMacListensInTheHost() async throws {
        let host = try ScratchServer()
        defer { host.stop() }
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        settings.designToolEnabled = false
        settings.remoteListenerEnabled = true
        settings.remoteListenerPort = 0
        var service: BackgroundService.Status? = .enabled
        HostSettingsMapping.serve(on: host.server, settings: settings) { service?.keepsAgentsRunning }
        let port = try #require(ShepherdHost.serveSettings(settings, on: host.server), "Serve this Mac listens in the host")

        let socket = host.dir.appendingPathComponent("h.sock").path
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(localSocket: socket)
        _ = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
        defer { client.disconnect() }

        #expect(try await client.hostSettings().designToolEnabled == false)
        #expect(!client.capabilities.contains(RemoteProtocol.designsCapability))
        let changed = try await client.hostSettings(.change(.designToolEnabled(true)))
        #expect(changed.designToolEnabled && settings.designToolEnabled)
        try await eventuallyOnMain("the host to serve designs") { client.capabilities.contains(RemoteProtocol.designsCapability) }

        // An iPhone reaches the same host over TCP, with the same token.
        let phone = RemoteHostClient()
        _ = try await phone.connect(host: "127.0.0.1", port: port, token: token, clientName: "iPhone")
        defer { phone.disconnect() }
        #expect(try await phone.hostSettings().designToolEnabled)
        // From the host's launchd status: on, off in Login Items, no job.
        #expect(phone.capabilities.contains(RemoteProtocol.hostSettingsBackgroundServiceCapability))
        #expect(try await phone.hostSettings().backgroundService == true)
        service = .requiresApproval
        #expect(try await phone.hostSettings().backgroundService == false)
        service = nil
        #expect(try await phone.hostSettings().backgroundService == nil)
    }
}
