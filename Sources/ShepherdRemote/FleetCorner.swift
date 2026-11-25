import Foundation
import ShepherdCore

// The sidebar's Fleet corner (FleetCornerFull, FleetCornerMin, FleetCornerMany, FleetCornerManyMin): a header, one row per Mac that
// matters now, and a minimized line. Plain values derived from `FleetPage`, so the Mac draws them and a test reads them.

public struct FleetCorner: Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        /// Green: awake and answering.
        case awake
        /// Hollow: asleep, or not answering.
        case asleep
        /// Red: can't take work.
        case blocked
        /// Blue: linking now.
        case connecting
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public var id: UUID
        /// "This Mac", "mini", "build-04".
        public var name: String
        public var dot: Dot
        /// How loaded the Mac is, 0...1: the gauge. Empty for a Mac that isn't taking work.
        public var load: Double
        /// `.warn` while the Mac is busy, `.active` while it has room; `.tertiary` draws only the track.
        public var gauge: FleetTone
        /// "3 running", "Room", "Next", "1 waiting", "Asleep", or why it can't take work ("No Xcode").
        public var state: String
        public var thisMac: Bool

        public var accessibilityLabel: String { "\(name), \(state)" }
    }

    /// The row that folds the Macs that don't matter now: "8 more, 2 asleep". It opens the Fleet page.
    public struct More: Equatable, Sendable {
        public var count: Int
        public var asleep: Int
        public var text: String
    }

    /// "3 Macs", beside "Fleet" in the open corner.
    public var headline: String
    /// The minimized line: "2 of 3 Macs awake", "3 Macs awake", "12 Macs, 7 with room".
    public var summary: String
    public var rows: [Row]
    public var more: More?
    /// A Mac can't take work: the minimized corner keeps a red dot.
    public var alert: Bool
    /// More Macs than the corner lists one by one.
    public var folded: Bool

    public var accessibilityLabel: String { "Fleet, \(headline)" }

    /// A fleet of more Macs than this lists only the ones that matter.
    public static let listsEveryMacUpTo = 5
    /// At most this many rows, `More` aside.
    public static let rowLimit = 5

    /// Nil while Fleet shows no Mac.
    public static func make(_ page: FleetPage) -> FleetCorner? {
        let cards = page.cards
        guard !cards.isEmpty else { return nil }
        let folded = cards.count > listsEveryMacUpTo
        let matter = folded ? Self.mattering(cards, next: page.nextGoesToID) : cards
        let shown = Array(matter.prefix(rowLimit))
        let rows = shown.map { row($0, next: folded && $0.id == page.nextGoesToID) }
        let hidden = cards.filter { card in !shown.contains { $0.id == card.id } }
        let asleep = cards.filter { $0.status == .asleep }.count
                let headline = cards.count == 1 ? "just this Mac" : "\(cards.count) Macs"
        let more = hidden.isEmpty ? nil : More(
            count: hidden.count, asleep: hidden.filter { $0.status == .asleep }.count,
            text: ["\(hidden.count) more", hidden.contains { $0.status == .asleep } ? "\(hidden.filter { $0.status == .asleep }.count) asleep" : nil]
                .compactMap { $0 }.joined(separator: ", "))
        return FleetCorner(headline: headline, summary: summary(cards), rows: rows, more: more,
                           alert: cards.contains { $0.cannotTake != nil }, folded: folded)
    }

    /// The Macs that matter now, in the order the corner draws them: This Mac, Auto's next pick, the Macs with work waiting for them, and the
    /// Macs that can't take work.
    public static func mattering(_ cards: [FleetMacCard], next: UUID?) -> [FleetMacCard] {
        var picked: [FleetMacCard] = []
        func add(_ matching: (FleetMacCard) -> Bool) {
            for card in cards where matching(card) && !picked.contains(where: { $0.id == card.id }) { picked.append(card) }
        }
        add { $0.isThisMac }
        add { $0.id == next }
        add { $0.waiting > 0 }
        add { $0.cannotTake != nil }
        return picked
    }

    /// "2 of 3 Macs awake", "3 Macs awake", "12 Macs, 7 with room", "Just this Mac".
    static func summary(_ cards: [FleetMacCard]) -> String {
        guard cards.count > 1 else { return "Just this Mac" }
        if cards.count > listsEveryMacUpTo { return "\(cards.count) Macs, \(cards.filter(\.hasRoom).count) with room" }
        let awake = cards.filter { $0.status != .asleep }.count
        return awake == cards.count ? "\(cards.count) Macs awake" : "\(awake) of \(cards.count) Macs awake"
    }

    static func row(_ card: FleetMacCard, next: Bool) -> Row {
        let name = card.isThisMac ? "This Mac" : FleetWherePicker.tagName(card.name)
        let dot: Dot = card.status == .asleep ? .asleep : card.cannotTake != nil ? .blocked : card.status == .connecting ? .connecting : .awake
        let idle = card.status == .asleep || card.cannotTake != nil
        var gauge: FleetTone = .tertiary
        if !idle { gauge = card.hasRoom ? .active : .warn }
        return Row(id: card.id, name: name, dot: dot, load: idle ? 0 : card.cpu?.fraction ?? 0, gauge: gauge,
                   state: state(card, next: next), thisMac: card.isThisMac)
    }

    /// Why the Mac is drawn as it is, the first of: it can't take work, work waits for it, it sleeps, Auto goes there next, how many threads run on it.
    static func state(_ card: FleetMacCard, next: Bool) -> String {
        if let reason = card.cannotTake { return reason.prefix(1).uppercased() + reason.dropFirst() }
        if card.waiting > 0 { return "\(card.waiting) waiting" }
        if card.status == .asleep { return "Asleep" }
        if next { return "Next" }
        if card.status == .connecting { return "Connecting" }
        guard card.cpu != nil else { return "No reading" }
        if card.room.text == FleetMacCard.notCounted { return "Not counted" }
        if let working = card.working, working > 0 { return "\(working) running" }
        return card.hasRoom ? "Room" : "Busy"
    }
}

extension FleetMacCard {
    static let notCounted = "Not counted"
    private static let roomWords: Set<String> = ["Most room", "Room to spare", "Some room"]

    /// The Mac is answering, can take work and has room for it: Auto would send work there.
    public var hasRoom: Bool { status != .asleep && cannotTake == nil && Self.roomWords.contains(room.text) }
}
