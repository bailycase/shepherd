import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// The pieces the skills and extensions units are made of: which files of a tree are units, what
/// a write may touch, how a unit that depends on another waits for it, and the unit names.
@Suite("Fleet content units")
struct FleetContentUnitTests {
    @Test func aTreesUnitsAreItsRegularFilesAndNeverALinkOrNoise() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tree = dir.appendingPathComponent("pdf")
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "a".write(to: tree.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "#!/bin/sh".write(to: tree.appendingPathComponent("scripts/run.sh"), atomically: true, encoding: .utf8)
        try "x".write(to: tree.appendingPathComponent(".git/config"), atomically: true, encoding: .utf8)
        try "secret".write(to: dir.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("link.txt"), withDestinationURL: dir.appendingPathComponent("outside.txt"))

        let files = try #require(FleetFileTree.files(under: tree.path, limits: .init(files: 10, bytes: 100)))
        #expect(files.map(\.relative) == ["SKILL.md", "scripts/run.sh"])
        let followed = try #require(FleetFileTree.files(under: tree.path, followingFileLinks: true, limits: .init(files: 10, bytes: 100)))
        #expect(followed.map(\.relative) == ["SKILL.md", "link.txt", "scripts/run.sh"], "a copy of someone's own folder reads through a link to a file")
        #expect(FleetFileTree.files(under: tree.path, limits: .init(files: 1, bytes: 100)) == nil, "over the file limit: not synced")
        #expect(FleetFileTree.files(under: tree.path, limits: .init(files: 10, bytes: 3)) == nil, "over the size limit: not synced")
    }

