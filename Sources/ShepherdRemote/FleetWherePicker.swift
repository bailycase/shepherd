import Foundation
import ShepherdCore
import ShepherdProtocol

// New thread's "Where it runs" (FleetNewThread): the chip that says which Mac the thread starts on, and the popover that
// ranks every Mac by room and says which have the repository. The winner is the same pure function the host places a
// dispatch with (`FleetPlacement`), over the same numbers, so the chip is what Send will do unless a sample changes
// first; the local host confirms at send, which owns placement.

/// What the person picked in the popover.
public enum FleetPlacePick: Hashable, Sendable {
    /// The Mac with the most room when Send is pressed.
    case auto
    /// A Mac by its fleet host id (this Mac's own included).
    case mac(UUID)
}

public struct FleetPlaceOption: Identifiable, Equatable, Sendable {
    public var id: String
    public var pick: FleetPlacePick
    public var name: String
    /// "18% CPU · 41 GB free · plugged in", "Asleep since 10:42 · the thread would wait".
    public var detail: String
    /// 0...1: the room gauge.
    public var room: Double
    /// "most", "some", "little", "full", "asleep", "mini" for Auto's pick.
    public var roomWord: String
    public var tone: FleetTone
    public var chosen: Bool
    public var selectable: Bool

    public var accessibilityLabel: String { "\(name), \(roomWord), \(detail)" }
}

public struct FleetWherePicker: Equatable, Sendable {
    public var options: [FleetPlaceOption]
    /// The chip's words: "Auto · Mac mini", "Mac mini", "This Mac".
    public var chip: String
    /// The Mac Auto would pick now; nil while none has room.
    public var winner: String?
    /// The host id of the chosen Mac; nil for This Mac and while Auto has no winner.
    public var target: UUID?
    /// The chosen place starts the thread somewhere else (a dispatch). False for This Mac.
    public var dispatches: Bool
    /// The line under the card.
    public var note: String?
    /// The popover's last line: which Macs have the repository.
    public var footnote: String?

    public static let empty = FleetWherePicker(options: [], chip: "This Mac", winner: nil, target: nil, dispatches: false, note: nil, footnote: nil)

