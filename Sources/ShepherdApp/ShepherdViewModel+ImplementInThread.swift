import AppKit
import Foundation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

// Handing a design's piece to a thread from its canvas (RefImplementMenu, RefImplementSheet,
// RefImplementBoard, RefSentStay, RefCopied, RefNoteBack): the canvas's actions, Implement in a
// thread's sheet and send, Copy reference, and notes back.

@MainActor
extension ShepherdViewModel {
    // MARK: The canvas

    /// What a local design's canvas does with references and notes.
    func designReferenceCanvasActions() -> DesignReferenceCanvasActions {
        let server = server
        return DesignReferenceCanvasActions(
            implement: { [weak self] in self?.openImplementSheet($0) },
            copy: { [weak self] in self?.copyDesignReference($0) },
            notes: { try await server.designThreadNotes($0) },
            removeNote: { try await server.removeDesignThreadNote($0, noteID: $1) },
            openThread: { [weak self] in self?.selectAgent($0) },
            threadExists: { [weak self] id in self?.state.agents.contains { $0.id == id } == true },
            report: { [weak self] in self?.remoteActionError = $0 })
    }

    /// A thread left or the user removed a note: the canvas reads the notes again.
    func designThreadNotesChanged(_ id: DesignID) {
        guard let screen = designScreens[id] else { return }
        Task { await screen.refreshNotes() }
    }

