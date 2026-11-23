import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

struct DesignThreadNotesStoreTests {
    private static let id = DesignID(rawValue: "sample-design")
    private static let kept = DesignThreadNote(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        agentID: AgentID(rawValue: "thread-one"), thread: "Checkout", board: DesignPath("checkout.dc.html")!,
        revision: 3, text: "Implemented the checkout.", createdAt: 1000)
    private static let added = DesignThreadNote(agentID: AgentID(rawValue: "thread-two"), thread: "Review",
        board: kept.board, revision: 4, text: "Checked the mobile layout.", createdAt: 2000)

    private static func withStore(read: @escaping (URL) throws -> Data? = DesignStore.readNotesBytes,
                                  stage: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1) },
                                  _ test: (DesignStore, URL) async throws -> Void) async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesignStore(directory: root, readNotesBytes: read, stageNotesBytes: stage)
        _ = try await store.create(id, title: "Checkout", at: Date(timeIntervalSince1970: 0))
        let file = try #require(store.folder(for: id)).appendingPathComponent("thread-notes.json")
        try await test(store, file)
    }

    private static func bytes(_ notes: [DesignThreadNote]) throws -> Data {
        try JSONEncoder().encode(DesignThreadNotes(notes: notes))
    }

    private static func unavailable<T>(_ operation: () async throws -> T) async throws -> String? {
        do { _ = try await operation(); return nil }
        catch DesignStoreError.threadNotesUnavailable(let message) { return message }
    }

    @Test(arguments: ["truncated", "null", "wrong type", "extra key", "bad envelope version", "missing value",
                      "legacy version", "bad note", "invalid UTF-8", "UTF-16", "BOM-less UTF-16", "BOM-less UTF-32"])
    func damageRefusesReadsAndBothNoteWriters(shape: String) async throws {
        try await Self.withStore { store, file in
            let valid = #"{"version":1,"notes":[]}"#
            let input: Data
            switch shape {
            case "truncated": input = Data(#"{"version":1,"notes":["#.utf8)
            case "null": input = Data(#"{"version":1,"value":null}"#.utf8)
            case "wrong type": input = Data(#"{"version":1,"value":[]}"#.utf8)
            case "extra key": input = Data(#"{"version":1,"value":\#(valid),"extra":true}"#.utf8)
            case "bad envelope version": input = Data(#"{"version":"1","value":\#(valid)}"#.utf8)
            case "missing value": input = Data(#"{"version":1}"#.utf8)
            case "legacy version": input = Data(#"{"version":2,"notes":[]}"#.utf8)
            case "bad note": input = Data(#"{"version":1,"notes":[{}]}"#.utf8)
            case "invalid UTF-8":
                // The structure and model are valid. Only an ignored string field has invalid bytes.
                input = Data(#"{"version":1,"notes":[],"extra":""#.utf8) + Data([0xff]) + Data(#""}"#.utf8)
            case "BOM-less UTF-16": input = try #require(valid.data(using: .utf16LittleEndian))
            case "BOM-less UTF-32": input = try #require(valid.data(using: .utf32BigEndian))
            default: input = try #require(valid.data(using: .utf16))
            }
            try input.write(to: file)
            let warning = try await store.snapshot(Self.id).threadNotesWarning
            #expect(warning?.contains("\(file.path) on the host") == true)
            #expect(warning?.contains("restore a backup, or move or delete the file to start with no notes") == true)
            if shape == "invalid UTF-8" { #expect(warning?.contains("not UTF-8") == true) }
            #expect(try await Self.unavailable { try await store.threadNotes(Self.id) } != nil)
            #expect(try await Self.unavailable { try await store.removeThreadNote(Self.id, noteID: Self.kept.id) } != nil)
            #expect(try await Self.unavailable { try await store.addThreadNote(Self.id, Self.added) } != nil)
            #expect(try Data(contentsOf: file) == input)
        }
    }

    @Test(arguments: ["directory", "dangling link"])
    func existingUnreadablePathIsNotMissing(kind: String) async throws {
        try await Self.withStore { store, file in
            if kind == "directory" {
                try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
            } else {
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: file.appendingPathExtension("absent"))
            }
            let warning = try await store.snapshot(Self.id).threadNotesWarning
            #expect(warning == "Thread notes at \(file.path) on the host are unavailable because the file could not be read. "
                + "Fix access, restore a backup, or move or delete the file to start with no notes. Then refresh the design.")
            #expect(try await Self.unavailable { try await store.threadNotes(Self.id) } != nil)
            #expect(try await Self.unavailable { try await store.addThreadNote(Self.id, Self.added) } != nil)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.type] as? FileAttributeType == (kind == "directory" ? .typeDirectory : .typeSymbolicLink))
        }
    }

    @Test(arguments: ["repair", "restore", "move", "delete"])
    func recoversWithoutRestart(how: String) async throws {
        try await Self.withStore { store, file in
            try Data("broken".utf8).write(to: file)
            #expect(try await Self.unavailable { try await store.threadNotes(Self.id) } != nil)
            let backup = try Self.bytes([Self.kept])
            if how == "repair" { try backup.write(to: file) }
            if how == "restore" { try backup.write(to: file, options: .atomic) }
            if how == "move" { try FileManager.default.moveItem(at: file, to: file.appendingPathExtension("backup")) }
            if how == "delete" { try FileManager.default.removeItem(at: file) }
            #expect(try await store.snapshot(Self.id).threadNotesWarning == nil)
            let recovered = how == "move" || how == "delete" ? [] : [Self.kept]
            #expect(try await store.threadNotes(Self.id) == recovered)
            _ = try await store.addThreadNote(Self.id, Self.added)
            #expect(try await store.threadNotes(Self.id) == recovered + [Self.added])
        }
    }

    @Test func supportedEnvelopeStillWritesLegacyShape() async throws {
        try await Self.withStore { store, file in
            let original = try Self.bytes([Self.kept])
            try (Data(#"{"version":1,"value":"#.utf8) + original + Data("}".utf8)).write(to: file)
            #expect(try await store.threadNotes(Self.id) == [Self.kept])
            _ = try await store.addThreadNote(Self.id, Self.added)
            #expect(try JSONDecoder().decode(DesignThreadNotes.self, from: Data(contentsOf: file)).notes == [Self.kept, Self.added])
        }
    }

    @Test(arguments: [POSIXErrorCode.EMFILE, .EIO, .EAGAIN])
    func transientReadFailureRetries(error: POSIXErrorCode) async throws {
        var failures = 0  // Read and changed between completed DesignStore operations only.
        try await Self.withStore(read: { url in
            if failures > 0 { failures -= 1; throw POSIXError(error) }
            return try DesignStore.readNotesBytes(url)
        }) { store, file in
            let original = try Self.bytes([Self.kept])
            try original.write(to: file)
            failures = 2
            #expect(try await Self.unavailable { try await store.threadNotes(Self.id) } != nil)
            #expect(try await Self.unavailable { try await store.addThreadNote(Self.id, Self.added) } != nil)
            #expect(try Data(contentsOf: file) == original)
            #expect(try await store.threadNotes(Self.id) == [Self.kept])
            _ = try await store.addThreadNote(Self.id, Self.added)
            #expect(try await store.threadNotes(Self.id) == [Self.kept, Self.added])
        }
    }

    @Test func failedSaveReportsFailureAndCallerCanRetry() async throws {
        var failWrite = true
        try await Self.withStore(stage: { data, url in
            if failWrite { throw POSIXError(.ENOSPC) }
            try data.write(to: url)
        }) { store, file in
            let original = try Self.bytes([Self.kept])
            try original.write(to: file)
            await #expect(throws: DesignStoreError.self) { try await store.addThreadNote(Self.id, Self.added) }
            #expect(try Data(contentsOf: file) == original)
            failWrite = false
            try Data("broken".utf8).write(to: file)
            #expect(try await Self.unavailable { try await store.addThreadNote(Self.id, Self.added) } != nil)
            try original.write(to: file, options: .atomic)
            _ = try await store.addThreadNote(Self.id, Self.added)
            #expect(try await store.threadNotes(Self.id) == [Self.kept, Self.added])
        }
    }

    @Test(arguments: ["backup", "damage", "same bytes"])
    func rechecksContentAfterStaging(change: String) async throws {
        let original = try Self.bytes([Self.kept])
        let replacement = change == "backup" ? try Self.bytes([]) : change == "damage" ? Data("broken".utf8) : original
        var replaceWhileStaging = true
        try await Self.withStore(stage: { data, url in
            try data.write(to: url)
            if replaceWhileStaging {
                let live = url.deletingLastPathComponent().appendingPathComponent("thread-notes.json")
                try replacement.write(to: live, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date(timeIntervalSince1970: 0)],
                                                      ofItemAtPath: live.path)
            }
        }) { store, file in
            try Data("broken".utf8).write(to: file)
            #expect(try await Self.unavailable { try await store.threadNotes(Self.id) } != nil)
            try original.write(to: file, options: .atomic)
            if change == "same bytes" {
                _ = try await store.addThreadNote(Self.id, Self.added)
                #expect(try await store.threadNotes(Self.id) == [Self.kept, Self.added])
                return
            }
            if change == "damage" {
                #expect(try await Self.unavailable { try await store.addThreadNote(Self.id, Self.added) } != nil)
            } else {
                await #expect(throws: DesignStoreError.self) { try await store.addThreadNote(Self.id, Self.added) }
            }
            #expect(try Data(contentsOf: file) == replacement)
            replaceWhileStaging = false
            if change == "damage" { try original.write(to: file, options: .atomic) }
            _ = try await store.addThreadNote(Self.id, Self.added)
            #expect(try await store.threadNotes(Self.id) == (change == "backup" ? [] : [Self.kept]) + [Self.added])
        }
    }

    @Test func wholeDesignRemovalCannotDiscardDamagedNotes() async throws {
        try await Self.withStore { store, file in
            let damage = Data("broken".utf8)
            try damage.write(to: file)
            #expect(try await Self.unavailable { try await store.stageDeletion(Self.id) } != nil)
            #expect(try await Self.unavailable { try await store.delete(Self.id) } != nil)
            #expect((try? Data(contentsOf: file)) == damage)
            try Self.bytes([Self.kept]).write(to: file)
            #expect(try await store.stageDeletion(Self.id))
            let staged = try #require(store.stagedFolder(for: Self.id)).appendingPathComponent(file.lastPathComponent)
            try damage.write(to: staged)
            #expect(try await Self.unavailable { try await store.finishDeletion(Self.id) } != nil)
            #expect(store.removeLeftovers().isEmpty)
            #expect((try? Data(contentsOf: staged)) == damage)
        }
    }
}
