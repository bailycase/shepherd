import Foundation
import ShepherdCore
import ShepherdRemote

// The Macs tab of the Fleet page (FleetA, FleetMany, FleetMacAsleep) as plain values: a row per Mac in the list, and the detail of each in the board's
// words, derived once per change from `FleetPage` (never in a view's body). The words are the page's own, with the boards' punctuation: commas
// where the iPhone's say " · ".

/// A Mac in the list: its name, a line under it and the word at its end.
struct FleetListRow: Identifiable, Equatable {
    var id: UUID
    var name: String
    var subtitle: String
    /// "Little room", "Needs 4", "No Xcode", "Asleep".
    var word: String
    /// The word is the one thing that needs doing here: it draws in the attention color.
    var attention: Bool
    /// A Mac that isn't answering is drawn quieter.
    var dim: Bool
}

/// A titled run of rows ("Need a fix 2"); untitled for a small fleet, which lists its Macs as they come.
struct FleetMacGroup: Identifiable, Equatable {
    var title: String?
    var rows: [FleetListRow]
    var id: String { title ?? "" }
}

/// The detail of one Mac.
struct FleetMacDetail: Identifiable, Equatable {
    var id: UUID
    var name: String
    var hardware: String
    var room: String
    var roomFraction: Double
    var cpu: FleetMacMeter?
    var memory: FleetMacMeter?
    var power: String
    var ready: String
    /// Ready names what the fleet needs of this Mac: it draws in the attention color.
    var needsAttention: Bool
    var agents: String
    var link: String?
    var note: String?
    var weight: FleetSendWeight
    var weightLabel: String
    var repos: String
    var canRetry: Bool
    var behind: Bool
    var checkable: Bool
}

struct FleetMacMeter: Equatable {
    var fraction: Double
    var text: String
}

/// The provider limit strip: the first sentence in ink, the rest in the quiet color, and how many wait.
struct FleetLimitLine: Identifiable, Equatable {
    var id: String
    var lead: String
    var rest: String
    var waiting: String?
}

struct FleetMacsLayout: Equatable {
    var groups: [FleetMacGroup] = []
    var details: [FleetMacDetail] = []
    var limits: [FleetLimitLine] = []
    /// "3 Macs, 1 asleep, 6 threads working" and the Check tab's summary, in the boards' punctuation.
    var summary = ""
    var checkSummary = ""

    /// The detail of `id`, else of the first Mac.
    func detail(_ id: UUID?) -> FleetMacDetail? { details.first { $0.id == id } ?? details.first }

    static func make(_ page: FleetPage) -> FleetMacsLayout {
        let rows = page.cards.map(row)
        let folded = page.cards.count > FleetCorner.listsEveryMacUpTo
        let groups: [FleetMacGroup]
        if folded {
            let fix = rows.indices.filter { page.cards[$0].status != .asleep && (page.cards[$0].needs > 0 || page.cards[$0].cannotTake != nil) }
            let asleep = rows.indices.filter { page.cards[$0].status == .asleep }
            let taking = rows.indices.filter { !fix.contains($0) && !asleep.contains($0) }
            groups = [("Need a fix", fix), ("Taking work", taking), ("Asleep", asleep)]
                .filter { !$0.1.isEmpty }.map { FleetMacGroup(title: $0.0, rows: $0.1.map { rows[$0] }) }
        } else {
            groups = rows.isEmpty ? [] : [FleetMacGroup(title: nil, rows: rows)]
        }
        return FleetMacsLayout(
            groups: groups, details: page.cards.map(detail), limits: page.limits.map(limit),
            summary: words(page.summary), checkSummary: words(page.check.summary))
    }

    /// " · " reads as ", " in the Mac boards.
    static func words(_ text: String) -> String { text.replacingOccurrences(of: " · ", with: ", ") }

    static func row(_ card: FleetMacCard) -> FleetListRow {
        let asleep = card.status == .asleep
        let needs = card.needs > 0 && !asleep
        let word: String
        if let blocked = card.cannotTake, !asleep { word = blocked.prefix(1).uppercased() + blocked.dropFirst() }
        else if needs { word = "Needs \(card.needs)" }
        else if asleep { word = "Asleep" }
        else if card.status == .connecting { word = "Connecting" }
        else { word = card.rowRoom }
        let attention = !asleep && (card.cannotTake != nil || needs)
        var parts: [String] = []
        if asleep {
            parts.append(card.since.map { "Since \($0)" } ?? "Not reached yet")
        } else if card.status == .connecting {
            parts.append("Linking now")
        } else {
            if let working = card.working { parts.append(working == 0 ? "None working" : "\(working) working") }
            if attention, card.room.text != "Not counted" { parts.append(card.room.text.lowercased()) }
            else if card.powerFact.contains("battery") { parts.append("on battery") }
        }
        if card.waiting > 0 { parts.append("\(card.waiting) waiting") }
        return FleetListRow(id: card.id, name: card.name, subtitle: parts.joined(separator: ", "), word: word, attention: attention, dim: asleep)
    }

    static func detail(_ card: FleetMacCard) -> FleetMacDetail {
        let asleep = card.status == .asleep
        let needs = card.needs > 0 && !asleep
        // "Needs 4 · node 22, muse CLI" is "Needs 4: node 22, muse CLI".
        var ready = card.ready.text
        if needs, let range = ready.range(of: " · ") { ready.replaceSubrange(range, with: ": ") }
        return FleetMacDetail(
            id: card.id, name: card.name, hardware: words(card.hardware), room: card.room.text, roomFraction: card.room.fraction,
            cpu: card.cpu.map { FleetMacMeter(fraction: $0.fraction, text: $0.text) },
            memory: card.memory.map { FleetMacMeter(fraction: $0.fraction, text: $0.text) },
            power: words(card.power.text), ready: words(ready), needsAttention: needs || card.ready.tone == .warn && !asleep,
            agents: words(card.agents), link: card.reach.map(words), note: card.note, weight: card.weight, weightLabel: card.weightLabel,
            repos: (card.repos + card.cloning.map { "\($0) (cloning)" }).joined(separator: ", "), canRetry: card.canRetry,
            behind: card.behindBuild != nil, checkable: card.needs > (card.behindBuild != nil ? 1 : 0))
    }

    static func limit(_ strip: FleetLimitStrip) -> FleetLimitLine {
        let text = strip.text
        let split = text.range(of: ". ")
        return FleetLimitLine(id: strip.id, lead: split.map { String(text[..<$0.lowerBound]) + "." } ?? text,
                              rest: split.map { String(text[$0.upperBound...]) } ?? "", waiting: strip.waiting)
    }
}
