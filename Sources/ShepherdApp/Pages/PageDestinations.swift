import AppKit
import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The Automations page in the main column: its model from the view model, every host's runs
/// read again as runs start, settle or end, and the editor.
struct AutomationsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    @State private var editor: AutomationEditorTarget?

    var body: some View {
        let _ = SHRenderProbe.tick("page.automations")
        AutomationsPage(model: vm.automationsPage, actions: actions, chrome: chrome)
            .task(id: vm.automationRunsSignature) { await vm.loadAutomationPageRuns() }
            .onAppear {
                vm.refreshAutomationTriggers()
                takeEditRequest()
            }
            // A sidebar row's Edit…, whether the page was open already or not.
            .onChange(of: vm.automationEditRequest) { takeEditRequest() }
            // A host's trigger status, now and every 30 s while the page is on screen.
            .task { await vm.watchRemoteAutomationTriggers() }
            .sheet(item: $editor) { target in
                AutomationEditorSheet(vm: vm, target: target) { editor = nil }
                    .dialogSheetFrame()
            }
    }

    private func takeEditRequest() {
        guard let key = vm.automationEditRequest else { return }
        vm.automationEditRequest = nil
        editor = .edit(key)
    }

    private var actions: AutomationsPageActions {
        AutomationsPageActions(
            setFilter: { vm.automationsPageFilter = $0 },
            select: { vm.automationsPageSelection = $0 },
            setEnabled: { vm.setAutomationEnabled($0, $1) },
            run: { vm.runAutomation($0) },
            stop: { vm.stopAutomation($0) },
            openThread: { vm.openThread($0) },
            delete: { vm.deleteAutomation($0) },
            edit: { editor = .edit($0) },
            create: { editor = .new },
            pause: { vm.pauseAutomationTrigger($0) },
            resume: { vm.resumeAutomationTrigger($0) },
            runEvent: { vm.runPendingAutomationEvent($0, eventID: $1) },
            dismissEvent: { vm.dismissAutomationEvent($0, eventID: $1) },
            setAllPaused: { vm.setAllAutomationTriggersPaused(host: $0, $1) },
            openURL: { NSWorkspace.shared.open($0) })
    }
}

/// The Hosts page in the main column, and the confirmation before a host is removed.
struct HostsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    @State private var removing: UUID?

    var body: some View {
        let _ = SHRenderProbe.tick("page.hosts")
        HostsPage(model: vm.hostsPage(agentVersion: vm.server.pi.engine.version), actions: HostsPageActions(
            retry: { vm.remoteHosts.reconnect(id: $0) },
            remove: { id in
                if vm.settings.skipped(.removeHost) != nil { vm.remoteHosts.removeHost(id: id) } else { removing = id }
            },
            addHost: { vm.showAddHost() }), chrome: chrome)
            .sheet(item: Binding(get: { removing.map(SheetItem.init) }, set: { removing = $0?.value })) { item in
                let name = vm.remoteHosts.connections.first { $0.id == item.value }?.config.name ?? "this host"
                DialogSheet(title: "Remove \(name)?",
                            subtitle: "Its threads keep running there; they leave Recents on this Mac. Add it again with its token to bring them back.",
                            actions: [
                                DialogAction("Cancel", kind: .cancel) { removing = nil },
                                DialogAction("Remove host", kind: .destructive) {
                                    removing = nil
                                    vm.remoteHosts.removeHost(id: item.value)
                                },
                            ],
                            dontAskAgain: .removeHost, settings: vm.settings)
            }
    }
}
