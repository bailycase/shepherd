import Foundation

/// What a review keeps that it can fetch again, bounded by what it costs rather than by count:
/// the oldest entries go first once `budget` is passed. Lookups move an entry to the newest.
/// ponytail: an array keeps the order, O(n) per touch; n is a review's cached files (tens to
/// hundreds), so a linked list waits until a profile shows it.
struct ReviewCostCache<Key: Hashable, Value> {
    let budget: Int
    private(set) var cost = 0
    private var entries: [Key: (value: Value, cost: Int)] = [:]
    /// Oldest first.
    private var order: [Key] = []

    init(budget: Int) { self.budget = budget }

    var count: Int { entries.count }

    mutating func value(for key: Key) -> Value? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.value
    }

    /// Keeps `value`, then lets the oldest go until the cache fits; a value bigger than the
    /// whole budget is not kept at all.
    mutating func insert(_ value: Value, cost: Int, for key: Key) {
        if let old = entries[key] { self.cost -= old.cost }
        entries[key] = (value, cost)
        self.cost += cost
        touch(key)
        while self.cost > budget, let oldest = order.first {
            order.removeFirst()
            if let gone = entries.removeValue(forKey: oldest) { self.cost -= gone.cost }
        }
    }

    mutating func removeAll() {
        entries = [:]
        order = []
        cost = 0
    }

    private mutating func touch(_ key: Key) {
        if order.last == key { return }
        order.removeAll { $0 == key }
        order.append(key)
    }
}

enum ReviewRetention {
    /// The reviews that let their reloadable data go: any no view (in any window) shows now,
    /// past the `keep` most recently shown or past `budget` of retained cost between them, newest
    /// kept first. A review on screen is never let go, whatever it holds. `recent` is oldest first.
    static func overflow<Key: Hashable>(recent: [Key], keep: Int, budget: Int = .max, cost: (Key) -> Int = { _ in 0 },
                                        shown: (Key) -> Bool) -> [Key] {
        var kept = 0
        var total = 0
        var out: [Key] = []
        for key in recent.reversed() where !shown(key) {
            let size = cost(key)
            if kept < keep, total + size <= budget {
                kept += 1
                total += size
            } else {
                out.append(key)
            }
        }
        return out
    }
}
