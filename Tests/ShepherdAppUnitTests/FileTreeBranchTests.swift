import Testing
@testable import ShepherdApp

@Suite("File tree branch updates")
@MainActor
struct FileTreeBranchTests {
    @Test func updatesVisitOnlySeparatorDelimitedAncestors() {
        func node(_ path: String, children: [FileNode]? = nil) -> FileNode {
            FileNode(id: path, name: path, isDirectory: true, isSymlink: false, children: children)
        }
        let siblings = (0..<100).map { index in
            node("/root/branch\(index)", children: (0..<100).map { node("/root/branch\(index)/child\($0)") })
        }
        let root = node("/root", children: siblings)
        var visited: [String] = []
        let updated = FileTreeModel.applyUpdate(to: root, path: "/root/branch99/child99", visited: { visited.append($0) }) {
            $0.lineCount = 42
        }
        #expect(visited == ["/root", "/root/branch99", "/root/branch99/child99"])
        #expect(updated.children?.last?.children?.last?.lineCount == 42)
        #expect(updated.children?.first == root.children?.first)
        #expect(!FileTreeModel.contains("/root/branch99", under: "/root/branch9"))
        #expect(FileTreeModel.contains("/root", under: "/"))
        #expect(FileTreeModel.applyUpdate(to: root, path: "/root/absent") { $0.error = "wrong" } == root)
    }
}
