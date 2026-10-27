import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// A remote thread's Files (`files.v1`): the host lists and reads the thread's own folder, read-only, only for a
/// client that listed the capability, and never outside the folder (docs/design/side-pane-files.md).
@Suite("Remote files", .timeLimit(.minutes(1)))
struct RemoteFilesTests {
    /// A host whose agent runs in a scratch folder: `Sources/App.swift`, `README.md`, `.env`, a secret beside the
    /// folder, a symlink out to it, a symlink back to the folder, an oversized file and a binary one.
    struct FilesHost {
        let remote: RemoteHost
        let agent: AgentID
        let folder: URL
        let outside: URL

        init() async throws {
            outside = try makeScratchDirectory("files-outside")
            folder = try makeScratchDirectory("files-thread")
            let fm = FileManager.default
            try fm.createDirectory(at: folder.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try Data("let x = 1\n".utf8).write(to: folder.appendingPathComponent("Sources/App.swift"))
            try Data("# Readme\n".utf8).write(to: folder.appendingPathComponent("README.md"))
            try Data("TOKEN=1\n".utf8).write(to: folder.appendingPathComponent(".env"))
            try Data("secret\n".utf8).write(to: outside.appendingPathComponent("secret.txt"))
            try Data(repeating: UInt8(ascii: "a"), count: ThreadFilesLimits.readBytes + 1).write(to: folder.appendingPathComponent("big.txt"))
            try Data([0, 1, 2, 3]).write(to: folder.appendingPathComponent("blob.bin"))
            try fm.createSymbolicLink(atPath: folder.appendingPathComponent("escape").path, withDestinationPath: outside.path)
            try fm.createSymbolicLink(atPath: folder.appendingPathComponent("escape.txt").path,
                                      withDestinationPath: outside.appendingPathComponent("secret.txt").path)
            try fm.createSymbolicLink(atPath: folder.appendingPathComponent("Sources/loop").path, withDestinationPath: "..")
            remote = try RemoteHost()
            let space = Fixture.space("web", path: folder.path)
            let seeded = Fixture.agent(in: space)
            try await remote.host.seed(Fixture.workspace([seeded], space: space))
            agent = seeded.agent.id
        }

        func stop() {
            remote.stop()
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }

        /// The host's answer to `query` for a raw client listing `capabilities`.
        func ask(_ query: RemoteAgentQuery, agent: AgentID? = nil, capabilities: [String] = RemoteProtocol.clientCapabilities) async throws -> RemoteReply {
            let raw = try await remote.raw(authenticated: false)
            defer { raw.closeConnection() }
            try await raw.hello(token: remote.token, capabilities: capabilities)
            try raw.send(.agentQuery(id: 7, agentID: agent ?? self.agent, query: query))
            var reply = try await raw.next()
            while case .stateChanged = reply { reply = try await raw.next() }
            return reply
        }
    }

    static func code(_ reply: RemoteReply) -> String? {
        if case .error(7, let code, _) = reply { return code }
        return nil
    }

    @Test func listsTheThreadsFolderFoldersFirstWithoutHiddenOrEscapingEntries() async throws {
        let host = try await FilesHost()
        defer { host.stop() }
        let client = try await host.remote.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.filesCapability))

        let root = try await client.listFiles(agentID: host.agent, path: "", showHidden: false)
        #expect(root.entries.map(\.name) == ["Sources", "big.txt", "blob.bin", "README.md"])
        #expect(root.entries.first?.kind == .directory)
        #expect(root.entries.first { $0.name == "README.md" }?.size == 9)
        #expect(!root.truncated)

        let hidden = try await client.listFiles(agentID: host.agent, path: "", showHidden: true)
        #expect(hidden.entries.map(\.name).contains(".env"))

        // The symlink back up to the folder is not listed.
        let sources = try await client.listFiles(agentID: host.agent, path: "Sources", showHidden: false)
        #expect(sources.entries.map(\.name) == ["App.swift"])
    }

    @Test func readsATextFile() async throws {
        let host = try await FilesHost()
        defer { host.stop() }
        let client = try await host.remote.typed()
        defer { client.disconnect() }
        #expect(try await client.readFile(agentID: host.agent, path: "Sources/App.swift") == Data("let x = 1\n".utf8))
    }

    @Test(arguments: [
        ("../files-outside/secret.txt", "invalid_path"),
        ("Sources/../../secret.txt", "invalid_path"),
        ("./README.md", "invalid_path"),
        ("/etc/hosts", "invalid_path"),
        ("~/.ssh/config", "invalid_path"),
        ("escape.txt", "outside_root"),
        ("escape/secret.txt", "outside_root"),
        ("Sources/loop/README.md", "outside_root"),
    ])
    func refusesEveryWayOutOfTheFolder(_ path: String, _ expected: String) async throws {
        let host = try await FilesHost()
        defer { host.stop() }
        #expect(Self.code(try await host.ask(.fileRead(path: path))) == expected)
        #expect(Self.code(try await host.ask(.files(path: path, showHidden: true))) == expected, "listing \(path) is refused too")
    }

    @Test func refusesOversizedBinaryAndMissingFiles() async throws {
        let host = try await FilesHost()
        defer { host.stop() }
        #expect(Self.code(try await host.ask(.fileRead(path: "big.txt"))) == "too_large")
        #expect(Self.code(try await host.ask(.fileRead(path: "blob.bin"))) == "binary")
        #expect(Self.code(try await host.ask(.fileRead(path: "missing.swift"))) == "not_found")
        #expect(Self.code(try await host.ask(.files(path: "missing", showHidden: false))) == "not_found")
        #expect(Self.code(try await host.ask(.files(path: "README.md", showHidden: false))) == "not_directory")
        #expect(Self.code(try await host.ask(.fileRead(path: "Sources"))) == "special_file")
        #expect(Self.code(try await host.ask(.fileRead(path: "README.md"), agent: AgentID())) == "no_such_agent")
    }

    @Test func aClientWithoutTheCapabilityIsNeitherOfferedNorServedFiles() async throws {
        let host = try await FilesHost()
        defer { host.stop() }
        let older = RemoteProtocol.clientCapabilities.filter { $0 != RemoteProtocol.filesCapability }
        let raw = try await host.remote.raw(authenticated: false)
        defer { raw.closeConnection() }
        let offered = try await raw.hello(token: host.remote.token, capabilities: older)
        #expect(!offered.contains(RemoteProtocol.filesCapability))
        #expect(Self.code(try await host.ask(.fileRead(path: "README.md"), capabilities: older)) == "unsupported")
        #expect(Self.code(try await host.ask(.files(path: "", showHidden: false), capabilities: [])) == "unsupported")
    }
}
