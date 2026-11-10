import Foundation
import ShepherdProtocol

/// The rules behind folding what pi saved into the thread's history, as pure functions: which live rows a
/// fold replaces, where the host's own records go, what a whole read lacks, and whether pi's message count
/// agrees with the events this host saw. `RPCThreadState` owns the state and calls these.
extension RPCThreadState {
    /// Why the next fold reads pi's whole history instead of appending what pi saved.
    enum HistoryRefetchReason: String, Equatable {
        /// The last read failed, so the thread may be missing messages.
        case unread
        /// A read that could still install was in flight when a fold was asked for.
        case readInFlight
        /// An extension displayed a message: pi saved it with a time its event does not carry.
        case displayedMessage
        /// The user ran an extension command, which can move pi's session or tree without an event.
        case command
        /// pi appended an entry its transcript lists that the events do not carry (a compaction).
        case entry
        /// A stdout record was lost, or the tail outgrew its budget before the thread served.
        case droppedRecord
        /// pi's message count says it saved something no event announced (or the other way round).
        case countMismatch
        /// A question or notice belongs among rows history already holds.
        case records
        /// A message of a role the host does not project.
        case unknownMessage
    }

    /// pi's message entries by role, as `get_session_stats` counts them. System messages count in the total only.
    struct SavedMessageCounts: Equatable {
        var total = 0, user = 0, assistant = 0, toolResults = 0

        init() {}

        /// nil unless the stats carry all four counts: an engine that does not count leaves the events alone.
        init?(stats: JSONValue) {
            guard let total = stats["totalMessages"]?.countValue, let user = stats["userMessages"]?.countValue,
                  let assistant = stats["assistantMessages"]?.countValue, let results = stats["toolResults"]?.countValue else { return nil }
            self.total = total
            self.user = user
            self.assistant = assistant
            self.toolResults = results
        }

        mutating func add(role: String) {
            total += 1
            switch role {
            case "user": user += 1
            case "assistant": assistant += 1
            case "toolResult": toolResults += 1
            default: break
            }
        }

        static func - (a: Self, b: Self) -> Self {
            var difference = Self()
            difference.total = a.total - b.total
            difference.user = a.user - b.user
            difference.assistant = a.assistant - b.assistant
            difference.toolResults = a.toolResults - b.toolResults
            return difference
        }
    }

    /// Whether what pi saved and what this host saw announced differ since the same moment. Either side may be ahead:
    /// pi saved a message no event told of, or an event repeated one the history already holds.
    static func countsDisagree(piDelta: SavedMessageCounts, hostDelta: SavedMessageCounts) -> Bool {
        piDelta != hostDelta
    }

    /// The messages of `pending` (events this host saw before pi answered, in pi's order) that `answer` lacks. pi answers a
    /// command after its handler returned, so a message saved in that step can precede an answer that does not hold it. The
    /// ones the answer lacks were saved last, so they are a suffix of `pending`: matched in order against the end of the
    /// answer, the first message with no match left and every one after it are returned.
    static func unread(_ pending: [RPCMessage], in answer: [RPCMessage]) -> [RPCMessage] {
        guard !pending.isEmpty else { return [] }
        var remaining: [SavedMessageKey: Int] = [:]
        for message in answer.suffix(pending.count + 64) { remaining[SavedMessageKey(message), default: 0] += 1 }
        for (offset, message) in pending.enumerated() {
            let key = SavedMessageKey(message)
            guard let left = remaining[key], left > 0 else { return Array(pending[offset...]) }
            remaining[key] = left - 1
        }
        return []
    }

    /// What names a saved message across the event that announced it and the answer that lists it. A custom message's time
    /// is left out: the answer holds the time pi saved it, the event the time it was made.
    private struct SavedMessageKey: Hashable {
        let role: String
        let toolCallID: String?
        let timestamp: Double?
        let customType: String?
        let textHash: Int
        let textBytes: Int

        init(_ message: RPCMessage) {
            role = message.role
            toolCallID = message.toolCallId
            timestamp = message.role == "custom" ? nil : message.timestamp
            customType = message.customType
            var hasher = Hasher()
            var bytes = 0
            for case .text(let text) in message.content {
                hasher.combine(text)
                bytes += text.utf8.count
            }
            textHash = hasher.finalize()
            textBytes = bytes
        }
    }

    /// Roughly what `message` holds in memory: its text, thinking and image bytes, and its tool calls' arguments.
    static func approximateBytes(_ message: RPCMessage) -> Int {
        message.content.reduce(0) { sum, block in
            switch block {
            case .text(let text), .thinking(let text): sum + text.utf8.count
            case .toolCall(_, let name, let arguments): sum + name.utf8.count + (arguments.map(jsonLength) ?? 0)
            case .image(_, let data, _): sum + data.utf8.count
            case .unknown: sum
            }
        }
    }

    /// Where `interleave` puts a row of pi's: a tool result starts when its call was made.
    static func rowStart(_ row: NativeThreadMessage) -> Double? {
        row.role == "toolResult" ? row.startedAt ?? row.timestamp : row.timestamp
    }

    // MARK: - Records

    /// Whether `row` is one the host keeps beside pi's history: a question (`q:`) or a command's notice (`n:`).
    static func isRecordRow(_ row: NativeThreadMessage) -> Bool {
        row.entryID.hasPrefix("q:") || row.entryID.hasPrefix("n:")
    }

    /// The records a whole read has dealt with: every record it was given. One that `interleave` left out (it ends before the
    /// first row a compaction kept) is as placed as any other, and must not look new to the next fold, which would read the
    /// whole history for it every time. A record row `keepingSummarized` kept from before is not a record to place.
    static func handledRecordIDs(_ records: [(at: Double, row: NativeThreadMessage)]) -> Set<String> {
        Set(records.lazy.map(\.row.entryID))
    }

