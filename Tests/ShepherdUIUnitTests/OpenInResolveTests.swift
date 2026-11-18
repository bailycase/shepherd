import Foundation
import Testing
@testable import ShepherdUI

/// A file row's Open in finds the file it names on this Mac: the agent's paths against its folder, a recorded turn's against
/// the repository's top above it, never a same-named file outside the repository, and nothing for a folder, a missing file
/// or a remote agent's thread.
@Suite("Open in resolves a row's file")
struct OpenInResolveTests {
    /// repo/.git, repo/README.md, repo/app/src/main.ts, repo/app/notes.md; outside it, ~/stray.md beside repo.
    private static func fixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appending(path: "openin-\(UUID().uuidString)", directoryHint: .isDirectory)
        let repo = base.appending(path: "repo")
        for folder in [".git", "app/src"] {
            try FileManager.default.createDirectory(at: repo.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["README.md", "app/src/main.ts", "app/notes.md", "../stray.md"] {
            try Data("x".utf8).write(to: repo.appending(path: file).standardizedFileURL)
        }
        return base.resolvingSymlinksInPath()
    }

    @Test func pathsResolveInTheAgentsFolderThenUpToTheRepositoryTop() throws {
        let base = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appending(path: "repo/app")
        #expect(SHOpenIn.resolve("src/main.ts", root: app)?.path == app.appending(path: "src/main.ts").path, "the agent's own path")
        #expect(SHOpenIn.resolve("notes.md", root: app)?.path == app.appending(path: "notes.md").path)
        #expect(SHOpenIn.resolve("app/src/main.ts", root: app)?.path == app.appending(path: "src/main.ts").path,
                "a recorded turn's path, from the repository's top")
        #expect(SHOpenIn.resolve("README.md", root: app)?.path == base.appending(path: "repo/README.md").path)
        #expect(SHOpenIn.resolve(app.appending(path: "notes.md").path, root: app) != nil, "an absolute path as it is")
    }

    @Test func nothingResolvesOutsideTheRepositoryForAFolderOrWithoutTheFiles() throws {
        let base = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: base) }
        let app = base.appending(path: "repo/app")
        #expect(SHOpenIn.resolve("stray.md", root: app) == nil, "a file above the repository's top is someone else's")
        #expect(SHOpenIn.resolve("src", root: app) == nil, "a folder")
        #expect(SHOpenIn.resolve("src/gone.ts", root: app) == nil, "a deleted file")
        #expect(SHOpenIn.resolve("src/main.ts", root: nil) == nil, "a remote agent's files aren't here")
        let outside = base.appending(path: "repo/app/src")
        try FileManager.default.removeItem(at: base.appending(path: "repo/.git"))
        #expect(SHOpenIn.resolve("notes.md", root: outside) == nil, "outside a repository, only the agent's folder")
        #expect(SHOpenIn.resolve("main.ts", root: outside) != nil)
    }
}
