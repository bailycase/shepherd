import Foundation
import ShepherdCore
import ShepherdProtocol

// Moving a thread to another Mac (FleetMove board): the menu the host chip opens, and the card a move draws while it goes. Plain values
// from the host's fleet snapshot, so the Mac app and the phone draw the same facts and a test reads them without a view.

/// "Runs on / Move to": every Mac of the fleet the thread could go to, with its room and a note, and the line under them.
public struct FleetMoveMenu: Equatable, Sendable {
    public struct Here: Equatable, Sendable {
        public var name: String
        /// "72% CPU · on battery".
        public var detail: String
        public var tone: FleetTone
    }

    public struct Target: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        /// "Most room · has acme-web · 2 working", "Asleep since 10:42", "Needs a newer Shepherd".
        public var note: String
        /// The dot: the Mac's room, or tertiary while it can't take the thread.
        public var tone: FleetTone
        /// 0...1: the room bar.
        public var room: Double
        public var enabled: Bool

        public var accessibilityLabel: String { "Move to \(name), \(note)" }
    }

    public var here: Here
    public var targets: [Target]

    /// What a move does to what is open on the Mac it leaves.
    public static let footnote = "The conversation, its branch and every uncommitted change go with it. Its terminals and browser tabs stay here and close."

    /// The Macs a thread running on `currentHostID` can move to; nil when the fleet has no other Mac. `repoKey` is the thread's repository
    /// (`Space.repoKey`): a Mac is told to have it, to clone it, or, with none, that no other Mac can find it. This Mac's own name reads "This Mac".
    public static func make(snapshot: FleetSnapshot, currentHostID: UUID, repoKey: String?, repoName: String, weight: (UUID) -> FleetSendWeight,
                            batteryCountsHalf: Bool = true, snapshotAge: TimeInterval = 0, locale: Locale = .current,
                            calendar: Calendar = .current, now: Date = Date()) -> FleetMoveMenu? {
        guard snapshot.enabled, snapshot.hostID != nil, !snapshot.peers.isEmpty else { return nil }
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: weight, snapshotAge: snapshotAge, batteryCountsHalf: batteryCountsHalf,
                                              locale: locale, calendar: calendar, now: now)
        let states = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        let peers = Dictionary(snapshot.peers.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let current = page.cards.first(where: { $0.id == currentHostID }) else { return nil }

        // The power as the board says it ("on battery", "plugged in"), without the percentage and the warmth the Fleet page adds.
        let power = current.powerFact.hasPrefix("battery") ? "on battery" : current.powerFact.hasPrefix("plugged") ? "plugged in" : nil
        var detail = [current.cpu.map { "\($0.text) CPU" }, power].compactMap { $0 }.joined(separator: " · ")
        if current.status == .asleep { detail = current.since.map { "Asleep since \($0)" } ?? "Not answering" }
        let here = Here(name: current.isThisMac ? "This Mac" : current.name, detail: detail,
                        tone: current.status == .asleep ? .tertiary : current.room.tone)

        var targets: [Target] = []
        for card in page.cards where card.id != currentHostID {
            let asleep = card.status == .asleep
            let name = card.isThisMac ? "This Mac" : card.name
            let readiness = states[card.id]?.readiness
            let hasRepo: Bool? = card.isThisMac ? true : repoKey.flatMap { key in readiness.map { $0.repoKeys.contains(key) } }
            var note: String
            var enabled = true
            if asleep {
                note = card.since.map { "Asleep since \($0)" } ?? "Not answering"
                enabled = false
            } else if peers[card.id]?.takesThreads == false {
                note = "Needs a newer Shepherd"
                enabled = false
            } else if let lacking = readiness?.lacks.first(where: { $0 == .git }) {
                note = "Not ready · \(lacking.name) isn't installed"
                enabled = false
            } else if repoKey == nil {
                note = "\(repoName) isn't a repository another Mac can find"
                enabled = false
            } else if hasRepo == nil {
                note = "Waiting for a reading"
                enabled = false
            } else {
                var parts = [card.room.text]
                parts.append(hasRepo == true ? "has \(repoName)" : "will clone \(repoName)")
                if let working = card.working, working > 0 { parts.append("\(working) working") }
                note = parts.joined(separator: " · ")
            }
            targets.append(Target(id: card.id, name: name, note: note, tone: enabled ? card.room.tone : .tertiary,
                                  room: enabled ? card.room.fraction : 0, enabled: enabled))
        }
        // Awake Macs with the most room first, asleep and unable ones after; ties keep the page's order.
        targets = targets.enumerated().sorted { a, b in
            if a.element.enabled != b.element.enabled { return a.element.enabled }
            if a.element.room != b.element.room { return a.element.room > b.element.room }
            return a.offset < b.offset
        }.map(\.element)
        return targets.isEmpty ? nil : FleetMoveMenu(here: here, targets: targets)
    }
}

