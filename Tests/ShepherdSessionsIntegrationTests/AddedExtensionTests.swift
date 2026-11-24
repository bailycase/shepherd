import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// Extensions added in Shepherd (Settings ▸ Tools ▸ Extensions), with no pi of the user's at all:
/// a file, a folder or a Git repository is copied into the home, switched on (its path in
/// settings.json `extensions`), and removed again without a trace.
@Suite("Adding extensions in Shepherd", .integrationTimeLimit)
struct AddedExtensionTests {
    struct Setup {
        let dir: URL
        let home: PiHome

        init() throws {
            dir = try makeScratchDirectory("addx")
            home = PiHome(directory: dir.appendingPathComponent("pi", isDirectory: true),
                          engine: PiEngine(command: ["/nonexistent/pi"], packageDirectory: nil, version: nil, node: .onPath("node")))
            try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        var importer: YourPiImport { YourPiImport(home: home, yourPi: nil, userHome: dir.path, log: { _ in }) }

        func settingsExtensions() throws -> [String] {
            let data = try Data(contentsOf: home.settings)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["extensions"] as? [String] ?? []
        }

        func write(_ text: String, to relative: String) throws -> URL {
            let url = dir.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            return url
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    static let provider = "export default pi => pi.registerProvider({ id: 'acme', name: 'Acme' });\n"

    @Test func aFileIsCopiedSwitchedOnAndRemoved() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let source = try setup.write(Self.provider, to: "src/acme-login.ts")

        let copy = try setup.importer.addExtension(from: source)

        #expect(copy.destination == "your-extensions/added/acme-login.ts" && copy.source == source.path)
        let path = setup.home.directory.appendingPathComponent(copy.destination).path
        #expect(try String(contentsOfFile: path, encoding: .utf8) == Self.provider)
        #expect(try setup.settingsExtensions() == [path])
        #expect(setup.importer.survey().extensions.map(\.on) == [true])

        try setup.importer.removeExtension(copy.destination)

        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try setup.settingsExtensions().isEmpty)
        #expect(setup.importer.survey().extensions.isEmpty)
    }

    @Test func aPackageFolderUsesItsManifestAndRefusesDependenciesItLacks() throws {
        let setup = try Setup()
        defer { setup.remove() }
        _ = try setup.write(Self.provider, to: "pkg/src/provider.ts")
        _ = try setup.write(#"{"name":"@acme/pi-login","pi":{"extensions":["src/provider.ts"]},"dependencies":{"left-pad":"1"}}"#,
                            to: "pkg/package.json")
        let folder = setup.dir.appendingPathComponent("pkg", isDirectory: true)

        #expect(throws: YourPiFileError.self) { try setup.importer.addExtension(from: folder) }
        #expect(setup.importer.state()?.copies.isEmpty ?? true, "A refused add leaves nothing behind")

        _ = try setup.write(#"{"name":"left-pad"}"#, to: "pkg/node_modules/left-pad/package.json")
        let copy = try setup.importer.addExtension(from: folder)

        #expect(copy.name == "@acme/pi-login" && copy.entries == ["src/provider.ts"])
        #expect(try setup.settingsExtensions() == [setup.home.directory.appendingPathComponent("\(copy.destination)/src/provider.ts").path])
        #expect(FileManager.default.fileExists(atPath: setup.home.directory.appendingPathComponent("\(copy.destination)/node_modules/left-pad").path))

        // Another source of the same name is refused; the same source again replaces the copy.
        _ = try setup.write(#"{"name":"@acme/pi-login"}"#, to: "other/package.json")
        _ = try setup.write(Self.provider, to: "other/index.ts")
        #expect(throws: YourPiFileError.self) { try setup.importer.addExtension(from: setup.dir.appendingPathComponent("other")) }
        _ = try setup.write("// v2\n" + Self.provider, to: "pkg/src/provider.ts")
        try setup.importer.addExtension(from: folder)
        #expect(try String(contentsOfFile: setup.home.directory.appendingPathComponent("\(copy.destination)/src/provider.ts").path, encoding: .utf8)
            .hasPrefix("// v2"))
        #expect(setup.importer.state()?.copies.count == 1)
    }

    @Test func aGitRepositoryIsClonedWithoutItsHistory() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let repository = setup.dir.appendingPathComponent("acme-provider", isDirectory: true)
        _ = try setup.write(Self.provider, to: "acme-provider/index.ts")
        for arguments in [["init", "-q", "-b", "main"], ["add", "."],
                          ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-q", "-m", "provider"]] {
            try SkillsGit.run(["-C", repository.path] + arguments, in: nil)
        }

        let copy = try setup.importer.addExtension(git: "file://" + repository.path)

        #expect(copy.name == "acme-provider" && copy.entries == ["index.ts"])
        let root = setup.home.directory.appendingPathComponent(copy.destination)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("index.ts").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        #expect(try setup.settingsExtensions() == [root.appendingPathComponent("index.ts").path])

        #expect(throws: YourPiFileError.self) { try setup.importer.addExtension(git: "--upload-pack=touch /tmp/x") }
        #expect(throws: YourPiFileError.self) { try setup.importer.addExtension(git: "file://" + setup.dir.appendingPathComponent("missing").path) }
    }
}
