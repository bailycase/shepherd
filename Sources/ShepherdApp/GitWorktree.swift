import Foundation

/// The New Agent sheet's "worktree" option: create a git worktree beside the
/// checkout and start the agent there. This is the one deliberate exception
/// to "Shepherd does not mutate repository state" — explicit, user-initiated,
/// and additive (a new branch + directory; nothing existing is touched).
enum GitWorktree {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Cheap probe for showing the sheet row. `.git` may be a directory (a
    /// primary checkout) or a file (an existing worktree).
    static func isRepo(_ path: String) -> Bool {
        FileManager.default.fileExists(
            atPath: ((path as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(".git")
        )
    }

    /// `git worktree add -b <branch> <repo>-<branch>` — a sibling of the
    /// checkout, so repo tooling that scans the repo itself never sees it.
    /// Returns the new worktree's absolute path.
    static func add(repo: String, branch: String) throws -> String {
        let repoPath = (repo as NSString).expandingTildeInPath
        // Branch names may contain '/'; the directory name must not.
        let directoryName = ((repoPath as NSString).lastPathComponent)
            + "-" + branch.replacingOccurrences(of: "/", with: "-")
        let destination = ((repoPath as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(directoryName)
        guard !FileManager.default.fileExists(atPath: destination) else {
            throw Failure(message: "\(destination) already exists")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repoPath, "worktree", "add", "-b", branch, destination]
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw Failure(message: "git not available: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: detail.isEmpty ? "git worktree add failed" : detail)
        }
        return destination
    }
}