    /// Implement in a thread… (the board actions, the right-click menu, the design's •••, ⌘↩):
    /// the sheet, with the piece pinned as it opens.
    func openImplementSheet(_ selection: DesignReferenceSelection) {
        guard implementSheet == nil, let reference = selection.reference else { return }
        let model = ImplementSheetModel(selection: selection, threads: implementThreads(), projects: implementProjects(),
                                        project: defaultImplementProject(selection.designID), opensThread: settings.implementOpensThread,
                                        picture: implementPicture(selection))
        implementSheet = model
        Task {
            do {
                model.prepared(try await prepareDesignReference(reference))
            } catch {
                model.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    func closeImplementSheet() {
        guard implementSheet?.sending != true else { return }
        implementSheet = nil
    }

    /// Send: to the thread picked, or to a new thread in the project (on a new worktree of it);
    /// then the thread, or the canvas with a toast offering it.
    func sendImplementSheet(_ model: ImplementSheetModel) {
        guard model.canSend, let prepared = model.prepared else { return }
        let text = model.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let opens = model.opensThread
        let designID = model.selection.designID
        // "Open the thread after sending" is remembered for the next sheet.
        if settings.implementOpensThread != opens { settings.implementOpensThread = opens }
        model.sending = true
        model.error = nil
        Task {
            defer { model.sending = false }
            do {
                let agentID: AgentID
                switch model.mode {
                case .existing:
                    guard let id = model.thread.map(AgentID.init(rawValue:)), state.agents.contains(where: { $0.id == id }) else {
                        throw DesignReferenceFailure("That thread is gone.")
                    }
                    agentID = id
                    try await sendDesignReferences([prepared.reference], text: text, to: agentID)
                case .new:
                    agentID = try await startImplementThread(model, piece: model.piece, select: opens)
                    try await sendDesignReferences([prepared.reference], text: text, to: agentID)
                }
                implementSheet = nil
                if opens {
                    selectAgent(agentID)
                } else {
                    let name = state.agents.first { $0.id == agentID }?.name ?? "the thread"
                    referenceToast = DesignReferenceToast(designID: designID, kind: .sent(thread: agentID, name: name), piece: model.piece)
                }
            } catch {
                model.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// A new thread in the chosen project, on a new worktree when it is a git checkout, through
    /// the same creation as the New thread page's.
    private func startImplementThread(_ model: ImplementSheetModel, piece: String, select: Bool) async throws -> AgentID {
        guard let project = model.chosenProject, let space = state.spaces.first(where: { $0.id == project.id }) else {
            throw DesignReferenceFailure("That space is gone.")
        }
        var config = NewAgentConfig(spaceID: space.id, workingDirectory: space.path, model: settings.agentDefaults.model,
                                    thinking: settings.defaultThinking, initialPrompt: nil)
        config.initialName = "Implement " + piece
        if project.isRepo {
            let repo = space.path
            let mode = settings.worktreeBaseMode
            let fetch = settings.worktreeFetchBeforeCreate
            let (path, branch, base) = try await Task.detached(priority: .userInitiated) { () -> (String, String, String) in
                let resolution = GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetch)
                var lastError: Error?
                for attempt in 1...5 {
                    let branch = ImplementBranch.name(for: piece, attempt: attempt)
                    do {
                        return (try GitWorktree.add(repo: repo, branch: branch, from: resolution.startPoint), branch, resolution.display)
                    } catch {
                        lastError = error
                    }
                }
                throw lastError ?? DesignReferenceFailure("Couldn't make a worktree.")
            }.value
            config.workingDirectory = path
            config.worktreeBranch = branch
            config.worktreeBase = base
            config.worktreePath = path
        }
        return try await startAgent(config, selectAfter: select, focusWindow: false)
    }

    /// Copy reference (the right-click menu, the design's •••, ⇧⌘C): the piece pinned now, its
    /// string on the pasteboard, and a toast saying so.
    func copyDesignReference(_ selection: DesignReferenceSelection) {
        guard let reference = selection.reference else { return }
        Task {
            do {
                let prepared = try await prepareDesignReference(reference)
                copyToPasteboard(prepared.reference.string)
                referenceToast = DesignReferenceToast(designID: selection.designID, kind: .copied, piece: selection.piece)
            } catch {
                remoteActionError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// The threads the sheet lists: this Mac's threads that draw no design, most recently active
    /// first, with their project and how long ago they were active.
    func implementThreads(now: Date = Date()) -> [ImplementSheetModel.Thread] {
        let names = Dictionary(state.spaces.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return designAttachTargets.compactMap { target in
            guard let agent = state.agents.first(where: { $0.id == target.id }) else { return nil }
            return ImplementSheetModel.Thread(id: agent.id, name: agent.name, project: names[agent.spaceID],
                                              age: agent.lastActiveAt.map { Self.implementAge($0, now: now) })
        }
    }

    /// "4m", "1h", "yesterday", "2d".
    static func implementAge(_ milliseconds: Double, now: Date) -> String {
        let seconds = now.timeIntervalSince1970 - milliseconds / 1000
        if seconds < 86_400 { return nwCommentAge(since: milliseconds, now: now) }
        return SuggestionsPresentation.when(milliseconds / 1000, now: now) == "yesterday" ? "yesterday" : nwCommentAge(since: milliseconds, now: now)
    }

    /// The projects a new thread can start in: every project the sidebar shows.
    func implementProjects() -> [ImplementSheetModel.Project] {
        visibleSpaces.filter { !$0.holdsDesigns }.map {
            ImplementSheetModel.Project(id: $0.id, name: $0.name, path: $0.path, isRepo: spaceIsRepo($0))
        }
    }

    /// The project a new thread starts in by default: the one the design's system was built from,
    /// else the project of the most recently active thread.
    func defaultImplementProject(_ designID: DesignID) -> SpaceID? {
        let projects = Set(implementProjects().map(\.id))
        if let namespace = design(designID)?.systemNamespace, let space = designSystems.summary(namespace)?.info.spaceID,
           projects.contains(space) {
            return space
        }
        return state.agents
            .filter { $0.designID == nil && projects.contains($0.spaceID) }
            .max { ($0.lastActiveAt ?? -1) < ($1.lastActiveAt ?? -1) }?.spaceID
    }

    /// The sheet's picture: the element cut from its board as the canvas drew it, the board, or
    /// the design's first board.
    func implementPicture(_ selection: DesignReferenceSelection) -> NWReferenceImage? {
        let host = designRendering.host(for: selection.designID)
        var image: CGImage?
        if let board = selection.board {
            // Observed: a view drawing this draws again when the board's snapshot lands.
            _ = host?.tokens[board]
            image = host?.image(board) ?? designRendering.boardPictures.image(selection.designID, board)
            if let element = selection.element, let whole = image,
               let size = designScreens[selection.designID]?.snapshot?.index.boards[board].map({ CGSize(width: $0.w, height: $0.h) }) {
                image = Self.crop(whole, board: size, rect: element.rect) ?? whole
            }
        } else {
            image = designRendering.thumbnails.image(selection.designID)
        }
        return image.map { NWReferenceImage(id: "implement/" + (selection.reference?.string ?? ""), image: Image(decorative: $0, scale: 2)) }
    }

    /// `rect` (in the board's points) cut from a picture of the whole board.
    static func crop(_ image: CGImage, board: CGSize, rect: CGRect) -> CGImage? {
        guard board.width > 0, board.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / board.width, scaleY = CGFloat(image.height) / board.height
        let pixels = CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY).integral
        return image.cropping(to: pixels.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }
}
