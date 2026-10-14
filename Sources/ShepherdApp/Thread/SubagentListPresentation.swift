import Foundation
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// The Subagents tab of the side pane (SubagentList board) as plain values: the summary, the two
// sections, and each run's row. Pure and clock-free: the rows are the tray's (`nativeTrayRow`), so
// a run reads the same in both places, and the sections are the touch client's (`nativeRunSections`).
// Derived once per change of the thread's runs, never in a view's body.

struct SubagentListPresentation: Equatable {
    /// One run: the row's values, and the run itself for the commands it offers.
    struct Item: Equatable, Identifiable {
        var id: String { row.id }
        let row: NWSubagentTrayRun
        let run: ChildRun
    }

    struct Section: Equatable {
        /// "This turn", "Earlier in this thread".
        let title: String
        /// "started 2:41 PM" and "1:58 PM": when the section's first run began; nil when none says.
        let time: String?
        let items: [Item]
    }

    /// "5 subagents".
    var title = ""
    /// "1 running", "1 waiting on parent", "2 done", "1 stopped": every phase present, live ones first.
    var tally: [NWSubagentTraySummary.Part] = []
    var sections: [Section] = []
    var count = 0

    var isEmpty: Bool { count == 0 }

    /// What a lazy stack lists after the summary: each section's head, then each of its rows, flat, so only
    /// the rows on screen are built.
    struct Element: Identifiable {
        enum Kind {
            case section(Section)
            case item(Item)
        }

        let id: String
        let kind: Kind
    }

    var elements: [Element] {
        sections.flatMap { section in
            [Element(id: "section:" + section.title, kind: .section(section))]
                + section.items.map { Element(id: "run:" + $0.id, kind: .item($0)) }
        }
    }

    init() {}

    /// `placements` and `turnOrder` are the store's (`NativeThreadStore.placements`, its rows' ids).
    init(runs: [ChildRun], placements: [String: NativeSubagentPlacement], turnOrder: [String], timeZone: TimeZone = .current) {
        count = runs.count
        title = nativeCount(runs.count, "subagent")
        tally = Self.tally(runs)
        let split = nativeRunSections(runs, placements: placements, turnOrder: turnOrder)
        // Both sections read in spawn order, as the board's do (the touch client lists earlier runs newest first).
        func items(_ runs: [ChildRun]) -> [Item] {
            runs.sorted { ($0.startedAt ?? 0, $0.id) < ($1.startedAt ?? 0, $1.id) }
                .map { Item(row: SubagentPresentation.row(nativeTrayRow($0)), run: $0) }
        }
        func started(_ runs: [ChildRun]) -> Double? { runs.compactMap(\.startedAt).min() }
        if !split.current.isEmpty {
            sections.append(Section(title: "This turn", time: started(split.current).map { "started " + nativeClockText($0, timeZone: timeZone) },
                                    items: items(split.current)))
        }
        if !split.earlier.isEmpty {
            // The clock is when the first of them began.
            sections.append(Section(title: "Earlier in this thread", time: started(split.earlier).map { nativeClockText($0, timeZone: timeZone) },
                                    items: items(split.earlier)))
        }
    }

    /// "1 running · 1 waiting on parent · 2 done · 1 stopped": live phases first, then how the rest ended.
    /// A run its parent or you stopped says "stopped", not "failed" (the board's word).
    static func tally(_ runs: [ChildRun]) -> [NWSubagentTraySummary.Part] {
        var counts: [(word: String, count: Int)] = []
        func add(_ word: String) {
            if let index = counts.firstIndex(where: { $0.word == word }) { counts[index].count += 1 } else { counts.append((word, 1)) }
        }
        let order = ["running", "queued", "paused", "waiting on parent", "done", "failed", "stopped"]
        for run in runs {
            let phase = nativeRunPhase(run)
            add(phase == .failed && run.state == "stopped" ? "stopped" : phase.word)
        }
        return order.compactMap { word in counts.first { $0.word == word }.map { NWSubagentTraySummary.Part("\($0.count) \(word)") } }
    }
}

extension SidePaneTabs {
    /// The Subagents tab's count and status dot (SubagentList: "Subagents 5 ●"; the user's decision: blue is still working,
    /// green is done). Working while any run is going or waiting (a run waiting on its parent is still working); else failed
    /// when any run failed or was stopped, which is never drawn as a success; else done. nil while the thread has no run,
    /// so the tab is not drawn.
    static func subagents(_ runs: [ChildRun]) -> (count: Int, status: AgentState)? {
        guard !runs.isEmpty else { return nil }
        let phases = runs.map(nativeRunPhase)
        let status: AgentState = phases.contains(where: \.isLive) ? .running : phases.contains(.failed) ? .failed : .done
        return (runs.count, status)
    }
}
