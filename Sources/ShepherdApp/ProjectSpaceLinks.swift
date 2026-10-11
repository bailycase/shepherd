import Foundation
import ShepherdCore

/// The Spaces tab's rows and Add choices (ProjectLead-SettingsSpacesV2), resolved against each link's own destination. A link is the
/// pair (destination host, SpaceID): two hosts may hold the same SpaceID, and two Spaces may share a name or a path, so nothing here
/// ever resolves, filters or removes by a bare SpaceID, a name or a path. A destination's Spaces are the owner's inventory for that
/// destination only: the owner's own Spaces for `.local`, and the matching `ProjectHostOption.spaces` for a remote host.
enum ProjectSpaceLinks {
    /// One linked Space, drawn as one row.
    struct Row: Equatable, Identifiable {
        let link: ProjectSpaceLink
        var id: ProjectSpaceLink.Identity { link.id }
        /// The Space's own name on its own host, or what is honestly known when that host does not list it.
        let name: String
        /// The Space's path as its own host reports it, nil when that host does not list the Space.
        let path: String?
        /// `path · host`, each part only if known; what VoiceOver reads. The row draws the two parts apart so a narrow window shortens the
        /// path and never the host. A path on another machine is never shortened with this Mac's home folder.
        let detail: String
        /// The owner-relative host the Space lives on, named by the owner's own host list.
        let hostName: String
        /// What VoiceOver and `ControlPress` call Remove: the Space's name, and its host unless it is on the owner's own machine.
        let removeLabel: String
    }

    /// One Space that can be added: a Space of one destination that is not linked there yet.
    struct AddChoice: Equatable, Identifiable {
        let destination: ProjectHostReference
        let space: Space
        let hostName: String
        var id: Key { Key(host: destination, spaceID: space.id) }
        /// The same pair a `ProjectSpaceLink` is identified by: a destination and a SpaceID, never either alone.
        struct Key: Hashable {
            let host: ProjectHostReference
            let spaceID: SpaceID
        }
        /// The owner's own Spaces are listed by name alone; another host's say where they are.
        var title: String { destination == .local ? space.name : "\(space.name) on \(hostName)" }
        /// `nil` for the owner's own machine, so a local link is stored as it always was.
        var host: ProjectHostReference? { destination == .local ? nil : destination }
    }

    /// `ownerName` names the owner's own machine ("This Mac" when this device owns the project). `options` is the owner's inventory,
    /// nil while it is unknown. `abbreviatesHome` is true only when the owner's own machine is this one.
    static func rows(links: [ProjectSpaceLink], ownerSpaces: [Space], options: [ProjectHostOption]?, ownerName: String,
                     abbreviatesHome: Bool) -> [Row] {
        links.map { link in
            let destination = link.destination
            let option = destination == .local ? nil : options?.first { $0.reference == destination }
            let spaces: [Space]? = destination == .local ? ownerSpaces : option?.spaces
            let hostName = destination == .local ? ownerName : option?.name
            let space = spaces?.first { $0.id == link.spaceID }
            let name: String
            switch (space, spaces, hostName) {
            case (let space?, _, _): name = space.name
            case (nil, .some, let host?): name = "A space that is no longer on \(host)"
            case (nil, nil, let host?): name = "A space on \(host), which does not list its spaces"
            case (nil, _, nil): name = "A space on a host that is not connected"
            }
            let path = space.map { abbreviatesHome && destination == .local ? ($0.path as NSString).abbreviatingWithTildeInPath : $0.path }
            let detail = [path, hostName].compactMap { $0 }.joined(separator: " · ")
            let remove = destination == .local ? "Remove \(name)" : "Remove \(name) on \(hostName ?? "an unknown host")"
            return Row(link: link, name: name, path: path, detail: detail, hostName: hostName ?? "an unknown host", removeLabel: remove)
        }
    }

    /// Every visible Space of every destination the owner lists, minus the (destination, SpaceID) pairs already linked. A remote host
    /// that does not list its Spaces (`spaces == nil`) offers none, so a link the owner would refuse is never offered.
    static func addChoices(links: [ProjectSpaceLink], ownerSpaces: [Space], options: [ProjectHostOption]?, ownerName: String) -> [AddChoice] {
        let linked = Set(links.map { AddChoice.Key(host: $0.destination, spaceID: $0.spaceID) })
        var made = ownerSpaces.filter { !$0.hidden }.map { AddChoice(destination: .local, space: $0, hostName: ownerName) }
        for option in options ?? [] where option.reference != .local {
            made += (option.spaces ?? []).filter { !$0.hidden }.map { AddChoice(destination: option.reference, space: $0, hostName: option.name) }
        }
        return made.filter { !linked.contains($0.id) }
    }
}
