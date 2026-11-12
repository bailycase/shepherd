import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

// Fleet on the iPhone and the iPad: a client reads the Macs, their load and readiness from one Mac that
// serves `fleet.view.v1`, and chooses where work is sent through that Mac's host settings. It holds no
// part of the fleet's store (`FleetAccess.device`). The page is `FleetPagePresentation`, the one the Mac's
// app draws, derived once per change here and never in a view's body.

/// What a client reads the fleet through: its `RemoteHostClient`, or a stand-in in tests. A host that
/// serves `fleet.view.v1` answers `fleetRead` with the cut down view (`FleetSnapshot.clientView`).
public protocol FleetViewClient: SettingsClient {
    func fleetRead() async throws -> FleetResult
    /// Tells the host the Fleet page is on screen (true) or isn't (false): it samples while it is.
    func fleetWatching(_ on: Bool) async throws
}

extension RemoteHostClient: FleetViewClient {
    public func fleetWatching(_ on: Bool) async throws {
        _ = try await fleetAction(.watching(on))
    }
}

@MainActor
@Observable
public final class ClientFleet {
    public enum Phase: Equatable, Sendable {
        /// Nothing read yet.
        case idle
        case loaded
        /// The Mac the page reads from has Fleet off.
        case off
        /// The last read failed; the page keeps what it had.
        case failed(String)
    }

    public private(set) var page = FleetPage.empty
    public private(set) var phase = Phase.idle
    /// The Mac the page is read from, by name.
    public private(set) var sourceName: String?

    /// The weights are host settings: shared with the rest of Settings, so one read serves both.
    public let hostSettings: ClientHostSettings
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored private var snapshot = FleetSnapshot()
    @ObservationIgnored private var snapshotAt = Date()
    @ObservationIgnored private var sourceID: UUID?
    @ObservationIgnored private var reads = 0
    /// How often the weights are read again with the snapshot: they rarely change, and each read is a whole settings page.
    static let settingsEvery = 6

    public init(hostSettings: ClientHostSettings) {
        self.hostSettings = hostSettings
    }

    /// The hosts a page can be read from: connected, and serving the view.
    public static func sources(_ hosts: [SettingsHost]) -> [SettingsHost] {
        hosts.filter { $0.serves(RemoteProtocol.fleetViewCapability) && $0.client is any FleetViewClient }
    }

    /// Some connected Mac serves the fleet: the Fleet entries show.
    public static func isAvailable(_ hosts: [SettingsHost]) -> Bool { !sources(hosts).isEmpty }

    private func source(in hosts: [SettingsHost]) -> SettingsHost? {
        let all = Self.sources(hosts)
        return all.first { $0.id == sourceID } ?? all.first
    }

    /// Reads the fleet again from the Mac in use, and the weights now and then. A read that fails keeps the page and
    /// moves on to the next Mac that serves the view.
    public func refresh(_ hosts: [SettingsHost]) async {
        guard let host = source(in: hosts), let client = host.client as? any FleetViewClient else {
            // No Mac to ask: the entries hide; what was drawn stays until one is back.
            sourceID = nil
            return
        }
        sourceID = host.id
        let held = reads
        reads += 1
        do {
            let read = try await client.fleetRead().snapshot
            if held % Self.settingsEvery == 0 || hostSettings.settings(of: host) == nil { await hostSettings.refresh(host) }
            guard sourceID == host.id else { return }
            sourceName = host.name
            snapshot = read
            snapshotAt = now()
            phase = read.enabled ? .loaded : .off
            recompute(host)
        } catch {
            guard sourceID == host.id else { return }
            if case RemoteHostClientError.rejected(let code, _) = error, code == FleetProtocol.Code.off {
                phase = .off
                page = .empty
                return
            }
            phase = .failed(settingsProblem(error))
            let all = Self.sources(hosts)
            if let index = all.firstIndex(where: { $0.id == host.id }), all.count > 1 { sourceID = all[(index + 1) % all.count].id }
        }
    }

    /// Derives the page again: a weight changed, or time passed (a sample the host stopped refreshing goes stale on screen).
    public func recompute(_ hosts: [SettingsHost]) {
        guard let host = source(in: hosts) else { return }
        recompute(host)
    }

    private func recompute(_ host: SettingsHost) {
        guard phase == .loaded || phase == .off else { return }
        let weights = hostSettings.settings(of: host)?.fleetWeights ?? [:]
        let next = FleetPagePresentation.make(snapshot: snapshot, weight: { weights[FleetSendWeight.settingKey(hostID: $0)] ?? .normal },
                                              snapshotAge: max(0, now().timeIntervalSince(snapshotAt)), viewer: .client)
        if next != page { page = next }
    }

    /// The Fleet page is on screen (true) or isn't: the Mac samples while it is. Best effort; a connection that
    /// closes ends it on the host either way.
    public func watching(_ on: Bool, _ hosts: [SettingsHost]) async {
        guard let client = source(in: hosts)?.client as? any FleetViewClient else { return }
        try? await client.fleetWatching(on)
    }

    /// Send work here: shows `choice` for the Mac `hostID` at once and writes it to the Mac in use as its own host setting,
    /// which it then syncs to the rest. A Mac that refuses it puts the old one back.
    @discardableResult
    public func choose(_ choice: FleetSendWeight, for hostID: UUID, _ hosts: [SettingsHost]) -> Task<Void, Never>? {
        guard let host = source(in: hosts) else { return nil }
        guard let sent = hostSettings.post(.fleetWeight(hostID: hostID, weight: choice), on: host) else { return nil }
        recompute(host)
        return Task { [weak self] in
            await sent.value
            self?.recompute(host)
        }
    }

    /// Why the last weight change was refused, in words.
    public var problem: String? { hostSettings.problem }

    public func dismissProblem() { hostSettings.dismissProblem() }
}
