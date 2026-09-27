import Foundation
import ShepherdCore
import ShepherdProtocol

/// Why a design reference was refused: a stable code, and words for the user or the agent.
public struct DesignReferenceError: Error, Hashable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }

    static func invalid(_ raw: String) -> DesignReferenceError {
        DesignReferenceError("invalid_reference", "\"\(raw.prefix(200))\" is not a design reference")
    }

    static let remote = DesignReferenceError(
        "remote_design", "A reference to a design on another Mac can't go into a thread yet: open the thread on that Mac.")
    static let notAThread = DesignReferenceError("not_a_thread", "A design's agent reads its design with its own tools, not references.")
    static let notGranted = DesignReferenceError(
        "not_granted", "That design piece was not handed to this thread. design_get reads only the references in its messages.")
    static let tooMany = DesignReferenceError(
        "too_many_references", "A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
}

/// A reference the host checked against the design as it is now: the record pi reads (every word
/// in it read from the design's files) and the grant sending it makes.
public struct CheckedDesignReference: Hashable, Sendable {
    public var reference: DesignReference
    public var record: DesignReferenceRecord
    public var grant: DesignGrant
}

/// What the app draws for a reference (a board view off screen, `DesignHost`), into a folder of
/// its drop folder: the board's (or the element's) PNG, the board's standalone page, the
/// element's markup and computed styles. Never on the server's queue.
public struct DesignReferenceRenderRequest: Hashable, Sendable {
    public var reference: DesignReference
    public var aspects: Set<DesignReferenceAspect>

    public init(reference: DesignReference, aspects: Set<DesignReferenceAspect>) {
        self.reference = reference
        self.aspects = aspects
    }
}

/// Reads references off the server's queue: the design store reads and pins on its own queue.
struct DesignReferenceService: Sendable {
    let server: SessionServer

    /// Checks each reference against the design as it is now (the design is in the workspace, the
    /// board on its canvas, the element in the board's source) and pins it at the design's
    /// revision now, keeping a copy of the board for `changes`. The record's words are read
    /// from the files, never taken from what was sent.
    func check(_ references: [DesignReference], files: [[String]?], state: ShepherdState,
               at now: Double) async throws -> [CheckedDesignReference] {
        guard references.count <= DesignReferenceRecord.maxPerMessage else { throw DesignReferenceError.tooMany }
        var out: [CheckedDesignReference] = []
        for (index, reference) in references.enumerated() {
            guard reference.host == .local else { throw DesignReferenceError.remote }
            guard let design = state.designs.first(where: { $0.id == reference.designID }) else {
                throw DesignReferenceError("no_such_design", "That design is no longer here.")
            }
            let board: DesignBoardSource
            let snapshot: DesignSnapshot
            do {
                snapshot = try await server.designs.snapshot(reference.designID)
                guard snapshot.index.boards[reference.board] != nil else { throw DesignStoreError.noSuchBoard(reference.board) }
                board = try await server.designs.pinBoard(reference.designID, path: reference.board)
            } catch let error as DesignStoreError {
                throw DesignReferenceError(error.code, error.description)
            }
            let entry = snapshot.index.boards[reference.board]
            var label: String?
            if let element = reference.element {
                guard let template = DesignTemplate(board: board.source), template.element(for: element) != nil else {
                    throw DesignReferenceError("no_such_element", "\(element) is not on \(reference.board) now.")
                }
                label = template.labels[element.tid]
            }
            let pinned = reference.pinned(at: board.revision)
            let names = (index < files.count ? files[index] : nil)?.filter(Self.isFileName).prefix(8).map { $0 }
            let record = DesignReferenceRecord(
                ref: pinned.string, design: design.name, board: reference.board.viewName,
                boardTitle: entry?.title.flatMap(DesignViewRecord.label), element: reference.element?.description,
                elementLabel: label, revision: board.revision, width: entry?.w, height: entry?.h,
                files: names.flatMap { $0.isEmpty ? nil : $0 })
            let grant = DesignGrant(designID: reference.designID, board: reference.board.rawValue,
                                    element: reference.element?.description, label: label, revision: board.revision,
                                    boardSHA: board.sha256, grantedAt: now)
            out.append(CheckedDesignReference(reference: pinned, record: record, grant: grant))
        }
        return out
    }

