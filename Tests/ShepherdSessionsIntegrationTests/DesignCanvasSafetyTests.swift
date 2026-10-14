import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite(.integrationTimeLimit)
struct DesignCanvasSafetyTests {
    @Test func dryRunAndPageConfirmationProtectFilesAndExplicitCleanupRemovesOnlyUninstalledCopies() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips()])
        try await t.installSystem(h, design)
        _ = try await h.server.updateDesignIndex(design.id, patch: .object(["pages": .array([.object(["id": .string("p1"), "name": .string("Main")])])]))
        let before = try await h.server.designSnapshot(design.id)
        let files = t.files(h, design)
        let patch: JSONValue = .object(["pages": .array([]), "designSystems": .array([])])
        let dry = try await h.server.updateDesignIndex(design.id, patch: patch,
            options: .init(dryRun: true, removeSystems: ["acme"]))
        #expect(!dry.changed && dry.revision == before.revision)
        #expect(dry.canvasPlan?.removedPages == ["p1"] && dry.canvasPlan?.removedSystems == ["acme"])
        #expect(try await h.server.designSnapshot(design.id) == before && t.files(h, design) == files)
        do {
            _ = try await h.server.updateDesignIndex(design.id, patch: patch)
            Issue.record("pages were deleted without confirmation")
        } catch { #expect(String(describing: error).contains("allow_delete_pages")) }
        do {
            _ = try await h.server.updateDesignIndex(design.id, patch: .object([:]), options: .init(removeSystems: ["acme"]))
            Issue.record("an installed system folder was removed")
        } catch { #expect(String(describing: error).contains("uninstalled")) }
        _ = try await h.server.updateDesignIndex(design.id, patch: patch,
            options: .init(allowDeletePages: true, removeSystems: ["acme"]))
        #expect(t.files(h, design).keys.allSatisfy { !$0.hasPrefix("ds/acme/") })
        #expect(try await h.server.designSystems.read("acme").summary.namespace == "acme")
        let after = try await h.server.designSnapshot(design.id)
        #expect(after.usage?.files == t.files(h, design).count && after.usage?.fileLimit == 512)
    }

    @Test func aCanvasCommitFailureKeepsDeletedBoardsVersionsAndSystemCopies() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips()])
        try await t.installSystem(h, design)
        let before = try await h.server.designSnapshot(design.id)
        let files = t.files(h, design)
        let versions = try await h.server.designVersions(design.id, path: DesignToolsStoreTests.a)
        let folder = try #require(h.server.designs.folder(for: design.id))
        let revision = folder.appendingPathComponent("revision")
        try FileManager.default.removeItem(at: revision)
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        do {
            _ = try await h.server.updateDesignIndex(design.id,
                patch: .object(["boards": .object([DesignToolsStoreTests.a.rawValue: .null]), "designSystems": .array([])]),
                options: .init(removeSystems: ["acme"]))
            Issue.record("a canvas change committed without recording its revision")
        } catch { #expect(String(describing: error).contains("could not record the revision")) }
        #expect(t.files(h, design) == files)
        #expect(try await h.server.designSnapshot(design.id) == before)
        #expect(try await h.server.designVersions(design.id, path: DesignToolsStoreTests.a) == versions)
    }

    @Test func aFailedCheckpointCommitRollsBackBoardsCanvasAndSystemCopies() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips()])
        try await t.installSystem(h, design)
        _ = try await h.server.designCheckpoint(design.id, request: .init(action: .create, name: "saved"))
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips().replacingOccurrences(of: "Pay now", with: "Buy now")])
        let project = try #require(h.server.designs.projectFolder(for: design.id))
        try Data("body{color:red}".utf8).write(to: project.appendingPathComponent("ds/acme/tokens.css"))
        let before = try await h.server.designSnapshot(design.id)
        let files = t.files(h, design)
        let folder = try #require(h.server.designs.folder(for: design.id))
        let revision = folder.appendingPathComponent("revision")
        try FileManager.default.removeItem(at: revision)
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        do {
            _ = try await h.server.designCheckpoint(design.id, request: .init(action: .restore, name: "saved"))
            Issue.record("a restore committed without recording its revision")
        } catch { #expect(String(describing: error).contains("could not record the revision")) }
        #expect(t.files(h, design) == files)
        #expect(try await h.server.designSnapshot(design.id) == before)
    }

    @Test func systemInstallationValidatesAllPathsAndRollsBackAFailedRevisionCommit() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.installSystem(h, design)
        let before = try await h.server.designSnapshot(design.id)
        let original = t.files(h, design)
        let record = try #require(before.index.designSystems?.first)
        let tokens = try #require(original["ds/acme/tokens.json"])
        let valid: [String: Data] = ["tokens.json": tokens, "tokens.css": Data("body{color:red}".utf8)]
        var invalid = valid
        invalid["z/../escape.txt"] = Data("bad".utf8)
        do {
            _ = try await h.server.designs.installSystem(design.id, namespace: "acme", record: record, files: invalid, baseRevision: nil)
            Issue.record("an invalid path installed")
        } catch { #expect(String(describing: error).contains("escape.txt")) }
        #expect(t.files(h, design) == original)
        let revision = try #require(h.server.designs.folder(for: design.id)).appendingPathComponent("revision")
        try FileManager.default.removeItem(at: revision)
        try FileManager.default.createDirectory(at: revision, withIntermediateDirectories: true)
        do {
            _ = try await h.server.designs.installSystem(design.id, namespace: "acme", record: record, files: valid, baseRevision: nil)
            Issue.record("an installation committed without recording its revision")
        } catch { #expect(String(describing: error).contains("could not record the revision")) }
        #expect(t.files(h, design) == original)
        #expect(try await h.server.designSnapshot(design.id) == before)
    }

    @Test func supportFilesCountTowardTheExistingProjectFileLimit() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips()])
        let project = try #require(h.server.designs.projectFolder(for: design.id))
        _ = try await h.server.designSnapshot(design.id)
        let remaining = DesignStore.maxFiles - t.files(h, design).keys.filter { !$0.hasSuffix("support.js") }.count
        for number in 0..<remaining { try Data("x".utf8).write(to: project.appendingPathComponent("support-\(number).txt")) }
        let path = try DesignPath.validate("C.dc.html")
        do {
            _ = try await h.server.writeDesignBoards(design.id, sources: [path: DesignToolsStoreTests.chips()])
            Issue.record("a 513th project file was written")
        } catch { #expect(error as? DesignStoreError == .tooManyFiles) }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(path.rawValue).path))
    }

    @Test func aSystemCopyCheckpointRestoresItsExactFilesAndRefusesAMissingFontBeforeChangingAnything() async throws {
        let t = DesignToolsStoreTests()
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [DesignToolsStoreTests.a: DesignToolsStoreTests.chips()])
        try await t.installSystem(h, design)
        let project = try #require(h.server.designs.projectFolder(for: design.id))
        let font = project.appendingPathComponent("ds/acme/fonts/Face.woff2")
        try FileManager.default.createDirectory(at: font.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("wOF2saved".utf8).write(to: font)
        let saved = t.files(h, design)
        let checkpoint = try await h.server.designCheckpoint(design.id, request: .init(action: .create, name: "with font"))
        #expect(checkpoint.checkpoint?.systems == ["acme"])
        try Data("wOF2changed".utf8).write(to: font)
        _ = try await h.server.designCheckpoint(design.id, request: .init(action: .restore, name: "with font"))
        #expect(t.files(h, design) == saved)
        let folder = try #require(h.server.designs.folder(for: design.id)).appendingPathComponent("checkpoints")
        let entries = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let copy = try #require(entries.first {
            guard let data = try? Data(contentsOf: $0.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return manifest["name"] as? String == "with font"
        })
        try FileManager.default.removeItem(at: copy.appendingPathComponent("ds/acme/fonts/Face.woff2"))
        let before = try await h.server.designSnapshot(design.id)
        do {
            _ = try await h.server.designCheckpoint(design.id, request: .init(action: .restore, name: "with font"))
            Issue.record("a damaged system checkpoint restored")
        } catch { #expect(String(describing: error).contains("missing or linked")) }
        #expect(try await h.server.designSnapshot(design.id) == before && t.files(h, design) == saved)
    }
}
