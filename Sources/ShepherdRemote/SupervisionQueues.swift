/// Routing priority derived from the existing Needs you and unseen Done groups. This does not
/// mark a completion seen; clients use their ordinary thread-selection path for that.
public struct SupervisionQueues<ID: Hashable>: Equatable {
    public struct Entry: Equatable {
        public let id: ID
        public let since: Double?
        public let changedFiles: Int

        public init(_ id: ID, since: Double?, changedFiles: Int = 0) {
            self.id = id
            self.since = since
            self.changedFiles = changedFiles
        }
    }

    public let needingYou: [ID]
    public let review: [ID]

    public init(blocked: [Entry], unseenDone: [Entry]) {
        let done = Self.oldestFirst(unseenDone)
        var used: Set<ID> = []
        needingYou = (Self.oldestFirst(blocked) + done).map(\.id).filter { used.insert($0).inserted }
        used.removeAll()
        review = done.filter { $0.changedFiles > 0 }.map(\.id).filter { used.insert($0).inserted }
    }

    public func needingYouCount(excluding current: ID?) -> Int {
        needingYou.count - (current.map(needingYou.contains) == true ? 1 : 0)
    }

    /// Start at the oldest blocked thread. If already in the queue, walk forward and wrap
    /// so a still-blocked thread doesn't prevent reaching the rest. Don't reopen the same thread.
    public func nextNeedingYou(after current: ID?) -> ID? {
        guard let current, let index = needingYou.firstIndex(of: current) else { return needingYou.first }
        guard needingYou.count > 1 else { return nil }
        return needingYou[(index + 1) % needingYou.count]
    }

    /// Finishing a review may race the host updating the queue, so exclude that thread explicitly.
    public func nextReview(excluding current: ID? = nil) -> ID? {
        review.first { $0 != current }
    }

    private static func oldestFirst(_ entries: [Entry]) -> [Entry] {
        entries.enumerated().sorted {
            let a = $0.element.since ?? .infinity
            let b = $1.element.since ?? .infinity
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }
}
