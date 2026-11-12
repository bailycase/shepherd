import Foundation
import ShepherdProtocol
import ShepherdRemote

/// One row of Settings ▸ Fleet's Macs: This Mac, then each Mac it is paired with. Plain values, derived once per change.
struct FleetMacRow: Identifiable, Equatable {
    /// "this" for This Mac, else the Mac's host id.
    let id: String
    /// Nil for This Mac, which can't be removed.
    let hostID: UUID?
    let title: String
    /// Where it is and since when.
    let detail: String
    let state: FleetMacRowState

    /// The rows for `snapshot`. `locale` and `calendar` fix the dates the detail lines show.
    static func rows(of snapshot: FleetSnapshot, locale: Locale = .current, calendar: Calendar = .current) -> [FleetMacRow] {
        func date(_ milliseconds: Double) -> String {
            Date(timeIntervalSince1970: milliseconds / 1000).formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day())
        }
        func time(_ milliseconds: Double) -> String {
            Date(timeIntervalSince1970: milliseconds / 1000).formatted(Date.FormatStyle(locale: locale, calendar: calendar).hour().minute())
        }
        let this = FleetMacRow(
            id: "this", hostID: nil, title: "This Mac",
            detail: [snapshot.name.isEmpty ? nil : snapshot.name, snapshot.addresses.first, snapshot.port.map { "port \($0)" } ?? "Not serving"]
                .compactMap { $0 }.joined(separator: " · "),
            state: .thisMac)
        let peers = snapshot.peers.map { peer -> FleetMacRow in
            let address = peer.host.map { host in peer.port.map { "\(host):\($0)" } ?? host } ?? "Unknown address"
            switch peer.link {
            case .connected:
                return FleetMacRow(id: peer.hostID.uuidString, hostID: peer.hostID, title: peer.name,
                                   detail: "\(address) · paired \(date(peer.pairedAt))", state: .connected)
            case .connecting:
                return FleetMacRow(id: peer.hostID.uuidString, hostID: peer.hostID, title: peer.name,
                                   detail: "\(address) · connecting…", state: .connecting)
            case .offline:
                let since = peer.lastSeen.map { "Offline since \(time($0))" } ?? "Not connected yet"
                return FleetMacRow(id: peer.hostID.uuidString, hostID: peer.hostID, title: peer.name,
                                   detail: "\(since) · \(address) · paired \(date(peer.pairedAt))", state: .offline)
            }
        }
        return [this] + peers
    }
}

extension FleetMacRow {
    /// A Mac this app is a client of (`RemoteHostStore`): where it is and how the connection stands.
    static func client(id: UUID, name: String, host: String, port: UInt16, phase: RemoteHostStore.Phase) -> FleetMacRow {
        let (word, state): (String, FleetMacRowState) = switch phase {
        case .connected: ("connected", .connected)
        case .connecting: ("connecting…", .connecting)
        case .failed(let failure): (failure.headline.lowercased(), .offline)
        case .disconnected: ("disconnected", .offline)
        }
        return FleetMacRow(id: id.uuidString, hostID: id, title: name, detail: "\(host):\(port) · \(word)", state: state)
    }
}

enum FleetMacRowState: Equatable {
    case thisMac, connected, connecting, offline
}

/// One row of Settings ▸ Fleet's Devices: a phone, an iPad or a Mac's app paired as a client.
struct FleetDeviceRow: Identifiable, Equatable {
    let id: UUID
    let title: String
    let kind: FleetDeviceKind
    /// What it is, when it was paired and whether it is connected here.
    let detail: String
    let connected: Bool

