import Foundation
import ShepherdCore
import ShepherdProtocol

// Fleet ▸ Check as plain values (FleetCheck, and the Check tab and Mac card of FleetA): the grid of what the fleet needs against each Mac,
// derived once per change from the host's `FleetSnapshot`, the synced ignored items and the fix threads that run. The Mac page and the
// iPhone and iPad Check list draw the same values; the buttons (Run on, Copy, Fix with an agent, Ignore, Fix everything) are the Mac's alone.

/// How a cell of the grid reads: which colors the view gives it.
public enum FleetCheckTone: Equatable, Sendable {
    /// Has what is asked for.
    case ok
    /// Differs, is missing, fails or is low.
    case warn
    /// Nothing asks for it here, or it couldn't be found out.
    case none
    /// An agent is fixing it.
    case fixing
    /// A Mac that is asleep: the column is from its last report.
    case old
}

/// One Mac's cell of a row.
public struct FleetCheckCell: Equatable, Sendable {
    public var text: String
    public var tone: FleetCheckTone

    public init(text: String, tone: FleetCheckTone) {
        self.text = text
        self.tone = tone
    }
}

/// A column: one Mac.
public struct FleetCheckColumn: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var status: FleetMacCard.Status
    /// When an asleep Mac was last seen, as a time of day.
    public var since: String?
    public var isAsleep: Bool { status == .asleep }
}

/// A row: one thing the fleet needs, and what each Mac has of it.
public struct FleetCheckRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var group: FleetCheckItem.Group
    public var name: String
    /// ".nvmrc in web, payments-api".
    public var why: String
    /// One per column, in the columns' order.
    public var cells: [FleetCheckCell]
    /// The Macs that have something to do about it (not ignored), in the columns' order.
    public var attention: [UUID]
    /// "node 22: differs on Mac mini".
    public var label: String
    /// The Mac card's word for it: "disk", "sign-ins", "muse CLI".
    public var short: String
}

public struct FleetCheckGroup: Identifiable, Equatable, Sendable {
    public var id: FleetCheckItem.Group
    public var name: String
    public var rows: [FleetCheckRow]
}

/// A fix that runs: the thread on the Mac, as the dispatch log holds it, or the thread this Mac started for itself.
public struct FleetCheckFixing: Equatable, Sendable {
    /// The dispatch's id, for a thread another Mac runs: what Open thread opens.
    public var dispatchID: UUID?
    /// The thread on this Mac, for a fix of This Mac.
    public var agentID: AgentID?
    public var threadTitle: String

    public init(dispatchID: UUID? = nil, agentID: AgentID? = nil, threadTitle: String) {
        self.dispatchID = dispatchID
        self.agentID = agentID
        self.threadTitle = threadTitle
    }
}

/// What the panel beside the grid says of one row on one Mac.
public struct FleetCheckDetail: Equatable, Sendable {
    public enum Pill: Equatable, Sendable { case warn, good, quiet }

    public var pill: String
    public var pillTone: Pill
    public var title: String
    public var body: String
    /// What it changes for Auto.
    public var effect: String
    /// The Mac the buttons are about; nil when everything matches.
    public var mac: UUID?
    public var macName: String
    /// "Run on Mac mini": the command, in the Mac's own package manager, and what to know about it. Nil when there is no honest one.
    public var command: String?
    public var commandNote: String?
    /// A fix with an agent is offered (the row needs something here and it can be fixed).
    public var fixable: Bool
    /// An agent is fixing it.
    public var fixing: FleetCheckFixing?
    /// It was set aside for this Mac.
    public var ignored: Bool
    /// Something to set aside, or to stop setting aside.
    public var ignorable: Bool
    /// What Fix everything on this Mac covers.
    public var fixAllCount: Int
    public var rowID: String

    public static let none = FleetCheckDetail(pill: "", pillTone: .quiet, title: "", body: "", effect: "", mac: nil, macName: "", command: nil,
                                              commandNote: nil, fixable: false, fixing: nil, ignored: false, ignorable: false, fixAllCount: 0, rowID: "")
}

