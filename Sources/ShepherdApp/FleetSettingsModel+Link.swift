import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Add a Mac when Bonjour can't find it: a pairing link the other Mac shared, or a Mac found over SSH. Either one says *where* a
/// Mac is and which Mac it is (`PairTarget`); the code, typed or in the link, is still the only proof, checked by the same
/// handshake over a direct connection to that Mac after its id matches.
extension FleetSettingsModel {
    /// How finding a Mac over SSH went.
    enum SSHState: Equatable {
        case idle
        case finding
        case found(PairTarget)
        case failed(String)
    }

    /// A Mac a link or an SSH find named: who it is and where it listens, in the order to try.
    struct PairTarget: Equatable {
        var hostID: UUID
        var name: String
        var port: UInt16
        var routes: [FleetReportedRoute]
        /// Epoch milliseconds the code in a link stops working; nil for a Mac found over SSH, whose code is typed.
        var expiresAt: Double?
        /// "Shepherd Nightly 1.9", when the Mac said.
        var version: String?

        /// "192.168.20.14:7434": the route it prefers.
        var address: String { routes.first.map { "\($0.host):\(port)" } ?? "" }
    }

    /// The Mac the link or the SSH find names: what Add a Mac pairs with in place of a Mac Bonjour found.
    var target: PairTarget? {
        if let link {
            return PairTarget(hostID: link.hostID, name: link.name, port: link.port, routes: link.routes, expiresAt: link.expiresAt)
        }
        if case .found(let found) = ssh { return found }
        return nil
    }

    // MARK: Pairing links

    /// Reads the text of the link field. A link this app opens fills in the Mac and its code; any other says why it can't be used. A link that adds a device
    /// to a Mac is for an iPhone or iPad, so Add a Mac refuses it.
    func readLink(_ text: String) {
        linkText = text
        link = nil
        linkProblem = nil
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        switch FleetPairingLink.read(text, scheme: linkScheme) {
        case .link(let read):
            if read.isExpired(at: now()) {
                linkProblem = "That link has expired. Open Join a fleet on the other Mac for a new one."
            } else if read.hostID == snapshot.hostID {
                linkProblem = "That link is for this Mac."
            } else if read.purpose == .device {
                linkProblem = "That link adds a device to a Mac. To add a Mac to this fleet, use the link under Join a fleet on the other Mac."
            } else {
                link = read
            }
        case .otherEdition(let app):
            linkProblem = "That link is for \(app). This app opens \(FleetPairingLink.appName(ofScheme: linkScheme) ?? "Shepherd") links."
        case .malformed:
            linkProblem = "That isn't a pairing link Shepherd can read. Ask the other Mac for a new one."
        case .notALink:
            linkProblem = "That isn't a pairing link. It starts with \(linkScheme)://fleet/join."
        }
    }

    /// A link opened from outside the app: Add a Mac opens with it.
    func receive(link url: URL) { incomingLink = url.absoluteString }

    /// The link for `code` this Mac shows, to share or copy. Nil while the host hasn't said where this Mac listens.
    func pairingLink(for code: Join, purpose: FleetPairingLink.Purpose = .join) -> FleetPairingLink? {
        guard let hostID = snapshot.hostID, let port = snapshot.port, !snapshot.routes.isEmpty, !snapshot.name.isEmpty else { return nil }
        return FleetPairingLink(purpose: purpose, hostID: hostID, name: snapshot.name, port: port, routes: snapshot.routes,
                                code: code.code, expiresAt: (code.expiresAt.timeIntervalSince1970 * 1000).rounded())
    }

    // MARK: SSH

    var canFindOverSSH: Bool { FleetSSHFinder.isTarget(sshTarget.trimmingCharacters(in: .whitespaces)) && ssh != .finding }

    /// Asks the Mac `sshTarget` where its Shepherd listens. Finds only: nothing is paired and nothing is written there.
    func findOverSSH() async {
        let typed = sshTarget.trimmingCharacters(in: .whitespaces)
        guard FleetSSHFinder.isTarget(typed) else { ssh = .failed(FleetSSHFinder.Failure.badTarget.message); return }
        ssh = .finding
        do {
            let found = try await sshFind(typed)
            guard found.hostID != snapshot.hostID else { ssh = .failed("That is this Mac."); return }
            // What was typed after ssh reaches that Mac, so it is a route too, after the ones the Mac gave.
            var routes = found.routes
            if let host = FleetSSHFinder.host(of: typed), !routes.contains(where: { $0.host == host }) {
                routes.append(FleetReportedRoute(host: host, kind: .hostname))
            }
            ssh = .found(PairTarget(hostID: found.hostID, name: found.name, port: found.port, routes: routes, expiresAt: nil,
                                    version: [found.app, found.build].compactMap { $0 }.joined(separator: " ").nilIfEmpty))
        } catch let failure as FleetSSHFinder.Failure {
            ssh = .failed(failure.message)
        } catch {
            ssh = .failed("Couldn't ask that Mac over ssh.")
        }
    }

    // MARK: Pairing with a named Mac

    /// Enters `code` on the Mac the link or the SSH find named. The host tries each route in turn and
    /// sends the code only to a Mac that answers as the one named. True when it paired.
    func pair(at target: PairTarget, code: String) async -> Bool {
        pairing = .working
        do {
            guard let client = try host() else { pairing = .failed("Shepherd's background service isn't answering."); return false }
            guard findsByLink else {
                pairing = .failed("Shepherd's background service is older than this app. Quit and reopen Shepherd, then try again.")
                return false
            }
            apply(try await client.fleetAction(.pairAt(hostID: target.hostID, port: target.port, routes: target.routes, code: code,
                                                       expiresAt: target.expiresAt)))
            pairing = .idle
            return true
        } catch let error as RemoteHostClientError {
            if case .rejected(let reason, _) = error, reason != FleetProtocol.Code.unreachable {
                pairing = .failed(Self.words(error))
            } else {
                pairing = .failed("Couldn't reach \(target.name) at any address it gave. Check that the two Macs can reach each other: a VPN or Tailscale on both, or one network.")
            }
            return false
        } catch {
            pairing = .failed(Self.words(error))
            return false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
