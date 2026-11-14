import Foundation
import ShepherdCore

// Fleet ▸ Check (`RemoteProtocol.fleetCheckCapability`): what each Mac found when it looked at itself for what the fleet's work
// needs. Facts only, read only: nothing here installs or changes anything. A Mac pushes its report to the Macs it is linked with
// and answers `fleetCheckNow`; the app's Check tab and a phone's Check list draw them side by side (`FleetMacState.check`).

/// One thing a Mac checked: a row of the Check grid, as this Mac found it.
public struct FleetCheckItem: Codable, Hashable, Sendable, Identifiable {
    /// Which group of the grid it is in.
    public enum Group: String, Codable, CaseIterable, Sendable {
        /// What the repositories here ask for: node, pnpm, Xcode.
        case needs
        /// The programs the MCP servers and extensions run.
        case tools
        /// Whether git's remotes and the model providers answer.
        case access
        /// Shepherd's build and the Mac itself: disk, sleep.
        case system
    }

    public enum State: String, Codable, Sendable {
        case ok
        /// Differs, missing, failing or low: something a person may want to fix. Never stops placement by itself.
        case warn
        /// This Mac holds nothing that asks for it.
        case notNeeded
        /// It couldn't be found out (a shell that didn't answer, a remote that couldn't be reached from here).
        case unknown
    }

    /// What a fix for it is about, which decides the command offered.
    public enum Kind: String, Codable, Sendable {
        /// A program a repository asks for (`tool`, at `want`).
        case tool
        /// A program an MCP server runs (`tool` is its command).
        case command
        /// A git remote that doesn't answer.
        case remote
        /// A provider that doesn't answer or can't start (`tool` is its id).
        case provider
        case build
        case disk
        case sleep
        /// A kind a newer build made: shown, never fixed.
        case other
    }

    /// The row's identity across Macs: "need:node:22", "tool:muse", "git:github.com/acme", "models", "build", "disk", "sleep".
    public var id: String
    public var group: Group
    /// What the row is called: "node 22", "muse CLI".
    public var name: String
    /// Why the fleet asks: ".nvmrc in web, payments-api".
    public var why: String
    public var state: State
    /// What this Mac says in its cell: "22.11", "Has 20.18", "Missing", "38 GB".
    public var value: String
    public var kind: Kind
    /// The program (a command, a provider id), when a fix is about one.
    public var tool: String?
    /// The version asked for ("22"), when there is one.
    public var want: String?
    /// How the version is asked for (`FleetRepoNeed.Match`), when `want` is set.
    public var atLeast: Bool
    /// Who asks for it: the repositories that need a program, the MCP servers that run a command; for the model sign-ins the providers that
    /// don't answer. Sorted, so Macs that hold different repositories can be merged into one row.
    public var subjects: [String]
    /// The files that say so (".nvmrc", "package.json"), for a program a repository asks for.
    public var sources: [String]

    public init(id: String, group: Group, name: String, why: String = "", state: State, value: String, kind: Kind = .other,
                tool: String? = nil, want: String? = nil, atLeast: Bool = false, subjects: [String] = [], sources: [String] = []) {
        self.subjects = subjects
        self.sources = sources
        self.id = id
        self.group = group
        self.name = name
        self.why = why
        self.state = state
        self.value = value
        self.kind = kind
        self.tool = tool
        self.want = want
        self.atLeast = atLeast
    }

    private enum CodingKeys: String, CodingKey { case id, group, name, why, state, value, kind, tool, want, atLeast, subjects, sources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        group = (try? c.decodeIfPresent(Group.self, forKey: .group)) ?? .system
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        // A state a newer build made reads as unknown: it counts for nothing.
        state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? .unknown
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .other
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        want = try c.decodeIfPresent(String.self, forKey: .want)
        atLeast = try c.decodeIfPresent(Bool.self, forKey: .atLeast) ?? false
        subjects = try c.decodeIfPresent([String].self, forKey: .subjects) ?? []
        sources = try c.decodeIfPresent([String].self, forKey: .sources) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(group, forKey: .group)
        try c.encode(name, forKey: .name)
        if !why.isEmpty { try c.encode(why, forKey: .why) }
        try c.encode(state, forKey: .state)
        try c.encode(value, forKey: .value)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encodeIfPresent(want, forKey: .want)
        if atLeast { try c.encode(atLeast, forKey: .atLeast) }
        if !subjects.isEmpty { try c.encode(subjects, forKey: .subjects) }
        if !sources.isEmpty { try c.encode(sources, forKey: .sources) }
    }
}

