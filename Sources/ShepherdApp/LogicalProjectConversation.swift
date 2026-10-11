import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Project conversation (ProjectLead-Started, -Question, -Paused, -Resolved): the shared thread over the
// coordinator's own native store, never a copied transcript. The composer is the thread's own card; only its send
// goes through the Project runtime. Before the first message there is no coordinator, so the page shows the Project's
// context (the Empty overview) and the composer; the first send creates the conversation.

/// The main column: the pause banner (while paused), then the thread (or the empty overview) with the composer.
struct LogicalProjectConversation: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let presentation: ProjectPagePresentation

    var body: some View {
        VStack(spacing: 0) {
            if project.paused { PausedBanner(vm: vm, ref: ref, project: project) }
            // The coordinator's own thread: this Mac's for a local Project, the owner's for a remote one (read through the owner).
            if let agent = project.coordinatorAgentID {
                ConversationThread(vm: vm, ref: ref, project: project, presentation: presentation, agent: agent)
            } else {
                ConversationThread.empty(vm: vm, ref: ref, project: project, presentation: presentation)
            }
        }
        .background(Color.nw.bgWindow)
    }
}

/// "Paused. Threads stopped at a safe point and nothing new starts. Messages wait until you resume." and Resume.
/// While the owner has not yet acknowledged the interruption, Resume is refused (the runtime says so), never faked.
private struct PausedBanner: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project

    var body: some View {
        HStack(spacing: NWLeadMetrics.bannerGap) {
            Image(systemName: "pause").font(.system(size: NWLeadMetrics.bannerGlyph)).foregroundStyle(Color.nw.textSecondary)
                .accessibilityHidden(true)
            Text(project.interruptPending
                 ? "Paused. Stopping threads at a safe point. Messages wait until you resume."
                 : "Paused. Threads stopped at a safe point and nothing new starts. Messages wait until you resume.")
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(Color.nw.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Resume") { Task { _ = await vm.logicalProjects.setPaused(ref, false) } }
                .buttonStyle(NWLeadSecondaryButton())
                .disabled(vm.logicalProjects.busy.contains(ref.id) || project.interruptPending)
        }
        .padding(NWLeadMetrics.bannerPadding)
        .frame(height: NWLeadMetrics.bannerHeight)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(Color.nw.lineStrong, radius: NW.Radius.m)
        .padding(.horizontal, NWLeadMetrics.bannerInset)
        .padding(.top, NWLeadMetrics.bannerTop)
        .accessibilityElement(children: .contain)
    }
}

