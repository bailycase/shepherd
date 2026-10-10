import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Project page's right pane (ProjectLead-Started, -Paused, -Resolved, -ThreadRunning): the Threads tab (the
// owner's real tasks, grouped by what they need from you) or one task's thread opened beside the conversation.
// Everything drawn is a task the Project record holds; an empty Project draws the board's own empty sentence.

/// Which task is open in the pane, if any. Ephemeral, per Project, like the thread selection.
struct ProjectPaneSelection: Equatable {
    var task: ProjectTaskID?
}

struct LogicalProjectPane: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let presentation: ProjectPagePresentation
    @State private var folded: Set<ProjectTaskGroup> = []
    @FocusState private var searchFocused: Bool

    /// The workers whose rows are on screen: each row's subtitle is its worker's own native activity, so those threads are read
    /// while the list shows (at most six, the Project's thread limit). Resolved work is not polled.
    private var listedWorkers: [ProjectTaskRow] {
        vm.logicalProjectPaneTab == .threads && openTask == nil ? presentation.rows.filter { $0.group != .resolved } : []
    }

    private var openTask: ProjectTaskRow? {
        vm.logicalProjectPaneTask.flatMap { id in presentation.rows.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let task = openTask {
                ProjectTaskDetail(vm: vm, ref: ref, project: project, task: task)
            } else {
                header
                if vm.logicalProjectPaneSearching { searchField }
                switch vm.logicalProjectPaneTab {
                case .threads: threads
                case .files: LogicalProjectFiles(vm: vm, ref: ref, project: project)
                case .automations: LogicalProjectPaneAutomations(vm: vm, ref: ref, project: project)
                }
                if project.paused && vm.logicalProjectPaneTab == .threads { pausedFooter }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The leading line takes its own 1pt (a CSS border-left), so the content starts one point in.
        .padding(.leading, NWLeadMetrics.paneBorder)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical, width: NWLeadMetrics.paneBorder) }
        .task(id: listedWorkers) {
            await withTaskGroup(of: Void.self) { group in
                for row in listedWorkers {
                    group.addTask { @MainActor [vm, ref] in
                        await vm.projectWorkerStore(ref.home, row.workerAgentID).run(request: vm.projectWorkerRequest(ref, task: row.id))
                    }
                }
            }
        }
    }

    // MARK: Header (ProjectLead-Started): Threads, Files, Automations, New thread | Search threads, Filter, Expand, Close.

    private var header: some View {
        HStack(spacing: NWLeadMetrics.paneTabGap) {
            ForEach(LogicalProjectPaneTab.allCases) { tab in
                if tab == vm.logicalProjectPaneTab {
                    NWLeadToolbarButton(tab.rawValue, symbol: Self.symbol(tab), selected: true, badge: tab == .threads ? presentation.needsYou : 0) {}
                } else {
                    Button { vm.logicalProjectPaneTab = tab } label: { Image(systemName: Self.symbol(tab)) }
                        .buttonStyle(.nwIcon(size: NWLeadMetrics.paneHeaderButton))
                        .nwHelp(tab.rawValue)
                        .accessibilityLabel(tab.rawValue)
                }
            }
            Button { vm.beginAssigningProjectTask(ref) } label: { Image(systemName: "plus") }
                .buttonStyle(.nwIcon(size: NWLeadMetrics.paneHeaderButton))
                .nwHelp("New thread")
                .accessibilityLabel("New thread")
            Spacer(minLength: NW.Space.m)
            Button { vm.logicalProjectPaneSearching.toggle(); searchFocused = vm.logicalProjectPaneSearching } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.nwIcon(isOn: vm.logicalProjectPaneSearching, size: NWLeadMetrics.paneHeaderButton))
                .nwHelp("Search threads")
                .accessibilityLabel("Search threads")
            filterMenu
            Button { vm.logicalProjectPaneExpanded.toggle() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.nwIcon(isOn: vm.logicalProjectPaneExpanded, size: NWLeadMetrics.paneHeaderButton))
                .nwHelp(vm.logicalProjectPaneExpanded ? "Collapse" : "Expand")
                .accessibilityLabel(vm.logicalProjectPaneExpanded ? "Collapse" : "Expand")
            Button { vm.logicalProjectPaneOpen = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.nwIcon(size: NWLeadMetrics.paneHeaderButton))
                .nwHelp("Close")
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
        .frame(height: NWLeadMetrics.toolbarHeight)
    }

    static func symbol(_ tab: LogicalProjectPaneTab) -> String {
        switch tab {
        case .threads: "bubble.left"
        case .files: NWGlyph.document.symbolName
        case .automations: "clock"
        }
    }

    /// Filter: show only the chosen groups of tasks (Waiting on you, Working, Resolved). None chosen shows all.
    private var filterMenu: some View {
        Menu {
            ForEach(ProjectTaskGroup.allCases, id: \.self) { group in
                Toggle(group.rawValue, isOn: Binding(
                    get: { vm.logicalProjectPaneFilter.contains(group) },
                    set: { on in if on { vm.logicalProjectPaneFilter.insert(group) } else { vm.logicalProjectPaneFilter.remove(group) } }))
            }
            if !vm.logicalProjectPaneFilter.isEmpty {
                Divider()
                Button("Show all") { vm.logicalProjectPaneFilter = [] }
            }
        } label: {
            Label("Filter", systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.nwIcon(isOn: !vm.logicalProjectPaneFilter.isEmpty, size: NWLeadMetrics.paneHeaderButton))
        .fixedSize()
        .nwHelp("Filter")
        .accessibilityLabel("Filter")
    }

    private var searchField: some View {
        NWSearchField("Search threads", text: Binding(get: { vm.logicalProjectPaneQuery }, set: { vm.logicalProjectPaneQuery = $0 }))
            .focused($searchFocused)
            .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
            .padding(.bottom, NW.Space.m)
    }

    // MARK: Threads

    private var threads: some View {
        let shown = presentation.visibleRows(query: vm.logicalProjectPaneQuery, groups: vm.logicalProjectPaneFilter)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: NW.Space.xl) {
                NWLeadWelcome(name: vm.projectViewerName, status: presentation.status)
                    .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
                if presentation.rows.isEmpty {
                    Text("Threads the project starts show here, grouped by what they need from you.")
                        .font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
                } else if shown.isEmpty {
                    Text("No thread matches.").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textTertiary)
                        .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
                } else {
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        ForEach(ProjectTaskGroup.allCases, id: \.self) { group in groupView(group, rows: shown.filter { $0.group == group }) }
                    }
                }
            }
            .padding(.horizontal, NWLeadMetrics.paneHeaderInset)
            .padding(.top, NWLeadMetrics.panePadding)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private func groupView(_ group: ProjectTaskGroup, rows: [ProjectTaskRow]) -> some View {
        if !rows.isEmpty {
            let open = !folded.contains(group)
            VStack(alignment: .leading, spacing: NWLeadMetrics.rowGap) {
                NWLeadGroupHeader(group.rawValue, count: rows.count, expanded: open) {
                    if open { folded.insert(group) } else { folded.remove(group) }
                }
                if open {
                    ForEach(rows) { row in
                        NWLeadThreadRow(title: row.title, lead: row.lead, detail: row.group == .resolved ? nil : row.detail ?? vm.workerActivity(row.workerAgentID, home: ref.home),
                                        tone: row.group == .resolved ? .resolved : row.group == .waiting ? .attention : .running,
                                        age: row.settledAt.map(Self.age) ?? vm.workerStarted(row.workerAgentID, home: ref.home).map(Self.age)) {
                            vm.logicalProjectPaneTask = row.id
                        }
                    }
                }
            }
        }
    }

    private var pausedFooter: some View {
        NWLeadFooterCard(title: "The project is paused.", action: "Resume",
                         enabled: !vm.logicalProjects.busy.contains(ref.id) && !project.interruptPending) {
            Task { _ = await vm.logicalProjects.setPaused(ref, false) }
        }
        .padding(NWLeadMetrics.footerInset)
    }

    /// "29m", "2h", "3d": minutes, hours or days since the task settled.
    static func age(_ settledAt: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - settledAt / 1000)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

