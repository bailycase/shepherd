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
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.xs)
                    SHListCard {
                        HStack(spacing: SH.Space.l) {
                            Image(systemName: "lock.shield")
                                .font(.sh(.ui, weight: .medium))
                                .foregroundStyle(Color.sh.textSecondary)
                                .frame(width: SHListMetrics.leadingWidth)
                                .accessibilityHidden(true)
                            Text("Notifications include thread titles and short reply, error, or question previews by default. Apple and Cloudflare receive this text, your device token, event type, and routing IDs. Known credentials are redacted, but previews may still contain sensitive text. Lock-screen previews follow iOS settings.")
                                .font(.sh(.caption))
                                .foregroundStyle(Color.sh.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, SH.Space.l)
                        .padding(.vertical, SH.Space.m)
                    }
                }

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
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
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
