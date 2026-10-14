import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// "Add a space…" with no Space to pick (ProjectLead-AddsSpace: a folder, then "Add to project"): choosing a folder registers it as a
/// Space on the Project's OWNER, then the Project links it. A viewer never uses its own folders for a remote owner's Project: that
/// goes through the existing remote directory picker on the owner, or says why it cannot.
enum ProjectFolderRoute: Equatable {
    case thisMac
    case host(UUID, name: String)
    /// The owner is a host this Mac is not connected to: its folders cannot be listed or registered.
    case offline(name: String)

    var menuTitle: String {
        switch self {
        case .thisMac: "Choose folder…"
        case .host(_, let name): "Choose folder on \(name)…"
        case .offline(let name): "Choose folder on \(name)… (not connected)"
        }
    }

    var isAvailable: Bool { if case .offline = self { false } else { true } }

    /// `connection` is the owner host's name and whether it is connected; nil for This Mac, or a host this Mac no longer lists.
    static func route(home: LogicalProjectHome, connection: (name: String, connected: Bool)?) -> ProjectFolderRoute {
        switch home {
        case .local: .thisMac
        case .host(let id):
            connection.map { $0.connected ? .host(id, name: $0.name) : .offline(name: $0.name) } ?? .offline(name: "its host")
        }
    }
}

extension ShepherdViewModel {
    func projectFolderRoute(_ home: LogicalProjectHome) -> ProjectFolderRoute {
        guard case .host(let id) = home else { return .thisMac }
        let connection = remoteHosts.connections.first { $0.id == id }
        return .route(home: home, connection: connection.map { ($0.config.name, $0.phase == .connected) })
    }
}

/// The folder chooser itself, in the owner's own terms. `chosen` gets the owner's Space once it exists there and links it.
struct ProjectFolderPicker: View {
    var vm: ShepherdViewModel
    let route: ProjectFolderRoute
    let chosen: @MainActor (SpaceID) async -> Void
    let close: () -> Void

    var body: some View {
        switch route {
        case .thisMac:
            RemoteDirectoryPicker(
                title: "Add a space", actionTitle: "Add to project", hostName: "this Mac",
                list: { path in try await LocalDirectoryLister.load(path: path) },
                choose: { path in
                    close()
                    Task {
                        if let space = await vm.spaceForProject(at: URL(fileURLWithPath: path)) { await chosen(space) }
                        else if vm.remoteActionError == nil { vm.remoteActionError = "Couldn't add that folder as a space." }
                    }
                },
                cancel: close)
        case .host(let hostID, let name):
            RemoteDirectoryPicker(
                title: "Add a space", actionTitle: "Add to project", hostName: name,
                list: { path in try await vm.remoteHosts.listDir(hostID: hostID, path: path) },
                choose: { path in
                    close()
                    Task {
                        do { await chosen(try await vm.addRemoteSpace(hostID: hostID, path: path)) }
                        catch { vm.remoteActionError = "Couldn't add the space on \(name): \(error)" }
                    }
                },
                cancel: close)
        case .offline:
            EmptyView()
        }
    }
}
