import CryptoKit
import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Finding a Mac through the person's own iCloud, with no server of Shepherd's.
///
/// Two kinds of record sit in the signed-in user's CloudKit **private** database, every field end to end encrypted
/// (`encryptedValues`):
///
/// - **Join**: written while a Mac shows a join code (Settings ▸ Fleet ▸ Join a fleet), keyed by a hash of the code, so
///   the code itself is never stored. It says where that Mac listens. A Mac that types the code fetches it by key and
///   pairs over the routes it names with the ordinary code-checked handshake (`fleetPair`). The record only says *where*:
///   a record whose code then doesn't verify pairs nothing.
/// - **Presence**: one per paired Mac, keyed by its host id, its routes and when they changed. A peer whose known routes
///   all fail reads it and reconnects without pairing again. Nothing but routes goes through iCloud.
///
/// iCloud is the optional layer. No account, another Apple ID, a CloudKit error or a build without the container
/// entitlement all end as "not available": logged once, nothing shown broken, and Bonjour, pairing links and the routes
/// already known go on as they did.
struct FleetRendezvousKey: Hashable, Sendable {
    enum Kind: String, Sendable {
        /// CloudKit record types (`scripts/fleet-rendezvous.ckdb`).
        case join = "FleetJoin", presence = "FleetPresence"
    }

    var kind: Kind
    var name: String

    /// The Join record of a code. HKDF over the code with a fixed salt, so the name says nothing a reader can use
    /// without already knowing the code, and the same code on any Mac gives the same name.
    static func join(code: String) -> FleetRendezvousKey {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(FleetJoinWindow.normalized(code).utf8)),
                                         salt: Data("shepherd.fleet.rendezvous.v1".utf8), info: Data("join".utf8), outputByteCount: 32)
        return FleetRendezvousKey(kind: .join, name: "join-" + key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() })
    }

    static func presence(of hostID: UUID) -> FleetRendezvousKey {
        FleetRendezvousKey(kind: .presence, name: "presence-" + hostID.uuidString.lowercased())
    }
}

/// What a record holds, whichever its kind. A presence record has no name, port or expiry.
struct FleetRendezvousRecord: Equatable, Sendable {
    var key: FleetRendezvousKey
    var hostID: UUID
    var name: String = ""
    /// The Mac's listener port; every route also carries its own.
    var port: UInt16 = 0
    /// Every route it has, most useful first, with each one's kind and whether it was learned (a record an older build wrote holds
    /// bare addresses, which read as given routes of the kind their form says).
    var routes: [FleetRoute]
    var build: String?
    /// Epoch milliseconds the code stops working (Join only).
    var expiresAt: Double?
    /// Epoch milliseconds the record was written.
    var updatedAt: Double

    func isExpired(at now: Date) -> Bool {
        expiresAt.map { now.timeIntervalSince1970 * 1000 >= $0 } ?? false
    }
}

enum FleetRendezvousError: Error, Equatable, Sendable {
    /// No iCloud account is signed in on this Mac.
    case noAccount
    /// iCloud can't be used now: no container entitlement, another account state, the network, or CloudKit said no.
    case unavailable
}

/// Put, fetch and delete by record id: all `FleetRendezvous` needs of CloudKit, so tests stand a dictionary in for it.
/// `fetch` answers nil for a record that isn't there; every other failure throws (`FleetRendezvousError` or any error,
/// which counts as unavailable).
protocol FleetRendezvousStore: Sendable {
    func put(_ record: FleetRendezvousRecord) async throws
    func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord?
    func delete(_ key: FleetRendezvousKey) async throws
}

/// The store of a build that can't reach iCloud (no entitlement): every call says unavailable.
struct UnavailableFleetRendezvousStore: FleetRendezvousStore {
    func put(_ record: FleetRendezvousRecord) async throws { throw FleetRendezvousError.unavailable }
    func fetch(_ key: FleetRendezvousKey) async throws -> FleetRendezvousRecord? { throw FleetRendezvousError.unavailable }
    func delete(_ key: FleetRendezvousKey) async throws { throw FleetRendezvousError.unavailable }
}

/// What a code found.
enum FleetRendezvousLookup: Equatable, Sendable {
    case found(FleetRendezvousRecord)
    case notFound
    case unavailable(FleetRendezvousError)
}

/// Writes and reads the records for `FleetService`. Writes (put, delete) run one after another in the order they were
/// asked, so a Join record that is retracted straight after it was written can't outlive its delete. A failure is
/// logged once for the process and then ignored: iCloud is never required.
final class FleetRendezvous: @unchecked Sendable {
    let store: FleetRendezvousStore
    private let lock = NSLock()
    private var tail: Task<Void, Never>?
    private var logged = false
    /// Times a failure was said to the log: one at most (tests).
    private(set) var warnings = 0

    init(store: FleetRendezvousStore) {
        self.store = store
    }

    // MARK: Writing

    func put(_ record: FleetRendezvousRecord) { enqueue { [store, self] in
        do { try await store.put(record) } catch { self.failed(error) }
    } }

    func delete(_ key: FleetRendezvousKey) { enqueue { [store, self] in
        do { try await store.delete(key) } catch { self.failed(error) }
    } }

    /// Returns once every write asked so far has finished (tests).
    func settle() async {
        let last = lock.withLock { tail }
        await last?.value
    }

    private func enqueue(_ write: @escaping @Sendable () async -> Void) {
        lock.withLock {
            let previous = tail
            tail = Task { await previous?.value; await write() }
        }
    }

    // MARK: Reading

    /// The Join record of `code`. One that has expired counts as not found and is deleted, so a record a crashed Mac left
    /// behind doesn't stay.
    func lookupJoin(code: String, now: Date = Date()) async -> FleetRendezvousLookup {
        let key = FleetRendezvousKey.join(code: code)
        do {
            guard let record = try await store.fetch(key) else { return .notFound }
            guard !record.isExpired(at: now) else {
                delete(key)
                return .notFound
            }
            return .found(record)
        } catch {
            return .unavailable(failed(error))
        }
    }

    /// Where the Mac `hostID` says it is, or nil: it never said, or iCloud isn't available.
    func lookupPresence(of hostID: UUID) async -> FleetRendezvousRecord? {
        do { return try await store.fetch(.presence(of: hostID)) } catch {
            failed(error)
            return nil
        }
    }

    /// Notes a failure: said once to the unified log, whatever it was, and returned as the reason a person is told.
    @discardableResult
    private func failed(_ error: Error) -> FleetRendezvousError {
        let reason = (error as? FleetRendezvousError) ?? .unavailable
        let first = lock.withLock { () -> Bool in
            defer { logged = true }
            if !logged { warnings += 1 }
            return !logged
        }
        if first {
            ShepherdLog.warning("fleet: iCloud isn't available for finding Macs (\(reason == .noAccount ? "no account" : "\(error)")); pairing links, Bonjour and the known routes still work")
        }
        return reason
    }
}
