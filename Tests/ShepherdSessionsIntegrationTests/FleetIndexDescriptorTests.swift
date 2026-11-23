import Foundation
import Testing
import ShepherdCore
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Fleet index descriptors", .integrationTimeLimit)
struct FleetIndexDescriptorTests {
    @Test func indexing150RootsLeavesDescriptorsForTheHost() async {
        // No other suites' descriptors in the measurement.
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.measureRoots() }
        }
        expectScenarioCompleted(result)
        if let result { print(String(decoding: result.standardOutputContent, as: UTF8.self), terminator: "") }
    }

    private static func measureRoots() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let count = 150
        let budget = 256
        let base = scratch.dir.appendingPathComponent("workspaces/projects/checkouts")
        let spaces = try (0..<count).map { n in
            let root = base.appendingPathComponent("project-\(n)/acme-web")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("# Acme Web\n".utf8).write(to: root.appendingPathComponent("README.md"))
            return Space(name: "acme-web-\(n)", path: root.path)
        }
        let server = scratch.server
        let index = FleetIndexService(queue: server.queue, directory: scratch.dir.appendingPathComponent("index"))
        let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let roots = await server.queue.testHop {
            index.classifier = FleetGitClassifier { root, _ in
                guard FileManager.default.fileExists(atPath: root) else { return nil }
                return .init(tracked: ["README.md"], untracked: [])
            }
            index.host = .init(spaces: { spaces })
            index.setActive(true)
            return index.indexes()
        }
        defer { server.queue.sync { index.stop() } }
        try #require(roots.count == count)
        for root in roots {
            let watching = await root.queue.testHop { root.eventStream?.latestEventID != nil }
            try #require(watching)
        }
        let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        let measurement = "\(count) indexed roots: \(before) descriptors before, \(after) after"
        print(measurement)
        #expect(after < budget, Comment(rawValue: measurement))
        #expect(after - before <= count, Comment(rawValue: measurement))

        // An ancestor rename may not deliver any ordinary events beneath the old root.
        let renamed = roots[0], removed = roots[1]
        let parent = URL(fileURLWithPath: renamed.root).deletingLastPathComponent()
        try FileManager.default.moveItem(at: parent, to: base.appendingPathComponent("relocated"))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: removed.root))
        for root in [renamed, removed] {
            try await eventually("the old checkout's contents to be invalidated") {
                await root.queue.testHop { root.entries.isEmpty && root.lostEvents > 0 }
            }
        }
    }
}
