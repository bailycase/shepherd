import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI

struct ProjectTaskQuestion: View {
    let ref: LogicalProjectRef
    let task: ProjectTaskRow
    var runsWorker = true
    @Environment(MobileProjects.self) private var projects
    @Environment(\.scenePhase) private var scenePhase

    private struct ReadKey: Equatable {
        var session: UUID?
        var owner: UUID?
        var active: Bool
    }

    var body: some View {
        let thread = projects.thread(ref, task: task.id)
        let store = thread.store
        let key = ReadKey(session: projects.host(ref)?.session, owner: projects.model.project(ref)?.ownerID,
                          active: scenePhase == .active)
        Group {
            if let dialog = store.dialogs.first, let session = store.session {
                let prompt = NativeQuestionPrompt(dialog: dialog)
                QuestionPanel(prompt: prompt, count: store.dialogs.count,
                              enabled: projects.canRun(ref) && store.supports("answer"), docked: false) { answer in
                    guard let reply = prompt.dialogAnswer(answer) else { return }
                    let request = NativeThreadRequest.answer(expectedSessionID: session.piSessionID, generation: session.generation,
                                                            operationID: UUID(), dialogID: dialog.id, answer: reply)
                    Task { _ = await projects.model.answer(ref, task: task.id, request: request) }
                }
                .id(session.key + ":" + dialog.id)
            } else {
                Text(store.loadError ?? task.detail ?? "Loading question…")
                    .font(.nw(.caption)).foregroundStyle(Color.nw.textSecondary)
            }
        }
        .task(id: key) {
            guard runsWorker else { return }
            guard key.active, let session = key.session else {
                thread.viewers.rest(detached: key.session == nil)
                return
            }
            await thread.viewers.run(connection: session) { [projects] in
                try await projects.native(ref, task: task.id, request: $0)
            }
        }
    }
}

struct ProjectSpaceOffer: View {
    let ref: LogicalProjectRef
    let proposal: ProjectSpaceProposal
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        let space = proposal.spaceID.flatMap { id in projects.host(ref)?.state.spaces.first { $0.id == id } }
        let path = space?.path ?? proposal.displayPath
        NWLeadSpaceOffer(name: space?.name ?? (path as NSString).lastPathComponent,
                         path: "\(path) · \(projects.host(ref)?.name ?? "Host")", enabled: projects.canRun(ref)) {
            Task { _ = await projects.model.decideSpace(ref, proposal: proposal, accept: false) }
        } add: {
            Task { _ = await projects.model.decideSpace(ref, proposal: proposal, accept: true) }
        }
    }
}
