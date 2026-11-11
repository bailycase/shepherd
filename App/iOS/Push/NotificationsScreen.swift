import ActivityKit
import SwiftUI
import UIKit
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Notifications (NotifSettings): what to send, to which device, per mission, and
/// which hosts send at all. The choices live on the phone and go to every host it registered
/// with, which applies them before sending (`RemotePushPreferences`).
struct NotificationsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(PushManager.self) private var push
    @Environment(\.settingsColumn) private var inColumn
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(MobileNavigator.self) private var navigator
    @State private var liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled

    private typealias Topic = RemotePushPreferences.Topic
    private typealias Level = RemotePushPreferences.MissionLevel

    var body: some View {
        let preferences = push.preferences
        let missions = Self.missions(hosts.hosts)
        let muted = Self.mutedThreads(hosts.hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                SettingsSection("Send me") {
                    SHListCard {
                        topic(.questions, "Questions and approvals", note: "Planner, subagent and automation questions, plans, reviews")
                        topic(.blocked, "Blocked work", note: "Stuck lanes and empty budgets")
                        topic(.failures, "Failures", note: "Failed turns and threads that stopped")
                        topic(.finished, "Finished work", note: "Quietly, and in your Scheduled Summary")
                    }
                }
                SettingsSection("Which device") {
                    SHListCard {
                        SettingsSwitchRow("Only when I’m away from my Mac",
                                          note: "Your Mac gets it first. This device only after 2 minutes idle.",
                                          isOn: preferences.awayOnly) { on in
                            var next = preferences
                            next.awayOnly = on
                            save(next)
                        }
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            SettingsControlRow("Live Activities") {
                                Text(liveActivities ? "On" : "Off").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                                Image(systemName: "chevron.right").font(.sh(.caption, weight: .semibold))
                                    .foregroundStyle(Color.sh.textTertiary).accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !missions.isEmpty {
                    SettingsSection("Per mission") {
                        SHListCard {
                            ForEach(missions) { mission in
                                SettingsControlRow(mission.title) {
                                    SettingsPicker(mission.title, selection: preferences.missions[mission.id] ?? .everything,
                                                   options: Level.allCases, title: Self.title) { level in
                                        var next = preferences
                                        next.missions[mission.id] = level == .everything ? nil : level
                                        save(next)
                                    }
                                }
                            }
                        }
                    }
                }
                if !muted.isEmpty {
                    SettingsSection("Muted threads") {
                        SHListCard {
                            ForEach(muted) { row in
                                SettingsControlRow(row.title, note: row.host) {
                                    Button("Unmute") {
                                        let hosts = hosts
                                        AgentActions.run("Couldn’t unmute the thread", navigator: navigator) {
                                            try await AgentActions.mutePushes(row.id, false, hosts: hosts)
                                        }
                                    }
                                    .buttonStyle(.sh(.secondary))
                                }
                            }
                        }
                    }
                }
                SettingsSection("Send from") {
                    if hosts.hosts.isEmpty {
                        SettingsFootnote("Add a host in Settings ▸ Hosts to enable push notifications.")
                    } else {
                        SHListCard {
                            ForEach(hosts.hosts) { host in
                                PushHostRow(host: host)
                            }
                        }
                    }
                }
                SettingsFootnote("Lock-screen previews follow iOS settings.")
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .task(id: scenePhase) {
            if scenePhase == .active {
                liveActivities = ActivityAuthorizationInfo().areActivitiesEnabled
                await push.refreshPermission()
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func topic(_ topic: Topic, _ title: String, note: String) -> some View {
        SettingsSwitchRow(title, note: note, isOn: push.preferences.topics.contains(topic)) { on in
            var next = push.preferences
            if on { next.topics.insert(topic) } else { next.topics.remove(topic) }
            save(next)
        }
    }

    private func save(_ next: RemotePushPreferences) {
        Task { await push.setPreferences(next, hosts: hosts.hosts) }
    }

    private static func title(_ level: Level) -> String {
        switch level {
        case .everything: "Everything"
        case .onlyBlocked: "Only blocked"
        case .onlyFailures: "Only failures"
        case .nothing: "Nothing"
        }
    }

    struct MutedRow: Identifiable, Equatable {
        let id: AgentRef
        let title: String
        let host: String
    }

    /// The threads muted on each connected host that keeps mutes (`pushMuteCapability`), in its order. Muting is
    /// in a thread's long-press menu; this is where they are found again.
    static func mutedThreads(_ hosts: [MobileHost]) -> [MutedRow] {
        hosts.filter { $0.phase.isConnected && $0.supports(RemoteProtocol.pushMuteCapability) }.flatMap { host in
            host.state.agents.filter(\.pushMuted).map { MutedRow(id: AgentRef(host: host.id, agent: $0.id), title: $0.name, host: host.name) }
        }
    }

    struct MissionRow: Identifiable, Equatable {
        let id: String
        let title: String
    }

    /// The missions still going on every host that has them, in each host's order.
    static func missions(_ hosts: [MobileHost]) -> [MissionRow] {
        hosts.flatMap { host in
            host.missions.records
                .filter { ![.done, .stopped].contains($0.run?.phase) }
                .map { MissionRow(id: $0.id.rawValue, title: $0.draft.title) }
        }
    }
}

/// One host's push toggle row with error/retry state.
private struct PushHostRow: View {
    let host: MobileHost
    @Environment(PushManager.self) private var push
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = push.hostStates[host.id] ?? PushManager.HostPushState()
        let supported = push.hostSupportsPush(host)
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.l) {
                VStack(alignment: .leading, spacing: SH.Space.xxs) {
                    Text(host.name)
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(Color.sh.textPrimary)
                    if !supported && host.phase.isConnected {
                        Text("Update Shepherd on this Mac")
                            .font(.sh(.caption))
                            .foregroundStyle(Color.sh.textTertiary)
                    } else if !host.phase.isConnected {
                        Text("Offline")
                            .font(.sh(.caption))
                            .foregroundStyle(Color.sh.textTertiary)
                    }
                }
                Spacer(minLength: SH.Space.m)
                if state.registering {
                    ProgressView()
                        .controlSize(.small)
                } else if state.revokeFailed {
                    Button("Retry") {
                        Task { await push.retryRevoke(host: host) }
                    }
                    .buttonStyle(.sh(.secondary))
                } else {
                    Toggle(host.name, isOn: Binding(
                        get: { state.enabled },
                        set: { on in
                            Task {
                                if on { await push.enable(host: host) }
                                else { await push.disable(host: host) }
                            }
                        }
                    ))
                    .toggleStyle(.shSwitch)
                    .labelsHidden()
                    .disabled(!supported && !state.enabled)
                }
            }
            if state.enabled, !state.registered, !state.revokeFailed {
                Text(host.phase.isConnected ? "Waiting for Mac to confirm registration" : "Waiting for Mac to connect")
                    .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
                if host.phase.isConnected, !state.registering {
                    Button("Retry registration") { Task { await push.renew(host: host, reconnect: true) } }
                        .buttonStyle(.sh(.secondary))
                }
            }
            if state.permissionDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.sh(.secondary))
            }
            if let error = state.error {
                Text(error)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHListMetrics.twoLineRowHeight)
        .accessibilityElement(children: .combine)
    }
}
