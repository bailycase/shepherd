import Foundation
import ShepherdCore
import ShepherdProtocol

// Revert one file of a working-tree review from a remote client (`RemoteAgentQuery.changesRevertFile`,
// `changes.revert.v1`): what the Mac's review pane does locally with Revert File, fenced to the
// version the client displayed.
extension ChangesService {
    /// Puts one file back as HEAD has it. `revision` must be an uncommitted list's: `old` HEAD
    /// (the empty tree before the first commit) and `new` a snapshot the file still matches,
    /// so a file that changed since the client read it is refused (`changedSince`) and nothing
    /// is touched. A modified or deleted file is restored from HEAD, a new one is moved to the
    /// Trash, a rename restores `oldPath` and trashes `path`. The index, HEAD and refs stay as
    /// they are, as with Undo.
    public func revertFile(agentID: AgentID, revision: ChangesRevision, path: String, oldPath: String? = nil,
                           cwd: String? = nil) async throws {
        let context = try context(agentID, cwd: cwd)
        try await perform {
            try self.revertFileNow(try self.repository(context.cwd), revision: revision, path: path, oldPath: oldPath)
        }
    }

    func revertFileNow(_ repository: Repository, revision: ChangesRevision, path: String, oldPath: String?) throws {
        let paths = [path] + (oldPath.map { [$0] } ?? [])
        guard paths.allSatisfy(Self.isSafePath) else { throw ChangesError(ChangesError.invalid, "Not a file of the repository.") }
        guard revision.isWellFormed, exists(revision.old, in: repository), exists(revision.new, in: repository) else {
            throw ChangesError(ChangesError.unavailable, "The review’s snapshot is no longer available. Refresh the review first.")
        }
        // The uncommitted list's `old` is HEAD's commit, or the empty tree before the first commit.
        let head = try commit("HEAD", in: repository) ?? emptyTree(repository)
        guard revision.old == head else {
            throw ChangesError(ChangesError.invalid, "Only a review of the working tree against HEAD can revert a file.")
        }
        let operation = restoreLock(for: repository)
        operation.lock()
        defer { operation.unlock() }
        let current = try snapshot(repository).tree
        let changed = try ChangesGit.checked(["diff", "--no-ext-diff", "--name-only", "--no-renames", "-z", revision.new, current, "--"] + paths,
                                             in: repository.root, literalPaths: true)
            .stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard changed.isEmpty else {
            throw ChangesError(ChangesError.changedSince, "\((path as NSString).lastPathComponent) changed since you read it, so Shepherd left it as it is.",
                               files: changed)
        }
        let root = URL(fileURLWithPath: repository.root, isDirectory: true)
        let inHead = { (file: String) -> Bool in self.exists("\(revision.old):\(file)", in: repository) }
        if let oldPath {
            guard inHead(oldPath) else { throw ChangesError(ChangesError.invalid, "\(oldPath) is not in HEAD.") }
            try restoreFiles(repository, from: revision.old, paths: [oldPath])
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) { try trash(root.appendingPathComponent(path)) }
        } else if inHead(path) {
            try restoreFiles(repository, from: revision.old, paths: [path])
        } else {
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else {
                throw ChangesError(ChangesError.invalid, "\(path) is neither in HEAD nor in the working tree.")
            }
            try trash(root.appendingPathComponent(path))
        }
    }

    /// A path a client may name: relative, inside the working tree, never an option.
    static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4096 && !path.hasPrefix("/") && !path.hasPrefix("-") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == ".git" }
    }
}
