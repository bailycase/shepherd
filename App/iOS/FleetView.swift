import SwiftUI
import ShepherdCore

struct FleetView: View {
    @ObservedObject var connection: HostConnection
    @Environment(\.colorScheme) private var scheme
    @State private var showingSettings = false
    @State private var path: [AgentID] = []

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let connected = connection.phase == .connected
        NavigationStack(path: $path) {
            List {
                Section {
                    if let configuration = connection.configuration {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.title2)
                                .foregroundStyle(connected ? tokens.status(.working) : tokens.secondary)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(configuration.name).font(MobileTokens.heading).lineLimit(2)
                                Text(connection.phase == .connecting ? "connecting…" : connection.phase.label)
                                    .font(MobileTokens.caption)
                                    .foregroundStyle(connected ? tokens.status(.working) : tokens.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            if connection.phase == .connecting {
                                ProgressView()
                            } else if !connected {
                                Button("reconnect", systemImage: "arrow.clockwise") { connection.reconnect() }
                                    .labelStyle(.iconOnly)
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { showingSettings = true }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Edit host connection")
                        if connection.phase == .connecting {
                            Button("cancel connection") { connection.stop() }.font(MobileTokens.caption)
                        }
                    } else {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Connect to your Mac", systemImage: "plus.circle")
                                .frame(minHeight: 44)
                        }
                    }
                } header: {
                    Text("HOST").font(MobileTokens.caption)
                }
                .listRowBackground(tokens.sidebar)

                Section {
                    if connection.state.agents.isEmpty {
                        Text(connected ? "No agents on this host yet. Start one in Shepherd on your Mac."
                             : connection.configuration == nil ? "Add a host to see its agents." : "Connect to browse this host's agents.")
                            .font(MobileTokens.caption)
                            .foregroundStyle(tokens.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                            .multilineTextAlignment(.center)
                            .listRowBackground(tokens.background)
                    } else {
                        ForEach(connection.state.agents) { agent in
                            NavigationLink(value: agent.id) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(tokens.status(agent.status))
                                        .frame(width: 9, height: 9)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(agent.name).font(MobileTokens.prose).lineLimit(2)
                                        HStack(spacing: 6) {
                                            Text(agent.status.rawValue)
                                                .foregroundStyle(agent.status == .blocked ? tokens.status(.blocked) : tokens.secondary)
                                            if let space = connection.state.spaces.first(where: { $0.id == agent.spaceID }) {
                                                Text("· " + space.name).foregroundStyle(tokens.secondary).lineLimit(1)
                                            }
                                        }
                                        .font(MobileTokens.caption)
                                    }
                                }
                                .padding(.vertical, 6)
                                .accessibilityElement(children: .combine)
                            }
                            .disabled(!connected)
                            .listRowBackground(tokens.background)
                        }
                    }
                } header: {
                    HStack {
                        Text("AGENTS").font(MobileTokens.caption)
                        if !connected, !connection.state.agents.isEmpty {
                            Text("· last known").font(MobileTokens.caption).foregroundStyle(tokens.secondary)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(tokens.background)
            .navigationTitle("Shepherd")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(tokens.sidebar, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("host connection", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .navigationDestination(for: AgentID.self) { id in
                ThreadView(connection: connection, agentID: id)
            }
        }
        .foregroundStyle(tokens.primary)
        .tint(tokens.accent)
        .sheet(isPresented: $showingSettings) { HostSettingsView(connection: connection) }
        .onChange(of: connection.configuration) { _, _ in path = [] }
    }
}