/// The card a move draws in the thread that moves, from the move's record: its four steps, or the line it waits with, or why it stopped.
public struct FleetMoveCard: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// "Move when it's done": the turn runs, and the move begins when it ends.
        case queued
        case moving
        case failed
    }

    public enum Mark: Equatable, Sendable {
        case done, current, later
    }

    public struct Step: Equatable, Sendable {
        public var mark: Mark
        public var text: String
        public var meta: String
    }

    public var id: UUID
    public var phase: Phase
    public var host: String
    /// "Moving to Mac mini", "Moves to Mac mini when this turn ends.", "Couldn't move to Mac mini".
    public var title: String
    public var steps: [Step]
    /// Why a failed move stopped.
    public var detail: String?
    public var canCancel: Bool

    /// The card of `record`; nil for a record that is not a live or failed move (a finished one is the divider in the conversation).
    public static func make(_ record: FleetDispatchRecord) -> FleetMoveCard? {
        guard record.kind == .move, let info = record.move else { return nil }
        let host = record.targetHostName ?? "another Mac"
        switch record.state {
        case .waitingTurn:
            return FleetMoveCard(id: record.id, phase: .queued, host: host, title: "Moves to \(host) when this turn ends.", steps: [], detail: nil, canCancel: true)
        case .failed:
            return FleetMoveCard(id: record.id, phase: .failed, host: host, title: "Couldn’t move to \(host)", steps: [], detail: failureText(record, host: host), canCancel: false)
        case .cancelled, .done:
            return nil
        default:
            break
        }
        let at = info.stage.order
        func mark(_ stage: FleetMoveStage) -> Mark { stage.order < at ? .done : stage.order == at ? .current : .later }
        // The conversation and worktree steps keep their stage until the next begins; `staged` and `starting` are the last step.
        let starting: Mark = at >= FleetMoveStage.staged.order ? .current : .later
        var conversation = ""
        if let messages = info.messages {
            conversation = nativeCount(messages, "message") + (info.transcriptBytes.map { " · " + byteText($0) } ?? "")
        }
        var worktree = [fileText(info.uncommittedFiles, "uncommitted file"), fileText(info.unpushedCommits, "unpushed commit")].compactMap { $0 }.joined(separator: ", ")
        if let total = record.snapshotBytes {
            worktree += (worktree.isEmpty ? "" : " · ") + byteText(total)
        }
        let steps = [
            Step(mark: mark(.stopping) == .current ? .current : .done, text: mark(.stopping) == .current ? "Stopping the turn" : "Stopped the turn", meta: ""),
            Step(mark: mark(.conversation), text: mark(.conversation) == .done ? "Sent the conversation" : "Sending the conversation",
                 meta: mark(.conversation) == .later ? "" : conversation),
            Step(mark: mark(.worktree), text: mark(.worktree) == .done ? "Sent the worktree" : "Sending the worktree", meta: mark(.worktree) == .later ? "" : worktree),
            Step(mark: starting, text: "Starting on \(host)", meta: ""),
        ]
        return FleetMoveCard(id: record.id, phase: .moving, host: host, title: "Moving to \(host)", steps: steps, detail: nil, canCancel: false)
    }

    /// What a move that failed says.
    static func failureText(_ record: FleetDispatchRecord, host: String) -> String {
        switch record.failure {
        case FleetDispatchCode.restarted: "Shepherd restarted before the thread was handed over. It is still here, as it was."
        case FleetDispatchCode.peerGone: "\(host) stopped answering. The thread is still here, as it was."
        case FleetDispatchCode.hostNotReady: "\(host) isn't ready\(record.failureDetail.map { ": \($0)" } ?? "")."
        case FleetDispatchCode.snapshotTooLarge: "The worktree is too large to send. The thread is still here."
        case FleetDispatchCode.cloneFailed: "\(host) couldn’t clone the repository. The thread is still here."
        case FleetDispatchCode.refused, FleetDispatchCode.moveRefused: record.failureDetail ?? "\(host) refused the move. The thread is still here."
        default: "The move didn’t finish. The thread is still here, as it was."
        }
    }

    private static func fileText(_ count: Int?, _ noun: String) -> String? {
        guard let count, count > 0 else { return nil }
        return nativeCount(count, noun)
    }

    private static func byteText(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The header's chip: where the thread runs, and where it came from after a move.
public struct FleetMoveChip: Equatable, Sendable {
    public var text: String
    public var tone: FleetTone
    /// "moved from This Mac · 14:02", after a move; nil for a thread that never moved.
    public var movedFrom: String?

    public var accessibilityLabel: String { "Runs on \(text). Move to another Mac" }

    public static func make(host: String, tone: FleetTone, movedFrom: MovedFrom?, thisFleetID: UUID?,
                            locale: Locale = .current, calendar: Calendar = .current) -> FleetMoveChip {
        var line: String?
        if let movedFrom, movedFrom.at > 0 {
            var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
            style.calendar = calendar
            style.timeZone = calendar.timeZone
            let name = movedFrom.hostID == thisFleetID ? "This Mac" : movedFrom.hostName
            line = "moved from \(name) · \(Date(timeIntervalSince1970: movedFrom.at / 1000).formatted(style))"
        }
        return FleetMoveChip(text: host, tone: tone, movedFrom: line)
    }
}

/// What the thread says when it is moved while a turn runs ("It's running a command"): what runs and for how long, and that moving stops it.
public struct FleetMoveConfirm: Equatable, Sendable {
    public var title: String
    public var message: String

    /// `call` is the tool call running now, when the thread is in one; nil while the model is writing.
    public static func make(running call: NativeActivityCall?, host: String, now: Date = Date()) -> FleetMoveConfirm {
        guard let call, call.running else {
            return FleetMoveConfirm(title: "It’s working",
                                    message: "Moving now stops the turn. The thread picks up on \(host) and carries on from the conversation.")
        }
        let what = call.detail.isEmpty ? call.label : call.detail
        let since = call.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        var duration = ""
        if let since {
            let seconds = max(0, Int(now.timeIntervalSince(since).rounded()))
            duration = seconds < 60 ? " for \(nativeCount(max(1, seconds), "second"))" : " for \(nativeCount(seconds / 60, "minute"))"
        }
        return FleetMoveConfirm(title: "It’s running a command",
                                message: "\(what) has been running\(duration). Moving now stops it; the thread picks up on \(host) and can run it again there.")
    }

    /// The call a thread's last turn is running now, if any.
    public static func runningCall(in items: [NativeTurnPresentation.Item]) -> NativeActivityCall? {
        for item in items.reversed() {
            if case .activity(_, let bursts) = item, let call = bursts.reversed().lazy.compactMap({ $0.calls.last { $0.running } }).first { return call }
        }
        return nil
    }
}
