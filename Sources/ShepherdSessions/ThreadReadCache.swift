import Foundation
import ShepherdProtocol

/// Shared across servers as well as threads. Like ChangesCache, only the bounded LRU table
/// is locked; file IO, encoding, projection, callbacks and queue hops never hold the lock.
final class ThreadReadCache: @unchecked Sendable {
    static let shared = ThreadReadCache()
    static let defaultBytes = 64 * 1024 * 1024
    static let defaultInFlightBytes = 128 * 1024 * 1024
    static let transcriptWorkBytes = 32 * 1024 * 1024
    static let imageWorkBytes = 8 * 1024 * 1024

    struct Transcript {
        let file: String
        let generation: String
        let versions: [String?]
        let rows: [NativeThreadMessage]
    }
    typealias Image = (mimeType: String, data: Data)
    enum Value {
        case transcript(Transcript)
        case image(Image)
    }
    private struct Key: Hashable { let owner: UUID; let name: String }
    private let lock = NSLock()
    private let byteLimit: Int
    private let inFlightLimit: Int
    private let entryLimit: Int
    private var entries: [Key: (value: Value, bytes: Int)] = [:]
    private var order: [Key] = []
    private var bytes = 0
    private var workingBytes = 0

    init(byteLimit: Int = defaultBytes, inFlightLimit: Int = defaultInFlightBytes, entryLimit: Int = 256) {
        self.byteLimit = byteLimit
        self.inFlightLimit = inFlightLimit
        self.entryLimit = entryLimit
    }

    var retainedBytes: Int { lock.withLock { bytes } }
    var inFlightBytes: Int { lock.withLock { workingBytes } }

    func value(owner: UUID, name: String) -> Value? {
        lock.withLock {
            let key = Key(owner: owner, name: name)
            guard let entry = entries[key] else { return nil }
            order.removeAll { $0 == key }
            order.append(key)
            return entry.value
        }
    }

    func insert(_ value: Value, bytes cost: Int, owner: UUID, name: String) {
        guard cost >= 0, cost <= byteLimit, entryLimit > 0 else { return }
        // Keep evicted storage alive until outside the lock: releasing a large row graph can
        // be expensive, and must not stall another server's cache lookup under this lock.
        var retired: [Value] = []
        lock.withLock {
            let key = Key(owner: owner, name: name)
            if let old = entries.removeValue(forKey: key) { bytes -= old.bytes; retired.append(old.value) }
            order.removeAll { $0 == key }
            while bytes + cost > byteLimit || order.count >= entryLimit {
                let first = order.removeFirst()
                if let old = entries.removeValue(forKey: first) { bytes -= old.bytes; retired.append(old.value) }
            }
            entries[key] = (value, cost)
            order.append(key)
            bytes += cost
        }
        withExtendedLifetime(retired) {}
    }

    func remove(owner: UUID, name: String? = nil) {
        var retired: [Value] = []
        lock.withLock {
            let removed = order.filter { $0.owner == owner && (name == nil || $0.name == name) }
            for key in removed {
                if let old = entries.removeValue(forKey: key) { bytes -= old.bytes; retired.append(old.value) }
            }
            order.removeAll { $0.owner == owner && (name == nil || $0.name == name) }
        }
        withExtendedLifetime(retired) {}
    }

    func imageBytes(owner: UUID) -> Int {
        lock.withLock {
            entries.reduce(0) { sum, entry in
                guard entry.key.owner == owner, case .image = entry.value.value else { return sum }
                return sum + entry.value.bytes
            }
        }
    }

    /// Nonblocking admission, not a semaphore/queue wait. The reservation follows the worker,
    /// even after cancellation, so stale generations cannot bypass the aggregate work bound.
    func reserve(bytes: Int) -> Reservation? {
        guard bytes > 0 else { return nil }
        return lock.withLock {
            guard bytes <= inFlightLimit - workingBytes else { return nil }
            workingBytes += bytes
            return Reservation(cache: self, bytes: bytes)
        }
    }

    final class Reservation: @unchecked Sendable {
        private let cache: ThreadReadCache
        private let bytes: Int
        fileprivate init(cache: ThreadReadCache, bytes: Int) { self.cache = cache; self.bytes = bytes }
        deinit { cache.lock.withLock { cache.workingBytes -= bytes } }
    }
}
