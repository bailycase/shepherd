import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A Project's page: the ongoing conversation with its coordinator. Wide enough (iPad, an open
/// iPhone Duo) the task list stands beside it; otherwise Tasks is pushed from the strip over the
/// composer or the toolbar.
struct ProjectScreen: View {
    let ref: LogicalProjectRef
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let project = projects.model.project(ref)
        Group {
            if let project {
                if sizeClass == .regular {
                    PadListDetail(listWidth: MobileLayout.projectTasksWidth) {
                        ProjectTaskList(ref: ref)
                    } detail: {
                        ProjectConversation(ref: ref, project: project, showsSummary: false)
                    } single: {
                        ProjectConversation(ref: ref, project: project, showsSummary: true)
                    }
                } else {
                    ProjectConversation(ref: ref, project: project, showsSummary: true)
                }
            } else {
                NWEmptyState(Text("This project is gone"), message: "It was deleted on its host, or its host was forgotten.") {}
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.nw.bgWindow)
        .toolbar(.hidden, for: .tabBar)
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let project {
                let needsYou = projects.pages[ref]?.needsYou ?? 0
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if sizeClass != .regular {
                        Button { navigator.open(.projects(.tasks(ref))) } label: {
                            Label(needsYou > 0 ? "Tasks, \(needsYou) need you" : "Tasks", systemImage: "list.bullet")
                        }
                        .badge(needsYou)
                    }
                }
                ToolbarOverflowMenu {
                    Button("New thread", systemImage: "plus") { navigator.present(.projects(.assign(ref))) }
                        .disabled(!projects.canRun(ref) || project.linkedSpaces.isEmpty)
                    if projects.host(ref)?.supports(RemoteProtocol.logicalProjectFilesCapability) == true {
                        Button("Files", systemImage: "doc") { navigator.open(.projects(.files(ref, path: ""))) }
                    }
                    Button("Project settings", systemImage: "gearshape") { navigator.open(.projects(.settings(ref))) }
                }
            }
        }
    }
}

/// The coordinator's own native thread, read through the owner (`ProjectRuntimeTransport.conversation`),
/// never a copied transcript. Before the first message there is no coordinator: the overview
/// stands in and the first send creates the conversation.
private struct ProjectConversation: View {
    let ref: LogicalProjectRef
    let project: Project
    let showsSummary: Bool
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    private struct RunKey: Equatable {
        var session: UUID?
        var owner: UUID
        var coordinator: AgentID?
        var active: Bool
    }

    var body: some View {
        let thread = projects.thread(ref)
        let store = thread.store
        let host = projects.host(ref)
        let page = projects.pages[ref]
        let key = RunKey(session: host?.session, owner: project.ownerID, coordinator: project.coordinatorAgentID, active: visible && scenePhase == .active)
        let offline = project.paused || host?.connectedClient == nil
        Group {
            if project.coordinatorAgentID == nil {
                ScrollView { ProjectOverview(ref: ref, project: project, store: store).padding(MobileLayout.gutter) }
            } else if let synthetic = AgentRef.project(ref, task: nil) {
                ThreadTranscript(ref: synthetic, store: store, banner: banner(host: host, store: store))
                    .environment(\.projectTranscript, true)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: MobileLayout.composerSpacing) {
                ProjectDock(ref: ref, project: project, page: page, showsSummary: showsSummary)
                ProjectComposer(ref: ref)
            }
            .background(Color.nw.bgWindow)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onChange(of: offline, initial: true) { _, offline in
            if project.coordinatorAgentID != nil { store.offline = offline }
        }
        .task(id: key) {
            guard key.active, key.coordinator != nil, let session = key.session else {
                thread.viewers.rest(detached: key.session == nil)
                return
            }
            await thread.viewers.run(connection: session) { [projects] in try await projects.native(ref, request: $0) }
        }
    }

    private func banner(host: MobileHost?, store: NativeThreadStore) -> String? {
        guard let host else { return "This host was forgotten." }
        if !host.phase.isConnected { return "\(host.name) is offline · showing the last known conversation" }
        if project.paused { return "Shepherd stopped this project. Your next message starts it again." }
        return store.loadError
    }
}

/// What sits over the composer, in the Mac's order: Space offers, workers' questions, the count strip.
private struct ProjectDock: View {
    let ref: LogicalProjectRef
    let project: Project
    let page: ProjectPagePresentation?
    let showsSummary: Bool
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        let offers = project.spaceProposals.filter { $0.phase == .pending }
        let questions = (page?.rows ?? []).filter { $0.phase == .waiting && !$0.answerHeld }
        VStack(spacing: MobileLayout.composerSpacing) {
            ForEach(offers) { ProjectSpaceOffer(ref: ref, proposal: $0) }
            if projects.thread(ref).store.dialogs.isEmpty {
                ForEach(questions) { ProjectTaskQuestion(ref: ref, task: $0, runsWorker: true) }
            }
            if showsSummary, let summary = page?.summary {
                Button { navigator.open(.projects(.tasks(ref))) } label: {
                    HStack(spacing: NW.Space.s) {
                        Text(summary).font(.nw(.caption))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.nw.textTertiary)
                    .frame(minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show project tasks")
                .accessibilityValue(summary)
            }
        }
        .padding(.horizontal, sizeClass == .regular ? MobileLayout.padThreadGutter : MobileLayout.gutter)
    }
}

/// The empty conversation (ProjectLead-EmptyV2): the name and goal, where its context lives, and
/// Suggestions that put words in the composer for the person to read and send.
private struct ProjectOverview: View {
    let ref: LogicalProjectRef
    let project: Project
    let store: NativeThreadStore
    @Environment(MobileProjects.self) private var projects
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let spaces = projects.host(ref)?.state.spaces ?? []
        let names = project.linkedSpaces.compactMap { link in spaces.first { $0.id == link.spaceID }?.name }
        VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text(project.name).font(.nw(.title, weight: .semibold)).foregroundStyle(Color.nw.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if !project.goal.isEmpty {
                    Text(project.goal).font(.nw(.body)).foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NWListCard {
                Button { navigator.open(.projects(.settings(ref))) } label: {
                    NWListRow("Spaces", subtitle: names.isEmpty ? "None yet · add in settings" : names.joined(separator: ", "),
                              subtitleMono: false, leading: .symbol("folder"))
                }
                .buttonStyle(.nwRow(radius: 0))
                Button { navigator.open(.projects(.settings(ref))) } label: {
                    NWListRow("Instructions, memory", subtitle: "In project settings", subtitleMono: false, leading: .symbol(NWGlyph.document.symbolName))
                }
                .buttonStyle(.nwRow(radius: 0))
            }
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListHeader("Suggestions")
                NWListCard {
                    ForEach(Self.suggestions(firstSpace: names.first), id: \.self) { text in
                        Button { store.draft = text } label: {
                            NWListRow(text, leading: .symbol("sparkles"), chevron: false)
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                }
            }
        }
        .frame(maxWidth: MobileLayout.threadMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
    }

    static func suggestions(firstSpace: String?) -> [String] {
        var items = ["Set up this project from my recent threads", "Help me work out a plan for this project"]
        if let firstSpace { items.append("Look around \(firstSpace) and suggest first threads") }
        return items
    }
}
