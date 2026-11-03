import ShepherdProtocol

/// Retains the settled prefix. A suffix starts at a user boundary and includes the preceding
/// reply: comment answers, retry eligibility and repeated-error folding depend on neighbors.
/// `changedFrom` is the first unequal source message, not merely the last visible row.
struct NativeTurnProjection {
    private(set) var turns: [NativeTurn] = []
    private var starts: [Int] = []
    private var byID: [String: Int] = [:]
    private var sourceCount = 0
    private(set) var userCount = 0

    var lastTurnStart: Int { starts.last ?? 0 }
    func start(for id: String) -> Int { byID[id] ?? 0 }

    @MainActor
    mutating func update(_ messages: [NativeThreadMessage], changedFrom: Int, aliases: [String: String])
        -> (start: Int, visited: Int, changed: Bool) {
        guard changedFrom < sourceCount || changedFrom < messages.count else { return (turns.count, 0, false) }
        // Appending can hide the previous empty streaming-thinking row (nativeTurns checks
        // the last source entry), so the previous source message is part of the change too.
        let affected = min(changedFrom, max(0, sourceCount - 1))
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= affected { low = middle + 1 } else { high = middle }
        }
        var row = max(0, low - 1)
        while row > 0 && !turns[row].isUser { row -= 1 }
        if row > 0 { row -= 1 }
        while row > 0 && !turns[row].isUser { row -= 1 }
        let source = row == 0 ? 0 : starts[row]
        let suffix = Array(messages.dropFirst(source))
        var suffixAliases = aliases
        var indices: [String: Int] = [:]
        for (offset, message) in suffix.enumerated() {
            indices[message.entryID] = source + offset
            if message.role == "user", let operation = message.operationID, suffixAliases[message.entryID] == nil {
                suffixAliases[message.entryID] = "pending:\(operation.uuidString)"
            }
        }
        let rebuilt = NativeThreadStore.endingCommentAnswers(nativeTurns(suffix, aliases: suffixAliases))
        let changed = turns.count - row != rebuilt.count || turns.dropFirst(row) != rebuilt[...]
        for turn in turns.dropFirst(row) {
            byID[turn.id] = nil
            if turn.isUser { userCount -= 1 }
        }
        turns.replaceSubrange(row..., with: rebuilt)
        starts.replaceSubrange(row..., with: rebuilt.map { indices[$0.messages[0].entryID]! })
        for index in row..<turns.count {
            byID[turns[index].id] = starts[index]
            if turns[index].isUser { userCount += 1 }
        }
        sourceCount = messages.count
        return (row, suffix.count, changed)
    }
}
