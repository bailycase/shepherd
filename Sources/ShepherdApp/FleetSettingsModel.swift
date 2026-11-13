import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

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
    /// A Mac this app was a client of before Fleet was how Macs connect (`RemoteHostStore.notInFleet`): where it was and that it
    /// is not in the fleet. Its row adds it (`Add to fleet…`) or dismisses it.
    static func notInFleet(id: UUID, name: String, host: String, port: UInt16) -> FleetMacRow {
        FleetMacRow(id: id.uuidString, hostID: id, title: name, detail: "\(host):\(port) · not in your fleet", state: .notInFleet)
    }
}

enum FleetMacRowState: Equatable {
    case thisMac, connected, connecting, offline
    /// A Mac this app was a client of: add it to the fleet or dismiss it.
    case notInFleet
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
    /// until the host answers.
    var snapshot = FleetSnapshot()
    /// The host answered with its devices: Add a device and the list work.
    var devicesReady = false
    /// This Mac and each Mac it is paired with, as Settings lists them.
    var rows: [FleetMacRow] = []
    /// Where sync stands, in the line under the page's explanation; nil with no Mac paired.
    var syncLine: FleetSyncLine?
    /// The host has answered at least once.
    var loaded = false
    /// The code this Mac shows while its Join screen is open.
    var join: Join?
    var joinEnd: JoinEnd?
    /// Add a Mac: the Macs Bonjour found that this Mac doesn't have and isn't.
    var found: [FoundMac] = []
    var pairing: Pairing = .idle
    /// The host can look a code up in this person's iCloud (`RemoteProtocol.fleetRendezvousCapability`): Add a Mac then works
    /// without a Mac picked from the list. A host without it (an older Nightly still running) pairs only with a picked Mac.
    var findsByCode = false
    /// The host pairs with a Mac a pairing link or an SSH find names (`RemoteProtocol.fleetPairLinkCapability`).
    var findsByLink = false
    /// Add a Mac, a pairing link: the text in its field, what it says once read, and why it can't be used.
    var linkText = ""
    var link: FleetPairingLink?
    var linkProblem: String?
    /// A pairing link opened from outside the app (Finder, Messages, AirDrop): Add a Mac opens with it filled in, then clears it.
    var incomingLink: String?
    /// Add a Mac, over SSH: what was typed, and how finding the Mac went.
    var sshTarget = ""
    var ssh: SSHState = .idle
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
    /// Asks the Mac `user@host` over ssh where its Shepherd listens (`FleetSSHFinder`); a fixture in tests.
    @ObservationIgnored var sshFind: (String) async throws -> FleetWhere = { try await FleetSSHFinder().find($0) }
    /// This app's link scheme, and the time a link's expiry is read against.
    @ObservationIgnored var linkScheme = FleetPairingLink.currentScheme
    @ObservationIgnored var now: () -> Date = Date.init
    /// Starts finding Macs; the answer stops it. Replaced by a fixture in tests.
    @ObservationIgnored var browse: @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void = { _ in {} }
    /// Every snapshot the host answered with, for the Fleet page (`FleetPageModel`).
    @ObservationIgnored var onSnapshot: ((FleetSnapshot) -> Void)?
    /// The Fleet page is on screen: the host is told again when its connection is made anew.
    @ObservationIgnored private(set) var wantsWatch = false
    @ObservationIgnored private var stopBrowsing: (() -> Void)?
    @ObservationIgnored private var everyFound: [FoundMac] = []
    @ObservationIgnored private var joinBaseline: Set<UUID> = []
    @ObservationIgnored private var deviceBaseline: Set<UUID> = []

    init() {}

    // MARK: Reading

    /// Reads the host's fleet again. A host that is away leaves what was shown, and says so once there is nothing.
    func refresh() async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetRead())
            findsByCode = client.capabilities.contains(RemoteProtocol.fleetRendezvousCapability)
            findsByLink = client.capabilities.contains(RemoteProtocol.fleetPairLinkCapability)
            problem = nil
        } catch {
            if !loaded { problem = Self.words(error) }
        }
    }

    func apply(_ result: FleetResult) {
        if result.snapshot != snapshot {
            snapshot = result.snapshot
            rows = result.snapshot.enabled ? FleetMacRow.rows(of: result.snapshot) : []
            let devices = FleetDeviceRow.rows(of: result.snapshot)
            if devices != deviceRows { deviceRows = devices }
            syncLine = result.snapshot.sync.flatMap(FleetSyncPresentation.line)
        }
        loaded = result.snapshot.enabled
        onSnapshot?(result.snapshot)
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
        linkText = ""
        link = nil
        linkProblem = nil
        sshTarget = ""
        ssh = .idle
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

    /// Enters `code` with no Mac picked: the host asks this person's iCloud where a Mac showed that code, then pairs over the
    /// routes it finds. The code is still the only proof. True when it paired.
    func pairByCode(_ code: String) async -> Bool {
        pairing = .working
        do {
            guard let client = try host() else { pairing = .failed("Shepherd's background service isn't answering."); return false }
            apply(try await client.fleetAction(.findAndPair(code: code)))
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

    // MARK: The Fleet page

    /// Tells the host the Fleet page is on screen: it samples this Mac and pushes each sample
    /// while it says so, and stops when this connection closes.
    func watch(_ on: Bool) async {
        wantsWatch = on
        guard let client = try? host(), let result = try? await client.fleetAction(.watching(on)) else { return }
        apply(result)
    }

    /// Retry on a Mac that isn't answering: the host tries its link again now.
    func reconnect(_ hostID: UUID) async {
        guard let client = try? host(), let result = try? await client.fleetAction(.reconnect(hostID: hostID)) else { return }
        apply(result)
    }

    // MARK: Dispatches

    /// Starts the thread the person wrote in New thread on the Mac Auto (or `thread.host`) picks. The record it made, or nil when the work
    /// stays on this Mac and the caller starts it as it always did. Throws the host's reason when it can't go.
    func sendThread(_ thread: FleetUserThread) async throws -> FleetDispatchRecord? {
        guard let client = try host() else { throw RemoteHostClientError.disconnected }
        let result = try await client.fleetAction(.sendThread(thread))
        apply(result)
        return result.dispatch
    }

    /// Sends a dispatch that waits, is held or wasn't sent: to `target` (this Mac's id included), else as it was asked.
    func retryDispatch(_ id: UUID, host target: UUID?) async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetAction(.retryDispatch(id: id, host: target)))
            problem = nil
        } catch {
            problem = Self.words(error)
        }
    }

    /// Stops a dispatch this Mac sent, and its thread on the other Mac.
    func cancelDispatch(_ id: UUID) async {
        do {
            guard let client = try host() else { return }
            apply(try await client.fleetAction(.cancelDispatch(id: id)))
        } catch {
            problem = Self.words(error)
        }
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
