import Darwin
import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Fleet file watcher", .integrationTimeLimit)
struct FleetWatcherTests {
    @Test func registeringFilesUsesLinearDescriptors() async {
        // Isolate process-wide descriptor counts from other suites.
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try Self.measureDescriptors() }
        }
        expectScenarioCompleted(result)
        if let result { print(String(decoding: result.standardOutputContent, as: UTF8.self), terminator: "") }
    }

    private static func measureDescriptors() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let queue = DispatchQueue(label: "fleet-watcher-descriptors")
        let files = try (0..<150).map { n in
            let parent = scratch.appendingPathComponent("project-\(n)/.git")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let file = parent.appendingPathComponent("config")
            try Data("config".utf8).write(to: file)
            return file
        }
        for folder in [false, true] {
            for count in [25, 50, 100, 150] {
                try queue.sync {
                    let watcher = FleetWatcher(queue: queue) {}
                    defer { watcher.stop() }
                    let before = try descriptorCount()
                    var peak = before
                    // Fleet registers the whole batch in one queue turn. No source cancel handler
                    // can run between registrations, so sampling here includes pending closes.
                    for file in files.prefix(count) {
                        watcher.watch(file: file, folder: folder)
                        peak = max(peak, try descriptorCount())
                    }
                    let measurement = "\(count) files (folder: \(folder)): peak \(peak), baseline \(before), delta \(peak - before)"
                    print(measurement)
                    #expect(peak - before <= count * (folder ? 2 : 1) + 8, Comment(rawValue: measurement))
                }
            }
        }
    }

    // Unlike enumerating /dev/fd, this still works when no descriptors are left.
    private static func descriptorCount() throws -> Int {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        try #require(size > 0)
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 16)
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, &list, Int32(list.count * stride))
        try #require(bytes > 0)
        return Int(bytes) / stride
    }

    @Test(arguments: [false, true]) func noticesConsecutiveAtomicReplacements(folder: Bool) async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("config")
        try Data("original".utf8).write(to: file)
        try await checkChanges(to: file, folder: folder) { changed in
            for value in ["first", "second"] {
                try await changed("atomic replacement \(value)") { try Data(value.utf8).write(to: file, options: .atomic) }
            }
            try await changed("write to the replacement inode") { try Self.append(to: file) }
        }
    }

    @Test func noticesFileCreatedAfterRegistration() async throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("settings.json")
        try await checkChanges(to: file, folder: true) { changed in
            try await changed("file creation") { try Data("{}".utf8).write(to: file) }
            try await changed("write to the newly watched file") { try Self.append(to: file) }
        }
    }

    private func checkChanges(to file: URL, folder: Bool,
                              _ check: (_ changed: (String, () throws -> Void) async throws -> Void) async throws -> Void) async throws {
        let queue = DispatchQueue(label: "fleet-watcher-changes")
        let changes = Locked(0)
        let watcher = FleetWatcher(queue: queue) { changes.withValue { $0 += 1 } }
        queue.sync { watcher.watch(file: file, folder: folder) }
        defer { queue.sync { watcher.stop() } }
        try await check { label, edit in
            let before = changes.current
            try edit()
            try await eventually(label) { changes.current > before }
        }
    }

    private static func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
    }
}
