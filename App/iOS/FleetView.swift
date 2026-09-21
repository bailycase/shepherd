import SwiftUI
import ShepherdCore

// Agents list per docs/design-spec page 4 + page 9 §8: host section with a Connected /
// Unreachable pill, 56pt rows (title + one-line live status in micro/mono, chevron),
// "Show N more" past five, an Automations section, and a dimmed Retry card when the host is
// unreachable. The status line shows only what ShepherdState carries (state word + space);
// the current tool and elapsed time live in the thread snapshot, so the list omits them.
struct FleetView: View {
    @ObservedObject var connection: HostConnection
    @Environment(\.colorScheme) private var scheme
    @State private var showingSettings = false
    @State private var showAll = false
    @State private var path: [AgentID] = []

    private static let collapsedCount = 5

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let connected = connection.phase == .connected
        let agents = connection.state.agents
        let shown = showAll || agents.count <= Self.collapsedCount ? agents : Array(agents.prefix(Self.collapsedCount))
        NavigationStack(path: $path) {
            List {
                Section {
                    if connection.configuration == nil {
                        Button { showingSettings = true } label: {
                            Text("Add your Mac in Settings to see its agents.")
                                .font(MobileTokens.labelRegular)
                                .foregroundStyle(tokens.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                                .multilineTextAlignment(.center)
                        }
                        .listRowBackground(tokens.raised)
                    } else if !connected {
                        unreachableCard(tokens)
                    } else if agents.isEmpty {
                        Text("No agents on this host yet. Start one in Shepherd on your Mac.")
                            .font(MobileTokens.labelRegular)
                            .foregroundStyle(tokens.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
                            .multilineTextAlignment(.center)
                            .listRowBackground(tokens.raised)
                    }
                    if !agents.isEmpty {
                        ForEach(shown) { agent in
                            NavigationLink(value: agent.id) {
                                agentRow(agent, tokens)
                            }
                            .disabled(!connected)
                            .listRowBackground(tokens.raised)
                        }
                        .opacity(connected ? 1 : 0.55)
                        if agents.count > Self.collapsedCount {
                            Button(showAll ? "Show fewer" : "Show \(agents.count - Self.collapsedCount) more") {
                                showAll.toggle()
                            }
                            .font(MobileTokens.label)
                            .foregroundStyle(tokens.text)
                            .frame(maxWidth: .infinity, minHeight: MobileTokens.touch)
                            .listRowBackground(tokens.raised)
                        }
                    }
                } header: {
                    hostHeader(tokens)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: MobileTokens.inset, bottom: 0, trailing: MobileTokens.inset))
                .listRowSeparatorTint(tokens.borderSubtle)

                if !connection.state.automations.isEmpty {
                    Section {
                        ForEach(connection.state.automations) { automation in
                            let agent = automation.agentID.flatMap { id in agents.first { $0.id == id } }
                            if let agent, connected {
                                NavigationLink(value: agent.id) { automationRow(automation, agent: agent, tokens) }
                                    .listRowBackground(tokens.raised)
                            } else {
                                automationRow(automation, agent: agent, tokens)
                                    .listRowBackground(tokens.raised)
                            }
                        }
                    } header: {
                        HStack {
                            Text("AUTOMATIONS").font(MobileTokens.section).tracking(0.5).foregroundStyle(tokens.textTertiary)
                            Spacer()
                            Text("\(connection.state.automations.count)").font(MobileTokens.micro).foregroundStyle(tokens.textMuted)
                        }
                        .textCase(nil)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: MobileTokens.inset, bottom: 0, trailing: MobileTokens.inset))
                    .listRowSeparatorTint(tokens.borderSubtle)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(tokens.canvas)
            .navigationTitle("Agents")
            // The system large-title bar imposes its own type and glass chrome; page 4 is a flat
            // display-size "Agents" with the gear beside it, so the row is drawn here.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Agents").font(MobileTokens.display).foregroundStyle(tokens.text)
                    Spacer()
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(tokens.textSecondary)
                            .frame(width: MobileTokens.touch, height: MobileTokens.touch)
                            .background(tokens.raised, in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tokens.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Settings")
                }
                .padding(.horizontal, MobileTokens.inset + 4)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .background(tokens.canvas)
            }
            .navigationDestination(for: AgentID.self) { id in
                ThreadView(connection: connection, agentID: id)
            }
        }
        .foregroundStyle(tokens.text)
        .tint(tokens.accent)
        .sheet(isPresented: $showingSettings) { HostSettingsView(connection: connection) }
        .onChange(of: connection.configuration) { _, _ in path = [] }
    }

