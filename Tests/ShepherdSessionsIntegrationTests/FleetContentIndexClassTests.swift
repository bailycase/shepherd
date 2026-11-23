import CoreServices
import Foundation
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

/// A new file's git class is asked of git beside the index. An answer that was asked for before git's lists changed (an add, a
/// commit) must never overwrite what the reclassify that followed put in, however late it lands.
@Suite("Fleet content index git classes", .integrationTimeLimit)
struct FleetContentIndexClassTests {
    @Test func aClassAskedForBeforeAReclassifyDoesNotOverwriteIt() async throws {
        let base = try makeScratchDirectory("class")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("acme-web", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# acme-web\n".utf8).write(to: root.appendingPathComponent("README.md"))

        // What git says is tracked now, and a gate that holds the answer to a question about named files after it was worked out.
        let tracked = Locked<Set<String>>([])
        let reached = Gate()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let hold = Locked(false)
        let classifier = FleetGitClassifier { _, paths in
            let inGit = tracked.current
            let scope = Set(paths ?? ["README.md", "src.ts"])
            let answer = FleetGitClassifier.Lookup(tracked: scope.intersection(inGit), untracked: scope.subtracting(inGit))
            if paths != nil, hold.current { reached.open(); release.wait() }
            return answer
        }
        let index = FleetContentIndex(root: root.path, storage: base.appendingPathComponent("index", isDirectory: true), classifier: classifier)
        await index.queue.testHop { index.rescan(initial: true) }

        // A new file is seen by an event, and the answer for it (untracked) is worked out and held.
        hold.withValue { $0 = true }
        try Data("export const x = 1\n".utf8).write(to: root.appendingPathComponent("src.ts"))
        let created = FleetFSEvents.Event(path: index.root + "/src.ts", flags: UInt32(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile), id: 1)
        await index.queue.testHop { index.ingest([created], classifyingInBackground: true) }
        await reached.wait()
        try Task.checkCancellation()

        // Meanwhile it is added, git's index changes, and the reclassify makes it tracked.
        hold.withValue { $0 = false }
        tracked.withValue { $0 = ["src.ts"] }
        let gitIndex = FleetFSEvents.Event(path: index.root + "/.git/index", flags: UInt32(kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemIsFile), id: 2)
        await index.queue.testHop { index.ingest([gitIndex]) }
        #expect(await index.queue.testHop { index.entries["src.ts"]?.state } == .tracked)

        // The old answer lands now, and is not applied.
        release.signal()
        try await eventually("the held answer to have been handled") { await index.queue.testHop { !index.classifying } }
        #expect(await index.queue.testHop { index.entries["src.ts"]?.state } == .tracked, "the answer from before the add did not undo it")
    }
}