/// The thread, mounted once per coordinator, with the Project's composer wiring.
struct ConversationThread: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let project: Project
    let presentation: ProjectPagePresentation
    let agent: AgentID?

    /// No coordinator yet: the shared thread over an empty store, so the composer and its empty state are the real ones.
    static func empty(vm: ShepherdViewModel, ref: LogicalProjectRef, project: Project, presentation: ProjectPagePresentation) -> some View {
        ConversationThread(vm: vm, ref: ref, project: project, presentation: presentation, agent: nil)
    }

    var body: some View {
        ThreadView(store: store, active: true, isFocused: true, request: request, commandKey: nil, agentName: project.name,
                   allowsLocalFiles: ref.home == .local, retainedInput: agent.map { vm.threadStores.input(for: $0) } ?? vm.emptyProjectInput)
            .environment(\.projectComposerSend, composerSend)
            .environment(\.nwUserBubbleMetrics, .lead)   // the boards' bubble: 520pt measure, 12 / 16 padding
            .environment(\.nwProseHalfLeading, true)     // and CSS's half-leading above and below a paragraph's lines
            .environment(\.projectActionCards, actionCards)
            .environment(\.nwProseTaskLinks, ProjectTaskLinks.table(project: ref.id, presentation: presentation))
            .environment(\.openURL, OpenURLAction { [vm, projectID = ref.id] url in
                ProjectTaskLinks.open(url, in: vm, project: projectID, presentation: presentation) ? .handled : .systemAction
            })
            .id(agent?.rawValue ?? "empty")
    }

    /// The coordinator's thread: this Mac's own store for a local Project, a store read through the OWNER for a remote one (its
    /// coordinator is not an agent this Mac runs or lists).
    private var store: NativeThreadStore {
        guard let agent else { return vm.emptyProjectConversation }
        switch ref.home {
        case .local: return vm.projectCoordinator.conversationStore(agentID: agent) ?? vm.emptyProjectConversation
        case .host(let host): return vm.remoteThreadStores.store(for: RemoteAgentRef(hostID: host, agentID: agent))
        }
    }

    private var request: NativeThreadStore.Request {
        if agent != nil, case .host(let host) = ref.home {
            return { [vm, projectID = ref.id] native in
                guard case .native(let result) = try await vm.remoteHosts.projectRuntime(
                    hostID: host, request: .conversation(projectID: projectID, request: native)) else {
                    throw LogicalProjectsError("protocol", "The host answered with something other than the conversation.")
                }
                return result
            }
        }
        guard let agent else {
            // No coordinator exists until the first message: the thread is an empty, ready one (no turns, nothing that can be
            // steered), so the composer shows and no connection is claimed lost. It accepts a send, which is the Project's own
            // (the store's `send` is never called); images are the Project owner's to carry (`ProjectComposerSend.carriesImages`).
            let empty = NativeThreadSnapshot(piSessionID: "project-empty", generation: "0", revision: 0, running: false,
                                             supportedActions: ["send"], dialogsSupported: true, dialogs: [], messages: [],
                                             provisional: [], clipped: false, runtime: "rpc")
            return { _ in .snapshot(value: empty) }
        }
        return { [vm] in try await vm.server.nativeThread(agentID: agent, request: $0) }
    }

    /// The typed results the transcript draws inline. Each is resolved against the owner's CURRENT project here: the task or the
    /// proposal must still exist, and the reference's own project must be this one. A gone task or a consumed proposal draws nothing.
    private var actionCards: ProjectActionCards {
        let resolver = ProjectActionResolver(project: project, presentation: presentation)
        return ProjectActionCards(resolved: { resolver.resolve($0) }, card: { [vm, ref] card in
            switch card {
            case .task(let row): AnyView(ProjectTaskCard(vm: vm, ref: ref, row: row))
            case .proposal(let proposal): AnyView(SpaceOffer(vm: vm, ref: ref, proposal: proposal))
            }
        }, startingThreads: project.tasks.contains { $0.phase == .queued || $0.phase == .reserved })
    }

    private var composerSend: ProjectComposerSend {
        let name = project.name
        // A task whose answer is already held by the owner is not asked again: its row says what became of it.
        let answered = Set(project.tasks.filter { $0.pendingAnswer != nil }.map(\.id))
        let questions: [ProjectTaskRow] = presentation.rows.filter { $0.phase == .waiting && $0.detail != nil && !answered.contains($0.id) }
        // A pending proposal is drawn inline where its typed tool result sits in the transcript. Only one the transcript has no card for
        // (its result is outside the loaded history, or came from a different path) is offered above the composer, so it is never
        // lost and never drawn twice. An accepted or denied proposal is consumed and drawn nowhere.
        let inline = Set((store.messages + store.rows.flatMap(\.turn.messages)).compactMap { $0.projectAction?.proposalID })
        let offers = project.spaceProposals.filter { $0.phase == .pending && !inline.contains($0.id) }
        return ProjectComposerSend(
            placeholder: project.paused ? "Paused. Your message waits until you resume…" : "Ask \(name) a question or start a task…",
            carriesImages: vm.projectCarriesImages(ref.home),
            send: { [vm, ref] text, images in await vm.logicalProjects.sendMessage(ref, text: text, images: images) },
            refusal: { [vm] in vm.logicalProjects.failure?.message },
            emptyState: agent == nil ? { AnyView(LogicalProjectOverview(vm: vm, ref: ref, project: project)) } : nil,
            dock: (presentation.summary != nil || !offers.isEmpty) ? { [vm, ref] in
                AnyView(VStack(spacing: NWLeadMetrics.dockGap) {
                    ForEach(offers) { proposal in SpaceOffer(vm: vm, ref: ref, proposal: proposal) }
                    ForEach(questions) { task in TaskQuestion(vm: vm, ref: ref, task: task) }
                    if let summary = presentation.summary { ProjectSummaryStrip(summary: summary) }
                })
            } : nil,
            held: { [store, project] in
                // Consumed native operations: the thread's own user messages (saved or pending echoes) name the send that became them.
                let consumed = Set((store.messages + store.pending + store.rows.flatMap(\.turn.messages)).compactMap { $0.operationID })
                return ProjectHeldMessages.held(messages: project.messages, paused: project.paused, consumed: consumed)
            },
            runtimeOperations: Set(project.messages.filter { $0.source != nil }.flatMap { [$0.id] + [$0.nativeDeliveryID].compactMap { $0 } }))
    }
}