/// A thread's job: what the agent on a Mac is asked to fix.
public struct FleetCheckFix: Equatable, Sendable {
    public var mac: UUID
    public var macName: String
    /// The Check items it covers (`FleetUserThread.fixes`).
    public var items: [String]
    /// The thread's title: "Install node 22 on Mac mini".
    public var title: String
    /// The checklist it starts with.
    public var prompt: String
    /// The repositories the items come from, by name: where the thread is best started.
    public var repos: [String]
}

/// The whole tab.
public struct FleetCheckPage: Equatable, Sendable {
    public var columns: [FleetCheckColumn]
    public var groups: [FleetCheckGroup]
    /// Things that differ across the fleet and aren't set aside: the tab's count.
    public var count: Int
    /// "6 things differ · 4 on Mac mini, 2 on Mac Studio", or "Everything matches on every Mac".
    public var summary: String
    /// "Checked 3m ago": the newest look at an awake Mac; nil before any.
    public var checkedAgo: String?
    /// The words under the grid.
    public var footer: String
    /// The tab's label: "Check · 6", or "Check".
    public var tabTitle: String { count > 0 ? "Check · \(count)" : "Check" }

    /// What each Mac reports, for the panel and the fixes.
    var entries: [UUID: Entry] = [:]
    var rows: [String: [UUID: FleetCheckItem]] = [:]
    var merged: [String: Merged] = [:]

    struct Entry: Equatable, Sendable {
        var name: String
        var packageManager: String
        var reported: Bool
        var ignored: Set<String>
        var fixing: [String: FleetCheckFixing]
        /// Items that differ here, by id, as presented (a build behind the fleet's newest differs, though the Mac says ok).
        var attention: Set<String>
        var asleep: Bool
    }

    /// One row's words across Macs: every repository that asks, the files that say so, and the newest build.
    struct Merged: Equatable, Sendable {
        var subjects: [String]
        var sources: [String]
        var newestBuild: String?
    }

    public static let empty = FleetCheckPage(columns: [], groups: [], count: 0, summary: "", checkedAgo: nil, footer: "")

    /// The first Mac a row needs something on (not ignored), in the columns' order.
    public func firstAttention(of rowID: String) -> UUID? {
        groups.lazy.flatMap(\.rows).first { $0.id == rowID }?.attention.first
    }

    /// Whether `mac` has reported what it found.
    public func reported(_ mac: UUID) -> Bool { entries[mac]?.reported == true }

    /// What needs doing on `mac`, short: the words of the Mac card's Ready line ("node 22", "muse CLI", "disk").
    public func shortNames(needing mac: UUID) -> [String] {
        groups.flatMap(\.rows).filter { $0.attention.contains(mac) }.map(\.short)
    }

    /// The first row that needs something on `mac`: where a Mac card's Check… lands.
    public func firstRow(needing mac: UUID) -> String? {
        groups.lazy.flatMap(\.rows).first { $0.attention.contains(mac) }?.id
    }

    /// Everything on `mac` that needs something, can be fixed and isn't being fixed already.
    public func fixableRows(on mac: UUID) -> [String] {
        guard let entry = entries[mac] else { return [] }
        return groups.flatMap(\.rows).compactMap { row in
            guard entry.attention.contains(row.id), entry.fixing[row.id] == nil, let item = rows[row.id]?[mac], FleetCheckPresentation.canFix(item) else { return nil }
            return row.id
        }
    }

    /// What the panel says of `rowID`, about `mac` (the first Mac that needs something when nil).
    public func detail(row rowID: String, mac chosen: UUID? = nil) -> FleetCheckDetail {
        guard let row = groups.lazy.flatMap(\.rows).first(where: { $0.id == rowID }) else { return .none }
        let mac = chosen ?? row.attention.first ?? columns.first?.id
        guard let mac, let entry = entries[mac], let item = rows[rowID]?[mac] else {
            return FleetCheckDetail(pill: "Not needed", pillTone: .quiet, title: row.name, body: "\(row.why.isEmpty ? row.name : row.why). Nothing here asks for it.", effect: "",
                                    mac: mac, macName: mac.flatMap { entries[$0]?.name } ?? "", command: nil, commandNote: nil, fixable: false, fixing: nil,
                                    ignored: false, ignorable: false, fixAllCount: 0, rowID: rowID)
        }
        return FleetCheckPresentation.detail(row: row, item: item, mac: mac, entry: entry, merged: merged[rowID] ?? Merged(subjects: [], sources: [], newestBuild: nil),
                                             fixAll: fixableRows(on: mac).count, matchesEverywhere: row.attention.isEmpty)
    }

