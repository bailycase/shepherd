import Foundation
import ShepherdCore

/// The host settings that sync across a fleet, each as one unit `setting:host.<key>` whose value
/// is the setting as JSON. Hardware and per Mac facts stay out: Fleet itself (the kill switch),
/// the listener, versions, the slash command catalog. Experiments stay per Mac in this slice, and
/// so do the settings of skills, extensions, MCP, hooks and subagents, which move with their units.
public enum FleetHostSetting: String, CaseIterable, Sendable {
    case defaultModel, defaultThinking, defaultServiceTier, textGenerationModel, visionModel, compactAtPercent, queueDelivery
    case worktreeBase, fetchBeforeCreating, generatePRDescriptions, closeOnMerge, worktreeDeleteAction
    /// Fleet policy: the same on every Mac (`HostSettings.fleetThreadsCanSend`, `fleetThreadCap`, `fleetAutoDispatch`,
    /// `fleetBatteryCountsHalf`).
    case fleetThreadsCanSend, fleetThreadCap, fleetAutoDispatch, fleetBatteryCountsHalf, fleetUncommitted

    /// The unit's key: "host.defaultModel".
    public var key: String { "host." + rawValue }

    public var unit: String { FleetUnit.setting(key) }

    public static func named(unit: String) -> FleetHostSetting? {
        guard FleetUnit.kind(of: unit) == "setting", let name = FleetUnit.name(of: unit), name.hasPrefix("host.") else { return nil }
        return FleetHostSetting(rawValue: String(name.dropFirst("host.".count)))
    }

    /// The setting's value in `settings`, as the JSON text an op carries.
    public func json(in settings: HostSettings) -> String {
        switch self {
        case .defaultModel: Self.encode(settings.defaultModel)
        case .defaultThinking: Self.encode(settings.defaultThinking)
        case .defaultServiceTier: Self.encode(settings.defaultServiceTier)
        case .textGenerationModel: Self.encode(settings.textGenerationModel)
        case .visionModel: Self.encode(settings.visionModel)
        case .compactAtPercent: Self.encode(settings.compactAtPercent)
        case .queueDelivery: Self.encode(settings.queueDelivery)
        case .worktreeBase: Self.encode(settings.worktreeBase)
        case .fetchBeforeCreating: Self.encode(settings.fetchBeforeCreating)
        case .generatePRDescriptions: Self.encode(settings.generatePRDescriptions)
        case .closeOnMerge: Self.encode(settings.closeOnMerge)
        case .worktreeDeleteAction: Self.encode(settings.worktreeDeleteAction)
        case .fleetThreadsCanSend: Self.encode(settings.fleetThreadsCanSend)
        case .fleetThreadCap: Self.encode(settings.fleetThreadCap)
        case .fleetUncommitted: Self.encode(settings.fleetUncommitted)
        case .fleetAutoDispatch: Self.encode(settings.fleetAutoDispatch)
        case .fleetBatteryCountsHalf: Self.encode(settings.fleetBatteryCountsHalf)
        }
    }

    /// The change that sets this setting to `json`; nil when the text isn't a value it takes.
    public func change(fromJSON json: String) -> HostSettingChange? {
        let data = Data(json.utf8)
        func decode<T: Decodable>(_ type: T.Type) -> T? { try? JSONDecoder().decode(T.self, from: data) }
        /// `null` is a value for an optional setting (back to the default); text that isn't JSON is not.
        func decodeOptional<T: Decodable>(_ type: T.Type) -> Result<T?, Error> { Result { try JSONDecoder().decode(T?.self, from: data) } }
        switch self {
        case .defaultModel: return try? .defaultModel(decodeOptional(String.self).get())
        case .defaultThinking: return decode(ThinkingLevel.self).map { .defaultThinking($0) }
        case .defaultServiceTier: return decode(ServiceTier.self).map { .defaultServiceTier($0) }
        case .textGenerationModel: return try? .textGenerationModel(decodeOptional(String.self).get())
        case .visionModel: return try? .visionModel(decodeOptional(String.self).get())
        case .compactAtPercent: return try? .compactAtPercent(decodeOptional(Int.self).get())
        case .queueDelivery: return decode(NativeQueueMode.self).map { .queueDelivery($0) }
        case .worktreeBase: return decode(HostSettings.WorktreeBase.self).map { .worktreeBase($0) }
        case .fetchBeforeCreating: return decode(Bool.self).map { .fetchBeforeCreating($0) }
        case .generatePRDescriptions: return decode(Bool.self).map { .generatePRDescriptions($0) }
        case .closeOnMerge: return decode(Bool.self).map { .closeOnMerge($0) }
        case .worktreeDeleteAction: return decode(HostSettings.WorktreeDeleteAction.self).map { .worktreeDeleteAction($0) }
        case .fleetThreadsCanSend: return decode(Bool.self).map { .fleetThreadsCanSend($0) }
        case .fleetThreadCap: return decode(Int.self).map { .fleetThreadCap($0) }
        case .fleetUncommitted: return decode(FleetUncommittedChanges.self).map { .fleetUncommitted($0) }
        case .fleetAutoDispatch: return decode(Bool.self).map { .fleetAutoDispatch($0) }
        case .fleetBatteryCountsHalf: return decode(Bool.self).map { .fleetBatteryCountsHalf($0) }
        }
    }

