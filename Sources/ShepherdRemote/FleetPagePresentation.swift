import Foundation
import ShepherdCore
import ShepherdProtocol

// The Fleet page as plain values (FleetA, and the sidebar's Fleet footer and the palette's Open
// Fleet): one card per Mac with its room, CPU, memory, power, readiness and agents, derived once
// per change from the host's `FleetSnapshot` and the Send work here weights. The Mac page and
// the iPhone and iPad fleet screens draw the same values.

/// How a line of a card reads: which color the view gives it.
public enum FleetTone: Equatable, Sendable {
    case primary, secondary, tertiary
    /// Plenty of room, plugged in, ready.
    case good
    /// Busy, on battery, warm, or missing something.
    case warn
    /// Full or hot: Auto leaves the Mac out.
    case bad
    /// Work in progress.
    case active
}

/// A gauge and the words beside it.
public struct FleetMetric: Equatable, Sendable {
    /// 0...1.
    public var fraction: Double
    public var text: String
    public var tone: FleetTone

    public init(fraction: Double, text: String, tone: FleetTone) {
        self.fraction = fraction
        self.text = text
        self.tone = tone
    }
}

/// A line of text and its tone.
public struct FleetLine: Equatable, Sendable {
    public var text: String
    public var tone: FleetTone

    public init(text: String, tone: FleetTone) {
        self.text = text
        self.tone = tone
    }
}

/// One Mac's card.
public struct FleetMacCard: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case thisMac, connected, connecting, asleep
    }

    public var id: UUID
    public var name: String
    /// "MacBook Pro · M4 Pro · 36 GB".
    public var hardware: String
    public var status: Status
    public var statusText: String
    /// "Most room", "Some room", "Little room", "No room" or "Not counted", with the gauge.
    public var room: FleetMetric
    /// Nil where the Mac isn't answering: the card draws a dash.
    public var cpu: FleetMetric?
    public var memory: FleetMetric?
    public var power: FleetLine
    public var ready: FleetLine
    public var agents: String
    /// Under the readings of a Mac that isn't answering.
    public var note: String?
    public var weight: FleetSendWeight
    public var repos: [String]
    /// Retry: try the link again now.
    public var canRetry: Bool
    /// What a compact row says of the power: "battery 41%", "plugged in", with "warm" or "hot" after it
    /// when the Mac runs warm. Empty while the Mac isn't answering.
    public var powerFact = ""
    /// When an asleep Mac was last seen, as a time of day ("10:42"); nil otherwise.
    public var since: String?
    /// Threads working on the Mac now; nil while it isn't answering.
    public var working: Int?
    /// The Mac is one of the fleet's (its id is a fleet host id), so a Send work here weight can be set for it. False for a
    /// Mac this device holds that no fleet Mac has told it about (`FleetDeviceList`).
    public var takesWeight = true
    /// Names the Mac's weight control for VoiceOver ("Send work to Mac mini").
    public var weightLabel: String { "Send work to \(name)" }
    public var isThisMac: Bool { status == .thisMac }
}

/// One line of the Dispatches log: work this Mac sent, where it went and why.
public struct FleetDispatchRow: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// "Sent by Speed up checkout CI", or "Sent by you" for a thread started from New Thread.
    public var sentBy: String
    /// The Mac it went to, as the chip names it; "No Mac yet" while it is waiting to be placed.
    public var host: String
    /// Why it went there, or why it didn't start.
    public var reason: String
    public var state: String
    public var tone: FleetTone
    /// "4m ago".
    public var age: String

    public var accessibilityLabel: String { "\(title), \(sentBy.lowercasedFirst), \(host), \(state), \(reason), \(age)" }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// How much of a card a compact row (the iPhone's and iPhone Duo's Fleet list) says in its facts line.
public enum FleetFactsStyle: Equatable, Sendable {
    /// FleetA-phone: "CPU 72% · 9.4 GB free · battery 41%".
    case phone
    /// DuoOpenFleet and DuoBookFleet: the phone's line and how many threads work.
    case duo
    /// DuoClosedFleet: "CPU 72% · battery 41%" (the memory only while plugged in).
    case compact
}

