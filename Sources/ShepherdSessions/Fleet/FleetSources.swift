import Foundation
import ShepherdProtocol

/// `instruction:AGENTS.md` and `instruction:APPEND_SYSTEM.md`: Shepherd's root instructions,
/// written through `InstructionsStore` so each synced copy lands in its history ("Synced from
/// Mac mini") like any other save.
final class FleetInstructionsSource: FleetUnitSource {
    private let store: InstructionsStore
    let units = InstructionFile.allCases.map(FleetUnit.instruction)

    init(_ store: InstructionsStore) { self.store = store }

    private func file(_ unit: String) -> InstructionFile? {
        FleetUnit.name(of: unit).flatMap(InstructionFile.init(rawValue:))
    }

    func storesBlob(_ unit: String) -> Bool { true }
    var watchedFiles: [URL] { InstructionFile.allCases.map { store.directory.appendingPathComponent($0.fileName) } }

    func read() -> [String: Data] {
        Dictionary(uniqueKeysWithValues: InstructionFile.allCases.map { (FleetUnit.instruction($0), Data(store.content($0).utf8)) })
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        !String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard let file = file(unit) else { return }
        try store.save(file, content: value.map { String(decoding: $0, as: UTF8.self) } ?? "", origin: origin, sync: true)
    }
}

/// `setting:pi.<key>`: the keys of pi's own `settings.json` that are a person's preferences. pi
/// writes this file too, and Shepherd writes its own keys in it (`shellCommandPrefix`, the
/// resource lists, compaction overrides), so a unit is one top level key, applied under pi's
/// lock with every other key left as it is, and pi's rewrites are read back as ops.
final class FleetPiSettingsSource: FleetUnitSource {
    /// What syncs. Left out on purpose: what Shepherd manages (`shellCommandPrefix`, `skills`,
    /// `extensions`, `packages`, `cacheWarming`, `compaction`) and what is about this Mac (`shellPath`,
    /// `externalEditor`, `sessionDir`, `httpProxy`, `npmCommand`, `terminal`).
    static let keys = [
        "defaultProvider", "defaultModel", "defaultThinkingLevel", "modelThinkingLevels", "thinkingBudgets", "enabledModels",
        "hideThinkingBlock", "showCacheMissNotices", "steeringMode", "followUpMode", "theme", "quietStartup", "transport",
        "retry", "images", "markdown",
    ]

    private let file: PiSettingsFile
    let units = keys.map { FleetUnit.setting("pi." + $0) }

    init(settings: URL) {
        // A write waits briefly for pi's lock; one that can't try again at the next change.
        file = PiSettingsFile(url: settings, patience: 1)
    }

    private func key(_ unit: String) -> String? {
        guard let name = FleetUnit.name(of: unit), name.hasPrefix("pi.") else { return nil }
        let key = String(name.dropFirst(3))
        return Self.keys.contains(key) ? key : nil
    }

    func storesBlob(_ unit: String) -> Bool { false }
    var watchedFiles: [URL] { [file.url] }

    func read() -> [String: Data] {
        guard let data = try? Data(contentsOf: file.url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var values: [String: Data] = [:]
        for key in Self.keys {
            guard let value = object[key], let json = Self.canonical(value) else { continue }
            values[FleetUnit.setting("pi." + key)] = json
        }
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard let key = key(unit) else { return }
        let parsed = try value.map { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        _ = try file.update { settings in
            if let parsed { settings[key] = parsed } else { settings.removeValue(forKey: key) }
            return []
        }
    }

    /// One JSON text for a value, the same on every Mac (sorted keys).
    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

/// `setting:host.<key>`: the host settings that are the same on every Mac (`FleetHostSetting`).
/// The values live in the app's preferences, which the app owns: the app tells the host what they
/// are (`update`), and a synced value is applied by the app's own setting code (`apply`), so the
/// switch, the pi files and the running agents follow exactly as if it was changed on this Mac.
final class FleetHostSettingsSource: FleetUnitSource {
    private var settings: HostSettings?
    private let apply: @Sendable (HostSettingChange) -> Void
    let units = FleetHostSetting.allCases.map(\.unit)

    init(apply: @escaping @Sendable (HostSettingChange) -> Void) { self.apply = apply }

    /// The settings as the app has them now; nil is no report yet.
    func update(_ settings: HostSettings) { self.settings = settings }

    var isReady: Bool { settings != nil }
    var writesAsynchronously: Bool { true }

    func storesBlob(_ unit: String) -> Bool { false }

    func read() -> [String: Data] {
        guard let settings else { return [:] }
        return FleetHostSetting.values(in: settings).mapValues { Data($0.utf8) }
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        guard let settings, let setting = FleetHostSetting.named(unit: unit) else { return false }
        return !setting.isDefault(in: settings)
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard let value else { return }
        guard let setting = FleetHostSetting.named(unit: unit),
              let change = setting.change(fromJSON: String(decoding: value, as: UTF8.self)) else {
            throw FleetUnitRefused(description: "\(unit) holds a value this version doesn't know")
        }
        apply(change)
    }
}
