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
    // Files, not pipes: a pipe's write end made here is inherited by any process another test thread starts in the meantime (a stub pi
    // that lives as long as its test), and reading to the end then waits for that process, not for git.
    let outputs = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outputs, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outputs) }
    let (outURL, errURL) = (outputs.appendingPathComponent("out"), outputs.appendingPathComponent("err"))
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = dir
    let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
    process.standardOutput = out
    process.standardError = err
    // Not `waitUntilExit()`: on the main thread it runs the run loop while it waits, and a main-actor test that starts another job there
    // can only return after every job started inside its wait has returned, however long they take.
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try process.run()
    exited.wait()
    try? out.close()
    try? err.close()
    let data = (try? Data(contentsOf: outURL)) ?? Data()
    let errors = (try? Data(contentsOf: errURL)) ?? Data()
    guard process.terminationStatus == 0 else {
        let stderr = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandFailure("git \(args.joined(separator: " "))", "exit \(process.terminationStatus)\(stderr.isEmpty ? "" : ": \(stderr)")")
    }
    return String(decoding: data, as: UTF8.self)
}
