import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// A client managing this Mac's pi extensions over the listener (`hostExtensions.v1`): the host's
/// own Settings ▸ Tools ▸ Extensions model does the work against a scratch pi home. An extension is
/// added from a Git repository by its https address (git reaches a local one through a scoped
/// `insteadOf`: no network), listed as the Mac's row words it, switched
/// off and on in the home's settings.json, and removed with its files. A failure comes back as the
/// Mac's reason, not as a list.
@Suite("Remote extensions", .mainActorExclusive)
@MainActor
struct RemoteExtensionsFlowTests {
    static let provider = "export default pi => pi.registerProvider({ id: 'acme', name: 'Acme' });\n"

    @Test func aClientAddsListsSwitchesAndRemovesAnExtensionFromAGitRepository() async throws {
        let dir = try makeScratchDirectory("rext")
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = dir.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        let pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("support/pi", isDirectory: true),
                         yourPi: YourPiLocator(.fixed(nil)), userHome: user.path)
        let repository = dir.appendingPathComponent("acme-login", isDirectory: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data(Self.provider.utf8).write(to: repository.appendingPathComponent("index.ts"))
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "provider"]] {
            try SkillsGit.run(["-C", repository.path] + arguments, in: nil)
        }

        // `https://example.invalid/<unique>/acme-login` is the local repository for the git this test runs,
        // and only that prefix: GIT_CONFIG_* reach every git the host starts.
        let base = "https://example.invalid/\(UUID().uuidString)/"
        setenv("GIT_CONFIG_COUNT", "1", 1)
        setenv("GIT_CONFIG_KEY_0", "url.file://\(dir.path)/.insteadOf", 1)
        setenv("GIT_CONFIG_VALUE_0", base, 1)
        defer { for name in ["GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0"] { unsetenv(name) } }

        let host = try ScratchServer(pi: pi)
        defer { host.stop() }
        let yourPi = YourPiModel(pi: pi)
        var changes = 0
        yourPi.onExtensionsChanged = { changes += 1 }
        HostStores(mcp: MCPStore(dependencies: .app(pi: pi, openURL: { _ in }, copy: { _ in })), subagents: { SubagentDefinitionsModel(pi: pi) },
                   piAuth: PiAuthStore(pi: pi), yourPi: yourPi, remoteSignIns: RemoteSignIns()).serve(on: host.server)
        let tokenURL = host.dir.appendingPathComponent("remote-token")
        let port = try host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "phone")
        defer { client.disconnect() }
        #expect(client.supports(.hostExtensions))

        func list(_ result: RemoteHostConfigResult) throws -> [HostExtension] {
            guard case .extensions(let rows) = result else { throw CommandFailure("extensions", "\(result)") }
            return rows
        }
        func settingsExtensions() throws -> [String] {
            guard let data = try? Data(contentsOf: pi.files.settings) else { return [] }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["extensions"] as? [String] ?? []
        }
        /// The entries of the added extensions: pi's own `-builtin:` switches are in the same list.
        func loaded() throws -> [String] { try settingsExtensions().filter { $0.contains("/" + YourPiImport.addedFolder + "/") } }

        guard case .extensions(let none) = try await client.hostInventory(.extensions) else { Issue.record("expected extensions"); return }
        #expect(none.isEmpty)

        // Added from a repository: cloned on this Mac, switched on, worded as the Mac's row words it.
        let url = base + "acme-login"
        let added = try list(try await client.hostConfig(.extensionAddGit(url: url)))
        let row = try #require(added.first)
        #expect(added.count == 1 && row.name == "acme-login" && row.on && row.added && row.failure == nil)
        #expect(row.id.hasPrefix(YourPiImport.addedFolder + "/"))
        #expect(row.subtitle == "Added from \(url)")
        #expect(try loaded().count == 1)
        guard case .extensions(let listed) = try await client.hostInventory(.extensions) else { Issue.record("expected extensions"); return }
        #expect(listed == added)

        // Off leaves it out of launches; on puts it back.
        let off = try list(try await client.hostConfig(.extensionSetEnabled(destination: row.id, on: false)))
        #expect(off.first?.on == false)
        #expect(try loaded().isEmpty)
        let on = try list(try await client.hostConfig(.extensionSetEnabled(destination: row.id, on: true)))
        #expect(on.first?.on == true)
        #expect(try loaded().count == 1)

        // A name the host has no copy of, and an address that isn't a repository, are refused with a reason.
        await #expect(throws: RemoteHostClientError.self) {
            try await client.hostConfig(.extensionSetEnabled(destination: "your-extensions/added/missing", on: true))
        }
        await #expect(throws: RemoteHostClientError.self) { try await client.hostConfig(.extensionRemove(destination: "../auth.json")) }
        do {
            _ = try await client.hostConfig(.extensionAddGit(url: "--upload-pack=touch /tmp/x"))
            Issue.record("a non-repository address must be refused")
        } catch let error as RemoteHostClientError {
            guard case .rejected(_, let message) = error else { Issue.record("expected a rejection"); return }
            #expect(message.contains("https:// or ssh"))
        }
        // Nor one on this Mac's own disk, or over a transport anyone on the way could tamper with.
        for refused in ["file://" + repository.path, repository.path, "http://example.invalid/acme/pi-login", "git://example.invalid/acme/pi-login"] {
            await #expect(throws: RemoteHostClientError.self, "\(refused)") { try await client.hostConfig(.extensionAddGit(url: refused)) }
        }
        #expect(try list(try await client.hostConfig(.extensionAddGit(url: url))).count == 1, "the same address again replaces its copy")

        // Removed with its files.
        let files = pi.files.directory.appendingPathComponent(row.id)
        #expect(FileManager.default.fileExists(atPath: files.path))
        #expect(try list(try await client.hostConfig(.extensionRemove(destination: row.id))).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: files.path))
        #expect(try loaded().isEmpty)
        #expect(changes >= 5, "each change tells the host's Sign-in to read its providers again")
    }
}