    /// What history needs placed of the host's records, given the rows it holds.
    struct RecordNeeds {
        /// The index after the last row of pi's; the record rows from there on were put at the end because no row started after them.
        var trailingStart: Int
        /// The ids of the record rows from there on.
        var trailingIDs: Set<String>
        /// The records not placed yet, or placed at the end, in placement order.
        var wanted: [(at: Double, row: NativeThreadMessage)]
        /// A wanted record is not in history at all yet.
        var hasNew: Bool
        /// A wanted record belongs among rows history already holds, or a record it holds is gone: only a whole read places those.
        var late: Bool
    }

    /// `records` are `placedRecords`; `placed` the record rows history holds (`q:` and `n:` ids); `maxStart` the latest start of
    /// one of pi's rows in it. O(records) and the trailing rows.
    static func recordNeeds(in history: [NativeThreadMessage], records: [(at: Double, row: NativeThreadMessage)],
                            placed: Set<String>, maxStart: Double) -> RecordNeeds {
        var trailingStart = history.count
        while trailingStart > 0, isRecordRow(history[trailingStart - 1]) { trailingStart -= 1 }
        let trailing = Set(history[trailingStart...].map(\.entryID))
        var known = Set<String>(), wanted: [(at: Double, row: NativeThreadMessage)] = [], hasNew = false, late = false
        for record in records {
            known.insert(record.row.entryID)
            let isNew = !placed.contains(record.row.entryID)
            guard isNew || trailing.contains(record.row.entryID) else { continue }
            wanted.append(record)
            hasNew = hasNew || isNew
            if record.at <= maxStart { late = true }
        }
        if !placed.isSubset(of: known) { late = true }
        return RecordNeeds(trailingStart: trailingStart, trailingIDs: trailing, wanted: wanted, hasNew: hasNew, late: late)
    }

    /// The rows a fold appends, with the wanted records that start after every row history holds placed among them as a whole
    /// `interleave` would place them. `placed` are the record rows history holds before the fold. The record ids that make
    /// history after the fold, and the ones placed now.
    static func placingRecords(_ needs: RecordNeeds, among rows: [NativeThreadMessage], maxStart: Double,
                               placed: Set<String>) -> (rows: [NativeThreadMessage], recordIDs: Set<String>, newRecordIDs: Set<String>) {
        let onTime = needs.wanted.filter { $0.at > maxStart }
        let placedNow = Set(onTime.map(\.row.entryID))
        return (interleave(onTime, into: rows, afterEarlierRows: needs.trailingStart > 0),
                placed.subtracting(needs.trailingIDs).union(placedNow), placedNow)
    }

    // MARK: - Live rows

    /// The indexes (ascending) of `live` rows that a fold of `folded` replaces: their content is in `rows` now. A row
    /// leaves only when it is finished. `parents` maps a nested call to the call it runs inside, so a script's nested calls
    /// leave with the script's result.
    static func liveRowsLeaving(_ live: [LiveItem], folded: [RPCMessage], rows: [NativeThreadMessage],
                                placedRecordIDs: Set<String>, parents: [String: String]) -> [Int] {
        var userTimes = Set<Double>(), assistantTimes = Set<Double>(), resultIDs = Set<String>()
        var untimedUsers = 0, untimedAssistants = 0
        for message in folded {
            switch message.role {
            case "user":
                if let time = message.timestamp { userTimes.insert(time) } else { untimedUsers += 1 }
            case "assistant":
                if let time = message.timestamp { assistantTimes.insert(time) } else { untimedAssistants += 1 }
            case "toolResult":
                if let id = message.toolCallId { resultIDs.insert(id) }
                for call in message.nestedCalls?.calls ?? [] { resultIDs.insert(call.id) }
            default: break
            }
        }
        let userIDs = Set(rows.lazy.filter { $0.role == "user" }.map(\.entryID))
        func leaves(_ item: LiveItem) -> Bool {
            switch item.kind {
            case .user:
                guard persisted(item) else { return false }
                if userIDs.contains(item.value.entryID) { return true }
                if let time = item.raw?.timestamp ?? item.value.timestamp { return userTimes.contains(time) }
                guard untimedUsers > 0 else { return false }
                untimedUsers -= 1
                return true
            case .assistant:
                guard persisted(item) else { return false }
                if let time = item.raw?.timestamp { return assistantTimes.contains(time) }
                guard untimedAssistants > 0 else { return false }
                untimedAssistants -= 1
                return true
            case .tool(let id):
                guard persisted(item) else { return false }
                var call = id
                for _ in 0...8 {
                    if resultIDs.contains(call) { return true }
                    guard let parent = parents[call] else { return false }
                    call = parent
                }
                return false
            case .question, .notice:
                return placedRecordIDs.contains(item.value.entryID)
            case .pending, .compaction:
                return false
            }
        }
        return live.indices.filter { leaves(live[$0]) }
    }

    // MARK: - State a fold carries

    /// A projector held by a reference, so the job that appends to it is its only owner: the thread gives its own up first.
    final class ProjectorBox {
        var value: HistoryProjector
        init(_ value: HistoryProjector) { self.value = value }
    }

    /// What appending a tail to the projector made, to install on the session queue.
    struct Fold {
        var rows: [NativeThreadMessage]
        var messages: [RPCMessage]
        var projector: HistoryProjector
        var estimate: ContextEstimate
        var generation: String
        var applied: UInt64
        var token: UUID?
    }
}