/// One task opened in the pane: its breadcrumb (Threads › title), Resolve or Reopen, and the worker's own native
/// conversation (the ordinary thread, steered with its own composer), or the resolved footer with Reopen.
struct ProjectTaskDetail: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let task: ProjectTaskRow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: NW.Space.m) {
                Button { vm.logicalProjectPaneTask = nil } label: {
                    Text("Threads").font(.nw(.ui, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                        .frame(minHeight: NW.Height.controlM)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Threads")
                Image(systemName: "chevron.right").font(.system(size: NWLeadMetrics.groupChevron)).foregroundStyle(Color.nw.textTertiary)
                    .accessibilityHidden(true)
                Text(task.title).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                Spacer(minLength: NW.Space.m)
                // Resolve is the check circle; it is drawn for every task and enabled only once the task has settled (the runtime
                // refuses to resolve work still running). A resolved task's check is the green Reopen.
                if task.canReopen {
                    Button { Task { _ = await vm.logicalProjects.reopen(ref, task: task.id) } } label: {
                        Image(systemName: NWGlyph.resolved.symbolName).foregroundStyle(Color.nw.done)
                    }
                    .buttonStyle(.nwIcon(size: NWLeadMetrics.detailButton))
                    .nwHelp("Reopen thread")
                    .accessibilityLabel("Reopen thread")
                } else {
                    Button { Task { _ = await vm.logicalProjects.resolve(ref, task: task.id) } } label: { Image(systemName: NWGlyph.resolved.symbolName) }
                        .buttonStyle(.nwIcon(size: NWLeadMetrics.detailButton))
                        .disabled(!task.canResolve || vm.logicalProjects.busy.contains(ref.id))
                        .nwHelp(task.canResolve ? "Mark resolved" : "Mark resolved once this thread has finished")
                        .accessibilityLabel("Mark resolved")
                }
                Menu {
                    Button("Open as a thread") { vm.selectAgent(task.workerAgentID) }
                    if task.canResolve { Button("Mark resolved") { Task { _ = await vm.logicalProjects.resolve(ref, task: task.id) } } }
                    if task.canReopen { Button("Reopen thread") { Task { _ = await vm.logicalProjects.reopen(ref, task: task.id) } } }
                } label: { Label("More", systemImage: "ellipsis").labelStyle(.iconOnly) }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.nwIcon(size: NWLeadMetrics.detailButton))
                    .fixedSize()
                    .nwHelp("More")
                    .accessibilityLabel("More")
                Button { vm.selectAgent(task.workerAgentID) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.nwIcon(size: NWLeadMetrics.detailButton))
                    .nwHelp("Open as a thread")
                    .accessibilityLabel("Open as a thread")
                Button { vm.logicalProjectPaneTask = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.nwIcon(size: NWLeadMetrics.detailButton))
                    .nwHelp("Close")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, NWLeadMetrics.paneHeaderInset + NW.Space.xs)
            .frame(height: NWLeadMetrics.toolbarHeight)
            .overlay(alignment: .bottom) { NWHairline() }
            // The worker's own conversation, the ordinary native thread: its composer steers it directly.
            WorkerThread(vm: vm, home: ref.home, projectID: ref.id, task: task)
            if task.group == .resolved {
                NWLeadFooterCard(symbol: NWGlyph.resolved.symbolName, title: "This thread is resolved.", detail: "Reopen it to send more messages.",
                                 action: "Reopen", enabled: !vm.logicalProjects.busy.contains(ref.id)) {
                    Task { _ = await vm.logicalProjects.reopen(ref, task: task.id) }
                }
                .padding(NWLeadMetrics.footerInset)
            }
        }
    }
}

/// The worker's ordinary thread, in the pane: its own store and composer. Steering stays native; the Project is not
/// in the path.
private struct WorkerThread: View {
    var vm: ShepherdViewModel
    let home: LogicalProjectHome
    let projectID: ProjectID
    let task: ProjectTaskRow

    var body: some View {
        ThreadView(store: vm.projectWorkerStore(home, task.workerAgentID), active: true, isFocused: false,
                   request: vm.projectWorkerRequest(LogicalProjectRef(home: home, id: projectID), task: task.id),
                   commandKey: ThreadCommandCenter.key(local: task.workerAgentID), agentName: task.title,
                   allowsLocalFiles: home == .local, retainedInput: vm.threadStores.input(for: task.workerAgentID))
            .environment(\.projectWorkerThread, ProjectWorkerThreadStyle(assignmentOperations: task.assignmentOperations))
            .environment(\.nwUserBubbleMetrics, .lead)
            .environment(\.nwProseHalfLeading, true)
            .id(task.workerAgentID.rawValue)
    }
}