    /// Derives the picker. `repoKey` is the chosen space's repository (`Space.repoKey`; nil for a folder with no origin, which no
    /// other Mac can find), `repoName` how to say it. `autoDispatch` is the setting; with it off the chip starts on This
    /// Mac, and Auto is still there to pick.
    public static func make(snapshot: FleetSnapshot, pick: FleetPlacePick?, repoKey: String?, repoName: String,
                            autoDispatch: Bool, weight: (UUID) -> FleetSendWeight, batteryCountsHalf: Bool = true, snapshotAge: TimeInterval = 0,
                            baseBranch: String? = nil, locale: Locale = .current, calendar: Calendar = .current, now: Date = Date()) -> FleetWherePicker {
        guard snapshot.enabled, let thisID = snapshot.hostID, !snapshot.peers.isEmpty else { return .empty }
        let page = FleetPagePresentation.make(snapshot: snapshot, weight: weight, snapshotAge: snapshotAge, batteryCountsHalf: batteryCountsHalf,
                                              locale: locale, calendar: calendar, now: now)
        let cards = Dictionary(page.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let states = Dictionary(snapshot.macs.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })

        // The same inputs the host places with.
        var macs = [FleetPlacement.Mac(hostID: thisID, name: "This Mac", isLocal: true, connected: true, hasRepo: true,
                                       problems: states[thisID]?.readiness?.missing.map(missingName) ?? [],
                                       sample: states[thisID]?.sample, sampleAge: states[thisID]?.sampleAge.map { $0 + snapshotAge },
                                       weight: weight(thisID))]
        for peer in snapshot.peers {
            let state = states[peer.hostID]
            macs.append(FleetPlacement.Mac(
                hostID: peer.hostID, name: peer.name, connected: peer.link == .connected,
                hasRepo: repoKey.flatMap { key in state?.readiness.map { $0.repoKeys.contains(key) } },
                problems: state?.readiness?.missing.map(missingName) ?? [], sample: state?.sample,
                sampleAge: state?.sampleAge.map { $0 + snapshotAge }, weight: weight(peer.hostID)))
        }
        var winnerID: UUID?
        if repoKey != nil, case .place(let target, _) = FleetPlacement.place(host: nil, macs: macs, batteryCountsHalf: batteryCountsHalf) {
            winnerID = target
        }
        let winnerName = winnerID.map { id in macs.first { $0.hostID == id }?.name ?? "" }
        let effective: FleetPlacePick = pick ?? (autoDispatch && repoKey != nil ? .auto : .mac(thisID))

        func detail(_ id: UUID, asleep: Bool, hasRepo: Bool?, name: String) -> String {
            guard let card = cards[id] else { return "" }
            if hasRepo == false { return "Doesn't have \(repoName)" }
            if asleep { return card.since.map { "Asleep since \($0) · the thread would wait" } ?? "Not answering · the thread would wait" }
            guard let cpu = card.cpu else { return "Waiting for a reading" }
            let power = card.powerFact.isEmpty ? nil : card.powerFact.replacingOccurrences(of: "battery", with: "on battery")
            return ["\(cpu.text) CPU", card.memory?.text, power].compactMap { $0 }.joined(separator: " · ")
        }
        func word(_ card: FleetMacCard) -> String {
            if card.status == .asleep { return "asleep" }
            switch card.room.text {
            case "Most room": return "most"
            case "Some room", "Room to spare": return "some"
            case "Little room": return "little"
            case "No room": return "full"
            default: return "—"
            }
        }

        var options: [FleetPlaceOption] = []
        let auto = winnerID.flatMap { cards[$0] }
        options.append(FleetPlaceOption(
            id: "auto", pick: .auto, name: "Auto",
            detail: winnerName.map { "The Mac with the most room when you send. Now: \($0)" } ?? "The Mac with the most room when you send. None has room now",
            room: auto?.room.fraction ?? 0, roomWord: winnerName.map { Self.shortName($0) } ?? "—", tone: auto?.room.tone ?? .tertiary,
            chosen: effective == .auto, selectable: repoKey != nil))
        // The Macs ranked by room, as the board draws them: awake ones first, the most room on top; ties keep the page's order.
        let ranked = page.cards.enumerated().sorted { a, b in
            let (left, right) = (a.element, b.element)
            if (left.status == .asleep) != (right.status == .asleep) { return right.status == .asleep }
            if left.room.fraction != right.room.fraction { return left.room.fraction > right.room.fraction }
            return a.offset < b.offset
        }.map(\.element)
        for card in ranked {
            let state = macs.first { $0.hostID == card.id }
            let asleep = card.status == .asleep
            let hasRepo = card.isThisMac ? true : state?.hasRepo
            options.append(FleetPlaceOption(
                id: card.id.uuidString, pick: .mac(card.id), name: card.name, detail: detail(card.id, asleep: asleep, hasRepo: hasRepo, name: card.name),
                room: asleep ? 0 : card.room.fraction, roomWord: word(card), tone: asleep || card.room.tone == .tertiary ? .tertiary : card.room.tone,
                chosen: effective == .mac(card.id), selectable: card.isThisMac || (hasRepo != false && repoKey != nil)))
        }

        // The footnote names Macs in the page's order (This Mac first), not the popover's ranking.
        let pageOrder = Dictionary(page.cards.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        func pageIndex(_ option: FleetPlaceOption) -> Int { if case .mac(let id) = option.pick { pageOrder[id] ?? 0 } else { 0 } }
        let inPageOrder = options.dropFirst().sorted { pageIndex($0) < pageIndex($1) }
        let with = inPageOrder.filter { option in
            if case .mac(let id) = option.pick { return id == thisID || macs.first { $0.hostID == id }?.hasRepo == true }
            return false
        }.map(\.name)
        let without = inPageOrder.filter { option in
            if case .mac(let id) = option.pick, id != thisID { return macs.first { $0.hostID == id }?.hasRepo == false }
            return false
        }.map(\.name)
        var footnote: String?
        if repoKey == nil {
            footnote = "\(repoName) has no origin remote, so no other Mac can find it."
        } else if !with.isEmpty {
            footnote = "\(repoName) is checked out on \(FleetDispatchPresentation.joined(with))."
            if !without.isEmpty { footnote! += " \(FleetDispatchPresentation.joined(without)) \(without.count == 1 ? "doesn't" : "don't") have it." }
        }

        // The chosen place.
        var chip = "This Mac"
        var target: UUID?
        var note: String?
        var dispatches = false
        let base = baseBranch.map { "from \($0)" } ?? "from its base branch"
        switch effective {
        case .auto:
            if let winnerID, let winnerName {
                chip = "Auto · \(winnerName)"
                target = winnerID == thisID ? nil : winnerID
                dispatches = winnerID != thisID
                note = winnerID == thisID ? nil : "Runs on \(winnerName) in a new worktree \(base). It shows in your sidebar like any thread."
            } else {
                chip = "Auto"
                note = "No Mac has room right now. The thread starts on This Mac."
            }
        case .mac(let id):
            let name = macs.first { $0.hostID == id }?.name ?? "This Mac"
            chip = name
            if id != thisID {
                target = id
                dispatches = true
                let asleep = cards[id]?.status == .asleep
                note = asleep ? "\(name) is asleep. The thread starts when it wakes; it never moves to another Mac."
                    : "Runs on \(name) in a new worktree \(base)."
            }
        }
        return FleetWherePicker(options: options, chip: chip, winner: winnerName, target: target, dispatches: dispatches, note: note, footnote: footnote)
    }

    /// A Mac's name on a tag: "mini" for "Mac mini", any other name as it is.
    public static func tagName(_ name: String) -> String { name.hasPrefix("Mac ") && name.count > 4 ? shortName(name) : name }

    /// "Mac mini" as the room column names it: "mini".
    public static func shortName(_ name: String) -> String {
        let words = name.split(separator: " ")
        if words.count > 1, words[0] == "Mac" { return words.dropFirst().joined(separator: " ").lowercased() }
        return name.lowercased()
    }

    static func missingName(_ tool: FleetMissingTool) -> String {
        switch tool.kind {
        case .binary: tool.name
        case .git: "git"
        case .xcode: "Xcode"
        }
    }
}
