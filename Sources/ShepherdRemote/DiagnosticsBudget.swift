import Foundation

/// The iOS client's spend bound on Sentry: at most `limit` reports of each kind per UTC day,
/// persisted so a relaunch loop cannot reset it. SDK callbacks call `take` from any thread.
public final class DiagnosticsBudget: @unchecked Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case error, transaction

        public var limit: Int {
            switch self {
            case .error: 100
            case .transaction: 1000
            }
        }
    }

    private let store: UserDefaults
    private let lock = NSLock()

    public init(store: UserDefaults) { self.store = store }

    /// Spends one report of `kind`; false once today's are gone.
    public func take(_ kind: Kind, now: Date = Date()) -> Bool {
        lock.withLock {
            let key = "shepherd.diagnostics.budget." + kind.rawValue
            let day = Int((now.timeIntervalSince1970 / 86_400).rounded(.down))
            let saved = store.array(forKey: key) as? [Int] ?? []
            let used = saved.count == 2 && saved[0] == day ? saved[1] : 0
            guard used < kind.limit else { return false }
            store.set([day, used + 1], forKey: key)
            return true
        }
    }
}
