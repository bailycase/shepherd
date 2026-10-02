import Foundation

/// Settings ▸ Agents ▸ Compact at: how full pi lets a context get before it compacts on its own,
/// as a share of each model's window. pi has no share: it compacts once the context passes
/// `window - compaction.reserveTokens`, and a per-model `compaction.modelOverrides` entry
/// (docs/settings.md) sets `reserveTokens` for one `provider/model`. So a share is written as one
/// override per model of the catalog, whose window is known, in Shepherd's own pi home, under
/// pi's lock (`PiSettingsFile`).
///
/// What Shepherd wrote is remembered in `shepherd-compaction.json` beside settings.json, so
/// "pi's default" takes back exactly those values and nothing else, and a model whose entry
/// holds a `reserveTokens` that Shepherd did not write (a re-import, a hand edit) is the user's
/// and is left alone. pi reads the file when a session starts, so a running agent keeps what it
/// started with: new agents follow the change, running ones at their next launch.
public enum PiCompactionThreshold {
    /// The shares Settings offers.
    public static let choices = [60, 70, 80, 90]

    /// pi's default `reserveTokens`: a share never leaves less room for a reply than this.
    public static let piDefaultReserve = 16_384

    static let sidecarName = "shepherd-compaction.json"

    /// What pi should reserve below the window for `percent` of it: the rest of the window, never
    /// less than pi's own default (so a share of a small window cannot compact later than pi).
    public static func reserveTokens(window: Int, percent: Int) -> Int {
        max(piDefaultReserve, window - window * percent / 100)
    }

    /// When pi compacts at `percent` in a window of `window`, as pi would resolve it: the context size.
    public static func compactsAt(window: Int, percent: Int?) -> Int {
        window - (percent.map { reserveTokens(window: window, percent: $0) } ?? piDefaultReserve)
    }

    /// The share Shepherd wrote last, or nil when none (pi's default).
    public static func written(in home: PiHome) -> Int? {
        sidecar(in: home)?.percent
    }

    /// Writes `percent` (nil: pi's default) for each model of `windows` (`provider/model` to its
    /// context window), taking back what an earlier call wrote for a model it no longer lists or
    /// at another share. Blocking, for pi's settings lock: call it off the main thread.
    @discardableResult
    public static func apply(percent: Int?, windows: [String: Int], in home: PiHome) throws -> [String] {
        let before = sidecar(in: home)?.reserves ?? [:]
        var now: [String: Int] = [:]
        let notes = try PiSettingsFile(url: home.settings).update { settings in
            var compaction = settings["compaction"] as? [String: Any] ?? [:]
            var overrides = compaction["modelOverrides"] as? [String: Any] ?? [:]
            // What Shepherd wrote and nobody changed since goes first.
            for (model, reserve) in before {
                guard var entry = overrides[model] as? [String: Any], (entry["reserveTokens"] as? NSNumber)?.intValue == reserve else { continue }
                entry.removeValue(forKey: "reserveTokens")
                if entry.isEmpty { overrides.removeValue(forKey: model) } else { overrides[model] = entry }
            }
            if let percent {
                for (model, window) in windows where window > 0 {
                    var entry = overrides[model] as? [String: Any] ?? [:]
                    if entry["reserveTokens"] != nil { continue }
                    let reserve = reserveTokens(window: window, percent: percent)
                    entry["reserveTokens"] = reserve
                    overrides[model] = entry
                    now[model] = reserve
                }
            }
            if overrides.isEmpty { compaction.removeValue(forKey: "modelOverrides") } else { compaction["modelOverrides"] = overrides }
            if compaction.isEmpty { settings.removeValue(forKey: "compaction") } else { settings["compaction"] = compaction }
            return []
        }
        try writeSidecar(percent.map { Sidecar(percent: $0, reserves: now) }, in: home)
        return notes
    }

    // MARK: What Shepherd wrote

    struct Sidecar: Codable, Equatable {
        var percent: Int
        var reserves: [String: Int]
    }

    static func sidecar(in home: PiHome) -> Sidecar? {
        guard let data = try? Data(contentsOf: home.directory.appendingPathComponent(sidecarName)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    private static func writeSidecar(_ sidecar: Sidecar?, in home: PiHome) throws {
        let url = home.directory.appendingPathComponent(sidecarName)
        guard let sidecar else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PiHome.write(try encoder.encode(sidecar), to: url, mode: 0o600)
    }
}

extension PiSetup {
    /// Writes Settings ▸ Agents ▸ Compact at (`PiCompactionThreshold`) for every model this pi
    /// offers. Blocking (it asks pi for its catalog and waits for the settings lock): call it off the
    /// main thread and the server queue.
    public func applyCompactionThreshold(percent: Int?) throws {
        // Nothing asked for and nothing of ours to take back: no need to start pi for its catalog.
        if percent == nil, PiCompactionThreshold.written(in: files) == nil { return }
        let windows = catalog.entriesOrConfigured().reduce(into: [String: Int]()) { windows, entry in
            if let window = entry.contextWindow { windows[entry.id] = window }
        }
        try PiCompactionThreshold.apply(percent: percent, windows: windows, in: files)
    }
}
