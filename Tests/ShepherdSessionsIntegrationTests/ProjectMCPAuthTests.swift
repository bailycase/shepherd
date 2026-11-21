import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project MCP authentication", .integrationTimeLimit)
struct ProjectMCPAuthTests {
    @Test func hostOwnedRunsAreBoundedScopedCancelledAndNeverPersisted() async throws {
        let dir = try makeScratchDirectory("mcp-auth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pi = try fakeSDK(in: dir)
        let service = ProjectMCPService(pi: pi, timeout: 0.5)
        let entries = Dictionary(uniqueKeysWithValues: (0..<5).map { ("issues\($0)", ["url": "https://example.invalid/mcp"]) })
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": entries]), as: UTF8.self)
        let owner = UUID()
        var ids: [UUID] = []
        for index in 0..<4 {
            let result = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: text, action: .login(server: "issues\(index)"), owner: owner)
            ids.append(try #require(result.id))
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: text, action: .login(server: "issues4"), owner: owner)
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: "", action: .poll(id: ids[0]), owner: UUID())
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: "/other", file: ".shepherd/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        }
        try await eventually("host sign-in deadline") {
            try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner).phase == .failed
        }
        let failed = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        #expect(failed.message?.contains("300 seconds") == true)
        let expired = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: "",
                                                action: .complete(id: ids[0], redirectURL: "http://localhost:1234/callback?code=late"), owner: owner)
        #expect(expired.phase == .failed)
        await service.cancel(owner: owner)
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        }
        let restarted = ProjectMCPService(pi: pi)
        await #expect(throws: ProjectFileError.self) {
            _ = try await restarted.request(directory: dir.path, file: ".shepherd/mcp.json", text: text, action: .poll(id: ids[0]), owner: owner)
        }
        #expect(!FileManager.default.fileExists(atPath: pi.home.appendingPathComponent("mcp-auth.json").path))
        await service.cancelAll()
    }

    @Test func theSameOwnerCanReplaceTheirWaitingLoginAtCapacity() async throws {
        let dir = try makeScratchDirectory("mcp-relogin")
        defer { try? FileManager.default.removeItem(at: dir) }
        let service = ProjectMCPService(pi: try WaitingMCP.setup(in: dir))
        let text = #"{"mcpServers":{"issues":{"url":"https://example.invalid/mcp"},"one":{"url":"https://example.invalid/mcp"},"two":{"url":"https://example.invalid/mcp"},"three":{"url":"https://example.invalid/mcp"}}}"#
        let owner = UUID(), other = UUID()
        func request(_ action: ProjectMCPAction, owner: UUID) async throws -> ProjectMCPResult {
            try await service.request(directory: dir.path, file: ".shepherd/mcp.json", text: text, action: action, owner: owner)
        }
        for server in ["one", "two", "three"] { _ = try await request(.login(server: server), owner: other) }
        let original = try #require(try await request(.login(server: "issues"), owner: owner).id)
        await #expect { try await request(.login(server: "issues"), owner: other) } throws: { ($0 as? ProjectFileError)?.code == "busy" }
        let replacement = try #require(try await request(.login(server: "issues"), owner: owner).id)
        #expect(replacement != original)
        await #expect { try await request(.poll(id: original), owner: owner) } throws: { ($0 as? ProjectFileError)?.code == "expired" }
        #expect(try await request(.poll(id: replacement), owner: owner).phase == .waiting)
        await service.cancelAll()
    }

    @Test func theLastDeviceSocketStartsAGracePeriodBeforeTheMacCanSignIn() async throws {
        let dir = try makeScratchDirectory("mcp-orphan")
        let host = try ScratchServer(dir: dir, pi: WaitingMCP.setup(in: dir))
        defer { host.stop() }
        host.server.setProjectMCPDisconnectGraceForTests(.seconds(1))
        host.server.configureFleet(name: "Acme Mac", advertises: false)
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await host.server.putState(ShepherdState(spaces: [Space(name: "Acme", path: project.path)]))
        let tokenURL = dir.appendingPathComponent("remote-token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let socket = dir.appendingPathComponent("h.sock").path
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let mac = RemoteHostClient(localSocket: socket)
        defer { mac.disconnect() }
        _ = try await mac.connect(host: "", port: 0, token: "", clientName: "Acme Mac")
        let token = FleetProtocol.makeToken(), deviceID = UUID()
        let code = try #require(try await mac.fleetAction(.startDeviceCode).deviceCode).code
        _ = try await RemoteHostClient.fleetPairDevice(host: "127.0.0.1", port: port, code: code, device: .init(
            deviceID: deviceID, name: "Acme Phone", kind: .iphone, tokenHash: FleetProtocol.hash(token)))
        func connect() async throws -> RemoteHostClient {
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "Acme Phone")
            return client
        }
        func action(_ action: ProjectMCPAction, on client: RemoteHostClient) async throws -> ProjectMCPResult {
            guard case .mcp(let result) = try await client.projects(.mcp(directory: project.path, file: ".shepherd/mcp.json", action: action)) else {
                throw ProjectFileError("protocol", "Expected MCP result")
            }
            return result
        }
        _ = try await mac.projects(.save(directory: project.path, file: ".shepherd/mcp.json",
                                         text: #"{"mcpServers":{"issues":{"url":"https://example.invalid/mcp"}}}"#, expected: nil))
        let phone = try await connect()
        defer { phone.disconnect() }
        let login = ProjectMCPAction.login(server: "issues")
        let id = try #require(try await action(login, on: phone).id)
        phone.disconnect() // Leave the run behind without a cancel.
        try await eventually("the host to see the device disconnect") {
            try await mac.fleetRead().snapshot.devices?.devices.first { $0.deviceID == deviceID }?.connected == false
        }
        let reconnected = try await connect()
        defer { reconnected.disconnect() }
        let secondSocket = try await connect()
        defer { secondSocket.disconnect() }
        reconnected.disconnect()
        let afterGrace = ContinuousClock.now + .milliseconds(1200)
        try await eventually("the former socket's grace period to have passed") { ContinuousClock.now >= afterGrace }
        #expect(try await action(.poll(id: id), on: secondSocket).phase == .waiting)
        await #expect { try await action(login, on: mac) } throws: { error in
            if case RemoteHostClientError.rejected(let code, _) = error { return code == "busy" }
            return false
        }
        secondSocket.disconnect()
        try await eventually("the Mac to start a new sign-in after the orphan's grace period", timeout: .seconds(5)) {
            do { return try await action(login, on: mac).phase == .waiting }
            catch RemoteHostClientError.rejected(let code, _) where code == "busy" { return false }
        }
    }

    @Test func remoteCredentialStatusIsScopedAndOldHostsRefuseBeforeSending() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        let root = host.host.dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await host.server.putState(ShepherdState(spaces: [Space(name: "project", path: root.path)]))
        let client = try await host.typed()
        defer { client.disconnect() }
        let text = #"{"mcpServers":{"issues":{"url":"https://example.invalid/mcp"}}}"#
        _ = try await client.projects(.save(directory: root.path, file: ".shepherd/mcp.json", text: text, expected: nil))
        #expect(client.capabilities.contains(RemoteProtocol.projectMCPCapability))
        #expect(!client.capabilities.contains(RemoteProtocol.projectTrustCapability), "Spaces need no approval")
        guard case .mcp(let result) = try await client.projects(.mcp(directory: root.path, file: ".shepherd/mcp.json", action: .credentials)) else { Issue.record("Expected MCP credentials"); return }
        #expect(result.signedIn.isEmpty && result.id == nil && result.authorizationURL == nil)
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.projects(.mcp(directory: root.path, file: ".shepherd/auth.json", action: .credentials))
        }
        let old = try RemoteHost()
        defer { old.stop() }
        old.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.projectMCPCapability && $0 != RemoteProtocol.projectTrustCapability }
        let oldClient = try await old.typed()
        defer { oldClient.disconnect() }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await oldClient.projects(.mcp(directory: root.path, file: ".shepherd/mcp.json", action: .login(server: "issues")))
        }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await oldClient.projects(.mcp(directory: root.path, file: ".shepherd/mcp.json", action: .approveProject))
        }
    }

    @Test(arguments: [".shepherd/mcp.json", ".pi/mcp.json", ".mcp.json"])
    func aRemoteProjectCompletesNativeOAuthAndRetainsTokensOnlyOnItsHost(_ file: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engineRoot = root.appendingPathComponent(".build/pi-engine")
        let node = engineRoot.appendingPathComponent(BundledPiEngine.nodePath)
        let package = engineRoot.appendingPathComponent(BundledPiEngine.packagePath)
        guard FileManager.default.isExecutableFile(atPath: node.path) else { return } // Real engine is staged in the release lane.
        let directory = try makeScratchDirectory("project-oauth")
        let pi = PiSetup(engine: .init(command: [node.path, package.appendingPathComponent(BundledPiEngine.entryPath).path],
                                      packageDirectory: package.path, version: "test", node: .executable(node.path)),
                         home: directory.appendingPathComponent("pi"), userHome: directory.path)
        let host = try ScratchServer(dir: directory, pi: pi)
        defer { host.stop() }
        let fixture = Process(), input = Pipe(), output = Pipe()
        fixture.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        fixture.arguments = ["python3", root.appendingPathComponent("Tests/Extensions/fixtures/fake-mcp-oauth.py").path]
        fixture.standardInput = input; fixture.standardOutput = output; fixture.standardError = Pipe()
        try fixture.run()
        defer { try? input.fileHandleForWriting.close(); if fixture.isRunning { fixture.terminate() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data([10]) { line.append(byte) }
        let fixturePort = try #require(Int(String(decoding: line, as: UTF8.self)))
        let url = "http://127.0.0.1:\(fixturePort)/mcp"
        let project = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try await host.server.putState(ShepherdState(spaces: [Space(name: "project", path: project.path)]))
        let port = try host.server.startRemoteListener(port: 0, tokenURL: directory.appendingPathComponent("remote-token"))
        let token = try String(contentsOf: directory.appendingPathComponent("remote-token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        @Sendable func connect(_ token: String) async throws -> RemoteHostClient {
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "oauth-test")
            return client
        }
        var client = try await connect(token)
        defer { client.disconnect() }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": ["issues": ["url": url]]]), as: UTF8.self)
        _ = try await client.projects(.save(directory: project.path, file: file, text: text, expected: nil))
        func action(_ action: ProjectMCPAction) async throws -> ProjectMCPResult {
            guard case .mcp(let value) = try await client.projects(.mcp(directory: project.path, file: file, action: action)) else { throw ProjectFileError("protocol", "Expected MCP result") }
            return value
        }
        if file != ".mcp.json" {
            #expect(try await action(.credentials).projectTrusted == true, "Older clients are told every space is approved")
            #expect(!client.capabilities.contains(RemoteProtocol.projectTrustCapability), "Approval is no longer offered")
        }
        let started = try await action(.login(server: "issues"))
        let id = try #require(started.id)
        var authorization: String?
        try await eventually("host authorization URL") {
            authorization = try await action(.poll(id: id)).authorizationURL
            return authorization != nil
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: try #require(authorization))!)
        let redirect = try #require((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"))
        let completion = RemoteProjectsRequest.mcp(directory: project.path, file: file, action: .complete(id: id, redirectURL: redirect))
        client.disconnect()
        let other = try await connect(host.server.clientTokenForTests())
        defer { other.disconnect() }
        await #expect {
            try await other.projects(completion)
        } throws: { error in
            if case RemoteHostClientError.rejected(let code, _) = error { return code == "expired" }
            return false
        }
        client = try await connect(token)
        _ = try await action(.complete(id: id, redirectURL: redirect))
        try await eventually("host token exchange") { try await action(.poll(id: id)).phase != .waiting }
        #expect(try await action(.poll(id: id)).phase == .done)
        #expect(try await action(.credentials).signedIn == ["issues"])
        let tokens = pi.home.appendingPathComponent("mcp-auth.json")
        #expect(FileManager.default.fileExists(atPath: tokens.path))
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("mcp-auth.json").path))
        let loggedOut = try await action(.logout(server: "issues"))
        let logoutID = try #require(loggedOut.id)
        try await eventually("host logout") { try await action(.poll(id: logoutID)).phase != .waiting }
        #expect(try await action(.credentials).signedIn.isEmpty)
        #expect(try String(contentsOf: project.appendingPathComponent(file), encoding: .utf8) == text)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }

    private func fakeSDK(in directory: URL) throws -> PiSetup {
        let package = directory.appendingPathComponent("package")
        let sdk = package.appendingPathComponent(BundledPiEngine.libraryPath)
        try FileManager.default.createDirectory(at: sdk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"type":"module"}"#.utf8).write(to: package.appendingPathComponent("package.json"))
        try Data("""
        export const SettingsManager = { inMemory: () => ({}) };
        export const SessionManager = { inMemory: () => ({}) };
        export const ModelRuntime = { create: async () => ({}) };
        export const createMcpExtension = () => () => {};
        export class DefaultResourceLoader { async reload() {} }
        export async function createAgentSession() {
          return { session: {
            extensionRunner: { getCommand: () => true, emit: async () => {} },
            bindExtensions: async () => {}, prompt: () => new Promise(() => {}), dispose: () => {}
          }};
        }
        """.utf8).write(to: sdk)
        // Resolve before the login shell runs the host's PATH-resetting startup files.
        let node = try #require(TestNode.url)
        return PiSetup(engine: .init(command: ["/usr/bin/false"], packageDirectory: package.path, version: "test", node: .executable(node.path)),
                       home: directory.appendingPathComponent("pi"), userHome: directory.path)
    }
}
