import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The Project's tasks, grouped by what they need from you (Waiting on you, Working, Stopped,
/// Resolved). Every row is a task the owner's record holds; each opens its worker's thread.
struct ProjectTaskList: View {
    let ref: LogicalProjectRef
    @Environment(MobileProjects.self) private var projects
    @State private var query = ""
    @State private var history: (input: ProjectHistoryInput, items: [ProjectHistoryInput.Item])?

    var body: some View {
        let page = projects.pages[ref]
        let input = ProjectHistoryInput(rows: page?.rows ?? [], query: query)
        let items = history?.input == input ? history?.items : nil
        let status = page.map { Text($0.status).font(.sh(.ui)).foregroundStyle(Color.sh.textSecondary) }
        ScrollView {
            Group {
                if input.rows.isEmpty || items?.isEmpty == true {
                    // Let the scroll view center the text block at its natural width.
                    VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                        status
                        if input.rows.isEmpty {
                            Text("Threads the project starts show here, grouped by what they need from you.")
                                .font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("No thread matches.").font(.sh(.ui)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                } else {
                    let now = Date()
                    LazyVStack(alignment: .leading, spacing: 0) {
                        status
                        ForEach(items ?? history?.items ?? []) { item in
                            VStack(spacing: 0) {
                                switch item {
                                case .header(let group, let count):
                                    SHListHeader(group.rawValue, attention: group == .waiting, count: count)
                                        .padding(.top, MobileLayout.sectionSpacing)
                                case .row(let row, let first, let last):
                                    SHListCardSegment(first: first, last: last) {
                                        ProjectTaskHistoryRow(ref: ref, row: row,
                                                              age: row.settledAt.map { ProjectAge.text($0, now: now) })
                                            .equatable()
                                    }
                                    .padding(.top, first ? MobileLayout.headerSpacing : 0)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, MobileLayout.sectionSpacing)
        }
        .onChange(of: input, initial: true) { _, input in
            history = (input, input.items())
        }
        .searchable(text: $query, prompt: "Search threads")
        .refreshable { await projects.model.refresh(ref.home) }
        .background(Color.sh.bgWindow)
    }
}

private struct ProjectTaskHistoryRow: View, Equatable {
    let ref: LogicalProjectRef
    let row: ProjectTaskRow
    let age: String?
    @Environment(MobileNavigator.self) private var navigator

    static func == (a: Self, b: Self) -> Bool { a.ref == b.ref && a.row == b.row && a.age == b.age }

    var body: some View {
        let _ = SHRenderProbe.tick("ios.projectTask.row")
        Button { navigator.open(.projects(.task(ref, row.id))) } label: {
            SHListRow(row.title, subtitle: row.line, subtitleMono: false,
                      leading: .state(row.mobileState),
                      trailing: age.map { .meta($0) } ?? .none)
        }
        .buttonStyle(.shRow(radius: 0))
    }
}

struct ProjectTasksScreen: View {
    let ref: LogicalProjectRef
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        ProjectTaskList(ref: ref)
            .toolbar(.hidden, for: .tabBar)
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New thread", systemImage: "plus") { navigator.present(.projects(.assign(ref))) }
                        .disabled(!projects.canRun(ref) || projects.model.project(ref)?.linkedSpaces.isEmpty != false)
                }
            }
    }
}

/// One task's worker thread, read and steered through the Project's owner
/// (`ProjectRuntimeTransport.worker`), keyed by Project and task, never by agent. Its composer
/// steers the worker natively; a resolved task is terminal: its history and no composer.
struct ProjectTaskScreen: View {
    let ref: LogicalProjectRef
    let task: ProjectTaskID
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var openProblem: String?

    private struct RunKey: Equatable {
        var session: UUID?
        var owner: UUID?
        var active: Bool
    }

    var body: some View {
        let row = projects.pages[ref]?.rows.first { $0.id == task }
        let thread = projects.thread(ref, task: task)
        let store = thread.store
        let host = projects.host(ref)
        let key = RunKey(session: row == nil ? nil : host?.session, owner: projects.model.project(ref)?.ownerID, active: visible && scenePhase == .active)
        Group {
            if let row, let synthetic = AgentRef.project(ref, task: task) {
                ThreadTranscript(ref: synthetic, store: store, banner: banner(host: host, store: store))
                    .environment(\.projectTranscript, true)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: MobileLayout.composerSpacing) {
                            if row.group == .resolved {
                                SHLeadFooterCard(symbol: SHGlyph.resolved.symbolName, title: "This thread is resolved.",
                                                 detail: "Its history stays here. New work starts a new thread.")
                                    .padding(.horizontal, MobileLayout.gutter)
                                    .padding(.bottom, MobileLayout.composerBottom)
                            } else if row.phase == .waiting, !row.answerHeld, !store.dialogs.isEmpty {
                                ProjectTaskQuestion(ref: ref, task: row, runsWorker: false)
                                    .padding(.horizontal, MobileLayout.gutter)
                                    .padding(.bottom, MobileLayout.composerBottom)
                            } else {
                                ProjectComposer(ref: ref, task: task)
                            }
                        }
                        .background(Color.sh.bgWindow)
                    }
            } else {
                SHEmptyState(Text("This thread is no longer in the project"), message: "The owner no longer lists this task.") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.sh.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(row?.title ?? "Thread")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let row {
                ToolbarItem(placement: .topBarTrailing) {
                    if row.group == .resolved {
                        Image(systemName: SHGlyph.resolved.symbolName).foregroundStyle(Color.sh.done)
                            .accessibilityLabel("Resolved")
                    } else {
                        Button("Mark resolved", systemImage: SHGlyph.resolved.symbolName) {
                            Task { _ = await projects.model.resolve(ref, task: task) }
                        }
                        .disabled(!row.canResolve || !projects.canRun(ref))
                        .accessibilityHint(row.canResolve ? "" : "Available once this thread's turn has stopped")
                    }
                }
                ToolbarOverflowMenu {
                    Button("Open as a thread", systemImage: "arrow.up.right") { openAsThread() }
                }
            }
        }
        .alert("Can't open the thread", isPresented: Binding(get: { openProblem != nil }, set: { if !$0 { openProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(openProblem ?? "") }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: key) {
            guard key.active, let session = key.session else {
                thread.viewers.rest(detached: key.session == nil)
                return
            }
            await thread.viewers.run(connection: session) { [projects] in try await projects.native(ref, task: task, request: $0) }
        }
    }

    private func banner(host: MobileHost?, store: NativeThreadStore) -> String? {
        guard let host else { return "This host was forgotten." }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known thread" }
        if let error = store.loadError { return error }
        if let problem = store.startProblem { return "\(problem.title) \(problem.advice(host: host.name))" }
        return nil
    }

    /// The worker's ordinary thread on the owner (the Mac's Open as a thread). A worker the owner
    /// placed on another Mac has no route from here, so it says so rather than search by agent ID.
    private func openAsThread() {
        guard case .host(let owner) = ref.home, let host = projects.host(ref),
              let record = projects.model.project(ref)?.tasks.first(where: { $0.id == task }) else {
            openProblem = "This thread is no longer in the project."; return
        }
        guard record.destination == .local else {
            openProblem = "This thread runs on a Mac that \(host.name) reaches. Read it here, or open it on that Mac."; return
        }
        guard host.phase.isConnected, host.agent(record.workerAgentID) != nil else {
            openProblem = "\(host.name) is not connected, or no longer has this thread."; return
        }
        navigator.open(.thread(AgentRef(host: owner, agent: record.workerAgentID)))
    }
}
