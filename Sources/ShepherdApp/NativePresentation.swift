import Foundation
import Observation
import ShepherdCore
import ShepherdRemote

/// Device-local presentation only. Neither preferences nor drafts mutate the workspace or PTY.
///
/// `defaultNative` is the Settings ▸ Agents choice; `overrides` holds the agents the user
/// flipped away from it with the header switch, so changing the default later never
/// disturbs an explicit per-agent choice.
@MainActor @Observable
final class NativePresentation {
    static let defaultsKey = "shepherd.nativeAgents"
    static let defaultKey = "shepherd.nativeDefault"
    private(set) var overrides: [AgentID: Bool]
    var defaultNative: Bool {
        didSet { defaults.set(defaultNative, forKey: Self.defaultKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var stores: [AgentID: NativeThreadStore] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultNative = defaults.bool(forKey: Self.defaultKey)
        if let dictionary = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Bool] {
            overrides = dictionary.reduce(into: [:]) { $0[AgentID(rawValue: $1.key)] = $1.value }
        } else {
            // Earlier builds stored the native agents as a plain list.
            overrides = (defaults.stringArray(forKey: Self.defaultsKey) ?? []).reduce(into: [:]) { $0[AgentID(rawValue: $1)] = true }
        }
    }

    func isNative(_ agentID: AgentID) -> Bool { overrides[agentID] ?? defaultNative }

    /// RPC agents have no terminal: always native, and no override is recorded for them.
    func isNative(_ agent: Agent) -> Bool { agent.runtime == .rpc || isNative(agent.id) }

    /// True when the user may flip this agent between Terminal and Native.
    func canSwitch(_ agent: Agent) -> Bool { agent.runtime == .terminal }

    /// Agents that resolve to native right now, under the current default.
    var nativeAgents: Set<AgentID> { Set(overrides.filter { $0.value }.keys) }

    func setNative(_ enabled: Bool, for agent: Agent) {
        guard canSwitch(agent) else { return }
        setNative(enabled, for: agent.id)
    }

    func setNative(_ enabled: Bool, for agentID: AgentID) {
        // Choosing the default again drops the override rather than pinning it.
        if enabled == defaultNative { overrides.removeValue(forKey: agentID) } else { overrides[agentID] = enabled }
        persist()
    }

    func store(for agentID: AgentID) -> NativeThreadStore {
        if let store = stores[agentID] { return store }
        let store = NativeThreadStore()
        stores[agentID] = store
        return store
    }

    func prune(liveAgents: Set<AgentID>) {
        for id in Set(stores.keys).subtracting(liveAgents) { stores.removeValue(forKey: id)?.stop() }
        if !Set(overrides.keys).isSubset(of: liveAgents) {
            overrides = overrides.filter { liveAgents.contains($0.key) }
            persist()
        }
    }

    private func persist() {
        defaults.set(overrides.reduce(into: [String: Bool]()) { $0[$1.key.rawValue] = $1.value }, forKey: Self.defaultsKey)
    }

    static func primaryAgent(in tab: Tab, pane: LeafPane, agents: [Agent]) -> Agent? {
        guard !tab.isShell, pane.isReview != true, tab.inspectorFor == nil else { return nil }
        return agents.first { $0.id == pane.agentID && $0.tabID == tab.id && $0.paneID == pane.id }
    }
}

extension ShepherdViewModel {
    var nativePresentationAgent: Agent? {
        guard selectedRemoteAgent == nil, let agent = selectedAgent,
              activeTabID == agent.tabID,
              let tab = state.tabs.first(where: { $0.id == agent.tabID }),
              let pane = tab.layout.leaves.first(where: { $0.id == agent.paneID }) else { return nil }
        return NativePresentation.primaryAgent(in: tab, pane: pane, agents: [agent])
    }
}