/// "2 of 3 done · 1 needs you": the strip over the composer. Counted from the tasks, never typed in.
struct ProjectSummaryStrip: View {
    let summary: String

    var body: some View {
        HStack(spacing: NW.Space.s) {
            Image(systemName: "chevron.right").font(.system(size: NWLeadMetrics.summaryChevron, weight: .medium))
                .foregroundStyle(Color.nw.textTertiary).accessibilityHidden(true)
            Text(summary).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(NWLeadMetrics.summaryPadding)
        .frame(height: NWLeadMetrics.summaryHeight)
        .background(Color.nw.bgRaised, in: RoundedRectangle(cornerRadius: NWLeadMetrics.summaryRadius))
        .nwBorder(Color.nw.lineStrong, radius: NWLeadMetrics.summaryRadius)
        .accessibilityLabel(summary)
    }
}

/// A waiting task's question, from the worker's own native dialog (never a copy): its options as the asker offered them,
/// answered through the Project so the same dialog is not answered twice.
struct TaskQuestion: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let task: ProjectTaskRow

    var body: some View {
        let store = vm.projectWorkerStore(ref.home, task.workerAgentID)
        Group {
            if let dialog = store.dialogs.first, let session = store.session { card(store, dialog, session) }
        }
        // The dialog is the worker's own native one: read it while the card is up. The pane runs the same store when it has this
        // task open, so only one loop ever polls it.
        .task(id: vm.logicalProjectPaneTask == task.id) {
            guard vm.logicalProjectPaneTask != task.id else { return }
            await store.run(request: vm.projectWorkerRequest(ref, task: task.id), preview: nil)
        }
    }

    @ViewBuilder private func card(_ store: NativeThreadStore, _ dialog: NativeThreadDialog, _ session: NativeThreadSession) -> some View {
        let prompt = NativeQuestionPrompt(dialog: dialog)
        NWLeadQuestionCard(
                question: prompt.question,
                options: prompt.options.map { NWLeadQuestionCard.Option(id: $0.number, title: $0.title, detail: $0.detail, recommended: $0.recommended) },
                footer: "Or just reply in chat. \(task.title) keeps going on its best guess until you answer.",
                enabled: store.supports("answer") && prompt.blocked == nil && !vm.logicalProjects.busy.contains(ref.id)) { option in
                    guard let reply = prompt.dialogAnswer(.option(prompt.options.first { $0.number == option.id } ?? prompt.options[0])) else { return }
                    let request = NativeThreadRequest.answer(expectedSessionID: session.piSessionID, generation: session.generation,
                                                             operationID: UUID(), dialogID: dialog.id, answer: reply)
                    Task { _ = await vm.logicalProjects.answer(ref, task: task.id, request: request) }
                }
    }
}

/// One pending proposal to add a Space (ProjectLead-AddsSpace). The owner's own Space is named when the proposal names its ID,
/// otherwise the folder's own name; the path is what the owner recorded, and the host is the owner's name (never this Mac by default).
struct SpaceOffer: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let proposal: ProjectSpaceProposal

    var body: some View {
        let space = proposal.spaceID.flatMap { id in vm.ownerSpaces(of: ref.home).first { $0.id == id } }
        let path = space.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? proposal.displayPath
        NWLeadSpaceOffer(name: space?.name ?? (path as NSString).lastPathComponent,
                         path: "\(path) · \(vm.ownerName(of: ref.home))",
                         enabled: !vm.logicalProjects.busy.contains(ref.id)) {
            Task { _ = await vm.logicalProjects.decideSpace(ref, proposal: proposal, accept: false) }
        } add: {
            Task { _ = await vm.logicalProjects.decideSpace(ref, proposal: proposal, accept: true) }
        }
    }
}

