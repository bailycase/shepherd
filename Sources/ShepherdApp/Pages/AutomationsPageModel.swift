import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// What the Automations page draws (NavAutomations), derived once per change from this Mac's
// automations, each connected host's, and the runs each host kept. This Mac is one more host to
// the shared presentation (`AutomationsModel`), under an id no remote host takes, so its rows
// read by the same rules as a host's.

/// This Mac, as the destination pages name it among the hosts.
enum PageHost {
    /// This Mac's id among the hosts' (remote ids are random UUIDs).
    static let localID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    static let localName = "This Mac"
}

/// One automation's row in the table.
struct AutomationsPageRow: Identifiable, Equatable {
    var key: AutomationKey
    var name: String
    var enabled: Bool
    /// Its switch works: the host is connected and serves automations, and no change is on its way.
    var canToggle: Bool
    var host: String
    /// How its last run went; nil while its runs have not been read.
    var lastRun: NWRunOutcome?
    var selected: Bool
    /// Its run works or waits on you: its menu offers Stop, else Run Now.
    var live: Bool
    /// Its run's thread, live or settled, while it exists.
    var run: FleetRef?
    var canRun: Bool
    var canStop: Bool
    /// Edit and Delete: the host is connected and serves automations.
    var canEdit: Bool

    var id: AutomationKey { key }
}

/// One run in the detail's history.
struct AutomationsPageRun: Identifiable, Equatable {
    var id: UUID
    /// "Sep 24 02:00".
    var started: String
    /// "finished", "asked you", "interrupted".
    var word: String
    /// Nil is quiet (stopped).
    var state: AgentState?
    var duration: String?
    /// Its thread, while it exists on the host.
    var thread: FleetRef?
}

/// The selected automation, beside the table.
struct AutomationsPageDetail: Equatable {
    struct Fact: Identifiable, Equatable {
        var label: String
        var value: String
        var mono: Bool
        var id: String { label }
    }

    var key: AutomationKey
    var name: String
    /// "Starts a thread on build-01 when Shepherd starts".
    var summary: String
    var prompt: String
    var facts: [Fact]
    /// Newest first.
    var runs: [AutomationsPageRun]
    /// Stands in for the runs while there are none to show ("Reading runs…", "No runs yet.").
    var runsNote: String?
    var live: Bool
    var canRun: Bool
    var canStop: Bool
    var canEdit: Bool
    /// Why nothing can be changed from here ("Host offline"), nil when something can.
    var readOnlyReason: String?
}

struct AutomationsPageModel: Equatable {
    /// The table, after the filter.
    var rows: [AutomationsPageRow] = []
    /// Every automation on every host, before the filter.
    var total = 0
    var filter = ""
    var detail: AutomationsPageDetail?
    /// Says why the table is empty.
    var emptyText: String?

    /// This Mac leads `hosts`; `runs` are each automation's runs as its host kept them, oldest
    /// first (absent until read). `selection` falls back to the first row the filter keeps;
    /// `pending` automations have a change on its way, so their controls wait. `models` are the
    /// run threads' models where a host says (`Agent.model`). `now`, `timeZone` and `locale`
    /// word the dates (tests fix them).
    static func make(hosts: [AutomationHost], runs: [AutomationKey: [AutomationRun]], selection: AutomationKey?,
                     filter: String, pending: Set<AutomationKey> = [], now: Date = Date(),
                     timeZone: TimeZone = .current, locale: Locale = .current) -> AutomationsPageModel {
        let shared = AutomationsModel(hosts: hosts, runs: runs)
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = query.isEmpty ? shared.rows : shared.rows.filter { row in
            row.name.localizedStandardContains(query) || row.hostName.localizedStandardContains(query)
                || row.prompt.localizedStandardContains(query)
        }
        let selected = kept.first { $0.key == selection }?.key ?? kept.first?.key
        var model = AutomationsPageModel()
        model.total = shared.rows.count
        model.filter = filter
        model.rows = kept.map { row in
            let busy = pending.contains(row.key)
            return AutomationsPageRow(
                key: row.key, name: row.name, enabled: row.enabled, canToggle: row.abilities.toggle && !busy,
                host: row.hostName, lastRun: lastRun(row, runsKnown: runs[row.key] != nil), selected: row.key == selected,
                live: row.live, run: row.run, canRun: row.abilities.run && !busy, canStop: row.abilities.stop && !busy,
                canEdit: row.abilities.edit && !busy)
        }
        if shared.rows.isEmpty {
            model.emptyText = "No automations yet. An automation saves a prompt that starts a thread on a host, by hand or whenever Shepherd starts."
        } else if kept.isEmpty {
            model.emptyText = "No automations match “\(query)”."
        }
        if let selected, let detail = shared.detail(selected, runs: runs[selected], now: now, timeZone: timeZone, locale: locale) {
            let host = hosts.first { $0.id == selected.host }
            model.detail = Self.detail(detail, host: host, busy: pending.contains(selected))
        }
        return model
    }

    /// The table's Last run: the run's word, lowercase as the board has it, with its time.
    static func lastRun(_ row: AutomationListRow, runsKnown: Bool) -> NWRunOutcome? {
        // Until the runs are read, a row without a run knows only whether it is on.
        guard runsKnown || row.run != nil || row.offline else { return nil }
        let clock: NWRowClock? = switch row.clock {
        case .elapsed(let since)?: .elapsed(since: since)
        case .ago(let at)?: .ago(at)
        case nil: nil
        }
        return NWRunOutcome(row.status.lowercasedFirst, state: state(row.tone), clock: clock)
    }

    /// A tone as the page colors it: stopped and off are quiet (a hollow dot).
    static func state(_ tone: AutomationTone) -> AgentState? {
        switch tone {
        case .running: .running
        case .attention: .attention
        case .done: .done
        case .failed: .failed
        case .stopped, .off: nil
        }
    }

    static func detail(_ detail: AutomationDetail, host: AutomationHost?, busy: Bool) -> AutomationsPageDetail {
        let row = detail.row
        let local = row.key.host == PageHost.localID
        let place = local ? "this Mac" : row.hostName
        var facts = [
            AutomationsPageDetail.Fact(label: "When", value: row.when, mono: false),
            .init(label: "Host", value: row.hostName, mono: true),
            .init(label: "Folder", value: local ? (row.cwd as NSString).abbreviatingWithTildeInPath : row.cwd, mono: true),
        ]
        // The model its run's thread uses, where the host says.
        let runAgent = row.run.flatMap { run in host?.state.agents.first { $0.id == run.agent } }
        if let model = runAgent?.model, !model.isEmpty {
            facts.append(.init(label: "Model", value: model, mono: true))
        }
        let runs = detail.runs.map { run in
            AutomationsPageRun(id: run.id, started: run.started, word: run.word, state: state(run.tone),
                               duration: run.duration, thread: run.agent)
        }
        let note: String? = if !detail.runsKnown {
            row.abilities.readOnlyReason == nil ? "Reading runs…" : "Runs aren't available from this host."
        } else if runs.isEmpty {
            "No runs yet."
        } else {
            nil
        }
        return AutomationsPageDetail(
            key: row.key, name: row.name,
            summary: "Starts a thread on \(place) " + (row.enabled ? "when Shepherd starts" : "when you run it"),
            prompt: row.prompt, facts: facts, runs: runs, runsNote: note, live: row.live,
            canRun: row.abilities.run && !busy, canStop: row.abilities.stop && !busy, canEdit: row.abilities.edit && !busy,
            readOnlyReason: row.abilities.readOnlyReason)
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
