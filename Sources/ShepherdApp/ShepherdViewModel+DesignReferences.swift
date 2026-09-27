import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// Design references (docs/designs.md › Design references): a whole design, a board, or one
// element of it handed to an ordinary thread on purpose. The only way anything of a design
// reaches a thread: the host keeps a copy of the piece with the message, fences its record for
// pi, and the thread's agent may read that copy (design_get) from then on. Nothing here opens UI;
// the menus, the Implement sheet, the composer's @ picker and the reference chip call it.

/// Why a reference couldn't be made or sent, in words for the error dialog.
struct DesignReferenceFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
extension ShepherdViewModel {
    /// A piece of a local design, not pinned yet: the whole design (`board` nil), a board, or an
    /// element of it. Nil for a design this Mac doesn't have, or an element on another board.
    func designReference(_ designID: DesignID, board: DesignPath? = nil, element: DesignElementID? = nil) -> DesignReference? {
        guard design(designID) != nil else { return nil }
        return DesignReference(designID: designID, board: board, element: element)
    }

    /// The threads a reference can go to: every local agent that draws no design, most recently
    /// active first (Export's Attach to a thread lists the same).
    var designReferenceTargets: [AgentID] {
        designAttachTargets.map(\.id)
    }

    /// Pins `reference` for Copy reference, the @ picker or the Implement sheet: checked against
    /// the design (another Mac's design, a design, board or element that is gone is refused), at
    /// its revision when a pin kept that version, else now. Answers the pinned, labelled
    /// reference and what a send of it carries (`DesignReferencePresentation.sends(outline)`).
    func prepareDesignReference(_ reference: DesignReference) async throws -> PreparedDesignReference {
        guard reference.host == .local else { throw DesignReferenceFailure(RemoteHostClient.designReferencesRefusal) }
        do {
            return try await server.pinDesignReference(reference)
        } catch let error as DesignReferenceError {
            throw DesignReferenceFailure(error.message)
        }
    }

    /// The @ picker, a pasted reference, "Send vN": `reference` waits in `agentID`'s composer
    /// beside the draft (in place of the same piece), pinned at its revision, and goes with the
    /// next message. Refused for a design's agent, and past five references.
    @discardableResult
    func attachDesignReference(_ reference: DesignReference, to agentID: AgentID) async throws -> NativeAttachedReference {
        try requireReferenceThread(agentID)
        let prepared = try await prepareDesignReference(reference)
        let attached = NativeAttachedReference(reference: prepared.reference, label: prepared.reference.label ?? prepared.piece,
                                               outline: prepared.outline)
        guard threadStores.store(for: agentID).attach(reference: attached) else {
            throw DesignReferenceFailure("A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
        }
        return attached
    }

    /// "Send vN" (a chip whose design moved on): the same piece pinned at the design's revision
    /// now, in the composer in place of the older one. Messages already sent keep theirs; nothing
    /// newer reaches the agent until this goes.
    @discardableResult
    func sendLatestDesignReference(_ reference: DesignReference, to agentID: AgentID) async throws -> NativeAttachedReference {
        try await attachDesignReference(reference.unpinned, to: agentID)
    }

    /// Implement in a thread…: sends `text` with `references` to `agentID`'s thread now, without
    /// touching its draft; while pi works it waits in the queue. The host keeps each piece's copy
    /// at the version it was pinned at and lets the thread's agent read it.
    func sendDesignReferences(_ references: [DesignReference], text: String, to agentID: AgentID) async throws {
        guard !references.isEmpty else { return }
        guard references.count <= DesignReferenceRecord.maxPerMessage else {
            throw DesignReferenceFailure("A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
        }
        try requireReferenceThread(agentID)
        var prepared: [NativeAttachedReference] = []
        for reference in references {
            let pinned = reference.revision == nil ? try await prepareDesignReference(reference).reference : reference
            prepared.append(NativeAttachedReference(reference: pinned, label: pinned.label ?? pinned.string))
        }
        let store = threadStores.store(for: agentID)
        // A thread on screen sends through its store (its echo shows at once); one that isn't (a
        // thread picked from the sheet, or one just started for it) through the host, once its pi
        // serves.
        guard store.ready else {
            try await sendDirectly(prepared, text: text, to: agentID)
            return
        }
        guard await store.send(text: text, references: prepared) else {
            throw DesignReferenceFailure(store.notice ?? "The thread didn't take the message. Check it before sending again.")
        }
    }

    /// How long a send waits for a thread's pi to serve (one just started boots in seconds).
    static let referenceSendWait: Duration = .seconds(90)

    /// Sends a message carrying `references` to a thread nothing on screen is showing: asks the
    /// host for the thread's session (waiting while its pi starts), then sends at it. While pi
    /// works it waits in the host's queue, as any follow-up does.
    private func sendDirectly(_ references: [NativeAttachedReference], text: String, to agentID: AgentID) async throws {
        let server = server
        let deadline = ContinuousClock.now + Self.referenceSendWait
        while true {
            switch try await server.nativeThread(agentID: agentID, request: .snapshot()) {
            case .snapshot(let snapshot) where !snapshot.piSessionID.isEmpty:
                let message = NativeAttachedFile.message(text, files: [], references: references.count)
                let reply = try await server.nativeThread(agentID: agentID, request: .send(
                    expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(), text: message,
                    delivery: .followUp, designReferences: references.map(\.record)))
                if case .failure(_, let why) = reply { throw DesignReferenceFailure(why) }
                return
            case .failure(let code, let why) where code != NativeThreadCode.starting:
                throw DesignReferenceFailure(why)
            default:
                guard ContinuousClock.now < deadline else {
                    throw DesignReferenceFailure("The thread's pi didn't start in time. Nothing was sent.")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func requireReferenceThread(_ agentID: AgentID) throws {
        guard let agent = state.agents.first(where: { $0.id == agentID }) else { throw DesignReferenceFailure("That thread is gone.") }
        guard !state.isDesignAgent(agent), agent.designID == nil else {
            throw DesignReferenceFailure("A design's agent reads its design with its own tools, not references.")
        }
    }

    /// Draws references' copies for the server when a send keeps them (`onDesignReferenceCapture`).
    func installDesignReferenceHandler() {
        // A thread left a note back, or one was removed: the canvas shows it.
        server.onDesignThreadNotesChanged = { [weak self] designID in
            MainActor.assumeIsolated { self?.designThreadNotesChanged(designID) }
        }
        server.onDesignReferenceCapture = { [weak self] request, respond in
            MainActor.assumeIsolated {
                guard let self else {
                    respond(.failure(DesignReferenceError("unavailable", "The workspace is gone.")))
                    return
                }
                Task { @MainActor in
                    do {
                        let files = try await self.server.designExportFiles(request.reference.designID, boards: request.boards.map(\.path))
                        respond(.success(try await self.designRendering.capture(request, files: files)))
                    } catch let error as DesignReferenceError {
                        respond(.failure(error))
                    } catch {
                        respond(.failure(DesignReferenceError("render_failed", (error as? LocalizedError)?.errorDescription ?? "\(error)")))
                    }
                }
            }
        }
    }
}
