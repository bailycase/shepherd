import AppKit
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI

// Git sharing for designs, in the app (docs/designs.md › Sharing with Git): each design's Git
// state as the server answers it, the sheet or dialog that is up, and the presses. Every git step
// is a press: nothing here runs on a timer, and nothing pushes unless a button says push.

/// One design's Git state on screen.
@MainActor @Observable
final class DesignGitDesignState {
    /// Nil while the design isn't shared (the chip offers Share with Git).
    private(set) var state: DesignGitState?
    /// A git action is running.
    var working = false
    /// The panel under the chip is open.
    var panelOpen = false
    var message = ""
    /// The changed file whose preview shows, by its repository path.
    var selected: String?
    var preview: SHGitPanelState.Preview?
    /// The last time the remote was reached, kept across a failed fetch (Offline · last checked).
    var lastChecked: Double?
    /// "Opened from Git" on the canvas, until dismissed.
    var openedNotice: String?
    /// The chip's trailing edge, from the window's: the panel's trailing edge lines up with it.
    private(set) var chipTrailing: CGFloat = 0

    func placeChip(trailing: CGFloat) {
        if chipTrailing != trailing { chipTrailing = trailing }
    }
    /// A Git action's failure, in the panel's notice (never a modal).
    var failure: String?

    func set(_ next: DesignGitState?) {
        if state != next { state = next }
        if let fetched = next?.status.fetchedAt, lastChecked != fetched { lastChecked = fetched }
    }
}

/// Share with Git (GitDesignPublish), over the window while it is up.
@MainActor @Observable
final class DesignGitShareModel {
    let designID: DesignID
    let boards: Int
    var repository = ""
    var message: String
    var error: SHGitSheetError?
    var working = false

    init(designID: DesignID, designName: String, boards: Int) {
        self.designID = designID
        self.boards = boards
        message = "Add \(designName.prefix(1).lowercased() + designName.dropFirst()) design"
    }
}

/// Open from Git (GitDesignOpen), over the window while it is up.
@MainActor @Observable
final class DesignGitOpenModel {
    var repository = ""
    var error: SHGitSheetError?
    var working = false
}

extension ShepherdViewModel {
    /// A design's Git state, made the first time its chip shows.
    func designGit(_ id: DesignID) -> DesignGitDesignState {
        if let git = designGitStates[id] { return git }
        let git = DesignGitDesignState()
        designGitStates[id] = git
        refreshDesignGit(id)
        return git
    }

    /// Reads the design's Git state again (the server announced a change, or the panel opened).
    /// `fetch` asks the remote first: only on a press (Open the panel, Pull), never on a timer.
    func refreshDesignGit(_ id: DesignID, fetch: Bool = false) {
        let server = server
        Task {
            let state = try? await server.designGitState(id, fetch: fetch)
            designGitStates[id]?.set(state)
            if let git = designGitStates[id], let path = git.selected, git.panelOpen { loadDesignGitPreview(id, path: path) }
        }
    }

    /// Whether the design's agent is in a turn: Git waits for it (GitDesignStates › drawing).
    func designAgentDrawing(_ id: DesignID) -> Bool {
        guard let agentID = design(id)?.agentID, let agent = state.agents.first(where: { $0.id == agentID }) else { return false }
        return agent.status == .working
    }

    // MARK: The chip

    /// The chip's press, as the board's chip goes (DesignGitStatus): Share with Git before the
    /// design is shared; Pull paused (a merge waiting, stopped or failed) opens the merge dialog;
    /// Merging shows the chat, where the agent works; else the panel (fetching first, so its
    /// sync line is current), in its merge mode once the merge is ready.
    func pressDesignGitChip(_ id: DesignID) {
        let git = designGit(id)
        guard let state = git.state else { openDesignGitShare(id); return }
        switch state.merge?.phase {
        case .conflict?, .stopped?, .failed?:
            designGitMergeDialog = id
            return
        case .running?:
            designScreens[id]?.paneTab = .chat
            return
        case .ready?, nil:
            break
        }
        git.panelOpen.toggle()
        if git.panelOpen {
            if git.selected == nil {
                git.selected = (state.merge?.phase == .ready ? state.mergeFiles : state.status.files).first?.path
            }
            if git.message.isEmpty, let merge = state.merge, merge.phase == .ready {
                // Git's own wording for a merge commit, which keeps both subjects intact.
                git.message = "Merge \"\(merge.theirs.subject)\" into \(state.status.branch)"
            }
            refreshDesignGit(id, fetch: true)
        }
    }