    /// The thread's job for `rows` on `mac` (every fixable row when nil), or nil when there is nothing to fix.
    public func fix(on mac: UUID, rows ids: [String]? = nil) -> FleetCheckFix? {
        guard let entry = entries[mac] else { return nil }
        let wanted = Set(ids ?? fixableRows(on: mac))
        let chosen = groups.flatMap(\.rows).filter { wanted.contains($0.id) && entry.attention.contains($0.id) }
        guard !chosen.isEmpty else { return nil }
        return FleetCheckPresentation.fix(rows: chosen, mac: mac, entry: entry, items: rows, merged: merged, everything: ids == nil)
    }
}

public enum FleetCheckPresentation {
    /// How the Mac card says what Check found: "Needs 4 · node 22, muse CLI, disk"; nil when nothing needs doing.
    public static func needs(_ rows: [String]) -> String? {
        rows.isEmpty ? nil : "Needs \(rows.count) · \(rows.prefix(3).joined(separator: ", "))"
    }

    // MARK: The page

    /// Builds the tab. `cards` are the Macs in the page's order (This Mac first). `ignored` is what a person set aside for each Mac.
    /// `fixing` is the fixes this Mac started for itself (a thread of its own, which the dispatch log doesn't hold), by item.
    public static func make(snapshot: FleetSnapshot, cards: [FleetMacCard], ignored: (UUID) -> Set<String> = { _ in [] }, snapshotAge: TimeInterval = 0,
                            fixing local: [UUID: [String: FleetCheckFixing]] = [:]) -> FleetCheckPage {
        guard !cards.isEmpty else { return .empty }
        let states = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        let columns = cards.map { FleetCheckColumn(id: $0.id, name: $0.name, status: $0.status, since: $0.since) }

        // Fix threads that run, by Mac and item.
        var fixing = local
        let running: Set<FleetDispatchState> = [.placing, .waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing, .running]
        for record in snapshot.dispatches where !record.fixes.isEmpty && running.contains(record.state) {
            guard let mac = record.targetHostID ?? record.requestedHost.flatMap(UUID.init(uuidString:)) else { continue }
            for id in record.fixes { fixing[mac, default: [:]][id] = FleetCheckFixing(dispatchID: record.id, threadTitle: record.title) }
        }

        // Each Mac's items by row, and what the rows say across Macs.
        var rows: [String: [UUID: FleetCheckItem]] = [:]
        var first: [String: FleetCheckItem] = [:]
        var order: [String] = []
        var merged: [String: FleetCheckPage.Merged] = [:]
        for card in cards {
            guard let report = states[card.id]?.check else { continue }
            for item in report.items {
                rows[item.id, default: [:]][card.id] = item
                if first[item.id] == nil { first[item.id] = item; order.append(item.id) }
                var group = merged[item.id] ?? FleetCheckPage.Merged(subjects: [], sources: [], newestBuild: nil)
                group.subjects = Array(Set(group.subjects + item.subjects)).sorted()
                group.sources = Array(Set(group.sources + item.sources)).sorted()
                merged[item.id] = group
            }
        }
        // The newest build in the fleet: a Mac on an older one differs.
        if let builds = rows["build"] {
            let newest = builds.values.compactMap { buildNumber($0.value) }.max()
            merged["build"]?.newestBuild = newest.map(String.init)
        }

        var entries: [UUID: FleetCheckPage.Entry] = [:]
        for card in cards {
            let state = states[card.id]
            let set = ignored(card.id)
            var attention: Set<String> = []
            for (id, byMac) in rows {
                guard let item = byMac[card.id], isAttention(item, newestBuild: merged[id]?.newestBuild) else { continue }
                if !set.contains(id) { attention.insert(id) }
            }
            entries[card.id] = FleetCheckPage.Entry(name: card.name, packageManager: state?.check?.packageManager ?? "", reported: state?.check != nil, ignored: set,
                                                    fixing: fixing[card.id] ?? [:], attention: attention, asleep: card.status == .asleep)
        }

        var page = FleetCheckPage.empty
        page.columns = columns
        page.entries = entries
        page.rows = rows
        page.merged = merged

        var groups: [FleetCheckItem.Group: [FleetCheckRow]] = [:]
        for id in order {
            guard let model = first[id] else { continue }
            let byMac = rows[id] ?? [:]
            var cells: [FleetCheckCell] = []
            var attention: [UUID] = []
            for card in cards {
                let entry = entries[card.id]
                cells.append(cell(item: byMac[card.id], entry: entry, rowID: id, reported: entry?.reported == true, newestBuild: merged[id]?.newestBuild, asleep: card.status == .asleep))
                if entry?.attention.contains(id) == true { attention.append(card.id) }
            }
            let name = rowName(model)
            let why = rowWhy(model, merged: merged[id])
            let names = attention.compactMap { mac in cards.first { $0.id == mac }?.name }
            let label = names.isEmpty ? "\(name): details" : "\(name): needs something on \(names.joined(separator: ", "))"
            groups[model.group, default: []].append(FleetCheckRow(id: id, group: model.group, name: name, why: why, cells: cells, attention: attention, label: label,
                                                     short: shortName(model, name: name)))
        }
        page.groups = FleetCheckItem.Group.allCases.compactMap { group in
            guard let rows = groups[group], !rows.isEmpty else { return nil }
            return FleetCheckGroup(id: group, name: groupName(group), rows: rows.sorted { rank($0) < rank($1) })
        }

        // The words around it.
        page.count = entries.values.reduce(0) { $0 + $1.attention.count }
        let by = cards.compactMap { card -> String? in
            let n = entries[card.id]?.attention.count ?? 0
            return n > 0 ? "\(n) on \(card.name)" : nil
        }
        let reported = cards.contains { entries[$0.id]?.reported == true }
        page.summary = page.count == 0 ? (reported ? "Everything matches on every Mac" : "Waiting for the Macs to look")
            : "\(page.count) \(page.count == 1 ? "thing differs" : "things differ") · \(by.joined(separator: ", "))"
        let ages = cards.compactMap { card -> TimeInterval? in
            guard card.status != .asleep, let age = states[card.id]?.checkAge else { return nil }
            return age + snapshotAge
        }
        page.checkedAgo = ages.min().map { "Checked \(since($0))" }
        page.footer = footer(columns.filter(\.isAsleep))
        return page
    }

