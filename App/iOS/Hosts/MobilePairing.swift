import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote

/// Add a Mac on a phone or iPad: the Macs Bonjour finds, the code one of them shows (Settings ▸ Fleet ▸
/// Add a device) typed or scanned from its QR, and the pairing itself (`MobileHosts.pair`). Nothing
/// else is entered: no address, no token.
@MainActor
@Observable
final class MobilePairing {
    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
        /// Paired: the names of the Macs now on this device.
        case paired([String])
    }

    /// The Macs found on this network that this device isn't already paired with.
    private(set) var found: [FoundMac] = []
    var picked: String?
    var code = "" {
        didSet {
            let digits = String(code.filter(\.isNumber).prefix(FleetProtocol.codeLength))
            if digits != code { code = digits }
        }
    }
    private(set) var phase: Phase = .idle

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let browse: @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void
    @ObservationIgnored private var stopBrowsing: (() -> Void)?
    @ObservationIgnored private var every: [FoundMac] = []
    /// A scanned QR named this Mac (`FleetProtocol.advertisedIDHash`): pairing checks it answers.
    @ObservationIgnored private var expecting: String?

    init(hosts: MobileHosts, browse: @escaping @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void = MobilePairing.bonjour) {
        self.hosts = hosts
        self.browse = browse
    }

    /// Finds Macs by Bonjour (`FleetBrowser`) until `stop`.
    static func bonjour(_ update: @escaping @Sendable ([FoundMac]) -> Void) -> () -> Void {
        let browser = FleetBrowser()
        browser.start(update)
        return { Task { @MainActor in browser.stop() } }
    }

    func start() {
        stopBrowsing?()
        stopBrowsing = browse { [weak self] macs in
            Task { @MainActor in
                self?.every = macs
                self?.filter()
            }
        }
    }

    func stop() {
        stopBrowsing?()
        stopBrowsing = nil
        every = []
        found = []
    }

    /// Macs this device already holds (same address and port) aren't offered again.
    private func filter() {
        let held = Set(hosts.hosts.map { "\($0.record.address):\($0.record.port)" })
        let shown = every.filter { mac in mac.address.map { !held.contains("\($0):\(mac.port ?? 0)") } ?? true }
        if shown != found { found = shown }
        if let picked, !shown.contains(where: { $0.id == picked }) { self.picked = nil }
    }

    /// The Mac the code will go to: the one chosen, or the only one found.
    var mac: FoundMac? { found.first { $0.id == picked } ?? (found.count == 1 ? found.first : nil) }

    var ready: Bool { mac != nil && code.count == FleetProtocol.codeLength && phase != .working }

    /// A scanned QR: its code is entered and the Mac it names is chosen. False for any other QR.
    @discardableResult
    func take(scanned text: String) -> Bool {
        guard let link = FleetProtocol.parsePairLink(text) else { return false }
        code = link.code
        expecting = link.advertisedID
        if let named = found.first(where: { $0.idHash == link.advertisedID }) { picked = named.id }
        return true
    }

    func pair() async {
        guard let mac, let address = mac.address, let port = mac.port, ready else { return }
        phase = .working
        do {
            let ids = try await hosts.pair(address: address, port: port, code: code, expecting: expecting)
            phase = .paired(ids.compactMap { hosts.host($0)?.name })
            code = ""
        } catch {
            phase = .failed(Self.words(error))
        }
    }

    /// A refusal's own sentence (a Mac writes them for people), or why nothing answered.
    static func words(_ error: Error) -> String {
        guard let error = error as? RemoteHostClientError else { return "Couldn't pair. Try again." }
        switch error {
        case .rejected(_, let message): return message
        case .timeout, .disconnected, .resolveFailed, .system:
            return "Couldn't reach that Mac. Check that Shepherd is open on it and that it is on this network."
        case .outcomeUnknown(let message): return message
        }
    }
}
