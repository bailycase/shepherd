import Foundation
import ShepherdProtocol
import ShepherdRemote

/// A kind of unit this Mac holds as real state (a file, a setting) and the materializer reads and
/// writes through the code that already owns it. A source never sees the store.
protocol FleetUnitSource: AnyObject {
    /// Every unit this source can read and write.
    var units: [String] { get }
    /// Whether it can be read now (a source fed by the app is not, until the app reports).
    var isReady: Bool { get }
    /// The files behind the units, which the watcher keeps an eye on (none for a source the app feeds).
    var watchedFiles: [URL] { get }
    /// Files the watcher keeps an eye on alone, without their folders (a git config).
    var watchedFilesOnly: [URL] { get }
    /// Whether a unit travels as content by hash (a file) rather than inline (a setting's JSON).
    func storesBlob(_ unit: String) -> Bool
    /// The units that hold a value here now, with it. A unit absent from the answer is unset.
    func read() -> [String: Data]
    /// Whether a value is worth seeding the fleet with: not empty, not the default. A Mac that
    /// never chose a setting must not outvote one that did.
    func isSeedable(_ unit: String, _ value: Data) -> Bool
    /// Writes a unit (nil: unset), through the owner of the real state. `origin` names the Mac
    /// whose write this is. Never write around the owner.
    func write(_ unit: String, _ value: Data?, origin: String) throws
    /// The write lands later (the app applies it on the main actor): a scan before then must not
    /// take the old value for a local edit.
    var writesAsynchronously: Bool { get }

    // Sources whose units come and go (a skill's files, an extension's): additive, with defaults.

    /// Whether `unit` is this source's, beyond the ones `units` lists: a source of many files owns
    /// every name of its kind, and `units` is then empty.
    func owns(_ unit: String) -> Bool
    /// Folders whose whole tree the watcher keeps an eye on (a save of any file in them).
    var watchedTrees: [URL] { get }
    /// What each unit holds here now, as the hash of its content (a unit that is absent is left
    /// out). A source of many or large files answers from a cache of what it already hashed, so
    /// nothing is read again that did not change.
    func fingerprints() -> [String: String]
    /// One unit's content now, asked only for a unit whose hash changed.
    func value(of unit: String) -> Data?
    /// Called before each scan: a source that mirrors a folder outside the store makes its copy current.
    func prepare()
    /// What the fleet holds for a unit now (nil: unset or its content isn't here yet), for a write
    /// that depends on another unit (where a skill's file goes depends on the skill's state).
    func attach(fleetValue: @escaping (String) -> Data?)
    /// The units whose name starts with a prefix that the fleet holds, each with the hash its winner
    /// leaves ("-" for a deletion), so a source can tell a tree is mid sync (some file's winner is not
    /// what is on disk yet) and keep a unit that describes the tree from being read as a local edit.
    func attach(fleetWinners: @escaping (String) -> [String: String])
    /// Whether its units are sign-ins, which only Macs of the fleet ever hold, and which a Mac about to
    /// start pi reads first (`FleetSync.catchUpCredentials`).
    var isCredential: Bool { get }
}

/// A source can't take a value (one this build doesn't understand): it keeps what it has and the
/// materializer doesn't try again.
struct FleetUnitRefused: Error, CustomStringConvertible {
    var description: String
    /// Expected and steady (a synced space with no folder here yet): not worth a log line at every pass.
    var quiet = false
}

/// A unit can't be written until another is (a skill's state needs the skill's files): the
/// materializer tries it again once the rest of the pass has written.
struct FleetUnitWaiting: Error, CustomStringConvertible {
    var description: String
}

extension FleetUnitSource {
    var isReady: Bool { true }
    var watchedFiles: [URL] { [] }
    var watchedFilesOnly: [URL] { [] }
    var writesAsynchronously: Bool { false }
    func owns(_ unit: String) -> Bool { units.contains(unit) }
    var watchedTrees: [URL] { [] }
    func fingerprints() -> [String: String] { read().mapValues { FleetSyncProtocol.hash($0) } }
    func value(of unit: String) -> Data? { read()[unit] }
    func prepare() {}
    func attach(fleetValue: @escaping (String) -> Data?) {}
    func attach(fleetWinners: @escaping (String) -> [String: String]) {}
    var isCredential: Bool { false }
}