    private func hostHeader(_ tokens: MobileTokens) -> some View {
        HStack(spacing: 6) {
            // .textCase(nil) stops the grouped-list header from restyling the label.
            Text((connection.configuration?.name ?? "Your Mac").uppercased())
                .font(MobileTokens.section).tracking(0.5).foregroundStyle(tokens.textTertiary).lineLimit(1).textCase(nil)
            Spacer()
            if connection.configuration != nil {
                let connected = connection.phase == .connected
                let word = connected ? "Connected" : connection.phase == .connecting ? "Connecting" : "Unreachable"
                HStack(spacing: 5) {
                    Circle().fill(connected ? tokens.success : tokens.danger)
                        .frame(width: MobileTokens.statusSize, height: MobileTokens.statusSize)
                        .accessibilityHidden(true)
                    Text(word).font(MobileTokens.caption12)
                }
                .foregroundStyle(connected ? tokens.successText : tokens.dangerText)
                .textCase(nil)
                .accessibilityLabel("Host \(word.lowercased())")
            }
        }
    }

    private func unreachableCard(_ tokens: MobileTokens) -> some View {
        VStack(alignment: .leading, spacing: MobileTokens.blockSpacing) {
            Text(connection.phase == .connecting ? "Connecting…" : "Unreachable")
                .font(MobileTokens.labelStrong).foregroundStyle(tokens.text)
            Text(connection.state.agents.isEmpty
                 ? "Agents appear when the host connects."
                 : "Showing the last known agents. They resume when the host reconnects.")
                .font(MobileTokens.caption12).foregroundStyle(tokens.textTertiary)
            if case .failed(let reason) = connection.phase {
                Text(reason).font(MobileTokens.micro).foregroundStyle(tokens.textMuted).lineLimit(2)
            }
            if connection.phase == .connecting {
                Button("Cancel") { connection.stop() }
                    .buttonStyle(MobileActionStyle(kind: .secondary, tokens: tokens))
            } else {
                Button("Retry") { connection.reconnect() }
                    .buttonStyle(MobileActionStyle(kind: .secondary, tokens: tokens))
            }
        }
        .padding(.vertical, 14)
        .listRowBackground(tokens.muted)
    }

    private func agentRow(_ agent: Agent, _ tokens: MobileTokens) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(tokens.status(agent.status))
                .frame(width: MobileTokens.statusSize, height: MobileTokens.statusSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(MobileTokens.label).foregroundStyle(tokens.text).lineLimit(1)
                HStack(spacing: 0) {
                    Text(MobileTokens.statusWord(agent.status)).foregroundStyle(tokens.statusText(agent.status))
                    if let space = connection.state.spaces.first(where: { $0.id == agent.spaceID }) {
                        Text(" · \(space.name)").foregroundStyle(tokens.textMuted)
                    }
                }
                .font(MobileTokens.micro)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: MobileTokens.agentRowHeight)
        .accessibilityElement(children: .combine)
    }

    private func automationRow(_ automation: Automation, agent: Agent?, _ tokens: MobileTokens) -> some View {
        let running = agent != nil
        return HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(running ? tokens.success : automation.enabled ? tokens.dotIdle : tokens.textDisabled)
                .frame(width: MobileTokens.statusSize, height: MobileTokens.statusSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name).font(MobileTokens.label).foregroundStyle(tokens.text).lineLimit(1)
                Text(running ? "running" : automation.enabled ? "enabled" : "stopped")
                    .font(MobileTokens.micro)
                    .foregroundStyle(running ? tokens.successText : tokens.textMuted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: MobileTokens.agentRowHeight)
        .accessibilityElement(children: .combine)
    }
}
