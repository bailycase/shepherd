import Foundation
import ShepherdCore
import ShepherdProtocol

/// Settings on the iPhone and the iPad: each row's value, and the words for a host's settings,
/// as the Mac's Settings pages say them.
public enum HostSettingsPresentation {
    /// Defaults' value: the model without its provider ("claude-opus"), or "Agent’s default".
    public static func defaultsValue(_ settings: HostSettings) -> String {
        guard let model = settings.defaultModel, !model.isEmpty else { return "Agent’s default" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }

    /// Extensions' value: how many load, Shepherd's that are on and the host's own ("6").
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

    /// The agent a host runs, as About says it: "agent 0.87.1". Beside the Pi page (the iPad's
    /// list foot) it names the program, "pi 0.87.1", as the Mac's Settings footer does.
    public static func agentVersion(_ settings: HostSettings?, namingPi: Bool = false) -> String? {
        settings?.piVersion.map { "\(namingPi ? "pi" : "agent") \($0)" }
    }

    /// What a bundled extension does, under its switch (Settings ▸ Extensions); nil for one
    /// this client doesn't know yet.
    public static func note(forBundled id: String) -> String? {
        switch id {
        case "panes": "Lets agents open and drive terminals, message or spawn agents, manage automations and notify."
        case "review": "Lets agents open the review pane with `review_diff`."
        case "nativeSubagents": "Helpers, agent files and workflows. Needs agent 0.85.1 or later."
        case "subagents": "Shows subagent runs in their thread. Off doesn't stop them running."
        case "mcp": "Lets agents use the host's MCP servers, through pi's own MCP and tool search."
        case "browser": "Lets agents open, read, click through and photograph pages in their thread's Browser on the host."
        case "context": "Clips one huge tool result and, as the context fills, replaces the oldest tool output, file contents, reasoning and screenshots with a line saying what they were. The thread keeps all of it."
        case "deferTools": "Keeps the browser, other-thread, automation and review tools out of every request until the model asks for one with a tool search."
        case "designReferences": "Lets a thread read the design pieces you hand it with `design_get`. Only a thread you sent one to gets the tool."
        case "codemode": "Lets the agent batch tool calls with JavaScript, up to 128 calls and five minutes per script. Direct classifier and image-model calls are disabled. Spaces can override this default. Applies when agents start or restart."
        default: nil
        }
    }

    public static func title(_ level: ThinkingLevel) -> String {
        level.title
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

    public static func title(_ action: HostSettings.WorktreeDeleteAction) -> String {
        switch action {
        case .ask: "Ask"
        case .keepWorktree: "Keep worktree"
        case .removeWorktree: "Remove worktree"
        }
    }

    // MARK: Host updates

    /// The version line for a host's update status: "Shepherd 1.2.3" or "Shepherd 1.2.3 Nightly".
    public static func versionLine(_ status: HostUpdateStatus) -> String {
        let channel = status.channel == "nightly" ? " Nightly" : ""
        return "Shepherd \(status.version)\(channel)"
    }

    /// One-line summary of the update phase: what the status row or fact says.
    public static func updateSummary(_ status: HostUpdateStatus) -> String {
        switch status.phase {
        case .upToDate: "Up to date"
        case .checking: "Checking for updates…"
        case .available: "Update available: \(status.offeredVersion ?? "newer version")"
        case .downloading: "Downloading update…"
        case .installing: "Installing update…"
        case .failed: status.error ?? "Update failed"
        case .idle: "Up to date"
        case .unsupported: "Updates not available"
        }
    }

    /// Which `AgentState` name an update phase maps to, for coloring in the view layer.
    /// Returns the raw value so this module doesn't depend on ShepherdUI.
    public enum UpdateTone: Sendable {
        case idle, running, attention, failed
    }

    public static func updateTone(_ status: HostUpdateStatus) -> UpdateTone {
        switch status.phase {
        case .upToDate, .idle: return .idle
        case .checking, .downloading, .installing: return .running
        case .available: return .attention
        case .failed: return .failed
        case .unsupported: return .idle
        }
    }

    /// Whether the "Check for update" action makes sense in this phase.
    public static func canCheck(_ status: HostUpdateStatus) -> Bool {
        switch status.phase {
        case .upToDate, .idle, .available, .failed: return true
        case .checking, .downloading, .installing, .unsupported: return false
        }
    }

    /// Whether the "Update and restart" action makes sense: an offer exists and the host says it can install.
    public static func canInstall(_ status: HostUpdateStatus) -> Bool {
        status.phase == .available && status.canInstall && status.offerID != nil
    }

    /// Why install is refused, when an update is available but `canInstall` is false.
    public static func installBlockReason(_ status: HostUpdateStatus) -> String? {
        guard status.phase == .available, !status.canInstall else { return nil }
        return status.error ?? "This host can't install updates right now."
    }

    /// The confirmation message before installing: what happens and what to expect.
    public static func installConfirmation(host: String) -> String {
        "Shepherd on \(host) will download, verify and install the update, then restart. "
        + "All clients disconnect while it restarts. Agents must be idle before updating."
    }
}
