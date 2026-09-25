import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// A remote automation's details and runs (NavAutomations' detail pane, as a sheet): whether it
/// starts with Shepherd, when and where it runs, its prompt, the chart of its latest runs, and
/// each run, opening as its thread while that thread still exists. Run Now (replacing a settled
/// run) or Stop (a live one) act on the host.
struct RemoteAutomationSheet: View {
    var vm: ShepherdViewModel
    let key: AutomationKey

    var body: some View {
        if let detail = vm.remoteAutomationDetail(key) {
            content(detail)
                // A run starting, settling or ending on the host changes what the runs say.
                .task(id: [detail.row.run?.agent.rawValue ?? "", detail.row.status]) { await vm.loadRemoteAutomationRuns(key) }
        } else {
            DialogSheet(title: "Automation", subtitle: "This automation is no longer on the host.",
                        actions: [DialogAction("Close", kind: .prominent) { vm.remoteAutomationSheet = nil }])
        }
    }

    private func content(_ detail: AutomationDetail) -> some View {
        let row = detail.row
        let abilities = row.abilities
        let pending = vm.remoteAutomationsPending.contains(key)
        var actions = [DialogAction("Close", kind: .cancel) { vm.remoteAutomationSheet = nil }]
        if let run = row.run {
            actions.append(DialogAction("Open Run", kind: .normal) {
                vm.remoteAutomationSheet = nil
                vm.selectRemoteAgent(hostID: run.host, agentID: run.agent)
            })
        }
        if row.live {
            actions.append(DialogAction("Stop", kind: .normal, isEnabled: abilities.stop && !pending) {
                vm.performRemoteAutomation(key, .stop)
            })
        } else {
            actions.append(DialogAction("Run Now", kind: .prominent, isEnabled: abilities.run && !pending) {
                vm.performRemoteAutomation(key, .run)
            })
        }
        return DialogSheet(title: row.name, subtitle: "Starts a thread on \(row.hostName) each run.",
                           width: AppLayout.automationSheetWidth, status: abilities.readOnlyReason, actions: actions) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                VStack(spacing: 0) {
                    NWFactRow("On") {
                        HStack(spacing: NW.Space.m) {
                            Toggle("Starts with Shepherd", isOn: Binding(get: { row.enabled },
                                                                         set: { vm.performRemoteAutomation(key, .setEnabled(enabled: $0)) }))
                                .toggleStyle(.nwSwitch)
                                .labelsHidden()
                                .disabled(!abilities.toggle || pending)
                            Text(row.enabled ? "Runs when Shepherd starts on \(row.hostName)" : "Runs only when you run it")
                                .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                        }
                    }
                    NWFactRow("Status", value: row.status)
                    NWFactRow("Host", value: row.hostName, mono: true)
                    NWFactRow("Folder", value: row.cwd, mono: true)
                }
                NWAutomationPrompt(row.prompt)
                runs(detail)
            }
            .padding(.horizontal, NWDialogMetrics.inset)
        }
    }

    @ViewBuilder
    private func runs(_ detail: AutomationDetail) -> some View {
        if !detail.runsKnown {
            Text(detail.row.abilities.readOnlyReason == nil ? "Reading runs…" : "Runs are not available from this host.")
                .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
        } else if detail.runs.isEmpty {
            Text("No runs yet.").nwText(.caption).foregroundStyle(Color.nw.textTertiary)
        } else {
            NWRunBars(detail.bars.map { NWRunBars.Bar(id: $0.id.uuidString, height: $0.height, state: AgentState($0.tone), label: $0.label) },
                      first: detail.chartStart, summary: detail.chartSummary, last: detail.chartEnd)
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                NWSectionHeader("Recent runs", count: detail.runs.count)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(detail.runs) { run in
                            NWRunRow(started: run.started, word: run.word, state: AgentState(run.tone), duration: run.duration,
                                     open: run.agent.map { agent in {
                                         vm.remoteAutomationSheet = nil
                                         vm.selectRemoteAgent(hostID: agent.host, agentID: agent.agent)
                                     } })
                        }
                    }
                }
                .frame(maxHeight: AppLayout.automationRunsMaxHeight)
            }
        }
    }
}

extension ShepherdViewModel {
    /// The sheet's automation as the shared presentation reads it; nil once it is gone.
    func remoteAutomationDetail(_ key: AutomationKey) -> AutomationDetail? {
        guard let connection = remoteHosts.connections.first(where: { $0.id == key.host }) else { return nil }
        return remoteAutomationsModel(connection).detail(key, runs: remoteAutomationRuns[key])
    }

    var remoteAutomationItem: SheetItem<AutomationKey>? {
        get { remoteAutomationSheet.map(SheetItem.init) }
        set { remoteAutomationSheet = newValue?.value }
    }
}
