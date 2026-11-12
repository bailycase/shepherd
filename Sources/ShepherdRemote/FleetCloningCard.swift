import Foundation
import ShepherdCore

/// The "Cloning" card (FleetStates, "Repo isn't on that Mac"): work whose Mac has no checkout of the repository yet and is cloning it
/// first, drawn from the dispatch record alone. It is `FleetDispatchCard.cloning`, shown in the thread that sent the work and on the
/// Fleet page while the record is `preparing` and says where the clone stands (`FleetDispatchRecord.clone`).
public struct FleetCloningCard: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// The Mac it is cloning on, as its tag names it.
    public var host: String
    /// The word on the pill.
    public var state: String
    /// "Cloning orders-svc from github.com/acme/orders-svc with Mac Studio's git sign-in. The thread starts when it finishes."
    public var summary: String
    /// How far through git's current phase, 0...1; nil before git has said.
    public var fraction: Double?
    /// git's own word for what it is doing: "receiving objects".
    public var progress: String

    public var accessibilityLabel: String { "\(title), cloning on \(host), \(progress). \(summary)" }

    /// The card for `record`, or nil when it isn't cloning now.
    public static func make(_ record: FleetDispatchRecord) -> FleetCloningCard? {
        guard record.state == .preparing, let clone = record.clone else { return nil }
        let host = record.targetHostName ?? "the other Mac"
        let words: String
        if clone.viaBundle {
            let why = CanonicalRepoKey.isLocal(record.repoKey) ? "\(clone.name) has no origin" : "\(host) couldn't reach \(record.repoKey)'s origin"
            words = "\(why), so \(clone.source) sent it the repository itself and \(host) is cloning that. The thread starts when it finishes."
        } else {
            words = "Cloning \(clone.name) from \(clone.source) with \(host)'s git sign-in. The thread starts when it finishes."
        }
        // A repository that is on its way in a bundle shows how much of it has arrived until git has begun.
        var fraction = clone.fraction
        if fraction == nil, clone.phase == nil, clone.viaBundle, let bytes = record.snapshotBytes, bytes > 0 {
            fraction = min(1, Double(record.snapshotProgress ?? 0) / Double(bytes))
        }
        return FleetCloningCard(id: record.id, title: record.title.isEmpty ? "Untitled" : record.title, host: host, state: "Cloning", summary: words,
                                fraction: fraction, progress: clone.phase ?? (clone.viaBundle ? "receiving the repository" : "starting"))
    }
}
