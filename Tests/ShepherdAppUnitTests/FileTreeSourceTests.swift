import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
import Testing
@testable import ShepherdApp

/// The Files pane over a remote thread's host (`files.v1`): the tree keeps its own paths under the host's folder and asks the
/// host relative to it.
@Suite("File tree source")
@MainActor
struct FileTreeSourceTests {
    @Test func treePathsGoToTheHostRelativeToTheFolder() {
        #expect(FileTreeSource.relative("/host/repo", root: "/host/repo") == "")
        #expect(FileTreeSource.relative("/host/repo/Sources/App.swift", root: "/host/repo") == "Sources/App.swift")
        #expect(FileTreeSource.relative("/host/repo/a", root: "/host/repo/") == "a")
    }

    @Test func aTreeReadsItsSourceAndKeepsItsOwnPaths() async {
        let asked = Locked<[String]>([])
        let source = FileTreeSource(list: { path, _ in
            asked.withValue { $0.append(FileTreeSource.relative(path, root: "/host/repo")) }
            return .success(path == "/host/repo" ? [ThreadFileEntry(name: "Sources", kind: .directory),
                                                    ThreadFileEntry(name: "README.md", kind: .file, size: 9)] : [])
        }, read: { _ in FileTreeModel.content(text: Data("# Hi\n".utf8), ext: "md") })
        let model = FileTreeModel(rootPath: "/host/repo", source: source)
        await model.loadRoot()
        #expect(model.visibleNodes().map(\.node.id) == ["/host/repo/Sources", "/host/repo/README.md"])
        await model.expand(path: "/host/repo/Sources")
        #expect(asked.current == ["", "Sources"])
        await model.select(path: "/host/repo/README.md")
        #expect(model.selectedContent == .text(["# Hi", ""], "md"))
    }
}
