import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Settings ▸ Notifications: per-host push opt-in with data disclosure.
/// Default off. Each host gets its own toggle; all event types enabled together.
/// One flat list — every host appears regardless of connection state so error/retry
/// rows stay visible even when the host goes offline.
struct NotificationsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(PushManager.self) private var push
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    Text("Get notified when a thread finishes, hits an error, or needs your answer, even when Shepherd isn't open.")
                        .nwText(.caption)
                        .foregroundStyle(Color.nw.textSecondary)
                        .padding(.horizontal, NW.Space.xs)
                    NWListCard {
                        HStack(spacing: NW.Space.l) {
                            Image(systemName: "lock.shield")
                                .font(.nw(.ui, weight: .medium))
                                .foregroundStyle(Color.nw.textSecondary)
                                .frame(width: NWListMetrics.leadingWidth)
                                .accessibilityHidden(true)
                            Text("Apple and Cloudflare receive your device token, event type, and opaque routing IDs. No thread content is sent.")
                                .font(.nw(.caption))
                                .foregroundStyle(Color.nw.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, NW.Space.l)
                        .padding(.vertical, NW.Space.m)
                    }
                }

                if hosts.hosts.isEmpty {
                    SettingsFootnote("Add a host in Settings ▸ Hosts to enable push notifications.")
                } else {
                    NWListCard {
                        ForEach(hosts.hosts) { host in
                            PushHostRow(host: host)
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One host's push toggle row with error/retry state.
private struct PushHostRow: View {
    let host: MobileHost
    @Environment(PushManager.self) private var push

    var body: some View {
        let state = push.hostStates[host.id] ?? PushManager.HostPushState()
        let supported = push.hostSupportsPush(host)
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            HStack(spacing: NW.Space.l) {
                VStack(alignment: .leading, spacing: NW.Space.xxs) {
                    Text(host.name)
                        .font(.nw(.ui, weight: .medium))
                        .foregroundStyle(Color.nw.textPrimary)
                    if !supported && host.phase.isConnected {
                        Text("Update Shepherd on this Mac")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                    } else if !host.phase.isConnected {
                        Text("Offline")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                    }
                }
                Spacer(minLength: NW.Space.m)
                if state.registering {
                    ProgressView()
                        .controlSize(.small)
                } else if state.revokeFailed {
                    Button("Retry") {
                        Task { await push.retryRevoke(host: host) }
                    }
                    .buttonStyle(.nw(.secondary))
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
                    .toggleStyle(.nwSwitch)
                    .labelsHidden()
                    .disabled(!supported && !state.enabled)
                }
            }
            if let error = state.error {
                Text(error)
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.failed)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWListMetrics.twoLineRowHeight)
        .accessibilityElement(children: .combine)
    }
}
