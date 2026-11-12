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
}

/// A source can't take a value (one this build doesn't understand): it keeps what it has and the
/// materializer doesn't try again.
struct FleetUnitRefused: Error, CustomStringConvertible {
    var description: String
}

extension FleetUnitSource {
    var isReady: Bool { true }
    var watchedFiles: [URL] { [] }
    var writesAsynchronously: Bool { false }
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
    /// unit → what an asynchronous write will leave, until it lands or `pendingPatience` passes.
    private var pending: [String: (hash: String, deadline: Date)] = [:]

    /// How long a scan waits for an asynchronous write to show.
    static let pendingPatience: TimeInterval = 10

    init(store: FleetStore, directory: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.url = directory.appendingPathComponent("observed.json")
        self.clock = clock
        observed = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func add(_ source: FleetUnitSource) { sources.append(source) }

    var watchedFiles: [URL] { sources.flatMap(\.watchedFiles) }

    private func source(for unit: String) -> FleetUnitSource? { sources.first { $0.units.contains(unit) } }

    static func fingerprint(_ value: Data?) -> String { value.map { FleetSyncProtocol.hash($0) } ?? "-" }

    // MARK: Local to store

    /// Appends an op for every unit whose value here differs from what the materializer last saw,
    /// and returns them. The first time a unit is seen with a value worth sharing, the op is a seed.
    @discardableResult
    func scan(name: String) -> [FleetOp] {
        var emitted: [FleetOp] = []
        var changed = false
        for source in sources where source.isReady {
            let present = source.read()
            for unit in source.units {
                let value = present[unit]
                let hash = Self.fingerprint(value)
                if let waiting = pending[unit] {
                    if waiting.hash == hash || clock() >= waiting.deadline { pending[unit] = nil } else { continue }
                }
                let seen = observed[unit]
                guard seen != hash else { continue }
                observed[unit] = hash
                changed = true
                // What the fleet already holds there needs no op.
                if let winner = store.winner(of: unit), Self.matches(winner.change, value, store: store) { continue }
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

    private static func matches(_ change: FleetChange, _ value: Data?, store: FleetStore) -> Bool {
        switch (change, value) {
        case (.deletion, nil): return true
        case (.value(let text), let value?): return Data(text.utf8) == value
        case (.blob(let hash, _), let value?): return FleetSyncProtocol.hash(value) == hash
        default: return false
        }
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
            let present = source.read()
            for unit in source.units {
                guard let winner = store.winner(of: unit), winner.mac != store.mac || observed[unit] != nil else { continue }
                let target: Data?
                switch winner.change {
                case .deletion: target = nil
                case .value(let text): target = Data(text.utf8)
                case .blob(let hash, _):
                    guard let data = store.blob(hash) else { continue }
                    target = data
                }
                let current = present[unit]
                guard Self.fingerprint(current) != Self.fingerprint(target) else {
                    if observed[unit] != Self.fingerprint(current) { observed[unit] = Self.fingerprint(current); changed = true }
                    continue
                }
                // A local edit not scanned yet must be an op before it is overwritten.
                if let current, observed[unit] != Self.fingerprint(current) { continue }
                // A divergent copy this Mac only seeded, replaced by another's: the sync line says so. A copy
                // the fleet already held (it made the same seed) replaced nothing.
                let replacedSeed = current.map { copy in
                    store.lastOwnOp(of: unit)?.seed == true && winner.mac != store.mac && !store.otherMacsHeld(copy, in: unit)
                } ?? false
                // Set before writing: the write may call back into a scan.
                observed[unit] = Self.fingerprint(target)
                if source.writesAsynchronously { pending[unit] = (Self.fingerprint(target), clock().addingTimeInterval(Self.pendingPatience)) }
                do {
                    try source.write(unit, target, origin: winner.macName.isEmpty ? "another Mac" : winner.macName)
                    changed = true
                    if replacedSeed { notices.append(Notice(unit: unit, from: winner.macName)) }
                } catch {
                    ShepherdLog.warning("fleet: couldn't write \(unit): \(error)")
                    observed[unit] = Self.fingerprint(current)
                    pending[unit] = nil
                    if !(error is FleetUnitRefused) { failed = true }
                }
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
