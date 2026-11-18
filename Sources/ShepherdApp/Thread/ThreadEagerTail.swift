import ShepherdRemote

/// Where a thread's eager tail starts (the rows laid out for real at its end; the rows before it are the lazy stack's), kept across the
/// updates that draw it, and moved only when the thread's rows or window change.
///
/// The rule is the store's (`NativeThreadStore.eagerTailRows`: the last rows within a cost, at least the rows covering the window). Followed
/// update for update, it would move rows between the stacks whenever the cost of a streaming row changed, and a crossing builds the row
/// again and drops its state, under a reader who may be looking at it. So the start is held at its row, and looks at the rule only when the
/// thread's rows, what a row that is not streaming costs (a large reply's parse landing) or the window's height change (a streamed chunk
/// moves nothing), and then:
/// - it takes the rule whole the first time, and when the row it held is gone (history that came back, another session), which is what a
///   thread builds when it opens or is shown again;
/// - for a reader who has left the tail it moves toward the rule by at most `crossing` rows, in either direction, so that no bulk of rows
///   crosses where the reader can see it; rows past `maxRows` leave at once, as they always did;
/// - for one following the tail, rows that leave go at once, and rows that come back are `crossing` at a time (they are built): the rows
///   that leave are above the two viewports the tail covers, so no one sees them go, and a thread that turned heavy under its reader must
///   not keep thirty rows because a turn arrived every time two could leave.
///
/// A reference whose reads in `body` redraw nothing, as `ThreadRowIndex`.
@MainActor
final class ThreadEagerTail {
    private var first: String?
    private var key: Key?
    private var count = 0

    private struct Key: Equatable {
        let revision: Int
        let costs: Int
        let rows: Int
        let first: String?
        let last: String?
        let cover: Int
    }

    /// The rows the eager tail holds now. `revision` and `costs` are the store's (`rowStructureRevision`, `rowCostRevision`). `rule` is how
    /// many it should hold (read only when the rows, what they cost or the window changed since the last call), `maxRows` the most it may, `crossing` how many rows move between the stacks at a time, `detached` whether the reader has
    /// left the tail.
    func update<Rows: RandomAccessCollection>(rows: Rows, revision: Int, costs: Int, cover: Int, maxRows: Int, crossing: Int, detached: Bool,
                                              rule: () -> Int) -> Int where Rows.Element == NativeThreadRow, Rows.Index == Int {
        let key = Key(revision: revision, costs: costs, rows: rows.count, first: rows.first?.id, last: rows.last?.id, cover: cover)
        guard key != self.key else { return count }
        self.key = key
        guard !rows.isEmpty else {
            first = nil
            count = 0
            return 0
        }
        let target = min(max(1, rule()), rows.count)
        guard let first, let index = rows.lastIndex(where: { $0.id == first }) else {
            self.first = rows[rows.endIndex - target].id
            count = target
            return target
        }
        let current = rows.endIndex - index
        let next: Int
        if current > target {
            next = detached ? max(target, min(maxRows, current - crossing)) : target
        } else {
            next = min(target, current + crossing)
        }
        self.first = rows[rows.endIndex - next].id
        count = next
        return next
    }

    /// The rows the tail held when last drawn: what a hidden thread draws, whose rows do not change. `rule` for a thread never drawn.
    func held<Rows: RandomAccessCollection>(rows: Rows, rule: () -> Int) -> Int where Rows.Element == NativeThreadRow, Rows.Index == Int {
        guard let first, let index = rows.lastIndex(where: { $0.id == first }) else { return min(max(1, rule()), rows.count) }
        return rows.endIndex - index
    }
}