    static func rows(of snapshot: FleetSnapshot, locale: Locale = .current, calendar: Calendar = .current) -> [FleetDeviceRow] {
        func date(_ milliseconds: Double) -> String {
            Date(timeIntervalSince1970: milliseconds / 1000).formatted(Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day())
        }
        func time(_ milliseconds: Double) -> String {
            Date(timeIntervalSince1970: milliseconds / 1000).formatted(Date.FormatStyle(locale: locale, calendar: calendar).hour().minute())
        }
        return (snapshot.devices?.devices ?? []).map { device in
            let kind = switch device.kind {
            case .iphone: "iPhone"
            case .ipad: "iPad"
            case .macApp: "Mac"
            }
            let seen = device.connected ? "connected here" : device.lastSeen.map { "last seen \(time($0))" } ?? "not connected yet"
            return FleetDeviceRow(id: device.deviceID, title: device.name, kind: device.kind,
                                  detail: "\(kind) · paired \(date(device.pairedAt)) · \(seen)", connected: device.connected)
        }
    }
}

/// Settings ▸ Fleet: this Mac's fleet as its host reports it (`FleetService`), the Macs Bonjour
/// finds for Add a Mac, and the two things a person does: enter a code shown on another Mac, or
/// show one here. The host does the work (it holds the links and takes the pairing, so both work
/// with only the background service running); this reads it over `host.sock` and acts through it.
@MainActor
@Observable
final class FleetSettingsModel {
    /// What a Join screen shows: the code and when it stops working.
    struct Join: Equatable {
        var code: String
        var expiresAt: Date
    }

    /// How a Join screen ended.
    enum JoinEnd: Equatable {
        /// A Mac paired with this one.
        case joined(String)
        /// The window closed with nobody: its five minutes ran out or five wrong codes were tried.
        case closed
    }

    /// How an Add a device screen ended.
    enum DeviceCodeEnd: Equatable {
        /// A device paired with this Mac: its name.
        case added(String)
        /// The window closed with nobody.
        case closed
    }

    enum Pairing: Equatable {
        case idle
        case working
        case failed(String)
    }

    /// The host's fleet: this Mac, the Macs it is paired with and each link. Empty (not enabled)
    /// until the host answers, and while Fleet is off (its devices and port are still read then).
    var snapshot = FleetSnapshot()
    /// The host answered with its devices: Add a device and the list work (Fleet on or off).
    var devicesReady = false
    /// This Mac and each Mac it is paired with, as Settings lists them.
    var rows: [FleetMacRow] = []
    /// Where sync stands, in the line under the page's explanation; nil with no Mac paired.
    var syncLine: FleetSyncLine?
    /// The host has answered at least once since Fleet was switched on.
    var loaded = false
    /// The code this Mac shows while its Join screen is open.
    var join: Join?
    var joinEnd: JoinEnd?
    /// Add a Mac: the Macs Bonjour found that this Mac doesn't have and isn't.
    var found: [FoundMac] = []
    var pairing: Pairing = .idle
    /// The last thing that failed on the page, said under the Macs.
    var problem: String?
    /// The phones, iPads and Mac apps paired as clients, as Settings lists them.
    var deviceRows: [FleetDeviceRow] = []
    /// The code this Mac shows while its Add a device screen is open.
    var deviceCode: Join?
    var deviceCodeEnd: DeviceCodeEnd?
    /// The last thing that failed on the Devices, said under them.
    var deviceProblem: String?

    /// This Mac's host, over its local socket; throws while it is away.
    @ObservationIgnored var host: () throws -> RemoteHostClient? = { nil }
    /// Pairs this app as a device of a Mac that is not in its fleet (Fleet off): the app does it, not its host.
    @ObservationIgnored var pairClient: (String, UInt16, String) async throws -> Void = { _, _, _ in }
    /// Starts finding Macs; the answer stops it. Replaced by a fixture in tests.
    @ObservationIgnored var browse: @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void = { _ in {} }
    @ObservationIgnored private var stopBrowsing: (() -> Void)?
    @ObservationIgnored private var everyFound: [FoundMac] = []
    @ObservationIgnored private var joinBaseline: Set<UUID> = []
    @ObservationIgnored private var deviceBaseline: Set<UUID> = []
    @ObservationIgnored private var adopting: Set<UUID> = []
    @ObservationIgnored private var notFleet: Set<UUID> = []

    init() {}

