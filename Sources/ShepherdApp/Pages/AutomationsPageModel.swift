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
    /// The Trigger column: "manual", "schedule", "GitHub", and its glyph.
    var trigger: String = "manual"
    var triggerGlyph: String = AutomationsPageModel.manualGlyph
    /// How its trigger stands, under the name ("Paused · gh isn't signed in"); nil for manual.
    var note: String?
    var noteState: AgentState?
    /// Runs finished or asking that nobody opened yet.
    var unread = 0
    /// How its last run went; nil while its runs have not been read.
    var lastRun: SHRunOutcome?
    var selected: Bool
    /// Its run works or waits on you: its menu offers Stop, else Run Now.
    var live: Bool
    /// Its run's thread, live or settled, while it exists.
    var run: FleetRef?
    var canRun: Bool
    var canStop: Bool
    /// Edit and Delete: the host is connected and serves automations.
    var canEdit: Bool
    /// Why Edit and Delete are off, when they are ("Host offline", a Project's automation).
    var disabledReason: String?

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
    /// A triggered automation's run: what fired it ("Run now" when nothing did).
    var trigger: String?
    var unread = false
    /// Why it didn't start.
    var failure: String?
    var pullRequest: URL?
}

/// An event waiting for a free slot.
struct AutomationsPageEvent: Identifiable, Equatable {
    var id: String
    var title: String
    /// "12m ago".
    var waited: String
}

/// A trigger that isn't watching: paused (by the user, Pause all, or a lasting error) or retrying.
struct AutomationsPageBanner: Equatable {
    var state: AgentState
    var title: String
    var message: String?
    /// Resume clears it (not Pause all, which the header's switch owns).
    var canResume: Bool
    /// A host's Pause all: the banner's Resume all lifts it there (This Mac's is the header's switch).
    var resumesAll = false
}

/// A remote host's Pause all triggers, in the header's menu.
struct AutomationsPageHostPause: Identifiable, Equatable {
    var id: UUID
    var name: String
    var paused: Bool
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
    /// A schedule or GitHub trigger: runs are an inbox, and Pause or Resume take Stop's place.
    var triggered = false
    var banner: AutomationsPageBanner?
    var pending: [AutomationsPageEvent] = []
    /// The trigger is paused (Resume), else watching (Pause); nil where it can't be told.
    var paused: Bool?
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
    /// This Mac's Pause all triggers, and whether it has a trigger to pause.
    var allPaused = false
    var hasTriggers = false
    /// Each connected host that serves triggers and has a triggered automation, with its own Pause all.
    var hostPauses: [AutomationsPageHostPause] = []

    /// The header's menu title once hosts have their own Pause all: what is paused, else the action.
    var pauseMenuTitle: String {
        let paused = (allPaused ? [PageHost.localName] : []) + hostPauses.filter(\.paused).map(\.name)
        switch paused.count {
        case 0: return "Pause triggers"
        case 1: return "Paused on \(paused[0])"
        default: return "Paused on \(paused.count) hosts"
        }
    }

    static let manualGlyph = "text.bubble"
    static let scheduleGlyph = "clock"

    /// This Mac leads `hosts`; `runs` are each automation's runs as its host kept them, oldest
    /// first (absent until read). `selection` falls back to the first row the filter keeps;
    /// `pending` automations have a change on its way, so their controls wait. `models` are the
    /// run threads' models where a host says (`Agent.model`). `now`, `timeZone` and `locale`
    /// word the dates (tests fix them).
    static func make(hosts: [AutomationHost], runs: [AutomationKey: [AutomationRun]], selection: AutomationKey?,
                     filter: String, pending: Set<AutomationKey> = [], triggers: [AutomationKey: AutomationTriggerStatus] = [:],
                     allPaused: Bool = false, now: Date = Date(),
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
        model.allPaused = allPaused
        let saved = Dictionary(hosts.flatMap { host in
            host.state.automations.map { (AutomationKey(host: host.id, automation: $0.id), $0) }
        }, uniquingKeysWith: { first, _ in first })
        model.hasTriggers = hosts.first { $0.id == PageHost.localID }?.state.automations.contains(where: \.isTriggered) ?? false
        model.hostPauses = hosts.filter { $0.id != PageHost.localID && $0.triggers && $0.connected && $0.state.automations.contains(where: \.isTriggered) }
            .map { host in
                AutomationsPageHostPause(id: host.id, name: host.name,
                                         paused: triggers.contains { $0.key.host == host.id && $0.value.allPaused })
            }
        model.rows = kept.map { row in
            let busy = pending.contains(row.key)
            var page = AutomationsPageRow(
                key: row.key, name: row.name, enabled: row.enabled, canToggle: row.abilities.toggle && !busy,
                host: row.hostName, lastRun: lastRun(row, runsKnown: runs[row.key] != nil), selected: row.key == selected,
                live: row.live, run: row.run, canRun: row.abilities.run && !busy, canStop: row.abilities.stop && !busy,
                canEdit: row.abilities.edit && !busy, disabledReason: row.abilities.edit ? (busy ? "Working…" : nil) : row.abilities.readOnlyReason)
            if let automation = saved[row.key] {
                (page.trigger, page.triggerGlyph) = Self.triggerKind(automation.trigger)
                if let note = Self.note(automation, status: triggers[row.key], allPaused: allPaused, now: now, timeZone: timeZone, locale: locale) {
                    (page.note, page.noteState) = note
                }
                page.unread = runs[row.key]?.filter(\.unread).count ?? 0
            }
            return page
        }
        if shared.rows.isEmpty {
            model.emptyText = "No automations yet. An automation saves a prompt that starts a thread on a host, by hand or whenever Shepherd starts."
        } else if kept.isEmpty {
            model.emptyText = "No automations match “\(query)”."
        }
        if let selected, let detail = shared.detail(selected, runs: runs[selected], now: now, timeZone: timeZone, locale: locale) {
            let host = hosts.first { $0.id == selected.host }
            model.detail = Self.detail(detail, host: host, busy: pending.contains(selected))
            if let automation = saved[selected], let host, automation.isTriggered {
                model.detail?.addTrigger(automation, host: host, runs: runs[selected], status: triggers[selected],
                                         allPaused: allPaused, now: now, timeZone: timeZone, locale: locale)
            }
        }
        return model
    }

