import Foundation
import ShepherdCore
import ShepherdProtocol

/// Settings on the iPhone and the iPad: each row's value, and the words for a host's settings,
/// as the Mac's Settings pages say them.
public enum HostSettingsPresentation {
    /// Defaults' value: the model without its provider ("claude-opus"), or "pi's default".
    public static func defaultsValue(_ settings: HostSettings) -> String {
        guard let model = settings.defaultModel, !model.isEmpty else { return "pi's default" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Pi extensions' value: how many load, Shepherd's that are on and the host's own ("6").
    public static func extensionsValue(_ settings: HostSettings) -> String {
        String(settings.bundledExtensions.filter(\.on).count + settings.installedExtensions.count)
    }

    /// Instructions' value: which files hold anything ("AGENTS.md, APPEND"), or "None".
    public static func instructionsValue(_ snapshot: InstructionsSnapshot) -> String {
        let held = [(InstructionFile.agents, "AGENTS.md"), (.appendSystem, "APPEND")]
            .filter { !snapshot[$0.0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.1)
        return held.isEmpty ? "None" : held.joined(separator: ", ")
    }

    /// Experiments' value: "1 on" or "Off" (Suggested instructions is the one experiment).
    public static func experimentsValue(on: Bool) -> String {
        on ? "1 on" : "Off"
    }

    /// About's pi: "pi 0.87.1".
    public static func piVersion(_ settings: HostSettings?) -> String? {
        settings?.piVersion.map { "pi \($0)" }
    }

    public static func title(_ level: ThinkingLevel) -> String {
        level.rawValue.capitalized
    }

    public static func title(_ mode: NativeQueueMode) -> String {
        switch mode {
        case .oneAtATime: "One per turn"
        case .all: "All at once"
        }
    }

    public static func title(_ base: HostSettings.WorktreeBase) -> String {
        switch base {
        case .fresh: "Remote default"
        case .head: "Current branch"
        }
    }

    public static func title(_ method: HostSettings.MergeMethod) -> String {
        method.rawValue.capitalized
    }
}