extension FleetMacCard {
    /// The mono line under a compact row's gauge. A Mac that isn't answering says since when.
    public func facts(_ style: FleetFactsStyle) -> String {
        if status == .asleep { return since.map { "since \($0)" } ?? "not reached yet" }
        guard let cpu else { return "Waiting for a reading" }
        let cpuFact = "CPU \(cpu.text)"
        let memoryFact = memory?.text
        switch style {
        case .phone, .duo:
            var parts = [cpuFact, memoryFact, powerFact.isEmpty ? nil : powerFact].compactMap { $0 }
            if style == .duo, let working, working > 0 { parts.append("\(working) working") }
            return parts.joined(separator: " · ")
        case .compact:
            return [cpuFact, powerFact.hasPrefix("battery") || powerFact.hasPrefix("on battery") ? powerFact : memoryFact].compactMap { $0 }.joined(separator: " · ")
        }
    }

    /// A compact row's VoiceOver label: "Mac mini, most room".
    public var rowLabel: String { "\(name), \(status == .asleep ? "asleep" : room.text.lowercased())" }

    /// The word at the right of a compact row's name: how much room, or "Asleep".
    public var rowRoom: String { status == .asleep ? "Asleep" : room.text }
}

/// Who reads the page. A Mac's app draws its own host as "This Mac"; a phone or an iPad has no "this", and
/// names the Mac it asked.
public enum FleetViewer: Equatable, Sendable {
    case mac, client
}

/// The page: its cards, the header's summary and where the next work would go.
public struct FleetPage: Equatable, Sendable {
    public var cards: [FleetMacCard]
    /// The Dispatches log, newest first.
    public var dispatches: [FleetDispatchRow] = []
    /// "3 Macs · 1 asleep · 6 threads working".
    public var summary: String
    /// The Mac Auto would pick now, by name; nil when no Mac counts.
    public var nextGoesTo: String?
    public var footer: FleetFooter
    /// Settings ▸ Fleet ▸ Auto dispatch: New thread's Auto place is on, and the page's placement card says so.
    public var autoDispatch = true
    /// Dispatches that need a decision or are on their way (waiting, held, starting, not sent), as cards (FleetStates).
    public var attention: [FleetDispatchCard] = []
    /// Macs that are linked and still taking in changes.
    public var behind: [FleetDispatchPresentation.BehindMac] = []
    /// Every dispatch this Mac sent, as a card: what a thread draws for the dispatches it made (`FleetDispatchPresentation`).
    public var dispatchCards: [FleetDispatchCard] = []

    public static let empty = FleetPage(cards: [], summary: "", nextGoesTo: nil, footer: .init(dots: [], detail: "", label: "Fleet"))
}

/// The sidebar's Fleet row: a dot per Mac and how many sleep.
public struct FleetFooter: Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        case thisMac, connected, connecting, asleep
    }

    public var dots: [Dot]
    /// "1 asleep", "All awake", "Just this Mac".
    public var detail: String
    /// What VoiceOver reads: "Fleet: 3 Macs, Mac Studio asleep".
    public var label: String
    /// The palette row's trailing word: "1 asleep", or nil while none is.
    public var asleepCount = 0

    public var paletteDetail: String? { asleepCount > 0 ? "\(asleepCount) asleep" : nil }

    public init(dots: [Dot], detail: String, label: String, asleepCount: Int = 0) {
        self.dots = dots
        self.detail = detail
        self.label = label
        self.asleepCount = asleepCount
    }
}

public enum FleetPagePresentation {
    /// How many dispatches the log lists.
    static let fleetDispatchLogLimit = 50