    // MARK: Triggers

    /// The Trigger column's word and glyph.
    static func triggerKind(_ trigger: AutomationTrigger) -> (String, String) {
        switch trigger {
        case .manual: ("manual", manualGlyph)
        case .schedule: ("schedule", scheduleGlyph)
        case .github: ("GitHub", SHGlyph.repository.symbolName)
        }
    }

    /// The line under a triggered automation's name: why it isn't watching, else what waits,
    /// when it next runs and today's runs against the cap. Nil for manual, off, or unknown.
    static func note(_ automation: Automation, status: AutomationTriggerStatus?, allPaused: Bool, now: Date,
                     timeZone: TimeZone, locale: Locale) -> (String, AgentState?)? {
        guard automation.isTriggered, automation.enabled, let status else { return nil }
        if allPaused || status.allPaused { return ("Paused · all triggers", nil) }
        switch status.state {
        case .off: return nil
        case .paused:
            guard let reason = status.reason else { return ("Paused", nil) }
            return ("Paused · \(reason)", .failed)
        case .retrying:
            let at = status.retryAt.map { " at " + when(Date(timeIntervalSince1970: $0), now: now, timeZone: timeZone, locale: locale) } ?? ""
            return (["Retrying\(at)", status.reason].compactMap { $0 }.joined(separator: " · "), .attention)
        case .active:
            var parts: [String] = []
            if !status.pending.isEmpty { parts.append("\(status.pending.count) waiting") }
            if let next = status.nextRunAt {
                parts.append("Next run " + when(Date(timeIntervalSince1970: next), now: now, timeZone: timeZone, locale: locale))
            }
            parts.append("\(status.runsToday)/\(automation.limits.maxPerDay) today")
            return (parts.joined(separator: " · "), nil)
        }
    }