    func selectDesignGitFile(_ id: DesignID, path: String) {
        let git = designGit(id)
        let files = git.state.map { $0.merge?.phase == .ready ? $0.mergeFiles : $0.status.files } ?? []
        guard let file = files.first(where: { DesignGitPresentation.shown($0.path) == path || $0.path == path }) else { return }
        git.selected = file.path
        loadDesignGitPreview(id, path: file.path)
    }

    private func loadDesignGitPreview(_ id: DesignID, path: String) {
        let server = server
        let merge = designGitStates[id]?.state?.merge?.phase == .ready
        let boards = designScreens[id]?.snapshot?.index.boards ?? [:]
        Task {
            guard let (before, after) = try? await server.designGitPreview(id, path: path, merge: merge) else { return }
            guard designGitStates[id]?.selected == path else { return }
            designGitStates[id]?.preview = DesignGitPresentation.preview(path: path, before: before, after: after, boards: boards, merge: merge)
        }
    }

    /// The panel's state, from the design's.
    func designGitPanel(_ id: DesignID) -> SHGitPanelState? {
        guard let git = designGitStates[id], let state = git.state else { return nil }
        return DesignGitPresentation.panel(.init(state: state, drawing: designAgentDrawing(id), working: git.working,
                                                 selected: git.selected, preview: git.preview,
                                                 boards: designScreens[id]?.snapshot?.index.boards ?? [:], lastChecked: git.lastChecked,
                                                 failure: git.failure, hasMessage: !git.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
    }

    // MARK: Share

    func openDesignGitShare(_ id: DesignID) {
        guard let design = design(id) else { return }
        let boards = designScreens[id]?.snapshot?.index.boards.count ?? design.boardCount ?? 0
        designGitShare = DesignGitShareModel(designID: id, designName: design.name, boards: boards)
    }

    func runDesignGitShare(_ model: DesignGitShareModel) {
        let url = model.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = model.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !message.isEmpty, !model.working else { return }
        model.working = true
        model.error = nil
        let server = server
        Task {
            do {
                let state = try await server.shareDesignWithGit(model.designID, url: url, message: message)
                designGit(model.designID).set(state)
                if designGitShare === model { designGitShare = nil }
            } catch {
                model.error = Self.sheetError(error)
            }
            model.working = false
        }
    }

    // MARK: Open

    func openDesignGitOpen() {
        designGitOpen = DesignGitOpenModel()
    }

    func runDesignGitOpen(_ model: DesignGitOpenModel) {
        let url = model.repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !model.working else { return }
        model.working = true
        model.error = nil
        let server = server
        Task {
            do {
                let design = try await server.openDesignFromGit(url)
                adopt(server.state)
                // The canvas's toast (GitDesignCoworker): what came with it.
                let comments = (try? await server.designComments(design.id).comments.filter { $0.resolvedAt == nil }.count) ?? 0
                let boards = design.boardCount ?? 0
                var detail = [boards == 1 ? "1 board" : "\(boards) boards"]
                if let system = design.systemNamespace { detail.append(system) }
                if comments > 0 { detail.append(comments == 1 ? "1 comment" : "\(comments) comments") }
                designGit(design.id).openedNotice = detail.joined(separator: " · ")
                if designGitOpen === model { designGitOpen = nil }
                // Its chat starts idle, as any design's does: no turn runs until the user sends one.
                openDesign(design.id)
            } catch {
                model.error = Self.sheetError(error)
            }
            model.working = false
        }
    }

    // MARK: Commit, push, pull

    func commitDesignGit(_ id: DesignID, push: Bool) {
        let git = designGit(id)
        let message = git.message.trimmingCharacters(in: .whitespacesAndNewlines)
        // The commit buttons are disabled while the message is empty.
        guard !git.working, !message.isEmpty else { return }
        let merging = git.state?.merge?.phase == .ready
        runDesignGit(id) { server in
            let state = merging ? try await server.commitDesignMerge(id, message: message, push: push)
                : try await server.commitDesign(id, message: message, push: push)
            await MainActor.run {
                git.message = ""
                git.selected = nil
                git.preview = nil
            }
            return state
        }
    }

    func pushDesignGit(_ id: DesignID) {
        runDesignGit(id) { try await $0.pushDesign(id) }
    }

    func pullDesignGit(_ id: DesignID) {
        let git = designGit(id)
        guard !git.working else { return }
        git.working = true
        let server = server
        Task {
            defer { git.working = false }
            do {
                git.failure = nil
                switch try await server.pullDesign(id) {
                case .needsMerge:
                    git.panelOpen = false
                    designGitMergeDialog = id
                case .updated, .upToDate: break
                }
                git.set(try await server.designGitState(id))
            } catch {
                git.failure = Self.message(error)
            }
        }
    }

    private func runDesignGit(_ id: DesignID, _ body: @escaping @Sendable (SessionServer) async throws -> DesignGitState) {
        let git = designGit(id)
        guard !git.working else { return }
        git.working = true
        let server = server
        Task {
            defer { git.working = false }
            do {
                git.failure = nil
                _ = try await body(server)
                // A push that failed shows as the panel's push-failed state, with Retry push.
                git.set(try await server.designGitState(id))
            } catch {
                git.failure = Self.message(error)
            }
        }
    }

    func copyDesignGitURL(_ id: DesignID) {
        guard let url = designGitStates[id]?.state?.status.remoteURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }

    // MARK: The merge

    /// Keep working locally (GitDesignConflict's close): the dialog goes; the merge waits, the
    /// chip reads Pull paused and the canvas says so until the user resolves it or drops it.
    func keepDesignGitLocal(_ id: DesignID) {
        designGitMergeDialog = nil
    }

    /// Drop the merge (the panel's, while it waits): both commits stay; Pull again later.
    func dropDesignGitMerge(_ id: DesignID) {
        designGitMergeDialog = nil
        Task {
            await server.keepDesignLocal(id)
            refreshDesignGit(id)
        }
    }

    /// Resolve with agent (and Try again with agent): one turn of the design's agent. The chat
    /// shows it; the dialog goes.
    func resolveDesignGitMerge(_ id: DesignID) {
        designGitMergeDialog = nil
        designGit(id).failure = nil
        let server = server
        Task {
            do {
                try await server.resolveDesignMergeWithAgent(id)
                designScreens[id]?.paneTab = .chat
            } catch {
                designGit(id).failure = Self.message(error)
                // The dialog comes back with why, so the merge isn't left without a way on.
                designGitMergeDialog = id
            }
            refreshDesignGit(id)
        }
    }

    func stopDesignGitMerge(_ id: DesignID) {
        Task {
            await server.stopDesignMerge(id)
            refreshDesignGit(id)
        }
    }

    /// Review merge: the panel in its merge mode, the first merged file selected.
    func reviewDesignGitMerge(_ id: DesignID) {
        let git = designGit(id)
        if !git.panelOpen { pressDesignGitChip(id) }
    }

    // MARK: Errors

    static func message(_ error: Error) -> String {
        (error as? DesignGitError)?.message ?? String(describing: error)
    }

    static func sheetError(_ error: Error) -> SHGitSheetError {
        if let git = error as? DesignGitError { return SHGitSheetError(title: git.title, detail: git.message) }
        return SHGitSheetError(title: "Git couldn't finish", detail: String(describing: error))
    }
}

// MARK: - Overlays

/// Share with Git and Open from Git over the window, on the sheet scrim. Cancel, the close
/// button and Escape put them away; a share or clone that's running finishes first.
struct DesignGitSheetsOverlay: View {
    var vm: ShepherdViewModel

    var body: some View {
        ZStack {
            if vm.designGitShare != nil || vm.designGitOpen != nil {
                Color.sh.sheetScrim
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .shTransition(.content)
            }
            if let model = vm.designGitShare {
                DesignGitShareSheetHost(model: model, close: { if !model.working { vm.designGitShare = nil } },
                                        share: { vm.runDesignGitShare(model) })
                    // Never taller than the window: its middle scrolls instead.
                    .padding(.vertical, SH.Space.xl)
                    .accessibilityAddTraits(.isModal)
                    .shTransition(.overlay, anchor: .center)
            } else if let model = vm.designGitOpen {
                DesignGitOpenSheetHost(model: model, close: { if !model.working { vm.designGitOpen = nil } },
                                       clone: { vm.runDesignGitOpen(model) })
                    .accessibilityAddTraits(.isModal)
                    .shTransition(.overlay, anchor: .center)
            } else if let id = vm.designGitMergeDialog, let merge = vm.designGitStates[id]?.state?.merge,
                      let status = vm.designGitStates[id]?.state?.status {
                Color.sh.sheetScrim
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .accessibilityHidden(true)
                    .shTransition(.content)
                SHGitMergeDialog(branch: status.branch, upstream: status.upstream,
                                 local: DesignGitPresentation.commit(merge.ours, local: true), incoming: DesignGitPresentation.commit(merge.theirs),
                                 failure: vm.designGitStates[id]?.failure ?? merge.reason,
                                 keepLocal: { vm.keepDesignGitLocal(id) }, resolve: { vm.resolveDesignGitMerge(id) },
                                 drop: { vm.dropDesignGitMerge(id) })
                    .accessibilityAddTraits(.isModal)
                    .shTransition(.overlay, anchor: .center)
                    .onExitCommand { vm.designGitMergeDialog = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(vm.designGitShare != nil || vm.designGitOpen != nil || vm.designGitMergeDialog != nil)
        .shAnimation(.overlay, value: vm.designGitShare != nil || vm.designGitOpen != nil || vm.designGitMergeDialog != nil)
    }
}

private struct DesignGitShareSheetHost: View {
    @Bindable var model: DesignGitShareModel
    let close: () -> Void
    let share: () -> Void

    var body: some View {
        SHGitShareSheet(repository: $model.repository, message: $model.message, boards: model.boards, error: model.error,
                        working: model.working, close: close, share: share)
    }
}

private struct DesignGitOpenSheetHost: View {
    @Bindable var model: DesignGitOpenModel
    let close: () -> Void
    let clone: () -> Void

    var body: some View {
        SHGitOpenSheet(repository: $model.repository, error: model.error, working: model.working, close: close, clone: clone)
    }
}

/// The Git panel under the chip (GitDesignChanges: top trailing, 12pt in, over the canvas and the
/// chat), or the canvas's notices (Opened from Git, Pull paused) at the canvas's top center.
struct DesignGitCanvasLayer: View {
    enum Part { case panel, notices }

    var vm: ShepherdViewModel
    let designID: DesignID
    let part: Part

    var body: some View {
        let git = vm.designGit(designID)
        switch part {
        case .panel:
            GeometryReader { geo in
                ZStack(alignment: .topTrailing) {
                    if git.panelOpen, let panel = vm.designGitPanel(designID) {
                        // Under the chip (GitDesignChanges): its trailing edge lines up with the
                        // chip's, 4pt below the toolbar, never past the window's edges.
                        let trailing = min(max(SH.Space.l, git.chipTrailing), max(SH.Space.l, geo.size.width - SHGitMetrics.panelWidth - SH.Space.l))
                        DesignGitPanelHost(git: git, panel: panel,
                                           maxHeight: max(SHGitMetrics.panelMinHeight, geo.size.height - SH.Space.xs - SH.Space.l),
                                           vm: vm, designID: designID)
                            .padding(.top, SH.Space.xs)
                            .padding(.trailing, trailing)
                            .shTransition(.overlay, anchor: .topTrailing)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
            }
            .allowsHitTesting(git.panelOpen)
            .shAnimation(.overlay, value: git.panelOpen)
        case .notices:
            // As the boards place them: Pull paused at the canvas's bottom leading corner (16pt
            // in, 80pt up, over the canvas toolbar); the Opened from Git toast at its bottom
            // center, 24pt up. Pull paused stays while the merge waits; the toast until dismissed.
            ZStack {
                if [.conflict, .stopped, .failed].contains(git.state?.merge?.phase) {
                    SHGitCanvasNotice(.paused, title: "Pull paused",
                                      detail: "Your work is safe. Resolve overlapping changes before updating the canvas.")
                        .padding(.leading, SH.Space.xl)
                        .padding(.bottom, SHGitMetrics.pausedBottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                if let detail = git.openedNotice {
                    SHGitCanvasNotice(.opened, title: "Opened from Git", detail: detail, dismiss: { git.openedNotice = nil })
                        .padding(.bottom, SHGitMetrics.toastBottom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .shTransition(.sheet, edge: .bottom)
                }
            }
            .shAnimation(.sheet, value: git.openedNotice)
        }
    }
}

private struct DesignGitPanelHost: View {
    @Bindable var git: DesignGitDesignState
    let panel: SHGitPanelState
    let maxHeight: CGFloat
    var vm: ShepherdViewModel
    let designID: DesignID

    var body: some View {
        SHGitPanel(state: panel, message: $git.message, maxHeight: maxHeight,
                   close: { git.panelOpen = false }, pull: { vm.pullDesignGit(designID) },
                   select: { vm.selectDesignGitFile(designID, path: $0) },
                   commit: { vm.commitDesignGit(designID, push: $0) }, push: { vm.pushDesignGit(designID) },
                   copyURL: { vm.copyDesignGitURL(designID) })
            .onExitCommand { git.panelOpen = false }
    }
}
