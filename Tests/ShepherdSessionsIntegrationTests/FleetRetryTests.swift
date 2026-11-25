import Foundation
import Testing
import ShepherdProtocol
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Fleet write retries", .integrationTimeLimit)
struct FleetRetryTests {
    final class FailingSource: FleetUnitSource, @unchecked Sendable {
        static let unit = "setting:test.retry"
        private let lock = NSLock()
        private var failing = true
        private var attempts = 0
        private var value: Data?
        var units: [String] { [Self.unit] }
        func storesBlob(_ unit: String) -> Bool { false }
        func isSeedable(_ unit: String, _ value: Data) -> Bool { true }
        func read() -> [String: Data] { lock.withLock { value.map { [Self.unit: $0] } ?? [:] } }
        func write(_ unit: String, _ value: Data?, origin: String) throws {
            try lock.withLock {
                attempts += 1
                if failing { throw HookSettingsStore.Busy() }
                self.value = value
            }
        }
        var tries: Int { lock.withLock { attempts } }
        var current: String? { lock.withLock { value.map { String(decoding: $0, as: UTF8.self) } } }
        func recover() { lock.withLock { failing = false } }
    }

    /// A write that keeps failing (the settings lock is held) is retried on a timer a bounded number of times, then stays
    /// pending for the next scan. It is not dropped: once it can land, the next scan applies it.
    @Test func aWriteThatKeepsFailingStopsTheTimerButIsNeverDropped() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fr-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = DispatchQueue(label: "fleet-retry-test")
        let macA = UUID(), macB = UUID()
        let sync = try FleetSync(queue: queue, directory: dir.appendingPathComponent("a"), mac: macA, name: { "A" }, retryDelay: 0.01, retryLimit: 3)
        let other = try FleetStore(directory: dir.appendingPathComponent("b"), mac: macB)
        let source = FailingSource()
        let op = try #require(other.appendLocal(unit: FailingSource.unit, change: .value("\"b\""), seed: false, name: "B"))
        queue.sync {
            sync.add(source)
            _ = sync.store.receive(op)
            sync.start()
        }

        try await eventually("the first try and three timed retries") { source.tries == 4 }
        try await Task.sleep(for: .milliseconds(300)) // a negative check: no fifth try comes from a timer
        #expect(source.tries == 4)

        queue.sync { sync.localChanged() }
        #expect(source.tries == 5, "the next scan tries the pending write once")
        try await Task.sleep(for: .milliseconds(100))
        #expect(source.tries == 5, "and starts no timer")

        source.recover()
        queue.sync { sync.localChanged() }
        #expect(source.current == "\"b\"")
        queue.sync { sync.stop() }
    }
}
