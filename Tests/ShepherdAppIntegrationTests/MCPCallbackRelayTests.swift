import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdApp

@Suite("Remote MCP callback", .integrationTimeLimit)
struct MCPCallbackRelayTests {
    @Test func onlyTheMatchingLoopbackPathAndStateReachesTheHostAndCancellationReleasesThePort() async throws {
        let port = try await RemoteBrowserDriveTests.unusedPort()
        let callback = "http://127.0.0.1:\(port)/oauth/callback"
        var parts = URLComponents(string: "https://example.invalid/authorize")!
        parts.queryItems = [.init(name: "redirect_uri", value: callback), .init(name: "state", value: "expected")]
        let received = Locked<[String]>([])
        let relay = try MCPCallbackRelay(authorizationURL: parts.url!) { value in received.withValue { $0.append(value) } }
        try await relay.start()
        defer { relay.cancel() }
        for target in ["/wrong?code=fake&state=expected", "/oauth/callback?code=fake&state=wrong"] {
            let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(target)")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 400)
            #expect(received.withValue { $0.isEmpty })
        }
        let valid = callback + "?code=fake&state=expected"
        let (_, response) = try await URLSession.shared.data(from: URL(string: valid)!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(received.withValue { $0 } == [valid])
        let conflict = try MCPCallbackRelay(authorizationURL: parts.url!) { _ in }
        defer { conflict.cancel() }
        await #expect(throws: MCPCallbackError.self) { try await conflict.start() }
        relay.cancel()
        try await eventually("callback listener released") {
            let next = try MCPCallbackRelay(authorizationURL: parts.url!) { _ in }
            defer { next.cancel() }
            do { try await next.start(); return true } catch { return false }
        }
    }

    @Test func publicOrNonHTTPRedirectListenersAreRejected() throws {
        for address in ["http://0.0.0.0:12345/callback", "http://example.invalid:12345/callback", "https://127.0.0.1:12345/callback", "http://127.0.0.1:80/callback"] {
            var url = URLComponents(string: "https://example.invalid/auth")!
            url.queryItems = [.init(name: "redirect_uri", value: address), .init(name: "state", value: "expected")]
            #expect(throws: MCPCallbackError.self) { _ = try MCPCallbackRelay(authorizationURL: url.url!) { _ in } }
        }
    }
}