    // MARK: Cells and rows

    static func isAttention(_ item: FleetCheckItem, newestBuild: String?) -> Bool {
        if item.id == "build" { return buildNumber(item.value).map { mine in newestBuild.flatMap(Int.init).map { mine < $0 } ?? false } ?? false }
        return item.state == .warn
    }

    static func buildNumber(_ text: String) -> Int? {
        Int(text.split(separator: " ").last.map(String.init) ?? text)
    }

    private static func cell(item: FleetCheckItem?, entry: FleetCheckPage.Entry?, rowID: String, reported: Bool, newestBuild: String?, asleep: Bool) -> FleetCheckCell {
        guard reported else { return FleetCheckCell(text: "Not checked yet", tone: .none) }
        guard let item else { return FleetCheckCell(text: "Not needed", tone: .none) }
        if let entry, entry.fixing[rowID] != nil { return FleetCheckCell(text: "Fixing…", tone: .fixing) }
        let differs = isAttention(item, newestBuild: newestBuild)
        if asleep { return FleetCheckCell(text: item.value, tone: .old) }
        if differs, entry?.ignored.contains(rowID) == true { return FleetCheckCell(text: item.value, tone: .none) }
        switch item.state {
        case .notNeeded: return FleetCheckCell(text: "Not needed", tone: .none)
        case .unknown: return FleetCheckCell(text: item.value, tone: .none)
        case .ok, .warn: return FleetCheckCell(text: item.value, tone: differs ? .warn : .ok)
        }
    }

    /// What a row is called: "node 22", "muse CLI", "Reach github.com/acme".
    static func rowName(_ item: FleetCheckItem) -> String {
        if item.kind == .command { return item.name.lowercased().contains("cli") ? item.name : "\(item.name) CLI" }
        return item.name
    }