/// Keeps this Mac's real state and the store the same, in both directions (docs: Sync engine).
///
/// `scan` finds what changed here since the materializer last looked (a person's edit, pi's own
/// rewrite of `settings.json`, a hand edit of a file) and returns it as ops to append. `materialize`
/// writes what the store decided onto this Mac, through the sources. What it wrote it also
/// remembers, by hash, so its own writes never come back as ops. Server queue only.
final class FleetMaterializer {
    struct Notice: Equatable {
        var unit: String
        /// The Mac whose copy replaced this Mac's.
        var from: String
    }

    private let store: FleetStore
    private let url: URL
    private let clock: @Sendable () -> Date
    private var sources: [FleetUnitSource] = []
    /// unit → hash of the value this Mac last held there that the store knows about ("-" unset).
    private var observed: [String: String]
    /// unit → an asynchronous write in flight: what it will leave, what was there, and when to stop waiting.
    private var pending: [String: (hash: String, previous: String, deadline: Date)] = [:]

    /// How long a scan waits for an asynchronous write to show.
    static let pendingPatience: TimeInterval = 10

    init(store: FleetStore, directory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.url = directory.appendingPathComponent("observed.json")
        self.clock = clock
        observed = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func add(_ source: FleetUnitSource) {
        sources.append(source)
        let store = store
        source.attach { unit in
            switch store.winner(of: unit)?.change {
            case .value(let text)?: Data(text.utf8)
            case .blob(let hash, _)?: store.blob(hash)
            default: nil
            }
        }
        source.attach { prefix in
            var winners: [String: String] = [:]
            for unit in store.units where unit.hasPrefix(prefix) {
                if let winner = store.winner(of: unit) { winners[unit] = Self.hash(of: winner.change) }
            }
            return winners
        }
    }

    var watchedFiles: [URL] { sources.flatMap(\.watchedFiles) }
    var watchedFilesOnly: [URL] { sources.flatMap(\.watchedFilesOnly) }
    var watchedTrees: [URL] { sources.flatMap(\.watchedTrees) }

    static func fingerprint(_ value: Data?) -> String { value.map { FleetSyncProtocol.hash($0) } ?? "-" }

    /// What a winning op leaves a unit holding, as the hash a read of it gives ("-" unset).
    private static func hash(of change: FleetChange) -> String {
        switch change {
        case .deletion: "-"
        case .value(let text): FleetSyncProtocol.hash(Data(text.utf8))
        case .blob(let hash, _): hash
        }
    }

    /// Every unit of `source` worth looking at: the ones it lists, the ones it holds, and the ones
    /// the fleet or this Mac's record names that are its own (a file the store has and this Mac
    /// doesn't, or one that is gone), in a stable order.
    private func units(of source: FleetUnitSource, holding present: [String: String]) -> [String] {
        var visit = Set(source.units)
        visit.formUnion(present.keys)
        visit.formUnion(store.units.filter(source.owns))
        visit.formUnion(observed.keys.filter(source.owns))
        return visit.sorted()
    }

    // MARK: Local to store

    /// Appends an op for every unit whose value here differs from what the materializer last saw,
    /// and returns them. The first time a unit is seen with a value worth sharing, the op is a seed.
    @discardableResult
    func scan(name: String, credentialsOnly: Bool = false) -> [FleetOp] {
        var emitted: [FleetOp] = []
        var changed = false
        for source in sources where source.isReady && (!credentialsOnly || source.isCredential) {
            source.prepare()
            let present = source.fingerprints()
            for unit in units(of: source, holding: present) {
                let hash = present[unit] ?? "-"
                if let waiting = pending[unit] {
                    if waiting.hash == hash {
                        pending[unit] = nil
                    } else if hash == waiting.previous {
                        // Still the old value: the write hasn't landed. Past the deadline it never will (the app
                        // refused it): leave the unit as it was, and the next pass writes again.
                        if clock() >= waiting.deadline { pending[unit] = nil; observed[unit] = hash; changed = true }
                        continue
                    } else {
                        // Neither: a person changed it meanwhile, and that is an edit like any other.
                        pending[unit] = nil
                    }
                }
                let seen = observed[unit]
                guard seen != hash else { continue }
                observed[unit] = hash
                changed = true
                // What the fleet already holds there needs no op.
                if let winner = store.winner(of: unit), Self.hash(of: winner.change) == hash { continue }
                let value = hash == "-" ? nil : source.value(of: unit)
                // It changed again between the two reads: the next scan sees it.
                if hash != "-", value == nil { observed[unit] = seen; continue }
                if seen == nil {
                    // First sight of this unit on this Mac: only a value worth sharing becomes a seed.
                    guard let value, source.isSeedable(unit, value) else { continue }
                    if let op = emit(unit, value, source: source, seed: true, name: name) { emitted.append(op) }
                } else if let op = emit(unit, value, source: source, seed: false, name: name) {
                    emitted.append(op)
                }
            }
        }
        if changed { save() }
        return emitted
    }

    private func emit(_ unit: String, _ value: Data?, source: FleetUnitSource, seed: Bool, name: String) -> FleetOp? {
        let change: FleetChange
        if let value {
            if source.storesBlob(unit) {
                guard let hash = store.putBlob(value) else { return nil }
                change = .blob(hash: hash, size: value.count)
            } else {
                guard value.count <= FleetSyncProtocol.maxInlineValueBytes else { return nil }
                change = .value(String(decoding: value, as: UTF8.self))
            }
        } else {
            change = .deletion
        }
        return store.appendLocal(unit: unit, change: change, seed: seed, name: name)
    }

    // MARK: Store to local

    /// Writes every unit the store decided differently from what is here. A unit whose blob hasn't
    /// arrived waits. Returns what replaced a copy this Mac had only seeded (the sync line's
    /// notice) and whether any write failed (to try again).
    func materialize(name: String) -> (notices: [Notice], failed: Bool) {
        var notices: [Notice] = []
        var failed = false
        var changed = false
        for source in sources where source.isReady {
            var present = source.fingerprints()
            /// Units that must wait for another unit of the same pass (a skill's state, for its files).
            var waiting: [String] = []
            func apply(_ unit: String, retrying: Bool) {
                guard let winner = store.winner(of: unit), winner.mac != store.mac || observed[unit] != nil else { return }
                let wanted = Self.hash(of: winner.change)
                let current = present[unit] ?? "-"
                guard current != wanted else {
                    if observed[unit] != current { observed[unit] = current; changed = true }
                    return
                }
                // A local edit not scanned yet must be an op before it is overwritten.
                if current != "-", observed[unit] != current { return }
                let target: Data?
                switch winner.change {
                case .deletion: target = nil
                case .value(let text): target = Data(text.utf8)
                case .blob(let hash, _):
                    guard let data = store.blob(hash) else { return }
                    target = data
                }
                // A divergent copy this Mac only seeded, replaced by another's: the sync line says so. A copy
                // the fleet already held (it made the same seed) replaced nothing.
                let replacedSeed = current != "-"
                    && store.lastOwnOp(of: unit)?.seed == true && winner.mac != store.mac && !store.otherMacsHeld(hash: current, in: unit)
                // Set before writing: the write may call back into a scan.
                observed[unit] = wanted
                if source.writesAsynchronously {
                    pending[unit] = (wanted, current, clock().addingTimeInterval(Self.pendingPatience))
                }
                do {
                    try source.write(unit, target, origin: winner.macName.isEmpty ? "another Mac" : winner.macName)
                    changed = true
                    if replacedSeed { notices.append(Notice(unit: unit, from: winner.macName)) }
                } catch {
                    observed[unit] = current
                    pending[unit] = nil
                    if error is FleetUnitWaiting, !retrying {
                        waiting.append(unit)
                        return
                    }
                    if !((error as? FleetUnitRefused)?.quiet ?? false) { ShepherdLog.warning("fleet: couldn't write \(unit): \(error)") }
                    if !(error is FleetUnitRefused || error is FleetUnitWaiting) { failed = true }
                }
            }
            for unit in units(of: source, holding: present) { apply(unit, retrying: false) }
            if !waiting.isEmpty {
                present = source.fingerprints()
                for unit in waiting { apply(unit, retrying: true) }
            }
        }
        if changed { save() }
        return (notices, failed)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(observed) { FleetStore.write(data, to: url) }
    }
}
