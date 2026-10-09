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
            let result = try await service.request(directory: dir.path, file: ".pi/mcp.json", text: text, action: .login(server: "issues\(index)"), owner: owner)
            ids.append(try #require(result.id))
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".pi/mcp.json", text: text, action: .login(server: "issues4"), owner: owner)
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".pi/mcp.json", text: "", action: .poll(id: ids[0]), owner: UUID())
        }
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: "/other", file: ".pi/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        }
        try await eventually("host sign-in deadline") {
            try await service.request(directory: dir.path, file: ".pi/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner).phase == .failed
        }
        let failed = try await service.request(directory: dir.path, file: ".pi/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        #expect(failed.message?.contains("300 seconds") == true)
        await service.cancel(owner: owner)
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: dir.path, file: ".pi/mcp.json", text: "", action: .poll(id: ids[0]), owner: owner)
        }
        let restarted = ProjectMCPService(pi: pi)
        await #expect(throws: ProjectFileError.self) {
            _ = try await restarted.request(directory: dir.path, file: ".pi/mcp.json", text: text, action: .poll(id: ids[0]), owner: owner)
        }
        #expect(!FileManager.default.fileExists(atPath: pi.home.appendingPathComponent("mcp-auth.json").path))
        await service.cancelAll()
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
        _ = try await client.projects(.save(directory: root.path, file: ".pi/mcp.json", text: text, expected: nil))
        #expect(client.capabilities.contains(RemoteProtocol.projectMCPCapability))
        #expect(client.capabilities.contains(RemoteProtocol.projectTrustCapability))
        guard case .mcp(let result) = try await client.projects(.mcp(directory: root.path, file: ".pi/mcp.json", action: .credentials)) else { Issue.record("Expected MCP credentials"); return }
        #expect(result.signedIn.isEmpty && result.id == nil && result.authorizationURL == nil)
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.projects(.mcp(directory: root.path, file: ".pi/auth.json", action: .credentials))
        }
        let old = try RemoteHost()
        defer { old.stop() }
        old.server.advertisedCapabilities = RemoteProtocol.capabilities.filter { $0 != RemoteProtocol.projectMCPCapability && $0 != RemoteProtocol.projectTrustCapability }
        let oldClient = try await old.typed()
        defer { oldClient.disconnect() }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await oldClient.projects(.mcp(directory: root.path, file: ".pi/mcp.json", action: .login(server: "issues")))
        }
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await oldClient.projects(.mcp(directory: root.path, file: ".pi/mcp.json", action: .approveProject))
        }
    }

    @Test(arguments: [".pi/mcp.json", ".mcp.json"])
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
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "oauth-test")
        defer { client.disconnect() }
        let text = String(decoding: try JSONSerialization.data(withJSONObject: ["mcpServers": ["issues": ["url": url]]]), as: UTF8.self)
        _ = try await client.projects(.save(directory: project.path, file: file, text: text, expected: nil))
        func action(_ action: ProjectMCPAction) async throws -> ProjectMCPResult {
            guard case .mcp(let value) = try await client.projects(.mcp(directory: project.path, file: file, action: action)) else { throw ProjectFileError("protocol", "Expected MCP result") }
            return value
        }
        if file == ".pi/mcp.json" {
            #expect(try await action(.credentials).projectTrusted == false)
            #expect(try await action(.approveProject).projectTrusted == true)
            #expect(try await action(.credentials).projectTrusted == true)
            await #expect(throws: RemoteHostClientError.self) {
                _ = try await client.projects(.mcp(directory: directory.path, file: file, action: .approveProject))
            }
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
