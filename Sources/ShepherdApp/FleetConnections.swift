import Foundation
import ShepherdProtocol
import ShepherdRemote

/// A Mac connects to another only by joining its fleet. This app holds one connection to each Mac its host has paired, to draw their
/// threads (`RemoteHostStore`), and none to any other. The host makes this app a device of the fleet (`FleetAction.enrollApp`), so one
/// token of its own works on every Mac and none uses the shared one. The connection's id is the Mac's fleet id, the same one Projects
/// and dispatches name it by; a connection held from before keeps the id and binding it had.
@MainActor
final class FleetConnections {
    private let hosts: RemoteHostStore
    private let fleet: FleetSettingsModel
    /// How long a Mac that didn't take the token yet waits before the next try.
    var retryDelay: Duration = .seconds(10)
    var deviceName = Host.current().localizedName ?? "Mac"

    private var syncing = false
    private var again = false
    private var retry: Task<Void, Never>?

    init(hosts: RemoteHostStore, fleet: FleetSettingsModel) {
        self.hosts = hosts
        self.fleet = fleet
    }

    /// The host's fleet changed: the connections follow it, one pass at a time.
    func snapshotChanged(_ snapshot: FleetSnapshot) {
        guard snapshot.enabled else { return }
        guard !syncing else { again = true; return }
        syncing = true
        Task {
            repeat {
                again = false
                await sync(fleet.snapshot)
            } while again
            syncing = false
        }
    }

    /// Adds a connection for each Mac of the fleet that has none, follows the address and name of those that have one, and removes
    /// those whose Mac left the fleet. A Mac that doesn't answer with the token yet (it hasn't taken the device in) is tried again.
    func sync(_ snapshot: FleetSnapshot) async {
        guard snapshot.enabled else { return }
        func connection(of peer: FleetPeerStatus) -> RemoteHostStore.Connection? {
            hosts.pairedConnections.first { $0.id == peer.hostID || $0.fleetID == peer.hostID }
                ?? hosts.pairedConnections.first { $0.config.host == peer.host && $0.config.port == peer.port }
        }
        var members = hosts.fleetMembers
        for held in hosts.pairedConnections where members.contains(held.id) && !snapshot.peers.contains(where: { connection(of: $0) === held }) {
            hosts.removeHost(id: held.id)
            members.remove(held.id)
        }
        defer { if members != hosts.fleetMembers { hosts.fleetMembers = members } }
        var owed = false
        var token = hosts.pairedConnections.first { $0.config.ownToken }?.config.token
        for peer in snapshot.peers where peer.kind == .mac {
            guard let host = peer.host, let port = peer.port else { continue }
            let held = connection(of: peer)
            // A connection the fleet didn't make is not the fleet's to follow.
            if let held, !held.config.fleetManaged { continue }
            if let held { members.insert(held.id) }
            if let held, held.config.ownToken {
                if held.config.host != host || held.config.port != port || held.config.name != peer.name {
                    hosts.follow(id: held.id, name: peer.name, host: host, port: port)
                }
                continue
            }
            if token == nil { token = await fleet.enrollApp(name: deviceName) }
            guard let token else { owed = true; continue }
            let probe = RemoteHostClient()
            defer { probe.disconnect() }
            guard (try? await probe.connect(host: host, port: port, token: token, clientName: deviceName, capabilities: [], fetchesState: false)) != nil else {
                owed = true
                continue
            }
            if let held {
                // A Mac reached with the shared token moves to the app's own, so it can stop accepting the shared one.
                hosts.useOwnToken(id: held.id, token: token)
            } else if connection(of: peer) == nil {
                hosts.addHost(id: peer.hostID, name: peer.name, host: host, port: port, token: token, ownToken: true, fleetManaged: true)
                members.insert(peer.hostID)
            }
        }
        retry?.cancel()
        retry = nil
        if owed {
            retry = Task { [weak self] in
                try? await Task.sleep(for: self?.retryDelay ?? .seconds(10))
                guard !Task.isCancelled, let self else { return }
                self.snapshotChanged(self.fleet.snapshot)
            }
        }
    }
}
