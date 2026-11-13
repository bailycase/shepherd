import Foundation
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdSessions

/// A restarted index finds every change made while the host was down by looking at the disk, whatever the system's event history holds:
/// a file missed here is missing from the sender's snapshot and from its digest, so nothing downstream could notice.
@Suite("Fleet content index restart", .integrationTimeLimit)
struct FleetContentIndexRestartTests {
    static let files = ["README.md": "# acme-web\n", "src/app.ts": "export const app = 1\n", "src/lib/util.ts": "export const util = 2\n",
                        "scripts/run.sh": "#!/bin/sh\necho hi\n", "docs/guide.md": "guide\n"]

    private func make(_ root: URL, _ storage: URL) -> FleetContentIndex {
        let classifier = FleetGitClassifier { _, paths in .init(tracked: [], untracked: Set(paths ?? [])) }
        return FleetContentIndex(root: root.path, storage: storage, classifier: classifier)
    }

    private func write(_ path: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// `dropHistory`: the saved event id is moved to now, as if the system's history of what happened while the host was down were
    /// gone (purged, or never written), so only looking at the disk can find anything.
    private func restarted(dropHistory: Bool) async throws -> (index: FleetContentIndex, root: URL, base: URL) {
        let base = try makeScratchDirectory("restart")
        let root = base.appendingPathComponent("acme-web", isDirectory: true), storage = base.appendingPathComponent("index", isDirectory: true)
        for (path, text) in Self.files { try write(path, text, in: root) }
        let first = make(root, storage)
        first.queue.sync { first.start() }
        #expect(first.queue.sync { first.state } == .ready)
        first.queue.sync { first.stop() }

        // While the host is down: an edit, a new file in a known folder, a new folder with a file, a removal, a removed folder, a rename.
        try write("src/app.ts", "export const app = 'while down'\n", in: root)
        try write("src/arrived.ts", "down\n", in: root)
        try write("fresh/deep/er/new.ts", "new folder\n", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("scripts/run.sh"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("docs"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("src/lib/util.ts"), to: root.appendingPathComponent("src/lib/renamed.ts"))

        if dropHistory {
            let meta = storage.appendingPathComponent("meta.json")
            var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any])
            object["eventID"] = NSNumber(value: FleetFSEvents.currentEventID())
            try JSONSerialization.data(withJSONObject: object).write(to: meta)
        }
        let second = make(root, storage)
        second.queue.sync { second.start() }
        return (second, root, base)
    }

    private func check(_ index: FleetContentIndex) {
        let entries = index.queue.sync { index.entries }
        #expect(index.queue.sync { index.loadedFromDisk })
        #expect(entries["src/arrived.ts"] != nil, "a file made in a known folder")
        #expect(entries["fresh/deep/er/new.ts"] != nil, "a file in folders made while down")
        #expect(entries["scripts/run.sh"] == nil && entries["docs/guide.md"] == nil, "removed files and a removed folder")
        #expect(entries["src/lib/util.ts"] == nil && entries["src/lib/renamed.ts"] != nil, "a rename")
        #expect(entries["src/app.ts"]?.hash == FleetHash(of: Data("export const app = 'while down'\n".utf8)), "an edit")
        #expect(entries["README.md"] != nil)
    }

    @Test func aRestartFindsWhatChangedWhileDownWithTheEventHistoryDropped() async throws {
        let (index, _, base) = try await restarted(dropHistory: true)
        defer { index.queue.sync { index.stop() }; try? FileManager.default.removeItem(at: base) }
        check(index)
        // Nothing needed the whole tree walked.
        #expect(index.queue.sync { index.rescans } == 0)
    }

    @Test func aRestartFindsWhatChangedWhileDownWithTheHistoryIntact() async throws {
        let (index, _, base) = try await restarted(dropHistory: false)
        defer { index.queue.sync { index.stop() }; try? FileManager.default.removeItem(at: base) }
        index.settle()
        check(index)
    }

    @Test func anIndexSavedWithoutDirectoryTimesIsWalkedOnceAtRestart() async throws {
        let base = try makeScratchDirectory("restart")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("acme-web", isDirectory: true), storage = base.appendingPathComponent("index", isDirectory: true)
        for (path, text) in Self.files { try write(path, text, in: root) }
        let first = make(root, storage)
        first.queue.sync { first.start() }
        first.queue.sync { first.stop() }
        let meta = storage.appendingPathComponent("meta.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any])
        object["directories"] = nil
        object["eventID"] = NSNumber(value: FleetFSEvents.currentEventID())
        try JSONSerialization.data(withJSONObject: object).write(to: meta)
        try write("src/arrived.ts", "down\n", in: root)
        let second = make(root, storage)
        second.queue.sync { second.start() }
        defer { second.queue.sync { second.stop() } }
        #expect(second.queue.sync { second.entries["src/arrived.ts"] } != nil)
        #expect(second.queue.sync { second.rescans } == 1)
    }

    /// What a restart costs on a big tree, printed for the PR (`SHEPHERD_FLEET_MEASURE=1`). Asserts only that the changes were found.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_FLEET_MEASURE"] == "1", "set SHEPHERD_FLEET_MEASURE=1"))
    func restartingOnATwentyThousandFileTreeCostsOneLookAtEveryFile() async throws {
        let base = try makeScratchDirectory("restart")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("acme-web", isDirectory: true), storage = base.appendingPathComponent("index", isDirectory: true)
        for directory in 0..<300 { for file in 0..<40 { try write("src/pkg-\(directory)/file-\(file).ts", "export const v = \(directory * file)\n// \(file)\n", in: root) } }
        for package in 0..<400 { for file in 0..<20 { try write("node_modules/dep-\(package)/lib/part-\(file).js", "module.exports = \(package + file)\n", in: root) } }
        let first = make(root, storage)
        let clock = ContinuousClock()
        let cold = clock.measure { first.queue.sync { first.start() } }
        first.queue.sync { first.stop() }
        try write("src/pkg-1/arrived.ts", "down\n", in: root)
        try write("src/pkg-2/file-2.ts", "edited while down\n", in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("src/pkg-3/file-3.ts"))
        let meta = storage.appendingPathComponent("meta.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: meta)) as? [String: Any])
        object["eventID"] = NSNumber(value: FleetFSEvents.currentEventID())
        try JSONSerialization.data(withJSONObject: object).write(to: meta)
        let second = make(root, storage)
        let warm = clock.measure { second.queue.sync { second.start() } }
        defer { second.queue.sync { second.stop() } }
        let (count, rescans) = second.queue.sync { (second.entries.count, second.rescans) }
        print("MEASURE restart: \(count) files, cold start \(cold), restart with 3 changes found by looking \(warm), rescans \(rescans)")
        #expect(second.queue.sync { second.entries["src/pkg-1/arrived.ts"] != nil && second.entries["src/pkg-3/file-3.ts"] == nil })
    }
}
