import Foundation
import ShepherdCore
import ShepherdProtocol

// Dispatches where records surface (FleetDispatch, FleetRemote, FleetStates, FleetSidebar): the parent thread's
// dispatch and result cards, the dispatched thread's From box, header and banners, and the cards of a record that
// waits, is held or couldn't be sent. Plain values derived from the records the sending Mac's host keeps
// (`FleetSnapshot.dispatches`), the thread's own `Agent.dispatchedFrom` and the fleet's Macs; no view parses or
// filters in its body. The Mac thread draws them, and iOS can.

/// What a button on a dispatch card does. The caller runs it; the card only says which buttons it has.
public enum FleetCardAction: Hashable, Sendable {
    /// Open the thread that runs the work.
    case open
    /// Stop the thread, and the dispatch.
    case stop
    /// Cancel a dispatch that hasn't started.
    case cancel
    /// Run it on this Mac instead.
    case runHere
    /// Run it on this Mac now, instead of waiting for room.
    case runHereNow
    /// Send it again, to the Mac asked for.
    case tryAgain
    /// Send it to this Mac instead (`FleetCard.alternative`): its id and name.
    case sendTo(UUID, String)
    /// Send a dispatch that was held after a restart.
    case send
    /// Open the parent's other dispatches, however many: the thread's own cards are what that shows.
    case openOthers(Int)

    public var title: String {
        switch self {
        case .open: "Open"
        case .stop: "Stop"
        case .cancel: "Cancel"
        case .runHere: "Run on This Mac"
        case .runHereNow: "Run on This Mac now"
        case .tryAgain: "Try again"
        case .sendTo(_, let name): "Send to \(name) instead"
        case .send: "Send it"
        case .openOthers(let count): "Open the other \(count)"
        }
    }
}

/// One dispatch as a card: in the thread that sent it, and on the Fleet page where it needs a decision.
public struct FleetDispatchCard: Identifiable, Equatable, Sendable {
    /// How it is drawn: a row of the thread's "Sent to other Macs" (a dispatch that is on a Mac), or a card that says
    /// what the dispatch waits for (FleetStates).
    public enum Layout: Equatable, Sendable {
        case row, state
    }

    public var id: UUID
    public var layout: Layout
    public var state: FleetDispatchState
    public var title: String
    /// The Mac it went to, as the tag names it; nil while none is chosen.
    public var host: String?
    /// "Working", "Done", "Waiting for room", "Held", "Starting", "Not sent".
    public var pill: String
    public var tone: FleetTone
    /// A row's line under the title, or a state card's words.
    public var detail: String
    /// While the work's snapshot is on its way (a `preparing` record with its sizes): the progress under the words, the "Sending with
    /// uncommitted changes" card of FleetStates.
    public var sending: FleetSendingCard?
    /// While the Mac that runs it clones the repository first: where that stands, the "Cloning" card of FleetStates.
    public var cloning: FleetCloningCard?
    public var actions: [FleetCardAction]
    /// The thread that sent it, and the thread that runs it, for the buttons.
    public var parentAgentID: AgentID?
    public var parentHostID: UUID
    public var targetHostID: UUID?
    public var remoteAgentID: AgentID?
    public var createdAt: Double