/// What a Mac found when it looked at itself.
public struct FleetCheckReport: Codable, Hashable, Sendable {
    public var items: [FleetCheckItem]
    /// How this Mac installs programs: "nix" when it has nix, else "brew" when it has Homebrew, else "" (a tool's own installer).
    public var packageManager: String

    public init(items: [FleetCheckItem] = [], packageManager: String = "") {
        self.items = items
        self.packageManager = packageManager
    }

    private enum CodingKeys: String, CodingKey { case items, packageManager }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([FleetCheckItem].self, forKey: .items)) ?? []
        packageManager = try c.decodeIfPresent(String.self, forKey: .packageManager) ?? ""
    }

    /// What a Mac holds of another's report is cut to this much: its own numbers, never trusted to be sane.
    public static let limits = (items: 200, text: 200)

    /// The report cut to bounds: items, one line each, a package manager only of the two it may be.
    public func sanitized() -> FleetCheckReport {
        func line(_ text: String) -> String { String(text.filter { !$0.isNewline }.prefix(Self.limits.text)) }
        func optional(_ text: String?) -> String? { text.map(line) }
        let seen = NSMutableSet()
        let items = items.compactMap { item -> FleetCheckItem? in
            guard !item.id.isEmpty, seen.count < Self.limits.items, !seen.contains(item.id) else { return nil }
            seen.add(item.id)
            return FleetCheckItem(id: line(item.id), group: item.group, name: line(item.name), why: line(item.why), state: item.state,
                                  value: line(item.value), kind: item.kind, tool: optional(item.tool), want: optional(item.want), atLeast: item.atLeast,
                                  subjects: item.subjects.prefix(Self.limits.items).map(line), sources: item.sources.prefix(20).map(line))
        }
        return FleetCheckReport(items: items, packageManager: ["nix", "brew"].contains(packageManager) ? packageManager : "")
    }
}

extension FleetCheckItem {
    /// The Mac has something to do about this: not "ok", not "not needed", and not a thing it couldn't tell.
    public var needsAttention: Bool { state == .warn }
}

extension FleetCheckReport {
    /// The model providers that can't start or refuse their sign-in here: a dispatch of a thread on one of their models isn't placed on this
    /// Mac (`FleetPlacement.Lack.provider`). Everything else Check finds is a warning that never stops placement.
    public var lacks: [FleetPlacement.Lack] {
        items.filter { $0.kind == .provider && $0.state == .warn }.flatMap(\.subjects).map { FleetPlacement.Lack.provider($0) }
    }

    /// What `ignored` leaves of the items that need attention.
    public func attention(ignoring ignored: Set<String> = []) -> [FleetCheckItem] {
        items.filter { $0.needsAttention && !ignored.contains($0.id) }
    }
}

/// `setting:fleet.checkIgnore.<hostID>`: the Check items a person set aside for a Mac (their ids), the same on every Mac of the fleet.
/// One unit per Mac; the value is the ids as a JSON array. No entry is nothing set aside.
public enum FleetCheckIgnoreSetting {
    /// The setting's key in `HostSettings.fleetCheckIgnores`.
    public static func settingKey(hostID: UUID) -> String { "fleet.checkIgnore." + hostID.uuidString.lowercased() }

    public static func unit(hostID: UUID) -> String { FleetUnit.setting(settingKey(hostID: hostID)) }

    /// The Mac a unit names the ignored items of; nil for any other unit.
    public static func hostID(unit: String) -> UUID? {
        guard FleetUnit.kind(of: unit) == "setting", let name = FleetUnit.name(of: unit), name.hasPrefix("fleet.checkIgnore.") else { return nil }
        guard let id = UUID(uuidString: String(name.dropFirst("fleet.checkIgnore.".count))) else { return nil }
        return unit == Self.unit(hostID: id) ? id : nil
    }

    /// Every list `settings` holds: unit to JSON.
    public static func values(in settings: HostSettings) -> [String: String] {
        var out: [String: String] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (key, ids) in settings.fleetCheckIgnores where !ids.isEmpty {
            guard let id = UUID(uuidString: String(key.dropFirst("fleet.checkIgnore.".count))), key == settingKey(hostID: id),
                  let data = try? encoder.encode(ids.sorted()) else { continue }
            out[unit(hostID: id)] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    /// The change a unit's value makes; nil when the text isn't a list of ids.
    public static func change(hostID: UUID, fromJSON json: String) -> HostSettingChange? {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))).map { .fleetCheckIgnore(hostID: hostID, ids: $0) }
    }

    /// The items set aside for `hostID` in `settings`.
    public static func ignored(for hostID: UUID, in settings: HostSettings?) -> Set<String> {
        Set(settings?.fleetCheckIgnores[settingKey(hostID: hostID)] ?? [])
    }
}
