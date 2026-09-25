import Foundation
import Observation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Settings over every host (home track): each host's settings, the root instructions and the
/// suggested ones, held by ShepherdRemote's models (`ClientHostSettings`, `ClientInstructions`,
/// `ClientSuggestions`), which keep every rule. The store hands them the hosts as the app knows
/// them now and reads every host again whenever one connects while a Settings screen shows.
/// Screens read the models and call them; they never ask a host themselves.
@MainActor
@Observable
final class SettingsStore {
    let hostSettings = ClientHostSettings()
    let instructions: ClientInstructions
    let suggestions = ClientSuggestions()

    /// The hosts as Settings sees them now.
    private(set) var hosts: [SettingsHost] = []
    /// The host Defaults, Worktrees and Extensions show; the first that serves its settings
    /// when nil or forgotten.
    var chosenHost: UUID?
    /// The page the iPad shows beside the list.
    var page: SettingsPage = .appearance

    @ObservationIgnored private let mobileHosts: MobileHosts
    @ObservationIgnored private var inputs: [Input] = []
    @ObservationIgnored private var watchers = 0

    /// What decides the hosts: a new connection (`session`) is read again.
    private struct Input: Equatable {
        var id: UUID
        var name: String
        var session: UUID?
        var capabilities: Set<String>
    }

    private static var stores: [ObjectIdentifier: SettingsStore] = [:]

    /// The store of the app's hosts: one per `MobileHosts`, made on first use.
    static func of(_ hosts: MobileHosts) -> SettingsStore {
        if let store = stores[ObjectIdentifier(hosts)] { return store }
        let store = SettingsStore(hosts: hosts)
        stores[ObjectIdentifier(hosts)] = store
        return store
    }

    private init(hosts: MobileHosts) {
        mobileHosts = hosts
        // Kept beside the hosts; "Synced from iPhone" in a host's history.
        instructions = ClientInstructions(defaults: hosts.defaults, origin: UIDevice.current.model)
        track()
    }

    // MARK: Reading

    /// The host Defaults, Worktrees and Extensions show: the one chosen, else the first that
    /// serves its settings, else the first.
    var settingsHost: SettingsHost? {
        if let chosen = hosts.first(where: { $0.id == chosenHost }) { return chosen }
        return hosts.first { $0.serves(RemoteProtocol.hostSettingsCapability) } ?? hosts.first
    }

    /// The settings host's settings, once read.
    var settings: HostSettings? {
        settingsHost.flatMap { hostSettings.settings(of: $0) }
    }

    /// Defaults' value on the list: the model without its provider ("claude-opus").
    var defaultsValue: String? { settings.map(HostSettingsPresentation.defaultsValue) }

    /// Extensions' value: how many load ("6").
    var extensionsValue: String? { settings.map(HostSettingsPresentation.extensionsValue) }

    /// Instructions' value: the files that hold anything ("AGENTS.md, APPEND").
    var instructionsValue: String? {
        instructions.reference(in: hosts).flatMap { instructions.files(of: $0).snapshot }.map(HostSettingsPresentation.instructionsValue)
    }

    /// Experiments' value: "1 on" or "Off", once a host says.
    var experimentsValue: String? {
        suggestions.hosts(hosts).isEmpty ? nil : HostSettingsPresentation.experimentsValue(on: suggestions.isOn(hosts))
    }

    /// About's agent: "agent 0.87.1", from the settings host.
    var agentVersion: String? { HostSettingsPresentation.agentVersion(settings) }

    /// The iPad list's foot names the program beside the Pi page ("pi 0.87.1"), as the Mac's does.
    var listFootVersion: String? { HostSettingsPresentation.agentVersion(settings, namingPi: page == .pi) }

    /// The app's host (its thread lists, its models), for a Settings host.
    func mobileHost(_ id: UUID) -> MobileHost? { mobileHosts.host(id) }

    // MARK: Refreshing

    /// Reads every connected host's settings, instructions and suggestions afresh.
    func refresh() async {
        let hosts = self.hosts
        await hostSettings.refresh(hosts)
        await instructions.refresh(hosts)
        await suggestions.refresh(hosts)
    }

    /// While a Settings screen shows: reads every host now, and a host again when it connects.
    func watch() async {
        watchers += 1
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        watchers -= 1
    }

    // MARK: Inputs

    private func track() {
        let next = withObservationTracking {
            mobileHosts.hosts.map { host in
                Input(id: host.id, name: host.name, session: host.phase == .connected ? host.session : nil, capabilities: host.capabilities)
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        guard next != inputs else { return }
        let connected = next.contains { input in
            input.session != nil && !inputs.contains { $0.id == input.id && $0.session == input.session }
        }
        inputs = next
        hosts = mobileHosts.hosts.map { host in
            SettingsHost(id: host.id, name: host.name, client: host.connectedClient, capabilities: host.capabilities)
        }
        if watchers > 0, connected { Task { await refresh() } }
    }
}
