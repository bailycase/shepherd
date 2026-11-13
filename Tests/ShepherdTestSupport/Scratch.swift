// Every integration test that imports this module also gets ShepherdTestKit (scratch
// directories, ScratchDefaults, Locked) and, through it, the load-time process isolation.
@_exported import ShepherdTestKit
import Foundation

/// A git repository in a scratch directory with one commit, for review and worktree tests.
public func makeScratchRepo(files: [String: String] = ["README.md": "# scratch\n"]) throws -> URL {
    let dir = try makeScratchDirectory("repo")
    for (path, contents) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Shepherd Tests"],
                 ["config", "user.email", "tests@example.com"], ["add", "."], ["commit", "-qm", "initial"]] {
        try git(args, in: dir)
    }
    return dir
}

/// Run git in `dir`; a non-zero exit throws `CommandFailure` carrying git's stderr.
@discardableResult
public func git(_ args: [String], in dir: URL) throws -> String {
    // Spawned and waited for directly, with output in files. A `Pipe` made here is inherited by any process another test thread starts in
    // the meantime (a stub pi that lives as long as its test), and reading to the end then waits for that process, not for git; and
    // `Process.waitUntilExit()` on the main thread runs the run loop, so a main-actor test that starts another job in its wait can only
    // return after every job started inside it has returned, however long they take.
    let outputs = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputs) }
    let (outURL, errURL) = (outputs.appendingPathComponent("out"), outputs.appendingPathComponent("err"))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 1, outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_addopen(&actions, 2, errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addchdir_np(&actions, dir.path)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let arguments = ["/usr/bin/git"] + args
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { environment.forEach { free($0) } }
    var pid: pid_t = 0
    let started = posix_spawn(&pid, "/usr/bin/git", &actions, &attributes, argv, environment)
    guard started == 0 else { throw CommandFailure("git \(args.joined(separator: " "))", "could not start: \(String(cString: strerror(started)))") }
    var status: Int32 = 0
    while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
    let exitCode = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)

    let data = (try? Data(contentsOf: outURL)) ?? Data()
    let errors = (try? Data(contentsOf: errURL)) ?? Data()
    guard exitCode == 0 else {
        let stderr = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandFailure("git \(args.joined(separator: " "))", "exit \(exitCode)\(stderr.isEmpty ? "" : ": \(stderr)")")
    }
    return String(decoding: data, as: UTF8.self)
}