    static func shortName(_ item: FleetCheckItem, name: String) -> String {
        switch item.id {
        case "disk": "disk"
        case "sleep": "sleep"
        case "build": "build"
        case "models": "sign-ins"
        default: item.id.hasPrefix("git:") ? (item.tool ?? name) : name
        }
    }

    /// Why the fleet asks: the files and every repository that asks, across Macs.
    static func rowWhy(_ item: FleetCheckItem, merged: FleetCheckPage.Merged?) -> String {
        guard let merged else { return item.why }
        switch item.kind {
        case .tool where !merged.subjects.isEmpty && !merged.sources.isEmpty:
            return "\(merged.sources.joined(separator: ", ")) in \(merged.subjects.joined(separator: ", "))"
        case .command where !merged.subjects.isEmpty:
            return "\(merged.subjects.joined(separator: ", ")) MCP server"
        default:
            return item.why
        }
    }

    static func groupName(_ group: FleetCheckItem.Group) -> String {
        switch group {
        case .needs: "Your repos need"
        case .tools: "Tools and MCP servers"
        case .access: "Access"
        case .system: "Shepherd and the Mac"
        }
    }

    private static func rank(_ row: FleetCheckRow) -> String {
        switch row.group {
        case .system: return ["build": "1", "disk": "2", "sleep": "3"][row.id] ?? "4"
        case .access: return row.id.hasPrefix("git:") ? "1" + row.id : "2" + row.id
        case .needs:
            // The tools in the order they are listed in (node, pnpm, npm, yarn, Xcode, nix, …), then by version.
            let tool = row.id.split(separator: ":").dropFirst().first.map(String.init) ?? ""
            let index = FleetRepoNeed.Tool(rawValue: tool).flatMap { FleetRepoNeed.Tool.allCases.firstIndex(of: $0) } ?? 99
            return String(format: "%02d", index) + row.id
        case .tools: return row.id
        }
    }

