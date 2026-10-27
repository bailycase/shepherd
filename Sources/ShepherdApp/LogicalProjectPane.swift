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
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // The leading line (a CSS border-left) is the page's divider, drawn and dragged by `RightPaneSplit`.
        .background(Color.sh.bgWindow)
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
        HStack(spacing: SHLeadMetrics.paneTabGap) {
            ForEach(LogicalProjectPaneTab.allCases) { tab in
                if tab == vm.logicalProjectPaneTab {
                    SHLeadToolbarButton(tab.rawValue, symbol: Self.symbol(tab), selected: true, badge: tab == .threads ? presentation.needsYou : 0) {}
                } else {
                    Button { vm.logicalProjectPaneTab = tab } label: { Image(systemName: Self.symbol(tab)) }
                        .buttonStyle(.shIcon(size: SHLeadMetrics.paneHeaderButton))
                        .shHelp(tab.rawValue)
                        .accessibilityLabel(tab.rawValue)
                }
            }
            Button { vm.beginAssigningProjectTask(ref) } label: { Image(systemName: "plus") }
                .buttonStyle(.shIcon(size: SHLeadMetrics.paneHeaderButton))
                .shHelp("New thread")
                .accessibilityLabel("New thread")
            Spacer(minLength: SH.Space.m)
            Button { vm.logicalProjectPaneSearching.toggle(); searchFocused = vm.logicalProjectPaneSearching } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.shIcon(isOn: vm.logicalProjectPaneSearching, size: SHLeadMetrics.paneHeaderButton))
                .shHelp("Search threads")
                .accessibilityLabel("Search threads")
            filterMenu
            Button { vm.logicalProjectPaneExpanded.toggle() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.shIcon(isOn: vm.logicalProjectPaneExpanded, size: SHLeadMetrics.paneHeaderButton))
                .shHelp(vm.logicalProjectPaneExpanded ? "Collapse" : "Expand")
                .accessibilityLabel(vm.logicalProjectPaneExpanded ? "Collapse" : "Expand")
            Button { vm.logicalProjectPaneOpen = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.shIcon(size: SHLeadMetrics.paneHeaderButton))
                .shHelp("Close")
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
        .frame(height: SHLeadMetrics.toolbarHeight)
    }

    static func symbol(_ tab: LogicalProjectPaneTab) -> String {
        switch tab {
        case .threads: "bubble.left"
        case .files: SHGlyph.document.symbolName
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
        .buttonStyle(.shIcon(isOn: !vm.logicalProjectPaneFilter.isEmpty, size: SHLeadMetrics.paneHeaderButton))
        .fixedSize()
        .shHelp("Filter")
        .accessibilityLabel("Filter")
    }

    private var searchField: some View {
        SHSearchField("Search threads", text: Binding(get: { vm.logicalProjectPaneQuery }, set: { vm.logicalProjectPaneQuery = $0 }))
            .focused($searchFocused)
            .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
            .padding(.bottom, SH.Space.m)
    }

    // MARK: Threads

    private var threads: some View {
        let shown = presentation.visibleRows(query: vm.logicalProjectPaneQuery, groups: vm.logicalProjectPaneFilter)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: SH.Space.xl) {
                SHLeadWelcome(name: vm.projectViewerName, status: presentation.status)
                    .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
                if presentation.rows.isEmpty {
                    Text("Threads the project starts show here, grouped by what they need from you.")
                        .font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
                } else if shown.isEmpty {
                    Text("No thread matches.").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                        .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
                } else {
                    let grouped = Dictionary(grouping: shown, by: \.group)
                    VStack(alignment: .leading, spacing: SH.Space.xs) {
                        ForEach(ProjectTaskGroup.allCases, id: \.self) { group in groupView(group, rows: grouped[group] ?? []) }
                    }
                }
            }
            .padding(.horizontal, SHLeadMetrics.paneHeaderInset)
            .padding(.top, SHLeadMetrics.panePadding)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder private func groupView(_ group: ProjectTaskGroup, rows: [ProjectTaskRow]) -> some View {
        if !rows.isEmpty {
            let open = !folded.contains(group)
            VStack(alignment: .leading, spacing: SHLeadMetrics.rowGap) {
                SHLeadGroupHeader(group.rawValue, count: rows.count, expanded: open) {
                    if open { folded.insert(group) } else { folded.remove(group) }
                }
                if open {
                    ForEach(rows) { row in
                        SHLeadThreadRow(title: row.title, lead: row.lead, detail: row.group == .working ? row.detail ?? vm.workerActivity(row.workerAgentID, home: ref.home) : row.detail,
                                        tone: row.tone,
                                        age: row.settledAt.map(Self.age) ?? vm.workerStarted(row.workerAgentID, home: ref.home).map(Self.age)) {
                            vm.logicalProjectPaneTask = row.id
                        }
                        .equatable()
                    }
                }
            }
        }
    }

    /// "29m", "2h", "3d": minutes, hours or days since the task settled.
    static func age(_ settledAt: Double) -> String {
        let seconds = max(0, Date().timeIntervalSince1970 - settledAt / 1000)
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

/// One task opened in the pane: its breadcrumb (Threads › title), Resolve, and the worker's own native conversation (the
/// ordinary thread, steered with its own composer), or, once resolved, its read-only history above the resolved footer.
/// A resolved task is terminal: nothing here reopens it; new work is a fresh assignment from the conversation.
struct ProjectTaskDetail: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let task: ProjectTaskRow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: SH.Space.m) {
                Button { vm.logicalProjectPaneTask = nil } label: {
                    Text("Threads").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                        .frame(minHeight: SH.Height.controlM)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Threads")
                Image(systemName: "chevron.right").font(.system(size: SHLeadMetrics.groupChevron)).foregroundStyle(Color.sh.textTertiary)
                    .accessibilityHidden(true)
                Text(task.title).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                // Resolve is the check circle; it is drawn for every task and enabled only once the task has settled (the runtime
                // refuses to resolve work still running). A resolved task's check is a green status, not a control.
                if task.group == .resolved {
                    Image(systemName: SHGlyph.resolved.symbolName).foregroundStyle(Color.sh.done)
                        .frame(width: SHLeadMetrics.detailButton, height: SHLeadMetrics.detailButton)
                        .shHelp("Resolved")
                        .accessibilityLabel("Resolved")
                } else {
                    Button { Task { _ = await vm.logicalProjects.resolve(ref, task: task.id) } } label: { Image(systemName: SHGlyph.resolved.symbolName) }
                        .buttonStyle(.shIcon(size: SHLeadMetrics.detailButton))
                        .disabled(!task.canResolve || vm.logicalProjects.busy.contains(ref))
                        .shHelp(task.canResolve ? "Mark resolved" : "Mark resolved once this thread's turn has stopped")
                        .accessibilityLabel("Mark resolved")
                }
                Menu {
                    Button("Open as a thread") { vm.openProjectWorkerThread(ref, task: task.id) }
                    if task.canResolve { Button("Mark resolved") { Task { _ = await vm.logicalProjects.resolve(ref, task: task.id) } } }
                } label: { Label("More", systemImage: "ellipsis").labelStyle(.iconOnly) }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(.shIcon(size: SHLeadMetrics.detailButton))
                    .fixedSize()
                    .shHelp("More")
                    .accessibilityLabel("More")
                Button { vm.openProjectWorkerThread(ref, task: task.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.shIcon(size: SHLeadMetrics.detailButton))
                    .shHelp("Open as a thread")
                    .accessibilityLabel("Open as a thread")
                Button { vm.logicalProjectPaneTask = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.shIcon(size: SHLeadMetrics.detailButton))
                    .shHelp("Close")
                    .accessibilityLabel("Close")
            }
            .padding(.horizontal, SHLeadMetrics.paneHeaderInset + SH.Space.xs)
            .frame(height: SHLeadMetrics.toolbarHeight)
            .overlay(alignment: .bottom) { SHHairline() }
            // The worker's own conversation, the ordinary native thread: its composer steers it directly.
            WorkerThread(vm: vm, home: ref.home, projectID: ref.id, task: task)
            if task.group == .resolved {
                SHLeadFooterCard(symbol: SHGlyph.resolved.symbolName, title: "This thread is resolved.",
                                 detail: "Its history stays here. New work starts a new thread.")
                    .padding(SHLeadMetrics.footerInset)
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
                   workingDirectory: workingDirectory,
                   allowsLocalFiles: home == .local, retainedInput: vm.threadStores.input(for: task.workerAgentID))
            .environment(\.projectWorkerThread, ProjectWorkerThreadStyle(assignmentOperations: task.assignmentOperations,
                                                                          composerHidden: task.group == .resolved,
                                                                          answerHeld: task.answerHeld))
            .environment(\.shUserBubbleMetrics, .lead)
            .environment(\.shProseHalfLeading, true)
            .id(task.workerAgentID.rawValue)
    }

    private var workingDirectory: String? {
        // Do not observe agent removal here: a mounted thread must keep its store and draft.
        let owner = vm.server.state
        guard case .local = home, let record = owner.agents.first(where: { $0.id == task.workerAgentID }),
              let paneID = record.paneID else { return nil }
        return owner.tabs.first(where: { $0.id == record.tabID })?.layout.leaf(withID: paneID)?.cwd
    }
}