    /// Builds the page. `snapshotAge` is how long this device has held `snapshot`, added to each
    /// sample's age, so a Mac that stops pushing goes stale on screen without a new snapshot.
    /// `batteryCountsHalf` is the fleet setting that halves a Mac on battery.
    public static func make(snapshot: FleetSnapshot, weight: (UUID) -> FleetSendWeight, snapshotAge: TimeInterval = 0,
                            batteryCountsHalf: Bool = true, autoDispatch: Bool = true, threadCap: Int = HostSettings.fleetThreadCapDefault,
                            viewer: FleetViewer = .mac,
                            locale: Locale = .current, calendar: Calendar = .current, now: Date = Date()) -> FleetPage {
        guard snapshot.enabled, let thisID = snapshot.hostID else { return .empty }
        let macs = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })

        struct Entry {
            var id: UUID
            var name: String
            var status: FleetMacCard.Status
            var lastSeen: Double?
            var state: FleetMacState?
            var weight: FleetSendWeight
            /// The sample, when it is recent enough to show.
            var sample: FleetPressureSample?
            var skip: FleetRoom.Skip?
        }
        // The Mac that answered is "This Mac" to its own app; a client names it, and reaches it, or it would not have answered.
        let answering = viewer == .mac ? Entry(id: thisID, name: "This Mac", status: .thisMac, lastSeen: nil, state: macs[thisID], weight: weight(thisID))
            : Entry(id: thisID, name: snapshot.name.isEmpty ? "Mac" : snapshot.name, status: .connected, lastSeen: nil, state: macs[thisID], weight: weight(thisID))
        var entries: [Entry] = [answering]
        for peer in snapshot.peers {
            let status: FleetMacCard.Status = switch peer.link {
            case .connected: .connected
            case .connecting: .connecting
            case .offline: .asleep
            }
            entries.append(Entry(id: peer.hostID, name: peer.name, status: status, lastSeen: peer.lastSeen, state: macs[peer.hostID], weight: weight(peer.hostID)))
        }
        for index in entries.indices {
            var entry = entries[index]
            guard entry.status != .asleep, let state = entry.state, let sample = state.sample, let age = state.sampleAge else {
                entries[index] = entry
                continue
            }
            let total = age + snapshotAge
            // A stale sample is not shown; a Mac Auto skips for its load is shown with its numbers.
            let recent = FleetRoom.skip(sample, age: total) != .stale && FleetRoom.skip(sample, age: total) != .future
            if recent {
                entry.sample = sample
                entry.skip = FleetRoom.skip(sample, age: total, weight: entry.weight)
            }
            entries[index] = entry
        }

        let scores = entries.map { entry in
            entry.sample != nil && entry.skip == nil ? FleetRoom.score(entry.sample!, weight: entry.weight, batteryCountsHalf: batteryCountsHalf) : 0
        }
        let best = scores.max() ?? 0
        // With one Mac counted there is nothing to compare it with: its room is its own.
        let compared = scores.filter { $0 > 0 }.count > 1

        var cards: [FleetMacCard] = []
        for (index, entry) in entries.enumerated() {
            cards.append(card(entry.id, name: entry.name, status: entry.status, lastSeen: entry.lastSeen, state: entry.state,
                              sample: entry.sample, skip: entry.skip, weight: entry.weight, score: scores[index], best: best, compared: compared,
                              batteryCountsHalf: batteryCountsHalf, locale: locale, calendar: calendar))
        }

        let winner = FleetRoom.nextGoesTo(zip(entries, scores).map { FleetRoom.Candidate(id: $0.0.id, score: $0.1) }, local: thisID)
        let working = entries.compactMap { $0.sample?.activeAgents }.reduce(0, +)
        let asleep = cards.filter { $0.status == .asleep }
        var summary = ["\(cards.count) \(cards.count == 1 ? "Mac" : "Macs")"]
        if !asleep.isEmpty { summary.append("\(asleep.count) asleep") }
        summary.append(working == 0 ? "no threads working" : "\(working) \(working == 1 ? "thread" : "threads") working")
        var page = FleetPage(cards: cards, summary: summary.joined(separator: " · "),
                             nextGoesTo: winner.flatMap { id in cards.first { $0.id == id }?.name },
                             footer: footer(cards, asleep: asleep, viewer: viewer))
        page.dispatches = snapshot.dispatches.sorted { $0.createdAt > $1.createdAt }.prefix(fleetDispatchLogLimit).map { dispatchRow($0, now: now) }
        page.autoDispatch = autoDispatch
        let context = FleetCardContext(snapshot: snapshot, cap: threadCap, locale: locale, calendar: calendar)
        page.dispatchCards = FleetDispatchPresentation.cards(Array(snapshot.dispatches.prefix(fleetDispatchLogLimit)), in: context)
        let dayAgo = (now.timeIntervalSince1970 - 86_400) * 1000
        let waiting: Set<FleetDispatchState> = [.waitingRoom, .waitingWake, .heldLimit, .heldRestart, .preparing]
        let recordState = Dictionary(snapshot.dispatches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        page.attention = page.dispatchCards.filter { card in
            guard card.layout == .state, let record = recordState[card.id] else { return false }
            return waiting.contains(record.state) || (record.state == .failed && record.updatedAt > dayAgo)
        }
        page.behind = FleetDispatchPresentation.behind(snapshot)
        return page
    }

    /// The words of one record: the state, why it went where it did (or why it didn't start) and its age.
    static func dispatchRow(_ record: FleetDispatchRecord, now: Date) -> FleetDispatchRow {
        let (state, tone): (String, FleetTone) = switch record.state {
        case .placing: ("Placing", .tertiary)
        case .waitingRoom, .waitingWake: ("Waiting", .tertiary)
        case .heldLimit, .heldRestart: ("Held", .warn)
        case .preparing: ("Preparing", .active)
        case .running: ("Working", .active)
        case .delivering: ("Delivering", .active)
        case .done: ("Done", .good)
        case .failed: ("Failed", .bad)
        case .cancelled: ("Cancelled", .tertiary)
        }
        let host = record.targetHostName ?? record.requestedHost.flatMap { FleetPlacement.isAuto($0) ? nil : $0 } ?? "No Mac yet"
        return FleetDispatchRow(
            id: record.id, title: record.title.isEmpty ? "Untitled" : record.title,
            sentBy: record.kind == .userThread ? "Sent by you" : record.parentTitle.isEmpty ? "Sent by a thread" : "Sent by \(record.parentTitle)",
            host: host, reason: reason(record, host: host), state: state, tone: tone,
            age: ForgePresentation.ago(Date(timeIntervalSince1970: record.createdAt / 1000), now: now))
    }

    private static func reason(_ record: FleetDispatchRecord, host: String) -> String {
        switch record.state {
        case .failed: return failureWords(record.failure, detail: record.failureDetail)
        case .heldLimit: return "This thread already has its limit of dispatches going"
        case .heldRestart: return "Held since the restart; send it again from the thread"
        case .waitingRoom: return "\(host) has no room for it yet"
        case .waitingWake: return "Waiting for \(host) to wake"
        default: break
        }
        let codes = record.reasonCodes
        if let skip = codes.first(where: { $0.code == .localIneligible })?.skip {
            let why = switch skip {
            case "cpu": "is busy"
            case "memory": "is low on memory"
            case "thermal": "is running hot"
            case "manualOnly": "is set to Manual only"
            default: "isn't counted"
            }
            return "Auto: This Mac \(why)"
        }
        switch codes.first?.code {
        case .named?: return record.kind == .userThread ? "You picked \(host)" : "Picked \(host)"
        case .mostRoom?: return "Auto: most room"
        case .onlyChoice?: return "Auto: the only Mac that counts"
        case .keptLocal?: return "Auto: This Mac has room"
        default: return ""
        }
    }

    private static func failureWords(_ code: String?, detail: String?) -> String {
        let words: String
        switch code {
        case FleetDispatchCode.repoMissing: words = "That Mac doesn't have this repository"
        case FleetDispatchCode.repoAmbiguous: words = "That Mac has this repository more than once"
        case FleetDispatchCode.commitUnreachable: words = "That Mac can't fetch this commit from origin"
        case FleetDispatchCode.hostNotReady: words = "That Mac lacks something the thread needs"
        case FleetDispatchCode.noSuchHost: words = "No Mac has that name"
        case FleetDispatchCode.snapshotTooLarge: return FleetSendingCard.tooLargeWords(detail)
        case FleetDispatchCode.snapshotMismatch: return "The files didn't arrive intact, so nothing started"
        case FleetDispatchCode.snapshotFailed: return "The files couldn't be sent, so nothing started"
        case FleetDispatchCode.peerGone: words = "The Mac went away"
        case FleetDispatchCode.refused: words = "That Mac refused it"
        default: words = "Not started"
        }
        return detail.map { "\(words): \($0)" } ?? words
    }

    private static func footer(_ cards: [FleetMacCard], asleep: [FleetMacCard], viewer: FleetViewer) -> FleetFooter {
        let dots: [FleetFooter.Dot] = cards.map {
            switch $0.status {
            case .thisMac: .thisMac
            case .connected: .connected
            case .connecting: .connecting
            case .asleep: .asleep
            }
        }
        let detail = asleep.isEmpty ? (cards.count <= 1 ? (viewer == .mac ? "Just this Mac" : "One Mac") : "All awake") : "\(asleep.count) asleep"
        let label: String
        switch asleep.count {
        case 0: label = "Fleet: \(cards.count) \(cards.count == 1 ? "Mac" : "Macs")"
        case 1: label = "Fleet: \(cards.count) Macs, \(asleep[0].name) asleep"
        default: label = "Fleet: \(cards.count) Macs, \(asleep.count) asleep"
        }
        return FleetFooter(dots: dots, detail: detail, label: label, asleepCount: asleep.count)
    }

    private static func card(_ id: UUID, name: String, status: FleetMacCard.Status, lastSeen: Double?, state: FleetMacState?,
                             sample: FleetPressureSample?, skip: FleetRoom.Skip?, weight: FleetSendWeight, score: Double, best: Double, compared: Bool,
                             batteryCountsHalf: Bool, locale: Locale, calendar: Calendar) -> FleetMacCard {
        let readiness = state?.readiness
        let asleep = status == .asleep
        let hardware = [readiness?.model, readiness?.chip.isEmpty == false ? readiness?.chip : nil,
                        (sample ?? state?.sample).map { memory($0.totalMemoryBytes) }]
            .compactMap { $0 }.joined(separator: " · ")

        // Room
        let room: FleetMetric
        if asleep || sample == nil {
            room = FleetMetric(fraction: 0, text: "Not counted", tone: .tertiary)
        } else {
            switch skip {
            case .manualOnly?, .stale?, .future?:
                room = FleetMetric(fraction: 0, text: "Not counted", tone: .tertiary)
            case .cpu?, .memory?, .thermal?:
                room = FleetMetric(fraction: 0, text: "No room", tone: .bad)
            case nil:
                if compared {
                    let share = best > 0 ? min(1, score / best) : 0
                    let text = score >= best ? "Most room" : share >= 0.5 ? "Some room" : "Little room"
                    room = FleetMetric(fraction: max(0.04, share), text: text, tone: score >= best ? .good : .warn)
                } else {
                    // What is free of the CPU and of the memory.
                    let share = (1 - min(1, max(0, sample?.cpuUtilization ?? 0))) * (sample?.availableShare ?? 0)
                    let text = share >= 0.5 ? "Room to spare" : share >= 0.2 ? "Some room" : "Little room"
                    room = FleetMetric(fraction: max(0.04, share), text: text, tone: share >= 0.5 ? .good : .warn)
                }
            }
        }

        // CPU and memory
        var cpu: FleetMetric?, mem: FleetMetric?
        if !asleep, let sample {
            let busy = min(1, max(0, sample.cpuUtilization))
            cpu = FleetMetric(fraction: busy, text: "\(Int((busy * 100).rounded()))%", tone: busy >= FleetRoom.cpuCeiling ? .bad : busy >= 0.6 ? .warn : .good)
            mem = FleetMetric(fraction: 1 - sample.availableShare, text: "\(memory(sample.availableMemoryBytes)) free", tone: .tertiary)
        }

        // Power
        let power: FleetLine
        if !asleep, let sample {
            var parts = [sample.onBattery ? (sample.batteryPercent.map { "Battery \($0)%" } ?? "On battery") : "Plugged in"]
            parts.append(thermalWord(sample.thermal))
            if sample.onBattery, batteryCountsHalf { parts.append("counts half") }
            power = FleetLine(text: parts.joined(separator: " · "),
                              tone: sample.thermal >= .serious ? .bad : sample.onBattery || sample.thermal >= .fair ? .warn : .primary)
        } else if asleep {
            power = FleetLine(text: lastSeen.map { "Last seen \(time($0, locale: locale, calendar: calendar))" } ?? "Not seen yet", tone: .tertiary)
        } else {
            power = FleetLine(text: "Waiting for a reading", tone: .tertiary)
        }

        // Ready
        let ready: FleetLine
        if asleep {
            ready = FleetLine(text: "Catches up when it wakes", tone: .tertiary)
        } else if let readiness {
            ready = readiness.missing.isEmpty ? FleetLine(text: "Every model and tool", tone: .good)
                : FleetLine(text: missingText(readiness.missing), tone: .warn)
        } else {
            ready = FleetLine(text: "Checking…", tone: .tertiary)
        }

        let statusText: String
        switch status {
        case .thisMac: statusText = "This Mac"
        case .connected: statusText = "Connected"
        case .connecting: statusText = "Connecting"
        case .asleep: statusText = lastSeen == nil ? "Offline" : "Asleep"
        }
        var note: String?
        if asleep {
            note = lastSeen.map { "Asleep since \(time($0, locale: locale, calendar: calendar)). Nothing moves to another Mac; it catches up when it wakes." }
                ?? "Not reachable yet. Nothing moves to another Mac."
        }
        var card = FleetMacCard(id: id, name: name, hardware: hardware, status: status, statusText: statusText, room: room, cpu: cpu, memory: mem,
                                power: power, ready: ready,
                                agents: asleep || sample == nil ? "—" : sample!.activeAgents == 0 ? "None working" : "\(sample!.activeAgents) working",
                                note: note, weight: weight, repos: readiness?.repos ?? [], canRetry: asleep)
        if !asleep, let sample {
            var fact = sample.onBattery ? (sample.batteryPercent.map { "battery \($0)%" } ?? "on battery") : "plugged in"
            if sample.thermal >= .fair { fact += " · \(thermalWord(sample.thermal))" }
            card.powerFact = fact
            card.working = sample.activeAgents
        } else if asleep {
            card.since = lastSeen.map { time($0, locale: locale, calendar: calendar) }
        }
        return card
    }

    // MARK: Words

    /// "9.4 GB", "41 GB": binary gigabytes, one decimal under ten.
    static func memory(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1_073_741_824
        return gigabytes < 10 ? String(format: "%.1f GB", gigabytes) : "\(Int(gigabytes.rounded())) GB"
    }

    static func thermalWord(_ thermal: FleetThermal) -> String {
        switch thermal {
        case .nominal: "cool"
        case .fair: "warm"
        case .serious: "hot"
        case .critical: "very hot"
        }
    }

    /// "muse CLI isn’t installed", "git and Xcode aren’t installed", "a, b and 2 more aren’t installed".
    public static func missingText(_ missing: [FleetMissingTool]) -> String {
        let names = missing.map { tool -> String in
            switch tool.kind {
            case .binary: "\(tool.name) CLI"
            case .git: "git"
            case .xcode: "Xcode"
            }
        }
        switch names.count {
        case 0: return ""
        case 1: return "\(names[0]) isn’t installed"
        case 2: return "\(names[0]) and \(names[1]) aren’t installed"
        case 3: return "\(names[0]), \(names[1]) and \(names[2]) aren’t installed"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more aren’t installed"
        }
    }

    private static func time(_ milliseconds: Double, locale: Locale, calendar: Calendar) -> String {
        Date(timeIntervalSince1970: milliseconds / 1000).formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
    }
}

