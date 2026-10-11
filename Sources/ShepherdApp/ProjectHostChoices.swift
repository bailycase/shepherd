import Foundation
import ShepherdCore

/// The Hosts row of a Project's Spaces tab (ProjectLead-SettingsSpacesV2): where threads may run. The words come from the
/// owner's own host list (`ProjectRuntimeTransport.hosts`), never from this viewer's. "This Mac" is the OWNER's own machine: for a
/// Project owned by a remote host it carries that host's name instead.
struct ProjectHostChoices: Equatable {
    struct Choice: Equatable, Identifiable {
        let title: String
        let policy: ProjectHostPolicy
        let allowedHosts: [ProjectHostReference]
        var id: String { title }
    }

    /// What is saved now, in words.
    let current: String
    /// What can be chosen: "This Mac and <host>" for each other host the owner knows, "This Mac only", "Any connected host".
    let choices: [Choice]

    /// `options`: the owner's known hosts, nil when it did not say (an older or unreachable owner). `ownerName` names the owner's own
    /// machine ("This Mac" when this device owns the Project).
    init(settings: LogicalProjectSettings, options: [ProjectHostOption]?, ownerName: String) {
        let local = ownerName
        func name(_ reference: ProjectHostReference) -> String {
            if reference == .local { return local }
            return options?.first { $0.reference == reference }?.name ?? "an unknown host"
        }
        var made: [Choice] = []
        for option in options ?? [] where option.reference != .local {
            made.append(Choice(title: "\(local) and \(option.name)", policy: .selected, allowedHosts: [.local, option.reference]))
        }
        made.append(Choice(title: "\(local) only", policy: .selected, allowedHosts: [.local]))
        made.append(Choice(title: "Any connected host", policy: .anyConnected, allowedHosts: settings.allowedHosts))
        choices = made

        if settings.hostPolicy == .anyConnected {
            current = "Any connected host"
        } else {
            let names = settings.allowedHosts.map(name)
            switch names.count {
            case 0: current = "No host"
            case 1: current = "\(names[0]) only"
            default: current = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            }
        }
    }

    /// The choice that is already saved, if it is one of the offered ones.
    var selected: Choice? { choices.first { $0.title == current } }
}