    /// Every synced setting of `settings`: unit key to JSON.
    public static func values(in settings: HostSettings) -> [String: String] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.unit, $0.json(in: settings)) })
    }

    /// Whether `settings` holds this setting at the value a Mac starts with, so a Mac that never
    /// chose one doesn't seed the fleet with its default.
    public func isDefault(in settings: HostSettings) -> Bool {
        json(in: settings) == json(in: HostSettings())
    }

    private static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }
}

/// `setting:fleet.weight.<hostID>`: where Fleet sends work, per Mac (`FleetSendWeight`), the same on every
/// Mac. One unit per Mac in the fleet, so the units are those of the weights a Mac holds and of the
/// ones the store decided; the value is the weight's name as JSON.
public enum FleetWeightSetting {
    public static func unit(hostID: UUID) -> String { FleetUnit.setting(FleetSendWeight.settingKey(hostID: hostID)) }

    /// The Mac a unit names the weight of; nil for any other unit.
    public static func hostID(unit: String) -> UUID? {
        guard FleetUnit.kind(of: unit) == "setting", let name = FleetUnit.name(of: unit), name.hasPrefix("fleet.weight.") else { return nil }
        guard let id = UUID(uuidString: String(name.dropFirst("fleet.weight.".count))) else { return nil }
        return unit == Self.unit(hostID: id) ? id : nil
    }

    /// Every weight `settings` holds: unit to JSON.
    public static func values(in settings: HostSettings) -> [String: String] {
        var out: [String: String] = [:]
        for (key, weight) in settings.fleetWeights {
            guard let id = UUID(uuidString: String(key.dropFirst("fleet.weight.".count))), key == FleetSendWeight.settingKey(hostID: id) else { continue }
            out[unit(hostID: id)] = "\"\(weight.rawValue)\""
        }
        return out
    }

    /// The change a unit's value makes; nil when the text isn't a weight.
    public static func change(hostID: UUID, fromJSON json: String) -> HostSettingChange? {
        (try? JSONDecoder().decode(String.self, from: Data(json.utf8))).flatMap(FleetSendWeight.init(rawValue:)).map { .fleetWeight(hostID: hostID, weight: $0) }
    }
}

/// `setting:fleet.snapshotExcludes.<spaceID>`: what a space keeps home or sends against the defaults when its checkout is sent
/// (`FleetSnapshotExcludes`), the same on every Mac. One unit per space; the value is the lists as JSON. No entry is the defaults.
public enum FleetSnapshotExcludeSetting {
    public static func unit(spaceID: String) -> String { FleetUnit.setting(FleetSnapshotExcludes.settingKey(spaceID: spaceID)) }

    /// The space a unit names the excludes of; nil for any other unit.
    public static func spaceID(unit: String) -> String? {
        guard FleetUnit.kind(of: unit) == "setting", let name = FleetUnit.name(of: unit), name.hasPrefix("fleet.snapshotExcludes.") else { return nil }
        let id = String(name.dropFirst("fleet.snapshotExcludes.".count))
        return !id.isEmpty && unit == Self.unit(spaceID: id) ? id : nil
    }

    /// Every list `settings` holds: unit to JSON.
    public static func values(in settings: HostSettings) -> [String: String] {
        var out: [String: String] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (key, excludes) in settings.fleetSnapshotExcludes where !excludes.isEmpty {
            let id = String(key.dropFirst("fleet.snapshotExcludes.".count))
            guard key.hasPrefix("fleet.snapshotExcludes."), let data = try? encoder.encode(excludes) else { continue }
            out[unit(spaceID: id)] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    /// The change a unit's value makes; nil when the text isn't a pair of lists.
    public static func change(spaceID: String, fromJSON json: String) -> HostSettingChange? {
        (try? JSONDecoder().decode(FleetSnapshotExcludes.self, from: Data(json.utf8))).map { .fleetSnapshotExcludes(spaceID: spaceID, excludes: $0) }
    }
}
