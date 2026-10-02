import Foundation
import ShepherdProtocol

/// What a snapshot carries of the lists beside the messages (the subagents' cards, the recorded
/// turns, the extensions' widgets). Each is bounded on its own, so a long, edit-heavy thread, whose
/// twenty finished cards each name thirty files and whose turns each name twenty, cannot fill the
/// snapshot and leave its history no room (docs/native-thread.md › Snapshots).
extension RPCThreadState {
    /// The encoded size of a JSON array of elements of these sizes.
    private static func listBytes(_ sizes: [Int]) -> Int {
        sizes.isEmpty ? 2 : sizes.reduce(2) { $0 + $1 } + sizes.count - 1
    }

    /// A run in one of these states has ended and asks for nothing: its card can lose detail.
    private static let finishedStates: Set<String> = ["complete", "failed", "stopped", "rejected"]

    /// `runs` within `limit` bytes. A run still going is never touched. Finished runs, oldest
    /// first, give up their lists of changed files (their `result` still counts them), then go.
    static func fitting(_ runs: [ChildRun], limit: Int) -> [ChildRun] {
        var sizes = runs.map { bytes($0) }
        guard listBytes(sizes) > limit else { return runs }
        var kept = runs
        let finished = runs.indices.filter { Self.finishedStates.contains(runs[$0].state) && !runs[$0].needsAttention }
            .sorted { (runs[$0].endedAt ?? runs[$0].startedAt ?? 0) < (runs[$1].endedAt ?? runs[$1].startedAt ?? 0) }
        for index in finished where listBytes(sizes) > limit && kept[index].files?.isEmpty == false {
            kept[index].files = nil
            sizes[index] = bytes(kept[index])
        }
        var dropped = Set<Int>()
        for index in finished where listBytes(sizes.indices.filter { !dropped.contains($0) }.map { sizes[$0] }) > limit {
            dropped.insert(index)
        }
        return kept.indices.filter { !dropped.contains($0) }.map { kept[$0] }
    }

    /// The files of a recorded turn an older turn keeps when the turns are over their budget: its
    /// count still says how many it changed.
    static let olderTurnFiles = 5

    /// `turns` (oldest first) within `limit` bytes: the older ones keep their first few files,
    /// then go, oldest first. The newest turn is never touched.
    static func fitting(_ turns: [ChangesTurn], limit: Int) -> [ChangesTurn] {
        var sizes = turns.map { bytes($0) }
        guard listBytes(sizes) > limit, turns.count > 1 else { return turns }
        var kept = turns
        for index in turns.indices.dropLast() where listBytes(sizes) > limit && kept[index].files.count > olderTurnFiles {
            kept[index].files = Array(kept[index].files.prefix(olderTurnFiles))
            sizes[index] = bytes(kept[index])
        }
        var first = 0
        while first < turns.count - 1, listBytes(Array(sizes[first...])) > limit { first += 1 }
        return Array(kept[first...])
    }

    /// `widgets` within `limit` bytes, in their order: the ones past it are left out.
    static func fitting(_ widgets: [NativeThreadWidget], limit: Int) -> [NativeThreadWidget] {
        var total = 2
        var kept: [NativeThreadWidget] = []
        for widget in widgets {
            let size = bytes(widget) + 1
            guard kept.isEmpty || total + size <= limit else { break }
            total += size
            kept.append(widget)
        }
        return kept
    }
}
