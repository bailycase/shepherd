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
    var phase: Phase = .idle
    /// A pairing link (opened from Messages or AirDrop, or pasted): the text in its field, the Mac and code it names, and why it can't be used.
    var linkText = ""
    private(set) var link: FleetPairingLink?
    private(set) var linkProblem: String?

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let browse: @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void
    @ObservationIgnored private var stopBrowsing: (() -> Void)?
    @ObservationIgnored private var every: [FoundMac] = []
    /// A scanned QR named this Mac (`FleetProtocol.advertisedIDHash`): pairing checks it answers.
    @ObservationIgnored private var expecting: String?

    /// Where Macs are found: Bonjour. The simulator fixtures (no network to browse) replace it.
    @MainActor static var source: @MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void = MobilePairing.bonjour

    /// Called with each new model: the simulator fixtures use it to show a state (a code half entered, a refusal).
    @MainActor static var seed: (MobilePairing) -> Void = { _ in }

    init(hosts: MobileHosts, browse: (@MainActor (@escaping @Sendable ([FoundMac]) -> Void) -> () -> Void)? = nil) {
        self.hosts = hosts
        self.browse = browse ?? Self.source
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
        link = nil
        linkText = ""
        linkProblem = nil
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

    var ready: Bool { (link != nil || mac != nil) && code.count == FleetProtocol.codeLength && phase != .working }

    /// The Mac's name for "Add …": the link's, else the one chosen.
    var macName: String? { link?.name ?? mac?.name }

    /// A link opened from outside the app fills in the link field.
    func takeIncomingLink() {
        guard let text = hosts.incomingPairingLink else { return }
        hosts.incomingPairingLink = nil
        read(link: text)
    }

    /// Reads the text of the link field. A pairing link for a device (Add a device on a Mac) of any edition names the Mac and its code;
    /// anything else says why it can't be used.
    func read(link text: String) {
        linkText = text
        link = nil
        linkProblem = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch FleetPairingLink.readAnyEdition(text) {
        case .link(let read):
            if read.isExpired(at: Date()) {
                linkProblem = "That link has expired. Open Add a device on the Mac for a new one."
            } else if read.purpose == .join {
                linkProblem = "That link adds a Mac to a fleet. On this device, use the link under Add a device on the Mac."
            } else {
                link = read
                code = read.code
                picked = nil
            }
        case .malformed: linkProblem = "That isn't a pairing link Shepherd can read. Ask the Mac for a new one."
        case .otherEdition, .notALink: linkProblem = "That isn't a pairing link. It starts with shepherd://fleet/join."
        }
    }

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
        guard ready else { return }
        phase = .working
        do {
            let ids: [UUID]
            if let link {
                ids = try await pair(over: link)
            } else if let mac, let address = mac.address, let port = mac.port {
                ids = try await hosts.pair(address: address, port: port, code: code, expecting: expecting)
            } else {
                phase = .idle
                return
            }
            phase = .paired(ids.compactMap { hosts.host($0)?.name })
            code = ""
            link = nil
            linkText = ""
        } catch {
            phase = .failed(Self.words(error))
        }
    }

    /// Pairs over the first of the link's routes that answers as the Mac it names (checked before the code is sent). A Mac that answers
    /// and says no (a wrong code, an expired one) ends it: another route says the same.
    private func pair(over link: FleetPairingLink) async throws -> [UUID] {
        var failure: Error = RemoteHostClientError.timeout
        for route in link.routes {
            do {
                return try await hosts.pair(address: route.host, port: link.port, code: code, expectingID: link.hostID)
            } catch RemoteHostClientError.rejected(let reason, let message) where reason != FleetProtocol.Code.wrongHost {
                throw RemoteHostClientError.rejected(code: reason, message: message)
            } catch {
                failure = error
            }
        }
        throw failure
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
