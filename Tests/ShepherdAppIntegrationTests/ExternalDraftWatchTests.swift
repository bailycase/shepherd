import AppKit
import Foundation
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Open in ▾'s watch on the real file system: an editor's save (an atomic replace, a new inode each time) reaches
/// the draft without a manual check, again and again.
@Suite("External draft watch", .mainActorExclusive)
@MainActor
struct ExternalDraftWatchTests {
    @Test func everyAtomicSaveReachesTheDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xdw-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "AGENTS.md", root: root)
        var latest = ""
        draft.start(text: "typed in app") { latest = $0 }
        for text in ["first save", "second save", "third save"] {
            try text.write(to: draft.url, atomically: true, encoding: .utf8)
            try await eventuallyOnMain("the draft takes \(text)") { latest == text }
        }
        draft.stop()
    }

    /// Launch Services names an app for a file only once it exists, so the button's menu prepares the file first.
    @Test func preparingMakesTheFileTheMenuAsksAbout() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xdp-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "hook.json", root: root)
        draft.prepare()
        #expect(FileManager.default.fileExists(atPath: draft.url.path))
        draft.stop()
        #expect(!FileManager.default.fileExists(atPath: draft.folder.path))
    }

    /// Leaving the input (a space switch re-keys its button) ends the watch: a late save in the other app reaches nothing.
    @Test func aSaveAfterStopChangesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xds-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = ExternalDraft(name: "keep-home.txt", root: root)
        var fieldsOfB = "b's text"
        a.start(text: "a's text") { fieldsOfB = $0 }
        a.stop()
        try? FileManager.default.createDirectory(at: a.folder, withIntermediateDirectories: true)
        try "late save".write(to: a.url, atomically: true, encoding: .utf8)
        a.check()
        try await Task.sleep(for: .milliseconds(400))
        #expect(fieldsOfB == "b's text")
    }

    /// The save is read in the event handler, not after the debounce.
    @Test func aSaveIsAppliedBeforeTheDebounceEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xdi-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "AGENTS.md", root: root)
        var latest = ""
        draft.start(text: "typed") { latest = $0 }
        try "saved".write(to: draft.url, atomically: true, encoding: .utf8)
        try await eventuallyOnMain("applied within the debounce", timeout: .seconds(ExternalDraft.debounce / 2)) { latest == "saved" }
        draft.stop()
    }

    /// A save made while the file events were still being re-armed is found when Shepherd becomes active.
    @Test func becomingActiveChecksEveryLiveDraft() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "xda-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "AGENTS.md", root: root)
        var latest = ""
        draft.start(text: "typed") { latest = $0 }
        try "missed".write(to: draft.url, atomically: true, encoding: .utf8)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(latest == "missed")
        draft.stop()
    }
}