    @Test func aWriteStaysInsideItsFolderAndKeepsAScriptRunnable() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("skill")
        let outside = dir.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FleetFileTree.write(Data("#!/bin/sh\n".utf8), to: "scripts/run.sh", under: folder)
        #expect(FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("scripts/run.sh").path))
        try FleetFileTree.write(Data("text".utf8), to: "notes.md", under: folder)
        #expect(!FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("notes.md").path))

        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("door"), withDestinationURL: outside)
        #expect(throws: FleetUnitRefused.self) { try FleetFileTree.write(Data("x".utf8), to: "door/x.txt", under: folder) }
        #expect(throws: FleetUnitRefused.self) { try FleetFileTree.write(Data("x".utf8), to: "../x.txt", under: folder) }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.txt").path))

        // Removing the last file takes the folders it leaves empty with it, never the skill's own folder.
        try FleetFileTree.remove("scripts/run.sh", under: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("scripts").path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func theHasherReadsAFileAgainOnlyWhenItChanged() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.txt")
        try "one".write(to: path, atomically: true, encoding: .utf8)
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        let hasher = FleetFileHasher()
        func file() throws -> FleetFileTree.File { try #require(FleetFileTree.files(under: path.path, limits: .init(files: 1, bytes: 100))?.first) }
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("one".utf8)))
        // Same size and time: answered from what it remembers, not from the bytes (which changed behind its back).
        try "two".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path.path)
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("one".utf8)))
        try "three".write(to: path, atomically: true, encoding: .utf8)
        #expect(hasher.hash(try file()) == FleetSyncProtocol.hash(Data("three".utf8)))
    }

    @Test func skillAndExtensionUnitsSplitIntoTheirParts() {
        let state = FleetUnit.skillParts(of: FleetUnit.skill("pdf"))
        #expect(state?.name == "pdf" && state?.path == nil)
        #expect(FleetUnit.skill("pdf") > FleetUnit.skillFile("pdf", "scripts/run.sh") && FleetUnit.skill("pdf") > FleetUnit.skillFile("pdf", "SKILL.md"),
                "a skill's state sorts after its files, so its op follows theirs")
        #expect(FleetUnit.extensionMeta("paths/acme") > FleetUnit.extensionFile("paths/acme/index.ts"))
        let file = FleetUnit.skillParts(of: FleetUnit.skillFile("pdf", "scripts/run.sh"))
        #expect(file?.name == "pdf" && file?.path == "scripts/run.sh")
        #expect(FleetUnit.skillParts(of: "setting:host.defaultModel") == nil)
        #expect(FleetUnit.isValid(FleetUnit.extensionFile("paths/acme/index.ts")) && FleetUnit.isValid(FleetUnit.extensionMeta("paths/acme")))
        #expect(!FleetUnit.isValid("extension:paths/../../x"))
    }

    // MARK: A unit that waits for another

    /// A source of two units where `state` can only be written once `file` is.
    final class DependentSource: FleetUnitSource, @unchecked Sendable {
        var values: [String: Data] = [:]
        let units = ["skill:x", "skill:x/SKILL.md"]
        func storesBlob(_ unit: String) -> Bool { unit.contains("/") }
        func read() -> [String: Data] { values }
        func isSeedable(_ unit: String, _ value: Data) -> Bool { true }
        func write(_ unit: String, _ value: Data?, origin: String) throws {
            if unit == "skill:x", values["skill:x/SKILL.md"] == nil { throw FleetUnitWaiting(description: "no files yet") }
            values[unit] = value
        }
    }

    @Test func aUnitThatNeedsAnotherIsWrittenAfterItInTheSamePassAndNeverComesBackAsAnOp() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sender = try FleetStore(directory: dir.appendingPathComponent("a"), mac: UUID())
        let receiverStore = try FleetStore(directory: dir.appendingPathComponent("b"), mac: UUID())
        // The state sorts first, so it is asked to write before its file exists.
        let state = sender.appendLocal(unit: "skill:x", change: .value("{\"on\":true}"), seed: false, name: "A")!
        let hash = try #require(sender.putBlob(Data("# x".utf8)))
        let file = sender.appendLocal(unit: "skill:x/SKILL.md", change: .blob(hash: hash, size: 3), seed: false, name: "A")!
        _ = receiverStore.receive(state)
        _ = receiverStore.receive(file)
        _ = receiverStore.putBlob(Data("# x".utf8), named: hash)

        let materializer = FleetMaterializer(store: receiverStore, directory: dir.appendingPathComponent("b"))
        let source = DependentSource()
        materializer.add(source)
        let result = materializer.materialize(name: "B")
        #expect(!result.failed)
        #expect(source.values["skill:x"] == Data("{\"on\":true}".utf8) && source.values["skill:x/SKILL.md"] == Data("# x".utf8), "both landed in one pass")
        #expect(materializer.scan(name: "B").isEmpty, "nothing the materializer wrote is an edit")
    }

    // MARK: Whole or nothing

    /// A Mac as a receiver: its own store and pi home, with the extensions and skills sources.
    final class Receiver {
        let dir: URL
        let store: FleetStore
        let materializer: FleetMaterializer
        let imports: YourPiImport
        let home: PiHome
        let skills: SkillsStore

        init() throws {
            dir = try makeTempDirectory()
            store = try FleetStore(directory: dir.appendingPathComponent("store"), mac: UUID())
            materializer = FleetMaterializer(store: store, directory: dir.appendingPathComponent("store"))
            home = PiHome(directory: dir.appendingPathComponent("pi"),
                          engine: PiEngine(command: ["/usr/bin/false"], packageDirectory: nil, version: nil, node: .executable("/usr/bin/false")))
            try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
            imports = YourPiImport(home: home, yourPi: nil, userHome: dir.path, log: { _ in })
            skills = SkillsStore(directory: dir.appendingPathComponent("skills"), stateDirectory: dir.appendingPathComponent("skills-state"))
            materializer.add(FleetExtensionsSource(imports))
            materializer.add(FleetSkillsSource(skills))
        }

        /// What pi would load from settings.json `extensions`.
        func listed() -> [String] {
            let json = (try? JSONSerialization.jsonObject(with: Data(contentsOf: home.settings))) as? [String: Any]
            return json?["extensions"] as? [String] ?? []
        }

        func file(_ relative: String) -> URL { home.directory.appendingPathComponent("your-extensions/" + relative) }
    }

    /// The ops another Mac made, as they reach a receiver: every op at once, but only the blobs given.
    final class Sender {
        let store: FleetStore
        init(dir: URL) throws { store = try FleetStore(directory: dir.appendingPathComponent("sender"), mac: UUID()) }

        @discardableResult
        func blob(_ unit: String, _ text: String) -> FleetOp {
            let hash = store.putBlob(Data(text.utf8))!
            return store.appendLocal(unit: unit, change: .blob(hash: hash, size: text.utf8.count), seed: false, name: "Mac mini")!
        }

        @discardableResult
        func value(_ unit: String, _ json: Data) -> FleetOp {
            store.appendLocal(unit: unit, change: .value(String(decoding: json, as: UTF8.self)), seed: false, name: "Mac mini")!
        }

        func deliver(to receiver: Receiver, blobs: Set<String> = []) {
            for op in store.ops(after: receiver.store.vector) { _ = receiver.store.receive(op) }
            for hash in blobs { if let data = store.blob(hash) { _ = receiver.store.putBlob(data, named: hash) } }
        }

        func hash(_ text: String) -> String { FleetSyncProtocol.hash(Data(text.utf8)) }
    }

    static func extensionMeta(on: Bool = true, _ files: [String: String]) -> Data {
        FleetExtensionsSource.json(.init(name: "acme", entries: ["index.ts"], on: on,
                                         digest: FleetTreeDigest.of(files.mapValues { FleetSyncProtocol.hash(Data($0.utf8)) })))
    }

    @Test func anExtensionIsNeverListedUntilEveryOneOfItsFilesIsHere() throws {
        let receiver = try Receiver()
        defer { try? FileManager.default.removeItem(at: receiver.dir) }
        let sender = try Sender(dir: receiver.dir)
        let files = ["index.ts": "export default 1\n", "lib/helper.ts": "export const h = 1\n", "lib/more.ts": "export const m = 2\n"]
        for (path, text) in files.sorted(by: { $0.key < $1.key }) { sender.blob(FleetUnit.extensionFile("paths/acme/" + path), text) }
        sender.value(FleetUnit.extensionMeta("paths/acme"), Self.extensionMeta(files))

        // Every op is here, the blobs arrive one at a time, in any order: it is listed only after the last.
        var arrived: Set<String> = []
        for path in ["lib/more.ts", "index.ts", "lib/helper.ts"] {
            sender.deliver(to: receiver, blobs: arrived)
            _ = receiver.materializer.materialize(name: "Mac studio")
            let ops = receiver.materializer.scan(name: "Mac studio")
            #expect(ops.isEmpty, "a half written extension is never an edit \(ops.map { ($0.unit, $0.change) })")
            #expect(receiver.listed().isEmpty, "not listed while \(path) is missing")
            #expect(receiver.imports.state()?.extensionsOn.isEmpty != false)
            arrived.insert(sender.hash(files[path]!))
        }
        sender.deliver(to: receiver, blobs: arrived)
        _ = receiver.materializer.materialize(name: "Mac studio")
        #expect(receiver.listed() == [receiver.file("paths/acme/index.ts").standardizedFileURL.path])
        for (path, text) in files { #expect((try? String(contentsOf: receiver.file("paths/acme/" + path), encoding: .utf8)) == text) }
        #expect(receiver.materializer.scan(name: "Mac studio").isEmpty)
    }

    @Test func anExtensionThatIsOnIsTakenOutWhileASyncRewritesItAndPutBackWhole() throws {
        let receiver = try Receiver()
        defer { try? FileManager.default.removeItem(at: receiver.dir) }
        let sender = try Sender(dir: receiver.dir)
        let first = ["index.ts": "v1\n", "lib/helper.ts": "h1\n"]
        for (path, text) in first.sorted(by: { $0.key < $1.key }) { sender.blob(FleetUnit.extensionFile("paths/acme/" + path), text) }
        sender.value(FleetUnit.extensionMeta("paths/acme"), Self.extensionMeta(first))
        sender.deliver(to: receiver, blobs: Set(first.values.map(sender.hash)))
        _ = receiver.materializer.materialize(name: "Mac studio")
        let entry = receiver.file("paths/acme/index.ts").standardizedFileURL.path
        #expect(receiver.listed() == [entry])

        // An update changes both files; only one of them arrives at first.
        let second = ["index.ts": "v2\n", "lib/helper.ts": "h2\n"]
        for (path, text) in second.sorted(by: { $0.key < $1.key }) { sender.blob(FleetUnit.extensionFile("paths/acme/" + path), text) }
        sender.value(FleetUnit.extensionMeta("paths/acme"), Self.extensionMeta(second))
        sender.deliver(to: receiver, blobs: Set(first.values.map(sender.hash) + [sender.hash("v2\n")]))
        _ = receiver.materializer.materialize(name: "Mac studio")
        #expect(receiver.listed().isEmpty, "index.ts is new and helper.ts old: pi must not load it")
        #expect(receiver.imports.state()?.extensionsOn.count == 1, "it is still on: only held")
        #expect(receiver.materializer.scan(name: "Mac studio").isEmpty, "and the hold is not an edit of its meta")

        sender.deliver(to: receiver, blobs: Set(second.values.map(sender.hash)))
        _ = receiver.materializer.materialize(name: "Mac studio")
        #expect(receiver.listed() == [entry])
        #expect((try? String(contentsOf: receiver.file("paths/acme/lib/helper.ts"), encoding: .utf8)) == "h2\n")
        #expect(receiver.imports.heldExtensions().isEmpty)
        #expect(receiver.materializer.scan(name: "Mac studio").isEmpty)
    }

    @Test func aSkillIsNotWhereTheAgentReadsUntilEveryOneOfItsFilesIsHere() throws {
        let receiver = try Receiver()
        defer { try? FileManager.default.removeItem(at: receiver.dir) }
        let sender = try Sender(dir: receiver.dir)
        let files = ["SKILL.md": "---\nname: pdf\ndescription: PDFs.\n---\n", "scripts/run.sh": "#!/bin/sh\n", "reference.md": "# Ref\n"]
        for (path, text) in files.sorted(by: { $0.key < $1.key }) { sender.blob(FleetUnit.skillFile("pdf", path), text) }
        let state = FleetSkillsSource.json(.init(on: true, source: nil,
                                                 digest: FleetTreeDigest.of(files.mapValues { FleetSyncProtocol.hash(Data($0.utf8)) })))
        sender.value(FleetUnit.skill("pdf"), state)

        // SKILL.md is the last to arrive: files of a skill nobody has listed yet are still files here, not deletions.
        var arrived: Set<String> = [sender.hash(files["scripts/run.sh"]!)]
        for path in ["reference.md", "SKILL.md"] {
            sender.deliver(to: receiver, blobs: arrived)
            _ = receiver.materializer.materialize(name: "Mac studio")
            #expect(receiver.materializer.scan(name: "Mac studio").isEmpty)
            #expect(!FileManager.default.fileExists(atPath: receiver.skills.directory.appendingPathComponent("pdf").path),
                    "SKILL.md is here but \(path) is not: pi must not see the skill")
            arrived.insert(sender.hash(files[path]!))
        }
        sender.deliver(to: receiver, blobs: arrived)
        _ = receiver.materializer.materialize(name: "Mac studio")
        let there = receiver.skills.directory.appendingPathComponent("pdf")
        for (path, text) in files { #expect((try? String(contentsOf: there.appendingPathComponent(path), encoding: .utf8)) == text) }
        #expect(receiver.skills.snapshot().skills.map(\.name) == ["pdf"] && receiver.skills.snapshot().skills.first?.isOn == true)
        #expect(receiver.materializer.scan(name: "Mac studio").isEmpty)
    }
}
