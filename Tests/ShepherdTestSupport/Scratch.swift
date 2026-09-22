import Foundation

/// A short-pathed scratch directory, removed by the caller (`sun_path` caps socket paths at
/// 104 bytes, so it lives under /tmp when the temporary directory is long).
public func makeScratchDirectory(_ label: String = "shepherd") throws -> URL {
    var base = FileManager.default.temporaryDirectory
    if base.path.utf8.count > 70 { base = URL(fileURLWithPath: "/tmp") }
    let dir = base.appendingPathComponent("\(label)-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

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

/// Run git in `dir`, failing on a non-zero exit.
@discardableResult
public func git(_ args: [String], in dir: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = args
    process.currentDirectoryURL = dir
    let out = Pipe()
    process.standardOutput = out
    process.standardError = Pipe()
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw WaitTimeout(what: "git \(args.joined(separator: " ")) to succeed (exit \(process.terminationStatus))")
    }
    return String(decoding: data, as: UTF8.self)
}
