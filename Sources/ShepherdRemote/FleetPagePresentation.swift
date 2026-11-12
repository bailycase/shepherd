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
}

/// A gauge and the words beside it.
public struct FleetMetric: Equatable, Sendable {
    /// 0...1.
    public var fraction: Double
    public var text: String
    public var tone: FleetTone
}

/// A line of text and its tone.
public struct FleetLine: Equatable, Sendable {
    public var text: String
    public var tone: FleetTone
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
    /// Names the Mac's weight control for VoiceOver ("Send work to Mac mini").
    public var weightLabel: String { "Send work to \(name)" }
    public var isThisMac: Bool { status == .thisMac }
}

/// The page: its cards, the header's summary and where the next work would go.
public struct FleetPage: Equatable, Sendable {
    public var cards: [FleetMacCard]
    /// "3 Macs · 1 asleep · 6 threads working".
    public var summary: String
    /// The Mac Auto would pick now, by name; nil when no Mac counts.
    public var nextGoesTo: String?
    public var footer: FleetFooter

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
    /// Builds the page. `snapshotAge` is how long this device has held `snapshot`, added to each
    /// sample's age, so a Mac that stops pushing goes stale on screen without a new snapshot.
    /// `batteryCountsHalf` is the fleet setting that halves a Mac on battery.
    public static func make(snapshot: FleetSnapshot, weight: (UUID) -> FleetSendWeight, snapshotAge: TimeInterval = 0,
                            batteryCountsHalf: Bool = true, locale: Locale = .current, calendar: Calendar = .current) -> FleetPage {
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
        var entries: [Entry] = [Entry(id: thisID, name: "This Mac", status: .thisMac, lastSeen: nil, state: macs[thisID], weight: weight(thisID))]
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

        var cards: [FleetMacCard] = []
        for (index, entry) in entries.enumerated() {
            cards.append(card(entry.id, name: entry.name, status: entry.status, lastSeen: entry.lastSeen, state: entry.state,
                              sample: entry.sample, skip: entry.skip, weight: entry.weight, score: scores[index], best: best,
                              batteryCountsHalf: batteryCountsHalf, locale: locale, calendar: calendar))
        }

        let winner = FleetRoom.nextGoesTo(zip(entries, scores).map { FleetRoom.Candidate(id: $0.0.id, score: $0.1) }, local: thisID)
        let working = entries.compactMap { $0.sample?.activeAgents }.reduce(0, +)
        let asleep = cards.filter { $0.status == .asleep }
        var summary = ["\(cards.count) \(cards.count == 1 ? "Mac" : "Macs")"]
        if !asleep.isEmpty { summary.append("\(asleep.count) asleep") }
        summary.append(working == 0 ? "no threads working" : "\(working) \(working == 1 ? "thread" : "threads") working")
        return FleetPage(cards: cards, summary: summary.joined(separator: " · "),
                         nextGoesTo: winner.flatMap { id in cards.first { $0.id == id }?.name },
                         footer: footer(cards, asleep: asleep))
    }

    private static func footer(_ cards: [FleetMacCard], asleep: [FleetMacCard]) -> FleetFooter {
        let dots: [FleetFooter.Dot] = cards.map {
            switch $0.status {
            case .thisMac: .thisMac
            case .connected: .connected
            case .connecting: .connecting
            case .asleep: .asleep
            }
        }
        let detail = asleep.isEmpty ? (cards.count <= 1 ? "Just this Mac" : "All awake") : "\(asleep.count) asleep"
        let label: String
        switch asleep.count {
        case 0: label = "Fleet: \(cards.count) \(cards.count == 1 ? "Mac" : "Macs")"
        case 1: label = "Fleet: \(cards.count) Macs, \(asleep[0].name) asleep"
        default: label = "Fleet: \(cards.count) Macs, \(asleep.count) asleep"
        }
        return FleetFooter(dots: dots, detail: detail, label: label, asleepCount: asleep.count)
    }

    private static func card(_ id: UUID, name: String, status: FleetMacCard.Status, lastSeen: Double?, state: FleetMacState?,
                             sample: FleetPressureSample?, skip: FleetRoom.Skip?, weight: FleetSendWeight, score: Double, best: Double,
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
                let share = best > 0 ? min(1, score / best) : 0
                let text = score >= best ? "Most room" : share >= 0.5 ? "Some room" : "Little room"
                room = FleetMetric(fraction: max(0.04, share), text: text, tone: score >= best ? .good : .warn)
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
        return FleetMacCard(id: id, name: name, hardware: hardware, status: status, statusText: statusText, room: room, cpu: cpu, memory: mem,
                            power: power, ready: ready,
                            agents: asleep || sample == nil ? "—" : sample!.activeAgents == 0 ? "None working" : "\(sample!.activeAgents) working",
                            note: note, weight: weight, repos: readiness?.repos ?? [], canRetry: asleep)
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