/// One task of the project as an inline card in its conversation. Pressing it opens the task in the pane; a task that needs you
/// carries its own question and "View thread".
struct ProjectTaskCard: View {
    var vm: ShepherdViewModel
    let ref: LogicalProjectRef
    let row: ProjectTaskRow

    var body: some View {
        let waiting = row.group == .waiting
        NWLeadTaskCard(
            title: row.title,
            tone: row.group == .resolved ? .resolved : waiting ? .attention : .running,
            detail: waiting || row.group == .resolved ? nil : vm.workerActivity(row.workerAgentID, home: ref.home),
            question: waiting ? row.detail : nil,
            files: row.files.map { .init(id: $0.id, name: $0.name) },
            open: { open() },
            openFile: { chip in
                // The file is the owner's, named by its receipt: it is read through the owner, never looked up on this Mac.
                guard let file = row.files.first(where: { $0.id == chip.id }) else { return }
                vm.logicalProjectPaneOpen = true
                vm.logicalProjectPaneTask = nil
                vm.logicalProjectPaneTab = .files
                vm.logicalProjectPaneFile = (ref, file)
            },
            viewThread: waiting ? { open() } : nil)
    }

    private func open() {
        vm.logicalProjectPaneOpen = true
        vm.logicalProjectPaneTab = .threads
        vm.logicalProjectPaneTask = row.id
    }
}

/// Resolves a typed Project reference (from a tool result) against the owner's CURRENT Project. The reference is display identity
/// only: the Project must be this one, and the task or pending proposal must still exist, or nothing is drawn. No title, prose or
/// timing is ever consulted.
struct ProjectActionResolver {
    enum Card: Equatable {
        case task(ProjectTaskRow)
        case proposal(ProjectSpaceProposal)
    }

    let project: Project
    let presentation: ProjectPagePresentation

    func resolve(_ action: NativeProjectAction) -> Card? {
        guard action.projectID == project.id else { return nil }
        if let taskID = action.taskID {
            return presentation.rows.first { $0.id == taskID }.map(Card.task)
        }
        if let proposalID = action.proposalID {
            return project.spaceProposals.first { $0.id == proposalID && $0.phase == .pending }.map(Card.proposal)
        }
        return nil
    }
}

/// The typed task references of the coordinator's prose: `[words](shepherd-project-task://<projectID>/<taskID>)`, a standard Markdown
/// link. A reference resolves only when its Project is this one and its task still exists; its chip shows the task's own current
/// title (the model's words are never read), so a renamed or duplicate title still opens the right task.
enum ProjectTaskLinks {
    static func url(project: ProjectID, task: ProjectTaskID) -> String { "\(NWProseTaskLinks.scheme)://\(project.rawValue)/\(task.rawValue)" }

    static func table(project: ProjectID, presentation: ProjectPagePresentation) -> NWProseTaskLinks {
        NWProseTaskLinks(links: Dictionary(uniqueKeysWithValues: presentation.rows.map { row in
            (url(project: project, task: row.id),
             .init(title: row.title, tone: row.group == .resolved ? .resolved : row.group == .waiting ? .attention : .running))
        }))
    }

    /// A press on a link in the Project's prose. A reference to a task of THIS Project opens it in the pane. Any other reference with
    /// the scheme is inert and is never handed to the system, so nothing internal can reach a browser or another app; every other
    /// link is the system's, as in any thread (the result is whether this handled it).
    @MainActor static func open(_ url: URL, in vm: ShepherdViewModel, project: ProjectID, presentation: ProjectPagePresentation) -> Bool {
        guard url.scheme == NWProseTaskLinks.scheme else { return false }
        if let task = task(in: url, project: project, presentation: presentation) {
            vm.logicalProjectPaneOpen = true
            vm.logicalProjectPaneTab = .threads
            vm.logicalProjectPaneTask = task
        }
        return true
    }

    /// The task a link names in this Project, or nil: a stale ID, another Project's or a malformed one.
    static func task(in url: URL, project: ProjectID, presentation: ProjectPagePresentation) -> ProjectTaskID? {
        guard url.scheme == NWProseTaskLinks.scheme, url.host == project.rawValue else { return nil }
        let id = ProjectTaskID(rawValue: url.path.dropFirst().description)
        return presentation.rows.first { $0.id == id }?.id
    }
}