    /// "just now", "3m ago", "2h ago", "3d ago".
    static func since(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "just now"
        case ..<3600: "\(Int(seconds / 60))m ago"
        case ..<86_400: "\(Int(seconds / 3600))h ago"
        default: "\(Int(seconds / 86_400))d ago"
        }
    }

    private static func footer(_ asleep: [FleetCheckColumn]) -> String {
        let base = "Checks only read. Nothing is installed or changed until you pick a fix."
        guard !asleep.isEmpty else { return base }
        if asleep.count == 1, let one = asleep.first {
            return "\(base) \(one.name) is asleep, so its column is from \(one.since.map { "\($0)" } ?? "its last look")."
        }
        return "\(base) \(list(asleep.map(\.name))) are asleep, so their columns are from their last look."
    }

    /// "web", "web and payments-api", "web, payments-api and orders-svc".
    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: ""
        case 1: names[0]
        case 2: "\(names[0]) and \(names[1])"
        default: names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }

    // MARK: The panel

    /// Whether Check can offer a fix for it: a program, a command, a remote, a provider, disk or sleep. A build behind the fleet's newest updates when
    /// the Mac does.
    static func canFix(_ item: FleetCheckItem) -> Bool {
        switch item.kind {
        case .tool, .command, .remote, .provider, .disk, .sleep: true
        case .build, .other: false
        }
    }

    static func detail(row: FleetCheckRow, item: FleetCheckItem, mac: UUID, entry: FleetCheckPage.Entry, merged: FleetCheckPage.Merged,
                       fixAll: Int, matchesEverywhere: Bool) -> FleetCheckDetail {
        let name = entry.name
        let attention = entry.attention.contains(row.id)
        let ignored = entry.ignored.contains(row.id)
        var detail = FleetCheckDetail(pill: "", pillTone: .warn, title: row.name, body: "", effect: "", mac: mac, macName: name, command: nil, commandNote: nil,
                                      fixable: false, fixing: entry.fixing[row.id], ignored: ignored, ignorable: attention || ignored, fixAllCount: fixAll, rowID: row.id)
        guard attention || ignored else {
            let others = item.state == .notNeeded
            detail.pill = matchesEverywhere ? "Matches on every Mac" : (others ? "Not needed on \(name)" : "Matches on \(name)")
            detail.pillTone = .good
            detail.body = "\(row.why.isEmpty ? row.name : row.why). \(matchesEverywhere ? "Every Mac has what it needs." : "\(name) has what it needs.")"
            return detail
        }
        let missing = item.value == "Missing"
        let has = item.value.hasPrefix("Has ") ? String(item.value.dropFirst(4)) : nil
        switch item.kind {
        case .tool:
            let tool = item.tool ?? item.name
            detail.pill = missing ? "Missing on \(name)" : "Differs on \(name)"
            detail.title = "\(row.name) on \(name)"
            let one = merged.subjects.count <= 1
            let verb: String
            if item.want == nil { verb = one ? "asks for \(row.name)" : "ask for \(row.name)" }
            else if item.atLeast { verb = (one ? "asks for " : "ask for ") + "\(row.name) or newer" }
            else { verb = (one ? "pins " : "pin ") + row.name }
            let files = merged.sources.isEmpty ? "" : " in \(merged.sources.joined(separator: ", "))"
            detail.body = "\(merged.subjects.isEmpty ? "A repository here" : list(merged.subjects)) \(verb)\(files). "
                + (has.map { "\(name) has \(tool) \($0)." } ?? "\(name) doesn’t have \(tool).")
            if item.tool == FleetRepoNeed.Tool.xcode.rawValue, missing {
                detail.effect = "Auto doesn’t send repos with an Xcode project to \(name) until Xcode is installed."
            } else {
                let older = has.flatMap { have in item.want.map { !FleetVersion.satisfies(have: have, need: $0, match: .atLeast) } } ?? false
                detail.effect = "Auto still sends these repos there, but their installs and tests may fail \(missing ? "without \(tool)" : older ? "on the older \(tool)" : "on a different \(tool)")."
            }
        case .command:
            let tool = item.tool ?? item.name
            detail.pill = "Missing on \(name)"
            detail.title = "\(row.name) on \(name)"
            detail.body = "The \(list(merged.subjects.isEmpty ? [item.name] : merged.subjects)) MCP server runs \(tool). \(name) doesn’t have it."
            detail.effect = "Threads on \(name) start without that server. Auto still sends work there."
        case .remote:
            detail.pill = "Fails on \(name)"
            detail.title = "\(name) can’t reach \(item.tool ?? row.name)"
            detail.body = "git gets no answer from \(item.tool ?? "the remote") on \(name) (\(row.why)). Its ssh key or sign-in there may be missing."
            detail.effect = "Auto still sends work there, but a dispatch that has to fetch or clone from it fails with git’s own words."
        case .provider:
            detail.pill = "Fails on \(name)"
            detail.title = "\(item.value) on \(name)"
            detail.body = "\(row.why). \(item.subjects.count == 1 ? "The one that doesn’t answer is" : "The ones that don’t answer are") \(list(item.subjects))."
            detail.effect = "Auto doesn’t send threads on those models to \(name) until they work."
        case .disk:
            detail.pill = "Low on \(name)"
            detail.title = "\(item.value) free on \(name)"
            detail.body = "Each dispatch makes a worktree, and a first dispatch can clone a whole repo. Below 50 GB, a big clone can fill the disk."
            detail.effect = "Nothing is stopped: Auto still sends work to \(name), and a clone that doesn’t fit fails with git’s own words."
        case .sleep:
            let minutes = item.value.split(separator: " ").compactMap { Int($0) }.first
            detail.pill = "Sleeps on \(name)"
            detail.title = minutes.map { "\(name) sleeps after \($0) minutes" } ?? "\(name) sleeps"
            detail.body = "A sleeping Mac stops sending its load, so Auto skips it and work you send there waits for it to wake."
            detail.effect = "Turning sleep off on power keeps it available."
        case .build:
            detail.pill = "Behind on \(name)"
            detail.title = "\(name) runs \(item.value.lowercasedFirst)"
            detail.body = "The rest of the fleet runs build \(merged.newestBuild ?? ""). \(name) updates when Shepherd does there."
            detail.effect = "Until then it may lack what the newer build added. Sync and dispatch still work between the builds."
        case .other:
            detail.pill = "Differs on \(name)"
            detail.title = "\(row.name) on \(name)"
            detail.body = item.why
        }
        detail.fixable = canFix(item) && attention
        if detail.fixable || item.kind == .disk || item.kind == .sleep {
            let made = command(for: item, packageManager: entry.packageManager, mac: name)
            detail.command = made?.command
            detail.commandNote = made?.note
        }
        return detail
    }

    // MARK: Commands

    /// The command to run on a Mac, in that Mac's own package manager (nix if it has nix, else brew if it has Homebrew, else the tool's own
    /// installer), and what to know about it. Nil when no honest command is known: a remote or a provider is fixed by looking.
    public static func command(for item: FleetCheckItem, packageManager: String, mac: String) -> (command: String, note: String)? {
        switch item.kind {
        case .disk:
            return ("du -sh ~/Library/Developer/Xcode/DerivedData ~/Library/Caches", "Shows the usual large caches. Nothing is deleted.")
        case .sleep:
            return ("sudo pmset -c sleep 0", "Asks for the Mac’s password.")
        case .tool:
            guard let tool = FleetRepoNeed.Tool(rawValue: item.tool ?? "") else { return nil }
            return install(tool, version: item.want, packageManager: packageManager, mac: mac)
        case .command:
            guard let program = item.tool, !program.isEmpty else { return nil }
            if let known = FleetCheckProgram(program) {
                return install(known.tool, version: nil, packageManager: packageManager, mac: mac)
            }
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#\(program)", "\(mac) installs tools with nix, so the command uses it. The package may be named differently.")
            case "brew": return ("brew install \(program)", "\(mac) installs tools with Homebrew, so the command uses it. The formula may be named differently.")
            default: return nil
            }
        case .remote, .provider, .build, .other:
            return nil
        }
    }

    /// A program's own installer, for a Mac with neither nix nor Homebrew; and a name a package manager knows it by.
    struct FleetCheckProgram {
        var tool: FleetRepoNeed.Tool
        init?(_ command: String) {
            switch command {
            case "npx", "node": tool = .node
            case "pnpm": tool = .pnpm
            case "yarn": tool = .yarn
            case "python3", "python": tool = .python
            case "cargo": tool = .cargo
            case "go": tool = .go
            default: return nil
            }
        }
    }

    static func install(_ tool: FleetRepoNeed.Tool, version: String?, packageManager: String, mac: String) -> (command: String, note: String)? {
        let major = version.flatMap { $0.split(separator: ".").first.map(String.init) }
        let minor = version.map { $0.split(separator: ".").prefix(2).joined() }
        let viaNix = "\(mac) installs tools with nix, so the command uses it."
        let viaBrew = "\(mac) installs tools with Homebrew, so the command uses it."
        let own = "\(mac) has neither nix nor Homebrew, so this is the tool’s own installer."
        switch tool {
        case .xcode:
            return ("open \"macappstore://apps.apple.com/app/xcode/id497799835\"", "Opens Xcode in the App Store on \(mac). Neither nix nor Homebrew installs it.")
        case .node:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#\(major.map { "nodejs_\($0)" } ?? "nodejs")", viaNix)
            case "brew": return ("brew install \(major.map { "node@\($0)" } ?? "node")", viaBrew)
            default: return ("curl -fsSL https://fnm.vercel.app/install | bash\(major.map { " && fnm install \($0)" } ?? "")", own)
            }
        case .npm:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#nodejs", viaNix)
            case "brew": return ("brew install node", viaBrew)
            default: return ("curl -fsSL https://fnm.vercel.app/install | bash", own)
            }
        case .pnpm:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#\(major.map { "pnpm_\($0)" } ?? "pnpm")", viaNix)
            case "brew": return ("brew install pnpm", viaBrew)
            default: return ("corepack enable pnpm\(major.map { " && corepack prepare pnpm@\($0) --activate" } ?? "")", "\(own) corepack comes with node.")
            }
        case .yarn:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#yarn", viaNix)
            case "brew": return ("brew install yarn", viaBrew)
            default: return ("corepack enable yarn", "\(own) corepack comes with node.")
            }
        case .nix:
            if packageManager == "brew" { return ("brew install nix", viaBrew) }
            return ("curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install", own)
        case .cargo:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#cargo", viaNix)
            case "brew": return ("brew install rust", viaBrew)
            default: return ("curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh", own)
            }
        case .go:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#go", viaNix)
            case "brew": return ("brew install go", viaBrew)
            default: return ("open https://go.dev/dl/", "\(own) It opens the download page.")
            }
        case .python:
            switch packageManager {
            case "nix": return ("nix profile install nixpkgs#python\(minor ?? "3")", viaNix)
            case "brew": return ("brew install python@\(version ?? "3")", viaBrew)
            default: return ("open https://www.python.org/downloads/", "\(own) It opens the download page.")
            }
        }
    }

    // MARK: Fixing with an agent

    static func fix(rows: [FleetCheckRow], mac: UUID, entry: FleetCheckPage.Entry, items: [String: [UUID: FleetCheckItem]],
                    merged: [String: FleetCheckPage.Merged], everything: Bool) -> FleetCheckFix {
        let name = entry.name
        var lines: [String] = []
        var repos: [String] = []
        for (index, row) in rows.enumerated() {
            guard let item = items[row.id]?[mac] else { continue }
            let context = merged[row.id]
            repos += context?.subjects ?? []
            var line = "\(index + 1). \(row.name): \(sentence(item, row: row, merged: context, mac: name))"
            if let made = command(for: item, packageManager: entry.packageManager, mac: name) { line += " Suggested: `\(made.command)`." }
            lines.append(line)
        }
        let title = everything || rows.count > 1 ? "Fix what Check found on \(name)" : rows.first.map { threadTitle($0, item: items[$0.id]?[mac], mac: name) } ?? "Fix what Check found on \(name)"
        let prompt = """
        Shepherd's Fleet Check found these on this Mac (\(name)). Fix them, one at a time, in order:

        \(lines.joined(separator: "\n"))

        Use \(entry.packageManager == "nix" ? "nix" : entry.packageManager == "brew" ? "Homebrew" : "each tool's own installer") to install programs on this Mac. \
        Stop and ask me before anything needs a password or opens a browser. When each is done, check it (a `--version` call, or the same check as above) and say so. \
        Change nothing else, and don't touch the repository.
        """
        return FleetCheckFix(mac: mac, macName: name, items: rows.map(\.id), title: title, prompt: prompt, repos: Array(Set(repos)).sorted())
    }

    private static func sentence(_ item: FleetCheckItem, row: FleetCheckRow, merged: FleetCheckPage.Merged?, mac: String) -> String {
        switch item.kind {
        case .tool:
            let who = merged.map { list($0.subjects) } ?? ""
            let asks = who.isEmpty ? "" : "\(who) ask for it\(merged?.sources.isEmpty == false ? " in \(merged!.sources.joined(separator: ", "))" : ""). "
            return "\(asks)This Mac \(item.value == "Missing" ? "doesn’t have it" : "has \(item.value.replacingOccurrences(of: "Has ", with: ""))")."
        case .command: return "the \(item.tool ?? item.name) program, which an MCP server runs, isn’t installed here."
        case .remote: return "`git ls-remote` of \(item.tool ?? "the remote") gets no answer from this Mac. Find out why (ssh key, sign-in) and fix it."
        case .provider: return "\(item.value). Find out why and fix it; the sign-in must stay in this Mac's own sign-ins."
        case .disk: return "\(item.value) free. Find what is large and safe to remove (caches, DerivedData) and tell me before deleting anything."
        case .sleep: return "this Mac sleeps (\(item.value.lowercasedFirst)). Keep it awake on power."
        case .build, .other: return item.value
        }
    }

    private static func threadTitle(_ row: FleetCheckRow, item: FleetCheckItem?, mac: String) -> String {
        guard let item else { return "Fix \(row.name) on \(mac)" }
        switch item.kind {
        case .tool: return item.value == "Missing" ? "Install \(row.name) on \(mac)" : "Switch \(row.name) on \(mac)"
        case .command: return "Install \(item.tool ?? item.name) on \(mac)"
        case .remote: return "Fix git access to \(item.tool ?? row.name) on \(mac)"
        case .provider: return "Fix \(item.subjects.first ?? "model") sign-in on \(mac)"
        case .disk: return "Free disk space on \(mac)"
        case .sleep: return "Keep \(mac) awake"
        case .build, .other: return "Fix \(row.name) on \(mac)"
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
