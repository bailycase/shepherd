import SwiftUI
import ShepherdUI

/// Settings ▸ Hosts (home track): every host with its connection, Retry, and Add host.
struct HostsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        List {
            Section {
                ForEach(hosts.hosts) { host in
                    NavigationLink(value: MobileRoute.settings(.host(host.id))) {
                        HStack(spacing: NW.Space.m) {
                            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                                Text(host.name).font(.nw(.ui)).foregroundStyle(Color.nw.textPrimary)
                                Text("\(host.record.address):\(String(host.record.port))").font(.nw(.mono))
                                    .foregroundStyle(Color.nw.textTertiary)
                            }
                            Spacer(minLength: 0)
                            NWStatusPill(host.phase.isConnected ? .done : host.phase == .connecting ? .running : .failed,
                                         label: host.phase.word)
                        }
                        .frame(minHeight: MobileLayout.twoLineRowHeight)
                        .accessibilityElement(children: .combine)
                    }
                    .swipeActions {
                        if !host.phase.isConnected { Button("Retry") { hosts.retry(host.id) } }
                    }
                }
            } footer: {
                Text("Trusted LAN or VPN only: the connection has no TLS.")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            }
            Section {
                NavigationLink(value: MobileRoute.settings(.host(nil))) {
                    Label("Add host", systemImage: "plus")
                }
            }
        }
        .font(.nw(.ui))
        .scrollContentBackground(.hidden)
        .background(Color.nw.bgWindow)
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
