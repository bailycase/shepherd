import Foundation
import ShepherdCore

// Deleting a design and naming the designs Shepherd makes from others (a duplicate, a project
// imported again). docs/designs.md › Deleting and importing.

/// A design the host deleted and still holds: out of the workspace (its record, its agents and
/// their layouts), its agents stopped, its files set aside until `undoUntil`. Undo before then
/// puts it all back where it was; after, the files and agents are gone.
public struct DesignDeletion: Codable, Hashable, Sendable {
    public var designID: DesignID
    public var name: String
    /// When the files go (ms since 1970). Nothing counts down to it on screen.
    public var undoUntil: Double

    public init(designID: DesignID, name: String, undoUntil: Double) {
        self.designID = designID
        self.name = name
        self.undoUntil = undoUntil
    }

    /// How long a deleted design can be restored (DesignDeleted: "Undo for 10 seconds").
    public static let undoWindow: TimeInterval = 10
}

/// The names Shepherd gives the designs it makes from others. Never a merge: a copy gets a
/// name no design has, compared regardless of case.
public enum DesignNaming {
    /// A project imported again (ImportAgain): "Checkout funnel 2", then "Checkout funnel 3", the
    /// first number no design is named; `name` itself while it is free.
    public static func importName(_ name: String, taken: some Sequence<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }

    /// Duplicate: "Checkout funnel copy", then "Checkout funnel copy 2", as a board's Duplicate
    /// names its copy.
    public static func duplicateName(_ name: String, taken: some Sequence<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines) + " copy"
        guard taken.contains(base.lowercased()) else { return base }
        var number = 2
        while taken.contains("\(base) \(number)".lowercased()) { number += 1 }
        return "\(base) \(number)"
    }
}
