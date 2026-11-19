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
}