    /// An attached file's name as a record lists it: one path segment of plain characters.
    static func isFileName(_ name: String) -> Bool {
        (1...100).contains(name.utf8.count) && !name.hasPrefix(".") && name.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || "@._-".utf8.contains($0)
        }
    }

    /// design_get's answer for `aspect` of a granted reference. Everything read from the design is
    /// fenced as data; rendered aspects come back as files in the app's drop folder.
    func answer(_ reference: DesignReference, aspect: DesignReferenceAspect, grant: DesignGrant,
                design: Design) async throws -> DesignReferenceAnswer {
        let snapshot: DesignSnapshot
        do {
            snapshot = try await server.designs.snapshot(reference.designID)
        } catch let error as DesignStoreError {
            throw DesignReferenceError(error.code, error.description)
        }
        let entry = snapshot.index.boards[reference.board]
        let current = entry == nil ? nil : try? await server.designs.board(reference.designID, path: reference.board)
        let element = currentElement(reference, grant: grant, source: current?.source)
        let lead = "design_get \(aspect.rawValue) of \(reference.string)"
        switch aspect {
        case .summary:
            let record = DesignReferenceRecord(
                ref: reference.string, design: design.name, board: reference.board.viewName,
                boardTitle: entry?.title.flatMap(DesignViewRecord.label), element: element?.description,
                elementLabel: element.flatMap { id in current.flatMap { DesignTemplate(board: $0.source)?.labels[id.tid] } },
                revision: snapshot.revision, width: entry?.w, height: entry?.h)
            var shown = reference
            shown.element = element ?? reference.element
            let changed = current.map { $0.sha256 != grant.boardSHA }
            let text = DesignReferenceReading.summary(reference: shown, record: record, pinned: grant.revision,
                                                      changed: changed, onCanvas: current != nil)
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(text))
        case .tokens:
            guard let current else { throw Self.offCanvas }
            let systems = (try? await server.designs.installedSystems(reference.designID)) ?? []
            let piece = DesignReferenceReading.pieceSource(current.source, element: element)
            var tokens = DesignReferenceReading.usedTokens(in: piece, systems: systems)
            var scope = element == nil ? "The board" : "The element"
            if tokens.isEmpty, element != nil {
                tokens = DesignReferenceReading.usedTokens(in: current.source, systems: systems)
                scope = "The element reads none itself; its board"
            }
            let components = DesignReferenceReading.usedComponents(in: element == nil ? current.source : piece, systems: systems)
            var text = DesignReferenceReading.tokensReport(tokens: tokens, components: components, scope: scope)
            if systems.isEmpty { text += "\nThe design has no design system installed." }
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(text))
        case .changes:
            var pinned: String?
            if let sha = grant.boardSHA { pinned = try? await server.designs.pinnedBoard(reference.designID, sha256: sha) }
            let text = DesignReferenceReading.changes(reference: reference, label: grant.label, pinnedRevision: grant.revision,
                                                      revision: snapshot.revision, pinned: pinned, current: current?.source)
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(text))
        case .image, .html, .element:
            guard current != nil else { throw Self.offCanvas }
            if aspect == .element, element == nil {
                throw DesignReferenceError("no_element", reference.element == nil
                    ? "This reference is a whole board: ask for its html or image, or its tokens."
                    : "The referenced element is no longer on the board.")
            }
            var drawn = reference
            drawn.element = aspect == .html ? nil : element
            let rendering = try await server.renderDesignReference(
                DesignReferenceRenderRequest(reference: drawn, aspects: [aspect]))
            let files: [String]
            let note: String
            switch aspect {
            case .image:
                files = rendering.image.map { [$0] } ?? []
                note = drawn.element == nil ? "A PNG of the board at twice its size." : "A PNG of the element cut from its board, at twice its size."
            case .html:
                files = rendering.html.map { [$0] } ?? []
                note = "The board as a standalone page: no runtime, no scripts. Read it with your read tool."
            default:
                files = [rendering.elementHTML, rendering.elementStyles].compactMap { $0 }
                note = "The element's markup as drawn, and its computed styles (JSON). Read them with your read tool."
            }
            guard !files.isEmpty else { throw DesignReferenceError("render_failed", "Shepherd couldn't draw \(reference.board).") }
            let text = lead + "\n" + note + "\n" + files.map { "- \($0)" }.joined(separator: "\n")
            return DesignReferenceAnswer(text: text, files: files, image: aspect == .image ? files.first : nil)
        }
    }

    static let offCanvas = DesignReferenceError("no_such_board", "The referenced board is no longer on the canvas.")

    /// The referenced element in the board's source now: at its id when that still names an
    /// element with its words, else found again by its path and words (`DesignCommentAnchor`).
    func currentElement(_ reference: DesignReference, grant: DesignGrant, source: String?) -> DesignElementID? {
        guard let element = reference.element else { return nil }
        guard let source, let template = DesignTemplate(board: source) else { return nil }
        if template.element(for: element) != nil, template.labels[element.tid] == grant.label { return element }
        guard let found = DesignCommentAnchor.find(path: element.path, label: grant.label, in: template) else { return nil }
        return DesignElementID(board: element.board, tid: found.tid, path: found.path)
    }
}
