import Foundation
import ShepherdProtocol

// A phone or an iPad paired with any Mac of a fleet keeps its saved Macs in step with the fleet (`RemoteProtocol.fleetFollowCapability`).
// The decision is made here, on plain values, so it is the same for every client and is tested without a connection; `MobileHosts` reads
// the fleet, asks for the plan and applies it.

/// A Mac the client has saved, as the plan sees it.
public struct FleetFollowSaved: Equatable, Sendable {
    /// The id the client saved it under (`RemoteHostRecord.id`).
    public var id: UUID
    /// The Mac's own id in its fleet, as its `hello` said; nil until it has said. Matching is by this, never by an address.
    public var fleetID: UUID?
    public var name: String
    public var routes: [RemoteHostRoute]
    /// Which fleet the client learned the Mac from (`FleetFollowPlan.group`); nil for a Mac the client has not placed in one.
    public var group: UUID?
    /// The saved token is this device's own, the one every Mac of a fleet accepts. Any other Mac (a pasted token, the shared one) is the
    /// user's own pairing and is left as it is.
    public var ownsToken: Bool

    public init(id: UUID, fleetID: UUID?, name: String, routes: [RemoteHostRoute], group: UUID?, ownsToken: Bool) {
        self.id = id
        self.fleetID = fleetID
        self.name = name
        self.routes = routes
        self.group = group
        self.ownsToken = ownsToken
    }
}

/// What to change on the client's saved Macs to match a fleet.
public struct FleetFollowPlan: Equatable, Sendable {
    public struct Update: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var routes: [RemoteHostRoute]
        public var group: UUID
    }

    /// The fleet these Macs belong to, as far as the client is concerned: the group of the Mac it read from, or a new one.
    public var group: UUID
    /// Macs of the fleet the client doesn't have: saved with the device's own token, in this group.
    public var add: [FleetViewMember]
    public var update: [Update]
    /// Saved Macs (`FleetFollowSaved.id`) that are no longer in the fleet.
    public var remove: [UUID]

    public var isEmpty: Bool { add.isEmpty && update.isEmpty && remove.isEmpty }
}

public enum FleetFollow {
    /// The routes a Mac of a view is reached by, in the order the Mac gave them.
    public static func routes(of member: FleetViewMember) -> [RemoteHostRoute] {
        member.routes.map { RemoteHostRoute(host: $0.host, port: member.port, kind: $0.kind) }
    }

    /// What reading the fleet from the saved Mac `source` (which answered with `members`) changes.
    ///
    /// - A Mac is found by its fleet id. One that is there gets the fleet's name and routes (a Mac that names no route keeps its own, and
    ///   one that is connected and reading its own fleet speaks for itself);
    ///   one that isn't is added unless `ignored` (the user forgot it); one that is in the source's group and not in the list is removed.
    /// - Only Macs on the device's own token are touched, and a removal needs a Mac the client placed in the same group.
    /// - A Mac that has left the fleet still answers with a fleet of its own, in which the others are missing. `views` holds what each
    ///   connected Mac last said (its members' ids), and the source doesn't remove a Mac whose own fleet is larger, or as large and
    ///   saved first: of two halves of a split, the bigger stays. A Mac in `awaiting` (connecting, or connected and not yet heard from) is
    ///   no rival yet and is not removed either; it is looked at again when it has said.
    ///
    /// Nil when there is nothing to go on: the source isn't one the client may follow from, or the answer is empty or leaves the source out
    /// (a host before this capability says nothing of its members, so it never prunes).
    public static func plan(source: UUID, members: [FleetViewMember], saved: [FleetFollowSaved], ignored: Set<UUID> = [],
                            views: [UUID: Set<UUID>] = [:], awaiting: Set<UUID> = [], newGroup: UUID = UUID()) -> FleetFollowPlan? {
        guard let from = saved.first(where: { $0.id == source }), from.ownsToken, let own = from.fleetID else { return nil }
        var seen = Set<UUID>()
        let listed = members.prefix(FleetViewMember.maxMembers).filter { $0.isValid && seen.insert($0.hostID).inserted }
        guard listed.contains(where: { $0.hostID == own }) else { return nil }
        let group = from.group ?? newGroup
        var plan = FleetFollowPlan(group: group, add: [], update: [], remove: [])
        for member in listed {
            let routes = routes(of: member)
            guard let held = saved.first(where: { $0.fleetID == member.hostID }) else {
                if !routes.isEmpty, !ignored.contains(member.hostID) { plan.add.append(member) }
                continue
            }
            guard held.ownsToken else { continue }
            // A connected Mac says what it is and how it is reached itself, better than another Mac does.
            let speaksForItself = held.id != source && views[held.id] != nil
            let next = FleetFollowPlan.Update(id: held.id, name: speaksForItself ? held.name : member.name,
                                              routes: routes.isEmpty || speaksForItself ? held.routes : routes, group: group)
            if next.name != held.name || next.routes != held.routes || held.group != group { plan.update.append(next) }
        }
        let inFleet = Set(listed.map(\.hostID))
        let rank = Dictionary(uniqueKeysWithValues: saved.enumerated().map { ($1.id, $0) })
        for other in saved where other.id != source && other.ownsToken && other.group == group {
            guard let id = other.fleetID, !inFleet.contains(id), !awaiting.contains(other.id) else { continue }
            if let theirs = views[other.id], theirs.count > inFleet.count || (theirs.count == inFleet.count && rank[other.id]! < rank[source]!) { continue }
            plan.remove.append(other.id)
        }
        return plan
    }
}