    // MARK: Reading

    /// Reads the host's fleet again. A host that is away leaves what was shown, and says so once there is nothing.
    func refresh() async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetRead())
            problem = nil
        } catch {
            if !loaded { problem = Self.words(error) }
        }
    }

    private func apply(_ result: FleetResult) {
        if result.snapshot != snapshot {
            snapshot = result.snapshot
            rows = result.snapshot.enabled ? FleetMacRow.rows(of: result.snapshot) : []
            let devices = FleetDeviceRow.rows(of: result.snapshot)
            if devices != deviceRows { deviceRows = devices }
            syncLine = result.snapshot.sync.flatMap(FleetSyncPresentation.line)
        }
        loaded = result.snapshot.enabled
        devicesReady = result.snapshot.devices != nil
        if join != nil, result.snapshot.join == nil {
            // The window is closed: a Mac paired (it is in the list now) or it ran out.
            let joined = result.snapshot.peers.first { !joinBaseline.contains($0.hostID) }
            join = nil
            joinEnd = joined.map { .joined($0.name) } ?? .closed
        }
        if deviceCode != nil, result.snapshot.devices?.code == nil {
            // The window is closed: a device paired (it is in the list now) or it ran out.
            let added = deviceRows.first { !deviceBaseline.contains($0.id) }
            deviceCode = nil
            deviceCodeEnd = added.map { .added($0.title) } ?? .closed
        }
        filterFound()
    }

    // MARK: Joining: this Mac shows the code

    /// Opens a code window on the host and shows its code.
    func startJoin() async {
        do {
            guard let client = try host() else { return }
            joinEnd = nil
            join = nil
            let result = try await client.fleetAction(.startJoin)
            joinBaseline = Set(result.snapshot.peers.map(\.hostID))
            apply(result)
            if let opened = result.join {
                join = Join(code: opened.code, expiresAt: Date(timeIntervalSince1970: opened.expiresAt / 1000))
            }
        } catch {
            problem = Self.words(error)
        }
    }

    /// The Join screen closed: so does the window, and its code stops working.
    func stopJoin() async {
        guard let client = try? host() else { return }
        if let result = try? await client.fleetAction(.stopJoin) { apply(result) }
    }

    // MARK: Devices: this Mac shows a code a phone or iPad enters

    /// Opens the code window of Add a device on the host and shows its code.
    func startDeviceCode() async {
        do {
            guard let client = try host() else { return }
            deviceCodeEnd = nil
            deviceCode = nil
            let result = try await client.fleetAction(.startDeviceCode)
            deviceBaseline = Set(FleetDeviceRow.rows(of: result.snapshot).map(\.id))
            apply(result)
            if let opened = result.deviceCode {
                deviceCode = Join(code: opened.code, expiresAt: Date(timeIntervalSince1970: opened.expiresAt / 1000))
            }
        } catch {
            deviceProblem = Self.words(error)
        }
    }

    /// The Add a device screen closed: so does the window, and its code stops working.
    func stopDeviceCode() async {
        guard let client = try? host() else { return }
        if let result = try? await client.fleetAction(.stopDeviceCode) { apply(result) }
    }

    /// Revokes a device here and on every Mac in the fleet: its connections end and its token is refused.
    func revokeDevice(_ id: UUID) async {
        await deviceAction(.revokeDevice(id))
    }

    /// Stops accepting the shared token. The host refuses while a device that used it hasn't switched.
    func retireSharedToken() async {
        await deviceAction(.retireSharedToken)
    }

    /// Stops waiting for a client that connected with the shared token and may never come back.
    func forgetWaiting(_ id: String) async {
        await deviceAction(.forgetLegacyClient(id))
    }

    private func deviceAction(_ action: FleetAction) async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetAction(action))
            deviceProblem = nil
        } catch {
            deviceProblem = Self.words(error)
        }
    }

    /// A token for this Mac's app to reach the other Macs of the fleet with, made by the host; nil while it is away.
    func enrollApp(name: String) async -> String? {
        guard let client = try? host(), let result = try? await client.fleetAction(.enrollApp(name: name)) else { return nil }
        apply(result)
        return result.appToken
    }

    // MARK: Adding: another Mac's code is entered here

    /// Starts finding Macs while the Add a Mac sheet is open. Opening the sheet clears the last try's failure (`openPairing`).
    func startFinding() {
        stopBrowsing?()
        stopBrowsing = browse { [weak self] macs in
            Task { @MainActor in
                self?.everyFound = macs
                self?.filterFound()
            }
        }
    }

    func openPairing() { pairing = .idle }

    func stopFinding() {
        stopBrowsing?()
        stopBrowsing = nil
        everyFound = []
        found = []
    }

    private func filterFound() {
        let own = snapshot.hostID.map(FleetProtocol.advertisedIDHash)
        let known = Set(snapshot.peers.map { FleetProtocol.advertisedIDHash($0.hostID) })
        let shown = everyFound.filter { mac in mac.idHash == nil || (mac.idHash != own && !known.contains(mac.idHash ?? "")) }
        if shown != found { found = shown }
    }

    /// Enters `code` on `mac`: the host connects to it, pairs and brings it into the fleet. True when it did.
    func pair(with mac: FoundMac, code: String) async -> Bool {
        guard let address = mac.address, let port = mac.port else { return false }
        pairing = .working
        do {
            guard let client = try host() else { pairing = .failed("Shepherd's background service isn't answering."); return false }
            apply(try await client.fleetAction(.pair(host: address, port: port, code: code)))
            pairing = .idle
            return true
        } catch {
            pairing = .failed(Self.words(error))
            return false
        }
    }

    /// Enters `code` on `mac` and adds it as a Mac this app is a client of (Fleet off). True when it did.
    func pairAsClient(with mac: FoundMac, code: String) async -> Bool {
        guard let address = mac.address, let port = mac.port else { return false }
        pairing = .working
        do {
            try await pairClient(address, port, code)
            pairing = .idle
            return true
        } catch {
            pairing = .failed(Self.words(error))
            return false
        }
    }

    // MARK: Removing

    /// Removes a Mac from the fleet, here and on every other member.
    func remove(_ hostID: UUID) async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetAction(.remove(hostID: hostID)))
            problem = nil
        } catch {
            problem = Self.words(error)
        }
    }

    // MARK: Moving a pre-fleet pairing over

    /// Hands hosts the app already reached with the shared token to its host, which makes the ones
    /// that speak Fleet peers. The answer says which became one. A host that said it isn't a fleet
    /// Mac isn't asked again until it connects again (`retrying`), and one being asked isn't asked twice.
    func adopt(_ hosts: [FleetLegacyHost], retrying: Bool = false) async -> [FleetAdoption] {
        let asked = hosts.filter { !adopting.contains($0.id) && (retrying || !notFleet.contains($0.id)) }
        guard !asked.isEmpty, let client = try? host() else { return [] }
        adopting.formUnion(asked.map(\.id))
        defer { adopting.subtract(asked.map(\.id)) }
        guard let result = try? await client.fleetAction(.adopt(asked)) else { return [] }
        apply(result)
        let outcomes = result.adopted ?? []
        for adoption in outcomes {
            if adoption.outcome == .notFleet { notFleet.insert(adoption.id) } else { notFleet.remove(adoption.id) }
        }
        return outcomes
    }

    // MARK: Words

    /// A refusal's own sentence (the host writes them for people), or why nothing answered.
    static func words(_ error: Error) -> String {
        guard let error = error as? RemoteHostClientError else { return "Couldn't reach Shepherd's background service." }
        switch error {
        case .rejected(_, let message): return message
        case .timeout, .disconnected: return "Couldn't reach that Mac. Check that Shepherd is open on it and that it is on this network."
        case .resolveFailed, .system: return "Couldn't reach that Mac. Check that Shepherd is open on it and that it is on this network."
        case .outcomeUnknown(let message): return message
        }
    }
}
