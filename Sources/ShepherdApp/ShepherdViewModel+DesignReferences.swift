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
        guard await store.send(text: text, references: prepared) else {
            throw DesignReferenceFailure(store.notice ?? "The thread didn't take the message. Check it before sending again.")
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