// MARK: A device's list of Macs

/// A Mac this device is paired with (`MobileHosts`): what the Fleet screen needs of it beyond the fleet's own view.
public struct FleetHeldMac: Equatable, Sendable {
    public enum Link: Equatable, Sendable { case connected, connecting, offline }

    /// This device's own id for the pairing (what Forget and Retry act on).
    public var configID: UUID
    /// The Mac's fleet host id, once it has said it (`helloOk.hostID`); how its card is found in the fleet's view.
    public var fleetID: UUID?
    public var name: String
    public var link: Link
    /// When this device's connection to it last ended.
    public var lastSeen: Date?

    public init(configID: UUID, fleetID: UUID?, name: String, link: Link, lastSeen: Date? = nil) {
        self.configID = configID
        self.fleetID = fleetID
        self.name = name
        self.link = link
        self.lastSeen = lastSeen
    }
}

/// One row of a device's Fleet screen: a Mac's card, and the pairing this device holds with it (nil for a Mac the fleet
/// told it about and it never paired with, which it can't forget).
public struct FleetListRow: Identifiable, Equatable, Sendable {
    public var card: FleetMacCard
    public var held: UUID?
    public var id: UUID { card.id }
    /// This device can't reach the Mac itself (it is offline or asleep): Retry tries again now.
    public var canRetry: Bool { held != nil && card.canRetry }
}

