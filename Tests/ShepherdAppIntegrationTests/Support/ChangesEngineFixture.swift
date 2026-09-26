import Foundation
import ShepherdProtocol
@testable import ShepherdApp

extension ChangesEngine {
    /// An engine that answers every scope with `files` (Uncommitted's working tree against HEAD):
    /// for tests that seed a review without git.
    @MainActor static func fixed(_ files: [DiffFile]) -> ChangesEngine {
        func list(_ scope: ChangesScope) -> ChangesList {
            ChangesList(scope: scope, revision: ChangesRevision(old: "aaaa", new: "bbbb"),
                        comparison: ChangesComparison(head: "Working tree", base: "HEAD"),
                        files: files.map { file in
                            ChangesFile(path: file.displayPath, status: file.isNew ? .added : file.isDeleted ? .deleted : .modified,
                                        added: file.addedCount, removed: file.removedCount)
                        })
        }
        return ChangesEngine(
            overview: { ChangesOverview(repository: "/tmp", defaultScope: .uncommitted) },
            list: { scope, _ in list(scope) },
            diffs: { _, _ in (files, []) },
            file: { _, file, _ in ChangesFileDiff(file: files.first { $0.id == file.id } ?? files[0]) },
            branches: { ChangesBranches(defaultBase: nil, branches: []) },
            patch: { _, _ in ("", false) })
    }
}
