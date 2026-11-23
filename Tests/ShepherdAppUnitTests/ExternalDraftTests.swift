import Foundation
import Testing
@testable import ShepherdApp

/// Open in ▾ for a text input: the draft goes to a temp file, each external save (an atomic replace, as editors do)
/// replaces the draft, and leaving the screen removes the folder.
@MainActor @Suite("External draft")
struct ExternalDraftTests {
    private func scratch() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "xd-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
    }

    @Test func writesTheDraftAndTakesEachExternalSave() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "AGENTS.md", root: root)
        var seen: [String] = []
        draft.start(text: "typed in app") { seen.append($0) }
        #expect(try String(contentsOf: draft.url, encoding: .utf8) == "typed in app")
        #expect(draft.url.lastPathComponent == "AGENTS.md")

        for text in ["first save", "second save"] {
            let temp = draft.folder.appending(path: ".swap")
            try text.write(to: temp, atomically: false, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(draft.url, withItemAt: temp)
            draft.check()
        }
        #expect(seen == ["first save", "second save"])
        draft.check()
        #expect(seen.count == 2)
        draft.stop()
    }

    @Test func openingAgainRewritesTheFile() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "hook.json", root: root)
        draft.start(text: "one") { _ in }
        draft.start(text: "two") { _ in }
        #expect(try String(contentsOf: draft.url, encoding: .utf8) == "two")
        draft.stop()
    }

    @Test func stopRemovesTheFolderAndIgnoresLaterChecks() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let draft = ExternalDraft(name: "mcp.json", root: root)
        var seen = 0
        draft.start(text: "{}") { _ in seen += 1 }
        #expect(FileManager.default.fileExists(atPath: draft.folder.path))
        draft.stop()
        #expect(!FileManager.default.fileExists(atPath: draft.folder.path))
        draft.check()
        #expect(seen == 0 && !draft.isWatching)
    }
}