    /// "14:05" today, "tomorrow 09:00", else "Sep 24 09:00".
    static func when(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if calendar.isDate(date, inSameDayAs: now) { return clock }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow " + clock
        }
        return AutomationsModel.stamp(date, timeZone: timeZone, locale: locale)
    }

    /// What starts a run, in a phrase: "Daily at 09:00", "On GitHub activity in acme/app".
    static func whenPhrase(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .manual: "By hand"
        case .schedule(let schedule): AutomationSchedulePreset(rrule: schedule.rrule).summary
        case .github(let triggers):
            "On GitHub activity in " + repos(triggers)
        }
    }

    /// "acme/app", "acme/app and 1 more", or "the folder's repository".
    static func repos(_ triggers: [GitHubTrigger]) -> String {
        var names: [String] = []
        for trigger in triggers {
            let name = trigger.repo ?? "the folder's repository"
            if !names.contains(name) { names.append(name) }
        }
        guard let first = names.first else { return "the folder's repository" }
        return names.count == 1 ? first : "\(first) and \(names.count - 1) more"
    }

    /// One GitHub trigger's fact: "acme/app · issue labeled, PR opened · labels shepherd".
    static func githubFact(_ trigger: GitHubTrigger) -> String {
        var parts = [trigger.repo ?? "folder's repository", trigger.events.map(\.label).joined(separator: ", ")]
        if !trigger.labels.isEmpty { parts.append("labels " + trigger.labels.joined(separator: ", ")) }
        if !trigger.authors.isEmpty { parts.append("by " + trigger.authors.joined(separator: ", ")) }
        if let title = trigger.titleContains { parts.append("title has “\(title)”") }
        if let number = trigger.number { parts.append("#\(number)") }
        return parts.joined(separator: " · ")
    }

    static func gateWords(_ gate: AutomationAuthorGate) -> String {
        switch gate {
        case .collaborators: "Collaborators"
        case .contributors: "Contributors"
        case .anyone: "Anyone"
        }
    }

    /// The table's Last run: the run's word, lowercase as the board has it, with its time.
    static func lastRun(_ row: AutomationListRow, runsKnown: Bool) -> SHRunOutcome? {
        // Until the runs are read, a row without a run knows only whether it is on.
        guard runsKnown || row.run != nil || row.offline else { return nil }
        let clock: SHRowClock? = switch row.clock {
        case .elapsed(let since)?: .elapsed(since: since)
        case .ago(let at)?: .ago(at)
        case nil: nil
        }
        return SHRunOutcome(row.status.lowercasedFirst, state: state(row.tone), clock: clock)
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

extension AutomationsPageDetail {
    /// A triggered automation's detail: what starts it and where its runs go, its trigger's
    /// state, what waits, and its runs as an inbox.
    mutating func addTrigger(_ automation: Automation, host: AutomationHost, runs: [AutomationRun]?,
                             status: AutomationTriggerStatus?, allPaused: Bool, now: Date, timeZone: TimeZone, locale: Locale) {
        typealias Page = AutomationsPageModel
        triggered = true
        let thread: String? = if case .thread(let id) = automation.destination {
            host.state.agents.first { $0.id == id }?.name ?? "a thread that no longer exists"
        } else {
            nil
        }
        let place = automation.workspace == .worktree ? "a new worktree thread" : "a new thread"
        summary = Page.whenPhrase(automation.trigger) + " · " + (thread.map { "messages “\($0)”" } ?? "\(place) each run")
        var trigger: [Fact] = []
        switch automation.trigger {
        case .manual: break
        case .schedule(let schedule):
            trigger.append(.init(label: "When", value: AutomationSchedulePreset(rrule: schedule.rrule).summary, mono: false))
            if let next = status?.nextRunAt {
                trigger.append(.init(label: "Next run", value: Page.when(Date(timeIntervalSince1970: next), now: now, timeZone: timeZone,
                                                                        locale: locale), mono: false))
            }
        case .github(let triggers):
            for (index, item) in triggers.enumerated() {
                trigger.append(.init(label: triggers.count == 1 ? "GitHub" : "GitHub \(index + 1)", value: Page.githubFact(item), mono: false))
            }
            trigger.append(.init(label: "Who", value: Page.gateWords(automation.authorGate), mono: false))
            if let checked = status?.lastCheckedAt {
                trigger.append(.init(label: "Checked", value: SHDuration.text(now.timeIntervalSince1970 - checked) + " ago", mono: false))
            }
        }
        trigger.append(.init(label: "Runs in", value: thread ?? (automation.workspace == .worktree ? "New worktree" : "The folder"), mono: false))
        let today = status.map { " · \($0.runsToday) today" } ?? ""
        trigger.append(.init(label: "Limits", value: "\(automation.limits.maxConcurrent) at once · \(automation.limits.maxPerDay) a day\(today)",
                             mono: false))
        if automation.model != nil || automation.thinking != nil || automation.serviceTier != nil {
            let pins = [automation.model ?? "default", automation.thinking.map { "thinking " + $0.title.lowercased() },
                        automation.serviceTier.map { "speed " + $0.title.lowercased() }].compactMap { $0 }
            facts.removeAll { $0.label == "Model" }
            trigger.append(.init(label: "Model", value: pins.joined(separator: " · "), mono: true))
        }
        facts.removeAll { $0.label == "When" }
        facts = trigger + facts

        let raw = Dictionary((runs ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.runs = self.runs.map { run in
            var run = run
            guard let saved = raw[run.id] else { return run }
            run.trigger = saved.trigger ?? "Run now"
            run.unread = saved.unread
            run.failure = saved.failure
            // A run that never started has no length worth showing.
            if saved.result == .failed { run.duration = nil }
            run.pullRequest = saved.pullRequestURL.flatMap(URL.init(string:))
            return run
        }
        let local = key.host == PageHost.localID
        pending = (status?.pending ?? []).map { event in
            AutomationsPageEvent(id: event.id, title: event.summary,
                                 waited: SHDuration.text(now.timeIntervalSince1970 - event.occurredAt) + " ago")
        }
        // A host without triggers sends no status: its automation keeps the facts alone.
        guard let status else { return }
        if local, allPaused || status.allPaused {
            banner = AutomationsPageBanner(state: .idle, title: "All triggers are paused",
                                           message: "Nothing starts on its own until you turn off Pause all triggers.", canResume: false)
        } else if status.allPaused {
            banner = AutomationsPageBanner(state: .idle, title: "All triggers on \(host.name) are paused",
                                           message: "Nothing starts on its own there until you resume them.", canResume: false,
                                           resumesAll: true)
        } else {
            switch status.state {
            case .paused:
                banner = AutomationsPageBanner(state: status.reason == nil ? .idle : .failed, title: "Paused",
                                               message: status.reason ?? "Nothing starts on its own until you resume it.", canResume: true)
            case .retrying:
                let at = status.retryAt.map { " at " + Page.when(Date(timeIntervalSince1970: $0), now: now, timeZone: timeZone, locale: locale) } ?? ""
                banner = AutomationsPageBanner(state: .attention, title: "Retrying\(at)", message: status.reason, canResume: true)
            case .active, .off:
                break
            }
        }
        paused = status.state == .paused
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