    public var accessibilityLabel: String {
        [title, host.map { "on \($0)" }, pill, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// What the cards are derived with: the fleet as the sending Mac's snapshot says it, and this Mac's settings.
public struct FleetCardContext: Sendable {
    public var snapshot: FleetSnapshot
    /// The most dispatches one thread may have going (`HostSettings.fleetThreadCap`).
    public var cap: Int
    public var locale: Locale
    public var calendar: Calendar
    /// How long this device has held `snapshot`, so a limit's countdown goes on between snapshots.
    public var snapshotAge: TimeInterval

    public init(snapshot: FleetSnapshot, cap: Int = HostSettings.fleetThreadCapDefault, locale: Locale = .current, calendar: Calendar = .current,
                snapshotAge: TimeInterval = 0) {
        self.snapshotAge = snapshotAge
        self.snapshot = snapshot
        self.cap = cap
        self.locale = locale
        self.calendar = calendar
    }
}

public enum FleetDispatchPresentation {
    // MARK: Cards

    /// A card for every record, newest first.
    public static func cards(_ records: [FleetDispatchRecord], in context: FleetCardContext) -> [FleetDispatchCard] {
        records.sorted { $0.createdAt > $1.createdAt }.map { card($0, among: records, in: context) }
    }

    /// The card of one record. `records` is every record the Mac holds, for what a card says of the others.
    public static func card(_ record: FleetDispatchRecord, among records: [FleetDispatchRecord], in context: FleetCardContext) -> FleetDispatchCard {
        let host = hostName(of: record)
        var card = FleetDispatchCard(
            id: record.id, layout: .state, state: record.state, title: record.title.isEmpty ? "Untitled" : record.title, host: host, pill: "", tone: .tertiary,
            detail: "", actions: [], parentAgentID: record.parentAgentID, parentHostID: record.parentHostID, targetHostID: record.targetHostID,
            remoteAgentID: record.remoteAgentID, createdAt: record.createdAt)
        switch record.state {
        case .placing:
            (card.pill, card.tone) = ("Placing", .tertiary)
            card.detail = "Choosing the Mac with the most room."
            card.actions = [.cancel]
        case .waitingRoom:
            if let limited = FleetPagePresentation.limitWords(record, limits: context.snapshot.limits, snapshotAge: context.snapshotAge) {
                // Held for the provider's limit, on every Mac alike: nothing has room to give it. It starts by itself when the limit lifts.
                (card.pill, card.tone) = ("Waiting for limit", .warn)
                card.detail = limited
            } else {
                (card.pill, card.tone) = ("Waiting for room", .tertiary)
                card.detail = busyWords(record, among: records, in: context)
            }
            card.actions = [.runHereNow, .cancel]
        case .waitingWake:
            (card.pill, card.tone) = ("Waiting", .tertiary)
            card.detail = asleepWords(record, in: context)
            var actions: [FleetCardAction] = []
            if let other = alternative(to: record, in: context) { actions.append(.sendTo(other.id, other.name)) }
            card.actions = actions + [.cancel]
        case .heldLimit:
            (card.pill, card.tone) = ("Held", .warn)
            let others = liveSiblings(of: record, among: records).count
            let who = record.parentTitle.isEmpty ? "This thread" : record.parentTitle
            card.detail = "\(who) already has \(others) \(others == 1 ? "thread" : "threads") running on other Macs. This one goes when one of them finishes."
            card.actions = others > 0 ? [.openOthers(others)] : []
        case .heldRestart:
            (card.pill, card.tone) = ("Held", .warn)
            card.detail = "Shepherd restarted before this was sent. Nothing is sent again by itself."
            card.actions = [.send, .cancel]
        case .preparing:
            (card.pill, card.tone) = ("Starting", .active)
            let repo = repoName(record.repoKey)
            let at = record.commitSHA.map { "\(repo) at \(short($0))" } ?? repo
            card.detail = "Sent \(at). \(host.map { the($0, capitalized: true) } ?? "The Mac") makes a new worktree and starts the thread. Nothing touches your checkout."
            if let sending = FleetSendingCard.make(record) {
                card.sending = sending
                card.detail = sending.summary
            }
            card.actions = [.cancel]
            // A Mac with no checkout clones it first: that is what the dispatch is doing, so that card replaces the sending one, and Stop
            // ends the clone and removes what it made.
            if let cloning = FleetCloningCard.make(record) {
                card.sending = nil
                card.cloning = cloning
                card.pill = cloning.state
                card.detail = cloning.summary
                card.actions = [.stop]
            }
        case .running:
            card.layout = .row
            (card.pill, card.tone) = ("Working", .active)
            card.detail = rowDetail(record)
            card.actions = [.open, .stop]
        case .delivering:
            card.layout = .row
            (card.pill, card.tone) = ("Delivering", .active)
            card.detail = rowDetail(record)
            card.actions = [.open]
        case .done:
            card.layout = .row
            (card.pill, card.tone) = ("Done", .good)
            card.detail = rowDetail(record)
            card.actions = [.open]
        case .cancelled:
            card.layout = .row
            (card.pill, card.tone) = ("Stopped", .tertiary)
            card.detail = rowDetail(record)
            card.actions = record.remoteAgentID == nil ? [] : [.open]
        case .failed:
            (card.pill, card.tone) = ("Not sent", .bad)
            card.detail = failureWords(record, in: context)
            card.actions = [.runHere, .tryAgain]
        }
        return card
    }

    /// The Mac a card's tag names: where it went, else the one named.
    static func hostName(of record: FleetDispatchRecord) -> String? {
        record.targetHostName ?? record.requestedHost.flatMap { FleetPlacement.isAuto($0) ? nil : $0 }
    }

    /// How a sentence names a Mac, as the boards write it: "the mini" for "Mac mini", the name as it is for any other ("iMac").
    /// `capitalized` opens a sentence.
    static func the(_ name: String, capitalized: Bool = false) -> String {
        guard name.hasPrefix("Mac "), name.count > 4 else { return name }
        return (capitalized ? "The " : "the ") + FleetWherePicker.shortName(name)
    }

    /// "payments-api" from "github.com/acme/payments-api".
    static func repoName(_ key: String) -> String {
        // A repository with no origin is named by its first commit: nothing a person would call it.
        if CanonicalRepoKey.isLocal(key) { return "this repository" }
        return key.split(separator: "/").last.map(String.init) ?? key
    }

    static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// The line under a placed dispatch's title: why it went there, what it started from, and where it works.
    /// "Auto: Mac mini had 3.4× the room · payments-api @ 4e1c9a2 · new worktree fleet/fix-flaky-payment".
    static func rowDetail(_ record: FleetDispatchRecord) -> String {
        var parts: [String] = []
        let why = whyWords(record)
        if !why.isEmpty { parts.append(why) }
        if let sha = record.commitSHA { parts.append("\(repoName(record.repoKey)) @ \(short(sha))") }
        else { parts.append(repoName(record.repoKey)) }
        if let branch = record.branch { parts.append("new worktree \(branch)") }
        if !record.without.isEmpty { parts.append("Started on \(hostName(of: record) ?? "that Mac") without: \(withoutWords(record.without))") }
        return parts.joined(separator: " · ")
    }

    /// The MCP servers a Mac lacked, by command: "bearcli (MCP)", "bearcli (MCP) and muse (MCP)".
    public static func withoutWords(_ commands: [String]) -> String { joined(commands.map { "\($0) (MCP)" }) }

    /// Why it went where it did, from the codes the sender's host recorded.
    static func whyWords(_ record: FleetDispatchRecord) -> String {
        let host = hostName(of: record) ?? "that Mac"
        let codes = record.reasonCodes
        let ratio = codes.compactMap(\.ratio).first
        if let skip = codes.first(where: { $0.code == .localIneligible })?.skip {
            let why = switch skip {
            case "cpu": "is busy"
            case "memory": "is low on memory"
            case "memoryPressure": "is under memory pressure"
            case "thermal": "is running hot"
            case "manualOnly": "is set to Manual only"
            default: "isn't counted"
            }
            return "Auto: This Mac \(why), so \(host)"
        }
        // What the Mac it went to was running when it was chosen, when it said.
        let running = codes.first?.commands.map { ", " + commandsWords($0) } ?? ""
        switch codes.first?.code {
        case .named?: return record.kind == .userThread ? "You picked \(host)" : "Picked \(host)"
        case .mostRoom?:
            guard let ratio, ratio > 1 else { return "Auto: \(host) had the most room\(running)" }
            return "Auto: \(host) had \(multiple(ratio)) the room\(running)"
        case .onlyChoice?: return "Auto: \(host) was the only Mac with room\(running)"
        case .keptLocal?: return "Auto: \(host) had enough room"
        default: return ""
        }
    }

    /// What a Mac was running: "no builds running", "1 running a build or test", "2 running builds or tests".
    public static func commandsWords(_ commands: Int) -> String {
        switch commands {
        case ...0: "no builds running"
        case 1: "1 running a build or test"
        default: "\(commands) running builds or tests"
        }
    }

    /// "3.4×".
    static func multiple(_ ratio: Double) -> String { String(format: "%.1f×", ratio) }

    // MARK: What a waiting dispatch says

    /// "This Mac is at 91% CPU and Mac mini has 6 agents working. It goes to the first Mac with room; it's first in line."
    static func busyWords(_ record: FleetDispatchRecord, among records: [FleetDispatchRecord], in context: FleetCardContext) -> String {
        let snapshot = context.snapshot
        let macs = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        var facts: [String] = []
        if let thisID = snapshot.hostID, let sample = macs[thisID]?.sample {
            facts.append("This Mac is at \(Int((sample.cpuUtilization * 100).rounded()))% CPU")
        }
        for peer in snapshot.peers where peer.link == .connected {
            if let sample = macs[peer.hostID]?.sample {
                facts.append("\(the(peer.name)) has \(sample.activeAgents) \(sample.activeAgents == 1 ? "agent" : "agents") working")
            }
        }
        let ahead = records.filter { $0.state == .waitingRoom && $0.createdAt < record.createdAt }.count
        let line = ahead == 0 ? "it's first in line" : "\(ahead) \(ahead == 1 ? "thread is" : "threads are") ahead of it"
        let lead = facts.isEmpty ? "Every Mac is busy." : joined(facts) + "."
        return "\(lead) It goes to the first Mac with room; \(line)."
    }

    /// "Mac Studio has been asleep since 10:42. The thread starts there when it wakes. It never moves on its own."
    static func asleepWords(_ record: FleetDispatchRecord, in context: FleetCardContext) -> String {
        let name = hostName(of: record) ?? "That Mac"
        let since = context.snapshot.peers.first { $0.hostID == record.targetHostID }?.lastSeen.map {
            Date(timeIntervalSince1970: $0 / 1000).formatted(Date.FormatStyle(locale: context.locale, calendar: context.calendar,
                                                                              timeZone: context.calendar.timeZone).hour().minute())
        }
        let asleep = since.map { "\(name) has been asleep since \($0)." } ?? "\(name) isn't answering."
        return "\(asleep) The thread starts there when it wakes. It never moves on its own."
    }

    /// The Mac "Send to … instead" would use: the connected one Auto likes best, else any connected one. Never the
    /// Mac the dispatch waits for.
    static func alternative(to record: FleetDispatchRecord, in context: FleetCardContext) -> (id: UUID, name: String)? {
        let snapshot = context.snapshot
        let macs = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        let connected = snapshot.peers.filter { $0.link == .connected && $0.hostID != record.targetHostID }
        func score(_ id: UUID) -> Double {
            guard let sample = macs[id]?.sample else { return -1 }
            return FleetRoom.score(sample)
        }
        guard let best = connected.max(by: { score($0.hostID) < score($1.hostID) }) else { return nil }
        return (best.hostID, best.name)
    }

    /// The parent's other dispatches that count against its limit.
    static func liveSiblings(of record: FleetDispatchRecord, among records: [FleetDispatchRecord]) -> [FleetDispatchRecord] {
        records.filter { $0.parentAgentID == record.parentAgentID && $0.id != record.id && $0.state.countsAgainstCap }
    }

    /// Why it wasn't sent, in a sentence, from the code.
    static func failureWords(_ record: FleetDispatchRecord, in context: FleetCardContext) -> String {
        let host = hostName(of: record).map { the($0, capitalized: true) } ?? "That Mac"
        let repo = repoName(record.repoKey)
        let sha = record.commitSHA.map(short)
        switch record.failure {
        case FleetDispatchCode.commitUnreachable:
            return "\(host) can't reach \(repo)'s origin" + (sha.map { ", and its commit \($0) was never pushed. Push the branch, or run it here." } ?? ". Push the branch, or run it here.")
        case FleetDispatchCode.repoMissing:
            // Both the clone and the bundle failed (or there was no way to send one): git's own words, so it can be fixed.
            return "\(host) doesn't have \(repo) and couldn't clone it" + (record.failureDetail.map { ": \($0)" } ?? "") + ". Run this here, or try again once it can."
        case FleetDispatchCode.cloneFailed:
            return "\(host) couldn't clone \(repo)" + (record.failureDetail.map { ": \($0)" } ?? "") + "."
        case FleetDispatchCode.repoAmbiguous:
            return "\(host) has \(repo) in more than one folder\(record.failureDetail.map { " (\($0))" } ?? ""), so it can't tell which to use."
        case FleetDispatchCode.hostNotReady:
            return "\(host) lacks something the thread needs" + (record.failureDetail.flatMap { $0 == "unknown" ? nil : " (\($0))" } ?? "") + "."
        case FleetDispatchCode.noSuchHost:
            return "No Mac named \(record.requestedHost ?? "that") is in the fleet."
        case FleetDispatchCode.peerGone:
            return "\(host) stopped answering and doesn't know this dispatch. Run it again, or run it here."
        case FleetDispatchCode.snapshotTooLarge:
            return "The changes to send are too large to send. Run it here, or commit and push them first."
        case FleetDispatchCode.snapshotMismatch, FleetDispatchCode.snapshotFailed:
            return "\(host) couldn't make a worktree that matches this checkout, so nothing started." + (record.failureDetail.map { " (\($0))" } ?? "")
        case FleetDispatchCode.refused:
            return "\(host) refused it" + (record.failureDetail.map { " (\($0))" } ?? "") + "."
        default:
            return "It wasn't sent" + (record.failureDetail.map { ": \($0)" } ?? ".")
        }
    }

    /// "a, b and c".
    static func joined(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    // MARK: A Mac behind the fleet

    /// A Mac that is linked and still taking in changes (FleetStates, "A Mac behind the fleet").
    public struct BehindMac: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var pill = "Out of date"
        public var detail: String
    }

    /// The Macs sync says are catching up, each with the card's words.
    public static func behind(_ snapshot: FleetSnapshot) -> [BehindMac] {
        (snapshot.sync?.peers ?? []).filter { $0.state == .catchingUp }.map {
            BehindMac(id: $0.hostID, name: $0.name,
                      detail: "Settings, instructions, skills and other changes are still reaching it. It updates before it takes any work, so nothing runs with old settings.")
        }
    }
}

// MARK: - The dispatched thread

/// What the dispatched thread draws of where it came from (FleetRemote): the header's host pill and "sent by" link, the
/// From box over the task, and the line saying where its last message goes. Derived from `Agent.dispatchedFrom`.
public struct FleetSentBy: Equatable, Sendable {
    /// The Mac running the thread, as the header's pill names it.
    public var host: String
    /// The thread that sent it; "you" for one the person started.
    public var sender: String
    /// The sender is a thread (the header offers its link, the banner says its last message goes back).
    public var fromThread: Bool
    /// "This Mac" or the Mac's own name: where the sender lives.
    public var senderHost: String
    /// Epoch milliseconds the dispatch was sent.
    public var at: Double
    /// The thread that sent it can be opened from here: it is on this Mac or on one this Mac is connected to.
    public var senderOpens = false

    /// "From Speed up checkout CI on This Mac".
    public var fromLine: String { "From \(sender) on \(senderHost)" }

    /// "sent by Speed up checkout CI".
    public var sentByLine: String { "sent by \(sender)" }

    /// "When this finishes, its last message goes back to Speed up checkout CI. You can still talk to it here."
    public var goesBackLine: String? {
        fromThread ? "When this finishes, its last message goes back to \(sender). You can still talk to it here." : nil
    }

    /// `viewer` is the fleet host id of the Mac whose app draws the thread; `host` is the Mac the thread runs on.
    public init(_ from: DispatchedFrom, host: String, viewer: UUID?) {
        self.host = host
        fromThread = from.agentID != nil
        sender = from.agentID == nil ? "you" : from.agentTitle.isEmpty ? "a thread" : from.agentTitle
        senderHost = from.hostID == viewer ? "This Mac" : from.hostName
        at = from.at
    }

    /// The task, without what the host added after it (`FleetDispatchProtocol.promptSeparator`): the From box draws the words
    /// that were sent, not the instructions about the branch.
    public static func task(in text: String) -> String {
        guard let cut = text.range(of: FleetDispatchProtocol.promptSeparator) else { return text }
        return String(text[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` is a message a dispatch started a thread with.
    public static func isDispatchMessage(_ text: String) -> Bool { text.contains(FleetDispatchProtocol.promptSeparator) }
}

/// "Mac mini stopped answering 2 minutes ago. Work there keeps running; this view catches up when it reconnects."
public struct FleetOfflineBanner: Equatable, Sendable {
    public var host: String
    /// Epoch milliseconds the Mac was last seen.
    public var lastSeen: Double

    public init(host: String, lastSeen: Double) {
        self.host = host
        self.lastSeen = lastSeen
    }

    public func message(now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince1970 - lastSeen / 1000)
        let age: String
        switch seconds {
        case ..<60: age = "a moment ago"
        case ..<3600: let minutes = Int(seconds / 60); age = minutes == 1 ? "1 minute ago" : "\(minutes) minutes ago"
        case ..<86_400: let hours = Int(seconds / 3600); age = hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        default: let days = Int(seconds / 86_400); age = days == 1 ? "1 day ago" : "\(days) days ago"
        }
        return "\(host) stopped answering \(age). Work there keeps running; this view catches up when it reconnects."
    }
}

// MARK: - The result

/// A dispatched thread's result as it reaches the thread that sent it (FleetDispatch's second card): the message the
/// host delivers (`FleetDispatch.resultMessage`), read back. The text is data from another agent, drawn, never acted on.
public struct FleetResultMessage: Equatable, Sendable {
    public var title: String
    public var host: String
    public var text: String
    /// The branch line the host adds: the branch, and whether origin has it.
    public var branch: String?
    public var pushed: Bool?

    /// Nil unless `text` is a result the host delivered: the header it frames agent messages with, then "Result from
    /// <title> on <Mac>:".
    public static func parse(_ text: String) -> FleetResultMessage? {
        guard text.hasPrefix("[from: "), let close = text.range(of: "] Result from ") else { return nil }
        var rest = text[close.upperBound...]
        guard let lineEnd = rest.firstIndex(of: "\n") else { return nil }
        let first = rest[..<lineEnd]
        guard first.hasSuffix(":"), let on = first.range(of: " on ", options: .backwards) else { return nil }
        let title = String(first[..<on.lowerBound])
        let host = String(first[on.upperBound...].dropLast())
        rest = rest[rest.index(after: lineEnd)...]
        var body = String(rest)
        var branch: String?, pushed: Bool?
        if let facts = body.range(of: "\n\nBranch ", options: .backwards) {
            let line = body[facts.upperBound...]
            if let colon = line.firstIndex(of: ":") {
                branch = String(line[..<colon])
                pushed = line.contains("pushed to origin")
                body = String(body[..<facts.lowerBound])
            }
        }
        return FleetResultMessage(title: title, host: host, text: body.trimmingCharacters(in: .whitespacesAndNewlines), branch: branch, pushed: pushed)
    }

    /// The dispatch this result belongs to, among the sending thread's records: its title, the Mac and a finished state.
    public func record(in records: [FleetDispatchRecord], parent: AgentID) -> FleetDispatchRecord? {
        records.filter {
            $0.parentAgentID == parent && $0.title == title && $0.targetHostName == host && [.delivering, .done].contains($0.state)
        }.max { $0.updatedAt < $1.updatedAt }
    }
}
