import Foundation
import Testing
import ShepherdTestSupport
import ShepherdProtocol
@testable import ShepherdApp

/// The Files tab's editor: a save writes only over the version it was edited from, a change on
/// disk reaches a clean editor and never replaces unsaved edits, and neither side is lost.
@Suite("File editing", .serialized, .integrationTimeLimit)
@MainActor
struct FileEditingTests {
    private func open(_ text: String) async throws -> (URL, URL, FileTreeModel) {
        let root = try makeScratchDirectory("fedit")
        let file = root.appendingPathComponent("Checkout.tsx")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let model = FileTreeModel(rootPath: root.path)
        await model.loadRoot()
        await model.select(path: file.path)
        return (root, file, model)
    }

    private func disk(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @Test func saveWritesTheEditInPlace() async throws {
        let (root, file, model) = try await open("one\ntwo\n")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.canEdit)
        let inode = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        model.setText("one\n2\n", for: file.path)
        #expect(model.edits[file.path]?.isDirty == true)
        await model.save()
        #expect(try disk(file) == "one\n2\n")
        #expect(model.edits[file.path]?.isDirty == false && model.saveError == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int == inode,
                "written in place: links and mode stay")
    }

    @Test func aCleanEditorTakesTheAgentsChangeAndMarksIt() async throws {
        let (root, file, model) = try await open("a\nb\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let revision = model.textRevision
        try "a\nB\n".write(to: file, atomically: true, encoding: .utf8)
        await model.checkDisk()
        let edit = try #require(model.edits[file.path])
        #expect(edit.text == "a\nB\n" && edit.saved == "a\nB\n" && edit.before == "a\nb\n" && edit.conflict == nil)
        #expect(model.textRevision != revision, "the editor resets to the new text")
    }

    @Test func aChangeUnderUnsavedEditsIsAConflictAndNothingIsOverwritten() async throws {
        let (root, file, model) = try await open("a\nb\n")
        defer { try? FileManager.default.removeItem(at: root) }
        model.setText("mine\nb\n", for: file.path)
        try "a\ntheirs\n".write(to: file, atomically: true, encoding: .utf8)
        await model.checkDisk()
        #expect(model.edits[file.path]?.text == "mine\nb\n", "unsaved edits stay")
        #expect(model.edits[file.path]?.conflict == "a\ntheirs\n")
        await model.save()
        #expect(try disk(file) == "a\ntheirs\n", "Save doesn't write over the newer version")
        await model.save(overwrite: true)
        #expect(try disk(file) == "mine\nb\n", "Overwrite does, once asked")
        #expect(model.edits[file.path]?.conflict == nil && model.edits[file.path]?.isDirty == false)
    }

    @Test func aChangeLandingBeforeTheSaveIsCaughtByTheSave() async throws {
        let (root, file, model) = try await open("a\n")
        defer { try? FileManager.default.removeItem(at: root) }
        model.setText("mine\n", for: file.path)
        try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
        await model.save()
        #expect(try disk(file) == "theirs\n")
        #expect(model.edits[file.path]?.conflict == "theirs\n" && model.edits[file.path]?.text == "mine\n")
        model.revert()
        #expect(model.edits[file.path]?.text == "theirs\n" && model.edits[file.path]?.isDirty == false)
        #expect(model.edits[file.path]?.conflict == nil && model.edits[file.path]?.before == "a\n")
        #expect(try disk(file) == "theirs\n")
    }

    @Test func closingATabDropsItsEditsAndAReopenReadsTheDisk() async throws {
        let (root, file, model) = try await open("a\n")
        defer { try? FileManager.default.removeItem(at: root) }
        model.setText("b\n", for: file.path)
        await model.closeTab(file.path)
        #expect(model.edits[file.path] == nil)
        await model.select(path: file.path)
        #expect(model.edits[file.path]?.text == "a\n")
    }

    @Test func aWriteNeverLeavesTheRoot() async throws {
        let root = try makeScratchDirectory("fedit")
        let outside = try makeScratchDirectory("fedit-outside")
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.txt")
        try "secret".write(to: secret, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let realRoot = try #require(ThreadFileSystem.canonicalRealpath(root.path))
        let result = FileTreeModel.safeWriteFile(path: link.path, resolvedRoot: realRoot, text: "owned", expected: "secret")
        #expect(result == .failed(ThreadFileError.outsideRoot.localizedDescription))
        #expect(try String(contentsOf: secret, encoding: .utf8) == "secret")
    }

    @Test func aRemoteTreeIsReadOnly() async throws {
        let source = FileTreeSource(list: { _, _ in .success([]) }, read: { _ in .success(.text(["a"], "txt")) })
        let model = FileTreeModel(rootPath: "/remote/acme-web", source: source)
        await model.select(path: "/remote/acme-web/a.txt")
        #expect(!model.canEdit)
        model.setText("b", for: "/remote/acme-web/a.txt")
        await model.save()
        #expect(model.edits["/remote/acme-web/a.txt"]?.saved == "a")
    }
}