/// The Macs a phone or iPad lists on its Fleet screen: the fleet's own cards, each joined to the pairing this device
/// holds with it, then the Macs it holds that the fleet's view doesn't show (the fleet couldn't be read, Fleet is off on
/// that Mac, or it is an older one), drawn as asleep or waiting in the same list.
public enum FleetDeviceList {
    public static func rows(page: FleetPage, held: [FleetHeldMac], locale: Locale = .current, calendar: Calendar = .current) -> [FleetListRow] {
        let byFleetID = Dictionary(held.compactMap { mac in mac.fleetID.map { ($0, mac) } }, uniquingKeysWith: { first, _ in first })
        var rows = page.cards.map { FleetListRow(card: $0, held: byFleetID[$0.id]?.configID) }
        let shown = Set(rows.compactMap(\.held))
        for mac in held where !shown.contains(mac.configID) {
            rows.append(FleetListRow(card: heldCard(mac, locale: locale, calendar: calendar), held: mac.configID))
        }
        return rows
    }

    /// The Mac's card from what this device knows of it alone.
    static func heldCard(_ mac: FleetHeldMac, locale: Locale, calendar: Calendar) -> FleetMacCard {
        let status: FleetMacCard.Status = switch mac.link {
        case .connected: .connected
        case .connecting: .connecting
        case .offline: .asleep
        }
        let seen = mac.lastSeen.map {
            $0.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).hour().minute())
        }
        var card = FleetMacCard(
            id: mac.fleetID ?? mac.configID, name: mac.name, hardware: "", status: status,
            statusText: status == .connected ? "Connected" : status == .connecting ? "Connecting" : seen == nil ? "Offline" : "Asleep",
            room: FleetMetric(fraction: 0, text: "Not counted", tone: .tertiary), cpu: nil, memory: nil,
            power: FleetLine(text: status == .asleep ? (seen.map { "Last seen \($0)" } ?? "Not seen yet") : "Waiting for a reading", tone: .tertiary),
            ready: FleetLine(text: status == .asleep ? "Catches up when it wakes" : "Checking…", tone: .tertiary),
            agents: "—", note: nil, weight: .normal, repos: [], canRetry: status == .asleep)
        card.since = seen
        card.takesWeight = mac.fleetID != nil
        return card
    }

    /// "3 Macs · 1 asleep": the Settings row's trail, nil with no Mac.
    public static func trail(_ rows: [FleetListRow]) -> String? {
        guard !rows.isEmpty else { return nil }
        let asleep = rows.filter { $0.card.status == .asleep }.count
        return ["\(rows.count) \(rows.count == 1 ? "Mac" : "Macs")", asleep > 0 ? "\(asleep) asleep" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The sidebar's Fleet row: "1 asleep", "All awake" or "One Mac"; and what VoiceOver reads.
    public static func footer(_ rows: [FleetListRow]) -> FleetFooter {
        let asleep = rows.filter { $0.card.status == .asleep }
        let dots: [FleetFooter.Dot] = rows.map {
            switch $0.card.status {
            case .thisMac: .thisMac
            case .connected: .connected
            case .connecting: .connecting
            case .asleep: .asleep
            }
        }
        let detail = asleep.isEmpty ? (rows.count <= 1 ? "One Mac" : "All awake") : "\(asleep.count) asleep"
        let label = switch asleep.count {
        case 0: "Fleet: \(rows.count) \(rows.count == 1 ? "Mac" : "Macs")"
        case 1: "Fleet: \(rows.count) Macs, \(asleep[0].card.name) asleep"
        default: "Fleet: \(rows.count) Macs, \(asleep.count) asleep"
        }
        return FleetFooter(dots: dots, detail: detail, label: label, asleepCount: asleep.count)
    }
}
